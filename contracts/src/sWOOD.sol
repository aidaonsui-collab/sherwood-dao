// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title sWOOD
/// @notice Non-rebasing share token for The Camp. Only the Camp contract may mint/burn.
///         WOOD-equivalent value is `Camp.toWood(balanceOf(user))` (shares × index).
contract sWOOD is ERC20 {
    address public immutable camp;

    error OnlyCamp();

    constructor(address camp_) ERC20("Staked WOOD", "sWOOD") {
        camp = camp_;
    }

    modifier onlyCamp() {
        if (msg.sender != camp) revert OnlyCamp();
        _;
    }

    function mint(address to, uint256 amount) external onlyCamp {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyCamp {
        _burn(from, amount);
    }
}
