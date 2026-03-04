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
 *         Each pool corresponds to one matched event-outcome pair:
 *         - One Polymarket ERC-1155 token ID on Polygon
 *         - One WrappedOpinion ERC-1155 token ID on Polygon
 *
 *         Pool creation is permissioned (owner only) to ensure correct
 *         event matching. Permissionless creation planned for Phase 4.
 */
contract PoolFactory is Ownable {
    // ─── Types ────────────────────────────────────────────────────────────────

    struct PoolInfo {
        address swapPool;
        address lpToken;
        address polymarketToken;
        uint256 polymarketTokenId;
        address opinionToken;
        uint256 opinionTokenId;
        uint256 resolutionDate;
        bool    isActive;
    }

    // ─── State ────────────────────────────────────────────────────────────────

    FeeCollector public immutable feeCollector;

    /// @notice All deployed pools
    PoolInfo[] public pools;

    /// @notice Lookup by (polymarketToken, polymarketTokenId, opinionToken, opinionTokenId) → poolId
    mapping(bytes32 => uint256) public poolIndex; // 1-indexed; 0 = not found

    // ─── Events ───────────────────────────────────────────────────────────────

    event PoolCreated(
        uint256 indexed poolId,
        address swapPool,
        address lpToken,
        address polymarketToken,
        uint256 polymarketTokenId,
        address opinionToken,
        uint256 opinionTokenId,
        uint256 resolutionDate
    );
    event PoolDeactivated(uint256 indexed poolId);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error PoolAlreadyExists(bytes32 key);
    error PoolNotFound(uint256 poolId);
    error InvalidAddress();

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(address feeCollector_, address owner_) Ownable(owner_) {
        if (feeCollector_ == address(0)) revert InvalidAddress();
        feeCollector = FeeCollector(feeCollector_);
    }

    // ─── Pool creation ────────────────────────────────────────────────────────

    /**
     * @notice Deploy a new SwapPool + LPToken for a matched event-outcome pair.
     *         Both tokens must already exist on Polygon:
     *           - polymarketToken: native Polymarket ERC-1155
     *           - opinionToken:    WrappedOpinionToken (bridged from BSC)
     *
     * @param polymarketToken_    Polymarket ERC-1155 contract
     * @param polymarketTokenId_  Token ID on Polymarket contract
     * @param opinionToken_       WrappedOpinionToken contract
     * @param opinionTokenId_     Token ID on WrappedOpinionToken (mirrors BSC ID)
     * @param resolutionDate_     Expected market resolution timestamp (informational)
     * @param lpName              ERC-20 name for LP token  e.g. "PredictSwap BTC-YES LP"
     * @param lpSymbol            ERC-20 symbol             e.g. "PS-BTC-YES"
     *
     * @return poolId  Zero-indexed pool ID
     */
    function createPool(
        address polymarketToken_,
        uint256 polymarketTokenId_,
        address opinionToken_,
        uint256 opinionTokenId_,
        uint256 resolutionDate_,
        string calldata lpName,
        string calldata lpSymbol
    ) external onlyOwner returns (uint256 poolId) {
        if (polymarketToken_ == address(0) || opinionToken_ == address(0))
            revert InvalidAddress();

        bytes32 key = _poolKey(
            polymarketToken_, polymarketTokenId_,
            opinionToken_,    opinionTokenId_
        );
        if (poolIndex[key] != 0) revert PoolAlreadyExists(key);

        // 1. Deploy LPToken with a temporary pool address (updated next step)
        //    We use a two-step deploy because SwapPool needs the LP address,
        //    and LPToken needs the SwapPool address. We pass the factory as
        //    a temporary owner and reassign after SwapPool is deployed.
        //
        //    Alternative: deploy LPToken with address(this) as pool, then swap.
        //    Here we compute the SwapPool address off-chain... but that's complex.
        //    Simpler: deploy LP with this factory as pool, deploy SwapPool,
        //    then deploy a thin LP wrapper. Instead we deploy LP with SwapPool
        //    predictively using CREATE2.

        // ── Two-step deploy (avoids CREATE2 chicken-and-egg) ─────────────
        // Step 1: Deploy LPToken with factory as temporary authority
        LPToken lp = new LPToken(lpName, lpSymbol, address(this));
        address lpAddr = address(lp);

        // Step 2: Deploy SwapPool — LP address is now known
        SwapPool pool_ = new SwapPool(
            polymarketToken_, polymarketTokenId_,
            opinionToken_,    opinionTokenId_,
            lpAddr,
            address(feeCollector)
        );
        address poolAddr = address(pool_);

        // Step 3: Wire LP token to its SwapPool (one-time, irreversible)
        lp.setPool(poolAddr);

        // Authorise the new pool to report fees to FeeCollector
        feeCollector.authorisePool(poolAddr);

        // Register
        poolId = pools.length;
        pools.push(PoolInfo({
            swapPool:         poolAddr,
            lpToken:          lpAddr,
            polymarketToken:  polymarketToken_,
            polymarketTokenId: polymarketTokenId_,
            opinionToken:     opinionToken_,
            opinionTokenId:   opinionTokenId_,
            resolutionDate:   resolutionDate_,
            isActive:         true
        }));
        poolIndex[key] = poolId + 1; // 1-indexed so 0 means "not found"

        emit PoolCreated(
            poolId,
            poolAddr,
            lpAddr,
            polymarketToken_,
            polymarketTokenId_,
            opinionToken_,
            opinionTokenId_,
            resolutionDate_
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

    function getActivePools() external view returns (PoolInfo[] memory) {
        uint256 count;
        for (uint256 i; i < pools.length; i++) {
            if (pools[i].isActive) count++;
        }
        PoolInfo[] memory active = new PoolInfo[](count);
        uint256 j;
        for (uint256 i; i < pools.length; i++) {
            if (pools[i].isActive) active[j++] = pools[i];
        }
        return active;
    }

    function poolCount() external view returns (uint256) {
        return pools.length;
    }

    function findPool(
        address polymarketToken_,
        uint256 polymarketTokenId_,
        address opinionToken_,
        uint256 opinionTokenId_
    ) external view returns (bool found, uint256 poolId) {
        bytes32 key = _poolKey(
            polymarketToken_, polymarketTokenId_,
            opinionToken_,    opinionTokenId_
        );
        uint256 idx = poolIndex[key];
        if (idx == 0) return (false, 0);
        return (true, idx - 1);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function deactivatePool(uint256 poolId) external onlyOwner {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        pools[poolId].isActive = false;
        emit PoolDeactivated(poolId);
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _poolKey(
        address polyToken, uint256 polyId,
        address opToken,   uint256 opId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(polyToken, polyId, opToken, opId));
    }

    /**
     * @notice Predict the CREATE2 address for a SwapPool given a salt.
     *         This is used to pre-wire the LP token to the correct pool address
     *         before the pool is deployed.
     */
    function _predictSwapPoolAddress(bytes32 salt) internal view returns (address) {
        // We don't know the exact bytecode yet at this point (it depends on LP address).
        // This is the classic chicken-and-egg CREATE2 problem.
        //
        // Resolution: use a two-step deploy where LP is deployed with factory as
        // temporary minter, then transferMintRole is called after SwapPool is deployed.
        //
        // See _createPoolTwoStep() below if you need this resolved cleanly.
        // For now return address(0) as placeholder — see NOTE in createPool().
        return address(0); // ← see two-step version below
    }
}

/*
 * NOTE ON CREATE2 CHICKEN-AND-EGG:
 *
 * The cleanest solution is a two-step LP deploy where the LP token accepts
 * a setPool(address) call that can only be called ONCE and only by the factory.
 * This avoids needing to predict addresses.
 *
 * Updated LPToken would look like:
 *
 *   address public pool;
 *   bool private poolSet;
 *
 *   function setPool(address pool_) external {
 *       require(!poolSet && msg.sender == factory);
 *       pool = pool_;
 *       poolSet = true;
 *   }
 *
 * Full production deployment flow:
 *   1. Deploy LPToken(name, symbol, factory_as_temp_pool)
 *   2. Deploy SwapPool(poly, polyId, op, opId, lpAddr, feeCollector)
 *   3. Call lpToken.setPool(swapPoolAddr)   ← one-time assignment
 *
 * This is simpler than CREATE2 address prediction and is recommended.
 */
