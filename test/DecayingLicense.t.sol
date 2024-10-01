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
    Bid _bid;

    /// @dev Users.
    address public immutable alice = payable(makeAddr("alice"));
    address public immutable bob = payable(makeAddr("bob"));
    address public immutable charlie = payable(makeAddr("charlie"));
    address public immutable david = payable(makeAddr("david"));
    address public immutable echo = payable(makeAddr("echo"));
    address public immutable fox = payable(makeAddr("fox"));

    /// @dev Constants.
    uint256 internal constant TEN_THOUSAND = 10000;
    uint256 internal constant RATE = 2;
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
        license(id, bob, terms.price);

        record = dLicense.getRecord(id);
        assertEq(record.price, terms.price);
        assertEq(record.timeLastLicensed, _record.timeLastLicensed + 1);
        assertEq(record.timeLastCollected, _record.timeLastCollected + 1);
        assertEq(record.deposit, terms.price);
        assertEq(address(dLicense).balance, record.deposit);
        assertEq(record.bidderShares, 0);
        assertEq(record.licensee, bob);
    }

    function test_NewLicense_NewPrice(uint256 rate) public payable {
        vm.assume(rate > 0);
        vm.assume(100 > rate);
        vm.deal(bob, 1 ether);

        // draft
        uint256 id = draft_new(FINNEY, rate, PERIOD, alice);
        _record = dLicense.getRecord(id);

        // update and license at new price
        terms = dLicense.getTerms(id);
        terms.price = TWO_FINNEY;
        license(id, bob, terms.price);

        record = dLicense.getRecord(id);
        assertEq(record.price, terms.price);
        assertEq(record.timeLastLicensed, _record.timeLastLicensed + 1);
        assertEq(record.timeLastCollected, _record.timeLastCollected + 1);
        assertEq(record.deposit, terms.price);
        assertEq(address(dLicense).balance, record.deposit);
        assertEq(record.bidderShares, 0);
        assertEq(record.licensee, bob);

        vm.warp(terms.period + 1);
        uint256 shares = dLicense.getDecayedShares(id);
        assertEq(shares, TEN_THOUSAND * rate);
        uint256 collection = dLicense.patronageOwed(id);
        assertEq(collection, terms.price);
    }

    function test_Bid() public payable {
        vm.deal(bob, 1 ether);
        uint256 id = draft_new(FINNEY, RATE, PERIOD, alice);
        license(id, bob, TWO_FINNEY);

        vm.warp(10000);
        vm.deal(charlie, 1 ether);
        uint256 bidId = dLicense.getNumOfBids(id);
        uint256 shares = dLicense.getDecayedShares(id);
        uint256 price = TWO_FINNEY + FINNEY;
        uint256 amount = (price * shares) / 10000;

        bid(id, charlie, price, amount);
        uint256 _bidId = dLicense.getNumOfBids(id);
        _bid = dLicense.getBid(id, _bidId - 1);

        assertEq(_bid.bidder, charlie);
        assertEq(_bid.price, price);
        assertEq(_bid.shares, shares);
        assertEq(_bid.deposit, amount);
        assertEq(++bidId, _bidId);

        record = dLicense.getRecord(id);
        assertEq(record.bidderShares, _bid.shares);
    }

    function test_Bid_UpdateWithHigherBid() public payable {
        vm.deal(bob, 1 ether);
        uint256 id = draft_new(FINNEY, RATE, PERIOD, alice);
        license(id, bob, TWO_FINNEY);

        // first bid
        vm.warp(10000);
        vm.deal(charlie, 1 ether);
        uint256 decayed = dLicense.getDecayedShares(id);
        uint256 price = TWO_FINNEY + FINNEY;
        uint256 amount = (price * decayed) / 10000;
        bid(id, charlie, price, amount);

        // second bid
        vm.warp(30000);
        uint256 numOfBids = dLicense.getNumOfBids(id);
        record = dLicense.getRecord(id);
        decayed = dLicense.getDecayedShares(id);
        uint256 pastBidId = dLicense.getPastBid(id, charlie);
        _bid = dLicense.getBid(id, pastBidId);
        uint256 prevBidShares = _bid.shares;
        price = TWO_FINNEY + TWO_FINNEY;
        amount = (price * (decayed - record.bidderShares)) / 10000;

        bid(id, charlie, price, amount - _bid.deposit);
        uint256 _numOfBids = dLicense.getNumOfBids(id);

        // validate
        _bid = dLicense.getBid(id, pastBidId);
        decayed = dLicense.getDecayedShares(id);
        assertEq(_bid.bidder, charlie);
        assertEq(_bid.price, price);
        assertEq(_bid.shares, decayed);
        assertEq(_bid.deposit, amount);
        assertEq(numOfBids, _numOfBids, "numbers should be the same");

        record = dLicense.getRecord(id);
        assertEq(record.bidderShares, _bid.shares, "Record biddershares");
    }

    function test_Bid_UpdateWithLowerBid() public payable {}

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
        uint256 price
    ) public payable {
        vm.prank(licensee);
        dLicense.license{value: price}(id, price);
    }

    function testReceiveETH() public payable {
        (bool sent, ) = address(dLicense).call{value: 5 ether}("");
        assert(sent);
    }
}
