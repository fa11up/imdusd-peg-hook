// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PegFeeHook} from "src/PegFeeHook.sol";

contract Tok is ERC20 {
    uint8 private immutable _d;

    constructor(string memory n, uint8 d) ERC20(n, n) {
        _d = d;
        _mint(msg.sender, 1e40);
    }

    function decimals() public view override returns (uint8) {
        return _d;
    }
}

/// @dev The smallest router: one unlock per action, settling what it owes and taking what it is owed.
contract Router is IUnlockCallback {
    IPoolManager immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function addLiquidity(PoolKey memory key, ModifyLiquidityParams memory p) external {
        pm.unlock(abi.encode(true, key, abi.encode(p)));
    }

    function swap(PoolKey memory key, SwapParams memory p) external returns (BalanceDelta d) {
        d = abi.decode(pm.unlock(abi.encode(false, key, abi.encode(p))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bool liquidity, PoolKey memory key, bytes memory inner) = abi.decode(data, (bool, PoolKey, bytes));
        BalanceDelta d;
        if (liquidity) (d,) = pm.modifyLiquidity(key, abi.decode(inner, (ModifyLiquidityParams)), "");
        else d = pm.swap(key, abi.decode(inner, (SwapParams)), "");
        _square(key.currency0, BalanceDeltaLibrary.amount0(d));
        _square(key.currency1, BalanceDeltaLibrary.amount1(d));
        return abi.encode(d);
    }

    function _square(Currency c, int128 delta) private {
        if (delta < 0) {
            pm.sync(c);
            ERC20(Currency.unwrap(c)).transfer(address(pm), uint128(-delta));
            pm.settle();
        } else if (delta > 0) {
            pm.take(c, address(this), uint128(delta));
        }
    }
}

/// @notice Against the real mainnet PoolManager on a fork:
///   forge test --match-contract PegFeeHook --fork-url $MAINNET_RPC_URL
contract PegFeeHookTest is Test {
    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant TREASURY = address(0x7EA5);
    bytes32 constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    Tok imdusd;
    Tok usdc;
    PegFeeHook hook;
    Router router;
    PoolKey key;

    function setUp() public {
        if (block.chainid != 1 || address(PM).code.length == 0) vm.skip(true);
        imdusd = new Tok("imdUSD", 18);
        usdc = new Tok("USDC", 6);
        hook = _deployHook(address(imdusd), address(usdc));
        router = new Router(PM);
        imdusd.transfer(address(router), 1e30);
        usdc.transfer(address(router), 1e30);
        key = _key(hook, 100, 1);
        PM.initialize(key, hook.pegSqrtPriceX96());
        // Full range, ~1M of each side at the peg.
        router.addLiquidity(key, ModifyLiquidityParams(TickMath.MIN_TICK, TickMath.MAX_TICK, 1e18, 0));
    }

    function _key(PegFeeHook h, uint24 fee, int24 spacing) private view returns (PoolKey memory) {
        (address c0, address c1) = h.stableIsToken0() ? (h.stable(), h.quote()) : (h.quote(), h.stable());
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, spacing, IHooks(address(h)));
    }

    /// @dev Mine a salt so the hook's address carries exactly its flag bits, as the real deploy does.
    function _deployHook(address stable, address quote) private returns (PegFeeHook h) {
        bytes memory init = abi.encodePacked(type(PegFeeHook).creationCode, abi.encode(PM, stable, quote, TREASURY));
        bytes32 initHash = keccak256(init);
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        for (uint256 salt;; ++salt) {
            address a = vm.computeCreate2Address(bytes32(salt), initHash, address(this));
            if (uint160(a) & Hooks.ALL_HOOK_MASK == flags) {
                h = new PegFeeHook{salt: bytes32(salt)}(PM, stable, quote, TREASURY);
                require(address(h) == a);
                return h;
            }
        }
    }

    function _stableIs0() private view returns (bool) {
        return address(imdusd) < address(usdc);
    }

    struct Swap {
        uint24 lpFee; // from the PoolManager's Swap event
        uint256 surcharge; // what the Treasury received
        uint256 unspecified; // the swap's unspecified amount before the surcharge (|output| exact-in, |input| exact-out)
        uint160 endSqrtPrice;
        bool zeroForOne;
    }

    /// @dev One swap; `exactIn` picks the kind. Returns the fee, the surcharge and the amount it was taken from.
    function _swap(bool sellStable, uint256 amount, uint160 limit, bool exactIn) private returns (Swap memory r) {
        r.zeroForOne = sellStable == _stableIs0();
        if (limit == 0) limit = r.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        // The surcharge is in the unspecified currency: token1 when token0 is specified, and token0 is specified
        // for an exact-in zeroForOne or an exact-out oneForZero.
        bool specifiedIs0 = exactIn == r.zeroForOne;
        ERC20 unspec = ERC20(Currency.unwrap(specifiedIs0 ? key.currency1 : key.currency0));
        uint256 before = unspec.balanceOf(TREASURY);
        vm.recordLogs();
        BalanceDelta d = router.swap(key, SwapParams(r.zeroForOne, exactIn ? -int256(amount) : int256(amount), limit));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; --i) {
            if (logs[i - 1].emitter == address(PM) && logs[i - 1].topics[0] == SWAP_TOPIC) {
                (,,,,, r.lpFee) = abi.decode(logs[i - 1].data, (int128, int128, uint160, uint128, int24, uint24));
                break;
            }
        }
        r.surcharge = unspec.balanceOf(TREASURY) - before;
        int128 paid = specifiedIs0 ? BalanceDeltaLibrary.amount1(d) : BalanceDeltaLibrary.amount0(d);
        uint256 abs = paid < 0 ? uint256(-int256(paid)) : uint256(int256(paid));
        // The swapper's delta already carries the surcharge: received less (exact-in) or paid more (exact-out).
        r.unspecified = exactIn ? abs + r.surcharge : abs - r.surcharge;
        (r.endSqrtPrice,,,) = _slot0();
    }

    function _exactIn(bool sellStable, uint256 amount) private returns (Swap memory) {
        return _swap(sellStable, amount, 0, true);
    }

    /// @dev The surcharge the hook should have taken, from where the swap ENDED.
    function _expected(Swap memory r) private view returns (uint256) {
        return r.unspecified * hook.surchargeFor(r.endSqrtPrice, r.zeroForOne) / 1_000_000;
    }

    /// @dev Push the price to `priceE18` (stable in USDC, 1e18 = $1) with a limit-bounded swap.
    function _moveTo(uint256 priceE18) private returns (Swap memory) {
        bool sellStable = priceE18 < _price();
        return _swap(sellStable, 1e27, _sqrtAt(priceE18), true);
    }

    function _sqrtAt(uint256 priceE18) private view returns (uint160) {
        uint256 rel = _stableIs0() ? priceE18 : 1e36 / priceE18;
        return uint160(hook.pegSqrtPriceX96() * _sqrt(rel * 1e18) / 1e18);
    }

    function _price() private view returns (uint256) {
        (uint160 sqrtP,,,) = _slot0();
        return hook.stablePrice(sqrtP);
    }

    function _slot0() private view returns (uint160, int24, uint24, uint24) {
        bytes32 id = keccak256(abi.encode(key));
        bytes32 slot = keccak256(abi.encode(id, uint256(6)));
        uint256 w = uint256(PM.extsload(slot));
        return (uint160(w), 0, 0, 0);
    }

    function _sqrt(uint256 x) private pure returns (uint256 y) {
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) (y, z) = (z, (x / z + z) / 2);
    }

    // ---------------------------------------------------------------- the pool

    function test_addressMustCarryTheFlags() public {
        vm.expectRevert(PegFeeHook.HookAddressMismatch.selector);
        new PegFeeHook(PM, address(imdusd), address(usdc), TREASURY); // an unmined address
    }

    function test_permissionsMatchTheFlags() public view {
        Hooks.validateHookPermissions(IHooks(address(hook)), hook.getHookPermissions()); // reverts on a mismatch
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, hook.FLAGS());
    }

    function test_attachesToItsOnePoolOnly() public {
        uint160 peg = hook.pegSqrtPriceX96();
        PegFeeHook other = _deployHook(address(new Tok("imdUSD2", 18)), address(usdc));
        // Keys and price built first: vm.expectRevert applies to the NEXT external call, which a getter would be.
        uint160 p = other.pegSqrtPriceX96();
        (PoolKey memory dyn, PoolKey memory fee500, PoolKey memory s60, PoolKey memory one) =
            (_key(other, 0x800000, 1), _key(other, 500, 1), _key(other, 100, 60), _key(other, 100, 1));
        vm.expectRevert();
        PM.initialize(dyn, p); // a dynamic-fee pool
        vm.expectRevert();
        PM.initialize(fee500, p); // another static fee
        vm.expectRevert();
        PM.initialize(s60, p); // another spacing
        vm.expectRevert();
        PM.initialize(one, p / 2); // another price
        PM.initialize(one, p); // the one pool, at $1
        vm.expectRevert();
        PM.initialize(one, p); // once
        assertGt(peg, 0);
    }

    function test_opensAtOneDollar() public view {
        assertApproxEqRel(_price(), 1e18, 1e9);
    }

    function test_readsTheTokensDecimals() public {
        // 18/6 either way round: the peg price is 2^96 / 1e6 or 2^96 * 1e6.
        uint256 q = uint256(1) << 96;
        assertEq(hook.pegSqrtPriceX96(), _stableIs0() ? q / 1e6 : q * 1e6);
        vm.expectRevert(PegFeeHook.ZeroAddress.selector);
        new PegFeeHook(PM, address(imdusd), address(usdc), address(0));
    }

    // ---------------------------------------------------------------- the fee

    function test_atThePegBothWaysPayOnlyTheLpFee() public {
        Swap memory a = _exactIn(true, 1_000e18);
        Swap memory b = _exactIn(false, 1_000e6);
        assertEq(a.lpFee, 100);
        assertEq(b.lpFee, 100);
        assertEq(a.surcharge + b.surcharge, 0);
    }

    function test_aSaleEndingBelowTheBandPaysTheSurchargeOfWhereItEnds() public {
        Swap memory r = _swap(true, 1e27, _sqrtAt(0.99e18), true); // one swap, $1 -> $0.99
        assertApproxEqRel(_price(), 0.99e18, 1e14);
        assertEq(r.lpFee, 100);
        assertGt(r.surcharge, 0);
        assertEq(r.surcharge, _expected(r));
        // 1% off: 75/175 of the way from nothing to 4.99%
        assertApproxEqAbs(hook.surchargeFor(r.endSqrtPrice, r.zeroForOne), uint256(49_900) * 75 / 175, 3);
    }

    function test_restoringPaysNothingExtra() public {
        _moveTo(0.99e18);
        Swap memory r = _exactIn(false, 100e6); // buys the stable: towards $1
        assertEq(r.surcharge, 0);
    }

    /// @dev The audit's high: a restore leg to inside the band, then one large sale, used to pay the floor.
    function test_restoreThenDumpPaysForWhereTheDumpEnds() public {
        _moveTo(0.97e18);
        Swap memory restore = _swap(false, 1e27, _sqrtAt(0.998e18), true); // into the band
        assertEq(restore.surcharge, 0, "the restore leg moves towards $1");
        Swap memory dump = _swap(true, 1e27, _sqrtAt(0.97e18), true); // one swap back down to $0.97
        assertEq(hook.surchargeFor(dump.endSqrtPrice, dump.zeroForOne), 49_900, "ends past the cap");
        assertEq(dump.surcharge, _expected(dump));
        assertGt(dump.surcharge, dump.unspecified * 49_800 / 1_000_000, "about 4.99% of the output");
    }

    /// @dev The audit's other route: one swap that crosses $1 and lands far on the other side.
    function test_crossingThePegPaysForHowFarPastItLands() public {
        _moveTo(0.99e18);
        Swap memory r = _swap(false, 1e27, _sqrtAt(1.03e18), true); // buys from $0.99 to $1.03
        assertGt(_price(), 1.02e18);
        assertEq(hook.surchargeFor(r.endSqrtPrice, r.zeroForOne), 49_900);
        assertEq(r.surcharge, _expected(r));
    }

    function test_exactOutputPaysTheSurchargeOnItsInput() public {
        _moveTo(0.99e18);
        Swap memory r = _swap(true, 10_000e6, 0, false); // sells the stable for exactly 10,000 USDC
        assertGt(r.surcharge, 0);
        assertEq(r.surcharge, _expected(r));
    }

    function test_feeIsCapped() public {
        _moveTo(0.97e18);
        Swap memory r = _exactIn(true, 100e18);
        assertEq(hook.feeFor(r.endSqrtPrice, r.zeroForOne), 50_000);
        assertEq(r.surcharge, _expected(r));
    }

    function test_theBandIsExact() public view {
        // ±0.25% exactly: no surcharge at the edge, some just past it.
        bool sellZero = _stableIs0(); // selling the stable
        assertEq(hook.surchargeFor(_sqrtAt(0.9975e18 + 1e13), sellZero), 0);
        assertGt(hook.surchargeFor(_sqrtAt(0.9974e18), sellZero), 0);
    }

    function test_neverRevertsAtTheExtremes() public view {
        hook.surchargeFor(TickMath.MIN_SQRT_PRICE, true);
        hook.surchargeFor(TickMath.MIN_SQRT_PRICE, false);
        hook.surchargeFor(TickMath.MAX_SQRT_PRICE - 1, true);
        hook.surchargeFor(TickMath.MAX_SQRT_PRICE - 1, false);
    }

    function test_onlyThePoolManagerCalls() public {
        vm.expectRevert(PegFeeHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, SwapParams(true, -1, 0), BalanceDeltaLibrary.ZERO_DELTA, "");
        uint160 p = hook.pegSqrtPriceX96();
        vm.expectRevert(PegFeeHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, p);
    }
}

import {DeployPegHook} from "script/DeployPegHook.s.sol";

contract MockVault {
    address public stablecoin;

    constructor(address s) {
        stablecoin = s;
    }
}

contract MockTreasury {
    address public vault;

    constructor(address v) {
        vault = v;
    }
}

/// @notice The deploy script, end to end on a fork: checks, mined address, canonical deployer, pool at $1, and a
/// second run that finds the pool already open.
contract DeployPegHookForkTest is Test {
    function test_scriptDeploysAndInitializes() public {
        if (block.chainid != 1) vm.skip(true);
        Tok imdusd = new Tok("imdUSD", 18); // stands in for the vault's imdUSD
        address treasury = address(new MockTreasury(address(new MockVault(address(imdusd)))));
        DeployPegHook s = new DeployPegHook();
        (bytes32 salt, address hook) = s.mine(address(imdusd), treasury);
        vm.setEnv("IMDUSD", vm.toString(address(imdusd)));
        vm.setEnv("TREASURY", vm.toString(treasury));
        vm.setEnv("SALT", vm.toString(uint256(salt)));
        s.run();
        PegFeeHook h = PegFeeHook(hook);
        assertEq(h.stable(), address(imdusd));
        assertEq(h.treasury(), treasury);
        bytes32 id = keccak256(abi.encode(s.poolKey(address(imdusd), hook)));
        uint256 slot0 = uint256(IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90).extsload(keccak256(abi.encode(id, uint256(6)))));
        assertEq(uint160(slot0), h.pegSqrtPriceX96(), "pool opened at $1");
        s.run(); // someone opened it first, or a rerun: skipped, not reverted
        s.checkPrice();
    }

    function test_scriptRefusesTheWrongTreasuryOrDecimals() public {
        if (block.chainid != 1) vm.skip(true);
        Tok imdusd = new Tok("imdUSD", 18);
        DeployPegHook s = new DeployPegHook();
        address wrong = address(new MockTreasury(address(new MockVault(address(0xBAD)))));
        vm.expectRevert(bytes("TREASURY is not imdUSD's Treasury"));
        s.check(address(imdusd), wrong);
        Tok six = new Tok("six", 6);
        address t6 = address(new MockTreasury(address(new MockVault(address(six)))));
        vm.expectRevert(bytes("IMDUSD has no code or not 18 decimals"));
        s.check(address(six), t6);
    }
}
