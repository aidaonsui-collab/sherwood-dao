// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Authority} from "./Authority.sol";
import {WOOD} from "./WOOD.sol";
import {Treasury} from "./Treasury.sol";

/**
 * @title Redeem
 * @notice Permissionless RFV-anchored WOOD → USDG redemption (NET InverseBond shape).
 *
 *         Anyone may burn WOOD for USDG from the Treasury at a small discount to
 *         `treasury.backingPerWood()`. No market oracle, no DEX, no keeper: if spot
 *         trades below this payout, buying WOOD and redeeming here is free money, and
 *         that buy pressure is the floor defense.
 *
 *         This replaces only the *bid* half of RangeBound's deferred market-making.
 *         RangeBound's ask side (selling into strength) stays guardian-operated and
 *         untouched.
 *
 *         Pricing: usdgOut = woodAmount * backingPerWood * (1 − spreadBps/BPS), scaled
 *         to USDG's native decimals (production USDG is 6-dec; tests may use 18).
 *
 *         Rate limit: each Camp-aligned 8h epoch captures `capBps` of then-current
 *         `excessReserves()` (as USDG units) and depletes it as redemptions land.
 *         Cap is frozen for the epoch — mid-epoch reserve moves do not expand it.
 *
 *         Auth: `RESERVE_SPENDER` to `treasury.withdraw` USDG; `WOOD_MINTER` only to
 *         `wood.burn(address(this), …)` after a successful `transferFrom`. This
 *         contract never burns an arbitrary address's WOOD.
 */
contract Redeem {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant WAD = 1e18;
    /// @notice Same watch cadence as Camp — one shared protocol heartbeat.
    uint256 public constant EPOCH_LENGTH = 8 hours;
    /// @dev Default protective spread below RFV (1.5%), matching the NET InverseBond reference.
    uint256 public constant DEFAULT_SPREAD_BPS = 150;
    /// @dev Default per-epoch outflow cap: 10% of excessReserves at epoch open.
    uint256 public constant DEFAULT_CAP_BPS = 1_000;

    Authority public immutable authority;
    WOOD public immutable wood;
    Treasury public immutable treasury;
    IERC20 public immutable usdg;
    /// @notice Cached USDG decimals (read once at deploy; production = 6, mocks often 18).
    uint8 public immutable usdgDecimals;

    /// @notice Discount below `backingPerWood` applied to every redemption, in bps of RFV.
    uint256 public spreadBps = DEFAULT_SPREAD_BPS;
    /// @notice Share of `excessReserves()` locked in as the epoch USDG cap, in bps.
    uint256 public capBps = DEFAULT_CAP_BPS;
    /// @notice Kill switch. When false, `redeem` reverts. Default on.
    bool public active = true;

    /// @notice End timestamp of the current epoch (exclusive upper bound for remaining capacity).
    uint256 public epochEnd;
    /// @notice Total USDG (native decimals) available for redemption this epoch at open.
    uint256 public epochCap;
    /// @notice USDG still available this epoch.
    uint256 public epochRemaining;

    event Redeemed(
        address indexed caller,
        uint256 woodBurned,
        uint256 usdgPaid,
        uint256 backingPerWood,
        uint256 spreadBpsApplied,
        uint256 epochRemaining
    );
    event SpreadBpsSet(uint256 spreadBps);
    event CapBpsSet(uint256 capBps);
    event ActiveSet(bool active);
    event EpochRolled(uint256 epochEnd, uint256 epochCap);

    error ZeroAddress();
    error ZeroAmount();
    error Paused();
    error BadConfig();
    error EpochCapExceeded(uint256 usdgOut, uint256 epochRemaining);
    error Slippage(uint256 usdgOut, uint256 minUsdgOut);

    constructor(address authority_, address wood_, address treasury_, address usdg_) {
        if (
            authority_ == address(0) || wood_ == address(0) || treasury_ == address(0) || usdg_ == address(0)
        ) revert ZeroAddress();
        authority = Authority(authority_);
        wood = WOOD(wood_);
        treasury = Treasury(treasury_);
        usdg = IERC20(usdg_);
        usdgDecimals = IERC20Metadata(usdg_).decimals();
    }

    modifier onlyGovernor() {
        if (!authority.hasRole(authority.GOVERNOR(), msg.sender)) {
            revert Authority.NotAuthorized(authority.GOVERNOR(), msg.sender);
        }
        _;
    }

    // ── admin ─────────────────────────────────────────────────────────────────

    function setSpreadBps(uint256 spreadBps_) external onlyGovernor {
        // Spread may be 0 (full RFV) up to but not including 100% (would pay nothing).
        if (spreadBps_ >= BPS) revert BadConfig();
        spreadBps = spreadBps_;
        emit SpreadBpsSet(spreadBps_);
    }

    function setCapBps(uint256 capBps_) external onlyGovernor {
        if (capBps_ > BPS) revert BadConfig();
        capBps = capBps_;
        emit CapBpsSet(capBps_);
    }

    function setActive(bool active_) external onlyGovernor {
        active = active_;
        emit ActiveSet(active_);
    }

    // ── views ─────────────────────────────────────────────────────────────────

    /// @notice USDG (native decimals) a `woodAmount` redemption would pay at current RFV + spread.
    ///         Does not account for the epoch remaining cap.
    function quote(uint256 woodAmount) public view returns (uint256 usdgOut) {
        if (woodAmount == 0) return 0;
        uint256 backing = treasury.backingPerWood(); // 18-dec USD / WOOD
        uint256 fairUsd18 = woodAmount * backing / WAD;
        uint256 afterSpread = fairUsd18 * (BPS - spreadBps) / BPS;
        return _usd18ToUsdg(afterSpread);
    }

    /// @notice USDG still redeemable this epoch after rolling if the current epoch has ended.
    function remainingCapacity() external view returns (uint256) {
        if (block.timestamp >= epochEnd) {
            return _usd18ToUsdg(treasury.excessReserves() * capBps / BPS);
        }
        return epochRemaining;
    }

    // ── redeem ────────────────────────────────────────────────────────────────

    /// @notice Permissionless. Pull `woodAmount` WOOD from caller, burn it, pay USDG from Treasury
    ///         at RFV − spread. Reverts if paused, zero, under minUsdgOut, or over epoch cap.
    function redeem(uint256 woodAmount, uint256 minUsdgOut) external returns (uint256 usdgOut) {
        if (!active) revert Paused();
        if (woodAmount == 0) revert ZeroAmount();

        _rollEpochIfNeeded();

        uint256 backing = treasury.backingPerWood();
        usdgOut = quote(woodAmount);
        if (usdgOut == 0) revert ZeroAmount();
        if (usdgOut < minUsdgOut) revert Slippage(usdgOut, minUsdgOut);
        if (usdgOut > epochRemaining) revert EpochCapExceeded(usdgOut, epochRemaining);

        // 1) Pull WOOD in. 2) Burn only what this contract now holds — never burn(msg.sender, …).
        IERC20(address(wood)).safeTransferFrom(msg.sender, address(this), woodAmount);
        wood.burn(address(this), woodAmount);

        // 3) Pay USDG straight to the caller (same withdraw shape as RangeBound.executeBid).
        epochRemaining -= usdgOut;
        treasury.withdraw(address(usdg), msg.sender, usdgOut);

        emit Redeemed(msg.sender, woodAmount, usdgOut, backing, spreadBps, epochRemaining);
    }

    // ── internals ─────────────────────────────────────────────────────────────

    function _rollEpochIfNeeded() internal {
        if (block.timestamp < epochEnd) return;

        uint256 next = epochEnd == 0 ? block.timestamp + EPOCH_LENGTH : epochEnd + EPOCH_LENGTH;
        if (next <= block.timestamp) next = block.timestamp + EPOCH_LENGTH;
        epochEnd = next;

        // Freeze cap against excess at open — mid-epoch reserve changes do not expand capacity.
        epochCap = _usd18ToUsdg(treasury.excessReserves() * capBps / BPS);
        epochRemaining = epochCap;
        emit EpochRolled(epochEnd, epochCap);
    }

    /// @dev Convert 18-dec USD notional to USDG's native decimals (6 on production, 18 in many mocks).
    function _usd18ToUsdg(uint256 usd18) internal view returns (uint256) {
        if (usdgDecimals == 18) return usd18;
        if (usdgDecimals < 18) return usd18 / (10 ** (18 - usdgDecimals));
        return usd18 * (10 ** (usdgDecimals - 18));
    }
}
