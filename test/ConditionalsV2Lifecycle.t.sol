// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ConditionalsV2} from "../src/ConditionalsV2.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";
import {IOracleAttestation} from "../src/interfaces/IOracleAttestation.sol";
import {MockIMD, MockIntake} from "./utils/Mocks.sol";

/// @dev Drives two markets through their whole life in random order: trades, time, oracle asks and answers
///      (including a single answer and failures), settlement, void, claims and fee withdrawals.
contract LifecycleHandler is Test {
    ConditionalsV2 public c;
    MockIMD public imd;
    MockIntake public intake;
    uint256 internal signerKey;
    uint256[2] public ids;
    address[] public actors;
    address public creator;
    address public builder;

    uint256 public now_;

    /// @dev Ghosts.
    mapping(uint256 => uint8) public seenStatus;
    mapping(uint256 => mapping(address => uint256)) public paid;
    bool public overpaid;
    bool public reopened;
    bool public settleClaimWrong;
    uint256 public settles;
    uint256 public voids;
    uint256 public claims;

    constructor(
        ConditionalsV2 c_,
        MockIMD imd_,
        MockIntake intake_,
        uint256 key,
        uint256[2] memory ids_,
        address creator_,
        address builder_,
        uint256 start
    ) {
        c = c_;
        imd = imd_;
        intake = intake_;
        signerKey = key;
        ids = ids_;
        creator = creator_;
        builder = builder_;
        now_ = start;
        for (uint256 i; i < 4; ++i) {
            address a = makeAddr(string.concat("lifecycle-actor", vm.toString(i)));
            actors.push(a);
            imd.mint(a, 1_000_000 ether);
            vm.prank(a);
            imd.approve(address(c), type(uint256).max);
        }
        imd.mint(address(this), 1_000 ether);
        imd.approve(address(c), type(uint256).max);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _id(uint256 sel) internal view returns (uint256) {
        return ids[sel % 2];
    }

    function _actor(uint256 who) internal view returns (address) {
        return actors[who % actors.length];
    }

    function _track(uint256 id) internal {
        uint8 s = uint8(c.getMarket(id).status);
        if (seenStatus[id] != 0 && s != seenStatus[id]) reopened = true;
        if (s != 0) seenStatus[id] = s;
    }

    // ---- trading ---------------------------------------------------------------------------------------------------

    function stake(uint256 sel, uint256 who, uint8 world, uint8 side, uint256 amount) external {
        uint256 id = _id(sel);
        vm.prank(_actor(who));
        try c.stakeConditional(id, world % 2, side % 2, bound(amount, 1e15, 200 ether), 0) {} catch {}
    }

    function buy(uint256 sel, uint256 who, uint8 outcome, uint256 shares) external {
        uint256 id = _id(sel);
        vm.prank(_actor(who));
        try c.buy(id, outcome % 4, bound(shares, 1e15, 150 ether), type(uint256).max) {} catch {}
    }

    function sell(uint256 sel, uint256 who, uint8 outcome, uint256 shares) external {
        uint256 id = _id(sel);
        address a = _actor(who);
        uint256 held = c.sharesOf(id, a)[outcome % 4];
        if (held < 1e15) return;
        vm.prank(a);
        try c.sell(id, outcome % 4, bound(shares, 1e15, held), 0) {} catch {}
    }

    function exit(uint256 sel, uint256 who) external {
        uint256 id = _id(sel);
        vm.prank(_actor(who));
        try c.exit(id, 0) {} catch {}
    }

    // ---- time ------------------------------------------------------------------------------------------------------

    function advance(uint256 dt) external {
        now_ += bound(dt, 1, 3 days);
        vm.warp(now_);
        vm.roll(block.number + 100);
    }

    function jumpPastVoid(uint256 sel) external {
        uint256 v = c.getMarket(_id(sel)).voidAfter + 1 days + 1;
        if (now_ < v) now_ = v;
        vm.warp(now_);
    }

    // ---- the oracle ------------------------------------------------------------------------------------------------

    /// @dev Asks what the market still needs and answers some of it: `mode` 0 both, 1 the condition only, 2 a
    ///      failure for the first ask.
    function resolve(uint256 sel, bool condition, bool outcome, uint8 mode) external {
        uint256 id = _id(sel);
        ConditionalsV2.Market memory m = c.getMarket(id);
        if (now_ < m.resolveTime) {
            now_ = m.resolveTime;
            vm.warp(now_);
        }
        if (m.status != ConditionalsV2.Status.Open || now_ > m.voidAfter) return;
        bool[2] memory wanted = [c.askable(id, 0), c.askable(id, 1)];
        if (!wanted[0] && !wanted[1]) return;
        uint256 before = intake.count();
        uint256 windowBlock = block.number - 10;
        c.requestResolution(id);
        uint256 k;
        for (uint8 q; q < 2; ++q) {
            if (!wanted[q]) continue;
            bytes32 requestId = intake.requestIds(before + k);
            ++k;
            if (mode % 3 == 2 && k == 1) {
                intake.fail(requestId, 2, bytes32("disagreed"));
                continue;
            }
            if (mode % 3 == 1 && q == 1) continue;
            IOracleAttestation.Attestation memory a = _attestation(id, q, windowBlock, q == 0 ? condition : outcome);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, c.attestationDigest(a));
            intake.complete(requestId, abi.encode(a, abi.encodePacked(r, s, v)));
        }
        _track(id);
    }

    function _attestation(uint256 id, uint8 q, uint256 windowBlock, bool value)
        internal
        view
        returns (IOracleAttestation.Attestation memory a)
    {
        a.requestId = keccak256(abi.encode(id, q, windowBlock));
        a.chainId = 1;
        a.questionHash = keccak256(bytes(c.questionDocument(id, q, windowBlock)));
        a.answer = abi.encode(value);
        a.fromBlock = uint64(windowBlock);
        a.toBlock = uint64(windowBlock);
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 4;
        a.issuedAt = uint64(now_);
        a.expiresAt = uint64(now_ + 1 days);
    }

    // ---- endings ---------------------------------------------------------------------------------------------------

    function settle(uint256 sel) external {
        uint256 id = _id(sel);
        try c.settle(id) {
            ++settles;
        } catch {}
        _track(id);
    }

    function voidIt(uint256 sel) external {
        uint256 id = _id(sel);
        try c.voidMarket(id) {
            ++voids;
        } catch {}
        _track(id);
    }

    function claim(uint256 sel, uint256 who) external {
        uint256 id = _id(sel);
        address a = _actor(who);
        int256 net = c.netIn(id, a);
        vm.prank(a);
        try c.claim(id) returns (uint256 amount) {
            ++claims;
            paid[id][a] += amount;
            ConditionalsV2.Market memory m = c.getMarket(id);
            if (m.status == ConditionalsV2.Status.Voided) {
                // A void refunds at most what the account put in, net of what it took out, fees excluded.
                if (net <= 0 || amount > uint256(net)) overpaid = true;
            } else if (amount != c.sharesOf(id, a)[m.winner]) {
                settleClaimWrong = true;
            }
        } catch {}
        _track(id);
    }

    function withdraw(bool fromCreator) external {
        vm.prank(fromCreator ? creator : builder);
        try c.withdrawOwed() {} catch {}
    }
}

contract ConditionalsV2LifecycleInvariantTest is Test {
    ConditionalsV2 internal c;
    MockIMD internal imd;
    MockIntake internal intake;
    LifecycleHandler internal h;
    uint256[2] internal ids;
    address internal creator = makeAddr("creator");
    address internal builder = makeAddr("builder");
    uint256 internal constant SIGNER_KEY = 0xA11CE;
    uint256 internal creatorStart;

    function setUp() public {
        uint256 start = 1_790_000_000;
        vm.warp(start);
        vm.roll(26_000_000);
        imd = new MockIMD();
        intake = new MockIntake();
        c = new ConditionalsV2(
            address(this), IERC20(address(imd)), IIntake(address(intake)), vm.addr(SIGNER_KEY), builder
        );
        imd.mint(creator, 1000 ether);
        creatorStart = 1000 ether;
        vm.startPrank(creator);
        imd.approve(address(c), type(uint256).max);
        ids[0] = c.createMarket(
            "The condition happens",
            "The outcome happens",
            "Use a public source for both statements.",
            uint64(start + 2 days),
            uint64(start + 3 days),
            1 ether,
            1.44 ether
        );
        ids[1] = c.createMarket(
            "The other condition happens",
            "The other outcome happens",
            "Use a public source for both statements.",
            uint64(start + 4 days),
            uint64(start + 5 days),
            1 ether,
            20 ether
        );
        vm.stopPrank();
        h = new LifecycleHandler(c, imd, intake, SIGNER_KEY, ids, creator, builder, start);
        targetContract(address(h));
    }

    /// @dev What the contract still owes for one market: to the maker and complete sets while open, to unclaimed
    ///      winners after a settlement, to unclaimed refunds after a void.
    function _liability(uint256 id) internal view returns (uint256 owes) {
        ConditionalsV2.Market memory m = c.getMarket(id);
        if (m.status == ConditionalsV2.Status.Open) return m.makerBalance + m.sets + m.budget;
        for (uint256 i; i < h.actorCount(); ++i) {
            address a = h.actors(i);
            owes += c.claimable(id, a);
        }
    }

    /// @dev Conservation: the contract always holds every IMD it could be asked to pay, across both markets.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 80
    function invariant_holdsEverythingItOwes() public view {
        uint256 owes = _liability(ids[0]) + _liability(ids[1]) + c.owed(creator) + c.owed(builder);
        assertGe(imd.balanceOf(address(c)), owes);
    }

    /// @dev Every account with a claim can actually be paid: no claim is larger than the contract's balance.
    function invariant_everyClaimIsPayable() public view {
        uint256 bal = imd.balanceOf(address(c));
        for (uint256 k; k < 2; ++k) {
            for (uint256 i; i < h.actorCount(); ++i) {
                assertLe(c.claimable(ids[k], h.actors(i)), bal);
            }
        }
    }

    /// @dev A settled or voided market never changes state again.
    function invariant_finishedNeverReopens() public view {
        assertFalse(h.reopened());
    }

    /// @dev A void never refunds an account more than its net IMD in; a settlement pays exactly the winning shares.
    function invariant_claimsAreExact() public view {
        assertFalse(h.overpaid());
        assertFalse(h.settleClaimWrong());
    }

    /// @dev The creator never loses more than the seeds plus the oracle budgets: owed is never inflated by a
    ///      negative residual cast to uint.
    function invariant_creatorLossBounded() public view {
        uint256 seeds = c.getMarket(ids[0]).subsidy + c.getMarket(ids[1]).subsidy;
        uint256 has = imd.balanceOf(creator) + c.owed(creator);
        assertGe(has + seeds + 2 ether, creatorStart);
        assertLe(c.owed(creator), imd.totalSupply());
    }

    /// @dev A finished market's books are closed: a settled one records a winner in range, a void's pool never
    ///      exceeds what it has to refund.
    function invariant_endStateConsistent() public view {
        for (uint256 k; k < 2; ++k) {
            ConditionalsV2.Market memory m = c.getMarket(ids[k]);
            if (m.status == ConditionalsV2.Status.Settled) {
                assertLt(m.winner, 4);
                assertEq(m.budget, 0);
            }
            if (m.status == ConditionalsV2.Status.Voided) {
                assertLe(m.refundPool, m.refundBase);
                assertEq(m.budget, 0);
            }
        }
    }

    /// @dev The handler's own paths reach every ending, so the invariants above are not checked only on open markets.
    function test_handlerReachesSettlementVoidAndClaims() public {
        h.stake(0, 0, 0, 0, 5 ether);
        h.stake(0, 1, 0, 1, 3 ether);
        h.stake(1, 2, 1, 0, 7 ether);
        h.resolve(0, true, true, 0);
        h.settle(0);
        assertEq(uint8(c.getMarket(ids[0]).status), uint8(ConditionalsV2.Status.Settled));
        h.claim(0, 0);
        h.claim(0, 1);
        assertGt(h.paid(ids[0], h.actors(0)), 5 ether, "the winner was paid");
        assertEq(h.paid(ids[0], h.actors(1)), 0, "the loser was not");
        h.resolve(1, true, true, 1); // the condition is answered, the outcome never is
        h.jumpPastVoid(1);
        h.voidIt(1);
        assertEq(uint8(c.getMarket(ids[1]).status), uint8(ConditionalsV2.Status.Voided));
        h.claim(1, 2);
        assertGt(h.paid(ids[1], h.actors(2)), 6.5 ether, "the void refunded the stake less fees");
        assertEq(h.claims(), 2);
        h.withdraw(true);
        h.withdraw(false);
        invariant_holdsEverythingItOwes();
        invariant_claimsAreExact();
        invariant_creatorLossBounded();
        assertEq(c.owed(creator), 0);
    }

    function afterInvariant() external view {
        // Not an assertion on coverage, but a sequence that never finishes a market proves little; log it.
        h.settles();
        h.voids();
        h.claims();
    }
}
