// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

interface IDecimals {
    function decimals() external view returns (uint8);
}

/// @title PegFeeHook
/// @notice The imdUSD/USDC v4 pool's peg fee. Every swap pays the pool's LP fee, BASE_FEE (0.01%). A swap that ends
/// with the price further from $1 than ±BAND_BPS, having pushed it there, also pays a surcharge priced from where it
/// ENDS: rising in a straight line from nothing at the band's edge to MAX_FEE − BASE_FEE at CAP_AT_BPS from $1, and
/// flat beyond. The surcharge goes to the imdUSD Treasury. A swap that moves the price towards $1 pays no surcharge.
/// @dev Deployed at a mined CREATE2 salt (its address must carry exactly BEFORE_INITIALIZE, AFTER_SWAP and
/// AFTER_SWAP_RETURNS_DELTA) by script/DeployPegHook.s.sol, which also creates the pool at $1.
///
/// Why the END price (swarm audit 5648bda5, high, all four specialists): a fee set from the price before a swap can
/// be routed around. A seller first trades back towards $1 at the floor, bringing the price into the band, then sells
/// any size in one swap, still at the floor; or one swap crosses $1 and lands far on the other side at the floor.
/// Priced from where a swap ends, both pay for how far they push. A sale split into steps pays each step at its own
/// end price, so about the average rate along the way (less than one swap pays at the final price, never the floor).
/// Copies of this hook at other mined addresses open their own pools; integrations pin this hook's poolId.
///
/// The surcharge is taken in the swap's unspecified currency (the output of an exact-input swap, the input of an
/// exact-output one), as v4's FeeTakingHook does: the hook returns it as an afterSwap delta, so the swapper pays it,
/// and takes it straight to the Treasury. Why these numbers: a 5% cap equals the redemption fee's cap, so once the
/// fee is at its cap the pool is never a cheaper exit than redemption, and selling pressure in a depeg goes to
/// redemption (which burns imdUSD) instead of draining LPs. Reaching it at $0.98 keeps it inside the LPs' ±5% range.
///
/// It attaches to exactly one pool: `beforeInitialize` refuses any key that is not (imdUSD, USDC), fee BASE_FEE,
/// TICK_SPACING, with this hook, and any opening price but exactly $1. No owner, no parameters to change, no storage.
contract PegFeeHook is IHooks {
    using StateLibrary for IPoolManager;

    uint24 public constant BASE_FEE = 100; // 0.01%, the pool's static LP fee
    uint256 public constant BAND_BPS = 25; // ±0.25%: no surcharge inside it
    uint256 public constant CAP_AT_BPS = 200; // the total reaches MAX_FEE 2% from $1 ($0.98 / $1.02)
    uint24 public constant MAX_FEE = 50_000; // 5%, LP fee and surcharge together
    int24 public constant TICK_SPACING = 1; // the one pool's spacing: any other spacing would be a second pool
    uint256 private constant PIPS = 1_000_000;

    uint160 public constant FLAGS =
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    IPoolManager public immutable poolManager;
    address public immutable stable; // imdUSD
    address public immutable quote; // USDC
    address public immutable treasury; // the imdUSD Treasury: where the surcharge goes
    bool public immutable stableIsToken0;
    uint160 public immutable pegSqrtPriceX96; // sqrtPriceX96 at which 1 stable = 1 quote

    error NotPoolManager();
    error WrongPool();
    error NotAtPeg();
    error HookAddressMismatch();
    error OddDecimalGap();
    error ZeroAddress();
    error NotImplemented();

    /// @dev Reads both tokens' decimals itself, so a wrong decimals argument cannot open the pool off the peg
    /// (swarm audit 5648bda5, low).
    constructor(IPoolManager poolManager_, address stable_, address quote_, address treasury_) {
        if (stable_ == address(0) || quote_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (uint160(address(this)) & Hooks.ALL_HOOK_MASK != FLAGS) revert HookAddressMismatch();
        poolManager = poolManager_;
        (stable, quote, treasury) = (stable_, quote_, treasury_);
        stableIsToken0 = stable_ < quote_;
        // Raw price token1/token0 at the peg is 10^(dec1 − dec0); its square root needs an even gap (18 vs 6: 12).
        (uint8 sd, uint8 qd) = (IDecimals(stable_).decimals(), IDecimals(quote_).decimals());
        (uint8 d0, uint8 d1) = stableIsToken0 ? (sd, qd) : (qd, sd);
        uint256 gap = d0 > d1 ? d0 - d1 : d1 - d0;
        if (gap % 2 != 0) revert OddDecimalGap();
        uint256 root = 10 ** (gap / 2);
        pegSqrtPriceX96 = uint160(d1 >= d0 ? (uint256(1) << 96) * root : (uint256(1) << 96) / root);
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @notice The callbacks this hook uses, as v4 tooling and BaseHook expect (swarm audit 5648bda5, medium).
    function getHookPermissions() external pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.afterSwap = true;
        p.afterSwapReturnDelta = true;
    }

    // ---------------------------------------------------------------- the hooks it uses

    function beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        (address c0, address c1) = stableIsToken0 ? (stable, quote) : (quote, stable);
        if (
            Currency.unwrap(key.currency0) != c0 || Currency.unwrap(key.currency1) != c1 || key.fee != BASE_FEE
                || key.tickSpacing != TICK_SPACING || address(key.hooks) != address(this)
        ) revert WrongPool();
        if (sqrtPriceX96 != pegSqrtPriceX96) revert NotAtPeg();
        return IHooks.beforeInitialize.selector;
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        uint256 pips = surchargeFor(sqrtPriceX96, params.zeroForOne);
        if (pips == 0) return (IHooks.afterSwap.selector, 0);
        bool specifiedIs0 = params.amountSpecified < 0 == params.zeroForOne;
        (Currency currency, int128 amount) =
            specifiedIs0 ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());
        uint256 abs = amount < 0 ? uint256(-int256(amount)) : uint256(int256(amount));
        uint256 surcharge = abs * pips / PIPS; // pips < PIPS, so surcharge < abs <= 2^127: fits int128
        if (surcharge == 0) return (IHooks.afterSwap.selector, 0);
        poolManager.take(currency, treasury, surcharge);
        return (IHooks.afterSwap.selector, int128(int256(surcharge)));
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

    /// @notice The total fee, LP fee plus surcharge, in pips, for a swap in direction `zeroForOne` that ENDS at
    /// `sqrtPriceX96`: BASE_FEE unless the swap pushed the price away from $1 and ended beyond the band.
    function feeFor(uint160 sqrtPriceX96, bool zeroForOne) public view returns (uint24) {
        return uint24(BASE_FEE + surchargeFor(sqrtPriceX96, zeroForOne));
    }

    /// @notice The surcharge, in pips of the swap's unspecified amount, for a swap in direction `zeroForOne` that
    /// ends at `sqrtPriceX96`.
    function surchargeFor(uint160 sqrtPriceX96, bool zeroForOne) public view returns (uint256) {
        uint256 p = stablePrice(sqrtPriceX96);
        bool below = p < 1e18;
        uint256 dev = below ? 1e18 - p : p - 1e18; // 1e18 = 100%
        uint256 band = BAND_BPS * 1e14;
        if (dev <= band) return 0; // exact: no rounding widens the band
        // Selling token0 lowers token0's price. The stable is sold when it is token0 and zeroForOne, or token1 and not.
        bool sellsStable = stableIsToken0 == zeroForOne;
        bool away = below ? sellsStable : !sellsStable;
        if (!away) return 0;
        uint256 cap = CAP_AT_BPS * 1e14;
        if (dev >= cap) return MAX_FEE - BASE_FEE;
        return uint256(MAX_FEE - BASE_FEE) * (dev - band) / (cap - band);
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

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4, BeforeSwapDelta, uint24)
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
