// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Authority
/// @notice Central role registry for SherwoodDAO. Owner (later: Council) grants/revokes roles;
///         modules gate privileged calls with `onlyRole`.
contract Authority is Ownable {
    // ── role ids (bytes32 constants, not OZ AccessControl, to keep surface tiny) ──
    bytes32 public constant GOVERNOR = keccak256("GOVERNOR");
    bytes32 public constant GUARDIAN = keccak256("GUARDIAN");
    bytes32 public constant RESERVE_DEPOSITOR = keccak256("RESERVE_DEPOSITOR");
    bytes32 public constant RESERVE_SPENDER = keccak256("RESERVE_SPENDER");
    bytes32 public constant REWARD_MANAGER = keccak256("REWARD_MANAGER");
    bytes32 public constant BOND_MANAGER = keccak256("BOND_MANAGER");
    bytes32 public constant WOOD_MINTER = keccak256("WOOD_MINTER");

    mapping(bytes32 => mapping(address => bool)) public roles;

    event RoleGranted(bytes32 indexed role, address indexed account);
    event RoleRevoked(bytes32 indexed role, address indexed account);

    error NotAuthorized(bytes32 role, address account);

    constructor(address owner_) Ownable(owner_) {
        // Owner is implicitly governor for bootstrap convenience.
        roles[GOVERNOR][owner_] = true;
        emit RoleGranted(GOVERNOR, owner_);
    }

    modifier onlyRole(bytes32 role) {
        if (!roles[role][msg.sender] && msg.sender != owner()) revert NotAuthorized(role, msg.sender);
        _;
    }

    function grantRole(bytes32 role, address account) external onlyOwner {
        roles[role][account] = true;
        emit RoleGranted(role, account);
    }

    function revokeRole(bytes32 role, address account) external onlyOwner {
        roles[role][account] = false;
        emit RoleRevoked(role, account);
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return roles[role][account] || account == owner();
    }
}
