#!/usr/bin/env bash
# RELEASE 8 PRE-DRIVE ATTACK TESTS — run AFTER deploy + seed, BEFORE the drive.
# All attacks come from a STRANGER address (burner C key) that is NOT
# allowlisted on the fresh oracle. Every attack MUST FAIL:
#   F1a pump: stranger setPrice 100x pump -> reverts NotPusher; then the
#         stranger deposits at the true price and mints exactly fair
#         shares (1:1 into the seed-only pool), then redeems in full.
#   F1b fake crash: stranger pushes a 3-print crash series -> all revert
#         NotPusher; oracle price unchanged, brain updates 0, no EXIT.
#   F4 zero price: stranger setPrice(token, 0) -> reverts NotPusher;
#         oracle price unchanged, brain updates 0.
#   F2 stale (never-pushed): priceStale() == true; eth_call of both swap
#         fills FROM the vault address returns 0 and traces the
#         StalePriceRefused event — never filled at a stale price.
# Any attack SUCCEEDING (push lands, price changes, fill returns nonzero,
# shares unfair) ABORTS the whole rehearsal (exit 1) — do not proceed.
# Transcript: goal hidden_files/release8-attacks-pre.log.
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
STRANGER="$USER_C_ADDRESS"
STRANGER_KEY="$USER_C_KEY"
LOG="${LOG:-$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/release8-attacks-pre.log}"
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
bal() { local out="" n=0; while [ $n -lt 5 ]; do out=$(cast call "$1" "balanceOf(address)(uint256)" "$2" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}'); [ -n "$out" ] && { echo "$out"; return 0; }; n=$((n+1)); sleep 5; done; echo "$out"; }

# expect_revert <label> <price18> — eth_call from stranger must revert
# with NotPusher, then the real tx must land status 0x0.
expect_revert() {
  local label="$1" price="$2" err tx receipt st
  err=$(cast call "$ORACLE" "setPrice(address,uint256)" "$WETH" "$price" --from "$STRANGER" --rpc-url "$BASE_RPC" 2>&1) \
    && fail "$label: eth_call setPrice did NOT revert (stranger push would succeed)"
  SEL=$(cast sig "NotPusher(address)" 2>/dev/null | cut -c1-10)
  echo "$err" | grep -qi "${SEL#0x}" \
    || fail "$label: eth_call reverted but NOT with NotPusher ($SEL): $err"
  say "$label: eth_call reverts NotPusher ($SEL) as expected"
  tx=$(cast send "$ORACLE" "setPrice(address,uint256)" "$WETH" "$price" --rpc-url "$BASE_RPC" --private-key "$STRANGER_KEY" --gas-limit 100000 --async 2>/dev/null)
  [[ "$tx" =~ ^0x[0-9a-fA-F]{64}$ ]] || fail "$label: async send failed to broadcast (got: $tx)"
  n=0; st=""
  while [ $n -lt 12 ]; do sleep 5; receipt=$(cast receipt "$tx" --rpc-url "$BASE_RPC" --json 2>/dev/null); st=$(echo "$receipt" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('status',''))" 2>/dev/null); [ -n "$st" ] && break; n=$((n+1)); done
  [ "$st" = "0x0" ] || fail "$label: on-chain tx $tx status $st != 0x0 (attack did not revert on-chain)"
  say "$label: on-chain tx $tx status 0x0 (reverted) — attack FAILED as required"
}

say "=== RELEASE 8 PRE-DRIVE ATTACK TESTS START ==="
say "stranger=$STRANGER (burner C key, NOT allowlisted) oracle=$ORACLE reactive=$REACTIVE swap=$SWAP vault=$VAULT"
[ "$(cv "$ORACLE" "pricePushers(address)(bool)" "$STRANGER" "$BASE_RPC")" = "false" ] || fail "stranger is allowlisted — test setup wrong"
[ "$(cv "$ORACLE" "latestPrice(address)(uint256)" "$WETH" "$BASE_RPC")" = "0" ] || fail "oracle price not 0 before attacks"
[ "$(cv "$REACTIVE" "updates()(uint256)" "$LASNA_RPC")" = "0" ] || fail "brain updates not 0 before attacks"
say "flagship before: brain updates=$(cv "$FLAGSHIP_BRAIN" "updates()(uint256)" "$LASNA_RPC") lastAction=$(cv "$FLAGSHIP_BRAIN" "lastAction()(uint8)" "$LASNA_RPC") vault totalShares=$(cv "$FLAGSHIP_VAULT" "totalShares()(uint256)" "$BASE_RPC")"

# --- F1a: 100x pump (100x the first kline $1,679.28 = $167,928) ---
expect_revert "F1a-pump" 167928000000000000000000
[ "$(cv "$ORACLE" "latestPrice(address)(uint256)" "$WETH" "$BASE_RPC")" = "0" ] || fail "F1a: oracle price changed after reverted pump"
[ "$(cv "$REACTIVE" "updates()(uint256)" "$LASNA_RPC")" = "0" ] || fail "F1a: brain ingested the pumped price"
say "F1a pump: push reverted, oracle price still 0, brain updates still 0"

# --- F1a continued: stranger deposits at the TRUE price — must mint exactly fair shares ---
# Pool at this point: dev seed only (0.002 WETH, managedSafe 0) -> 1:1 mint.
WETH_BEFORE=$(bal "$WETH" "$STRANGER")
H1=$(cast send "$WETH" "deposit()" --value 500000000000000 --rpc-url "$BASE_RPC" --private-key "$STRANGER_KEY" --json 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='0x1';print(d['transactionHash'])") || fail "F1a: stranger wrap failed"
H2=$(cast send "$WETH" "approve(address,uint256)" "$VAULT" 500000000000000 --rpc-url "$BASE_RPC" --private-key "$STRANGER_KEY" --json 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='0x1';print(d['transactionHash'])") || fail "F1a: stranger approve failed"
H3=$(cast send "$VAULT" "deposit(uint256)" 500000000000000 --rpc-url "$BASE_RPC" --private-key "$STRANGER_KEY" --json 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='0x1';print(d['transactionHash'])") || fail "F1a: stranger deposit failed"
SH=$(cv "$VAULT" "sharesOf(address)(uint256)" "$STRANGER" "$BASE_RPC")
[ "$SH" = "500000000000000" ] || fail "F1a: stranger shares $SH != 500000000000000 — SHARE THEFT (unfair mint)"
say "F1a deposit: stranger minted exactly $SH shares for 0.0005 WETH (fair 1:1) wrap=$H1 approve=$H2 deposit=$H3 — NO THEFT"
H4=$(cast send "$VAULT" "redeemAll()" --rpc-url "$BASE_RPC" --private-key "$STRANGER_KEY" --json 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='0x1';print(d['transactionHash'])") || fail "F1a: stranger redeemAll failed"
[ "$(cv "$VAULT" "sharesOf(address)(uint256)" "$STRANGER" "$BASE_RPC")" = "0" ] || fail "F1a: stranger shares not 0 after redeemAll"
WETH_AFTER=$(bal "$WETH" "$STRANGER")
# Round-trip is exact when AFTER == BEFORE + wrapped 5e14 (the wrapped WETH
# stays in the stranger's wallet; deposit+redeem returns exactly the 5e14 deposited).
python3 -c "exit(0 if $WETH_AFTER == $WETH_BEFORE + 500000000000000 else 1)" || fail "F1a: stranger WETH $WETH_BEFORE -> $WETH_AFTER after deposit+redeem (expected BEFORE + 500000000000000, not exact)"
[ "$(cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC")" = "2000000000000000" ] || fail "F1a: vault totalShares != dev seed 2e15 after stranger redeem"
say "F1a cleanup: stranger redeemAll=$H4, WETH $WETH_BEFORE -> $WETH_AFTER (exactly +0.0005 wrapped), vault back to dev seed only"

# --- F1b: fake crash series (3 descending prints) ---
expect_revert "F1b-crash-1" 1500000000000000000000
expect_revert "F1b-crash-2" 1200000000000000000000
expect_revert "F1b-crash-3" 900000000000000000000
[ "$(cv "$ORACLE" "latestPrice(address)(uint256)" "$WETH" "$BASE_RPC")" = "0" ] || fail "F1b: oracle price changed after reverted crash series"
[ "$(cv "$REACTIVE" "updates()(uint256)" "$LASNA_RPC")" = "0" ] || fail "F1b: brain ingested a fake crash print"
[ "$(cv "$REACTIVE" "lastAction()(uint8)" "$LASNA_RPC")" = "0" ] || fail "F1b: brain lastAction != HOLD after fake crash"
[ "$(cv "$VAULT" "protectionCount()(uint256)" "$BASE_RPC")" = "0" ] || fail "F1b: protection fired from fake crash"
say "F1b fake crash: all 3 pushes reverted, oracle 0, brain updates 0, lastAction HOLD, protectionCount 0 — NO EXIT FIRED"

# --- F4: zero price ---
expect_revert "F4-zero" 0
[ "$(cv "$ORACLE" "latestPrice(address)(uint256)" "$WETH" "$BASE_RPC")" = "0" ] || fail "F4: oracle price changed after reverted zero push"
[ "$(cv "$REACTIVE" "updates()(uint256)" "$LASNA_RPC")" = "0" ] || fail "F4: brain ingested the zero price"
say "F4 zero price: push reverted NotPusher, oracle 0, brain updates 0 — brain never saw the poison print"

# --- F2: stale desk fill, never-pushed source (fail closed from deploy) ---
[ "$(cv "$SWAP" "priceStale()(bool)" "$BASE_RPC")" = "true" ] || fail "F2: priceStale != true pre-push"
AGE=$(cv "$SWAP" "priceAge()(uint256)" "$BASE_RPC")
say "F2: priceStale=true priceAge=$AGE (> 3600)"
for FN in "swapRiskForSafe(uint256)(uint256)" "swapSafeForRisk(uint256)(uint256)"; do
  RET=$(cast call "$SWAP" "$FN" 1000000000000000 --from "$VAULT" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}')
  [ "$RET" = "0" ] || fail "F2: $FN returned $RET, expected 0 (stale fill must refuse)"
  TRACE=$(cast call "$SWAP" "$FN" 1000000000000000 --from "$VAULT" --rpc-url "$BASE_RPC" --trace 2>&1) || fail "F2: $FN trace call failed unexpectedly"
  echo "$TRACE" | grep -q "StalePriceRefused" || fail "F2: $FN trace lacks StalePriceRefused event"
  say "F2: $FN from vault returns 0 + StalePriceRefused in trace — fill REFUSED, never filled at stale price"
done

say "flagship after: brain updates=$(cv "$FLAGSHIP_BRAIN" "updates()(uint256)" "$LASNA_RPC") lastAction=$(cv "$FLAGSHIP_BRAIN" "lastAction()(uint8)" "$LASNA_RPC") vault totalShares=$(cv "$FLAGSHIP_VAULT" "totalShares()(uint256)" "$BASE_RPC")"
say "=== RELEASE 8 PRE-DRIVE ATTACK TESTS COMPLETE — ALL ATTACKS FAILED AS REQUIRED ==="
