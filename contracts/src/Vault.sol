// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Authority} from "./Authority.sol";
import {Camp} from "./Camp.sol";
import {sWOOD} from "./sWOOD.sol";
import {WOOD} from "./WOOD.sol";
import {Treasury} from "./Treasury.sol";

/// @title Vault
/// @notice Borrow a stable (USDG) against sWOOD collateral at the *backing floor*, not spot.
///         max LTV 95% of RFV, fixed 0.50% APR (Olympus Cooler-style), no price liquidations.
///
///         Protocol revenue: 100% of interest is protocol-owned. Accrued interest increases
///         borrower debt; on repay, USDG (principal + interest) returns to the Treasury as
///         reserves — there is no separate platform wallet skim. Interest is repaid first.
///
///         Phase-1: interest accrues; underwater positions can be repaid by guardian path only
///         (no open liquidation market yet).
contract Vault {
    using SafeERC20 for IERC20;

    Authority public immutable authority;
    Camp public immutable camp;
    sWOOD public immutable sWood;
    WOOD public immutable wood;
    Treasury public immutable treasury;
    IERC20 public immutable usdg; // borrow asset, 18-dec assumed

    uint256 public constant BPS = 10_000;
    uint256 public constant WAD = 1e18;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    uint256 public maxLtvBps = 9_500; // 95%
    uint256 public interestBps = 50; // 0.50% APR — Cooler default

    /// @notice Lifetime interest accrued into positions (protocol revenue metric).
    uint256 public totalInterestAccrued;
    /// @notice Lifetime interest actually repaid into Treasury.
    uint256 public totalInterestRepaid;

    struct Position {
        uint256 collateralShares; // sWOOD shares locked
        uint256 principal; // USDG principal outstanding
        uint256 debt; // principal + accrued interest
        uint256 lastAccrual;
    }

    mapping(address => Position) public positions;
    uint256 public totalDebt;
    uint256 public totalCollateralShares;

    event Deposited(address indexed user, uint256 shares);
    event Withdrawn(address indexed user, uint256 shares);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount, uint256 interestPortion);
    event InterestAccrued(address indexed user, uint256 interest);
    event ParamsSet(uint256 maxLtvBps, uint256 interestBps);
    event Seized(address indexed user, uint256 shares, uint256 woodRecovered, uint256 debtWrittenOff);

    error ZeroAmount();
    error ExceedsLtv();
    error InsufficientCollateral();
    error BadParam();
    error NotUnderwater();

    constructor(address authority_, address camp_, address treasury_, address usdg_) {
        authority = Authority(authority_);
        camp = Camp(camp_);
        sWood = Camp(camp_).sWood();
        wood = Camp(camp_).wood();
        treasury = Treasury(treasury_);
        usdg = IERC20(usdg_);
    }

    // ── views ─────────────────────────────────────────────────────────────────

    function _accrue(Position storage p, address account) internal returns (uint256 interest) {
        if (p.debt == 0 || p.lastAccrual == 0 || block.timestamp <= p.lastAccrual) {
            p.lastAccrual = block.timestamp;
            return 0;
        }
        uint256 dt = block.timestamp - p.lastAccrual;
        // Compound on full debt (principal + prior interest), Cooler-style continuous accrual.
        interest = p.debt * interestBps / BPS * dt / SECONDS_PER_YEAR;
        if (interest > 0) {
            p.debt += interest;
            totalDebt += interest;
            totalInterestAccrued += interest;
            emit InterestAccrued(account, interest);
        }
        p.lastAccrual = block.timestamp;
    }

    /// @notice Max USDG borrowable for `shares` of sWOOD at current backing floor.
    function maxBorrowFor(uint256 shares) public view returns (uint256) {
        uint256 woodValue = camp.toWood(shares);
        uint256 backing = treasury.backingPerWood();
        uint256 rfv = woodValue * backing / WAD;
        return rfv * maxLtvBps / BPS;
    }

    function maxBorrow(address user) external view returns (uint256) {
        Position memory p = positions[user];
        uint256 debt = p.debt;
        if (debt > 0 && p.lastAccrual > 0 && block.timestamp > p.lastAccrual) {
            uint256 dt = block.timestamp - p.lastAccrual;
            debt += debt * interestBps / BPS * dt / SECONDS_PER_YEAR;
        }
        uint256 cap = maxBorrowFor(p.collateralShares);
        return cap > debt ? cap - debt : 0;
    }

    // ── collateral ────────────────────────────────────────────────────────────

    function deposit(uint256 shares) external {
        if (shares == 0) revert ZeroAmount();
        Position storage p = positions[msg.sender];
        _accrue(p, msg.sender);
        IERC20(address(sWood)).safeTransferFrom(msg.sender, address(this), shares);
        p.collateralShares += shares;
        totalCollateralShares += shares;
        if (p.lastAccrual == 0) p.lastAccrual = block.timestamp;
        emit Deposited(msg.sender, shares);
    }

    function withdraw(uint256 shares) external {
        if (shares == 0) revert ZeroAmount();
        Position storage p = positions[msg.sender];
        _accrue(p, msg.sender);
        if (shares > p.collateralShares) revert InsufficientCollateral();
        uint256 remaining = p.collateralShares - shares;
        if (p.debt > maxBorrowFor(remaining)) revert ExceedsLtv();
        p.collateralShares = remaining;
        totalCollateralShares -= shares;
        IERC20(address(sWood)).safeTransfer(msg.sender, shares);
        emit Withdrawn(msg.sender, shares);
    }

    // ── borrow / repay ────────────────────────────────────────────────────────

    function borrow(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        Position storage p = positions[msg.sender];
        _accrue(p, msg.sender);
        if (p.debt + amount > maxBorrowFor(p.collateralShares)) revert ExceedsLtv();
        p.principal += amount;
        p.debt += amount;
        totalDebt += amount;
        treasury.withdraw(address(usdg), msg.sender, amount);
        emit Borrowed(msg.sender, amount);
    }

    /// @notice Repay USDG to Treasury. Interest is satisfied first (protocol revenue), then principal.
    function repay(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        Position storage p = positions[msg.sender];
        _accrue(p, msg.sender);
        if (amount > p.debt) amount = p.debt;

        uint256 interestOwed = p.debt - p.principal;
        uint256 interestPortion = amount < interestOwed ? amount : interestOwed;
        uint256 principalPortion = amount - interestPortion;

        p.debt -= amount;
        if (principalPortion > 0) {
            p.principal -= principalPortion;
        }
        totalDebt -= amount;
        totalInterestRepaid += interestPortion;

        // 100% of repayment lands in Treasury reserves — protocol-owned, no platform split.
        usdg.safeTransferFrom(msg.sender, address(treasury), amount);
        emit Repaid(msg.sender, amount, interestPortion);
    }

    /// @notice Guardian: close an underwater position. The sWOOD collateral is unstaked to WOOD and
    ///         sent to the Treasury (governor burns it via `Treasury.burnWood` to restore backing);
    ///         the remaining debt is written off. Phase-1 recovery path — full disposal happens on the
    ///         governance side, there is no open/partial liquidation market yet.
    function seize(address user) external returns (uint256 woodRecovered) {
        if (!authority.hasRole(authority.GUARDIAN(), msg.sender)) {
            revert Authority.NotAuthorized(authority.GUARDIAN(), msg.sender);
        }
        Position storage p = positions[user];
        _accrue(p, user);
        uint256 shares = p.collateralShares;
        if (shares == 0) revert InsufficientCollateral();
        // Only positions whose debt has risen above what the collateral can back may be seized.
        if (p.debt <= maxBorrowFor(shares)) revert NotUnderwater();

        uint256 writtenOff = p.debt;
        p.collateralShares = 0;
        p.principal = 0;
        p.debt = 0;
        totalCollateralShares -= shares;
        totalDebt -= writtenOff;

        // Unstake the seized collateral to WOOD and hand it to the Treasury; governance burns it
        // (`Treasury.burnWood`) to shrink supply and offset the reserves the defaulter withdrew.
        woodRecovered = camp.unstake(shares);
        IERC20(address(wood)).safeTransfer(address(treasury), woodRecovered);
        emit Seized(user, shares, woodRecovered, writtenOff);
    }

    function setParams(uint256 maxLtvBps_, uint256 interestBps_) external {
        if (!authority.hasRole(authority.GOVERNOR(), msg.sender)) {
            revert Authority.NotAuthorized(authority.GOVERNOR(), msg.sender);
        }
        if (maxLtvBps_ > BPS || interestBps_ > 1_000) revert BadParam();
        maxLtvBps = maxLtvBps_;
        interestBps = interestBps_;
        emit ParamsSet(maxLtvBps_, interestBps_);
    }
}
