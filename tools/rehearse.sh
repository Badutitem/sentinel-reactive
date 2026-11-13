#!/usr/bin/env bash
# Live testnet rehearsal driver for Sentinel.
# Pushes a calm -> grind-down -> crash price series into MockPriceOracle on
# Base Sepolia and records, per stage, the origin tx hashes. Reactive txs on
# Lasna and callback txs on Base Sepolia are collected separately by polling
# the Decision / ProtectionExecuted event logs (see README deployment table).
#
# Required env: ORACLE, TOKEN (defaults to 0x...dEaD), plus PRIVATE_KEY via
# .env.local. Optional: PUSH_DELAY (seconds between pushes, default 6).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env.local; set +a
BASE_RPC="https://sepolia.base.org"
TOKEN="${TOKEN:-0x000000000000000000000000000000000000dEaD}"
DELAY="${PUSH_DELAY:-6}"

push() {
  local price="$1"
  local hash
  hash=$(cast send "$ORACLE" "setPrice(address,uint256)" "$TOKEN" "$price" \
    --rpc-url "$BASE_RPC" --private-key "$PRIVATE_KEY" --json | python3 -c "import sys,json;print(json.load(sys.stdin)['transactionHash'])")
  echo "  setPrice $price -> $hash"
  sleep "$DELAY"
}

echo "== Stage A: calm (expect HOLD, no callbacks) =="
for p in 10000000000 10050000000 9980000000 10020000000 10010000000 9990000000 10030000000 10000000000 10020000000; do push $p; done

echo "== Stage B: grind-down (expect TRIM callback, position 1000 -> 500) =="
for p in 9900000000 9750000000 9600000000 9460000000 9320000000 9180000000 9040000000 8910000000 8770000000; do push $p; done

echo "== Re-arm position to 1000 on the vault =="
# (In the recorded 2026-11-13 run a few minutes passed here while the TRIM
# callback was collected; the crash-stage EXIT fires via the escalation
# bypass even inside the 300 s cooldown, so no fixed wait is required.)
cast send "$VAULT" "openPosition(uint256)" 1000 --rpc-url "$BASE_RPC" --private-key "$PRIVATE_KEY" | grep -E "transactionHash|status"

echo "== Stage C: window flush at ~100, then crash (expect EXIT callback, position -> 0) =="
for p in 10000000000 10040000000 9970000000 10010000000 10020000000 9995000000 10030000000 10000000000 10010000000; do push $p; done
for p in 9200000000 8100000000 7600000000; do push $p; done
echo "== Rehearsal pushes complete =="
