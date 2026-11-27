// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice Minimal ERC20 surface used by the Release 1 contracts.
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice ERC20 metadata surface — used for decimals normalisation.
interface IERC20Metadata {
    function decimals() external view returns (uint8);
}

/// @notice Price-source surface: the exact view MockPriceOracle already
///         exposes. The Chainlink adapter (Release 2, upgrade B) exposes the
///         same view, so one swap contract serves both demos.
interface IPriceSource {
    function latestPrice(address token) external view returns (uint256);
    function priceUpdatedAt(address token) external view returns (uint256);
}

/// @title SentinelSwapV3 — two-way fixed-price OTC desk (Release 6).
/// @notice SentinelSwapV2 plus the Release 6 patches in V6-DESIGN.md:
///         (AH-3/AH-4) the reference price is bounded to [$1, $1M] in
///         both directions — an insane price refuses the fill
///         (returns 0, never reverts a callback) instead of overflowing
///         the pricing math and bricking the in-flight callback;
///         (AH-6) `setVault` wires once and locks forever. Everything
///         else — pricing convention, decimals normalisation, the
///         onlyVault gate, the never-revert-on-shortfall rule, the
///         3600 s staleness bound — is V2's unchanged. This is NOT a
///         DEX and must not be described as one: it is a fixed-price
///         testnet desk standing in for a DEX (there is no liquid
///         WETH/MockUSDC pair on Base Sepolia); the production path is
///         a real DEX integration.
contract SentinelSwapV3 {
    /// @notice Prices are 18-decimal USD (e.g. $2,000 = 2000e18).
    uint256 public constant PRICE_SCALE = 1e18;
    /// @notice Maximum age of the reference price a fill or deposit will
    ///         accept (seconds). Matches the Chainlink adapter's own
    ///         `maxStaleness`: a consumer must not trade on data older
    ///         than the relay itself deems unfit.
    uint256 public constant MAX_PRICE_AGE = 3600;
    /// @notice Release 6 (AH-3/AH-4): the reference price is sane only
    ///         inside [$1, $1M] at the 18-decimal USD scale. Below $1
    ///         (the 1-wei cliff) or above $1M (the overflow that bricks
    ///         a callback) the fill is refused, never executed and never
    ///         allowed to revert. The brain enforces the same bounds on
    ///         ingest; the swap enforces them again at pricing time
    ///         (defence in depth — the two read the price at different
    ///         moments).
    uint256 public constant MIN_SANE_PRICE = 1e18;
    uint256 public constant MAX_SANE_PRICE = 1_000_000e18;

    IERC20 public immutable riskAsset;
    IERC20 public immutable safeAsset;
    IPriceSource public immutable priceSource;
    address public owner;
    /// @notice The only address allowed to swap (the SentinelVaultV6). May be
    ///         set after deployment via `setVault` to break the deploy-order
    ///         cycle (the vault approves this desk in its own constructor).
    address public vault;
    /// @notice Release 6 (AH-6): true once `setVault` has been called;
    ///         any later call reverts `VaultAlreadySet`.
    bool public vaultLocked;

    event VaultSet(address vault);
    event Swapped(uint256 riskFilled, uint256 safeOut, uint256 price);
    event ReserveShortfall(uint256 riskRequested, uint256 riskFilled);
    event SwappedReverse(uint256 safeFilled, uint256 riskOut, uint256 price);
    event RiskShortfall(uint256 safeRequested, uint256 safeFilled);
    event StalePriceRefused(uint256 ageSeconds, uint256 boundSeconds);
    /// @notice Release 6 (AH-3/AH-4): emitted when a fill is refused
    ///         because the reference price is outside the sane band.
    event InsanePriceRefused(uint256 price);

    error NotOwner(address caller);
    error NotVault(address caller);
    error StalePrice(uint256 ageSeconds);
    error VaultAlreadySet(address vault);

    constructor(address riskAsset_, address safeAsset_, address priceSource_, address vault_) {
        riskAsset = IERC20(riskAsset_);
        safeAsset = IERC20(safeAsset_);
        priceSource = IPriceSource(priceSource_);
        vault = vault_;
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault(msg.sender);
        _;
    }

    /// @notice Wires the vault after deployment. Owner-only.
    /// @dev Release 6 (AH-6): single-use. The first call wires the
    ///      vault and locks forever; any later call reverts
    ///      `VaultAlreadySet` — after deploy, no owner (compromised or
    ///      otherwise) can redirect the desk to another vault.
    function setVault(address vault_) external onlyOwner {
        if (vaultLocked) revert VaultAlreadySet(vault);
        vault = vault_;
        vaultLocked = true;
        emit VaultSet(vault_);
    }

    /// @notice Safe-asset reserve currently held by the desk.
    function reserve() external view returns (uint256) {
        return safeAsset.balanceOf(address(this));
    }

    /// @notice Risk-asset inventory currently held by the desk — the pool
    ///         re-risk buybacks are paid out of (seeded by earlier
    ///         TRIM/EXIT fills, or by a plain transfer in).
    function riskReserve() external view returns (uint256) {
        return riskAsset.balanceOf(address(this));
    }

    /// @notice Age of the reference price in seconds. A source that never
    ///         pushed yields the full `block.timestamp` (i.e. stale).
    function priceAge() public view returns (uint256) {
        return block.timestamp - priceSource.priceUpdatedAt(address(riskAsset));
    }

    /// @notice True when the reference price is older than `MAX_PRICE_AGE`.
    function priceStale() external view returns (bool) {
        return priceAge() > MAX_PRICE_AGE;
    }

    /// @notice Buys `riskIn` of the risk asset from the vault at the current
    ///         reference price, paying the safe asset out of the reserve.
    /// @dev Never reverts on a short reserve: it fills only what the reserve
    ///      covers and emits `ReserveShortfall`. A reverting swap would revert
    ///      the vault's protection callback with it — burning the vault's
    ///      callback billing and desyncing its protection counters.
    ///      safeOut = riskIn * price * 10^safeDec / (10^riskDec * PRICE_SCALE)
    function swapRiskForSafe(uint256 riskIn) external onlyVault returns (uint256 safeOut) {
        if (riskIn == 0) return 0;
        uint256 age = priceAge();
        if (age > MAX_PRICE_AGE) {
            emit StalePriceRefused(age, MAX_PRICE_AGE);
            return 0; // Stale price: refuse the fill, never revert a callback.
        }
        uint256 price = priceSource.latestPrice(address(riskAsset));
        if (price == 0) return 0; // No reference price: move nothing, never revert a callback.
        // Release 6 (AH-3/AH-4): an insane price refuses the fill
        // (returns 0, never reverts a callback) instead of overflowing
        // `riskIn * price * safeUnit` below and bricking the in-flight
        // protection. The check sits BEFORE any multiplication on price.
        if (price < MIN_SANE_PRICE || price > MAX_SANE_PRICE) {
            emit InsanePriceRefused(price);
            return 0;
        }

        uint256 riskUnit = 10 ** uint256(IERC20Metadata(address(riskAsset)).decimals());
        uint256 safeUnit = 10 ** uint256(IERC20Metadata(address(safeAsset)).decimals());

        uint256 filled = riskIn;
        safeOut = riskIn * price * safeUnit / (riskUnit * PRICE_SCALE);
        uint256 reserve_ = safeAsset.balanceOf(address(this));
        if (safeOut > reserve_) {
            filled = reserve_ * riskUnit * PRICE_SCALE / (price * safeUnit);
            if (filled > riskIn) filled = riskIn;
            safeOut = filled * price * safeUnit / (riskUnit * PRICE_SCALE);
            emit ReserveShortfall(riskIn, filled);
        }
        if (filled > 0) {
            require(riskAsset.transferFrom(msg.sender, address(this), filled), "SentinelSwapV3: risk transfer failed");
        }
        if (safeOut > 0) {
            require(safeAsset.transfer(msg.sender, safeOut), "SentinelSwapV3: safe transfer failed");
        }
        emit Swapped(filled, safeOut, price);
    }

    /// @notice Reverse direction for re-risk: buys the risk asset back for
    ///         the vault, spending `safeIn` of the safe asset at the current
    ///         reference price and paying risk out of the desk's own
    ///         risk-asset inventory.
    /// @dev Mirrors `swapRiskForSafe`'s safety contract exactly, because a
    ///      re-risk callback deserves the same protection as a protection
    ///      callback: NEVER reverts on short risk inventory — it fills only
    ///      what the inventory covers (spending only the covered part of
    ///      `safeIn`) and emits `RiskShortfall`; with no reference price
    ///      (price == 0) it moves nothing and returns 0. The unspent part
    ///      of `safeIn` simply stays in the vault.
    ///      riskOut = safeIn * 10^riskDec * PRICE_SCALE / (price * 10^safeDec)
    function swapSafeForRisk(uint256 safeIn) external onlyVault returns (uint256 riskOut) {
        if (safeIn == 0) return 0;
        uint256 age = priceAge();
        if (age > MAX_PRICE_AGE) {
            emit StalePriceRefused(age, MAX_PRICE_AGE);
            return 0; // Stale price: refuse the fill, never revert a callback.
        }
        uint256 price = priceSource.latestPrice(address(riskAsset));
        if (price == 0) return 0; // No reference price: move nothing, never revert a callback.
        // Release 6 (AH-3/AH-4): same bound as `swapRiskForSafe` — the
        // shortfall branch below computes `inventory * price *
        // safeUnit`, which overflows the same way on an absurd price.
        if (price < MIN_SANE_PRICE || price > MAX_SANE_PRICE) {
            emit InsanePriceRefused(price);
            return 0;
        }

        uint256 riskUnit = 10 ** uint256(IERC20Metadata(address(riskAsset)).decimals());
        uint256 safeUnit = 10 ** uint256(IERC20Metadata(address(safeAsset)).decimals());

        uint256 filled = safeIn;
        riskOut = safeIn * riskUnit * PRICE_SCALE / (price * safeUnit);
        uint256 inventory = riskAsset.balanceOf(address(this));
        if (riskOut > inventory) {
            filled = inventory * price * safeUnit / (riskUnit * PRICE_SCALE);
            if (filled > safeIn) filled = safeIn;
            riskOut = filled * riskUnit * PRICE_SCALE / (price * safeUnit);
            emit RiskShortfall(safeIn, filled);
        }
        if (filled > 0) {
            require(safeAsset.transferFrom(msg.sender, address(this), filled), "SentinelSwapV3: safe transfer failed");
        }
        if (riskOut > 0) {
            require(riskAsset.transfer(msg.sender, riskOut), "SentinelSwapV3: risk transfer failed");
        }
        emit SwappedReverse(filled, riskOut, price);
    }

    /// @notice Owner housekeeping: pull tokens out of the desk (end-of-life
    ///         rescue). Seeding the reserves is a plain transfer in.
    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        require(IERC20(token).transfer(to, amount), "SentinelSwapV3: withdraw failed");
    }
}
