// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AbstractReactive} from "./base/AbstractReactive.sol";
import {ISystemContract} from "./base/ISystemContract.sol";
import {IReactive} from "./base/IReactive.sol";

import {RiskMath} from "../libraries/RiskMath.sol";

contract HookSafetyReactive is AbstractReactive {
    uint64 public constant CALLBACK_GAS_LIMIT = 1_500_000;

    // keccak256("SecurityTelemetry(bytes32,address,uint64,uint64,uint64,int24,uint160,uint128,int128,int128,bool,int256,uint24,uint8)")
    uint256 public constant TELEMETRY_TOPIC_0 =
        0xdd031e33fe2f8df6f3eeaf6f3f7700b019972efff1840c4fe7f36e56d82f6aa0;

    uint16 public mediumThreshold;
    uint16 public highThreshold;

    uint256 public originChainId;
    uint256 public destinationChainId;
    address public hook;
    address public executor;

    struct Baseline {
        uint160 emaPriceX96;
        uint128 emaVolume;
        uint128 emaLiquidity;
        int24 lastTick;
        uint40 lastTimestamp;
        uint64 nonce;
        bool initialized;
    }

    mapping(bytes32 => Baseline) public baselines;

    event RiskEvaluated(bytes32 indexed poolId, uint16 score, uint16 computedScore, uint8 localRisk);

    event MitigationPlanned(
        bytes32 indexed poolId,
        uint8 tier,
        uint16 score,
        uint64 nonce,
        uint40 throttleUntil,
        uint40 pauseUntil,
        bytes32 evidenceHash
    );

    constructor(
        address serviceAddress,
        uint256 originChainId_,
        address hook_,
        uint256 destinationChainId_,
        address executor_,
        uint16 mediumThreshold_,
        uint16 highThreshold_
    ) payable {
        service = ISystemContract(payable(serviceAddress));
        addAuthorizedSender(serviceAddress);

        originChainId = originChainId_;
        destinationChainId = destinationChainId_;
        hook = hook_;
        executor = executor_;
        mediumThreshold = mediumThreshold_;
        highThreshold = highThreshold_;

        if (!vm) {
            service.subscribe(
                originChainId,
                hook,
                TELEMETRY_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    function setThresholds(uint16 mediumThreshold_, uint16 highThreshold_) external rnOnly {
        mediumThreshold = mediumThreshold_;
        highThreshold = highThreshold_;
    }

    function react(LogRecord calldata log) external vmOnly {
        if (log.topic_0 != TELEMETRY_TOPIC_0) return;

        bytes32 poolId = bytes32(log.topic_1);

        (
            uint64 sequence,
            uint64 eventTimestamp,
            uint64 eventBlockNumber,
            int24 tick,
            uint160 sqrtPriceX96,
            uint128 liquidity,
            int128 amount0,
            int128 amount1,
            bool zeroForOne,
            int256 amountSpecified,
            uint24 activeFee,
            uint8 localRisk
        ) = abi.decode(log.data, (uint64, uint64, uint64, int24, uint160, uint128, int128, int128, bool, int256, uint24, uint8));

        sequence;
        eventBlockNumber;
        amountSpecified;
        activeFee;

        uint256 volume = RiskMath.absInt128(amount0) + RiskMath.absInt128(amount1);

        Baseline storage baseline = baselines[poolId];
        Baseline memory snapshot = baseline;

        if (!snapshot.initialized) {
            baseline.initialized = true;
            baseline.emaPriceX96 = sqrtPriceX96;
            baseline.emaVolume = uint128(volume);
            baseline.emaLiquidity = liquidity;
            baseline.lastTick = tick;
            baseline.lastTimestamp = uint40(eventTimestamp);
            return;
        }

        RiskMath.FeatureVector memory features =
            _deriveFeatures(snapshot, eventTimestamp, tick, sqrtPriceX96, liquidity, volume, zeroForOne);
        uint16 computedScore = RiskMath.score(features, RiskMath.defaultWeights());
        uint16 score = uint16((uint256(computedScore) + uint256(localRisk)) / 2);

        emit RiskEvaluated(poolId, score, computedScore, localRisk);

        // EMA update after scoring to preserve causality.
        baseline.emaPriceX96 = uint160((uint256(snapshot.emaPriceX96) * 7 + uint256(sqrtPriceX96)) / 8);
        baseline.emaVolume = uint128((uint256(snapshot.emaVolume) * 7 + volume) / 8);
        baseline.emaLiquidity = uint128((uint256(snapshot.emaLiquidity) * 7 + uint256(liquidity)) / 8);
        baseline.lastTick = tick;
        baseline.lastTimestamp = uint40(eventTimestamp);

        uint8 tier;
        uint40 throttleUntil;
        uint40 pauseUntil;

        if (score >= highThreshold) {
            tier = 2;
            throttleUntil = uint40(block.timestamp + 180);
            pauseUntil = uint40(block.timestamp + 90);
        } else if (score >= mediumThreshold) {
            tier = 1;
            throttleUntil = uint40(block.timestamp + 45);
            pauseUntil = 0;
        }

        if (tier == 0) return;

        uint64 nonce = ++baseline.nonce;

        bytes32 evidenceHash = keccak256(
            abi.encode(log.chain_id, log._contract, log.block_number, log.tx_hash, log.log_index, poolId, score, tier, nonce)
        );

        bytes memory payload = abi.encodeWithSignature(
            "executeMitigation(address,bytes32,uint8,uint16,uint40,uint40,uint64,bytes32)",
            address(0),
            poolId,
            tier,
            score,
            throttleUntil,
            pauseUntil,
            nonce,
            evidenceHash
        );

        emit Callback(destinationChainId, executor, CALLBACK_GAS_LIMIT, payload);
        emit MitigationPlanned(poolId, tier, score, nonce, throttleUntil, pauseUntil, evidenceHash);
    }

    function _deriveFeatures(
        Baseline memory baseline,
        uint64 eventTimestamp,
        int24 tick,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint256 volume,
        bool zeroForOne
    ) private pure returns (RiskMath.FeatureVector memory features) {
        uint16 priceDeviationBps =
            RiskMath.ratioBps(RiskMath.absDiff(uint256(sqrtPriceX96), uint256(baseline.emaPriceX96)), baseline.emaPriceX96);

        uint16 volumeSpikeBps = RiskMath.ratioBps(volume, baseline.emaVolume == 0 ? 1 : uint256(baseline.emaVolume));

        int256 tickDiff = int256(tick) - int256(baseline.lastTick);
        if (tickDiff < 0) tickDiff = -tickDiff;
        uint16 slippageAnomalyBps = RiskMath.clampBps(uint256(tickDiff) * 20);

        uint16 liquidityImbalanceBps = RiskMath.ratioBps(
            RiskMath.absDiff(uint256(liquidity), uint256(baseline.emaLiquidity)),
            baseline.emaLiquidity == 0 ? 1 : uint256(baseline.emaLiquidity)
        );

        uint16 temporalCorrelationBps = _temporalCorrelation(eventTimestamp, baseline.lastTimestamp);
        uint16 mevHeuristicBps =
            _mevHeuristic(priceDeviationBps, volumeSpikeBps, temporalCorrelationBps, zeroForOne, baseline.lastTick, tick);

        features = RiskMath.FeatureVector({
            priceDeviationBps: priceDeviationBps,
            volumeSpikeBps: volumeSpikeBps,
            slippageAnomalyBps: slippageAnomalyBps,
            liquidityImbalanceBps: liquidityImbalanceBps,
            temporalCorrelationBps: temporalCorrelationBps,
            mevHeuristicBps: mevHeuristicBps
        });
    }

    function _temporalCorrelation(uint64 currentTimestamp, uint40 previousTimestamp) private pure returns (uint16) {
        if (previousTimestamp == 0) return 0;
        uint256 delta = currentTimestamp - uint64(previousTimestamp);
        if (delta <= 2) return 10_000;
        if (delta <= 8) return 6_500;
        if (delta <= 20) return 3_000;
        return 900;
    }

    function _mevHeuristic(
        uint16 priceDeviationBps,
        uint16 volumeSpikeBps,
        uint16 temporalCorrelationBps,
        bool zeroForOne,
        int24 previousTick,
        int24 currentTick
    ) private pure returns (uint16) {
        uint256 score;
        if (priceDeviationBps >= 1_800) score += 3_200;
        if (volumeSpikeBps >= 7_500) score += 3_200;
        if (temporalCorrelationBps >= 6_500) score += 2_400;
        bool directionFlip = (currentTick > previousTick) != zeroForOne;
        if (directionFlip) score += 2_000;
        return RiskMath.clampBps(score);
    }
}
