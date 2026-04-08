// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../../src/SwapPool.sol";
import "../../src/PoolFactory.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/**
 * @title Swap
 * @notice Swaps shares from one side to the other in a SwapPool.
 *         Deposits `fromSide` shares, receives `toSide` shares minus fee.
 *
 *         Fee is set per-pool at creation time, adjustable by owner.
 *
 * Required env vars:
 *   DEPLOYER_PRIVATE_KEY   — wallet holding the fromSide ERC-1155 shares
 *   POOL_FACTORY_ADDRESS   — deployed PoolFactory address
 *   POOL_ID                — pool index (0-based)
 *   SWAP_FROM_SIDE         — "0" = MARKET_A → MARKET_B, "1" = MARKET_B → MARKET_A
 *   SWAP_AMOUNT            — number of raw shares to swap in (native decimals of fromSide)
 *
 * Run:
 *   forge script script/integration_tests/Swap.s.sol --rpc-url polygon --broadcast
 */
contract Swap is Script {
    function run() external {
        uint256 key      = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address factAddr = vm.envAddress("POOL_FACTORY_ADDRESS");
        uint256 poolId   = vm.envUint("POOL_ID");
        uint256 sideRaw  = vm.envUint("SWAP_FROM_SIDE");
        uint256 amountIn = vm.envUint("SWAP_AMOUNT");
        address sender   = vm.addr(key);

        PoolFactory factory = PoolFactory(factAddr);
        PoolFactory.PoolInfo memory info = factory.getPool(poolId);
        SwapPool pool = SwapPool(payable(info.swapPool));
        SwapPool.Side fromSide = SwapPool.Side(sideRaw);

        // Resolve contracts and token IDs — live on pool, not factory
        address fromToken = fromSide == SwapPool.Side.MARKET_A ? pool.marketAContract() : pool.marketBContract();
        address toToken   = fromSide == SwapPool.Side.MARKET_A ? pool.marketBContract() : pool.marketAContract();
        uint256 fromId    = fromSide == SwapPool.Side.MARKET_A ? pool.marketATokenId()  : pool.marketBTokenId();
        uint256 toId      = fromSide == SwapPool.Side.MARKET_A ? pool.marketBTokenId()  : pool.marketATokenId();

        string memory fromName = fromSide == SwapPool.Side.MARKET_A ? info.marketA.name : info.marketB.name;
        string memory toName   = fromSide == SwapPool.Side.MARKET_A ? info.marketB.name : info.marketA.name;

        // Expected output — fees read from pool, computed in normalized space.
        // This is an approximation for display only; exact value computed on-chain.
        uint256 totalFeeBps = pool.lpFeeBps() + pool.protocolFeeBps();
        uint256 expectedOut = amountIn - (amountIn * totalFeeBps / pool.FEE_DENOMINATOR());

        uint256 fromBalance = IERC1155(fromToken).balanceOf(sender, fromId);
        uint256 toBalance   = IERC1155(toToken).balanceOf(sender, toId);
        uint256 poolToLiq   = fromSide == SwapPool.Side.MARKET_A ? pool.marketBBalance() : pool.marketABalance();

        console.log("=== Swap ===");
        console.log("Pool ID:           ", poolId);
        console.log("SwapPool:          ", info.swapPool);
        console.log("From side:         ", sideRaw == 0 ? "MARKET_A" : "MARKET_B");
        console.log("From market:       ", fromName);
        console.log("To side:           ", sideRaw == 0 ? "MARKET_B" : "MARKET_A");
        console.log("To market:         ", toName);
        console.log("Amount in:         ", amountIn);
        console.log("Expected out:      ", expectedOut);
        console.log("Total fee bps:     ", totalFeeBps);
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
        console.log("Amount out:      ", amountOut);
        console.log("Fees:            ", amountIn - amountOut, "shares");
        console.log("From bal after:  ", IERC1155(fromToken).balanceOf(sender, fromId));
        console.log("To bal after:    ", IERC1155(toToken).balanceOf(sender, toId));
    }
}