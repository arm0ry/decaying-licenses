// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import "lib/forge-std/src/Test.sol";
import "lib/forge-std/src/console2.sol";

import {DecayingLicense, Terms, Bid, Record} from "../src/DecayingLicense.sol";

contract DecayingLicenseTest is Test {
    DecayingLicense dLicense;
    Terms terms;
    Record record;
    Record _record;

    /// @dev Users.
    address public immutable alice = payable(makeAddr("alice"));
    address public immutable bob = payable(makeAddr("bob"));
    address public immutable charlie = payable(makeAddr("charlie"));
    address public immutable david = payable(makeAddr("david"));
    address public immutable echo = payable(makeAddr("echo"));
    address public immutable fox = payable(makeAddr("fox"));

    /// @dev Constants.
    uint256 internal constant TEN_THOUSAND = 10000;
    uint256 internal constant RATE = 1000;
    uint256 internal constant PERIOD = 1 weeks;
    uint256 internal constant FINNEY = 0.001 ether;
    uint256 internal constant TWO_FINNEY = 0.002 ether;
    uint256 internal constant THREE_FINNEY = 0.003 ether;
    string internal constant TEST = "TEST";
    bytes internal constant BYTES = "BYTES";

    /// @dev Reserves.

    /// -----------------------------------------------------------------------
    ///  Setup Tests
    /// -----------------------------------------------------------------------

    /// @notice Set up the testing suite.
    function setUp() public payable {
        dLicense = new DecayingLicense();
    }

    function test_Draft_New() public payable {
        uint256 newId = draft_new(FINNEY, RATE, PERIOD, alice);

        terms = dLicense.getTerms(newId);

        assertEq(terms.price, FINNEY);
        assertEq(terms.rate, RATE);
        assertEq(terms.period, PERIOD);
    }

    function test_Draft_Update() public payable {
        uint256 rate = 40;
        uint256 period = 2 weeks;
        test_Draft_New();

        uint256 licenseId = dLicense.licenseId();
        draft_update(licenseId, TWO_FINNEY, rate, period, alice);

        vm.warp(10000);
        terms = dLicense.getTerms(licenseId);

        assertEq(terms.price, FINNEY);
        assertEq(terms.rate, rate);
        assertEq(terms.period, period);
        assertEq(terms.licensor, alice);
    }

    function test_Draft_Update_Unauthorized() public payable {
        uint256 rate = 40;
        uint256 period = 2 weeks;
        test_Draft_New();

        uint256 licenseId = dLicense.licenseId();

        vm.prank(bob);
        vm.expectRevert(DecayingLicense.Unauthorized.selector);
        dLicense.draft(licenseId, TWO_FINNEY, rate, period, TEST);
    }

    function test_NewLicense_TermsPrice() public payable {
        vm.deal(bob, 1 ether);

        // draft
        uint256 id = draft_new(FINNEY, 1000, 1 weeks, alice);
        _record = dLicense.getRecord(id);

        terms = dLicense.getTerms(id);
        license(
            id,
            bob,
            terms.price,
            terms.price + (terms.price * terms.rate) / TEN_THOUSAND
        );

        record = dLicense.getRecord(id);
        assertEq(record.price, terms.price);
        assertEq(record.timeLastLicensed, _record.timeLastLicensed + 1);
        assertEq(record.timeLastCollected, _record.timeLastCollected + 1);
        assertEq(record.deposit, (terms.price * terms.rate) / TEN_THOUSAND);
        assertEq(address(dLicense).balance, record.deposit);
        assertEq(record.bidderShares, 0);
        assertEq(record.licensee, bob);
    }

    function test_NewLicense_NewPrice() public payable {
        vm.deal(bob, 1 ether);

        // draft
        uint256 id = draft_new(FINNEY, 1000, 1 weeks, alice);
        _record = dLicense.getRecord(id);

        terms = dLicense.getTerms(id);
        terms.price = TWO_FINNEY;
        license(
            id,
            bob,
            terms.price,
            terms.price + (terms.price * terms.rate) / TEN_THOUSAND
        );

        record = dLicense.getRecord(id);
        assertEq(record.price, terms.price);
        assertEq(record.timeLastLicensed, _record.timeLastLicensed + 1);
        assertEq(record.timeLastCollected, _record.timeLastCollected + 1);
        assertEq(record.deposit, (terms.price * terms.rate) / TEN_THOUSAND);
        assertEq(address(dLicense).balance, record.deposit);
        assertEq(record.bidderShares, 0);
        assertEq(record.licensee, bob);

        // 1 week with 10% decay reverts 1 share per ~2hrs
        vm.warp(7000);
        uint256 shares = dLicense.getDecayedShares(id);
        emit log_uint(shares);
    }

    // TODO: test_Bid

    function draft_new(
        uint256 price,
        uint256 rate,
        uint256 period,
        address licensor
    ) public payable returns (uint256) {
        uint256 id = dLicense.licenseId();

        vm.prank(licensor);
        dLicense.draft(0, price, rate, period, TEST);

        uint256 _id = dLicense.licenseId();
        assertEq(_id, id + 1);
        return _id;
    }

    function draft_update(
        uint256 id,
        uint256 price,
        uint256 rate,
        uint256 period,
        address licensor
    ) public payable {
        vm.prank(licensor);
        dLicense.draft(id, price, rate, period, TEST);

        terms = dLicense.getTerms(id);
        assertEq(terms.price, FINNEY);
        assertEq(terms.rate, rate);
        assertEq(terms.period, period);
        assertEq(terms.content, TEST);
    }

    function bid(
        uint256 id,
        address bidder,
        uint256 price,
        uint256 value
    ) public payable {
        vm.prank(bidder);
        dLicense.bid{value: value}(id, price);
    }

    function deposit() public payable {}

    function license(
        uint256 id,
        address licensee,
        uint256 price,
        uint256 value
    ) public payable {
        vm.prank(licensee);
        dLicense.license{value: value}(id, price);
    }

    function testReceiveETH() public payable {
        (bool sent, ) = address(dLicense).call{value: 5 ether}("");
        assert(sent);
    }
}
