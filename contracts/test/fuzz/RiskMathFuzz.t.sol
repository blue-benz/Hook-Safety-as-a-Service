// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RiskMath} from "../../src/libraries/RiskMath.sol";

contract RiskMathFuzzTest is Test {
    function testFuzzScoreBounded(
        uint16 p,
        uint16 v,
        uint16 s,
        uint16 l,
        uint16 t,
        uint16 m
    ) public pure {
        RiskMath.FeatureVector memory features = RiskMath.FeatureVector({
            priceDeviationBps: uint16(bound(uint256(p), 0, 10_000)),
            volumeSpikeBps: uint16(bound(uint256(v), 0, 10_000)),
            slippageAnomalyBps: uint16(bound(uint256(s), 0, 10_000)),
            liquidityImbalanceBps: uint16(bound(uint256(l), 0, 10_000)),
            temporalCorrelationBps: uint16(bound(uint256(t), 0, 10_000)),
            mevHeuristicBps: uint16(bound(uint256(m), 0, 10_000))
        });

        uint16 score = RiskMath.score(features, RiskMath.defaultWeights());
        assertLe(score, 100);
    }

    function testFuzzRatioNeverExceedsBps(uint256 numerator, uint256 denominator) public pure {
        uint16 ratio = RiskMath.ratioBps(numerator, denominator);
        assertLe(ratio, 10_000);
    }
}
