// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/SwapPool.sol";
import "../../src/PoolFactory.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/**
 * @title Swap
 * @notice Swaps shares from one side to the other in a SwapPool.
 *         Deposits `fromSide` shares, receives `toSide` shares minus fee.
 *
 *         Fee: 0.40% total (0.30% LP auto-compound + 0.10% protocol)
 *
 * Required env vars:
 *   DEPLOYER_PRIVATE_KEY   — wallet holding the fromSide ERC-1155 shares
 *   POOL_FACTORY_ADDRESS   — deployed PoolFactory address
 *   POOL_ID                — pool index (0-based)
 *   SWAP_FROM_SIDE         — "0" = POLYMARKET→OPINION, "1" = OPINION→POLYMARKET
 *   SWAP_AMOUNT            — number of shares to swap in
 *
 * Run:
 *   forge script script/Swap.s.sol --rpc-url polygon --broadcast
 */
contract Swap is Script {
    function run() external {
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address factAddr = vm.envAddress("POOL_FACTORY_ADDRESS");
        uint256 poolId = vm.envUint("POOL_ID");
        uint256 sideRaw = vm.envUint("SWAP_FROM_SIDE");
        uint256 amountIn = vm.envUint("SWAP_AMOUNT");

        address sender = vm.addr(key);
        PoolFactory factory = PoolFactory(factAddr);

        PoolFactory.PoolInfo memory info = factory.getPool(poolId);
        SwapPool pool = SwapPool(info.swapPool);

        SwapPool.Side fromSide = SwapPool.Side(sideRaw);
        SwapPool.Side toSide = fromSide == SwapPool.Side.POLYMARKET ? SwapPool.Side.OPINION : SwapPool.Side.POLYMARKET;

        address fromToken = fromSide == SwapPool.Side.POLYMARKET ? factory.polymarketToken() : factory.opinionToken();
        address toToken = fromSide == SwapPool.Side.POLYMARKET ? factory.opinionToken() : factory.polymarketToken();
        uint256 fromId = fromSide == SwapPool.Side.POLYMARKET ? info.polymarketTokenId : info.opinionTokenId;
        uint256 toId = fromSide == SwapPool.Side.POLYMARKET ? info.opinionTokenId : info.polymarketTokenId;

        // Calculate expected output for display
        uint256 totalFee = factory.lpFeeBps() + factory.protocolFeeBps();
        uint256 expectedOut = amountIn - (amountIn * totalFee / factory.FEE_DENOMINATOR());

        uint256 fromBalance = IERC1155(fromToken).balanceOf(sender, fromId);
        uint256 toBalance = IERC1155(toToken).balanceOf(sender, toId);
        uint256 poolToLiq = fromSide == SwapPool.Side.POLYMARKET ? pool.opinionBalance() : pool.polymarketBalance();

        console.log("=== Swap ===");
        console.log("Pool ID:           ", poolId);
        console.log("SwapPool:          ", info.swapPool);
        console.log("From side:         ", sideRaw == 0 ? "POLYMARKET" : "OPINION");
        console.log("To side:           ", sideRaw == 0 ? "OPINION" : "POLYMARKET");
        console.log("Amount in:         ", amountIn);
        console.log("Expected out:      ", expectedOut);
        console.log("Total fee bps:     ", totalFee);
        console.log("Pool to-liquidity: ", poolToLiq);
        console.log("Wallet from bal:   ", fromBalance);
        console.log("Wallet to bal:     ", toBalance);
        console.log("");

        require(fromBalance >= amountIn, "Insufficient from-token balance");
        require(poolToLiq >= expectedOut, "Insufficient pool liquidity");

        vm.startBroadcast(key);

        if (!IERC1155(fromToken).isApprovedForAll(sender, info.swapPool)) {
            IERC1155(fromToken).setApprovalForAll(info.swapPool, true);
            console.log("Approved SwapPool to transfer tokens");
        }

        uint256 amountOut = pool.swap(fromSide, amountIn);

        vm.stopBroadcast();

        console.log("=== Done ===");
        console.log("Amount out:     ", amountOut);
        console.log("Fees:       ", amountIn - amountOut, "shares");
        console.log("From bal after: ", IERC1155(fromToken).balanceOf(sender, fromId));
        console.log("To bal after:   ", IERC1155(toToken).balanceOf(sender, toId));
    }
}
