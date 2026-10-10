// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PegFeeHook} from "src/PegFeeHook.sol";

/// @notice Deploy the imdUSD/USDC PegFeeHook at a mined address through the canonical CREATE2 deployer, then
/// initialize the pool at $1. Liquidity is added separately, in a $0.95–$1.05 range.
///
///   plan:  IMDUSD=<addr> forge script script/DeployPegHook.s.sol --sig "plan()" --rpc-url $MAINNET_RPC_URL
///   run:   IMDUSD=<addr> SALT=<from plan> forge script script/DeployPegHook.s.sol --sig "run()" \
///            --rpc-url $MAINNET_RPC_URL --broadcast --account <deployer>
///
/// Mining is deterministic (lowest salt that works), so plan and run agree, and the address is fixed by the
/// hook's bytecode and its constructor arguments alone — whoever broadcasts gains no authority over it.
contract DeployPegHook is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    IPoolManager constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    int24 constant TICK_SPACING = 1; // must equal PegFeeHook.TICK_SPACING, which the hook enforces at initialize
    uint256 constant MAX_SALTS = 2_000_000;

    function initCode(address imdUsd) public pure returns (bytes memory) {
        return abi.encodePacked(type(PegFeeHook).creationCode, abi.encode(POOL_MANAGER, imdUsd, uint8(18), USDC, uint8(6)));
    }

    /// @notice The lowest salt whose CREATE2 address carries exactly the hook's flag bits.
    function mine(address imdUsd) public pure returns (bytes32 salt, address hook) {
        bytes32 h = keccak256(initCode(imdUsd));
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG;
        for (uint256 i; i < MAX_SALTS; ++i) {
            hook = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, bytes32(i), h)))));
            if (uint160(hook) & Hooks.ALL_HOOK_MASK == flags) return (bytes32(i), hook);
        }
        revert("no salt");
    }

    function poolKey(address imdUsd, address hook) public pure returns (PoolKey memory) {
        (address c0, address c1) = imdUsd < USDC ? (imdUsd, USDC) : (USDC, imdUsd);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, IHooks(hook));
    }

    function plan() external view {
        address imdUsd = vm.envAddress("IMDUSD");
        require(imdUsd.code.length != 0, "IMDUSD has no code on this chain");
        (bytes32 salt, address hook) = mine(imdUsd);
        console2.log("salt  ", uint256(salt));
        console2.log("hook  ", hook);
        console2.log("poolId");
        console2.logBytes32(keccak256(abi.encode(poolKey(imdUsd, hook))));
        console2.log(hook.code.length == 0 ? "status: not deployed" : "status: ALREADY DEPLOYED");
    }

    function run() external {
        address imdUsd = vm.envAddress("IMDUSD");
        require(imdUsd.code.length != 0, "IMDUSD has no code on this chain");
        require(CREATE2_DEPLOYER.code.length != 0, "no canonical CREATE2 deployer");
        (bytes32 salt, address hook) = mine(imdUsd);
        require(salt == bytes32(vm.envUint("SALT")), "SALT differs from the plan");

        vm.startBroadcast();
        if (hook.code.length == 0) {
            (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode(imdUsd)));
            require(ok && hook.code.length != 0, "deploy failed");
        }
        PegFeeHook h = PegFeeHook(hook);
        require(h.stable() == imdUsd && h.quote() == USDC, "hook wired wrong");
        POOL_MANAGER.initialize(poolKey(imdUsd, hook), h.pegSqrtPriceX96());
        vm.stopBroadcast();

        console2.log("hook  ", hook);
        console2.logBytes32(keccak256(abi.encode(poolKey(imdUsd, hook))));
    }
}
