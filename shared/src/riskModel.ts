export type FeatureVector = {
  priceDeviationBps: number;
  volumeSpikeBps: number;
  slippageAnomalyBps: number;
  liquidityImbalanceBps: number;
  temporalCorrelationBps: number;
  mevHeuristicBps: number;
};

export type Weights = {
  priceDeviation: number;
  volumeSpike: number;
  slippageAnomaly: number;
  liquidityImbalance: number;
  temporalCorrelation: number;
  mevHeuristic: number;
};

export const BPS = 10_000;

export const DEFAULT_WEIGHTS: Weights = {
  priceDeviation: 2200,
  volumeSpike: 1800,
  slippageAnomaly: 1800,
  liquidityImbalance: 1300,
  temporalCorrelation: 1400,
  mevHeuristic: 1500,
};

export function score(
  features: FeatureVector,
  weights: Weights = DEFAULT_WEIGHTS,
): number {
  const totalWeight =
    weights.priceDeviation +
    weights.volumeSpike +
    weights.slippageAnomaly +
    weights.liquidityImbalance +
    weights.temporalCorrelation +
    weights.mevHeuristic;

  if (!totalWeight) return 0;

  const weighted =
    features.priceDeviationBps * weights.priceDeviation +
    features.volumeSpikeBps * weights.volumeSpike +
    features.slippageAnomalyBps * weights.slippageAnomaly +
    features.liquidityImbalanceBps * weights.liquidityImbalance +
    features.temporalCorrelationBps * weights.temporalCorrelation +
    features.mevHeuristicBps * weights.mevHeuristic;

  const normalizedBps = Math.min(BPS, Math.floor(weighted / totalWeight));
  return Math.min(100, Math.ceil(normalizedBps / 100));
}
