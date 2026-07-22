// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Authority} from "./Authority.sol";
import {WOOD} from "./WOOD.sol";
import {Treasury} from "./Treasury.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/// @title Heist
/// @notice Minimal single-market bond depository. Pay a quote asset → vest WOOD over time.
///         WOOD capacity is minted from Treasury excess on claim (not up front).
contract Heist {
    using SafeERC20 for IERC20;

    Authority public immutable authority;
    WOOD public immutable wood;
    Treasury public immutable treasury;

    struct Market {
        address quote; // bond payment token
        address oracle; // USD price of quote
        uint8 quoteDecimals;
        uint256 capacity; // remaining WOOD that can be sold (18-dec)
        uint256 totalDebt; // outstanding unvested WOOD
        uint256 controlVariable; // WOOD per 1e18 USD of quote * 1e18 scale (e.g. 1.05e18 = 5% discount → more WOOD)
        uint256 vestingTerm; // seconds
        bool enabled;
    }

    struct Bond {
        uint256 payout; // WOOD owed
        uint256 vested; // WOOD already claimed
        uint256 lastBlock; // last claim timestamp
        uint256 vestingEnd;
        uint256 pricePaid; // USD paid (18-dec), informational
    }

    Market public market;
    mapping(address => Bond) public bonds;

    uint256 public constant WAD = 1e18;

    event MarketSet(
        address quote, address oracle, uint256 capacity, uint256 controlVariable, uint256 vestingTerm
    );
    event BondCreated(address indexed user, uint256 payout, uint256 vestingEnd, uint256 pricePaid);
    event BondClaimed(address indexed user, uint256 amount);

    error MarketDisabled();
    error ZeroAmount();
    error CapacityExceeded();
    error NothingToClaim();
    error BadConfig();
    error InsufficientExcess();

    constructor(address authority_, address wood_, address treasury_) {
        authority = Authority(authority_);
        wood = WOOD(wood_);
        treasury = Treasury(treasury_);
    }

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
        if (controlVariable == 0 || vestingTerm == 0) revert BadConfig();
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

    /// @notice Deposit `quoteAmount` of the market quote token; open/add a vesting bond for WOOD.
    function deposit(uint256 quoteAmount) external returns (uint256 payout) {
        Market memory m = market;
        if (!m.enabled) revert MarketDisabled();
        if (quoteAmount == 0) revert ZeroAmount();

        // USD value of payment
        (uint256 price,) = IPriceOracle(m.oracle).latestPrice();
        uint256 norm = quoteAmount;
        if (m.quoteDecimals < 18) norm = quoteAmount * (10 ** (18 - m.quoteDecimals));
        else if (m.quoteDecimals > 18) norm = quoteAmount / (10 ** (m.quoteDecimals - 18));
        uint256 usdValue = norm * price / WAD;

        // payout = usd * controlVariable / 1e18  (controlVariable > 1e18 → discount bond)
        payout = usdValue * m.controlVariable / WAD;
        if (payout == 0) revert ZeroAmount();
        if (payout > m.capacity) revert CapacityExceeded();

        // Pull quote into Treasury first so the deposit itself funds excess for this bond.
        IERC20(m.quote).safeTransferFrom(msg.sender, address(treasury), quoteAmount);
        // Hard check after credit: discounted payout must still be coverable by RFV excess.
        if (payout > treasury.excessReserves()) revert InsufficientExcess();

        market.capacity = m.capacity - payout;
        market.totalDebt = m.totalDebt + payout;

        Bond storage b = bonds[msg.sender];
        // If existing bond, vest remaining into new combined schedule (simple: add payout, reset vest clock)
        uint256 outstanding = b.payout - b.vested;
        b.payout = outstanding + payout;
        b.vested = 0;
        b.lastBlock = block.timestamp;
        b.vestingEnd = block.timestamp + m.vestingTerm;
        b.pricePaid += usdValue;

        emit BondCreated(msg.sender, payout, b.vestingEnd, usdValue);
    }

    /// @notice Claim linearly vested WOOD. Mints from excess at claim time.
    function claim() external returns (uint256 amount) {
        Bond storage b = bonds[msg.sender];
        amount = pendingPayout(msg.sender);
        if (amount == 0) revert NothingToClaim();

        b.vested += amount;
        b.lastBlock = block.timestamp;
        if (market.totalDebt >= amount) market.totalDebt -= amount;
        else market.totalDebt = 0;

        // Mint from excess — deposit already raised reserves, so this should clear if prices held
        if (amount > treasury.excessReserves()) revert InsufficientExcess();
        treasury.mintWoodFromExcess(msg.sender, amount);
        emit BondClaimed(msg.sender, amount);
    }

    function pendingPayout(address user) public view returns (uint256) {
        Bond memory b = bonds[user];
        if (b.payout == 0 || b.vested >= b.payout) return 0;
        uint256 remaining = b.payout - b.vested;
        if (block.timestamp >= b.vestingEnd) return remaining;
        // Linear from last claim to end
        if (b.vestingEnd <= b.lastBlock) return remaining;
        uint256 elapsed = block.timestamp - b.lastBlock;
        uint256 window = b.vestingEnd - b.lastBlock;
        return remaining * elapsed / window;
    }
}
