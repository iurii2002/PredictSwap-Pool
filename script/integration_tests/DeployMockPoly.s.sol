// script/DeployMockPolymarket.s.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Script, console} from "forge-std/Script.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

contract MockPolymarket is ERC1155 {
    constructor() ERC1155("https://mock.uri/{id}") {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }
}

contract DeployMockPolymarket is Script {
    function run() external {
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        MockPolymarket mock = new MockPolymarket();
        console.log("MockPolymarket:", address(mock));
        vm.stopBroadcast();
    }
}
