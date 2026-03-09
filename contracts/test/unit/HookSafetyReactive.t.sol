// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {HookSafetyReactive} from "../../src/reactive/HookSafetyReactive.sol";
import {IReactive} from "../../src/reactive/base/IReactive.sol";

contract HookSafetyReactiveTest is Test {
    HookSafetyReactive internal reactive;

    bytes32 internal constant POOL_ID = keccak256("pool-a");

    function setUp() public {
        reactive = new HookSafetyReactive(
            address(0x0000000000000000000000000000000000fffFfF),
            84_532,
            address(0x1234),
            block.chainid,
            address(0x5678),
            55,
            80
        );
    }

    function testReactBootstrapsThenPlansMitigationOnHighRisk() public {
        IReactive.LogRecord memory warmup = _telemetryLog(1, uint64(block.timestamp), 1_000_000_000_000, 200_000, 200, -1e18, 9e17, 35);
        reactive.react(warmup);

        vm.recordLogs();

        vm.warp(block.timestamp + 1);
        IReactive.LogRecord memory hot = _telemetryLog(2, uint64(block.timestamp), 9_000_000_000_000, 2_500_000, 2_000, -8e18, 7e18, 96);
        reactive.react(hot);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 callbackTopic = keccak256("Callback(uint256,address,uint64,bytes)");

        bool hasCallback;
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == callbackTopic) {
                hasCallback = true;
                break;
            }
        }

        assertTrue(hasCallback);
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
            _contract: address(0x1234),
            topic_0: reactive.TELEMETRY_TOPIC_0(),
            topic_1: uint256(POOL_ID),
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
