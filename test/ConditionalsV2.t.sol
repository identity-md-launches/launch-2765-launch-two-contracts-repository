// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {ConditionalsV2} from "../src/ConditionalsV2.sol";
import {IOracleAttestation} from "../src/interfaces/IOracleAttestation.sol";

contract ConditionalsV2Test is Fixture {
    uint256 internal constant SEED_20 = 27_725_887_222_397_812_376; // 20 ln 4, the design's worked example

    function _invariantsHold(uint256 id) internal view {
        ConditionalsV2.Market memory m = c.getMarket(id);
        for (uint256 i; i < 4; ++i) {
            assertGe(int256(m.makerBalance), m.q[i], "maker covers every outcome");
        }
    }

    // ---- creation --------------------------------------------------------------------------------------------------

    function test_create_takesBudgetAndSeed() public {
        uint256 before = imd.balanceOf(creator);
        uint256 id = _create();
        ConditionalsV2.Market memory m = c.getMarket(id);
        assertApproxEqAbs(m.subsidy, SEED_20, 1000);
        assertEq(m.makerBalance, m.subsidy);
        assertEq(m.budget, 1 ether);
        assertEq(before - imd.balanceOf(creator), 1 ether + m.subsidy);
        uint256[4] memory p = c.prices(id);
        for (uint256 i; i < 4; ++i) {
            assertApproxEqAbs(p[i], 0.25 ether, 4);
        }
    }

    function test_create_boundsB() public {
        vm.startPrank(creator);
        vm.expectRevert(ConditionalsV2.InvalidConfig.selector);
        c.createMarket(CONDITION, OUTCOME, RULES, closeTime, resolveTime, 1 ether, 0.49 ether);
        vm.expectRevert(ConditionalsV2.InvalidConfig.selector);
        c.createMarket(CONDITION, OUTCOME, RULES, closeTime, resolveTime, 1 ether, 100 ether + 1);
        vm.expectRevert(abi.encodeWithSelector(ConditionalsV2.BudgetTooHigh.selector, 1 ether, 0.9 ether));
        c.createMarket(CONDITION, OUTCOME, RULES, closeTime, resolveTime, 0.9 ether, B);
        vm.stopPrank();
    }

    function test_seedFor_isbln4() public view {
        assertApproxEqRel(c.seedFor(1.44 ether), 1.996 ether, 0.001e18);
        assertApproxEqRel(c.seedFor(0.5 ether), 0.693 ether, 0.001e18);
    }

    // ---- the design's worked example -------------------------------------------------------------------------------

    function test_stake_matchesTheDesignExample() public {
        uint256 id = _create();
        // Fees on both legs make k a little below the design's fee-free 6.6359.
        (uint256 quoted,) = c.quoteStake(id, 0, 0, 10 ether);
        uint256 k = _stake(alice, id, 0, 0, 10 ether);
        assertEq(k, quoted);
        assertApproxEqRel(k, 6.3 ether, 0.03e18);

        uint256[4] memory held = c.sharesOf(id, alice);
        assertEq(held[0], 10 ether + k, "paid in its world");
        assertEq(held[1], 0, "opposite side sold");
        assertEq(held[2], 10 ether, "refund leg");
        assertEq(held[3], 10 ether, "refund leg");

        uint256[4] memory p = c.prices(id);
        assertGt(p[0], 0.33 ether);
        assertLt(p[1], 0.17 ether);
        // Fees leave the maker a little short of the design's fee-free quotes, so world B's mass rises a little.
        assertApproxEqRel(p[2], 0.25 ether, 0.01e18);
        assertApproxEqRel(p[0] + p[1], 0.5 ether, 0.01e18, "P(C) barely moves");
        (uint256 yesA, uint256 yesB) = c.conditionals(id);
        assertGt(yesA, 0.66 ether);
        assertApproxEqAbs(yesB, 0.5 ether, 4);
        _invariantsHold(id);
    }

    function test_stake_otherWorldRefundsTheStake() public {
        uint256 id = _create();
        uint256 before = imd.balanceOf(alice);
        _stake(alice, id, 0, 0, 10 ether);
        _resolve(id, false, true);
        assertEq(_claim(alice, id), 10 ether);
        assertEq(imd.balanceOf(alice), before, "the world that did not happen is refunded in full");
    }

    function test_stake_winningWorldPays() public {
        uint256 id = _create();
        uint256 before = imd.balanceOf(alice);
        uint256 k = _stake(alice, id, 0, 0, 10 ether);
        _resolve(id, true, true);
        assertEq(_claim(alice, id), 10 ether + k);
        assertEq(imd.balanceOf(alice), before + k);
    }

    function test_stake_losingSideLosesTheStake() public {
        uint256 id = _create();
        uint256 before = imd.balanceOf(alice);
        _stake(alice, id, 0, 0, 10 ether);
        _resolve(id, true, false);
        // A claim with nothing to pay returns 0 and changes nothing (it used to revert NothingToClaim).
        assertEq(_claim(alice, id), 0);
        assertFalse(c.claimed(id, alice));
        assertEq(imd.balanceOf(alice), before - 10 ether);
    }

    function test_stake_slippageAndBounds() public {
        uint256 id = _create();
        vm.startPrank(alice);
        vm.expectRevert(ConditionalsV2.SlippageExceeded.selector);
        c.stakeConditional(id, 0, 0, 10 ether, 100 ether);
        vm.expectRevert(ConditionalsV2.TradeTooSmall.selector);
        c.stakeConditional(id, 0, 0, 1e15 - 1, 0);
        vm.expectRevert(ConditionalsV2.InvalidChoice.selector);
        c.stakeConditional(id, 2, 0, 1 ether, 0);
        vm.expectRevert(ConditionalsV2.InvalidChoice.selector);
        c.stakeConditional(id, 0, 2, 1 ether, 0);
        vm.stopPrank();
    }

    function test_stakeFor_creditsTheAccountAndChargesTheCaller() public {
        uint256 id = _create();
        uint256 payer = imd.balanceOf(bob);
        uint256 credited = imd.balanceOf(alice);
        vm.prank(bob);
        c.stakeFor(alice, id, 1, 1, 5 ether, 0);
        assertEq(imd.balanceOf(bob), payer - 5 ether);
        assertEq(imd.balanceOf(alice), credited);
        assertEq(c.sharesOf(id, alice)[0], 5 ether);
        assertEq(c.sharesOf(id, bob)[0], 0);
        vm.prank(bob);
        vm.expectRevert(ConditionalsV2.ZeroAddress.selector);
        c.stakeFor(address(0), id, 1, 1, 5 ether, 0);
    }

    function test_closedMarketRefusesTrades() public {
        uint256 id = _create();
        _stake(alice, id, 0, 0, 1 ether);
        vm.warp(closeTime);
        vm.startPrank(alice);
        vm.expectRevert(ConditionalsV2.BettingClosed.selector);
        c.stakeConditional(id, 0, 0, 1 ether, 0);
        vm.expectRevert(ConditionalsV2.BettingClosed.selector);
        c.exit(id, 0);
        vm.expectRevert(ConditionalsV2.BettingClosed.selector);
        c.buy(id, 0, 1 ether, 10 ether);
        vm.expectRevert(ConditionalsV2.BettingClosed.selector);
        c.sell(id, 0, 1 ether, 0);
        vm.stopPrank();
    }

    // ---- buy, sell and exit ----------------------------------------------------------------------------------------

    function test_buySell_roundTripLoses() public {
        uint256 id = _create();
        uint256 before = imd.balanceOf(alice);
        vm.startPrank(alice);
        (uint256 cost, uint256 fee) = c.buy(id, 2, 5 ether, 10 ether);
        uint256 got = c.sell(id, 2, 5 ether, 0);
        vm.stopPrank();
        assertLt(got, cost + fee);
        assertLt(imd.balanceOf(alice), before);
        _invariantsHold(id);
    }

    function test_buySell_slippage() public {
        uint256 id = _create();
        vm.startPrank(alice);
        vm.expectRevert(ConditionalsV2.SlippageExceeded.selector);
        c.buy(id, 0, 5 ether, 1 ether);
        c.buy(id, 0, 5 ether, 10 ether);
        vm.expectRevert(ConditionalsV2.SlippageExceeded.selector);
        c.sell(id, 0, 5 ether, 5 ether);
        vm.stopPrank();
    }

    function test_exit_closesThePositionAtQuote() public {
        uint256 id = _create();
        _stake(alice, id, 0, 0, 10 ether);
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        uint256 got = c.exit(id, 0);
        assertEq(imd.balanceOf(alice), before + got);
        uint256[4] memory held = c.sharesOf(id, alice);
        for (uint256 i; i < 4; ++i) {
            assertEq(held[i], 0);
        }
        assertLt(got, 10 ether, "fees and price impact are lost");
        assertGt(got, 9 ether);
        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.NoPosition.selector);
        c.exit(id, 0);
        _invariantsHold(id);
    }

    function test_exit_slippage() public {
        uint256 id = _create();
        _stake(alice, id, 0, 0, 10 ether);
        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.SlippageExceeded.selector);
        c.exit(id, 10 ether);
    }

    function test_priceLimitRefusesASaturatedMarket() public {
        vm.prank(creator);
        uint256 id = c.createMarket(CONDITION, OUTCOME, RULES, closeTime, resolveTime, 1 ether, 0.5 ether);
        vm.startPrank(alice);
        vm.expectRevert(ConditionalsV2.PriceLimit.selector);
        c.stakeConditional(id, 0, 0, 500 ether, 0);
        vm.stopPrank();
        _stake(alice, id, 0, 0, 3 ether);
        _invariantsHold(id);
    }

    // ---- fees ------------------------------------------------------------------------------------------------------

    function test_fees_splitAndAccrue() public {
        uint256 id = _create();
        vm.prank(alice);
        (, uint256 fee) = c.buy(id, 0, 10 ether, 10 ether);
        assertGt(fee, 0);
        uint256 toCreator = fee / 2;
        uint256 burned = fee * 67 / 200;
        assertEq(c.owed(creator), toCreator);
        assertEq(imd.balanceOf(DEAD), burned);
        assertEq(c.owed(builder), fee - toCreator - burned);
        assertEq(c.totalBurned(), burned);

        uint256 before = imd.balanceOf(creator);
        vm.prank(creator);
        c.withdrawOwed();
        assertEq(imd.balanceOf(creator), before + toCreator);
    }

    function test_fees_blockedRecipientsDoNotBlockTrades() public {
        uint256 id = _create();
        imd.setBlocked(DEAD, true);
        imd.setBlocked(builder, true);
        _stake(alice, id, 0, 0, 1 ether);
        assertGt(c.owed(DEAD), 0, "burn deferred");
        assertGt(c.owed(builder), 0);
    }

    // ---- settlement ------------------------------------------------------------------------------------------------

    function test_settle_creatorGetsResidualAndBudget() public {
        uint256 id = _create();
        uint256 afterCreate = imd.balanceOf(creator);
        ConditionalsV2.Market memory m = c.getMarket(id);
        _resolve(id, true, true);
        vm.prank(alice);
        c.settleable(id);
        c.settle(id);
        m = c.getMarket(id);
        assertEq(m.winner, 0);
        // No trades: everything in the maker comes back, and the two asks spent the budget.
        assertEq(imd.balanceOf(creator), afterCreate + m.subsidy);
        assertEq(imd.balanceOf(address(c)), 0);
    }

    function test_settle_allFourOutcomes() public {
        bool[2][4] memory cases = [[true, true], [true, false], [false, true], [false, false]];
        for (uint256 t; t < 4; ++t) {
            closeTime = uint64(vm.getBlockTimestamp() + 7 days);
            resolveTime = uint64(vm.getBlockTimestamp() + 14 days);
            uint256 id = _create();
            uint256 k = _stake(alice, id, 0, 0, 2 ether);
            uint256 l = _stake(bob, id, 1, 1, 3 ether);
            _resolve(id, cases[t][0], cases[t][1]);
            c.settle(id);
            assertEq(c.getMarket(id).winner, t);
            uint256[2] memory expected;
            if (t == 0) expected = [2 ether + k, uint256(3 ether)];
            if (t == 1) expected = [uint256(0), uint256(3 ether)];
            if (t == 2) expected = [uint256(2 ether), uint256(0)];
            if (t == 3) expected = [uint256(2 ether), 3 ether + l];
            assertEq(c.claimable(id, alice), expected[0]);
            assertEq(c.claimable(id, bob), expected[1]);
            if (expected[0] != 0) _claim(alice, id);
            if (expected[1] != 0) _claim(bob, id);
        }
        assertLe(imd.balanceOf(address(c)), c.owed(creator) + c.owed(builder) + 16);
    }

    function test_claim_settlesAndOnlyOnce() public {
        uint256 id = _create();
        _stake(alice, id, 0, 0, 1 ether);
        _resolve(id, true, true);
        _claim(alice, id);
        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.AlreadyClaimed.selector);
        c.claim(id);
    }

    function test_creatorLossIsBoundedByTheSeed() public {
        uint256 id = _create();
        uint256 seed = c.getMarket(id).subsidy;
        uint256 before = imd.balanceOf(creator);
        vm.prank(alice);
        c.buy(id, 0, 200 ether, 1000 ether);
        _resolve(id, true, true);
        c.settle(id);
        // The informed buyer took the seed, and nothing can be asked of the creator beyond it.
        assertGe(imd.balanceOf(creator), before);
        assertLe(imd.balanceOf(creator) - before, seed);
        assertGe(imd.balanceOf(address(c)), 200 ether);
        assertEq(_claim(alice, id), 200 ether);
    }

    // ---- void ------------------------------------------------------------------------------------------------------

    function test_void_refundsCostLessFees() public {
        uint256 id = _create();
        _stake(alice, id, 0, 0, 10 ether);
        _stake(bob, id, 0, 1, 4 ether);
        vm.warp(resolveTime + 30 days + 1);
        assertTrue(c.voidable(id));
        c.voidMarket(id);
        int256 netAlice = c.netIn(id, alice);
        int256 netBob = c.netIn(id, bob);
        assertGt(netAlice, 9.5 ether);
        assertLt(netAlice, 10 ether);
        assertEq(_claim(alice, id), uint256(netAlice));
        assertEq(_claim(bob, id), uint256(netBob));
        assertEq(_claim(carol, id), 0, "no position, nothing to claim");
    }

    function test_void_paysTheCreatorLastAndProRataWhenShort() public {
        uint256 id = _create();
        // Alice buys cheap, Bob buys high, Alice sells to Bob's price: the seed backs Bob until it runs out.
        vm.prank(alice);
        c.buy(id, 0, 150 ether, 1000 ether);
        vm.prank(bob);
        c.buy(id, 0, 150 ether, 1000 ether);
        vm.prank(alice);
        c.sell(id, 0, 150 ether, 0);
        vm.warp(resolveTime + 30 days + 1);
        uint256 before = imd.balanceOf(creator);
        c.voidMarket(id);
        ConditionalsV2.Market memory m = c.getMarket(id);
        assertLe(m.refundPool, m.refundBase);
        assertEq(imd.balanceOf(creator) - before, m.makerBalance + m.sets - m.refundPool + 1 ether);
        assertEq(_claim(bob, id), c.getMarket(id).refundPool * uint256(c.netIn(id, bob)) / m.refundBase);
        // Alice sold everything: her gain is realised and nothing of hers is left to refund.
        assertEq(c.netIn(id, alice), 0);
        assertEq(_claim(alice, id), 0);
    }

    function test_void_waitsForALiveAsk() public {
        uint256 id = _create();
        vm.warp(resolveTime + 30 days);
        c.requestResolution(id);
        vm.warp(block.timestamp + 1);
        assertFalse(c.voidable(id));
        vm.expectRevert(ConditionalsV2.NotVoidable.selector);
        c.voidMarket(id);
        vm.warp(block.timestamp + 1 days);
        assertTrue(c.voidable(id));
    }

    // ---- oracle ----------------------------------------------------------------------------------------------------

    function test_oracle_badSignatureIsRefused() public {
        uint256 id = _create();
        AskRef[] memory refs = _request(id);
        bool ok =
            _deliver(refs[0].requestId, _attestation(id, refs[0], true), _sign(_attestation(id, refs[0], true), 0xB0B));
        assertFalse(ok);
        assertEq(c.getMarket(id).answers[0], 0);
    }

    function test_oracle_wrongQuestionHashIsRefused() public {
        uint256 id = _create();
        AskRef[] memory refs = _request(id);
        IOracleAttestation.Attestation memory a = _attestation(id, refs[0], true);
        a.questionHash = keccak256("other");
        assertFalse(_deliver(refs[0].requestId, a, _sign(a, signerKey)));
    }

    function test_oracle_failureAllowsAPaidRetry() public {
        uint256 id = _create();
        AskRef[] memory refs = _request(id);
        assertTrue(intake.fail(refs[0].requestId, 1, bytes32("refused")));
        assertTrue(c.askable(id, 0));
        assertFalse(c.askable(id, 1));
        uint256 before = imd.balanceOf(address(this));
        c.requestResolution(id);
        assertEq(before - imd.balanceOf(address(this)), 0.5 ether, "the budget is spent, so the caller pays");
    }

    function test_oracle_callbackFitsTheIntakeGasLimit() public {
        uint256 id = _create();
        _stake(alice, id, 0, 0, 1 ether);
        AskRef[] memory refs = _request(id);
        assertTrue(_answer(id, refs[0], true), "delivered under 200,000 gas");
    }

    function test_oracle_budgetSpentThenReturned() public {
        intake.setPrice(0.25 ether);
        uint256 id = _create();
        uint256 afterCreate = imd.balanceOf(creator);
        _resolve(id, true, true);
        c.settle(id);
        assertEq(imd.balanceOf(creator), afterCreate + c.getMarket(id).subsidy + 0.5 ether);
    }

    // ---- ownership -------------------------------------------------------------------------------------------------

    function test_owner_cannotChangeAnOpenMarket() public {
        uint256 id = _create();
        vm.prank(owner);
        c.proposeOracleConfig(_config());
        vm.warp(block.timestamp + 3 days);
        vm.prank(owner);
        c.activateOracleConfig();
        assertEq(c.getMarket(id).oracle.signer, signer);
        vm.prank(alice);
        vm.expectRevert();
        c.setFeeRecipient(alice);
    }

    // ---- fuzz ------------------------------------------------------------------------------------------------------

    function testFuzz_stakeNeverBreaksSolvency(uint96 b, uint96 amount, uint8 world, uint8 side, uint8 settleTo)
        public
    {
        uint256 liq = bound(b, 0.5 ether, 100 ether);
        uint256 x = bound(amount, 1e15, 15 * liq);
        world %= 2;
        side %= 2;
        vm.prank(creator);
        uint256 id = c.createMarket(CONDITION, OUTCOME, RULES, closeTime, resolveTime, 1 ether, liq);
        imd.mint(alice, 1_000_000 ether);
        uint256 k = _stake(alice, id, world, side, x);
        _invariantsHold(id);
        _resolve(id, settleTo % 2 == 0, settleTo % 4 < 2);
        c.settle(id);
        uint256 payable_ = c.claimable(id, alice);
        assertLe(payable_, x + k);
        if (payable_ != 0) _claim(alice, id);
        assertLe(imd.balanceOf(address(c)), c.owed(creator) + c.owed(builder) + c.owed(DEAD));
    }

    function testFuzz_roundTripNeverProfits(uint96 b, uint96 shares, uint8 outcome) public {
        uint256 liq = bound(b, 0.5 ether, 100 ether);
        uint256 s = bound(shares, 1e15, 15 * liq);
        outcome %= 4;
        vm.prank(creator);
        uint256 id = c.createMarket(CONDITION, OUTCOME, RULES, closeTime, resolveTime, 1 ether, liq);
        imd.mint(alice, 1_000_000 ether);
        uint256 before = imd.balanceOf(alice);
        vm.startPrank(alice);
        c.buy(id, outcome, s, type(uint256).max);
        c.sell(id, outcome, s, 0);
        vm.stopPrank();
        assertLt(imd.balanceOf(alice), before);
        _invariantsHold(id);
    }

    function testFuzz_exitNeverProfits(uint96 b, uint96 amount, uint8 world, uint8 side) public {
        uint256 liq = bound(b, 0.5 ether, 100 ether);
        uint256 x = bound(amount, 1e15, 10 * liq);
        vm.prank(creator);
        uint256 id = c.createMarket(CONDITION, OUTCOME, RULES, closeTime, resolveTime, 1 ether, liq);
        imd.mint(alice, 1_000_000 ether);
        uint256 before = imd.balanceOf(alice);
        _stake(alice, id, world % 2, side % 2, x);
        vm.prank(alice);
        c.exit(id, 0);
        assertLt(imd.balanceOf(alice), before);
        _invariantsHold(id);
    }

    function test_exit_largeStakeOnThinMarketAbsorbsSets() public {
        vm.prank(creator);
        uint256 id = c.createMarket(CONDITION, OUTCOME, RULES, closeTime, resolveTime, 1 ether, 0.5 ether);
        _stake(alice, id, 0, 0, 5 ether);
        vm.prank(alice);
        assertGt(c.exit(id, 0), 0);
        ConditionalsV2.Market memory m = c.getMarket(id);
        assertEq(m.sets, 0, "the sets the maker bought back are gone");
        _invariantsHold(id);
        assertGe(imd.balanceOf(address(c)), m.makerBalance + m.budget + c.owed(creator) + c.owed(builder));
    }

    function testFuzz_pricesSumToOne(int64[4] memory moves, uint96 b) public {
        uint256 liq = bound(b, 0.5 ether, 100 ether);
        vm.prank(creator);
        uint256 id = c.createMarket(CONDITION, OUTCOME, RULES, closeTime, resolveTime, 1 ether, liq);
        imd.mint(alice, 1_000_000 ether);
        vm.startPrank(alice);
        for (uint256 i; i < 4; ++i) {
            uint256 s = bound(uint256(uint64(moves[i])), 1e15, 4 * liq);
            c.buy(id, uint8(i), s, type(uint256).max);
        }
        vm.stopPrank();
        uint256[4] memory p = c.prices(id);
        assertApproxEqAbs(p[0] + p[1] + p[2] + p[3], 1 ether, 4);
    }

    // ---- audit findings --------------------------------------------------------------------------------------------

    /// @dev Audit 7011982a: a complete set bought from the maker one outcome at a time is not counted in `sets`. The
    ///      last account to exit used to underflow `m.sets`; the maker now redeems the sets it sold.
    function test_audit_exitRedeemsSetsBoughtFromTheMaker() public {
        uint256 id = _create();
        vm.prank(alice);
        c.stakeConditional(id, 0, 0, 10 ether, 0);
        vm.prank(alice);
        c.buy(id, 1, 10 ether, type(uint256).max);
        for (uint8 i; i < 4; ++i) {
            vm.prank(bob);
            c.buy(id, i, 1 ether, type(uint256).max);
        }
        assertEq(c.getMarket(id).sets, 10 ether);
        vm.prank(alice);
        c.exit(id, 0);
        assertEq(c.getMarket(id).sets, 0);

        uint256[4] memory pricesBefore = c.prices(id);
        ConditionalsV2.Market memory before = c.getMarket(id);
        uint256 balance = imd.balanceOf(bob);
        vm.prank(bob);
        uint256 got = c.exit(id, 0);
        assertEq(got, 1 ether, "a complete set redeems at 1 IMD, fee-free");
        assertEq(imd.balanceOf(bob), balance + 1 ether);
        ConditionalsV2.Market memory m = c.getMarket(id);
        assertEq(m.makerBalance, before.makerBalance - 1 ether);
        uint256[4] memory pricesAfter = c.prices(id);
        for (uint256 i; i < 4; ++i) {
            assertEq(m.q[i], before.q[i] - 1 ether);
            assertEq(pricesAfter[i], pricesBefore[i], "redeeming a set does not move prices");
            assertEq(c.sharesOf(id, bob)[i], 0);
        }
        _invariantsHold(id);
        assertGe(imd.balanceOf(address(c)), m.makerBalance + m.sets + m.budget + c.owed(creator) + c.owed(builder));
    }

    /// @dev Audit 7011982a, fuzzed: any complete set bought from the maker can be redeemed by `exit` at 1 IMD, partly
    ///      from minted sets and partly from the maker, and every outcome stays payable after.
    function testFuzz_audit_exitAnyCompleteSet(uint96 b, uint96 staked, uint96 bought, uint8 settleTo) public {
        uint256 liq = bound(b, 0.5 ether, 100 ether);
        uint256 x = bound(staked, 0, 5 * liq);
        uint256 y = bound(bought, 1e15, 3 * liq);
        vm.prank(creator);
        uint256 id = c.createMarket(CONDITION, OUTCOME, RULES, closeTime, resolveTime, 1 ether, liq);
        imd.mint(bob, 1_000_000 ether);
        if (x >= 1e15) _stake(alice, id, 0, 0, x);
        for (uint8 i; i < 4; ++i) {
            vm.prank(bob);
            c.buy(id, i, y, type(uint256).max);
        }
        vm.prank(bob);
        assertEq(c.exit(id, 0), y);
        _invariantsHold(id);
        _resolve(id, settleTo % 2 == 0, settleTo % 4 < 2);
        c.settle(id);
        uint256 owedAlice = c.claimable(id, alice);
        if (owedAlice != 0) assertEq(_claim(alice, id), owedAlice);
        assertLe(imd.balanceOf(address(c)), c.owed(creator) + c.owed(builder) + 16);
    }

    /// @dev Audit 913c99ee: dumping one world on the maker used to price it at exactly zero, after which
    ///      `conditionals` reverted and every buy and stake reverted PriceLimit. Sells are now spread-checked.
    function test_audit_sellCannotPriceAWorldAtZero() public {
        vm.prank(creator);
        uint256 id = c.createMarket(CONDITION, OUTCOME, RULES, closeTime, resolveTime, 1 ether, 0.5 ether);
        imd.mint(alice, 10_000 ether);
        vm.startPrank(alice);
        for (uint256 i; i < 8; ++i) {
            c.stakeConditional(id, 1, 0, 3 ether, 0);
            c.sell(id, 2, c.sharesOf(id, alice)[2] - 3 ether * (i + 1), 0);
            c.buy(id, 3, 3 ether, type(uint256).max);
        }
        vm.expectRevert(ConditionalsV2.PriceLimit.selector);
        c.sell(id, 0, 24 ether, 0);
        // Inside the spread the same holder sells as before.
        c.sell(id, 0, 9 ether, 0);
        vm.expectRevert(ConditionalsV2.PriceLimit.selector);
        c.sell(id, 1, 24 ether, 0);
        vm.stopPrank();

        uint256[4] memory p = c.prices(id);
        assertGt(p[0] + p[1], 0);
        (uint256 yesIfCondition, uint256 yesIfNot) = c.conditionals(id);
        assertLe(yesIfCondition, 1 ether);
        assertLe(yesIfNot, 1 ether);
        (uint256 shares,) = c.quoteStake(id, 0, 0, 1 ether);
        assertGt(shares, 0);
        _stake(bob, id, 0, 0, 1 ether);
        _invariantsHold(id);
    }

    /// @dev Audit 913c99ee: `exit` sells only what keeps the spread, so the spread check cannot lock anyone out of
    ///      `exit`; what it leaves is sold by a later exit once the market has moved.
    function test_audit_exitSellsWhatFitsTheSpread() public {
        vm.prank(creator);
        uint256 id = c.createMarket(CONDITION, OUTCOME, RULES, closeTime, resolveTime, 1 ether, 0.5 ether);
        _stake(alice, id, 1, 0, 3 ether);
        vm.startPrank(bob);
        c.buy(id, 3, 3 ether, type(uint256).max);
        c.buy(id, 2, uint256(10 ether - c.getMarket(id).q[2]), type(uint256).max);
        vm.stopPrank();
        assertEq(c.getMarket(id).q[2], 10 ether, "outcome 2 is 20 b above outcomes 0 and 1");

        vm.startPrank(alice);
        vm.expectRevert(ConditionalsV2.PriceLimit.selector);
        c.sell(id, 0, 3 ether, 0);
        assertGt(c.exit(id, 0), 0);
        uint256[4] memory held = c.sharesOf(id, alice);
        assertEq(held[0], 3 ether, "kept: no room to sell");
        assertEq(held[1], 3 ether, "kept: no room to sell");
        assertEq(held[2], 0);
        // Selling outcome 2 made room: the next exit closes the position.
        assertGt(c.exit(id, 0), 0);
        vm.stopPrank();
        held = c.sharesOf(id, alice);
        for (uint256 i; i < 4; ++i) {
            assertEq(held[i], 0);
        }
        c.conditionals(id);
        _invariantsHold(id);
    }

    /// @dev Audit b37b3ab1: a live price above the snapshot used to make every ask revert, so the market could only
    ///      void. The ask now pays the live price: from the budget while it lasts, then from the caller. Review
    ///      fc599613: the budget is drawn down to zero and the caller pays only the shortfall.
    function test_audit_askPaysALivePriceAboveTheSnapshot() public {
        uint256 id = _create();
        _stake(alice, id, 0, 0, 1 ether);
        intake.setPrice(0.6 ether);
        uint256 before = imd.balanceOf(address(this));
        AskRef[] memory refs = _request(id);
        assertEq(refs.length, 2);
        assertEq(before - imd.balanceOf(address(this)), 0.2 ether, "the budget pays 1 IMD, the caller the shortfall");
        assertEq(imd.balanceOf(intake.PAYEE()), 1.2 ether);
        assertEq(c.getMarket(id).budget, 0);
        assertFalse(c.askable(id, 0));
        assertFalse(c.askable(id, 1));
        assertEq(imd.allowance(address(c), address(intake)), 0);

        uint256 creatorBefore = imd.balanceOf(creator);
        ConditionalsV2.Market memory m = c.getMarket(id);
        assertTrue(_answer(id, refs[0], true));
        assertTrue(_answer(id, refs[1], true));
        c.settle(id);
        uint256 residual = uint256(int256(m.makerBalance) - m.q[0]);
        assertEq(imd.balanceOf(creator) - creatorBefore, residual, "nothing of the budget is left to return");
    }

    /// @dev Review fc599613: a live price far above the snapshot. The first ask takes the whole budget and 9 IMD from
    ///      the caller; the second is paid by the caller in full. No budget idles to be returned to the creator.
    function test_review_askDrawsTheBudgetDownThenChargesTheCaller() public {
        uint256 id = _create();
        intake.setPrice(10 ether);
        uint256 before = imd.balanceOf(address(this));
        AskRef[] memory refs = _request(id);
        assertEq(refs.length, 2);
        assertEq(before - imd.balanceOf(address(this)), 19 ether);
        assertEq(c.getMarket(id).budget, 0);
        assertEq(imd.balanceOf(intake.PAYEE()), 20 ether);
        assertEq(c.totalOracleSpend(), 20 ether);
    }

    /// @dev Review fc599613 (b): with a live price below the snapshot the budget covers more than two asks, and a
    ///      retry after a failure is paid from it while it lasts, as the NatSpec now says.
    function test_review_retryIsPaidFromTheBudgetWhileItLasts() public {
        uint256 id = _create();
        intake.setPrice(0.25 ether);
        AskRef[] memory refs = _request(id);
        assertEq(c.getMarket(id).budget, 0.5 ether);
        assertTrue(intake.fail(refs[0].requestId, 1, bytes32("body_refused")));
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        assertEq(c.requestResolution(id), 1);
        assertEq(imd.balanceOf(alice), before, "the budget still covers the retry");
        assertEq(c.getMarket(id).budget, 0.25 ether);
    }

    // ---- review findings (void accounting) ----------------------------------------------------------------------

    /// @dev Review d1218754: two accounts cycle the maker (B buys, A buys more, B sells at the top, A sells at the
    ///      bottom) so that B banks A's loss. The pair ends with no shares. A void used to refund A's loss out of the
    ///      seed and then out of honest stakers' refunds. Now a realised loss is not refundable: A has no position,
    ///      so nothing; the honest staker gets its collateral back; the creator gets the seed back.
    function test_review_voidDoesNotRefundRealisedLosses() public {
        uint256 id = _create();
        _stake(carol, id, 0, 0, 50 ether);
        int256 honestNet = c.netIn(id, carol);
        assertEq(c.getMarket(id).refundBase, uint256(honestNet));

        uint256 startPair = imd.balanceOf(alice) + imd.balanceOf(bob);
        for (uint256 i; i < 10; ++i) {
            vm.prank(bob);
            c.buy(id, 0, 10 ether, type(uint256).max);
            vm.prank(alice);
            c.buy(id, 0, 20 ether, type(uint256).max);
            vm.prank(bob);
            c.sell(id, 0, 10 ether, 0);
            vm.prank(alice);
            c.sell(id, 0, 20 ether, 0);
        }
        assertEq(c.sharesOf(id, alice)[0] + c.sharesOf(id, bob)[0], 0);
        assertEq(c.netIn(id, alice), 0, "a realised loss is not a refund claim");
        assertEq(c.netIn(id, bob), 0);
        assertEq(c.getMarket(id).refundBase, uint256(honestNet), "only the honest position is refundable");
        assertLt(imd.balanceOf(alice) + imd.balanceOf(bob), startPair, "the pair paid fees");

        vm.warp(resolveTime + 30 days + 1);
        uint256 creatorBefore = imd.balanceOf(creator);
        ConditionalsV2.Market memory m = c.getMarket(id);
        c.voidMarket(id);
        assertGe(imd.balanceOf(creator) - creatorBefore, m.subsidy + 1 ether, "the creator gets the seed back");
        assertEq(_claim(alice, id), 0);
        assertEq(_claim(carol, id), uint256(honestNet), "the honest staker gets its collateral back");
        assertLe(imd.balanceOf(alice) + imd.balanceOf(bob), startPair, "a void does not pay for wash trading");
    }

    /// @dev A void refunds what the shares still held cost. Selling part of a holding releases that part's share of
    ///      its cost, whatever the sale fetched: a gain is kept by the seller, a loss is the seller's.
    function test_review_voidRefundsTheCostOfSharesStillHeld() public {
        uint256 id = _create();
        vm.prank(alice);
        (uint256 cost,) = c.buy(id, 0, 10 ether, type(uint256).max);
        assertEq(c.netIn(id, alice), int256(cost));
        // Bob pushes the price up, so Alice sells 4 of her 10 at a gain.
        vm.prank(bob);
        c.buy(id, 0, 30 ether, type(uint256).max);
        vm.prank(alice);
        uint256 proceeds = c.sell(id, 0, 4 ether, 0);
        assertGt(proceeds, cost * 4 / 10, "sold at a gain");
        uint256 left = cost - cost * 4 ether / 10 ether;
        assertEq(c.netIn(id, alice), int256(left), "the 6 shares left keep their share of the cost");

        vm.warp(resolveTime + 30 days + 1);
        c.voidMarket(id);
        ConditionalsV2.Market memory m = c.getMarket(id);
        assertEq(m.refundPool, m.refundBase, "nothing is short");
        assertEq(_claim(alice, id), left);
        (uint256 bobCost,) = (uint256(c.netIn(id, bob)), 0);
        assertEq(_claim(bob, id), bobCost);
    }

    /// @dev A stake's collateral is its refund claim, exactly. Its cost is spread over the three outcomes kept by their
    ///      prices, so selling one leg later at the market realises about nothing and the rest stays refundable.
    function test_review_stakeCostFollowsPrices() public {
        uint256 id = _create();
        _stake(bob, id, 1, 1, 20 ether); // moves the prices off 1/4 each
        uint256 shares = _stake(alice, id, 0, 0, 10 ether);
        int256 net = c.netIn(id, alice);
        assertEq(uint256(net), c.getMarket(id).refundBase - uint256(c.netIn(id, bob)));
        // The two other-world legs (10 shares each) carry about their market value: the split uses the prices before
        // the stake, and the stake's own impact on the opposite side is in it, so it sits a little above the value at
        // the prices after it. Selling them releases exactly that from the refund claim, whatever the sale fetches.
        uint256[4] memory p = c.prices(id);
        uint256 value = 10 ether * (p[2] + p[3]) / 1e18;
        vm.startPrank(alice);
        uint256 got = c.sell(id, 2, 10 ether, 0) + c.sell(id, 3, 10 ether, 0);
        vm.stopPrank();
        int256 later = c.netIn(id, alice);
        uint256 released = uint256(net - later);
        assertApproxEqRel(released, value, 0.1e18, "the legs carried about their market value");
        assertGe(released, value);
        assertLt(got, released, "impact and fees are the seller's, not the refund pool's");
        assertEq(c.sharesOf(id, alice)[0], 10 ether + shares);
        assertGt(later, 0);
        // The chosen outcome carries the rest; selling it all leaves nothing refundable.
        vm.prank(alice);
        c.sell(id, 0, 10 ether + shares, 0);
        assertEq(c.netIn(id, alice), 0);
        assertEq(c.getMarket(id).refundBase, uint256(c.netIn(id, bob)));
    }

    /// @dev Exiting complete sets releases their cost from every outcome; whatever is left is still refundable.
    function test_review_exitReleasesTheSetsCost() public {
        uint256 id = _create();
        _stake(alice, id, 0, 0, 10 ether);
        vm.prank(alice);
        c.buy(id, 1, 10 ether, type(uint256).max); // alice now holds at least 10 of every outcome
        int256 before = c.netIn(id, alice);
        uint256[4] memory held = c.sharesOf(id, alice);
        vm.prank(alice);
        c.exit(id, 0);
        uint256[4] memory later = c.sharesOf(id, alice);
        for (uint256 i; i < 4; ++i) {
            assertLt(later[i], held[i]);
        }
        assertLt(c.netIn(id, alice), before);
        assertEq(uint256(c.netIn(id, alice)), c.getMarket(id).refundBase);
    }

    function testFuzz_review_partialSellKeepsAShareOfTheCost(uint96 shares, uint96 sold, uint96 move) public {
        shares = uint96(bound(shares, 2e15, 100 ether));
        sold = uint96(bound(sold, 1e15, shares - 1e15));
        move = uint96(bound(move, 1e15, 100 ether));
        uint256 id = _create();
        vm.prank(alice);
        (uint256 cost,) = c.buy(id, 1, shares, type(uint256).max);
        vm.prank(bob);
        c.buy(id, 0, move, type(uint256).max);
        vm.prank(alice);
        c.sell(id, 1, sold, 0);
        uint256 expected = cost - cost * sold / shares;
        assertEq(uint256(c.netIn(id, alice)), expected);
        assertLe(expected, cost);
        assertEq(c.getMarket(id).refundBase, expected + uint256(c.netIn(id, bob)));
    }

    // ---- review findings (quotes and views) ---------------------------------------------------------------------

    /// @dev Review 06e7064f: on a saturated market a small stake's proceeds could not fit the rounding margins within
    ///      the exact-in quote's fixed cuts, so stakes far above MIN_TRADE reverted TradeTooSmall.
    function test_review_smallStakeOnASaturatedMarket() public {
        imd.mint(alice, 5_000 ether);
        vm.prank(creator);
        uint256 id = c.createMarket(CONDITION, OUTCOME, RULES, closeTime, resolveTime, 1 ether, 100 ether);
        vm.prank(alice);
        c.buy(id, 0, 1900 ether, type(uint256).max);
        assertLt(c.prices(id)[1], 1e10, "the opposite side is nearly worthless");
        uint256[3] memory amounts = [uint256(1e15), 1e16, 1e17];
        for (uint256 i; i < 3; ++i) {
            (uint256 quoted,) = c.quoteStake(id, 0, 0, amounts[i]);
            uint256 got = _stake(bob, id, 0, 0, amounts[i]);
            assertEq(got, quoted);
            assertGt(got, 0);
        }
        _invariantsHold(id);
    }

    /// @dev Review 87a6c426: `claimable` counts an open market that `claim` would settle in the same call.
    function test_review_claimableCountsASettleableMarket() public {
        uint256 id = _create();
        _stake(alice, id, 0, 0, 2 ether);
        _resolve(id, true, true);
        assertTrue(c.settleable(id));
        assertEq(uint8(c.getMarket(id).status), uint8(ConditionalsV2.Status.Open));
        uint256 expected = c.claimable(id, alice);
        assertGt(expected, 0);
        assertEq(c.claimable(id, bob), 0);
        assertEq(_claim(alice, id), expected);
        assertEq(c.claimable(id, alice), 0);
    }

    function test_review_claimableIsZeroWhileAnAnswerIsMissing() public {
        uint256 id = _create();
        _stake(alice, id, 0, 0, 2 ether);
        AskRef[] memory refs = _request(id);
        assertTrue(_answer(id, refs[0], true));
        assertEq(c.claimable(id, alice), 0);
    }

    /// @dev A live price above MAX_PRICE is not paid: the snapshot is offered and the Intake refuses it.
    function test_audit_askNeverPaysAboveMaxPrice() public {
        uint256 id = _create();
        intake.setPrice(10 ether + 1);
        vm.warp(resolveTime);
        vm.expectRevert(bytes("PriceNotMet"));
        c.requestResolution(id);
        intake.setPrice(10 ether);
        assertEq(c.requestResolution(id), 2);
    }

    /// @dev int256(shares) wrapped above type(int256).max into a tiny sale credited as ~2**256 shares (review e665f90a).
    function test_review_buyAboveInt256MaxReverts() public {
        uint256 id = _create();
        uint256[2] memory huge = [type(uint256).max - 1e15 + 1, uint256(type(int256).max) + 1];
        for (uint256 j; j < 2; ++j) {
            for (uint8 i; i < 4; ++i) {
                vm.prank(alice);
                vm.expectRevert(ConditionalsV2.TradeTooLarge.selector);
                c.buy(id, i, huge[j], type(uint256).max);
            }
        }
        assertEq(c.sharesOf(id, alice)[0], 0);
        _invariantsHold(id);
    }

    /// @dev Review bf61cff9: a pair pumps two outcomes so that the holder keeps ~1 IMD a share of cost on each while
    ///      only one can pay. A short void lays the shortfall on cost that the position's final value does not back,
    ///      so the honest staker, whose position is worth its cost, is refunded in full.
    function test_review_voidShortfallFallsOnUnbackedCost() public {
        uint256 id = _create();
        _stake(carol, id, 1, 0, 100 ether);
        uint256 honestNet = uint256(c.netIn(id, carol));
        uint256 pairStart = imd.balanceOf(alice) + imd.balanceOf(bob);

        vm.prank(alice);
        c.buy(id, 0, 100 ether, type(uint256).max);
        vm.prank(bob);
        c.buy(id, 0, 100 ether, type(uint256).max);
        vm.prank(alice);
        c.sell(id, 0, 100 ether, 0);
        vm.prank(alice);
        c.buy(id, 1, 180 ether, type(uint256).max);
        vm.prank(bob);
        c.buy(id, 1, 100 ether, type(uint256).max);
        vm.prank(alice);
        c.sell(id, 1, 180 ether, 0);
        uint256 holderNet = uint256(c.netIn(id, bob));

        vm.warp(resolveTime + 30 days + 1);
        c.voidMarket(id);
        ConditionalsV2.Market memory m = c.getMarket(id);
        assertLt(m.refundPool, m.refundBase, "the void is short");
        assertEq(m.refundPool, m.makerBalance + m.sets);

        uint256 paid = _claim(carol, id);
        assertGe(paid, honestNet, "the honest staker is refunded its cost");
        uint256 holderPaid = _claim(bob, id);
        assertLt(holderPaid, holderNet, "the unbacked cost takes the shortfall");
        assertEq(_claim(alice, id), 0);
        assertLe(paid + holderPaid, m.refundPool, "the payouts fit in the pool");
        assertLe(imd.balanceOf(alice) + imd.balanceOf(bob), pairStart + m.subsidy, "the pair takes at most the seed");
    }

    /// @dev Review 0b859a73: a short void must never refund an account more than it paid in. Carol pumps outcomes 0 and
    ///      2 and sells most of 0 back, so her remaining position is worth more at the final prices than it cost, and
    ///      Dave's stake is worth more too. Before the fix both were paid above their cost, out of Alice's refund.
    function test_review_shortVoidNeverPaysAboveCost() public {
        uint256 id = _create();
        _stake(dave, id, 1, 0, 100 ether);
        vm.prank(alice);
        c.buy(id, 3, 199.999 ether, type(uint256).max);
        vm.startPrank(carol);
        c.buy(id, 0, 199.999 ether, type(uint256).max);
        c.buy(id, 2, 199.999 ether, type(uint256).max);
        c.buy(id, 0, 199.999 ether, type(uint256).max);
        c.sell(id, 0, 192.5 ether, 0);
        vm.stopPrank();

        vm.warp(resolveTime + 30 days + 1);
        c.voidMarket(id);
        ConditionalsV2.Market memory m = c.getMarket(id);
        assertLt(m.refundPool, m.refundBase, "the void is short");

        uint256 carolNet = uint256(c.netIn(id, carol));
        uint256 daveNet = uint256(c.netIn(id, dave));
        uint256 aliceNet = uint256(c.netIn(id, alice));
        uint256 carolPaid = _claim(carol, id);
        uint256 davePaid = _claim(dave, id);
        uint256 alicePaid = _claim(alice, id);
        assertLe(carolPaid, carolNet, "a short void never refunds carol more than she paid in");
        assertLe(davePaid, daveNet, "a short void never refunds dave more than he paid in");
        assertLe(alicePaid, aliceNet, "a short void never refunds alice more than she paid in");
        // Carol's position and Dave's complete sets are worth at least their cost at the final prices, so both are
        // refunded exactly at cost. Alice, whose cost the pool does not back, takes the whole shortfall.
        assertEq(carolPaid, carolNet);
        assertEq(davePaid, daveNet);
        assertLt(alicePaid, aliceNet);
        assertLe(carolPaid + davePaid + alicePaid, m.refundPool, "the payouts fit in the pool");
        assertGe(imd.balanceOf(address(c)), c.owed(creator) + c.owed(builder));
    }

    /// @dev Whatever the trades, a void pays every claim, each at most the cost, in total at most the pool, and
    ///      exactly the cost when it is not short.
    function testFuzz_review_voidPaysEveryClaimWithinThePool(uint96[6] memory sizes, uint8[6] memory outcomes) public {
        uint256 id = _create();
        _stake(dave, id, 0, 1, 50 ether);
        address[3] memory traders = [alice, bob, carol];
        for (uint256 i; i < 6; ++i) {
            address who = traders[i % 3];
            uint8 o = outcomes[i] % 4;
            uint256 amount = bound(sizes[i], 1e15, 150 ether);
            vm.prank(who);
            try c.buy(id, o, amount, type(uint256).max) {} catch {}
            if (i % 2 == 1) {
                address seller = traders[(i + 2) % 3];
                uint256 held = c.sharesOf(id, seller)[o];
                if (held >= 1e15) {
                    vm.prank(seller);
                    try c.sell(id, o, held, 0) {} catch {}
                }
            }
        }
        vm.warp(resolveTime + 30 days + 1);
        c.voidMarket(id);
        ConditionalsV2.Market memory m = c.getMarket(id);
        address[4] memory all = [alice, bob, carol, dave];
        uint256 total;
        for (uint256 i; i < 4; ++i) {
            uint256 net = uint256(c.netIn(id, all[i]));
            uint256 paid = _claim(all[i], id);
            if (m.refundPool == m.refundBase) assertEq(paid, net);
            else assertLe(paid, net, "a short void never refunds more than the cost");
            total += paid;
        }
        assertLe(total, m.refundPool);
        assertGe(imd.balanceOf(address(c)), c.owed(creator) + c.owed(builder));
    }
}
