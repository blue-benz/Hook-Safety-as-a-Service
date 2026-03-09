// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library RiskMath {
    uint256 internal constant BPS = 10_000;
    uint16 internal constant MAX_SCORE = 100;

    struct FeatureVector {
        uint16 priceDeviationBps;
        uint16 volumeSpikeBps;
        uint16 slippageAnomalyBps;
        uint16 liquidityImbalanceBps;
        uint16 temporalCorrelationBps;
        uint16 mevHeuristicBps;
    }

    struct Weights {
        uint16 priceDeviation;
        uint16 volumeSpike;
        uint16 slippageAnomaly;
        uint16 liquidityImbalance;
        uint16 temporalCorrelation;
        uint16 mevHeuristic;
    }

    function defaultWeights() internal pure returns (Weights memory) {
        return Weights({
            priceDeviation: 2_200,
            volumeSpike: 1_800,
            slippageAnomaly: 1_800,
            liquidityImbalance: 1_300,
            temporalCorrelation: 1_400,
            mevHeuristic: 1_500
        });
    }

    function score(FeatureVector memory features, Weights memory weights) internal pure returns (uint16) {
        uint256 totalWeight = uint256(weights.priceDeviation) + uint256(weights.volumeSpike)
            + uint256(weights.slippageAnomaly) + uint256(weights.liquidityImbalance)
            + uint256(weights.temporalCorrelation) + uint256(weights.mevHeuristic);
        if (totalWeight == 0) return 0;

        uint256 weighted = uint256(features.priceDeviationBps) * uint256(weights.priceDeviation)
            + uint256(features.volumeSpikeBps) * uint256(weights.volumeSpike)
            + uint256(features.slippageAnomalyBps) * uint256(weights.slippageAnomaly)
            + uint256(features.liquidityImbalanceBps) * uint256(weights.liquidityImbalance)
            + uint256(features.temporalCorrelationBps) * uint256(weights.temporalCorrelation)
            + uint256(features.mevHeuristicBps) * uint256(weights.mevHeuristic);

        // weighted/totalWeight is normalized to BPS, then translated to [0..100]
        uint256 normalizedBps = weighted / totalWeight;
        if (normalizedBps > BPS) normalizedBps = BPS;

        uint256 normalizedScore = (normalizedBps + 99) / 100;
        if (normalizedScore > MAX_SCORE) normalizedScore = MAX_SCORE;
        return uint16(normalizedScore);
    }

    function ratioBps(uint256 numerator, uint256 denominator) internal pure returns (uint16) {
        if (denominator == 0) return uint16(BPS);
        if (numerator == 0) return 0;
        if (numerator >= denominator) return uint16(BPS);

        uint256 raw;
        if (numerator <= type(uint256).max / BPS) {
            raw = (numerator * BPS) / denominator;
        } else {
            // For extremely large numerator values where multiplication by BPS may overflow,
            // denominator is guaranteed to be greater than numerator (early return above).
            // Divide first to stay within bounds.
            uint256 denominatorChunk = denominator / BPS;
            if (denominatorChunk == 0) return uint16(BPS);
            raw = numerator / denominatorChunk;
        }
        if (raw > BPS) raw = BPS;
        return uint16(raw);
    }

    function clampBps(uint256 value) internal pure returns (uint16) {
        if (value > BPS) return uint16(BPS);
        return uint16(value);
    }

    function absDiff(uint256 lhs, uint256 rhs) internal pure returns (uint256) {
        return lhs >= rhs ? lhs - rhs : rhs - lhs;
    }

    function absInt256(int256 value) internal pure returns (uint256) {
        return uint256(value >= 0 ? value : -value);
    }

    function absInt128(int128 value) internal pure returns (uint256) {
        return uint128(value >= 0 ? value : -value);
    }
}
