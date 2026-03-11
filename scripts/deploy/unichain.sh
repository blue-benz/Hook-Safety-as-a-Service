#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"
DEPLOY_FILE="$ROOT_DIR/deployments/sepolia.json"
REACTIVE_PRIVATE_KEY_OVERRIDE="${REACTIVE_PRIVATE_KEY_OVERRIDE:-}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1"
    exit 1
  fi
}

require_cmd cast
require_cmd forge
require_cmd jq

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

if [[ -n "$REACTIVE_PRIVATE_KEY_OVERRIDE" ]]; then
  REACTIVE_PRIVATE_KEY="$REACTIVE_PRIVATE_KEY_OVERRIDE"
fi

RPC_URL="${UNICHAIN_SEPOLIA_RPC_URL:-${SEPOLIA_RPC_URL:-}}"
PRIVATE_KEY="${SEPOLIA_PRIVATE_KEY:-${PRIVATE_KEY:-}}"
OWNER="${OWNER_ADDRESS:-${OWNER:-}}"
POOL_MANAGER="${POOL_MANAGER:-${POOL_MANAGER_ADDRESS:-}}"

REACTIVE_RPC="${REACTIVE_RPC_URL:-}"
REACTIVE_KEY="${REACTIVE_PRIVATE_KEY:-}"
SERVICE_CONTRACT="${SERVICE_CONTRACT:-0x0000000000000000000000000000000000fffFfF}"

ORIGIN_CHAIN_ID="${ORIGIN_CHAIN_ID:-1301}"
DESTINATION_CHAIN_ID="${DESTINATION_CHAIN_ID:-1301}"
CALLBACK_PROXY="${CALLBACK_PROXY:-${DESTINATION_CALLBACK_PROXY_ADDR:-}}"
MEDIUM_THRESHOLD="${MEDIUM_THRESHOLD:-55}"
HIGH_THRESHOLD="${HIGH_THRESHOLD:-80}"

UNICHAIN_EXPLORER_BASE="${UNICHAIN_EXPLORER_BASE:-https://sepolia.uniscan.xyz}"
LASNA_EXPLORER_BASE="${LASNA_EXPLORER_BASE:-https://lasna.reactscan.net}"
FORCE_REDEPLOY="${FORCE_REDEPLOY:-false}"
FORCE_REACTIVE_REDEPLOY="${FORCE_REACTIVE_REDEPLOY:-false}"
VERIFY_REACTIVE_SUBSCRIPTION="${VERIFY_REACTIVE_SUBSCRIPTION:-false}"

DEMO_CURRENCY0="${DEMO_CURRENCY0:-0x1111111111111111111111111111111111111111}"
DEMO_CURRENCY1="${DEMO_CURRENCY1:-0x2222222222222222222222222222222222222222}"
DEMO_TICK_SPACING="${DEMO_TICK_SPACING:-60}"
DYNAMIC_FEE_FLAG="${DYNAMIC_FEE_FLAG:-8388608}"
TX_TIMEOUT_SECONDS="${TX_TIMEOUT_SECONDS:-300}"
REACTIVE_TARGET_BALANCE_WEI="${REACTIVE_TARGET_BALANCE_WEI:-100000000000000000}"
EXPECTED_TELEMETRY_TOPIC_0="0x6c9834cf0ad702ad4cc765c956cdead93b1a6ce4b8606ad58afe8e27cc343270"

if [[ -z "$RPC_URL" || -z "$PRIVATE_KEY" || -z "$OWNER" || -z "$POOL_MANAGER" ]]; then
  echo "Missing required environment values. Required: RPC_URL, PRIVATE_KEY, OWNER, POOL_MANAGER."
  exit 1
fi

mkdir -p "$ROOT_DIR/deployments"

code_exists() {
  local address="$1"
  local rpc="$2"
  local code
  code="$(cast code "$address" --rpc-url "$rpc" 2>/dev/null || true)"
  [[ -n "$code" && "$code" != "0x" ]]
}

is_tx_hash() {
  local maybe_hash="$1"
  [[ "$maybe_hash" =~ ^0x[0-9a-fA-F]{64}$ ]]
}

default_callback_proxy_for_chain() {
  local chain_id="$1"
  case "$chain_id" in
    1301|130|999|59144|9745|146|2741)
      printf "%s\n" "0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4"
      ;;
    84532)
      printf "%s\n" "0xa6eA49Ed671B8a4dfCDd34E36b7a75Ac79B8A5a6"
      ;;
    11155111)
      printf "%s\n" "0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA"
      ;;
    5318007|1597)
      printf "%s\n" "0x0000000000000000000000000000000000fffFfF"
      ;;
    *)
      printf "%s\n" ""
      ;;
  esac
}

to_lower() {
  printf "%s" "$1" | tr '[:upper:]' '[:lower:]'
}

reactive_subscription_exists() {
  local reactive_addr="$1"
  local chain_id="$2"
  local origin_contract="$3"
  local topic_0="$4"
  local origin_contract_lc
  local topic_0_lc
  local mapping_json
  local rvm_id
  local subscribers_json

  if [[ -z "$REACTIVE_RPC" ]]; then
    return 1
  fi

  mapping_json="$(
    curl -sS --max-time 10 -X POST "$REACTIVE_RPC" -H "Content-Type: application/json" --data \
      "{\"jsonrpc\":\"2.0\",\"method\":\"rnk_getRnkAddressMapping\",\"params\":[\"$reactive_addr\"],\"id\":1}" \
      2>/dev/null || true
  )"
  rvm_id="$(jq -r '.result.rvmId // empty' <<<"${mapping_json:-{}}" 2>/dev/null || true)"
  if [[ -z "$rvm_id" || "$rvm_id" == "null" ]]; then
    return 1
  fi

  subscribers_json="$(
    curl -sS --max-time 10 -X POST "$REACTIVE_RPC" -H "Content-Type: application/json" --data \
      "{\"jsonrpc\":\"2.0\",\"method\":\"rnk_getSubscribers\",\"params\":[\"$rvm_id\"],\"id\":1}" \
      2>/dev/null || true
  )"
  origin_contract_lc="$(to_lower "$origin_contract")"
  topic_0_lc="$(to_lower "$topic_0")"

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
    ' <<<"${subscribers_json:-{}}" >/dev/null 2>&1
}

current_nonce_for() {
  local rpc="$1"
  local key="$2"
  local signer

  signer="$(cast wallet address --private-key "${key#0x}")"
  cast nonce "$signer" --rpc-url "$rpc"
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

deploy_from_artifact() {
  local artifact="$1"
  local constructor_sig="$2"
  local rpc="$3"
  local key="$4"
  shift 4

  local bytecode
  local args
  local data
  local output
  local tx_hash
  local contract_address
  local nonce

  bytecode="$(jq -r '.bytecode.object' "$artifact")"
  args="$(cast abi-encode "$constructor_sig" "$@")"
  data="${bytecode}${args:2}"
  nonce="$(current_nonce_for "$rpc" "$key")"

  output="$(cast send --rpc-url "$rpc" --private-key "$key" --nonce "$nonce" --timeout "$TX_TIMEOUT_SECONDS" --create "$data")"
  tx_hash="$(awk '/^transactionHash[[:space:]]/{print $2; exit}' <<<"$output")"
  contract_address="$(awk '/^contractAddress[[:space:]]/{print $2; exit}' <<<"$output")"

  if [[ -z "$tx_hash" || -z "$contract_address" ]]; then
    echo "Failed to parse deployment output:"
    echo "$output"
    exit 1
  fi

  printf "%s|%s\n" "$contract_address" "$tx_hash"
}

if [[ -z "$CALLBACK_PROXY" ]]; then
  CALLBACK_PROXY="$(default_callback_proxy_for_chain "$DESTINATION_CHAIN_ID")"
fi
if [[ -z "$CALLBACK_PROXY" ]]; then
  echo "Missing callback proxy for destination chain $DESTINATION_CHAIN_ID."
  echo "Set CALLBACK_PROXY in .env (or DESTINATION_CALLBACK_PROXY_ADDR) and re-run."
  exit 1
fi

hook_addr="${HOOK_ADDRESS:-}"
hook_tx="${HOOK_DEPLOY_TX:-}"
if [[ "$FORCE_REDEPLOY" == "true" || "$FORCE_REDEPLOY" == "1" ]]; then
  hook_addr=""
  hook_tx=""
fi
if [[ -n "$hook_tx" ]] && ! is_tx_hash "$hook_tx"; then
  hook_tx=""
fi

if [[ -n "$hook_addr" ]] && code_exists "$hook_addr" "$RPC_URL"; then
  echo "Using existing hook: $hook_addr"
else
  echo "Deploying HookSafetyFirewallHook..."
  export POOL_MANAGER OWNER
  forge script scripts/foundry/00_DeployHookFirewall.s.sol:DeployHookFirewallScript \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast >/tmp/hook-deploy.log 2>&1

  hook_addr="$(jq -r '.returns.hook.value' "$ROOT_DIR/broadcast/00_DeployHookFirewall.s.sol/1301/run-latest.json")"
  hook_tx="$(jq -r '.transactions[0].hash' "$ROOT_DIR/broadcast/00_DeployHookFirewall.s.sol/1301/run-latest.json")"

  if [[ -z "$hook_addr" || "$hook_addr" == "null" || -z "$hook_tx" || "$hook_tx" == "null" ]]; then
    echo "Hook deployment output could not be parsed."
    cat /tmp/hook-deploy.log
    exit 1
  fi
fi

prod_executor_addr="${EXECUTOR_ADDRESS:-}"
prod_executor_tx="${EXECUTOR_DEPLOY_TX:-}"
if [[ "$FORCE_REDEPLOY" == "true" || "$FORCE_REDEPLOY" == "1" ]]; then
  prod_executor_addr=""
  prod_executor_tx=""
fi
if [[ -n "$prod_executor_tx" ]] && ! is_tx_hash "$prod_executor_tx"; then
  prod_executor_tx=""
fi

if [[ -n "$prod_executor_addr" ]] && code_exists "$prod_executor_addr" "$RPC_URL"; then
  echo "Using existing executor: $prod_executor_addr"
else
  echo "Deploying HookSafetyExecutor (callback proxy authenticated)..."
  IFS='|' read -r prod_executor_addr prod_executor_tx < <(
    deploy_from_artifact \
      "$ROOT_DIR/out/HookSafetyExecutor.sol/HookSafetyExecutor.json" \
      "constructor(address,address,address)" \
      "$RPC_URL" \
      "$PRIVATE_KEY" \
      "$CALLBACK_PROXY" \
      "$hook_addr" \
      "$OWNER"
  )
fi

demo_executor_addr="${DEMO_EXECUTOR_ADDRESS:-}"
demo_executor_tx="${DEMO_EXECUTOR_DEPLOY_TX:-}"
if [[ "$FORCE_REDEPLOY" == "true" || "$FORCE_REDEPLOY" == "1" ]]; then
  demo_executor_addr=""
  demo_executor_tx=""
fi
if [[ -n "$demo_executor_tx" ]] && ! is_tx_hash "$demo_executor_tx"; then
  demo_executor_tx=""
fi

if [[ -n "$demo_executor_addr" ]] && code_exists "$demo_executor_addr" "$RPC_URL"; then
  echo "Using existing demo executor: $demo_executor_addr"
else
  echo "Deploying HookSafetyExecutor (demo callback sender = owner)..."
  IFS='|' read -r demo_executor_addr demo_executor_tx < <(
    deploy_from_artifact \
      "$ROOT_DIR/out/HookSafetyExecutor.sol/HookSafetyExecutor.json" \
      "constructor(address,address,address)" \
      "$RPC_URL" \
      "$PRIVATE_KEY" \
      "$OWNER" \
      "$hook_addr" \
      "$OWNER"
  )
fi

prev_reactive_addr=""
prev_reactive_tx=""
prev_reactive_fund_tx=""
if [[ -f "$DEPLOY_FILE" ]]; then
  prev_reactive_addr="$(jq -r '.reactiveLasna.reactive // empty' "$DEPLOY_FILE" 2>/dev/null || true)"
  prev_reactive_tx="$(jq -r '.reactiveLasna.tx.deployReactive // empty' "$DEPLOY_FILE" 2>/dev/null || true)"
  prev_reactive_fund_tx="$(jq -r '.reactiveLasna.tx.fundReactive // empty' "$DEPLOY_FILE" 2>/dev/null || true)"
  if [[ "$prev_reactive_addr" == "null" ]]; then
    prev_reactive_addr=""
  fi
  if [[ "$prev_reactive_tx" == "null" ]]; then
    prev_reactive_tx=""
  fi
  if [[ "$prev_reactive_fund_tx" == "null" ]]; then
    prev_reactive_fund_tx=""
  fi
fi

reactive_addr="${REACTIVE_ADDRESS:-$prev_reactive_addr}"
reactive_tx="${REACTIVE_DEPLOY_TX:-$prev_reactive_tx}"
reactive_fund_tx="${REACTIVE_FUND_TX:-$prev_reactive_fund_tx}"
if [[ "$FORCE_REDEPLOY" == "true" || "$FORCE_REDEPLOY" == "1" ]]; then
  reactive_addr=""
  reactive_tx=""
  reactive_fund_tx=""
fi
if [[ "$FORCE_REACTIVE_REDEPLOY" == "true" || "$FORCE_REACTIVE_REDEPLOY" == "1" ]]; then
  reactive_addr=""
  reactive_tx=""
  reactive_fund_tx=""
fi
reactive_status="not_attempted"
if [[ -n "$reactive_tx" ]] && ! is_tx_hash "$reactive_tx"; then
  reactive_tx=""
fi
if [[ -n "$reactive_fund_tx" ]] && ! is_tx_hash "$reactive_fund_tx"; then
  reactive_fund_tx=""
fi

if [[ -n "$reactive_addr" && -n "$REACTIVE_RPC" ]] && code_exists "$reactive_addr" "$REACTIVE_RPC"; then
  if [[ "$VERIFY_REACTIVE_SUBSCRIPTION" == "true" ]]; then
    if reactive_subscription_exists "$reactive_addr" "$ORIGIN_CHAIN_ID" "$hook_addr" "$EXPECTED_TELEMETRY_TOPIC_0"; then
      reactive_status="existing"
    else
      echo "Existing reactive contract subscription mismatch; redeploying with current telemetry topic."
      reactive_status="redeploy_subscription_mismatch"
      reactive_addr=""
      reactive_tx=""
    fi
  else
    reactive_status="existing"
  fi
else
  reactive_addr=""
  reactive_tx=""
fi

if [[ -z "$reactive_addr" ]]; then
  if [[ -n "$REACTIVE_RPC" && -n "$REACTIVE_KEY" ]]; then
    reactive_status="skipped_insufficient_funds"
    reactive_balance="$(cast balance "$OWNER" --rpc-url "$REACTIVE_RPC" 2>/dev/null || echo 0)"
    # Avoid bash signed-int overflow for large uint256 balances.
    if [[ "$reactive_balance" =~ ^[0-9]+$ ]] && [[ "$reactive_balance" != "0" ]]; then
      echo "Deploying HookSafetyReactive on Lasna..."
      IFS='|' read -r reactive_addr reactive_tx < <(
        deploy_from_artifact \
          "$ROOT_DIR/out/HookSafetyReactive.sol/HookSafetyReactive.json" \
          "constructor(address,uint256,address,uint256,address,uint16,uint16)" \
          "$REACTIVE_RPC" \
          "$REACTIVE_KEY" \
          "$SERVICE_CONTRACT" \
          "$ORIGIN_CHAIN_ID" \
          "$hook_addr" \
          "$DESTINATION_CHAIN_ID" \
          "$prod_executor_addr" \
          "$MEDIUM_THRESHOLD" \
          "$HIGH_THRESHOLD"
      )
      reactive_status="deployed"
    fi
  else
    reactive_status="skipped_missing_config"
  fi
fi

if [[ -n "$reactive_addr" && -n "$REACTIVE_RPC" && -n "$REACTIVE_KEY" ]]; then
  reactive_contract_balance="$(cast balance "$reactive_addr" --rpc-url "$REACTIVE_RPC" 2>/dev/null || echo 0)"
  if [[ "$reactive_contract_balance" =~ ^[0-9]+$ ]] && [[ "$REACTIVE_TARGET_BALANCE_WEI" =~ ^[0-9]+$ ]]; then
    if (( reactive_contract_balance < REACTIVE_TARGET_BALANCE_WEI )); then
      reactive_top_up_wei=$((REACTIVE_TARGET_BALANCE_WEI - reactive_contract_balance))
      reactive_fund_nonce="$(current_nonce_for "$REACTIVE_RPC" "$REACTIVE_KEY")"
      reactive_fund_output="$(
        cast send \
          --rpc-url "$REACTIVE_RPC" \
          --private-key "$REACTIVE_KEY" \
          --nonce "$reactive_fund_nonce" \
          --timeout "$TX_TIMEOUT_SECONDS" \
          --value "$reactive_top_up_wei" \
          "$reactive_addr"
      )"
      reactive_fund_tx="$(awk '/^transactionHash[[:space:]]/{print $2; exit}' <<<"$reactive_fund_output")"
      if [[ -z "$reactive_fund_tx" ]]; then
        echo "Failed to parse reactive funding tx hash."
        echo "$reactive_fund_output"
        exit 1
      fi
    fi
  fi
fi

pool_key_encoded="$(
  cast abi-encode \
    "f(address,address,uint24,int24,address)" \
    "$DEMO_CURRENCY0" \
    "$DEMO_CURRENCY1" \
    "$DYNAMIC_FEE_FLAG" \
    "$DEMO_TICK_SPACING" \
    "$hook_addr"
)"
pool_id="$(cast keccak "$pool_key_encoded")"

reactive_addr_json="null"
reactive_tx_json="null"
reactive_fund_tx_json="null"
if [[ -n "$reactive_addr" ]]; then
  reactive_addr_json="\"$reactive_addr\""
fi
if [[ -n "$reactive_tx" ]]; then
  reactive_tx_json="\"$reactive_tx\""
fi
if [[ -n "$reactive_fund_tx" ]]; then
  reactive_fund_tx_json="\"$reactive_fund_tx\""
fi

cat >"$DEPLOY_FILE" <<JSON
{
  "network": "unichain-sepolia",
  "chainId": $DESTINATION_CHAIN_ID,
  "explorers": {
    "unichainSepolia": "$UNICHAIN_EXPLORER_BASE",
    "lasna": "$LASNA_EXPLORER_BASE"
  },
  "unichainSepolia": {
    "hook": "$hook_addr",
    "executor": "$prod_executor_addr",
    "demoExecutor": "$demo_executor_addr",
    "poolId": "$pool_id",
    "poolKey": {
      "currency0": "$DEMO_CURRENCY0",
      "currency1": "$DEMO_CURRENCY1",
      "fee": $DYNAMIC_FEE_FLAG,
      "tickSpacing": $DEMO_TICK_SPACING,
      "hooks": "$hook_addr"
    },
    "tx": {
      "deployHook": "$hook_tx",
      "deployExecutor": "$prod_executor_tx",
      "deployDemoExecutor": "$demo_executor_tx"
    }
  },
  "reactiveLasna": {
    "reactive": $reactive_addr_json,
    "status": "$reactive_status",
    "tx": {
      "deployReactive": $reactive_tx_json,
      "fundReactive": $reactive_fund_tx_json
    }
  }
}
JSON

upsert_env "HOOK_ADDRESS" "$hook_addr"
upsert_env "EXECUTOR_ADDRESS" "$prod_executor_addr"
upsert_env "DEMO_EXECUTOR_ADDRESS" "$demo_executor_addr"
upsert_env "DEMO_POOL_ID" "$pool_id"
upsert_env "DEMO_CURRENCY0" "$DEMO_CURRENCY0"
upsert_env "DEMO_CURRENCY1" "$DEMO_CURRENCY1"
upsert_env "DEMO_TICK_SPACING" "$DEMO_TICK_SPACING"
upsert_env "DYNAMIC_FEE_FLAG" "$DYNAMIC_FEE_FLAG"
upsert_env "HOOK_DEPLOY_TX" "$hook_tx"
upsert_env "EXECUTOR_DEPLOY_TX" "$prod_executor_tx"
upsert_env "DEMO_EXECUTOR_DEPLOY_TX" "$demo_executor_tx"
if [[ -n "$reactive_addr" ]]; then
  upsert_env "REACTIVE_ADDRESS" "$reactive_addr"
fi
if [[ -n "$reactive_tx" ]]; then
  upsert_env "REACTIVE_DEPLOY_TX" "$reactive_tx"
fi
if [[ -n "$reactive_fund_tx" ]]; then
  upsert_env "REACTIVE_FUND_TX" "$reactive_fund_tx"
fi
upsert_env "UNICHAIN_EXPLORER_BASE" "$UNICHAIN_EXPLORER_BASE"
upsert_env "LASNA_EXPLORER_BASE" "$LASNA_EXPLORER_BASE"

echo
echo "Deployment summary"
echo "  Hook:            $hook_addr"
echo "  Executor:        $prod_executor_addr"
echo "  Demo Executor:   $demo_executor_addr"
echo "  Reactive (Lasna): ${reactive_addr:-N/A} ($reactive_status)"
echo "  PoolId:          $pool_id"
echo
echo "Explorer links"
if is_tx_hash "$hook_tx"; then
  echo "  Hook tx:         $UNICHAIN_EXPLORER_BASE/tx/$hook_tx"
else
  echo "  Hook tx:         N/A"
fi
if is_tx_hash "$prod_executor_tx"; then
  echo "  Executor tx:     $UNICHAIN_EXPLORER_BASE/tx/$prod_executor_tx"
else
  echo "  Executor tx:     N/A"
fi
if is_tx_hash "$demo_executor_tx"; then
  echo "  Demo Executor tx:$UNICHAIN_EXPLORER_BASE/tx/$demo_executor_tx"
else
  echo "  Demo Executor tx:N/A"
fi
if [[ -n "$reactive_tx" ]]; then
  echo "  Reactive tx:     $LASNA_EXPLORER_BASE/tx/$reactive_tx"
fi
if [[ -n "$reactive_fund_tx" ]]; then
  echo "  Reactive fund tx:$LASNA_EXPLORER_BASE/tx/$reactive_fund_tx"
fi
