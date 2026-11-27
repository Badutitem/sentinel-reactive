#!/usr/bin/env bash
# RELEASE 6 LIVE deploy driver — fresh parallel LIVE set, V6 code.
# LIVE variant of tools/deploy_release6.sh (rehearsal driver).
# Differences: log -> release6-live-deploy.log; R6_ORACLE resume REMOVED
# (a set R6_ORACLE aborts — live must be FRESH, never the rehearsal set);
# banners say LIVE. Everything else identical to the rehearsal driver.
#   1. MockPriceOracle (Base Sepolia, allowlisted — deployer auto-pusher)
#   2. SentinelSwapV3 (Base Sepolia, priceSource = oracle, vault = 0)
#   3. SentinelReactiveV6 (Lasna, mock origin, 2.20 lREACT attached)
#   4. SentinelVaultV6 (Base Sepolia)
#   5. swap.setVault + reactive.setVault — SINGLE USE on V6, then
#      vaultLocked == true on both (AH-6); verified by reads
#   6. dedicated pusher key (AH-5 separation): allowPusher(pusher)
#      — the pusher is NOT the dev key; the driver pushes with it
#   7. desk seeded exactly 1,000 mUSDC; vault billing 0.0001 ETH
# Faucet round is a separate pre-step (design §5); this script
# GATES on dev Lasna >= 2.40 lREACT before any deploy
# (2.20 attach + 0.1801715 deploy gas, rounded up).
# V6 read-backs beyond R8: swap MIN_SANE_PRICE() == 1e18,
# swap MAX_SANE_PRICE() == 1_000_000e18,
# vault MAX_DEPOSIT_DEVIATION_BPS() == 2000,
# swap.vaultLocked() == true, reactive.vaultLocked() == true,
# reactive.exitLatched() == false, vault lastSettledPrice() == 0.
# Any failed expectation ABORTS (exit 1) with state preserved.
# Transcript: goal hidden_files/release6-deploy.log.
# FLAGSHIP SET IS NEVER TOUCHED by this script.
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."
set -a; source .env.local; set +a
set -a; source "$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/v6-pusher.env"; set +a

BASE_RPC="https://sepolia.base.org"
LASNA_RPC="https://lasna-rpc.rnk.dev"
DEV="0x75c328F0354fFC73bee24F61F7166a33Bf90Bf94"
WETH="0x4200000000000000000000000000000000000006"
MUSDC="0x96E467Ff7958851d307D28118EBAAD333CAb85B2"
PROXY="0x476F44b11F5C942c58f4c8E3d0300E5710743585"
FLAGSHIP_BRAIN="0x162DdFa4dD0db9bA60c4444b9a1BD1fa6b5343A9"
FLAGSHIP_ADAPTER="0xcc99348d41eec983584eE071EADC7091a895030d"
FLAGSHIP_VAULT="0xD61E27bC945ceE8Bd967aA42c907e7bA6968b5e9"
LOG="${LOG:-$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/release6-live-deploy.log}"
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

say "=== RELEASE 6 LIVE DEPLOY START ==="
DEVBASE=$(bal "$DEV" "$BASE_RPC")
DEVLASNA=$(bal "$DEV" "$LASNA_RPC")
say "preflight: dev BaseSep=$DEVBASE dev Lasna=$DEVLASNA flagshipBrainUpdates=$(cv "$FLAGSHIP_BRAIN" "updates()(uint256)" "$LASNA_RPC") flagshipVaultShares=$(cv "$FLAGSHIP_VAULT" "totalShares()(uint256)" "$BASE_RPC") pusher=$PUSHER"
python3 -c "exit(0 if $DEVBASE >= 10000000000000000 else 1)" || fail "dev Base Sepolia balance below 0.01 ETH"
python3 -c "exit(0 if $DEVLASNA >= 2400000000000000000 else 1)" || fail "FAUCET GATE: dev Lasna $DEVLASNA < 2.40 lREACT — deploy does not start"
[ -n "${PUSHER:-}" ] || fail "PUSHER unset — v6-pusher.env missing"
[ "$(echo "$PUSHER" | tr 'A-F' 'a-f')" != "$(echo "$DEV" | tr 'A-F' 'a-f')" ] || fail "pusher == dev — separation requires a distinct key"

# --- 1. MockPriceOracle (no constructor args) ---
# LIVE: resume is FORBIDDEN — a set R6_ORACLE would risk reusing the
# rehearsal oracle. Live must deploy FRESH.
[ -z "${R6_ORACLE:-}" ] || fail "R6_ORACLE is set — live deploy must be FRESH, resume forbidden"
read ORACLE ORACLE_TX <<< "$(create "$BASE_RPC" src/MockPriceOracle.sol:MockPriceOracle)"
say "ORACLE deployed: $ORACLE tx=$ORACLE_TX"
[ "$(echo "$ORACLE" | tr 'A-F' 'a-f')" != "0x94244819916102db22fba4f58542055df3e37f55" ] || fail "fresh oracle == REHEARSAL oracle — abort"
[ "$(cv "$ORACLE" "latestPrice(address)(uint256)" "$WETH" "$BASE_RPC")" = "0" ] || fail "oracle price not 0 at birth"
[ "$(cv "$ORACLE" "owner()(address)" "$BASE_RPC" | tr 'A-F' 'a-f')" = "$(echo "$DEV" | tr 'A-F' 'a-f')" ] || fail "oracle owner != dev"
[ "$(cv "$ORACLE" "pricePushers(address)(bool)" "$DEV" "$BASE_RPC")" = "true" ] || fail "oracle pricePushers(dev) != true"

# --- 2. Swap desk V3 (vault = 0, wired later; priceSource = fresh oracle) ---
read SWAP SWAP_TX <<< "$(create "$BASE_RPC" src/SentinelSwapV3.sol:SentinelSwapV3 --constructor-args "$WETH" "$MUSDC" "$ORACLE" 0x0000000000000000000000000000000000000000)"
say "SWAP deployed: $SWAP tx=$SWAP_TX"
[ "$(cv "$SWAP" "priceSource()(address)" "$BASE_RPC" | tr 'A-F' 'a-f')" = "$(echo "$ORACLE" | tr 'A-F' 'a-f')" ] || fail "swap priceSource mismatch"
[ "$(cv "$SWAP" "MAX_PRICE_AGE()(uint256)" "$BASE_RPC")" = "3600" ] || fail "swap MAX_PRICE_AGE != 3600"
[ "$(cv "$SWAP" "priceStale()(bool)" "$BASE_RPC")" = "true" ] || fail "swap priceStale != true pre-push (never-pushed source must read stale)"
# V6 bounds read-backs (AH-3/AH-4).
[ "$(cv "$SWAP" "MIN_SANE_PRICE()(uint256)" "$BASE_RPC")" = "1000000000000000000" ] || fail "swap MIN_SANE_PRICE != 1e18"
[ "$(cv "$SWAP" "MAX_SANE_PRICE()(uint256)" "$BASE_RPC")" = "1000000000000000000000000" ] || fail "swap MAX_SANE_PRICE != 1_000_000e18"

# --- 3. Brain V6 on Lasna, mock origin, 2.20 lREACT attached ---
read REACTIVE REACTIVE_TX <<< "$(create "$LASNA_RPC" src/SentinelReactiveV6.sol:SentinelReactiveV6 --value 2200000000000000000 --constructor-args 84532 "$ORACLE" "$WETH" 84532 300)"
say "REACTIVE deployed: $REACTIVE tx=$REACTIVE_TX balance=$(bal "$REACTIVE" "$LASNA_RPC")"
[ "$(cv "$REACTIVE" "oracle()(address)" "$LASNA_RPC" | tr 'A-F' 'a-f')" = "$(echo "$ORACLE" | tr 'A-F' 'a-f')" ] || fail "reactive oracle mismatch"
[ "$(cv "$REACTIVE" "updates()(uint256)" "$LASNA_RPC")" = "0" ] || fail "reactive updates not 0 at birth"
[ "$(cv "$REACTIVE" "exitLatched()(bool)" "$LASNA_RPC")" = "false" ] || fail "reactive exitLatched != false at birth"
[ "$(cv "$REACTIVE" "vaultLocked()(bool)" "$LASNA_RPC")" = "false" ] || fail "reactive vaultLocked != false pre-wiring"
# R-7: flagship brain must still point at its own Chainlink adapter, untouched.
[ "$(cv "$FLAGSHIP_BRAIN" "oracle()(address)" "$LASNA_RPC" | tr 'A-F' 'a-f')" = "$(echo "$FLAGSHIP_ADAPTER" | tr 'A-F' 'a-f')" ] || fail "R-7: flagship brain oracle changed (expected Chainlink adapter)"
[ "$(cv "$FLAGSHIP_BRAIN" "oracle()(address)" "$LASNA_RPC" | tr 'A-F' 'a-f')" != "$(echo "$ORACLE" | tr 'A-F' 'a-f')" ] || fail "R-7: flagship brain now points at fresh oracle"

# --- 4. VaultV6 ---
read VAULT VAULT_TX <<< "$(create "$BASE_RPC" src/SentinelVaultV6.sol:SentinelVaultV6 --constructor-args "$PROXY" "$REACTIVE" "$WETH" "$MUSDC" "$SWAP")"
say "VAULT deployed: $VAULT tx=$VAULT_TX"
[ "$(cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC")" = "0" ] || fail "vault totalShares not 0 at birth"
[ "$(cv "$VAULT" "lastSettledPrice()(uint256)" "$BASE_RPC")" = "0" ] || fail "vault lastSettledPrice not 0 at birth"
[ "$(cv "$VAULT" "MAX_DEPOSIT_DEVIATION_BPS()(uint256)" "$BASE_RPC")" = "2000" ] || fail "vault MAX_DEPOSIT_DEVIATION_BPS != 2000 (AH-5)"

# --- 5. Wiring — single use on V6 ---
H=$(send "$BASE_RPC" "$SWAP" "setVault(address)" "$VAULT"); say "swap.setVault tx=$H"
[ "$(cv "$SWAP" "vault()(address)" "$BASE_RPC" | tr 'A-F' 'a-f')" = "$(echo "$VAULT" | tr 'A-F' 'a-f')" ] || fail "swap vault mismatch after setVault"
[ "$(cv "$SWAP" "vaultLocked()(bool)" "$BASE_RPC")" = "true" ] || fail "swap vaultLocked != true after setVault (AH-6)"
H=$(send "$LASNA_RPC" "$REACTIVE" "setVault(address)" "$VAULT"); say "reactive.setVault tx=$H"
[ "$(cv "$REACTIVE" "vault()(address)" "$LASNA_RPC" | tr 'A-F' 'a-f')" = "$(echo "$VAULT" | tr 'A-F' 'a-f')" ] || fail "reactive vault mismatch after setVault"
[ "$(cv "$REACTIVE" "vaultLocked()(bool)" "$LASNA_RPC")" = "true" ] || fail "reactive vaultLocked != true after setVault (AH-6)"
say "flagship brain after wiring: updates=$(cv "$FLAGSHIP_BRAIN" "updates()(uint256)" "$LASNA_RPC") lastAction=$(cv "$FLAGSHIP_BRAIN" "lastAction()(uint8)" "$LASNA_RPC") flagshipVaultShares=$(cv "$FLAGSHIP_VAULT" "totalShares()(uint256)" "$BASE_RPC")"

# --- 6. Dedicated pusher (AH-5 separation) ---
H=$(send "$BASE_RPC" "$ORACLE" "allowPusher(address)" "$PUSHER"); say "oracle.allowPusher(pusher) tx=$H"
[ "$(cv "$ORACLE" "pricePushers(address)(bool)" "$PUSHER" "$BASE_RPC")" = "true" ] || fail "oracle pricePushers(pusher) != true"
[ "$(cv "$ORACLE" "pricePushers(address)(bool)" "$DEV" "$BASE_RPC")" = "true" ] || fail "oracle pricePushers(dev) lost after allowPusher"

# --- 7. Seed desk exactly 1,000 mUSDC + vault billing 0.0001 ETH ---
H=$(send "$BASE_RPC" "$MUSDC" "mint(address,uint256)" "$SWAP" 1000000000000000000000); say "desk seed mint tx=$H"
[ "$(cast call "$MUSDC" "balanceOf(address)(uint256)" "$SWAP" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}')" = "1000000000000000000000" ] || fail "desk mUSDC balance != 1000e18 after seed"
H=$(cast send "$VAULT" --value 100000000000000 --rpc-url "$BASE_RPC" --private-key "$PRIVATE_KEY" --json 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='0x1';print(d['transactionHash'])" 2>/dev/null) || fail "vault billing fund failed"
say "vault billing fund tx=$H vaultETH=$(bal "$VAULT" "$BASE_RPC")"

say "RELEASE6_ADDRESSES oracle=$ORACLE swap=$SWAP reactive=$REACTIVE vault=$VAULT pusher=$PUSHER"
say "RELEASE6_TXS oracle=$ORACLE_TX swap=$SWAP_TX reactive=$REACTIVE_TX vault=$VAULT_TX"
say "post: dev BaseSep=$(bal "$DEV" "$BASE_RPC") dev Lasna=$(bal "$DEV" "$LASNA_RPC") brain Lasna=$(bal "$REACTIVE" "$LASNA_RPC")"
say "=== RELEASE 6 LIVE DEPLOY COMPLETE ==="
