# Security Model

## Threats Addressed

- Sandwich-like flow spikes and timing anomalies.
- Flash-loan-shaped volume bursts.
- Liquidity/price deviations beyond baseline behavior.
- Unauthorized callback execution attempts.
- Replay of old mitigation payloads.

## Core Controls

- `authorizedSenderOnly` callback proxy gate.
- `rvmIdOnly` ReactVM identity binding.
- Per-pool monotonic nonce replay protection.
- Non-reentrancy guard on mitigation executor.
- Strict tier bounds and score bounds.
- Owner/executor separation for privileged operations.

## Remaining Risks

- Heuristic false positives in exceptional volatility.
- Heuristic false negatives for novel attack patterns.
- Dependency and protocol upgrades outside this codebase.
- Operational misconfiguration (wrong callback proxy or chain IDs).

## Reporting

Security issues should be disclosed privately to maintainers before public disclosure.
Include:

- reproducible steps
- impact assessment
- affected chain and contract addresses
