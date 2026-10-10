// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @dev The hook's callbacks, as its mined address must carry them; the deploy script and tests mine against this.
uint160 constant PEG_HOOK_FLAGS =
    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

interface IDecimals {
    function decimals() external view returns (uint8);
}

/// @title PegFeeHook
/// @notice The imdUSD/USDC v4 pool's peg fee. Every swap pays the pool's LP fee, BASE_FEE (0.01%). A swap that ends
/// with the price further from $1 than ±BAND_BPS, having pushed it there, also pays a surcharge priced from where it
/// ENDS: rising in a straight line from nothing at the band's edge to MAX_FEE − BASE_FEE at CAP_AT_BPS from $1, and
/// flat beyond. The surcharge is held as PoolManager claims and swept to the imdUSD Treasury. A swap that leaves the
/// price no further from $1 on its own side, or inside the band, pays no surcharge.
/// The surcharge also funds a cashback for swaps that bring the price back: see "The restorer's cashback" below.
/// @dev Deployed at a mined CREATE2 salt (its address must carry exactly BEFORE_INITIALIZE, BEFORE_SWAP, AFTER_SWAP
/// and AFTER_SWAP_RETURNS_DELTA) by script/DeployPegHook.s.sol, which also creates the pool at $1.
///
/// Why the END price (swarm audit 5648bda5, high, all four specialists): a fee set from the price before a swap can
/// be routed around. A seller first trades back towards $1 at the floor, bringing the price into the band, then sells
/// any size in one swap, still at the floor; or one swap crosses $1 and lands far on the other side at the floor.
/// Priced from where a swap ends, both pay for how far they push. Two consequences, stated plainly (re-audit
/// 3d492b20): a sale split into steps pays each step at its own end price, so a third to a half less than one swap
/// ending at the same price (never the floor); and a swap that crosses $1 is charged by where it lands, on its whole
/// unspecified amount, even if it started further from $1 on the other side. And because the rate depends only on the
/// END price, a trade placed just before a swap can push that swap past the band edge so it pays the ramp (third
/// round 442fd649, low): the surcharge goes to the Treasury, not to whoever placed the trade, and the swap's own
/// price limit bounds it. Copies of this hook at other mined addresses open their own pools; integrations pin this
/// hook's poolId.
///
/// The surcharge never moves a token during a swap (re-audit 3d492b20, medium): afterSwap MINTS it as ERC-6909
/// claims to this hook, which needs neither the token's transfer to succeed nor the PoolManager to hold it yet, so no
/// swap can revert on it (a Treasury the token refuses, or an exact-output sale whose input has not arrived). Anyone
/// calls `sweep(currency)` to turn the claims into tokens at the Treasury; if that transfer is refused, the claims
/// wait and swapping carries on.
///
/// The first liquidity is protected by the deposit itself, not by this hook (third round 442fd649): an empty pool's
/// price can be moved for free, and a hook guard keyed on active liquidity is switched off by one wei of it while
/// blocking honest adds once the price leaves every range. So deposits go through PositionManager with each token's
/// maximum set to what a $1 position needs (plus a small tolerance): at a moved price one side exceeds its maximum
/// and the mint reverts, whatever liquidity anyone else added. See script/DeployPegHook.s.sol.
///
/// The surcharge is taken in the swap's unspecified currency (the output of an exact-input swap, the input of an
/// exact-output one), as v4's FeeTakingHook does: the hook returns it as an afterSwap delta, so the swapper pays it,
/// and keeps it as claims. Why these numbers: a 5% cap equals the redemption fee's cap, so a single swap ending at the
/// cap pays as much as redeeming (per swap, not per exit: a sliced sale pays less, as above; and an exact-output
/// swap's surcharge is on its input). Reaching it at $0.98 keeps it inside the LPs' ±5% range.
///
/// It attaches to exactly one pool: `beforeInitialize` refuses any key that is not (imdUSD, USDC), fee BASE_FEE,
/// TICK_SPACING, with this hook, and any opening price but exactly $1. No owner, no parameters to change.
///
/// The restorer's cashback (PROTOTYPE, not yet audited). Each surcharge is reserved in a pot for the side of $1 its
/// swap ended on (`pot[BELOW]` or `pot[ABOVE]`, per currency), instead of being sweepable at once. A swap that moves
/// the price back towards $1 RELEASES a share of the pot of the side it started on: the share of the distance from
/// where it started to the band's edge that it covered, both measured with deviations clamped to CAP_AT_BPS. Of what
/// is released, REBATE_BPS goes to the recipient the swapper names in hookData (32 bytes: abi.encode(address)) and
/// the rest becomes sweepable to the Treasury; with no recipient, or on a swap that itself pays a surcharge (it
/// crossed $1 and landed beyond the band), all of it does. So a pot never strands: once the price is back inside the
/// band, by anyone, that side's pot is empty.
///
/// Why a pot and not a rate on the restoring swap's volume: volume is free to make. A restorer can add liquidity of
/// its own just past the band and buy through it, or move the price through a range nobody provides; a rebate per
/// unit traded pays for both. Here the most any restorer can be paid is REBATE_BPS of surcharges already paid, and
/// releasing it takes moving the price, inside [band, cap], through whatever liquidity other LPs hold there. Why the
/// clamp at the cap: beyond it the surcharge is flat and the LPs' range may be empty, so the price can be moved there
/// for nothing; measured unclamped, a free move from far out back to the cap would release most of a pot. Why the
/// share is of the distance LEFT: release is multiplicative, so a restore split into steps releases what one swap
/// covering the same distance would, never more. And pushing the price away to grow a pot pays 100% of the surcharge
/// in for at most REBATE_BPS back.
///
/// The rebate is paid in both currencies, as the side's pot holds them, with `take`: a real transfer to the
/// recipient during the swap. If the token refuses it (a blacklisted recipient), that swap reverts; the recipient was
/// the swapper's own choice, and a swap with no hookData never transfers anything. The start price comes from
/// beforeSwap through transient storage; nothing else moves the pool between the two callbacks.
contract PegFeeHook is IHooks, IUnlockCallback {
    using StateLibrary for IPoolManager;

    uint24 public constant BASE_FEE = 100; // 0.01%, the pool's static LP fee
    uint256 public constant BAND_BPS = 25; // ±0.25%: no surcharge inside it
    uint256 public constant CAP_AT_BPS = 200; // the total reaches MAX_FEE 2% from $1 ($0.98 / $1.02)
    uint24 public constant MAX_FEE = 50_000; // 5%, LP fee and surcharge together
    int24 public constant TICK_SPACING = 1; // the one pool's spacing: any other spacing would be a second pool
    uint256 private constant PIPS = 1_000_000;

    uint256 public constant REBATE_BPS = 5_000; // the restorer's share of what its swap releases from a pot
    uint256 public constant BELOW = 0; // pot index: the stable under $1
    uint256 public constant ABOVE = 1; // pot index: the stable over $1
    uint256 private constant START_SLOT = uint256(keccak256("PegFeeHook.startSqrtPriceX96")) - 1; // transient

    uint160 public constant FLAGS = PEG_HOOK_FLAGS;

    IPoolManager public immutable poolManager;
    address public immutable stable; // imdUSD
    address public immutable quote; // USDC
    address public immutable treasury; // the imdUSD Treasury: where the surcharge goes
    bool public immutable stableIsToken0;
    uint160 public immutable pegSqrtPriceX96; // sqrtPriceX96 at which 1 stable = 1 quote

    /// @notice Surcharge claims reserved for restorers: pot[side][i], i = 0 for currency0, 1 for currency1. The
    /// hook's claims on a currency always cover both sides' pots of it; `sweep` takes only the rest.
    uint256[2][2] public pot;

    error NotPoolManager();
    error WrongPool();
    error NotAtPeg();
    error HookAddressMismatch();
    error OddDecimalGap();
    error ZeroAddress();
    error NotImplemented();

    event Swept(Currency indexed currency, uint256 amount);
    event Released(uint256 indexed side, uint256 amount0, uint256 amount1);
    event Rebated(address indexed recipient, uint256 amount0, uint256 amount1);

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
        p.beforeSwap = true;
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

    /// @dev Records where the swap starts, for afterSwap's release. Changes nothing about the swap.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        uint256 slot = START_SLOT;
        assembly ("memory-safe") {
            tstore(slot, sqrtPriceX96)
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        uint160 startSqrtPriceX96;
        uint256 slot = START_SLOT;
        assembly ("memory-safe") {
            startSqrtPriceX96 := tload(slot)
        }
        uint256 pips = surchargeFor(sqrtPriceX96, params.zeroForOne);
        // A surcharged swap is paid no cashback, but still releases (to the Treasury) the pot it crossed out of.
        _release(key, startSqrtPriceX96, sqrtPriceX96, pips == 0 ? _recipient(hookData) : address(0));
        if (pips == 0) return (IHooks.afterSwap.selector, 0);
        bool specifiedIs0 = params.amountSpecified < 0 == params.zeroForOne;
        (Currency currency, int128 amount) =
            specifiedIs0 ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());
        uint256 abs = amount < 0 ? uint256(-int256(amount)) : uint256(int256(amount));
        uint256 surcharge = abs * pips / PIPS; // pips < PIPS, so surcharge < abs <= 2^127: fits int128
        if (surcharge == 0) return (IHooks.afterSwap.selector, 0);
        // Claims, not a transfer: the returned delta credits this hook and the mint debits it, so it ends square.
        poolManager.mint(address(this), currency.toId(), surcharge);
        (, bool below) = deviation(sqrtPriceX96);
        pot[below ? BELOW : ABOVE][specifiedIs0 ? 1 : 0] += surcharge;
        return (IHooks.afterSwap.selector, int128(int256(surcharge)));
    }

    // ---------------------------------------------------------------- the restorer's cashback

    /// @dev Release the share of the start side's pot that this swap's move towards $1 covers; pay REBATE_BPS of it
    /// to `recipient` (if any) and leave the rest as sweepable claims.
    function _release(PoolKey calldata key, uint160 startSqrtPriceX96, uint160 endSqrtPriceX96, address recipient)
        private
    {
        uint256 band = BAND_BPS * 1e14;
        uint256 cap = CAP_AT_BPS * 1e14;
        (uint256 from, bool startBelow) = deviation(startSqrtPriceX96);
        if (from > cap) from = cap;
        if (from <= band) return; // the start side's pot can only be non-empty if the price is past the band
        (uint256 to, bool endBelow) = deviation(endSqrtPriceX96);
        if (endBelow != startBelow) to = band; // crossed $1: the start side is wholly restored
        else if (to < band) to = band;
        else if (to > cap) to = cap;
        if (to >= from) return; // no closer to $1, as measured inside [band, cap]
        uint256 side = startBelow ? BELOW : ABOVE;
        uint256[2] memory released;
        for (uint256 i; i < 2; ++i) {
            uint256 reserved = pot[side][i];
            if (reserved == 0) continue;
            released[i] = FullMath.mulDiv(reserved, from - to, from - band); // <= reserved: to >= band
            pot[side][i] = reserved - released[i];
        }
        if (released[0] == 0 && released[1] == 0) return;
        emit Released(side, released[0], released[1]);
        if (recipient == address(0)) return;
        uint256 r0 = released[0] * REBATE_BPS / 10_000;
        uint256 r1 = released[1] * REBATE_BPS / 10_000;
        // Burning claims credits this hook; taking to the recipient debits it: square within the swap's unlock.
        if (r0 != 0) _pay(key.currency0, recipient, r0);
        if (r1 != 0) _pay(key.currency1, recipient, r1);
        emit Rebated(recipient, r0, r1);
    }

    function _pay(Currency currency, address to, uint256 amount) private {
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, to, amount);
    }

    /// @dev The cashback's recipient: hookData of exactly one abi-encoded address, else none.
    function _recipient(bytes calldata hookData) private pure returns (address) {
        return hookData.length == 32 ? abi.decode(hookData, (address)) : address(0);
    }

    // ---------------------------------------------------------------- the surcharge, to the Treasury

    /// @notice Turn this hook's claims on `currency` into tokens at the Treasury. Anyone may call it.
    function sweep(Currency currency) external returns (uint256 amount) {
        amount = sweepable(currency);
        if (amount == 0) return 0;
        poolManager.unlock(abi.encode(currency, amount));
        emit Swept(currency, amount);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Currency currency, uint256 amount) = abi.decode(data, (Currency, uint256));
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, treasury, amount);
        return "";
    }

    // ---------------------------------------------------------------- views

    /// @notice The claims on `currency` that `sweep` would send to the Treasury now: all but the pots.
    function sweepable(Currency currency) public view returns (uint256) {
        address c = Currency.unwrap(currency);
        uint256 i = c == (stableIsToken0 ? stable : quote) ? 0 : c == (stableIsToken0 ? quote : stable) ? 1 : 2;
        uint256 reserved = i == 2 ? 0 : pot[BELOW][i] + pot[ABOVE][i];
        return poolManager.balanceOf(address(this), currency.toId()) - reserved;
    }

    /// @notice How far the stable's price at `sqrtPriceX96` is from $1 (1e18 = 100%), and on which side.
    function deviation(uint160 sqrtPriceX96) public view returns (uint256 dev, bool below) {
        uint256 p = stablePrice(sqrtPriceX96);
        below = p < 1e18;
        dev = below ? 1e18 - p : p - 1e18;
    }

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
        (uint256 dev, bool below) = deviation(sqrtPriceX96); // 1e18 = 100%
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

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert NotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert NotImplemented();
    }
}
