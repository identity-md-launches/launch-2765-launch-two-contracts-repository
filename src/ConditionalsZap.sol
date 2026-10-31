// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ConditionalsV2} from "./ConditionalsV2.sol";
import {IPoolManager, IUnlockCallback} from "./interfaces/IPoolManager.sol";

/// @title ConditionalsZap
/// @notice Places a conditional stake paid in ETH or USDG. In one transaction it swaps the coin into IMD through two
///         hookless Uniswap v4 pools (USDG to ETH at 0.05%, ETH to IMD at 1%) and stakes the IMD for the caller, who
///         sets the fewest IMD they accept. The whole call reverts if any step falls short.
///
/// It holds nothing between calls and has no owner: the position, its exit and its payout are in ConditionalsV2, in IMD.
contract ConditionalsZap is IUnlockCallback {
    using SafeERC20 for IERC20;

    uint24 public constant ETH_IMD_FEE = 10_000;
    int24 public constant ETH_IMD_TICK_SPACING = 100;
    uint24 public constant ETH_USDG_FEE = 500;
    int24 public constant ETH_USDG_TICK_SPACING = 10;

    /// @dev Uniswap's TickMath bounds, one step inside. They only stop the price running off the end of the curve.
    uint160 internal constant MIN_SQRT_PRICE_LIMIT = 4_295_128_740;
    uint160 internal constant MAX_SQRT_PRICE_LIMIT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    ConditionalsV2 public immutable conditionals;
    IPoolManager public immutable poolManager;
    IERC20 public immutable imd;
    IERC20 public immutable usdg;

    event Zapped(
        address indexed account,
        uint256 indexed marketId,
        address coin,
        uint256 amountIn,
        uint256 imdStaked,
        uint256 shares
    );

    error ZeroAddress();
    error ZeroAmount();
    error NotPoolManager();
    error PartialFill();
    error SlippageExceeded();

    /// @param conditionals_ The market contract.
    /// @param poolManager_ The Uniswap v4 PoolManager (Robinhood Chain: 0x8366a39CC670B4001A1121B8F6A443A643e40951).
    /// @param imd_ IMD (Robinhood Chain: 0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127). Must sort after address zero.
    /// @param usdg_ Global Dollar (Robinhood Chain: 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168).
    constructor(ConditionalsV2 conditionals_, IPoolManager poolManager_, IERC20 imd_, IERC20 usdg_) {
        if (
            address(conditionals_) == address(0) || address(poolManager_) == address(0) || address(imd_) == address(0)
                || address(usdg_) == address(0)
        ) revert ZeroAddress();
        conditionals = conditionals_;
        poolManager = poolManager_;
        imd = imd_;
        usdg = usdg_;
    }

    /// @notice Stakes `msg.value` ETH worth of IMD.
    /// @param minImd The fewest IMD the swap may return.
    /// @param minShares Passed to `stakeFor`.
    function stakeWithEth(uint256 marketId, uint8 world, uint8 side, uint256 minImd, uint256 minShares)
        external
        payable
        returns (uint256 imdStaked, uint256 shares)
    {
        if (msg.value == 0) revert ZeroAmount();
        imdStaked = abi.decode(poolManager.unlock(abi.encode(false, msg.value)), (uint256));
        shares = _stake(marketId, world, side, imdStaked, minImd, minShares);
        emit Zapped(msg.sender, marketId, address(0), msg.value, imdStaked, shares);
    }

    /// @notice Stakes `amount` USDG worth of IMD. The caller approves this contract for `amount` USDG first.
    function stakeWithUsdg(uint256 marketId, uint8 world, uint8 side, uint256 amount, uint256 minImd, uint256 minShares)
        external
        returns (uint256 imdStaked, uint256 shares)
    {
        if (amount == 0) revert ZeroAmount();
        usdg.safeTransferFrom(msg.sender, address(this), amount);
        imdStaked = abi.decode(poolManager.unlock(abi.encode(true, amount)), (uint256));
        shares = _stake(marketId, world, side, imdStaked, minImd, minShares);
        emit Zapped(msg.sender, marketId, address(usdg), amount, imdStaked, shares);
    }

    /// @dev The PoolManager calls back only the contract that asked it to unlock, so `data` is always this contract's.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (bool fromUsdg, uint256 amountIn) = abi.decode(data, (bool, uint256));

        uint256 ethIn = amountIn;
        if (fromUsdg) {
            // USDG is currency1 of the ETH pool: sell it for ETH, then pay the debt the swap opened.
            (int128 ethOut, int128 usdgDelta) =
                _swap(address(usdg), ETH_USDG_FEE, ETH_USDG_TICK_SPACING, false, amountIn);
            if (usdgDelta != -int128(int256(amountIn))) revert PartialFill();
            ethIn = uint256(int256(ethOut));
            poolManager.sync(address(usdg));
            usdg.safeTransfer(address(poolManager), amountIn);
            poolManager.settle();
        }

        (int128 ethDelta, int128 imdOut) = _swap(address(imd), ETH_IMD_FEE, ETH_IMD_TICK_SPACING, true, ethIn);
        if (ethDelta != -int128(int256(ethIn))) revert PartialFill();
        if (!fromUsdg) poolManager.settle{value: ethIn}();
        // From USDG, the ETH this swap spends is the ETH the first one earned, so the two deltas cancel.

        uint256 out = uint256(int256(imdOut));
        poolManager.take(address(imd), address(this), out);
        return abi.encode(out);
    }

    /// @dev An exact-input swap in the hookless pool of ETH (currency0) and `token` (currency1).
    function _swap(address token, uint24 fee, int24 tickSpacing, bool sellEth, uint256 amountIn)
        internal
        returns (int128 amount0, int128 amount1)
    {
        int256 delta = poolManager.swap(
            IPoolManager.PoolKey(address(0), token, fee, tickSpacing, address(0)),
            IPoolManager.SwapParams(sellEth, -int256(amountIn), sellEth ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT),
            ""
        );
        amount0 = int128(delta >> 128);
        amount1 = int128(delta);
    }

    function _stake(uint256 marketId, uint8 world, uint8 side, uint256 imdIn, uint256 minImd, uint256 minShares)
        internal
        returns (uint256 shares)
    {
        if (imdIn < minImd) revert SlippageExceeded();
        imd.forceApprove(address(conditionals), imdIn);
        shares = conditionals.stakeFor(msg.sender, marketId, world, side, imdIn, minShares);
    }
}
