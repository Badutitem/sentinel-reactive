#!/usr/bin/env bash
# RELEASE 6 BLEED LEG (AH-2) — runs AFTER the June-core drive + final
# redemption, on the SAME V6 brain (updates 56, EXIT latched from June).
# 40 fresh pushes, -1% per update from the June close ($1,283.46),
# pacing >= 42 s between push starts (origin spacing is wall-clock;
# the forge H12 test pins the hourly-spacing case at 3 callbacks on a
# FRESH brain — the latch makes the count spacing-independent).
# The June EXIT@56 set exitLatched; the bleed's repeat EXIT votes must
# be suppressed. CORRECTION (2026-11-27, live result): the design's
# "exactly 3 callbacks" assumed the fresh-brain H12 vote shape. On the
# post-June brain the June episode anchor (~$1,594) carries over, so
# the bleed votes EXIT from push 1 and the latch suppresses ALL 40:
# expected EXACTLY 0 callbacks for the bleed leg, updates 56 -> 96,
# lastAction EXIT, exitLatched true. Fuel is measured from the brain
# balance delta.
# PRE-GATE: brain must hold >= 1.50 lREACT (June burns ~1.95 of the
# 2.20 attach; top up with one faucet round + attach BEFORE this leg
# if the gate fails — do NOT start the bleed under-fuelled).
# Transcript: goal hidden_files/release6-bleed.log.
# FLAGSHIP SET IS NEVER TOUCHED by this script.
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."
set -a; source .env.local; source "$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/vaultv5-rehearsal-burners.env"; source "$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/v6-pusher.env"; set +a

BASE_RPC="https://sepolia.base.org"
LASNA_RPC="https://lasna-rpc.rnk.dev"
WETH="0x4200000000000000000000000000000000000006"
ORACLE="${R6_ORACLE:?R6_ORACLE not set}"
REACTIVE="${R6_REACTIVE:?R6_REACTIVE not set}"
SWAP="${R6_SWAP:?R6_SWAP not set}"
VAULT="${R6_VAULT:?R6_VAULT not set}"
FLAGSHIP_BRAIN="0x162DdFa4dD0db9bA60c4444b9a1BD1fa6b5343A9"
FLAGSHIP_VAULT="0xD61E27bC945ceE8Bd967aA42c907e7bA6968b5e9"
LOG="${LOG:-$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/release6-bleed.log}"
exec > >(tee -a "$LOG") 2>&1

fail() { echo "!!! ABORT: $*"; echo "!!! State preserved; nothing further will be sent."; exit 1; }
say() { echo "[$(date -u +%H:%M:%S)] $*"; }

cv() { # cv <addr> <sig> [args...] <rpc> — last arg is always the RPC URL; retries transient empty reads
  local addr="$1" sig="$2"; shift 2
  local rpc="${@: -1}" nargs=$(($# - 1)) args=() out="" n=0
  if [ "$nargs" -gt 0 ]; then args=("${@:1:$nargs}"); fi
  while [ $n -lt 5 ]; do
    out=$(cast call "$addr" "$sig" "${args[@]}" --rpc-url "$rpc" 2>/dev/null | awk '{print $1}')
    [ -n "$out" ] && { echo "$out"; return 0; }
    n=$((n+1)); sleep 5
  done
  echo "$out"
}
updates() { cv "$REACTIVE" "updates()(uint256)" "$LASNA_RPC"; }
prot() { cv "$VAULT" "protectionCount()(uint256)" "$BASE_RPC"; }
bal() { cast balance "$1" --rpc-url "$2" 2>/dev/null; }
send() { # send <rpc> <key> <to> <sig> [args...] -> tx hash or FAIL
  local rpc="$1" key="$2" to="$3" sig="$4"; shift 4
  local out h
  out=$(cast send "$to" "$sig" "$@" --rpc-url "$rpc" --private-key "$key" --json 2>/dev/null) || fail "send failed: $sig to $to"
  h=$(echo "$out" | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='0x1','status '+d['status'];print(d['transactionHash'])" 2>/dev/null) || fail "tx reverted: $sig to $to"
  echo "$h"
}

say "=== RELEASE 6 BLEED LEG (AH-2) START ==="
say "oracle=$ORACLE reactive=$REACTIVE swap=$SWAP vault=$VAULT pusher=$PUSHER"
say "flagship before: brain updates=$(cv "$FLAGSHIP_BRAIN" "updates()(uint256)" "$LASNA_RPC") vault shares=$(cv "$FLAGSHIP_VAULT" "totalShares()(uint256)" "$BASE_RPC")"
[ "$(updates)" = "56" ] || fail "brain updates != 56 at bleed entry (June incomplete?)"
[ "$(cv "$VAULT" "closed()(bool)" "$BASE_RPC")" = "true" ] || fail "vault not closed at bleed entry"
[ "$(cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC")" = "0" ] || fail "vault not empty at bleed entry"
[ "$(prot)" = "6" ] || fail "protectionCount != 6 at bleed entry"
[ "$(cv "$REACTIVE" "exitLatched()(bool)" "$LASNA_RPC")" = "true" ] || fail "exitLatched != true at bleed entry (June EXIT did not latch?)"
BRAIN_BAL0=$(bal "$REACTIVE" "$LASNA_RPC")
say "brain balance at bleed entry: $BRAIN_BAL0 lREACT-wei"
python3 -c "exit(0 if $BRAIN_BAL0 >= 1500000000000000000 else 1)" || fail "FUEL GATE: brain $BRAIN_BAL0 < 1.50 lREACT — top up (faucet round + attach) before the bleed"

# June close $1,283.46 = kline 175 = 128346 * 1e10. Bleed -1%/update.
PRICE=1283460000000000000000
LAST_PUSH_START=0
for i in $(seq 1 40); do
  PRICE=$(python3 -c "print($PRICE * 99 // 100)")
  now=$(date +%s)
  if [ "$LAST_PUSH_START" != "0" ]; then
    gap=$(( now - LAST_PUSH_START ))
    if [ "$gap" -lt 42 ]; then sleep $((42 - gap)); fi
  fi
  LAST_PUSH_START=$(date +%s)
  before=$(updates); p0=$(prot)
  hash=$(send "$BASE_RPC" "$PUSHER_KEY" "$ORACLE" "setPrice(address,uint256)" "$WETH" "$PRICE")
  [[ "$hash" =~ ^0x[0-9a-fA-F]{64}$ ]] || fail "bleed push $i send failed: $hash"
  [ "$(cv "$ORACLE" "latestPrice(address)(uint256)" "$WETH" "$BASE_RPC")" = "$PRICE" ] || fail "oracle price != $PRICE at bleed push $i"
  after="$before"; n=0
  while [ "$after" = "$before" ] && [ $n -lt 30 ]; do sleep 3; after=$(updates); n=$((n+1)); done
  [ "$after" != "$before" ] || fail "reactive did not ingest bleed push $i after 90s (updates stuck at $before)"
  [ "$after" = "$(( before + 1 ))" ] || fail "updates jumped $before -> $after at bleed push $i"
  # Let any callback land (up to ~40 s) before logging the count.
  sleep 5; p1=$(prot)
  say "bleed push $i: update=$after price18=$PRICE action=$(cv "$REACTIVE" "lastAction()(uint8)" "$LASNA_RPC") prot=$p0->$p1 latched=$(cv "$REACTIVE" "exitLatched()(bool)" "$LASNA_RPC") tx=$hash"
done

# Final settle: last callback may lag the last push by up to ~2 min.
n=0; p=$(prot)
while [ $n -lt 40 ]; do sleep 3; p2=$(prot); [ "$p2" = "$p" ] && n=$((n+1)) || { p=$p2; n=0; }; [ $n -ge 5 ] && break; done
say "bleed settle: protectionCount=$p (June 6 + bleed leg)"
BRAIN_BAL1=$(bal "$REACTIVE" "$LASNA_RPC")
FUEL=$(python3 -c "print($BRAIN_BAL0 - $BRAIN_BAL1)")
say "brain balance at bleed end: $BRAIN_BAL1 lREACT-wei; bleed fuel burned: $FUEL lREACT-wei"
[ "$(updates)" = "96" ] || fail "brain updates $(updates) != 96 after bleed"
[ "$(cv "$REACTIVE" "lastAction()(uint8)" "$LASNA_RPC")" = "2" ] || fail "lastAction != EXIT after bleed"
[ "$(cv "$REACTIVE" "exitLatched()(bool)" "$LASNA_RPC")" = "true" ] || fail "exitLatched != true after bleed"
# CORRECTION (2026-11-27, after the live run): the design predicted 3
# bleed callbacks (the fresh-brain H12 shape: 2 TRIM + 1 EXIT). On the
# post-June brain the June episode anchor (~$1,594) carries over, so the
# bleed votes EXIT from push 1 and the latch suppresses ALL 40 — the
# correct live result is 0 bleed callbacks (protectionCount stays 6),
# which is strictly better than the predicted 3. The script aborted on
# the old "9" on its first run; the assertion below is the corrected one.
[ "$p" = "6" ] || fail "protectionCount $p != 6 after bleed (June 6 + bleed 0)"
[ "$(cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC")" = "0" ] || fail "vault not empty after bleed"
say "flagship after: brain updates=$(cv "$FLAGSHIP_BRAIN" "updates()(uint256)" "$LASNA_RPC") vault shares=$(cv "$FLAGSHIP_VAULT" "totalShares()(uint256)" "$BASE_RPC")"
say "RELEASE6_BLEED_RESULT updates=96 protectionCount=$p fuelBurnedWei=$FUEL brainBal0=$BRAIN_BAL0 brainBal1=$BRAIN_BAL1"
say "=== RELEASE 6 BLEED LEG COMPLETE — 0 callbacks, not 20 ==="
