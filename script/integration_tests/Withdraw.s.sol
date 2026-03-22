// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/SwapPool.sol";
import "../../src/PoolFactory.sol";
import "../../src/LPToken.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/**
 * @title Withdraw
 * @notice Burns LP tokens and withdraws underlying shares from a SwapPool.
 *
 *         Specify a preferred side to receive. If that side doesn't have
 *         enough liquidity, the pool falls back to the other side or splits.
 *
 *         Set WITHDRAW_LP_AMOUNT=0 to withdraw your entire LP balance.
 *
 * Required env vars:
 *   DEPLOYER_PRIVATE_KEY    — wallet holding LP tokens
 *   POOL_FACTORY_ADDRESS    — deployed PoolFactory address
 *   POOL_ID                 — pool index (0-based)
 *   WITHDRAW_LP_AMOUNT      — LP tokens to burn (0 = withdraw all)
 *   WITHDRAW_PREFERRED_SIDE — "0" for POLYMARKET, "1" for OPINION
 *
 * Run:
 *   forge script script/Withdraw.s.sol --rpc-url polygon --broadcast
 */
contract Withdraw is Script {
    function run() external {
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address factAddr = vm.envAddress("POOL_FACTORY_ADDRESS");
        uint256 poolId = vm.envUint("POOL_ID");
        uint256 lpAmount = vm.envUint("WITHDRAW_LP_AMOUNT");
        uint256 sideRaw = vm.envUint("WITHDRAW_PREFERRED_SIDE");

        address sender = vm.addr(key);
        PoolFactory factory = PoolFactory(factAddr);

        PoolFactory.PoolInfo memory info = factory.getPool(poolId);
        SwapPool pool = SwapPool(info.swapPool);
        LPToken lp = LPToken(info.lpToken);

        uint256 lpBalance = lp.balanceOf(sender);

        // 0 means "withdraw everything"
        if (lpAmount == 0) {
            lpAmount = lpBalance;
        }

        SwapPool.Side preferredSide = SwapPool.Side(sideRaw);

        // Calculate expected shares out for display
        uint256 totalShares = pool.totalShares();
        uint256 lpSupply = lp.totalSupply();
        uint256 expectedOut = lpSupply > 0 ? (lpAmount * totalShares) / lpSupply : 0;

        uint256 polyBal = IERC1155(factory.polymarketToken()).balanceOf(sender, info.polymarketTokenId);
        uint256 opinionBal = IERC1155(factory.opinionToken()).balanceOf(sender, info.opinionTokenId);

        console.log("=== Withdraw ===");
        console.log("Pool ID:          ", poolId);
        console.log("SwapPool:         ", info.swapPool);
        console.log("LP balance:       ", lpBalance);
        console.log("LP to burn:       ", lpAmount);
        console.log("Expected shares:  ", expectedOut);
        console.log("Preferred side:   ", sideRaw == 0 ? "POLYMARKET" : "OPINION");
        console.log("Pool POLY bal:    ", pool.polymarketBalance());
        console.log("Pool OPINION bal: ", pool.opinionBalance());
        console.log("Exchange rate:    ", pool.exchangeRate());
        console.log("Wallet POLY:      ", polyBal);
        console.log("Wallet OPINION:   ", opinionBal);
        console.log("");

        require(lpBalance >= lpAmount, "Insufficient LP balance");
        require(lpAmount > 0, "Nothing to withdraw");

        vm.startBroadcast(key);

        uint256 sharesOut = pool.withdraw(lpAmount, preferredSide);

        vm.stopBroadcast();

        console.log("=== Done ===");
        console.log("Shares received:  ", sharesOut);
        console.log("LP remaining:     ", lp.balanceOf(sender));
        console.log(
            "Wallet POLY after:   ", IERC1155(factory.polymarketToken()).balanceOf(sender, info.polymarketTokenId)
        );
        console.log("Wallet OPINION after:", IERC1155(factory.opinionToken()).balanceOf(sender, info.opinionTokenId));
    }
}
