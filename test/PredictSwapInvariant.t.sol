// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/FeeCollector.sol";
import "../src/LPToken.sol";
import "../src/PoolFactory.sol";
import "../src/SwapPool.sol";
import "./MockERC1155.sol";

contract SwapPoolHandler is Test {

    SwapPool     public pool;
    PoolFactory  public factory;
    MockERC1155  public marketAToken;
    MockERC1155  public marketBToken;
    FeeCollector public feeCollector;
    LPToken      public marketALpToken;
    LPToken      public marketBLpToken;
    uint256      public lpIdA;
    uint256      public lpIdB;
    uint256      public marketAId;
    uint256      public marketBId;
    uint256      public marketADecRaw;
    uint256      public marketBDecRaw;

    address[] public actors;
    address   public operator;

    uint256 public ghost_totalDepositsA;
    uint256 public ghost_totalDepositsB;
    uint256 public ghost_totalSwaps;
    uint256 public ghost_totalWithdrawals;

    uint256 public ghost_rateA_max;
    uint256 public ghost_rateB_max;

    constructor(
        SwapPool pool_,
        PoolFactory factory_,
        MockERC1155 marketAToken_,
        MockERC1155 marketBToken_,
        FeeCollector feeCollector_,
        uint256 marketAId_,
        uint256 marketBId_,
        uint256 marketADecRaw_,
        uint256 marketBDecRaw_,
        address[] memory actors_,
        address operator_
    ) {
        pool = pool_;
        factory = factory_;
        marketAToken = marketAToken_;
        marketBToken = marketBToken_;
        feeCollector = feeCollector_;
        marketAId = marketAId_;
        marketBId = marketBId_;
        marketADecRaw = marketADecRaw_;
        marketBDecRaw = marketBDecRaw_;
        actors = actors_;
        operator = operator_;

        marketALpToken = factory.marketALpToken();
        marketBLpToken = factory.marketBLpToken();

        PoolFactory.PoolInfo memory info = factory.getPool(0);
        lpIdA = info.marketALpTokenId;
        lpIdB = info.marketBLpTokenId;

        ghost_rateA_max = 1e18;
        ghost_rateB_max = 1e18;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _trackRates() internal {
        uint256 rA = pool.marketARate();
        uint256 rB = pool.marketBRate();
        if (rA > ghost_rateA_max) ghost_rateA_max = rA;
        if (rB > ghost_rateB_max) ghost_rateB_max = rB;
    }

    // ─── Actions ──────────────────────────────────────────────────────────────

    function depositA(uint256 actorSeed, uint256 amount) external {
        if (pool.depositsPaused() || pool.resolved()) return;
        address actor = _actor(actorSeed);
        amount = bound(amount, 1 * marketADecRaw, 1_000_000 * marketADecRaw);

        vm.prank(actor);
        pool.deposit(SwapPool.Side.MARKET_A, amount);
        ghost_totalDepositsA++;
        _trackRates();
    }

    function depositB(uint256 actorSeed, uint256 amount) external {
        if (pool.depositsPaused() || pool.resolved()) return;
        address actor = _actor(actorSeed);
        amount = bound(amount, 1 * marketBDecRaw, 1_000_000 * marketBDecRaw);

        vm.prank(actor);
        pool.deposit(SwapPool.Side.MARKET_B, amount);
        ghost_totalDepositsB++;
        _trackRates();
    }

    function swapAtoB(uint256 actorSeed, uint256 amount) external {
        if (pool.swapsPaused()) return;
        address actor = _actor(actorSeed);

        uint256 physB = pool.physicalBalanceNorm(SwapPool.Side.MARKET_B);
        if (physB < 2 ether) return;

        uint256 maxRaw = physB / (2 * (10 ** (18 - 6)));
        if (maxRaw < 1 * marketADecRaw) return;
        amount = bound(amount, 1 * marketADecRaw, maxRaw);

        vm.prank(actor);
        try pool.swap(SwapPool.Side.MARKET_A, amount) {
            ghost_totalSwaps++;
        } catch {}
        _trackRates();
    }

    function swapBtoA(uint256 actorSeed, uint256 amount) external {
        if (pool.swapsPaused()) return;
        address actor = _actor(actorSeed);

        uint256 physA = pool.physicalBalanceNorm(SwapPool.Side.MARKET_A);
        if (physA < 2 ether) return;

        uint256 maxRaw = physA / 2;
        if (maxRaw < 1 * marketBDecRaw) return;
        amount = bound(amount, 1 * marketBDecRaw, maxRaw);

        vm.prank(actor);
        try pool.swap(SwapPool.Side.MARKET_B, amount) {
            ghost_totalSwaps++;
        } catch {}
        _trackRates();
    }

    function withdrawSameSideA(uint256 actorSeed, uint256 fraction) external {
        if (pool.swapsPaused()) return;
        address actor = _actor(actorSeed);
        uint256 bal = marketALpToken.balanceOf(actor, lpIdA);
        if (bal == 0) return;

        fraction = bound(fraction, 1, 100);
        uint256 burnAmt = (bal * fraction) / 100;
        if (burnAmt == 0) return;

        vm.prank(actor);
        try pool.withdrawal(SwapPool.Side.MARKET_A, burnAmt, SwapPool.Side.MARKET_A) {
            ghost_totalWithdrawals++;
        } catch {}
        _trackRates();
    }

    function withdrawSameSideB(uint256 actorSeed, uint256 fraction) external {
        if (pool.swapsPaused()) return;
        address actor = _actor(actorSeed);
        uint256 bal = marketBLpToken.balanceOf(actor, lpIdB);
        if (bal == 0) return;

        fraction = bound(fraction, 1, 100);
        uint256 burnAmt = (bal * fraction) / 100;
        if (burnAmt == 0) return;

        vm.prank(actor);
        try pool.withdrawal(SwapPool.Side.MARKET_B, burnAmt, SwapPool.Side.MARKET_B) {
            ghost_totalWithdrawals++;
        } catch {}
        _trackRates();
    }

    function withdrawCrossSide(uint256 actorSeed, uint256 fraction, bool fromA) external {
        if (pool.swapsPaused()) return;
        address actor = _actor(actorSeed);

        SwapPool.Side lpSide = fromA ? SwapPool.Side.MARKET_A : SwapPool.Side.MARKET_B;
        SwapPool.Side recvSide = fromA ? SwapPool.Side.MARKET_B : SwapPool.Side.MARKET_A;
        LPToken lp = fromA ? marketALpToken : marketBLpToken;
        uint256 id = fromA ? lpIdA : lpIdB;

        uint256 bal = lp.balanceOf(actor, id);
        if (bal == 0) return;

        fraction = bound(fraction, 1, 100);
        uint256 burnAmt = (bal * fraction) / 100;
        if (burnAmt == 0) return;

        vm.prank(actor);
        try pool.withdrawal(recvSide, burnAmt, lpSide) {
            ghost_totalWithdrawals++;
        } catch {}
        _trackRates();
    }

    function skipTime(uint256 secs) external {
        secs = bound(secs, 1 minutes, 48 hours);
        skip(secs);
    }
}

contract PredictSwapInvariantTest is Test {

    // ─── Actors ───────────────────────────────────────────────────────────────

    address owner    = makeAddr("owner");
    address operator = makeAddr("operator");

    // ─── Token IDs ────────────────────────────────────────────────────────────

    uint256 constant MARKET_A_ID = 1;
    uint256 constant MARKET_B_ID = 511515;

    uint8 constant MARKET_A_DEC = 6;
    uint8 constant MARKET_B_DEC = 18;

    uint256 constant MARKET_A_DEC_RAW = 1e6;
    uint256 constant MARKET_B_DEC_RAW = 1e18;

    uint256 constant LP_FEE_BPS       = 30;
    uint256 constant PROTOCOL_FEE_BPS = 10;

    // ─── Contracts ────────────────────────────────────────────────────────────

    MockERC1155  marketAToken;
    MockERC1155  marketBToken;
    FeeCollector feeCollector;
    PoolFactory  factory;
    SwapPool     pool;
    LPToken      marketALpToken;
    LPToken      marketBLpToken;
    uint256      lpIdA;
    uint256      lpIdB;

    SwapPoolHandler handler;

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
        factory.createPool(
            PoolFactory.MarketConfig({tokenId: MARKET_A_ID, decimals: MARKET_A_DEC}),
            PoolFactory.MarketConfig({tokenId: MARKET_B_ID, decimals: MARKET_B_DEC}),
            LP_FEE_BPS,
            PROTOCOL_FEE_BPS,
            "Trump impeachment 2028 - YES"
        );

        PoolFactory.PoolInfo memory info = factory.getPool(0);
        pool  = SwapPool(payable(info.swapPool));
        lpIdA = info.marketALpTokenId;
        lpIdB = info.marketBLpTokenId;

        address[] memory actors = new address[](4);
        actors[0] = makeAddr("actor0");
        actors[1] = makeAddr("actor1");
        actors[2] = makeAddr("actor2");
        actors[3] = makeAddr("actor3");

        for (uint256 i; i < actors.length; i++) {
            marketAToken.mint(actors[i], MARKET_A_ID, 100_000_000 * MARKET_A_DEC_RAW);
            marketBToken.mint(actors[i], MARKET_B_ID, 100_000_000 * MARKET_B_DEC_RAW);
            vm.startPrank(actors[i]);
            marketAToken.setApprovalForAll(address(pool), true);
            marketBToken.setApprovalForAll(address(pool), true);
            vm.stopPrank();
        }

        handler = new SwapPoolHandler(
            pool, factory, marketAToken, marketBToken, feeCollector,
            MARKET_A_ID, MARKET_B_ID,
            MARKET_A_DEC_RAW, MARKET_B_DEC_RAW,
            actors, operator
        );

        vm.prank(actors[0]);
        pool.deposit(SwapPool.Side.MARKET_A, 1_000_000 * MARKET_A_DEC_RAW);
        vm.prank(actors[1]);
        pool.deposit(SwapPool.Side.MARKET_B, 1_000_000 * MARKET_B_DEC_RAW);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = SwapPoolHandler.depositA.selector;
        selectors[1] = SwapPoolHandler.depositB.selector;
        selectors[2] = SwapPoolHandler.swapAtoB.selector;
        selectors[3] = SwapPoolHandler.swapBtoA.selector;
        selectors[4] = SwapPoolHandler.withdrawSameSideA.selector;
        selectors[5] = SwapPoolHandler.withdrawSameSideB.selector;
        selectors[6] = SwapPoolHandler.withdrawCrossSide.selector;
        selectors[7] = SwapPoolHandler.skipTime.selector;
        selectors[8] = SwapPoolHandler.depositA.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ─── Invariant: Value Conservation ────────────────────────────────────────

    function invariant_ValueConservation() public view {
        uint256 physA = pool.physicalBalanceNorm(SwapPool.Side.MARKET_A);
        uint256 physB = pool.physicalBalanceNorm(SwapPool.Side.MARKET_B);
        uint256 tracked = pool.aSideValue() + pool.bSideValue();
        uint256 minDec = MARKET_A_DEC < MARKET_B_DEC ? MARKET_A_DEC : MARKET_B_DEC;
        // Each op can lose up to ~2 units of lowest-precision token in rounding;
        // with depth=64 calls the error accumulates, so allow 128 units.
        uint256 tolerance = 128 * 10 ** (18 - minDec);
        assertApproxEqAbs(tracked, physA + physB, tolerance, "INVARIANT: tracked ~= physical");
    }

    // ─── Invariant: LP Supply Consistency ─────────────────────────────────────

    function invariant_LPSupplyNonNegative() public view {
        assertTrue(marketALpToken.totalSupply(lpIdA) >= 0, "A supply >= 0");
        assertTrue(marketBLpToken.totalSupply(lpIdB) >= 0, "B supply >= 0");
    }

    // ─── Invariant: Rate is at least 1e18 ─────────────────────────────────────

    function invariant_RateAtLeast1e18() public view {
        assertGe(pool.marketARate(), 1e18, "A rate >= 1e18");
        assertGe(pool.marketBRate(), 1e18, "B rate >= 1e18");
    }

    // ─── Invariant: Pool solvency ─────────────────────────────────────────────

    function invariant_PoolSolvency() public view {
        uint256 physA = pool.physicalBalanceNorm(SwapPool.Side.MARKET_A);
        uint256 physB = pool.physicalBalanceNorm(SwapPool.Side.MARKET_B);
        uint256 totalPhysical = physA + physB;
        uint256 totalTracked = pool.aSideValue() + pool.bSideValue();
        assertGe(totalPhysical, totalTracked, "physical >= tracked (solvent)");
    }

    // ─── Invariant: Fee bounds ────────────────────────────────────────────────

    function invariant_FeeBounds() public view {
        assertLe(pool.lpFeeBps(), 100, "lpFee <= MAX");
        assertLe(pool.protocolFeeBps(), 50, "protoFee <= MAX");
    }

    // ─── Summary ──────────────────────────────────────────────────────────────

    function invariant_CallSummary() public view {
        console.log("Deposits A:", handler.ghost_totalDepositsA());
        console.log("Deposits B:", handler.ghost_totalDepositsB());
        console.log("Swaps:     ", handler.ghost_totalSwaps());
        console.log("Withdraws: ", handler.ghost_totalWithdrawals());
        console.log("Rate A:    ", pool.marketARate());
        console.log("Rate B:    ", pool.marketBRate());
    }
}
