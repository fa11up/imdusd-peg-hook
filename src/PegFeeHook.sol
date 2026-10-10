// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @title PegFeeHook
/// @notice Dynamic LP fee for the imdUSD/USDC v4 pool: cheap near $1 and for trades that pull the price back
/// towards $1, more expensive the further a trade pushes it away. Arbitrage that restores the peg pays the
/// floor fee; selling into a depeg pays for it, and that fee goes to the LPs holding the peg.
/// @dev Deployed at a mined CREATE2 salt (its address must carry exactly the BEFORE_INITIALIZE and BEFORE_SWAP flag
/// bits) by script/DeployPegHook.s.sol, which also creates the pool at $1.
///
/// Fee, in pips (1e6 = 100%), from the price BEFORE the swap:
///   - within ±BAND_BPS of $1, or the trade moves the price towards $1: BASE_FEE;
///   - otherwise: rises in a straight line from BASE_FEE at the band's edge to MAX_FEE at CAP_AT_BPS from $1,
///     and stays at MAX_FEE beyond it.
/// Why these numbers: a 5% cap equals the redemption fee's cap, so once the fee is
/// at its cap the pool is never a cheaper exit than redemption, and selling pressure in a depeg goes to
/// redemption (which burns imdUSD) instead of draining LPs. Reaching it at $0.98 keeps it well inside the LPs'
/// intended ±5% range, so the fee bites before the pool's USDC runs out.
/// Known limit, inherent to a before-swap fee: a single trade that starts inside the band pays BASE_FEE however
/// far it pushes; every following trade in the same direction pays the escalated fee. (An after-swap charge would
/// need a hook-owned delta, a larger surface; not worth it for a stablecoin pool.)
///
/// It attaches to exactly one pool: `beforeInitialize` refuses any key that is not (imdUSD, USDC), dynamic-fee,
/// TICK_SPACING, with this hook, and any opening price but exactly $1, so nobody can create the pool first at
/// another price or open a second one beside it. No owner, no parameters to change, no storage.
contract PegFeeHook is IHooks {
    using StateLibrary for IPoolManager;

    uint24 public constant BASE_FEE = 100; // 0.01%
    uint256 public constant BAND_BPS = 25; // ±0.25%
    uint256 public constant CAP_AT_BPS = 200; // the fee reaches MAX_FEE 2% from $1 ($0.98 / $1.02)
    uint24 public constant MAX_FEE = 50_000; // 5%
    int24 public constant TICK_SPACING = 1; // the one pool's spacing: any other spacing would be a second pool

    uint160 public constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG;

    IPoolManager public immutable poolManager;
    address public immutable stable; // imdUSD
    address public immutable quote; // USDC
    bool public immutable stableIsToken0;
    uint160 public immutable pegSqrtPriceX96; // sqrtPriceX96 at which 1 stable = 1 quote

    error NotPoolManager();
    error WrongPool();
    error NotAtPeg();
    error HookAddressMismatch();
    error OddDecimalGap();
    error NotImplemented();

    constructor(IPoolManager poolManager_, address stable_, uint8 stableDecimals, address quote_, uint8 quoteDecimals) {
        if (uint160(address(this)) & Hooks.ALL_HOOK_MASK != FLAGS) revert HookAddressMismatch();
        poolManager = poolManager_;
        (stable, quote) = (stable_, quote_);
        stableIsToken0 = stable_ < quote_;
        // Raw price token1/token0 at the peg is 10^(dec1 − dec0); its square root needs an even gap (18 vs 6: 12).
        (uint8 d0, uint8 d1) = stableIsToken0 ? (stableDecimals, quoteDecimals) : (quoteDecimals, stableDecimals);
        uint256 gap = d0 > d1 ? d0 - d1 : d1 - d0;
        if (gap % 2 != 0) revert OddDecimalGap();
        uint256 root = 10 ** (gap / 2);
        pegSqrtPriceX96 = uint160(d1 >= d0 ? (uint256(1) << 96) * root : (uint256(1) << 96) / root);
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    // ---------------------------------------------------------------- the two hooks it uses

    function beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        (address c0, address c1) = stableIsToken0 ? (stable, quote) : (quote, stable);
        if (
            Currency.unwrap(key.currency0) != c0 || Currency.unwrap(key.currency1) != c1
                || key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG || key.tickSpacing != TICK_SPACING
                || address(key.hooks) != address(this)
        ) revert WrongPool();
        if (sqrtPriceX96 != pegSqrtPriceX96) revert NotAtPeg();
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        uint24 fee = feeFor(sqrtPriceX96, params.zeroForOne);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // ---------------------------------------------------------------- views

    /// @notice The stable's price in the quote token, 1e18 = exactly $1 (decimals accounted for).
    function stablePrice(uint160 sqrtPriceX96) public view returns (uint256) {
        // r = (sqrtPrice / pegSqrtPrice)^2 = raw price relative to the peg's raw price, 1e18-scaled.
        uint256 ratioX96 = FullMath.mulDiv(sqrtPriceX96, 1 << 96, pegSqrtPriceX96);
        // Far off the peg (beyond 2^88 either way) the square would overflow; a swap must never revert on the
        // fee, so saturate: the stable is then priced at the extreme it is heading towards.
        if (ratioX96 >= 1 << 140) return stableIsToken0 ? type(uint256).max : 0;
        uint256 r = FullMath.mulDiv(FullMath.mulDiv(ratioX96, ratioX96, 1 << 96), 1e18, 1 << 96);
        // raw price is token1 per token0: if the stable is token0 that is its price, else the inverse.
        return stableIsToken0 ? r : (r == 0 ? type(uint256).max : 1e36 / r);
    }

    /// @notice The fee a swap in direction `zeroForOne` pays at pre-swap price `sqrtPriceX96`.
    function feeFor(uint160 sqrtPriceX96, bool zeroForOne) public view returns (uint24) {
        uint256 p = stablePrice(sqrtPriceX96);
        bool below = p < 1e18;
        uint256 devBps = (below ? 1e18 - p : p - 1e18) / 1e14;
        if (devBps <= BAND_BPS) return BASE_FEE;
        // Selling token0 lowers token0's price. The stable is sold when it is token0 and zeroForOne, or token1 and not.
        bool sellsStable = stableIsToken0 == zeroForOne;
        bool away = below ? sellsStable : !sellsStable;
        if (!away) return BASE_FEE;
        if (devBps >= CAP_AT_BPS) return MAX_FEE;
        return uint24(BASE_FEE + (MAX_FEE - BASE_FEE) * (devBps - BAND_BPS) / (CAP_AT_BPS - BAND_BPS));
    }

    // ---------------------------------------------------------------- unused (their flag bits are not set)

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert NotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert NotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert NotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert NotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert NotImplemented();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert NotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert NotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert NotImplemented();
    }
}
