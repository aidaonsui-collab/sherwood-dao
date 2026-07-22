// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Authority} from "./Authority.sol";
import {WOOD} from "./WOOD.sol";
import {Treasury} from "./Treasury.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/// @title Heist
/// @notice Bond depository (Olympus-style reserve bonds).
///
///         Pricing (user WOOD):
///           payout = quoteUSD * 1e18 / controlVariable
///           controlVariable = USD price per WOOD (18-dec), must be ≥ max(backingPerWood, $1)
///           so the protocol never sells WOOD below RFV (premium / par only — no discount bonds).
///
///         Protocol revenue (two layers, both Olympus-shaped):
///           1) RFV gap: quoteUSD − (payout + protocolShare) * floor ≥ 0  → excess reserves grow
///           2) Protocol mint: protocolShare = payout * protocolMintBps / 10_000
///              minted to the Treasury on each claim (V1 DAO mint, lite default 10%)
///
///         Capacity tracks user-facing WOOD only; excess must cover user + protocol mint at claim.
contract Heist {
    using SafeERC20 for IERC20;

    Authority public immutable authority;
    WOOD public immutable wood;
    Treasury public immutable treasury;

    struct Market {
        address quote;
        address oracle;
        uint8 quoteDecimals;
        uint256 capacity; // remaining user-facing WOOD that can be sold
        uint256 totalDebt; // outstanding unvested user WOOD
        /// @dev USD per WOOD (18-dec). Must stay ≥ RFV floor at deposit time.
        uint256 controlVariable;
        uint256 vestingTerm;
        bool enabled;
    }

    struct Bond {
        uint256 payout; // user WOOD owed
        uint256 vested;
        uint256 lastBlock;
        uint256 vestingEnd;
        uint256 pricePaid; // USD paid (18-dec)
    }

    Market public market;
    mapping(address => Bond) public bonds;

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_PROTOCOL_MINT_BPS = 10_000; // hard cap = classic V1 100% match

    /// @notice Share of each claimed user payout additionally minted to Treasury (default 10%).
    uint256 public protocolMintBps = 1_000;

    event MarketSet(
        address quote, address oracle, uint256 capacity, uint256 controlVariable, uint256 vestingTerm
    );
    event ProtocolMintBpsSet(uint256 bps);
    event BondCreated(
        address indexed user, uint256 payout, uint256 protocolShare, uint256 vestingEnd, uint256 pricePaid
    );
    event BondClaimed(address indexed user, uint256 userAmount, uint256 protocolAmount);

    error MarketDisabled();
    error ZeroAmount();
    error CapacityExceeded();
    error NothingToClaim();
    error BadConfig();
    error InsufficientExcess();
    error BelowRfvFloor();
    error UnprofitableBond();
    error QuoteNotReserve();

    constructor(address authority_, address wood_, address treasury_) {
        authority = Authority(authority_);
        wood = WOOD(wood_);
        treasury = Treasury(treasury_);
    }

    // ── admin ─────────────────────────────────────────────────────────────────

    function setMarket(
        address quote,
        address oracle,
        uint8 quoteDecimals,
        uint256 capacity,
        uint256 controlVariable,
        uint256 vestingTerm
    ) external {
        if (!authority.hasRole(authority.GOVERNOR(), msg.sender)) {
            revert Authority.NotAuthorized(authority.GOVERNOR(), msg.sender);
        }
        if (quote == address(0) || oracle == address(0)) revert BadConfig();
        if (controlVariable < WAD || vestingTerm == 0) revert BadConfig(); // never list below $1
        // Quote must be a Treasury reserve asset credited at FULL RFV (uiMultiplier == 1e18) and
        // priced by the SAME oracle + decimals the bond values against. Otherwise the bond's USD
        // valuation (full price) diverges from the reserves the deposit actually adds (haircut, or
        // 0 if unregistered), silently minting WOOD against backing that never arrived.
        (bool tEnabled, address tOracle, uint256 tMult, uint8 tDecimals) = treasury.assets(quote);
        if (!tEnabled || tMult != WAD || tOracle != oracle || tDecimals != quoteDecimals) {
            revert QuoteNotReserve();
        }
        market = Market({
            quote: quote,
            oracle: oracle,
            quoteDecimals: quoteDecimals,
            capacity: capacity,
            totalDebt: market.totalDebt,
            controlVariable: controlVariable,
            vestingTerm: vestingTerm,
            enabled: true
        });
        emit MarketSet(quote, oracle, capacity, controlVariable, vestingTerm);
    }

    function setEnabled(bool enabled) external {
        if (!authority.hasRole(authority.GOVERNOR(), msg.sender)) {
            revert Authority.NotAuthorized(authority.GOVERNOR(), msg.sender);
        }
        market.enabled = enabled;
    }

    function setProtocolMintBps(uint256 bps) external {
        if (!authority.hasRole(authority.GOVERNOR(), msg.sender)) {
            revert Authority.NotAuthorized(authority.GOVERNOR(), msg.sender);
        }
        if (bps > MAX_PROTOCOL_MINT_BPS) revert BadConfig();
        protocolMintBps = bps;
        emit ProtocolMintBpsSet(bps);
    }

    // ── views ─────────────────────────────────────────────────────────────────

    /// @notice RFV floor used for bond profitability: max(backingPerWood, $1).
    function rfvFloor() public view returns (uint256) {
        uint256 backing = treasury.backingPerWood();
        return backing > WAD ? backing : WAD;
    }

    /// @notice Protocol WOOD that will be minted alongside `userPayout` at current bps.
    function protocolShareOf(uint256 userPayout) public view returns (uint256) {
        return userPayout * protocolMintBps / BPS;
    }

    function pendingPayout(address user) public view returns (uint256) {
        Bond memory b = bonds[user];
        if (b.payout == 0 || b.vested >= b.payout) return 0;
        uint256 remaining = b.payout - b.vested;
        if (block.timestamp >= b.vestingEnd) return remaining;
        if (b.vestingEnd <= b.lastBlock) return remaining;
        uint256 elapsed = block.timestamp - b.lastBlock;
        uint256 window = b.vestingEnd - b.lastBlock;
        return remaining * elapsed / window;
    }

    // ── bond lifecycle ────────────────────────────────────────────────────────

    /// @notice Deposit quote asset → open/extend a vesting WOOD bond.
    function deposit(uint256 quoteAmount) external returns (uint256 payout) {
        Market memory m = market;
        if (!m.enabled) revert MarketDisabled();
        if (quoteAmount == 0) revert ZeroAmount();

        (uint256 price,) = IPriceOracle(m.oracle).latestPrice();
        uint256 norm = quoteAmount;
        if (m.quoteDecimals < 18) norm = quoteAmount * (10 ** (18 - m.quoteDecimals));
        else if (m.quoteDecimals > 18) norm = quoteAmount / (10 ** (m.quoteDecimals - 18));
        uint256 usdValue = norm * price / WAD;
        if (usdValue == 0) revert ZeroAmount();

        // Floor price must cover user + protocol mint at current backing (or $1 hard floor).
        // minPrice = floor * (1 + protocolMintBps/BPS) so total RFV cost ≤ quote at par.
        uint256 floor = rfvFloor();
        uint256 minPrice = floor * (BPS + protocolMintBps) / BPS;
        if (m.controlVariable < minPrice) revert BelowRfvFloor();

        // payout = quoteUSD / bondPrice  (higher controlVariable → fewer WOOD → more protocol RFV profit)
        payout = usdValue * WAD / m.controlVariable;
        if (payout == 0) revert ZeroAmount();
        if (payout > m.capacity) revert CapacityExceeded();

        uint256 protoShare = protocolShareOf(payout);
        // RFV cost of all WOOD that will eventually be minted for this bond.
        uint256 rfvCost = (payout + protoShare) * floor / WAD;
        if (rfvCost > usdValue) revert UnprofitableBond();

        // Quote into Treasury first — raises reserves / excess.
        IERC20(m.quote).safeTransferFrom(msg.sender, address(treasury), quoteAmount);

        // Excess must cover full future mint (user + protocol).
        if (payout + protoShare > treasury.excessReserves()) revert InsufficientExcess();

        market.capacity = m.capacity - payout;
        market.totalDebt = m.totalDebt + payout;

        Bond storage b = bonds[msg.sender];
        uint256 outstanding = b.payout - b.vested;
        b.payout = outstanding + payout;
        b.vested = 0;
        b.lastBlock = block.timestamp;
        b.vestingEnd = block.timestamp + m.vestingTerm;
        b.pricePaid += usdValue;

        emit BondCreated(msg.sender, payout, protoShare, b.vestingEnd, usdValue);
    }

    /// @notice Claim linearly vested WOOD. Mints user share + protocol mint from excess.
    function claim() external returns (uint256 amount) {
        Bond storage b = bonds[msg.sender];
        amount = pendingPayout(msg.sender);
        if (amount == 0) revert NothingToClaim();

        uint256 protoAmount = protocolShareOf(amount);
        uint256 totalMint = amount + protoAmount;
        if (totalMint > treasury.excessReserves()) revert InsufficientExcess();

        b.vested += amount;
        b.lastBlock = block.timestamp;
        if (market.totalDebt >= amount) market.totalDebt -= amount;
        else market.totalDebt = 0;

        treasury.mintWoodFromExcess(msg.sender, amount);
        if (protoAmount > 0) {
            // Protocol-owned WOOD held by Treasury (Olympus V1 DAO mint, lite).
            treasury.mintWoodFromExcess(address(treasury), protoAmount);
        }
        emit BondClaimed(msg.sender, amount, protoAmount);
    }
}
