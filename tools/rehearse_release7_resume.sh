#!/usr/bin/env bash
# RELEASE 7 June-core RESUME driver — continues the aborted run at update 55.
# Root cause of the abort (tooling-side, driver table bug): the main driver's
# EXPECTED_ACTIONS string had 55 tokens (11 ones in the 44-55 run instead of
# 12), so position 55 read as EXIT(2); the chain correctly voted TRIM(1).
# The chain state was verified before this resume (design §6.6):
#   updates=55, oracle latestPrice=1324.35e18 (idx 174), PriceUpdated events=55,
#   prot=5, managedRisk=925000000000000, managedSafe=6799266250000000000,
#   totalShares=5457221886906302, shares A/B/C exact, raw==managed (INV-1).
# This script pushes ONLY idx 175 (update 56, EXIT), then the final redemption.
# It never re-pushes an index. Any mismatch ABORTS with state preserved.
# Transcript: goal hidden_files/release7-driver-resume.log (main driver log
# is also appended to by the shared LOG? No — this script has its own log).
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."
set -a; source .env.local; source "$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/vaultv5-rehearsal-burners.env"; set +a

BASE_RPC="https://sepolia.base.org"
LASNA_RPC="https://lasna-rpc.rnk.dev"
WETH="0x4200000000000000000000000000000000000006"
MUSDC="0x96E467Ff7958851d307D28118EBAAD333CAb85B2"
ORACLE="0xAdEBD7a0C3129020c0E807673848E812daCc3409"
REACTIVE="0x4030b231B348B212175c0D218735cf82Ff2f0f5a"
SWAP="0xa5400474d07bdC26E5591589D7EaA1824065771E"
VAULT="0xf68e7fC6d496E8ad253ee0B7D74059B9e8A25237"
KLINES="tools/data/klines_jun2022.json"
LOG="${LOG:-$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/release7-driver-resume.log}"
exec > >(tee -a "$LOG") 2>&1

fail() { echo "!!! ABORT: $*"; echo "!!! State preserved; nothing further will be sent."; exit 1; }
say() { echo "[$(date -u +%H:%M:%S)] $*"; }

cv() { # cv <addr> <sig> [args...] <rpc> — last arg is always the RPC URL
  local addr="$1" sig="$2"; shift 2
  local rpc="${@: -1}" nargs=$(($# - 1)) args=()
  if [ "$nargs" -gt 0 ]; then args=("${@:1:$nargs}"); fi
  cast call "$addr" "$sig" "${args[@]}" --rpc-url "$rpc" 2>/dev/null | awk '{print $1}'
}
updates() { cv "$REACTIVE" "updates()(uint256)" "$LASNA_RPC"; }
prot() { cv "$VAULT" "protectionCount()(uint256)" "$BASE_RPC"; }
mshares() { cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC"; }
mrisk() { cv "$VAULT" "managedRisk()(uint256)" "$BASE_RPC"; }
msafe() { cv "$VAULT" "managedSafe()(uint256)" "$BASE_RPC"; }
sharesof() { cast call "$VAULT" "sharesOf(address)(uint256)" "$1" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}'; }
bal() { cast call "$1" "balanceOf(address)(uint256)" "$2" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}'; }

snap() {
  local mr ms rw rs ts
  mr=$(mrisk); ms=$(msafe)
  rw=$(bal "$WETH" "$VAULT"); rs=$(bal "$MUSDC" "$VAULT"); ts=$(mshares)
  say "SNAP $1: updates=$(updates) prot=$(prot) closed=$(cv "$VAULT" "closed()(bool)" "$BASE_RPC") managedRisk=$mr managedSafe=$ms rawWETH=$rw rawMUSDC=$rs totalShares=$ts sharesA=$(sharesof $USER_A_ADDRESS) sharesB=$(sharesof $USER_B_ADDRESS) sharesC=$(sharesof $USER_C_ADDRESS) deskWETH=$(bal "$WETH" "$SWAP") deskMUSDC=$(bal "$MUSDC" "$SWAP")"
  python3 -c "exit(0 if $rw >= $mr and $rs >= $ms else 1)" || fail "INV-1 violated at $1 (raw $rw/$rs < managed $mr/$ms)"
}

expect_managed() {
  [ "$(mrisk)" = "$2" ] || fail "$1: managedRisk $(mrisk) != $2"
  [ "$(msafe)" = "$3" ] || fail "$1: managedSafe $(msafe) != $3"
  say "managed totals match design at $1: risk=$2 safe=$3"
}

send() {
  local rpc="$1" key="$2" to="$3" sig="$4"; shift 4
  local out h
  out=$(cast send "$to" "$sig" "$@" --rpc-url "$rpc" --private-key "$key" --json 2>/dev/null) || fail "send failed: $sig to $to"
  h=$(echo "$out" | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='0x1','status '+d['status'];print(d['transactionHash'])" 2>/dev/null) || fail "tx reverted: $sig to $to"
  echo "$h"
}

wait_prot() { local want="$1" n=0 got; got=$(prot); while [ "$got" != "$want" ] && [ $n -lt 40 ]; do sleep 3; got=$(prot); n=$((n+1)); done; [ "$got" = "$want" ] || fail "protectionCount stuck at $got, expected $want"; say "callback landed: protectionCount=$got"; }

say "=== RELEASE 7 JUNE-CORE RESUME START (update 55 -> 56) ==="
# --- Resume gate (design §6.6): rebuild state from chain reads ---
[ "$(updates)" = "55" ] || fail "resume gate: updates $(updates) != 55"
[ "$(cv "$ORACLE" "latestPrice(address)(uint256)" "$WETH" "$BASE_RPC")" = "1324350000000000000000" ] || fail "resume gate: oracle latestPrice != idx174 price18"
[ "$(prot)" = "5" ] || fail "resume gate: protectionCount $(prot) != 5 (TRIM@55 callback?)"
[ "$(cv "$VAULT" "closed()(bool)" "$BASE_RPC")" = "false" ] || fail "resume gate: vault already closed"
[ "$(mshares)" = "5457221886906302" ] || fail "resume gate: totalShares $(mshares) != 5457221886906302"
[ "$(sharesof $USER_A_ADDRESS)" = "2000000000000000" ] || fail "resume gate: sharesA mismatch"
[ "$(sharesof $USER_B_ADDRESS)" = "2000000000000000" ] || fail "resume gate: sharesB mismatch"
[ "$(sharesof $USER_C_ADDRESS)" = "1457221886906302" ] || fail "resume gate: sharesC mismatch"
snap "resume-TRIM55-verified"
expect_managed "TRIM@55-resume-gate" 925000000000000 6799266250000000000
say "resume gate PASS: oracle history (55 events, verified separately) == updates 55; no price will be pushed twice"

say "== EXIT@56 (idx 175, \$1283.46) — LAST PUSH =="
# Single push of idx 175 only. Price asserted == kline*1e10 before sending.
KLINE175=$(python3 -c "import json;print(json.load(open('$KLINES'))[175])")
P18_175=$(python3 -c "print($KLINE175 * 10**10)")
[ "$P18_175" = "1283460000000000000000" ] || fail "idx175 price18 $P18_175 != 1283460000000000000000"
BEFORE=$(updates)
HASH=$(send "$BASE_RPC" "$PRIVATE_KEY" "$ORACLE" "setPrice(address,uint256)" "$WETH" "$P18_175")
[[ "$HASH" =~ ^0x[0-9a-fA-F]{64}$ ]] || fail "push idx 175 send failed: $HASH"
[ "$(cv "$ORACLE" "latestPrice(address)(uint256)" "$WETH" "$BASE_RPC")" = "$P18_175" ] || fail "oracle price != kline*1e10 at idx 175"
AFTER="$BEFORE"; N=0
while [ "$AFTER" = "$BEFORE" ] && [ $N -lt 30 ]; do sleep 3; AFTER=$(updates); N=$((N+1)); done
[ "$AFTER" = "56" ] || fail "updates after idx175 = $AFTER, expected 56"
ACT=$(cv "$REACTIVE" "lastAction()(uint8)" "$LASNA_RPC")
[ "$ACT" = "2" ] || fail "update 56: lastAction $ACT != 2 (EXIT)"
say "push idx=175 update=56 price18=$P18_175 (\$1283.46) origin_tx=$HASH action=$ACT prot=$(prot)"
wait_prot 6
[ "$(cv "$VAULT" "closed()(bool)" "$BASE_RPC")" = "true" ] || fail "vault not closed after EXIT@56"
snap "after-EXIT56"
expect_managed "EXIT@56" 0 7986466750000000000
say "== STOP: no update 57 is ever pushed (R-2) =="

say "== Final redemption sequence (A, B, C redeemAll) =="
say "managed totals before sequence: risk=$(mrisk) safe=$(msafe) totalShares=$(mshares)"
for u in A B C; do
  addr=$(eval echo \$USER_${u}_ADDRESS); key=$(eval echo \$USER_${u}_KEY)
  h=$(send "$BASE_RPC" "$key" "$VAULT" "redeemAll()")
  [[ "$h" =~ ^0x[0-9a-fA-F]{64}$ ]] || fail "user $u redeemAll failed: $h"
  say "USER $u redeemAll tx=$h sharesAfter=$(sharesof $addr) wethBal=$(bal "$WETH" "$addr") musdcBal=$(bal "$MUSDC" "$addr")"
done
snap "final"
[ "$(mshares)" = "0" ] || fail "final totalShares != 0"
[ "$(mrisk)" = "0" ] || fail "final managedRisk != 0"
[ "$(msafe)" = "0" ] || fail "final managedSafe != 0"
[ "$(bal "$WETH" "$VAULT")" = "0" ] || fail "final raw WETH != 0"
[ "$(bal "$MUSDC" "$VAULT")" = "0" ] || fail "final raw mUSDC != 0"
say "=== RELEASE 7 JUNE-CORE REHEARSAL COMPLETE (main driver + resume) ==="
