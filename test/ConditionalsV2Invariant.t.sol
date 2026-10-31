// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ConditionalsV2} from "../src/ConditionalsV2.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";
import {MockIMD, MockIntake} from "./utils/Mocks.sol";

/// @dev Random actors trade one market. Tracks what the design's invariants need.
contract Handler is Test {
    ConditionalsV2 public c;
    MockIMD public imd;
    uint256 public id;
    address[] public actors;

    constructor(ConditionalsV2 c_, MockIMD imd_, uint256 id_) {
        c = c_;
        imd = imd_;
        id = id_;
        for (uint256 i; i < 4; ++i) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(a);
            imd.mint(a, 1_000_000 ether);
            vm.prank(a);
            imd.approve(address(c), type(uint256).max);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function stake(uint256 who, uint8 world, uint8 side, uint256 amount) external {
        address a = actors[who % actors.length];
        vm.prank(a);
        try c.stakeConditional(id, world % 2, side % 2, bound(amount, 1e15, 300 ether), 0) {} catch {}
    }

    function buy(uint256 who, uint8 outcome, uint256 shares) external {
        address a = actors[who % actors.length];
        vm.prank(a);
        try c.buy(id, outcome % 4, bound(shares, 1e15, 200 ether), type(uint256).max) {} catch {}
    }

    function sell(uint256 who, uint8 outcome, uint256 shares) external {
        address a = actors[who % actors.length];
        uint256 held = c.sharesOf(id, a)[outcome % 4];
        if (held < 1e15) return;
        vm.prank(a);
        try c.sell(id, outcome % 4, bound(shares, 1e15, held), 0) {} catch {}
    }

    function exit(uint256 who) external {
        address a = actors[who % actors.length];
        vm.prank(a);
        try c.exit(id, 0) {} catch {}
    }
}

contract ConditionalsV2InvariantTest is Test {
    ConditionalsV2 internal c;
    MockIMD internal imd;
    Handler internal h;
    uint256 internal id;
    address internal creator = makeAddr("creator");
    address internal builder = makeAddr("builder");

    function setUp() public {
        vm.warp(1_790_000_000);
        vm.roll(26_000_000);
        imd = new MockIMD();
        MockIntake intake = new MockIntake();
        c = new ConditionalsV2(address(this), IERC20(address(imd)), IIntake(address(intake)), vm.addr(1), builder);
        imd.mint(creator, 1000 ether);
        vm.startPrank(creator);
        imd.approve(address(c), type(uint256).max);
        id = c.createMarket(
            "The condition happens",
            "The outcome happens",
            "Use a public source for both statements.",
            uint64(block.timestamp + 365 days),
            uint64(block.timestamp + 366 days),
            1 ether,
            1.44 ether
        );
        vm.stopPrank();
        h = new Handler(c, imd, id);
        targetContract(address(h));
    }

    /// @dev I1: the contract holds everything it accounts for.
    function invariant_balanceCoversEverything() public view {
        ConditionalsV2.Market memory m = c.getMarket(id);
        uint256 owed = c.owed(creator) + c.owed(builder);
        assertGe(imd.balanceOf(address(c)), m.makerBalance + m.sets + m.budget + owed);
    }

    /// @dev I2: the maker covers every outcome.
    function invariant_makerSolvent() public view {
        ConditionalsV2.Market memory m = c.getMarket(id);
        for (uint256 i; i < 4; ++i) {
            assertGe(int256(m.makerBalance), m.q[i]);
        }
    }

    /// @dev I3: shares held equal q + sets.
    function invariant_sharesMatchTheBook() public view {
        ConditionalsV2.Market memory m = c.getMarket(id);
        for (uint256 i; i < 4; ++i) {
            uint256 total;
            for (uint256 a; a < h.actorCount(); ++a) {
                total += c.sharesOf(id, h.actors(a))[i];
            }
            assertEq(int256(total), m.q[i] + int256(m.sets));
        }
    }

    /// @dev I4: prices sum to one.
    function invariant_pricesSumToOne() public view {
        uint256[4] memory p = c.prices(id);
        assertApproxEqAbs(p[0] + p[1] + p[2] + p[3], 1 ether, 4);
    }

    /// @dev Every winner can be paid in full, whichever outcome happens.
    function invariant_everyOutcomeIsPayable() public view {
        ConditionalsV2.Market memory m = c.getMarket(id);
        for (uint256 i; i < 4; ++i) {
            assertGe(int256(m.makerBalance + m.sets), m.q[i] + int256(m.sets));
        }
    }

    /// @dev The creator loses at most the seed: what is left for the creator is never negative.
    function invariant_refundBaseMatchesPositiveNets() public view {
        ConditionalsV2.Market memory m = c.getMarket(id);
        uint256 total;
        for (uint256 a; a < h.actorCount(); ++a) {
            int256 net = c.netIn(id, h.actors(a));
            if (net > 0) total += uint256(net);
        }
        assertEq(total, m.refundBase);
    }
}
