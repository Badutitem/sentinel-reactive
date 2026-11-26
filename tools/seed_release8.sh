#!/usr/bin/env bash
# RELEASE 8 owner seed (public flow, dev wallet) — mirrors R7 live deploy §3.
# Wrap 0.002 ETH -> WETH, approve vault, deposit; shares must read 1:1.
# Runs AFTER deploy_release8.sh, BEFORE attack_release8_pre.sh.
# Any failed expectation ABORTS (exit 1) with state preserved.
# Transcript: goal hidden_files/release8-seed.log.
# FLAGSHIP SET IS NEVER TOUCHED by this script.
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."
set -a; source .env.local; set +a

BASE_RPC="https://sepolia.base.org"
LASNA_RPC="https://lasna-rpc.rnk.dev"
DEV="0x75c328F0354fFC73bee24F61F7166a33Bf90Bf94"
WETH="0x4200000000000000000000000000000000000006"
FLAGSHIP_BRAIN="0x37EeF5e3179E55c0e96E1528180B55Fa20DC150B"
FLAGSHIP_VAULT="0x108513e6439664fdeE9050e1ccc208e8c1b61441"
VAULT="${R8_VAULT:?R8_VAULT not set}"
LOG="${LOG:-$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/release8-seed.log}"
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

say "=== RELEASE 8 SEED START ==="
say "flagship before: brain updates=$(cv "$FLAGSHIP_BRAIN" "updates()(uint256)" "$LASNA_RPC") lastAction=$(cv "$FLAGSHIP_BRAIN" "lastAction()(uint8)" "$LASNA_RPC") vault totalShares=$(cv "$FLAGSHIP_VAULT" "totalShares()(uint256)" "$BASE_RPC")"
[ "$(cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC")" = "0" ] || fail "vault not empty before seed"

H1=$(send "$BASE_RPC" "$PRIVATE_KEY" "$WETH" "deposit()" --value 2000000000000000)
H2=$(send "$BASE_RPC" "$PRIVATE_KEY" "$WETH" "approve(address,uint256)" "$VAULT" 2000000000000000)
H3=$(send "$BASE_RPC" "$PRIVATE_KEY" "$VAULT" "deposit(uint256)" 2000000000000000)
say "seed: wrap=$H1 approve=$H2 deposit=$H3"
SH=$(cv "$VAULT" "sharesOf(address)(uint256)" "$DEV" "$BASE_RPC")
[ "$SH" = "2000000000000000" ] || fail "dev shares $SH != 2000000000000000 (not 1:1)"
say "seed verified: sharesOf(dev)=$SH (1:1), totalShares=$(cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC") managedRisk=$(cv "$VAULT" "managedRisk()(uint256)" "$BASE_RPC") managedSafe=$(cv "$VAULT" "managedSafe()(uint256)" "$BASE_RPC")"
say "flagship after: brain updates=$(cv "$FLAGSHIP_BRAIN" "updates()(uint256)" "$LASNA_RPC") lastAction=$(cv "$FLAGSHIP_BRAIN" "lastAction()(uint8)" "$LASNA_RPC") vault totalShares=$(cv "$FLAGSHIP_VAULT" "totalShares()(uint256)" "$BASE_RPC")"
say "=== RELEASE 8 SEED COMPLETE ==="
