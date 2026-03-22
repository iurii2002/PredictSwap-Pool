// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/FeeCollector.sol";

/**
 * @title WithdrawFees
 * @notice Withdraws accumulated protocol fees from FeeCollector.
 *         Supports single token ID or batch withdrawal.
 *
 * Required env vars:
 *   DEPLOYER_PRIVATE_KEY      — must be the FeeCollector owner
 *   FEE_COLLECTOR_ADDRESS     — deployed FeeCollector address
 *   FEE_TOKEN_ADDRESS         — ERC-1155 token contract to withdraw from
 *   FEE_RECIPIENT_ADDRESS     — address to send fees to (e.g. team treasury)
 *
 * For single withdrawal, also set:
 *   FEE_TOKEN_ID              — token ID to withdraw
 *
 * Run (withdrawAll single):
 *   forge script script/WithdrawFees.s.sol --rpc-url polygon --broadcast
 */
contract WithdrawFees is Script {
    function run() external {
        uint256 ownerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address collectorAddr = vm.envAddress("FEE_COLLECTOR_ADDRESS");
        address tokenAddr = vm.envAddress("FEE_TOKEN_ADDRESS");
        address recipient = vm.envAddress("FEE_RECIPIENT_ADDRESS");
        uint256 tokenId = vm.envUint("FEE_TOKEN_ID");

        FeeCollector collector = FeeCollector(collectorAddr);

        uint256 balance = IERC1155(tokenAddr).balanceOf(collectorAddr, tokenId);

        console.log("=== WithdrawFees ===");
        console.log("FeeCollector: ", collectorAddr);
        console.log("Token:        ", tokenAddr);
        console.log("Token ID:     ", tokenId);
        console.log("Balance:      ", balance);
        console.log("Recipient:    ", recipient);

        if (balance == 0) {
            console.log("Nothing to withdraw.");
            return;
        }

        vm.startBroadcast(ownerKey);
        collector.withdrawAll(tokenAddr, tokenId, recipient);
        vm.stopBroadcast();

        console.log("Withdrawn:    ", balance);
    }
}
