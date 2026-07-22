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

    function test_wood_tax_appliesOnBuyAndSell_matchesNetRatio() public {
        address pair = makeAddr("pair");
        address platform = makeAddr("platform");
        vm.startPrank(owner);
        wood.setTaxedPair(pair, true);
        // 5% total tax, split 66.6% platform / 33.4% treasury — reproduces NET's observed
        // 3.33%/1.67% (of the transfer) ratio when taxBps = 500.
        wood.setTax(500, 6_660, platform, address(treasury), false);
        vm.stopPrank();

        // Sell: alice → pair.
        uint256 sellAmount = 10_000 ether;
        uint256 sellTax = sellAmount * 500 / 10_000;
        uint256 sellPlatform = sellTax * 6_660 / 10_000;
        uint256 sellTreasury = sellTax - sellPlatform;

        uint256 treasuryBefore = wood.balanceOf(address(treasury));
        vm.prank(alice);
        wood.transfer(pair, sellAmount);

        assertEq(wood.balanceOf(pair), sellAmount - sellTax);
        assertEq(wood.balanceOf(platform), sellPlatform);
        assertEq(wood.balanceOf(address(treasury)) - treasuryBefore, sellTreasury);

        // Buy: pair → bob (pair now holds sellAmount - sellTax from the leg above).
        uint256 buyAmount = 3_000 ether;
        uint256 buyTax = buyAmount * 500 / 10_000;
        uint256 buyPlatform = buyTax * 6_660 / 10_000;
        uint256 buyTreasury = buyTax - buyPlatform;

        uint256 platformBefore = wood.balanceOf(platform);
        uint256 treasuryBefore2 = wood.balanceOf(address(treasury));
        vm.prank(pair);
        wood.transfer(bob, buyAmount);

        assertEq(wood.balanceOf(bob), buyAmount - buyTax);
        assertEq(wood.balanceOf(platform) - platformBefore, buyPlatform);
        assertEq(wood.balanceOf(address(treasury)) - treasuryBefore2, buyTreasury);
    }

    function test_wood_tax_skipsMintAndBurn() public {
        address pair = makeAddr("pair");
        address platform = makeAddr("platform");
        vm.startPrank(owner);
        wood.setTaxedPair(pair, true);
        wood.setTax(500, 6_660, platform, address(treasury), false);
        vm.stopPrank();

        // Mint straight to the registered pair address itself — from == address(0), must skip tax.
        vm.prank(address(treasury));
        wood.mint(pair, 5_000 ether);
        assertEq(wood.balanceOf(pair), 5_000 ether); // no skim taken off a mint

        // Burn from the pair — to == address(0), must also skip tax.
        vm.prank(address(treasury));
        wood.burn(pair, 2_000 ether);
        assertEq(wood.balanceOf(pair), 3_000 ether);
        assertEq(wood.balanceOf(platform), 0);
    }

    function test_wood_tax_skipsPlainWalletTransfer() public {
        // Tax enabled, but neither alice nor bob is a registered pair — plain P2P transfer untaxed.
        address pair = makeAddr("pair");
        address platform = makeAddr("platform");
        vm.startPrank(owner);
        wood.setTaxedPair(pair, true);
        wood.setTax(500, 6_660, platform, address(treasury), false);
        vm.stopPrank();

        vm.prank(alice);
        wood.transfer(bob, 1_000 ether);
        assertEq(wood.balanceOf(bob), 1_000 ether);
        assertEq(wood.balanceOf(platform), 0);
    }

    function test_wood_setTax_governorOnly_reverts() public {
        vm.prank(bob);
        vm.expectRevert();
        wood.setTax(500, 5_000, bob, address(treasury), false);
    }

    function test_wood_setTax_badConfig_reverts() public {
        uint256 tooHigh = wood.MAX_TAX_BPS() + 1; // read before expectRevert — it's a separate call
        vm.startPrank(owner);
        vm.expectRevert(WOOD.BadConfig.selector);
        wood.setTax(tooHigh, 5_000, bob, address(treasury), false); // > MAX_TAX_BPS

        vm.expectRevert(WOOD.BadConfig.selector);
        wood.setTax(500, 10_001, bob, address(treasury), false); // platformFeeBps > BPS

        vm.expectRevert(WOOD.BadConfig.selector);
        wood.setTax(500, 5_000, address(0), address(treasury), false); // taxBps > 0, zero platform wallet

        vm.expectRevert(WOOD.BadConfig.selector);
        wood.setTax(500, 5_000, bob, address(0), false); // taxBps > 0, zero treasury wallet
        vm.stopPrank();
    }

    function test_wood_setTax_locksPermanently() public {
        address platform = makeAddr("platform");
        vm.startPrank(owner);
        // Lock in the same call that sets the real config — matches NET's one-shot-at-genesis shape.
        wood.setTax(500, 6_660, platform, address(treasury), true);
        assertTrue(wood.taxLocked());
        assertEq(wood.taxBps(), 500);

        vm.expectRevert(WOOD.TaxLocked.selector);
        wood.setTax(0, 0, address(0), address(0), false); // even disabling it is blocked once locked
        vm.stopPrank();

        // setTaxedPair is deliberately NOT covered by the lock — new markets can still be listed,
        // matching NET's own accepted "guardian can add new AMM pairs" behavior.
        vm.prank(owner);
        wood.setTaxedPair(makeAddr("newPair"), true);
    }

    function test_wood_setTaxedPair_governorOnly_reverts() public {
        vm.prank(bob);
        vm.expectRevert();
        wood.setTaxedPair(makeAddr("pair"), true);
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
