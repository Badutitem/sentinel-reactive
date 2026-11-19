#!/usr/bin/env python3
"""
Re-risk variant evaluation harness (trio #5 follow-up).

Builds a Python mirror of the FULL SentinelReactiveV4 + SentinelVaultV3 +
SentinelSwapV2 stack — shipped v2 model inference (tools/train.py
forward_int_v2 over the parsed SentinelWeightsV2.sol), anchor / TRIM
suppression / cooldown-escalation semantics, the re-risk episode machine,
and the fixed-price desk's exact integer math — then runs five re-risk
trigger variants over real and synthetic price streams:

  OFF  re-risk disabled (the no-rerisk Sentinel baseline)
  V1   shipped trio #5 rule: 100% buyback at >= 97% of the episode
       anchor, >= 3 updates after the de-risk, one per episode, episode
       cancelled by a new anchor high above the episode anchor
  B    scale-in: 50% of the safe balance at the >= 97% reclaim (action
       3), the remaining 50% when the running anchor sets a NEW high
       above the episode anchor (action 4)
  C    exit-price reclaim: 100% when price reclaims the last de-risk
       fill price (the price the fired TRIM/EXIT executed at) instead
       of 97% of the anchor
  D    reclaim + momentum: V1's reclaim AND the model's window-momentum
       feature (feature 4) positive on 2 consecutive inference updates
  E    differentiated: TRIM episodes reclaim at 95%, EXIT episodes at
       99% (100% spend either way)

Everything else — model, suppression, cooldown, cancel rule (except B's
tranche interaction, documented in RERISK-VARIANTS.md), desk math — is
identical across variants, so every difference in the table is the
trigger rule and nothing else.

Mirror discipline: the mirror is validated FIRST against the streams
pinned in the Foundry V4 suites (SentinelReactiveV4.t.sol,
SentinelReactiveV4EndToEnd.t.sol, SentinelAdversarialV4.t.sol) —
callback sequences, episode anchors, and desk-exact vault balances must
match bit-for-bit before any scenario number is produced. A validation
failure aborts the run.

Conventions: streams are hourly (3600 s spacing, cooldown 300 s never
binds — the same convention as BACKTEST.md; the validation streams keep
their Foundry 400 s spacing, which also never binds); callbacks are
delivered immediately at the firing update's print (the Foundry
end-to-end delivery discipline); every scenario starts with a $1,000
position at the first price; the desk starts with a 1,000,000 USDC
reserve and zero risk inventory, exactly like the end-to-end test
setup. Both tokens are 18 decimals (MockUSDC is 18, per its source).

Real episodes: the same /tmp/klines_<episode>.json caches the repo's
backtest uses (Binance ETHUSDT 1h closes x1e8; windows and lengths in
ANCHOR.md Appendix C). If a cache file is absent the episode is
reported MISSING — this harness never fetches anything.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import train as T

HOLD, TRIM, EXIT = T.HOLD, T.TRIM, T.EXIT
RERISK = 3        # action 3: V1/C/D/E full spend; B first tranche (50%)
RERISK_FINAL = 4  # action 4: B second tranche (spend the rest) only
ROOT = Path(__file__).resolve().parent.parent
W2 = T.parse_weights_v2_sol(ROOT / "src" / "model" / "SentinelWeightsV2.sol")

WINDOW = 9
MIN_UPDATES = 3
TRIM_SUPPRESS_UPDATES = 10
EXIT_ANCHOR_DD = 180_000
RERISK_MIN_UPDATES = 3
COOLDOWN = 300

E18 = 10 ** 18
DESK_SAFE_SEED = 1_000_000 * E18

EPISODES = ("may2021", "jun2022", "aug2024", "sep2023", "feb2024")


def p18(price_1e8):
    """Reactive-side prices are 1e8-scaled; the desk trades 1e18-scaled."""
    return price_1e8 * 10 ** 10


# ---------------------------------------------------------------------------
# Desk + vault mirror (SentinelSwapV2 / SentinelVaultV3 integer math).
# ---------------------------------------------------------------------------

class Desk:
    """SentinelSwapV2 with 18/18-decimal tokens. Swaps return the filled
    amounts exactly as the contract moves them."""

    def __init__(self):
        self.safe = DESK_SAFE_SEED   # safe-asset reserve
        self.risk = 0                # risk-asset inventory

    def swap_risk_for_safe(self, risk_in, price):
        """Returns (safe_out, risk_filled). Never 'reverts': partial
        fill on a short reserve, 0 on price == 0."""
        if risk_in == 0 or price == 0:
            return 0, 0
        filled = risk_in
        safe_out = risk_in * price // E18
        if safe_out > self.safe:
            filled = self.safe * E18 // price
            if filled > risk_in:
                filled = risk_in
            safe_out = filled * price // E18
        self.risk += filled
        self.safe -= safe_out
        return safe_out, filled

    def swap_safe_for_risk(self, safe_in, price):
        """Returns (risk_out, safe_filled). Partial fill on short risk
        inventory, 0 on price == 0."""
        if safe_in == 0 or price == 0:
            return 0, 0
        filled = safe_in
        risk_out = safe_in * E18 // price
        if risk_out > self.risk:
            filled = self.risk * price // E18
            if filled > safe_in:
                filled = safe_in
            risk_out = filled * E18 // price
        self.safe += filled
        self.risk -= risk_out
        return risk_out, filled


class Vault:
    """SentinelVaultV3.executeProtection, delivered callbacks only."""

    def __init__(self, desk, risk_wei):
        self.desk = desk
        self.risk = risk_wei
        self.safe = 0
        self.closed = False
        self.protection_count = 0
        self.rerisk_count = 0

    def execute(self, action, price, spend_half=False):
        """Delivers one callback at `price` (1e18 scale). Returns the
        safe amount actually spent if a buyback moved risk, else 0."""
        spent = 0
        if action in (RERISK, RERISK_FINAL):
            if self.safe > 0:
                if action == RERISK_FINAL or not spend_half:
                    spend = self.safe
                else:
                    spend = self.safe // 2
                risk_out, filled = self.desk.swap_safe_for_risk(spend, price)
                if risk_out > 0:
                    self.risk += risk_out
                    self.safe -= filled
                    self.closed = False
                    self.rerisk_count += 1
                    spent = filled
        elif not self.closed and self.risk > 0:
            if action == EXIT:
                safe_in, filled = self.desk.swap_risk_for_safe(self.risk, price)
                self.risk -= filled
                self.safe += safe_in
                self.closed = True
            elif action == TRIM:
                safe_in, filled = self.desk.swap_risk_for_safe(self.risk // 2, price)
                self.risk -= filled
                self.safe += safe_in
        self.protection_count += 1
        return spent


# ---------------------------------------------------------------------------
# Reactive mirror (SentinelReactiveV4) with a parameterised episode machine.
# ---------------------------------------------------------------------------

class Reactive:
    def __init__(self, variant):
        assert variant in ("OFF", "V1", "B", "C", "D", "E")
        self.variant = variant
        self.window = []            # ordered, oldest -> newest, <= 9
        self.updates = 0
        self.anchor = 0
        self.last_fired_action = HOLD
        self.last_fired_ts = 0
        self.last_trim_fired_update = 0
        # episode machine
        self.episode_active = False
        self.episode_anchor = 0
        self.episode_start = 0
        self.episode_kind = None    # TRIM or EXIT that opened the episode
        self.episode_fill = 0       # price the opening de-risk executed at
        self.rerisk_used = False    # V1/C/D/E: the one re-risk is spent
        self.tranche1 = False       # B only
        self.tranche2 = False       # B only
        self.episode_id = 0
        # variant D: consecutive inference updates with feature[4] > 0
        self.mom_streak = 0
        # observability
        self.callbacks = []         # (update, action)
        self.episodes_opened = []   # dicts, for validation
        self.cancels = []           # updates at which an episode cancelled
        self.buyback_events = []    # (episode_id, update, vault risk after)

    # -- episode evaluation (runs after inference, before protection) --
    def _evaluate_episode(self, price, vault, desk_price):
        if not self.episode_active or self.variant == "OFF":
            return
        if self.variant == "B":
            self._evaluate_b(price, vault, desk_price)
            return
        if self.rerisk_used:
            return
        # cancel first (V1 semantics, kept by C/D/E): a new anchor high
        # above the episode anchor ends the episode with no callback.
        if self.anchor > self.episode_anchor:
            self.episode_active = False
            self.cancels.append(self.updates)
            return
        if self.updates - self.episode_start < RERISK_MIN_UPDATES:
            return
        if self.variant == "V1":
            fire = price * 100 >= self.episode_anchor * 97
        elif self.variant == "C":
            fire = price >= self.episode_fill
        elif self.variant == "D":
            fire = price * 100 >= self.episode_anchor * 97 and self.mom_streak >= 2
        elif self.variant == "E":
            num = 95 if self.episode_kind == TRIM else 99
            fire = price * 100 >= self.episode_anchor * num
        if fire:
            self.rerisk_used = True
            self.episode_active = False
            self.callbacks.append((self.updates, RERISK))
            before = vault.risk
            vault.execute(RERISK, desk_price)
            if vault.risk > before:
                self.buyback_events.append((self.episode_id, self.updates, vault.risk))

    def _evaluate_b(self, price, vault, desk_price):
        if not self.tranche1:
            # Reclaim check first: a print above the anchor also satisfies
            # >= 97%, and B's first tranche is the reclaim tranche. Only a
            # runaway high that arrives BEFORE the 3-update minimum (or
            # while price sits below the band on a decaying-anchor quirk)
            # cancels, exactly as V1's cancel would.
            if (self.updates - self.episode_start >= RERISK_MIN_UPDATES
                    and price * 100 >= self.episode_anchor * 97):
                self.tranche1 = True
                self.callbacks.append((self.updates, RERISK))
                before = vault.risk
                vault.execute(RERISK, desk_price, spend_half=True)
                if vault.risk > before:
                    self.buyback_events.append(
                        (self.episode_id, self.updates, vault.risk))
                return
            if self.anchor > self.episode_anchor:
                self.episode_active = False
                self.cancels.append(self.updates)
            return
        if not self.tranche2:
            if self.anchor > self.episode_anchor:
                self.tranche2 = True
                self.episode_active = False
                self.callbacks.append((self.updates, RERISK_FINAL))
                before = vault.risk
                vault.execute(RERISK_FINAL, desk_price)
                if vault.risk > before:
                    self.buyback_events.append(
                        (self.episode_id, self.updates, vault.risk))

    # -- one ingested price (dedup is a stream-level concern; every price
    #    fed here is a unique log, as in the Foundry suites) --
    def react(self, price, ts, vault):
        # _push + _updateAnchor
        if self.updates == 0:
            self.anchor = price
        else:
            decayed = self.anchor * 999 // 1000
            self.anchor = price if price > decayed else decayed
        self.window.append(price)
        if len(self.window) > WINDOW:
            self.window.pop(0)
        self.updates += 1
        if self.updates < MIN_UPDATES:
            return

        features = T.features7_from_window(self.window, self.anchor)
        action, _logits, _hidden = T.forward_int_v2(features, *W2)
        if features[4] > 0:
            self.mom_streak += 1
        else:
            self.mom_streak = 0

        # episode evaluation BEFORE this update's protection processing
        self._evaluate_episode(price, vault, p18(price))

        if action == HOLD:
            return

        # TRIM suppression (repair 3), EXIT conditions bypass
        if (action == TRIM and self.last_trim_fired_update != 0
                and self.updates - self.last_trim_fired_update <= TRIM_SUPPRESS_UPDATES):
            exit_conditions = features[6] >= EXIT_ANCHOR_DD and features[4] < 0
            if not exit_conditions:
                return

        escalation = action > self.last_fired_action
        cooled = ts >= self.last_fired_ts + COOLDOWN
        if not escalation and not cooled:
            return

        # fire: deliver immediately at this print
        self.callbacks.append((self.updates, action))
        vault.execute(action, p18(price))
        if action == EXIT:
            self.last_fired_action = HOLD
            self.last_fired_ts = 0
            self.last_trim_fired_update = 0
        else:
            self.last_fired_action = action
            self.last_fired_ts = ts
            self.last_trim_fired_update = self.updates
        # a fired de-risk opens / refreshes the episode
        if self.variant != "OFF":
            self.episode_anchor = self.anchor
            self.episode_start = self.updates
            self.episode_kind = action
            self.episode_fill = price
            self.episode_active = True
            self.rerisk_used = False
            self.tranche1 = False
            self.tranche2 = False
            self.episode_id += 1
            self.episodes_opened.append({
                "id": self.episode_id, "update": self.updates,
                "anchor": self.episode_anchor, "kind": action,
                "fill": price,
            })


# ---------------------------------------------------------------------------
# Stream runner + metrics
# ---------------------------------------------------------------------------

def run_stream(prices, variant, ts_step=3600, t0=1_700_000_000):
    """prices: 1e8-scaled ints. Returns a result dict."""
    desk = Desk()
    p0_18 = p18(prices[0])
    risk0 = 1000 * E18 * E18 // p0_18  # $1,000 position at the first price
    vault = Vault(desk, risk0)
    rx = Reactive(variant)
    for i, price in enumerate(prices):
        rx.react(price, t0 + i * ts_step, vault)
    buybacks = rx.buyback_events
    final_18 = p18(prices[-1])
    equity_wei = vault.risk * final_18 // E18 + vault.safe
    bh_wei = risk0 * final_18 // E18
    recovered = None
    if buybacks:
        first_ep = buybacks[0][0]
        last_first = [b for b in buybacks if b[0] == first_ep][-1]
        recovered = 100.0 * last_first[2] / risk0
    return {
        "variant": variant,
        "final_equity": equity_wei / E18,
        "bh_equity": bh_wei / E18,
        "rerisks": sum(1 for _, a in rx.callbacks if a in (RERISK, RERISK_FINAL)),
        "buyback_callbacks": sum(1 for _, a in rx.callbacks if a in (RERISK, RERISK_FINAL)),
        "callbacks": list(rx.callbacks),
        "vault_risk": vault.risk,
        "vault_safe": vault.safe,
        "recovered_pct": recovered,
        "episodes": rx.episodes_opened,
        "cancels": rx.cancels,
    }


# ---------------------------------------------------------------------------
# Mirror validation against the Foundry-pinned V4 streams
# ---------------------------------------------------------------------------

def usd(x):
    return int(round(x * 1e8))


CALM = [usd(100), usd(100.5), usd(99.8), usd(100.2), usd(100.1)]


def validate():
    failures = []

    def check(name, cond, detail=""):
        if not cond:
            failures.append(f"{name}: {detail}")

    # (1) bleed -> TRIM@6, EXIT@7, episode anchor/start pinned in the test
    r = run_stream(CALM + [usd(92), usd(81)], "V1", ts_step=400)
    check("bleed callbacks", r["callbacks"] == [(6, TRIM), (7, EXIT)],
          str(r["callbacks"]))
    check("bleed episode anchor", r["episodes"][-1]["anchor"] == 9_999_850_397,
          str(r["episodes"]))
    check("bleed episode start", r["episodes"][-1]["update"] == 7,
          str(r["episodes"]))

    # (2) crash-path parity: +76 -> third callback EXIT@8, anchor pinned
    r = run_stream(CALM + [usd(92), usd(81), usd(76)], "V1", ts_step=400)
    check("parity callbacks",
          r["callbacks"] == [(6, TRIM), (7, EXIT), (8, EXIT)], str(r["callbacks"]))
    check("parity episode anchor", r["episodes"][-1]["anchor"] == 9_989_850_546,
          str(r["episodes"]))

    # (3) scenario (a): reclaim fires exactly one RERISK at update 11
    r = run_stream(CALM + [usd(92), usd(81), usd(85), usd(90), usd(95), usd(98)],
                   "V1", ts_step=400)
    check("(a) rerisk at 11",
          r["callbacks"] == [(6, TRIM), (7, EXIT), (11, RERISK)], str(r["callbacks"]))

    # (4) scenario (b): shallow recovery to 90 -> no rerisk
    r = run_stream(CALM + [usd(92), usd(81), usd(85), usd(88)] + [usd(90)] * 6,
                   "V1", ts_step=400)
    check("(b) no rerisk", r["rerisks"] == 0, str(r["callbacks"]))

    # (5) scenario (c): -0.5% grind, TRIM@8 with pinned anchor, RERISK@11
    grind = [10_000_000_000, 9_950_000_000, 9_900_250_000, 9_850_748_750,
             9_801_495_006, 9_752_487_530, 9_703_725_092, 9_655_206_466]
    r = run_stream(grind + [grind[-1]] * 3, "V1", ts_step=400)
    check("(c) callbacks", r["callbacks"] == [(8, TRIM), (11, RERISK)],
          str(r["callbacks"]))
    check("(c) episode anchor", r["episodes"][-1]["anchor"] == 9_930_209_650,
          str(r["episodes"]))

    # (6) scenario (e): print at 101 cancels at update 8; band later: none
    r = run_stream(CALM + [usd(92), usd(81), usd(101)] + [usd(98)] * 5,
                   "V1", ts_step=400)
    check("(e) cancel at 8", r["cancels"] == [8], str(r["cancels"]))
    check("(e) no rerisk", r["rerisks"] == 0, str(r["callbacks"]))

    # (7) end-to-end: desk-exact balances pinned in the Foundry suite
    e2e = CALM + [usd(92), usd(81), usd(85), usd(90), usd(98), usd(90), usd(80), usd(74)]
    r = run_stream(e2e, "V1", ts_step=3600)
    check("e2e callbacks",
          r["callbacks"] == [(6, TRIM), (7, EXIT), (10, RERISK), (13, EXIT)],
          str(r["callbacks"]))
    check("e2e final safe", r["vault_safe"] == 653_163_265_306_122_448_966,
          str(r["vault_safe"]))
    check("e2e final risk", r["vault_risk"] == 0, str(r["vault_risk"]))
    # mid-cycle balances: rerun truncated at the rerisk delivery (update 10)
    r_mid = run_stream(e2e[:10], "V1", ts_step=3600)
    check("e2e rerisk risk", r_mid["vault_risk"] == 8_826_530_612_244_897_959,
          str(r_mid["vault_risk"]))
    check("e2e rerisk safe", r_mid["vault_safe"] == 0, str(r_mid["vault_safe"]))
    r_trim = run_stream(e2e[:6], "V1", ts_step=3600)
    check("e2e trim balances",
          r_trim["vault_risk"] == 5 * E18 and r_trim["vault_safe"] == 460 * E18,
          f"{r_trim['vault_risk']} / {r_trim['vault_safe']}")
    r_exit = run_stream(e2e[:7], "V1", ts_step=3600)
    check("e2e exit balances",
          r_exit["vault_risk"] == 0 and r_exit["vault_safe"] == 865 * E18,
          f"{r_exit['vault_risk']} / {r_exit['vault_safe']}")

    # (8) adversarial square wave: exact 11-callback sequence pinned
    wave = CALM + [usd(92), usd(81)]
    for _ in range(3):
        wave += [usd(98)] * 6 + [usd(90), usd(82), usd(74), usd(74)]
    r = run_stream(wave, "V1", ts_step=400)
    expected = [TRIM, EXIT] + [RERISK, EXIT, EXIT] * 3
    got = [a for _, a in r["callbacks"]]
    check("square wave sequence", got == expected, str(got))
    check("square wave rerisks", r["rerisks"] == 3, str(r["rerisks"]))

    return failures


# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

def scenario_streams():
    """Synthetic price paths (USD floats -> 1e8 ints in build_scenarios)."""
    drop = [94, 88, 82, 76, 71, 68]
    return {
        # drop -> recover through the band -> keep rising well above the
        # anchor -> hold the top
        "succ_V": CALM_USD + drop + [72, 77, 83, 89, 96, 103, 110, 118, 125, 132]
                  + [132] * 4,
        # drop -> reclaim above every variant's trigger -> fall again to
        # a second EXIT -> stay down
        "fail_V": CALM_USD + drop + [72, 78, 85, 92, 97.5, 99.2, 99.2]
                  + [92, 84, 76, 68, 62] + [60] * 3,
        # the Foundry adversarial square wave (3 cycles)
        "square_wave": None,  # built specially below
        # -0.8%/step for 85 prints: no reclaim ever
        "slow_grind": [100 * (0.992 ** k) for k in range(85)],
        # drop -> EXIT -> 30 prints chopping around the 97% reclaim level
        "chop_trigger": CALM_USD + [92, 81]
                        + [96.6, 98.6, 96.9, 98.3, 97.1, 98.8, 96.7, 98.4,
                           97.3, 98.9, 96.8, 98.2, 97.0, 98.7, 96.6, 98.5,
                           97.2, 98.3, 96.9, 98.8, 97.4, 98.4, 96.7, 98.6,
                           97.1, 98.2, 96.8, 98.5, 97.3, 97.5],
    }


CALM_USD = [100, 100.5, 99.8, 100.2, 100.1]


def build_scenarios():
    out = {}
    for name, floats in scenario_streams().items():
        if name == "square_wave":
            wave = [100, 100.5, 99.8, 100.2, 100.1, 92, 81]
            for _ in range(3):
                wave += [98] * 6 + [90, 82, 74, 74]
            out[name] = [usd(x) for x in wave]
        else:
            out[name] = [usd(x) for x in floats]
    # real episodes, if the repo's kline caches are present
    missing = []
    for name in EPISODES:
        path = Path(f"/tmp/klines_{name}.json")
        if path.exists():
            out[name] = json.loads(path.read_text())
        else:
            missing.append(name)
    return out, missing


VARIANTS = ("OFF", "V1", "B", "C", "D", "E")


def main():
    failures = validate()
    if failures:
        print("MIRROR VALIDATION FAILED — no scenario numbers produced:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("Mirror validation: ALL PASS (8 Foundry-pinned stream groups)\n")

    scenarios, missing = build_scenarios()
    results = {}
    for sname, prices in scenarios.items():
        results[sname] = {v: run_stream(prices, v) for v in VARIANTS}

    print(f"{'scenario':<14}" + "".join(f"{v:>28}" for v in VARIANTS))
    for sname in scenarios:
        off = results[sname]["OFF"]["final_equity"]
        print(f"\n{sname}  (OFF final ${off:,.2f} | B&H ${results[sname]['OFF']['bh_equity']:,.2f})")
        for metric in ("final_equity", "delta_vs_off", "rerisks", "recovered_pct"):
            cells = []
            for v in VARIANTS:
                r = results[sname][v]
                if metric == "final_equity":
                    cells.append(f"${r['final_equity']:,.2f}")
                elif metric == "delta_vs_off":
                    cells.append(f"{r['final_equity'] - off:+,.2f}")
                elif metric == "rerisks":
                    cells.append(str(r["rerisks"]))
                else:
                    cells.append("-" if r["recovered_pct"] is None
                                 else f"{r['recovered_pct']:.1f}%")
            print(f"  {metric:<14}" + "".join(f"{c:>28}" for c in cells))

    if missing:
        print(f"\nMISSING REAL EPISODES (kline caches absent, nothing fetched): "
              f"{', '.join(missing)}")
    # machine-readable dump for the report
    dump = {s: {v: {k: results[s][v][k] for k in
                    ("final_equity", "bh_equity", "rerisks", "recovered_pct")}
                for v in VARIANTS} for s in scenarios}
    Path("/tmp/rerisk_variant_results.json").write_text(json.dumps(dump, indent=1))
    print("\nWrote /tmp/rerisk_variant_results.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
