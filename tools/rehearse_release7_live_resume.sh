#!/usr/bin/env bash
# RELEASE 7 June-core LIVE driver — RESUME from update 28 (idx 148) — fresh live set, Binance ETHUSDT
# hourly closes, klines indices 120-175 (56 pushes, 11-13 Jun 2022).
#   A deposits 0.003 WETH before push 1 (1:1)
#   TRIM@9  -> B deposits 0.002 WETH
#   TRIM@21 -> (no user step)
#   TRIM@32 -> A partial-redeems 1,000,000,000,000,000 shares
#   TRIM@44 -> C deposits 0.0015 WETH
#   TRIM@55 -> (no user step)
#   EXIT@56 -> closed; STOP. No update 57 is ever pushed (R-2).
#   Final redemption A -> B -> C redeemAll; pool must reconcile to the wei.
# Every push asserts: price18 == kline*1e10, updates +1 exactly,
# lastAction == mirror vote table. Every callback snapshot asserts the
# design §3 managed totals exactly. Any mismatch ABORTS (exit 1) with
# state preserved — no improvising past a mismatch.
# Pacing: push-start gaps >= 42 s (mirror validated 35-60 s; floor 40 s).
# Transcript: $LOG (default: goal hidden_files, NOT /tmp).
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."
set -a; source .env.local; source "$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/vaultv5-rehearsal-burners.env"; set +a

BASE_RPC="https://sepolia.base.org"
LASNA_RPC="https://lasna-rpc.rnk.dev"
WETH="0x4200000000000000000000000000000000000006"
MUSDC="0x96E467Ff7958851d307D28118EBAAD333CAb85B2"
ORACLE="0x9960575DB4681bC5c02cBa4A7248633aFE897f9d"
REACTIVE="0x31414A31674d1E138C0Dce0FA04828229DE22FC9"
SWAP="0x23484EC173816395494492f0677f9DB985B73111"
VAULT="0xF2Fda1aCEb36a95136eCDA6707C7CDc96D105068"
KLINES="tools/data/klines_jun2022.json"
KLINES_SHA="e003dd72be0253ce5d91f999a620a95660018dd56008ffa5236b806b12d2ed47"
LOG="${LOG:-$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/release7-live-driver-resume.log}"
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

expect_managed() { # expect_managed <label> <risk-wei> <safe-wei>
  [ "$(mrisk)" = "$2" ] || fail "$1: managedRisk $(mrisk) != $2"
  [ "$(msafe)" = "$3" ] || fail "$1: managedSafe $(msafe) != $3"
  say "managed totals match design at $1: risk=$2 safe=$3"
}

send() { # send <rpc> <key> <to> <sig> [args...] -> tx hash or FAIL
  local rpc="$1" key="$2" to="$3" sig="$4"; shift 4
  local out h
  out=$(cast send "$to" "$sig" "$@" --rpc-url "$rpc" --private-key "$key" --json 2>/dev/null) || fail "send failed: $sig to $to"
  h=$(echo "$out" | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='0x1','status '+d['status'];print(d['transactionHash'])" 2>/dev/null) || fail "tx reverted: $sig to $to"
  echo "$h"
}

# Mirror vote table, updates 1..56 (HOLD=0, TRIM=1, EXIT=2; updates 1-2 warmup, lastAction 0).
EXPECTED_ACTIONS="0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1 1 1 0 0 1 0 0 0 0 1 1 1 1 1 1 1 1 1 1 0 1 1 0 0 0 0 0 1 1 1 1 1 1 1 1 1 1 1 1 2"
expected_action() { echo "$EXPECTED_ACTIONS" | awk -v n="$1" '{print $n}'; }

LAST_PUSH_START=0
push_idx() { # push_idx <kline-index> — asserts price18, updates+1, lastAction
  local idx="$1" kline p18 before after n=0 hash now gap
  kline=$(python3 -c "import json;print(json.load(open('$KLINES'))[$idx])")
  p18=$(python3 -c "print($kline * 10**10)")
  # Pacing: push-start gaps >= 42 s (design floor 40 s).
  now=$(date +%s)
  if [ "$LAST_PUSH_START" != "0" ]; then
    gap=$(( now - LAST_PUSH_START ))
    if [ "$gap" -lt 42 ]; then say "pacing sleep $((42 - gap))s (gap was ${gap}s)"; sleep $((42 - gap)); fi
  fi
  LAST_PUSH_START=$(date +%s)
  before=$(updates)
  hash=$(send "$BASE_RPC" "$PRIVATE_KEY" "$ORACLE" "setPrice(address,uint256)" "$WETH" "$p18")
  [[ "$hash" =~ ^0x[0-9a-fA-F]{64}$ ]] || fail "push idx $idx send failed: $hash"
  # Verify the oracle actually stored price18 == kline*1e10.
  [ "$(cv "$ORACLE" "latestPrice(address)(uint256)" "$WETH" "$BASE_RPC")" = "$p18" ] || fail "oracle price != kline*1e10 at idx $idx"
  after="$before"
  while [ "$after" = "$before" ] && [ $n -lt 30 ]; do sleep 3; after=$(updates); n=$((n+1)); done
  [ "$after" != "$before" ] || fail "reactive did not ingest idx $idx after 90s (updates stuck at $before)"
  local upd=$(( after ))
  [ "$upd" = "$(( before + 1 ))" ] || fail "updates jumped $before -> $after at idx $idx (expected +1 exactly)"
  local act; act=$(cv "$REACTIVE" "lastAction()(uint8)" "$LASNA_RPC")
  [ "$act" = "$(expected_action "$upd")" ] || fail "update $upd (idx $idx): lastAction $act != mirror $(expected_action "$upd")"
  say "push idx=$idx update=$upd price18=$p18 (\$$(( kline / 100000000 )).$(( (kline / 1000000) % 100 ))) origin_tx=$hash action=$act prot=$(prot)"
}

wait_prot() { local want="$1" n=0 got; got=$(prot); while [ "$got" != "$want" ] && [ $n -lt 40 ]; do sleep 3; got=$(prot); n=$((n+1)); done; [ "$got" = "$want" ] || fail "protectionCount stuck at $got, expected $want"; say "callback landed: protectionCount=$got"; }

user_deposit() { # user_deposit <A|B|C> <weth-wei> <expected-shares>
  local u="$1" amt="$2" exp="$3" addr key h1 h2 h3
  addr=$(eval echo \$USER_${u}_ADDRESS); key=$(eval echo \$USER_${u}_KEY)
  h1=$(send "$BASE_RPC" "$key" "$WETH" "deposit()" --value "$amt")
  h2=$(send "$BASE_RPC" "$key" "$WETH" "approve(address,uint256)" "$VAULT" "$amt")
  h3=$(send "$BASE_RPC" "$key" "$VAULT" "deposit(uint256)" "$amt")
  [[ "$h1" =~ ^0x[0-9a-fA-F]{64}$ && "$h2" =~ ^0x[0-9a-fA-F]{64}$ && "$h3" =~ ^0x[0-9a-fA-F]{64}$ ]] || fail "user $u deposit flow failed: $h1 $h2 $h3"
  local sh; sh=$(sharesof $addr)
  [ "$sh" = "$exp" ] || fail "user $u shares $sh != expected $exp"
  say "USER $u deposit $amt wei WETH: wrap=$h1 approve=$h2 deposit=$h3 shares=$sh"
}

say "=== RELEASE 7 JUNE-CORE LIVE DRIVE — RESUME (updates 28 -> 56) ==="
say "oracle=$ORACLE reactive=$REACTIVE swap=$SWAP vault=$VAULT"
say "Resume reason: main driver aborted at idx 147 (RPC read timeout on oracle readback) AFTER the idx-147 setPrice tx had landed; Reactive ingested it (updates 28). State rebuilt from chain reads; idx 147 is NEVER re-pushed."
[ "$(sha256sum "$KLINES" | awk '{print $1}')" = "$KLINES_SHA" ] || fail "klines file hash mismatch"
# --- Resume gates: chain must read exactly the post-update-28 state ---
[ "$(updates)" = "28" ] || fail "resume gate: updates $(updates) != 28"
[ "$(cv "$ORACLE" "latestPrice(address)(uint256)" "$WETH" "$BASE_RPC")" = "1466970000000000000000" ] || fail "resume gate: oracle price != idx147 p18"
[ "$(cv "$REACTIVE" "lastAction()(uint8)" "$LASNA_RPC")" = "1" ] || fail "resume gate: lastAction != 1 (mirror update 28 suppressed TRIM)"
[ "$(prot)" = "2" ] || fail "resume gate: protectionCount != 2"
expect_managed "resume-state" 1750000000000000 5033130000000000000
[ "$(sharesof $USER_A_ADDRESS)" = "3000000000000000" ] || fail "resume gate: sharesA wrong"
[ "$(sharesof $USER_B_ADDRESS)" = "2000000000000000" ] || fail "resume gate: sharesB wrong"
[ "$(sharesof $USER_C_ADDRESS)" = "0" ] || fail "resume gate: sharesC wrong"
snap "resume-state-verified"
say "resume gates PASS: updates=28, oracle=idx147 price, prot=2, managed totals = TRIM@21 state, shares A/B/C correct. Next push is idx 148 (update 29)."

say "== updates 29-31 (idx 148-150) =="
for idx in 148 149 150; do push_idx $idx; done

say "== TRIM@32 (idx 151, \$1471.26) =="
push_idx 151
wait_prot 3
snap "after-TRIM32"
expect_managed "TRIM@32" 875000000000000 6320482500000000000
AHASH=$(send "$BASE_RPC" "$USER_A_KEY" "$VAULT" "redeem(uint256)" 1000000000000000)
[[ "$AHASH" =~ ^0x[0-9a-fA-F]{64}$ ]] || fail "A partial redeem failed: $AHASH"
say "USER A partial redeem 1000000000000000 shares: tx=$AHASH wethBal=$(bal "$WETH" "$USER_A_ADDRESS") musdcBal=$(bal "$MUSDC" "$USER_A_ADDRESS") sharesA=$(sharesof $USER_A_ADDRESS)"
snap "after-A-partial-redeem"
expect_managed "A-partial-redeem" 700000000000000 5056386000000000000

say "== updates 33-43 =="
for idx in 152 153 154 155 156 157 158 159 160 161 162; do push_idx $idx; done
say "== TRIM@44 (idx 163, \$1479.59) =="
push_idx 163
wait_prot 4
snap "after-TRIM44"
expect_managed "TRIM@44" 350000000000000 5574242500000000000
user_deposit C 1500000000000000 1457221886906302
snap "after-C-deposit"

say "== updates 45-54 =="
for idx in 164 165 166 167 168 169 170 171 172 173; do push_idx $idx; done
say "== TRIM@55 (idx 174, \$1324.35) =="
push_idx 174
wait_prot 5
snap "after-TRIM55"
expect_managed "TRIM@55" 925000000000000 6799266250000000000

say "== EXIT@56 (idx 175, \$1283.46) — LAST PUSH =="
push_idx 175
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
say "=== RELEASE 7 JUNE-CORE REHEARSAL PUSHES COMPLETE ==="
