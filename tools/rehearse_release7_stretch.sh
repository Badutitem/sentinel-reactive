#!/usr/bin/env bash
# RELEASE 7 AUG-STRETCH rehearsal driver — fresh R7 stretch set, Binance
# ETHUSDT hourly closes, klines indices 280-382 (103 pushes, Aug 2024).
#   A deposits 0.003 WETH before push 1 (1:1)
#   TRIM@8  -> B deposits 0.002 WETH
#   EXIT@15 -> closed; A partial-redeems 1,000,000,000,000,000 shares
#   TRIM@17, EXIT@21, TRIM@27/41/55/68/79 -> NO-OP callbacks on closed
#     vault (protectionCount still +1 each; managed totals UNCHANGED)
#   TRIM@79 -> C deposits 0.0015 WETH (deposit re-arms closed=false, so C
#     MUST land after the last no-op callback, or later fires go real)
#   RERISK@97 (tranche 1) -> RERISK_FINAL@102 (tranche 2)
#   Update 103 is the LAST push. No update 104 is ever pushed.
#   Final redemption A -> B -> C redeemAll; pool must reconcile to the wei.
# Every push asserts: price18 == kline*1e10, updates +1 exactly,
# lastAction == mirror vote table. Every callback snapshot asserts the
# predicted managed totals exactly. Any mismatch ABORTS (exit 1) with
# state preserved — no improvising past a mismatch.
# Pacing: push-start gaps >= 42 s (mirror validated 35-60 s; floor 40 s).
# Transcript: $LOG (goal hidden_files, NOT /tmp).
# EXPECTED_ACTIONS was generated from a fresh mirror run
# (r7-stretch-derive.py) and diffed against the mirror before driving.
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."
set -a; source .env.local; source "$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/vaultv5-rehearsal-burners.env"; set +a

BASE_RPC="https://sepolia.base.org"
LASNA_RPC="https://lasna-rpc.rnk.dev"
WETH="0x4200000000000000000000000000000000000006"
MUSDC="0x96E467Ff7958851d307D28118EBAAD333CAb85B2"
ORACLE="0x0AE8fe8884580c6F6D5a5683DE42b241584EA304"
REACTIVE="0x88B53f2Aa7e5056EB21616498aC926d7AD837851"
SWAP="0x46f61e3ce5D9c441Df9DC6138f67d468524986a4"
VAULT="0x4998d509123aFdf6F2911359906d7df801BF062e"
KLINES="tools/data/klines_aug2024.json"
KLINES_SHA="08a51821b2fc353f0c84935a844edddfdd78a86b99ca55e1d5d25454810723f5"
LOG="${LOG:-$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/release7-stretch-driver.log}"
exec > >(tee -a "$LOG") 2>&1

fail() { echo "!!! ABORT: $*"; echo "!!! State preserved; nothing further will be sent."; exit 1; }
say() { echo "[$(date -u +%H:%M:%S)] $*"; }

cv() { # cv <addr> <sig> [args...] <rpc> — retries; empty after 3 tries = READ FAILED
  local addr="$1" sig="$2"; shift 2
  local rpc="${@: -1}" nargs=$(($# - 1)) args=() i v
  if [ "$nargs" -gt 0 ]; then args=("${@:1:$nargs}"); fi
  for i in 1 2 3; do
    v=$(cast call "$addr" "$sig" "${args[@]}" --rpc-url "$rpc" 2>/dev/null | awk '{print $1}')
    [ -n "$v" ] && { echo "$v"; return 0; }
    sleep 3
  done
  echo "READ_FAILED"
  return 1
}
updates() { cv "$REACTIVE" "updates()(uint256)" "$LASNA_RPC"; }
prot() { cv "$VAULT" "protectionCount()(uint256)" "$BASE_RPC"; }
reriskc() { cv "$VAULT" "reriskCount()(uint256)" "$BASE_RPC"; }
mshares() { cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC"; }
mrisk() { cv "$VAULT" "managedRisk()(uint256)" "$BASE_RPC"; }
msafe() { cv "$VAULT" "managedSafe()(uint256)" "$BASE_RPC"; }
sharesof() { cast call "$VAULT" "sharesOf(address)(uint256)" "$1" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}'; }
bal() { cast call "$1" "balanceOf(address)(uint256)" "$2" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}'; }

snap() {
  local mr ms rw rs ts
  mr=$(mrisk); ms=$(msafe)
  rw=$(bal "$WETH" "$VAULT"); rs=$(bal "$MUSDC" "$VAULT"); ts=$(mshares)
  say "SNAP $1: updates=$(updates) prot=$(prot) rerisk=$(reriskc) closed=$(cv "$VAULT" "closed()(bool)" "$BASE_RPC") managedRisk=$mr managedSafe=$ms rawWETH=$rw rawMUSDC=$rs totalShares=$ts sharesA=$(sharesof $USER_A_ADDRESS) sharesB=$(sharesof $USER_B_ADDRESS) sharesC=$(sharesof $USER_C_ADDRESS) deskWETH=$(bal "$WETH" "$SWAP") deskMUSDC=$(bal "$MUSDC" "$SWAP")"
  python3 -c "exit(0 if $rw >= $mr and $rs >= $ms else 1)" || fail "INV-1 violated at $1 (raw $rw/$rs < managed $mr/$ms)"
}

expect_managed() { # expect_managed <label> <risk-wei> <safe-wei>
  [ "$(mrisk)" = "$2" ] || fail "$1: managedRisk $(mrisk) != $2"
  [ "$(msafe)" = "$3" ] || fail "$1: managedSafe $(msafe) != $3"
  say "managed totals match prediction at $1: risk=$2 safe=$3"
}

expect_noop() { # expect_noop <label> — vault closed, totals unchanged
  [ "$(cv "$VAULT" "closed()(bool)" "$BASE_RPC")" = "true" ] || fail "$1: vault NOT closed (expected no-op on closed vault)"
  expect_managed "$1-noop" 0 9577692000000000000
  say "no-op confirmed at $1: vault closed, totals unchanged"
}

send() { # send <rpc> <key> <to> <sig> [args...] -> tx hash or FAIL
  local rpc="$1" key="$2" to="$3" sig="$4"; shift 4
  local out h
  out=$(cast send "$to" "$sig" "$@" --rpc-url "$rpc" --private-key "$key" --json 2>/dev/null) || fail "send failed: $sig to $to"
  h=$(echo "$out" | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='0x1','status '+d['status'];print(d['transactionHash'])" 2>/dev/null) || fail "tx reverted: $sig to $to"
  echo "$h"
}

# Mirror vote table, updates 1..103 (HOLD=0, TRIM=1, EXIT=2; updates 1-2 warmup, lastAction 0).
# Generated by r7-stretch-derive.py from a fresh mirror run; diffed before driving.
EXPECTED_ACTIONS="0 0 0 0 0 0 0 1 1 1 1 1 0 0 2 0 1 1 1 1 2 0 0 0 0 0 1 0 0 1 0 1 0 0 0 0 0 0 0 0 1 1 1 1 1 1 0 0 0 1 0 0 0 0 1 1 1 0 0 0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1 1 1 1 1 1 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"
expected_action() { echo "$EXPECTED_ACTIONS" | awk -v n="$1" '{print $n}'; }

LAST_PUSH_START=0
push_idx() { # push_idx <kline-index> — asserts price18, updates+1, lastAction
  local idx="$1" kline p18 before after n=0 hash now gap
  kline=$(python3 -c "import json;print(json.load(open('$KLINES'))[$idx])")
  p18=$(python3 -c "print($kline * 10**10)")
  now=$(date +%s)
  if [ "$LAST_PUSH_START" != "0" ]; then
    gap=$(( now - LAST_PUSH_START ))
    if [ "$gap" -lt 42 ]; then say "pacing sleep $((42 - gap))s (gap was ${gap}s)"; sleep $((42 - gap)); fi
  fi
  LAST_PUSH_START=$(date +%s)
  before=$(updates)
  [ "$before" != "READ_FAILED" ] || fail "updates read FAILED before push idx $idx"
  hash=$(send "$BASE_RPC" "$PRIVATE_KEY" "$ORACLE" "setPrice(address,uint256)" "$WETH" "$p18")
  [[ "$hash" =~ ^0x[0-9a-fA-F]{64}$ ]] || fail "push idx $idx send failed: $hash"
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
wait_rerisk() { local want="$1" n=0 got; got=$(reriskc); while [ "$got" != "$want" ] && [ $n -lt 40 ]; do sleep 3; got=$(reriskc); n=$((n+1)); done; [ "$got" = "$want" ] || fail "reriskCount stuck at $got, expected $want"; say "rerisk callback landed: reriskCount=$got"; }

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

say "=== RELEASE 7 AUG-STRETCH REHEARSAL START ==="
say "oracle=$ORACLE reactive=$REACTIVE swap=$SWAP vault=$VAULT"
[ "$(sha256sum "$KLINES" | awk '{print $1}')" = "$KLINES_SHA" ] || fail "klines file hash mismatch"
[ "$(updates)" = "0" ] || fail "reactive updates not 0 at start (stale set?)"
snap "initial"
[ "$(mshares)" = "0" ] || fail "vault not empty at start"

# --- User A: first deposit, before push 1 (1:1 expected) ---
user_deposit A 3000000000000000 3000000000000000
snap "after-A-deposit"

say "== Stage A: calm, updates 1-7 (expect HOLD x7, prot 0) =="
for idx in 280 281 282 283 284 285 286; do push_idx $idx; done
[ "$(prot)" = "0" ] || fail "unexpected protection during calm stage"
snap "stage-A-end"

say "== TRIM@8 (idx 287, \$2688.92) =="
push_idx 287
wait_prot 1
snap "after-TRIM8"
expect_managed "TRIM@8" 1500000000000000 4033380000000000000
user_deposit B 2000000000000000 2000000000000000
snap "after-B-deposit"

say "== updates 9-14 =="
for idx in 288 289 290 291 292 293; do push_idx $idx; done
say "== EXIT@15 (idx 294, \$2268.21) =="
push_idx 294
wait_prot 2
[ "$(cv "$VAULT" "closed()(bool)" "$BASE_RPC")" = "true" ] || fail "vault not closed after EXIT@15"
snap "after-EXIT15"
expect_managed "EXIT@15" 0 11972115000000000000
AHASH=$(send "$BASE_RPC" "$USER_A_KEY" "$VAULT" "redeem(uint256)" 1000000000000000)
[[ "$AHASH" =~ ^0x[0-9a-fA-F]{64}$ ]] || fail "A partial redeem failed: $AHASH"
say "USER A partial redeem 1000000000000000 shares: tx=$AHASH wethBal=$(bal "$WETH" "$USER_A_ADDRESS") musdcBal=$(bal "$MUSDC" "$USER_A_ADDRESS") sharesA=$(sharesof $USER_A_ADDRESS)"
snap "after-A-partial-redeem"
expect_managed "A-partial-redeem" 0 9577692000000000000

say "== update 16 (HOLD) =="
push_idx 295
say "== TRIM@17 no-op (idx 296, \$2325.44) =="
push_idx 296
wait_prot 3
snap "after-TRIM17-noop"
expect_noop "TRIM@17"
say "== updates 18-20 =="
for idx in 297 298 299; do push_idx $idx; done
say "== EXIT@21 no-op (idx 300, \$2228.21) =="
push_idx 300
wait_prot 4
snap "after-EXIT21-noop"
expect_noop "EXIT@21"
say "== updates 22-26 =="
for idx in 301 302 303 304 305; do push_idx $idx; done
say "== TRIM@27 no-op (idx 306, \$2374.41) =="
push_idx 306
wait_prot 5
snap "after-TRIM27-noop"
expect_noop "TRIM@27"
say "== updates 28-40 =="
for idx in 307 308 309 310 311 312 313 314 315 316 317 318 319; do push_idx $idx; done
say "== TRIM@41 no-op (idx 320, \$2460.51) =="
push_idx 320
wait_prot 6
snap "after-TRIM41-noop"
expect_noop "TRIM@41"
say "== updates 42-54 =="
for idx in 321 322 323 324 325 326 327 328 329 330 331 332 333; do push_idx $idx; done
say "== TRIM@55 no-op (idx 334, \$2475.40) =="
push_idx 334
wait_prot 7
snap "after-TRIM55-noop"
expect_noop "TRIM@55"
say "== updates 56-67 =="
for idx in 335 336 337 338 339 340 341 342 343 344 345 346; do push_idx $idx; done
say "== TRIM@68 no-op (idx 347, \$2473.01) =="
push_idx 347
wait_prot 8
snap "after-TRIM68-noop"
expect_noop "TRIM@68"
say "== updates 69-78 =="
for idx in 348 349 350 351 352 353 354 355 356 357; do push_idx $idx; done
say "== TRIM@79 no-op (idx 358, \$2356.46) — LAST NO-OP =="
push_idx 358
wait_prot 9
snap "after-TRIM79-noop"
expect_noop "TRIM@79"
# C deposits AFTER the last no-op: deposit re-arms closed=false.
user_deposit C 1500000000000000 1476217861255091
[ "$(cv "$VAULT" "closed()(bool)" "$BASE_RPC")" = "false" ] || fail "vault not re-armed after C deposit"
snap "after-C-deposit"
expect_managed "C-deposit" 1500000000000000 9577692000000000000

say "== updates 80-96 (HOLDs, no callbacks) =="
for idx in 359 360 361 362 363 364 365 366 367 368 369 370 371 372 373 374 375; do push_idx $idx; done
[ "$(prot)" = "9" ] || fail "unexpected callback during updates 80-96 (prot $(prot) != 9)"
snap "pre-RERISK"

say "== RERISK@97 tranche 1 (idx 376, \$2585.83) =="
push_idx 376
wait_prot 10
wait_rerisk 1
snap "after-RERISK97"
expect_managed "RERISK@97" 3351957011868529 4788846000000000000

say "== updates 98-101 =="
for idx in 377 378 379 380; do push_idx $idx; done
say "== RERISK_FINAL@102 tranche 2 (idx 381, \$2640.90) =="
push_idx 381
wait_prot 11
wait_rerisk 2
snap "after-RERISK-FINAL102"
expect_managed "RERISK_FINAL@102" 5165295646424930 0

say "== update 103 (idx 382, \$2707.67) — LAST PUSH =="
push_idx 382
[ "$(prot)" = "11" ] || fail "unexpected callback at update 103 (prot $(prot) != 11)"
snap "after-update-103"
say "== STOP: no update 104 is ever pushed =="

say "== Final redemption sequence (A, B, C redeemAll) =="
say "managed totals before sequence: risk=$(mrisk) safe=$(msafe) totalShares=$(mshares)"
for u in A B C; do
  addr=$(eval echo \$USER_${u}_ADDRESS); key=$(eval echo \$USER_${u}_KEY)
  h=$(send "$BASE_RPC" "$key" "$VAULT" "redeemAll()")
  [[ "$h" =~ ^0x[0-9a-fA-F]{64}$ ]] || fail "user $u redeemAll failed: $h"
  say "USER $u redeemAll tx=$h sharesAfter=$(sharesof $addr) wethBal=$(bal "$WETH" "$addr") musdcBal=$(bal "$MUSDC" "$addr")"
done
snap "final"
[ "$(mshares)" = "0" ] || fail "totalShares not 0 after final redemption"
[ "$(mrisk)" = "0" ] || fail "managedRisk not 0 after final redemption"
[ "$(msafe)" = "0" ] || fail "managedSafe not 0 after final redemption"
say "=== RELEASE 7 AUG-STRETCH REHEARSAL PUSHES COMPLETE ==="
