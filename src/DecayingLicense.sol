// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.24;

/// @notice Decaying License.
/// @author audsssy.eth
///
/// @dev Note:
/// An onchain variation of Depreciating Licenses
/// (https://inequality.stanford.edu/sites/default/files/Zhang-paper.pdf).
///
/// A decaying license gradually and continuously reverts licensed rights back to its licensor.
/// Draft terms to decaying licenses and collect licensing fees, price to license + patronage.
/// Bid to license by paying licensing fees and self-assessing a new license price.

// provided by licensor
struct Terms {
    uint256 price; // future price never goes below price in terms
    string content;
    address licensor;
    uint40 rate; // higher it is, faster license decays
    uint40 period;
}

// provided by licensee
struct Bid {
    address bidder;
    uint40 shares;
    uint256 price;
    uint256 deposit;
}

// managed by contract
struct Record {
    uint256 price; // price of license as provided by licensee
    uint256 deposit; // deposits to cover patronage
    address licensee; // license holder
    uint40 timeLastLicensed; // last licensed timestamp
    uint40 timeLastCollected; // last patronage collection timestamp
    uint40 bidderShares; // amount of shares decayed and owned by bidders
}

contract DecayingLicense {
    /* -------------------------------------------------------------------------- */
    /*                                   Events.                                  */
    /* -------------------------------------------------------------------------- */

    event Drafted(
        uint256 indexed id,
        address indexed licensor,
        uint256 indexed price
    );
    event BidSubmitted(
        uint256 indexed id,
        address indexed bidder,
        uint256 indexed price
    );
    event Deposited(
        uint256 indexed id,
        bool indexed forLicense,
        uint256 indexed totalDeposit
    );
    event Licensed(
        uint256 indexed id,
        address indexed licensee,
        uint256 indexed newPurchasePrice
    );
    event Collected(uint256 indexed id, uint256 indexed amount);

    /* -------------------------------------------------------------------------- */
    /*                                   Errors.                                  */
    /* -------------------------------------------------------------------------- */

    error Unauthorized();
    error InvalidTerms();
    error InvalidLicense();
    error InvalidPrice();
    error InvalidAmount();
    error ReadyToLicense();
    error InvalidBidAmount();
    error TooManyBids();
    error HigherPriceRequired();
    error TransferFailed();
    error LicenseInUse();
    error NothingToCollect();

    /* -------------------------------------------------------------------------- */
    /*                                  Storage.                                  */
    /* -------------------------------------------------------------------------- */

    /// @notice
    uint256 public licenseId;

    mapping(uint256 id => Terms terms) public terms;

    mapping(uint256 id => Record record) public records;

    mapping(uint256 id => Bid[]) public bids;

    /* -------------------------------------------------------------------------- */
    /*                          Constructor & Modifiers.                          */
    /* -------------------------------------------------------------------------- */

    function draft(
        uint256 id,
        uint256 price,
        uint256 rate,
        uint256 period,
        string memory content
    ) public payable {
        if (rate > period) revert InvalidTerms();

        Terms memory $ = terms[id];
        if (price == 0 || bytes(content).length == 0) revert InvalidLicense();

        if (id == 0) {
            // Draft new license.
            unchecked {
                id = ++licenseId;
            }
        } else {
            // Update previous license.
            if ($.licensor != msg.sender) revert Unauthorized();

            // Licensors must draft new licenses to change base price and content.
            price = $.price;
            delete content;
        }

        $ = Terms({
            price: price,
            content: (bytes(content).length == 0) ? $.content : content,
            licensor: msg.sender,
            rate: uint40(rate),
            period: uint40(period)
        });

        terms[id] = $;

        emit Drafted(id, msg.sender, $.price);
    }

    function bid(uint256 id, uint256 price) public payable {
        uint256 amount;
        Terms memory _terms = terms[id];
        Record memory _record = records[id];

        // Check if licensable.
        if (bytes(_terms.content).length == 0) revert InvalidLicense();

        // Check if total share reached 100.
        uint256 decayed = getDecayedShares(id);
        if (decayed > 10000) revert ReadyToLicense();

        // Check if price is higher than base price required in terms.
        if (_terms.price > price) revert InvalidPrice();

        uint256 shares;
        unchecked {
            // Calculate shares bid by bidder.
            shares = decayed - _record.bidderShares;

            // Increment shares owned by bidders.
            records[id].bidderShares += uint40(shares);
        }

        // Retrieve any previous bid by bidder.
        uint256 bidId = getPastBid(id, msg.sender);

        Bid memory _bid;

        if (bidId != type(uint256).max) {
            amount = (price * shares) / 10000;
            // If previous bid exists, refund of difference in self-assessed fee is issued to bidder.
            _bid = getBid(id, bidId);

            if (amount > _bid.deposit) {
                if (msg.value != amount - _bid.deposit)
                    revert InvalidBidAmount();
            } else {
                (bool success, ) = _bid.bidder.call{
                    value: _bid.deposit - amount
                }("");
                if (!success) revert TransferFailed();
            }

            placeBid(
                id,
                bidId,
                Bid({
                    bidder: msg.sender,
                    shares: _bid.shares + uint40(shares),
                    price: price,
                    deposit: amount
                })
            );
        } else {
            if (bids[id].length == 100) revert TooManyBids();
            amount = (price * shares) / 10000;

            /// Check if bid amount matches `msg.value`.
            if (msg.value != amount) revert InvalidBidAmount();

            placeBid(
                id,
                type(uint256).max,
                Bid({
                    bidder: msg.sender,
                    shares: uint40(shares),
                    price: price,
                    deposit: amount
                })
            );
        }
    }

    // function deposit(uint256 id, uint256 bidId) public payable {
    //     bool forLicense = (bidId == 0) ? true : false;
    //     uint256 totalDeposit;

    //     if (forLicense) {
    //         // Make license deposits.
    //         Record memory $ = records[id];
    //         if ($.licensee != msg.sender) revert Unauthorized();

    //         unchecked {
    //             totalDeposit = records[id].deposit += msg.value;
    //         }
    //     } else {
    //         // Make bid deposits.
    //         Bid memory $ = bids[id][bidId];
    //         if ($.bidder != msg.sender) revert Unauthorized();

    //         unchecked {
    //             totalDeposit = bids[id][bidId].deposit += msg.value;
    //         }
    //     }

    //     emit Deposited(id, forLicense, totalDeposit);
    // }

    function license(uint256 id, uint256 price) public payable {
        // Check if licensable.
        Terms memory _terms = terms[id];
        Record memory _record = records[id];
        if (bytes(_terms.content).length == 0) revert InvalidLicense();

        uint256 decayed = getDecayedShares(id);

        // New or terminated licenses.
        if (_record.timeLastLicensed == 0) {
            // Check if price is higher than base price in terms.
            if (_terms.price > price) revert InvalidPrice();

            // Check if `msg.value` is sufficient to cover license fee.
            if (price != msg.value) revert InvalidAmount();

            // Transfer price to license to licensor.
            // (bool success, ) = _terms.licensor.call{value: price}("");
            // if (!success) revert TransferFailed();

            // Record new license price, deposit, licensee, and license timestamp.
            _record = Record({
                price: price,
                deposit: msg.value,
                licensee: msg.sender,
                timeLastLicensed: uint40(block.timestamp),
                timeLastCollected: uint40(block.timestamp),
                bidderShares: 0
            });
            records[id] = _record;
        } else if (_record.timeLastLicensed + _terms.period > block.timestamp) {
            if (decayed >= 10000) {
                // Forced sell possible when licensed rights have fully decayed.
                _license(id, price, _record, _terms);
            } else {
                // Forced sell not possible.
                // License remains in `use cycle` to ensure license holder has
                // ample time to enjoy licensed content.
                // Future iteration on current `use cycle` is expected.
                revert LicenseInUse();
            }
        } else {
            // Inactive licenses.
            _license(id, price, _record, _terms);
        }

        emit Licensed(id, _record.licensee, _record.price);
    }

    function _license(
        uint256 id,
        uint256 price,
        Record memory _record,
        Terms memory _terms
    ) internal {
        // Collect past license fee, if any.
        bool success;
        uint256 collection = patronageOwed(id);
        if (collection >= _record.deposit) {
            // Licensor collects new license price and previous deposit, if any.
            (success, ) = _terms.licensor.call{value: _record.deposit}("");
            if (!success) revert TransferFailed();
        } else {
            // Licensor collects new license price and previous deposit, if any.
            (success, ) = _terms.licensor.call{value: collection}("");
            if (!success) revert TransferFailed();

            // Refund any deposit to previous license holder.
            (success, ) = _record.licensee.call{
                value: _record.deposit - collection
            }("");
            if (!success) revert TransferFailed();
        }

        // If there is no highest bid, `msg.sender` may license directly.
        Bid memory _bid = getBestBid(id);
        if (_bid.bidder == address(0)) {
            // Check if price is higher than base price in terms.
            if (_terms.price > price) revert InvalidPrice();

            // Check if `msg.value` is sufficient to cover license fee.
            if (price != msg.value) revert InvalidAmount();

            _bid.bidder = msg.sender;
            _bid.price = price;
            // _bid.deposit = msg.value;
        }

        // Record new license price, deposit, licensee, and license timestamp.
        _record = Record({
            price: _bid.price,
            deposit: _bid.price,
            licensee: _bid.bidder,
            timeLastLicensed: uint40(block.timestamp),
            timeLastCollected: uint40(block.timestamp),
            bidderShares: 0
        });
        records[id] = _record;

        // Refund all bids.
        refundDeposits(id);
    }

    /* -------------------------------------------------------------------------- */
    /*                                Collect Fees.                               */
    /* -------------------------------------------------------------------------- */

    /// @dev Collection.
    function collect(uint256 id) public payable {
        Terms memory _terms = terms[id];
        Record memory _record = records[id];

        uint256 collection = patronageOwed(id);
        if (collection > 0) {
            records[id].timeLastCollected = uint40(block.timestamp);

            if (collection > _record.deposit) {
                collection = _record.deposit;

                // Reset license.
                // records[id].price = _terms.price;
                // delete records[id].deposit;
                // delete records[id].licensee;
                // delete records[id].timeLastLicensed;

                // Take deposit.
                (bool success, ) = _terms.licensor.call{value: collection}("");
                if (!success) revert TransferFailed();
            } else {
                records[id].deposit = _record.deposit - collection;

                // Take collection.
                (bool success, ) = _terms.licensor.call{value: collection}("");
                if (!success) revert TransferFailed();
            }
        } else {
            revert NothingToCollect();
        }

        emit Collected(id, collection);
    }

    /* -------------------------------------------------------------------------- */
    /*                                  Helpers.                                  */
    /* -------------------------------------------------------------------------- */

    function refundDeposits(uint256 id) internal {
        Bid memory $;
        uint256 length = bids[id].length;
        for (uint256 i; i < length; ++i) {
            $ = bids[id][i];

            (bool success, ) = $.bidder.call{value: $.price}("");
            if (!success) revert TransferFailed();
        }
    }

    /// @dev Helper function to calculate reverted shares.
    function getDecayedShares(uint256 id) public view returns (uint256 shares) {
        Terms memory _terms = terms[id];
        Record memory _record = records[id];

        // Return 0 if license is not active.
        if (_record.timeLastLicensed == 0) shares;
        unchecked {
            shares = (((uint40(block.timestamp) - _record.timeLastLicensed) *
                _terms.rate *
                10000) / _terms.period);
        }
    }

    /// @dev Helper function to calculate patronage owed.
    // credit: simondlr  https://github.com/simondlr/thisartworkisalwaysonsale/blob/master/packages/hardhat/contracts/v1/ArtStewardV2.sol
    function patronageOwed(
        uint256 id
    ) public view returns (uint256 patronageDue) {
        Terms memory _terms = terms[id];
        Record memory _record = records[id];

        // Return 0 if license is not active.
        if (_record.timeLastLicensed == 0) patronageDue;
        unchecked {
            patronageDue =
                (_record.price *
                    (block.timestamp - _record.timeLastCollected)) /
                _terms.period;
        }
    }

    function getBestBid(uint256 id) public view returns (Bid memory $) {
        Bid memory _$;
        uint256 length = bids[id].length;
        for (uint256 i; i < length; ++i) {
            _$ = bids[id][i];

            if (_$.price > $.price) {
                $ = _$;
            } else if (_$.price == $.price) {
                (_$.shares > $.shares) ? $ = _$ : $;
            } else {
                $;
            }
        }
    }

    function placeBid(uint256 id, uint256 bidId, Bid memory _bid) internal {
        if (bidId == type(uint256).max) {
            bids[id].push(_bid);
        } else {
            uint256 length = getNumOfBids(id);
            for (uint256 i; i != length; ++i) {
                (i == bidId) ? bids[id][i] = _bid : _bid;
            }
        }

        emit BidSubmitted(id, _bid.bidder, _bid.price);
    }

    function getPastBid(
        uint256 id,
        address bidder
    ) public view returns (uint256 bidId) {
        Bid memory $;
        uint256 length = getNumOfBids(id);
        (length == 0) ? bidId = type(uint256).max : bidId;
        for (uint256 i; i != length; ++i) {
            $ = bids[id][i];
            ($.bidder == bidder) ? bidId = i : bidId = type(uint256).max;
        }
    }

    /* -------------------------------------------------------------------------- */
    /*                                 Public Get.                                */
    /* -------------------------------------------------------------------------- */

    function getTerms(uint256 id) public view returns (Terms memory _terms) {
        _terms = terms[id];
    }

    function getRecord(uint256 id) public view returns (Record memory _record) {
        _record = records[id];
    }

    function getNumOfBids(uint256 id) public view returns (uint256) {
        return bids[id].length;
    }

    function getBid(
        uint256 id,
        uint256 bidId
    ) public view returns (Bid memory _bid) {
        uint256 length = bids[id].length;

        for (uint256 i; i != length; ++i) {
            (i == bidId) ? _bid = bids[id][i] : _bid;
        }
    }

    receive() external payable virtual {}
}
