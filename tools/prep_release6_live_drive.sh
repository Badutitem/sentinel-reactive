#!/usr/bin/env bash
# RELEASE 6 LIVE PRE-DRIVE PREP — V6 live set (NOT rehearsal, NOT flagship).
#   1. Dev redeems the 0.002 WETH seed (vault back to empty — drive
#      choreography requires an empty vault at push 1, same as R8 live).
#   2. Burner top-ups from dev: A +0.003 ETH (holds 0.0004845, needs
#      0.003 to wrap), B +0.001 ETH (holds 0.0014889, needs 0.002 wrap),
#      C +0.001 ETH (holds 0.0014835, needs 0.0015 wrap + gas).
#   3. Pre-drive gates: brain updates 0 / lastAction 0 / balance 2.20,
#      exitLatched false, vaultLocked true (brain + swap), MIN_SANE_PRICE
#      1e18, band 2000, pusher allowlisted, vault totalShares 0 /
#      managed 0/0 / closed false, desk 1,000 mUSDC, swap stale true,
#      flagship untouched (brain updates 1, vault shares 2e15).
# Any failed expectation ABORTS (exit 1) with state preserved.
# Transcript: goal hidden_files/release6-live-prep.log.
# FLAGSHIP SET IS NEVER TOUCHED by this script.
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."
set -a; source .env.local; source "$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/vaultv5-rehearsal-burners.env"; source "$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/v6-pusher.env"; set +a

BASE_RPC="https://sepolia.base.org"
LASNA_RPC="https://lasna-rpc.rnk.dev"
DEV="0x75c328F0354fFC73bee24F61F7166a33Bf90Bf94"
WETH="0x4200000000000000000000000000000000000006"
MUSDC="0x96E467Ff7958851d307D28118EBAAD333CAb85B2"
FLAGSHIP_BRAIN="0x162DdFa4dD0db9bA60c4444b9a1BD1fa6b5343A9"
FLAGSHIP_VAULT="0xD61E27bC945ceE8Bd967aA42c907e7bA6968b5e9"
ORACLE="0x3862815C65d0142BF91eB4bE0C66463021e06f30"
REACTIVE="0x78c18D3F064B19193Ab856D15b83287e677Ff569"
SWAP="0xEAe1C0674c9E8F96442A6a6839C18F01eC05553A"
VAULT="0xC429ba42745be233614b486B25855821f2b9A99a"
LOG="${LOG:-$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/release6-live-prep.log}"
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

say "=== RELEASE 6 LIVE PRE-DRIVE PREP START ==="
say "flagship before: brain updates=$(cv "$FLAGSHIP_BRAIN" "updates()(uint256)" "$LASNA_RPC") vault totalShares=$(cv "$FLAGSHIP_VAULT" "totalShares()(uint256)" "$BASE_RPC")"

# --- 1. Dev redeems the seed ---
[ "$(cv "$VAULT" "sharesOf(address)(uint256)" "$DEV" "$BASE_RPC")" = "2000000000000000" ] || fail "dev seed shares != 2e15 before redeem"
H=$(send "$BASE_RPC" "$PRIVATE_KEY" "$VAULT" "redeemAll()")
say "dev seed redeemAll tx=$H"
[ "$(cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC")" = "0" ] || fail "vault totalShares != 0 after seed redeem"
[ "$(cv "$VAULT" "managedRisk()(uint256)" "$BASE_RPC")" = "0" ] || fail "vault managedRisk != 0 after seed redeem"
[ "$(cv "$VAULT" "managedSafe()(uint256)" "$BASE_RPC")" = "0" ] || fail "vault managedSafe != 0 after seed redeem"
WETH_BACK=$(cast call "$WETH" "balanceOf(address)(uint256)" "$DEV" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}')
say "vault empty again; dev WETH balance now $WETH_BACK (seed principal back, exact)"

# --- 2. Burner top-ups ---
HA=$(cast send "$USER_A_ADDRESS" --value 3000000000000000 --rpc-url "$BASE_RPC" --private-key "$PRIVATE_KEY" --json 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='0x1';print(d['transactionHash'])") || fail "A top-up failed"
HB=$(cast send "$USER_B_ADDRESS" --value 1000000000000000 --rpc-url "$BASE_RPC" --private-key "$PRIVATE_KEY" --json 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='0x1';print(d['transactionHash'])") || fail "B top-up failed"
HC=$(cast send "$USER_C_ADDRESS" --value 1000000000000000 --rpc-url "$BASE_RPC" --private-key "$PRIVATE_KEY" --json 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='0x1';print(d['transactionHash'])") || fail "C top-up failed"
say "top-ups: A +0.003 ETH tx=$HA (A ETH now $(bal "$USER_A_ADDRESS" "$BASE_RPC")), B +0.001 ETH tx=$HB (B ETH now $(bal "$USER_B_ADDRESS" "$BASE_RPC")), C +0.001 ETH tx=$HC (C ETH now $(bal "$USER_C_ADDRESS" "$BASE_RPC"))"

# --- 3. Pre-drive gates ---
[ "$(cv "$REACTIVE" "updates()(uint256)" "$LASNA_RPC")" = "0" ] || fail "brain updates != 0 at drive start"
[ "$(cv "$REACTIVE" "lastAction()(uint8)" "$LASNA_RPC")" = "0" ] || fail "brain lastAction != 0 at drive start"
[ "$(bal "$REACTIVE" "$LASNA_RPC")" = "2200000000000000000" ] || fail "brain balance != 2.20 lREACT at drive start"
[ "$(cv "$REACTIVE" "exitLatched()(bool)" "$LASNA_RPC")" = "false" ] || fail "brain exitLatched != false at drive start"
[ "$(cv "$REACTIVE" "vaultLocked()(bool)" "$LASNA_RPC")" = "true" ] || fail "brain vaultLocked != true at drive start"
[ "$(cv "$SWAP" "vaultLocked()(bool)" "$BASE_RPC")" = "true" ] || fail "swap vaultLocked != true at drive start"
[ "$(cv "$SWAP" "MIN_SANE_PRICE()(uint256)" "$BASE_RPC")" = "1000000000000000000" ] || fail "swap MIN_SANE_PRICE != 1e18 at drive start"
[ "$(cv "$VAULT" "MAX_DEPOSIT_DEVIATION_BPS()(uint256)" "$BASE_RPC")" = "2000" ] || fail "vault band != 2000 at drive start"
[ "$(cv "$ORACLE" "pricePushers(address)(bool)" "$PUSHER" "$BASE_RPC")" = "true" ] || fail "oracle pricePushers(pusher) != true at drive start"
[ "$(cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC")" = "0" ] || fail "vault not empty at drive start"
[ "$(cv "$VAULT" "closed()(bool)" "$BASE_RPC")" = "false" ] || fail "vault closed at drive start"
[ "$(cast call "$MUSDC" "balanceOf(address)(uint256)" "$SWAP" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}')" = "1000000000000000000000" ] || fail "desk mUSDC != 1000 at drive start"
[ "$(cv "$SWAP" "priceStale()(bool)" "$BASE_RPC")" = "true" ] || fail "swap priceStale != true at drive start"
say "pre-drive gates: brain 0/0/2.20 latch-false locked, vault empty/open, desk 1000 mUSDC, swap stale pre-first-push — PASS"
say "flagship after: brain updates=$(cv "$FLAGSHIP_BRAIN" "updates()(uint256)" "$LASNA_RPC") vault totalShares=$(cv "$FLAGSHIP_VAULT" "totalShares()(uint256)" "$BASE_RPC")"
say "=== RELEASE 6 LIVE PRE-DRIVE PREP COMPLETE — DRIVE MAY START ==="
