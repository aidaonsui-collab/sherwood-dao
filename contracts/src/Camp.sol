// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Authority} from "./Authority.sol";
import {WOOD} from "./WOOD.sol";
import {sWOOD} from "./sWOOD.sol";
import {Treasury} from "./Treasury.sol";

/// @title Camp
/// @notice "The Camp" — stake WOOD for sWOOD shares; 8-hour watches (rebases) mint from
///         Treasury excess reserves and raise the share index.
///
///         share math: wood = shares * index / INDEX_PRECISION
///         Initial index = INDEX_PRECISION (1:1).
contract Camp {
    using SafeERC20 for IERC20;

    Authority public immutable authority;
    WOOD public immutable wood;
    sWOOD public immutable sWood;
    Treasury public immutable treasury;

    /// @dev 1e9 precision keeps index growth smooth over many epochs without overflow drama.
    uint256 public constant INDEX_PRECISION = 1e9;
    uint256 public constant EPOCH_LENGTH = 8 hours;
    uint256 public constant BPS = 10_000;

    /// @notice WOOD per share scale. Starts at 1e9 (1 share = 1 WOOD).
    uint256 public index = INDEX_PRECISION;

    /// @notice Reward rate per epoch in bps of *staked WOOD value* (not shares). e.g. 10 = 0.10%/epoch.
    uint256 public rewardRateBps = 10;

    /// @notice Hard cap on rewardRateBps a governor may set (anti-fat-finger).
    uint256 public constant MAX_REWARD_RATE_BPS = 500; // 5%/epoch absolute ceiling

    uint256 public epochNumber;
    uint256 public epochEnd;

    event Staked(address indexed user, uint256 woodIn, uint256 sharesOut);
    event Unstaked(address indexed user, uint256 sharesIn, uint256 woodOut);
    event Rebased(uint256 indexed epoch, uint256 rewardWood, uint256 newIndex, uint256 nextEpochEnd);
    event RewardRateSet(uint256 bps);

    error ZeroAmount();
    error EpochNotEnded();
    error BadRate();

    constructor(address authority_, address wood_, address treasury_) {
        authority = Authority(authority_);
        wood = WOOD(wood_);
        treasury = Treasury(treasury_);
        sWood = new sWOOD(address(this));
        epochEnd = block.timestamp + EPOCH_LENGTH;
    }

    // ── views ─────────────────────────────────────────────────────────────────

    function toWood(uint256 shares) public view returns (uint256) {
        return shares * index / INDEX_PRECISION;
    }

    function toShares(uint256 woodAmount) public view returns (uint256) {
        return woodAmount * INDEX_PRECISION / index;
    }

    function totalStakedWood() public view returns (uint256) {
        return toWood(sWood.totalSupply());
    }

    function woodBalanceOf(address user) external view returns (uint256) {
        return toWood(sWood.balanceOf(user));
    }

    // ── stake / unstake ───────────────────────────────────────────────────────

    function stake(uint256 woodAmount) external returns (uint256 shares) {
        if (woodAmount == 0) revert ZeroAmount();
        shares = toShares(woodAmount);
        if (shares == 0) revert ZeroAmount();
        IERC20(address(wood)).safeTransferFrom(msg.sender, address(this), woodAmount);
        sWood.mint(msg.sender, shares);
        emit Staked(msg.sender, woodAmount, shares);
    }

    function unstake(uint256 shares) external returns (uint256 woodOut) {
        if (shares == 0) revert ZeroAmount();
        woodOut = toWood(shares);
        if (woodOut == 0) revert ZeroAmount();
        sWood.burn(msg.sender, shares);
        IERC20(address(wood)).safeTransfer(msg.sender, woodOut);
        emit Unstaked(msg.sender, shares, woodOut);
    }

    // ── watches (rebase) ──────────────────────────────────────────────────────

    /// @notice Permissionless. Mints reward WOOD from excess reserves into Camp, raises index.
    function rebase() external returns (uint256 reward) {
        if (block.timestamp < epochEnd) revert EpochNotEnded();

        uint256 staked = totalStakedWood();
        if (staked > 0 && rewardRateBps > 0) {
            reward = staked * rewardRateBps / BPS;
            uint256 excess = treasury.excessReserves();
            // Cap by excess. Also leave the WOOD that is already staked (held here) out of
            // excess math — excess is reserves − totalSupply; minting increases supply and
            // consumes excess 1:1.
            if (reward > excess) reward = excess;
            if (reward > 0) {
                // Mint to Camp so unstakers can withdraw the grown WOOD liability.
                treasury.mintWoodFromExcess(address(this), reward);
                // index' = index * (staked + reward) / staked
                index = index * (staked + reward) / staked;
            }
        }

        epochNumber += 1;
        // Chain from previous end if we didn't miss too far; otherwise from now.
        uint256 next = epochEnd + EPOCH_LENGTH;
        if (next < block.timestamp) next = block.timestamp + EPOCH_LENGTH;
        epochEnd = next;

        emit Rebased(epochNumber, reward, index, epochEnd);
    }

    function setRewardRateBps(uint256 bps) external {
        if (!authority.hasRole(authority.GOVERNOR(), msg.sender)) {
            revert Authority.NotAuthorized(authority.GOVERNOR(), msg.sender);
        }
        if (bps > MAX_REWARD_RATE_BPS) revert BadRate();
        rewardRateBps = bps;
        emit RewardRateSet(bps);
    }
}
