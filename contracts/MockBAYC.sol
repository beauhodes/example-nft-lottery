// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MockBAYC is ERC721 {

    constructor () ERC721("Bored Ape", "BAYC") {
        _mint(msg.sender, 0); //mint 0 tokenId
    }

    function simulateAirdrop(uint256 _tokenId) public {
        _mint(msg.sender, _tokenId);
    }
}