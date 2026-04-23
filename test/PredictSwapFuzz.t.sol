// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/FeeCollector.sol";
import "../src/LPToken.sol";
import "../src/PoolFactory.sol";
import "../src/SwapPool.sol";
import "./MockERC1155.sol";

contract PredictSwapFuzzTest is Test {

    // ─── Actors ───────────────────────────────────────────────────────────────

    address owner    = makeAddr("owner");
    address operator = makeAddr("operator");
    address lp1      = makeAddr("lp1");
    address lp2      = makeAddr("lp2");
    address swapper  = makeAddr("swapper");

    // ─── Token IDs ────────────────────────────────────────────────────────────

    uint256 constant MARKET_A_ID = 1;
    uint256 constant MARKET_B_ID = 511515;

    uint8 constant MARKET_A_DEC = 6;
    uint8 constant MARKET_B_DEC = 18;

    uint256 constant MARKET_A_DEC_RAW = 1e6;
    uint256 constant MARKET_B_DEC_RAW = 1e18;

    uint256 constant LP_FEE_BPS       = 30;
    uint256 constant PROTOCOL_FEE_BPS = 10;
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

        _mintAndApprove(lp1);
        _mintAndApprove(lp2);
        _mintAndApprove(swapper);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _cfg(uint256 id, uint8 dec) internal pure returns (PoolFactory.MarketConfig memory) {
        return PoolFactory.MarketConfig({tokenId: id, decimals: dec});
    }

    function _mintAndApprove(address user) internal {
        uint256 bigA = 100_000_000 * MARKET_A_DEC_RAW;
        uint256 bigB = 100_000_000 * MARKET_B_DEC_RAW;
        marketAToken.mint(user, MARKET_A_ID, bigA);
        marketBToken.mint(user, MARKET_B_ID, bigB);
        vm.startPrank(user);
        marketAToken.setApprovalForAll(address(pool), true);
        marketBToken.setApprovalForAll(address(pool), true);
        vm.stopPrank();
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

    function _computeFees(uint256 normAmount) internal pure returns (uint256 lpFee, uint256 protocolFee) {
        uint256 totalBps = LP_FEE_BPS + PROTOCOL_FEE_BPS;
        if (totalBps == 0 || normAmount == 0) return (0, 0);
        uint256 totalFee = (normAmount * totalBps + FEE_DEN - 1) / FEE_DEN;
        protocolFee = PROTOCOL_FEE_BPS > 0 ? (totalFee * PROTOCOL_FEE_BPS) / totalBps : 0;
        lpFee = totalFee - protocolFee;
    }

    // ─── Stateless Fuzz: Deposit ──────────────────────────────────────────────

    function testFuzz_Deposit_FirstDeposit1to1(uint256 amount) public {
        amount = bound(amount, 1 * MARKET_A_DEC_RAW, 10_000_000 * MARKET_A_DEC_RAW);
        vm.prank(lp1);
        uint256 minted = pool.deposit(SwapPool.Side.MARKET_A, amount);
        assertEq(minted, _toNorm(amount, MARKET_A_DEC), "first deposit 1:1 normalized");
        assertEq(pool.aSideValue(), _toNorm(amount, MARKET_A_DEC));
        _assertValueInvariant();
    }

    function testFuzz_Deposit_SecondDepositorGetsProportionalLP(uint256 dep1, uint256 dep2) public {
        dep1 = bound(dep1, 1 * MARKET_A_DEC_RAW, 50_000_000 * MARKET_A_DEC_RAW);
        dep2 = bound(dep2, 1 * MARKET_A_DEC_RAW, 50_000_000 * MARKET_A_DEC_RAW);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, dep1);

        uint256 supplyBefore = marketALpToken.totalSupply(lpIdA);
        uint256 valueBefore = pool.aSideValue();

        vm.prank(lp2);
        uint256 minted = pool.deposit(SwapPool.Side.MARKET_A, dep2);

        uint256 expected = (_toNorm(dep2, MARKET_A_DEC) * supplyBefore) / valueBefore;
        assertEq(minted, expected, "proportional mint");
        _assertValueInvariant();
    }

    function testFuzz_Deposit_BothSidesIndependent(uint256 depA, uint256 depB) public {
        depA = bound(depA, 1 * MARKET_A_DEC_RAW, 50_000_000 * MARKET_A_DEC_RAW);
        depB = bound(depB, 1 * MARKET_B_DEC_RAW, 50_000_000 * MARKET_B_DEC_RAW);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, depA);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, depB);

        assertEq(pool.aSideValue(), _toNorm(depA, MARKET_A_DEC));
        assertEq(pool.bSideValue(), _toNorm(depB, MARKET_B_DEC));
        _assertValueInvariant();
    }

    // ─── Stateless Fuzz: Fee Math ─────────────────────────────────────────────

    function testFuzz_FeeCalc_CeilingRound(uint256 amount) public view {
        amount = bound(amount, 1, 100_000_000 ether);

        uint256 totalBps = LP_FEE_BPS + PROTOCOL_FEE_BPS;
        uint256 expectedTotal = (amount * totalBps + FEE_DEN - 1) / FEE_DEN;

        (uint256 lpFee, uint256 protocolFee) = _computeFees(amount);
        uint256 actualTotal = lpFee + protocolFee;

        assertEq(actualTotal, expectedTotal, "total fee matches ceiling formula");
        assertLe(actualTotal, amount, "fee <= amount");
        assertTrue(lpFee >= protocolFee, "lp fee >= proto fee (30 vs 10 bps)");
    }

    function testFuzz_FeeCalc_SplitConsistency(uint256 amount) public view {
        amount = bound(amount, 1, 100_000_000 ether);
        (uint256 lpFee, uint256 protocolFee) = _computeFees(amount);
        uint256 payout = amount - lpFee - protocolFee;
        assertEq(payout + lpFee + protocolFee, amount, "amount = payout + fees");
    }

    // ─── Stateless Fuzz: Swap ─────────────────────────────────────────────────

    function testFuzz_Swap_OutputCorrectness(uint256 liqUnits, uint256 swapUnits) public {
        liqUnits  = bound(liqUnits, 10, 10_000_000);
        swapUnits = bound(swapUnits, 1, liqUnits / 2);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, liqUnits * MARKET_A_DEC_RAW);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, liqUnits * MARKET_B_DEC_RAW);

        uint256 rawSwapA = swapUnits * MARKET_A_DEC_RAW;
        uint256 normIn = _toNorm(rawSwapA, MARKET_A_DEC);
        (uint256 lpFee, uint256 protocolFee) = _computeFees(normIn);
        uint256 expectedOut = _fromNorm(normIn - lpFee - protocolFee, MARKET_B_DEC);

        vm.prank(swapper);
        uint256 out = pool.swap(SwapPool.Side.MARKET_A, rawSwapA);

        assertEq(out, expectedOut, "output matches expected");
        _assertValueInvariant();
    }

    function testFuzz_Swap_DrainedSideRateGrows(uint256 liqUnits, uint256 swapUnits) public {
        liqUnits  = bound(liqUnits, 10, 10_000_000);
        swapUnits = bound(swapUnits, 1, liqUnits / 2);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, liqUnits * MARKET_A_DEC_RAW);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, liqUnits * MARKET_B_DEC_RAW);

        uint256 bRateBefore = pool.marketBRate();
        uint256 aRateBefore = pool.marketARate();

        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_A, swapUnits * MARKET_A_DEC_RAW);

        assertGe(pool.marketBRate(), bRateBefore, "drained side rate non-decreasing");
        assertEq(pool.marketARate(), aRateBefore, "non-drained side unchanged");
    }

    function testFuzz_Swap_SymmetricFees(uint256 liqUnits, uint256 swapUnits) public {
        liqUnits  = bound(liqUnits, 10, 10_000_000);
        swapUnits = bound(swapUnits, 1, liqUnits / 2);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, liqUnits * MARKET_A_DEC_RAW);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, liqUnits * MARKET_B_DEC_RAW);

        uint256 snap = vm.snapshotState();

        uint256 normSwap = swapUnits * 1 ether;

        vm.prank(swapper);
        uint256 outAtoBRaw = pool.swap(SwapPool.Side.MARKET_A, _fromNorm(normSwap, MARKET_A_DEC));
        uint256 outAtoBNorm = _toNorm(outAtoBRaw, MARKET_B_DEC);

        vm.revertToState(snap);

        vm.prank(swapper);
        uint256 outBtoARaw = pool.swap(SwapPool.Side.MARKET_B, _fromNorm(normSwap, MARKET_B_DEC));
        uint256 outBtoANorm = _toNorm(outBtoARaw, MARKET_A_DEC);

        uint256 minDec = MARKET_A_DEC < MARKET_B_DEC ? MARKET_A_DEC : MARKET_B_DEC;
        uint256 tolerance = 10 ** (18 - minDec);
        assertApproxEqAbs(outAtoBNorm, outBtoANorm, tolerance, "symmetric fees in normalized terms");
    }

    // ─── Stateless Fuzz: Withdrawal ───────────────────────────────────────────

    function testFuzz_Withdrawal_SameSideMaturedNoFee(uint256 depUnits) public {
        depUnits = bound(depUnits, 1, 10_000_000);

        uint256 depA = depUnits * MARKET_A_DEC_RAW;
        uint256 depB = depUnits * MARKET_B_DEC_RAW;

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, depA);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, depB);

        skip(25 hours);

        uint256 lpBal = marketALpToken.balanceOf(lp1, lpIdA);
        uint256 balBefore = marketAToken.balanceOf(lp1, MARKET_A_ID);
        uint256 fcBefore = marketAToken.balanceOf(address(feeCollector), MARKET_A_ID);

        vm.prank(lp1);
        pool.withdrawal(SwapPool.Side.MARKET_A, lpBal, SwapPool.Side.MARKET_A);

        assertEq(marketAToken.balanceOf(lp1, MARKET_A_ID) - balBefore, depA, "full claim matured");
        assertEq(marketAToken.balanceOf(address(feeCollector), MARKET_A_ID), fcBefore, "no fee matured");
        _assertValueInvariant();
    }

    function testFuzz_Withdrawal_DepositWithdrawNoProfit(uint256 depUnits) public {
        depUnits = bound(depUnits, 1, 10_000_000);

        uint256 depA = depUnits * MARKET_A_DEC_RAW;
        uint256 depB = depUnits * MARKET_B_DEC_RAW;

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, depA);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, depB);

        uint256 lpBal = marketALpToken.balanceOf(lp1, lpIdA);
        uint256 balBefore = marketAToken.balanceOf(lp1, MARKET_A_ID);

        vm.prank(lp1);
        pool.withdrawal(SwapPool.Side.MARKET_A, lpBal, SwapPool.Side.MARKET_A);

        uint256 returned = marketAToken.balanceOf(lp1, MARKET_A_ID) - balBefore;
        assertLe(returned, depA, "cannot profit from deposit+withdraw without swaps");
        _assertValueInvariant();
    }

    function testFuzz_Withdrawal_CrossSideUnresolvedPaysFullFee(uint256 depUnits) public {
        depUnits = bound(depUnits, 1, 10_000_000);

        uint256 depA = depUnits * MARKET_A_DEC_RAW;
        uint256 depB = depUnits * MARKET_B_DEC_RAW;

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, depA);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, depB);

        skip(25 hours);

        uint256 lpBal = marketALpToken.balanceOf(lp1, lpIdA);
        uint256 bBefore = marketBToken.balanceOf(lp1, MARKET_B_ID);

        vm.prank(lp1);
        pool.withdrawal(SwapPool.Side.MARKET_B, lpBal, SwapPool.Side.MARKET_A);

        uint256 returned = marketBToken.balanceOf(lp1, MARKET_B_ID) - bBefore;
        uint256 expectedMax = (depB * (FEE_DEN - TOTAL_FEE_BPS)) / FEE_DEN;
        assertLe(returned, expectedMax + 1, "cross-side pays fee");
        assertGt(returned, 0, "non-zero return");
        _assertValueInvariant();
    }

    // ─── Stateless Fuzz: WithdrawProRata ──────────────────────────────────────

    function testFuzz_ProRata_NeverOverpays(uint256 depAUnits, uint256 depBUnits, uint256 swapUnits) public {
        depAUnits = bound(depAUnits, 10, 10_000_000);
        depBUnits = bound(depBUnits, 10, 10_000_000);
        uint256 maxSwap = depBUnits < depAUnits ? depBUnits : depAUnits;
        swapUnits = bound(swapUnits, 1, maxSwap / 2);

        uint256 depA = depAUnits * MARKET_A_DEC_RAW;
        uint256 depB = depBUnits * MARKET_B_DEC_RAW;

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, depA);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, depB);

        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_A, swapUnits * MARKET_A_DEC_RAW);

        vm.prank(operator);
        factory.setPoolSwapsPaused(0, true);

        uint256 lpBal = marketALpToken.balanceOf(lp1, lpIdA);
        uint256 aBefore = marketAToken.balanceOf(lp1, MARKET_A_ID);
        uint256 bBefore = marketBToken.balanceOf(lp1, MARKET_B_ID);

        vm.prank(lp1);
        pool.withdrawProRata(lpBal, SwapPool.Side.MARKET_A);

        uint256 gotA = marketAToken.balanceOf(lp1, MARKET_A_ID) - aBefore;
        uint256 gotB = marketBToken.balanceOf(lp1, MARKET_B_ID) - bBefore;

        uint256 gotNorm = _toNorm(gotA, MARKET_A_DEC) + _toNorm(gotB, MARKET_B_DEC);
        uint256 maxNorm = _toNorm(depA, MARKET_A_DEC) + _toNorm(swapUnits * MARKET_A_DEC_RAW, MARKET_A_DEC);
        assertLe(gotNorm, maxNorm, "pro-rata total <= deposited + possible swap gains (normalized)");
        _assertValueInvariant();
    }

    function testFuzz_ProRata_NoFees(uint256 depUnits) public {
        depUnits = bound(depUnits, 1, 10_000_000);

        uint256 depA = depUnits * MARKET_A_DEC_RAW;
        uint256 depB = depUnits * MARKET_B_DEC_RAW;

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, depA);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, depB);

        vm.prank(operator);
        factory.setPoolSwapsPaused(0, true);

        uint256 fcABefore = marketAToken.balanceOf(address(feeCollector), MARKET_A_ID);
        uint256 fcBBefore = marketBToken.balanceOf(address(feeCollector), MARKET_B_ID);

        uint256 lpBal = marketALpToken.balanceOf(lp1, lpIdA);
        vm.prank(lp1);
        pool.withdrawProRata(lpBal, SwapPool.Side.MARKET_A);

        assertEq(marketAToken.balanceOf(address(feeCollector), MARKET_A_ID), fcABefore, "no A fee");
        assertEq(marketBToken.balanceOf(address(feeCollector), MARKET_B_ID), fcBBefore, "no B fee");
        _assertValueInvariant();
    }

    // ─── Stateless Fuzz: JIT Lock ─────────────────────────────────────────────

    function testFuzz_Lock_WeightedAvgTimestamp(uint256 amt1Units, uint256 amt2Units, uint256 gap) public {
        amt1Units = bound(amt1Units, 1, 10_000_000);
        amt2Units = bound(amt2Units, 1, 10_000_000);
        gap       = bound(gap, 1, 23 hours);

        uint256 t0 = 1_000_000;
        vm.warp(t0);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, amt1Units * MARKET_A_DEC_RAW);

        vm.warp(t0 + gap);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, amt2Units * MARKET_A_DEC_RAW);

        (, uint256 ts) = marketALpToken.freshDeposit(lp1, lpIdA);

        assertGe(ts, t0, "weighted avg >= first deposit time");
        assertLe(ts, t0 + gap, "weighted avg <= second deposit time");
    }

    function testFuzz_Lock_MaturationAfter24h(uint256 amtUnits, uint256 extraTime) public {
        amtUnits  = bound(amtUnits, 1, 10_000_000);
        extraTime = bound(extraTime, 1, 365 days);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, amtUnits * MARKET_A_DEC_RAW);

        assertTrue(marketALpToken.isLocked(lp1, lpIdA), "locked initially");

        skip(24 hours + extraTime);

        assertFalse(marketALpToken.isLocked(lp1, lpIdA), "matured after 24h");
        assertEq(marketALpToken.lockedAmount(lp1, lpIdA), 0, "locked amount = 0");
    }

    function testFuzz_Lock_TransferAlwaysFresh(uint256 depUnits, uint256 transferAmt) public {
        depUnits = bound(depUnits, 2, 10_000_000);
        uint256 dep = depUnits * MARKET_A_DEC_RAW;
        uint256 normDep = _toNorm(dep, MARKET_A_DEC);
        transferAmt = bound(transferAmt, 1, normDep);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, dep);

        skip(25 hours);
        assertEq(marketALpToken.lockedAmount(lp1, lpIdA), 0, "matured");

        uint256 transferTime = block.timestamp;
        vm.prank(lp1);
        marketALpToken.safeTransferFrom(lp1, lp2, lpIdA, transferAmt, "");

        assertEq(marketALpToken.lockedAmount(lp2, lpIdA), transferAmt, "transfer always fresh");
        (, uint256 ts) = marketALpToken.freshDeposit(lp2, lpIdA);
        assertEq(ts, transferTime, "fresh timestamp = transfer time");
    }

    // ─── Stateless Fuzz: Multi-operation Conservation ─────────────────────────

    function testFuzz_Conservation_DepositSwapWithdraw(
        uint256 depAUnits, uint256 depBUnits, uint256 swapUnits, bool swapDirection
    ) public {
        depAUnits = bound(depAUnits, 10, 10_000_000);
        depBUnits = bound(depBUnits, 10, 10_000_000);
        uint256 maxSwap = depBUnits < depAUnits ? depBUnits : depAUnits;
        swapUnits = bound(swapUnits, 1, maxSwap / 2);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, depAUnits * MARKET_A_DEC_RAW);
        _assertValueInvariant();

        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, depBUnits * MARKET_B_DEC_RAW);
        _assertValueInvariant();

        SwapPool.Side fromSide = swapDirection ? SwapPool.Side.MARKET_A : SwapPool.Side.MARKET_B;
        uint256 rawSwap = swapDirection
            ? swapUnits * MARKET_A_DEC_RAW
            : swapUnits * MARKET_B_DEC_RAW;
        vm.prank(swapper);
        pool.swap(fromSide, rawSwap);
        _assertValueInvariant();

        skip(25 hours);

        uint256 lpBal = marketALpToken.balanceOf(lp1, lpIdA);
        if (lpBal > 0) {
            uint256 shares = (lpBal * pool.marketARate()) / 1e18;
            uint256 physA = pool.physicalBalanceNorm(SwapPool.Side.MARKET_A);
            if (shares <= physA) {
                vm.prank(lp1);
                pool.withdrawal(SwapPool.Side.MARKET_A, lpBal, SwapPool.Side.MARKET_A);
                _assertValueInvariant();
            }
        }
    }

    // ─── Stateless Fuzz: Rate Monotonicity ────────────────────────────────────

    function testFuzz_Rate_NeverDecreasesFromSwaps(
        uint256 liqUnits, uint256 swap1Units, uint256 swap2Units
    ) public {
        liqUnits   = bound(liqUnits, 100, 10_000_000);
        swap1Units = bound(swap1Units, 1, liqUnits / 4);
        swap2Units = bound(swap2Units, 1, liqUnits / 4);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, liqUnits * MARKET_A_DEC_RAW);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, liqUnits * MARKET_B_DEC_RAW);

        uint256 rateA0 = pool.marketARate();
        uint256 rateB0 = pool.marketBRate();

        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_A, swap1Units * MARKET_A_DEC_RAW);

        uint256 rateA1 = pool.marketARate();
        uint256 rateB1 = pool.marketBRate();
        assertEq(rateA1, rateA0, "A rate unchanged after A-to-B swap");
        assertGe(rateB1, rateB0, "B rate grew after A-to-B swap");

        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_B, swap2Units * MARKET_B_DEC_RAW);

        assertGe(pool.marketARate(), rateA1, "A rate grew after B-to-A swap");
        assertEq(pool.marketBRate(), rateB1, "B rate unchanged after B-to-A swap");
    }

    // ─── Stateless Fuzz: Full Drain & Refill ──────────────────────────────────

    function testFuzz_FlushResidual_FullExit(uint256 depAUnits, uint256 depBUnits, uint256 swapUnits) public {
        depAUnits = bound(depAUnits, 4, 1_000_000);
        depBUnits = bound(depBUnits, 4, 1_000_000);
        uint256 maxSwap = depBUnits < depAUnits ? depBUnits : depAUnits;
        swapUnits = bound(swapUnits, 1, maxSwap / 3);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, depAUnits * MARKET_A_DEC_RAW);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, depBUnits * MARKET_B_DEC_RAW);

        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_A, swapUnits * MARKET_A_DEC_RAW);

        vm.prank(operator);
        factory.setPoolSwapsPaused(0, true);

        uint256 lpBalA = marketALpToken.balanceOf(lp1, lpIdA);
        uint256 lpBalB = marketBLpToken.balanceOf(lp2, lpIdB);

        vm.prank(lp1);
        pool.withdrawProRata(lpBalA, SwapPool.Side.MARKET_A);
        vm.prank(lp2);
        pool.withdrawProRata(lpBalB, SwapPool.Side.MARKET_B);

        assertEq(marketALpToken.totalSupply(lpIdA), 0, "A supply zero");
        assertEq(marketBLpToken.totalSupply(lpIdB), 0, "B supply zero");
        assertEq(pool.aSideValue(), 0, "aSideValue zero");
        assertEq(pool.bSideValue(), 0, "bSideValue zero");
        assertEq(marketAToken.balanceOf(address(pool), MARKET_A_ID), 0, "pool A clean");
        assertEq(marketBToken.balanceOf(address(pool), MARKET_B_ID), 0, "pool B clean");
    }
}
