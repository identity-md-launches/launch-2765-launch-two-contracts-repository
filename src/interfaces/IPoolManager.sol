// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The part of the Uniswap v4 PoolManager the zap uses. Currencies are addresses, ETH being address zero.
interface IPoolManager {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function unlock(bytes calldata data) external returns (bytes memory);

    /// @return delta The caller's balance delta: amount0 in the upper 128 bits, amount1 in the lower.
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256 delta);

    function sync(address currency) external;

    function settle() external payable returns (uint256 paid);

    function take(address currency, address to, uint256 amount) external;
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}
