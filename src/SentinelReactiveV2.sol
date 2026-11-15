// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {SentinelModelV2} from "./model/SentinelModelV2.sol";

/// @title SentinelReactiveV2 — the anchor-aware Sentinel reactive contract (model v2).
/// @notice Same system as SentinelReactive (v1), with the two changes ANCHOR.md
///         specifies:
///           1. A seventh feature, anchorDrawdown, computed from a persistent
///              leaky-peak state (x999/1000 decay per price update), fed to the
///              7 -> 12 -> 3 MLP in SentinelModelV2. V1's drawdown only sees the
///              last 9 prices, so a bleed slower than ~2.6%/step could never
///              reach its EXIT band; the anchor gives the model a long-horizon
///              drawdown and slow bleeds now EXIT (validated in ANCHOR.md).
///           2. The cooldown state-leak fix: when an EXIT callback fires, the
///              fired-state is reset (see the note at the firing site), so a
///              stale EXIT can no longer suppress the next position's first
///              protection callback.
///         Everything else — subscription shape, event surface, callback
///         payload, cooldown semantics for non-EXIT fires — is v1's, and the
///         callback interface stays byte-identical, so SentinelVaultV2 (or V1)
///         can be pointed at this contract via `setVault` unchanged.
/// @dev Deploy order matters (Omni callback model):
///        1. deploy this contract (fund it with lREACT — it pays for its own
///           reactive transactions; a contract in debt receives nothing),
///        2. deploy SentinelVaultV2 with this contract's address,
///        3. call `setVault` here so callbacks have a recipient.
///      Intended deployment (ANCHOR.md, wiring phase): origin = Base Sepolia,
///      oracle = the ChainlinkPriceAdapter (which re-emits PriceUpdated keyed
///      to real WETH), token = WETH, cooldown = 300 s.
contract SentinelReactiveV2 is AbstractReactive {
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
    /// @notice Leaky-peak decay per price update: anchorPeak x999/1000
    ///         (half-life ~693 updates). Chosen on measured evidence — see
    ///         ANCHOR.md section 2.2. Per-update, not per-second: the constant
    ///         is only valid at the cadence the model was validated at.
    uint256 internal constant ANCHOR_DECAY_NUM = 999;
    uint256 internal constant ANCHOR_DECAY_DEN = 1000;

    uint256 public immutable originChainId;
    address public immutable oracle;
    uint256 public immutable destChainId;
    /// @notice Minimum origin-time between two fired callbacks of the same or
    ///         lower severity. Escalations (TRIM -> EXIT) always fire.
    uint256 public immutable cooldownSeconds;

    address public owner;
    /// @notice Callback recipient (SentinelVaultV2 on the destination chain).
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
    uint256 public anchorPeak;
    /// @notice Features from the most recent inference (1e6 scale).
    int256[7] public lastFeatures;
    /// @notice Logits from the most recent inference [HOLD, TRIM, EXIT].
    int256[3] public lastScores;
    /// @notice Action from the most recent inference.
    uint8 public lastAction;

    uint8 internal _lastFiredAction;
    uint256 internal _lastFiredTs;

    event PriceSeen(uint256 price, uint256 originTimestamp, uint256 updates);
    event Decision(
        uint256 price, uint256 originTimestamp, uint8 action, int256 holdScore, int256 trimScore, int256 exitScore
    );
    event CallbackRequested(uint8 action, uint256 originTimestamp);
    event VaultSet(address vault);

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
    function setVault(address vault_) external {
        require(msg.sender == owner, "Sentinel: not owner");
        vault = vault_;
        emit VaultSet(vault_);
    }

    /// @notice Entry point called by the system contract for every subscribed log.
    /// @dev Non-matching logs fall through silently (reverting would still bill us).
    function react(IReactive.LogRecord calldata log_) external override onlySystem {
        if (log_.topic0 != PRICE_UPDATED_TOPIC0) return;
        if (log_.chainId != originChainId) return;

        (uint256 price, uint256 originTs) = abi.decode(log_.data, (uint256, uint256));
        _push(price);
        emit PriceSeen(price, originTs, updates);
        if (updates < MIN_UPDATES) return;

        int256[7] memory features = _features();
        (uint8 action, int256[3] memory logits,) = SentinelModelV2.predict(features);
        lastFeatures = features;
        lastScores = logits;
        lastAction = action;
        emit Decision(price, originTs, action, logits[0], logits[1], logits[2]);

        if (action == SentinelModelV2.HOLD || vault == address(0)) return;
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
            // COOLDOWN STATE-LEAK FIX (v1 audit finding). V1 recorded the EXIT
            // fire and never reset it, so the dead position's state — severity
            // EXIT (2) plus its timestamp — leaked into the NEXT position
            // cycle: a fresh position's first TRIM (severity 1) is not an
            // escalation over EXIT and stayed suppressed until the old
            // cooldown lapsed, exactly when a new position may need protection
            // most. An EXIT closes the position, so the cycle is over by
            // definition; reset the fired-state to its initial values and the
            // next position starts clean.
            //
            // Trade-off, accepted deliberately: a repeated EXIT vote against
            // an already-closed position now fires immediately instead of
            // after the cooldown. The vault treats a callback on a closed or
            // empty position as a counted no-op, so the cost is callback
            // fees, never missed protection — and the first TRIM after a
            // reset re-arms the state below, so TRIM spam protection is
            // unaffected.
            //
            // Residual case this cannot fix: a position closed WITHOUT an
            // EXIT callback — the owner manually withdrawing the vault's
            // assets (SentinelVaultV2.withdraw) and re-depositing — is
            // invisible to this contract, so a stale fired-state from that
            // cycle can still suppress the new cycle's first non-escalating
            // callback until the cooldown lapses, exactly as in v1. The EXIT
            // path is the only close this contract can observe, because it is
            // the one that requested it.
            _lastFiredAction = SentinelModelV2.HOLD;
            _lastFiredTs = 0;
        } else {
            _lastFiredAction = action;
            _lastFiredTs = originTs;
        }
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
        uint256 mean = sumPrice / n;
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
