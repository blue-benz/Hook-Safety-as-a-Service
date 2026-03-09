#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOY_FILE="$ROOT_DIR/deployments/sepolia.json"

if [[ ! -f "$DEPLOY_FILE" ]]; then
  echo "Missing deployment file: $DEPLOY_FILE"
  echo "Run sepolia deployment first and write deployments/sepolia.json"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required for demo scripts"
  exit 1
fi

HOOK_ADDR="$(jq -r '.baseSepolia.hook' "$DEPLOY_FILE")"
ATTACK_TX="$(jq -r '.baseSepolia.tx.attack' "$DEPLOY_FILE")"
DETECTION_TX="$(jq -r '.lasna.tx.detection' "$DEPLOY_FILE")"
MITIGATION_TX="$(jq -r '.baseSepolia.tx.mitigation' "$DEPLOY_FILE")"

echo "Deployed Security Hook: $HOOK_ADDR"
echo
echo "Tx: Attack Simulation"
echo "BaseSepolia: https://sepolia.basescan.org/tx/$ATTACK_TX"
echo "Lasna: https://lasna.network/tx/$DETECTION_TX"
echo
echo "Tx: Detection Trigger"
echo "BaseSepolia: https://sepolia.basescan.org/tx/$ATTACK_TX"
echo "Lasna: https://lasna.network/tx/$DETECTION_TX"
echo
echo "Tx: Mitigation Execution"
echo "BaseSepolia: https://sepolia.basescan.org/tx/$MITIGATION_TX"
echo "Lasna: https://lasna.network/tx/$DETECTION_TX"
echo
echo "Liquidity protection outcome: verify MitigationExecuted events and tier/fee changes on the hook."
