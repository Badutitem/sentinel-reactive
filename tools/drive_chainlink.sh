#!/usr/bin/env bash
# Demo B live-window driver for Sentinel (phase 2, upgrade B).
# Polls the Chainlink feed's latestRoundData() off-chain; when the round
# changes (or a periodic poke is due), calls ChainlinkPriceAdapter.sync()
# from the dev wallet. The adapter re-checks deadband / min-interval /
# heartbeat on-chain, so extra syncs are silent no-ops — this driver is
# deliberately dumb. Every sync tx hash is logged with a UTC timestamp.
#
# Required env: ADAPTER, FEED. PRIVATE_KEY via .env.local.
# Optional env: DURATION (seconds, default 5400), POLL (default 15),
#               POKE_EVERY (seconds between unconditional sync pokes,
#               default 240 — keeps the adapter's 300 s heartbeat honest
#               even when the feed's round is quiet).
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."
set -a; source .env.local; set +a
BASE_RPC="https://sepolia.base.org"
DURATION="${DURATION:-5400}"
POLL="${POLL:-15}"
POKE_EVERY="${POKE_EVERY:-240}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

round_id() {
  cast call "$FEED" "latestRoundData()(uint80,int256,uint256,uint256,uint80)" \
    --rpc-url "$BASE_RPC" 2>/dev/null | head -1 | awk '{print $1}'
}

adapter_state() {
  # echoes "<lastPrice> <lastEmittedAt>"
  local p e
  p=$(cast call "$ADAPTER" "lastPrice()(uint256)" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}')
  e=$(cast call "$ADAPTER" "lastEmittedAt()(uint256)" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}')
  echo "$p $e"
}

do_sync() {
  local why="$1" before after hash
  before=$(adapter_state)
  hash=$(cast send "$ADAPTER" "sync()" --rpc-url "$BASE_RPC" --private-key "$PRIVATE_KEY" --json 2>/dev/null \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['transactionHash'])" 2>/dev/null || echo "SEND_FAILED")
  after=$(adapter_state)
  if [ "$before" != "$after" ]; then
    echo "$(ts) SYNC($why) tx=$hash EMITTED lastPrice=$after"
  else
    echo "$(ts) SYNC($why) tx=$hash no-op"
  fi
}

echo "$(ts) driver start adapter=$ADAPTER feed=$FEED duration=${DURATION}s"
LAST_ROUND="$(round_id)"
echo "$(ts) initial roundId=$LAST_ROUND"
LAST_POKE=$(date +%s)
START=$(date +%s)

while [ $(( $(date +%s) - START )) -lt "$DURATION" ]; do
  R="$(round_id)"
  NOW=$(date +%s)
  if [ -n "$R" ] && [ "$R" != "$LAST_ROUND" ]; then
    echo "$(ts) round changed $LAST_ROUND -> $R"
    LAST_ROUND="$R"
    do_sync "round"
    LAST_POKE=$NOW
  elif [ $(( NOW - LAST_POKE )) -ge "$POKE_EVERY" ]; then
    do_sync "poke"
    LAST_POKE=$NOW
  fi
  sleep "$POLL"
done
echo "$(ts) driver end"
