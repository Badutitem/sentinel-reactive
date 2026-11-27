#!/usr/bin/env bash
# RELEASE 6 June-core rehearsal driver — fresh R8 set (FIXED code), Binance ETHUSDT
# hourly closes, klines indices 120-175 (56 pushes, 11-13 Jun 2022).
# Same choreography as R7 (A 0.003 before push 1, B 0.002 after TRIM@9,
# A partial-redeem 1e15 after TRIM@32, C 0.0015 after TRIM@44, EXIT@56,
# final redemption A -> B -> C redeemAll; pool must reconcile to the wei).
# Addresses are filled in by the deploy step (R6_* env or sed after deploy).
# Every push asserts: price18 == kline*1e10, updates +1 exactly,
# lastAction == mirror vote table. Every callback snapshot asserts the
# design §3 managed totals exactly. Any mismatch ABORTS (exit 1) with
# state preserved — no improvising past a mismatch.
# Pacing: push-start gaps >= 42 s (mirror validated 35-60 s; floor 40 s).
# Transcript: $LOG (default: goal hidden_files, NOT /tmp).
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."
set -a; source .env.local; source "$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/vaultv5-rehearsal-burners.env"; source "$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/v6-pusher.env"; set +a

BASE_RPC="https://sepolia.base.org"
LASNA_RPC="https://lasna-rpc.rnk.dev"
WETH="0x4200000000000000000000000000000000000006"
MUSDC="0x96E467Ff7958851d307D28118EBAAD333CAb85B2"
ORACLE="${R6_ORACLE:?R6_ORACLE not set}"
REACTIVE="${R6_REACTIVE:?R6_REACTIVE not set}"
SWAP="${R6_SWAP:?R6_SWAP not set}"
VAULT="${R6_VAULT:?R6_VAULT not set}"
KLINES="tools/data/klines_jun2022.json"
KLINES_SHA="e003dd72be0253ce5d91f999a620a95660018dd56008ffa5236b806b12d2ed47"
LOG="${LOG:-$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/release6-driver.log}"
exec > >(tee -a "$LOG") 2>&1

fail() { echo "!!! ABORT: $*"; echo "!!! State preserved; nothing further will be sent."; exit 1; }
say() { echo "[$(date -u +%H:%M:%S)] $*"; }

cv() { # cv <addr> <sig> [args...] <rpc> — last arg is always the RPC URL; retries transient empty reads (idempotent)
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
mshares() { cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC"; }
mrisk() { cv "$VAULT" "managedRisk()(uint256)" "$BASE_RPC"; }
msafe() { cv "$VAULT" "managedSafe()(uint256)" "$BASE_RPC"; }
sharesof() { local out="" n=0; while [ $n -lt 5 ]; do out=$(cast call "$VAULT" "sharesOf(address)(uint256)" "$1" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}'); [ -n "$out" ] && { echo "$out"; return 0; }; n=$((n+1)); sleep 5; done; echo "$out"; }
bal() { local out="" n=0; while [ $n -lt 5 ]; do out=$(cast call "$1" "balanceOf(address)(uint256)" "$2" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}'); [ -n "$out" ] && { echo "$out"; return 0; }; n=$((n+1)); sleep 5; done; echo "$out"; }

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
  hash=$(send "$BASE_RPC" "$PUSHER_KEY" "$ORACLE" "setPrice(address,uint256)" "$WETH" "$p18")
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

say "=== RELEASE 6 JUNE-CORE REHEARSAL START ==="
say "oracle=$ORACLE reactive=$REACTIVE swap=$SWAP vault=$VAULT pusher=$PUSHER"
[ "$(sha256sum "$KLINES" | awk '{print $1}')" = "$KLINES_SHA" ] || fail "klines file hash mismatch"
[ "$(updates)" = "0" ] || fail "reactive updates not 0 at start (stale set?)"
# V6 read-backs (AH-2/AH-3/AH-5/AH-6): latch clear, wiring locked, bounds set.
[ "$(cv "$REACTIVE" "exitLatched()(bool)" "$LASNA_RPC")" = "false" ] || fail "reactive exitLatched != false at start"
[ "$(cv "$REACTIVE" "vaultLocked()(bool)" "$LASNA_RPC")" = "true" ] || fail "reactive vaultLocked != true at start"
[ "$(cv "$SWAP" "vaultLocked()(bool)" "$BASE_RPC")" = "true" ] || fail "swap vaultLocked != true at start"
[ "$(cv "$SWAP" "MIN_SANE_PRICE()(uint256)" "$BASE_RPC")" = "1000000000000000000" ] || fail "swap MIN_SANE_PRICE != 1e18 at start"
[ "$(cv "$VAULT" "MAX_DEPOSIT_DEVIATION_BPS()(uint256)" "$BASE_RPC")" = "2000" ] || fail "vault band != 2000 at start"
[ "$(cv "$ORACLE" "pricePushers(address)(bool)" "$PUSHER" "$BASE_RPC")" = "true" ] || fail "oracle pricePushers(pusher) != true at start"
snap "initial"
[ "$(mshares)" = "0" ] || fail "vault not empty at start"

# --- User A: first deposit, before push 1 (1:1 expected) ---
user_deposit A 3000000000000000 3000000000000000
snap "after-A-deposit"

say "== Stage A: calm, updates 1-8 (expect HOLD x8, prot 0) =="
for idx in 120 121 122 123 124 125 126 127; do push_idx $idx; done
[ "$(prot)" = "0" ] || fail "unexpected protection during calm stage"
snap "stage-A-end"

say "== TRIM@9 (idx 128, \$1578.19) =="
push_idx 128
wait_prot 1
snap "after-TRIM9"
expect_managed "TRIM@9" 1500000000000000 2367285000000000000
user_deposit B 2000000000000000 2000000000000000
snap "after-B-deposit"

say "== updates 10-20 (TRIM votes suppressed, HOLD@19-20) =="
for idx in 129 130 131 132 133 134 135 136 137 138 139; do push_idx $idx; done
say "== TRIM@21 (idx 140, \$1523.34) =="
push_idx 140
wait_prot 2
snap "after-TRIM21"
expect_managed "TRIM@21" 1750000000000000 5033130000000000000

say "== updates 22-31 =="
for idx in 141 142 143 144 145 146 147 148 149 150; do push_idx $idx; done
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
say "=== RELEASE 6 JUNE-CORE REHEARSAL PUSHES COMPLETE ==="
