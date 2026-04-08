// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/FeeCollector.sol";
import "../src/LPToken.sol";
import "../src/PoolFactory.sol";
import "../src/SwapPool.sol";
import "./MockERC1155.sol";

/**
 * @title PredictSwap Test Suite
 *
 * Covers:
 *   FeeCollector  — recordFee, withdraw, withdrawAll, withdrawAllBatch, access control
 *   LPToken       — setPool, mint, burn, access control
 *   PoolFactory   — createPool, registry reads, setPoolFees, resolve/unresolve,
 *                   approveMarketContract, operator role
 *   SwapPool      — deposit, withdrawSingleSide (same-side / cross-side / resolved),
 *                   withdrawBothSides, swap, exchange rate, fee math, rescue, pausing,
 *                   decimal normalization, per-pool fees, metadata
 */
contract PredictSwapTest is Test {

    // ─── Actors ───────────────────────────────────────────────────────────────

    address owner    = makeAddr("owner");
    address operator = makeAddr("operator");
    address lp1      = makeAddr("lp1");
    address lp2      = makeAddr("lp2");
    address swapper  = makeAddr("swapper");
    address attacker = makeAddr("attacker");

    // ─── Token IDs ────────────────────────────────────────────────────────────

    uint256 constant MARKET_A_ID = 1;
    uint256 constant MARKET_B_ID = 511515;

    // ─── Contracts ────────────────────────────────────────────────────────────

    MockERC1155  marketAToken;
    MockERC1155  marketBToken;
    FeeCollector feeCollector;
    PoolFactory  factory;
    SwapPool     pool;
    LPToken      marketALp;
    LPToken      marketBLp;

    // ─── Setup ────────────────────────────────────────────────────────────────

    function setUp() public {
        marketAToken = new MockERC1155();
        marketBToken = new MockERC1155();

        vm.startPrank(owner);

        feeCollector = new FeeCollector(owner);
        factory = new PoolFactory(address(feeCollector), operator, owner);

        factory.approveMarketContract(address(marketAToken));
        factory.approveMarketContract(address(marketBToken));

        vm.stopPrank();

        // Operator deploys the pool
        vm.prank(operator);
        uint256 poolId = factory.createPool(
            _marketAConfig(MARKET_A_ID, 18),
            _marketBConfig(MARKET_B_ID, 18),
            30, 10,
            "PredictSwap BTC-YES MarketALP", "PS-BTC-YES-A",
            "PredictSwap BTC-YES MarketBLP", "PS-BTC-YES-B"
        );

        PoolFactory.PoolInfo memory info = factory.getPool(poolId);
        pool      = SwapPool(payable(info.swapPool));
        marketALp = LPToken(info.marketALpToken);
        marketBLp = LPToken(info.marketBLpToken);

        _fundAndApprove(lp1,     10_000, 10_000);
        _fundAndApprove(lp2,     10_000, 10_000);
        _fundAndApprove(swapper,  5_000,  5_000);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _fundAndApprove(address user, uint256 amtA, uint256 amtB) internal {
        marketAToken.mint(user, MARKET_A_ID, amtA);
        marketBToken.mint(user, MARKET_B_ID, amtB);
        vm.startPrank(user);
        marketAToken.setApprovalForAll(address(pool), true);
        marketBToken.setApprovalForAll(address(pool), true);
        vm.stopPrank();
    }

    function _marketAConfig(uint256 tokenId, uint8 decimals) internal view returns (PoolFactory.MarketConfig memory) {
        return PoolFactory.MarketConfig({
            marketContract: address(marketAToken),
            tokenId:        tokenId,
            decimals:       decimals,
            name:           "Polymarket"
        });
    }

    function _marketBConfig(uint256 tokenId, uint8 decimals) internal view returns (PoolFactory.MarketConfig memory) {
        return PoolFactory.MarketConfig({
            marketContract: address(marketBToken),
            tokenId:        tokenId,
            decimals:       decimals,
            name:           "Opinion"
        });
    }

    /// @dev Deploy a second pool with custom decimals for normalization tests.
    ///      Uses different token IDs to avoid duplicate pool key.
    function _createPoolWithDecimals(uint8 decA, uint8 decB) internal returns (SwapPool newPool) {
        vm.prank(operator);
        uint256 pid = factory.createPool(
            _marketAConfig(MARKET_A_ID + 100, decA),
            _marketBConfig(MARKET_B_ID + 100, decB),
            30, 10,
            "Dec Test A LP", "DT-A",
            "Dec Test B LP", "DT-B"
        );
        newPool = SwapPool(payable(factory.getPool(pid).swapPool));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FeeCollector
    // ═══════════════════════════════════════════════════════════════════════════

    function test_FeeCollector_recordFee_emitsEvent() public {
        marketAToken.mint(address(feeCollector), MARKET_A_ID, 100);
        vm.expectEmit(true, true, false, true);
        emit FeeCollector.FeeReceived(address(this), address(marketAToken), MARKET_A_ID, 100);
        feeCollector.recordFee(address(marketAToken), MARKET_A_ID, 100);
    }

    function test_FeeCollector_recordFee_revertsOnZero() public {
        vm.expectRevert(FeeCollector.ZeroAmount.selector);
        feeCollector.recordFee(address(marketAToken), MARKET_A_ID, 0);
    }

    function test_FeeCollector_withdraw_success() public {
        marketAToken.mint(address(feeCollector), MARKET_A_ID, 500);
        vm.prank(owner);
        feeCollector.withdraw(address(marketAToken), MARKET_A_ID, 500, owner);
        assertEq(marketAToken.balanceOf(owner, MARKET_A_ID), 500);
    }

    function test_FeeCollector_withdraw_revertsNonOwner() public {
        marketAToken.mint(address(feeCollector), MARKET_A_ID, 100);
        vm.prank(attacker);
        vm.expectRevert();
        feeCollector.withdraw(address(marketAToken), MARKET_A_ID, 100, attacker);
    }

    function test_FeeCollector_withdraw_revertsZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(FeeCollector.ZeroAmount.selector);
        feeCollector.withdraw(address(marketAToken), MARKET_A_ID, 0, owner);
    }

    function test_FeeCollector_withdrawAll_success() public {
        marketAToken.mint(address(feeCollector), MARKET_A_ID, 300);
        vm.prank(owner);
        feeCollector.withdrawAll(address(marketAToken), MARKET_A_ID, owner);
        assertEq(marketAToken.balanceOf(owner, MARKET_A_ID), 300);
        assertEq(marketAToken.balanceOf(address(feeCollector), MARKET_A_ID), 0);
    }

    function test_FeeCollector_withdrawAll_revertsIfEmpty() public {
        vm.prank(owner);
        vm.expectRevert(FeeCollector.ZeroAmount.selector);
        feeCollector.withdrawAll(address(marketAToken), MARKET_A_ID, owner);
    }

    function test_FeeCollector_withdrawAllBatch_skipsZeroBalanceIds() public {
        MockERC1155 multi = new MockERC1155();
        multi.mint(address(feeCollector), 1, 100);
        // id 2 has zero balance — should not revert
        multi.mint(address(feeCollector), 3, 300);

        uint256[] memory ids = new uint256[](3);
        ids[0] = 1; ids[1] = 2; ids[2] = 3;

        vm.prank(owner);
        feeCollector.withdrawAllBatch(address(multi), ids, owner);

        assertEq(multi.balanceOf(owner, 1), 100);
        assertEq(multi.balanceOf(owner, 2), 0);
        assertEq(multi.balanceOf(owner, 3), 300);
    }

    function test_FeeCollector_withdrawAllBatch_success() public {
        MockERC1155 multi = new MockERC1155();
        multi.mint(address(feeCollector), 1, 100);
        multi.mint(address(feeCollector), 2, 200);
        multi.mint(address(feeCollector), 3, 300);

        uint256[] memory ids = new uint256[](3);
        ids[0] = 1; ids[1] = 2; ids[2] = 3;

        vm.prank(owner);
        feeCollector.withdrawAllBatch(address(multi), ids, owner);

        assertEq(multi.balanceOf(owner, 1), 100);
        assertEq(multi.balanceOf(owner, 2), 200);
        assertEq(multi.balanceOf(owner, 3), 300);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LPToken
    // ═══════════════════════════════════════════════════════════════════════════

    function test_LPToken_setPool_onlyFactory() public {
        LPToken newLp = new LPToken("Test", "T", address(this), MARKET_A_ID);
        newLp.setPool(address(pool));
        assertEq(newLp.pool(), address(pool));
    }

    function test_LPToken_setPool_revertsIfCalledTwice() public {
        LPToken newLp = new LPToken("Test", "T", address(this), MARKET_A_ID);
        newLp.setPool(makeAddr("pool1"));
        vm.expectRevert(LPToken.PoolAlreadySet.selector);
        newLp.setPool(makeAddr("pool2"));
    }

    function test_LPToken_setPool_revertsNonFactory() public {
        LPToken newLp = new LPToken("Test", "T", address(this), MARKET_A_ID);
        vm.prank(attacker);
        vm.expectRevert(LPToken.OnlyFactory.selector);
        newLp.setPool(makeAddr("pool"));
    }

    function test_LPToken_setPool_revertsZeroAddress() public {
        LPToken newLp = new LPToken("Test", "T", address(this), MARKET_A_ID);
        vm.expectRevert(LPToken.ZeroAddress.selector);
        newLp.setPool(address(0));
    }

    function test_LPToken_mint_onlyPool() public {
        vm.prank(attacker);
        vm.expectRevert(LPToken.OnlyPool.selector);
        marketALp.mint(attacker, 100);
    }

    function test_LPToken_burn_onlyPool() public {
        vm.prank(attacker);
        vm.expectRevert(LPToken.OnlyPool.selector);
        marketALp.burn(attacker, 100);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PoolFactory — market contract approval
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Factory_approveMarketContract_success() public {
        MockERC1155 newMarket = new MockERC1155();
        assertFalse(factory.approvedMarketContracts(address(newMarket)));

        vm.prank(owner);
        factory.approveMarketContract(address(newMarket));

        assertTrue(factory.approvedMarketContracts(address(newMarket)));
    }

    function test_Factory_approveMarketContract_revertsNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        factory.approveMarketContract(makeAddr("market"));
    }

    function test_Factory_approveMarketContract_revertsNonOperator() public {
        // Operator cannot approve — owner only
        vm.prank(operator);
        vm.expectRevert();
        factory.approveMarketContract(makeAddr("market"));
    }

    function test_Factory_approveMarketContract_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(PoolFactory.ZeroAddress.selector);
        factory.approveMarketContract(address(0));
    }

    function test_Factory_revokeMarketContract_success() public {
        assertTrue(factory.approvedMarketContracts(address(marketAToken)));

        vm.prank(owner);
        factory.revokeMarketContract(address(marketAToken));

        assertFalse(factory.approvedMarketContracts(address(marketAToken)));
    }

    function test_Factory_revokeMarketContract_existingPoolsUnaffected() public {
        // Revoke after pool is deployed — pool still works
        vm.prank(owner);
        factory.revokeMarketContract(address(marketAToken));

        vm.prank(lp1);
        uint256 minted = pool.deposit(SwapPool.Side.MARKET_A, 1000);
        assertEq(minted, 1000);
    }

    function test_Factory_createPool_revertsUnapprovedMarketA() public {
        MockERC1155 unknown = new MockERC1155();
        PoolFactory.MarketConfig memory bad = PoolFactory.MarketConfig({
            marketContract: address(unknown),
            tokenId: 1,
            decimals: 18,
            name: "Unknown"
        });

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PoolFactory.MarketContractNotApproved.selector, address(unknown)));
        factory.createPool(bad, _marketBConfig(MARKET_B_ID + 1, 18), 30, 10, "A", "A", "B", "B");
    }

    function test_Factory_createPool_revertsUnapprovedMarketB() public {
        MockERC1155 unknown = new MockERC1155();
        PoolFactory.MarketConfig memory bad = PoolFactory.MarketConfig({
            marketContract: address(unknown),
            tokenId: 1,
            decimals: 18,
            name: "Unknown"
        });

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PoolFactory.MarketContractNotApproved.selector, address(unknown)));
        factory.createPool(_marketAConfig(MARKET_A_ID + 1, 18), bad, 30, 10, "A", "A", "B", "B");
    }

    function test_Factory_createPool_revertsMissingMarketAName() public {
        PoolFactory.MarketConfig memory bad = PoolFactory.MarketConfig({
            marketContract: address(marketAToken),
            tokenId: MARKET_A_ID + 1,
            decimals: 18,
            name: ""
        });

        vm.prank(operator);
        vm.expectRevert(PoolFactory.MissingName.selector);
        factory.createPool(bad, _marketBConfig(MARKET_B_ID + 1, 18), 30, 10, "A", "A", "B", "B");
    }

    function test_Factory_createPool_revertsMissingMarketBName() public {
        PoolFactory.MarketConfig memory bad = PoolFactory.MarketConfig({
            marketContract: address(marketBToken),
            tokenId: MARKET_B_ID + 1,
            decimals: 18,
            name: ""
        });

        vm.prank(operator);
        vm.expectRevert(PoolFactory.MissingName.selector);
        factory.createPool(_marketAConfig(MARKET_A_ID + 1, 18), bad, 30, 10, "A", "A", "B", "B");
    }

    function test_Factory_createPool_revertsInvalidDecimalsA() public {
        PoolFactory.MarketConfig memory bad = PoolFactory.MarketConfig({
            marketContract: address(marketAToken),
            tokenId: MARKET_A_ID + 1,
            decimals: 19,
            name: "X"
        });

        vm.prank(operator);
        vm.expectRevert(PoolFactory.InvalidDecimals.selector);
        factory.createPool(bad, _marketBConfig(MARKET_B_ID + 1, 18), 30, 10, "A", "A", "B", "B");
    }

    function test_Factory_createPool_revertsInvalidDecimalsB() public {
        PoolFactory.MarketConfig memory bad = PoolFactory.MarketConfig({
            marketContract: address(marketBToken),
            tokenId: MARKET_B_ID + 1,
            decimals: 19,
            name: "X"
        });

        vm.prank(operator);
        vm.expectRevert(PoolFactory.InvalidDecimals.selector);
        factory.createPool(_marketAConfig(MARKET_A_ID + 1, 18), bad, 30, 10, "A", "A", "B", "B");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PoolFactory — operator role
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Factory_operator_canCreatePool() public {
        vm.prank(operator);
        uint256 pid = factory.createPool(
            _marketAConfig(MARKET_A_ID + 1, 18),
            _marketBConfig(MARKET_B_ID + 1, 18),
            30, 10, "A", "A", "B", "B"
        );
        assertEq(pid, 1);
    }

    function test_Factory_attacker_cannotCreatePool() public {
        vm.prank(attacker);
        vm.expectRevert(PoolFactory.NotOperator.selector);
        factory.createPool(
            _marketAConfig(MARKET_A_ID + 1, 18),
            _marketBConfig(MARKET_B_ID + 1, 18),
            30, 10, "A", "A", "B", "B"
        );
    }

    function test_Factory_owner_canDoOperatorActions() public {
        // Owner can create pools without being the operator
        vm.prank(owner);
        uint256 pid = factory.createPool(
            _marketAConfig(MARKET_A_ID + 1, 18),
            _marketBConfig(MARKET_B_ID + 1, 18),
            30, 10, "A", "A", "B", "B"
        );
        assertEq(pid, 1);
    }

    function test_Factory_operator_canPauseDeposits() public {
        vm.prank(operator);
        factory.setPoolDepositsPaused(0, true);
        assertTrue(pool.depositsPaused());
    }

    function test_Factory_operator_canPauseSwaps() public {
        vm.prank(operator);
        factory.setPoolSwapsPaused(0, true);
        assertTrue(pool.swapsPaused());
    }

    function test_Factory_operator_canResolvePool() public {
        vm.prank(operator);
        factory.resolvePoolAndPausedDeposits(0);
        assertTrue(pool.resolved());
    }

    function test_Factory_operator_canUnresolvePool() public {
        vm.prank(operator);
        factory.resolvePoolAndPausedDeposits(0);
        vm.prank(operator);
        factory.unresolvePool(0);
        assertFalse(pool.resolved());
    }

    function test_Factory_operator_cannotSetPoolFees() public {
        // setPoolFees is owner only
        vm.prank(operator);
        vm.expectRevert();
        factory.setPoolFees(0, 50, 20);
    }

    function test_Factory_operator_cannotRescue() public {
        vm.prank(operator);
        vm.expectRevert();
        factory.rescuePoolETH(0, payable(operator));
    }

    function test_Factory_setOperator_updatesOperator() public {
        address newOperator = makeAddr("newOperator");
        vm.prank(owner);
        factory.setOperator(newOperator);
        assertEq(factory.operator(), newOperator);

        // Old operator can no longer create pools
        vm.prank(operator);
        vm.expectRevert(PoolFactory.NotOperator.selector);
        factory.createPool(
            _marketAConfig(MARKET_A_ID + 1, 18),
            _marketBConfig(MARKET_B_ID + 1, 18),
            30, 10, "A", "A", "B", "B"
        );

        vm.prank(newOperator);
        factory.createPool(
            _marketAConfig(MARKET_A_ID + 1, 18),
            _marketBConfig(MARKET_B_ID + 1, 18),
            30, 10, "A", "A", "B", "B"
        );
    }

    function test_Factory_setOperator_revertsNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        factory.setOperator(attacker);
    }

    function test_Factory_setOperator_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(PoolFactory.ZeroAddress.selector);
        factory.setOperator(address(0));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PoolFactory — pool creation and registry
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Factory_createPool_registersCorrectly() public view {
        PoolFactory.PoolInfo memory info = factory.getPool(0);
        assertEq(info.marketA.tokenId, MARKET_A_ID);
        assertEq(info.marketB.tokenId, MARKET_B_ID);
        assertEq(info.marketA.name, "Polymarket");
        assertEq(info.marketB.name, "Opinion");
        assertTrue(info.swapPool       != address(0));
        assertTrue(info.marketALpToken != address(0));
        assertTrue(info.marketBLpToken != address(0));
    }

    function test_Factory_createPool_twoDistinctLpTokens() public view {
        PoolFactory.PoolInfo memory info = factory.getPool(0);
        assertTrue(info.marketALpToken != info.marketBLpToken);
    }

    function test_Factory_createPool_revertsDuplicate() public {
        vm.prank(operator);
        vm.expectRevert();
        factory.createPool(
            _marketAConfig(MARKET_A_ID, 18),
            _marketBConfig(MARKET_B_ID, 18),
            30, 10, "Dup", "D", "Dup2", "D2"
        );
    }

    function test_Factory_createPool_multiplePools() public {
        vm.startPrank(operator);
        factory.createPool(_marketAConfig(2, 18), _marketBConfig(511516, 18), 30, 10, "P2A", "P2A", "P2B", "P2B");
        factory.createPool(_marketAConfig(3, 18), _marketBConfig(511517, 18), 30, 10, "P3A", "P3A", "P3B", "P3B");
        vm.stopPrank();

        assertEq(factory.poolCount(), 3);
        assertEq(factory.getAllPools().length, 3);
    }

    function test_Factory_findPool_found() public view {
        (bool found, uint256 pid) = factory.findPool(
            address(marketAToken), MARKET_A_ID,
            address(marketBToken), MARKET_B_ID
        );
        assertTrue(found);
        assertEq(pid, 0);
    }

    function test_Factory_findPool_notFound() public view {
        (bool found,) = factory.findPool(address(marketAToken), 999, address(marketBToken), 888);
        assertFalse(found);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PoolFactory — per-pool fees
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Factory_setPoolFees_success() public {
        vm.prank(owner);
        factory.setPoolFees(0, 50, 20);
        assertEq(pool.lpFeeBps(), 50);
        assertEq(pool.protocolFeeBps(), 20);
        assertEq(pool.totalFeeBps(), 70);
    }

    function test_Factory_setPoolFees_revertsAboveLpCap() public {
        vm.prank(owner);
        vm.expectRevert(SwapPool.FeeTooHigh.selector);
        factory.setPoolFees(0, 101, 10);
    }

    function test_Factory_setPoolFees_revertsAboveProtocolCap() public {
        vm.prank(owner);
        vm.expectRevert(SwapPool.FeeTooHigh.selector);
        factory.setPoolFees(0, 50, 51);
    }

    function test_Factory_setPoolFees_canSetZero() public {
        vm.prank(owner);
        factory.setPoolFees(0, 0, 0);
        assertEq(pool.lpFeeBps(), 0);
        assertEq(pool.protocolFeeBps(), 0);
        assertEq(pool.totalFeeBps(), 0);
    }

    function test_Factory_setPoolFees_revertsNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        factory.setPoolFees(0, 10, 5);
    }

    function test_Factory_setPoolFees_independentPerPool() public {
        vm.startPrank(operator);
        uint256 pid2 = factory.createPool(
            _marketAConfig(MARKET_A_ID + 1, 18),
            _marketBConfig(MARKET_B_ID + 1, 18),
            30, 10, "A", "A", "B", "B"
        );
        vm.stopPrank();

        SwapPool pool2 = SwapPool(payable(factory.getPool(pid2).swapPool));

        vm.prank(owner);
        factory.setPoolFees(0, 50, 20);

        // pool2 fee unchanged
        assertEq(pool.lpFeeBps(), 50);
        assertEq(pool2.lpFeeBps(), 30);
    }

    function test_Pool_setFees_revertsNonFactory() public {
        vm.prank(attacker);
        vm.expectRevert(SwapPool.Unauthorized.selector);
        pool.setFees(10, 5);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PoolFactory — pause / resolve
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Factory_pauseDeposits() public {
        vm.prank(operator);
        factory.setPoolDepositsPaused(0, true);
        assertTrue(pool.depositsPaused());

        vm.prank(lp1);
        vm.expectRevert(SwapPool.DepositsPaused.selector);
        pool.deposit(SwapPool.Side.MARKET_A, 100);
    }

    function test_Factory_pauseSwaps() public {
        vm.prank(operator);
        factory.setPoolSwapsPaused(0, true);
        assertTrue(pool.swapsPaused());

        vm.prank(swapper);
        vm.expectRevert(SwapPool.SwapsPaused.selector);
        pool.swap(SwapPool.Side.MARKET_A, 100);
    }

    function test_Factory_resolvePool_pausesDeposits() public {
        vm.prank(operator);
        factory.resolvePoolAndPausedDeposits(0);

        assertTrue(pool.resolved());
        assertTrue(pool.depositsPaused());
    }

    function test_Factory_unresolvePool_resolveFlagOnly() public {
        vm.prank(operator);
        factory.resolvePoolAndPausedDeposits(0);

        vm.prank(operator);
        factory.unresolvePool(0);

        // resolved cleared, but depositsPaused stays — unsetResolved doesn't touch it
        assertFalse(pool.resolved());
        assertTrue(pool.depositsPaused(), "depositsPaused remains after unresolve");
    }

    function test_Factory_resolvePool_revertsIfAlreadyResolved() public {
        vm.prank(operator);
        factory.resolvePoolAndPausedDeposits(0);

        vm.prank(operator);
        vm.expectRevert(SwapPool.AlreadyResolved.selector);
        factory.resolvePoolAndPausedDeposits(0);
    }

    function test_Factory_unresolvePool_revertsIfNotResolved() public {
        vm.prank(operator);
        vm.expectRevert(SwapPool.NotResolved.selector);
        factory.unresolvePool(0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SwapPool — metadata
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Pool_metadata_storedCorrectly() public view {
        assertEq(pool.marketAContract(), address(marketAToken));
        assertEq(pool.marketBContract(), address(marketBToken));
        assertEq(pool.marketATokenId(),  MARKET_A_ID);
        assertEq(pool.marketBTokenId(),  MARKET_B_ID);
        assertEq(pool.marketADecimals(), 18);
        assertEq(pool.marketBDecimals(), 18);
        assertEq(pool.marketAName(),     "Polymarket");
        assertEq(pool.marketBName(),     "Opinion");
        assertEq(pool.lpFeeBps(),        30);
        assertEq(pool.protocolFeeBps(),  10);
    }

    function test_Pool_feesUpdated_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit SwapPool.FeesUpdated(50, 20);
        factory.setPoolFees(0, 50, 20);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SwapPool — Deposit
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Deposit_marketA_mintsMarketALp() public {
        vm.prank(lp1);
        uint256 minted = pool.deposit(SwapPool.Side.MARKET_A, 1000);

        assertEq(minted, 1000);
        assertEq(marketALp.balanceOf(lp1), 1000);
        assertEq(marketBLp.balanceOf(lp1), 0);
        assertEq(pool.marketABalance(), 1000);
    }

    function test_Deposit_marketB_mintsMarketBLp() public {
        vm.prank(lp1);
        uint256 minted = pool.deposit(SwapPool.Side.MARKET_B, 1000);

        assertEq(minted, 1000);
        assertEq(marketBLp.balanceOf(lp1), 1000);
        assertEq(marketALp.balanceOf(lp1), 0);
        assertEq(pool.marketBBalance(), 1000);
    }

    function test_Deposit_firstDepositor_oneToOne() public {
        vm.prank(lp1);
        uint256 minted = pool.deposit(SwapPool.Side.MARKET_A, 1000);

        assertEq(minted, 1000);
        assertEq(pool.totalLpSupply(), 1000);
        assertEq(pool.exchangeRate(), 1e18);
    }

    function test_Deposit_secondDepositor_cleanPool() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 1000);

        vm.prank(lp2);
        uint256 minted = pool.deposit(SwapPool.Side.MARKET_B, 1000);

        assertEq(minted, 1000);
        assertEq(pool.totalLpSupply(), 2000);
        assertEq(pool.totalSharesNorm(), 2000);
    }

    function test_Deposit_secondDepositor_afterFeeAccrual() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 1000);
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_B, 1000);

        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_A, 1000);

        uint256 rateAfter = pool.exchangeRate();
        assertGt(rateAfter, 1e18, "rate should increase after fee");

        vm.prank(lp2);
        uint256 minted = pool.deposit(SwapPool.Side.MARKET_B, 1000);
        assertLt(minted, 1000, "lp2 should get fewer LP tokens after fee accrual");
    }

    function test_Deposit_totalLpSupply_sumsBothTokens() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 600);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, 400);

        assertEq(marketALp.totalSupply(), 600);
        assertEq(marketBLp.totalSupply(), 400);
        assertEq(pool.totalLpSupply(), 1000);
    }

    function test_Deposit_revertsZeroAmount() public {
        vm.prank(lp1);
        vm.expectRevert(SwapPool.ZeroAmount.selector);
        pool.deposit(SwapPool.Side.MARKET_A, 0);
    }

    function test_Deposit_revertsWhenPaused() public {
        vm.prank(operator);
        factory.setPoolDepositsPaused(0, true);

        vm.prank(lp1);
        vm.expectRevert(SwapPool.DepositsPaused.selector);
        pool.deposit(SwapPool.Side.MARKET_A, 100);
    }

    function test_Deposit_emitsEvent() public {
        vm.prank(lp1);
        vm.expectEmit(true, false, false, true);
        emit SwapPool.Deposited(lp1, SwapPool.Side.MARKET_A, 500, 500);
        pool.deposit(SwapPool.Side.MARKET_A, 500);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SwapPool — decimal normalization
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Decimals_6and18_firstDepositNormalized() public {
        SwapPool decPool = _createPoolWithDecimals(6, 18);

        uint256 idA = MARKET_A_ID + 100;
        uint256 idB = MARKET_B_ID + 100;

        marketAToken.mint(lp1, idA, 1_000_000); // 1e6 raw = 1e18 normalized
        vm.startPrank(lp1);
        marketAToken.setApprovalForAll(address(decPool), true);
        vm.stopPrank();

        vm.prank(lp1);
        uint256 minted = decPool.deposit(SwapPool.Side.MARKET_A, 1_000_000);

        // First deposit: lpMinted = normAmount = 1e6 * 1e12 = 1e18
        assertEq(minted, 1e18, "first deposit should mint normalized amount as LP");
        assertEq(decPool.exchangeRate(), 1e18);
    }

    function test_Decimals_6and18_secondDepositProportional() public {
        SwapPool decPool = _createPoolWithDecimals(6, 18);

        uint256 idA = MARKET_A_ID + 100;
        uint256 idB = MARKET_B_ID + 100;

        // Fund and approve
        marketAToken.mint(lp1, idA, 2_000_000);
        marketBToken.mint(lp1, idB, 2e18);
        vm.startPrank(lp1);
        marketAToken.setApprovalForAll(address(decPool), true);
        marketBToken.setApprovalForAll(address(decPool), true);
        vm.stopPrank();

        // First: deposit 1e6 marketA → 1e18 LP minted
        vm.prank(lp1);
        uint256 lpA = decPool.deposit(SwapPool.Side.MARKET_A, 1_000_000);
        assertEq(lpA, 1e18);

        // Second: deposit 1e18 marketB → same normalized value → same LP minted
        vm.prank(lp1);
        uint256 lpB = decPool.deposit(SwapPool.Side.MARKET_B, 1e18);
        assertEq(lpB, 1e18, "1e18 marketB (18 dec) should mint same LP as 1e6 marketA (6 dec)");

        assertEq(decPool.totalSharesNorm(), 2e18);
        assertEq(decPool.exchangeRate(), 1e18);
    }

    function test_Decimals_6and18_swapOutputDenormalized() public {
        SwapPool decPool = _createPoolWithDecimals(6, 18);

        uint256 idA = MARKET_A_ID + 100;
        uint256 idB = MARKET_B_ID + 100;

        marketAToken.mint(lp1, idA, 5_000_000);
        marketBToken.mint(lp1, idB, 5e18);
        marketAToken.mint(swapper, idA, 1_000_000);

        vm.startPrank(lp1);
        marketAToken.setApprovalForAll(address(decPool), true);
        marketBToken.setApprovalForAll(address(decPool), true);
        vm.stopPrank();
        vm.prank(swapper);
        marketAToken.setApprovalForAll(address(decPool), true);

        vm.prank(lp1);
        decPool.deposit(SwapPool.Side.MARKET_A, 5_000_000);
        vm.prank(lp1);
        decPool.deposit(SwapPool.Side.MARKET_B, 5e18);

        // Swap 1_000_000 marketA (6 dec) → marketB (18 dec)
        // normIn = 1e6 * 1e12 = 1e18
        // fee = 40 bps on 1e18 → 4e15
        // normOut = 1e18 - 4e15 = 0.996e18
        // rawOut (18 dec) = 0.996e18
        vm.prank(swapper);
        uint256 out = decPool.swap(SwapPool.Side.MARKET_A, 1_000_000);

        assertEq(out, 996_000_000_000_000_000, "output should be 0.996e18 marketB");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SwapPool — withdrawSingleSide
    // ═══════════════════════════════════════════════════════════════════════════

    function test_WithdrawSingleSide_sameSide_marketA_free() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 1000);

        uint256 before = marketAToken.balanceOf(lp1, MARKET_A_ID);

        vm.prank(lp1);
        pool.withdrawSingleSide(1000, SwapPool.Side.MARKET_A, SwapPool.Side.MARKET_A);

        assertEq(marketAToken.balanceOf(lp1, MARKET_A_ID), before + 1000);
        assertEq(marketALp.balanceOf(lp1), 0);
        assertEq(pool.marketABalance(), 0);
        assertEq(marketAToken.balanceOf(address(feeCollector), MARKET_A_ID), 0);
    }

    function test_WithdrawSingleSide_sameSide_marketB_free() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_B, 1000);

        uint256 before = marketBToken.balanceOf(lp1, MARKET_B_ID);

        vm.prank(lp1);
        pool.withdrawSingleSide(1000, SwapPool.Side.MARKET_B, SwapPool.Side.MARKET_B);

        assertEq(marketBToken.balanceOf(lp1, MARKET_B_ID), before + 1000);
        assertEq(marketBLp.balanceOf(lp1), 0);
    }

    function test_WithdrawSingleSide_crossSide_chargesFee() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 5000);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, 5000);

        uint256 before = marketBToken.balanceOf(lp1, MARKET_B_ID);

        vm.prank(lp1);
        pool.withdrawSingleSide(1000, SwapPool.Side.MARKET_A, SwapPool.Side.MARKET_B);

        // sharesOut=1000, totalFee=4 (ceil(1000*40/10000)), protocolFee=1, lpFee=3, actualOut=996
        assertEq(marketBToken.balanceOf(lp1, MARKET_B_ID), before + 996);
        assertEq(marketBToken.balanceOf(address(feeCollector), MARKET_B_ID), 1);
    }

    function test_WithdrawSingleSide_crossSide_resolved_free() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 5000);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, 5000);

        vm.prank(operator);
        factory.resolvePoolAndPausedDeposits(0);

        uint256 before = marketBToken.balanceOf(lp1, MARKET_B_ID);

        vm.prank(lp1);
        pool.withdrawSingleSide(1000, SwapPool.Side.MARKET_A, SwapPool.Side.MARKET_B);

        assertEq(marketBToken.balanceOf(lp1, MARKET_B_ID), before + 1000);
        assertEq(marketBToken.balanceOf(address(feeCollector), MARKET_B_ID), 0);
    }

    function test_WithdrawSingleSide_revertsInsufficientLiquidity_crossSide() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 1000);

        vm.prank(lp1);
        vm.expectRevert();
        pool.withdrawSingleSide(1000, SwapPool.Side.MARKET_A, SwapPool.Side.MARKET_B);
    }

    function test_WithdrawSingleSide_revertsInsufficientLiquidity_sameSide() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 1000);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, 5000);

        // Drain marketA via swap (marketB→marketA)
        address drainer = makeAddr("drainer");
        marketBToken.mint(drainer, MARKET_B_ID, 2000);
        vm.startPrank(drainer);
        marketBToken.setApprovalForAll(address(pool), true);
        pool.swap(SwapPool.Side.MARKET_B, 1004); // drains most of marketA
        vm.stopPrank();

        vm.prank(lp1);
        vm.expectRevert();
        pool.withdrawSingleSide(1000, SwapPool.Side.MARKET_A, SwapPool.Side.MARKET_A);
    }

    function test_WithdrawSingleSide_revertsZeroAmount() public {
        vm.prank(lp1);
        vm.expectRevert(SwapPool.ZeroAmount.selector);
        pool.withdrawSingleSide(0, SwapPool.Side.MARKET_A, SwapPool.Side.MARKET_A);
    }

    function test_WithdrawSingleSide_ratePreservedAfterSameSideWithdraw() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 1000);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, 1000);

        uint256 rateBefore = pool.exchangeRate();

        vm.prank(lp1);
        pool.withdrawSingleSide(500, SwapPool.Side.MARKET_A, SwapPool.Side.MARKET_A);

        assertEq(pool.exchangeRate(), rateBefore, "rate should not change after same-side withdraw");
    }

    function test_WithdrawSingleSide_lpFeeRemainsInPool_crossSide() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 5000);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, 5000);

        vm.prank(lp1);
        pool.withdrawSingleSide(5000, SwapPool.Side.MARKET_A, SwapPool.Side.MARKET_B);

        // actualOut=4985, protocolFee=5 transferred out, lpFee=15 stays in marketBBalance
        assertEq(pool.marketBBalance(), 5000 - 4985);
        assertEq(pool.totalLpSupply(), marketBLp.totalSupply()); // only marketBLp remains
    }

    function test_WithdrawSingleSide_emitsSameSideEvent() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 1000);

        vm.prank(lp1);
        vm.expectEmit(true, false, false, true);
        emit SwapPool.WithdrawnSingleSide(lp1, SwapPool.Side.MARKET_A, SwapPool.Side.MARKET_A, 1000, 1000, 0, 0);
        pool.withdrawSingleSide(1000, SwapPool.Side.MARKET_A, SwapPool.Side.MARKET_A);
    }

    function test_WithdrawSingleSide_emitsCrossSideEvent() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 5000);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, 5000);

        vm.prank(lp1);
        vm.expectEmit(true, false, false, true);
        // actualOut=996, lpFee=3, protocolFee=1
        emit SwapPool.WithdrawnSingleSide(lp1, SwapPool.Side.MARKET_A, SwapPool.Side.MARKET_B, 1000, 996, 3, 1);
        pool.withdrawSingleSide(1000, SwapPool.Side.MARKET_A, SwapPool.Side.MARKET_B);
    }

    function test_WithdrawSingleSide_crossSide_revertsWhenSwapsPaused() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 5000);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, 5000);

        vm.prank(operator);
        factory.setPoolSwapsPaused(0, true);

        vm.prank(lp1);
        vm.expectRevert(SwapPool.SwapsPaused.selector);
        pool.withdrawSingleSide(1000, SwapPool.Side.MARKET_A, SwapPool.Side.MARKET_B);
    }

    function test_WithdrawSingleSide_sameSide_notBlockedBySwapsPaused() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 1000);

        vm.prank(operator);
        factory.setPoolSwapsPaused(0, true);

        // Same-side is never blocked by swapsPaused
        vm.prank(lp1);
        uint256 received = pool.withdrawSingleSide(1000, SwapPool.Side.MARKET_A, SwapPool.Side.MARKET_A);
        assertEq(received, 1000);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SwapPool — withdrawBothSides
    // ═══════════════════════════════════════════════════════════════════════════

    function test_WithdrawBothSides_exactSplit() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 5000);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, 5000);

        // lp1 has 5000 marketALp, grossOut=5000, split: 8000 bps same, 2000 cross
        // sameside = 4000 MARKET_A (free), crossside = 1000 MARKET_B (fee)
        uint256 beforeA = marketAToken.balanceOf(lp1, MARKET_A_ID);
        uint256 beforeB = marketBToken.balanceOf(lp1, MARKET_B_ID);

        vm.prank(lp1);
        pool.withdrawBothSides(5000, SwapPool.Side.MARKET_A, 8000);

        assertEq(marketAToken.balanceOf(lp1, MARKET_A_ID), beforeA + 4000);
        // crossside: 1000, fee=4, actualOut=996
        assertEq(marketBToken.balanceOf(lp1, MARKET_B_ID), beforeB + 996);
        assertEq(marketBToken.balanceOf(address(feeCollector), MARKET_B_ID), 1);
    }

    function test_WithdrawBothSides_allSameSide_equivalentToSingleSide() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 1000);

        uint256 before = marketAToken.balanceOf(lp1, MARKET_A_ID);

        vm.prank(lp1);
        pool.withdrawBothSides(1000, SwapPool.Side.MARKET_A, 10000);

        assertEq(marketAToken.balanceOf(lp1, MARKET_A_ID), before + 1000);
        assertEq(marketALp.balanceOf(lp1), 0);
        assertEq(marketBToken.balanceOf(address(feeCollector), MARKET_B_ID), 0);
    }

    function test_WithdrawBothSides_allCrossSide_fullFee() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 5000);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, 5000);

        uint256 before = marketBToken.balanceOf(lp1, MARKET_B_ID);

        vm.prank(lp1);
        (uint256 sameReceived, uint256 crossReceived) =
            pool.withdrawBothSides(1000, SwapPool.Side.MARKET_A, 0);

        assertEq(sameReceived, 0);
        assertEq(crossReceived, 996);
        assertEq(marketBToken.balanceOf(lp1, MARKET_B_ID), before + 996);
    }

    function test_WithdrawBothSides_resolved_crossSideFree() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 5000);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, 5000);

        vm.prank(operator);
        factory.resolvePoolAndPausedDeposits(0);

        uint256 before = marketBToken.balanceOf(lp1, MARKET_B_ID);

        vm.prank(lp1);
        pool.withdrawBothSides(5000, SwapPool.Side.MARKET_A, 8000);

        // crossside resolved → no fee, full 1000 MARKET_B
        assertEq(marketBToken.balanceOf(lp1, MARKET_B_ID), before + 1000);
        assertEq(marketBToken.balanceOf(address(feeCollector), MARKET_B_ID), 0);
    }

    function test_WithdrawBothSides_revertsInvalidSplit() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 1000);

        vm.prank(lp1);
        vm.expectRevert(SwapPool.InvalidSplit.selector);
        pool.withdrawBothSides(1000, SwapPool.Side.MARKET_A, 10001);
    }

    function test_WithdrawBothSides_revertsZeroAmount() public {
        vm.prank(lp1);
        vm.expectRevert(SwapPool.ZeroAmount.selector);
        pool.withdrawBothSides(0, SwapPool.Side.MARKET_A, 0);
    }

    function test_WithdrawBothSides_revertsInsufficientCrossSideLiquidity() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 1000);
        // Pool has 0 MARKET_B — cross-side portion should revert

        vm.prank(lp1);
        vm.expectRevert();
        pool.withdrawBothSides(1000, SwapPool.Side.MARKET_A, 5000);
    }

    function test_WithdrawBothSides_crossSide_revertsWhenSwapsPaused() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 5000);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, 5000);

        vm.prank(operator);
        factory.setPoolSwapsPaused(0, true);

        vm.prank(lp1);
        vm.expectRevert(SwapPool.SwapsPaused.selector);
        pool.withdrawBothSides(1000, SwapPool.Side.MARKET_A, 5000);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SwapPool — Swap
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Swap_marketAToMarketB_basicFees() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 5000);
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_B, 5000);

        uint256 before = marketBToken.balanceOf(swapper, MARKET_B_ID);

        vm.prank(swapper);
        uint256 amountOut = pool.swap(SwapPool.Side.MARKET_A, 1000);

        // totalFee = ceil(1000*40/10000) = 4, protocolFee=1, lpFee=3, out=996
        assertEq(amountOut, 996);
        assertEq(marketBToken.balanceOf(swapper, MARKET_B_ID), before + 996);
        assertEq(marketAToken.balanceOf(address(feeCollector), MARKET_A_ID), 1);
    }

    function test_Swap_marketBToMarketA_basicFees() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 5000);
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_B, 5000);

        uint256 before = marketAToken.balanceOf(swapper, MARKET_A_ID);

        vm.prank(swapper);
        uint256 amountOut = pool.swap(SwapPool.Side.MARKET_B, 1000);

        assertEq(amountOut, 996);
        assertEq(marketAToken.balanceOf(swapper, MARKET_A_ID), before + 996);
        assertEq(marketBToken.balanceOf(address(feeCollector), MARKET_B_ID), 1);
    }

    function test_Swap_lpFeeAutoCompounds_noNewLpMinted() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 5000);
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_B, 5000);

        uint256 supplyBefore = pool.totalLpSupply();
        uint256 rateBefore   = pool.exchangeRate();

        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_A, 1000);

        assertEq(pool.totalLpSupply(), supplyBefore, "LP supply should not change");
        assertGt(pool.exchangeRate(), rateBefore, "rate should increase from LP fee");
    }

    function test_Swap_feesUpdatePoolBalanceCorrectly() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 5000);
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_B, 5000);

        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_A, 1000);

        // fromSide MARKET_A: +1000 in, -1 protocol out → net +999
        // toSide MARKET_B: -996 to swapper
        assertEq(pool.marketABalance(), 5000 + 999);
        assertEq(pool.marketBBalance(), 5000 - 996);
    }

    function test_Swap_revertsInsufficientLiquidity() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_B, 100);

        vm.prank(swapper);
        vm.expectRevert();
        pool.swap(SwapPool.Side.MARKET_A, 200);
    }

    function test_Swap_revertsZeroAmount() public {
        vm.prank(swapper);
        vm.expectRevert(SwapPool.ZeroAmount.selector);
        pool.swap(SwapPool.Side.MARKET_A, 0);
    }

    function test_Swap_revertsWhenPaused() public {
        vm.prank(operator);
        factory.setPoolSwapsPaused(0, true);

        vm.prank(swapper);
        vm.expectRevert(SwapPool.SwapsPaused.selector);
        pool.swap(SwapPool.Side.MARKET_A, 100);
    }

    function test_Swap_emitsEvent() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 5000);
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_B, 5000);

        vm.prank(swapper);
        vm.expectEmit(true, false, false, true);
        emit SwapPool.Swapped(swapper, SwapPool.Side.MARKET_A, 1000, 996, 3, 1);
        pool.swap(SwapPool.Side.MARKET_A, 1000);
    }

    function test_Swap_zeroFee_fullAmountOut() public {
        vm.prank(owner);
        factory.setPoolFees(0, 0, 0);

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 5000);
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_B, 5000);

        vm.prank(swapper);
        uint256 amountOut = pool.swap(SwapPool.Side.MARKET_A, 1000);

        assertEq(amountOut, 1000);
    }

    function test_Swap_customFee_correctCalculation() public {
        vm.prank(owner);
        factory.setPoolFees(0, 100, 50); // 1% LP + 0.5% protocol

        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 5000);
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_B, 5000);

        // totalFee = ceil(5000 * 150 / 10000) = ceil(75) = 75
        // protocolFee = (75 * 50) / 150 = 25
        // lpFee = 75 - 25 = 50
        // amountOut = 5000 - 75 = 4925
        vm.prank(swapper);
        uint256 amountOut = pool.swap(SwapPool.Side.MARKET_A, 5000);

        assertEq(amountOut, 4925);
        assertEq(marketAToken.balanceOf(address(feeCollector), MARKET_A_ID), 25);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Exchange rate integrity
    // ═══════════════════════════════════════════════════════════════════════════

    function test_ExchangeRate_startsAtOne() public view {
        assertEq(pool.exchangeRate(), 1e18);
    }

    function test_ExchangeRate_unchangedAfterDeposit() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 1000);
        assertEq(pool.exchangeRate(), 1e18);

        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, 500);
        assertEq(pool.exchangeRate(), 1e18);
    }

    function test_ExchangeRate_increasesAfterSwapFee() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 5000);
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_B, 5000);

        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_A, 1000);

        assertGt(pool.exchangeRate(), 1e18);
    }

    function test_ExchangeRate_multipleSwapsIncreaseRate() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 5000);
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_B, 5000);

        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_A, 1000);
        uint256 rateAfterFirst = pool.exchangeRate();

        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_B, 1000);
        uint256 rateAfterSecond = pool.exchangeRate();

        assertGt(rateAfterSecond, rateAfterFirst);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Rescue functions
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Rescue_surplusPoolTokens() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 1000);

        // Someone sends tokens directly to pool without depositing
        marketAToken.mint(address(pool), MARKET_A_ID, 50);

        vm.prank(owner);
        factory.rescuePoolTokens(0, SwapPool.Side.MARKET_A, 50, owner);

        assertEq(marketAToken.balanceOf(owner, MARKET_A_ID), 50);
        assertEq(pool.marketABalance(), 1000); // tracked balance unchanged
    }

    function test_Rescue_revertsIfAmountExceedsSurplus() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 1000);

        vm.prank(owner);
        vm.expectRevert(SwapPool.NothingToRescue.selector);
        factory.rescuePoolTokens(0, SwapPool.Side.MARKET_A, 1, owner);
    }

    function test_Rescue_foreignERC1155() public {
        MockERC1155 foreign = new MockERC1155();
        foreign.mint(address(pool), 99, 500);

        vm.prank(owner);
        factory.rescuePoolERC1155(0, address(foreign), 99, 500, owner);

        assertEq(foreign.balanceOf(owner, 99), 500);
    }

    function test_Rescue_foreignERC1155_revertsOnMarketAContract() public {
        vm.prank(owner);
        vm.expectRevert(SwapPool.CannotRescuePoolTokens.selector);
        factory.rescuePoolERC1155(0, address(marketAToken), MARKET_A_ID, 1, owner);
    }

    function test_Rescue_foreignERC1155_revertsOnMarketBContract() public {
        vm.prank(owner);
        vm.expectRevert(SwapPool.CannotRescuePoolTokens.selector);
        factory.rescuePoolERC1155(0, address(marketBToken), MARKET_B_ID, 1, owner);
    }

    function test_Rescue_ETH() public {
        vm.deal(address(pool), 1 ether);
        uint256 balBefore = owner.balance;

        vm.prank(owner);
        factory.rescuePoolETH(0, payable(owner));

        assertEq(owner.balance, balBefore + 1 ether);
    }

    function test_Rescue_revertsNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        factory.rescuePoolTokens(0, SwapPool.Side.MARKET_A, 1, attacker);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Integration — full LP lifecycle
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Integration_fullLpLifecycle_sameSideWithdraw() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 2000);
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_B, 2000);

        assertEq(marketALp.balanceOf(lp1), 2000);
        assertEq(marketBLp.balanceOf(lp1), 2000);

        vm.prank(swapper);
        pool.swap(SwapPool.Side.MARKET_A, 1004);

        assertGt(pool.exchangeRate(), 1e18);

        uint256 beforeA      = marketAToken.balanceOf(lp1, MARKET_A_ID);
        uint256 beforeB      = marketBToken.balanceOf(lp1, MARKET_B_ID);
        uint256 normShares   = pool.totalSharesNorm();
        uint256 totalLpSup   = pool.totalLpSupply();

        vm.prank(lp1);
        pool.withdrawSingleSide(1000, SwapPool.Side.MARKET_A, SwapPool.Side.MARKET_A);
        vm.prank(lp1);
        pool.withdrawSingleSide(1000, SwapPool.Side.MARKET_B, SwapPool.Side.MARKET_B);

        uint256 expectedNorm   = (2000 * normShares) / totalLpSup;
        uint256 actualReceived = (marketAToken.balanceOf(lp1, MARKET_A_ID) - beforeA)
                               + (marketBToken.balanceOf(lp1, MARKET_B_ID) - beforeB);

        assertApproxEqAbs(actualReceived, expectedNorm, 2, "received shares should match expected");
    }

    function test_Integration_twoLps_proportionalFeeShare() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 1000);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, 1000);

        assertEq(marketALp.balanceOf(lp1), marketBLp.balanceOf(lp2));
        assertEq(pool.totalLpSupply(), 2000);

        for (uint256 i; i < 5; i++) {
            vm.prank(swapper);
            pool.swap(SwapPool.Side.MARKET_A, 500);
            vm.prank(swapper);
            pool.swap(SwapPool.Side.MARKET_B, 500);
        }

        // Both hold 1000/2000 = 50% each — proportional shares should be equal
        uint256 lp1Shares = (marketALp.balanceOf(lp1) * pool.totalSharesNorm()) / pool.totalLpSupply();
        uint256 lp2Shares = (marketBLp.balanceOf(lp2) * pool.totalSharesNorm()) / pool.totalLpSupply();
        assertEq(lp1Shares, lp2Shares, "both LPs should have equal share");
    }

    function test_Integration_crossSideBypassPrevented() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 5000);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, 5000);

        uint256 before = marketBToken.balanceOf(lp1, MARKET_B_ID);

        vm.prank(lp1);
        pool.withdrawSingleSide(1000, SwapPool.Side.MARKET_A, SwapPool.Side.MARKET_B);

        uint256 received = marketBToken.balanceOf(lp1, MARKET_B_ID) - before;

        assertLt(received, 1000, "cross-side withdraw must not bypass fee");
        assertEq(received, 996);
    }

    function test_Integration_resolvedPool_crossSideFreeForBoth() public {
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 5000);
        vm.prank(lp2);
        pool.deposit(SwapPool.Side.MARKET_B, 5000);

        vm.prank(operator);
        factory.resolvePoolAndPausedDeposits(0);

        uint256 beforeB = marketBToken.balanceOf(lp1, MARKET_B_ID);
        uint256 beforeA = marketAToken.balanceOf(lp2, MARKET_A_ID);

        vm.prank(lp1);
        pool.withdrawSingleSide(1000, SwapPool.Side.MARKET_A, SwapPool.Side.MARKET_B);
        vm.prank(lp2);
        pool.withdrawSingleSide(1000, SwapPool.Side.MARKET_B, SwapPool.Side.MARKET_A);

        assertEq(marketBToken.balanceOf(lp1, MARKET_B_ID), beforeB + 1000);
        assertEq(marketAToken.balanceOf(lp2, MARKET_A_ID), beforeA + 1000);
        assertEq(marketBToken.balanceOf(address(feeCollector), MARKET_B_ID), 0);
        assertEq(marketAToken.balanceOf(address(feeCollector), MARKET_A_ID), 0);
    }

    function test_Integration_perPoolFees_affectOnlyTargetPool() public {
        vm.startPrank(operator);
        uint256 pid2 = factory.createPool(
            _marketAConfig(MARKET_A_ID + 1, 18),
            _marketBConfig(MARKET_B_ID + 1, 18),
            30, 10, "P2A", "P2A", "P2B", "P2B"
        );
        vm.stopPrank();

        SwapPool pool2 = SwapPool(payable(factory.getPool(pid2).swapPool));

        address lp3 = makeAddr("lp3");
        marketAToken.mint(lp3, MARKET_A_ID + 1, 10_000);
        marketBToken.mint(lp3, MARKET_B_ID + 1, 10_000);
        vm.startPrank(lp3);
        marketAToken.setApprovalForAll(address(pool2), true);
        marketBToken.setApprovalForAll(address(pool2), true);
        pool2.deposit(SwapPool.Side.MARKET_A, 5000);
        pool2.deposit(SwapPool.Side.MARKET_B, 5000);
        vm.stopPrank();

        // Change fees only on pool 0
        vm.prank(owner);
        factory.setPoolFees(0, 0, 0);

        // Setup pool 0 liquidity
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_A, 5000);
        vm.prank(lp1);
        pool.deposit(SwapPool.Side.MARKET_B, 5000);

        // pool 0 has zero fee → full amount out
        vm.prank(swapper);
        uint256 out0 = pool.swap(SwapPool.Side.MARKET_A, 1000);
        assertEq(out0, 1000, "pool0 should have zero fee");

        // pool2 still has original 0.4% fee
        address swapper2 = makeAddr("swapper2");
        marketAToken.mint(swapper2, MARKET_A_ID + 1, 1000);
        vm.startPrank(swapper2);
        marketAToken.setApprovalForAll(address(pool2), true);
        uint256 out2 = pool2.swap(SwapPool.Side.MARKET_A, 1000);
        vm.stopPrank();
        assertEq(out2, 996, "pool2 should still charge original fee");
    }
}