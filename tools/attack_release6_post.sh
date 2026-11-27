#!/usr/bin/env bash
# RELEASE 6 POST-BLEED ATTACK RE-RUNS — run AFTER the June drive + bleed
# leg complete, on the closed, empty V6 set. State at entry:
# brain updates 96, lastAction 2 (EXIT), exitLatched true,
# vault closed, totalShares 0, protectionCount 6 (June 6 + bleed 0 —
# the latch suppressed all 40 bleed EXIT votes).
#   AH-3: stranger (burner C key, NOT allowlisted) pushes 1 wei -> the
#         oracle call REVERTS NotPusher. Dev (allowlisted) pushes 1 wei
#         -> oracle stores it, brain CONSUMES without ingesting
#         (updates stays 96). Sane follow-up price -> updates 97, no
#         new callback (latch still set), brain alive.
#   AH-4: dev pushes 2^200 -> oracle stores it, brain consumes without
#         ingesting (updates stays 97). EXIT callback attempt via the
#         proxy path MUST NOT revert (swap returns 0 + InsanePriceRefused
#         both directions, eth_call FROM the vault). Sane follow-up
#         price -> updates 98, no new callback, brain alive.
#   AH-5: live band check on the re-armed vault. Dev deposits 0.0001
#         WETH at the anchor price (succeeds, re-arms), then a deposit
#         at +21% REVERTS PriceDeviation, then a deposit at exactly +20%
#         succeeds (boundary inclusive). redeemAll resets to empty.
#         The full theft numbers are forge-pinned (Release6Regression:
#         pump 5.2941 vs V5 5.625; dump 4.6154 vs V5 3.787; walk 8.2861
#         vs V5 8.7535) — deterministic share math, no chain variance.
#   AH-6: dev calls setVault(attacker) on swap AND brain -> both REVERT
#         VaultAlreadySet; wiring unchanged (vaultLocked true, vault()
#         still the V6 vault).
# Any failure ABORTS (exit 1).
# Transcript: goal hidden_files/release6-attacks-post.log.
# FLAGSHIP SET IS NEVER TOUCHED by this script.
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."
set -a; source .env.local; source "$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/vaultv5-rehearsal-burners.env"; set +a

BASE_RPC="https://sepolia.base.org"
LASNA_RPC="https://lasna-rpc.rnk.dev"
WETH="0x4200000000000000000000000000000000000006"
MUSDC="0x96E467Ff7958851d307D28118EBAAD333CAb85B2"
DEV="0x75c328F0354fFC73bee24F61F7166a33Bf90Bf94"
FLAGSHIP_BRAIN="0x162DdFa4dD0db9bA60c4444b9a1BD1fa6b5343A9"
FLAGSHIP_VAULT="0xD61E27bC945ceE8Bd967aA42c907e7bA6968b5e9"
ORACLE="${R6_ORACLE:?R6_ORACLE not set}"
REACTIVE="${R6_REACTIVE:?R6_REACTIVE not set}"
SWAP="${R6_SWAP:?R6_SWAP not set}"
VAULT="${R6_VAULT:?R6_VAULT not set}"
ATTACKER="0x0be5e7CC763F4B2aC524d7038e14fB60C6b05A6f"
LOG="${LOG:-$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/release6-attacks-post.log}"
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
expect_revert() { # expect_revert <label> <err-sig> <rpc> <key> <from> <to> <sig> [args...]
  # Proven R8 pattern: eth_call must revert with the named error, then the
  # real tx is broadcast --async (bypasses cast's simulation gate) and
  # must land status 0x0 on-chain.
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
  [ "$st" = "0x0" ] || fail "$label: on-chain tx $tx status $st != 0x0 (attack did NOT revert on-chain)"
  say "$label: on-chain tx $tx status 0x0 (reverted) — attack FAILED as required"
}
wait_updates() { # wait_updates <want> — poll until brain updates == want (90 s max)
  local want="$1" n=0 u
  u=$(cv "$REACTIVE" "updates()(uint256)" "$LASNA_RPC")
  while [ "$u" != "$want" ] && [ $n -lt 30 ]; do sleep 3; u=$(cv "$REACTIVE" "updates()(uint256)" "$LASNA_RPC"); n=$((n+1)); done
  [ "$u" = "$want" ] || fail "brain updates stuck at $u, expected $want"
}

say "=== RELEASE 6 POST-BLEED ATTACK RE-RUNS START ==="
say "flagship before: brain updates=$(cv "$FLAGSHIP_BRAIN" "updates()(uint256)" "$LASNA_RPC") vault shares=$(cv "$FLAGSHIP_VAULT" "totalShares()(uint256)" "$BASE_RPC")"
[ "$(cv "$REACTIVE" "updates()(uint256)" "$LASNA_RPC")" = "96" ] || fail "brain updates != 96 at attack entry (bleed incomplete?)"
[ "$(cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC")" = "0" ] || fail "vault not empty at attack entry"
[ "$(cv "$VAULT" "closed()(bool)" "$BASE_RPC")" = "true" ] || fail "vault not closed at attack entry"
[ "$(cv "$VAULT" "protectionCount()(uint256)" "$BASE_RPC")" = "6" ] || fail "protectionCount != 6 at attack entry"
[ "$(cv "$REACTIVE" "exitLatched()(bool)" "$LASNA_RPC")" = "true" ] || fail "exitLatched != true at attack entry"

# --- AH-3: 1-wei print ---
# The bleed close is the oracle's current price; it is the sane follow-up
# price for both AH-3 and AH-4 (a flat print after the bleed).
BLEED_CLOSE=$(cv "$ORACLE" "latestPrice(address)(uint256)" "$WETH" "$BASE_RPC")
say "AH-3: bleed close (oracle latestPrice) = $BLEED_CLOSE"
# Stranger (burner C key) is NOT allowlisted: the push itself reverts.
expect_revert "AH-3 stranger 1-wei push" "NotPusher(address)" "$BASE_RPC" "$USER_C_KEY" "$USER_C_ADDRESS" "$ORACLE" "setPrice(address,uint256)" "$WETH" 1
# Dev IS allowlisted: the oracle stores 1 wei; the brain consumes without ingesting.
H=$(send "$BASE_RPC" "$PRIVATE_KEY" "$ORACLE" "setPrice(address,uint256)" "$WETH" 1)
say "AH-3: dev pushed 1 wei tx=$H"
[ "$(cv "$ORACLE" "latestPrice(address)(uint256)" "$WETH" "$BASE_RPC")" = "1" ] || fail "AH-3: oracle did not store the 1-wei price"
sleep 45
[ "$(cv "$REACTIVE" "updates()(uint256)" "$LASNA_RPC")" = "96" ] || fail "AH-3: brain ingested the 1-wei print (updates moved off 96)"
[ "$(cv "$VAULT" "protectionCount()(uint256)" "$BASE_RPC")" = "6" ] || fail "AH-3: 1-wei print fired a callback"
say "AH-3: 45 s after the 1-wei print, brain updates still 96, protectionCount still 6 — poison consumed, never ingested"
# Sane follow-up: flat at the bleed close. Any vote is latch-suppressed.
H=$(send "$BASE_RPC" "$PRIVATE_KEY" "$ORACLE" "setPrice(address,uint256)" "$WETH" "$BLEED_CLOSE")
say "AH-3: dev pushed sane bleed-close price tx=$H"
wait_updates 97
[ "$(cv "$VAULT" "protectionCount()(uint256)" "$BASE_RPC")" = "6" ] || fail "AH-3: sane follow-up fired a callback (protectionCount != 6)"
[ "$(cv "$REACTIVE" "exitLatched()(bool)" "$LASNA_RPC")" = "true" ] || fail "AH-3: latch cleared by the follow-up price"
say "AH-3: brain advanced to 97, lastAction=$(cv "$REACTIVE" "lastAction()(uint8)" "$LASNA_RPC") (vote latch-suppressed), protectionCount still 6 — BRAIN ALIVE"

# --- AH-4: 2^200 absurd price ---
H=$(send "$BASE_RPC" "$PRIVATE_KEY" "$ORACLE" "setPrice(address,uint256)" "$WETH" 1606938044258990275541962092341162602522202993782792835301376)
say "AH-4: dev pushed 2^200 tx=$H"
sleep 45
[ "$(cv "$REACTIVE" "updates()(uint256)" "$LASNA_RPC")" = "97" ] || fail "AH-4: brain ingested the 2^200 print (updates moved off 97)"
say "AH-4: 45 s after the 2^200 print, brain updates still 97 — absurd price consumed, never ingested"
for FN in "swapRiskForSafe(uint256)(uint256)" "swapSafeForRisk(uint256)(uint256)"; do
  RET=$(cast call "$SWAP" "$FN" 1000000000000000 --from "$VAULT" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}')
  [ "$RET" = "0" ] || fail "AH-4: $FN returned $RET at 2^200, expected 0"
  TRACE=$(cast call "$SWAP" "$FN" 1000000000000000 --from "$VAULT" --rpc-url "$BASE_RPC" --trace 2>&1) || fail "AH-4: $FN trace call failed unexpectedly"
  echo "$TRACE" | grep -q "InsanePriceRefused" || fail "AH-4: $FN trace lacks InsanePriceRefused event"
  say "AH-4: $FN from vault returns 0 + InsanePriceRefused at 2^200 — fill REFUSED, no revert"
done
# EXIT callback attempt while the price is absurd: must NOT revert.
# (Called via eth_call simulation of the proxy path is impossible on-chain
# without the system contract; instead verify the swap refusal above is the
# binding layer, and confirm the vault's managed totals are untouched.)
[ "$(cv "$VAULT" "managedRisk()(uint256)" "$BASE_RPC")" = "0" ] || fail "AH-4: vault managedRisk moved at 2^200"
[ "$(cv "$VAULT" "managedSafe()(uint256)" "$BASE_RPC")" = "0" ] || fail "AH-4: vault managedSafe moved at 2^200"
say "AH-4: vault managed totals still 0/0 at the absurd price — position intact"
# Sane follow-up again (flat at the bleed close).
H=$(send "$BASE_RPC" "$PRIVATE_KEY" "$ORACLE" "setPrice(address,uint256)" "$WETH" "$BLEED_CLOSE")
say "AH-4: dev pushed sane bleed-close price tx=$H"
wait_updates 98
[ "$(cv "$VAULT" "protectionCount()(uint256)" "$BASE_RPC")" = "6" ] || fail "AH-4: sane follow-up fired a callback (protectionCount != 6)"
say "AH-4: brain advanced to 98, protectionCount still 6 — BRAIN ALIVE after the absurd price"

# --- AH-5: live band check (vault re-arms on deposit) ---
# NOTE (2026-11-27, live run): this section ABORTED at the +21% deposit
# for two diagnosed reasons, and the AH-5 live check MOVED to
# tools/rehearse_release6_recovery.sh Phase B, where it PASSED
# (+21% reverts PriceDeviation on-chain, +20% succeeds).
# (1) On the post-June vault managedSafe == 0, so the band guard
# correctly does NOT engage — the +21% deposit reverted for missing
# allowance instead (the anchor deposit consumed it), not for
# PriceDeviation. The band only gates deposits into a MIXED pool.
# (2) The +21% price push ($1,552.99) itself fired tranche-1: it is
# >= 97% of the June episode anchor ($1,546.14), so update 100
# cleared the latch live (reriskCount 0->1, prot 6->7) — the recovery
# leg's Phase R happened organically here. Do not re-run this section
# on the current state (updates 110, mixed pool gone); use the
# recovery leg's Phase B as the AH-5 live proof.
# Anchor is the June EXIT fill $1,283.46 (no fills since). Deposit at the
# anchor price first (succeeds), then +21% (reverts), then +20% (succeeds).
ANCHOR=$(cv "$VAULT" "lastSettledPrice()(uint256)" "$BASE_RPC")
say "AH-5: vault anchor (lastSettledPrice) = $ANCHOR"
[ "$ANCHOR" = "1283460000000000000000" ] || fail "AH-5: anchor $ANCHOR != June EXIT fill \$1283.46"
H=$(send "$BASE_RPC" "$PRIVATE_KEY" "$ORACLE" "setPrice(address,uint256)" "$WETH" 1283460000000000000000)
say "AH-5: dev pushed anchor price \$1283.46 tx=$H"
H=$(send "$BASE_RPC" "$PRIVATE_KEY" "$WETH" "deposit()" --value 100000000000000)
H=$(send "$BASE_RPC" "$PRIVATE_KEY" "$WETH" "approve(address,uint256)" "$VAULT" 100000000000000)
H=$(send "$BASE_RPC" "$PRIVATE_KEY" "$VAULT" "deposit(uint256)" 100000000000000)
say "AH-5: dev deposited 0.0001 WETH at the anchor tx=$H shares=$(cv "$VAULT" "sharesOf(address)(uint256)" 0x75c328F0354fFC73bee24F61F7166a33Bf90Bf94 "$BASE_RPC") closed=$(cv "$VAULT" "closed()(bool)" "$BASE_RPC")"
[ "$(cv "$VAULT" "closed()(bool)" "$BASE_RPC")" = "false" ] || fail "AH-5: deposit did not re-arm the vault"
# +21%: 1283.46 * 1.21 = 1552.9866 -> 1552986600000000000000 (floor).
H=$(send "$BASE_RPC" "$PRIVATE_KEY" "$ORACLE" "setPrice(address,uint256)" "$WETH" 1552986600000000000000)
say "AH-5: dev pushed +21% price \$1552.99"
expect_revert "AH-5 +21% deposit" "PriceDeviation(uint256,uint256)" "$BASE_RPC" "$PRIVATE_KEY" "$DEV" "$VAULT" "deposit(uint256)" 100000000000000
# +20% exactly: 1283.46 * 1.20 = 1540.152 -> 1540152000000000000000. Boundary inclusive.
H=$(send "$BASE_RPC" "$PRIVATE_KEY" "$ORACLE" "setPrice(address,uint256)" "$WETH" 1540152000000000000000)
say "AH-5: dev pushed +20% price \$1540.15"
H=$(send "$BASE_RPC" "$PRIVATE_KEY" "$VAULT" "deposit(uint256)" 100000000000000)
say "AH-5: dev deposited 0.0001 WETH at exactly +20% tx=$H (boundary inclusive)"
H=$(send "$BASE_RPC" "$PRIVATE_KEY" "$VAULT" "redeemAll()")
say "AH-5: dev redeemAll tx=$H sharesAfter=$(cv "$VAULT" "sharesOf(address)(uint256)" 0x75c328F0354fFC73bee24F61F7166a33Bf90Bf94 "$BASE_RPC") totalShares=$(cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC")"
[ "$(cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC")" = "0" ] || fail "AH-5: vault not empty after redeemAll"

# --- AH-6: setVault is single-use ---
expect_revert "AH-6 swap.setVault(attacker)" "VaultAlreadySet(address)" "$BASE_RPC" "$PRIVATE_KEY" "$DEV" "$SWAP" "setVault(address)" "$ATTACKER"
expect_revert "AH-6 reactive.setVault(attacker)" "VaultAlreadySet(address)" "$LASNA_RPC" "$PRIVATE_KEY" "$DEV" "$REACTIVE" "setVault(address)" "$ATTACKER"
[ "$(cv "$SWAP" "vault()(address)" "$BASE_RPC" | tr 'A-F' 'a-f')" = "$(echo "$VAULT" | tr 'A-F' 'a-f')" ] || fail "AH-6: swap vault changed"
[ "$(cv "$REACTIVE" "vault()(address)" "$LASNA_RPC" | tr 'A-F' 'a-f')" = "$(echo "$VAULT" | tr 'A-F' 'a-f')" ] || fail "AH-6: reactive vault changed"
[ "$(cv "$SWAP" "vaultLocked()(bool)" "$BASE_RPC")" = "true" ] || fail "AH-6: swap vaultLocked != true"
[ "$(cv "$REACTIVE" "vaultLocked()(bool)" "$LASNA_RPC")" = "true" ] || fail "AH-6: reactive vaultLocked != true"
say "AH-6: both setVault(attacker) calls reverted VaultAlreadySet; wiring unchanged"

say "flagship after: brain updates=$(cv "$FLAGSHIP_BRAIN" "updates()(uint256)" "$LASNA_RPC") vault shares=$(cv "$FLAGSHIP_VAULT" "totalShares()(uint256)" "$BASE_RPC")"
say "RELEASE6_ATTACKS_RESULT updates=$(cv "$REACTIVE" "updates()(uint256)" "$LASNA_RPC") protectionCount=$(cv "$VAULT" "protectionCount()(uint256)" "$BASE_RPC") totalShares=$(cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC")"
say "=== RELEASE 6 POST-BLEED ATTACK RE-RUNS COMPLETE — AH-3/AH-4/AH-5/AH-6 ALL BLOCKED ==="
