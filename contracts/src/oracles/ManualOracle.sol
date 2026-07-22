// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {Authority} from "../Authority.sol";

/// @notice Governor-pushed price feed for bootstrap assets without on-chain oracles.
/// @dev Oracle-manipulation risk is explicit — only use until real RH feeds exist.
contract ManualOracle is IPriceOracle {
    Authority public immutable authority;
    uint256 public priceE18;
    uint256 public updatedAt;

    error BadPrice();

    event PriceUpdated(uint256 priceE18, uint256 updatedAt);

    constructor(address authority_, uint256 initialPriceE18) {
        if (initialPriceE18 == 0) revert BadPrice();
        authority = Authority(authority_);
        priceE18 = initialPriceE18;
        updatedAt = block.timestamp;
    }

    function setPrice(uint256 priceE18_) external {
        if (!authority.hasRole(authority.GOVERNOR(), msg.sender)) {
            revert Authority.NotAuthorized(authority.GOVERNOR(), msg.sender);
        }
        if (priceE18_ == 0) revert BadPrice();
        priceE18 = priceE18_;
        updatedAt = block.timestamp;
        emit PriceUpdated(priceE18_, updatedAt);
    }

    function latestPrice() external view returns (uint256, uint256) {
        return (priceE18, updatedAt);
    }
}
