#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOY_FILE="$ROOT_DIR/deployments/local.json"

if [[ ! -f "$DEPLOY_FILE" ]]; then
  echo "Missing deployment file: $DEPLOY_FILE"
  echo "Run local deployment first and write deployments/local.json"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required for demo scripts"
  exit 1
fi

HOOK_ADDR="$(jq -r '.hook' "$DEPLOY_FILE")"
EXECUTOR_ADDR="$(jq -r '.executor' "$DEPLOY_FILE")"
REACTIVE_ADDR="$(jq -r '.reactive' "$DEPLOY_FILE")"

ATTACK_TX="$(jq -r '.tx.attack // "N/A"' "$DEPLOY_FILE")"
DETECTION_TX="$(jq -r '.tx.detection // "N/A"' "$DEPLOY_FILE")"
MITIGATION_TX="$(jq -r '.tx.mitigation // "N/A"' "$DEPLOY_FILE")"

echo "Deployed Security Hook: $HOOK_ADDR"
echo "Deployed Security Executor: $EXECUTOR_ADDR"
echo "Deployed Reactive Contract: $REACTIVE_ADDR"
echo
echo "Tx: Attack Simulation"
echo "Local: $ATTACK_TX"
echo
echo "Tx: Detection Trigger"
echo "Local: $DETECTION_TX"
echo
echo "Tx: Mitigation Execution"
echo "Local: $MITIGATION_TX"
echo
echo "Liquidity protection outcome: Check hook pool state and mitigation events in local logs."
