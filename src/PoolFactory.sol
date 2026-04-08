// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./SwapPool.sol";
import "./LPToken.sol";
import "./FeeCollector.sol";

/**
 * @title PoolFactory
 * @notice Generic factory that deploys SwapPool + two LPToken contracts per pool
 *         and serves as the on-chain registry of all active pools.
 *
 *         Not tied to any specific prediction market platform. Any two ERC-1155
 *         prediction market contracts can be paired, as long as both are approved
 *         by the owner. One factory serves all market combinations.
 *
 *         Fees are set per-pool at creation time and stored on the pool itself.
 *         The factory only holds the FeeCollector address — the destination for
 *         protocol fees across all pools.
 *
 * ─── Roles ────────────────────────────────────────────────────────────────────
 *
 *   Owner (multisig, slow, critical):
 *     - approveMarketContract / revokeMarketContract
 *     - setFeeCollector
 *     - setOperator
 *     - setPoolFees
 *     - rescuePool*
 *
 *   Operator (EOA, fast, day-to-day):
 *     - createPool
 *     - setPoolDepositsPaused / setPoolSwapsPaused
 *     - resolvePoolAndPausedDeposits / unresolvePool
 *
 *   Operator actions are also executable by owner.
 *
 * ─── Approved market contracts ────────────────────────────────────────────────
 *
 *   Before a market contract can be used in a pool, the owner must explicitly
 *   approve it via approveMarketContract(). This prevents operator mistakes
 *   (wrong address passed to createPool) without locking the factory to specific
 *   contracts at deploy time.
 *
 * ─── Two LP tokens per pool ───────────────────────────────────────────────────
 *
 *   Each pool has a marketALpToken and a marketBLpToken.
 *   Both share the same exchange rate; the token type only records which side
 *   a user deposited from, controlling same-side vs cross-side withdrawal fees.
 *
 * ─── MarketConfig ─────────────────────────────────────────────────────────────
 *
 *   Bundles all parameters describing one side of a pool.
 *   Stored on the pool itself — pools are fully self-describing.
 */
contract PoolFactory is Ownable {

    // ─── Types ────────────────────────────────────────────────────────────────

    /**
     * @notice Full description of one market side in a pool.
     *
     * @param marketContract  ERC-1155 prediction market contract address
     * @param tokenId         Outcome/event ID within that contract
     * @param decimals        Decimal precision of the shares (max 18)
     * @param name            Human-readable platform name, e.g. "Polymarket"
     */
    struct MarketConfig {
        address marketContract;
        uint256 tokenId;
        uint8   decimals;
        string  name;
    }

    struct PoolInfo {
        address swapPool;
        address marketALpToken;
        address marketBLpToken;
        MarketConfig marketA;
        MarketConfig marketB;
    }

    // ─── Roles ────────────────────────────────────────────────────────────────

    /// @notice Operator address — can manage day-to-day pool operations.
    ///         Owner can always perform operator actions too.
    address public operator;

    // ─── Fee collector ────────────────────────────────────────────────────────

    /// @notice Destination for protocol fees across all pools.
    FeeCollector public feeCollector;

    // ─── State ────────────────────────────────────────────────────────────────

    /// @notice Whitelisted ERC-1155 prediction market contracts.
    ///         Only approved contracts can be used in createPool().
    mapping(address => bool) public approvedMarketContracts;

    PoolInfo[] public pools;

    /// @notice keccak256(marketAContract, marketATokenId, marketBContract, marketBTokenId)
    ///         → poolId, 1-indexed; 0 = not found
    mapping(bytes32 => uint256) public poolIndex;

    // ─── Events ───────────────────────────────────────────────────────────────

    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event MarketContractApproved(address indexed marketContract);
    event MarketContractRevoked(address indexed marketContract);

    event PoolCreated(
        uint256 indexed poolId,
        address swapPool,
        address marketALpToken,
        address marketBLpToken,
        address marketAContract,
        uint256 marketATokenId,
        string  marketAName,
        address marketBContract,
        uint256 marketBTokenId,
        string  marketBName,
        uint256 lpFeeBps,
        uint256 protocolFeeBps
    );
    event PoolDepositsPaused(uint256 indexed poolId, bool isPaused);
    event PoolSwapsPaused(uint256 indexed poolId, bool isPaused);
    event PoolResolved(uint256 indexed poolId, bool isResolved);
    event FeeCollectorUpdated(address indexed oldFeeCollector, address indexed newFeeCollector);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error PoolAlreadyExists(bytes32 key);
    error PoolNotFound(uint256 poolId);
    error ZeroAddress();
    error InvalidTokenID();
    error InvalidDecimals();
    error MissingName();
    error MarketContractNotApproved(address marketContract);
    error NotOperator();

    // ─── Modifiers ────────────────────────────────────────────────────────────

    /// @dev Operator or owner can call.
    modifier onlyOperator() {
        if (msg.sender != operator && msg.sender != owner()) revert NotOperator();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(address feeCollector_, address operator_, address owner_) Ownable(owner_) {
        if (feeCollector_ == address(0)) revert ZeroAddress();
        if (operator_ == address(0)) revert ZeroAddress();
        feeCollector = FeeCollector(feeCollector_);
        operator = operator_;
    }

    // ─── Market contract approval (owner only) ────────────────────────────────

    /// @notice Whitelist an ERC-1155 prediction market contract for use in pools.
    function approveMarketContract(address marketContract_) external onlyOwner {
        if (marketContract_ == address(0)) revert ZeroAddress();
        approvedMarketContracts[marketContract_] = true;
        emit MarketContractApproved(marketContract_);
    }

    /// @notice Remove a market contract from the whitelist.
    ///         Existing pools using this contract are unaffected.
    function revokeMarketContract(address marketContract_) external onlyOwner {
        approvedMarketContracts[marketContract_] = false;
        emit MarketContractRevoked(marketContract_);
    }

    // ─── Pool creation (operator) ─────────────────────────────────────────────

    /**
     * @notice Deploy a new SwapPool + two LPTokens for a matched event-outcome pair.
     *         Both market contracts must be pre-approved via approveMarketContract().
     *         Fees are set at creation time and stored on the pool.
     *
     * @param marketA_        Full config for market A (contract, tokenId, decimals, name)
     * @param marketB_        Full config for market B (contract, tokenId, decimals, name)
     * @param lpFeeBps_       LP fee in basis points, e.g. 30 = 0.30%
     * @param protocolFeeBps_ Protocol fee in basis points, e.g. 10 = 0.10%
     * @param marketALpName   ERC-20 name for marketA LP,   e.g. "PredictSwap BTC-YES PolyLP"
     * @param marketALpSymbol ERC-20 symbol,                e.g. "PS-BTC-YES-POLY"
     * @param marketBLpName   ERC-20 name for marketB LP,   e.g. "PredictSwap BTC-YES OpinionLP"
     * @param marketBLpSymbol ERC-20 symbol,                e.g. "PS-BTC-YES-OPN"
     *
     * @return poolId  Zero-indexed pool ID
     */
    function createPool(
        MarketConfig calldata marketA_,
        MarketConfig calldata marketB_,
        uint256 lpFeeBps_,
        uint256 protocolFeeBps_,
        string calldata marketALpName,
        string calldata marketALpSymbol,
        string calldata marketBLpName,
        string calldata marketBLpSymbol
    ) external onlyOperator returns (uint256 poolId) {
        if (!approvedMarketContracts[marketA_.marketContract])
            revert MarketContractNotApproved(marketA_.marketContract);
        if (!approvedMarketContracts[marketB_.marketContract])
            revert MarketContractNotApproved(marketB_.marketContract);

        if (marketA_.tokenId == 0 || marketB_.tokenId == 0) revert InvalidTokenID();
        if (marketA_.decimals > 18 || marketB_.decimals > 18) revert InvalidDecimals();
        if (bytes(marketA_.name).length == 0 || bytes(marketB_.name).length == 0)
            revert MissingName();

        bytes32 key = _poolKey(marketA_.marketContract, marketA_.tokenId, marketB_.marketContract, marketB_.tokenId);
        if (poolIndex[key] != 0) revert PoolAlreadyExists(key);

        // Deploy both LP tokens with factory as temporary authority
        LPToken marketALp = new LPToken(marketALpName, marketALpSymbol, address(this), marketA_.tokenId);
        LPToken marketBLp = new LPToken(marketBLpName, marketBLpSymbol, address(this), marketB_.tokenId);

        // Deploy pool — fees validated and stored inside SwapPool
        SwapPool pool_ = new SwapPool(
            address(this),
            marketA_,
            marketB_,
            lpFeeBps_,
            protocolFeeBps_,
            address(marketALp),
            address(marketBLp),
            address(feeCollector)
        );

        // Wire both LP tokens to the pool (one-time, irreversible)
        marketALp.setPool(address(pool_));
        marketBLp.setPool(address(pool_));

        poolId = pools.length;
        pools.push(PoolInfo({
            swapPool:       address(pool_),
            marketALpToken: address(marketALp),
            marketBLpToken: address(marketBLp),
            marketA:        marketA_,
            marketB:        marketB_
        }));
        poolIndex[key] = poolId + 1;

        emit PoolCreated(
            poolId,
            address(pool_),
            address(marketALp),
            address(marketBLp),
            marketA_.marketContract,
            marketA_.tokenId,
            marketA_.name,
            marketB_.marketContract,
            marketB_.tokenId,
            marketB_.name,
            lpFeeBps_,
            protocolFeeBps_
        );
    }

    // ─── Registry reads ───────────────────────────────────────────────────────

    function getPool(uint256 poolId) external view returns (PoolInfo memory) {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        return pools[poolId];
    }

    function getAllPools() external view returns (PoolInfo[] memory) {
        return pools;
    }

    function poolCount() external view returns (uint256) {
        return pools.length;
    }

    function findPool(
        address marketAContract_,
        uint256 marketATokenId_,
        address marketBContract_,
        uint256 marketBTokenId_
    )
        external
        view
        returns (bool found, uint256 poolId)
    {
        uint256 idx = poolIndex[_poolKey(marketAContract_, marketATokenId_, marketBContract_, marketBTokenId_)];
        if (idx == 0) return (false, 0);
        return (true, idx - 1);
    }

    // ─── Admin — owner only ───────────────────────────────────────────────────

    /// @notice Update the operator address. Owner only.
    function setOperator(address operator_) external onlyOwner {
        if (operator_ == address(0)) revert ZeroAddress();
        emit OperatorUpdated(operator, operator_);
        operator = operator_;
    }

    /// @notice Update fee collector. Affects new pools only — existing pools keep their
    ///         hardcoded feeCollector address from deploy time.
    function setFeeCollector(address feeCollector_) external onlyOwner {
        if (feeCollector_ == address(0)) revert ZeroAddress();
        emit FeeCollectorUpdated(address(feeCollector), feeCollector_);
        feeCollector = FeeCollector(feeCollector_);
    }

    /// @notice Update fees for a specific pool. Owner only.
    function setPoolFees(uint256 poolId, uint256 lpFeeBps_, uint256 protocolFeeBps_) external onlyOwner {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        SwapPool(payable(pools[poolId].swapPool)).setFees(lpFeeBps_, protocolFeeBps_);
    }

    // ─── Admin — operator ─────────────────────────────────────────────────────

    function setPoolDepositsPaused(uint256 poolId, bool paused_) external onlyOperator {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        SwapPool(payable(pools[poolId].swapPool)).setDepositsPaused(paused_);
        emit PoolDepositsPaused(poolId, paused_);
    }

    function setPoolSwapsPaused(uint256 poolId, bool paused_) external onlyOperator {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        SwapPool(payable(pools[poolId].swapPool)).setSwapsPaused(paused_);
        emit PoolSwapsPaused(poolId, paused_);
    }

    /// @notice Mark a pool as resolved and pause deposits. Cross-side withdrawals become fee-free.
    ///         Call once the underlying prediction market event has settled.
    function resolvePoolAndPausedDeposits(uint256 poolId) external onlyOperator {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        SwapPool(payable(pools[poolId].swapPool)).setResolvedAndPausedDeposits();
        emit PoolResolved(poolId, true);
    }

    /// @notice In case it was resolved by mistake.
    function unresolvePool(uint256 poolId) external onlyOperator {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        SwapPool(payable(pools[poolId].swapPool)).unsetResolved();
        emit PoolResolved(poolId, false);
    }

    // ─── Rescue — owner only ──────────────────────────────────────────────────

    function rescuePoolTokens(uint256 poolId, SwapPool.Side side, uint256 amount, address to)
        external onlyOwner
    {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        SwapPool(payable(pools[poolId].swapPool)).rescueTokens(side, amount, to);
    }

    function rescuePoolERC1155(uint256 poolId, address contractAddress, uint256 tokenId, uint256 amount, address to)
        external onlyOwner
    {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        SwapPool(payable(pools[poolId].swapPool)).rescueERC1155(contractAddress, tokenId, amount, to);
    }

    function rescuePoolERC20(uint256 poolId, address token, uint256 amount, address to)
        external onlyOwner
    {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        SwapPool(payable(pools[poolId].swapPool)).rescueERC20(token, amount, to);
    }

    function rescuePoolETH(uint256 poolId, address payable to) external onlyOwner {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        SwapPool(payable(pools[poolId].swapPool)).rescueETH(to);
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    /// @dev Pool uniqueness is determined by (contractA, tokenIdA, contractB, tokenIdB).
    ///      Name, decimals, and fees are not part of the key.
    function _poolKey(
        address marketAContract_,
        uint256 marketATokenId_,
        address marketBContract_,
        uint256 marketBTokenId_
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(marketAContract_, marketATokenId_, marketBContract_, marketBTokenId_));
    }
}