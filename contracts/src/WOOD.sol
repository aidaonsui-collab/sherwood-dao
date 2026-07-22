// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Authority} from "./Authority.sol";

/// @title WOOD
/// @notice SherwoodDAO reserve currency. Mint/burn only by WOOD_MINTER role (Treasury, Camp, Heist).
///
///         Transfer tax (disclosed, opt-in, off by default): a governor-set `taxBps` applies only
///         to transfers into/out of a registered `isTaxedPair` (i.e. buys/sells against a listed
///         market), never to plain wallet-to-wallet transfers, staking, or protocol mint/burn
///         (mint has from == address(0), burn has to == address(0) — both skip tax entirely).
///         The tax splits between `platformWallet` and `treasuryWallet` via `platformFeeBps` (a
///         share OF the tax, not of the transfer — same shape as Heist's `founderFeeBps`).
///         Default taxBps = 0 → no tax anywhere, matching the "no platform wallet" default this
///         protocol shipped with; enabling it requires both wallets configured in the same call
///         so a rate can never go live pointed at an unset (zero) address. `setTax` can freeze
///         itself permanently (`taxLocked`) — once locked, the rate/split/wallets can never change
///         again, matching a comparable live token's design where the tax is fixed forever from
///         genesis. `setTaxedPair` is deliberately NOT lockable — new markets can always be listed.
contract WOOD is ERC20 {
    Authority public immutable authority;

    uint256 public constant BPS = 10_000;
    /// @dev Hard ceiling on the tax rate itself — a seatbelt against a governor mistake or a
    ///      compromised key setting something confiscatory. Well above any rate this protocol
    ///      actually intends to run (5% = 500 bps).
    uint256 public constant MAX_TAX_BPS = 2_000;

    /// @notice Total buy/sell tax, in bps of the transfer amount. 0 = disabled (default).
    uint256 public taxBps;
    /// @notice Share of `taxBps` routed to `platformWallet` instead of `treasuryWallet`.
    uint256 public platformFeeBps;
    address public platformWallet;
    address public treasuryWallet;
    mapping(address => bool) public isTaxedPair;
    /// @notice Once true, `setTax` can never be called again — rate, split, and wallets are frozen.
    bool public taxLocked;

    event TaxedPairSet(address indexed pair, bool taxed);
    event TaxConfigSet(
        uint256 taxBps, uint256 platformFeeBps, address platformWallet, address treasuryWallet, bool locked
    );
    /// @param tax splits exactly into `platformAmount` + `treasuryAmount`; `to` receives `value - tax`.
    event TransferTaxed(
        address indexed from,
        address indexed to,
        uint256 tax,
        uint256 platformAmount,
        uint256 treasuryAmount
    );

    error NotMinter();
    error BadConfig();
    error TaxLocked();

    constructor(address authority_) ERC20("Sherwood WOOD", "WOOD") {
        authority = Authority(authority_);
    }

    modifier onlyMinter() {
        if (!authority.hasRole(authority.WOOD_MINTER(), msg.sender)) revert NotMinter();
        _;
    }

    modifier onlyGovernor() {
        if (!authority.hasRole(authority.GOVERNOR(), msg.sender)) {
            revert Authority.NotAuthorized(authority.GOVERNOR(), msg.sender);
        }
        _;
    }

    function mint(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyMinter {
        _burn(from, amount);
    }

    // ── admin ─────────────────────────────────────────────────────────────────

    function setTaxedPair(address pair, bool taxed) external onlyGovernor {
        if (pair == address(0)) revert BadConfig();
        isTaxedPair[pair] = taxed;
        emit TaxedPairSet(pair, taxed);
    }

    /// @notice Governor: set the whole tax config atomically. `platformFeeBps` is a share OF
    ///         `taxBps_` (10_000 = the entire tax goes to platform). A non-zero `taxBps_` requires
    ///         both wallets to be real addresses — otherwise the redirected share would silently
    ///         burn into the zero address. Passing `taxBps_ == 0` disables tax regardless of the
    ///         other params (wallets may be left configured for a later re-enable). Reverts once
    ///         `taxLocked` — set `lock_ = true` here to finalize this call's config permanently in
    ///         the same transaction (no separate unlock path; irreversible by design).
    function setTax(
        uint256 taxBps_,
        uint256 platformFeeBps_,
        address platformWallet_,
        address treasuryWallet_,
        bool lock_
    ) external onlyGovernor {
        if (taxLocked) revert TaxLocked();
        if (taxBps_ > MAX_TAX_BPS) revert BadConfig();
        if (platformFeeBps_ > BPS) revert BadConfig();
        if (taxBps_ > 0 && (platformWallet_ == address(0) || treasuryWallet_ == address(0))) {
            revert BadConfig();
        }
        taxBps = taxBps_;
        platformFeeBps = platformFeeBps_;
        platformWallet = platformWallet_;
        treasuryWallet = treasuryWallet_;
        if (lock_) taxLocked = true;
        emit TaxConfigSet(taxBps_, platformFeeBps_, platformWallet_, treasuryWallet_, lock_);
    }

    // ── transfer tax ──────────────────────────────────────────────────────────

    function _update(address from, address to, uint256 value) internal override {
        if (
            taxBps > 0 && from != address(0) && to != address(0)
                && (isTaxedPair[from] || isTaxedPair[to])
        ) {
            uint256 tax = value * taxBps / BPS;
            if (tax > 0) {
                uint256 platformAmount = tax * platformFeeBps / BPS;
                uint256 treasuryAmount = tax - platformAmount;
                super._update(from, to, value - tax);
                if (platformAmount > 0) super._update(from, platformWallet, platformAmount);
                if (treasuryAmount > 0) super._update(from, treasuryWallet, treasuryAmount);
                emit TransferTaxed(from, to, tax, platformAmount, treasuryAmount);
                return;
            }
        }
        super._update(from, to, value);
    }
}
