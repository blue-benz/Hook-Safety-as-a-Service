#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LCOV_FILE="$ROOT_DIR/coverage/lcov-src-noir.info"

mkdir -p "$ROOT_DIR/coverage"

if ! FOUNDRY_OFFLINE="${FOUNDRY_OFFLINE:-true}" forge coverage \
  --exclude-tests \
  --no-match-coverage "scripts/" \
  --report lcov \
  --report-file "$LCOV_FILE" >/tmp/hook-safety-coverage.log 2>&1; then
  echo "forge coverage failed. Last 80 lines:"
  tail -n 80 /tmp/hook-safety-coverage.log || true
  exit 1
fi

TOTAL_LINES="$(awk -F: '/^LF:/{sum+=$2} END{print sum+0}' "$LCOV_FILE")"
HIT_LINES="$(awk -F: '/^LH:/{sum+=$2} END{print sum+0}' "$LCOV_FILE")"
TOTAL_FUNCS="$(awk -F: '/^FNF:/{sum+=$2} END{print sum+0}' "$LCOV_FILE")"
HIT_FUNCS="$(awk -F: '/^FNH:/{sum+=$2} END{print sum+0}' "$LCOV_FILE")"

if [[ "$TOTAL_LINES" -eq 0 || "$TOTAL_FUNCS" -eq 0 ]]; then
  echo "Coverage report is empty."
  exit 1
fi

echo "Coverage gate (contracts/src/**):"
echo "  Lines:     $HIT_LINES/$TOTAL_LINES"
echo "  Functions: $HIT_FUNCS/$TOTAL_FUNCS"

if [[ "$HIT_LINES" -ne "$TOTAL_LINES" ]]; then
  echo "Line coverage must be 100%."
  exit 1
fi

if [[ "$HIT_FUNCS" -ne "$TOTAL_FUNCS" ]]; then
  echo "Function coverage must be 100%."
  exit 1
fi

echo "Coverage gate passed."
echo "Run 'npm run contracts:coverage:raw' for the full Foundry summary table."
