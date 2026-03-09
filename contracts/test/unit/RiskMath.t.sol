// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RiskMath} from "../../src/libraries/RiskMath.sol";

contract RiskMathTest is Test {
    function testScoreIsBoundedTo100() public pure {
        RiskMath.FeatureVector memory features = RiskMath.FeatureVector({
            priceDeviationBps: 10_000,
            volumeSpikeBps: 10_000,
            slippageAnomalyBps: 10_000,
            liquidityImbalanceBps: 10_000,
            temporalCorrelationBps: 10_000,
            mevHeuristicBps: 10_000
        });

        uint16 score = RiskMath.score(features, RiskMath.defaultWeights());
        assertEq(score, 100);
    }

    function testScoreReflectsFeatureIncrease() public pure {
        RiskMath.FeatureVector memory low = RiskMath.FeatureVector({
            priceDeviationBps: 500,
            volumeSpikeBps: 600,
            slippageAnomalyBps: 700,
            liquidityImbalanceBps: 800,
            temporalCorrelationBps: 900,
            mevHeuristicBps: 1_000
        });

        RiskMath.FeatureVector memory high = RiskMath.FeatureVector({
            priceDeviationBps: 2_000,
            volumeSpikeBps: 3_000,
            slippageAnomalyBps: 4_000,
            liquidityImbalanceBps: 2_000,
            temporalCorrelationBps: 2_000,
            mevHeuristicBps: 3_500
        });

        uint16 lowScore = RiskMath.score(low, RiskMath.defaultWeights());
        uint16 highScore = RiskMath.score(high, RiskMath.defaultWeights());

        assertGt(highScore, lowScore);
        assertLe(highScore, 100);
    }

    function testRatioBpsClampsTo10000() public pure {
        assertEq(RiskMath.ratioBps(25, 10), 10_000);
        assertEq(RiskMath.ratioBps(5, 10), 5_000);
    }
}
