// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../../src/SwapPool.sol";
import "../../src/PoolFactory.sol";
import "../../src/LPToken.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/**
 * @title WithdrawAll
 * @notice Convenience script: burns the caller's full balance of BOTH LP tokens
 *         (marketALpToken and marketBLpToken) in two same-side withdrawals.
 *
 *         Both withdrawals are same-side and therefore always free and never
 *         blocked by swapsPaused.
 *
 *         Useful for a clean full exit without paying cross-side fees:
 *           marketALp → MARKET_A shares  (same-side, free)
 *           marketBLp → MARKET_B shares  (same-side, free)
 *
 *         If one LP balance is zero the corresponding withdrawal is skipped.
 *
 * Required env vars:
 *   DEPLOYER_PRIVATE_KEY   — wallet holding LP tokens
 *   POOL_FACTORY_ADDRESS   — deployed PoolFactory address
 *   POOL_ID                — pool index (0-based)
 *
 * Run:
 *   forge script script/integration_tests/WithdrawAll.s.sol --rpc-url polygon --broadcast
 */
contract WithdrawAll is Script {
    function run() external {
        uint256 key      = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address factAddr = vm.envAddress("POOL_FACTORY_ADDRESS");
        uint256 poolId   = vm.envUint("POOL_ID");

        address sender = vm.addr(key);
        PoolFactory factory = PoolFactory(factAddr);
        PoolFactory.PoolInfo memory info = factory.getPool(poolId);
        SwapPool pool = SwapPool(payable(info.swapPool));

        LPToken marketALp = LPToken(info.marketALpToken);
        LPToken marketBLp = LPToken(info.marketBLpToken);

        uint256 marketALpBal = marketALp.balanceOf(sender);
        uint256 marketBLpBal = marketBLp.balanceOf(sender);

        // Gross estimates for pre-flight display — uses normalized shares
        uint256 supply       = pool.totalLpSupply();
        uint256 marketAGross = (supply > 0 && marketALpBal > 0)
            ? (marketALpBal * pool.totalSharesNorm()) / supply : 0;
        uint256 marketBGross = (supply > 0 && marketBLpBal > 0)
            ? (marketBLpBal * pool.totalSharesNorm()) / supply : 0;

        // Resolve market contracts and token IDs from pool
        address marketAContract = pool.marketAContract();
        address marketBContract = pool.marketBContract();
        uint256 marketATokenId  = pool.marketATokenId();
        uint256 marketBTokenId  = pool.marketBTokenId();

        console.log("=== WithdrawAll (same-side, free) ===");
        console.log("Pool ID:                  ", poolId);
        console.log("SwapPool:                 ", info.swapPool);
        console.log("Market A:                 ", info.marketA.name);
        console.log("Market B:                 ", info.marketB.name);
        console.log("Pool resolved:            ", pool.resolved() ? "YES" : "NO");
        console.log("Pool depositsPaused:      ", pool.depositsPaused() ? "YES" : "NO");
        console.log("Pool swapsPaused:         ", pool.swapsPaused() ? "YES (no effect on same-side)" : "NO");
        console.log("marketALp balance:        ", marketALpBal);
        console.log("marketBLp balance:        ", marketBLpBal);
        console.log("MARKET_A gross out (norm):", marketAGross);
        console.log("MARKET_B gross out (norm):", marketBGross);
        console.log("Pool MARKET_A bal:        ", pool.marketABalance());
        console.log("Pool MARKET_B bal:        ", pool.marketBBalance());
        console.log("Exchange rate:            ", pool.exchangeRate());
        console.log("Total LP supply:          ", supply);
        console.log("Wallet MARKET_A:          ", IERC1155(marketAContract).balanceOf(sender, marketATokenId));
        console.log("Wallet MARKET_B:          ", IERC1155(marketBContract).balanceOf(sender, marketBTokenId));
        console.log("");

        require(marketALpBal > 0 || marketBLpBal > 0, "No LP tokens to withdraw");

        vm.startBroadcast(key);

        uint256 marketAReceived;
        uint256 marketBReceived;

        if (marketALpBal > 0) {
            marketAReceived = pool.withdrawSingleSide(
                marketALpBal,
                SwapPool.Side.MARKET_A,
                SwapPool.Side.MARKET_A
            );
        }

        if (marketBLpBal > 0) {
            marketBReceived = pool.withdrawSingleSide(
                marketBLpBal,
                SwapPool.Side.MARKET_B,
                SwapPool.Side.MARKET_B
            );
        }

        vm.stopBroadcast();

        console.log("=== Done ===");
        console.log("MARKET_A received:        ", marketAReceived);
        console.log("MARKET_B received:        ", marketBReceived);
        console.log("marketALp remaining:      ", marketALp.balanceOf(sender));
        console.log("marketBLp remaining:      ", marketBLp.balanceOf(sender));
        console.log("Wallet MARKET_A after:    ", IERC1155(marketAContract).balanceOf(sender, marketATokenId));
        console.log("Wallet MARKET_B after:    ", IERC1155(marketBContract).balanceOf(sender, marketBTokenId));
    }
}