// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {HookSafetyReactive} from "../../src/reactive/HookSafetyReactive.sol";
import {IReactive} from "../../src/reactive/base/IReactive.sol";
import {AbstractReactive} from "../../src/reactive/base/AbstractReactive.sol";
import {MockSystemContract} from "../mocks/MockSystemContract.sol";

contract HookSafetyReactiveTest is Test {
    HookSafetyReactive internal reactive;

    address internal constant SERVICE_ADDR = address(0x0000000000000000000000000000000000fffFfF);
    bytes32 internal constant POOL_ID = keccak256("pool-a");

    function setUp() public {
        reactive = _newReactive(55, 80);
    }

    function testReactBootstrapsThenPlansMitigationOnHighRisk() public {
        IReactive.LogRecord memory warmup =
            _telemetryLog(1, uint64(block.timestamp), 1_000_000_000_000, 200_000, 200, -1e18, 9e17, true, 35);
        reactive.react(warmup);

        vm.recordLogs();

        vm.warp(block.timestamp + 1);
        IReactive.LogRecord memory hot =
            _telemetryLog(2, uint64(block.timestamp), 9_000_000_000_000, 2_500_000, 2_000, -8e18, 7e18, true, 96);
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

    function testReactIgnoresUnexpectedTopic() public {
        IReactive.LogRecord memory unknown = _telemetryLog(
            1,
            uint64(block.timestamp),
            1_000_000_000_000,
            200_000,
            120,
            -1e18,
            8e17,
            true,
            20
        );
        unknown.topic_0 = uint256(keccak256("UnknownTopic()"));

        reactive.react(unknown);

        (,,,,,, bool initialized) = reactive.baselines(POOL_ID);
        assertFalse(initialized);
    }

    function testSetThresholdsRevertsInsideReactVmMode() public {
        vm.expectRevert(AbstractReactive.ReactiveNetworkOnly.selector);
        reactive.setThresholds(40, 70);
    }

    function testReactiveNetworkModeSubscribesAndAllowsThresholdUpdates() public {
        MockSystemContract mockService = new MockSystemContract();
        vm.etch(SERVICE_ADDR, address(mockService).code);

        HookSafetyReactive networkReactive = _newReactive(55, 80);

        MockSystemContract service = MockSystemContract(payable(SERVICE_ADDR));
        assertEq(service.subscribeCount(), 1);
        assertEq(service.lastChainId(), 84_532);
        assertEq(service.lastTarget(), address(0x1234));

        networkReactive.setThresholds(44, 79);
        assertEq(networkReactive.mediumThreshold(), 44);
        assertEq(networkReactive.highThreshold(), 79);

        IReactive.LogRecord memory log =
            _telemetryLog(1, uint64(block.timestamp), 1_000_000_000_000, 100_000, 100, -1e18, 9e17, true, 35);
        vm.expectRevert(AbstractReactive.ReactVmOnly.selector);
        networkReactive.react(log);
    }

    function testReactPlansTierOneMitigationOnMediumRisk() public {
        HookSafetyReactive mediumReactive = _newReactive(50, 90);

        mediumReactive.react(
            _telemetryLog(1, uint64(block.timestamp), 1_000_000_000_000, 220_000, 100, -1e18, 9e17, true, 40)
        );

        vm.recordLogs();
        vm.warp(block.timestamp + 12);
        mediumReactive.react(
            _telemetryLog(2, uint64(block.timestamp), 1_600_000_000_000, 500_000, 500, -4e18, 8e17, true, 78)
        );

        bytes32 plannedTopic = keccak256("MitigationPlanned(bytes32,uint8,uint16,uint64,uint40,uint40,bytes32)");
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bool found;
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == plannedTopic) {
                (uint8 tier,,,,,) = abi.decode(entries[i].data, (uint8, uint16, uint64, uint40, uint40, bytes32));
                assertEq(tier, 1);
                found = true;
                break;
            }
        }
        assertTrue(found);
    }

    function testReactCoversTemporalCorrelationAndDirectionFlipPaths() public {
        reactive.react(_telemetryLog(1, 1_000, 1_000_000_000_000, 200_000, 100, -1e18, 1e18, true, 15));
        reactive.react(_telemetryLog(2, 1_006, 1_050_000_000_000, 200_000, 120, -1e18, 1e18, true, 20));
        reactive.react(_telemetryLog(3, 1_018, 1_100_000_000_000, 200_000, 140, -1e18, 1e18, false, 25));
        reactive.react(_telemetryLog(4, 1_050, 1_150_000_000_000, 200_000, 90, -1e18, 1e18, true, 30));

        (,,,, uint40 lastTimestamp,, bool initialized) = reactive.baselines(POOL_ID);
        assertTrue(initialized);
        assertEq(lastTimestamp, 1_050);
    }

    function _newReactive(uint16 medium, uint16 high) internal returns (HookSafetyReactive) {
        return HookSafetyReactive(new HookSafetyReactive(SERVICE_ADDR, 84_532, address(0x1234), block.chainid, address(0x5678), medium, high));
    }

    function _telemetryLog(
        uint64 sequence,
        uint64 ts,
        uint160 price,
        uint128 liquidity,
        int24 tick,
        int128 amount0,
        int128 amount1,
        bool zeroForOne,
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
            zeroForOne,
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
