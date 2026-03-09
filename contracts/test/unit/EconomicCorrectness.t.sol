// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {HookSafetyFirewallHook} from "../../src/hooks/HookSafetyFirewallHook.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract EconomicCorrectnessTest is Test {
    using PoolIdLibrary for PoolKey;

    function testMitigationRaisesFeeTierMonotonically() public {
        MockPoolManager manager = new MockPoolManager();

        address hookAddress = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (uint160(0xA11C) << 144));
        deployCodeTo(
            "hooks/HookSafetyFirewallHook.sol:HookSafetyFirewallHook",
            abi.encode(IPoolManager(address(manager)), address(this)),
            hookAddress
        );
        HookSafetyFirewallHook hook = HookSafetyFirewallHook(hookAddress);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x1111)),
            currency1: Currency.wrap(address(0x2222)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        bytes32 poolId = PoolId.unwrap(key.toId());

        hook.configurePool(key, 3_000, 9_000, 20_000);
        hook.setExecutor(address(this), true);

        hook.applyMitigation(poolId, 1, uint40(block.timestamp + 30), 0, 1, 60);
        HookSafetyFirewallHook.PoolState memory state = hook.getPoolState(poolId);
        assertEq(state.currentFeePips, 9_000);

        hook.applyMitigation(poolId, 2, uint40(block.timestamp + 120), uint40(block.timestamp + 60), 2, 95);
        state = hook.getPoolState(poolId);
        assertEq(state.currentFeePips, 20_000);
    }
}
