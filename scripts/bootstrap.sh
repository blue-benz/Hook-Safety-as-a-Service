#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

UNISWAP_V4_PERIPHERY_COMMIT="3779387e5d296f39df543d23524b050f89a62917"
UNISWAP_V4_CORE_COMMIT="59d3ecf53afa9264a16bba0e38f4c5d2231f80bc"

CHECK_ONLY="${1:-}"

ensure_repo() {
  local path="$1"
  if ! git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "missing git repository at $path"
    exit 1
  fi
}

pin_commit() {
  local path="$1"
  local commit="$2"
  git -C "$path" fetch --all --tags --quiet
  git -C "$path" checkout --quiet "$commit"
}

verify_commit() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(git -C "$path" rev-parse HEAD)"
  if [[ "$actual" != "$expected" ]]; then
    echo "dependency mismatch at $path"
    echo "expected: $expected"
    echo "actual:   $actual"
    exit 1
  fi
}

if [[ "$CHECK_ONLY" != "--check-only" ]]; then
  git submodule update --init --recursive
fi

ensure_repo "lib/uniswap-hooks/lib/v4-periphery"
ensure_repo "lib/uniswap-hooks/lib/v4-core"
ensure_repo "lib/uniswap-hooks/lib/v4-periphery/lib/v4-core"

if [[ "$CHECK_ONLY" != "--check-only" ]]; then
  pin_commit "lib/uniswap-hooks/lib/v4-periphery" "$UNISWAP_V4_PERIPHERY_COMMIT"
  pin_commit "lib/uniswap-hooks/lib/v4-core" "$UNISWAP_V4_CORE_COMMIT"
  pin_commit "lib/uniswap-hooks/lib/v4-periphery/lib/v4-core" "$UNISWAP_V4_CORE_COMMIT"
fi

verify_commit "lib/uniswap-hooks/lib/v4-periphery" "$UNISWAP_V4_PERIPHERY_COMMIT"
verify_commit "lib/uniswap-hooks/lib/v4-core" "$UNISWAP_V4_CORE_COMMIT"
verify_commit "lib/uniswap-hooks/lib/v4-periphery/lib/v4-core" "$UNISWAP_V4_CORE_COMMIT"

cat > .deps.lock <<LOCK
UNISWAP_V4_PERIPHERY_COMMIT=$UNISWAP_V4_PERIPHERY_COMMIT
UNISWAP_V4_CORE_COMMIT=$UNISWAP_V4_CORE_COMMIT
LOCK

echo "Dependency bootstrap complete."
echo "Pinned v4-periphery: $(git -C lib/uniswap-hooks/lib/v4-periphery rev-parse --short HEAD)"
echo "Pinned v4-core:      $(git -C lib/uniswap-hooks/lib/v4-core rev-parse --short HEAD)"
