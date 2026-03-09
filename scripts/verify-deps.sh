#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

./scripts/bootstrap.sh

if [[ ! -f package-lock.json ]]; then
  echo "package-lock.json is missing"
  exit 1
fi

if [[ ! -f foundry.lock ]]; then
  echo "foundry.lock is missing"
  exit 1
fi

echo "Dependency integrity checks passed."
