// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Authority} from "./Authority.sol";
import {Camp} from "./Camp.sol";
import {sWOOD} from "./sWOOD.sol";
import {Treasury} from "./Treasury.sol";

/// @title Vault
/// @notice Borrow a stable (USDG) against sWOOD collateral at the *backing floor*, not spot.
///         max LTV 95% of RFV, fixed 0.50% APR, no price liquidations.
///         Phase-1: interest accrues; underwater positions can be repaid by guardian path only
///         (no open liquidation market yet).
contract Vault {
    using SafeERC20 for IERC20;

    Authority public immutable authority;
    Camp public immutable camp;
    sWOOD public immutable sWood;
    Treasury public immutable treasury;
    IERC20 public immutable usdg; // borrow asset, 18-dec assumed

    uint256 public constant BPS = 10_000;
    uint256 public constant WAD = 1e18;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    uint256 public maxLtvBps = 9_500; // 95%
    uint256 public interestBps = 50; // 0.50% APR

    struct Position {
        uint256 collateralShares; // sWOOD shares locked
        uint256 debt; // USDG principal+interest outstanding (18-dec)
        uint256 lastAccrual; // timestamp
    }

    mapping(address => Position) public positions;
    uint256 public totalDebt;
    uint256 public totalCollateralShares;

    event Deposited(address indexed user, uint256 shares);
    event Withdrawn(address indexed user, uint256 shares);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event ParamsSet(uint256 maxLtvBps, uint256 interestBps);

    error ZeroAmount();
    error ExceedsLtv();
    error InsufficientCollateral();
    error InsufficientDebt();
    error BadParam();

    constructor(address authority_, address camp_, address treasury_, address usdg_) {
        authority = Authority(authority_);
        camp = Camp(camp_);
        sWood = Camp(camp_).sWood();
        treasury = Treasury(treasury_);
        usdg = IERC20(usdg_);
    }

    // ── views ─────────────────────────────────────────────────────────────────

    function _accrue(Position storage p) internal {
        if (p.debt == 0 || p.lastAccrual == 0 || block.timestamp <= p.lastAccrual) {
            p.lastAccrual = block.timestamp;
            return;
        }
        uint256 dt = block.timestamp - p.lastAccrual;
        // interest = debt * rate * dt / year
        uint256 interest = p.debt * interestBps / BPS * dt / SECONDS_PER_YEAR;
        if (interest > 0) {
            p.debt += interest;
            totalDebt += interest;
        }
        p.lastAccrual = block.timestamp;
    }

    /// @notice Max USDG borrowable for `shares` of sWOOD at current backing floor.
    function maxBorrowFor(uint256 shares) public view returns (uint256) {
        uint256 woodValue = camp.toWood(shares); // 18-dec WOOD
        uint256 backing = treasury.backingPerWood(); // 18-dec USD per WOOD
        uint256 rfv = woodValue * backing / WAD;
        return rfv * maxLtvBps / BPS;
    }

    function maxBorrow(address user) external view returns (uint256) {
        Position memory p = positions[user];
        // view-path approximate interest
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
        _accrue(p);
        IERC20(address(sWood)).safeTransferFrom(msg.sender, address(this), shares);
        p.collateralShares += shares;
        totalCollateralShares += shares;
        if (p.lastAccrual == 0) p.lastAccrual = block.timestamp;
        emit Deposited(msg.sender, shares);
    }

    function withdraw(uint256 shares) external {
        if (shares == 0) revert ZeroAmount();
        Position storage p = positions[msg.sender];
        _accrue(p);
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
        _accrue(p);
        if (p.debt + amount > maxBorrowFor(p.collateralShares)) revert ExceedsLtv();
        p.debt += amount;
        totalDebt += amount;
        // Liquidity comes from Treasury USDG reserves
        if (!authority.hasRole(authority.RESERVE_SPENDER(), address(this))) {
            // Vault must be granted RESERVE_SPENDER; withdraw via treasury
        }
        treasury.withdraw(address(usdg), msg.sender, amount);
        emit Borrowed(msg.sender, amount);
    }

    function repay(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        Position storage p = positions[msg.sender];
        _accrue(p);
        if (amount > p.debt) amount = p.debt;
        p.debt -= amount;
        totalDebt -= amount;
        // Return USDG to Treasury as reserves
        usdg.safeTransferFrom(msg.sender, address(treasury), amount);
        emit Repaid(msg.sender, amount);
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
