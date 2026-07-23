// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Authority} from "../src/Authority.sol";
import {WOOD} from "../src/WOOD.sol";
import {Treasury} from "../src/Treasury.sol";
import {Camp} from "../src/Camp.sol";
import {Heist} from "../src/Heist.sol";
import {Vault} from "../src/Vault.sol";
import {RangeBound} from "../src/RangeBound.sol";
import {Redeem} from "../src/Redeem.sol";
import {MockOracle} from "../src/oracles/MockOracle.sol";

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Robinhood Chain testnet (46630) deploy of the Phase-1 stack, with mock reserve assets
///         (self-minted, no dependency on any shared/canonical testnet token) so this deploy is
///         fully isolated. Vesting term is short (2 min) specifically so the bond lifecycle
///         (deposit -> real elapsed time -> claim) can be exercised live, not just under vm.warp.
/// Usage: PRIVATE_KEY=0x... forge script script/DeployTestnet.s.sol --tc DeployTestnet \
///          --rpc-url https://rpc.testnet.chain.robinhood.com --broadcast
contract DeployTestnet is Script {
    struct Deployed {
        address auth;
        address wood;
        address sWood;
        address treasury;
        address camp;
        address heist;
        address vault;
        address rangeBound;
        address redeem;
        address usdg;
        address sgov;
        address usdgOracle;
        address sgovOracle;
        address woodSpot;
        uint256 reserves;
        uint256 excess;
        uint256 backing;
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        console2.log("Deployer  ", deployer);
        console2.log("Balance   ", deployer.balance);

        vm.startBroadcast(pk);
        Deployed memory d = _deployAll(deployer);
        vm.stopBroadcast();

        console2.log("");
        console2.log("=== SherwoodDAO Phase-1 :: Robinhood Chain testnet (46630) ===");
        console2.log("Authority   ", d.auth);
        console2.log("WOOD        ", d.wood);
        console2.log("sWOOD       ", d.sWood);
        console2.log("Treasury    ", d.treasury);
        console2.log("Camp        ", d.camp);
        console2.log("Heist       ", d.heist);
        console2.log("Vault       ", d.vault);
        console2.log("RangeBound  ", d.rangeBound);
        console2.log("Redeem     ", d.redeem);
        console2.log("tUSDG       ", d.usdg);
        console2.log("tSGOV       ", d.sgov);
        console2.log("tUSDG oracle", d.usdgOracle);
        console2.log("tSGOV oracle", d.sgovOracle);
        console2.log("WOOD spot   ", d.woodSpot);
        console2.log("reserves    ", d.reserves);
        console2.log("excess      ", d.excess);
        console2.log("backing/WOOD", d.backing);
    }

    function _deployAll(address deployer) internal returns (Deployed memory d) {
        d.auth = address(new Authority(deployer));
        d.wood = address(new WOOD(d.auth));
        d.treasury = address(new Treasury(d.auth, d.wood));
        d.camp = address(new Camp(d.auth, d.wood, d.treasury));
        d.heist = address(new Heist(d.auth, d.wood, d.treasury));
        d.sWood = address(Camp(d.camp).sWood());

        d.usdg = address(new MockERC20("Sherwood Test USDG", "tUSDG"));
        d.sgov = address(new MockERC20("Sherwood Test SGOV", "tSGOV"));
        d.usdgOracle = address(new MockOracle(1e18));
        d.sgovOracle = address(new MockOracle(1e18));
        d.woodSpot = address(new MockOracle(1e18));

        d.vault = address(new Vault(d.auth, d.camp, d.treasury, d.usdg));
        d.rangeBound = address(new RangeBound(d.auth, d.wood, d.treasury, d.usdg));
        d.redeem = address(new Redeem(d.auth, d.wood, d.treasury, d.usdg));

        _grantAndWire(d, deployer);
        _seed(d, deployer);

        d.reserves = Treasury(d.treasury).totalReserves();
        d.excess = Treasury(d.treasury).excessReserves();
        d.backing = Treasury(d.treasury).backingPerWood();
    }

    function _grantAndWire(Deployed memory d, address deployer) internal {
        Authority auth = Authority(d.auth);
        auth.grantRole(auth.WOOD_MINTER(), d.treasury);
        auth.grantRole(auth.REWARD_MANAGER(), d.camp);
        auth.grantRole(auth.BOND_MANAGER(), d.heist);
        auth.grantRole(auth.RESERVE_DEPOSITOR(), deployer);
        auth.grantRole(auth.RESERVE_SPENDER(), d.vault);
        auth.grantRole(auth.RESERVE_SPENDER(), d.rangeBound);
        auth.grantRole(auth.RESERVE_SPENDER(), d.redeem);
        // Redeem burns only WOOD it already pulled in; needs WOOD_MINTER for that burn path.
        auth.grantRole(auth.WOOD_MINTER(), d.redeem);
        auth.grantRole(auth.GUARDIAN(), deployer);
        auth.grantRole(auth.REWARD_MANAGER(), deployer);

        require(auth.hasRole(auth.WOOD_MINTER(), d.treasury), "wiring: treasury !WOOD_MINTER");
        require(!auth.hasRole(auth.WOOD_MINTER(), d.camp), "wiring: camp has WOOD_MINTER");
        require(!auth.hasRole(auth.WOOD_MINTER(), d.heist), "wiring: heist has WOOD_MINTER");
        require(auth.hasRole(auth.WOOD_MINTER(), d.redeem), "wiring: redeem !WOOD_MINTER");
        require(auth.hasRole(auth.RESERVE_SPENDER(), d.redeem), "wiring: redeem !RESERVE_SPENDER");
        require(auth.hasRole(auth.REWARD_MANAGER(), d.camp), "wiring: camp !REWARD_MANAGER");
        require(auth.hasRole(auth.BOND_MANAGER(), d.heist), "wiring: heist !BOND_MANAGER");
    }

    function _seed(Deployed memory d, address deployer) internal {
        Treasury treasury = Treasury(d.treasury);
        MockERC20 usdg = MockERC20(d.usdg);
        MockERC20 sgov = MockERC20(d.sgov);

        treasury.registerAsset(d.usdg, d.usdgOracle, 1e18, 18);
        treasury.registerAsset(d.sgov, d.sgovOracle, 1e18, 18);

        usdg.mint(deployer, 150_000 ether);
        sgov.mint(deployer, 50_000 ether);
        usdg.approve(d.treasury, type(uint256).max);
        sgov.approve(d.treasury, type(uint256).max);
        treasury.deposit(d.usdg, 150_000 ether);
        treasury.deposit(d.sgov, 50_000 ether);

        treasury.mintWoodFromExcess(deployer, 10_000 ether);

        Heist heist = Heist(d.heist);
        uint256 floor = treasury.backingPerWood();
        uint256 minBondPrice = floor * (10_000 + heist.protocolMintBps()) / 10_000;
        heist.setMarket(d.usdg, d.usdgOracle, 18, 5_000 ether, minBondPrice * 2, 2 minutes);
        RangeBound(d.rangeBound).setSpotOracle(d.woodSpot);
    }
}
