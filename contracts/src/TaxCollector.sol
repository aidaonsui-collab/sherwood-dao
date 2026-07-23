// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Authority} from "./Authority.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/// @notice Minimal Uniswap V2-style router surface used by `convert()`.
///         Not wired to a live WOOD market yet — governor sets the real router when one exists.
interface ITaxSwapRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/**
 * @title TaxCollector
 * @notice Accumulates WOOD from the transfer tax (set WOOD.treasuryWallet = this contract), then
 *         permissionlessly converts the balance to USDG via a governor-configured V2-style router
 *         and splits the USDG proceeds between treasury and team (platform) by bps.
 *
 *         Mirrors the NET TaxCollector pattern on rh4663: tax lands as the raw token first; convert()
 *         sells for the stable and splits proceeds — not the raw WOOD. WOOD's isTaxExempt mapping
 *         must list this contract so the conversion sell does not re-trigger the transfer tax.
 *
 *         `treasuryBps + teamBps` must equal 10_000 (full split of USDG proceeds).
 *
 *         Sandwich protection: convert() is permissionless but does not trust `minUsdgOut` alone.
 *         A governor-set WOOD/USD oracle defines a floor; the effective amountOutMin is
 *         max(caller minUsdgOut, oracleFloor). Callers may only tighten the floor, never loosen it.
 */
contract TaxCollector {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant WAD = 1e18;

    Authority public immutable authority;
    IERC20 public immutable wood;
    IERC20 public immutable usdg;

    /// @notice V2-style router used by convert(). Governor-settable (no live WOOD market at ship time).
    address public router;
    /// @notice Optional pool address for ops/UI; not required by the V2 router path itself.
    address public pool;

    address public treasuryWallet;
    address public platformWallet; // "team" in NET naming

    /// @notice Share of USDG proceeds to treasuryWallet (of 10_000).
    uint256 public treasuryBps;
    /// @notice Share of USDG proceeds to platformWallet (of 10_000). Must satisfy treasuryBps + teamBps == BPS.
    uint256 public teamBps;

    /// @notice WOOD/USD reference price (18-dec). Required before convert(); same feed surface as Treasury.
    IPriceOracle public woodOracle;
    /// @notice Max discount from oracle fair value accepted on convert (of 10_000). 0 = require full oracle value.
    uint256 public maxSlippageBps;

    event RouterSet(address indexed router, address indexed pool);
    event RecipientsSet(address indexed treasuryWallet, address indexed platformWallet);
    event SplitSet(uint256 treasuryBps, uint256 teamBps);
    event WoodOracleSet(address indexed oracle);
    event MaxSlippageBpsSet(uint256 maxSlippageBps);
    /// @param woodIn WOOD sold · @param usdgOut USDG received · split into the two recipient amounts.
    event Converted(
        address indexed caller,
        uint256 woodIn,
        uint256 usdgOut,
        uint256 treasuryAmount,
        uint256 teamAmount
    );

    error BadConfig();
    error NotConfigured();
    error NothingToConvert();
    error ZeroAddress();
    error ZeroPrice();
    error BelowOracleFloor(uint256 minUsdgOut, uint256 oracleFloor);

    constructor(address authority_, address wood_, address usdg_) {
        if (authority_ == address(0) || wood_ == address(0) || usdg_ == address(0)) revert ZeroAddress();
        authority = Authority(authority_);
        wood = IERC20(wood_);
        usdg = IERC20(usdg_);
        // Default split: 100% treasury until governor sets otherwise (safe no-platform default).
        treasuryBps = BPS;
        teamBps = 0;
    }

    modifier onlyGovernor() {
        if (!authority.hasRole(authority.GOVERNOR(), msg.sender)) {
            revert Authority.NotAuthorized(authority.GOVERNOR(), msg.sender);
        }
        _;
    }

    // ── admin ─────────────────────────────────────────────────────────────────

    function setRouter(address router_, address pool_) external onlyGovernor {
        if (router_ == address(0)) revert ZeroAddress();
        router = router_;
        pool = pool_; // may be zero — informational until a real pool exists
        emit RouterSet(router_, pool_);
    }

    function setRecipients(address treasuryWallet_, address platformWallet_) external onlyGovernor {
        if (treasuryWallet_ == address(0)) revert ZeroAddress();
        // platform may be zero only while teamBps == 0
        if (teamBps > 0 && platformWallet_ == address(0)) revert BadConfig();
        treasuryWallet = treasuryWallet_;
        platformWallet = platformWallet_;
        emit RecipientsSet(treasuryWallet_, platformWallet_);
    }

    /// @notice Set USDG proceeds split. `treasuryBps_ + teamBps_` must equal 10_000.
    function setSplit(uint256 treasuryBps_, uint256 teamBps_) external onlyGovernor {
        if (treasuryBps_ + teamBps_ != BPS) revert BadConfig();
        if (teamBps_ > 0 && platformWallet == address(0)) revert BadConfig();
        treasuryBps = treasuryBps_;
        teamBps = teamBps_;
        emit SplitSet(treasuryBps_, teamBps_);
    }

    /// @notice WOOD/USD oracle used as the unconditional convert floor (same IPriceOracle surface as Treasury).
    function setWoodOracle(address oracle_) external onlyGovernor {
        if (oracle_ == address(0)) revert ZeroAddress();
        woodOracle = IPriceOracle(oracle_);
        emit WoodOracleSet(oracle_);
    }

    /// @notice Max bps below oracle fair value that convert() will accept. 0 = exact oracle (strictest).
    function setMaxSlippageBps(uint256 maxSlippageBps_) external onlyGovernor {
        if (maxSlippageBps_ > BPS) revert BadConfig();
        maxSlippageBps = maxSlippageBps_;
        emit MaxSlippageBpsSet(maxSlippageBps_);
    }

    // ── views ─────────────────────────────────────────────────────────────────

    /// @notice Minimum USDG out for `woodAmount` at the oracle price after maxSlippageBps.
    ///         Assumes WOOD and USDG are both 18-decimal and the oracle is WOOD/USD (USDG ≈ $1).
    function minUsdgFromOracle(uint256 woodAmount) public view returns (uint256) {
        if (address(woodOracle) == address(0)) revert NotConfigured();
        (uint256 price,) = woodOracle.latestPrice();
        if (price == 0) revert ZeroPrice();
        uint256 fair = woodAmount * price / WAD;
        return fair * (BPS - maxSlippageBps) / BPS;
    }

    // ── convert ───────────────────────────────────────────────────────────────

    /// @notice Permissionless. Sells up to `woodAmount` (0 = full balance) of WOOD for USDG via
    ///         the configured router, then splits USDG by treasuryBps/teamBps.
    /// @param woodAmount Max WOOD to sell; 0 means the collector's full WOOD balance.
    /// @param minUsdgOut Caller slippage floor; raised on-chain to at least `minUsdgFromOracle(amountIn)`.
    ///                   Callers may only tighten (raise) the floor — a zero or low value is ignored
    ///                   in favor of the oracle floor, so convert(0, 0) remains safe against sandwiches.
    function convert(uint256 woodAmount, uint256 minUsdgOut) external returns (uint256 usdgOut) {
        if (router == address(0) || treasuryWallet == address(0) || address(woodOracle) == address(0)) {
            revert NotConfigured();
        }
        if (teamBps > 0 && platformWallet == address(0)) revert NotConfigured();

        uint256 bal = wood.balanceOf(address(this));
        if (bal == 0) revert NothingToConvert();
        uint256 amountIn = woodAmount == 0 || woodAmount > bal ? bal : woodAmount;
        if (amountIn == 0) revert NothingToConvert();

        // Unconditional on-chain floor (Heist rfvFloor shape): caller min can only tighten it.
        uint256 oracleFloor = minUsdgFromOracle(amountIn);
        uint256 effectiveMin = minUsdgOut > oracleFloor ? minUsdgOut : oracleFloor;

        address[] memory path = new address[](2);
        path[0] = address(wood);
        path[1] = address(usdg);

        wood.forceApprove(router, amountIn);
        uint256 usdgBefore = usdg.balanceOf(address(this));
        ITaxSwapRouter(router).swapExactTokensForTokens(
            amountIn, effectiveMin, path, address(this), block.timestamp
        );
        wood.forceApprove(router, 0);

        usdgOut = usdg.balanceOf(address(this)) - usdgBefore;
        // Belt-and-suspenders if the router lies about amountOutMin enforcement.
        if (usdgOut < effectiveMin) revert BelowOracleFloor(usdgOut, effectiveMin);

        uint256 teamAmount = usdgOut * teamBps / BPS;
        uint256 treasuryAmount = usdgOut - teamAmount;

        if (treasuryAmount > 0) usdg.safeTransfer(treasuryWallet, treasuryAmount);
        if (teamAmount > 0) usdg.safeTransfer(platformWallet, teamAmount);

        emit Converted(msg.sender, amountIn, usdgOut, treasuryAmount, teamAmount);
    }
}
