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

/// @title SentinelSwapV2 — two-way fixed-price OTC desk (Release 5 candidate).
/// @notice SentinelSwap (V1) plus the reverse direction the re-risk feature
///         needs: `swapSafeForRisk` sells the vault's safe asset back into
///         the risk asset at the same reference price, paying out of the
///         risk inventory the desk accumulated from earlier TRIM/EXIT
///         fills. Everything else — pricing convention, decimals
///         normalisation, the onlyVault gate, the never-revert-on-shortfall
///         rule — is V1's unchanged. This is NOT a DEX and must not be
///         described as one: it is a fixed-price testnet desk standing in
///         for a DEX (there is no liquid WETH/MockUSDC pair on Base
///         Sepolia); the production path is a real DEX integration.
/// @dev Prices follow the pipeline-wide convention: 18-decimal USD
///      (PRICE_SCALE = 1e18). Token decimals are normalised per token, so a
///      6-decimal safe asset (real USDC) is a drop-in replacement.
///      The vault is the only allowed caller, and the desk holds no other
///      privileges — that is what makes the vault's max approvals to it
///      safe (the vault grants max allowances on BOTH assets, because the
///      reverse swap pulls the safe asset via `transferFrom`).
contract SentinelSwapV2 {
    /// @notice Prices are 18-decimal USD (e.g. $2,000 = 2000e18).
    uint256 public constant PRICE_SCALE = 1e18;
    /// @notice Maximum age of the reference price a fill or deposit will
    ///         accept (seconds). Matches the Chainlink adapter's own
    ///         `maxStaleness`: a consumer must not trade on data older
    ///         than the relay itself deems unfit.
    uint256 public constant MAX_PRICE_AGE = 3600;

    IERC20 public immutable riskAsset;
    IERC20 public immutable safeAsset;
    IPriceSource public immutable priceSource;
    address public owner;
    /// @notice The only address allowed to swap (the SentinelVaultV3). May be
    ///         set after deployment via `setVault` to break the deploy-order
    ///         cycle (the vault approves this desk in its own constructor).
    address public vault;

    event VaultSet(address vault);
    event Swapped(uint256 riskFilled, uint256 safeOut, uint256 price);
    event ReserveShortfall(uint256 riskRequested, uint256 riskFilled);
    event SwappedReverse(uint256 safeFilled, uint256 riskOut, uint256 price);
    event RiskShortfall(uint256 safeRequested, uint256 safeFilled);
    event StalePriceRefused(uint256 ageSeconds, uint256 boundSeconds);

    error NotOwner(address caller);
    error NotVault(address caller);
    error StalePrice(uint256 ageSeconds);

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
    function setVault(address vault_) external onlyOwner {
        vault = vault_;
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
            require(riskAsset.transferFrom(msg.sender, address(this), filled), "SentinelSwapV2: risk transfer failed");
        }
        if (safeOut > 0) {
            require(safeAsset.transfer(msg.sender, safeOut), "SentinelSwapV2: safe transfer failed");
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
            require(safeAsset.transferFrom(msg.sender, address(this), filled), "SentinelSwapV2: safe transfer failed");
        }
        if (riskOut > 0) {
            require(riskAsset.transfer(msg.sender, riskOut), "SentinelSwapV2: risk transfer failed");
        }
        emit SwappedReverse(filled, riskOut, price);
    }

    /// @notice Owner housekeeping: pull tokens out of the desk (end-of-life
    ///         rescue). Seeding the reserves is a plain transfer in.
    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        require(IERC20(token).transfer(to, amount), "SentinelSwapV2: withdraw failed");
    }
}
