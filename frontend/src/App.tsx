import { score, type FeatureVector } from "@hsaas/shared";

type EventRow = {
  id: string;
  pair: string;
  risk: number;
  status: "normal" | "elevated" | "emergency";
  action: string;
  timestamp: string;
};

const vectors: FeatureVector[] = [
  {
    priceDeviationBps: 1200,
    volumeSpikeBps: 3200,
    slippageAnomalyBps: 1800,
    liquidityImbalanceBps: 1500,
    temporalCorrelationBps: 4800,
    mevHeuristicBps: 3100,
  },
  {
    priceDeviationBps: 6000,
    volumeSpikeBps: 9200,
    slippageAnomalyBps: 7600,
    liquidityImbalanceBps: 6200,
    temporalCorrelationBps: 8000,
    mevHeuristicBps: 9100,
  },
  {
    priceDeviationBps: 2200,
    volumeSpikeBps: 2500,
    slippageAnomalyBps: 1800,
    liquidityImbalanceBps: 2000,
    temporalCorrelationBps: 1900,
    mevHeuristicBps: 2200,
  },
];

const rows: EventRow[] = [
  {
    id: "EVT-10241",
    pair: "WETH/USDC",
    risk: score(vectors[0]),
    status: "elevated",
    action: "Fee +90 bps / throttle 45s",
    timestamp: "2026-03-09 03:12:24 UTC",
  },
  {
    id: "EVT-10242",
    pair: "cbBTC/USDC",
    risk: score(vectors[1]),
    status: "emergency",
    action: "Pause 90s / fee emergency",
    timestamp: "2026-03-09 03:12:29 UTC",
  },
  {
    id: "EVT-10243",
    pair: "DEGEN/ETH",
    risk: score(vectors[2]),
    status: "normal",
    action: "No intervention",
    timestamp: "2026-03-09 03:12:37 UTC",
  },
];

export function App() {
  return (
    <main className="app-shell">
      <section className="hero">
        <p className="eyebrow">Reactive Security Layer</p>
        <h1>Hook Safety-as-a-Service</h1>
        <p className="subtitle">
          Autonomous firewall for Uniswap v4 hooks. Detects toxic flow and
          routes deterministic mitigation through Reactive callbacks.
        </p>
      </section>

      <section className="kpi-grid">
        <article>
          <h2>97</h2>
          <p>Peak Risk Score</p>
        </article>
        <article>
          <h2>12ms</h2>
          <p>Telemetry to Risk Eval</p>
        </article>
        <article>
          <h2>3</h2>
          <p>Mitigations Last Hour</p>
        </article>
        <article>
          <h2>0</h2>
          <p>Unauthorized Callbacks</p>
        </article>
      </section>

      <section className="table-wrap">
        <div className="table-head">
          <h3>Protection Events</h3>
          <span>Origin → Reactive → Destination</span>
        </div>
        <table>
          <thead>
            <tr>
              <th>ID</th>
              <th>Pool</th>
              <th>Risk</th>
              <th>Status</th>
              <th>Action</th>
              <th>Timestamp</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={row.id}>
                <td>{row.id}</td>
                <td>{row.pair}</td>
                <td>{row.risk}</td>
                <td>
                  <span className={`pill ${row.status}`}>{row.status}</span>
                </td>
                <td>{row.action}</td>
                <td>{row.timestamp}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>
    </main>
  );
}
