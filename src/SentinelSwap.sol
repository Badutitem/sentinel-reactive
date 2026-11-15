// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice Minimal ERC20 surface used by the phase-2 contracts.
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
///         exposes. The Chainlink adapter (phase 2, upgrade B) exposes the
///         same view, so one swap contract serves both demos.
interface IPriceSource {
    function latestPrice(address token) external view returns (uint256);
}

/// @title SentinelSwap — fixed-price OTC desk for the Sentinel vault (testnet).
/// @notice Holds a seeded safe-asset (MockUSDC) reserve and buys the vault's
///         risk asset (WETH) at the price source's current reference price, so
///         a TRIM or EXIT produces real ERC20 transfers a judge can trace on
///         Basescan. This is NOT a DEX and must not be described as one: it is
///         a fixed-price testnet desk standing in for a DEX (there is no
///         liquid WETH/MockUSDC pair on Base Sepolia); the production path is
///         a real DEX integration.
/// @dev Prices follow the pipeline-wide convention: 18-decimal USD
///      (PRICE_SCALE = 1e18). Token decimals are normalised per token, so a
///      6-decimal safe asset (real USDC) is a drop-in replacement.
///      The vault is the only allowed caller, and the desk holds no other
///      privileges — that is what makes the vault's max approval to it safe.
contract SentinelSwap {
    /// @notice Prices are 18-decimal USD (e.g. $2,000 = 2000e18).
    uint256 public constant PRICE_SCALE = 1e18;

    IERC20 public immutable riskAsset;
    IERC20 public immutable safeAsset;
    IPriceSource public immutable priceSource;
    address public owner;
    /// @notice The only address allowed to swap (the SentinelVaultV2). May be
    ///         set after deployment via `setVault` to break the deploy-order
    ///         cycle (the vault approves this desk in its own constructor).
    address public vault;

    event VaultSet(address vault);
    event Swapped(uint256 riskFilled, uint256 safeOut, uint256 price);
    event ReserveShortfall(uint256 riskRequested, uint256 riskFilled);

    error NotOwner(address caller);
    error NotVault(address caller);

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

    /// @notice Buys `riskIn` of the risk asset from the vault at the current
    ///         reference price, paying the safe asset out of the reserve.
    /// @dev Never reverts on a short reserve: it fills only what the reserve
    ///      covers and emits `ReserveShortfall`. A reverting swap would revert
    ///      the vault's protection callback with it — burning the vault's
    ///      callback billing and desyncing its protection counters.
    ///      safeOut = riskIn * price * 10^safeDec / (10^riskDec * PRICE_SCALE)
    function swapRiskForSafe(uint256 riskIn) external onlyVault returns (uint256 safeOut) {
        if (riskIn == 0) return 0;
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
            require(riskAsset.transferFrom(msg.sender, address(this), filled), "SentinelSwap: risk transfer failed");
        }
        if (safeOut > 0) {
            require(safeAsset.transfer(msg.sender, safeOut), "SentinelSwap: safe transfer failed");
        }
        emit Swapped(filled, safeOut, price);
    }

    /// @notice Owner housekeeping: pull tokens out of the desk (end-of-life
    ///         rescue). Seeding the reserve is a plain transfer in.
    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        require(IERC20(token).transfer(to, amount), "SentinelSwap: withdraw failed");
    }
}
