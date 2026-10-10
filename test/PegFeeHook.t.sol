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
        (address c0, address c1) = address(imdusd) < address(usdc)
            ? (address(imdusd), address(usdc))
            : (address(usdc), address(imdusd));
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), LPFeeLibrary.DYNAMIC_FEE_FLAG, 1, IHooks(address(hook)));
        PM.initialize(key, hook.pegSqrtPriceX96());
        // Full range, ~1M of each side at the peg.
        router.addLiquidity(key, ModifyLiquidityParams(TickMath.MIN_TICK, TickMath.MAX_TICK, 1e18, 0));
    }

    /// @dev Mine a salt so the hook's address carries exactly its two flag bits, as the real deploy does.
    function _deployHook(address stable, address quote) private returns (PegFeeHook h) {
        bytes memory init = abi.encodePacked(
            type(PegFeeHook).creationCode, abi.encode(PM, stable, uint8(18), quote, uint8(6))
        );
        bytes32 initHash = keccak256(init);
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG;
        for (uint256 salt;; ++salt) {
            address a = vm.computeCreate2Address(bytes32(salt), initHash, address(this));
            if (uint160(a) & Hooks.ALL_HOOK_MASK == flags) {
                h = new PegFeeHook{salt: bytes32(salt)}(PM, stable, 18, quote, 6);
                require(address(h) == a);
                return h;
            }
        }
    }

    function _stableIs0() private view returns (bool) {
        return address(imdusd) < address(usdc);
    }

    /// @dev Swap `amount` exact-in; sellStable picks the direction. Returns the fee the PoolManager applied.
    function _swap(bool sellStable, uint256 amount, uint160 limit) private returns (uint24 fee) {
        bool zeroForOne = sellStable == _stableIs0();
        if (limit == 0) limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        vm.recordLogs();
        router.swap(key, SwapParams(zeroForOne, -int256(amount), limit));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; --i) {
            if (logs[i - 1].topics[0] == SWAP_TOPIC) {
                (,,,,, fee) = abi.decode(logs[i - 1].data, (int128, int128, uint160, uint128, int24, uint24));
                return fee;
            }
        }
        revert("no Swap event");
    }

    /// @dev Push the price to `priceE18` (stable in USDC, 1e18 = $1) with a limit-bounded swap.
    function _moveTo(uint256 priceE18) private {
        uint256 current = _price();
        bool sellStable = priceE18 < current;
        // sqrt of the target raw price: scale the peg by sqrt(target), inverted when the stable is token1.
        uint256 rel = _stableIs0() ? priceE18 : 1e36 / priceE18;
        uint160 limit = uint160(hook.pegSqrtPriceX96() * _sqrt(rel * 1e18) / 1e18);
        _swap(sellStable, 1e27, limit);
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

    // ---------------------------------------------------------------- tests

    function test_addressMustCarryTheFlags() public {
        vm.expectRevert(PegFeeHook.HookAddressMismatch.selector);
        new PegFeeHook(PM, address(imdusd), 18, address(usdc), 6); // an unmined address
    }

    function test_attachesToItsOnePoolOnly() public {
        uint160 peg = hook.pegSqrtPriceX96();
        PoolKey memory k = key;
        k.fee = 500; // a static-fee pool
        vm.expectRevert();
        PM.initialize(k, peg);
        Tok other = new Tok("OTHER", 18);
        k = key;
        (k.currency0, k.currency1) = address(other) < address(usdc)
            ? (Currency.wrap(address(other)), Currency.wrap(address(usdc)))
            : (Currency.wrap(address(usdc)), Currency.wrap(address(other)));
        k.tickSpacing = 10;
        vm.expectRevert();
        PM.initialize(k, peg);
    }

    /// @dev Nobody can create the pool first at another price, or a second one at another spacing (both refused
    /// in beforeInitialize; the PoolManager wraps a hook's revert, so any revert is the refusal).
    function test_nobodyCanOpenItAtAnotherPriceOrSpacing() public {
        (, PegFeeHook h) = (0, _deployHook(address(new Tok("imdUSD2", 18)), address(usdc)));
        (address c0, address c1) = h.stableIsToken0() ? (h.stable(), h.quote()) : (h.quote(), h.stable());
        PoolKey memory k = PoolKey(Currency.wrap(c0), Currency.wrap(c1), LPFeeLibrary.DYNAMIC_FEE_FLAG, 1, IHooks(address(h)));
        uint160 peg = h.pegSqrtPriceX96();
        vm.expectRevert();
        PM.initialize(k, peg / 2); // $0.25 or $4, either way not the peg
        k.tickSpacing = 60;
        vm.expectRevert();
        PM.initialize(k, peg); // a second pool beside it
        k.tickSpacing = 1;
        PM.initialize(k, peg); // the one pool, at $1
        // and only once
        vm.expectRevert();
        PM.initialize(k, peg);
        assertEq(h.TICK_SPACING(), 1);
    }

    function test_opensAtOneDollar() public view {
        assertApproxEqRel(_price(), 1e18, 1e9);
    }

    function test_atThePegBothWaysPayTheFloor() public {
        assertEq(_swap(true, 1_000e18, 0), 100);
        assertEq(_swap(false, 1_000e6, 0), 100);
    }

    function test_belowThePegSellingPaysMoreAndBuyingPaysTheFloor() public {
        _moveTo(0.99e18);
        assertApproxEqRel(_price(), 0.99e18, 1e14);
        uint24 sell = _swap(true, 100e18, 0); // pushes further below: away
        uint24 buy = _swap(false, 100e6, 0); // restores: the floor
        assertApproxEqAbs(uint256(sell), uint256(100) + uint256(49_900) * 75 / 175, 300, "1% off: 3/7 of the way from 0.01% to 5% (~2.15%)");
        assertEq(buy, 100);
    }

    function test_aboveThePegBuyingPaysMoreAndSellingPaysTheFloor() public {
        _moveTo(1.02e18);
        uint24 buy = _swap(false, 100e6, 0);
        uint24 sell = _swap(true, 100e18, 0);
        assertEq(buy, 50_000, "2% off: the cap");
        assertEq(sell, 100);
    }

    function test_feeIsCapped() public {
        _moveTo(0.97e18);
        assertEq(_swap(true, 100e18, 0), 50_000);
    }

    function test_neverRevertsAtTheExtremes() public view {
        hook.feeFor(TickMath.MIN_SQRT_PRICE, true);
        hook.feeFor(TickMath.MIN_SQRT_PRICE, false);
        hook.feeFor(TickMath.MAX_SQRT_PRICE - 1, true);
        hook.feeFor(TickMath.MAX_SQRT_PRICE - 1, false);
    }

    function test_onlyThePoolManagerCalls() public {
        vm.expectRevert(PegFeeHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1, 0), "");
    }
}

import {DeployPegHook} from "script/DeployPegHook.s.sol";

/// @notice The deploy script, end to end on a fork: mined address, canonical deployer, pool initialized at $1.
contract DeployPegHookForkTest is Test {
    function test_scriptDeploysAndInitializes() public {
        if (block.chainid != 1) vm.skip(true);
        Tok imdusd = new Tok("imdUSD", 18); // stands in for the vault's imdUSD
        DeployPegHook s = new DeployPegHook();
        (bytes32 salt, address hook) = s.mine(address(imdusd));
        vm.setEnv("IMDUSD", vm.toString(address(imdusd)));
        vm.setEnv("SALT", vm.toString(uint256(salt)));
        s.run();
        PegFeeHook h = PegFeeHook(hook);
        assertEq(h.stable(), address(imdusd));
        assertEq(uint160(hook) & Hooks.ALL_HOOK_MASK, Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        bytes32 id = keccak256(abi.encode(s.poolKey(address(imdusd), hook)));
        uint256 slot0 = uint256(IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90).extsload(keccak256(abi.encode(id, uint256(6)))));
        assertEq(uint160(slot0), h.pegSqrtPriceX96(), "pool opened at $1");
        emit log_named_uint("salt", uint256(salt));
    }
}
