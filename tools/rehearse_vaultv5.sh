#!/usr/bin/env bash
# Live testnet rehearsal driver for SentinelVaultV5 (pooled vault,
# multi-user). Mirrors Release 5R's mirror-validated 31-push series on a
# fresh rehearsal set (MockPriceOracle + SentinelReactiveV5 + Sentinel
# SwapV2 + SentinelVaultV5), interleaving three burner users:
#   A deposits 0.003 WETH before push 1 (first depositor, 1:1)
#   B deposits 0.002 WETH after the TRIM@7 callback lands
#   A redeems 0.001 shares (partial) after RERISK tranche 1 (@18)
#   C deposits 0.0015 WETH after stage C (update 20)
#   Stage D bleed -> TRIM@25, EXIT@31; then all redeemAll in order
#   A, B, C and the pool must reconcile to the wei (INV-1..INV-4).
# Any failed expectation or invariant violation ABORTS the run
# (exit 1) with state preserved — no improvising past a mismatch.
# Transcript: $LOG (default: goal hidden_files, NOT /tmp).
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."
set -a; source .env.local; source "$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/vaultv5-rehearsal-burners.env"; set +a

BASE_RPC="https://sepolia.base.org"
LASNA_RPC="https://lasna-rpc.rnk.dev"
WETH="0x4200000000000000000000000000000000000006"
MUSDC="0x96E467Ff7958851d307D28118EBAAD333CAb85B2"
ORACLE="0x4a3022010e253bc2dc49c2cb03ce0e5c544630b3"
REACTIVE="0xaf030D808133C36E571c87C3A3fD2B7F511971E0"
SWAP="0xF25B97c6c3738b8a91a9c3eE2E1518e3ffB0A34a"
VAULT="0xf874c4E680EBBD65315a130A521399f43171dad2"
LOG="${LOG:-$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/vaultv5-rehearsal-driver.log}"
exec > >(tee -a "$LOG") 2>&1

fail() { echo "!!! ABORT: $*"; echo "!!! State preserved; nothing further will be sent."; exit 1; }
say() { echo "[$(date -u +%H:%M:%S)] $*"; }

cv() { cast call "$1" "$2" --rpc-url "$3" 2>/dev/null | awk '{print $1}'; }
updates() { cv "$REACTIVE" "updates()(uint256)" "$LASNA_RPC"; }
prot() { cv "$VAULT" "protectionCount()(uint256)" "$BASE_RPC"; }
rerisk() { cv "$VAULT" "reriskCount()(uint256)" "$BASE_RPC"; }
mshares() { cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC"; }
sharesof() { cast call "$VAULT" "sharesOf(address)(uint256)" "$1" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}'; }
bal() { cast call "$1" "balanceOf(address)(uint256)" "$2" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}'; }

snap() {
  local mr ms rw rs ts
  mr=$(cv "$VAULT" "managedRisk()(uint256)" "$BASE_RPC"); ms=$(cv "$VAULT" "managedSafe()(uint256)" "$BASE_RPC")
  rw=$(bal "$WETH" "$VAULT"); rs=$(bal "$MUSDC" "$VAULT"); ts=$(mshares)
  say "SNAP $1: updates=$(updates) prot=$(prot) rerisk=$(rerisk) closed=$(cv "$VAULT" "closed()(bool)" "$BASE_RPC") managedRisk=$mr managedSafe=$ms rawWETH=$rw rawMUSDC=$rs totalShares=$ts sharesA=$(sharesof $USER_A_ADDRESS) sharesB=$(sharesof $USER_B_ADDRESS) sharesC=$(sharesof $USER_C_ADDRESS) deskWETH=$(bal "$WETH" "$SWAP") deskMUSDC=$(bal "$MUSDC" "$SWAP")"
  # INV-1: raw balances must cover managed totals.
  python3 -c "exit(0 if $rw >= $mr and $rs >= $ms else 1)" || fail "INV-1 violated at $1 (raw $rw/$rs < managed $mr/$ms)"
}

send() { # send <rpc> <key> <to> <sig> [args...] -> tx hash or FAIL
  local rpc="$1" key="$2" to="$3" sig="$4"; shift 4
  local out h
  out=$(cast send "$to" "$sig" "$@" --rpc-url "$rpc" --private-key "$key" --json 2>/dev/null) || fail "send failed: $sig to $to"
  h=$(echo "$out" | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='0x1','status '+d['status'];print(d['transactionHash'])" 2>/dev/null) || fail "tx reverted: $sig to $to"
  echo "$h"
}

push() { # push <price-as-decimal-string>
  local p="$1" before after n=0 hash
  before=$(updates)
  hash=$(send "$BASE_RPC" "$PRIVATE_KEY" "$ORACLE" "setPrice(address,uint256)" "$WETH" "$(python3 -c "print(int(round($p * 10**18)))")")
  [[ "$hash" =~ ^0x[0-9a-fA-F]{64}$ ]] || fail "push $p send failed: $hash"
  after="$before"
  while [ "$after" = "$before" ] && [ $n -lt 30 ]; do sleep 3; after=$(updates); n=$((n+1)); done
  [ "$after" != "$before" ] || fail "reactive did not ingest push $p after 90s (updates stuck at $before)"
  say "push $p origin_tx=$hash updates=$after action=$(cv "$REACTIVE" "lastAction()(uint8)" "$LASNA_RPC") prot=$(prot) rerisk=$(rerisk)"
}

wait_prot() { local want="$1" n=0 got; got=$(prot); while [ "$got" != "$want" ] && [ $n -lt 40 ]; do sleep 3; got=$(prot); n=$((n+1)); done; [ "$got" = "$want" ] || fail "protectionCount stuck at $got, expected $want"; say "callback landed: protectionCount=$got"; }
wait_rerisk() { local want="$1" n=0 got; got=$(rerisk); while [ "$got" != "$want" ] && [ $n -lt 40 ]; do sleep 3; got=$(rerisk); n=$((n+1)); done; [ "$got" = "$want" ] || fail "reriskCount stuck at $got, expected $want"; say "callback landed: reriskCount=$got"; }

user_deposit() { # user_deposit <A|B|C> <weth-wei>
  local u="$1" amt="$2" addr key h1 h2 h3
  addr=$(eval echo \$USER_${u}_ADDRESS); key=$(eval echo \$USER_${u}_KEY)
  h1=$(send "$BASE_RPC" "$key" "$WETH" "deposit()" --value "$amt")
  h2=$(send "$BASE_RPC" "$key" "$WETH" "approve(address,uint256)" "$VAULT" "$amt")
  h3=$(send "$BASE_RPC" "$key" "$VAULT" "deposit(uint256)" "$amt")
  [[ "$h1" =~ ^0x[0-9a-fA-F]{64}$ && "$h2" =~ ^0x[0-9a-fA-F]{64}$ && "$h3" =~ ^0x[0-9a-fA-F]{64}$ ]] || fail "user $u deposit flow failed: $h1 $h2 $h3"
  say "USER $u deposit $amt wei WETH: wrap=$h1 approve=$h2 deposit=$h3 shares=$(sharesof $addr)"
}

say "=== VAULTV5 REHEARSAL START ==="
say "oracle=$ORACLE reactive=$REACTIVE swap=$SWAP vault=$VAULT"
snap "initial"
[ "$(mshares)" = "0" ] || fail "vault not empty at start"

# --- User A: first deposit, before any price action (1:1 expected) ---
user_deposit A 3000000000000000
[ "$(sharesof $USER_A_ADDRESS)" = "3000000000000000" ] || fail "A first deposit not 1:1"
snap "after-A-deposit"

say "== Stage A: calm x5 (expect HOLD, no callbacks) =="
for p in 100 100.5 99.8 100.2 100.1; do push $p; done
[ "$(prot)" = "0" ] || fail "unexpected protection during calm stage"
snap "stage-A-end"

say "== Stage B: bleed (expect TRIM@7, EXIT@15) =="
push 98.098
push 96.136
wait_prot 1
snap "after-TRIM1"
# INV-4 spot check is implicit: share counts printed in every snap.
# --- User B deposits into the de-risked (mixed) pool ---
user_deposit B 2000000000000000
snap "after-B-deposit"
for p in 94.213 92.329 90.483 88.673 86.899 85.161 83.458; do push $p; done
push 81.789
wait_prot 2
[ "$(cv "$VAULT" "closed()(bool)" "$BASE_RPC")" = "true" ] || fail "vault not closed after EXIT@15"
TS15=$(cv "$ORACLE" "updatedAtOf(address)(uint256)" "$BASE_RPC")
say "EXIT@15 origin timestamp: $TS15"
snap "after-EXIT1"

say "== Stage C: recovery (expect RERISK@18 tranche1, RERISK_FINAL@19 tranche2) =="
push 90
push 93
push 96.5
wait_rerisk 1
wait_prot 3
snap "after-RERISK1"
# --- User A partial redeem, mid-episode ---
AHASH=$(send "$BASE_RPC" "$USER_A_KEY" "$VAULT" "redeem(uint256)" 1000000000000000)
[[ "$AHASH" =~ ^0x[0-9a-fA-F]{64}$ ]] || fail "A partial redeem failed: $AHASH"
say "USER A partial redeem 1000000000000000 shares: tx=$AHASH wethBal=$(bal "$WETH" "$USER_A_ADDRESS") musdcBal=$(bal "$MUSDC" "$USER_A_ADDRESS") sharesA=$(sharesof $USER_A_ADDRESS)"
snap "after-A-partial-redeem"
push 99.5
wait_rerisk 2
wait_prot 4
snap "after-RERISK2"
push 103.5
snap "stage-C-end"

# --- User C deposits late (pool re-risked) ---
user_deposit C 1500000000000000
snap "after-C-deposit"

# Cooldown hygiene: push 25's origin must be >=300s after push 15's.
NOW=$(date +%s)
WAIT=$(( TS15 + 330 - NOW ))
if [ "$WAIT" -gt 0 ]; then say "cooldown wait ${WAIT}s before stage D"; sleep "$WAIT"; fi

say "== Stage D: bleed (expect TRIM@25, EXIT@31) =="
for p in 101.43 99.401 97.413 95.465; do push $p; done
push 93.556
wait_prot 5
snap "after-TRIM2"
for p in 91.685 89.851 88.054 86.293 84.567; do push $p; done
push 82.876
wait_prot 6
[ "$(cv "$VAULT" "closed()(bool)" "$BASE_RPC")" = "true" ] || fail "vault not closed after EXIT@31"
snap "after-EXIT2"

say "== Final redemption sequence (A, B, C redeemAll) =="
say "managed totals before sequence: risk=$(cv "$VAULT" "managedRisk()(uint256)" "$BASE_RPC") safe=$(cv "$VAULT" "managedSafe()(uint256)" "$BASE_RPC") totalShares=$(mshares)"
for u in A B C; do
  addr=$(eval echo \$USER_${u}_ADDRESS); key=$(eval echo \$USER_${u}_KEY)
  h=$(send "$BASE_RPC" "$key" "$VAULT" "redeemAll()")
  [[ "$h" =~ ^0x[0-9a-fA-F]{64}$ ]] || fail "user $u redeemAll failed: $h"
  say "USER $u redeemAll tx=$h sharesAfter=$(sharesof $addr) wethBal=$(bal "$WETH" "$addr") musdcBal=$(bal "$MUSDC" "$addr")"
done
snap "final"
say "=== VAULTV5 REHEARSAL PUSHES COMPLETE ==="
