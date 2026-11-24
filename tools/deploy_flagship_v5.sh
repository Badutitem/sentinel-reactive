#!/usr/bin/env bash
# FLAGSHIP SWAP deploy driver — SentinelVaultV5 flagship set.
# Mirrors the trio #5 MAIN deployment (ChainlinkPriceAdapter origin),
# with SentinelVaultV5 as the vault:
#   1. SentinelSwapV2 (Base Sepolia, priceSource = adapter, vault = 0)
#   2. SentinelReactiveV5 (Lasna, adapter origin, 1.15 lREACT attached)
#   3. SentinelVaultV5 (Base Sepolia)
#   4. swap.setVault + reactive.setVault
#   5. desk seeded exactly 1,000 mUSDC; vault billing 0.0001 ETH
#   6. owner seed deposit 0.002 WETH via the PUBLIC flow (wrap/approve/
#      deposit); shares must mint exactly 1:1.
# Any failed expectation ABORTS (exit 1) with state preserved.
# Transcript: goal hidden_files/flagship-v5-deploy.log.
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."
set -a; source .env.local; set +a

BASE_RPC="https://sepolia.base.org"
LASNA_RPC="https://lasna-rpc.rnk.dev"
DEV="0x75c328F0354fFC73bee24F61F7166a33Bf90Bf94"
WETH="0x4200000000000000000000000000000000000006"
MUSDC="0x96E467Ff7958851d307D28118EBAAD333CAb85B2"
ADAPTER="0xAb9c7a5178B444cd1C1fD705e5eBeCf4b9A1C25F"
PROXY="0x476F44b11F5C942c58f4c8E3d0300E5710743585"
LOG="${LOG:-$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/flagship-v5-deploy.log}"
exec > >(tee -a "$LOG") 2>&1

fail() { echo "!!! ABORT: $*"; echo "!!! State preserved; nothing further will be sent."; exit 1; }
say() { echo "[$(date -u +%H:%M:%S)] $*"; }

cv() { cast call "$1" "$2" --rpc-url "$3" 2>/dev/null | awk '{print $1}'; }
bal() { cast balance "$1" --rpc-url "$2" 2>/dev/null; }

create() { # create <rpc> <contract> [forge-create args...] -> echoes "addr txhash"
  local rpc="$1" contract="$2"; shift 2
  local out
  out=$(forge create "$contract" --rpc-url "$rpc" --private-key "$PRIVATE_KEY" --broadcast --json "$@" 2>/dev/null) \
    || fail "forge create $contract failed"
  echo "$out" | python3 -c "import sys,json;d=json.load(sys.stdin);a=d.get('contractAddress');h=d.get('transactionHash');assert a and h;print(a,h)" 2>/dev/null \
    || fail "could not parse forge create output for $contract: $out"
}

send() { # send <rpc> <to> <sig> [args...] -> tx hash or FAIL (dev key)
  local rpc="$1" to="$2" sig="$3"; shift 3
  local out h
  out=$(cast send "$to" "$sig" "$@" --rpc-url "$rpc" --private-key "$PRIVATE_KEY" --json 2>/dev/null) || fail "send failed: $sig to $to"
  h=$(echo "$out" | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='0x1','status '+d['status'];print(d['transactionHash'])" 2>/dev/null) || fail "tx reverted: $sig to $to"
  echo "$h"
}

say "=== FLAGSHIP V5 DEPLOY START ==="
DEVBASE=$(bal "$DEV" "$BASE_RPC")
DEVLASNA=$(bal "$DEV" "$LASNA_RPC")
say "preflight: dev BaseSep=$DEVBASE dev Lasna=$DEVLASNA adapterLastPrice=$(cv "$ADAPTER" "lastPrice()(uint256)" "$BASE_RPC")"
python3 -c "exit(0 if $DEVBASE >= 10000000000000000 else 1)" || fail "dev Base Sepolia balance below 0.01 ETH"
python3 -c "exit(0 if $DEVLASNA >= 1350000000000000000 else 1)" || fail "dev Lasna balance below 1.35 lREACT"

# --- 1. Swap desk (vault = 0, wired later, exactly as trio #5) ---
read SWAP SWAP_TX <<< "$(create "$BASE_RPC" src/SentinelSwapV2.sol:SentinelSwapV2 --constructor-args "$WETH" "$MUSDC" "$ADAPTER" 0x0000000000000000000000000000000000000000)"
say "SWAP deployed: $SWAP tx=$SWAP_TX"
[ "$(cv "$SWAP" "priceSource()(address)" "$BASE_RPC" | tr 'A-F' 'a-f')" = "$(echo "$ADAPTER" | tr 'A-F' 'a-f')" ] || fail "swap priceSource mismatch"

# --- 2. Brain on Lasna, real Chainlink adapter origin, 1.15 lREACT ---
read REACTIVE REACTIVE_TX <<< "$(create "$LASNA_RPC" src/SentinelReactiveV5.sol:SentinelReactiveV5 --value 1150000000000000000 --constructor-args 84532 "$ADAPTER" "$WETH" 84532 300)"
say "REACTIVE deployed: $REACTIVE tx=$REACTIVE_TX balance=$(bal "$REACTIVE" "$LASNA_RPC")"
[ "$(cv "$REACTIVE" "oracle()(address)" "$LASNA_RPC" | tr 'A-F' 'a-f')" = "$(echo "$ADAPTER" | tr 'A-F' 'a-f')" ] || fail "reactive oracle mismatch"
[ "$(cv "$REACTIVE" "updates()(uint256)" "$LASNA_RPC")" = "0" ] || fail "reactive updates not 0 at birth"

# --- 3. VaultV5 ---
read VAULT VAULT_TX <<< "$(create "$BASE_RPC" src/SentinelVaultV5.sol:SentinelVaultV5 --constructor-args "$PROXY" "$REACTIVE" "$WETH" "$MUSDC" "$SWAP")"
say "VAULT deployed: $VAULT tx=$VAULT_TX"
[ "$(cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC")" = "0" ] || fail "vault totalShares not 0 at birth"

# --- 4. Wiring ---
H=$(send "$BASE_RPC" "$SWAP" "setVault(address)" "$VAULT"); say "swap.setVault tx=$H"
[ "$(cv "$SWAP" "vault()(address)" "$BASE_RPC" | tr 'A-F' 'a-f')" = "$(echo "$VAULT" | tr 'A-F' 'a-f')" ] || fail "swap vault mismatch after setVault"
H=$(send "$LASNA_RPC" "$REACTIVE" "setVault(address)" "$VAULT"); say "reactive.setVault tx=$H"
[ "$(cv "$REACTIVE" "vault()(address)" "$LASNA_RPC" | tr 'A-F' 'a-f')" = "$(echo "$VAULT" | tr 'A-F' 'a-f')" ] || fail "reactive vault mismatch after setVault"

# --- 5. Seed desk exactly 1,000 mUSDC + vault billing 0.0001 ETH ---
H=$(send "$BASE_RPC" "$MUSDC" "mint(address,uint256)" "$SWAP" 1000000000000000000000); say "desk seed mint tx=$H"
[ "$(cast call "$MUSDC" "balanceOf(address)(uint256)" "$SWAP" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}')" = "1000000000000000000000" ] || fail "desk mUSDC balance != 1000e18 after seed"
H=$(cast send "$VAULT" --value 100000000000000 --rpc-url "$BASE_RPC" --private-key "$PRIVATE_KEY" --json 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='0x1';print(d['transactionHash'])" 2>/dev/null) || fail "vault billing fund failed"
say "vault billing fund tx=$H vaultETH=$(bal "$VAULT" "$BASE_RPC")"

# --- 6. Owner seed deposit 0.002 WETH via the public flow ---
H1=$(send "$BASE_RPC" "$WETH" "deposit()" --value 2000000000000000); say "wrap tx=$H1"
H2=$(send "$BASE_RPC" "$WETH" "approve(address,uint256)" "$VAULT" 2000000000000000); say "approve tx=$H2"
H3=$(send "$BASE_RPC" "$VAULT" "deposit(uint256)" 2000000000000000); say "deposit tx=$H3"
SH=$(cast call "$VAULT" "sharesOf(address)(uint256)" "$DEV" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}')
say "owner shares=$SH totalShares=$(cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC") managedRisk=$(cv "$VAULT" "managedRisk()(uint256)" "$BASE_RPC") positionSize=$(cv "$VAULT" "positionSize()(uint256)" "$BASE_RPC")"
[ "$SH" = "2000000000000000" ] || fail "owner shares != 0.002e18 (not 1:1)"
[ "$(cv "$VAULT" "managedRisk()(uint256)" "$BASE_RPC")" = "2000000000000000" ] || fail "managedRisk != 0.002 WETH after seed deposit"

say "FLAGSHIP_ADDRESSES swap=$SWAP reactive=$REACTIVE vault=$VAULT"
say "FLAGSHIP_TXS swap=$SWAP_TX reactive=$REACTIVE_TX vault=$VAULT_TX wrap=$H1 approve=$H2 deposit=$H3"
say "post: dev BaseSep=$(bal "$DEV" "$BASE_RPC") dev Lasna=$(bal "$DEV" "$LASNA_RPC") brain Lasna=$(bal "$REACTIVE" "$LASNA_RPC")"
say "=== FLAGSHIP V5 DEPLOY COMPLETE ==="
