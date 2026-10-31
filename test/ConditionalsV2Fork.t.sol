// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ConditionalsV2} from "../src/ConditionalsV2.sol";
import {ConditionalsZap} from "../src/ConditionalsZap.sol";
import {IIntake, IIntakePrice} from "../src/interfaces/IIntake.sol";
import {IPoolManager} from "../src/interfaces/IPoolManager.sol";
import {IOracleAttestation} from "../src/interfaces/IOracleAttestation.sol";

/// @dev Deploys both applications in one call, as the launch factory does in one transaction, with the brief's
///      constructor arguments.
contract ForkLauncher {
    ConditionalsV2 public conditionals;
    ConditionalsZap public zap;

    constructor(address owner, IERC20 imd, IIntake intake, address signer, address feeRecipient, IPoolManager pm, IERC20 usdg) {
        conditionals = new ConditionalsV2(owner, imd, intake, signer, feeRecipient);
        zap = new ConditionalsZap(conditionals, pm, imd, usdg);
    }
}

/// @dev Runs against Robinhood Chain at a pinned block when ROBINHOOD_RPC_URL is set: the real Intake takes the asks
///      and the real Uniswap v4 pools fill the zap. Skipped when the variable is empty, so the suite needs no RPC.
contract ConditionalsV2ForkTest is Test {
    uint256 constant FORK_BLOCK = 102_349_062;

    IERC20 constant IMD = IERC20(0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127);
    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    IIntake constant INTAKE = IIntake(0xa43e6F75ee006411F79Ac1C84120606C2330DE82);
    IPoolManager constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    address constant FEE_RECIPIENT = 0x63BCf2d1483c7628d7D53704ff9c8199Dc28d907;
    bytes32 constant ACTION = bytes32("oracle.request@oracle-1");

    ConditionalsV2 c;
    ConditionalsZap zap;
    uint256 id;
    address owner = makeAddr("owner");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");

    function setUp() public {
        string memory url = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url, FORK_BLOCK);
        ForkLauncher launcher = new ForkLauncher(owner, IMD, INTAKE, SIGNER, FEE_RECIPIENT, MANAGER, USDG);
        c = launcher.conditionals();
        zap = launcher.zap();

        deal(address(IMD), creator, 10 ether);
        vm.startPrank(creator);
        IMD.approve(address(c), type(uint256).max);
        id = c.createMarket(
            "The Federal Reserve raises rates at its December 2026 meeting",
            "BTC closes above 80000 USD on Coinbase on 2026-12-31",
            "Use federalreserve.gov for the decision and the Coinbase BTC-USD daily close for the price.",
            uint64(block.timestamp + 1 hours),
            uint64(block.timestamp + 2 hours),
            1 ether,
            1.44 ether
        );
        vm.stopPrank();
    }

    function test_fork_launchArgumentsAndDependencies() public view {
        // On Robinhood Chain block.number is the Ethereum block number, which the question window is pinned to.
        assertGt(block.number, 26_000_000);
        assertLt(block.number, FORK_BLOCK);
        assertEq(c.owner(), owner);
        assertEq(address(c.imd()), address(IMD));
        assertEq(c.feeRecipient(), FEE_RECIPIENT);
        (IIntake intake, address signer, uint128 price, uint16 panel, uint16 quorum, bytes32 action) = c.oracleConfig();
        assertEq(address(intake), address(INTAKE));
        assertEq(signer, SIGNER);
        assertEq(price, 0.5 ether);
        assertEq(panel, 5);
        assertEq(quorum, 4);
        assertEq(action, ACTION);
        assertEq(address(zap.conditionals()), address(c));
        assertEq(address(zap.poolManager()), address(MANAGER));
        assertEq(address(zap.imd()), address(IMD));
        assertEq(address(zap.usdg()), address(USDG));
        assertLe(address(c).code.length, 24_576, "EIP-170");
        assertGt(address(INTAKE).code.length, 0);
        assertGt(address(MANAGER).code.length, 0);
        assertEq(IIntakePrice(address(INTAKE)).priceOf(ACTION, address(IMD)), 0.5 ether, "live oracle price");
    }

    function test_fork_realIntakeAcceptsTheAsks() public {
        vm.warp(block.timestamp + 2 hours);
        uint256 held = IMD.balanceOf(address(c));
        assertEq(c.requestResolution(id), 2);
        assertEq(held - IMD.balanceOf(address(c)), 1 ether, "both asks paid from the budget");
        assertEq(IMD.balanceOf(address(INTAKE)), 0, "the Intake escrows nothing");
        assertEq(IMD.allowance(address(c), address(INTAKE)), 0);
        ConditionalsV2.Market memory m = c.getMarket(id);
        assertEq(m.budget, 0);
        assertEq(m.openAsks[0], 1);
        assertEq(m.openAsks[1], 1);
        assertFalse(c.askable(id, 0));
        vm.expectRevert(ConditionalsV2.NothingToAsk.selector);
        c.requestResolution(id);
    }

    function test_fork_askBeforeResolveTimeReverts() public {
        vm.expectRevert(ConditionalsV2.TooEarly.selector);
        c.requestResolution(id);
    }

    /// @dev Only the Intake may deliver: a forged answer from anyone else is refused even for a real request id.
    function test_fork_answersOnlyFromTheIntake() public {
        vm.warp(block.timestamp + 2 hours);
        vm.recordLogs();
        c.requestResolution(id);
        bytes32 requestId;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = ConditionalsV2.ResolutionRequested.selector;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(c) && logs[i].topics[0] == topic) {
                uint256 windowBlock;
                (requestId,, windowBlock) = abi.decode(logs[i].data, (bytes32, bytes32, uint256));
                assertEq(windowBlock, block.number - 10, "window pinned ten Ethereum blocks back");
                break;
            }
        }
        assertTrue(requestId != bytes32(0));
        IOracleAttestation.Attestation memory a;
        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.UnknownAsk.selector);
        c.onOracleResult(requestId, a, "");
        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.UnknownAsk.selector);
        c.onFailure(requestId, 1, bytes32("refused"), 0, 0, "");
        // From the Intake, an unsigned answer is refused and the ask stays live.
        vm.prank(address(INTAKE));
        vm.expectRevert(ConditionalsV2.BadAttestation.selector);
        c.onOracleResult(requestId, a, "");
        assertEq(c.getMarket(id).openAsks[0] + c.getMarket(id).openAsks[1], 2);
        // A failure from the Intake clears the ask, and a retry is paid by the caller.
        vm.prank(address(INTAKE));
        c.onFailure(requestId, 2, bytes32("disagreed"), 2, 5, "");
        assertEq(c.getMarket(id).openAsks[0] + c.getMarket(id).openAsks[1], 1);
        deal(address(IMD), alice, 1 ether);
        vm.startPrank(alice);
        IMD.approve(address(c), type(uint256).max);
        assertEq(c.requestResolution(id), 1);
        vm.stopPrank();
        assertEq(IMD.balanceOf(alice), 0.5 ether, "the retry cost the caller the live price");
    }

    function test_fork_zapStakesWithEth() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (uint256 imdStaked, uint256 shares) = zap.stakeWithEth{value: 0.0005 ether}(id, 0, 0, 0.001 ether, 0);
        emit log_named_uint("imd for 0.0005 eth", imdStaked);
        assertGt(shares, 0);
        assertEq(c.sharesOf(id, alice)[0], imdStaked + shares, "credited to the caller");
        assertEq(c.sharesOf(id, alice)[2], imdStaked);
        assertEq(c.sharesOf(id, address(zap))[0], 0);
        assertEq(IMD.balanceOf(address(zap)), 0, "the zap keeps nothing");
        assertEq(address(zap).balance, 0);
        assertEq(IMD.allowance(address(zap), address(c)), 0);
        assertEq(alice.balance, 1 ether - 0.0005 ether);
    }

    function test_fork_zapStakesWithUsdg() public {
        deal(address(USDG), alice, 100e6);
        vm.startPrank(alice);
        USDG.approve(address(zap), type(uint256).max);
        (uint256 imdStaked,) = zap.stakeWithUsdg(id, 1, 1, 5e6, 0.001 ether, 0);
        vm.stopPrank();
        emit log_named_uint("imd for 5 usdg", imdStaked);
        assertEq(c.sharesOf(id, alice)[0], imdStaked, "the other world is refunded");
        assertEq(USDG.balanceOf(alice), 95e6);
        assertEq(USDG.balanceOf(address(zap)), 0);
        assertEq(IMD.balanceOf(address(zap)), 0);
        assertEq(address(zap).balance, 0);
    }

    function test_fork_zapHonoursMinImd() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(ConditionalsZap.SlippageExceeded.selector);
        zap.stakeWithEth{value: 0.0005 ether}(id, 0, 0, 1_000_000 ether, 0);
    }

    function test_fork_zapHonoursMinShares() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.SlippageExceeded.selector);
        zap.stakeWithEth{value: 0.0005 ether}(id, 0, 0, 0, 1_000_000 ether);
    }

    function test_fork_zapRefusesAClosedMarketAndKeepsNothing() public {
        vm.warp(block.timestamp + 1 hours);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.BettingClosed.selector);
        zap.stakeWithEth{value: 0.0005 ether}(id, 0, 0, 0, 0);
        assertEq(alice.balance, 1 ether, "the whole call reverted");
    }

    function test_fork_zapRefusesZeroAmounts() public {
        vm.prank(alice);
        vm.expectRevert(ConditionalsZap.ZeroAmount.selector);
        zap.stakeWithEth(id, 0, 0, 0, 0);
        vm.prank(alice);
        vm.expectRevert(ConditionalsZap.ZeroAmount.selector);
        zap.stakeWithUsdg(id, 0, 0, 0, 0, 0);
    }

    function test_fork_callbackOnlyFromTheManager() public {
        vm.expectRevert(ConditionalsZap.NotPoolManager.selector);
        zap.unlockCallback(abi.encode(false, 1 ether));
    }
}
