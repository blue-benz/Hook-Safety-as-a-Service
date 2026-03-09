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

    struct Telemetry {
        uint64 eventTimestamp;
        int24 tick;
        uint160 sqrtPriceX96;
        uint128 liquidity;
        int128 amount0;
        int128 amount1;
        bool zeroForOne;
        uint8 localRisk;
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

    error InvalidTelemetryData(uint256 length);

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
        Telemetry memory telemetry = _decodeTelemetry(log.data);
        uint256 volume = RiskMath.absInt128(telemetry.amount0) + RiskMath.absInt128(telemetry.amount1);

        Baseline storage baseline = baselines[poolId];
        Baseline memory snapshot = baseline;

        if (!snapshot.initialized) {
            _bootstrapBaseline(baseline, telemetry, volume);
            return;
        }

        (uint16 computedScore, uint16 score) = _scoreAndRefreshBaseline(baseline, snapshot, telemetry, volume);

        emit RiskEvaluated(poolId, score, computedScore, telemetry.localRisk);

        (uint8 tier, uint40 throttleUntil, uint40 pauseUntil) = _mitigationFromScore(score);

        if (tier == 0) return;

        uint64 nonce = ++baseline.nonce;
        _emitMitigation(log, poolId, score, tier, throttleUntil, pauseUntil, nonce);
    }

    function _decodeTelemetry(bytes calldata data) private pure returns (Telemetry memory telemetry) {
        if (data.length != 384) revert InvalidTelemetryData(data.length);

        uint256 eventTimestampWord;
        int256 tickWord;
        uint256 sqrtPriceWord;
        uint256 liquidityWord;
        int256 amount0Word;
        int256 amount1Word;
        uint256 zeroForOneWord;
        uint256 localRiskWord;

        assembly ("memory-safe") {
            let ptr := data.offset
            eventTimestampWord := calldataload(add(ptr, 32))
            tickWord := calldataload(add(ptr, 96))
            sqrtPriceWord := calldataload(add(ptr, 128))
            liquidityWord := calldataload(add(ptr, 160))
            amount0Word := calldataload(add(ptr, 192))
            amount1Word := calldataload(add(ptr, 224))
            zeroForOneWord := calldataload(add(ptr, 256))
            localRiskWord := calldataload(add(ptr, 352))
        }

        telemetry.eventTimestamp = uint64(eventTimestampWord);
        telemetry.tick = int24(tickWord);
        telemetry.sqrtPriceX96 = uint160(sqrtPriceWord);
        telemetry.liquidity = uint128(liquidityWord);
        telemetry.amount0 = int128(amount0Word);
        telemetry.amount1 = int128(amount1Word);
        telemetry.zeroForOne = zeroForOneWord != 0;
        telemetry.localRisk = uint8(localRiskWord);
    }

    function _bootstrapBaseline(Baseline storage baseline, Telemetry memory telemetry, uint256 volume) private {
        baseline.initialized = true;
        baseline.emaPriceX96 = telemetry.sqrtPriceX96;
        baseline.emaVolume = uint128(volume);
        baseline.emaLiquidity = telemetry.liquidity;
        baseline.lastTick = telemetry.tick;
        baseline.lastTimestamp = uint40(telemetry.eventTimestamp);
    }

    function _scoreAndRefreshBaseline(
        Baseline storage baseline,
        Baseline memory snapshot,
        Telemetry memory telemetry,
        uint256 volume
    ) private returns (uint16 computedScore, uint16 score) {
        RiskMath.FeatureVector memory features = _deriveFeatures(
            snapshot,
            telemetry.eventTimestamp,
            telemetry.tick,
            telemetry.sqrtPriceX96,
            telemetry.liquidity,
            volume,
            telemetry.zeroForOne
        );
        computedScore = RiskMath.score(features, RiskMath.defaultWeights());
        score = uint16((uint256(computedScore) + uint256(telemetry.localRisk)) / 2);

        // EMA update after scoring to preserve causality.
        baseline.emaPriceX96 = uint160((uint256(snapshot.emaPriceX96) * 7 + uint256(telemetry.sqrtPriceX96)) / 8);
        baseline.emaVolume = uint128((uint256(snapshot.emaVolume) * 7 + volume) / 8);
        baseline.emaLiquidity = uint128((uint256(snapshot.emaLiquidity) * 7 + uint256(telemetry.liquidity)) / 8);
        baseline.lastTick = telemetry.tick;
        baseline.lastTimestamp = uint40(telemetry.eventTimestamp);
    }

    function _mitigationFromScore(uint16 score) private view returns (uint8 tier, uint40 throttleUntil, uint40 pauseUntil) {
        if (score >= highThreshold) {
            tier = 2;
            throttleUntil = uint40(block.timestamp + 180);
            pauseUntil = uint40(block.timestamp + 90);
        } else if (score >= mediumThreshold) {
            tier = 1;
            throttleUntil = uint40(block.timestamp + 45);
            pauseUntil = 0;
        }
    }

    function _emitMitigation(
        LogRecord calldata log,
        bytes32 poolId,
        uint16 score,
        uint8 tier,
        uint40 throttleUntil,
        uint40 pauseUntil,
        uint64 nonce
    ) private {
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
        features.priceDeviationBps =
            RiskMath.ratioBps(RiskMath.absDiff(uint256(sqrtPriceX96), uint256(baseline.emaPriceX96)), baseline.emaPriceX96);
        features.volumeSpikeBps = RiskMath.ratioBps(volume, baseline.emaVolume == 0 ? 1 : uint256(baseline.emaVolume));
        features.slippageAnomalyBps = _slippageAnomaly(baseline.lastTick, tick);
        features.liquidityImbalanceBps = _liquidityImbalance(baseline.emaLiquidity, liquidity);
        features.temporalCorrelationBps = _temporalCorrelation(eventTimestamp, baseline.lastTimestamp);
        features.mevHeuristicBps = _mevHeuristic(
            features.priceDeviationBps,
            features.volumeSpikeBps,
            features.temporalCorrelationBps,
            zeroForOne,
            baseline.lastTick,
            tick
        );
    }

    function _slippageAnomaly(int24 previousTick, int24 currentTick) private pure returns (uint16) {
        int256 tickDiff = int256(currentTick) - int256(previousTick);
        if (tickDiff < 0) tickDiff = -tickDiff;
        return RiskMath.clampBps(uint256(tickDiff) * 20);
    }

    function _liquidityImbalance(uint128 baselineLiquidity, uint128 liquidity) private pure returns (uint16) {
        return RiskMath.ratioBps(
            RiskMath.absDiff(uint256(liquidity), uint256(baselineLiquidity)),
            baselineLiquidity == 0 ? 1 : uint256(baselineLiquidity)
        );
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
