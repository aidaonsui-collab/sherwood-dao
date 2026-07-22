// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Authority} from "./Authority.sol";

/// @title WOOD
/// @notice SherwoodDAO reserve currency. Mint/burn only by WOOD_MINTER role (Treasury, Camp, Heist).
contract WOOD is ERC20 {
    Authority public immutable authority;

    error NotMinter();

    constructor(address authority_) ERC20("Sherwood WOOD", "WOOD") {
        authority = Authority(authority_);
    }

    modifier onlyMinter() {
        if (!authority.hasRole(authority.WOOD_MINTER(), msg.sender)) revert NotMinter();
        _;
    }

    function mint(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyMinter {
        _burn(from, amount);
    }
}
