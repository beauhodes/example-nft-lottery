// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {

    constructor () ERC20("USDC Token", "USDC") {
        _mint(msg.sender, 10000000000000000000); //10 USDC
    }

    function simulateAirdrop(uint256 _amount) public {
        _mint(msg.sender, _amount);
    }
}