// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {HookSafetyReactive} from "../../src/reactive/HookSafetyReactive.sol";
import {HookSafetyExecutor} from "../../src/executor/HookSafetyExecutor.sol";
import {HookSafetyFirewallHook} from "../../src/hooks/HookSafetyFirewallHook.sol";
import {IReactive} from "../../src/reactive/base/IReactive.sol";

import {MockCallbackProxy} from "../mocks/MockCallbackProxy.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract ReactiveLifecycleIntegrationTest is Test {
    using PoolIdLibrary for PoolKey;

    bytes32 internal poolId;

    HookSafetyReactive internal reactive;
    HookSafetyExecutor internal executor;
    HookSafetyFirewallHook internal hook;

    MockCallbackProxy internal callbackProxy;
    MockPoolManager internal poolManager;

    function setUp() public {
        callbackProxy = new MockCallbackProxy();
        poolManager = new MockPoolManager();

        address hookAddress = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (uint160(0xCCDD) << 144));

        deployCodeTo(
            "hooks/HookSafetyFirewallHook.sol:HookSafetyFirewallHook",
            abi.encode(IPoolManager(address(poolManager)), address(this)),
            hookAddress
        );
        hook = HookSafetyFirewallHook(hookAddress);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x3003)),
            currency1: Currency.wrap(address(0x4004)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        poolId = PoolId.unwrap(key.toId());

        hook.configurePool(key, 3_000, 9_000, 20_000);

        executor = new HookSafetyExecutor(address(callbackProxy), address(hook), address(this));
        hook.setExecutor(address(executor), true);

        reactive = new HookSafetyReactive(
            address(0x0000000000000000000000000000000000fffFfF),
            84_532,
            address(hook),
            block.chainid,
            address(executor),
            55,
            80
        );
    }

    function testTelemetryToMitigationLifecycle() public {
        reactive.react(_telemetryLog(1, uint64(block.timestamp), 1_000_000_000_000, 200_000, 180, -1e18, 8e17, 20));

        vm.recordLogs();
        vm.warp(block.timestamp + 1);
        reactive.react(_telemetryLog(2, uint64(block.timestamp), 10_000_000_000_000, 2_700_000, 2_900, -8e18, 7e18, 98));

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 callbackTopic = keccak256("Callback(uint256,address,uint64,bytes)");

        bytes memory payload;
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == callbackTopic) {
                payload = abi.decode(entries[i].data, (bytes));
                break;
            }
        }

        assertGt(payload.length, 4, "callback payload missing");

        // Simulate ReactVM ID injection that the Reactive callback proxy performs in production.
        bytes memory patchedPayload = payload;
        uint256 rvm = uint256(uint160(address(this)));
        assembly ("memory-safe") {
            mstore(add(patchedPayload, 36), rvm)
        }

        callbackProxy.relay(address(executor), patchedPayload);

        HookSafetyFirewallHook.PoolState memory state = hook.getPoolState(poolId);
        assertTrue(state.tier >= 1);
        assertEq(executor.lastNonceByPool(poolId), 1);
    }

    function _telemetryLog(
        uint64 sequence,
        uint64 ts,
        uint160 price,
        uint128 liquidity,
        int24 tick,
        int128 amount0,
        int128 amount1,
        uint8 localRisk
    ) internal view returns (IReactive.LogRecord memory) {
        bytes memory data = abi.encode(
            sequence,
            ts,
            uint64(block.number),
            tick,
            price,
            liquidity,
            amount0,
            amount1,
            true,
            int256(-1 ether),
            uint24(3_000),
            localRisk
        );

        return IReactive.LogRecord({
            chain_id: 84_532,
            _contract: address(hook),
            topic_0: reactive.TELEMETRY_TOPIC_0(),
            topic_1: uint256(poolId),
            topic_2: uint256(uint160(address(this))),
            topic_3: 0,
            data: data,
            block_number: block.number,
            op_code: 0,
            block_hash: uint256(blockhash(block.number - 1)),
            tx_hash: uint256(keccak256(abi.encodePacked(sequence, ts))),
            log_index: sequence
        });
    }
}
