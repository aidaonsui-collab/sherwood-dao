// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Authority} from "./Authority.sol";
import {WOOD} from "./WOOD.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/// @title Treasury
/// @notice Holds reserve assets and reports risk-free value (RFV) backing for WOOD.
///         Backing unit: 1 WOOD targets ≥ 1e18 USD of RFV.
///         `totalReserves` = Σ balance_asset_normalized × uiMultiplier × price / 1e18
///         `excessReserves` = totalReserves − WOOD.totalSupply (floored at 0)
contract Treasury {
    using SafeERC20 for IERC20;

    Authority public immutable authority;
    WOOD public immutable wood;

    struct Asset {
        bool enabled;
        address oracle;
        uint256 uiMultiplier; // 1e18 = 100% RFV credit; haircut volatiles e.g. 0.9e18
        uint8 decimals;
    }

    mapping(address => Asset) public assets;
    address[] public assetList;

    uint256 public constant BPS = 10_000;
    uint256 public constant WAD = 1e18;

    event AssetRegistered(address indexed token, address oracle, uint256 uiMultiplier, uint8 decimals);
    event AssetUpdated(address indexed token, bool enabled, address oracle, uint256 uiMultiplier);
    event Deposited(address indexed token, address indexed from, uint256 amount);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event WoodMintedFromExcess(address indexed to, uint256 amount);
    event WoodBurned(uint256 amount);

    error ZeroAddress();
    error AssetNotEnabled();
    error BadConfig();
    error InsufficientExcess();
    error TransferFailed();

    constructor(address authority_, address wood_) {
        if (authority_ == address(0) || wood_ == address(0)) revert ZeroAddress();
        authority = Authority(authority_);
        wood = WOOD(wood_);
    }

    modifier onlyGovernor() {
        if (!authority.hasRole(authority.GOVERNOR(), msg.sender)) {
            revert Authority.NotAuthorized(authority.GOVERNOR(), msg.sender);
        }
        _;
    }

    modifier onlyDepositor() {
        if (!authority.hasRole(authority.RESERVE_DEPOSITOR(), msg.sender)) {
            revert Authority.NotAuthorized(authority.RESERVE_DEPOSITOR(), msg.sender);
        }
        _;
    }

    modifier onlySpender() {
        if (!authority.hasRole(authority.RESERVE_SPENDER(), msg.sender)) {
            revert Authority.NotAuthorized(authority.RESERVE_SPENDER(), msg.sender);
        }
        _;
    }

    modifier onlyMinterCaller() {
        // Camp / Heist / RangeBound mint WOOD via Treasury while holding WOOD_MINTER on WOOD itself
        // is alternate — here we gate mintWoodFromExcess to REWARD_MANAGER + BOND_MANAGER roles
        // or anyone with WOOD_MINTER who is expected to call through treasury.
        if (
            !authority.hasRole(authority.REWARD_MANAGER(), msg.sender)
                && !authority.hasRole(authority.BOND_MANAGER(), msg.sender)
                && !authority.hasRole(authority.WOOD_MINTER(), msg.sender)
        ) {
            revert Authority.NotAuthorized(authority.REWARD_MANAGER(), msg.sender);
        }
        _;
    }

    // ── asset registry ────────────────────────────────────────────────────────

    function registerAsset(address token, address oracle, uint256 uiMultiplier, uint8 decimals_)
        external
        onlyGovernor
    {
        if (token == address(0) || oracle == address(0)) revert ZeroAddress();
        if (uiMultiplier == 0 || uiMultiplier > WAD) revert BadConfig();
        if (decimals_ > 18) revert BadConfig();

        Asset storage a = assets[token];
        if (a.oracle == address(0)) {
            assetList.push(token);
        }
        a.enabled = true;
        a.oracle = oracle;
        a.uiMultiplier = uiMultiplier;
        a.decimals = decimals_;
        emit AssetRegistered(token, oracle, uiMultiplier, decimals_);
    }

    function setAsset(address token, bool enabled, address oracle, uint256 uiMultiplier) external onlyGovernor {
        Asset storage a = assets[token];
        if (a.oracle == address(0) && oracle == address(0)) revert BadConfig();
        if (oracle != address(0)) a.oracle = oracle;
        if (uiMultiplier != 0) {
            if (uiMultiplier > WAD) revert BadConfig();
            a.uiMultiplier = uiMultiplier;
        }
        a.enabled = enabled;
        emit AssetUpdated(token, enabled, a.oracle, a.uiMultiplier);
    }

    function assetCount() external view returns (uint256) {
        return assetList.length;
    }

    // ── valuation ─────────────────────────────────────────────────────────────

    /// @notice RFV of a single asset balance, 18-dec USD.
    function assetValue(address token) public view returns (uint256) {
        Asset memory a = assets[token];
        if (!a.enabled) return 0;
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) return 0;
        (uint256 price,) = IPriceOracle(a.oracle).latestPrice();
        // normalize balance to 18 decimals
        uint256 norm = bal;
        if (a.decimals < 18) norm = bal * (10 ** (18 - a.decimals));
        else if (a.decimals > 18) norm = bal / (10 ** (a.decimals - 18));
        // value = norm * price / 1e18 * uiMultiplier / 1e18
        return (norm * price / WAD) * a.uiMultiplier / WAD;
    }

    /// @notice Total RFV across all enabled reserve assets, 18-dec USD.
    function totalReserves() public view returns (uint256 total) {
        uint256 n = assetList.length;
        for (uint256 i; i < n; i++) {
            total += assetValue(assetList[i]);
        }
    }

    /// @notice Reserves above 1:1 RFV backing of circulating WOOD. Floor 0.
    function excessReserves() public view returns (uint256) {
        uint256 reserves = totalReserves();
        uint256 supply = wood.totalSupply();
        return reserves > supply ? reserves - supply : 0;
    }

    /// @notice RFV backing per WOOD (18-dec). 0 if no supply.
    function backingPerWood() public view returns (uint256) {
        uint256 supply = wood.totalSupply();
        if (supply == 0) return WAD; // empty protocol: floor treated as $1 for Vault math
        return totalReserves() * WAD / supply;
    }

    // ── movements ─────────────────────────────────────────────────────────────

    /// @notice Pull reserves from caller (must approve). Caller needs RESERVE_DEPOSITOR.
    function deposit(address token, uint256 amount) external onlyDepositor {
        if (!assets[token].enabled) revert AssetNotEnabled();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(token, msg.sender, amount);
    }

    /// @notice Permissionless deposit for enabled assets — anyone may gift reserves.
    function donate(address token, uint256 amount) external {
        if (!assets[token].enabled) revert AssetNotEnabled();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(token, msg.sender, amount);
    }

    function withdraw(address token, address to, uint256 amount) external onlySpender {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    /// @notice Mint WOOD up to excessReserves. Used by Camp (rebase) and Heist (bonds).
    function mintWoodFromExcess(address to, uint256 amount) external onlyMinterCaller {
        if (amount > excessReserves()) revert InsufficientExcess();
        wood.mint(to, amount);
        emit WoodMintedFromExcess(to, amount);
    }

    /// @notice Burn WOOD held by the Treasury (e.g. collateral recovered from a seized Vault loan)
    ///         to reduce supply and restore backing per WOOD. Governor-gated.
    function burnWood(uint256 amount) external onlyGovernor {
        wood.burn(address(this), amount);
        emit WoodBurned(amount);
    }
}
