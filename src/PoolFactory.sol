// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./SwapPool.sol";
import "./LPToken.sol";
import "./FeeCollector.sol";

/**
 * @title PoolFactory
 * @notice Team-only factory that deploys SwapPool + LPToken pairs and serves
 *         as the on-chain registry of all active pools.
 *
 *         Both the Polymarket ERC-1155 contract and WrappedOpinionToken contract
 *         are fixed at construction — only token IDs vary per pool.
 *
 *         Swap fees are global and configurable by owner, capped by hard limits.
 *         All pools read fees from here at swap time.
 */
contract PoolFactory is Ownable {
    // ─── Types ────────────────────────────────────────────────────────────────

    struct PoolInfo {
        address swapPool;
        address lpToken;
        uint256 polymarketTokenId;
        uint256 opinionTokenId;
    }

    // ─── Immutable config ─────────────────────────────────────────────────────

    /// @notice if Polymarket or Opinion migrates their contract, redeploy this factory.
    /// @notice The single Polymarket ERC-1155 contract on Polygon
    address public immutable polymarketToken;
    /// @notice The single WrappedOpinionToken ERC-1155 contract on Polygon
    address public immutable opinionToken;
    /// @notice Protocol fee recipient
    FeeCollector public feeCollector;

    // ─── Configurable fees ────────────────────────────────────────────────────

    uint256 public lpFeeBps = 30; // 0.30% default
    uint256 public protocolFeeBps = 10; // 0.10% default

    uint256 public constant FEE_DENOMINATOR = 10_000;
    uint256 public constant MAX_LP_FEE = 100; // 1.00% hard cap
    uint256 public constant MAX_PROTOCOL_FEE = 50; // 0.50% hard cap

    // ─── State ────────────────────────────────────────────────────────────────

    PoolInfo[] public pools;

    /// @notice (polymarketTokenId, opinionTokenId) → poolId, 1-indexed; 0 = not found
    mapping(bytes32 => uint256) public poolIndex;

    // ─── Events ───────────────────────────────────────────────────────────────

    event PoolCreated(
        uint256 indexed poolId, address swapPool, address lpToken, uint256 polymarketTokenId, uint256 opinionTokenId
    );
    event FeesUpdated(uint256 lpFeeBps, uint256 protocolFeeBps);
    event PoolDepositsPaused(uint256 indexed poolId, bool paused);
    event PoolSwapsPaused(uint256 indexed poolId, bool paused);

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
        if (polymarketToken_ == address(0) || opinionToken_ == address(0) || feeCollector_ == address(0)) revert ZeroAddress();

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
     * @notice Deploy a new SwapPool + LPToken for a matched event-outcome pair.
     *         Only token IDs are needed — token contracts are fixed at construction.
     *
     * @param polymarketTokenId_  Token ID on the Polymarket ERC-1155 contract
     * @param opinionTokenId_     Token ID on the WrappedOpinionToken contract
     * @param lpName              ERC-20 name   e.g. "PredictSwap BTC-YES LP"
     * @param lpSymbol            ERC-20 symbol e.g. "PS-BTC-YES"
     *
     * @return poolId  Zero-indexed pool ID
     */
    function createPool(
        uint256 polymarketTokenId_,
        uint256 opinionTokenId_,
        string calldata lpName,
        string calldata lpSymbol
    ) external onlyOwner returns (uint256 poolId) {
        if (polymarketTokenId_ == 0 || opinionTokenId_ == 0) revert InvalidTokenID();

        bytes32 key = _poolKey(polymarketTokenId_, opinionTokenId_);
        if (poolIndex[key] != 0) revert PoolAlreadyExists(key);

        LPToken lp = new LPToken(lpName, lpSymbol, address(this));

        SwapPool pool_ =
            new SwapPool(address(this), polymarketTokenId_, opinionTokenId_, address(lp), address(feeCollector));

        lp.setPool(address(pool_));

        poolId = pools.length;
        pools.push(
            PoolInfo({
                swapPool: address(pool_),
                lpToken: address(lp),
                polymarketTokenId: polymarketTokenId_,
                opinionTokenId: opinionTokenId_
            })
        );
        poolIndex[key] = poolId + 1;

        emit PoolCreated(poolId, address(pool_), address(lp), polymarketTokenId_, opinionTokenId_);
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

    // Update fee collecter for new pools, but not for the old one
    function setFeeCollector(address feeCollector_) external onlyOwner {
        if (feeCollector_ == address(0)) revert ZeroAddress();
        emit FeeCollectorUpdated(address(feeCollector), feeCollector_);
        feeCollector = FeeCollector(feeCollector_);
    }

    function setPoolDepositsPaused(uint256 poolId, bool paused_) external onlyOwner {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        SwapPool(pools[poolId].swapPool).setDepositsPaused(paused_);
        emit PoolDepositsPaused(poolId, paused_);
    }

    function setPoolSwapsPaused(uint256 poolId, bool paused_) external onlyOwner {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        SwapPool(pools[poolId].swapPool).setSwapsPaused(paused_);
        emit PoolSwapsPaused(poolId, paused_);
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _poolKey(uint256 polyId, uint256 opId) internal pure returns (bytes32) {
        return keccak256(abi.encode(polyId, opId));
    }
}
