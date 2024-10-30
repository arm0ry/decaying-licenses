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
    uint256 internal constant ONE_WEEK = 1 weeks;
    uint256 internal constant FINNEY = 0.001 ether;
    uint256 internal constant TWO_FINNEY = 0.002 ether;
    uint256 internal constant THREE_FINNEY = 0.003 ether;
    string internal constant TEST = "TEST";
    bytes internal constant BYTES = "BYTES";

    /* -------------------------------------------------------------------------- */
    /*                                   Setup.                                   */
    /* -------------------------------------------------------------------------- */

    /// @notice Set up the testing suite.
    function setUp() public payable {
        dLicense = new DecayingLicense();
    }

    function testReceiveETH() public payable {
        (bool sent, ) = address(dLicense).call{value: 5 ether}("");
        assert(sent);
    }

    /* -------------------------------------------------------------------------- */
    /*                                   Tests.                                   */
    /* -------------------------------------------------------------------------- */

    function test_Draft_New() public payable {
        // Alice drafts license.
        uint256 newId = draft_new(FINNEY, RATE, ONE_WEEK, alice);
        terms = dLicense.getTerms(newId);

        // Validate.
        assertEq(terms.price, FINNEY);
        assertEq(terms.rate, RATE);
        assertEq(terms.period, ONE_WEEK);
    }

    function test_Draft_Revert_InvalidTerms(
        uint256 rate,
        uint256 period
    ) public payable {
        vm.assume(rate > period);

        uint256 licenseId = dLicense.licenseId();
        vm.prank(alice);
        vm.expectRevert(DecayingLicense.InvalidTerms.selector);
        dLicense.draft(licenseId, TWO_FINNEY, rate, period, TEST);
    }

    function test_Draft_Revert_EmptyContent() public payable {
        uint256 licenseId = dLicense.licenseId();
        vm.prank(alice);
        vm.expectRevert(DecayingLicense.InvalidLicense.selector);
        dLicense.draft(licenseId, TWO_FINNEY, RATE, ONE_WEEK, "");
    }

    function test_Draft_Revert_ZeroPrice(
        uint256 rate,
        uint256 period
    ) public payable {
        uint256 licenseId = dLicense.licenseId();
        vm.prank(alice);
        vm.expectRevert(DecayingLicense.InvalidLicense.selector);
        dLicense.draft(licenseId, 0, RATE, ONE_WEEK, TEST);
    }

    function test_Draft_Update() public payable {
        // Alice drafts license.
        uint256 rate = 40;
        uint256 period = 2 weeks;
        test_Draft_New();

        // Alice updates license.
        uint256 licenseId = dLicense.licenseId();
        draft_update(licenseId, TWO_FINNEY, rate, period, alice);

        // Validate.
        terms = dLicense.getTerms(licenseId);
        assertEq(terms.price, TWO_FINNEY, "price");
        assertEq(terms.rate, rate);
        assertEq(terms.period, period);
        assertEq(terms.licensor, alice);
    }

    function test_Draft_Update_Revert_Unauthorized() public payable {
        uint256 rate = 40;
        uint256 period = 2 weeks;
        test_Draft_New();

        uint256 licenseId = dLicense.licenseId();
        vm.prank(bob);
        vm.expectRevert(DecayingLicense.Unauthorized.selector);
        dLicense.draft(licenseId, TWO_FINNEY, rate, period, TEST);
    }

    function test_License_TermsPrice() public payable {
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

    function test_License_HigherPrice(uint256 rate) public payable {
        vm.assume(rate > 0);
        vm.assume(100 > rate);
        vm.deal(bob, 1 ether);

        // draft
        uint256 id = draft_new(FINNEY, rate, ONE_WEEK, alice);
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

    // TODO
    function test_License_LowerThanTermsPrice_Revert_InvalidPrice(
        uint256 rate
    ) public payable {}

    function test_Bid() public payable {
        // alice drafts license
        uint256 id = draft_new(FINNEY, RATE, ONE_WEEK, alice);

        // bob licenses
        vm.deal(bob, 1 ether);
        license(id, bob, TWO_FINNEY);

        // charlie places first bid
        vm.warp(10000);
        vm.deal(charlie, 1 ether);
        uint256 bidId = dLicense.getNumOfBids(id);
        uint256 shares = dLicense.getDecayedShares(id);
        uint256 price = TWO_FINNEY + FINNEY;
        uint256 amount = (price * shares) / 10000;
        bid(id, charlie, price, amount);

        // validate
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
        // alice drafts license
        uint256 id = draft_new(FINNEY, RATE, ONE_WEEK, alice);

        // bob licenses
        vm.deal(bob, 1 ether);
        license(id, bob, TWO_FINNEY);
        uint256 prevBalance = address(dLicense).balance;

        // charlie places first bid
        vm.warp(10000);
        vm.deal(charlie, 1 ether);
        uint256 decayed = dLicense.getDecayedShares(id);
        uint256 price = TWO_FINNEY + FINNEY;
        uint256 amount = (price * decayed) / 10000;
        bid(id, charlie, price, amount);

        // charlie places second higher bid
        vm.warp(30000);
        uint256 numOfBids = dLicense.getNumOfBids(id);
        record = dLicense.getRecord(id);
        decayed = dLicense.getDecayedShares(id);
        uint256 pastBidId = dLicense.getPastBidByBidder(id, charlie);
        _bid = dLicense.getBid(id, pastBidId);
        price = TWO_FINNEY + TWO_FINNEY;
        amount = (price * (decayed - record.bidderShares)) / 10000;
        bid(id, charlie, price, amount - _bid.deposit);

        // validate
        uint256 balance = address(dLicense).balance;
        uint256 _numOfBids = dLicense.getNumOfBids(id);
        _bid = dLicense.getBid(id, pastBidId);
        decayed = dLicense.getDecayedShares(id);
        assertEq(_bid.bidder, charlie);
        assertEq(_bid.price, price);
        assertEq(_bid.shares, decayed);
        assertEq(_bid.deposit, amount);
        assertEq(numOfBids, _numOfBids);
        assertEq(balance - prevBalance, _bid.deposit);

        record = dLicense.getRecord(id);
        assertEq(record.bidderShares, _bid.shares);
    }

    function test_Bid_UpdateWithLowerBid() public payable {
        // alice drafts license
        uint256 id = draft_new(FINNEY, RATE, ONE_WEEK, alice);

        // bob licenses
        vm.deal(bob, 1 ether);
        license(id, bob, TWO_FINNEY);
        uint256 prevBalance = address(dLicense).balance;

        // charlie places first bid
        vm.warp(10000);
        vm.deal(charlie, 1 ether);
        uint256 decayed = dLicense.getDecayedShares(id);
        uint256 price = TWO_FINNEY + FINNEY;
        uint256 amount = (price * decayed) / 10000;
        bid(id, charlie, price, amount);

        // charlie places second higher bid
        vm.warp(30000);
        uint256 numOfBids = dLicense.getNumOfBids(id);
        record = dLicense.getRecord(id);
        decayed = dLicense.getDecayedShares(id);
        uint256 pastBidId = dLicense.getPastBidByBidder(id, charlie);
        _bid = dLicense.getBid(id, pastBidId);

        /// @notice identical test as `test_Bid_UpdateWithHigherBid()`
        /// except for `price` below
        price = TWO_FINNEY;
        amount = (price * (decayed - record.bidderShares)) / 10000;
        bid(id, charlie, price, amount - _bid.deposit);

        // validate
        uint256 balance = address(dLicense).balance;
        uint256 _numOfBids = dLicense.getNumOfBids(id);
        _bid = dLicense.getBid(id, pastBidId);
        decayed = dLicense.getDecayedShares(id);
        assertEq(_bid.bidder, charlie);
        assertEq(_bid.price, price);
        assertEq(_bid.shares, decayed);
        assertEq(_bid.deposit, amount);
        assertEq(numOfBids, _numOfBids);
        assertEq(balance - prevBalance, _bid.deposit);

        record = dLicense.getRecord(id);
        assertEq(record.bidderShares, _bid.shares);
    }

    function test_Bids_MultipleParties() public payable {
        // alice drafts license
        uint256 rate = 2;
        uint256 id = draft_new(FINNEY, rate, ONE_WEEK, alice);

        // bob licenses
        vm.deal(bob, 1 ether);
        license(id, bob, TWO_FINNEY);

        // charlie places first bid
        vm.warp(10000);
        vm.deal(charlie, 1 ether);
        uint256 decayed = dLicense.getDecayedShares(id);
        uint256 price = TWO_FINNEY + FINNEY;
        uint256 amount = (price * decayed) / 10000;
        bid(id, charlie, price, amount);

        // david places second bid
        vm.warp(200000);
        vm.deal(david, 1 ether);
        decayed = dLicense.getDecayedShares(id);
        price = TWO_FINNEY + TWO_FINNEY;
        record = dLicense.getRecord(id);
        amount = (price * (decayed - record.bidderShares)) / 10000;
        bid(id, david, price, amount);

        // echo places third bid
        vm.warp(300000);
        vm.deal(echo, 1 ether);
        decayed = dLicense.getDecayedShares(id);
        price = TWO_FINNEY + TWO_FINNEY + FINNEY;
        record = dLicense.getRecord(id);
        amount = (price * (decayed - record.bidderShares)) / 10000;
        bid(id, echo, price, amount);

        // validate
        uint256 numOfBids = dLicense.getNumOfBids(id);
        assertEq(numOfBids, 3);

        uint256 _decayed;
        uint256 _balance;
        _bid = dLicense.getBid(id, 0);
        _decayed += _bid.shares;
        _balance += _bid.deposit;
        _bid = dLicense.getBid(id, 1);
        _decayed += _bid.shares;
        _balance += _bid.deposit;
        _bid = dLicense.getBid(id, 2);
        _decayed += _bid.shares;
        _balance += _bid.deposit;

        decayed = dLicense.getDecayedShares(id);
        assertEq(_decayed, decayed);

        record = dLicense.getRecord(id);
        assertEq(_decayed, record.bidderShares);
        assertEq(address(dLicense).balance, _balance + record.deposit);
    }

    function test_Deposit() public payable {
        // alice drafts license
        uint256 rate = 2;
        uint256 id = draft_new(FINNEY, rate, ONE_WEEK, alice);

        // david places a bid
        vm.warp(200000);
        vm.deal(david, 1 ether);
        uint256 decayed = dLicense.getDecayedShares(id);
        uint256 price = TWO_FINNEY + TWO_FINNEY;
        record = dLicense.getRecord(id);
        uint256 amount = (price * (decayed - record.bidderShares)) / 10000;
        bid(id, david, price, amount);

        // david deposits remainder to prepare bid to license
        uint256 _deposit;
        uint256 bidId; // bidId is 0
        vm.warp(300500);
        _bid = dLicense.getBid(id, bidId);
        _deposit += _bid.deposit;
        amount = _bid.price - _bid.deposit;
        deposit(id, bidId, david, amount);
        _bid = dLicense.getBid(id, bidId);
        assertEq(_bid.deposit, _deposit + amount);
        assertEq(address(dLicense).balance, _bid.deposit);
    }

    function test_License_WithIneligibleBids() public payable {
        // alice drafts license
        uint256 rate = 2;
        uint256 id = draft_new(FINNEY, rate, ONE_WEEK, alice);

        // bob licenses
        vm.deal(bob, 1 ether);
        license(id, bob, TWO_FINNEY);

        // charlie places first bid
        vm.warp(10000);
        vm.deal(charlie, 1 ether);
        uint256 decayed = dLicense.getDecayedShares(id);
        uint256 price = TWO_FINNEY + FINNEY;
        uint256 amount = (price * decayed) / 10000;
        bid(id, charlie, price, amount);

        // david places second bid
        vm.warp(200000);
        vm.deal(david, 1 ether);
        decayed = dLicense.getDecayedShares(id);
        price = TWO_FINNEY + TWO_FINNEY;
        record = dLicense.getRecord(id);
        amount = (price * (decayed - record.bidderShares)) / 10000;
        bid(id, david, price, amount);

        // echo places third bid
        vm.warp(300000);
        vm.deal(echo, 1 ether);
        decayed = dLicense.getDecayedShares(id);
        price = TWO_FINNEY + TWO_FINNEY + FINNEY;
        record = dLicense.getRecord(id);
        amount = (price * (decayed - record.bidderShares)) / 10000;
        bid(id, echo, price, amount);

        // charlie, david, and echo do not deposit enough for their bids to become eligible
        // fox licenses
        vm.warp(350000);
        vm.deal(fox, 1 ether);
        license(id, fox, amount = TWO_FINNEY + TWO_FINNEY);

        record = dLicense.getRecord(id);
        assertEq(record.licensee, fox);
        assertEq(record.bidderShares, 0);
        assertEq(record.deposit, amount);
    }

    function test_License_WithEligibleBids() public payable {
        // alice drafts license
        uint256 rate = 2;
        uint256 id = draft_new(FINNEY, rate, ONE_WEEK, alice);

        // bob licenses
        vm.deal(bob, 1 ether);
        license(id, bob, TWO_FINNEY);

        // charlie places first bid
        vm.warp(10000);
        vm.deal(charlie, 1 ether);
        uint256 decayed = dLicense.getDecayedShares(id);
        uint256 price = TWO_FINNEY + FINNEY;
        uint256 amount = (price * decayed) / 10000;
        bid(id, charlie, price, amount);

        // david places second bid
        vm.warp(200000);
        vm.deal(david, 1 ether);
        decayed = dLicense.getDecayedShares(id);
        price = TWO_FINNEY + TWO_FINNEY;
        record = dLicense.getRecord(id);
        amount = (price * (decayed - record.bidderShares)) / 10000;
        bid(id, david, price, amount);

        // echo places third bid
        vm.warp(300000);
        vm.deal(echo, 1 ether);
        decayed = dLicense.getDecayedShares(id);
        price = TWO_FINNEY + TWO_FINNEY + FINNEY;
        record = dLicense.getRecord(id);
        amount = (price * (decayed - record.bidderShares)) / 10000;
        bid(id, echo, price, amount);

        // david deposits enough so his bid becomes an eligible bid
        uint256 bidId = 1;
        _bid = dLicense.getBid(id, bidId);
        amount = _bid.price - _bid.deposit;
        deposit(id, bidId, david, amount);

        // fox licenses but loses to david because david has greater number of decayed shares
        vm.warp(350000);
        vm.deal(fox, 1 ether);
        license(id, fox, amount = TWO_FINNEY + TWO_FINNEY);

        record = dLicense.getRecord(id);
        assertEq(record.licensee, david);
        assertEq(record.bidderShares, 0);
        assertEq(record.deposit, amount);
        emit log_uint(address(dLicense).balance);
    }

    function test_License_Revert_LicenseInUse() public payable {
        // alice drafts license
        uint256 rate = 2;
        uint256 id = draft_new(FINNEY, rate, ONE_WEEK, alice);

        // bob licenses
        vm.deal(bob, 1 ether);
        license(id, bob, TWO_FINNEY);

        // fox tries to license
        vm.warp(302000);
        vm.deal(fox, 1 ether);
        uint256 amount = TWO_FINNEY + TWO_FINNEY;
        vm.prank(fox);
        vm.expectRevert(DecayingLicense.LicenseInUse.selector);
        dLicense.license{value: amount}(id, amount);
    }

    // TODO:
    function test_Collect_LicenseActive() public payable {
        // alice drafts license
        uint256 rate = 2;
        uint256 id = draft_new(FINNEY, rate, ONE_WEEK, alice);

        // bob licenses
        vm.deal(bob, 1 ether);
        license(id, bob, TWO_FINNEY);

        vm.warp(1000);
        record = dLicense.getRecord(id);
        uint256 collection = dLicense.patronageOwed(id);
        uint256 depositBeforeCollection = record.deposit;

        dLicense.collect(id);
        record = dLicense.getRecord(id);
        assertEq(record.deposit, depositBeforeCollection - collection);
        assertEq(record.timeLastCollected, 1000);
        assertEq(record.timeLastLicensed, 1);

        collection = dLicense.patronageOwed(id);
        assertEq(collection, 0);
    }

    // TODO:
    function test_Collect_LicenseOverdue() public payable {
        // alice drafts license
        uint256 rate = 2;
        uint256 id = draft_new(FINNEY, rate, ONE_WEEK, alice);

        // bob licenses
        vm.deal(bob, 1 ether);
        license(id, bob, TWO_FINNEY);

        vm.warp(10000000000);
        record = dLicense.getRecord(id);
        uint256 collection = dLicense.patronageOwed(id);

        dLicense.collect(id);
        record = dLicense.getRecord(id);
        assertEq(record.deposit, 0);
        assertEq(record.timeLastCollected, 10000000000);
        assertEq(record.timeLastLicensed, 0);

        collection = dLicense.patronageOwed(id);
        assertEq(collection, 0);
    }

    function test_Collect_Revert_NothingToCollect() public payable {
        // alice drafts license
        uint256 rate = 2;
        uint256 id = draft_new(FINNEY, rate, ONE_WEEK, alice);

        // bob licenses
        vm.deal(bob, 1 ether);
        license(id, bob, TWO_FINNEY);

        vm.expectRevert(DecayingLicense.NothingToCollect.selector);
        dLicense.collect(id + 1);
    }

    /* -------------------------------------------------------------------------- */
    /*                                  Helpers.                                  */
    /* -------------------------------------------------------------------------- */

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
        assertEq(terms.price, price);
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

    function deposit(
        uint256 id,
        uint256 bidId,
        address bidder,
        uint256 amount
    ) public payable {
        vm.prank(bidder);
        dLicense.deposit{value: amount}(id, bidId);
    }

    function license(
        uint256 id,
        address licensee,
        uint256 price
    ) public payable {
        vm.prank(licensee);
        dLicense.license{value: price}(id, price);
    }

    function collect(uint256 id, address licensor) public payable {
        vm.prank(licensor);
        dLicense.collect(id);
    }
}
