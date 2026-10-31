// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {MockIntake, MockSignerRegistry} from "./utils/Mocks.sol";
import {ConditionalsV2} from "../src/ConditionalsV2.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";
import {IOracleAttestation} from "../src/interfaces/IOracleAttestation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20 as IERC20Like} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Failure paths of the oracle callback, the owner's powers, market creation and the claim flow.
contract ConditionalsV2FailurePathsTest is Fixture {
    // ---- the oracle callback ---------------------------------------------------------------------------------------

    function _callback(bytes32 requestId, IOracleAttestation.Attestation memory a, bytes memory sig) internal {
        vm.prank(address(intake));
        c.onOracleResult(requestId, a, sig);
    }

    function _expectBad(bytes32 requestId, IOracleAttestation.Attestation memory a) internal {
        bytes memory sig = _sign(a, signerKey);
        vm.prank(address(intake));
        vm.expectRevert(ConditionalsV2.BadAttestation.selector);
        c.onOracleResult(requestId, a, sig);
    }

    function test_oracle_eachTamperedFieldIsRefused() public {
        uint256 id = _create();
        AskRef[] memory refs = _request(id);
        AskRef memory r = refs[0];
        IOracleAttestation.Attestation memory a;

        a = _attestation(id, r, true);
        a.answerType = 3;
        _expectBad(r.requestId, a);

        a = _attestation(id, r, true);
        a.answer = abi.encodePacked(uint8(1));
        _expectBad(r.requestId, a);

        a = _attestation(id, r, true);
        a.answer = abi.encode(uint256(2));
        _expectBad(r.requestId, a);

        a = _attestation(id, r, true);
        a.panelSize = 4;
        a.agreed = 4;
        _expectBad(r.requestId, a);

        a = _attestation(id, r, true);
        a.quorum = 3;
        a.agreed = 3;
        _expectBad(r.requestId, a);

        a = _attestation(id, r, true);
        a.agreed = 3;
        _expectBad(r.requestId, a);

        a = _attestation(id, r, true);
        a.agreed = 6;
        _expectBad(r.requestId, a);

        a = _attestation(id, r, true);
        a.expiresAt = uint64(block.timestamp - 1);
        _expectBad(r.requestId, a);

        a = _attestation(id, r, true);
        a.issuedAt = uint64(block.timestamp + 5 minutes + 1);
        _expectBad(r.requestId, a);

        // The other question's hash: an answer to a different pending request is refused.
        a = _attestation(id, refs[1], true);
        _expectBad(r.requestId, a);

        // A signature over different fields than delivered.
        a = _attestation(id, r, true);
        bytes memory sig = _sign(a, signerKey);
        a.answer = abi.encode(false);
        vm.prank(address(intake));
        vm.expectRevert(ConditionalsV2.BadAttestation.selector);
        c.onOracleResult(r.requestId, a, sig);

        // Nothing was consumed: the honest answer still lands.
        assertEq(c.getMarket(id).openAsks[0], 1);
        a = _attestation(id, r, true);
        _callback(r.requestId, a, _sign(a, signerKey));
        assertEq(c.getMarket(id).answers[0], 1);
        assertEq(c.getMarket(id).openAsks[0], 0);
    }

    function test_oracle_boundaryValuesAreAccepted() public {
        uint256 id = _create();
        AskRef[] memory refs = _request(id);
        IOracleAttestation.Attestation memory a = _attestation(id, refs[0], false);
        a.agreed = 4; // exactly the quorum
        a.expiresAt = uint64(block.timestamp); // expires this second
        a.issuedAt = uint64(block.timestamp + 5 minutes); // at the tolerance
        _callback(refs[0].requestId, a, _sign(a, signerKey));
        assertEq(c.getMarket(id).answers[0], 2, "a no is stored, not refused");
    }

    function test_oracle_wrongSenderAndUnknownIdAreRefused() public {
        uint256 id = _create();
        AskRef[] memory refs = _request(id);
        IOracleAttestation.Attestation memory a = _attestation(id, refs[0], true);
        bytes memory sig = _sign(a, signerKey);

        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.UnknownAsk.selector);
        c.onOracleResult(refs[0].requestId, a, sig);

        // Another Intake (anyone can deploy one and name this contract as the callback).
        MockIntake rogue = new MockIntake();
        vm.prank(address(rogue));
        vm.expectRevert(ConditionalsV2.UnknownAsk.selector);
        c.onOracleResult(refs[0].requestId, a, sig);

        vm.prank(address(intake));
        vm.expectRevert(ConditionalsV2.UnknownAsk.selector);
        c.onOracleResult(keccak256("unknown"), a, sig);

        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.UnknownAsk.selector);
        c.onFailure(refs[0].requestId, 1, bytes32("body_refused"), 0, 0, "");
    }

    function test_oracle_answerIsConsumedOnce() public {
        uint256 id = _create();
        AskRef[] memory refs = _request(id);
        IOracleAttestation.Attestation memory a = _attestation(id, refs[0], true);
        bytes memory sig = _sign(a, signerKey);
        _callback(refs[0].requestId, a, sig);
        vm.prank(address(intake));
        vm.expectRevert(ConditionalsV2.UnknownAsk.selector);
        c.onOracleResult(refs[0].requestId, a, sig);
        vm.prank(address(intake));
        vm.expectRevert(ConditionalsV2.UnknownAsk.selector);
        c.onFailure(refs[0].requestId, 2, bytes32("disagreed"), 0, 0, "");
        assertFalse(c.askable(id, 0), "an answered question is never asked again");
    }

    function test_oracle_failureOnlyClearsTheAsk() public {
        uint256 id = _create();
        _stake(alice, id, 0, 0, 5 ether);
        AskRef[] memory refs = _request(id);
        uint256 held = imd.balanceOf(address(c));
        vm.prank(address(intake));
        c.onFailure(refs[0].requestId, 1, bytes32("body_refused"), 0, 0, "");
        assertEq(imd.balanceOf(address(c)), held, "no money moves on a failure");
        assertEq(c.getMarket(id).answers[0], 0);
        assertEq(c.getMarket(id).openAsks[0], 0);
        assertEq(uint8(c.getMarket(id).status), uint8(ConditionalsV2.Status.Open));
        vm.prank(address(intake));
        vm.expectRevert(ConditionalsV2.UnknownAsk.selector);
        c.onFailure(refs[0].requestId, 1, bytes32("body_refused"), 0, 0, "");
    }

    function test_oracle_retryBeforeDelayIsRefusedAndLateAnswerIgnored() public {
        uint256 id = _create();
        AskRef[] memory first = _request(id);
        vm.expectRevert(ConditionalsV2.NothingToAsk.selector);
        c.requestResolution(id);
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 7200);
        AskRef[] memory second = _request(id);
        assertEq(second.length, 2, "both retried after the delay, paid by the caller");
        assertEq(c.getMarket(id).openAsks[0], 2);

        assertTrue(_answer(id, second[0], true));
        assertTrue(_answer(id, second[1], false));
        // The first ask's answer arrives after the question was answered: ignored, not reverted.
        vm.expectEmit(true, true, false, true, address(c));
        emit ConditionalsV2.AnswerIgnored(id, 0, first[0].requestId);
        assertTrue(_answer(id, first[0], false));
        assertEq(c.getMarket(id).answers[0], 1, "the first answer stands");
        assertEq(c.getMarket(id).openAsks[0], 0);
        c.settle(id);
        assertEq(c.getMarket(id).winner, 1);
        // After settlement a late answer is ignored too.
        assertTrue(_answer(id, first[1], true));
        assertEq(c.getMarket(id).answers[1], 2);
    }

    function test_oracle_erc1271SignerRegistry() public {
        MockSignerRegistry registry = new MockSignerRegistry();
        registry.set(signer, true);
        ConditionalsV2.OracleConfig memory cfg = _config();
        cfg.signer = address(registry);
        vm.prank(owner);
        c.proposeOracleConfig(cfg);
        vm.warp(block.timestamp + 3 days);
        vm.prank(owner);
        c.activateOracleConfig();
        closeTime = uint64(block.timestamp + 7 days);
        resolveTime = uint64(block.timestamp + 14 days);
        uint256 id = _create();
        AskRef[] memory refs = _request(id);
        assertTrue(_answer(id, refs[0], true), "a listed key answers through the registry");
        registry.set(signer, false);
        assertFalse(_answer(id, refs[1], true), "an unlisted key is refused");
    }

    function test_request_boundsAndUnknownMarkets() public {
        uint256 id = _create();
        vm.warp(resolveTime - 1);
        vm.expectRevert(ConditionalsV2.TooEarly.selector);
        c.requestResolution(id);
        vm.expectRevert(ConditionalsV2.UnknownMarket.selector);
        c.requestResolution(0);
        vm.expectRevert(ConditionalsV2.UnknownMarket.selector);
        c.requestResolution(id + 1);
        vm.warp(resolveTime + 30 days + 1);
        vm.expectRevert(ConditionalsV2.MarketNotOpen.selector);
        c.requestResolution(id);
        assertFalse(c.askable(id, 0));
        assertFalse(c.askable(id, 2));
    }

    function test_request_retryCallerWithoutFundsReverts() public {
        uint256 id = _create();
        AskRef[] memory refs = _request(id);
        vm.prank(address(intake));
        c.onFailure(refs[0].requestId, 1, bytes32("x"), 0, 0, "");
        address poor = makeAddr("poor");
        vm.prank(poor);
        vm.expectRevert();
        c.requestResolution(id);
    }

    // ---- settlement, void and claims -------------------------------------------------------------------------------

    function test_settle_needsBothAnswers() public {
        uint256 id = _create();
        _stake(alice, id, 0, 0, 1 ether);
        vm.expectRevert(ConditionalsV2.NotSettleable.selector);
        c.settle(id);
        AskRef[] memory refs = _request(id);
        assertTrue(_answer(id, refs[0], true));
        vm.expectRevert(ConditionalsV2.NotSettleable.selector);
        c.settle(id);
        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.NotSettleable.selector);
        c.claim(id);
        // Half-answered and past the deadline: void is the way out.
        vm.warp(resolveTime + 30 days + 1 days + 1);
        c.voidMarket(id);
        vm.expectRevert(ConditionalsV2.NotSettleable.selector);
        c.settle(id);
        vm.expectRevert(ConditionalsV2.NotVoidable.selector);
        c.voidMarket(id);
    }

    function test_settledMarketCannotBeVoidedOrTraded() public {
        uint256 id = _create();
        _stake(alice, id, 0, 0, 1 ether);
        _resolve(id, true, true);
        vm.warp(resolveTime + 31 days);
        assertFalse(c.voidable(id), "an answered market is never voided");
        vm.expectRevert(ConditionalsV2.NotVoidable.selector);
        c.voidMarket(id);
        c.settle(id);
        vm.expectRevert(ConditionalsV2.NotSettleable.selector);
        c.settle(id);
        vm.expectRevert(ConditionalsV2.NotVoidable.selector);
        c.voidMarket(id);
        vm.expectRevert(ConditionalsV2.MarketNotOpen.selector);
        c.requestResolution(id);
        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.MarketNotOpen.selector);
        c.stakeConditional(id, 0, 0, 1 ether, 0);
        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.MarketNotOpen.selector);
        c.exit(id, 0);
    }

    function test_void_beforeDeadlineRefused() public {
        uint256 id = _create();
        vm.warp(resolveTime + 30 days);
        assertFalse(c.voidable(id));
        vm.expectRevert(ConditionalsV2.NotVoidable.selector);
        c.voidMarket(id);
        vm.expectRevert(ConditionalsV2.UnknownMarket.selector);
        c.voidMarket(7);
    }

    function test_void_nobodyTradedReturnsEverythingToTheCreator() public {
        uint256 before = imd.balanceOf(creator);
        uint256 id = _create();
        vm.warp(resolveTime + 30 days + 1);
        c.voidMarket(id);
        assertEq(imd.balanceOf(creator), before, "seed and budget back");
        assertEq(imd.balanceOf(address(c)), 0);
        assertEq(_claim(creator, id), 0, "the creator is paid by the void, not by a claim");
        assertFalse(c.claimed(id, creator));
    }

    function test_claim_loserGetsNothingAndWinnerOnce() public {
        uint256 id = _create();
        _stake(alice, id, 0, 0, 2 ether);
        _stake(bob, id, 0, 1, 2 ether);
        assertEq(c.claimable(id, alice), 0, "nothing claimable before the answers");
        _resolve(id, true, true);
        assertEq(c.claimable(id, alice), c.sharesOf(id, alice)[0], "a claim would settle");
        assertEq(c.claimable(id, bob), 0);
        assertEq(_claim(alice, id), c.sharesOf(id, alice)[0]);
        assertEq(c.claimable(id, alice), 0);
        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.AlreadyClaimed.selector);
        c.claim(id);
        uint256 held = imd.balanceOf(bob);
        assertEq(_claim(bob, id), 0, "the loser is paid nothing");
        assertEq(imd.balanceOf(bob), held);
        assertFalse(c.claimed(id, bob), "an empty claim marks nothing");
    }

    function test_claim_openMarketAndUnknownMarketAreRefused() public {
        uint256 id = _create();
        _stake(alice, id, 0, 0, 2 ether);
        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.NotSettleable.selector);
        c.claim(id);
        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.UnknownMarket.selector);
        c.claim(id + 1);
        assertEq(c.claimable(id + 1, alice), 0);
    }

    function test_claim_voidRefundIsPaidOnce() public {
        uint256 id = _create();
        _stake(alice, id, 0, 0, 5 ether);
        vm.warp(resolveTime + 30 days + 1);
        c.voidMarket(id);
        uint256 refund = uint256(c.netIn(id, alice));
        assertEq(c.claimable(id, alice), refund);
        assertEq(_claim(alice, id), refund);
        assertEq(c.claimable(id, alice), 0);
        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.AlreadyClaimed.selector);
        c.claim(id);
        assertEq(uint8(c.getMarket(id).status), uint8(ConditionalsV2.Status.Voided));
    }

    /// @dev A failed payment to a blocked claimant leaves the claim standing: nothing is marked or lost.
    function test_claim_blockedAccountRevertsAndKeepsItsClaim() public {
        uint256 id = _create();
        _stake(alice, id, 0, 0, 5 ether);
        _resolve(id, true, true);
        c.settle(id);
        uint256 due = c.claimable(id, alice);
        imd.setBlocked(alice, true);
        vm.prank(alice);
        vm.expectRevert(bytes("blocked"));
        c.claim(id);
        assertFalse(c.claimed(id, alice));
        imd.setBlocked(alice, false);
        assertEq(_claim(alice, id), due);
    }

    function test_withdrawOwed_paysOnceAndRefusesNothing() public {
        uint256 id = _create();
        _stake(alice, id, 0, 0, 10 ether);
        uint256 due = c.owed(builder);
        assertGt(due, 0);
        vm.prank(builder);
        assertEq(c.withdrawOwed(), due);
        assertEq(imd.balanceOf(builder), due);
        vm.prank(builder);
        vm.expectRevert(ConditionalsV2.NothingToClaim.selector);
        c.withdrawOwed();
        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.NothingToClaim.selector);
        c.withdrawOwed();
    }

    function test_settle_blockedCreatorIsCreditedNotBlocking() public {
        uint256 id = _create();
        _stake(alice, id, 0, 0, 10 ether);
        _resolve(id, false, false);
        imd.setBlocked(creator, true);
        uint256 owedBefore = c.owed(creator);
        _claim(alice, id); // settles inside the claim
        assertGt(c.owed(creator), owedBefore, "residual and budget deferred to owed");
        imd.setBlocked(creator, false);
        vm.prank(creator);
        c.withdrawOwed();
    }

    // ---- trading inputs --------------------------------------------------------------------------------------------

    function test_trade_invalidChoicesAndSizes() public {
        uint256 id = _create();
        vm.startPrank(alice);
        vm.expectRevert(ConditionalsV2.InvalidChoice.selector);
        c.stakeConditional(id, 2, 0, 1 ether, 0);
        vm.expectRevert(ConditionalsV2.InvalidChoice.selector);
        c.stakeConditional(id, 0, 2, 1 ether, 0);
        vm.expectRevert(ConditionalsV2.TradeTooSmall.selector);
        c.stakeConditional(id, 0, 0, 1e15 - 1, 0);
        vm.expectRevert(ConditionalsV2.InvalidChoice.selector);
        c.buy(id, 4, 1 ether, type(uint256).max);
        vm.expectRevert(ConditionalsV2.TradeTooSmall.selector);
        c.buy(id, 0, 1e15 - 1, type(uint256).max);
        vm.expectRevert(ConditionalsV2.InvalidChoice.selector);
        c.sell(id, 4, 1 ether, 0);
        vm.expectRevert(ConditionalsV2.TradeTooSmall.selector);
        c.sell(id, 0, 1e15 - 1, 0);
        vm.expectRevert(ConditionalsV2.NoPosition.selector);
        c.exit(id, 0);
        vm.expectRevert(ConditionalsV2.UnknownMarket.selector);
        c.buy(0, 0, 1 ether, type(uint256).max);
        vm.expectRevert(ConditionalsV2.UnknownMarket.selector);
        c.stakeConditional(2, 0, 0, 1 ether, 0);
        vm.stopPrank();
        vm.expectRevert(ConditionalsV2.ZeroAddress.selector);
        c.stakeFor(address(0), id, 0, 0, 1 ether, 0);
    }

    /// @dev The largest size `buy` can price as a buy. Sizes above type(int256).max are reported in .imd-findings.json.
    function test_buy_hugeSizesInsideInt256AreRefused() public {
        uint256 id = _create();
        uint256 held = imd.balanceOf(alice);
        vm.startPrank(alice);
        vm.expectRevert();
        c.buy(id, 0, uint256(type(int256).max), type(uint256).max);
        vm.expectRevert(ConditionalsV2.PriceLimit.selector);
        c.buy(id, 0, 20 * B + 1, type(uint256).max);
        vm.stopPrank();
        assertEq(imd.balanceOf(alice), held);
        assertEq(c.sharesOf(id, alice)[0], 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_buy_neverCreditsMoreThanItChargesFor(uint256 shares, uint8 outcome) public {
        shares = bound(shares, 1e15, uint256(type(int256).max));
        uint256 id = _create();
        uint256 held = imd.balanceOf(alice);
        vm.prank(alice);
        try c.buy(id, outcome % 4, shares, type(uint256).max) returns (uint256 cost, uint256 fee) {
            assertLe(shares, 20 * B, "the spread bound caps a buy");
            assertEq(c.sharesOf(id, alice)[outcome % 4], shares);
            assertEq(c.netIn(id, alice), int256(cost));
            assertEq(held - imd.balanceOf(alice), cost + fee);
            // A share is worth at most 1 IMD, and C(q) grows slower than q.
            assertLe(cost, shares);
        } catch {
            assertEq(c.sharesOf(id, alice)[outcome % 4], 0);
            assertEq(imd.balanceOf(alice), held);
        }
    }

    function test_sell_moreThanHeldReverts() public {
        uint256 id = _create();
        vm.prank(alice);
        c.buy(id, 0, 1 ether, type(uint256).max);
        vm.prank(bob);
        vm.expectRevert();
        c.sell(id, 0, 1 ether, 0);
        vm.prank(alice);
        vm.expectRevert();
        c.sell(id, 0, 1 ether + 1, 0);
    }

    function test_stake_tooLargeForTheMakerReverts() public {
        uint256 id = _create();
        vm.prank(alice);
        vm.expectRevert();
        c.stakeConditional(id, 0, 0, 900 ether, 0);
    }

    function test_trade_withoutApprovalOrBalanceReverts() public {
        uint256 id = _create();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        c.stakeConditional(id, 0, 0, 1 ether, 0);
        vm.prank(stranger);
        vm.expectRevert();
        c.buy(id, 0, 1 ether, type(uint256).max);
    }

    // ---- creation --------------------------------------------------------------------------------------------------

    function test_create_refusesBadText() public {
        vm.startPrank(creator);
        vm.expectRevert(ConditionalsV2.InvalidText.selector);
        c.createMarket("", OUTCOME, RULES, closeTime, resolveTime, 1 ether, B);
        vm.expectRevert(ConditionalsV2.InvalidText.selector);
        c.createMarket(CONDITION, "say \"yes\"", RULES, closeTime, resolveTime, 1 ether, B);
        vm.expectRevert(ConditionalsV2.InvalidText.selector);
        c.createMarket(CONDITION, OUTCOME, "back\\slash rules", closeTime, resolveTime, 1 ether, B);
        vm.expectRevert(ConditionalsV2.InvalidText.selector);
        c.createMarket(CONDITION, "line\nbreak", RULES, closeTime, resolveTime, 1 ether, B);
        vm.expectRevert(ConditionalsV2.InvalidText.selector);
        c.createMarket(CONDITION, unicode"café opens", RULES, closeTime, resolveTime, 1 ether, B);
        // Rules that are exactly an address would be lowercased by the oracle: a rule needs a space.
        vm.expectRevert(ConditionalsV2.InvalidText.selector);
        c.createMarket(CONDITION, OUTCOME, "0xABCDEF", closeTime, resolveTime, 1 ether, B);
        vm.expectRevert(ConditionalsV2.InvalidText.selector);
        c.createMarket(_repeat("a ", 141), OUTCOME, RULES, closeTime, resolveTime, 1 ether, B);
        vm.expectRevert(ConditionalsV2.InvalidText.selector);
        c.createMarket(CONDITION, OUTCOME, _repeat("a ", 251), closeTime, resolveTime, 1 ether, B);
        // At the limits it is accepted.
        c.createMarket(_repeat("a ", 140), _repeat("b ", 140), _repeat("c ", 250), closeTime, resolveTime, 1 ether, B);
        vm.stopPrank();
    }

    function test_create_refusesBadTimes() public {
        vm.startPrank(creator);
        vm.expectRevert(ConditionalsV2.InvalidTimes.selector);
        c.createMarket(CONDITION, OUTCOME, RULES, uint64(block.timestamp), resolveTime, 1 ether, B);
        vm.expectRevert(ConditionalsV2.InvalidTimes.selector);
        c.createMarket(CONDITION, OUTCOME, RULES, closeTime, closeTime - 1, 1 ether, B);
        vm.expectRevert(ConditionalsV2.InvalidTimes.selector);
        c.createMarket(CONDITION, OUTCOME, RULES, closeTime, uint64(block.timestamp + 730 days + 1), 1 ether, B);
        // closeTime == resolveTime and the furthest horizon are fine.
        c.createMarket(CONDITION, OUTCOME, RULES, closeTime, closeTime, 1 ether, B);
        c.createMarket(CONDITION, OUTCOME, RULES, closeTime, uint64(block.timestamp + 730 days), 1 ether, B);
        vm.stopPrank();
    }

    function test_create_withoutFundsReverts() public {
        address poor = makeAddr("poor");
        vm.prank(poor);
        vm.expectRevert();
        c.createMarket(CONDITION, OUTCOME, RULES, closeTime, resolveTime, 1 ether, B);
        assertEq(c.marketCount(), 0);
    }

    function _repeat(string memory s, uint256 n) internal pure returns (string memory out) {
        for (uint256 i; i < n; ++i) {
            out = string.concat(out, s);
        }
    }

    // ---- the owner -------------------------------------------------------------------------------------------------

    function test_owner_onlyOwnerConfigures() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        c.proposeOracleConfig(_config());
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        c.activateOracleConfig();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        c.setFeeRecipient(alice);
        vm.stopPrank();
        vm.prank(owner);
        vm.expectRevert(ConditionalsV2.ZeroAddress.selector);
        c.setFeeRecipient(address(0));
    }

    function test_owner_configDelayAndWindow() public {
        ConditionalsV2.OracleConfig memory cfg = _config();
        cfg.panelSize = 9;
        cfg.quorum = 7;
        vm.prank(owner);
        vm.expectRevert(ConditionalsV2.TooEarly.selector);
        c.activateOracleConfig();
        uint256 t0 = 1_790_000_000; // the fixture's clock; block.timestamp is re-read after a warp under via-IR
        vm.prank(owner);
        c.proposeOracleConfig(cfg);
        assertEq(c.pendingOracleConfigAt(), t0 + 3 days);
        vm.warp(t0 + 3 days - 1);
        vm.prank(owner);
        vm.expectRevert(ConditionalsV2.TooEarly.selector);
        c.activateOracleConfig();
        vm.warp(t0 + 10 days + 1);
        vm.prank(owner);
        vm.expectRevert(ConditionalsV2.ConfigExpired.selector);
        c.activateOracleConfig();

        vm.prank(owner);
        c.proposeOracleConfig(cfg);
        vm.warp(t0 + 13 days + 1);
        vm.prank(owner);
        c.activateOracleConfig();
        (,,, uint16 panel, uint16 quorum,) = c.oracleConfig();
        assertEq(panel, 9);
        assertEq(quorum, 7);
        vm.prank(owner);
        vm.expectRevert(ConditionalsV2.TooEarly.selector);
        c.activateOracleConfig();
    }

    function test_owner_invalidConfigsRefused() public {
        ConditionalsV2.OracleConfig memory cfg;
        vm.startPrank(owner);
        cfg = _config();
        cfg.intake = IIntake(address(0));
        vm.expectRevert(ConditionalsV2.ZeroAddress.selector);
        c.proposeOracleConfig(cfg);
        cfg = _config();
        cfg.signer = address(0);
        vm.expectRevert(ConditionalsV2.ZeroAddress.selector);
        c.proposeOracleConfig(cfg);
        cfg = _config();
        cfg.action = bytes32(0);
        vm.expectRevert(ConditionalsV2.InvalidConfig.selector);
        c.proposeOracleConfig(cfg);
        cfg = _config();
        cfg.price = 0;
        vm.expectRevert(ConditionalsV2.InvalidConfig.selector);
        c.proposeOracleConfig(cfg);
        cfg = _config();
        cfg.price = 10 ether + 1;
        vm.expectRevert(ConditionalsV2.InvalidConfig.selector);
        c.proposeOracleConfig(cfg);
        cfg = _config();
        cfg.panelSize = 4;
        cfg.quorum = 4;
        vm.expectRevert(ConditionalsV2.InvalidConfig.selector);
        c.proposeOracleConfig(cfg);
        cfg = _config();
        cfg.panelSize = 101;
        vm.expectRevert(ConditionalsV2.InvalidConfig.selector);
        c.proposeOracleConfig(cfg);
        cfg = _config();
        cfg.quorum = 1;
        vm.expectRevert(ConditionalsV2.InvalidConfig.selector);
        c.proposeOracleConfig(cfg);
        cfg = _config();
        cfg.quorum = 6;
        vm.expectRevert(ConditionalsV2.InvalidConfig.selector);
        c.proposeOracleConfig(cfg);
        vm.stopPrank();
    }

    function test_owner_newConfigAppliesOnlyToNewMarkets() public {
        uint256 oldId = _create();
        ConditionalsV2.OracleConfig memory cfg = _config();
        cfg.panelSize = 9;
        cfg.quorum = 7;
        cfg.price = 2 ether;
        vm.prank(owner);
        c.proposeOracleConfig(cfg);
        vm.warp(block.timestamp + 3 days);
        vm.prank(owner);
        c.activateOracleConfig();
        // The old market's answers still need only its own panel.
        AskRef[] memory refs = _request(oldId);
        assertTrue(_answer(oldId, refs[0], true));
        // A creator's maxBudget protects against the new price.
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ConditionalsV2.BudgetTooHigh.selector, 4 ether, 1 ether));
        c.createMarket(
            CONDITION, OUTCOME, RULES, uint64(block.timestamp + 1 days), uint64(block.timestamp + 2 days), 1 ether, B
        );
    }

    function test_owner_twoStepTransfer() public {
        vm.prank(owner);
        c.transferOwnership(alice);
        assertEq(c.owner(), owner);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        c.acceptOwnership();
        vm.prank(alice);
        c.acceptOwnership();
        assertEq(c.owner(), alice);
    }

    function test_constructor_refusesZeroAddresses() public {
        vm.expectRevert(ConditionalsV2.ZeroAddress.selector);
        new ConditionalsV2(owner, imd_(address(0)), IIntake(address(intake)), signer, builder);
        vm.expectRevert(ConditionalsV2.ZeroAddress.selector);
        new ConditionalsV2(owner, imd_(address(imd)), IIntake(address(intake)), signer, address(0));
        vm.expectRevert(ConditionalsV2.ZeroAddress.selector);
        new ConditionalsV2(owner, imd_(address(imd)), IIntake(address(0)), signer, builder);
        vm.expectRevert(ConditionalsV2.ZeroAddress.selector);
        new ConditionalsV2(owner, imd_(address(imd)), IIntake(address(intake)), address(0), builder);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new ConditionalsV2(address(0), imd_(address(imd)), IIntake(address(intake)), signer, builder);
    }

    function imd_(address a) internal pure returns (IERC20Like) {
        return IERC20Like(a);
    }
}
