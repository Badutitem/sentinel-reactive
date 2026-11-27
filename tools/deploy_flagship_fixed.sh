#!/usr/bin/env bash
# FLAGSHIP MIGRATION deploy driver — fresh set from the FIXED code (FIX-DESIGN.md).
#   1. ChainlinkPriceAdapter (Base Sepolia, FRESH — N1: the old flagship
#      adapter has NO priceUpdatedAt, so the fixed swap cannot use it)
#      feed 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1, WETH,
#      deadbandBps 10, minInterval 60, heartbeat 3600 (AH-1 fix: NOT 300 —
#      permissionless sync + 300 s heartbeat let a stranger drain the
#      brain in ~32.6 h of flat-price pokes; 3600 s stretches that to
#      ~16 days, inside the liveness watch's alarm window),
#      maxStaleness 3600, priceScaleFactor 1e10 (computed from feed decimals).
#   2. SentinelSwapV2 (Base Sepolia, priceSource = fresh adapter)
#   3. SentinelReactiveV5 (Lasna, Chainlink origin = fresh adapter,
#      2.20 lREACT attached)
#   4. SentinelVaultV5 (Base Sepolia)
#   5. swap.setVault + reactive.setVault (verified by reads)
#   6. desk seeded exactly 1,000 mUSDC; vault billing 0.0001 ETH
# Faucet round is a separate pre-step; this script GATES on dev Lasna
# >= 2.40 lREACT before any deploy (2.20 attach + ~0.18 deploy gas).
# The fresh adapter is NOT synced here and NO deposit is made here:
# sync + seed are step (d), AFTER the old-flagship redemption (step c),
# because the fresh adapter's lastEmittedAt is 0 until its first sync
# and the seed deposit would revert StalePrice before then.
# Any failed expectation ABORTS (exit 1) with state preserved.
# Transcript: goal hidden_files/flagship-migration-deploy.log.
# R7 / R8 LIVE SETS ARE NEVER TOUCHED by this script (gated by reads
# before and after). The OLD flagship set is not touched either, except
# by the reads that confirm it is unchanged.
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."
set -a; source .env.local; set +a

BASE_RPC="https://sepolia.base.org"
LASNA_RPC="https://lasna-rpc.rnk.dev"
DEV="0x75c328F0354fFC73bee24F61F7166a33Bf90Bf94"
WETH="0x4200000000000000000000000000000000000006"
MUSDC="0x96E467Ff7958851d307D28118EBAAD333CAb85B2"
PROXY="0x476F44b11F5C942c58f4c8E3d0300E5710743585"
FEED="0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1"
OLD_ADAPTER="0xAb9c7a5178B444cd1C1fD705e5eBeCf4b9A1C25F"
FLAGSHIP_BRAIN="0x37EeF5e3179E55c0e96E1528180B55Fa20DC150B"
FLAGSHIP_VAULT="0x108513e6439664fdeE9050e1ccc208e8c1b61441"
R7_BRAIN="0x31414A31674d1E138C0Dce0FA04828229DE22FC9"
R7_VAULT="0xF2Fda1aCEb36a95136eCDA6707C7CDc96D105068"
R8_BRAIN="0x2C1d278d31d52Ec8405cF33E319ba0eB8C6b0d1F"
R8_VAULT="0x86b551AF1D8A5c0c2767Bf8Bb53F1F8bAeC74e18"
LOG="${LOG:-$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/flagship-migration-deploy.log}"
exec > >(tee -a "$LOG") 2>&1

fail() { echo "!!! ABORT: $*"; echo "!!! State preserved; nothing further will be sent."; exit 1; }
say() { echo "[$(date -u +%H:%M:%S)] $*"; }

cv() { # cv <addr> <sig> [args...] <rpc> — last arg is always the RPC URL
  local addr="$1" sig="$2"; shift 2
  local rpc="${@: -1}" nargs=$(($# - 1)) args=()
  if [ "$nargs" -gt 0 ]; then args=("${@:1:$nargs}"); fi
  cast call "$addr" "$sig" "${args[@]}" --rpc-url "$rpc" 2>/dev/null | awk '{print $1}'
}
bal() { cast balance "$1" --rpc-url "$2" 2>/dev/null; }

create() { # create <rpc> <contract> [forge-create args...] -> echoes "addr txhash"
  local rpc="$1" contract="$2"; shift 2
  local out
  out=$(forge create "$contract" --rpc-url "$rpc" --private-key "$PRIVATE_KEY" --broadcast --json "$@" 2>/dev/null) \
    || fail "forge create $contract failed"
  echo "$out" | python3 -c "import sys,json;d=json.load(sys.stdin);a=d.get('deployedTo') or d.get('contractAddress');h=d.get('transactionHash');assert a and h;print(a,h)" 2>/dev/null \
    || fail "could not parse forge create output for $contract: $out"
}

send() { # send <rpc> <to> <sig> [args...] -> tx hash or FAIL (dev key)
  local rpc="$1" to="$2" sig="$3"; shift 3
  local out h
  out=$(cast send "$to" "$sig" "$@" --rpc-url "$rpc" --private-key "$PRIVATE_KEY" --json 2>/dev/null) || fail "send failed: $sig to $to"
  h=$(echo "$out" | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='0x1','status '+d['status'];print(d['transactionHash'])" 2>/dev/null) || fail "tx reverted: $sig to $to"
  echo "$h"
}

say "=== FLAGSHIP MIGRATION DEPLOY START ==="
DEVBASE=$(bal "$DEV" "$BASE_RPC")
DEVLASNA=$(bal "$DEV" "$LASNA_RPC")
say "preflight: dev BaseSep=$DEVBASE dev Lasna=$DEVLASNA"
say "preflight old flagship: brain updates=$(cv "$FLAGSHIP_BRAIN" "updates()(uint256)" "$LASNA_RPC") lastAction=$(cv "$FLAGSHIP_BRAIN" "lastAction()(uint8)" "$LASNA_RPC") vault totalShares=$(cv "$FLAGSHIP_VAULT" "totalShares()(uint256)" "$BASE_RPC")"
say "preflight R7: brain updates=$(cv "$R7_BRAIN" "updates()(uint256)" "$LASNA_RPC") vault totalShares=$(cv "$R7_VAULT" "totalShares()(uint256)" "$BASE_RPC")"
say "preflight R8: brain updates=$(cv "$R8_BRAIN" "updates()(uint256)" "$LASNA_RPC") vault totalShares=$(cv "$R8_VAULT" "totalShares()(uint256)" "$BASE_RPC")"
python3 -c "exit(0 if $DEVBASE >= 10000000000000000 else 1)" || fail "dev Base Sepolia balance below 0.01 ETH"
python3 -c "exit(0 if $DEVLASNA >= 2400000000000000000 else 1)" || fail "FAUCET GATE: dev Lasna $DEVLASNA < 2.40 lREACT — deploy does not start"
[ "$(cv "$FLAGSHIP_BRAIN" "updates()(uint256)" "$LASNA_RPC")" = "4" ] || fail "old flagship brain updates != 4 (step-a state drift)"
[ "$(cv "$FLAGSHIP_VAULT" "totalShares()(uint256)" "$BASE_RPC")" = "2300000000000000" ] || fail "old flagship vault totalShares != 2.3e15 (step-a state drift)"

# --- 1. Fresh ChainlinkPriceAdapter (N1; heartbeat 3600 per AH-1) ---
# Resume: MIG_ADAPTER set reuses an already-deployed adapter.
if [ -n "${MIG_ADAPTER:-}" ]; then
  ADAPTER="$MIG_ADAPTER"; ADAPTER_TX="(pre-deployed)"
  say "ADAPTER reused: $ADAPTER"
else
  read ADAPTER ADAPTER_TX <<< "$(create "$BASE_RPC" src/ChainlinkPriceAdapter.sol:ChainlinkPriceAdapter --constructor-args "$FEED" "$WETH" 10 60 3600 3600)"
  say "ADAPTER deployed: $ADAPTER tx=$ADAPTER_TX"
fi
[ "$(cv "$ADAPTER" "feed()(address)" "$BASE_RPC" | tr 'A-F' 'a-f')" = "$(echo "$FEED" | tr 'A-F' 'a-f')" ] || fail "adapter feed mismatch"
[ "$(cv "$ADAPTER" "token()(address)" "$BASE_RPC" | tr 'A-F' 'a-f')" = "$(echo "$WETH" | tr 'A-F' 'a-f')" ] || fail "adapter token mismatch"
[ "$(cv "$ADAPTER" "deadbandBps()(uint256)" "$BASE_RPC")" = "10" ] || fail "adapter deadbandBps != 10"
[ "$(cv "$ADAPTER" "minInterval()(uint256)" "$BASE_RPC")" = "60" ] || fail "adapter minInterval != 60"
[ "$(cv "$ADAPTER" "heartbeat()(uint256)" "$BASE_RPC")" = "3600" ] || fail "adapter heartbeat != 3600 (AH-1 fix)"
[ "$(cv "$ADAPTER" "maxStaleness()(uint256)" "$BASE_RPC")" = "3600" ] || fail "adapter maxStaleness != 3600"
[ "$(cv "$ADAPTER" "priceScaleFactor()(uint256)" "$BASE_RPC")" = "10000000000" ] || fail "adapter priceScaleFactor != 1e10"
[ "$(cv "$ADAPTER" "lastPrice()(uint256)" "$BASE_RPC")" = "0" ] || fail "adapter lastPrice not 0 at birth"
[ "$(cv "$ADAPTER" "lastEmittedAt()(uint256)" "$BASE_RPC")" = "0" ] || fail "adapter lastEmittedAt not 0 at birth"
[ "$(cv "$ADAPTER" "priceUpdatedAt(address)(uint256)" "$WETH" "$BASE_RPC")" = "0" ] || fail "adapter priceUpdatedAt not 0 at birth (N1 read-back)"

# --- 2. Swap desk (vault = 0, wired later; priceSource = fresh adapter) ---
read SWAP SWAP_TX <<< "$(create "$BASE_RPC" src/SentinelSwapV2.sol:SentinelSwapV2 --constructor-args "$WETH" "$MUSDC" "$ADAPTER" 0x0000000000000000000000000000000000000000)"
say "SWAP deployed: $SWAP tx=$SWAP_TX"
[ "$(cv "$SWAP" "priceSource()(address)" "$BASE_RPC" | tr 'A-F' 'a-f')" = "$(echo "$ADAPTER" | tr 'A-F' 'a-f')" ] || fail "swap priceSource mismatch"
[ "$(cv "$SWAP" "MAX_PRICE_AGE()(uint256)" "$BASE_RPC")" = "3600" ] || fail "swap MAX_PRICE_AGE != 3600"
[ "$(cv "$SWAP" "priceStale()(bool)" "$BASE_RPC")" = "true" ] || fail "swap priceStale != true pre-sync (never-pushed source must read stale)"

# --- 3. Brain on Lasna, Chainlink origin = fresh adapter, 2.20 lREACT attached ---
read REACTIVE REACTIVE_TX <<< "$(create "$LASNA_RPC" src/SentinelReactiveV5.sol:SentinelReactiveV5 --value 2200000000000000000 --constructor-args 84532 "$ADAPTER" "$WETH" 84532 300)"
say "REACTIVE deployed: $REACTIVE tx=$REACTIVE_TX balance=$(bal "$REACTIVE" "$LASNA_RPC")"
[ "$(cv "$REACTIVE" "oracle()(address)" "$LASNA_RPC" | tr 'A-F' 'a-f')" = "$(echo "$ADAPTER" | tr 'A-F' 'a-f')" ] || fail "reactive oracle mismatch"
[ "$(cv "$REACTIVE" "updates()(uint256)" "$LASNA_RPC")" = "0" ] || fail "reactive updates not 0 at birth"
[ "$(cv "$FLAGSHIP_BRAIN" "oracle()(address)" "$LASNA_RPC" | tr 'A-F' 'a-f')" = "$(echo "$OLD_ADAPTER" | tr 'A-F' 'a-f')" ] || fail "old flagship brain oracle changed (expected old adapter)"
[ "$(cv "$FLAGSHIP_BRAIN" "oracle()(address)" "$LASNA_RPC" | tr 'A-F' 'a-f')" != "$(echo "$ADAPTER" | tr 'A-F' 'a-f')" ] || fail "old flagship brain now points at fresh adapter"

# --- 4. VaultV5 ---
read VAULT VAULT_TX <<< "$(create "$BASE_RPC" src/SentinelVaultV5.sol:SentinelVaultV5 --constructor-args "$PROXY" "$REACTIVE" "$WETH" "$MUSDC" "$SWAP")"
say "VAULT deployed: $VAULT tx=$VAULT_TX"
[ "$(cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC")" = "0" ] || fail "vault totalShares not 0 at birth"
[ "$(cv "$VAULT" "lastSettledPrice()(uint256)" "$BASE_RPC")" = "0" ] || fail "vault lastSettledPrice not 0 at birth"

# --- 5. Wiring ---
H=$(send "$BASE_RPC" "$SWAP" "setVault(address)" "$VAULT"); say "swap.setVault tx=$H"
[ "$(cv "$SWAP" "vault()(address)" "$BASE_RPC" | tr 'A-F' 'a-f')" = "$(echo "$VAULT" | tr 'A-F' 'a-f')" ] || fail "swap vault mismatch after setVault"
H=$(send "$LASNA_RPC" "$REACTIVE" "setVault(address)" "$VAULT"); say "reactive.setVault tx=$H"
[ "$(cv "$REACTIVE" "vault()(address)" "$LASNA_RPC" | tr 'A-F' 'a-f')" = "$(echo "$VAULT" | tr 'A-F' 'a-f')" ] || fail "reactive vault mismatch after setVault"
# Vault-side wiring read-backs (callback sender + swap pointer, all in-set).
[ "$(cv "$VAULT" "swap()(address)" "$BASE_RPC" | tr 'A-F' 'a-f')" = "$(echo "$SWAP" | tr 'A-F' 'a-f')" ] || fail "vault swap mismatch"
[ "$(cv "$VAULT" "_CALLBACK_SENDER()(address)" "$BASE_RPC" | tr 'A-F' 'a-f')" = "$(echo "$REACTIVE" | tr 'A-F' 'a-f')" ] || fail "vault _CALLBACK_SENDER mismatch"

# --- 6. Seed desk exactly 1,000 mUSDC + vault billing 0.0001 ETH ---
H=$(send "$BASE_RPC" "$MUSDC" "mint(address,uint256)" "$SWAP" 1000000000000000000000); say "desk seed mint tx=$H"
[ "$(cast call "$MUSDC" "balanceOf(address)(uint256)" "$SWAP" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}')" = "1000000000000000000000" ] || fail "desk mUSDC balance != 1000e18 after seed"
H=$(cast send "$VAULT" --value 100000000000000 --rpc-url "$BASE_RPC" --private-key "$PRIVATE_KEY" --json 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='0x1';print(d['transactionHash'])" 2>/dev/null) || fail "vault billing fund failed"
say "vault billing fund tx=$H vaultETH=$(bal "$VAULT" "$BASE_RPC")"

say "MIGRATION_ADDRESSES adapter=$ADAPTER swap=$SWAP reactive=$REACTIVE vault=$VAULT"
say "MIGRATION_TXS adapter=$ADAPTER_TX swap=$SWAP_TX reactive=$REACTIVE_TX vault=$VAULT_TX"
say "post: dev BaseSep=$(bal "$DEV" "$BASE_RPC") dev Lasna=$(bal "$DEV" "$LASNA_RPC") brain Lasna=$(bal "$REACTIVE" "$LASNA_RPC")"
say "post old flagship: brain updates=$(cv "$FLAGSHIP_BRAIN" "updates()(uint256)" "$LASNA_RPC") lastAction=$(cv "$FLAGSHIP_BRAIN" "lastAction()(uint8)" "$LASNA_RPC") vault totalShares=$(cv "$FLAGSHIP_VAULT" "totalShares()(uint256)" "$BASE_RPC")"
say "post R7: brain updates=$(cv "$R7_BRAIN" "updates()(uint256)" "$LASNA_RPC") vault totalShares=$(cv "$R7_VAULT" "totalShares()(uint256)" "$BASE_RPC")"
say "post R8: brain updates=$(cv "$R8_BRAIN" "updates()(uint256)" "$LASNA_RPC") vault totalShares=$(cv "$R8_VAULT" "totalShares()(uint256)" "$BASE_RPC")"
[ "$(cv "$R7_BRAIN" "updates()(uint256)" "$LASNA_RPC")" = "56" ] || fail "R7 brain updates changed"
[ "$(cv "$R8_BRAIN" "updates()(uint256)" "$LASNA_RPC")" = "57" ] || fail "R8 brain updates changed"
[ "$(cv "$R7_VAULT" "totalShares()(uint256)" "$BASE_RPC")" = "0" ] || fail "R7 vault totalShares changed"
[ "$(cv "$R8_VAULT" "totalShares()(uint256)" "$BASE_RPC")" = "0" ] || fail "R8 vault totalShares changed"
say "=== FLAGSHIP MIGRATION DEPLOY COMPLETE (adapter NOT synced, NO deposit yet — step d) ==="
