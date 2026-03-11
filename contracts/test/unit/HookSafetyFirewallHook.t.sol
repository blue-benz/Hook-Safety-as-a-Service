// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {HookSafetyFirewallHook} from "../../src/hooks/HookSafetyFirewallHook.sol";
import {Owned} from "../../src/common/Owned.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract HookSafetyFirewallHookTest is Test {
    using PoolIdLibrary for PoolKey;

    MockPoolManager internal poolManager;
    HookSafetyFirewallHook internal hook;

    PoolKey internal key;
    bytes32 internal poolId;

    function setUp() public {
        poolManager = new MockPoolManager();

        address hookAddress = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (uint160(0xBEEF) << 144));

        deployCodeTo(
            "hooks/HookSafetyFirewallHook.sol:HookSafetyFirewallHook",
            abi.encode(IPoolManager(address(poolManager)), address(this)),
            hookAddress
        );

        hook = HookSafetyFirewallHook(hookAddress);

        key = PoolKey({
            currency0: Currency.wrap(address(0x1001)),
            currency1: Currency.wrap(address(0x2002)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        poolId = PoolId.unwrap(key.toId());

        hook.configurePool(key, 3_000, 9_000, 20_000);
        hook.setExecutor(address(this), true);

        _setPoolSlot0(1_000_000_000_000, 10, 3_000);
        _setLiquidity(1_000_000);
    }

    function testBeforeSwapReturnsDynamicFeeOverride() public {
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        (bytes4 selector,, uint24 feeOverride) = poolManager.callBeforeSwap(hook, key, params, "");

        assertEq(selector, hook.beforeSwap.selector);
        assertEq(feeOverride, LPFeeLibrary.OVERRIDE_FEE_FLAG | 3_000);
    }

    function testBeforeSwapRevertsWhenPoolPaused() public {
        uint40 until = uint40(block.timestamp + 120);
        hook.applyMitigation(poolId, 2, until, until, 1, 95);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        vm.expectRevert(abi.encodeWithSelector(HookSafetyFirewallHook.PoolPaused.selector, poolId, until));
        poolManager.callBeforeSwap(hook, key, params, "");
    }

    function testBeforeSwapRevertsWhenPoolThrottled() public {
        uint40 until = uint40(block.timestamp + 45);
        hook.applyMitigation(poolId, 1, until, 0, 1, 67);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        vm.expectRevert(abi.encodeWithSelector(HookSafetyFirewallHook.PoolThrottled.selector, poolId, until));
        poolManager.callBeforeSwap(hook, key, params, "");
    }

    function testAfterSwapPublishesTelemetryAndUpdatesRiskState() public {
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -3 ether, sqrtPriceLimitX96: 0});

        poolManager.callAfterSwap(hook, key, params, toBalanceDelta(-3e18, int128(2_100_000_000_000_000_000)), "");

        HookSafetyFirewallHook.PoolState memory state = hook.getPoolState(poolId);
        assertEq(state.sequence, 1);
        assertLe(state.lastLocalRisk, 100);

        _setPoolSlot0(5_200_000_000_000, 1_300, 3_000);
        vm.warp(block.timestamp + 1);
        poolManager.callAfterSwap(hook, key, params, toBalanceDelta(-6e18, int128(4_500_000_000_000_000_000)), "");

        state = hook.getPoolState(poolId);
        assertEq(state.sequence, 2);
        assertTrue(state.tier >= hook.TIER_ELEVATED());
        assertTrue(state.currentFeePips >= 9_000);
    }

    function testApplyMitigationIsIdempotentForStaleNonce() public {
        hook.applyMitigation(poolId, 2, uint40(block.timestamp + 120), uint40(block.timestamp + 90), 7, 95);
        HookSafetyFirewallHook.PoolState memory state = hook.getPoolState(poolId);
        assertEq(state.lastMitigationNonce, 7);
        assertEq(state.tier, hook.TIER_EMERGENCY());

        hook.applyMitigation(poolId, 1, uint40(block.timestamp + 10), 0, 3, 60);
        state = hook.getPoolState(poolId);
        assertEq(state.lastMitigationNonce, 7);
        assertEq(state.tier, hook.TIER_EMERGENCY());
    }

    function testApplyMitigationTierZeroKeepsBaseFee() public {
        hook.applyMitigation(poolId, 0, uint40(block.timestamp + 10), 0, 1, 40);
        HookSafetyFirewallHook.PoolState memory state = hook.getPoolState(poolId);
        assertEq(state.tier, hook.TIER_NORMAL());
        assertEq(state.currentFeePips, 3_000);
    }

    function testClearMitigationRestoresNormalTierAndBaseFee() public {
        hook.applyMitigation(poolId, 2, uint40(block.timestamp + 120), uint40(block.timestamp + 60), 1, 90);
        hook.clearMitigation(poolId);

        HookSafetyFirewallHook.PoolState memory state = hook.getPoolState(poolId);
        assertEq(state.tier, hook.TIER_NORMAL());
        assertEq(state.pauseUntil, 0);
        assertEq(state.throttleUntil, 0);
        assertEq(state.currentFeePips, 3_000);
    }

    function testClearMitigationRejectsUnknownPool() public {
        bytes32 unknown = keccak256("unknown-pool");
        vm.expectRevert(abi.encodeWithSelector(HookSafetyFirewallHook.UnknownPool.selector, unknown));
        hook.clearMitigation(unknown);
    }

    function testEmitTelemetryForDemoEmitsAndUpdatesPoolState() public {
        uint160 sqrtPriceX96 = 1_350_000_000_000;
        int24 tick = 420;
        uint128 liquidity = 850_000;
        int128 amount0 = -2e18;
        int128 amount1 = int128(15e17);
        uint8 localRisk = 88;

        vm.expectEmit(true, true, false, true, address(hook));
        emit HookSafetyFirewallHook.SecurityTelemetry(
            poolId,
            address(this),
            1,
            uint64(block.timestamp),
            uint64(block.number),
            tick,
            sqrtPriceX96,
            liquidity,
            amount0,
            amount1,
            true,
            -2e18,
            3_000,
            localRisk
        );

        hook.emitTelemetryForDemo(poolId, 0, tick, sqrtPriceX96, liquidity, amount0, amount1, true, -2e18, 0, localRisk);

        HookSafetyFirewallHook.PoolState memory state = hook.getPoolState(poolId);
        assertEq(state.sequence, 1);
        assertEq(state.lastSwapTimestamp, uint40(block.timestamp));
        assertEq(state.lastSqrtPriceX96, sqrtPriceX96);
        assertEq(state.lastTick, tick);
        assertEq(state.lastLiquidity, liquidity);
        assertTrue(state.lastDirectionZeroForOne);
        assertEq(state.lastLocalRisk, localRisk);
    }

    function testGetPoolConfigReturnsConfiguredFees() public {
        HookSafetyFirewallHook.PoolConfig memory cfg = hook.getPoolConfig(poolId);
        assertEq(cfg.baseFeePips, 3_000);
        assertEq(cfg.elevatedFeePips, 9_000);
        assertEq(cfg.emergencyFeePips, 20_000);
        assertTrue(cfg.exists);
    }

    function testTransferOwnershipEnforcesAccessControl() public {
        address newOwner = address(0xA11CE);
        hook.transferOwnership(newOwner);
        assertEq(hook.owner(), newOwner);

        vm.expectRevert(abi.encodeWithSelector(Owned.NotOwner.selector, address(this)));
        hook.setExecutor(address(0xD00D), true);

        vm.prank(newOwner);
        hook.setExecutor(address(0xD00D), true);
        assertTrue(hook.executors(address(0xD00D)));

        vm.prank(newOwner);
        vm.expectRevert(Owned.ZeroAddressOwner.selector);
        hook.transferOwnership(address(0));
    }

    function testAfterSwapTriggersLocalThrottleForMediumRisk() public {
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        poolManager.callAfterSwap(hook, key, params, toBalanceDelta(-1e18, int128(9e17)), "");

        _setPoolSlot0(1_400_000_000_000, 360, 3_000);
        vm.warp(block.timestamp + 15);
        poolManager.callAfterSwap(hook, key, params, toBalanceDelta(-3e18, int128(5e17)), "");

        HookSafetyFirewallHook.PoolState memory state = hook.getPoolState(poolId);
        assertEq(state.tier, hook.TIER_ELEVATED());
        assertEq(state.currentFeePips, 9_000);
        assertGt(state.throttleUntil, block.timestamp - 1);
    }

    function testAfterSwapTemporalCorrelationCoversAllBranches() public {
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        poolManager.callAfterSwap(hook, key, params, toBalanceDelta(-1e18, int128(1e18)), "");

        vm.warp(block.timestamp + 5);
        poolManager.callAfterSwap(hook, key, params, toBalanceDelta(-1e18, int128(1e18)), "");

        vm.warp(block.timestamp + 10);
        poolManager.callAfterSwap(hook, key, params, toBalanceDelta(-1e18, int128(1e18)), "");

        vm.warp(block.timestamp + 30);
        poolManager.callAfterSwap(hook, key, params, toBalanceDelta(-1e18, int128(1e18)), "");

        HookSafetyFirewallHook.PoolState memory state = hook.getPoolState(poolId);
        assertEq(state.sequence, 4);
    }

    function _setPoolSlot0(uint160 sqrtPriceX96, int24 tick, uint24 lpFee) internal {
        bytes32 stateSlot = keccak256(abi.encode(poolId, bytes32(uint256(6))));
        uint256 packed = uint256(sqrtPriceX96) | (uint256(uint24(tick)) << 160) | (uint256(0) << 184) | (uint256(lpFee) << 208);
        poolManager.setSlot(stateSlot, bytes32(packed));
    }

    function _setLiquidity(uint128 liquidity) internal {
        bytes32 stateSlot = keccak256(abi.encode(poolId, bytes32(uint256(6))));
        poolManager.setSlot(bytes32(uint256(stateSlot) + 3), bytes32(uint256(liquidity)));
    }
}
