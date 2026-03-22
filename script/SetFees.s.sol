// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/PoolFactory.sol";

/**
 * @title SetFees
 * @notice Updates the global swap fee config on PoolFactory.
 *         Changes take effect immediately for all pools.
 *
 * Required env vars:
 *   DEPLOYER_PRIVATE_KEY  — must be the factory owner
 *   POOL_FACTORY_ADDRESS  — deployed PoolFactory address
 *   LP_FEE_BPS            — new LP fee in basis points      (max 100 = 1.00%)
 *   PROTOCOL_FEE_BPS      — new protocol fee in basis points (max  50 = 0.50%)
 *
 * Run:
 *   forge script script/SetFees.s.sol --rpc-url polygon --broadcast
 */
contract SetFees is Script {
    function run() external {
        uint256 ownerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address factoryAddr = vm.envAddress("POOL_FACTORY_ADDRESS");
        uint256 lpFee = vm.envUint("LP_FEE_BPS");
        uint256 protocolFee = vm.envUint("PROTOCOL_FEE_BPS");

        PoolFactory factory = PoolFactory(factoryAddr);

        console.log("=== SetFees ===");
        console.log("Factory:          ", factoryAddr);
        console.log("Current LP fee:   ", factory.lpFeeBps(), "bps");
        console.log("Current prot fee: ", factory.protocolFeeBps(), "bps");
        console.log("New LP fee:       ", lpFee, "bps");
        console.log("New prot fee:     ", protocolFee, "bps");

        vm.startBroadcast(ownerKey);
        factory.setFees(lpFee, protocolFee);
        vm.stopBroadcast();

        console.log("Done. Total fee:", lpFee + protocolFee, "bps");
    }
}
