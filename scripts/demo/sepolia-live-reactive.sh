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
CALLBACK_PROXY="${CALLBACK_PROXY:-${DESTINATION_CALLBACK_PROXY_ADDR:-}}"
UNICHAIN_EXPLORER_BASE="${UNICHAIN_EXPLORER_BASE:-https://sepolia.uniscan.xyz}"
LASNA_EXPLORER_BASE="${LASNA_EXPLORER_BASE:-https://lasna.reactscan.net}"
TX_TIMEOUT_SECONDS="${TX_TIMEOUT_SECONDS:-300}"
SUBSCRIPTION_SETTLE_SECONDS="${SUBSCRIPTION_SETTLE_SECONDS:-20}"
SUBSCRIPTION_READY_ATTEMPTS="${SUBSCRIPTION_READY_ATTEMPTS:-20}"
POLL_ATTEMPTS="${POLL_ATTEMPTS:-60}"
STRICT_LIVE_REACTIVE="${STRICT_LIVE_REACTIVE:-true}"
REACTIVE_RPC_TIMEOUT_SECONDS="${REACTIVE_RPC_TIMEOUT_SECONDS:-4}"
ORIGIN_RPC_TIMEOUT_SECONDS="${ORIGIN_RPC_TIMEOUT_SECONDS:-3}"
POLL_SLEEP_SECONDS="${POLL_SLEEP_SECONDS:-2}"
LASNA_BACKFILL_TX_WINDOW="${LASNA_BACKFILL_TX_WINDOW:-300}"
FINAL_BACKFILL_WAIT_SECONDS="${FINAL_BACKFILL_WAIT_SECONDS:-180}"

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
  local latest_block
  local start_block
  local chunk_start
  local chunk_end
  local start_hex
  local end_hex
  local result
  local tx_hash

  start_block="$(cast to-dec "$from_block" 2>/dev/null || echo 0)"
  latest_block="$(cast block-number --rpc-url "$rpc" 2>/dev/null || echo 0)"

  for ((chunk_end = latest_block; chunk_end >= start_block; chunk_end -= 10)); do
    chunk_start=$((chunk_end - 9))
    if ((chunk_start < start_block)); then
      chunk_start="$start_block"
    fi
    start_hex="$(printf "0x%x" "$chunk_start")"
    end_hex="$(printf "0x%x" "$chunk_end")"

    result="$(
      curl -sS --max-time "$ORIGIN_RPC_TIMEOUT_SECONDS" -X POST "$rpc" -H "Content-Type: application/json" --data \
        "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getLogs\",\"params\":[{\"fromBlock\":\"$start_hex\",\"toBlock\":\"$end_hex\",\"address\":\"$contract\",\"topics\":[\"$topic0\",\"$topic1\"]}],\"id\":1}" \
        2>/dev/null || true
    )"
    tx_hash="$(jq -r '.result[0].transactionHash // empty' <<<"${result:-{}}" 2>/dev/null || true)"
    if is_tx_hash "$tx_hash"; then
      printf "%s\n" "$tx_hash"
      return 0
    fi
  done

  printf "%s\n" ""
}

fetch_rvm_id() {
  local reactive_addr="$1"
  local result
  result="$(
    curl -sS --max-time "$REACTIVE_RPC_TIMEOUT_SECONDS" -X POST "$REACTIVE_RPC" -H "Content-Type: application/json" --data \
      "{\"jsonrpc\":\"2.0\",\"method\":\"rnk_getRnkAddressMapping\",\"params\":[\"$reactive_addr\"],\"id\":1}" \
      2>/dev/null || true
  )"
  jq -r '.result.rvmId // empty' <<<"${result:-{}}" 2>/dev/null || true
}

has_reactive_subscription() {
  local rvm_id="$1"
  local chain_id="$2"
  local origin_contract="$3"
  local topic_0="$4"
  local origin_contract_lc
  local topic_0_lc
  local result

  result="$(
    curl -sS --max-time "$REACTIVE_RPC_TIMEOUT_SECONDS" -X POST "$REACTIVE_RPC" -H "Content-Type: application/json" --data \
      "{\"jsonrpc\":\"2.0\",\"method\":\"rnk_getSubscribers\",\"params\":[\"$rvm_id\"],\"id\":1}" \
      2>/dev/null || true
  )"
  origin_contract_lc="$(printf "%s" "$origin_contract" | tr '[:upper:]' '[:lower:]')"
  topic_0_lc="$(printf "%s" "$topic_0" | tr '[:upper:]' '[:lower:]')"

  jq -e \
    --argjson chain "$chain_id" \
    --arg contract "$origin_contract_lc" \
    --arg topic "$topic_0_lc" \
    '
      (.result // [])
      | map(
          select(
            ((.chainId | tonumber) == $chain)
            and ((.contract // "" | ascii_downcase) == $contract)
            and ((.topics[0] // "" | ascii_downcase) == $topic)
          )
        )
      | length > 0
    ' <<<"${result:-{}}" >/dev/null 2>&1
}

poll_cross_chain_outcome() {
  local ref_tx="$1"
  local attempts="$2"
  local i
  local match
  local match_hash
  local match_number

  for ((i = 1; i <= attempts; i++)); do
    if ((i == 1 || i % 10 == 0)); then
      echo "  Poll attempt $i/$attempts ..."
    fi
    if [[ -z "$LASNA_REACT_TX" ]]; then
      match="$(find_lasna_react_tx_for_ref "$ref_tx")"
      if [[ -n "$match" ]]; then
        match_hash="$(awk '{print $1}' <<<"$match")"
        match_number="$(awk '{print $2}' <<<"$match")"
        if is_tx_hash "$match_hash" && has_lasna_mitigation_planned "$match_number"; then
          LASNA_REACT_TX="$match_hash"
          LASNA_REACT_TX_NUMBER="$match_number"
        fi
      fi
    fi
    if [[ -z "$UNICHAIN_CALLBACK_TX" && -n "$LASNA_REACT_TX" ]]; then
      if [[ -n "$CALLBACK_PROXY" && -n "$LASNA_REACT_TX_NUMBER" ]]; then
        LASNA_EVIDENCE_HASH="$(extract_lasna_evidence_hash "$LASNA_REACT_TX_NUMBER")"
        UNICHAIN_CALLBACK_TX="$(find_callback_proxy_tx_by_evidence "$LASNA_EVIDENCE_HASH" "$START_UNI_HEX")"
        if is_tx_hash "$UNICHAIN_CALLBACK_TX"; then
          UNICHAIN_CALLBACK_KIND="proxy"
        fi
      fi
      if [[ -z "$UNICHAIN_CALLBACK_TX" ]]; then
        UNICHAIN_CALLBACK_TX="$(find_event_tx "$RPC_URL" "$EXECUTOR_ADDR" "$TOPIC_MITIGATION_EXECUTED" "$POOL_ID" "$START_UNI_HEX")"
        if is_tx_hash "$UNICHAIN_CALLBACK_TX"; then
          UNICHAIN_CALLBACK_KIND="executor"
        fi
      fi
    fi

    if is_tx_hash "$LASNA_REACT_TX" && is_tx_hash "$UNICHAIN_CALLBACK_TX"; then
      break
    fi
    sleep "$POLL_SLEEP_SECONDS"
  done

  # Backfill once in case RNK indexing lagged past the active polling window.
  if [[ -z "$LASNA_REACT_TX" ]]; then
    match="$(find_lasna_react_tx_for_ref_backfill "$ref_tx" "$LASNA_BACKFILL_TX_WINDOW")"
    if [[ -n "$match" ]]; then
      match_hash="$(awk '{print $1}' <<<"$match")"
      match_number="$(awk '{print $2}' <<<"$match")"
      if is_tx_hash "$match_hash" && has_lasna_mitigation_planned "$match_number"; then
        LASNA_REACT_TX="$match_hash"
        LASNA_REACT_TX_NUMBER="$match_number"
      fi
    fi
  fi

  if [[ -z "$UNICHAIN_CALLBACK_TX" && -n "$LASNA_REACT_TX" && -n "$CALLBACK_PROXY" && -n "$LASNA_REACT_TX_NUMBER" ]]; then
    LASNA_EVIDENCE_HASH="$(extract_lasna_evidence_hash "$LASNA_REACT_TX_NUMBER")"
    UNICHAIN_CALLBACK_TX="$(find_callback_proxy_tx_by_evidence "$LASNA_EVIDENCE_HASH" "$START_UNI_HEX")"
    if is_tx_hash "$UNICHAIN_CALLBACK_TX"; then
      UNICHAIN_CALLBACK_KIND="proxy"
    fi
  fi

  if [[ -z "$UNICHAIN_CALLBACK_TX" && -n "$LASNA_REACT_TX" ]]; then
    UNICHAIN_CALLBACK_TX="$(find_event_tx "$RPC_URL" "$EXECUTOR_ADDR" "$TOPIC_MITIGATION_EXECUTED" "$POOL_ID" "$START_UNI_HEX")"
    if is_tx_hash "$UNICHAIN_CALLBACK_TX"; then
      UNICHAIN_CALLBACK_KIND="executor"
    fi
  fi
}

find_lasna_react_tx_for_ref() {
  local ref_tx="$1"
  local vm_json
  local last_hex
  local last_dec
  local from_dec
  local from_hex
  local limit_dec
  local limit_hex
  local txs_json
  local reactive_lc
  local ref_tx_lc
  local chain_id

  vm_json="$(
    curl -sS --max-time "$REACTIVE_RPC_TIMEOUT_SECONDS" -X POST "$REACTIVE_RPC" -H "Content-Type: application/json" --data \
      "{\"jsonrpc\":\"2.0\",\"method\":\"rnk_getVm\",\"params\":[\"$RVM_ID\"],\"id\":1}" \
      2>/dev/null || true
  )"
  last_hex="$(jq -r '.result.lastTxNumber // "0x0"' <<<"${vm_json:-{}}" 2>/dev/null || true)"
  last_dec="$(cast to-dec "$last_hex" 2>/dev/null || echo 0)"
  if [[ -z "${LASNA_LAST_SCANNED_TX_DEC:-}" ]]; then
    LASNA_LAST_SCANNED_TX_DEC=-1
  fi
  if ((LASNA_LAST_SCANNED_TX_DEC < 0)); then
    from_dec=$((last_dec > 50 ? last_dec - 50 : 0))
  else
    from_dec=$((LASNA_LAST_SCANNED_TX_DEC + 1))
  fi
  if ((from_dec > last_dec)); then
    LASNA_LAST_SCANNED_TX_DEC="$last_dec"
    printf "%s\n" ""
    return 0
  fi

  limit_dec=$((last_dec - from_dec + 1))
  if ((limit_dec > 50)); then
    from_dec=$((last_dec - 49))
    limit_dec=50
  fi

  from_hex="$(printf "0x%x" "$from_dec")"
  limit_hex="$(printf "0x%x" "$limit_dec")"
  reactive_lc="$(printf "%s" "$REACTIVE_ADDR" | tr '[:upper:]' '[:lower:]')"
  ref_tx_lc="$(printf "%s" "$ref_tx" | tr '[:upper:]' '[:lower:]')"
  chain_id="${ORIGIN_CHAIN_ID:-1301}"
  txs_json="$(
    curl -sS --max-time "$REACTIVE_RPC_TIMEOUT_SECONDS" -X POST "$REACTIVE_RPC" -H "Content-Type: application/json" --data \
      "{\"jsonrpc\":\"2.0\",\"method\":\"rnk_getTransactions\",\"params\":[\"$RVM_ID\",\"$from_hex\",\"$limit_hex\"],\"id\":1}" \
      2>/dev/null || true
  )"
  LASNA_LAST_SCANNED_TX_DEC="$last_dec"

  jq -r \
    --arg to "$reactive_lc" \
    --arg ref "$ref_tx_lc" \
    --argjson chain "$chain_id" \
    '
      (.result // [])
      | map(
          select(
            ((.to // "" | ascii_downcase) == $to)
            and ((.refTx // "" | ascii_downcase) == $ref)
            and ((.refChainId | tonumber) == $chain)
          )
        )
      | last // empty
      | if . == "" then empty else "\(.hash) \(.number)" end
    ' <<<"${txs_json:-{}}" 2>/dev/null || true
}

find_lasna_react_tx_for_ref_backfill() {
  local ref_tx="$1"
  local lookback="${2:-300}"
  local vm_json
  local last_hex
  local last_dec
  local from_dec
  local from_hex
  local limit_hex
  local txs_json
  local reactive_lc
  local ref_tx_lc
  local chain_id

  vm_json="$(
    curl -sS --max-time "$REACTIVE_RPC_TIMEOUT_SECONDS" -X POST "$REACTIVE_RPC" -H "Content-Type: application/json" --data \
      "{\"jsonrpc\":\"2.0\",\"method\":\"rnk_getVm\",\"params\":[\"$RVM_ID\"],\"id\":1}" \
      2>/dev/null || true
  )"
  last_hex="$(jq -r '.result.lastTxNumber // "0x0"' <<<"${vm_json:-{}}" 2>/dev/null || true)"
  last_dec="$(cast to-dec "$last_hex" 2>/dev/null || echo 0)"
  from_dec=$((last_dec > lookback ? last_dec - lookback : 0))

  from_hex="$(printf "0x%x" "$from_dec")"
  limit_hex="$(printf "0x%x" "$((last_dec - from_dec + 1))")"
  reactive_lc="$(printf "%s" "$REACTIVE_ADDR" | tr '[:upper:]' '[:lower:]')"
  ref_tx_lc="$(printf "%s" "$ref_tx" | tr '[:upper:]' '[:lower:]')"
  chain_id="${ORIGIN_CHAIN_ID:-1301}"

  txs_json="$(
    curl -sS --max-time "$REACTIVE_RPC_TIMEOUT_SECONDS" -X POST "$REACTIVE_RPC" -H "Content-Type: application/json" --data \
      "{\"jsonrpc\":\"2.0\",\"method\":\"rnk_getTransactions\",\"params\":[\"$RVM_ID\",\"$from_hex\",\"$limit_hex\"],\"id\":1}" \
      2>/dev/null || true
  )"

  jq -r \
    --arg to "$reactive_lc" \
    --arg ref "$ref_tx_lc" \
    --argjson chain "$chain_id" \
    '
      (.result // [])
      | map(
          select(
            ((.to // "" | ascii_downcase) == $to)
            and ((.refTx // "" | ascii_downcase) == $ref)
            and ((.refChainId | tonumber) == $chain)
          )
        )
      | last // empty
      | if . == "" then empty else "\(.hash) \(.number)" end
    ' <<<"${txs_json:-{}}" 2>/dev/null || true
}

find_latest_lasna_mitigation_tx() {
  local lookback="${1:-300}"
  local vm_json
  local last_hex
  local last_dec
  local from_dec
  local from_hex
  local limit_hex
  local txs_json
  local reactive_lc
  local chain_id
  local candidates
  local tx_hash
  local tx_number

  vm_json="$(
    curl -sS --max-time "$REACTIVE_RPC_TIMEOUT_SECONDS" -X POST "$REACTIVE_RPC" -H "Content-Type: application/json" --data \
      "{\"jsonrpc\":\"2.0\",\"method\":\"rnk_getVm\",\"params\":[\"$RVM_ID\"],\"id\":1}" \
      2>/dev/null || true
  )"
  last_hex="$(jq -r '.result.lastTxNumber // "0x0"' <<<"${vm_json:-{}}" 2>/dev/null || true)"
  last_dec="$(cast to-dec "$last_hex" 2>/dev/null || echo 0)"
  from_dec=$((last_dec > lookback ? last_dec - lookback : 0))

  from_hex="$(printf "0x%x" "$from_dec")"
  limit_hex="$(printf "0x%x" "$((last_dec - from_dec + 1))")"
  reactive_lc="$(printf "%s" "$REACTIVE_ADDR" | tr '[:upper:]' '[:lower:]')"
  chain_id="${ORIGIN_CHAIN_ID:-1301}"

  txs_json="$(
    curl -sS --max-time "$REACTIVE_RPC_TIMEOUT_SECONDS" -X POST "$REACTIVE_RPC" -H "Content-Type: application/json" --data \
      "{\"jsonrpc\":\"2.0\",\"method\":\"rnk_getTransactions\",\"params\":[\"$RVM_ID\",\"$from_hex\",\"$limit_hex\"],\"id\":1}" \
      2>/dev/null || true
  )"

  candidates="$(
    jq -r \
      --arg to "$reactive_lc" \
      --argjson chain "$chain_id" \
      '
        (.result // [])
        | reverse
        | map(
            select(
              ((.to // "" | ascii_downcase) == $to)
              and ((.refChainId | tonumber) == $chain)
              and (.hash // "" | test("^0x[0-9a-fA-F]{64}$"))
            )
          )
        | .[]
        | "\(.hash) \(.number)"
      ' <<<"${txs_json:-{}}" 2>/dev/null || true
  )"

  while read -r tx_hash tx_number; do
    if [[ -z "$tx_hash" || -z "$tx_number" ]]; then
      continue
    fi
    if has_lasna_mitigation_planned "$tx_number"; then
      printf "%s %s\n" "$tx_hash" "$tx_number"
      return 0
    fi
  done <<<"$candidates"

  printf "%s\n" ""
}

has_lasna_mitigation_planned() {
  local tx_number="$1"
  local logs_json
  local topic_lc
  local pool_lc

  logs_json="$(
    curl -sS --max-time "$REACTIVE_RPC_TIMEOUT_SECONDS" -X POST "$REACTIVE_RPC" -H "Content-Type: application/json" --data \
      "{\"jsonrpc\":\"2.0\",\"method\":\"rnk_getTransactionLogs\",\"params\":[\"$RVM_ID\",\"$tx_number\"],\"id\":1}" \
      2>/dev/null || true
  )"
  topic_lc="$(printf "%s" "$TOPIC_MITIGATION_PLANNED" | tr '[:upper:]' '[:lower:]')"
  pool_lc="$(printf "%s" "$POOL_ID" | tr '[:upper:]' '[:lower:]')"

  jq -e \
    --arg topic "$topic_lc" \
    --arg pool "$pool_lc" \
    '
      (.result // [])
      | map(
          select(
            ((.topics[0] // "" | ascii_downcase) == $topic)
            and ((.topics[1] // "" | ascii_downcase) == $pool)
          )
        )
      | length > 0
    ' <<<"${logs_json:-{}}" >/dev/null 2>&1
}

extract_lasna_evidence_hash() {
  local tx_number="$1"
  local logs_json
  local topic_lc
  local pool_lc
  local data_hex

  logs_json="$(
    curl -sS --max-time "$REACTIVE_RPC_TIMEOUT_SECONDS" -X POST "$REACTIVE_RPC" -H "Content-Type: application/json" --data \
      "{\"jsonrpc\":\"2.0\",\"method\":\"rnk_getTransactionLogs\",\"params\":[\"$RVM_ID\",\"$tx_number\"],\"id\":1}" \
      2>/dev/null || true
  )"
  topic_lc="$(printf "%s" "$TOPIC_MITIGATION_PLANNED" | tr '[:upper:]' '[:lower:]')"
  pool_lc="$(printf "%s" "$POOL_ID" | tr '[:upper:]' '[:lower:]')"
  data_hex="$(
    jq -r \
      --arg topic "$topic_lc" \
      --arg pool "$pool_lc" \
      '
        (.result // [])
        | map(
            select(
              ((.topics[0] // "" | ascii_downcase) == $topic)
              and ((.topics[1] // "" | ascii_downcase) == $pool)
            )
          )
        | .[0].data // ""
      ' <<<"${logs_json:-{}}" 2>/dev/null || true
  )"
  if [[ "${#data_hex}" -lt 66 ]]; then
    printf "%s\n" ""
    return 0
  fi
  printf "0x%s\n" "${data_hex: -64}"
}

find_callback_proxy_tx_by_evidence() {
  local evidence_hash="$1"
  local from_block="$2"
  local latest_block
  local start_block
  local chunk_start
  local chunk_end
  local start_hex
  local end_hex
  local result
  local tx_hash
  local evidence_lc

  if [[ -z "$CALLBACK_PROXY" || -z "$evidence_hash" ]]; then
    printf "%s\n" ""
    return 0
  fi

  evidence_lc="$(printf "%s" "${evidence_hash#0x}" | tr '[:upper:]' '[:lower:]')"
  start_block="$(cast to-dec "$from_block" 2>/dev/null || echo 0)"
  latest_block="$(cast block-number --rpc-url "$RPC_URL" 2>/dev/null || echo 0)"

  for ((chunk_end = latest_block; chunk_end >= start_block; chunk_end -= 10)); do
    chunk_start=$((chunk_end - 9))
    if ((chunk_start < start_block)); then
      chunk_start="$start_block"
    fi
    start_hex="$(printf "0x%x" "$chunk_start")"
    end_hex="$(printf "0x%x" "$chunk_end")"

    result="$(
      curl -sS --max-time "$ORIGIN_RPC_TIMEOUT_SECONDS" -X POST "$RPC_URL" -H "Content-Type: application/json" --data \
        "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getLogs\",\"params\":[{\"fromBlock\":\"$start_hex\",\"toBlock\":\"$end_hex\",\"address\":\"$CALLBACK_PROXY\",\"topics\":[\"$TOPIC_PROXY_CALLBACK_ATTEMPT\",\"$EXECUTOR_TOPIC_1\"]}],\"id\":1}" \
        2>/dev/null || true
    )"
    tx_hash="$(
      jq -r \
        --arg evidence "$evidence_lc" \
        '
          (.result // [])
          | map(select((.data // "" | ascii_downcase | contains($evidence))))
          | .[0].transactionHash // empty
        ' <<<"${result:-{}}" 2>/dev/null || true
    )"
    if is_tx_hash "$tx_hash"; then
      printf "%s\n" "$tx_hash"
      return 0
    fi
  done

  printf "%s\n" ""
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
    curl -sS --max-time "$ORIGIN_RPC_TIMEOUT_SECONDS" -X POST "$RPC_URL" -H "Content-Type: application/json" --data \
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":[{\"to\":\"$hook_addr\",\"from\":\"$OWNER\",\"data\":\"$probe_data\"},\"latest\"]}"
  )"
  err_data="$(jq -r '.error.data // empty' <<<"$result")"
  [[ "$err_data" =~ ^0x180b8555 ]]
}

echo "Hook Safety Live Reactive Demo (Unichain <-> Lasna)"
echo "This run proves event->react->callback path using live Reactive subscriptions."
echo "Strict proof mode: $STRICT_LIVE_REACTIVE"
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

TELEMETRY_TOPIC_0="$(cast keccak "SecurityTelemetry(bytes32,address,uint64,uint64,uint64,int24,uint160,uint128,int128,int128,bool,int256,uint24,uint8)")"
RVM_ID="$(fetch_rvm_id "$REACTIVE_ADDR")"
if [[ -z "$RVM_ID" || "$RVM_ID" == "null" ]]; then
  echo "Unable to resolve RVM ID for reactive contract: $REACTIVE_ADDR"
  exit 1
fi
subscription_ready=0
for ((i = 1; i <= SUBSCRIPTION_READY_ATTEMPTS; i++)); do
  if has_reactive_subscription "$RVM_ID" "${ORIGIN_CHAIN_ID:-1301}" "$HOOK_ADDR" "$TELEMETRY_TOPIC_0"; then
    subscription_ready=1
    break
  fi
  sleep 3
done

if [[ "$subscription_ready" -ne 1 ]]; then
  echo "Reactive subscription preflight could not be confirmed."
  echo "Expected chain: ${ORIGIN_CHAIN_ID:-1301}, hook: $HOOK_ADDR, topic0: $TELEMETRY_TOPIC_0"
  echo "Continuing to strict live proof; final tx checks remain enforced."
fi

echo "  Hook:      $HOOK_ADDR"
echo "  Executor:  $EXECUTOR_ADDR"
echo "  Reactive:  $REACTIVE_ADDR ($REACTIVE_STATUS)"
echo "  RVM ID:    $RVM_ID"
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
    "$RVM_ID"
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
    255
)"
echo "  Attack telemetry tx: $TX_ATTACK_TELEMETRY"
echo "  Unichain: $UNICHAIN_EXPLORER_BASE/tx/$TX_ATTACK_TELEMETRY"

echo
echo "[Phase 4/6] Await Reactive processing on Lasna + callback on Unichain"
TOPIC_MITIGATION_PLANNED="$(cast keccak "MitigationPlanned(bytes32,uint8,uint16,uint64,uint40,uint40,bytes32)")"
TOPIC_MITIGATION_EXECUTED="$(cast keccak "MitigationExecuted(bytes32,uint8,uint16,uint64)")"
TOPIC_PROXY_CALLBACK_ATTEMPT="0xc8313f695443128e273f1edfcec40b94b7deea8dfbeafd0043290d6601d999db"
EXECUTOR_TOPIC_1="0x000000000000000000000000${EXECUTOR_ADDR#0x}"

LASNA_REACT_TX=""
LASNA_REACT_TX_NUMBER=""
LASNA_EVIDENCE_HASH=""
UNICHAIN_CALLBACK_TX=""
UNICHAIN_CALLBACK_KIND=""
TX_ATTACK_RETRY=""

poll_cross_chain_outcome "$TX_ATTACK_TELEMETRY" "$POLL_ATTEMPTS"

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
      255
  )"
  echo "  Retry anomaly tx:    $TX_ATTACK_RETRY"
  echo "  Unichain:            $UNICHAIN_EXPLORER_BASE/tx/$TX_ATTACK_RETRY"
  poll_cross_chain_outcome "$TX_ATTACK_RETRY" "$POLL_ATTEMPTS"
fi

if ! is_tx_hash "$LASNA_REACT_TX" && [[ "$FINAL_BACKFILL_WAIT_SECONDS" -gt 0 ]]; then
  echo "  Waiting ${FINAL_BACKFILL_WAIT_SECONDS}s for late RNK indexing before final backfill..."
  sleep "$FINAL_BACKFILL_WAIT_SECONDS"

  for ref in "$TX_ATTACK_RETRY" "$TX_ATTACK_TELEMETRY"; do
    if ! is_tx_hash "$ref"; then
      continue
    fi
    match="$(find_lasna_react_tx_for_ref_backfill "$ref" "$LASNA_BACKFILL_TX_WINDOW")"
    if [[ -n "$match" ]]; then
      match_hash="$(awk '{print $1}' <<<"$match")"
      match_number="$(awk '{print $2}' <<<"$match")"
      if is_tx_hash "$match_hash" && has_lasna_mitigation_planned "$match_number"; then
        LASNA_REACT_TX="$match_hash"
        LASNA_REACT_TX_NUMBER="$match_number"
        break
      fi
    fi
  done

  if ! is_tx_hash "$LASNA_REACT_TX"; then
    match="$(find_latest_lasna_mitigation_tx "$LASNA_BACKFILL_TX_WINDOW")"
    if [[ -n "$match" ]]; then
      match_hash="$(awk '{print $1}' <<<"$match")"
      match_number="$(awk '{print $2}' <<<"$match")"
      if is_tx_hash "$match_hash"; then
        LASNA_REACT_TX="$match_hash"
        LASNA_REACT_TX_NUMBER="$match_number"
        echo "  Using latest indexed Lasna mitigation fallback: $LASNA_REACT_TX"
      fi
    fi
  fi

  if ! is_tx_hash "$UNICHAIN_CALLBACK_TX" && is_tx_hash "$LASNA_REACT_TX" && [[ -n "$CALLBACK_PROXY" && -n "$LASNA_REACT_TX_NUMBER" ]]; then
    LASNA_EVIDENCE_HASH="$(extract_lasna_evidence_hash "$LASNA_REACT_TX_NUMBER")"
    UNICHAIN_CALLBACK_TX="$(find_callback_proxy_tx_by_evidence "$LASNA_EVIDENCE_HASH" "$START_UNI_HEX")"
    if is_tx_hash "$UNICHAIN_CALLBACK_TX"; then
      UNICHAIN_CALLBACK_KIND="proxy"
    fi
  fi
fi

if is_tx_hash "$LASNA_REACT_TX"; then
  echo "  Lasna react tx:    $LASNA_REACT_TX"
  echo "  Lasna URL:         $LASNA_EXPLORER_BASE/tx/$LASNA_REACT_TX"
else
  echo "  Lasna react tx:    N/A (not observed in polling window)"
fi

if is_tx_hash "$UNICHAIN_CALLBACK_TX"; then
  if [[ "$UNICHAIN_CALLBACK_KIND" == "proxy" ]]; then
    echo "  Callback tx:       $UNICHAIN_CALLBACK_TX (proxy callback attempt)"
  else
    echo "  Callback tx:       $UNICHAIN_CALLBACK_TX (executor mitigation event)"
  fi
  echo "  Unichain callback: $UNICHAIN_EXPLORER_BASE/tx/$UNICHAIN_CALLBACK_TX"
else
  echo "  Callback tx:       N/A (not observed in polling window)"
fi

CROSS_CHAIN_PROOF_OK=true
if ! is_tx_hash "$LASNA_REACT_TX" || ! is_tx_hash "$UNICHAIN_CALLBACK_TX"; then
  CROSS_CHAIN_PROOF_OK=false
  echo
  echo "  Diagnostics:"
  if has_reactive_subscription "$RVM_ID" "${ORIGIN_CHAIN_ID:-1301}" "$HOOK_ADDR" "$TELEMETRY_TOPIC_0"; then
    echo "    Subscription check: OK"
  else
    echo "    Subscription check: FAIL"
  fi
  ORIGIN_TELEMETRY_TX="$(find_event_tx "$RPC_URL" "$HOOK_ADDR" "$TELEMETRY_TOPIC_0" "$POOL_ID" "$START_UNI_HEX")"
  if is_tx_hash "$ORIGIN_TELEMETRY_TX"; then
    echo "    Origin telemetry tx: $ORIGIN_TELEMETRY_TX"
    echo "    Origin telemetry URL: $UNICHAIN_EXPLORER_BASE/tx/$ORIGIN_TELEMETRY_TX"
  else
    echo "    Origin telemetry tx: N/A"
  fi
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
  --arg txCallbackKind "$UNICHAIN_CALLBACK_KIND" \
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
      unichainCallbackTx: ($txCallback | if test("^0x[0-9a-fA-F]{64}$") then . else null end),
      unichainCallbackKind: ($txCallbackKind | if . == "" then null else . end)
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

if [[ "$STRICT_LIVE_REACTIVE" == "true" && "$CROSS_CHAIN_PROOF_OK" != "true" ]]; then
  echo "Live reactive demo failed strict proof mode: missing Lasna and/or callback tx."
  exit 1
fi

echo "Live reactive demo complete."
