#!/usr/bin/env bash
# RELEASE 8 LIVE POST-DRIVE ATTACK TESTS — run AFTER the 56-push LIVE drive + final
# redemption complete, on the closed, empty R8 set. State at entry:
# brain updates 56, lastAction 2 (EXIT), vault closed, totalShares 0.
#   F2 time-based stale: wait until 3600 s after the LAST drive push
#         (idx 175), then priceStale() must read true and both swap fills
#         (eth_call FROM the vault) must return 0 + StalePriceRefused.
#   F4 brain guard (layer 2, dev is allowlisted): dev pushes price 0 —
#         the oracle stores it, the brain must CONSUME the log without
#         ingesting it (updates stays 56, no brick). Then dev pushes a
#         mirror-chosen HOLD price (R8_HOLD_PRICE18, default $1,600) and
#         updates must advance to 57 with no callback — brain alive.
# These pushes are POST-REPLAY phase: they advance updates past 56 and are
# recorded separately from the rehearsal final state (updates 56).
# Any failure ABORTS (exit 1).
# Transcript: goal hidden_files/release8-attacks-post.log.
# FLAGSHIP SET IS NEVER TOUCHED by this script.
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."
set -a; source .env.local; set +a

BASE_RPC="https://sepolia.base.org"
LASNA_RPC="https://lasna-rpc.rnk.dev"
WETH="0x4200000000000000000000000000000000000006"
FLAGSHIP_BRAIN="0x37EeF5e3179E55c0e96E1528180B55Fa20DC150B"
FLAGSHIP_VAULT="0x108513e6439664fdeE9050e1ccc208e8c1b61441"
ORACLE="0x9380ee21a8C00f9FB42346F63E28BCf1B847de4F"  # LIVE R8 oracle
REACTIVE="0x2C1d278d31d52Ec8405cF33E319ba0eB8C6b0d1F"  # LIVE R8 brain
SWAP="0xBDF3e24a673016dcCB00f7CA489456e3fa2d7D41"  # LIVE R8 swap desk
VAULT="0x86b551AF1D8A5c0c2767Bf8Bb53F1F8bAeC74e18"  # LIVE R8 vault
LAST_PUSH_EPOCH="${R8_LAST_PUSH_EPOCH:?R8_LAST_PUSH_EPOCH not set (unix seconds of the idx-175 push)}"
HOLD_PRICE18="${R8_HOLD_PRICE18:-1600000000000000000000}"
DRIVER_LOG="$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/release8-live-driver.log"
LOG="${LOG:-$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/release8-live-attacks-post.log}"
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
send() { # send <rpc> <key> <to> <sig> [args...] -> tx hash or FAIL
  local rpc="$1" key="$2" to="$3" sig="$4"; shift 4
  local out h
  out=$(cast send "$to" "$sig" "$@" --rpc-url "$rpc" --private-key "$key" --json 2>/dev/null) || fail "send failed: $sig to $to"
  h=$(echo "$out" | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='0x1','status '+d['status'];print(d['transactionHash'])" 2>/dev/null) || fail "tx reverted: $sig to $to"
  echo "$h"
}

say "=== RELEASE 8 POST-DRIVE ATTACK TESTS START ==="
say "flagship before: brain updates=$(cv "$FLAGSHIP_BRAIN" "updates()(uint256)" "$LASNA_RPC") lastAction=$(cv "$FLAGSHIP_BRAIN" "lastAction()(uint8)" "$LASNA_RPC") vault totalShares=$(cv "$FLAGSHIP_VAULT" "totalShares()(uint256)" "$BASE_RPC")"
[ "$(cv "$REACTIVE" "updates()(uint256)" "$LASNA_RPC")" = "56" ] || fail "brain updates != 56 at post-drive entry (drive incomplete?)"
[ "$(cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC")" = "0" ] || fail "vault not empty at post-drive entry"
[ "$(cv "$VAULT" "closed()(bool)" "$BASE_RPC")" = "true" ] || fail "vault not closed at post-drive entry"

# --- F2 time-based stale: wait out the 3600 s bound from the last push ---
NOW=$(date +%s)
DEADLINE=$(( LAST_PUSH_EPOCH + 3600 + 60 ))
if [ "$NOW" -lt "$DEADLINE" ]; then
  WAIT=$(( DEADLINE - NOW ))
  say "F2: waiting ${WAIT}s for the price source to go stale (last push epoch $LAST_PUSH_EPOCH + 3600s + 60s margin)"
  sleep "$WAIT"
fi
[ "$(cv "$SWAP" "priceStale()(bool)" "$BASE_RPC")" = "true" ] || fail "F2: priceStale != true after 3600 s of price silence"
AGE=$(cv "$SWAP" "priceAge()(uint256)" "$BASE_RPC")
say "F2: priceStale=true priceAge=$AGE (> 3600) after genuine halt"
for FN in "swapRiskForSafe(uint256)(uint256)" "swapSafeForRisk(uint256)(uint256)"; do
  RET=$(cast call "$SWAP" "$FN" 1000000000000000 --from "$VAULT" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}')
  [ "$RET" = "0" ] || fail "F2: $FN returned $RET, expected 0 (stale fill must refuse)"
  TRACE=$(cast call "$SWAP" "$FN" 1000000000000000 --from "$VAULT" --rpc-url "$BASE_RPC" --trace 2>&1) || fail "F2: $FN trace call failed unexpectedly"
  echo "$TRACE" | grep -q "StalePriceRefused" || fail "F2: $FN trace lacks StalePriceRefused event"
  say "F2: $FN from vault returns 0 + StalePriceRefused in trace — fill REFUSED after 3600 s halt"
done

# --- F4 brain guard, layer 2: dev (allowlisted) pushes price 0 ---
# The oracle stores 0; the brain must consume the log without ingesting it.
H0=$(send "$BASE_RPC" "$PRIVATE_KEY" "$ORACLE" "setPrice(address,uint256)" "$WETH" 0)
say "F4-guard: dev pushed price 0 tx=$H0 (allowlisted push SUCCEEDS at the oracle)"
[ "$(cv "$ORACLE" "latestPrice(address)(uint256)" "$WETH" "$BASE_RPC")" = "0" ] || fail "F4-guard: oracle did not store the 0 price"
sleep 45
[ "$(cv "$REACTIVE" "updates()(uint256)" "$LASNA_RPC")" = "56" ] || fail "F4-guard: brain updates moved off 56 after the 0 print (guard did not ignore it)"
say "F4-guard: 45 s after the 0 print, brain updates still 56 — poison log consumed, never ingested, NO BRICK"
# Follow-up legitimate price (mirror-chosen HOLD): brain must advance.
H1=$(send "$BASE_RPC" "$PRIVATE_KEY" "$ORACLE" "setPrice(address,uint256)" "$WETH" "$HOLD_PRICE18")
say "F4-guard: dev pushed legitimate price $HOLD_PRICE18 tx=$H1"
n=0; U=56
while [ "$U" = "56" ] && [ $n -lt 30 ]; do sleep 3; U=$(cv "$REACTIVE" "updates()(uint256)" "$LASNA_RPC"); n=$((n+1)); done
[ "$U" = "57" ] || fail "F4-guard: brain did not advance to 57 after the legitimate price (stuck at $U)"
[ "$(cv "$REACTIVE" "lastAction()(uint8)" "$LASNA_RPC")" = "0" ] || fail "F4-guard: follow-up price did not vote HOLD as the mirror predicted"
[ "$(cv "$VAULT" "protectionCount()(uint256)" "$BASE_RPC")" = "6" ] || fail "F4-guard: follow-up price fired a callback (protectionCount != 6)"
say "F4-guard: brain advanced to 57, lastAction HOLD, protectionCount still 6 — BRAIN ALIVE after the poison print"

say "flagship after: brain updates=$(cv "$FLAGSHIP_BRAIN" "updates()(uint256)" "$LASNA_RPC") lastAction=$(cv "$FLAGSHIP_BRAIN" "lastAction()(uint8)" "$LASNA_RPC") vault totalShares=$(cv "$FLAGSHIP_VAULT" "totalShares()(uint256)" "$BASE_RPC")"
say "=== RELEASE 8 POST-DRIVE ATTACK TESTS COMPLETE — F2 REFUSED, F4 GUARD HELD ==="
