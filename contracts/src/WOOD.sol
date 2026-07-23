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
///
///         The full tax (in WOOD) is sent to `treasuryWallet`. Intended production setup points
///         `treasuryWallet` at a `TaxCollector`, which later converts accumulated WOOD → USDG and
///         splits the stable proceeds (NET-style). `platformWallet` / `platformFeeBps` remain in
///         `setTax` for lock-compatible config surface / event transparency but do **not** route
///         raw WOOD — the collector owns the USDG split.
///
///         `isTaxExempt` is a governor toggle (immediate, no queue) so TaxCollector's convert()
///         sell into a taxed pair does not re-skim the tax. Default taxBps = 0 → no tax anywhere.
///         `setTax` can freeze itself permanently (`taxLocked`). `setTaxedPair` is deliberately
///         NOT lockable — new markets can always be listed.
contract WOOD is ERC20 {
    Authority public immutable authority;

    uint256 public constant BPS = 10_000;
    /// @dev Hard ceiling on the tax rate itself — a seatbelt against a governor mistake or a
    ///      compromised key setting something confiscatory. Well above any rate this protocol
    ///      actually intends to run (5% = 500 bps).
    uint256 public constant MAX_TAX_BPS = 2_000;

    /// @notice Total buy/sell tax, in bps of the transfer amount. 0 = disabled (default).
    uint256 public taxBps;
    /// @notice Legacy config surface (share of tax historically routed to platform). No longer
    ///         used for raw WOOD routing — TaxCollector splits USDG after convert(). Kept so
    ///         `setTax` / `taxLocked` stay a single atomic, lockable config call.
    uint256 public platformFeeBps;
    address public platformWallet;
    /// @notice Destination of the full WOOD tax skim. Production: TaxCollector address.
    address public treasuryWallet;
    mapping(address => bool) public isTaxedPair;
    /// @notice Governor-gated exemption from transfer tax (TaxCollector must be exempt).
    mapping(address => bool) public isTaxExempt;
    /// @notice Once true, `setTax` can never be called again — rate/split/wallets are frozen.
    bool public taxLocked;

    event TaxedPairSet(address indexed pair, bool taxed);
    event TaxExemptSet(address indexed account, bool exempt);
    event TaxConfigSet(
        uint256 taxBps, uint256 platformFeeBps, address platformWallet, address treasuryWallet, bool locked
    );
    /// @param tax full WOOD skim; `platformAmount` is always 0 under collector routing;
    ///        `treasuryAmount == tax` and lands in `treasuryWallet` (the collector).
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

    /// @notice Governor: immediate tax exemption toggle (no queue). TaxCollector must be exempt
    ///         so convert() sales into a taxed pair do not re-trigger the transfer tax.
    function setTaxExempt(address account, bool exempt) external onlyGovernor {
        if (account == address(0)) revert BadConfig();
        isTaxExempt[account] = exempt;
        emit TaxExemptSet(account, exempt);
    }

    /// @notice Governor: set the whole tax config atomically. A non-zero `taxBps_` requires a
    ///         real `treasuryWallet_` (typically TaxCollector) — the full WOOD tax lands there.
    ///         `platformFeeBps_` / `platformWallet_` are retained for lock-compatible config
    ///         history; they do not route raw WOOD. Passing `taxBps_ == 0` disables tax.
    ///         Reverts once `taxLocked` — set `lock_ = true` to freeze permanently.
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
        // Full tax lands in treasuryWallet (collector). platformWallet only required if a
        // non-zero platformFeeBps is recorded for the locked config snapshot.
        if (taxBps_ > 0 && treasuryWallet_ == address(0)) revert BadConfig();
        if (platformFeeBps_ > 0 && platformWallet_ == address(0)) revert BadConfig();
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
            taxBps > 0 && from != address(0) && to != address(0) && !isTaxExempt[from] && !isTaxExempt[to]
                && (isTaxedPair[from] || isTaxedPair[to])
        ) {
            uint256 tax = value * taxBps / BPS;
            if (tax > 0) {
                // Entire WOOD tax → treasuryWallet (TaxCollector). USDG split happens on convert().
                super._update(from, to, value - tax);
                super._update(from, treasuryWallet, tax);
                emit TransferTaxed(from, to, tax, 0, tax);
                return;
            }
        }
        super._update(from, to, value);
    }
}
