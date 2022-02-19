// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@chainlink/contracts/src/v0.8/mocks/VRFCoordinatorMock.sol";

contract MockVRFC is VRFCoordinatorMock {

    constructor (address _linkAddress) VRFCoordinatorMock(_linkAddress) {}

}