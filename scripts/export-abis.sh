#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

forge build

mkdir -p shared/abi frontend/src/abi

cp out/HookSafetyFirewallHook.sol/HookSafetyFirewallHook.json shared/abi/HookSafetyFirewallHook.json
cp out/HookSafetyReactive.sol/HookSafetyReactive.json shared/abi/HookSafetyReactive.json
cp out/HookSafetyExecutor.sol/HookSafetyExecutor.json shared/abi/HookSafetyExecutor.json

cp shared/abi/HookSafetyFirewallHook.json frontend/src/abi/HookSafetyFirewallHook.json
cp shared/abi/HookSafetyReactive.json frontend/src/abi/HookSafetyReactive.json
cp shared/abi/HookSafetyExecutor.json frontend/src/abi/HookSafetyExecutor.json

echo "ABIs exported to shared/abi and frontend/src/abi"
