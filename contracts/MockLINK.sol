// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockLINK is ERC20 {

    constructor () ERC20("LINK Token", "LINK") {
        _mint(msg.sender, 10000000000000000000); //10 LINK
    }

    function simulateAirdrop(uint256 _amount) public {
        _mint(msg.sender, _amount);
    }
}