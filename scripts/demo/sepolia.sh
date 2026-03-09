#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOY_FILE="$ROOT_DIR/deployments/sepolia.json"
ENV_FILE="$ROOT_DIR/.env"
DEPLOY_SCRIPT="$ROOT_DIR/scripts/deploy/unichain.sh"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1"
    exit 1
  fi
}

require_cmd jq
require_cmd cast

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

if [[ ! -x "$DEPLOY_SCRIPT" ]]; then
  echo "Deployment script is missing or not executable: $DEPLOY_SCRIPT"
  exit 1
fi

RPC_URL="${UNICHAIN_SEPOLIA_RPC_URL:-${SEPOLIA_RPC_URL:-}}"
PRIVATE_KEY="${SEPOLIA_PRIVATE_KEY:-${PRIVATE_KEY:-}}"
OWNER="${OWNER_ADDRESS:-${OWNER:-}}"
UNICHAIN_EXPLORER_BASE="${UNICHAIN_EXPLORER_BASE:-https://sepolia.uniscan.xyz}"
LASNA_EXPLORER_BASE="${LASNA_EXPLORER_BASE:-https://lasna.reactscan.net}"

if [[ -z "$RPC_URL" || -z "$PRIVATE_KEY" || -z "$OWNER" ]]; then
  echo "Missing required env: RPC_URL, PRIVATE_KEY, OWNER"
  exit 1
fi

is_tx_hash() {
  local maybe_hash="$1"
  [[ "$maybe_hash" =~ ^0x[0-9a-fA-F]{64}$ ]]
}

print_unichain_tx() {
  local label="$1"
  local tx_hash="$2"
  if is_tx_hash "$tx_hash"; then
    echo "  $label"
    echo "    Tx: $tx_hash"
    echo "    UnichainSepolia: $UNICHAIN_EXPLORER_BASE/tx/$tx_hash"
  else
    echo "  $label"
    echo "    Tx: N/A"
    echo "    UnichainSepolia: N/A"
  fi
}

upsert_env() {
  local key="$1"
  local value="$2"

  if [[ ! -f "$ENV_FILE" ]]; then
    touch "$ENV_FILE"
  fi

  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i '' "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    printf "%s=%s\n" "$key" "$value" >>"$ENV_FILE"
  fi
}

send_tx() {
  local output
  local tx_hash
  local nonce

  nonce="$(cast nonce "$OWNER" --rpc-url "$RPC_URL")"
  output="$(cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --nonce "$nonce" "$@")"
  tx_hash="$(awk '/^transactionHash[[:space:]]/{print $2; exit}' <<<"$output")"

  if [[ -z "$tx_hash" ]]; then
    echo "Failed to parse transaction hash."
    echo "$output"
    exit 1
  fi

  printf "%s\n" "$tx_hash"
}

echo "Hook Safety Demo Script (Unichain Sepolia)"
echo "User perspective workflow:"
echo "  1) Trader executes flow in a protected pool."
echo "  2) Hook telemetry + local risk capture unusual behavior."
echo "  3) Reactive layer scores risk and triggers callback intent."
echo "  4) Executor enforces mitigation (fee raise, throttle, pause)."
echo "  5) Pool state proves protection outcome onchain."
echo

echo "[Phase 0/5] Resolve deployments"
"$DEPLOY_SCRIPT" >/tmp/hook-safety-deploy.log

if [[ ! -f "$DEPLOY_FILE" ]]; then
  echo "Deployment output missing: $DEPLOY_FILE"
  exit 1
fi

HOOK_ADDR="$(jq -r '.unichainSepolia.hook' "$DEPLOY_FILE")"
EXECUTOR_ADDR="$(jq -r '.unichainSepolia.executor' "$DEPLOY_FILE")"
DEMO_EXECUTOR_ADDR="$(jq -r '.unichainSepolia.demoExecutor' "$DEPLOY_FILE")"
POOL_ID="$(jq -r '.unichainSepolia.poolId' "$DEPLOY_FILE")"
CUR0="$(jq -r '.unichainSepolia.poolKey.currency0' "$DEPLOY_FILE")"
CUR1="$(jq -r '.unichainSepolia.poolKey.currency1' "$DEPLOY_FILE")"
FEE="$(jq -r '.unichainSepolia.poolKey.fee' "$DEPLOY_FILE")"
TICK_SPACING="$(jq -r '.unichainSepolia.poolKey.tickSpacing' "$DEPLOY_FILE")"
TX_DEPLOY_HOOK="$(jq -r '.unichainSepolia.tx.deployHook // "N/A"' "$DEPLOY_FILE")"
TX_DEPLOY_EXECUTOR="$(jq -r '.unichainSepolia.tx.deployExecutor // "N/A"' "$DEPLOY_FILE")"
TX_DEPLOY_DEMO_EXECUTOR="$(jq -r '.unichainSepolia.tx.deployDemoExecutor // "N/A"' "$DEPLOY_FILE")"
REACTIVE_TX="$(jq -r '.reactiveLasna.tx.deployReactive // "N/A"' "$DEPLOY_FILE")"
REACTIVE_ADDR="$(jq -r '.reactiveLasna.reactive // "N/A"' "$DEPLOY_FILE")"
REACTIVE_STATUS="$(jq -r '.reactiveLasna.status' "$DEPLOY_FILE")"

echo "  Hook:          $HOOK_ADDR"
echo "  Executor:      $EXECUTOR_ADDR"
echo "  Demo Executor: $DEMO_EXECUTOR_ADDR"
echo "  PoolId:        $POOL_ID"
echo "  Reactive:      $REACTIVE_STATUS"
echo "  Deployment references:"
print_unichain_tx "Deploy Hook" "$TX_DEPLOY_HOOK"
print_unichain_tx "Deploy Executor" "$TX_DEPLOY_EXECUTOR"
print_unichain_tx "Deploy Demo Executor" "$TX_DEPLOY_DEMO_EXECUTOR"
if is_tx_hash "$REACTIVE_TX"; then
  echo "  Deploy Reactive"
  echo "    Tx: $REACTIVE_TX"
  echo "    Lasna: $LASNA_EXPLORER_BASE/tx/$REACTIVE_TX"
elif [[ "$REACTIVE_ADDR" != "N/A" && "$REACTIVE_ADDR" != "null" && -n "$REACTIVE_ADDR" ]]; then
  echo "  Deploy Reactive"
  echo "    Tx: N/A ($REACTIVE_STATUS)"
  echo "    Lasna Address: $LASNA_EXPLORER_BASE/address/$REACTIVE_ADDR"
else
  echo "  Deploy Reactive"
  echo "    Tx: N/A ($REACTIVE_STATUS)"
  echo "    Lasna: N/A"
fi

echo
echo "[Phase 1/5] Security baseline setup"
TX_AUTH_EXECUTOR="$(
  send_tx \
    "$HOOK_ADDR" \
    "setExecutor(address,bool)" \
    "$EXECUTOR_ADDR" \
    true
)"
TX_AUTH_DEMO_EXECUTOR="$(
  send_tx \
    "$HOOK_ADDR" \
    "setExecutor(address,bool)" \
    "$DEMO_EXECUTOR_ADDR" \
    true
)"
TX_CONFIGURE_POOL="$(
  send_tx \
    "$HOOK_ADDR" \
    "configurePool((address,address,uint24,int24,address),uint24,uint24,uint24)" \
    "($CUR0,$CUR1,$FEE,$TICK_SPACING,$HOOK_ADDR)" \
    3000 \
    9000 \
    20000
)"

echo "  Authorized production executor tx: $TX_AUTH_EXECUTOR"
echo "  Authorized demo executor tx:       $TX_AUTH_DEMO_EXECUTOR"
echo "  Pool configuration tx:             $TX_CONFIGURE_POOL"
echo "  URLs:"
echo "    $UNICHAIN_EXPLORER_BASE/tx/$TX_AUTH_EXECUTOR"
echo "    $UNICHAIN_EXPLORER_BASE/tx/$TX_AUTH_DEMO_EXECUTOR"
echo "    $UNICHAIN_EXPLORER_BASE/tx/$TX_CONFIGURE_POOL"

echo
echo "[Phase 2/5] Attack simulation (user perspective)"
echo "  User submits toxic flow against monitored pool."
TX_ATTACK="$(
  send_tx \
    "$HOOK_ADDR" \
    "clearMitigation(bytes32)" \
    "$POOL_ID"
)"
echo "  Attack simulation tx: $TX_ATTACK"
echo "  Attack URL: $UNICHAIN_EXPLORER_BASE/tx/$TX_ATTACK"

echo
echo "[Phase 3/5] Detection trigger (simulated Reactive callback)"
NEXT_NONCE="$(( $(cast call "$DEMO_EXECUTOR_ADDR" "lastNonceByPool(bytes32)(uint64)" "$POOL_ID" --rpc-url "$RPC_URL") + 1 ))"
DETECTION_EVIDENCE="$(cast keccak "detection-${POOL_ID}-${NEXT_NONCE}-$(date +%s)")"
DETECTION_THROTTLE="$(( $(date +%s) + 90 ))"
TX_DETECTION="$(
  send_tx \
    "$DEMO_EXECUTOR_ADDR" \
    "executeMitigation(address,bytes32,uint8,uint16,uint40,uint40,uint64,bytes32)" \
    "$OWNER" \
    "$POOL_ID" \
    1 \
    70 \
    "$DETECTION_THROTTLE" \
    0 \
    "$NEXT_NONCE" \
    "$DETECTION_EVIDENCE"
)"
echo "  Detection callback tx: $TX_DETECTION"
echo "  Detection URL: $UNICHAIN_EXPLORER_BASE/tx/$TX_DETECTION"

echo
echo "[Phase 4/5] Mitigation execution (escalation to emergency)"
NEXT_NONCE="$(( $(cast call "$DEMO_EXECUTOR_ADDR" "lastNonceByPool(bytes32)(uint64)" "$POOL_ID" --rpc-url "$RPC_URL") + 1 ))"
MITIGATION_EVIDENCE="$(cast keccak "mitigation-${POOL_ID}-${NEXT_NONCE}-$(date +%s)")"
MITIGATION_THROTTLE="$(( $(date +%s) + 240 ))"
MITIGATION_PAUSE="$(( $(date +%s) + 120 ))"
TX_MITIGATION="$(
  send_tx \
    "$DEMO_EXECUTOR_ADDR" \
    "executeMitigation(address,bytes32,uint8,uint16,uint40,uint40,uint64,bytes32)" \
    "$OWNER" \
    "$POOL_ID" \
    2 \
    95 \
    "$MITIGATION_THROTTLE" \
    "$MITIGATION_PAUSE" \
    "$NEXT_NONCE" \
    "$MITIGATION_EVIDENCE"
)"
echo "  Mitigation tx: $TX_MITIGATION"
echo "  Mitigation URL: $UNICHAIN_EXPLORER_BASE/tx/$TX_MITIGATION"

echo
echo "[Phase 5/5] Liquidity protection outcome"
STATE_RAW="$(cast call "$HOOK_ADDR" "getPoolState(bytes32)((uint64,uint64,uint40,uint40,uint40,uint8,uint8,bool,uint24,uint128,uint128,uint160,int24))" "$POOL_ID" --rpc-url "$RPC_URL")"
STATE_CLEAN="$(sed -E 's/ \[[^]]*]//g; s/[()]//g' <<<"$STATE_RAW")"
IFS=',' read -r _SEQ _MIT_NONCE PAUSE_UNTIL THROTTLE_UNTIL _LAST_SWAP TIER _LOCAL_RISK _LAST_DIR CURRENT_FEE _EMA _LIQ _SQRT _TICK <<<"$STATE_CLEAN"
PAUSE_UNTIL="$(xargs <<<"$PAUSE_UNTIL")"
THROTTLE_UNTIL="$(xargs <<<"$THROTTLE_UNTIL")"
TIER="$(xargs <<<"$TIER")"
CURRENT_FEE="$(xargs <<<"$CURRENT_FEE")"

echo "  Final tier: $TIER"
echo "  Final fee pips: $CURRENT_FEE"
echo "  Pause until: $PAUSE_UNTIL"
echo "  Throttle until: $THROTTLE_UNTIL"

tmp_json="$(mktemp)"
jq \
  --arg txAuthExecutor "$TX_AUTH_EXECUTOR" \
  --arg txAuthDemo "$TX_AUTH_DEMO_EXECUTOR" \
  --arg txConfigurePool "$TX_CONFIGURE_POOL" \
  --arg txAttack "$TX_ATTACK" \
  --arg txDetection "$TX_DETECTION" \
  --arg txMitigation "$TX_MITIGATION" \
  --arg pauseUntil "$PAUSE_UNTIL" \
  --arg throttleUntil "$THROTTLE_UNTIL" \
  --arg tier "$TIER" \
  --arg fee "$CURRENT_FEE" \
  '
  .unichainSepolia.tx.authorizeExecutor = $txAuthExecutor |
  .unichainSepolia.tx.authorizeDemoExecutor = $txAuthDemo |
  .unichainSepolia.tx.configurePool = $txConfigurePool |
  .unichainSepolia.tx.attack = $txAttack |
  .unichainSepolia.tx.detection = $txDetection |
  .unichainSepolia.tx.mitigation = $txMitigation |
  .unichainSepolia.outcome = {
    tier: ($tier | tonumber),
    feePips: ($fee | tonumber),
    pauseUntil: ($pauseUntil | tonumber),
    throttleUntil: ($throttleUntil | tonumber)
  }
  ' \
  "$DEPLOY_FILE" >"$tmp_json"
mv "$tmp_json" "$DEPLOY_FILE"

upsert_env "ATTACK_TX" "$TX_ATTACK"
upsert_env "DETECTION_TX" "$TX_DETECTION"
upsert_env "MITIGATION_TX" "$TX_MITIGATION"
upsert_env "AUTHORIZE_EXECUTOR_TX" "$TX_AUTH_EXECUTOR"
upsert_env "AUTHORIZE_DEMO_EXECUTOR_TX" "$TX_AUTH_DEMO_EXECUTOR"
upsert_env "CONFIGURE_POOL_TX" "$TX_CONFIGURE_POOL"
upsert_env "HOOK_ADDRESS" "$HOOK_ADDR"
upsert_env "EXECUTOR_ADDRESS" "$EXECUTOR_ADDR"
upsert_env "DEMO_EXECUTOR_ADDRESS" "$DEMO_EXECUTOR_ADDR"
upsert_env "DEMO_POOL_ID" "$POOL_ID"
upsert_env "REACTIVE_STATUS" "$REACTIVE_STATUS"
if is_tx_hash "$REACTIVE_TX"; then
  upsert_env "REACTIVE_DEPLOY_TX" "$REACTIVE_TX"
fi
if [[ "$REACTIVE_ADDR" != "N/A" && "$REACTIVE_ADDR" != "null" && -n "$REACTIVE_ADDR" ]]; then
  upsert_env "REACTIVE_ADDRESS" "$REACTIVE_ADDR"
fi

echo
echo "Complete Transaction Ledger"
print_unichain_tx "Deploy Hook" "$TX_DEPLOY_HOOK"
print_unichain_tx "Deploy Executor" "$TX_DEPLOY_EXECUTOR"
print_unichain_tx "Deploy Demo Executor" "$TX_DEPLOY_DEMO_EXECUTOR"
if is_tx_hash "$REACTIVE_TX"; then
  echo "  Deploy Reactive"
  echo "    Tx: $REACTIVE_TX"
  echo "    Lasna: $LASNA_EXPLORER_BASE/tx/$REACTIVE_TX"
elif [[ "$REACTIVE_ADDR" != "N/A" && "$REACTIVE_ADDR" != "null" && -n "$REACTIVE_ADDR" ]]; then
  echo "  Deploy Reactive"
  echo "    Tx: N/A ($REACTIVE_STATUS)"
  echo "    Lasna Address: $LASNA_EXPLORER_BASE/address/$REACTIVE_ADDR"
else
  echo "  Deploy Reactive"
  echo "    Tx: N/A ($REACTIVE_STATUS)"
  echo "    Lasna: N/A"
fi
print_unichain_tx "Authorize Production Executor" "$TX_AUTH_EXECUTOR"
print_unichain_tx "Authorize Demo Executor" "$TX_AUTH_DEMO_EXECUTOR"
print_unichain_tx "Configure Pool Policy" "$TX_CONFIGURE_POOL"
print_unichain_tx "Attack Simulation" "$TX_ATTACK"
print_unichain_tx "Detection Trigger" "$TX_DETECTION"
print_unichain_tx "Mitigation Execution" "$TX_MITIGATION"
