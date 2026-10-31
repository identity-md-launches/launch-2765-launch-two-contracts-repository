// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ConditionalsV2} from "../src/ConditionalsV2.sol";
import {ConditionalsZap} from "../src/ConditionalsZap.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";
import {IPoolManager} from "../src/interfaces/IPoolManager.sol";

/// @dev Runs against Robinhood Chain when FORK_ROBINHOOD=1: the real Intake takes the asks and the real Uniswap v4
///      pools fill the zap. Skipped otherwise, so the suite needs no RPC.
contract ConditionalsV2ForkTest is Test {
    IERC20 constant IMD = IERC20(0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127);
    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    IIntake constant INTAKE = IIntake(0xa43e6F75ee006411F79Ac1C84120606C2330DE82);
    IPoolManager constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    address constant PAYEE = 0x4e0fA57Bde726079356537E2F34d671E9F41ADbc;

    ConditionalsV2 c;
    ConditionalsZap zap;
    uint256 id;
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");

    modifier forked() {
        if (!vm.envOr("FORK_ROBINHOOD", false)) return;
        vm.createSelectFork("robinhood");
        c = new ConditionalsV2(address(this), IMD, INTAKE, SIGNER, address(this));
        zap = new ConditionalsZap(c, MANAGER, IMD, USDG);
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
        _;
    }

    function test_fork_realIntakeAcceptsTheAsks() public forked {
        assertGt(block.number, 26_000_000, "block.number is the Ethereum block number on Robinhood Chain");
        vm.warp(block.timestamp + 2 hours);
        uint256 payeeBefore = IMD.balanceOf(PAYEE);
        assertEq(c.requestResolution(id), 2);
        assertEq(IMD.balanceOf(PAYEE) - payeeBefore, 1 ether, "the Intake forwarded both payments");
        assertEq(IMD.allowance(address(c), address(INTAKE)), 0);
        assertEq(c.getMarket(id).openAsks[0], 1);
        assertEq(c.getMarket(id).openAsks[1], 1);
    }

    function test_fork_zapStakesWithEth() public forked {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (uint256 imdStaked, uint256 shares) = zap.stakeWithEth{value: 0.0005 ether}(id, 0, 0, 0.1 ether, 0);
        emit log_named_uint("imd for 0.0005 eth", imdStaked);
        emit log_named_uint("shares", shares);
        assertEq(c.sharesOf(id, alice)[2], imdStaked, "credited to the caller");
        assertEq(c.sharesOf(id, address(zap))[2], 0);
        assertEq(IMD.balanceOf(address(zap)), 0, "the zap keeps nothing");
        assertEq(address(zap).balance, 0);
        assertEq(IMD.allowance(address(zap), address(c)), 0);
    }

    function test_fork_zapStakesWithUsdg() public forked {
        deal(address(USDG), alice, 100e6);
        vm.startPrank(alice);
        USDG.approve(address(zap), type(uint256).max);
        (uint256 imdStaked,) = zap.stakeWithUsdg(id, 1, 1, 5e6, 1 ether, 0);
        vm.stopPrank();
        emit log_named_uint("imd for 5 usdg", imdStaked);
        assertEq(c.sharesOf(id, alice)[0], imdStaked);
        assertEq(USDG.balanceOf(alice), 95e6);
        assertEq(USDG.balanceOf(address(zap)), 0);
        assertEq(IMD.balanceOf(address(zap)), 0);
        assertEq(address(zap).balance, 0);
    }

    function test_fork_zapHonoursMinImd() public forked {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(ConditionalsZap.SlippageExceeded.selector);
        zap.stakeWithEth{value: 0.0005 ether}(id, 0, 0, 1000 ether, 0);
    }

    function test_fork_callbackOnlyFromTheManager() public forked {
        vm.expectRevert(ConditionalsZap.NotPoolManager.selector);
        zap.unlockCallback(abi.encode(false, 1 ether));
    }
}
