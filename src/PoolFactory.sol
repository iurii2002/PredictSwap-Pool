// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./SwapPool.sol";
import "./LPToken.sol";
import "./FeeCollector.sol";

/**
 * @title PoolFactory
 * @notice Team-only factory that deploys SwapPool + two LPToken contracts per pool
 *         and serves as the on-chain registry of all active pools.
 *
 *         Both the Polymarket ERC-1155 contract and WrappedOpinionToken contract
 *         are fixed at construction — only token IDs vary per pool.
 *
 *         Swap fees are global and configurable by owner, capped by hard limits.
 *         All pools read fees from here at swap time.
 *
 * ─── Two LP tokens per pool ───────────────────────────────────────────────────
 *
 *   Each pool has a polyLpToken and an opinionLpToken.
 *   Both share the same exchange rate; the token type only records which side
 *   a user deposited from, controlling same-side vs cross-side withdrawal fees.
 */
contract PoolFactory is Ownable {
    // ─── Types ────────────────────────────────────────────────────────────────

    struct PoolInfo {
        address swapPool;
        address polyLpToken;
        address opinionLpToken;
        uint256 polymarketTokenId;
        uint256 opinionTokenId;
    }

    // ─── Immutable config ─────────────────────────────────────────────────────

    /// @notice If Polymarket or Opinion migrates their contract, redeploy this factory.
    /// @notice The single Polymarket ERC-1155 contract on Polygon
    address public immutable polymarketToken;
    /// @notice The single WrappedOpinionToken ERC-1155 contract on Polygon
    address public immutable opinionToken;
    /// @notice Protocol fee recipient
    FeeCollector public feeCollector;

    // ─── Configurable fees ────────────────────────────────────────────────────

    uint256 public lpFeeBps = 30;       // 0.30% default
    uint256 public protocolFeeBps = 10; // 0.10% default

    uint256 public constant FEE_DENOMINATOR = 10_000;
    uint256 public constant MAX_LP_FEE = 100;      // 1.00% hard cap
    uint256 public constant MAX_PROTOCOL_FEE = 50; // 0.50% hard cap

    // ─── State ────────────────────────────────────────────────────────────────

    PoolInfo[] public pools;

    /// @notice (polymarketTokenId, opinionTokenId) → poolId, 1-indexed; 0 = not found
    mapping(bytes32 => uint256) public poolIndex;

    // ─── Events ───────────────────────────────────────────────────────────────

    event PoolCreated(
        uint256 indexed poolId,
        address swapPool,
        address polyLpToken,
        address opinionLpToken,
        uint256 polymarketTokenId,
        uint256 opinionTokenId
    );
    event FeesUpdated(uint256 lpFeeBps, uint256 protocolFeeBps);
    event PoolDepositsPaused(uint256 indexed poolId, bool isPaused);
    event PoolSwapsPaused(uint256 indexed poolId, bool isPaused);
    event PoolResolved(uint256 indexed poolId, bool isResolved);
    event FeeCollectorUpdated(address indexed oldFeeCollector, address indexed newFeeCollector);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error PoolAlreadyExists(bytes32 key);
    error PoolNotFound(uint256 poolId);
    error ZeroAddress();
    error InvalidTokenID();
    error FeeTooHigh();

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(address polymarketToken_, address opinionToken_, address feeCollector_, address owner_)
        Ownable(owner_)
    {
        if (polymarketToken_ == address(0) || opinionToken_ == address(0) || feeCollector_ == address(0))
            revert ZeroAddress();

        polymarketToken = polymarketToken_;
        opinionToken = opinionToken_;
        feeCollector = FeeCollector(feeCollector_);
    }

    // ─── Fee config ───────────────────────────────────────────────────────────

    /**
     * @notice Update swap fees. Changes take effect immediately for all pools.
     * @param lpFeeBps_        New LP fee in basis points (max 100 = 1.00%)
     * @param protocolFeeBps_  New protocol fee in basis points (max 50 = 0.50%)
     */
    function setFees(uint256 lpFeeBps_, uint256 protocolFeeBps_) external onlyOwner {
        if (lpFeeBps_ > MAX_LP_FEE || protocolFeeBps_ > MAX_PROTOCOL_FEE) revert FeeTooHigh();
        lpFeeBps = lpFeeBps_;
        protocolFeeBps = protocolFeeBps_;
        emit FeesUpdated(lpFeeBps_, protocolFeeBps_);
    }

    /// @notice Total fee in basis points (LP + protocol)
    function totalFeeBps() external view returns (uint256) {
        return lpFeeBps + protocolFeeBps;
    }

    // ─── Pool creation ────────────────────────────────────────────────────────

    /**
     * @notice Deploy a new SwapPool + two LPTokens for a matched event-outcome pair.
     *         Only token IDs are needed — token contracts are fixed at construction.
     *
     * @param polymarketTokenId_  Token ID on the Polymarket ERC-1155 contract
     * @param opinionTokenId_     Token ID on the WrappedOpinionToken contract
     * @param polyLpName          ERC-20 name for Poly LP   e.g. "PredictSwap BTC-YES PolyLP"
     * @param polyLpSymbol        ERC-20 symbol             e.g. "PS-BTC-YES-POLY"
     * @param opinionLpName       ERC-20 name for Opinion LP e.g. "PredictSwap BTC-YES OpinionLP"
     * @param opinionLpSymbol     ERC-20 symbol             e.g. "PS-BTC-YES-OP"
     *
     * @return poolId  Zero-indexed pool ID
     */
    function createPool(
        uint256 polymarketTokenId_,
        uint256 opinionTokenId_,
        string calldata polyLpName,
        string calldata polyLpSymbol,
        string calldata opinionLpName,
        string calldata opinionLpSymbol
    ) external onlyOwner returns (uint256 poolId) {
        if (polymarketTokenId_ == 0 || opinionTokenId_ == 0) revert InvalidTokenID();

        bytes32 key = _poolKey(polymarketTokenId_, opinionTokenId_);
        if (poolIndex[key] != 0) revert PoolAlreadyExists(key);

        // Deploy both LP tokens with factory as temporary authority
        LPToken polyLp = new LPToken(polyLpName, polyLpSymbol, address(this));
        LPToken opinionLp = new LPToken(opinionLpName, opinionLpSymbol, address(this));

        // Deploy pool
        SwapPool pool_ = new SwapPool(
            address(this),
            polymarketTokenId_,
            opinionTokenId_,
            address(polyLp),
            address(opinionLp),
            address(feeCollector)
        );

        // Wire both LP tokens to the pool (one-time, irreversible)
        polyLp.setPool(address(pool_));
        opinionLp.setPool(address(pool_));

        poolId = pools.length;
        pools.push(PoolInfo({
            swapPool: address(pool_),
            polyLpToken: address(polyLp),
            opinionLpToken: address(opinionLp),
            polymarketTokenId: polymarketTokenId_,
            opinionTokenId: opinionTokenId_
        }));
        poolIndex[key] = poolId + 1;

        emit PoolCreated(
            poolId,
            address(pool_),
            address(polyLp),
            address(opinionLp),
            polymarketTokenId_,
            opinionTokenId_
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

    function findPool(uint256 polymarketTokenId_, uint256 opinionTokenId_)
        external
        view
        returns (bool found, uint256 poolId)
    {
        uint256 idx = poolIndex[_poolKey(polymarketTokenId_, opinionTokenId_)];
        if (idx == 0) return (false, 0);
        return (true, idx - 1);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    /// @notice Update fee collector. Affects new pools only — existing pools keep their
    ///         hardcoded feeCollector address from deploy time.
    function setFeeCollector(address feeCollector_) external onlyOwner {
        if (feeCollector_ == address(0)) revert ZeroAddress();
        emit FeeCollectorUpdated(address(feeCollector), feeCollector_);
        feeCollector = FeeCollector(feeCollector_);
    }

    function setPoolDepositsPaused(uint256 poolId, bool paused_) external onlyOwner {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        SwapPool(payable(pools[poolId].swapPool)).setDepositsPaused(paused_);
        emit PoolDepositsPaused(poolId, paused_);
    }

    function setPoolSwapsPaused(uint256 poolId, bool paused_) external onlyOwner {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        SwapPool(payable(pools[poolId].swapPool)).setSwapsPaused(paused_);
        emit PoolSwapsPaused(poolId, paused_);
    }

    /// @notice Mark a pool as resolved  and pause deposits. Cross-side withdrawals become fee-free.
    ///         Call once the underlying prediction market event has settled.
    function resolvePoolAndPausedDeposits(uint256 poolId) external onlyOwner {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        SwapPool(payable(pools[poolId].swapPool)).setResolvedAndPausedDeposits();
        emit PoolResolved(poolId, true);
    }

    /// @notice In case it was resolved by mistake
    function unresolvePool(uint256 poolId) external onlyOwner {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        SwapPool(payable(pools[poolId].swapPool)).unsetResolved();
        emit PoolResolved(poolId, false);
    }

    // ─── Rescue (routed through factory) ─────────────────────────────────────

    /// @notice Recover surplus pool tokens sent directly to a pool without using deposit().
    function rescuePoolTokens(uint256 poolId, SwapPool.Side side, uint256 amount, address to)
        external
        onlyOwner
    {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        SwapPool(payable(pools[poolId].swapPool)).rescueTokens(side, amount, to);
    }

    /// @notice Recover any other ERC-1155 token accidentally sent to a pool.
    function rescuePoolERC1155(uint256 poolId, address token, uint256 tokenId, uint256 amount, address to)
        external
        onlyOwner
    {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        SwapPool(payable(pools[poolId].swapPool)).rescueERC1155(token, tokenId, amount, to);
    }

    /// @notice Recover any ERC-20 token accidentally sent to a pool.
    function rescuePoolERC20(uint256 poolId, address token, uint256 amount, address to)
        external
        onlyOwner
    {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        SwapPool(payable(pools[poolId].swapPool)).rescueERC20(token, amount, to);
    }

    /// @notice Recover ETH accidentally sent to a pool.
    function rescuePoolETH(uint256 poolId, address payable to) external onlyOwner {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        SwapPool(payable(pools[poolId].swapPool)).rescueETH(to);
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _poolKey(uint256 polyId, uint256 opId) internal pure returns (bytes32) {
        return keccak256(abi.encode(polyId, opId));
    }
}