// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/FeeCollector.sol";
import "../src/LPToken.sol";
import "../src/PoolFactory.sol";

/**
 * @title Deploy
 * @notice Deploys the full PredictSwap pool system on Polygon.
 *
 * Required env vars:
 *   DEPLOYER_PRIVATE_KEY     — deployer wallet (pays gas)
 *   OWNER_ADDRESS            — protocol owner/multisig (receives ownership)
 *   POLYMARKET_TOKEN_ADDRESS — native Polymarket ERC-1155 contract on Polygon
 *   OPINION_TOKEN_ADDRESS    — WrappedOpinionToken contract on Polygon (from bridge deploy)
 *
 * Run (dry-run):
 *   forge script script/Deploy.s.sol --rpc-url polygon
 *
 * Run (broadcast):
 *   forge script script/Deploy.s.sol --rpc-url polygon --broadcast --verify
 */
contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address owner = vm.envAddress("OWNER_ADDRESS");
        address polyToken = vm.envAddress("POLYMARKET_TOKEN_ADDRESS");
        address opinionToken = vm.envAddress("OPINION_TOKEN_ADDRESS");

        address deployer = vm.addr(deployerKey);

        console.log("=== PredictSwap Pool Deploy ===");
        console.log("Deployer:      ", deployer);
        console.log("Owner:         ", owner);
        console.log("Polymarket:    ", polyToken);
        console.log("OpinionToken:  ", opinionToken);
        console.log("");

        vm.startBroadcast(deployerKey);

        // 1. FeeCollector
        FeeCollector feeCollector = new FeeCollector(owner);
        console.log("FeeCollector:  ", address(feeCollector));

        // 2. PoolFactory (owns FeeCollector authorisation, holds token addresses)
        PoolFactory factory = new PoolFactory(polyToken, opinionToken, address(feeCollector), owner);
        console.log("PoolFactory:   ", address(factory));

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deploy complete ===");
        console.log("Save these addresses to your .env:");
        console.log("  FEE_COLLECTOR_ADDRESS=", address(feeCollector));
        console.log("  POOL_FACTORY_ADDRESS= ", address(factory));
    }
}
