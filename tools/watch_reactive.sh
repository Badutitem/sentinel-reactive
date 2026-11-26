#!/usr/bin/env bash
# Release 2 Lasna event watcher: tails a SentinelReactive contract's
# PriceSeen / Decision / CallbackRequested events via RPC log polling and
# prints each new event with its transaction hash and a UTC timestamp.
#
# Required env: REACTIVE. Optional: FROM_BLOCK (default: current head),
# POLL (default 20), DURATION (default 5400).
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
LASNA_RPC="https://lasna-rpc.rnk.dev"
POLL="${POLL:-20}"
DURATION="${DURATION:-5400}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

SIG_PRICESEEN="PriceSeen(uint256,uint256,uint256)"
SIG_DECISION="Decision(uint256,uint256,uint8,int256,int256,int256)"
SIG_CALLBACK="CallbackRequested(uint8,uint256)"

FROM="${FROM_BLOCK:-$(cast block-number --rpc-url "$LASNA_RPC")}"
echo "$(ts) watcher start reactive=$REACTIVE fromBlock=$FROM duration=${DURATION}s"
START=$(date +%s)

while [ $(( $(date +%s) - START )) -lt "$DURATION" ]; do
  HEAD=$(cast block-number --rpc-url "$LASNA_RPC" 2>/dev/null || echo "$FROM")
  if [ -n "$HEAD" ] && [ "$HEAD" -ge "$FROM" ]; then
    for SIG in "$SIG_PRICESEEN" "$SIG_DECISION" "$SIG_CALLBACK"; do
      OUT=$(cast logs --rpc-url "$LASNA_RPC" --address "$REACTIVE" \
        --from-block "$FROM" --to-block "$HEAD" "$SIG" 2>/dev/null)
      if [ -n "$OUT" ]; then
        echo "$(ts) === $SIG (blocks $FROM..$HEAD) ==="
        echo "$OUT" | grep -E "blockNumber|transactionHash|data:|topics:" | head -40
      fi
    done
    FROM=$(( HEAD + 1 ))
  fi
  sleep "$POLL"
done
echo "$(ts) watcher end"
