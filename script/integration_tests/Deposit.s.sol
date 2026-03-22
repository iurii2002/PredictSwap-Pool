// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/SwapPool.sol";
import "../../src/PoolFactory.sol";
import "../../src/LPToken.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/**
 * @title Deposit
 * @notice Deposits ERC-1155 shares into a SwapPool and receives LP tokens.
 *         Single-sided: deposit either Polymarket OR WrappedOpinion shares.
 *
 * Required env vars:
 *   DEPLOYER_PRIVATE_KEY   — wallet holding the ERC-1155 shares
 *   POOL_FACTORY_ADDRESS   — deployed PoolFactory address
 *   POOL_ID                — pool index (0-based, from factory registry)
 *   DEPOSIT_SIDE           — "0" for POLYMARKET, "1" for OPINION
 *   DEPOSIT_AMOUNT         — number of shares to deposit (in token units, no decimals)
 *
 * Run:
 *   forge script script/Deposit.s.sol --rpc-url polygon --broadcast
 */
contract Deposit is Script {
    function run() external {
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address factAddr = vm.envAddress("POOL_FACTORY_ADDRESS");
        uint256 poolId = vm.envUint("POOL_ID");
        uint256 sideRaw = vm.envUint("DEPOSIT_SIDE");
        uint256 amount = vm.envUint("DEPOSIT_AMOUNT");

        address sender = vm.addr(key);
        PoolFactory factory = PoolFactory(factAddr);

        PoolFactory.PoolInfo memory info = factory.getPool(poolId);
        SwapPool pool = SwapPool(info.swapPool);
        LPToken lp = LPToken(info.lpToken);

        SwapPool.Side side = SwapPool.Side(sideRaw);
        address tokenAddr = side == SwapPool.Side.POLYMARKET ? factory.polymarketToken() : factory.opinionToken();
        uint256 tokenId = side == SwapPool.Side.POLYMARKET ? info.polymarketTokenId : info.opinionTokenId;

        uint256 tokenBalance = IERC1155(tokenAddr).balanceOf(sender, tokenId);
        uint256 lpBefore = lp.balanceOf(sender);
        uint256 rateBefore = pool.exchangeRate();

        console.log("=== Deposit ===");
        console.log("Pool ID:        ", poolId);
        console.log("SwapPool:       ", info.swapPool);
        console.log("Side:           ", sideRaw == 0 ? "POLYMARKET" : "OPINION");
        console.log("Token:          ", tokenAddr);
        console.log("Token ID:       ", tokenId);
        console.log("Wallet balance: ", tokenBalance);
        console.log("Deposit amount: ", amount);
        console.log("LP before:      ", lpBefore);
        console.log("Exchange rate:  ", rateBefore);
        console.log("");

        require(tokenBalance >= amount, "Insufficient token balance");

        vm.startBroadcast(key);

        // Approve pool to pull tokens if not already approved
        if (!IERC1155(tokenAddr).isApprovedForAll(sender, info.swapPool)) {
            IERC1155(tokenAddr).setApprovalForAll(info.swapPool, true);
            console.log("Approved SwapPool to transfer tokens");
        }

        uint256 lpMinted = pool.deposit(side, amount);

        vm.stopBroadcast();

        console.log("=== Done ===");
        console.log("LP minted:    ", lpMinted);
        console.log("LP after:     ", lp.balanceOf(sender));
        console.log("Pool total shares:", pool.totalShares());
    }
}
