#!/usr/bin/env bash
# RELEASE 6 RECOVERY LEG — runs AFTER the post-bleed attacks, on the V6 set.
# Purpose: (1) prove the post-EXIT latch clears live on tranche-1
# (forge-only until now); (2) rebuild a mixed pool so the AH-5 20% band
# can be tested against LIVE deposits.
# State at entry: brain updates 100, exitLatched false, reriskCount 1,
# protectionCount 7, vault OPEN holding the dev's 0.0001 WETH anchor
# deposit (managedRisk 1e14, managedSafe 0), brain ~0.86 lREACT.
#   Phase R (recovery): SKIPPED — tranche-1 already fired organically
#         at update 100 (the AH-5 attack's own price pushes: $1,283.46
#         then $1,552.99, >= 97% of the June episode anchor $1,546.14).
#         Latch cleared live, reriskCount 0->1, prot 6->7. This leg
#         VERIFIES that state at entry instead of re-running it.
#   Phase D (position): dev tops the position up to 0.001 WETH total.
#   Phase C (crash): -2%/update until the first protection callback
#         fires (TRIM expected, EXIT acceptable — either leaves a mixed
#         pool: TRIM halves the risk, EXIT sells it all to safe).
#         protectionCount 7->8, managedSafe > 0.
#   Phase B (band): anchor = lastSettledPrice (the crash fill). Deposit
#         0.0001 WETH at +21% -> REVERTS PriceDeviation; at exactly +20%
#         -> succeeds (boundary inclusive). redeemAll resets to empty.
#         The theft NUMBERS are forge-pinned (Release6Regression:
#         pump 5.2941, dump 4.6154, walk 8.2861); this leg proves the
#         band GATES live deposits.
# PRE-GATE: brain >= 0.50 lREACT (crash ~8 reactions).
# Any failed expectation ABORTS (exit 1) with state preserved.
# Transcript: goal hidden_files/release6-recovery.log.
# FLAGSHIP SET IS NEVER TOUCHED by this script.
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."
set -a; source .env.local; source "$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/vaultv5-rehearsal-burners.env"; source "$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/v6-pusher.env"; set +a

BASE_RPC="https://sepolia.base.org"
LASNA_RPC="https://lasna-rpc.rnk.dev"
WETH="0x4200000000000000000000000000000000000006"
MUSDC="0x96E467Ff7958851d307D28118EBAAD333CAb85B2"
DEV="0x75c328F0354fFC73bee24F61F7166a33Bf90Bf94"
ORACLE="${R6_ORACLE:?R6_ORACLE not set}"
REACTIVE="${R6_REACTIVE:?R6_REACTIVE not set}"
SWAP="${R6_SWAP:?R6_SWAP not set}"
VAULT="${R6_VAULT:?R6_VAULT not set}"
FLAGSHIP_BRAIN="0x162DdFa4dD0db9bA60c4444b9a1BD1fa6b5343A9"
FLAGSHIP_VAULT="0xD61E27bC945ceE8Bd967aA42c907e7bA6968b5e9"
LOG="${LOG:-$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/release6-recovery.log}"
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
updates() { cv "$REACTIVE" "updates()(uint256)" "$LASNA_RPC"; }
prot() { cv "$VAULT" "protectionCount()(uint256)" "$BASE_RPC"; }
rerisks() { cv "$REACTIVE" "reriskCount()(uint256)" "$LASNA_RPC"; }
bal() { cast balance "$1" --rpc-url "$2" 2>/dev/null; }
send() { # send <rpc> <key> <to> <sig> [args...] -> tx hash or FAIL
  local rpc="$1" key="$2" to="$3" sig="$4"; shift 4
  local out h
  out=$(cast send "$to" "$sig" "$@" --rpc-url "$rpc" --private-key "$key" --json 2>/dev/null) || fail "send failed: $sig to $to"
  h=$(echo "$out" | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='0x1','status '+d['status'];print(d['transactionHash'])" 2>/dev/null) || fail "tx reverted: $sig to $to"
  echo "$h"
}
expect_revert() { # expect_revert <label> <err-sig> <rpc> <key> <from> <to> <sig> [args...]
  local label="$1" errsig="$2" rpc="$3" key="$4" from="$5" to="$6" sig="$7"; shift 7
  local err tx receipt st SEL n
  err=$(cast call "$to" "$sig" "$@" --from "$from" --rpc-url "$rpc" 2>&1) \
    && fail "$label: eth_call did NOT revert"
  SEL=$(cast sig "$errsig" 2>/dev/null | cut -c1-10)
  echo "$err" | grep -qi "${SEL#0x}" \
    || fail "$label: eth_call reverted but NOT with $errsig ($SEL): $err"
  say "$label: eth_call reverts $errsig ($SEL) as expected"
  tx=$(cast send "$to" "$sig" "$@" --rpc-url "$rpc" --private-key "$key" --gas-limit 300000 --async 2>/dev/null)
  [[ "$tx" =~ ^0x[0-9a-fA-F]{64}$ ]] || fail "$label: async send failed to broadcast (got: $tx)"
  n=0; st=""
  while [ $n -lt 12 ]; do sleep 5; receipt=$(cast receipt "$tx" --rpc-url "$rpc" --json 2>/dev/null); st=$(echo "$receipt" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('status',''))" 2>/dev/null); [ -n "$st" ] && break; n=$((n+1)); done
  [ "$st" = "0x0" ] || fail "$label: on-chain tx $tx status $st != 0x0"
  say "$label: on-chain tx $tx status 0x0 (reverted) — attack FAILED as required"
}
wait_prot() { local want="$1" n=0 got; got=$(prot); while [ "$got" != "$want" ] && [ $n -lt 40 ]; do sleep 3; got=$(prot); n=$((n+1)); done; [ "$got" = "$want" ] || fail "protectionCount stuck at $got, expected $want"; say "callback landed: protectionCount=$got"; }

say "=== RELEASE 6 RECOVERY LEG START ==="
say "oracle=$ORACLE reactive=$REACTIVE swap=$SWAP vault=$VAULT pusher=$PUSHER"
say "flagship before: brain updates=$(cv "$FLAGSHIP_BRAIN" "updates()(uint256)" "$LASNA_RPC") vault shares=$(cv "$FLAGSHIP_VAULT" "totalShares()(uint256)" "$BASE_RPC")"
# NOTE (2026-11-27): Phase R did NOT run as a separate leg — the AH-5
# attack's own price pushes fired tranche-1 organically: update 99
# ingested the $1,283.46 anchor, update 100 ingested $1,552.99, which is
# >= 97% of the June episode anchor ($1,546.14). The latch cleared live
# (PostExitLatch false at update 100), reriskCount 0->1, prot 6->7.
# Entry state below is that post-tranche-1 state; Phase R is skipped
# and the leg starts at Phase D.
[ "$(updates)" = "100" ] || fail "brain updates != 100 at recovery entry"
[ "$(cv "$REACTIVE" "exitLatched()(bool)" "$LASNA_RPC")" = "false" ] || fail "exitLatched != false at recovery entry (tranche-1 should have cleared it)"
[ "$(rerisks)" = "1" ] || fail "reriskCount != 1 at recovery entry"
[ "$(prot)" = "7" ] || fail "protectionCount != 7 at recovery entry"
[ "$(cv "$VAULT" "closed()(bool)" "$BASE_RPC")" = "false" ] || fail "vault not open at recovery entry"
[ "$(cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC")" = "100000000000000" ] || fail "vault shares != 0.0001 WETH (dev anchor deposit) at recovery entry"
BRAIN_BAL0=$(bal "$REACTIVE" "$LASNA_RPC")
say "brain balance at recovery entry: $BRAIN_BAL0 lREACT-wei"
say "Phase R SKIPPED — tranche-1 already fired organically at update 100 (AH-5 price pushes); latch cleared live, reriskCount=1, prot=7"
python3 -c "exit(0 if $BRAIN_BAL0 >= 500000000000000000 else 1)" || fail "FUEL GATE: brain $BRAIN_BAL0 < 0.50 lREACT — top up before the recovery leg"

# --- Phase D: top the dev position up to 0.001 WETH total (0.0001 already in). ---
PRICE=$(cv "$ORACLE" "latestPrice(address)(uint256)" "$WETH" "$BASE_RPC")
say "position top-up: oracle price now $PRICE"
H=$(send "$BASE_RPC" "$PRIVATE_KEY" "$WETH" "deposit()" --value 900000000000000)
H=$(send "$BASE_RPC" "$PRIVATE_KEY" "$WETH" "approve(address,uint256)" "$VAULT" 900000000000000)
H=$(send "$BASE_RPC" "$PRIVATE_KEY" "$VAULT" "deposit(uint256)" 900000000000000)
say "dev topped up +0.0009 WETH tx=$H shares=$(cv "$VAULT" "sharesOf(address)(uint256)" "$DEV" "$BASE_RPC") managedRisk=$(cv "$VAULT" "managedRisk()(uint256)" "$BASE_RPC")"

# --- Phase C: crash -2%/update until the first protection callback fires. ---
LAST_PUSH_START=0
CFIRED=0
for i in $(seq 1 15); do
  PRICE=$(python3 -c "print($PRICE * 98 // 100)")
  now=$(date +%s)
  if [ "$LAST_PUSH_START" != "0" ]; then
    gap=$(( now - LAST_PUSH_START ))
    if [ "$gap" -lt 42 ]; then sleep $((42 - gap)); fi
  fi
  LAST_PUSH_START=$(date +%s)
  before=$(updates); p0=$(prot)
  hash=$(send "$BASE_RPC" "$PUSHER_KEY" "$ORACLE" "setPrice(address,uint256)" "$WETH" "$PRICE")
  [[ "$hash" =~ ^0x[0-9a-fA-F]{64}$ ]] || fail "crash push $i send failed"
  after="$before"; n=0
  while [ "$after" = "$before" ] && [ $n -lt 30 ]; do sleep 3; after=$(updates); n=$((n+1)); done
  [ "$after" = "$(( before + 1 ))" ] || fail "updates jumped $before -> $after at crash push $i"
  sleep 5; p1=$(prot)
  say "crash push $i: update=$after price18=$PRICE action=$(cv "$REACTIVE" "lastAction()(uint8)" "$LASNA_RPC") prot=$p0->$p1 tx=$hash"
  if [ "$p1" != "$p0" ]; then CFIRED=1; break; fi
done
[ "$CFIRED" = "1" ] || fail "no protection callback fired within 15 crash pushes"
wait_prot 8
say "CRASH CALLBACK FIRED: protectionCount=8 managedRisk=$(cv "$VAULT" "managedRisk()(uint256)" "$BASE_RPC") managedSafe=$(cv "$VAULT" "managedSafe()(uint256)" "$BASE_RPC") anchor=$(cv "$VAULT" "lastSettledPrice()(uint256)" "$BASE_RPC") closed=$(cv "$VAULT" "closed()(bool)" "$BASE_RPC")"
[ "$(cv "$VAULT" "managedSafe()(uint256)" "$BASE_RPC")" != "0" ] || fail "managedSafe still 0 after the crash callback (no mixed pool)"

# --- Phase B: live band test against the crash-fill anchor. ---
ANCHOR=$(cv "$VAULT" "lastSettledPrice()(uint256)" "$BASE_RPC")
say "AH-5 live: vault anchor (lastSettledPrice) = $ANCHOR"
P21=$(python3 -c "print($ANCHOR * 121 // 100)")
P20=$(python3 -c "print($ANCHOR * 120 // 100)")
H=$(send "$BASE_RPC" "$PRIVATE_KEY" "$ORACLE" "setPrice(address,uint256)" "$WETH" "$P21")
say "AH-5 live: dev pushed +21% price $P21"
# Fresh approval: the anchor deposit consumed the earlier allowance.
H=$(send "$BASE_RPC" "$PRIVATE_KEY" "$WETH" "deposit()" --value 100000000000000)
H=$(send "$BASE_RPC" "$PRIVATE_KEY" "$WETH" "approve(address,uint256)" "$VAULT" 100000000000000)
expect_revert "AH-5 live +21% deposit" "PriceDeviation(uint256,uint256)" "$BASE_RPC" "$PRIVATE_KEY" "$DEV" "$VAULT" "deposit(uint256)" 100000000000000
H=$(send "$BASE_RPC" "$PRIVATE_KEY" "$ORACLE" "setPrice(address,uint256)" "$WETH" "$P20")
say "AH-5 live: dev pushed +20% price $P20"
H=$(send "$BASE_RPC" "$PRIVATE_KEY" "$VAULT" "deposit(uint256)" 100000000000000)
say "AH-5 live: dev deposited 0.0001 WETH at exactly +20% tx=$H (boundary inclusive)"
H=$(send "$BASE_RPC" "$PRIVATE_KEY" "$VAULT" "redeemAll()")
say "AH-5 live: dev redeemAll tx=$H totalShares=$(cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC")"
[ "$(cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC")" = "0" ] || fail "vault not empty after redeemAll"

BRAIN_BAL1=$(bal "$REACTIVE" "$LASNA_RPC")
FUEL=$(python3 -c "print($BRAIN_BAL0 - $BRAIN_BAL1)")
say "flagship after: brain updates=$(cv "$FLAGSHIP_BRAIN" "updates()(uint256)" "$LASNA_RPC") vault shares=$(cv "$FLAGSHIP_VAULT" "totalShares()(uint256)" "$BASE_RPC")"
say "RELEASE6_RECOVERY_RESULT updates=$(updates) protectionCount=$(prot) reriskCount=$(rerisks) latched=$(cv "$REACTIVE" "exitLatched()(bool)" "$LASNA_RPC") fuelBurnedWei=$FUEL brainBal0=$BRAIN_BAL0 brainBal1=$BRAIN_BAL1"
say "=== RELEASE 6 RECOVERY LEG COMPLETE — latch cleared live, band gates live deposits ==="
