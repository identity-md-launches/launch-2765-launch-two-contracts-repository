// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {MockIMD} from "./utils/Mocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ConditionalsV2} from "../src/ConditionalsV2.sol";
import {ConditionalsZap} from "../src/ConditionalsZap.sol";
import {IPoolManager, IUnlockCallback} from "../src/interfaces/IPoolManager.sol";

/// @dev A PoolManager that keeps the rules the zap relies on: it calls back only the unlocker, swaps fill at a fixed
///      rate (optionally only half the input), and the unlock reverts unless every delta is settled.
contract MockPoolManager {
    MockIMD public imd;
    address public usdg;
    bool public unlocked;
    bool public halfFill;
    /// @dev Output per 1e18 of input, per pool (keyed by currency1).
    mapping(address => uint256) public rate;
    mapping(address => int256) public delta;
    address public synced;
    uint256 public syncedBalance;
    IPoolManager.PoolKey[] public keys;

    constructor(MockIMD imd_, address usdg_) {
        imd = imd_;
        usdg = usdg_;
    }

    receive() external payable {}

    function setRate(address token, uint256 r) external {
        rate[token] = r;
    }

    function setPartial(bool p) external {
        halfFill = p;
    }

    function keyCount() external view returns (uint256) {
        return keys.length;
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(!unlocked, "already unlocked");
        unlocked = true;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        require(delta[address(0)] == 0 && delta[address(imd)] == 0 && delta[usdg] == 0, "CurrencyNotSettled");
        unlocked = false;
    }

    function swap(IPoolManager.PoolKey memory key, IPoolManager.SwapParams memory params, bytes calldata)
        external
        returns (int256)
    {
        require(unlocked, "locked");
        require(params.amountSpecified < 0, "exact input only");
        keys.push(key);
        uint256 amountIn = uint256(-params.amountSpecified);
        if (halfFill) amountIn /= 2;
        uint256 out = amountIn * rate[key.currency1] / 1e18;
        int128 a0;
        int128 a1;
        if (params.zeroForOne) {
            a0 = -int128(int256(amountIn));
            a1 = int128(int256(out));
        } else {
            a0 = int128(int256(out));
            a1 = -int128(int256(amountIn));
        }
        delta[key.currency0] += a0;
        delta[key.currency1] += a1;
        return (int256(a0) << 128) | int256(uint256(uint128(a1)));
    }

    function sync(address currency) external {
        synced = currency;
        syncedBalance = IERC20(currency).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        if (synced == address(0)) {
            paid = msg.value;
            delta[address(0)] += int256(paid);
        } else {
            paid = IERC20(synced).balanceOf(address(this)) - syncedBalance;
            delta[synced] += int256(paid);
            synced = address(0);
        }
    }

    function take(address currency, address to, uint256 amount) external {
        delta[currency] -= int256(amount);
        imd.mint(to, amount);
        require(currency == address(imd), "take");
    }
}

contract ConditionalsZapTest is Fixture {
    MockIMD internal usdg;
    MockPoolManager internal pm;
    ConditionalsZap internal zap;
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        usdg = new MockIMD();
        pm = new MockPoolManager(imd, address(usdg));
        pm.setRate(address(imd), 600 ether); // 1 ETH buys 600 IMD
        zap = new ConditionalsZap(c, IPoolManager(address(pm)), IERC20(address(imd)), IERC20(address(usdg)));
        id = _create();
        vm.deal(alice, 10 ether);
        usdg.mint(alice, 1_000e6);
        vm.prank(alice);
        usdg.approve(address(zap), type(uint256).max);
    }

    function _assertHoldsNothing() internal view {
        assertEq(address(zap).balance, 0, "eth left");
        assertEq(imd.balanceOf(address(zap)), 0, "imd left");
        assertEq(usdg.balanceOf(address(zap)), 0, "usdg left");
        assertEq(imd.allowance(address(zap), address(c)), 0, "allowance left");
        uint256[4] memory s = c.sharesOf(id, address(zap));
        assertEq(s[0] + s[1] + s[2] + s[3], 0, "the zap holds no position");
    }

    function test_eth_stakesForTheCallerThroughTheEthImdPool() public {
        vm.prank(alice);
        (uint256 imdStaked, uint256 shares) = zap.stakeWithEth{value: 0.01 ether}(id, 1, 0, 6 ether, 0);
        assertEq(imdStaked, 6 ether);
        assertEq(c.sharesOf(id, alice)[2], imdStaked + shares);
        assertEq(c.sharesOf(id, alice)[0], imdStaked, "the other world refunds");
        assertGt(c.netIn(id, alice), 0);
        assertEq(pm.keyCount(), 1);
        (address c0, address c1, uint24 fee, int24 spacing, address hooks) = pm.keys(0);
        assertEq(c0, address(0));
        assertEq(c1, address(imd));
        assertEq(fee, 10_000);
        assertEq(spacing, 100);
        assertEq(hooks, address(0));
        assertEq(address(pm).balance, 0.01 ether);
        _assertHoldsNothing();
    }

    function test_usdg_stakesForTheCaller() public {
        // The mock prices by currency1; for the USDG pool the output is ETH per USDG unit.
        pm.setRate(address(usdg), 0.0005 ether * 1e18 / 1e6); // 1 USDG = 0.0005 ETH
        vm.prank(alice);
        (uint256 imdStaked,) = zap.stakeWithUsdg(id, 0, 1, 20e6, 0, 0);
        assertEq(imdStaked, 6 ether, "20 USDG -> 0.01 ETH -> 6 IMD");
        assertEq(usdg.balanceOf(alice), 980e6);
        assertEq(usdg.balanceOf(address(pm)), 20e6, "the USDG was paid to the manager");
        assertEq(pm.keyCount(), 2);
        (address c0, address c1, uint24 fee, int24 spacing, address hooks) = pm.keys(0);
        assertEq(c0, address(0));
        assertEq(c1, address(usdg));
        assertEq(fee, 500);
        assertEq(spacing, 10);
        assertEq(hooks, address(0));
        (, c1, fee, spacing,) = pm.keys(1);
        assertEq(c1, address(imd));
        assertEq(fee, 10_000);
        assertEq(spacing, 100);
        assertGt(c.sharesOf(id, alice)[1], imdStaked, "the chosen side got the extra shares");
        assertEq(c.sharesOf(id, alice)[2], imdStaked);
        _assertHoldsNothing();
    }

    function test_partialFillReverts() public {
        pm.setPartial(true);
        vm.prank(alice);
        vm.expectRevert(ConditionalsZap.PartialFill.selector);
        zap.stakeWithEth{value: 0.01 ether}(id, 0, 0, 0, 0);
        pm.setRate(address(usdg), 0.0005 ether * 1e18 / 1e6);
        vm.prank(alice);
        vm.expectRevert(ConditionalsZap.PartialFill.selector);
        zap.stakeWithUsdg(id, 0, 0, 20e6, 0, 0);
        assertEq(alice.balance, 10 ether);
        assertEq(usdg.balanceOf(alice), 1_000e6);
    }

    function test_slippageBoundsRevert() public {
        vm.prank(alice);
        vm.expectRevert(ConditionalsZap.SlippageExceeded.selector);
        zap.stakeWithEth{value: 0.01 ether}(id, 0, 0, 6 ether + 1, 0);
        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.SlippageExceeded.selector);
        zap.stakeWithEth{value: 0.01 ether}(id, 0, 0, 6 ether, 100 ether);
        assertEq(alice.balance, 10 ether);
    }

    function test_marketRefusalRevertsTheWholeZap() public {
        vm.warp(closeTime);
        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.BettingClosed.selector);
        zap.stakeWithEth{value: 0.01 ether}(id, 0, 0, 0, 0);
        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.UnknownMarket.selector);
        zap.stakeWithEth{value: 0.01 ether}(99, 0, 0, 0, 0);
    }

    function test_tinySwapBelowMinTradeReverts() public {
        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.TradeTooSmall.selector);
        zap.stakeWithEth{value: 1e12}(id, 0, 0, 0, 0); // 1e12 wei buys 6e14 IMD < MIN_TRADE
    }

    function test_zeroAmountsAndCallerChecks() public {
        vm.prank(alice);
        vm.expectRevert(ConditionalsZap.ZeroAmount.selector);
        zap.stakeWithEth(id, 0, 0, 0, 0);
        vm.prank(alice);
        vm.expectRevert(ConditionalsZap.ZeroAmount.selector);
        zap.stakeWithUsdg(id, 0, 0, 0, 0, 0);
        vm.prank(alice);
        vm.expectRevert(ConditionalsZap.NotPoolManager.selector);
        zap.unlockCallback(abi.encode(false, 1 ether));
        // Without approval the USDG pull fails before any swap.
        vm.prank(bob);
        vm.expectRevert();
        zap.stakeWithUsdg(id, 0, 0, 1e6, 0, 0);
    }

    function test_constructorRefusesZeroAddresses() public {
        IPoolManager p = IPoolManager(address(pm));
        IERC20 i = IERC20(address(imd));
        IERC20 u = IERC20(address(usdg));
        vm.expectRevert(ConditionalsZap.ZeroAddress.selector);
        new ConditionalsZap(ConditionalsV2(address(0)), p, i, u);
        vm.expectRevert(ConditionalsZap.ZeroAddress.selector);
        new ConditionalsZap(c, IPoolManager(address(0)), i, u);
        vm.expectRevert(ConditionalsZap.ZeroAddress.selector);
        new ConditionalsZap(c, p, IERC20(address(0)), u);
        vm.expectRevert(ConditionalsZap.ZeroAddress.selector);
        new ConditionalsZap(c, p, i, IERC20(address(0)));
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_ethZapLeavesNothingBehind(uint96 value, uint8 world, uint8 side) public {
        value = uint96(bound(value, 1e13, 0.2 ether));
        vm.deal(alice, value);
        vm.prank(alice);
        try zap.stakeWithEth{value: value}(id, world % 2, side % 2, 0, 0) returns (uint256 imdStaked, uint256) {
            assertEq(imdStaked, uint256(value) * 600);
            assertEq(alice.balance, 0);
        } catch {
            assertEq(alice.balance, value, "a refused zap returns the ETH");
        }
        _assertHoldsNothing();
    }
}
