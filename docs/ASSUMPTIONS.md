# Assumptions / TBD

1. The repository contains `/context/uniswap_docs` rather than `/context/uniswap`; implementation references the available path.
2. Required pin `3779387` is implemented as v4-periphery commit `3779387e5d296f39df543d23524b050f89a62917`.
3. v4-core is pinned to `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc`, the submodule pointer linked from the pinned v4-periphery commit.
4. Automated sepolia demo script expects pre-populated `deployments/sepolia.json` with tx hashes.
5. Reactive callback payload first-argument rewrite is validated in integration tests via test harness simulation.
