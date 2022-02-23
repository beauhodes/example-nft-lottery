// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "ds-test/test.sol";
import 'src/Lottery.sol';

contract LotteryTest is DSTest {
    Lottery lotInst;

    address currencyAddr;
    address coordinatorAddr;
    address linkAddr;
    bytes32 keyHash;

    function setUp() public {
        lotInst = new Lottery(currencyAddr, coordinatorAddr, linkAddr, keyHash);
    }

    function test1(string memory _greeting) public {
        //todo
    }
}
