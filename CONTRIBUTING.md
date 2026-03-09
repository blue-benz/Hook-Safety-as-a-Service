# Contributing

## Prerequisites

- Foundry (stable)
- Node.js >= 20.10
- npm >= 10

## Setup

```bash
make bootstrap
npm install
```

## Development Flow

1. Create a branch.
2. Keep dependency versions aligned across workspace packages.
3. Add or update tests for every behavior change.
4. Run:

```bash
npm run ci:deps
npm run contracts:test
npm run contracts:fuzz
npm run contracts:integration
npm run frontend:build
```

## Style

- Solidity: explicit errors, bounded arithmetic, deterministic control flow.
- TypeScript: strict mode, no implicit `any`.
- Keep docs synchronized with architecture changes.
