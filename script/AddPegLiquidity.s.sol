// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {PegFeeHook} from "src/PegFeeHook.sol";
import {DeployPegHook} from "./DeployPegHook.s.sol";

interface IPermit2Approve {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IPositionManagerLike {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
}

/// @notice The first (and any later) liquidity in the imdUSD/USDC peg pool: one PositionManager mint over $0.9524–$1.05,
/// bounded by `DeployPegHook.maxesAt` at $1, so a pool moved off the peg makes the mint revert instead of filling at a
/// bad price (third audit round 442fd649).
///
///   plan:  forge script script/AddPegLiquidity.s.sol --sig "plan(address,address,uint256,uint256,uint256)" \
///            <imdUSD> <Treasury> <usdcRaw> <imdUsdRaw> <toleranceBps> --rpc-url $RPC
///   add:   IMDUSD=.. TREASURY=.. USDC_AMOUNT=<raw, 6 dec> IMDUSD_AMOUNT=<raw, 18 dec> TOLERANCE_BPS=50 [OWNER=..] \
///            forge script script/AddPegLiquidity.s.sol --sig "addFromEnv()" --rpc-url $RPC --broadcast --account <depositor>
///
/// The position's NFT goes to OWNER (default: the broadcaster). Amounts are maximums: at exactly $1 the mint takes the
/// liquidity both amounts allow, and returns nothing unspent because nothing beyond it is pulled (Permit2 approves only
/// the computed maximums, and the approvals are reset to zero afterwards).
contract AddPegLiquidity is DeployPegHook {
    using StateLibrary for IPoolManager;

    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    IPositionManagerLike constant POSITION_MANAGER = IPositionManagerLike(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    uint8 constant MINT_POSITION = 0x02; // v4-periphery Actions
    uint8 constant SETTLE_PAIR = 0x0d;
    // 488 ticks either side of the peg: $1/1.05 = $0.9524 to $1.05. Balanced around $1 in sqrt-price terms, so a deposit
    // at the peg takes equal amounts of the two tokens (a $0.95 floor, 513 ticks down, took ~5% less imdUSD than USDC).
    int24 constant TICKS_UP = 488;
    int24 constant TICKS_DOWN = 488;

    struct Mint {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 amount0Max;
        uint256 amount1Max;
    }

    /// @notice The range in ticks for imdUSD at $0.95–$1.05, whichever side of the pair imdUSD is.
    function range(address imdUsd, address hook) public view returns (int24 lower, int24 upper) {
        int24 peg = TickMath.getTickAtSqrtPrice(PegFeeHook(hook).pegSqrtPriceX96());
        // Raw price is currency1 per currency0. imdUSD as currency0: a dearer imdUSD is a higher tick.
        (lower, upper) = imdUsd < USDC ? (peg - TICKS_DOWN, peg + TICKS_UP) : (peg - TICKS_UP, peg + TICKS_DOWN);
    }

    /// @notice The mint `usdc` and `imdUsd` (raw units) allow at $1, and its maximums with `toleranceBps`.
    function quote(address imdUsd, address treasury, uint256 usdc, uint256 imdUsdAmount, uint256 toleranceBps)
        public
        view
        returns (Mint memory m)
    {
        (, address hook) = mine(imdUsd, treasury);
        require(hook.code.length != 0, "the peg hook is not deployed");
        m.key = poolKey(imdUsd, hook);
        (m.tickLower, m.tickUpper) = range(imdUsd, hook);
        uint160 p = PegFeeHook(hook).pegSqrtPriceX96();
        uint160 lo = TickMath.getSqrtPriceAtTick(m.tickLower);
        uint160 hi = TickMath.getSqrtPriceAtTick(m.tickUpper);
        (uint256 a0, uint256 a1) = imdUsd < USDC ? (imdUsdAmount, usdc) : (usdc, imdUsdAmount);
        // Liquidity from each side at the peg, the smaller binding: L0 = a0 * p * hi / (hi - p) / Q96, L1 = a1 * Q96 / (p - lo).
        uint256 l0 = FullMath.mulDiv(FullMath.mulDiv(a0, p, FixedPoint96.Q96), hi, hi - p);
        uint256 l1 = FullMath.mulDiv(a1, FixedPoint96.Q96, p - lo);
        uint256 l = l0 < l1 ? l0 : l1;
        require(l > 0 && l <= type(uint128).max, "amounts give no liquidity");
        m.liquidity = uint128(l);
        (m.amount0Max, m.amount1Max) = maxesAt(p, m.liquidity, m.tickLower, m.tickUpper, toleranceBps);
    }

    function plan(address imdUsd, address treasury, uint256 usdc, uint256 imdUsdAmount, uint256 toleranceBps)
        external
        view
    {
        check(imdUsd, treasury);
        Mint memory m = quote(imdUsd, treasury, usdc, imdUsdAmount, toleranceBps);
        console2.log("tickLower ", m.tickLower);
        console2.log("tickUpper ", m.tickUpper);
        console2.log("liquidity ", m.liquidity);
        console2.log("amount0Max", m.amount0Max);
        console2.log("amount1Max", m.amount1Max);
        (uint160 sqrtP,,,) = POOL_MANAGER.getSlot0(m.key.toId());
        PegFeeHook h = PegFeeHook(address(m.key.hooks));
        console2.log("range in $ (1e18 = $1):", h.stablePrice(TickMath.getSqrtPriceAtTick(m.tickLower)), h.stablePrice(TickMath.getSqrtPriceAtTick(m.tickUpper)));
        if (sqrtP == 0) console2.log("pool NOT initialized: run DeployPegHook first");
        else console2.log("imdUSD price now (1e18 = $1):", h.stablePrice(sqrtP));
    }

    function addFromEnv() external {
        address owner = vm.envOr("OWNER", msg.sender);
        vm.startBroadcast();
        add(
            vm.envAddress("IMDUSD"),
            vm.envAddress("TREASURY"),
            vm.envUint("USDC_AMOUNT"),
            vm.envUint("IMDUSD_AMOUNT"),
            vm.envOr("TOLERANCE_BPS", uint256(50)),
            owner
        );
        vm.stopBroadcast();
    }

    /// @notice Approve exactly the maximums through Permit2, mint, reset the approvals. Returns the position's id.
    function add(address imdUsd, address treasury, uint256 usdc, uint256 imdUsdAmount, uint256 toleranceBps, address owner)
        public
        returns (uint256 tokenId)
    {
        check(imdUsd, treasury);
        Mint memory m = quote(imdUsd, treasury, usdc, imdUsdAmount, toleranceBps);
        (uint160 sqrtP,,,) = POOL_MANAGER.getSlot0(m.key.toId());
        require(sqrtP != 0, "pool not initialized: run DeployPegHook first");
        address c0 = Currency.unwrap(m.key.currency0);
        address c1 = Currency.unwrap(m.key.currency1);
        _allow(c0, m.amount0Max);
        _allow(c1, m.amount1Max);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            m.key, m.tickLower, m.tickUpper, uint256(m.liquidity), uint128(m.amount0Max), uint128(m.amount1Max), owner, bytes("")
        );
        params[1] = abi.encode(m.key.currency0, m.key.currency1);
        tokenId = POSITION_MANAGER.nextTokenId();
        POSITION_MANAGER.modifyLiquidities(abi.encode(abi.encodePacked(MINT_POSITION, SETTLE_PAIR), params), block.timestamp + 600);
        _allow(c0, 0);
        _allow(c1, 0);
        console2.log("position", tokenId);
        console2.log("liquidity", m.liquidity);
    }

    function _allow(address token, uint256 amount) private {
        IERC20(token).approve(PERMIT2, amount);
        IPermit2Approve(PERMIT2).approve(token, address(POSITION_MANAGER), uint160(amount), uint48(block.timestamp + 3600));
    }
}
