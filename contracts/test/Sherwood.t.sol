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

    // ── Heist ─────────────────────────────────────────────────────────────────

    function test_heist_bond_vestsWood() public {
        // Market: 1.05e18 control → 5% discount (more WOOD per USD)
        vm.prank(owner);
        heist.setMarket(address(usdg), address(usdgOracle), 18, 10_000 ether, 1.05e18, 1 days);

        usdg.mint(bob, 1_000 ether);
        vm.startPrank(bob);
        usdg.approve(address(heist), type(uint256).max);
        uint256 payout = heist.deposit(1_000 ether);
        // $1000 * 1.05 = 1050 WOOD
        assertEq(payout, 1_050 ether);

        // Halfway through vest
        vm.warp(block.timestamp + 12 hours);
        uint256 pending = heist.pendingPayout(bob);
        assertApproxEqAbs(pending, 525 ether, 1e15);

        uint256 claimed = heist.claim();
        assertApproxEqAbs(claimed, 525 ether, 1e15);
        assertApproxEqAbs(wood.balanceOf(bob), claimed, 1e15);

        // Finish vest
        vm.warp(block.timestamp + 12 hours);
        uint256 claimed2 = heist.claim();
        assertGt(claimed2, 0);
        assertApproxEqAbs(wood.balanceOf(bob), 1_050 ether, 1e15);
        vm.stopPrank();
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
        (uint256 col, uint256 debt,) = vault.positions(alice);
        assertEq(col, 10_000 ether);
        assertEq(debt, 50_000 ether);
        vm.stopPrank();
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
}
