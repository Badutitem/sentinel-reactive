// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {SentinelModelV2} from "./model/SentinelModelV2.sol";

/// @title SentinelReactiveV6 — Release 6: post-EXIT latch (AH-2), sane-price floor (AH-3), single-use wiring (AH-6).
/// @notice SentinelReactiveV5 (Release 8 fixed code) plus the V6 patches
///         in V6-DESIGN.md. The model, weights, features, anchor, cooldown,
///         TRIM suppression and re-risk variant B are untouched. What is
///         new: (AH-2) after an EXIT fires, protection callbacks stay
///         latched off until a re-risk tranche fires or the episode
///         cancels/closes — a sustained bleed can no longer burn the
///         brain's fuel on no-op repeat EXITs; (AH-3) prices below $1
///         are consumed but never ingested, alongside the $1M ceiling;
///         (AH-6) `setVault` wires once and locks forever.
/// @dev Deploy order matters (Omni callback model):
///        1. deploy this contract (fund it with lREACT — it pays for its own
///           reactive transactions; a contract in debt receives nothing),
///        2. deploy SentinelVaultV6 with this contract's address,
///        3. call `setVault` here so callbacks have a recipient (once —
///           the second call reverts `VaultAlreadySet`).
///      Intended deployment (Release 6, NOT deployed — rehearsal candidate):
///      origin = Base Sepolia, oracle = the MockPriceOracle (rehearsal) or
///      the ChainlinkPriceAdapter (live), token = WETH, cooldown = 300 s.
contract SentinelReactiveV6 is AbstractReactive {
    /// @notice topic0 of PriceUpdated(address,uint256,uint256) — emitted by both
    ///         MockPriceOracle and the ChainlinkPriceAdapter.
    uint256 internal constant PRICE_UPDATED_TOPIC0 = uint256(keccak256("PriceUpdated(address,uint256,uint256)"));

    /// @notice Fixed-point scale for features (1e6 = 1.0).
    int256 internal constant SCALE = 1_000_000;
    /// @notice Prices kept in the ring buffer (=> WINDOW - 1 returns).
    uint256 internal constant WINDOW = 9;
    /// @notice Inference starts once at least this many prices were seen.
    uint256 internal constant MIN_UPDATES = 3;
    /// @notice Gas limit granted to the destination callback.
    uint64 internal constant CALLBACK_GAS_LIMIT = 1_000_000;
    /// @notice Release 8 (F4/L8): prices above this are ignored at the top
    ///         of `react()` instead of entering the window — $1,000,000 at
    ///         the 1e18 price scale, ~370x the highest price ever ingested
    ///         ($2,707.67) and ~58 orders of magnitude below the `int256`
    ///         wrap threshold. Zero prices are ignored the same way.
    uint256 internal constant MAX_SANE_PRICE = 1_000_000e18;
    /// @notice Release 6 (AH-3): prices below this are ignored the same
    ///         way — $1 at the 1e18 price scale. The lowest legitimate
    ///         price ever ingested is $1,283.46 (June 2022), three orders
    ///         of magnitude above the floor; the 1-wei cliff (a 1-wei
    ///         print firing EXIT and selling the position for dust) is
    ///         18 orders of magnitude below it.
    uint256 internal constant MIN_SANE_PRICE = 1e18;
    /// @notice Leaky-peak decay per price update: anchorPeak x999/1000
    ///         (half-life ~693 updates). Chosen on measured evidence — see
    ///         ANCHOR.md section 2.2. Per-update, not per-second: the constant
    ///         is only valid at the cadence the model was validated at.
    uint256 internal constant ANCHOR_DECAY_NUM = 999;
    uint256 internal constant ANCHOR_DECAY_DEN = 1000;
    /// @notice WHIPSAW HARDENING (v3, kept): after a TRIM callback fires, TRIM
    ///         votes are suppressed for this many subsequent price updates (a
    ///         full ring-buffer turnover is WINDOW = 9; 10 guarantees the
    ///         entire window that produced the first TRIM has been
    ///         replaced before a second TRIM can fire on price action
    ///         alone). EXIT-condition votes bypass the suppression — see
    ///         the check at the firing site.
    uint256 internal constant TRIM_SUPPRESS_UPDATES = 10;
    /// @notice EXIT conditions for the suppression bypass, in feature
    ///         scale: anchorDrawdown (feature 6) at or above 18% — the
    ///         teacher's own anchor EXIT band (ANCHOR.md) — while window
    ///         momentum (feature 4) is negative.
    int256 internal constant EXIT_ANCHOR_DD = 180_000;

    /// @notice Callback action code for re-risk tranche 1
    ///         (SentinelVaultV6.ACTION_RERISK — spends half the safe balance).
    uint8 public constant ACTION_RERISK = 3;
    /// @notice Callback action code for re-risk tranche 2
    ///         (SentinelVaultV6.ACTION_RERISK_FINAL — spends the rest).
    uint8 public constant ACTION_RERISK_FINAL = 4;
    /// @notice RE-RISK: minimum price updates that must pass after the
    ///         de-risk before tranche 1 can fire — a one-print spike back
    ///         into the band is not a proven recovery.
    uint256 internal constant RERISK_MIN_UPDATES = 3;
    /// @notice RE-RISK: tranche-1 reclaim threshold — the current price
    ///         must be at least 97/100 of the episode anchor.
    uint256 internal constant RERISK_RECLAIM_NUM = 97;
    uint256 internal constant RERISK_RECLAIM_DEN = 100;

    uint256 public immutable originChainId;
    address public immutable oracle;
    uint256 public immutable destChainId;
    /// @notice Minimum origin-time between two fired callbacks of the same or
    ///         lower severity. Escalations (TRIM -> EXIT) always fire.
    uint256 public immutable cooldownSeconds;

    address public owner;
    /// @notice Callback recipient (SentinelVaultV6 on the destination chain).
    address public vault;

    uint256[WINDOW] internal _window;
    uint256 internal _next;
    /// @notice Total price updates processed.
    uint256 public updates;
    /// @notice Leaky-peak anchor state (same integer scale as the prices).
    ///         Updated on EVERY ingested price — including warmup prices and
    ///         prices inside a cooldown — because the training semantics define
    ///         the anchor as a pure function of the whole price stream since
    ///         the first price; a skipped update would silently desync the
    ///         feature from the model it was trained for (ANCHOR.md section 6).
    ///         (A REPLAYED log is not an ingested price — v3 repair 1 — so it
    ///         correctly does not advance the anchor.)
    uint256 public anchorPeak;
    /// @notice Features from the most recent inference (1e6 scale).
    int256[7] public lastFeatures;
    /// @notice Logits from the most recent inference [HOLD, TRIM, EXIT].
    int256[3] public lastScores;
    /// @notice Action from the most recent inference.
    uint8 public lastAction;

    /// @notice REPAIR 1 (v3, kept): identities of origin logs already
    ///         processed, keyed by keccak256(chainId, contractAddress,
    ///         txHash, logIndex) of the LogRecord. A log identity is
    ///         unique per origin log, so a redelivery maps to the same
    ///         key and is ignored before any state changes.
    mapping(bytes32 => bool) internal _seenLogs;
    /// @notice How many duplicate logs have been ignored (observability).
    uint256 public duplicatesIgnored;

    /// @notice REPAIR 3 (v3, kept): the `updates` counter value at which
    ///         the most recent TRIM callback fired (0 = no TRIM fired in
    ///         the current position cycle). Reset to 0 when an EXIT
    ///         callback fires, alongside the fired-state reset.
    uint256 public lastTrimFiredUpdate;

    /// @notice RE-RISK (B): a de-risk episode is open (a TRIM/EXIT fired
    ///         and its recovery has neither completed both tranches nor
    ///         cancelled pre-tranche-1).
    bool public episodeActive;
    /// @notice RE-RISK (B): the anchor price in effect when the current
    ///         episode's de-risk fired — the level both tranches are
    ///         measured against. Fixed at episode open; the running
    ///         anchor keeps decaying, this does not.
    uint256 public episodeAnchor;
    /// @notice RE-RISK (B): the `updates` counter value at which the
    ///         current episode's de-risk fired.
    uint256 public episodeStartUpdate;
    /// @notice RE-RISK (B): tranche 1 (action 3, half spend) has fired
    ///         for the current episode.
    bool public tranche1Fired;
    /// @notice RE-RISK (B): tranche 2 (action 4, spend the rest) has
    ///         fired for the current episode; the episode closes with it.
    bool public tranche2Fired;
    /// @notice RE-RISK (B): total re-risk tranche callbacks requested,
    ///         all episodes (each completed episode contributes 2).
    uint256 public reriskCount;

    /// @notice Release 6 (AH-2): post-EXIT latch. True once an EXIT
    ///         callback has fired and until a re-risk tranche fires or
    ///         the episode cancels/closes (see `_clearLatch`). While
    ///         latched, TRIM/EXIT votes still decide (the `Decision`
    ///         event is emitted) but no protection callback is
    ///         requested: after the vault closed, repeat EXITs are pure
    ///         fuel burn. The brain cannot read the vault's `closed`
    ///         flag cross-chain, so this is brain-local state.
    bool public exitLatched;

    uint8 internal _lastFiredAction;
    uint256 internal _lastFiredTs;

    /// @notice Release 6 (AH-6): wiring lock. True once `setVault` has
    ///         been called; any later call reverts `VaultAlreadySet`.
    bool public vaultLocked;

    error VaultAlreadySet(address vault);

    event PriceSeen(uint256 price, uint256 originTimestamp, uint256 updates);
    event Decision(
        uint256 price, uint256 originTimestamp, uint8 action, int256 holdScore, int256 trimScore, int256 exitScore
    );
    event CallbackRequested(uint8 action, uint256 originTimestamp);
    event TrimSuppressed(uint256 price, uint256 originTimestamp, uint256 updates);
    event EpisodeOpened(uint256 episodeAnchor, uint256 updates);
    event EpisodeCancelled(uint256 price, uint256 originTimestamp, uint256 updates);
    event VaultSet(address vault);
    /// @notice Release 6 (AH-2): emitted whenever the post-EXIT latch
    ///         is set (an EXIT fired) or cleared (a tranche fired or
    ///         the episode cancelled/closed).
    event PostExitLatch(bool latched, uint256 updates);

    /// @param originChainId_ Chain the oracle lives on (Base Sepolia = 84532).
    /// @param oracle_ Price-source address on the origin chain (the
    ///        ChainlinkPriceAdapter for the live deployment; MockPriceOracle
    ///        for the mock-origin rehearsal).
    /// @param token_ Token whose PriceUpdated events to follow (matched as topic1).
    /// @param destChainId_ Chain the vault lives on (Base Sepolia = 84532).
    /// @param cooldownSeconds_ Anti-spam cooldown between non-escalating callbacks.
    constructor(uint256 originChainId_, address oracle_, address token_, uint256 destChainId_, uint256 cooldownSeconds_)
        payable {
        originChainId = originChainId_;
        oracle = oracle_;
        destChainId = destChainId_;
        cooldownSeconds = cooldownSeconds_;
        owner = msg.sender;
        SYSTEM.subscribe(
            originChainId_, oracle_, PRICE_UPDATED_TOPIC0, uint256(uint160(token_)), REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    /// @notice Sets the callback recipient. Owner-only; step 3 of deployment.
    /// @dev Release 6 (AH-6): single-use. The first call wires the vault
    ///      and locks forever; any later call reverts `VaultAlreadySet`
    ///      — after deploy, no owner (compromised or otherwise) can
    ///      redirect the brain's callbacks to another recipient.
    function setVault(address vault_) external {
        require(msg.sender == owner, "Sentinel: not owner");
        if (vaultLocked) revert VaultAlreadySet(vault);
        vault = vault_;
        vaultLocked = true;
        emit VaultSet(vault_);
    }

    /// @notice Entry point called by the system contract for every subscribed log.
    /// @dev Non-matching logs fall through silently (reverting would still bill us).
    function react(IReactive.LogRecord calldata log_) external override onlySystem {
        if (log_.topic0 != PRICE_UPDATED_TOPIC0) return;
        if (log_.chainId != originChainId) return;

        // REPAIR 1 — replay dedup. The log's identity is unique on its
        // origin chain; if we have processed it before, ignore the
        // redelivery completely (no window push, no anchor step, no
        // inference, no callback, no events). The identity is recorded
        // BEFORE processing so that even a log whose processing ends in
        // the warmup return is deduplicated.
        bytes32 logKey = keccak256(abi.encode(log_.chainId, log_.contractAddress, log_.txHash, log_.logIndex));
        if (_seenLogs[logKey]) {
            duplicatesIgnored++;
            return;
        }
        _seenLogs[logKey] = true;

        (uint256 price, uint256 originTs) = abi.decode(log_.data, (uint256, uint256));
        // Release 8 (F4/L8) + Release 6 (AH-3): a zero, sub-dollar or
        // absurd price is consumed (marked seen above, so it is never
        // redelivered into a revert loop) but never enters the window:
        // no push, no PriceSeen event, `updates` does not advance. One
        // bad print can never wedge the brain or dump the position
        // for dust.
        if (price < MIN_SANE_PRICE || price > MAX_SANE_PRICE) return;
        _push(price);
        emit PriceSeen(price, originTs, updates);
        if (updates < MIN_UPDATES) return;

        int256[7] memory features = _features();
        (uint8 action, int256[3] memory logits,) = SentinelModelV2.predict(features);
        lastFeatures = features;
        lastScores = logits;
        lastAction = action;
        emit Decision(price, originTs, action, logits[0], logits[1], logits[2]);

        // RE-RISK (B) — episode evaluation. Rule-based and independent
        // of the model vote above: a recovery is by definition a
        // stretch of prices the protection model mostly HOLDs, so the
        // check cannot live inside the protection path. It runs on
        // every ingested update while an episode is open (replays
        // never reach here — dedup returned already), BEFORE this
        // update's own protection processing, so an episode opened by
        // a de-risk firing on THIS update is first evaluated on the
        // NEXT one ("subsequent").
        if (episodeActive && vault != address(0)) {
            _evaluateEpisode(price, originTs);
        }

        if (action == SentinelModelV2.HOLD || vault == address(0)) return;

        // Release 6 (AH-2) — post-EXIT latch. After an EXIT fired, the
        // vault is closed, so every further TRIM/EXIT vote is a
        // no-op callback that still burns brain fuel. Withhold the
        // callback (the vote itself stands — `Decision` above). The
        // latch clears only in `_evaluateEpisode` (tranche fire or
        // episode cancel/close), so a sustained bleed requests no
        // further protection callbacks at all.
        if (exitLatched) return;

        // REPAIR 3 — whipsaw hardening. A TRIM vote inside the
        // suppression window opened by the last fired TRIM does not
        // fire, UNLESS the EXIT conditions hold at this vote
        // (anchorDrawdown >= 18% with negative window momentum): a
        // position in EXIT territory must never wait out an anti-flap
        // timer. The vote itself stands (Decision above); only the
        // callback is withheld, and the suppression is observable via
        // the TrimSuppressed event.
        if (
            action == SentinelModelV2.TRIM && lastTrimFiredUpdate != 0
                && updates - lastTrimFiredUpdate <= TRIM_SUPPRESS_UPDATES
        ) {
            bool exitConditions = features[6] >= EXIT_ANCHOR_DD && features[4] < 0;
            if (!exitConditions) {
                emit TrimSuppressed(price, originTs, updates);
                return;
            }
        }

        bool escalation = action > _lastFiredAction;
        bool cooledDown = originTs >= _lastFiredTs + cooldownSeconds;
        if (!escalation && !cooledDown) return;

        // The payload's first argument MUST be an address(0) placeholder: the
        // network overwrites it with this contract's address so the vault can
        // authenticate the callback.
        bytes memory payload = abi.encodeWithSignature("executeProtection(address,uint8)", address(0), action);
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destChainId, recipient: vault, gasLimit: CALLBACK_GAS_LIMIT, payload: payload
            })
        );
        if (action == SentinelModelV2.EXIT) {
            // Release 8 (F3): the fired state is KEPT across the EXIT.
            // Resetting it to HOLD/0 made every subsequent EXIT vote an
            // "escalation" that bypassed the cooldown entirely — one
            // callback per price update for as long as the crash lasts.
            // Keeping EXIT + originTs makes every repeat EXIT
            // cooldown-gated at 300 s instead. Accepted cost: a genuinely
            // new position's first TRIM can wait up to 300 s, because a
            // TRIM vote (1 > 2 is false) is not an escalation either.
            // Only the TRIM-suppression state resets: suppression belongs
            // to the cycle the EXIT closed.
            _lastFiredAction = SentinelModelV2.EXIT;
            _lastFiredTs = originTs;
            lastTrimFiredUpdate = 0;
            // Release 6 (AH-2): latch protection callbacks off. At live
            // cadence the 300 s cooldown always passes, so without the
            // latch a sustained bleed would still fire one EXIT per
            // price update — all no-ops after the vault closed. The
            // latch clears only when the position is partially or
            // fully restored (tranche fire) or the episode cancels.
            exitLatched = true;
            emit PostExitLatch(true, updates);
        } else {
            _lastFiredAction = action;
            _lastFiredTs = originTs;
            // REPAIR 3: a fired TRIM opens its suppression window.
            lastTrimFiredUpdate = updates;
        }
        // RE-RISK (B): a fired de-risk (TRIM or EXIT) opens a fresh
        // episode, replacing any episode still open — the anchor and
        // start point of the LATEST de-risk are the ones its recovery
        // is measured against, and both tranche flags reset with it.
        // (A tranche fired earlier in this same update already
        // advanced the old episode; this fire then replaces it.)
        episodeAnchor = anchorPeak;
        episodeStartUpdate = updates;
        episodeActive = true;
        tranche1Fired = false;
        tranche2Fired = false;
        emit EpisodeOpened(anchorPeak, updates);
        emit CallbackRequested(action, originTs);
    }

    /// @notice RE-RISK (B): evaluates the open episode against the price
    ///         just ingested, in the mirror's exact order:
    ///           - tranche 1 pending: the reclaim check runs FIRST
    ///             (>= 3 updates since the de-risk and price >= 97% of
    ///             the episode anchor fires action 3); only if it does
    ///             not fire does the cancel check run (anchor above the
    ///             episode anchor ends the episode silently);
    ///           - tranche 1 done: no cancel — the episode ends when
    ///             the anchor exceeds the episode anchor (action 4) or
    ///             a fresh de-risk refreshes the episode.
    function _evaluateEpisode(uint256 price, uint256 originTs) internal {
        if (!tranche1Fired) {
            if (
                updates - episodeStartUpdate >= RERISK_MIN_UPDATES
                    && price * RERISK_RECLAIM_DEN >= episodeAnchor * RERISK_RECLAIM_NUM
            ) {
                tranche1Fired = true;
                reriskCount++;
                // Release 6 (AH-2): the position is partially restored
                // (half the safe balance bought back into risk), so the
                // restored half deserves protection again.
                _clearLatch();
                _requestCallback(ACTION_RERISK, originTs);
                return;
            }
            if (anchorPeak > episodeAnchor) {
                episodeActive = false;
                // Release 6 (AH-2): the market recovered strongly and
                // the episode is over — protection evaluation returns
                // to normal (worst case one no-op fire, then re-latch).
                _clearLatch();
                emit EpisodeCancelled(price, originTs, updates);
            }
            return;
        }
        if (!tranche2Fired && anchorPeak > episodeAnchor) {
            tranche2Fired = true;
            episodeActive = false;
            // Release 8 (L3): a tranche-2 close means the position is
            // fully bought back, so a new cycle starts and a fresh TRIM
            // must be allowed — suppression is per position cycle, not
            // per brain lifetime. An episode CANCEL (pre-tranche-1) does
            // NOT reset it: the position is still de-risked and no new
            // cycle has started.
            lastTrimFiredUpdate = 0;
            // Release 6 (AH-2): full restoration clears the latch.
            _clearLatch();
            reriskCount++;
            _requestCallback(ACTION_RERISK_FINAL, originTs);
        }
    }

    /// @notice Release 6 (AH-2): clears the post-EXIT latch, if set.
    ///         Idempotent — emits nothing when already clear.
    function _clearLatch() internal {
        if (exitLatched) {
            exitLatched = false;
            emit PostExitLatch(false, updates);
        }
    }

    /// @notice Requests one re-risk tranche callback (same payload shape
    ///         as the protection callbacks: address(0) sender slot).
    function _requestCallback(uint8 action, uint256 originTs) internal {
        bytes memory payload = abi.encodeWithSignature("executeProtection(address,uint8)", address(0), action);
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destChainId, recipient: vault, gasLimit: CALLBACK_GAS_LIMIT, payload: payload
            })
        );
        emit CallbackRequested(action, originTs);
    }

    function _push(uint256 price) internal {
        _updateAnchor(price);
        _window[_next] = price;
        _next = (_next + 1) % WINDOW;
        updates++;
    }

    /// @notice Advances the leaky-peak anchor by one price:
    ///         anchorPeak = max(price, anchorPeak * 999 / 1000), with the very
    ///         first price initialising the peak (so the peak is never zero
    ///         when a feature is computed from a real price). Integer math on
    ///         non-negative values — floor division, identical to the
    ///         off-chain mirror (`anchor_update` in tools/train.py).
    function _updateAnchor(uint256 price) internal {
        if (updates == 0) {
            anchorPeak = price;
            return;
        }
        uint256 decayed = anchorPeak * ANCHOR_DECAY_NUM / ANCHOR_DECAY_DEN;
        anchorPeak = price > decayed ? price : decayed;
    }

    /// @notice Returns the ring buffer as an ordered (oldest -> newest) window.
    function _ordered() internal view returns (uint256[WINDOW] memory p, uint256 n) {
        n = updates < WINDOW ? updates : WINDOW;
        if (updates < WINDOW) {
            for (uint256 i = 0; i < n; i++) {
                p[i] = _window[i];
            }
        } else {
            for (uint256 i = 0; i < WINDOW; i++) {
                p[i] = _window[(_next + i) % WINDOW];
            }
        }
    }

    /// @notice Computes the seven model features from the current window plus
    ///         the anchor state. All values are 1e6-scaled; signed divisions
    ///         truncate toward zero exactly like the off-chain reference
    ///         implementation.
    ///         [0] last return, [1] mean return, [2] RMS volatility,
    ///         [3] drawdown from window peak, [4] window momentum,
    ///         [5] last price vs window mean price,
    ///         [6] anchor drawdown: (anchorPeak - last) / anchorPeak, from the
    ///         anchor state AFTER this window's newest price was ingested.
    function _features() internal view returns (int256[7] memory f) {
        (uint256[WINDOW] memory p, uint256 n) = _ordered();

        uint256 peak = 0;
        uint256 sumPrice = 0;
        for (uint256 i = 0; i < n; i++) {
            if (p[i] > peak) peak = p[i];
            sumPrice += p[i];
        }
        uint256 mean = sumPrice / n;

        // Release 8 (F4), defence in depth: the `react()` guard admits no
        // zero price, so this branch is unreachable in a fresh deploy —
        // but if any future path ever pushes a zero, the divisions below
        // (by `p[i-1]`, `p[0]`, `mean`, `peak`) must not re-brick the
        // brain. Return the zero-initialised feature array instead.
        if (peak == 0 || p[0] == 0 || mean == 0) return f;

        int256 sumRet = 0;
        uint256 sumSq = 0;
        int256 lastRet = 0;
        for (uint256 i = 1; i < n; i++) {
            int256 r = (int256(p[i]) - int256(p[i - 1])) * SCALE / int256(p[i - 1]);
            sumRet += r;
            sumSq += uint256(r * r);
            lastRet = r;
        }

        uint256 m = n - 1;
        f[0] = lastRet;
        f[1] = sumRet / int256(m);
        f[2] = int256(_isqrt(sumSq / m));
        f[3] = (int256(peak) - int256(p[n - 1])) * SCALE / int256(peak);
        f[4] = (int256(p[n - 1]) - int256(p[0])) * SCALE / int256(p[0]);
        f[5] = (int256(p[n - 1]) - int256(mean)) * SCALE / int256(mean);
        // anchorPeak >= p[n-1] always (the update for this very price took
        // the max with it), so the subtraction cannot underflow. The zero
        // guard only covers the degenerate case of a zero first price, where
        // the off-chain mirror is likewise undefined.
        f[6] = anchorPeak == 0 ? int256(0) : int256((anchorPeak - p[n - 1]) * uint256(SCALE) / anchorPeak);
    }

    /// @notice Floor integer square root (Babylonian).
    function _isqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
