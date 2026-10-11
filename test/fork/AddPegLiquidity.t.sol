// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {AddPegLiquidity} from "script/AddPegLiquidity.s.sol";

interface IOwnerOf {
    function ownerOf(uint256 id) external view returns (address);
}

/// @notice The first peg-pool deposit through the REAL Uniswap v4 PositionManager and Permit2, against the imdUSD
/// stack deployed on a local mainnet fork by infer-protocol's launch.sh (rehearsal):
///   PEG_IMDUSD=<imdUSD> PEG_TREASURY=<Treasury> forge test --match-path test/fork/AddPegLiquidity.t.sol \
///     --fork-url http://127.0.0.1:8546
contract AddPegLiquidityForkTest is Test {
    using StateLibrary for IPoolManager;

    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address constant POSM = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant OWNER = address(0xB0B);

    AddPegLiquidity s;
    address imdUsd;
    address treasury;

    function setUp() public {
        imdUsd = vm.envOr("PEG_IMDUSD", address(0));
        treasury = vm.envOr("PEG_TREASURY", address(0));
        if (block.chainid != 1 || imdUsd == address(0) || imdUsd.code.length == 0) vm.skip(true);
        s = new AddPegLiquidity();
        (bytes32 salt,) = s.mine(imdUsd, treasury);
        s.deploy(imdUsd, treasury, salt);
    }

    function test_firstDepositMintsTheRangeAtThePeg() public {
        uint256 usdc = 100_000e6;
        uint256 stable = 100_000e18;
        deal(address(USDC), address(s), usdc);
        deal(imdUsd, address(s), stable);
        AddPegLiquidity.Mint memory m = s.quote(imdUsd, treasury, usdc, stable, 50);

        uint256 id = s.add(imdUsd, treasury, usdc, stable, 50, OWNER);

        assertEq(IOwnerOf(POSM).ownerOf(id), OWNER, "the position NFT goes to the owner");
        IPoolManager pm = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
        assertEq(pm.getLiquidity(m.key.toId()), m.liquidity, "the pool's active liquidity is the minted position");
        uint256 usdcSpent = usdc - USDC.balanceOf(address(s));
        uint256 stableSpent = stable - IERC20(imdUsd).balanceOf(address(s));
        (uint256 usdcMax, uint256 stableMax) = imdUsd < address(USDC) ? (m.amount1Max, m.amount0Max) : (m.amount0Max, m.amount1Max);
        assertLe(usdcSpent, usdcMax);
        assertLe(stableSpent, stableMax);
        // A centred $0.95-$1.05 range at $1 takes nearly equal dollars of each side, all of one side bounded by the input.
        assertGt(usdcSpent * 1e12 + stableSpent, 150_000e18, "most of the $200k went in");
        assertEq(USDC.allowance(address(s), PERMIT2), 0, "approvals reset");
        assertEq(IERC20(imdUsd).allowance(address(s), PERMIT2), 0, "approvals reset");
        emit log_named_uint("USDC in (6 dec)", usdcSpent);
        emit log_named_uint("imdUSD in (18 dec)", stableSpent);
    }

    function test_rangeIsFiveCentsEachWay() public view {
        (, address hook) = s.mine(imdUsd, treasury);
        (int24 lo, int24 hi) = s.range(imdUsd, hook);
        (bool okLo, bytes memory pLo) = hook.staticcall(abi.encodeWithSignature("stablePrice(uint160)", _sqrt(lo)));
        (bool okHi, bytes memory pHi) = hook.staticcall(abi.encodeWithSignature("stablePrice(uint160)", _sqrt(hi)));
        require(okLo && okHi);
        (uint256 a, uint256 b) = (abi.decode(pLo, (uint256)), abi.decode(pHi, (uint256)));
        (uint256 low, uint256 high) = a < b ? (a, b) : (b, a);
        assertApproxEqRel(low, 0.95e18, 0.0002e18, "lower end $0.95");
        assertApproxEqRel(high, 1.05e18, 0.0002e18, "upper end $1.05");
    }

    function _sqrt(int24 t) private pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(t);
    }
}
