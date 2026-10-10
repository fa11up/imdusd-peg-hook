// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PegFeeHook, IDecimals} from "src/PegFeeHook.sol";

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
///   before adding liquidity:
///          IMDUSD=<addr> TREASURY=<addr> forge script script/DeployPegHook.s.sol --sig "checkPrice()" --rpc-url $RPC
///
/// Mining is deterministic (lowest salt that works), so plan and run agree, and the address is fixed by the
/// hook's bytecode and its constructor arguments alone — whoever broadcasts gains no authority over it.
///
/// Until the first liquidity lands, an empty pool's price can be moved by a swap that exchanges nothing. The hook
/// refuses liquidity added to an empty pool whose price is outside the band (re-audit 3d492b20), so such a deposit
/// reverts rather than landing at a moved price; `checkPrice()` says beforehand whether it would.
contract DeployPegHook is Script {
    using StateLibrary for IPoolManager;

    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    IPoolManager constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 constant MAX_SALTS = 2_000_000;
    uint160 constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

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
        (address imdUsd, address treasury) = (vm.envAddress("IMDUSD"), vm.envAddress("TREASURY"));
        check(imdUsd, treasury);
        (bytes32 salt, address hook) = mine(imdUsd, treasury);
        require(salt == bytes32(vm.envUint("SALT")), "SALT differs from the plan");
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

    /// @notice Run right before adding liquidity: refuses unless the pool's price is inside the ±0.25% band.
    function checkPrice() external view {
        (address imdUsd, address treasury) = (vm.envAddress("IMDUSD"), vm.envAddress("TREASURY"));
        (, address hook) = mine(imdUsd, treasury);
        (uint160 sqrtP,,,) = POOL_MANAGER.getSlot0(poolKey(imdUsd, hook).toId());
        require(sqrtP != 0, "pool not initialized");
        uint256 p = PegFeeHook(hook).stablePrice(sqrtP);
        console2.log("imdUSD price in USDC (1e18 = $1):", p);
        uint256 dev = p > 1e18 ? p - 1e18 : 1e18 - p;
        require(dev <= 25e14, "outside the band: an add to the empty pool would revert; restore it to $1 first");
        console2.log("inside the band: liquidity can be added");
    }
}
