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
require_cmd curl
require_cmd forge

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
REACTIVE_RPC="${REACTIVE_RPC_URL:-}"
PRIVATE_KEY="${SEPOLIA_PRIVATE_KEY:-${PRIVATE_KEY:-}}"
OWNER="${OWNER_ADDRESS:-${OWNER:-}}"
UNICHAIN_EXPLORER_BASE="${UNICHAIN_EXPLORER_BASE:-https://sepolia.uniscan.xyz}"
LASNA_EXPLORER_BASE="${LASNA_EXPLORER_BASE:-https://lasna.reactscan.net}"
TX_TIMEOUT_SECONDS="${TX_TIMEOUT_SECONDS:-300}"
SUBSCRIPTION_SETTLE_SECONDS="${SUBSCRIPTION_SETTLE_SECONDS:-20}"

if [[ -z "$RPC_URL" || -z "$REACTIVE_RPC" || -z "$PRIVATE_KEY" || -z "$OWNER" ]]; then
  echo "Missing required env: RPC_URL, REACTIVE_RPC, PRIVATE_KEY, OWNER"
  exit 1
fi

is_tx_hash() {
  local maybe_hash="$1"
  [[ "$maybe_hash" =~ ^0x[0-9a-fA-F]{64}$ ]]
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
  output="$(cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --nonce "$nonce" --timeout "$TX_TIMEOUT_SECONDS" "$@")"
  tx_hash="$(awk '/^transactionHash[[:space:]]/{print $2; exit}' <<<"$output")"

  if [[ -z "$tx_hash" ]]; then
    echo "Failed to parse transaction hash."
    echo "$output"
    exit 1
  fi

  printf "%s\n" "$tx_hash"
}

find_event_tx() {
  local rpc="$1"
  local contract="$2"
  local topic0="$3"
  local topic1="$4"
  local from_block="$5"
  local result
  local tx_hash

  result="$(
    curl -sS --max-time 3 -X POST "$rpc" -H "Content-Type: application/json" --data \
      "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getLogs\",\"params\":[{\"fromBlock\":\"$from_block\",\"toBlock\":\"latest\",\"address\":\"$contract\",\"topics\":[\"$topic0\",\"$topic1\"]}],\"id\":1}" \
      2>/dev/null || true
  )"
  tx_hash="$(jq -r '.result[0].transactionHash // empty' <<<"${result:-{}}" 2>/dev/null || true)"
  printf "%s\n" "$tx_hash"
}

poll_cross_chain_outcome() {
  local attempts="$1"
  local i
  for ((i = 1; i <= attempts; i++)); do
    if [[ -z "$LASNA_REACT_TX" ]]; then
      LASNA_REACT_TX="$(find_event_tx "$REACTIVE_RPC" "$REACTIVE_ADDR" "$TOPIC_MITIGATION_PLANNED" "$POOL_ID" "$START_LASNA_HEX")"
    fi
    if [[ -z "$UNICHAIN_CALLBACK_TX" ]]; then
      UNICHAIN_CALLBACK_TX="$(find_event_tx "$RPC_URL" "$EXECUTOR_ADDR" "$TOPIC_MITIGATION_EXECUTED" "$POOL_ID" "$START_UNI_HEX")"
    fi

    if is_tx_hash "$LASNA_REACT_TX" && is_tx_hash "$UNICHAIN_CALLBACK_TX"; then
      break
    fi
    sleep 3
  done
}

hook_supports_demo_telemetry() {
  local hook_addr="$1"
  local probe_pool="0x1111111111111111111111111111111111111111111111111111111111111111"
  local probe_data
  local result
  local err_data

  probe_data="$(
    cast calldata \
      "emitTelemetryForDemo(bytes32,uint64,int24,uint160,uint128,int128,int128,bool,int256,uint24,uint8)" \
      "$probe_pool" \
      0 \
      1 \
      1 \
      1 \
      0 \
      0 \
      true \
      0 \
      0 \
      0
  )"

  result="$(
    curl -sS --max-time 10 -X POST "$RPC_URL" -H "Content-Type: application/json" --data \
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":[{\"to\":\"$hook_addr\",\"from\":\"$OWNER\",\"data\":\"$probe_data\"},\"latest\"]}"
  )"
  err_data="$(jq -r '.error.data // empty' <<<"$result")"
  [[ "$err_data" =~ ^0x180b8555 ]]
}

echo "Hook Safety Live Reactive Demo (Unichain <-> Lasna)"
echo "This run proves event->react->callback path using live Reactive subscriptions."
if [[ "${ORIGIN_CHAIN_ID:-}" == "1301" || "${DESTINATION_CHAIN_ID:-}" == "1301" ]]; then
  echo "Note: Reactive public testnet docs may not include Unichain Sepolia (1301) in the relay matrix."
  echo "If Lasna/callback txs are absent, validate origin/destination support in current Reactive docs."
fi
echo

echo "[Phase 0/6] Resolve deployments"
forge build >/tmp/hook-safety-live-build.log 2>&1

force_redeploy=0
if [[ -f "$DEPLOY_FILE" ]]; then
  existing_hook="$(jq -r '.unichainSepolia.hook // empty' "$DEPLOY_FILE")"
  if [[ -n "$existing_hook" && "$existing_hook" != "null" ]]; then
    if ! hook_supports_demo_telemetry "$existing_hook"; then
      force_redeploy=1
      echo "  Existing hook does not expose demo telemetry entrypoint."
      echo "  Forcing full redeploy to ensure live demo path is available."
    fi
  fi
fi

if [[ "$force_redeploy" -eq 1 ]]; then
  FORCE_REDEPLOY=true "$DEPLOY_SCRIPT" >/tmp/hook-safety-deploy-live.log
else
  "$DEPLOY_SCRIPT" >/tmp/hook-safety-deploy-live.log
fi

if [[ ! -f "$DEPLOY_FILE" ]]; then
  echo "Deployment output missing: $DEPLOY_FILE"
  exit 1
fi

HOOK_ADDR="$(jq -r '.unichainSepolia.hook' "$DEPLOY_FILE")"
EXECUTOR_ADDR="$(jq -r '.unichainSepolia.executor' "$DEPLOY_FILE")"
REACTIVE_ADDR="$(jq -r '.reactiveLasna.reactive // "N/A"' "$DEPLOY_FILE")"
REACTIVE_TX="$(jq -r '.reactiveLasna.tx.deployReactive // "N/A"' "$DEPLOY_FILE")"
REACTIVE_STATUS="$(jq -r '.reactiveLasna.status' "$DEPLOY_FILE")"
POOL_ID="$(jq -r '.unichainSepolia.poolId' "$DEPLOY_FILE")"
CUR0="$(jq -r '.unichainSepolia.poolKey.currency0' "$DEPLOY_FILE")"
CUR1="$(jq -r '.unichainSepolia.poolKey.currency1' "$DEPLOY_FILE")"
FEE="$(jq -r '.unichainSepolia.poolKey.fee' "$DEPLOY_FILE")"
TICK_SPACING="$(jq -r '.unichainSepolia.poolKey.tickSpacing' "$DEPLOY_FILE")"

if [[ "$REACTIVE_ADDR" == "N/A" || "$REACTIVE_ADDR" == "null" || -z "$REACTIVE_ADDR" ]]; then
  echo "Reactive contract address missing in $DEPLOY_FILE."
  exit 1
fi

echo "  Hook:      $HOOK_ADDR"
echo "  Executor:  $EXECUTOR_ADDR"
echo "  Reactive:  $REACTIVE_ADDR ($REACTIVE_STATUS)"
if is_tx_hash "$REACTIVE_TX"; then
  echo "  Reactive deployment tx: $LASNA_EXPLORER_BASE/tx/$REACTIVE_TX"
fi

echo
echo "[Phase 1/6] Baseline setup"
TX_AUTH_EXECUTOR="$(
  send_tx \
    "$HOOK_ADDR" \
    "setExecutor(address,bool)" \
    "$EXECUTOR_ADDR" \
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
TX_BIND_RVM="$(
  send_tx \
    "$EXECUTOR_ADDR" \
    "bindRvmId(address)" \
    "0x0000000000000000000000000000000000000000"
)"
TX_CLEAR="$(
  send_tx \
    "$HOOK_ADDR" \
    "clearMitigation(bytes32)" \
    "$POOL_ID"
)"

echo "  Authorize executor tx: $TX_AUTH_EXECUTOR"
echo "  Configure pool tx:     $TX_CONFIGURE_POOL"
echo "  Bind RVM tx:           $TX_BIND_RVM"
echo "  Clear mitigation tx:   $TX_CLEAR"

echo
echo "[Phase 1.5/6] Allow Reactive subscription to settle"
sleep "$SUBSCRIPTION_SETTLE_SECONDS"

START_UNI_BLOCK="$(cast block-number --rpc-url "$RPC_URL")"
START_LASNA_BLOCK="$(cast block-number --rpc-url "$REACTIVE_RPC")"
START_UNI_HEX="$(printf "0x%x" "$START_UNI_BLOCK")"
START_LASNA_HEX="$(printf "0x%x" "$START_LASNA_BLOCK")"

echo
echo "[Phase 2/6] Emit baseline telemetry (no mitigation expected)"
NOW="$(date +%s)"
TX_BASELINE="$(
  send_tx \
    "$HOOK_ADDR" \
    "emitTelemetryForDemo(bytes32,uint64,int24,uint160,uint128,int128,int128,bool,int256,uint24,uint8)" \
    "$POOL_ID" \
    "$NOW" \
    100 \
    1000000000000 \
    1000000 \
    -1000000000000000000 \
    900000000000000000 \
    true \
    -1000000000000000000 \
    3000 \
    20
)"
echo "  Baseline telemetry tx: $TX_BASELINE"
echo "  Unichain: $UNICHAIN_EXPLORER_BASE/tx/$TX_BASELINE"

echo
echo "[Phase 3/6] Emit anomalous telemetry (mitigation expected)"
NOW2="$((NOW + 1))"
TX_ATTACK_TELEMETRY="$(
  send_tx \
    "$HOOK_ADDR" \
    "emitTelemetryForDemo(bytes32,uint64,int24,uint160,uint128,int128,int128,bool,int256,uint24,uint8)" \
    "$POOL_ID" \
    "$NOW2" \
    2900 \
    9000000000000 \
    120000 \
    -7000000000000000000 \
    5000000000000000000 \
    true \
    -7000000000000000000 \
    20000 \
    99
)"
echo "  Attack telemetry tx: $TX_ATTACK_TELEMETRY"
echo "  Unichain: $UNICHAIN_EXPLORER_BASE/tx/$TX_ATTACK_TELEMETRY"

echo
echo "[Phase 4/6] Await Reactive processing on Lasna + callback on Unichain"
TOPIC_MITIGATION_PLANNED="$(cast keccak "MitigationPlanned(bytes32,uint8,uint16,uint64,uint40,uint40,bytes32)")"
TOPIC_MITIGATION_EXECUTED="$(cast keccak "MitigationExecuted(bytes32,uint8,uint16,uint64)")"

LASNA_REACT_TX=""
UNICHAIN_CALLBACK_TX=""
TX_ATTACK_RETRY=""

poll_cross_chain_outcome 15

if ! is_tx_hash "$LASNA_REACT_TX"; then
  echo "  No Lasna mitigation observed from first anomaly. Retrying with stronger anomaly."
  NOW3="$((NOW2 + 1))"
  TX_ATTACK_RETRY="$(
    send_tx \
      "$HOOK_ADDR" \
      "emitTelemetryForDemo(bytes32,uint64,int24,uint160,uint128,int128,int128,bool,int256,uint24,uint8)" \
      "$POOL_ID" \
      "$NOW3" \
      4200 \
      13000000000000 \
      1 \
      -9000000000000000000 \
      9000000000000000000 \
      true \
      -9000000000000000000 \
      20000 \
      100
  )"
  echo "  Retry anomaly tx:    $TX_ATTACK_RETRY"
  echo "  Unichain:            $UNICHAIN_EXPLORER_BASE/tx/$TX_ATTACK_RETRY"
  poll_cross_chain_outcome 15
fi

if is_tx_hash "$LASNA_REACT_TX"; then
  echo "  Lasna react tx:    $LASNA_REACT_TX"
  echo "  Lasna URL:         $LASNA_EXPLORER_BASE/tx/$LASNA_REACT_TX"
else
  echo "  Lasna react tx:    N/A (not observed in polling window)"
fi

if is_tx_hash "$UNICHAIN_CALLBACK_TX"; then
  echo "  Callback tx:       $UNICHAIN_CALLBACK_TX"
  echo "  Unichain callback: $UNICHAIN_EXPLORER_BASE/tx/$UNICHAIN_CALLBACK_TX"
else
  echo "  Callback tx:       N/A (not observed in polling window)"
fi

echo
echo "[Phase 5/6] Verify destination protection state"
STATE_RAW="$(cast call "$HOOK_ADDR" "getPoolState(bytes32)((uint64,uint64,uint40,uint40,uint40,uint8,uint8,bool,uint24,uint128,uint128,uint160,int24))" "$POOL_ID" --rpc-url "$RPC_URL")"
STATE_CLEAN="$(sed -E 's/ \[[^]]*]//g; s/[()]//g' <<<"$STATE_RAW")"
IFS=',' read -r _SEQ _MIT_NONCE PAUSE_UNTIL THROTTLE_UNTIL _LAST_SWAP TIER _LOCAL_RISK _LAST_DIR CURRENT_FEE _EMA _LIQ _SQRT _TICK <<<"$STATE_CLEAN"
PAUSE_UNTIL="$(xargs <<<"$PAUSE_UNTIL")"
THROTTLE_UNTIL="$(xargs <<<"$THROTTLE_UNTIL")"
TIER="$(xargs <<<"$TIER")"
CURRENT_FEE="$(xargs <<<"$CURRENT_FEE")"

echo "  Final tier:         $TIER"
echo "  Final fee pips:     $CURRENT_FEE"
echo "  Pause until:        $PAUSE_UNTIL"
echo "  Throttle until:     $THROTTLE_UNTIL"

echo
echo "[Phase 6/6] Persist demo artifacts"
tmp_json="$(mktemp)"
jq \
  --arg txAuth "$TX_AUTH_EXECUTOR" \
  --arg txCfg "$TX_CONFIGURE_POOL" \
  --arg txBind "$TX_BIND_RVM" \
  --arg txClear "$TX_CLEAR" \
  --arg txBase "$TX_BASELINE" \
  --arg txAttack "$TX_ATTACK_TELEMETRY" \
  --arg txAttackRetry "$TX_ATTACK_RETRY" \
  --arg txLasna "$LASNA_REACT_TX" \
  --arg txCallback "$UNICHAIN_CALLBACK_TX" \
  --arg tier "$TIER" \
  --arg fee "$CURRENT_FEE" \
  --arg pauseUntil "$PAUSE_UNTIL" \
  --arg throttleUntil "$THROTTLE_UNTIL" \
  '
  .liveReactive = {
    setup: {
      authorizeExecutor: $txAuth,
      configurePool: $txCfg,
      bindRvm: $txBind,
      clearMitigation: $txClear
    },
    telemetry: {
      baseline: $txBase,
      anomaly: $txAttack,
      retryAnomaly: ($txAttackRetry | if test("^0x[0-9a-fA-F]{64}$") then . else null end)
    },
    reactive: {
      lasnaMitigationPlannedTx: ($txLasna | if test("^0x[0-9a-fA-F]{64}$") then . else null end),
      unichainCallbackTx: ($txCallback | if test("^0x[0-9a-fA-F]{64}$") then . else null end)
    },
    outcome: {
      tier: ($tier | tonumber),
      feePips: ($fee | tonumber),
      pauseUntil: ($pauseUntil | tonumber),
      throttleUntil: ($throttleUntil | tonumber)
    }
  }
  ' \
  "$DEPLOY_FILE" >"$tmp_json"
mv "$tmp_json" "$DEPLOY_FILE"

upsert_env "LIVE_BASELINE_TELEMETRY_TX" "$TX_BASELINE"
upsert_env "LIVE_ATTACK_TELEMETRY_TX" "$TX_ATTACK_TELEMETRY"
upsert_env "LIVE_ATTACK_TELEMETRY_RETRY_TX" "$TX_ATTACK_RETRY"
upsert_env "LIVE_LASNA_REACTIVE_TX" "$LASNA_REACT_TX"
upsert_env "LIVE_UNICHAIN_CALLBACK_TX" "$UNICHAIN_CALLBACK_TX"

echo "Live reactive demo complete."
