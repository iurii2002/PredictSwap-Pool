// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Script, console} from "forge-std/Script.sol";

interface IMockOpinion {
    function mint(address to, uint256 id, uint256 amount) external;
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

contract MintMock is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address mock = vm.envAddress("POLYMARKET_TOKEN_ADDRESS");
        address recipient = vm.envAddress("OWNER_ADDRESS");

        // Token ID and amount to mint
        uint256 tokenId = vm.envUint("POLY_TOKEN_ID");
        uint256 amount = 100 * 1e18;

        vm.startBroadcast(deployerKey);
        IMockOpinion(mock).mint(recipient, tokenId, amount);
        vm.stopBroadcast();

        uint256 bal = IMockOpinion(mock).balanceOf(recipient, tokenId);
        console.log("Minted tokenId:", tokenId);
        console.log("Balance of recipient:", bal);
    }
}
