#!/usr/bin/env bash
# RELEASE 8 PRE-DRIVE PREP — run AFTER attack_release8_pre.sh, BEFORE the drive.
#   1. Dev redeems the 0.002 WETH seed (vault back to empty, design choreography
#      requires an empty vault at push 1 — same as the R7 live pre-drive correction).
#   2. Burner top-ups from dev: A +0.003 ETH (A holds 0.0004924 ETH, needs
#      0.003 to wrap its deposit), B +0.001 ETH (B holds 0.0019947 ETH,
#      short 0.0000053 of its 0.002 wrap). C needs none (0.0039947 ETH).
#   3. Pre-drive gates: brain updates 0 / lastAction 0 / balance 2.20,
#      vault totalShares 0 / managed 0/0 / closed false, desk 1,000 mUSDC,
#      flagship untouched, mirror prediction on file.
# Any failed expectation ABORTS (exit 1) with state preserved.
# Transcript: goal hidden_files/release8-prep.log.
# FLAGSHIP SET IS NEVER TOUCHED by this script.
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."
set -a; source .env.local; source "$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/vaultv5-rehearsal-burners.env"; set +a

BASE_RPC="https://sepolia.base.org"
LASNA_RPC="https://lasna-rpc.rnk.dev"
DEV="0x75c328F0354fFC73bee24F61F7166a33Bf90Bf94"
WETH="0x4200000000000000000000000000000000000006"
MUSDC="0x96E467Ff7958851d307D28118EBAAD333CAb85B2"
FLAGSHIP_BRAIN="0x37EeF5e3179E55c0e96E1528180B55Fa20DC150B"
FLAGSHIP_VAULT="0x108513e6439664fdeE9050e1ccc208e8c1b61441"
ORACLE="${R8_ORACLE:?R8_ORACLE not set}"
REACTIVE="${R8_REACTIVE:?R8_REACTIVE not set}"
SWAP="${R8_SWAP:?R8_SWAP not set}"
VAULT="${R8_VAULT:?R8_VAULT not set}"
LOG="${LOG:-$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/release8-prep.log}"
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
bal() { cast balance "$1" --rpc-url "$2" 2>/dev/null; }
send() { # send <rpc> <key> <to> <sig> [args...] -> tx hash or FAIL
  local rpc="$1" key="$2" to="$3" sig="$4"; shift 4
  local out h
  out=$(cast send "$to" "$sig" "$@" --rpc-url "$rpc" --private-key "$key" --json 2>/dev/null) || fail "send failed: $sig to $to"
  h=$(echo "$out" | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='0x1','status '+d['status'];print(d['transactionHash'])" 2>/dev/null) || fail "tx reverted: $sig to $to"
  echo "$h"
}

say "=== RELEASE 8 PRE-DRIVE PREP START ==="
say "flagship before: brain updates=$(cv "$FLAGSHIP_BRAIN" "updates()(uint256)" "$LASNA_RPC") lastAction=$(cv "$FLAGSHIP_BRAIN" "lastAction()(uint8)" "$LASNA_RPC") vault totalShares=$(cv "$FLAGSHIP_VAULT" "totalShares()(uint256)" "$BASE_RPC")"

# --- 1. Dev redeems the seed ---
[ "$(cv "$VAULT" "sharesOf(address)(uint256)" "$DEV" "$BASE_RPC")" = "2000000000000000" ] || fail "dev seed shares != 2e15 before redeem"
H=$(send "$BASE_RPC" "$PRIVATE_KEY" "$VAULT" "redeemAll()")
say "dev seed redeemAll tx=$H"
[ "$(cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC")" = "0" ] || fail "vault totalShares != 0 after seed redeem"
[ "$(cv "$VAULT" "managedRisk()(uint256)" "$BASE_RPC")" = "0" ] || fail "vault managedRisk != 0 after seed redeem"
[ "$(cv "$VAULT" "managedSafe()(uint256)" "$BASE_RPC")" = "0" ] || fail "vault managedSafe != 0 after seed redeem"
WETH_BACK=$(cast call "$WETH" "balanceOf(address)(uint256)" "$DEV" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}')
say "vault empty again; dev WETH balance now $WETH_BACK (seed principal back, minus nothing — redeem is exact)"

# --- 2. Burner top-ups ---
HA=$(cast send "$USER_A_ADDRESS" --value 3000000000000000 --rpc-url "$BASE_RPC" --private-key "$PRIVATE_KEY" --json 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='0x1';print(d['transactionHash'])") || fail "A top-up failed"
HB=$(cast send "$USER_B_ADDRESS" --value 1000000000000000 --rpc-url "$BASE_RPC" --private-key "$PRIVATE_KEY" --json 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='0x1';print(d['transactionHash'])") || fail "B top-up failed"
say "top-ups: A +0.003 ETH tx=$HA (A ETH now $(bal "$USER_A_ADDRESS" "$BASE_RPC")), B +0.001 ETH tx=$HB (B ETH now $(bal "$USER_B_ADDRESS" "$BASE_RPC")), C untouched ($(bal "$USER_C_ADDRESS" "$BASE_RPC"))"

# --- 3. Pre-drive gates ---
[ "$(cv "$REACTIVE" "updates()(uint256)" "$LASNA_RPC")" = "0" ] || fail "brain updates != 0 at drive start"
[ "$(cv "$REACTIVE" "lastAction()(uint8)" "$LASNA_RPC")" = "0" ] || fail "brain lastAction != 0 at drive start"
[ "$(bal "$REACTIVE" "$LASNA_RPC")" = "2200000000000000000" ] || fail "brain balance != 2.20 lREACT at drive start"
[ "$(cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC")" = "0" ] || fail "vault not empty at drive start"
[ "$(cv "$VAULT" "closed()(bool)" "$BASE_RPC")" = "false" ] || fail "vault closed at drive start"
[ "$(cast call "$MUSDC" "balanceOf(address)(uint256)" "$SWAP" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}')" = "1000000000000000000000" ] || fail "desk mUSDC != 1000 at drive start"
[ "$(cv "$SWAP" "priceStale()(bool)" "$BASE_RPC")" = "true" ] || fail "swap priceStale != true at drive start (no legitimate push has landed yet — all attack pushes reverted)"
say "pre-drive gates: brain 0/0/2.20, vault empty/open, desk 1000 mUSDC, swap still stale pre-first-push (first drive push clears it) — PASS"
say "flagship after: brain updates=$(cv "$FLAGSHIP_BRAIN" "updates()(uint256)" "$LASNA_RPC") lastAction=$(cv "$FLAGSHIP_BRAIN" "lastAction()(uint8)" "$LASNA_RPC") vault totalShares=$(cv "$FLAGSHIP_VAULT" "totalShares()(uint256)" "$BASE_RPC")"
say "=== RELEASE 8 PRE-DRIVE PREP COMPLETE — DRIVE MAY START ==="
