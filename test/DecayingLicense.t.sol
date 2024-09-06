// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import "@forge/Test.sol";
import "@forge/console2.sol";
import "@solady/test/utils/mocks/MockERC6909.sol";

import {DecayingLicense} from "../src/DecayingLicense.sol";

contract DecayingLicenseTest is Test {
    DecayingLicense license;

    /// @dev Users.
    address public immutable alice = payable(makeAddr("alice"));
    address public immutable bob = payable(makeAddr("bob"));
    address public immutable charlie = payable(makeAddr("charlie"));
    address public immutable david = payable(makeAddr("david"));
    address public immutable echo = payable(makeAddr("echo"));
    address public immutable fox = payable(makeAddr("fox"));

    /// @dev Constants.
    string internal constant NAME = "NAME";
    string internal constant SYMBOL = "SYMBOL";
    string internal constant WORK = "WORK";
    uint256 internal constant MAXSUPPLY = 100;
    uint64 internal constant SCALE = 0.0001 ether;
    bytes internal constant BYTES = "BYTES";

    /// @dev Reserves.

    /// -----------------------------------------------------------------------
    ///  Setup Tests
    /// -----------------------------------------------------------------------

    /// @notice Set up the testing suite.
    function setUp() public payable {
        license = new DecayingLicense();
    }

    function testReceiveETH() public payable {
        (bool sent, ) = address(license).call{value: 5 ether}("");
        assert(sent);
    }
}
