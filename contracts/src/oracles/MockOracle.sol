// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/// @notice Fixed-price oracle for tests and local deploy.
contract MockOracle is IPriceOracle {
    uint256 public priceE18;
    uint256 public updatedAt;

    constructor(uint256 priceE18_) {
        priceE18 = priceE18_;
        updatedAt = block.timestamp;
    }

    function setPrice(uint256 priceE18_) external {
        priceE18 = priceE18_;
        updatedAt = block.timestamp;
    }

    function latestPrice() external view returns (uint256, uint256) {
        return (priceE18, updatedAt);
    }
}
