// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Authority} from "../src/Authority.sol";
import {WOOD} from "../src/WOOD.sol";
import {sWOOD} from "../src/sWOOD.sol";
import {Treasury} from "../src/Treasury.sol";
import {Camp} from "../src/Camp.sol";
import {Heist} from "../src/Heist.sol";
import {Vault} from "../src/Vault.sol";
import {RangeBound} from "../src/RangeBound.sol";
import {MockOracle} from "../src/oracles/MockOracle.sol";
import {TaxCollector, ITaxSwapRouter} from "../src/TaxCollector.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _decimals = d;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev V2-faithful router mock: pulls WOOD from caller *to the pool* (not to itself), matching
///      Uniswap V2 TransferHelper.safeTransferFrom(path[0], msg.sender, pair, amounts[0]), then
///      mints USDG at a fixed rate for tests. The pool must be set via setPool so taxed-pair
///      semantics are actually exercised when the collector is not tax-exempt.
contract MockTaxRouter is ITaxSwapRouter {
    IERC20 public wood;
    MockERC20 public usdg;
    /// @notice Pair / sink that receives the WOOD pull (production V2 pair address).
    address public pool;
    /// @notice USDG out per 1e18 WOOD in (1e18 = 1:1).
    uint256 public rate = 1e18;

    constructor(address wood_, address usdg_) {
        wood = IERC20(wood_);
        usdg = MockERC20(usdg_);
    }

    function setPool(address pool_) external {
        pool = pool_;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external returns (uint256[] memory amounts) {
        require(path.length == 2, "path");
        require(path[0] == address(wood) && path[1] == address(usdg), "tokens");
        require(pool != address(0), "no pool");
        uint256 out = amountIn * rate / 1e18;
        require(out >= amountOutMin, "slippage");
        // Pull WOOD from caller to the pair — same leg real V2 uses (never holds the token).
        require(wood.transferFrom(msg.sender, pool, amountIn), "pull");
        usdg.mint(to, out);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }
}

contract SherwoodTest is Test {
    Authority internal auth;
    WOOD internal wood;
    Treasury internal treasury;
    Camp internal camp;
    Heist internal heist;
    Vault internal vault;
    RangeBound internal rangeBound;

    MockERC20 internal usdg;
    MockERC20 internal sgov;
    MockOracle internal usdgOracle;
    MockOracle internal sgovOracle;
    MockOracle internal woodSpot;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant WAD = 1e18;

    function setUp() public {
        vm.startPrank(owner);
        auth = new Authority(owner);
        wood = new WOOD(address(auth));
        treasury = new Treasury(address(auth), address(wood));
        camp = new Camp(address(auth), address(wood), address(treasury));
        heist = new Heist(address(auth), address(wood), address(treasury));

        usdg = new MockERC20("USDG", "USDG", 18);
        sgov = new MockERC20("SGOV", "SGOV", 18);
        usdgOracle = new MockOracle(1e18); // $1
        sgovOracle = new MockOracle(1e18); // $1 RFV after multiplier
        woodSpot = new MockOracle(1e18);

        vault = new Vault(address(auth), address(camp), address(treasury), address(usdg));
        rangeBound = new RangeBound(address(auth), address(wood), address(treasury), address(usdg));

        // Roles
        auth.grantRole(auth.WOOD_MINTER(), address(treasury));
        auth.grantRole(auth.REWARD_MANAGER(), address(camp));
        auth.grantRole(auth.BOND_MANAGER(), address(heist));
        auth.grantRole(auth.RESERVE_DEPOSITOR(), owner);
        auth.grantRole(auth.RESERVE_SPENDER(), address(vault));
        auth.grantRole(auth.RESERVE_SPENDER(), address(rangeBound));
        auth.grantRole(auth.GUARDIAN(), owner);

        // Register reserves
        treasury.registerAsset(address(usdg), address(usdgOracle), 1e18, 18);
        treasury.registerAsset(address(sgov), address(sgovOracle), 1e18, 18);

        // Seed treasury with $2M RFV
        usdg.mint(owner, 1_500_000 ether);
        sgov.mint(owner, 500_000 ether);
        usdg.approve(address(treasury), type(uint256).max);
        sgov.approve(address(treasury), type(uint256).max);
        treasury.deposit(address(usdg), 1_500_000 ether);
        treasury.deposit(address(sgov), 500_000 ether);

        // Seed initial WOOD supply to alice via excess mint through a temporary grant
        // Give owner WOOD_MINTER path: mint via treasury as REWARD_MANAGER
        auth.grantRole(auth.REWARD_MANAGER(), owner);
        treasury.mintWoodFromExcess(alice, 100_000 ether); // $100k WOOD against $2M reserves
        vm.stopPrank();

        // Alice approves camp
        vm.prank(alice);
        wood.approve(address(camp), type(uint256).max);
    }

    // ── Treasury ──────────────────────────────────────────────────────────────

    function test_treasury_totalReserves_multiAsset() public view {
        // 1.5M USDG + 0.5M SGOV = 2M
        assertEq(treasury.totalReserves(), 2_000_000 ether);
        // supply 100k → excess 1.9M
        assertEq(treasury.excessReserves(), 1_900_000 ether);
        assertEq(treasury.backingPerWood(), 20 ether); // $20 / WOOD
    }

    function test_mint_fromExcess_revertsWhenInsufficient() public {
        vm.prank(owner);
        vm.expectRevert(Treasury.InsufficientExcess.selector);
        treasury.mintWoodFromExcess(alice, 2_000_001 ether);
    }

    // ── Camp ──────────────────────────────────────────────────────────────────

    function test_stake_unstake_roundTrip() public {
        vm.startPrank(alice);
        uint256 shares = camp.stake(10_000 ether);
        assertEq(shares, 10_000 ether); // index 1e9 → 1:1 shares in "share units"
        // shares minted = wood * 1e9 / index = 10000e18 * 1e9 / 1e9 = 10000e18
        assertEq(camp.sWood().balanceOf(alice), 10_000 ether);
        assertEq(camp.woodBalanceOf(alice), 10_000 ether);

        uint256 out = camp.unstake(shares);
        assertEq(out, 10_000 ether);
        assertEq(wood.balanceOf(alice), 100_000 ether);
        vm.stopPrank();
    }

    function test_rebase_increasesIndex_mintsFromExcess() public {
        vm.prank(alice);
        camp.stake(50_000 ether);

        uint256 indexBefore = camp.index();
        uint256 stakedBefore = camp.totalStakedWood();
        assertEq(stakedBefore, 50_000 ether);

        vm.warp(block.timestamp + 8 hours);
        uint256 reward = camp.rebase();

        // default rewardRateBps = 10 → 0.10% of 50k = 50 WOOD
        assertEq(reward, 50 ether);
        assertGt(camp.index(), indexBefore);
        assertEq(camp.totalStakedWood(), 50_050 ether);
        // alice's wood balance via shares grew
        assertEq(camp.woodBalanceOf(alice), 50_050 ether);
    }

    function test_rebase_cappedByExcess() public {
        // Drain excess almost fully by minting most of it
        uint256 excess = treasury.excessReserves();
        vm.prank(owner);
        treasury.mintWoodFromExcess(bob, excess - 10 ether); // leave only 10 WOOD excess

        vm.prank(alice);
        camp.stake(50_000 ether);

        // Desired reward = 50 WOOD but excess is only 10
        vm.warp(block.timestamp + 8 hours);
        uint256 reward = camp.rebase();
        assertEq(reward, 10 ether);
    }

    function test_rebase_tooEarly_reverts() public {
        vm.expectRevert(Camp.EpochNotEnded.selector);
        camp.rebase();
    }

    // ── Heist (Olympus-style RFV + protocol mint) ─────────────────────────────

    function test_heist_bond_vestsWood() public {
        // Backing = $20/WOOD, protocolMintBps = 10% → minPrice = 22e18
        // Price at min → $1000 buys 1000/22 ≈ 45.4545 WOOD user, 4.545 protocol
        uint256 minPrice = heist.rfvFloor() * (10_000 + heist.protocolMintBps()) / 10_000;
        assertEq(minPrice, 22 ether);

        vm.prank(owner);
        heist.setMarket(address(usdg), address(usdgOracle), 18, 10_000 ether, minPrice, 1 days);

        usdg.mint(bob, 1_000 ether);
        vm.startPrank(bob);
        usdg.approve(address(heist), type(uint256).max);
        uint256 payout = heist.deposit(1_000 ether);
        uint256 expected = uint256(1_000 ether) * 1e18 / minPrice;
        assertEq(payout, expected);

        // Halfway through vest
        vm.warp(block.timestamp + 12 hours);
        uint256 pending = heist.pendingPayout(bob);
        assertApproxEqAbs(pending, expected / 2, 1e15);

        uint256 woodBeforeTreasury = wood.balanceOf(address(treasury));
        uint256 claimed = heist.claim();
        assertApproxEqAbs(claimed, expected / 2, 1e15);
        assertApproxEqAbs(wood.balanceOf(bob), claimed, 1e15);
        // Protocol mint 10% of claim → Treasury
        uint256 proto = claimed * heist.protocolMintBps() / 10_000;
        assertApproxEqAbs(wood.balanceOf(address(treasury)) - woodBeforeTreasury, proto, 1e15);

        // Finish vest
        vm.warp(block.timestamp + 12 hours);
        uint256 claimed2 = heist.claim();
        assertGt(claimed2, 0);
        assertApproxEqAbs(wood.balanceOf(bob), expected, 1e15);
        vm.stopPrank();
    }

    function test_heist_belowRfvFloor_reverts() public {
        // controlVariable $1 while backing is $20 → rejected
        vm.prank(owner);
        heist.setMarket(address(usdg), address(usdgOracle), 18, 10_000 ether, 1 ether, 1 days);

        usdg.mint(bob, 1_000 ether);
        vm.startPrank(bob);
        usdg.approve(address(heist), type(uint256).max);
        vm.expectRevert(Heist.BelowRfvFloor.selector);
        heist.deposit(1_000 ether);
        vm.stopPrank();
    }

    function test_heist_premium_grows_excess() public {
        // Price well above min → fewer WOOD → larger RFV gap (protocol profit)
        uint256 minPrice = heist.rfvFloor() * (10_000 + heist.protocolMintBps()) / 10_000;
        uint256 premiumPrice = minPrice * 2; // 2× min
        vm.prank(owner);
        heist.setMarket(address(usdg), address(usdgOracle), 18, 10_000 ether, premiumPrice, 1 days);

        uint256 excessBefore = treasury.excessReserves();
        usdg.mint(bob, 1_000 ether);
        vm.startPrank(bob);
        usdg.approve(address(heist), type(uint256).max);
        uint256 payout = heist.deposit(1_000 ether);
        vm.stopPrank();

        // After deposit: +1000 reserves, no mint yet → excess up by 1000
        assertEq(treasury.excessReserves(), excessBefore + 1_000 ether);
        // User WOOD owed is half of min-price case
        assertEq(payout, uint256(1_000 ether) * 1e18 / premiumPrice);
    }

    // ── Vault ─────────────────────────────────────────────────────────────────

    function test_vault_borrow_atBackingFloor_noSpotOracle() public {
        // alice stakes then deposits sWOOD as collateral
        vm.startPrank(alice);
        camp.stake(10_000 ether);
        sWOOD s = camp.sWood();
        s.approve(address(vault), type(uint256).max);
        vault.deposit(10_000 ether);

        // backing = $20/WOOD, LTV 95% → max borrow = 10000 * 20 * 0.95 = 190_000 USDG
        uint256 maxB = vault.maxBorrow(alice);
        assertEq(maxB, 190_000 ether);

        vault.borrow(50_000 ether);
        assertEq(usdg.balanceOf(alice), 50_000 ether);
        (uint256 col, uint256 principal, uint256 debt,) = vault.positions(alice);
        assertEq(col, 10_000 ether);
        assertEq(principal, 50_000 ether);
        assertEq(debt, 50_000 ether);
        vm.stopPrank();
    }

    function test_vault_interest_repays_to_treasury() public {
        vm.startPrank(alice);
        camp.stake(10_000 ether);
        camp.sWood().approve(address(vault), type(uint256).max);
        vault.deposit(10_000 ether);
        vault.borrow(10_000 ether);
        vm.stopPrank();

        // Accrue ~1 year of 0.50% on 10k = 50 USDG interest
        vm.warp(block.timestamp + 365 days);

        uint256 reservesBefore = usdg.balanceOf(address(treasury));
        vm.startPrank(alice);
        // Pull more USDG for interest repayment
        // alice has 10k from borrow; needs ~50 more — mint to alice for test
        vm.stopPrank();
        usdg.mint(alice, 100 ether);
        vm.startPrank(alice);
        usdg.approve(address(vault), type(uint256).max);
        vault.repay(type(uint256).max); // repay all
        vm.stopPrank();

        assertGt(vault.totalInterestAccrued(), 0);
        assertGt(vault.totalInterestRepaid(), 0);
        // Full principal+interest returned to treasury
        assertGt(usdg.balanceOf(address(treasury)), reservesBefore);
        (,, uint256 debt,) = vault.positions(alice);
        assertEq(debt, 0);
    }

    function test_vault_borrowAboveLtv_reverts() public {
        vm.startPrank(alice);
        camp.stake(1_000 ether);
        camp.sWood().approve(address(vault), type(uint256).max);
        vault.deposit(1_000 ether);
        // max = 1000 * 20 * 0.95 = 19_000
        vm.expectRevert(Vault.ExceedsLtv.selector);
        vault.borrow(19_001 ether);
        vm.stopPrank();
    }

    // ── RangeBound skeleton ─────────────────────────────────────────────────────

    function test_rangeBound_inBand_bidReverts() public {
        vm.prank(owner);
        rangeBound.setSpotOracle(address(woodSpot));
        // spot $1, backing $20, lower = 20 * 0.95 = 19 → spot << lower → actually BELOW band, bid OK
        // set spot high inside band
        woodSpot.setPrice(20 ether); // at backing
        vm.prank(owner);
        vm.expectRevert(RangeBound.InBand.selector);
        rangeBound.executeBid(100 ether);
    }

    function test_rangeBound_belowBand_bidPullsUsdg() public {
        vm.prank(owner);
        rangeBound.setSpotOracle(address(woodSpot));
        woodSpot.setPrice(10 ether); // below lower bound (~19)
        uint256 before = usdg.balanceOf(address(rangeBound));
        vm.prank(owner);
        rangeBound.executeBid(100 ether);
        assertEq(usdg.balanceOf(address(rangeBound)), before + 100 ether);
    }

    // ── Finding #1: bond quote must be a full-RFV treasury reserve w/ matching oracle ──────────

    function test_heist_quoteMustBeFullRfvReserve_reverts() public {
        uint256 minPrice = heist.rfvFloor() * (10_000 + heist.protocolMintBps()) / 10_000;
        MockERC20 rando = new MockERC20("RANDO", "RND", 18);
        MockOracle randoOracle = new MockOracle(1e18);

        vm.startPrank(owner);

        // (1) Unregistered quote → bond value would be credited $0 by the treasury → revert.
        vm.expectRevert(Heist.QuoteNotReserve.selector);
        heist.setMarket(address(rando), address(randoOracle), 18, 10_000 ether, minPrice, 1 days);

        // (2) Registered but haircut (uiMultiplier 0.9e18) → deposit adds < bond USD value → revert.
        treasury.registerAsset(address(rando), address(randoOracle), 0.9e18, 18);
        vm.expectRevert(Heist.QuoteNotReserve.selector);
        heist.setMarket(address(rando), address(randoOracle), 18, 10_000 ether, minPrice, 1 days);

        // (3) Full RFV but bond oracle ≠ treasury oracle → valuations can diverge → revert.
        treasury.setAsset(address(rando), true, address(randoOracle), 1e18);
        MockOracle otherOracle = new MockOracle(1e18);
        vm.expectRevert(Heist.QuoteNotReserve.selector);
        heist.setMarket(address(rando), address(otherOracle), 18, 10_000 ether, minPrice, 1 days);

        // (4) Enabled + full RFV + matching oracle & decimals → accepted.
        heist.setMarket(address(rando), address(randoOracle), 18, 10_000 ether, minPrice, 1 days);
        (address q,,,,,,,) = heist.market();
        assertEq(q, address(rando));
        vm.stopPrank();
    }

    // ── Finding #2: underwater loans can be seized; collateral recovered to treasury ───────────

    function test_vault_seize_underwater_recoversCollateral() public {
        vm.startPrank(alice);
        camp.stake(10_000 ether);
        camp.sWood().approve(address(vault), type(uint256).max);
        vault.deposit(10_000 ether);
        vault.borrow(100_000 ether); // backing $20 → max 190k → healthy
        vm.stopPrank();

        // Healthy position: seize reverts.
        vm.prank(owner);
        vm.expectRevert(Vault.NotUnderwater.selector);
        vault.seize(alice);

        // Crash USDG price → treasury RFV collapses → backing falls → position underwater.
        // treasury USDG = 1.5M − 100k = 1.4M; @ $0.05 = 70k, + 500k SGOV = 570k / 100k supply = $5.7.
        // maxBorrowFor(10k) = 10k × 5.7 × 0.95 = 54,150 < 100k debt → underwater.
        usdgOracle.setPrice(0.05 ether);
        assertLt(vault.maxBorrowFor(10_000 ether), 100_000 ether);

        // Non-guardian cannot seize.
        vm.prank(alice);
        vm.expectRevert();
        vault.seize(alice);

        uint256 treasuryWoodBefore = wood.balanceOf(address(treasury));
        uint256 supplyBefore = wood.totalSupply();

        vm.prank(owner); // owner holds GUARDIAN
        uint256 recovered = vault.seize(alice);

        (uint256 col, uint256 principal, uint256 debt,) = vault.positions(alice);
        assertEq(col, 0);
        assertEq(principal, 0);
        assertEq(debt, 0);
        assertEq(vault.totalCollateralShares(), 0);
        assertEq(recovered, 10_000 ether); // index 1:1, no rebase
        assertEq(wood.balanceOf(address(treasury)) - treasuryWoodBefore, 10_000 ether);

        // Governance burns the recovered WOOD → supply shrinks → backing restored for holders.
        vm.prank(owner);
        treasury.burnWood(10_000 ether);
        assertEq(wood.totalSupply(), supplyBefore - 10_000 ether);
    }

    // ── Finding #3: mint-role invariant (Camp/Heist must NOT hold WOOD_MINTER) ─────────────────

    // ── Founder fee: disclosed split of the (unchanged) protocol mint ──────────────────────────

    function test_heist_founderFee_splitsProtocolMintWithoutChangingTotal() public {
        address founder = makeAddr("founder");
        vm.prank(owner);
        heist.setFounderFee(founder, 3_000); // 30% of the protocol share, 70% stays with Treasury

        uint256 minPrice = heist.rfvFloor() * (10_000 + heist.protocolMintBps()) / 10_000;
        vm.prank(owner);
        heist.setMarket(address(usdg), address(usdgOracle), 18, 10_000 ether, minPrice * 2, 1 days);

        usdg.mint(bob, 1_000 ether);
        vm.startPrank(bob);
        usdg.approve(address(heist), type(uint256).max);
        uint256 payout = heist.deposit(1_000 ether);
        vm.warp(block.timestamp + 1 days);

        uint256 treasuryWoodBefore = wood.balanceOf(address(treasury));
        uint256 claimed = heist.claim();
        vm.stopPrank();

        uint256 expectedProto = claimed * heist.protocolMintBps() / 10_000;
        uint256 expectedFounder = expectedProto * 3_000 / 10_000;
        uint256 expectedTreasury = expectedProto - expectedFounder;

        assertEq(claimed, payout);
        assertEq(wood.balanceOf(founder), expectedFounder);
        assertEq(wood.balanceOf(address(treasury)) - treasuryWoodBefore, expectedTreasury);
        // Total protocol-side mint is IDENTICAL to the no-founder-fee case — only the destination
        // of the existing protocolMintBps cut changed, not its size.
        assertEq(expectedFounder + expectedTreasury, expectedProto);
    }

    function test_heist_founderFee_defaultsToAllTreasury() public {
        // No setFounderFee call at all — founderFeeBps=0, recipient=address(0) out of the box.
        uint256 minPrice = heist.rfvFloor() * (10_000 + heist.protocolMintBps()) / 10_000;
        vm.prank(owner);
        heist.setMarket(address(usdg), address(usdgOracle), 18, 10_000 ether, minPrice * 2, 1 days);

        usdg.mint(bob, 1_000 ether);
        vm.startPrank(bob);
        usdg.approve(address(heist), type(uint256).max);
        heist.deposit(1_000 ether);
        vm.warp(block.timestamp + 1 days);
        uint256 treasuryWoodBefore = wood.balanceOf(address(treasury));
        uint256 claimed = heist.claim();
        vm.stopPrank();

        uint256 expectedProto = claimed * heist.protocolMintBps() / 10_000;
        assertEq(wood.balanceOf(address(treasury)) - treasuryWoodBefore, expectedProto);
    }

    function test_heist_setFounderFee_governorOnly_reverts() public {
        vm.prank(bob);
        vm.expectRevert();
        heist.setFounderFee(bob, 1_000);
    }

    function test_heist_setFounderFee_badConfig_reverts() public {
        vm.startPrank(owner);
        vm.expectRevert(Heist.BadConfig.selector);
        heist.setFounderFee(bob, 10_001); // > BPS

        vm.expectRevert(Heist.BadConfig.selector);
        heist.setFounderFee(address(0), 1); // bps > 0 with no recipient
        vm.stopPrank();
    }

    function test_heist_setFounderFee_clearBackToDisabled() public {
        address founder = makeAddr("founder");
        vm.startPrank(owner);
        heist.setFounderFee(founder, 5_000);
        assertEq(heist.founderFeeBps(), 5_000);

        heist.setFounderFee(address(0), 0);
        vm.stopPrank();
        assertEq(heist.founderFeeBps(), 0);
        assertEq(heist.founderFeeRecipient(), address(0));
    }

    function test_roleWiring_onlyTreasuryMintsWood() public view {
        assertTrue(auth.hasRole(auth.WOOD_MINTER(), address(treasury)));
        assertFalse(auth.hasRole(auth.WOOD_MINTER(), address(camp)));
        assertFalse(auth.hasRole(auth.WOOD_MINTER(), address(heist)));
        assertTrue(auth.hasRole(auth.REWARD_MANAGER(), address(camp)));
        assertTrue(auth.hasRole(auth.BOND_MANAGER(), address(heist)));
    }

    // ── Low fixes: re-bond auto-claims vested WOOD (no vesting re-lock) ─────────────────────────

    function test_heist_rebond_autoClaimsVested() public {
        uint256 minPrice = heist.rfvFloor() * (10_000 + heist.protocolMintBps()) / 10_000;
        // Price at a premium above the floor: the first deposit lifts backing (reserves up, no mint
        // yet), so a market priced exactly at the floor would reject the second deposit before the
        // auto-claim can run. Real markets carry headroom above the floor for the same reason.
        uint256 price = minPrice * 2;
        vm.prank(owner);
        heist.setMarket(address(usdg), address(usdgOracle), 18, 100_000 ether, price, 1 days);

        usdg.mint(bob, 2_000 ether);
        vm.startPrank(bob);
        usdg.approve(address(heist), type(uint256).max);
        uint256 firstPayout = heist.deposit(1_000 ether);

        // Halfway through the first bond's vest, bond again.
        vm.warp(block.timestamp + 12 hours);
        uint256 pendingBefore = heist.pendingPayout(bob);
        assertApproxEqAbs(pendingBefore, firstPayout / 2, 1e15);

        assertEq(wood.balanceOf(bob), 0); // nothing delivered yet
        heist.deposit(1_000 ether); // re-bond → should auto-deliver the vested half

        // The vested half was minted to bob instead of being re-locked on a fresh clock.
        assertApproxEqAbs(wood.balanceOf(bob), firstPayout / 2, 1e15);
        // Outstanding bond now = unvested remainder of bond 1 + full bond 2, freshly vesting.
        (uint256 bondPayout, uint256 vested,,,) = heist.bonds(bob);
        assertEq(vested, 0);
        assertApproxEqAbs(bondPayout, firstPayout / 2 + firstPayout, 1e15);
        vm.stopPrank();
    }

    // ── Low fixes: setAsset requires prior registration (else silently uncounted) ──────────────

    function test_treasury_setAsset_unregistered_reverts() public {
        MockERC20 rando = new MockERC20("RND", "RND", 18);
        MockOracle o = new MockOracle(1e18);
        vm.prank(owner);
        vm.expectRevert(Treasury.AssetNotRegistered.selector);
        treasury.setAsset(address(rando), true, address(o), 1e18);
    }

    // ── Low fixes: opt-in oracle staleness guard ───────────────────────────────────────────────

    // ── WOOD transfer tax: disclosed, opt-in buy/sell tax on registered pairs only ──────────────

    function test_wood_tax_defaultsOff_noTaxOnAnyTransfer() public {
        address pair = makeAddr("pair");
        vm.prank(owner);
        wood.setTaxedPair(pair, true); // pair registered, but taxBps is still 0

        vm.prank(alice);
        wood.transfer(pair, 10_000 ether);
        assertEq(wood.balanceOf(pair), 10_000 ether); // full amount, no skim
    }

    function test_wood_tax_appliesOnBuyAndSell_fullTaxToCollectorWallet() public {
        address pair = makeAddr("pair");
        address collector = makeAddr("collector"); // stands in for TaxCollector
        vm.startPrank(owner);
        wood.setTaxedPair(pair, true);
        // Full WOOD tax lands in treasuryWallet (collector). platformFeeBps is config-only.
        wood.setTax(500, 0, address(0), collector, false);
        vm.stopPrank();

        // Sell: alice → pair.
        uint256 sellAmount = 10_000 ether;
        uint256 sellTax = sellAmount * 500 / 10_000;

        vm.prank(alice);
        wood.transfer(pair, sellAmount);

        assertEq(wood.balanceOf(pair), sellAmount - sellTax);
        assertEq(wood.balanceOf(collector), sellTax);

        // Buy: pair → bob (pair now holds sellAmount - sellTax from the leg above).
        uint256 buyAmount = 3_000 ether;
        uint256 buyTax = buyAmount * 500 / 10_000;
        uint256 collectorBefore = wood.balanceOf(collector);

        vm.prank(pair);
        wood.transfer(bob, buyAmount);

        assertEq(wood.balanceOf(bob), buyAmount - buyTax);
        assertEq(wood.balanceOf(collector) - collectorBefore, buyTax);
    }

    function test_wood_tax_skipsMintAndBurn() public {
        address pair = makeAddr("pair");
        address collector = makeAddr("collector");
        vm.startPrank(owner);
        wood.setTaxedPair(pair, true);
        wood.setTax(500, 0, address(0), collector, false);
        vm.stopPrank();

        // Mint straight to the registered pair address itself — from == address(0), must skip tax.
        vm.prank(address(treasury));
        wood.mint(pair, 5_000 ether);
        assertEq(wood.balanceOf(pair), 5_000 ether); // no skim taken off a mint

        // Burn from the pair — to == address(0), must also skip tax.
        vm.prank(address(treasury));
        wood.burn(pair, 2_000 ether);
        assertEq(wood.balanceOf(pair), 3_000 ether);
        assertEq(wood.balanceOf(collector), 0);
    }

    function test_wood_tax_skipsPlainWalletTransfer() public {
        // Tax enabled, but neither alice nor bob is a registered pair — plain P2P transfer untaxed.
        address pair = makeAddr("pair");
        address collector = makeAddr("collector");
        vm.startPrank(owner);
        wood.setTaxedPair(pair, true);
        wood.setTax(500, 0, address(0), collector, false);
        vm.stopPrank();

        vm.prank(alice);
        wood.transfer(bob, 1_000 ether);
        assertEq(wood.balanceOf(bob), 1_000 ether);
        assertEq(wood.balanceOf(collector), 0);
    }

    function test_wood_setTax_governorOnly_reverts() public {
        vm.prank(bob);
        vm.expectRevert();
        wood.setTax(500, 0, address(0), address(treasury), false);
    }

    function test_wood_setTax_badConfig_reverts() public {
        uint256 tooHigh = wood.MAX_TAX_BPS() + 1; // read before expectRevert — it's a separate call
        vm.startPrank(owner);
        vm.expectRevert(WOOD.BadConfig.selector);
        wood.setTax(tooHigh, 0, address(0), address(treasury), false); // > MAX_TAX_BPS

        vm.expectRevert(WOOD.BadConfig.selector);
        wood.setTax(500, 10_001, bob, address(treasury), false); // platformFeeBps > BPS

        vm.expectRevert(WOOD.BadConfig.selector);
        wood.setTax(500, 5_000, address(0), address(treasury), false); // platformFeeBps > 0, zero platform

        vm.expectRevert(WOOD.BadConfig.selector);
        wood.setTax(500, 0, address(0), address(0), false); // taxBps > 0, zero treasury wallet
        vm.stopPrank();
    }

    function test_wood_setTax_locksPermanently() public {
        address collector = makeAddr("collector");
        vm.startPrank(owner);
        // Lock in the same call that sets the real config — matches NET's one-shot-at-genesis shape.
        wood.setTax(500, 0, address(0), collector, true);
        assertTrue(wood.taxLocked());
        assertEq(wood.taxBps(), 500);
        assertEq(wood.treasuryWallet(), collector);

        vm.expectRevert(WOOD.TaxLocked.selector);
        wood.setTax(0, 0, address(0), address(0), false); // even disabling it is blocked once locked
        vm.stopPrank();

        // setTaxedPair is deliberately NOT covered by the lock — new markets can still be listed.
        vm.prank(owner);
        wood.setTaxedPair(makeAddr("newPair"), true);
    }

    function test_wood_setTaxedPair_governorOnly_reverts() public {
        vm.prank(bob);
        vm.expectRevert();
        wood.setTaxedPair(makeAddr("pair"), true);
    }

    // ── TaxCollector: WOOD → USDG convert + split (NET-style) ─────────────────

    /// @dev Configure collector + V2-faithful mock router for convert tests.
    function _configureCollector(TaxCollector collector, MockTaxRouter router, address pair, address platform)
        internal
    {
        router.setPool(pair);
        collector.setRouter(address(router), pair);
        collector.setRecipients(address(treasury), platform);
        collector.setWoodOracle(address(woodSpot)); // $1 WOOD (setUp default)
        collector.setMaxSlippageBps(0); // require full oracle value unless a test loosens
    }

    function test_wood_tax_accumulatesInTaxCollector() public {
        address pair = makeAddr("pair");
        TaxCollector collector = new TaxCollector(address(auth), address(wood), address(usdg));
        vm.startPrank(owner);
        wood.setTaxedPair(pair, true);
        wood.setTax(500, 0, address(0), address(collector), false);
        wood.setTaxExempt(address(collector), true);
        vm.stopPrank();

        uint256 sellAmount = 10_000 ether;
        uint256 tax = sellAmount * 500 / 10_000;
        vm.prank(alice);
        wood.transfer(pair, sellAmount);
        assertEq(wood.balanceOf(address(collector)), tax);
    }

    function test_taxCollector_convert_swapsAndSplits() public {
        address pair = makeAddr("pair");
        address platform = makeAddr("platform");
        TaxCollector collector = new TaxCollector(address(auth), address(wood), address(usdg));
        MockTaxRouter router = new MockTaxRouter(address(wood), address(usdg));

        vm.startPrank(owner);
        wood.setTaxedPair(pair, true);
        wood.setTax(500, 0, address(0), address(collector), false);
        wood.setTaxExempt(address(collector), true);
        _configureCollector(collector, router, pair, platform);
        // NET-shaped proceeds split: ~1/3 treasury / ~2/3 team on a 10_000 scale.
        collector.setSplit(3_340, 6_660);
        vm.stopPrank();

        // Accumulate tax WOOD in collector.
        uint256 sellAmount = 10_000 ether;
        uint256 tax = sellAmount * 500 / 10_000; // 500 ether
        vm.prank(alice);
        wood.transfer(pair, sellAmount);
        assertEq(wood.balanceOf(address(collector)), tax);

        uint256 treasUsdgBefore = usdg.balanceOf(address(treasury));
        uint256 platformUsdgBefore = usdg.balanceOf(platform);

        // Anyone may convert; minUsdgOut=0 is raised to the oracle floor on chain.
        vm.prank(bob);
        uint256 usdgOut = collector.convert(0, 0); // full balance
        assertEq(usdgOut, tax); // mock 1:1 at $1 oracle
        assertEq(wood.balanceOf(address(collector)), 0);

        uint256 expectedTeam = usdgOut * 6_660 / 10_000;
        uint256 expectedTreasury = usdgOut - expectedTeam;
        assertEq(usdg.balanceOf(platform) - platformUsdgBefore, expectedTeam);
        assertEq(usdg.balanceOf(address(treasury)) - treasUsdgBefore, expectedTreasury);
    }

    /// @notice Load-bearing exemption test: MockTaxRouter pulls WOOD to the *taxed pair* (V2
    ///         semantics). Without setTaxExempt(collector), convert leaves residual tax WOOD on
    ///         the collector and the pair receives only (amountIn − tax). With exemption, the
    ///         full amount lands on the pair and the collector balance goes to zero.
    function test_taxCollector_convert_exemptSaleNotRetaxed() public {
        address pair = makeAddr("pair");
        address platform = makeAddr("platform");
        TaxCollector collector = new TaxCollector(address(auth), address(wood), address(usdg));
        MockTaxRouter router = new MockTaxRouter(address(wood), address(usdg));

        vm.startPrank(owner);
        wood.setTaxedPair(pair, true);
        wood.setTax(500, 0, address(0), address(collector), false);
        wood.setTaxExempt(address(collector), true);
        _configureCollector(collector, router, pair, platform);
        collector.setSplit(5_000, 5_000);
        vm.stopPrank();

        // Fund collector directly with known WOOD (mint path).
        vm.prank(address(treasury));
        wood.mint(address(collector), 1_000 ether);

        uint256 treasBefore = usdg.balanceOf(address(treasury));
        uint256 platBefore = usdg.balanceOf(platform);
        // Router pulls 1000 WOOD to the taxed pair. With exemption, full amount lands on pair
        // and collector residual is zero — these asserts fail if exemption is removed.
        collector.convert(0, 0);
        assertEq(wood.balanceOf(address(collector)), 0);
        assertEq(wood.balanceOf(pair), 1_000 ether);
        assertEq(
            (usdg.balanceOf(address(treasury)) - treasBefore) + (usdg.balanceOf(platform) - platBefore),
            1_000 ether
        );
    }

    /// @notice Counterpart to exemptSaleNotRetaxed: without exemption, selling into a taxed pair
    ///         re-skims the collector. Proves the pair-sink mock makes exemption load-bearing.
    function test_taxCollector_convert_withoutExempt_leavesResidualTax() public {
        address pair = makeAddr("pair");
        address platform = makeAddr("platform");
        TaxCollector collector = new TaxCollector(address(auth), address(wood), address(usdg));
        MockTaxRouter router = new MockTaxRouter(address(wood), address(usdg));

        vm.startPrank(owner);
        wood.setTaxedPair(pair, true);
        wood.setTax(500, 0, address(0), address(collector), false);
        // deliberately NO setTaxExempt(collector)
        _configureCollector(collector, router, pair, platform);
        collector.setSplit(5_000, 5_000);
        vm.stopPrank();

        vm.prank(address(treasury));
        wood.mint(address(collector), 1_000 ether);

        // convert still "succeeds" (transferFrom of amountIn nets tax back to collector),
        // but leaves residual WOOD and under-delivers to the pair.
        collector.convert(0, 0);
        uint256 expectedTax = 1_000 ether * 500 / 10_000; // 50 ether
        assertEq(wood.balanceOf(address(collector)), expectedTax);
        assertEq(wood.balanceOf(pair), 1_000 ether - expectedTax);
    }

    function test_taxCollector_nonExemptStillTaxedNormally() public {
        address pair = makeAddr("pair");
        TaxCollector collector = new TaxCollector(address(auth), address(wood), address(usdg));
        // Collector is treasuryWallet but deliberately NOT exempt — proves exemption is scoped.
        vm.startPrank(owner);
        wood.setTaxedPair(pair, true);
        wood.setTax(500, 0, address(0), address(collector), false);
        // no setTaxExempt
        vm.stopPrank();

        vm.prank(alice);
        wood.transfer(pair, 10_000 ether);
        // Tax still lands on collector as recipient of the skim (from=alice, to=collector is not
        // pair-sided for the skim legs... wait: skim is from→collector, collector not pair, so
        // the skim itself is not taxed. Non-exempt matters for collector selling INTO pair.
        assertEq(wood.balanceOf(address(collector)), 500 ether);

        // Non-exempt address selling into pair still pays tax.
        vm.prank(alice);
        wood.transfer(bob, 2_000 ether); // P2P untaxed
        vm.prank(bob);
        wood.transfer(pair, 1_000 ether);
        uint256 expectedTax = 1_000 ether * 500 / 10_000;
        assertEq(wood.balanceOf(pair), (10_000 ether - 500 ether) + (1_000 ether - expectedTax));
        assertEq(wood.balanceOf(address(collector)), 500 ether + expectedTax);
        assertEq(wood.balanceOf(bob), 1_000 ether); // 2k received − 1k sold
    }

    function test_taxCollector_setters_governorOnly() public {
        TaxCollector collector = new TaxCollector(address(auth), address(wood), address(usdg));
        vm.prank(bob);
        vm.expectRevert();
        collector.setRouter(makeAddr("r"), makeAddr("p"));

        vm.prank(bob);
        vm.expectRevert();
        collector.setRecipients(address(treasury), bob);

        vm.prank(bob);
        vm.expectRevert();
        collector.setSplit(5_000, 5_000);

        vm.prank(bob);
        vm.expectRevert();
        collector.setWoodOracle(address(woodSpot));

        vm.prank(bob);
        vm.expectRevert();
        collector.setMaxSlippageBps(100);

        vm.prank(bob);
        vm.expectRevert();
        wood.setTaxExempt(address(collector), true);
    }

    function test_taxCollector_splitMustSumToBps() public {
        TaxCollector collector = new TaxCollector(address(auth), address(wood), address(usdg));
        vm.startPrank(owner);
        collector.setRecipients(address(treasury), bob);
        vm.expectRevert(TaxCollector.BadConfig.selector);
        collector.setSplit(5_000, 4_999); // != 10000
        collector.setSplit(3_340, 6_660); // ok
        vm.stopPrank();
    }

    function test_taxCollector_convert_requiresConfig() public {
        TaxCollector collector = new TaxCollector(address(auth), address(wood), address(usdg));
        vm.prank(address(treasury));
        wood.mint(address(collector), 100 ether);
        // No router / recipients / oracle → NotConfigured.
        vm.expectRevert(TaxCollector.NotConfigured.selector);
        collector.convert(0, 0);

        // Router + recipients still insufficient without oracle.
        MockTaxRouter router = new MockTaxRouter(address(wood), address(usdg));
        address pair = makeAddr("pair");
        vm.startPrank(owner);
        router.setPool(pair);
        collector.setRouter(address(router), pair);
        collector.setRecipients(address(treasury), address(0));
        vm.stopPrank();
        vm.expectRevert(TaxCollector.NotConfigured.selector);
        collector.convert(0, 0);
    }

    function test_taxCollector_minUsdgFromOracle() public {
        TaxCollector collector = new TaxCollector(address(auth), address(wood), address(usdg));
        vm.startPrank(owner);
        collector.setWoodOracle(address(woodSpot)); // $1
        collector.setMaxSlippageBps(500); // 5%
        vm.stopPrank();

        // fair = 1000e18 * 1e18 / 1e18 = 1000e18; floor = 95%
        assertEq(collector.minUsdgFromOracle(1_000 ether), 950 ether);

        vm.prank(owner);
        woodSpot.setPrice(2e18); // $2 WOOD
        assertEq(collector.minUsdgFromOracle(1_000 ether), 1_900 ether); // 2000 * 0.95
    }

    /// @notice Depressed pool rate below the oracle floor must revert even when caller passes
    ///         minUsdgOut = 0 (the sandwich vector: manipulate pool → convert(0,0) → restore).
    function test_taxCollector_convert_oracleFloor_blocksSandwich() public {
        address pair = makeAddr("pair");
        address platform = makeAddr("platform");
        TaxCollector collector = new TaxCollector(address(auth), address(wood), address(usdg));
        MockTaxRouter router = new MockTaxRouter(address(wood), address(usdg));

        vm.startPrank(owner);
        wood.setTaxedPair(pair, true);
        wood.setTax(500, 0, address(0), address(collector), false);
        wood.setTaxExempt(address(collector), true);
        _configureCollector(collector, router, pair, platform);
        collector.setSplit(5_000, 5_000);
        collector.setMaxSlippageBps(100); // allow 1% below oracle
        vm.stopPrank();

        vm.prank(address(treasury));
        wood.mint(address(collector), 1_000 ether);

        // Attacker depresses pool to 50% of fair value.
        router.setRate(0.5e18);
        // convert(0, 0) raises min to oracleFloor = 1000 * 0.99 = 990; mock out = 500 → reverts.
        vm.expectRevert(bytes("slippage"));
        collector.convert(0, 0);

        // Fair rate succeeds; convert(0,0) is protected but still permissionless.
        router.setRate(1e18);
        uint256 out = collector.convert(0, 0);
        assertEq(out, 1_000 ether);
        assertEq(wood.balanceOf(address(collector)), 0);
    }

    /// @notice Caller-supplied minUsdgOut may only tighten the oracle floor, never loosen it.
    function test_taxCollector_convert_callerMinTightensFloor() public {
        address pair = makeAddr("pair");
        address platform = makeAddr("platform");
        TaxCollector collector = new TaxCollector(address(auth), address(wood), address(usdg));
        MockTaxRouter router = new MockTaxRouter(address(wood), address(usdg));

        vm.startPrank(owner);
        wood.setTaxExempt(address(collector), true);
        _configureCollector(collector, router, pair, platform);
        collector.setSplit(10_000, 0);
        collector.setMaxSlippageBps(500); // oracle floor = 95% of fair
        vm.stopPrank();

        vm.prank(address(treasury));
        wood.mint(address(collector), 1_000 ether);

        // Oracle floor = 950. Mock at 97% would clear the floor but not a tighter caller min.
        router.setRate(0.97e18);
        assertEq(collector.minUsdgFromOracle(1_000 ether), 950 ether);

        // Loose caller min is raised to floor → succeeds at 970 >= 950.
        uint256 out = collector.convert(500 ether, 0);
        assertEq(out, 500 ether * 0.97e18 / 1e18);

        // Tight caller min above mock out reverts even though mock is above oracle floor.
        // remaining bal = 500; fair floor = 475; caller asks for 490; mock out = 485.
        router.setRate(0.97e18);
        vm.expectRevert(bytes("slippage"));
        collector.convert(500 ether, 490 ether);
    }

    function test_wood_taxExempt_skipsTaxWhenFromExempt() public {
        address pair = makeAddr("pair");
        address collector = makeAddr("collector");
        address exemptSeller = makeAddr("exemptSeller");
        vm.startPrank(owner);
        wood.setTaxedPair(pair, true);
        wood.setTax(500, 0, address(0), collector, false);
        wood.setTaxExempt(exemptSeller, true);
        vm.stopPrank();

        // Fund exempt seller.
        vm.prank(alice);
        wood.transfer(exemptSeller, 1_000 ether);

        vm.prank(exemptSeller);
        wood.transfer(pair, 1_000 ether);
        // Full amount delivered — no tax.
        assertEq(wood.balanceOf(pair), 1_000 ether);
        assertEq(wood.balanceOf(collector), 0);
    }

    function test_treasury_stalePrice_guard() public {
        vm.prank(owner);
        treasury.setMaxPriceAge(1 hours);
        assertGt(treasury.totalReserves(), 0); // fresh feeds

        vm.warp(block.timestamp + 2 hours); // feeds now stale
        vm.expectRevert(Treasury.StalePrice.selector);
        treasury.totalReserves();

        // Refresh both feeds → valuation works again.
        usdgOracle.setPrice(1e18);
        sgovOracle.setPrice(1e18);
        assertGt(treasury.totalReserves(), 0);

        // maxPriceAge = 0 disables the check entirely (Phase-1 default).
        vm.prank(owner);
        treasury.setMaxPriceAge(0);
        vm.warp(block.timestamp + 100 hours);
        assertGt(treasury.totalReserves(), 0);
    }
}
