// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Authority} from "./Authority.sol";
import {WOOD} from "./WOOD.sol";
import {Treasury} from "./Treasury.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/// @title RangeBound
/// @notice Skeleton for range-bound stability: when WOOD/USD spot is below the band floor
///         (relative to backing), treasury bids; above the ceiling, treasury asks.
///         Phase-1 implements the band math + governor-gated execute hooks. Keeper automation
///         and full AMM routing are follow-ups.
contract RangeBound {
    using SafeERC20 for IERC20;

    Authority public immutable authority;
    WOOD public immutable wood;
    Treasury public immutable treasury;
    IERC20 public immutable usdg;
    IPriceOracle public woodSpotOracle; // WOOD/USD market price

    uint256 public lowerBps = 9_500; // bid when spot < backing * 95%
    uint256 public upperBps = 10_500; // ask when spot > backing * 105%
    uint256 public constant BPS = 10_000;
    uint256 public constant WAD = 1e18;

    event BandSet(uint256 lowerBps, uint256 upperBps);
    event SpotOracleSet(address oracle);
    event Bid(uint256 woodBought, uint256 usdgSpent);
    event Ask(uint256 woodSold, uint256 usdgReceived);

    error BadBand();
    error InBand();
    error ZeroAddress();
    error ZeroAmount();

    constructor(address authority_, address wood_, address treasury_, address usdg_) {
        authority = Authority(authority_);
        wood = WOOD(wood_);
        treasury = Treasury(treasury_);
        usdg = IERC20(usdg_);
    }

    function setBand(uint256 lowerBps_, uint256 upperBps_) external {
        if (!authority.hasRole(authority.GOVERNOR(), msg.sender)) {
            revert Authority.NotAuthorized(authority.GOVERNOR(), msg.sender);
        }
        if (lowerBps_ == 0 || upperBps_ <= lowerBps_ || upperBps_ > 20_000) revert BadBand();
        lowerBps = lowerBps_;
        upperBps = upperBps_;
        emit BandSet(lowerBps_, upperBps_);
    }

    function setSpotOracle(address oracle) external {
        if (!authority.hasRole(authority.GOVERNOR(), msg.sender)) {
            revert Authority.NotAuthorized(authority.GOVERNOR(), msg.sender);
        }
        if (oracle == address(0)) revert ZeroAddress();
        woodSpotOracle = IPriceOracle(oracle);
        emit SpotOracleSet(oracle);
    }

    function lowerBound() public view returns (uint256) {
        return treasury.backingPerWood() * lowerBps / BPS;
    }

    function upperBound() public view returns (uint256) {
        return treasury.backingPerWood() * upperBps / BPS;
    }

    function spotPrice() public view returns (uint256) {
        if (address(woodSpotOracle) == address(0)) return 0;
        // Validated through the Treasury (non-zero + optional staleness) so a stale/dead spot feed
        // can't drive band execution once real market oracles are wired.
        return treasury.readPrice(address(woodSpotOracle));
    }

    /// @notice Guardian/keeper: spend up to `usdgAmount` of treasury USDG to buy WOOD at floor
    ///         when spot is below the lower band. WOOD is held in Treasury (or burned later).
    /// @dev Simplified: pulls USDG from treasury to this contract; caller is expected to have
    ///      already sold WOOD into market off-module OR we mint nothing and just record intent.
    ///      Real routing is out of Phase 1 — this enforces band gating only.
    function executeBid(uint256 usdgAmount) external returns (uint256) {
        if (!authority.hasRole(authority.GUARDIAN(), msg.sender) && !authority.hasRole(authority.GOVERNOR(), msg.sender))
        {
            revert Authority.NotAuthorized(authority.GUARDIAN(), msg.sender);
        }
        if (usdgAmount == 0) revert ZeroAmount();
        uint256 spot = spotPrice();
        if (spot == 0 || spot >= lowerBound()) revert InBand();
        // Pull USDG to this contract as "market dry powder" accounting; real swap is external.
        treasury.withdraw(address(usdg), address(this), usdgAmount);
        emit Bid(0, usdgAmount);
        return usdgAmount;
    }

    /// @notice Guardian/keeper: sell WOOD into strength when above upper band.
    /// @dev Requires WOOD sitting on this contract (from prior market ops). Phase-1 skeleton.
    function executeAsk(uint256 woodAmount) external returns (uint256) {
        if (!authority.hasRole(authority.GUARDIAN(), msg.sender) && !authority.hasRole(authority.GOVERNOR(), msg.sender))
        {
            revert Authority.NotAuthorized(authority.GUARDIAN(), msg.sender);
        }
        if (woodAmount == 0) revert ZeroAmount();
        uint256 spot = spotPrice();
        if (spot == 0 || spot <= upperBound()) revert InBand();
        // Transfer WOOD from this contract into Treasury reserves accounting as protocol income.
        if (wood.balanceOf(address(this)) < woodAmount) revert ZeroAmount();
        IERC20(address(wood)).safeTransfer(address(treasury), woodAmount);
        emit Ask(woodAmount, 0);
        return woodAmount;
    }
}
