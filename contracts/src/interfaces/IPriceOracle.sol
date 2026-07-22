// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice USD price feed, 18 decimals. Phase-1 bootstrap may use ManualOracle / MockOracle.
interface IPriceOracle {
    /// @return priceE18 USD price of 1 whole token unit, scaled 1e18 (e.g. $1 = 1e18)
    /// @return updatedAt unix timestamp of last update
    function latestPrice() external view returns (uint256 priceE18, uint256 updatedAt);
}
