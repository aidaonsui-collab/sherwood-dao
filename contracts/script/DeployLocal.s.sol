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
import {MockOracle} from "../src/oracles/MockOracle.sol";
import {ManualOracle} from "../src/oracles/ManualOracle.sol";

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Local / anvil deploy of SherwoodDAO Phase-1 stack with mock USDG + seeded treasury.
/// Usage: forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
contract DeployLocal is Script {
    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        Authority auth = new Authority(deployer);
        WOOD wood = new WOOD(address(auth));
        Treasury treasury = new Treasury(address(auth), address(wood));
        Camp camp = new Camp(address(auth), address(wood), address(treasury));
        Heist heist = new Heist(address(auth), address(wood), address(treasury));

        MockERC20 usdg = new MockERC20("USDG", "USDG");
        MockOracle usdgOracle = new MockOracle(1e18);
        ManualOracle woodSpot = new ManualOracle(address(auth), 1e18);

        Vault vault = new Vault(address(auth), address(camp), address(treasury), address(usdg));
        RangeBound rangeBound = new RangeBound(address(auth), address(wood), address(treasury), address(usdg));

        auth.grantRole(auth.WOOD_MINTER(), address(treasury));
        auth.grantRole(auth.REWARD_MANAGER(), address(camp));
        auth.grantRole(auth.BOND_MANAGER(), address(heist));
        auth.grantRole(auth.RESERVE_DEPOSITOR(), deployer);
        auth.grantRole(auth.RESERVE_SPENDER(), address(vault));
        auth.grantRole(auth.RESERVE_SPENDER(), address(rangeBound));
        auth.grantRole(auth.GUARDIAN(), deployer);
        auth.grantRole(auth.REWARD_MANAGER(), deployer);

        // ── Invariant: only the Treasury may mint WOOD. Camp/Heist mint solely through
        //    treasury.mintWoodFromExcess (excess-capped); if either held WOOD_MINTER directly they
        //    could mint unbacked WOOD and bypass the RFV cap. Fail the deploy if wiring is wrong. ──
        require(auth.hasRole(auth.WOOD_MINTER(), address(treasury)), "wiring: treasury !WOOD_MINTER");
        require(!auth.hasRole(auth.WOOD_MINTER(), address(camp)), "wiring: camp has WOOD_MINTER");
        require(!auth.hasRole(auth.WOOD_MINTER(), address(heist)), "wiring: heist has WOOD_MINTER");
        require(auth.hasRole(auth.REWARD_MANAGER(), address(camp)), "wiring: camp !REWARD_MANAGER");
        require(auth.hasRole(auth.BOND_MANAGER(), address(heist)), "wiring: heist !BOND_MANAGER");

        treasury.registerAsset(address(usdg), address(usdgOracle), 1e18, 18);
        usdg.mint(deployer, 1_000_000 ether);
        usdg.approve(address(treasury), type(uint256).max);
        treasury.deposit(address(usdg), 1_000_000 ether);

        // Bootstrap circulating WOOD
        treasury.mintWoodFromExcess(deployer, 50_000 ether);

        // Bond price ≥ RFV floor * (1 + protocolMintBps). Fresh deploy: backing = 1e6/50k = $20.
        uint256 floor = treasury.backingPerWood();
        uint256 minBondPrice = floor * (10_000 + heist.protocolMintBps()) / 10_000;
        heist.setMarket(address(usdg), address(usdgOracle), 18, 20_000 ether, minBondPrice, 5 days);
        rangeBound.setSpotOracle(address(woodSpot));

        vm.stopBroadcast();

        console2.log("Authority ", address(auth));
        console2.log("WOOD      ", address(wood));
        console2.log("sWOOD     ", address(camp.sWood()));
        console2.log("Treasury  ", address(treasury));
        console2.log("Camp      ", address(camp));
        console2.log("Heist     ", address(heist));
        console2.log("Vault     ", address(vault));
        console2.log("RangeBound ", address(rangeBound));
        console2.log("USDG      ", address(usdg));
        console2.log("reserves  ", treasury.totalReserves());
        console2.log("excess    ", treasury.excessReserves());
    }
}
