// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import "@forge/Test.sol";
import "@forge/console2.sol";
import "@solady/test/utils/mocks/MockERC6909.sol";

import {DecayingLicense, License} from "../src/DecayingLicense.sol";

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
    string internal constant TEST = "TEST";
    bytes internal constant BYTES = "BYTES";

    /// @dev Reserves.

    /// -----------------------------------------------------------------------
    ///  Setup Tests
    /// -----------------------------------------------------------------------

    /// @notice Set up the testing suite.
    function setUp() public payable {
        license = new DecayingLicense();
    }

    function test_Draft(uint256 id) public payable {
        draft(id);
    }

    // TODO: test_License
    // TODO: test_Update_License
    // TODO: test_Bid

    function draft(uint256 id) public payable {
        vm.assume(id == 0);
        uint256 _id = license.licenseId();

        vm.prank(alice);
        license.draft(id, 0.001 ether, 10, 1 weeks, TEST);

        uint256 __id = license.licenseId();
        assertEq(__id, _id + 1);

        vm.warp(10000000);
        uint256 reverted = license.sharesReverted(__id);
        uint256 owed = license.patronageOwed(__id);
        emit log_uint(owed);
        emit log_uint(reverted);
        emit log_uint(uint40(block.timestamp));
    }

    function testReceiveETH() public payable {
        (bool sent, ) = address(license).call{value: 5 ether}("");
        assert(sent);
    }
}
