// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/PoolFactory.sol";

/**
 * @title CreatePool
 * @notice Creates a new SwapPool + LPToken pair for a matched event-outcome.
 *
 * Required env vars:
 *   DEPLOYER_PRIVATE_KEY    — must be the factory owner
 *   POOL_FACTORY_ADDRESS    — deployed PoolFactory address
 *   POLY_TOKEN_ID           — Polymarket ERC-1155 token ID for this event
 *   OPINION_TOKEN_ID        — WrappedOpinion ERC-1155 token ID for this event
 *   RESOLUTION_DATE         — Unix timestamp of expected market resolution
 *   LP_NAME                 — ERC-20 name for LP token  e.g. "PredictSwap BTC-YES LP"
 *   LP_SYMBOL               — ERC-20 symbol             e.g. "PS-BTC-YES"
 *
 * Run:
 *   forge script script/CreatePool.s.sol --rpc-url polygon --broadcast
 */
contract CreatePool is Script {

    function run() external {
        uint256 ownerKey    = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address factoryAddr = vm.envAddress("POOL_FACTORY_ADDRESS");
        uint256 polyId      = vm.envUint("POLY_TOKEN_ID");
        uint256 opinionId   = vm.envUint("OPINION_TOKEN_ID");
        uint256 resolution  = vm.envUint("RESOLUTION_DATE");
        string memory name  = vm.envString("LP_NAME");
        string memory sym   = vm.envString("LP_SYMBOL");

        PoolFactory factory = PoolFactory(factoryAddr);

        console.log("=== CreatePool ===");
        console.log("Factory:         ", factoryAddr);
        console.log("Poly token ID:   ", polyId);
        console.log("Opinion token ID:", opinionId);
        console.log("Resolution:      ", resolution);
        console.log("LP name:         ", name);
        console.log("LP symbol:       ", sym);
        console.log("");

        vm.startBroadcast(ownerKey);

        uint256 poolId = factory.createPool(
            polyId,
            opinionId,
            name,
            sym
        );

        vm.stopBroadcast();

        PoolFactory.PoolInfo memory info = factory.getPool(poolId);

        console.log("=== Pool created ===");
        console.log("Pool ID:   ", poolId);
        console.log("SwapPool:  ", info.swapPool);
        console.log("LPToken:   ", info.lpToken);
    }
}
