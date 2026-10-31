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
        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.NothingToClaim.selector);
        c.claim(id);
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
        vm.prank(carol);
        vm.expectRevert(ConditionalsV2.NothingToClaim.selector);
        c.claim(id);
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
        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.NothingToClaim.selector);
        c.claim(id);
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
        bool ok = _deliver(refs[0].requestId, _attestation(id, refs[0], true), _sign(_attestation(id, refs[0], true), 0xB0B));
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
}
