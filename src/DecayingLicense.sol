// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.24;

/// @notice Decaying License.
/// @author audsssy.eth
///
/// @dev Note:
/// An onchain variation of Depreciating Licenses
/// (https://inequality.stanford.edu/sites/default/files/Zhang-paper.pdf).
///
/// A license decays as its ownership continuously reverts back to its licensor.
/// Anyone can draft decaying licenses, become licensor, and set license terms.
/// Anyone can bid to become a license holder by paying license price and
/// self-assessing a new license price.

// provided by licensor
struct Terms {
    uint256 price; // future price never goes below price in terms
    string content;
    address licensor;
    uint40 rate;
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
    uint256 deposit; // deposits to cover license tax rates
    address licensee; // license holder
    uint40 timeLastLicensed; // last licensed timestamp
    uint40 timeLastCollected; // last tax collection timestamp
    uint40 bidderShares; // amount of shares decayed and owned by bidders
}

contract DecayingLicense {
    /* -------------------------------------------------------------------------- */
    /*                                   Errors.                                  */
    /* -------------------------------------------------------------------------- */

    error Unauthorized();
    error InvalidLicense();
    error InvalidPrice();
    error InvalidAmount();
    error InvalidBid();
    error InvalidBidAmount();
    error TooManyBids();
    error HigherAmountRequired();
    error TransferFailed();
    error LicenseInUse();

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
        string calldata content
    ) public payable {
        if (price == 0 || bytes(content).length == 0) revert InvalidLicense();

        if (id == 0) {
            // Draft new license.
            unchecked {
                id = ++licenseId;
            }
        } else {
            // Update previous license.
            Terms memory $ = terms[id];
            if ($.licensor != msg.sender) revert Unauthorized();
        }

        terms[id].price = price;
        terms[id].content = content;
        terms[id].licensor = msg.sender;
        terms[id].rate = uint40(rate); // x / 10000
        terms[id].period = uint40(period);
    }

    function bid(uint256 id, uint256 price) public payable {
        Terms memory _terms = terms[id];
        Record memory _record = records[id];

        // Check if licensable.
        if (bytes(_terms.content).length == 0) revert InvalidLicense();

        // Check if total shares exceed 100.
        uint256 licensorShares = getLicensorShares(id);
        if (licensorShares + _record.bidderShares > 100) revert InvalidBid();

        /// Check if bid amount matches `msg.value`.
        uint256 shares = licensorShares - _record.bidderShares;
        if (msg.value > (price * shares) / 10000) revert InvalidBidAmount();

        unchecked {
            // Increment shares owned by bidders.
            records[id].bidderShares += uint40(shares);
        }

        // Iterate bids and increment shares by current bidder.
        uint256 bidId = getRepeatedBid(id, msg.sender);
        if (bidId > 0) {
            if (price > bids[id][bidId].price) revert HigherAmountRequired();

            bids[id][bidId].price = price;
            bids[id][bidId].deposit += msg.value;
            bids[id][bidId].shares += uint40(shares);
        } else {
            if (bids[id].length == 10) revert TooManyBids();
            bids[id].push(
                Bid({
                    bidder: msg.sender,
                    shares: uint40(shares),
                    price: price,
                    deposit: msg.value
                })
            );
        }
    }

    function deposit(uint256 id, uint256 bidId) public payable {
        if (bidId == 0) {
            // Make license deposits.
            Record memory $ = records[id];
            if ($.licensee != msg.sender) revert Unauthorized();

            records[id].deposit += msg.value;
        } else {
            // Make bid deposits.
            Bid memory $ = bids[id][bidId];
            if ($.bidder != msg.sender) revert Unauthorized();

            bids[id][bidId].deposit += msg.value;
        }
    }

    function license(uint256 id, uint256 price) public payable {
        // Check if licensable.
        Terms memory _terms = terms[id];
        Record memory _record = records[id];
        if (bytes(_terms.content).length == 0) revert InvalidLicense();

        if (_record.timeLastLicensed == 0) {
            // Check if price is higher than base price in terms.
            if (_terms.price > price) revert InvalidPrice();

            // Check if `msg.value` is sufficient to cover license fees, price and tax.
            if ((price + price * _terms.rate) / 10000 > msg.value)
                revert InvalidAmount();

            // Transfer price to license to licensor.
            (bool success, ) = _terms.licensor.call{value: price}("");
            if (!success) revert TransferFailed();

            // Record new license price, deposit, licensee, and license timestamp.
            records[id].price = price;
            records[id].deposit = msg.value - price;
            records[id].licensee = msg.sender;
            records[id].timeLastLicensed = uint40(block.timestamp);
            records[id].timeLastCollected = uint40(block.timestamp);
        } else if (
            block.timestamp > _record.timeLastLicensed &&
            _record.timeLastLicensed + _terms.period / 3 > block.timestamp
        ) {
            // Forced sell not possible.
            // License remains in `use cycle` to ensure license holder has
            // ample time to enjoy licensed content.
            // `Use cycle` is hard-coded to first third of a license.
            // Future iteration on current `use cycle` is expected.
            revert LicenseInUse();
        } else if (
            _record.timeLastLicensed > 0 &&
            _record.timeLastLicensed + _terms.period > block.timestamp &&
            block.timestamp > _record.timeLastLicensed + _terms.period / 3
        ) {
            // `Use cycle` passed. Forced sell possible.
            Bid memory _bid = getHighestBid(id);

            // Forced sell is limited to bidders.
            if (_bid.bidder == address(0)) revert InvalidBid();

            // Collect license fees from previous licensor.
            bool success;
            uint256 collection = patronageOwed(id);
            if (collection >= _record.deposit) {
                // Licensor collects new license price and previous deposit, if any.
                (success, ) = _terms.licensor.call{
                    value: _bid.price + _record.deposit
                }("");
                if (!success) revert TransferFailed();
            } else {
                // Licensor collects new license price and previous deposit, if any.
                (success, ) = _terms.licensor.call{
                    value: _bid.price + collection
                }("");
                if (!success) revert TransferFailed();

                // Refund any deposit to previous license holder.
                (success, ) = _record.licensee.call{
                    value: _record.deposit - collection
                }("");
                if (!success) revert TransferFailed();
            }

            // Record new license price, deposit, licensee, and license timestamp.
            records[id].price = _bid.price;
            records[id].deposit = _bid.deposit - _bid.price;
            records[id].licensee = _bid.bidder;
            records[id].timeLastLicensed = uint40(block.timestamp);
            records[id].timeLastCollected = uint40(block.timestamp);

            // Reset shares owned by bidders.
            delete records[id].bidderShares;

            // Refund all bids.
            refundDeposits(id);
        }
    }

    /* -------------------------------------------------------------------------- */
    /*                                Collect Fees.                               */
    /* -------------------------------------------------------------------------- */

    /// @dev Collection is limited to licensors.
    function collect(uint256 id) public payable returns (uint256, uint256) {
        Terms memory _terms = terms[id];
        Record memory _record = records[id];
        if (_terms.licensor != msg.sender) revert Unauthorized();

        uint256 collection = patronageOwed(id);
        if (collection > 0) {
            records[id].timeLastCollected = uint40(block.timestamp);

            if (collection >= _record.deposit) {
                // Terminate license.
                delete records[id].price;
                delete records[id].deposit;
                delete records[id].licensee;

                // Record last tax collection timestamp.
                records[id].timeLastCollected = uint40(block.timestamp);

                // Take deposit.
                (bool success, ) = _terms.licensor.call{value: _record.deposit}(
                    ""
                );
                if (!success) revert TransferFailed();

                return (_record.deposit, 0);
            } else {
                // Take collection.
                (bool success, ) = _terms.licensor.call{value: collection}("");
                if (!success) revert TransferFailed();

                return (
                    collection,
                    records[id].deposit = _record.deposit - collection
                );
            }
        } else {
            return (0, 0);
        }
    }

    /* -------------------------------------------------------------------------- */
    /*                                  Helpers.                                  */
    /* -------------------------------------------------------------------------- */

    function refundDeposits(uint256 id) internal {
        Bid memory $;
        uint256 length = bids[id].length;

        for (uint256 i; i < length; ++i) {
            $ = bids[id][i];

            if ($.deposit > 0) {
                (bool success, ) = $.bidder.call{value: $.deposit}("");
                if (!success) revert TransferFailed();
            }
        }
    }

    /// @dev Helper function to calculate reverted shares.
    function getLicensorShares(
        uint256 id
    ) public view returns (uint256 shares) {
        Terms memory _terms = terms[id];
        Record memory _record = records[id];

        // Return 0 if license is not active.
        if (_record.timeLastCollected == 0) shares;
        shares = (((uint40(block.timestamp) - _record.timeLastLicensed) * 100) /
            _terms.period);
    }

    /// @dev Helper function to calculate patronage owed.
    // credit: simondlr  https://github.com/simondlr/thisartworkisalwaysonsale/blob/master/packages/hardhat/contracts/v1/ArtStewardV2.sol
    function patronageOwed(
        uint256 id
    ) public view returns (uint256 patronageDue) {
        Terms memory _terms = terms[id];
        Record memory _record = records[id];

        // Return 0 if license is not active.
        if (_record.timeLastCollected == 0) return 0;
        return
            ((_record.price * (block.timestamp - _record.timeLastCollected)) *
                _terms.rate) /
            10000 /
            365 days;
    }

    function getHighestBid(uint256 id) public view returns (Bid memory $) {
        Bid memory _$;
        uint256 length = bids[id].length;
        for (uint256 i; i < length; ++i) {
            _$ = bids[id][i];

            if (_$.deposit > _$.price && _$.price > $.price) {
                $ = _$;
            }
        }
        return $;
    }

    function getRepeatedBid(
        uint256 id,
        address bidder
    ) public view returns (uint256 bidId) {
        Bid memory $;
        uint256 length = bids[id].length;
        for (uint256 i; i != length; ++i) {
            $ = bids[id][i];
            if ($.bidder == bidder) bidId = i;
        }
    }

    /* -------------------------------------------------------------------------- */
    /*                                 Public Get.                                */
    /* -------------------------------------------------------------------------- */

    // function getLicense(uint256 id) public view returns (License memory) {
    //     return licenses[id];
    // }

    receive() external payable virtual {}
}
