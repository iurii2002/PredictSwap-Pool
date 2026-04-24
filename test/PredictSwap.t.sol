// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/FeeCollector.sol";
import "../src/LPToken.sol";
import "../src/PoolFactory.sol";
import "../src/SwapPool.sol";
import "./MockERC1155.sol";

/**
 * @title PredictSwap v3 Test Suite
 *
 * Categories:
 *   Lock_*              — two-bucket fresh/matured lock on LPToken (per-tokenId)
 *   Deposit_*           — mint-at-rate, DepositsPaused revert, dust
 *   Swap_*              — 1:1 minus fees, fee credited to drained side, liquidity check
 *   Withdrawal_*        — unified withdrawal(): same-side (JIT fee on fresh only) and
 *                         cross-side (full fee unless resolved); fee credited to receiveSide
 *   WithdrawProRata_*   — only when swapsPaused; proportional native+cross split, never fees
 *   ValueInvariant_*    — aSideValue + bSideValue == physical(A) + physical(B) normalized
 *   RateAttribution_*   — swap grows drained side's rate only; same-side JIT fee grows own rate
 *   Factory_*           — createPool, uniqueness checks, resolve toggles, names
 *   FlushResidual_*     — residual dust flushed to collector when both supplies hit zero
 *   Rescue_*            — rescue surplus only when physical > tracked
 */
contract PredictSwapV3Test is Test {

    // ─── Actors ───────────────────────────────────────────────────────────────

    address owner    = makeAddr("owner");
    address operator = makeAddr("operator");
    address lp1      = makeAddr("lp1");
    address lp2      = makeAddr("lp2");
    address lp3      = makeAddr("lp3");
    address swapper  = makeAddr("swapper");
    address recv     = makeAddr("recv");
    address attacker = makeAddr("attacker");

    // ─── Token IDs ────────────────────────────────────────────────────────────

    uint256 constant MARKET_A_ID   = 1;
    uint256 constant MARKET_B_ID   = 511515;
    uint256 constant MARKET_A_ID_2 = 2;
    uint256 constant MARKET_B_ID_2 = 22;

    uint8 constant MARKET_A_DEC = 6;
    uint8 constant MARKET_B_DEC = 18;

    // All deposits and actually recieved from withdraw are in raw decimals.
    // All calculations inside contracts are normalized to 1e18
    uint256 constant MARKET_A_DEC_RAW = 1e6;
    uint256 constant MARKET_B_DEC_RAW = 1e18;

    uint256 constant LP_FEE_BPS       = 30; // 0.30%
    uint256 constant PROTOCOL_FEE_BPS = 10; // 0.10%
    uint256 constant TOTAL_FEE_BPS    = 40;
    uint256 constant FEE_DEN          = 10_000;

    // ─── Contracts ────────────────────────────────────────────────────────────

    MockERC1155  marketAToken;
    MockERC1155  marketBToken;
    FeeCollector feeCollector;
    PoolFactory  factory;
    SwapPool     pool;
    LPToken      marketALpToken;
    LPToken      marketBLpToken;

    uint256 lpIdA;
    uint256 lpIdB;

    // ─── Setup ────────────────────────────────────────────────────────────────

    function setUp() public {
        marketAToken = new MockERC1155();
        marketBToken = new MockERC1155();

        vm.startPrank(owner);
        feeCollector = new FeeCollector(owner);
        factory = new PoolFactory(
            address(marketAToken),
            address(marketBToken),
            address(feeCollector),
            operator,
            owner,
            "Polymarket",
            "Opinion",
            "Polymarket LP. Polymarket:Opinion pools",
            "Opinion LP. Polymarket:Opinion pools"
        );
        vm.stopPrank();

        marketALpToken = factory.marketALpToken();
        marketBLpToken = factory.marketBLpToken();

        vm.prank(operator);
        uint256 poolId = factory.createPool(
            _cfg(MARKET_A_ID, MARKET_A_DEC),
            _cfg(MARKET_B_ID, MARKET_B_DEC),
            LP_FEE_BPS,
            PROTOCOL_FEE_BPS,
            "Trump impeachment 2028 - YES"
        );

        PoolFactory.PoolInfo memory info = factory.getPool(poolId);
        pool  = SwapPool(payable(info.swapPool));
        lpIdA = info.marketALpTokenId;
        lpIdB = info.marketBLpTokenId;

        _mintAndApprove(lp1,     10_000 * MARKET_A_DEC_RAW, 10_000 * MARKET_B_DEC_RAW);
        _mintAndApprove(lp2,     10_000 * MARKET_A_DEC_RAW, 10_000 * MARKET_B_DEC_RAW);
        _mintAndApprove(lp3,     10_000 * MARKET_A_DEC_RAW, 10_000 * MARKET_B_DEC_RAW);
        _mintAndApprove(swapper, 10_000 * MARKET_A_DEC_RAW, 10_000 * MARKET_B_DEC_RAW);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _cfg(uint256 id, uint8 dec) internal pure returns (PoolFactory.MarketConfig memory) {
        return PoolFactory.MarketConfig({tokenId: id, decimals: dec});
    }

    function _mintAndApprove(address user, uint256 amtA, uint256 amtB) internal {
        marketAToken.mint(user, MARKET_A_ID, amtA);
        marketBToken.mint(user, MARKET_B_ID, amtB);
        marketAToken.mint(user, MARKET_A_ID_2, amtA);
        marketBToken.mint(user, MARKET_B_ID_2, amtB);
        vm.startPrank(user);
        marketAToken.setApprovalForAll(address(pool), true);
        marketBToken.setApprovalForAll(address(pool), true);
        vm.stopPrank();
    }

    function _deposit(address who, SwapPool.Side side, uint256 amount) internal returns (uint256) {
        vm.prank(who);
        return pool.deposit(side, amount);
    }

    function _seedBalanced(uint256 aDep, uint256 bDep) internal {
        _deposit(lp1, SwapPool.Side.MARKET_A, aDep);
        _deposit(lp2, SwapPool.Side.MARKET_B, bDep);
    }

    function _freshAmount(address user, uint256 id) internal view returns (uint256) {
        (uint256 amt,) = marketALpToken.freshDeposit(user, id);
        return amt;
    }

    function _freshTimestamp(address user, uint256 id) internal view returns (uint256) {
        (, uint256 ts) = marketALpToken.freshDeposit(user, id);
        return ts;
    }

    function _pauseSwaps() internal {
        vm.prank(operator);
        factory.setPoolSwapsPaused(0, true);
    }

    function _resolve() internal {
        vm.prank(operator);
        factory.setResolvePool(0, true);
    }

    function _toNorm(uint256 raw, uint8 dec) internal pure returns (uint256) {
        return raw * 10 ** (18 - dec);
    }

    function _fromNorm(uint256 norm, uint8 dec) internal pure returns (uint256) {
        return norm / 10 ** (18 - dec);
    }

    function _assertValueInvariant() internal view {
        uint256 physA = pool.physicalBalanceNorm(SwapPool.Side.MARKET_A);
        uint256 physB = pool.physicalBalanceNorm(SwapPool.Side.MARKET_B);
        uint256 minDec = MARKET_A_DEC < MARKET_B_DEC ? MARKET_A_DEC : MARKET_B_DEC;
        uint256 tolerance = 10 ** (18 - minDec);
        assertApproxEqAbs(
            pool.aSideValue() + pool.bSideValue(),
            physA + physB,
            tolerance,
            "aSideValue + bSideValue ~= physical(A) + physical(B)"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                             LOCK (Fresh deposit status for 24 hour)
    // ─────────────────────────────────────────────────────────────────────────

    function testLock_FirstDepositCreatesFreshBucket() public {
        uint256 t0 = block.timestamp;
        _deposit(lp1, SwapPool.Side.MARKET_A, 100 * MARKET_A_DEC_RAW);
        assertEq(_freshAmount(lp1, lpIdA), 100 ether, "fresh amount");
        assertEq(_freshTimestamp(lp1, lpIdA), t0, "fresh timestamp");
        assertTrue(marketALpToken.isLocked(lp1, lpIdA), "locked after deposit");
        assertEq(marketALpToken.lockedAmount(lp1, lpIdA), 100 ether, "fully locked");
    }

    function testLock_ConsecutiveDepositsWeightedAverage() public {
        vm.warp(1_000_000);
        _deposit(lp1, SwapPool.Side.MARKET_A, 100 * MARKET_A_DEC_RAW);
        assertEq(_freshTimestamp(lp1, lpIdA), 1_000_000, "first timestamp");

        vm.warp(1_000_000 + 12 hours);
        _deposit(lp1, SwapPool.Side.MARKET_A, 100 * MARKET_A_DEC_RAW);

        // (100*1_000_000 + 100*(1_000_000 + 43_200)) / 200 = 1_000_000 + 21_600
        assertEq(_freshTimestamp(lp1, lpIdA), 1_021_600, "weighted avg timestamp");
        assertEq(_freshAmount(lp1, lpIdA), 200 ether, "amounts merged");
    }

    function testLock_TransferToEmptyWallet_FreshAtRecipient() public {
        _deposit(lp1, SwapPool.Side.MARKET_A, 100 * MARKET_A_DEC_RAW);
        skip(5 hours);
        uint256 recvStamp = block.timestamp;

        vm.prank(lp1);
        marketALpToken.safeTransferFrom(lp1, recv, lpIdA, 100 ether, "");

        assertEq(_freshAmount(recv, lpIdA), 100 ether, "recv fresh amount");
        assertEq(_freshTimestamp(recv, lpIdA), recvStamp, "recv timestamp = now");
    }

    function testLock_TransferToMaturedHolder_OnlyIncomingIsFresh() public {
        _deposit(lp2, SwapPool.Side.MARKET_A, 100 * MARKET_A_DEC_RAW);
        skip(30 hours);
        assertEq(marketALpToken.lockedAmount(lp2, lpIdA), 0, "lp2 matured");

        _deposit(lp1, SwapPool.Side.MARKET_A, 100 * MARKET_A_DEC_RAW);
        vm.prank(lp1);
        marketALpToken.safeTransferFrom(lp1, lp2, lpIdA, 40 ether, "");

        assertEq(marketALpToken.balanceOf(lp2, lpIdA), 140 ether, "lp2 balance");
        assertEq(marketALpToken.lockedAmount(lp2, lpIdA), 40 ether, "only incoming is fresh");
    }

    function testLock_OutflowFromMatured_DoesNotTouchFresh() public {
        _deposit(lp1, SwapPool.Side.MARKET_A, 100 * MARKET_A_DEC_RAW);
        skip(30 hours);
        _deposit(lp1, SwapPool.Side.MARKET_A, 30 * MARKET_A_DEC_RAW);
        assertEq(_freshAmount(lp1, lpIdA), 30 ether, "fresh pre");

        vm.prank(lp1);
        marketALpToken.safeTransferFrom(lp1, recv, lpIdA, 50 ether, "");

        assertEq(_freshAmount(lp1, lpIdA), 30 ether, "fresh unchanged");
        assertEq(marketALpToken.lockedAmount(lp1, lpIdA), 30 ether, "still locked=30");
    }

    function testLock_OutflowExceedingMatured_ReducesFresh() public {
        _deposit(lp1, SwapPool.Side.MARKET_A, 100 * MARKET_A_DEC_RAW);
        skip(30 hours);
        _deposit(lp1, SwapPool.Side.MARKET_A, 30 * MARKET_A_DEC_RAW);

        vm.prank(lp1);
        marketALpToken.safeTransferFrom(lp1, recv, lpIdA, 110 ether, "");

        assertEq(_freshAmount(lp1, lpIdA), 20 ether, "fresh reduced by overflow");
    }

    function testLock_PoisoningResistance_OneWeiDoesNotLockMatured() public {
        _mintAndApprove(attacker, 1_000 * MARKET_A_DEC_RAW, 1_000 * MARKET_B_DEC_RAW);

        _deposit(lp1, SwapPool.Side.MARKET_A, 100 * MARKET_A_DEC_RAW);
        skip(30 hours);
        assertEq(marketALpToken.lockedAmount(lp1, lpIdA), 0, "whale matured");

        _deposit(attacker, SwapPool.Side.MARKET_A, 1 * MARKET_A_DEC_RAW);
        vm.prank(attacker);
        marketALpToken.safeTransferFrom(attacker, lp1, lpIdA, 1, "");

        assertEq(marketALpToken.lockedAmount(lp1, lpIdA), 1, "only 1 wei locked after poison");
        assertEq(marketALpToken.balanceOf(lp1, lpIdA), 100 ether + 1, "balance");
    }

    function testLock_FreshGraduatesAfterLockPeriod() public {
        _deposit(lp1, SwapPool.Side.MARKET_A, 100 * MARKET_A_DEC_RAW);
        assertEq(marketALpToken.lockedAmount(lp1, lpIdA), 100 ether, "initially locked");
        skip(24 hours + 1);
        assertEq(marketALpToken.lockedAmount(lp1, lpIdA), 0, "graduates by time");
        assertFalse(marketALpToken.isLocked(lp1, lpIdA), "isLocked false");
    }

    function testLock_BurnDoesNotRevert() public {
        _deposit(lp1, SwapPool.Side.MARKET_A, 100 * MARKET_A_DEC_RAW);
        _deposit(lp3, SwapPool.Side.MARKET_B, 100 * MARKET_B_DEC_RAW);
        skip(25 hours);
        uint256 lpBal = marketALpToken.balanceOf(lp1, lpIdA);
        vm.prank(lp1);
        pool.withdrawal(SwapPool.Side.MARKET_A, lpBal, SwapPool.Side.MARKET_A);
        assertEq(marketALpToken.balanceOf(lp1, lpIdA), 0);
    }

    function testLock_PerTokenIdIsolation() public {
        vm.prank(operator);
        uint256 pool2Id = factory.createPool(
            _cfg(MARKET_A_ID_2, MARKET_A_DEC),
            _cfg(MARKET_B_ID_2, MARKET_B_DEC),
            LP_FEE_BPS,
            PROTOCOL_FEE_BPS,
            "ETH-NO"
        );
        PoolFactory.PoolInfo memory info2 = factory.getPool(pool2Id);
        SwapPool pool2 = SwapPool(payable(info2.swapPool));
        uint256 lpIdA2 = info2.marketALpTokenId;

        vm.prank(lp1);
        marketAToken.setApprovalForAll(address(pool2), true);

        vm.warp(1_000);
        _deposit(lp1, SwapPool.Side.MARKET_A, 100 * MARKET_A_DEC_RAW);

        vm.warp(1_000 + 30 hours);
        vm.prank(lp1);
        pool2.deposit(SwapPool.Side.MARKET_A, 100 * MARKET_A_DEC_RAW);

        assertFalse(marketALpToken.isLocked(lp1, lpIdA),  "pool1 matured");
        assertTrue(marketALpToken.isLocked(lp1, lpIdA2), "pool2 fresh");
        assertEq(marketALpToken.lockedAmount(lp1, lpIdA),  0,         "pool1 locked=0");
        assertEq(marketALpToken.lockedAmount(lp1, lpIdA2), 100 ether, "pool2 fully locked");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                                 DEPOSIT
    // ─────────────────────────────────────────────────────────────────────────

    function testDeposit_FirstDepositOnSideMints1to1() public {
        uint256 minted = _deposit(lp1, SwapPool.Side.MARKET_A, 500 * MARKET_A_DEC_RAW);
        assertEq(minted, 500 ether, "LP minted 1:1");
        assertEq(marketALpToken.balanceOf(lp1, lpIdA), 500 ether);
        assertEq(pool.aSideValue(), 500 ether);
        assertEq(pool.bSideValue(), 0);
    }

    function testDeposit_SecondDepositMintsAtCurrentRate() public {
        _deposit(lp1, SwapPool.Side.MARKET_A, 1000 * MARKET_A_DEC_RAW);
        _deposit(lp3, SwapPool.Side.MARKET_B, 1000 * MARKET_B_DEC_RAW);
        // Run a B→A swap to grow aSideValue via lpFee.
        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_B, 500 * MARKET_B_DEC_RAW);
        uint256 aValBefore = pool.aSideValue();
        uint256 aSupply    = marketALpToken.totalSupply(lpIdA);

        uint256 minted = _deposit(lp2, SwapPool.Side.MARKET_A, 100 * MARKET_A_DEC_RAW);
        // minted = 100 * aSupply / aValBefore
        uint256 expected = (100 ether * aSupply) / aValBefore;
        assertEq(minted, expected, "mint at post-fee rate");
    }

    function testDeposit_RevertsOnPaused() public {
        vm.prank(operator);
        factory.setPoolDepositsPaused(0, true);
        vm.prank(lp1);
        vm.expectRevert(SwapPool.DepositsPaused.selector);
        pool.deposit(SwapPool.Side.MARKET_A, 100 * MARKET_A_DEC_RAW);
    }

    function testDeposit_RevertsOnZero() public {
        vm.prank(lp1);
        vm.expectRevert(SwapPool.ZeroAmount.selector);
        pool.deposit(SwapPool.Side.MARKET_A, 0);
    }

    function testDeposit_RevertsWhenResolved() public {
        _resolve();
        vm.prank(lp1);
        vm.expectRevert(SwapPool.MarketResolved.selector);
        pool.deposit(SwapPool.Side.MARKET_A, 100 * MARKET_A_DEC_RAW);
    }

    function testDeposit_RevertsWhenResolvedAndPaused() public {
        // resolvePoolAndPause sets depositsPaused; the resolved-guard is still correct
        // regardless, but the earlier depositsPaused check trips first.
        vm.prank(operator);
        factory.resolvePoolAndPause(0);
        vm.prank(lp1);
        vm.expectRevert(SwapPool.DepositsPaused.selector);
        pool.deposit(SwapPool.Side.MARKET_A, 100 * MARKET_A_DEC_RAW);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                                  SWAP
    // ─────────────────────────────────────────────────────────────────────────

    function testSwap_PaysExpectedNetAndGrowsDrainedSideRate() public {
        _seedBalanced(1000 * MARKET_A_DEC_RAW, 1000 * MARKET_B_DEC_RAW);
        uint256 bRateBefore = pool.marketBRate();
        uint256 aRateBefore = pool.marketARate();

        // A → B swap: drained side is B, so bSideValue grows by lpFee.
        uint256 amountIn = 100 * MARKET_A_DEC_RAW;
        uint256 bBefore  = marketBToken.balanceOf(swapper, MARKET_B_ID);
        vm.prank(swapper);
        uint256 out = pool.swap(SwapPool.Side.MARKET_A, amountIn);

        // Ceiling-rounded total fee → payout is normIn - totalFee (ceil), off by at most 1.
        assertApproxEqAbs(out, _fromNorm(_toNorm(amountIn - ((amountIn * TOTAL_FEE_BPS + FEE_DEN - 1) / FEE_DEN), MARKET_A_DEC), MARKET_B_DEC), 1, "payout");
        assertEq(marketBToken.balanceOf(swapper, MARKET_B_ID) - bBefore, out);

        assertGt(pool.marketBRate(), bRateBefore, "B rate grew (drained side)");
        assertEq(pool.marketARate(), aRateBefore, "A rate unchanged");
        _assertValueInvariant();
    }

    function testSwap_BtoA_GrowsARateOnly() public {
        _seedBalanced(1000 * MARKET_A_DEC_RAW, 1000 * MARKET_B_DEC_RAW);
        uint256 aRateBefore = pool.marketARate();
        uint256 bRateBefore = pool.marketBRate();
        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_B, 100 * MARKET_B_DEC_RAW);
        assertGt(pool.marketARate(), aRateBefore, "A rate grew");
        assertEq(pool.marketBRate(), bRateBefore, "B rate unchanged");
        _assertValueInvariant();
    }

    function testSwap_RevertsOnPaused() public {
        _seedBalanced(1000 * MARKET_A_DEC_RAW, 1000 * MARKET_B_DEC_RAW);
        _pauseSwaps();
        vm.prank(swapper);
        vm.expectRevert(SwapPool.SwapsPaused.selector);
        pool.swap(SwapPool.Side.MARKET_A, 100 * MARKET_A_DEC_RAW);
    }

    function testSwap_RevertsOnInsufficientLiquidity() public {
        _deposit(lp1, SwapPool.Side.MARKET_A, 1000 * MARKET_A_DEC_RAW);
        // No B deposits → B physical = 0. A→B swap should revert.
        vm.prank(swapper);
        vm.expectRevert(abi.encodeWithSelector(SwapPool.InsufficientLiquidity.selector, 0, 99.6 ether));
        pool.swap(SwapPool.Side.MARKET_A, 100 * MARKET_A_DEC_RAW);
    }

    function testSwap_RevertsWhenResolved() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 1000 * MARKET_A_DEC_RAW);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, 1000 * MARKET_B_DEC_RAW);

        vm.prank(operator);
        factory.setResolvePool(0, true);

        vm.prank(swapper);
        vm.expectRevert(SwapPool.MarketResolved.selector);
        pool.swap(SwapPool.Side.MARKET_A, 100 * MARKET_A_DEC_RAW);
    }

    function testSwap_RevertsOnZeroAmount() public {
        vm.prank(swapper);
        vm.expectRevert(SwapPool.ZeroAmount.selector);
        pool.swap(SwapPool.Side.MARKET_A, 0);
    }


    // ─────────────────────────────────────────────────────────────────────────
    //                              WITHDRAWAL (unified)
    // ─────────────────────────────────────────────────────────────────────────

    function testWithdrawal_SameSide_Matured_Free() public {
        _seedBalanced(1000 * MARKET_A_DEC_RAW, 1000 * MARKET_B_DEC_RAW);
        skip(25 hours); // everything matures
        uint256 bal = marketALpToken.balanceOf(lp1, lpIdA);
        uint256 fcBefore = marketAToken.balanceOf(address(feeCollector), MARKET_A_ID);
        uint256 aBefore  = marketAToken.balanceOf(lp1, MARKET_A_ID);

        vm.prank(lp1);
        pool.withdrawal(SwapPool.Side.MARKET_A, bal, SwapPool.Side.MARKET_A);

        assertEq(marketAToken.balanceOf(address(feeCollector), MARKET_A_ID), fcBefore, "no fee");
        assertEq(marketAToken.balanceOf(lp1, MARKET_A_ID) - aBefore, 1000 * MARKET_A_DEC_RAW, "full claim");
        _assertValueInvariant();
    }

    function testWithdrawal_SameSide_Fresh_0p4Fee() public {
        _seedBalanced(1000 * MARKET_A_DEC_RAW, 1000 * MARKET_B_DEC_RAW);
        uint256 bal = marketALpToken.balanceOf(lp1, lpIdA);
        uint256 aBefore = marketAToken.balanceOf(lp1, MARKET_A_ID);

        vm.prank(lp1);
        pool.withdrawal(SwapPool.Side.MARKET_A, bal, SwapPool.Side.MARKET_A);

        uint256 out = marketAToken.balanceOf(lp1, MARKET_A_ID) - aBefore;
        uint256 expected = (1000 * MARKET_A_DEC_RAW * (FEE_DEN - TOTAL_FEE_BPS)) / FEE_DEN;
        assertApproxEqAbs(out, expected, 2, "payout after 0.4% JIT fee");
        assertApproxEqAbs(
            marketAToken.balanceOf(address(feeCollector), MARKET_A_ID),
            (1000 * MARKET_A_DEC_RAW * PROTOCOL_FEE_BPS) / FEE_DEN,
            2,
            "protocol fee"
        );
        _assertValueInvariant();
    }

    function testWithdrawal_SameSide_PartialFresh_FeeOnOverhangOnly() public {
        _deposit(lp1, SwapPool.Side.MARKET_A, 1000 * MARKET_A_DEC_RAW);
        _deposit(lp3, SwapPool.Side.MARKET_B, 1000 * MARKET_B_DEC_RAW);
        skip(25 hours);
        _deposit(lp1, SwapPool.Side.MARKET_A, 200 * MARKET_A_DEC_RAW);
        // 1000 matured + 200 fresh. Burn 1100: 1000 from matured, 100 from fresh.

        uint256 bal  = marketALpToken.balanceOf(lp1, lpIdA);
        uint256 burn = bal - 100 ether;
        uint256 fcBefore = marketAToken.balanceOf(address(feeCollector), MARKET_A_ID);

        vm.prank(lp1);
        pool.withdrawal(SwapPool.Side.MARKET_A, burn, SwapPool.Side.MARKET_A);

        // feeBase = claim * freshConsumed/burn = burn * 100/burn = 100
        uint256 expectedProto = (100 * MARKET_A_DEC_RAW * PROTOCOL_FEE_BPS + FEE_DEN - 1) / FEE_DEN;
        assertApproxEqAbs(
            marketAToken.balanceOf(address(feeCollector), MARKET_A_ID) - fcBefore,
            expectedProto,
            2,
            "fee scales by fresh portion"
        );
        _assertValueInvariant();
    }

    function testWithdrawal_SameSide_BurnFitsInMatured_NoFee() public {
        _deposit(lp1, SwapPool.Side.MARKET_A, 1000 * MARKET_A_DEC_RAW);
        _deposit(lp3, SwapPool.Side.MARKET_B, 1000 * MARKET_B_DEC_RAW);
        skip(25 hours);
        _deposit(lp1, SwapPool.Side.MARKET_A, 200 * MARKET_A_DEC_RAW);
        uint256 fcBefore = marketAToken.balanceOf(address(feeCollector), MARKET_A_ID);

        vm.prank(lp1);
        pool.withdrawal(SwapPool.Side.MARKET_A, 500 ether, SwapPool.Side.MARKET_A);

        assertEq(
            marketAToken.balanceOf(address(feeCollector), MARKET_A_ID),
            fcBefore,
            "no fee when burn fits matured"
        );
        _assertValueInvariant();
    }

    function testWithdrawal_CrossSide_Unresolved_FullFee() public {
        _seedBalanced(1000 * MARKET_A_DEC_RAW, 1000 * MARKET_B_DEC_RAW);
        skip(25 hours); // matured → no JIT fee would have applied on same-side
        uint256 bal = marketALpToken.balanceOf(lp1, lpIdA);
        uint256 bBefore = marketBToken.balanceOf(lp1, MARKET_B_ID);

        vm.prank(lp1);
        pool.withdrawal(SwapPool.Side.MARKET_B, bal, SwapPool.Side.MARKET_A);

        uint256 out = marketBToken.balanceOf(lp1, MARKET_B_ID) - bBefore;
        uint256 expected = (1000 * MARKET_B_DEC_RAW * (FEE_DEN - TOTAL_FEE_BPS)) / FEE_DEN;
        assertApproxEqAbs(out, expected, 2, "cross-side payout after 0.4% fee");
        _assertValueInvariant();
    }

    function testWithdrawal_CrossSide_Resolved_FullClaim() public {
        _seedBalanced(1000 * MARKET_A_DEC_RAW, 1000 * MARKET_B_DEC_RAW);
        _resolve();
        uint256 bal = marketALpToken.balanceOf(lp1, lpIdA);
        uint256 bBefore = marketBToken.balanceOf(lp1, MARKET_B_ID);

        vm.prank(lp1);
        pool.withdrawal(SwapPool.Side.MARKET_B, bal, SwapPool.Side.MARKET_A);

        assertEq(marketBToken.balanceOf(lp1, MARKET_B_ID) - bBefore, 1000 * MARKET_B_DEC_RAW, "full claim when resolved");
        assertEq(marketBToken.balanceOf(address(feeCollector), MARKET_B_ID), 0, "no fee");
        _assertValueInvariant();
    }

    function testWithdrawal_CrossSide_FeeCreditedToReceiveSide() public {
        _seedBalanced(1000 * MARKET_A_DEC_RAW, 1000 * MARKET_B_DEC_RAW);
        skip(25 hours);
        uint256 aRateBefore = pool.marketARate();
        uint256 bRateBefore = pool.marketBRate();

        // A-LP burns cross-side to B: fee should credit bSideValue (receiveSide).
        uint256 bal = marketALpToken.balanceOf(lp1, lpIdA);
        vm.prank(lp1);
        pool.withdrawal(SwapPool.Side.MARKET_B, bal, SwapPool.Side.MARKET_A);

        assertEq(pool.marketARate(), aRateBefore, "A rate unchanged (lpFee left A's accounting)");
        assertGt(pool.marketBRate(), bRateBefore, "B rate grew (receiveSide received lpFee)");
        _assertValueInvariant();
    }

    function testWithdrawal_RevertsOnSwapsPaused() public {
        _seedBalanced(1000 * MARKET_A_DEC_RAW, 1000 * MARKET_B_DEC_RAW);
        _pauseSwaps();
        uint256 bal = marketALpToken.balanceOf(lp1, lpIdA);
        vm.prank(lp1);
        vm.expectRevert(SwapPool.SwapsPaused.selector);
        pool.withdrawal(SwapPool.Side.MARKET_A, bal, SwapPool.Side.MARKET_A);
    }

    function testWithdrawal_RevertsOnZeroAmount() public {
        vm.prank(lp1);
        vm.expectRevert(SwapPool.ZeroAmount.selector);
        pool.withdrawal(SwapPool.Side.MARKET_A, 0, SwapPool.Side.MARKET_A);
    }

    function testWithdrawal_RevertsOnInsufficientPhysical() public {
        // Deposit A only; attempt same-side A withdraw after a drain via swap pushes A physical low
        _seedBalanced(1000 * MARKET_A_DEC_RAW, 1000 * MARKET_B_DEC_RAW);
        // Drain most of A via B→A swap
        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_B, 900 * MARKET_B_DEC_RAW);
        // A physical is now ~100; lp1 holds 1000 A-LP worth ~1000 claim → revert
        uint256 bal = marketALpToken.balanceOf(lp1, lpIdA);
        vm.prank(lp1);
        skip(25 hours);
        vm.expectRevert(); // InsufficientLiquidity with dynamic values
        pool.withdrawal(SwapPool.Side.MARKET_A, bal, SwapPool.Side.MARKET_A);
    }

    function testWithdrawal_LastLP_SameSide_FeeCreditsOtherSide() public {
        _seedBalanced(1000 * MARKET_A_DEC_RAW, 1000 * MARKET_B_DEC_RAW);
        // lp1 has fresh A-LP → JIT fee applies
        uint256 bal = marketALpToken.balanceOf(lp1, lpIdA);
        uint256 bRateBefore = pool.marketBRate();

        vm.prank(lp1);
        pool.withdrawal(SwapPool.Side.MARKET_A, bal, SwapPool.Side.MARKET_A);

        // lp1 was the only A-side LP → isLastLp=true → lpFee credited to B side
        assertEq(marketALpToken.totalSupply(lpIdA), 0, "A supply zeroed");
        assertGt(pool.marketBRate(), bRateBefore, "B rate grew from redirected lpFee");
        assertEq(pool.aSideValue(), 0, "A side fully drained");
        _assertValueInvariant();
    }

    function testWithdrawal_LastLP_BothSidesEmpty_FeeToCollector() public {
        // Only A-side deposit, no B-side LPs
        _deposit(lp1, SwapPool.Side.MARKET_A, 1000 * MARKET_A_DEC_RAW);
        // lp1 is fresh → JIT fee applies, and B side has 0 supply
        uint256 bal = marketALpToken.balanceOf(lp1, lpIdA);
        uint256 fcBefore = marketAToken.balanceOf(address(feeCollector), MARKET_A_ID);

        vm.prank(lp1);
        pool.withdrawal(SwapPool.Side.MARKET_A, bal, SwapPool.Side.MARKET_A);

        assertEq(marketALpToken.totalSupply(lpIdA), 0, "A supply zeroed");
        assertEq(marketBLpToken.totalSupply(lpIdB), 0, "B supply was already 0");
        assertEq(pool.aSideValue(), 0, "A side clean");
        assertEq(pool.bSideValue(), 0, "B side clean");
        // lpFee should not be stranded — verify it went to fee collector or pool is clean
        assertGt(
            marketAToken.balanceOf(address(feeCollector), MARKET_A_ID) - fcBefore,
            0,
            "lpFee routed to fee collector when no other side LPs exist"
        );
        _assertValueInvariant();
    }

    function testWithdrawal_CrossSide_Resolved_NoFee() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 1000 * MARKET_A_DEC_RAW);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, 1000 * MARKET_B_DEC_RAW);

        vm.prank(operator);
        factory.setResolvePool(0, true);

        uint256 bal = marketALpToken.balanceOf(lp1, lpIdA);
        uint256 bBefore = marketBToken.balanceOf(lp1, MARKET_B_ID);

        vm.prank(lp1);
        pool.withdrawal(SwapPool.Side.MARKET_B, bal, SwapPool.Side.MARKET_A);

        uint256 received = marketBToken.balanceOf(lp1, MARKET_B_ID) - bBefore;
        assertEq(received, 1000 * MARKET_B_DEC_RAW, "full claim when resolved");
    }

    function testWithdrawal_SameSide_Resolved_FreshLP_NoFee() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 1000 * MARKET_A_DEC_RAW);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, 1000 * MARKET_B_DEC_RAW);

        vm.prank(operator);
        factory.setResolvePool(0, true);

        uint256 bal = marketALpToken.balanceOf(lp1, lpIdA);
        uint256 aBefore = marketAToken.balanceOf(lp1, MARKET_A_ID);

        vm.prank(lp1);
        pool.withdrawal(SwapPool.Side.MARKET_A, bal, SwapPool.Side.MARKET_A);

        assertEq(marketAToken.balanceOf(lp1, MARKET_A_ID) - aBefore, 1000 * MARKET_A_DEC_RAW);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                             WITHDRAW PRO-RATA
    // ─────────────────────────────────────────────────────────────────────────

    function testWithdrawProRata_RevertsWhenSwapsActive() public {
        _seedBalanced(1000 * MARKET_A_DEC_RAW, 1000 * MARKET_B_DEC_RAW);
        uint256 bal = marketALpToken.balanceOf(lp1, lpIdA);
        vm.prank(lp1);
        vm.expectRevert(SwapPool.SwapsNotPaused.selector);
        pool.withdrawProRata(bal, SwapPool.Side.MARKET_A);
    }

    function testWithdrawProRata_Balanced_AllNative() public {
        _seedBalanced(1000 * MARKET_A_DEC_RAW, 1000 * MARKET_B_DEC_RAW);
        _pauseSwaps();
        uint256 bal = marketALpToken.balanceOf(lp1, lpIdA);
        uint256 aBefore = marketAToken.balanceOf(lp1, MARKET_A_ID);
        uint256 bBefore = marketBToken.balanceOf(lp1, MARKET_B_ID);

        vm.prank(lp1);
        pool.withdrawProRata(bal, SwapPool.Side.MARKET_A);

        assertEq(marketAToken.balanceOf(lp1, MARKET_A_ID) - aBefore, 1000 * MARKET_A_DEC_RAW, "all in A (native)");
        assertEq(marketBToken.balanceOf(lp1, MARKET_B_ID) - bBefore, 0,          "nothing in B");
        _assertValueInvariant();
    }

    function testWithdrawProRata_Imbalanced_SplitsNativeAndCross() public {
        _seedBalanced(1000 * MARKET_A_DEC_RAW, 1000 * MARKET_B_DEC_RAW);
        // Drain some A via B→A swap (physical A decreases).
        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_B, 200 * MARKET_B_DEC_RAW);
        _pauseSwaps();

        uint256 fcABefore = marketAToken.balanceOf(address(feeCollector), MARKET_A_ID);
        uint256 fcBBefore = marketBToken.balanceOf(address(feeCollector), MARKET_B_ID);

        uint256 bal = marketALpToken.balanceOf(lp1, lpIdA);
        uint256 aBefore = marketAToken.balanceOf(lp1, MARKET_A_ID);
        uint256 bBefore = marketBToken.balanceOf(lp1, MARKET_B_ID);

        vm.prank(lp1);
        (uint256 nativeOut, uint256 crossOut) = pool.withdrawProRata(bal, SwapPool.Side.MARKET_A);

        assertGt(nativeOut, 0, "native > 0");
        assertGt(crossOut,  0, "cross > 0");
        assertEq(marketAToken.balanceOf(lp1, MARKET_A_ID) - aBefore, nativeOut);
        assertEq(marketBToken.balanceOf(lp1, MARKET_B_ID) - bBefore, crossOut);
        // No *additional* fee-collector inflow from the pro-rata (swap fees pre-dated this).
        assertEq(marketAToken.balanceOf(address(feeCollector), MARKET_A_ID), fcABefore, "no new A fee");
        assertEq(marketBToken.balanceOf(address(feeCollector), MARKET_B_ID), fcBBefore, "no new B fee");
        _assertValueInvariant();
    }

    function testWithdrawProRata_NoFee_EvenWithFreshLP() public {
        _seedBalanced(1000 * MARKET_A_DEC_RAW, 1000 * MARKET_B_DEC_RAW);
        _pauseSwaps();
        uint256 bal = marketALpToken.balanceOf(lp1, lpIdA);
        assertTrue(marketALpToken.isLocked(lp1, lpIdA), "fresh");

        vm.prank(lp1);
        pool.withdrawProRata(bal, SwapPool.Side.MARKET_A);

        assertEq(marketAToken.balanceOf(address(feeCollector), MARKET_A_ID), 0, "pro-rata never fees");
    }

    function testWithdrawProRata_RevertsOnZeroAmount() public {
        vm.prank(operator);
        factory.setPoolSwapsPaused(0, true);

        vm.prank(lp1);
        vm.expectRevert(SwapPool.ZeroAmount.selector);
        pool.withdrawProRata(0, SwapPool.Side.MARKET_A);
    }

    function testWithdrawProRata_CrossSideCheck() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 1000 * MARKET_A_DEC_RAW);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, 1000 * MARKET_B_DEC_RAW);

        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_B, 900 * MARKET_B_DEC_RAW);

        vm.prank(operator);
        factory.setPoolSwapsPaused(0, true);

        uint256 bal = marketALpToken.balanceOf(lp1, lpIdA);
        vm.prank(lp1);
        (uint256 nativeOut, uint256 crossOut) = pool.withdrawProRata(bal, SwapPool.Side.MARKET_A);

        assertGt(nativeOut, 0, "native portion");
        assertGt(crossOut, 0, "cross portion");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                              VALUE INVARIANT
    // ─────────────────────────────────────────────────────────────────────────

    function testValueInvariant_AfterDeposits() public {
        _deposit(lp1, SwapPool.Side.MARKET_A, 500 * MARKET_A_DEC_RAW);
        _deposit(lp2, SwapPool.Side.MARKET_B, 300 * MARKET_B_DEC_RAW);
        _deposit(lp3, SwapPool.Side.MARKET_A, 200 * MARKET_A_DEC_RAW);
        _assertValueInvariant();
    }

    function testValueInvariant_AfterMixedOps() public {
        _seedBalanced(1000 * MARKET_A_DEC_RAW, 1000 * MARKET_B_DEC_RAW);
        _assertValueInvariant();

        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_A, 50 * MARKET_A_DEC_RAW);
        _assertValueInvariant();

        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_B, 80 * MARKET_B_DEC_RAW);
        _assertValueInvariant();

        skip(25 hours);
        vm.prank(lp1);
        pool.withdrawal(SwapPool.Side.MARKET_A, 100 ether, SwapPool.Side.MARKET_A);
        _assertValueInvariant();

        vm.prank(lp2);
        pool.withdrawal(SwapPool.Side.MARKET_A, 50 ether, SwapPool.Side.MARKET_B);
        _assertValueInvariant();
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                              RATE ATTRIBUTION
    // ─────────────────────────────────────────────────────────────────────────

    function testRateAttribution_SwapGrowsDrainedSideOnly() public {
        _seedBalanced(1000 * MARKET_A_DEC_RAW, 1000 * MARKET_B_DEC_RAW);
        uint256 aBefore = pool.marketARate();
        uint256 bBefore = pool.marketBRate();

        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_A, 100 * MARKET_A_DEC_RAW); // drain is B
        assertEq(pool.marketARate(), aBefore, "A unchanged");
        assertGt(pool.marketBRate(), bBefore, "B grew");
    }

    function testRateAttribution_SameSideJITFeeGrowsOwnRate() public {
        _seedBalanced(1000 * MARKET_A_DEC_RAW, 1000 * MARKET_B_DEC_RAW);
        _deposit(lp3, SwapPool.Side.MARKET_A, 500 * MARKET_A_DEC_RAW); // lp3 stays in after lp1 exits
        uint256 aBefore = pool.marketARate();

        uint256 bal = marketALpToken.balanceOf(lp1, lpIdA);
        vm.prank(lp1);
        pool.withdrawal(SwapPool.Side.MARKET_A, bal, SwapPool.Side.MARKET_A);
        assertGt(pool.marketARate(), aBefore, "JIT fee retained on A-side grows A rate");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                          FEE DISTRIBUTION SPLIT
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev When drain > drainedSideValue, the fee splits between both sides
    ///      proportionally to their effective ownership of the drained liquidity.
    function testFeeDistribution_SwapSplitsWhenOverflow() public {
        // Step 1: balanced seed
        _seedBalanced(1000 * MARKET_A_DEC_RAW, 1000 * MARKET_B_DEC_RAW);

        // Step 2: large B→A swap creates A-side overflow into B physical.
        //   After: aSideValue > physA  ⇒  physB > bSideValue
        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_B, 900 * MARKET_B_DEC_RAW);

        uint256 aRateBefore = pool.marketARate();
        uint256 bRateBefore = pool.marketBRate();

        // Step 3: large A→B swap whose normOut > bSideValue → split triggers.
        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_A, 1100 * MARKET_A_DEC_RAW);

        assertGt(pool.marketARate(), aRateBefore, "A rate grew (overflow side got partial fee)");
        assertGt(pool.marketBRate(), bRateBefore, "B rate grew (drained side got partial fee)");
        _assertValueInvariant();
    }

    /// @dev Balanced pool: drain stays within drainedSideValue → no split,
    ///      only the drained side's rate grows (existing behaviour preserved).
    function testFeeDistribution_SwapNoSplitWhenBalanced() public {
        _seedBalanced(1000 * MARKET_A_DEC_RAW, 1000 * MARKET_B_DEC_RAW);
        uint256 aRateBefore = pool.marketARate();
        uint256 bRateBefore = pool.marketBRate();

        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_A, 100 * MARKET_A_DEC_RAW);

        assertEq(pool.marketARate(), aRateBefore, "A rate unchanged (no overflow)");
        assertGt(pool.marketBRate(), bRateBefore, "B rate grew (100% of fee)");
        _assertValueInvariant();
    }

    /// @dev Cross-side withdrawal whose totalOutflow > receiveSideValue splits
    ///      the LP fee between both sides.
    function testFeeDistribution_CrossSideWithdrawalSplitsWhenOverflow() public {
        // Asymmetric seed: large A, small B
        _deposit(lp1, SwapPool.Side.MARKET_A, 1000 * MARKET_A_DEC_RAW);
        _deposit(lp2, SwapPool.Side.MARKET_B, 10 * MARKET_B_DEC_RAW);

        // Large B→A swap drains A physical, swells B physical.
        // After: aSideValue >> physA, physB >> bSideValue.
        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_B, 1000 * MARKET_B_DEC_RAW);

        skip(25 hours); // matured — removes JIT fee noise

        uint256 aRateBefore = pool.marketARate();
        uint256 bRateBefore = pool.marketBRate();

        // lp1 does partial cross-side withdrawal A→B.
        // totalOutflow ≈ 100 >> bSideValue(10) → split triggers.
        vm.prank(lp1);
        pool.withdrawal(SwapPool.Side.MARKET_B, 100 ether, SwapPool.Side.MARKET_A);

        assertGt(pool.marketARate(), aRateBefore, "A rate grew (overflow side got partial fee)");
        assertGt(pool.marketBRate(), bRateBefore, "B rate grew (drained side got partial fee)");
        _assertValueInvariant();
    }

    /// @dev Verifies the split is proportional: drained side with 10% ownership
    ///      gets ~10% of the fee, not 100%.
    function testFeeDistribution_SwapSplitIsProportional() public {
        _seedBalanced(1000 * MARKET_A_DEC_RAW, 1000 * MARKET_B_DEC_RAW);

        // B→A swap: makes aSideValue ≈ 1002.7, physA ≈ 103.6, physB ≈ 1899
        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_B, 900 * MARKET_B_DEC_RAW);

        uint256 bValBefore = pool.bSideValue();
        uint256 aValBefore = pool.aSideValue();

        // A→B swap of 1100: normOut ≈ 1095.6 > bSideValue(1000) → split
        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_A, 1100 * MARKET_A_DEC_RAW);

        uint256 bValAfter = pool.bSideValue();
        uint256 aValAfter = pool.aSideValue();

        uint256 feeToB = bValAfter - bValBefore;
        uint256 feeToA = aValAfter - aValBefore;
        uint256 totalLpFee = feeToA + feeToB;

        // B-side owned ~1000/1095.6 ≈ 91.3% of the drained liquidity
        // So B should get ~91% of the fee, A should get ~9%
        assertGt(feeToB, 0, "B got some fee");
        assertGt(feeToA, 0, "A got some fee");
        assertGt(feeToB, feeToA, "B got more (owns majority of drained liquidity)");

        // B's share should be roughly proportional to bSideValue / normOut
        // bSideValue=1000, normOut≈1095.6 → B gets ~91.3%
        uint256 bShareBps = (feeToB * 10000) / totalLpFee;
        assertGt(bShareBps, 9000, "B share > 90%");
        assertLt(bShareBps, 9200, "B share < 92%");
        _assertValueInvariant();
    }

    /// @dev When the drained side has 0 LPs (drainedVal == 0) but physical
    ///      tokens exist from the other side's overflow, 100% of the fee
    ///      goes to the other side.
    function testFeeDistribution_DrainedSideZeroLP_AllFeeToOtherSide() public {
        // lp1 deposits A, lp2 deposits B
        _deposit(lp1, SwapPool.Side.MARKET_A, 1000 * MARKET_A_DEC_RAW);
        _deposit(lp2, SwapPool.Side.MARKET_B, 100 * MARKET_B_DEC_RAW);
        skip(25 hours);

        // lp2 withdraws all B-LP cross-side → bSideValue drops to 0,
        // but physB stays at 100 (withdrawal paid out in A tokens).
        uint256 bLpBal = marketBLpToken.balanceOf(lp2, lpIdB);
        vm.prank(lp2);
        pool.withdrawal(SwapPool.Side.MARKET_A, bLpBal, SwapPool.Side.MARKET_B);

        assertEq(pool.bSideValue(), 0, "B side value is 0");
        assertGt(pool.physicalBalanceNorm(SwapPool.Side.MARKET_B), 0, "B physical still has tokens");

        uint256 aRateBefore = pool.marketARate();

        // Swap A→B: drained side is B with 0 value → all fee to A
        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_A, 50 * MARKET_A_DEC_RAW);

        assertEq(pool.bSideValue(), 0, "B side still 0 (got no fee)");
        assertGt(pool.marketARate(), aRateBefore, "A rate grew (100% of fee)");
        _assertValueInvariant();
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                                FEE COLLECTOR
    // ─────────────────────────────────────────────────────────────────────────

    function testFeeCollector_CanReceiveSingleERC1155() public {
        marketAToken.mint(address(feeCollector), MARKET_A_ID, 50);
        assertEq(marketAToken.balanceOf(address(feeCollector), MARKET_A_ID), 50);
    }

    function testFeeCollector_Withdraw_TransfersTokens() public {
        marketAToken.mint(address(feeCollector), MARKET_A_ID, 1000);

        vm.prank(owner);
        feeCollector.withdraw(address(marketAToken), MARKET_A_ID, 400, recv);

        assertEq(marketAToken.balanceOf(address(feeCollector), MARKET_A_ID), 600);
        assertEq(marketAToken.balanceOf(recv, MARKET_A_ID), 400);
    }

    function testFeeCollector_Withdraw_EmitsEvent() public {
        marketAToken.mint(address(feeCollector), MARKET_A_ID, 1000);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit FeeCollector.FeeWithdrawn(address(marketAToken), MARKET_A_ID, 400, recv);
        feeCollector.withdraw(address(marketAToken), MARKET_A_ID, 400, recv);
    }

    function testFeeCollector_Withdraw_RevertsForNonOwner() public {
        marketAToken.mint(address(feeCollector), MARKET_A_ID, 1000);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        feeCollector.withdraw(address(marketAToken), MARKET_A_ID, 100, recv);
    }

    function testFeeCollector_WithdrawAll_TransfersEntireBalance() public {
        marketAToken.mint(address(feeCollector), MARKET_A_ID, 750);

        vm.prank(owner);
        feeCollector.withdrawAll(address(marketAToken), MARKET_A_ID, recv);

        assertEq(marketAToken.balanceOf(address(feeCollector), MARKET_A_ID), 0);
        assertEq(marketAToken.balanceOf(recv, MARKET_A_ID), 750);
    }

    function testFeeCollector_WithdrawAll_EmitsEvent() public {
        marketAToken.mint(address(feeCollector), MARKET_A_ID, 750);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit FeeCollector.FeeWithdrawn(address(marketAToken), MARKET_A_ID, 750, recv);
        feeCollector.withdrawAll(address(marketAToken), MARKET_A_ID, recv);
    }

    function testFeeCollector_RecordFee_RevertsOnZero() public {
        vm.expectRevert(FeeCollector.ZeroAmount.selector);
        feeCollector.recordFee(address(marketAToken), MARKET_A_ID, 0);
    }

    function testFeeCollector_RecordFee_AnyoneCanCall() public {
        vm.prank(attacker);
        feeCollector.recordFee(address(marketAToken), MARKET_A_ID, 100);
    }

    function testFeeCollector_Withdraw_RevertsOnZeroAddress() public {
        marketAToken.mint(address(feeCollector), MARKET_A_ID, 1000);
        vm.prank(owner);
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        feeCollector.withdraw(address(marketAToken), MARKET_A_ID, 100, address(0));
    }

    function testFeeCollector_Withdraw_RevertsOnZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(FeeCollector.ZeroAmount.selector);
        feeCollector.withdraw(address(marketAToken), MARKET_A_ID, 0, recv);
    }

    function testFeeCollector_WithdrawBatch_TransfersTokens() public {
        marketAToken.mint(address(feeCollector), MARKET_A_ID, 500);
        marketAToken.mint(address(feeCollector), MARKET_A_ID_2, 300);

        uint256[] memory ids = new uint256[](2);
        ids[0] = MARKET_A_ID;
        ids[1] = MARKET_A_ID_2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 500;
        amounts[1] = 300;

        vm.prank(owner);
        feeCollector.withdrawBatch(address(marketAToken), ids, amounts, recv);

        assertEq(marketAToken.balanceOf(recv, MARKET_A_ID), 500);
        assertEq(marketAToken.balanceOf(recv, MARKET_A_ID_2), 300);
    }

    function testFeeCollector_WithdrawBatch_RevertsOnZeroAddress() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = MARKET_A_ID;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;

        vm.prank(owner);
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        feeCollector.withdrawBatch(address(marketAToken), ids, amounts, address(0));
    }

    function testFeeCollector_WithdrawBatch_RevertsOnZeroAmount() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = MARKET_A_ID;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0;

        vm.prank(owner);
        vm.expectRevert(FeeCollector.ZeroAmount.selector);
        feeCollector.withdrawBatch(address(marketAToken), ids, amounts, recv);
    }

    function testFeeCollector_WithdrawBatch_RevertsForNonOwner() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = MARKET_A_ID;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        feeCollector.withdrawBatch(address(marketAToken), ids, amounts, recv);
    }

    function testFeeCollector_WithdrawAll_RevertsOnZeroBalance() public {
        vm.prank(owner);
        vm.expectRevert(FeeCollector.ZeroAmount.selector);
        feeCollector.withdrawAll(address(marketAToken), MARKET_A_ID, recv);
    }

    function testFeeCollector_WithdrawAll_RevertsOnZeroAddress() public {
        marketAToken.mint(address(feeCollector), MARKET_A_ID, 100);
        vm.prank(owner);
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        feeCollector.withdrawAll(address(marketAToken), MARKET_A_ID, address(0));
    }

    function testFeeCollector_WithdrawAllBatch_TransfersOnlyNonZero() public {
        marketAToken.mint(address(feeCollector), MARKET_A_ID, 500);
        // MARKET_A_ID_2 has zero balance — should be skipped

        uint256[] memory ids = new uint256[](2);
        ids[0] = MARKET_A_ID;
        ids[1] = MARKET_A_ID_2;

        vm.prank(owner);
        feeCollector.withdrawAllBatch(address(marketAToken), ids, recv);

        assertEq(marketAToken.balanceOf(recv, MARKET_A_ID), 500);
        assertEq(marketAToken.balanceOf(recv, MARKET_A_ID_2), 0);
    }

    function testFeeCollector_WithdrawAllBatch_RevertsOnAllZero() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = MARKET_A_ID;
        ids[1] = MARKET_A_ID_2;

        vm.prank(owner);
        vm.expectRevert(FeeCollector.ZeroAmount.selector);
        feeCollector.withdrawAllBatch(address(marketAToken), ids, recv);
    }

    function testFeeCollector_WithdrawAllBatch_RevertsOnZeroAddress() public {
        marketAToken.mint(address(feeCollector), MARKET_A_ID, 100);

        uint256[] memory ids = new uint256[](1);
        ids[0] = MARKET_A_ID;

        vm.prank(owner);
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        feeCollector.withdrawAllBatch(address(marketAToken), ids, address(0));
    }

    function testFeeCollector_WithdrawAllBatch_RevertsForNonOwner() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = MARKET_A_ID;

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        feeCollector.withdrawAllBatch(address(marketAToken), ids, recv);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                                FACTORY
    // ─────────────────────────────────────────────────────────────────────────

    function testFactory_LpTokenIds_MirrorMarketTokenIds() public {
        assertEq(lpIdA, MARKET_A_ID);
        assertEq(lpIdB, MARKET_B_ID);

        vm.prank(operator);
        uint256 pool2Id = factory.createPool(
            _cfg(MARKET_A_ID_2, 18),
            _cfg(MARKET_B_ID_2, 18),
            LP_FEE_BPS,
            PROTOCOL_FEE_BPS,
            "evt2"
        );
        PoolFactory.PoolInfo memory info2 = factory.getPool(pool2Id);
        assertEq(info2.marketALpTokenId, MARKET_A_ID_2);
        assertEq(info2.marketBLpTokenId, MARKET_B_ID_2);
    }

    function testFactory_RevertsOnReusedMarketATokenId() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PoolFactory.MarketATokenIdAlreadyUsed.selector, MARKET_A_ID));
        factory.createPool(
            _cfg(MARKET_A_ID,   18),
            _cfg(MARKET_B_ID_2, 18),
            LP_FEE_BPS,
            PROTOCOL_FEE_BPS,
            "dup-A"
        );
    }

    function testFactory_RevertsOnReusedMarketBTokenId() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PoolFactory.MarketBTokenIdAlreadyUsed.selector, MARKET_B_ID));
        factory.createPool(
            _cfg(MARKET_A_ID_2, 18),
            _cfg(MARKET_B_ID,   18),
            LP_FEE_BPS,
            PROTOCOL_FEE_BPS,
            "dup-B"
        );
    }

    function testFactory_SetResolvePool_TogglesWithoutTouchingPauseFlags() public {
        _seedBalanced(1000 * MARKET_A_DEC_RAW, 1000 * MARKET_B_DEC_RAW);

        vm.prank(operator);
        factory.setResolvePool(0, true);
        assertTrue(pool.resolved());
        assertFalse(pool.depositsPaused());
        assertFalse(pool.swapsPaused());

        vm.prank(operator);
        factory.setResolvePool(0, false);
        assertFalse(pool.resolved());
    }

    function testFactory_ResolvePoolAndPause_AtomicAllThreeFlags() public {
        _seedBalanced(1000 * MARKET_A_DEC_RAW, 1000 * MARKET_B_DEC_RAW);

        vm.prank(operator);
        factory.resolvePoolAndPause(0);

        assertTrue(pool.resolved());
        assertTrue(pool.depositsPaused());
        assertTrue(pool.swapsPaused());
    }

    function testFactory_ProjectAndLpNamesStoredAtFactory() public {
        assertEq(factory.marketAName(), "Polymarket");
        assertEq(factory.marketBName(), "Opinion");
        assertEq(marketALpToken.name(), "Polymarket LP. Polymarket:Opinion pools");
        assertEq(marketBLpToken.name(), "Opinion LP. Polymarket:Opinion pools");
    }

    function testFactory_SecondFactoryWithDifferentNames() public {
        FeeCollector fc2 = new FeeCollector(owner);
        vm.prank(owner);
        PoolFactory factory2 = new PoolFactory(
            address(marketAToken),
            address(marketBToken),
            address(fc2),
            operator,
            owner,
            "Mambojumbo",
            "Flipflop",
            "Mambojumbo LP",
            "Flipflop LP"
        );
        assertEq(factory2.marketAName(), "Mambojumbo");
        assertEq(factory2.marketBName(), "Flipflop");
        assertEq(factory2.marketALpToken().name(), "Mambojumbo LP");
        assertEq(factory2.marketBLpToken().name(), "Flipflop LP");
    }

    function testFactory_Constructor_RevertsOnZeroMarketA() public {
        vm.expectRevert(PoolFactory.ZeroAddress.selector);
        new PoolFactory(address(0), address(marketBToken), address(feeCollector), operator, owner, "A", "B", "A-LP", "B-LP");
    }

    function testFactory_Constructor_RevertsOnZeroMarketB() public {
        vm.expectRevert(PoolFactory.ZeroAddress.selector);
        new PoolFactory(address(marketAToken), address(0), address(feeCollector), operator, owner, "A", "B", "A-LP", "B-LP");
    }

    function testFactory_Constructor_RevertsOnZeroFeeCollector() public {
        vm.expectRevert(PoolFactory.ZeroAddress.selector);
        new PoolFactory(address(marketAToken), address(marketBToken), address(0), operator, owner, "A", "B", "A-LP", "B-LP");
    }

    function testFactory_Constructor_RevertsOnZeroOperator() public {
        vm.expectRevert(PoolFactory.ZeroAddress.selector);
        new PoolFactory(address(marketAToken), address(marketBToken), address(feeCollector), address(0), owner, "A", "B", "A-LP", "B-LP");
    }

    function testFactory_Constructor_RevertsOnEmptyMarketAName() public {
        vm.expectRevert(PoolFactory.MissingName.selector);
        new PoolFactory(address(marketAToken), address(marketBToken), address(feeCollector), operator, owner, "", "B", "A-LP", "B-LP");
    }

    function testFactory_Constructor_RevertsOnEmptyMarketBName() public {
        vm.expectRevert(PoolFactory.MissingName.selector);
        new PoolFactory(address(marketAToken), address(marketBToken), address(feeCollector), operator, owner, "A", "", "A-LP", "B-LP");
    }

    function testFactory_Constructor_RevertsOnEmptyLpAName() public {
        vm.expectRevert(PoolFactory.MissingName.selector);
        new PoolFactory(address(marketAToken), address(marketBToken), address(feeCollector), operator, owner, "A", "B", "", "B-LP");
    }

    function testFactory_Constructor_RevertsOnEmptyLpBName() public {
        vm.expectRevert(PoolFactory.MissingName.selector);
        new PoolFactory(address(marketAToken), address(marketBToken), address(feeCollector), operator, owner, "A", "B", "A-LP", "");
    }

    function testFactory_CreatePool_RevertsOnZeroTokenIdA() public {
        vm.prank(operator);
        vm.expectRevert(PoolFactory.InvalidTokenID.selector);
        factory.createPool(
            PoolFactory.MarketConfig({tokenId: 0, decimals: 18}),
            PoolFactory.MarketConfig({tokenId: 999, decimals: 18}),
            LP_FEE_BPS, PROTOCOL_FEE_BPS, "bad"
        );
    }

    function testFactory_CreatePool_RevertsOnZeroTokenIdB() public {
        vm.prank(operator);
        vm.expectRevert(PoolFactory.InvalidTokenID.selector);
        factory.createPool(
            PoolFactory.MarketConfig({tokenId: 999, decimals: 18}),
            PoolFactory.MarketConfig({tokenId: 0, decimals: 18}),
            LP_FEE_BPS, PROTOCOL_FEE_BPS, "bad"
        );
    }

    function testFactory_CreatePool_RevertsOnInvalidDecimalsA() public {
        vm.prank(operator);
        vm.expectRevert(PoolFactory.InvalidDecimals.selector);
        factory.createPool(
            PoolFactory.MarketConfig({tokenId: 999, decimals: 19}),
            PoolFactory.MarketConfig({tokenId: 998, decimals: 18}),
            LP_FEE_BPS, PROTOCOL_FEE_BPS, "bad"
        );
    }

    function testFactory_CreatePool_RevertsOnInvalidDecimalsB() public {
        vm.prank(operator);
        vm.expectRevert(PoolFactory.InvalidDecimals.selector);
        factory.createPool(
            PoolFactory.MarketConfig({tokenId: 999, decimals: 18}),
            PoolFactory.MarketConfig({tokenId: 998, decimals: 19}),
            LP_FEE_BPS, PROTOCOL_FEE_BPS, "bad"
        );
    }

    function testFactory_CreatePool_RevertsOnDuplicatePoolKey() public {
        vm.prank(operator);
        vm.expectRevert();
        factory.createPool(
            PoolFactory.MarketConfig({tokenId: MARKET_A_ID, decimals: MARKET_A_DEC}),
            PoolFactory.MarketConfig({tokenId: MARKET_B_ID, decimals: MARKET_B_DEC}),
            LP_FEE_BPS, PROTOCOL_FEE_BPS, "dup"
        );
    }

    function testFactory_CreatePool_RevertsOnFeeTooHighLp() public {
        vm.prank(operator);
        vm.expectRevert(SwapPool.FeeTooHigh.selector);
        factory.createPool(
            PoolFactory.MarketConfig({tokenId: 999, decimals: 18}),
            PoolFactory.MarketConfig({tokenId: 998, decimals: 18}),
            101, PROTOCOL_FEE_BPS, "bad"
        );
    }

    function testFactory_CreatePool_RevertsOnFeeTooHighProtocol() public {
        vm.prank(operator);
        vm.expectRevert(SwapPool.FeeTooHigh.selector);
        factory.createPool(
            PoolFactory.MarketConfig({tokenId: 999, decimals: 18}),
            PoolFactory.MarketConfig({tokenId: 998, decimals: 18}),
            LP_FEE_BPS, 51, "bad"
        );
    }

    function testFactory_CreatePool_RevertsForNonOperator() public {
        vm.prank(attacker);
        vm.expectRevert(PoolFactory.NotOperator.selector);
        factory.createPool(
            PoolFactory.MarketConfig({tokenId: 999, decimals: 18}),
            PoolFactory.MarketConfig({tokenId: 998, decimals: 18}),
            LP_FEE_BPS, PROTOCOL_FEE_BPS, "bad"
        );
    }

    function testFactory_SetOperator_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(PoolFactory.ZeroAddress.selector);
        factory.setOperator(address(0));
    }

    function testFactory_SetOperator_Works() public {
        address newOp = makeAddr("newOp");
        vm.prank(owner);
        factory.setOperator(newOp);
        assertEq(factory.operator(), newOp);
    }

    function testFactory_SetFeeCollector_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(PoolFactory.ZeroAddress.selector);
        factory.setFeeCollector(address(0));
    }

    function testFactory_SetFeeCollector_Works() public {
        FeeCollector fc2 = new FeeCollector(owner);
        vm.prank(owner);
        factory.setFeeCollector(address(fc2));
        assertEq(address(factory.feeCollector()), address(fc2));
    }

    function testFactory_SetPoolFees_Works() public {
        vm.prank(owner);
        factory.setPoolFees(0, 50, 20);
        assertEq(pool.lpFeeBps(), 50);
        assertEq(pool.protocolFeeBps(), 20);
    }

    function testFactory_SetPoolFees_RevertsOnInvalidPool() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PoolFactory.PoolNotFound.selector, 999));
        factory.setPoolFees(999, 50, 20);
    }

    function testFactory_GetPool_RevertsOnInvalidId() public {
        vm.expectRevert(abi.encodeWithSelector(PoolFactory.PoolNotFound.selector, 999));
        factory.getPool(999);
    }

    function testFactory_GetAllPools_ReturnsArray() public view {
        PoolFactory.PoolInfo[] memory allPools = factory.getAllPools();
        assertEq(allPools.length, 1);
    }

    function testFactory_PoolCount_ReturnsCorrect() public view {
        assertEq(factory.poolCount(), 1);
    }

    function testFactory_FindPool_ReturnsCorrectPool() public view {
        (bool found, uint256 id) = factory.findPool(MARKET_A_ID, MARKET_B_ID);
        assertTrue(found);
        assertEq(id, 0);
    }

    function testFactory_FindPool_ReturnsFalseForMissing() public view {
        (bool found,) = factory.findPool(999, 998);
        assertFalse(found);
    }

    function testFactory_SetPoolDepositsPaused_RevertsOnInvalidPool() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PoolFactory.PoolNotFound.selector, 999));
        factory.setPoolDepositsPaused(999, true);
    }

    function testFactory_SetPoolSwapsPaused_RevertsOnInvalidPool() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PoolFactory.PoolNotFound.selector, 999));
        factory.setPoolSwapsPaused(999, true);
    }

    function testFactory_SetResolvePool_RevertsOnInvalidPool() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PoolFactory.PoolNotFound.selector, 999));
        factory.setResolvePool(999, true);
    }

    function testFactory_ResolvePoolAndPause_RevertsOnInvalidPool() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PoolFactory.PoolNotFound.selector, 999));
        factory.resolvePoolAndPause(999);
    }

    function testFactory_OwnerCanActAsOperator() public {
        vm.prank(owner);
        factory.setPoolDepositsPaused(0, true);
        assertTrue(pool.depositsPaused());
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                          FLUSH RESIDUAL / RESCUE
    // ─────────────────────────────────────────────────────────────────────────

    function testFlushResidual_LastExitResetsState() public {
        _seedBalanced(1000 * MARKET_A_DEC_RAW, 1000 * MARKET_B_DEC_RAW);
        skip(25 hours);

        vm.prank(lp1);
        pool.withdrawal(SwapPool.Side.MARKET_A, 1000 ether, SwapPool.Side.MARKET_A);

        vm.prank(lp2);
        pool.withdrawal(SwapPool.Side.MARKET_B, 1000 ether, SwapPool.Side.MARKET_B);

        assertEq(marketALpToken.totalSupply(lpIdA), 0, "A supply 0");
        assertEq(marketBLpToken.totalSupply(lpIdB), 0, "B supply 0");
        assertEq(pool.aSideValue(), 0);
        assertEq(pool.bSideValue(), 0);
        assertEq(marketAToken.balanceOf(address(pool), MARKET_A_ID), 0, "no A dust");
        assertEq(marketBToken.balanceOf(address(pool), MARKET_B_ID), 0, "no B dust");
    }

    function testFlushResidual_ProRataExitAfterSwapFlushesDust() public {
        // A swap creates rounding dust on one side; pro-rata exits of both sides should
        // leave the pool clean with any residual swept to the fee collector.
        _seedBalanced(1000 * MARKET_A_DEC_RAW, 1000 * MARKET_B_DEC_RAW);
        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_A, 100 * MARKET_A_DEC_RAW);
        _pauseSwaps();

        vm.prank(lp1);
        pool.withdrawProRata(1000 ether, SwapPool.Side.MARKET_A);
        vm.prank(lp2);
        pool.withdrawProRata(1000 ether, SwapPool.Side.MARKET_B);

        assertEq(marketALpToken.totalSupply(lpIdA), 0);
        assertEq(marketBLpToken.totalSupply(lpIdB), 0);
        assertEq(pool.aSideValue(), 0);
        assertEq(pool.bSideValue(), 0);
        assertEq(marketAToken.balanceOf(address(pool), MARKET_A_ID), 0, "pool A clean");
        assertEq(marketBToken.balanceOf(address(pool), MARKET_B_ID), 0, "pool B clean");
    }

    function testRescue_NothingToRescueWhenPhysicalMatchesTracked() public {
        _seedBalanced(1000 * MARKET_A_DEC_RAW, 1000 * MARKET_B_DEC_RAW);
        vm.prank(owner);
        vm.expectRevert(SwapPool.NothingToRescue.selector);
        factory.rescuePoolTokens(0, SwapPool.Side.MARKET_A, 1, recv);
    }

    function testRescue_SurplusPhysicalCanBeRescued() public {
        // Empty pool (no deposits). Someone accidentally sends tokens in.
        // rescueTokens's conservative check requires physical > aSideValue + bSideValue.
        marketAToken.mint(address(pool), MARKET_A_ID, 50 * MARKET_A_DEC_RAW);

        uint256 recvBefore = marketAToken.balanceOf(recv, MARKET_A_ID);
        vm.prank(owner);
        factory.rescuePoolTokens(0, SwapPool.Side.MARKET_A, 50 * MARKET_A_DEC_RAW, recv);
        assertEq(marketAToken.balanceOf(recv, MARKET_A_ID) - recvBefore, 50 * MARKET_A_DEC_RAW);
    }

    function testRescue_RevertsForNonFactory() public {
        vm.prank(attacker);
        vm.expectRevert(SwapPool.Unauthorized.selector);
        pool.rescueTokens(SwapPool.Side.MARKET_A, 1, recv);
    }

    function testRescue_RevertsOnZeroAddress() public {
        marketAToken.mint(address(pool), MARKET_A_ID, 100 * MARKET_A_DEC_RAW);
        vm.prank(owner);
        vm.expectRevert(SwapPool.ZeroAddress.selector);
        factory.rescuePoolTokens(0, SwapPool.Side.MARKET_A, 100, address(0));
    }

    function testRescue_RevertsWhenSurplusExceeded() public {
        marketAToken.mint(address(pool), MARKET_A_ID, 50 * MARKET_A_DEC_RAW);
        vm.prank(owner);
        vm.expectRevert(SwapPool.NothingToRescue.selector);
        factory.rescuePoolTokens(0, SwapPool.Side.MARKET_A, 51 * MARKET_A_DEC_RAW, recv);
    }

    function testRescue_GlobalSurplusCalculation() public {
        marketAToken.mint(address(pool), MARKET_A_ID, 100 * MARKET_A_DEC_RAW);
        marketBToken.mint(address(pool), MARKET_B_ID, 50 * MARKET_B_DEC_RAW);

        vm.prank(owner);
        factory.rescuePoolTokens(0, SwapPool.Side.MARKET_A, 50 * MARKET_A_DEC_RAW, recv);
        assertEq(marketAToken.balanceOf(recv, MARKET_A_ID), 50 * MARKET_A_DEC_RAW);

        vm.prank(owner);
        factory.rescuePoolTokens(0, SwapPool.Side.MARKET_B, 50 * MARKET_B_DEC_RAW, recv);
        assertEq(marketBToken.balanceOf(recv, MARKET_B_ID), 50 * MARKET_B_DEC_RAW);
    }

    function testRescueERC1155_RevertsOnPoolTokenContract() public {
        vm.prank(owner);
        vm.expectRevert(SwapPool.CannotRescuePoolTokens.selector);
        factory.rescuePoolERC1155(0, address(marketAToken), MARKET_A_ID, 1, recv);
    }

    function testRescueERC1155_RevertsOnPoolTokenContractB() public {
        vm.prank(owner);
        vm.expectRevert(SwapPool.CannotRescuePoolTokens.selector);
        factory.rescuePoolERC1155(0, address(marketBToken), MARKET_B_ID, 1, recv);
    }

    function testRescueERC1155_CanRescueOtherContracts() public {
        MockERC1155 otherToken = new MockERC1155();
        otherToken.mint(address(pool), 1, 500);

        vm.prank(owner);
        factory.rescuePoolERC1155(0, address(otherToken), 1, 500, recv);
        assertEq(otherToken.balanceOf(recv, 1), 500);
    }

    function testRescueERC20_Works() public {
        // SwapPool uses SafeERC20; for this test we just verify auth
        vm.prank(attacker);
        vm.expectRevert(SwapPool.Unauthorized.selector);
        pool.rescueERC20(address(0x1), 1, recv);
    }

    function testRescueETH_Works() public {
        vm.deal(address(pool), 1 ether);
        uint256 before = recv.balance;
        vm.prank(owner);
        factory.rescuePoolETH(0, payable(recv));
        assertEq(recv.balance - before, 1 ether);
    }

    function testRescueETH_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(SwapPool.ZeroAddress.selector);
        factory.rescuePoolETH(0, payable(address(0)));
    }

    function testRescuePoolTokens_RevertsOnInvalidPool() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PoolFactory.PoolNotFound.selector, 999));
        factory.rescuePoolTokens(999, SwapPool.Side.MARKET_A, 1, recv);
    }

    function testRescuePoolERC1155_RevertsOnInvalidPool() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PoolFactory.PoolNotFound.selector, 999));
        factory.rescuePoolERC1155(999, address(0x1), 1, 1, recv);
    }

    function testRescuePoolERC20_RevertsOnInvalidPool() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PoolFactory.PoolNotFound.selector, 999));
        factory.rescuePoolERC20(999, address(0x1), 1, recv);
    }

    function testRescuePoolETH_RevertsOnInvalidPool() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PoolFactory.PoolNotFound.selector, 999));
        factory.rescuePoolETH(999, payable(recv));
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                     LP TOKEN COVERAGE
    // ─────────────────────────────────────────────────────────────────────────

    function testLPToken_RegisterPool_RevertsOnZeroAddress() public {
        LPToken lp = new LPToken(address(this), "Test LP");
        vm.expectRevert(LPToken.ZeroAddress.selector);
        lp.registerPool(address(0), 1);
    }

    function testLPToken_RegisterPool_RevertsOnZeroTokenId() public {
        LPToken lp = new LPToken(address(this), "Test LP");
        vm.expectRevert(LPToken.InvalidTokenId.selector);
        lp.registerPool(address(0x1), 0);
    }

    function testLPToken_RegisterPool_RevertsOnDuplicate() public {
        LPToken lp = new LPToken(address(this), "Test LP");
        lp.registerPool(address(0x1), 1);
        vm.expectRevert(LPToken.TokenIdAlreadyRegistered.selector);
        lp.registerPool(address(0x2), 1);
    }

    function testLPToken_RegisterPool_RevertsForNonFactory() public {
        vm.prank(attacker);
        vm.expectRevert(LPToken.OnlyFactory.selector);
        marketALpToken.registerPool(address(0x1), 999);
    }

    function testLPToken_Mint_RevertsForNonPool() public {
        vm.prank(attacker);
        vm.expectRevert(LPToken.OnlyPool.selector);
        marketALpToken.mint(attacker, lpIdA, 100);
    }

    function testLPToken_Burn_RevertsForNonPool() public {
        vm.prank(attacker);
        vm.expectRevert(LPToken.OnlyPool.selector);
        marketALpToken.burn(attacker, lpIdA, 100);
    }

    function testLPToken_Constructor_RevertsOnZeroFactory() public {
        vm.expectRevert(LPToken.ZeroAddress.selector);
        new LPToken(address(0), "Test");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                     SWAP POOL
    // ─────────────────────────────────────────────────────────────────────────

    function testSwapPool_ReceivesETH() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(pool).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(pool).balance, 1 ether);
    }

    function testSwapPool_TotalFeeBps() public view {
        assertEq(pool.totalFeeBps(), LP_FEE_BPS + PROTOCOL_FEE_BPS);
    }

    function testSwapPool_RateReturns1e18WhenSupplyZero() public view {
        assertEq(pool.marketARate(), 1e18);
        assertEq(pool.marketBRate(), 1e18);
    }

    function testSwapPool_PhysicalBalanceNorm() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 100 * MARKET_A_DEC_RAW);
        assertEq(pool.physicalBalanceNorm(SwapPool.Side.MARKET_A), 100 ether);
    }

    function testSwapPool_Initialize_RevertsIfAlreadyInitialized() public {
        vm.prank(address(factory));
        vm.expectRevert(SwapPool.AlreadyInitialized.selector);
        pool.initialize(99, 100);
    }

    function testSwapPool_Initialize_RevertsForNonFactory() public {
        vm.prank(attacker);
        vm.expectRevert(SwapPool.Unauthorized.selector);
        pool.initialize(99, 100);
    }

    function testSwapPool_SetDepositsPaused_RevertsForNonFactory() public {
        vm.prank(attacker);
        vm.expectRevert(SwapPool.Unauthorized.selector);
        pool.setDepositsPaused(true);
    }

    function testSwapPool_SetSwapsPaused_RevertsForNonFactory() public {
        vm.prank(attacker);
        vm.expectRevert(SwapPool.Unauthorized.selector);
        pool.setSwapsPaused(true);
    }

    function testSwapPool_SetResolved_RevertsForNonFactory() public {
        vm.prank(attacker);
        vm.expectRevert(SwapPool.Unauthorized.selector);
        pool.setResolved(true);
    }

    function testSwapPool_SetResolvedAndPaused_RevertsForNonFactory() public {
        vm.prank(attacker);
        vm.expectRevert(SwapPool.Unauthorized.selector);
        pool.setResolvedAndPaused();
    }

    function testSwapPool_SetFees_RevertsForNonFactory() public {
        vm.prank(attacker);
        vm.expectRevert(SwapPool.Unauthorized.selector);
        pool.setFees(10, 10);
    }

    function testSwapPool_SetFees_RevertsOnFeeTooHighLp() public {
        vm.prank(owner);
        vm.expectRevert(SwapPool.FeeTooHigh.selector);
        factory.setPoolFees(0, 101, 10);
    }

    function testSwapPool_SetFees_RevertsOnFeeTooHighProtocol() public {
        vm.prank(owner);
        vm.expectRevert(SwapPool.FeeTooHigh.selector);
        factory.setPoolFees(0, 10, 51);
    }

}
