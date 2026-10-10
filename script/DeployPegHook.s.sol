// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {PegFeeHook, IDecimals, PEG_HOOK_FLAGS} from "src/PegFeeHook.sol";

interface ITreasuryLike {
    function vault() external view returns (address);
}

interface IFiatTokenLike {
    function isBlacklisted(address account) external view returns (bool);
}

interface IVaultLike {
    function stablecoin() external view returns (address);
}

/// @notice Deploy the imdUSD/USDC PegFeeHook at a mined address through the canonical CREATE2 deployer, then
/// initialize the pool at $1. Liquidity is added separately, in a $0.95–$1.05 range.
///
///   plan:  IMDUSD=<addr> TREASURY=<addr> forge script script/DeployPegHook.s.sol --sig "plan()" --rpc-url $RPC
///   run:   IMDUSD=<addr> TREASURY=<addr> SALT=<from plan> forge script script/DeployPegHook.s.sol --sig "run()" \
///            --rpc-url $RPC --broadcast --account <deployer>
///   before adding liquidity: the most of each token a $1 deposit may take (PositionManager MINT_POSITION's
///   amount0Max / amount1Max), and whether the pool is at $1 now:
///          IMDUSD=<addr> TREASURY=<addr> forge script script/DeployPegHook.s.sol \
///            --sig "depositMaxes(uint128,int24,int24,uint256)" <liquidity> <tickLower> <tickUpper> <toleranceBps> --rpc-url $RPC
///
/// Mining is deterministic (lowest salt that works), so plan and run agree, and the address is fixed by the
/// hook's bytecode and its constructor arguments alone — whoever broadcasts gains no authority over it.
///
/// Until the first liquidity lands, an empty pool's price can be moved by a swap that exchanges nothing, and one wei
/// of liquidity keeps it there. The protection is the deposit's own bounds (third audit round 442fd649): mint through
/// PositionManager with amount0Max / amount1Max from `depositMaxes`, computed at $1. At a moved price the position
/// needs more of one token than its maximum and the mint reverts. If someone keeps moving it, restore and deposit in
/// one transaction (Universal Router: a V4 swap back to $1, then the PositionManager call).
contract DeployPegHook is Script {
    using StateLibrary for IPoolManager;

    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    IPoolManager constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 constant MAX_SALTS = 2_000_000;
    uint160 constant FLAGS = PEG_HOOK_FLAGS;

    function initCode(address imdUsd, address treasury) public pure returns (bytes memory) {
        return abi.encodePacked(type(PegFeeHook).creationCode, abi.encode(POOL_MANAGER, imdUsd, USDC, treasury));
    }

    /// @notice The lowest salt whose CREATE2 address carries exactly the hook's flag bits.
    function mine(address imdUsd, address treasury) public pure returns (bytes32 salt, address hook) {
        bytes32 h = keccak256(initCode(imdUsd, treasury));
        for (uint256 i; i < MAX_SALTS; ++i) {
            hook = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, bytes32(i), h)))));
            if (uint160(hook) & Hooks.ALL_HOOK_MASK == FLAGS) return (bytes32(i), hook);
        }
        revert("no salt");
    }

    function poolKey(address imdUsd, address hook) public pure returns (PoolKey memory) {
        (address c0, address c1) = imdUsd < USDC ? (imdUsd, USDC) : (USDC, imdUsd);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), 100, 1, IHooks(hook)); // PegFeeHook.BASE_FEE, TICK_SPACING
    }

    /// @dev Everything the hook's constructor and the pool depend on, checked on chain (swarm audit 5648bda5, low):
    /// mainnet, the PoolManager and USDC as expected, imdUSD with 18 decimals, and TREASURY the Treasury of the
    /// vault that issues this imdUSD.
    function check(address imdUsd, address treasury) public view {
        require(block.chainid == 1, "mainnet only");
        require(address(POOL_MANAGER).code.length != 0, "no PoolManager");
        require(CREATE2_DEPLOYER.code.length != 0, "no canonical CREATE2 deployer");
        require(USDC.code.length != 0 && IDecimals(USDC).decimals() == 6, "USDC is not what it should be");
        require(imdUsd.code.length != 0 && IDecimals(imdUsd).decimals() == 18, "IMDUSD has no code or not 18 decimals");
        require(treasury.code.length != 0, "TREASURY has no code");
        require(IVaultLike(ITreasuryLike(treasury).vault()).stablecoin() == imdUsd, "TREASURY is not imdUSD's Treasury");
        // The one precondition of sweeping USDC that is checkable on chain (re-audit 3d492b20, low). Swaps never
        // depend on it: the surcharge is held as claims until it can be swept.
        try IFiatTokenLike(USDC).isBlacklisted(treasury) returns (bool listed) {
            require(!listed, "USDC has blacklisted TREASURY");
        } catch {}
    }

    function plan() external view {
        (address imdUsd, address treasury) = (vm.envAddress("IMDUSD"), vm.envAddress("TREASURY"));
        check(imdUsd, treasury);
        (bytes32 salt, address hook) = mine(imdUsd, treasury);
        console2.log("salt  ", uint256(salt));
        console2.log("hook  ", hook);
        console2.log("poolId");
        console2.logBytes32(keccak256(abi.encode(poolKey(imdUsd, hook))));
        console2.log(hook.code.length == 0 ? "status: not deployed" : "status: ALREADY DEPLOYED");
    }

    function run() external {
        deploy(vm.envAddress("IMDUSD"), vm.envAddress("TREASURY"), bytes32(vm.envUint("SALT")));
    }

    /// @notice `run()` with its inputs as arguments (tests call this: vm.setEnv is process-wide and would leak
    /// into other suites running in parallel).
    function deploy(address imdUsd, address treasury, bytes32 plannedSalt) public {
        check(imdUsd, treasury);
        (bytes32 salt, address hook) = mine(imdUsd, treasury);
        require(salt == plannedSalt, "SALT differs from the plan");
        PoolKey memory key = poolKey(imdUsd, hook);

        vm.startBroadcast();
        if (hook.code.length == 0) {
            (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode(imdUsd, treasury)));
            require(ok && hook.code.length != 0, "deploy failed");
        }
        PegFeeHook h = PegFeeHook(hook);
        require(h.stable() == imdUsd && h.quote() == USDC && h.treasury() == treasury, "hook wired wrong");
        // Anyone may initialize the one pool first, and only at $1 (the hook refuses anything else), so an
        // existing pool is the same pool: skip instead of reverting (swarm audit 5648bda5, low).
        (uint160 sqrtP,,,) = POOL_MANAGER.getSlot0(key.toId());
        if (sqrtP == 0) POOL_MANAGER.initialize(key, h.pegSqrtPriceX96());
        else console2.log("pool already initialized: skipped");
        vm.stopBroadcast();

        console2.log("hook  ", hook);
        console2.logBytes32(keccak256(abi.encode(key)));
    }

    /// @notice The most of each token a deposit of `liquidity` in [tickLower, tickUpper] takes at exactly $1, plus
    /// `toleranceBps`: PositionManager MINT_POSITION's amount0Max / amount1Max. Also prints the pool's price now.
    function depositMaxes(uint128 liquidity, int24 tickLower, int24 tickUpper, uint256 toleranceBps)
        external
        view
        returns (uint256 amount0Max, uint256 amount1Max)
    {
        return depositMaxesFor(vm.envAddress("IMDUSD"), vm.envAddress("TREASURY"), liquidity, tickLower, tickUpper, toleranceBps);
    }

    function depositMaxesFor(
        address imdUsd,
        address treasury,
        uint128 liquidity,
        int24 tickLower,
        int24 tickUpper,
        uint256 toleranceBps
    ) public view returns (uint256 amount0Max, uint256 amount1Max) {
        (, address hook) = mine(imdUsd, treasury);
        (amount0Max, amount1Max) = maxesAt(PegFeeHook(hook).pegSqrtPriceX96(), liquidity, tickLower, tickUpper, toleranceBps);
        console2.log("amount0Max", amount0Max);
        console2.log("amount1Max", amount1Max);
        if (hook.code.length != 0) {
            (uint160 sqrtP,,,) = POOL_MANAGER.getSlot0(poolKey(imdUsd, hook).toId());
            if (sqrtP == 0) console2.log("pool not initialized");
            else console2.log("imdUSD price now (1e18 = $1):", PegFeeHook(hook).stablePrice(sqrtP));
        }
    }

    /// @notice What a position of `liquidity` in [tickLower, tickUpper] holds at `sqrtPegX96`, rounded up, plus
    /// `toleranceBps` of it. Pure, so tests and the script agree.
    function maxesAt(uint160 sqrtPegX96, uint128 liquidity, int24 tickLower, int24 tickUpper, uint256 toleranceBps)
        public
        pure
        returns (uint256 amount0Max, uint256 amount1Max)
    {
        uint160 lo = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 hi = TickMath.getSqrtPriceAtTick(tickUpper);
        require(lo < sqrtPegX96 && sqrtPegX96 < hi, "the range must contain $1");
        uint256 a0 = SqrtPriceMath.getAmount0Delta(sqrtPegX96, hi, liquidity, true);
        uint256 a1 = SqrtPriceMath.getAmount1Delta(lo, sqrtPegX96, liquidity, true);
        (amount0Max, amount1Max) = (a0 + a0 * toleranceBps / 10_000, a1 + a1 * toleranceBps / 10_000);
    }
}
