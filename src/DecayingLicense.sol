// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.24;

/// @notice Local Decaying License.
/// @author audsssy.eth
///
/// @dev Note:
/// An onchain variation of Depreciating Licenses (https://inequality.stanford.edu/sites/default/files/Zhang-paper.pdf).
///
/// A license is decaying when its ownership continuously reverts back to its licensor.
/// Owner of stuff can create one or more licenses for stuff and become licensor.
/// Anyone can bid to become a license holder by paying license price and self-assessing a new price.
/// Anyone may reassess the eligibility of current license holder and effectuate necessary changes.

struct License {
    uint256 price; // provided by licensee
    uint256 deposit; // provided by licensee
    address holder; // provided by licensee
    uint40 rate; // provided by licensor, e.g., 10% per year
    address licensor; // provided by licensor
    uint40 term; // provided by licensor
    string subject; // provided by licensor
    uint40 timeLastLicensed; // automated by contract
    uint40 timeLastCollected; // automated by contract
    uint40 holderShares; // automated by contract
}

struct Bid {
    uint256 price;
    uint256 deposit;
    uint256 shares;
    address bidder;
}

contract DecayingLicense {
    /* -------------------------------------------------------------------------- */
    /*                                   Errors.                                  */
    /* -------------------------------------------------------------------------- */

    error Unauthorized();
    error InvalidLicense();
    error InvalidLicenseAmount();
    error InvalidBidAmount();
    error TransferFailed();
    error LicenseInUse();

    /* -------------------------------------------------------------------------- */
    /*                                  Storage.                                  */
    /* -------------------------------------------------------------------------- */

    uint256 licenseId;

    mapping(uint256 licenseId => License license) licenses;

    mapping(uint256 licenseId => Bid[]) bids;

    /* -------------------------------------------------------------------------- */
    /*                          Constructor & Modifiers.                          */
    /* -------------------------------------------------------------------------- */

    modifier authorized(uint256 id) {
        if (msg.sender != licenses[id].licensor) revert Unauthorized();
        _;
    }

    function draft(
        uint256 id,
        uint256 price,
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
            License memory $ = licenses[id];
            if ($.licensor != msg.sender) revert Unauthorized();
        }

        licenses[id].price = price;
        licenses[id].subject = content;
        licenses[id].licensor = msg.sender;

        // TODO: Hardcoded.
        licenses[id].rate = 10; // 10 / 10000
        licenses[id].term = 1 weeks;
    }

    function bid(uint256 id, uint256 price) public payable {
        License memory $ = licenses[id];
        if (bytes($.subject).length == 0) revert InvalidLicense();

        uint256 shares = sharesReverted(id);
        if (msg.value > (price * shares) / 10000) revert InvalidBidAmount();

        bids[id].push(
            Bid({
                price: price,
                deposit: msg.value,
                bidder: msg.sender,
                shares: shares // TODO: Do we need this?
            })
        );
    }

    function deposit(uint256 id, uint256 bidId) public payable {
        if (bidId == 0) {
            // Make license deposits.
            License memory $ = licenses[id];
            if ($.holder != msg.sender) revert Unauthorized();

            licenses[id].deposit += msg.value;
        } else {
            // Make bid deposits.
            Bid memory $ = bids[id][bidId];
            if ($.bidder != msg.sender) revert Unauthorized();

            bids[id][bidId].deposit += msg.value;
        }
    }

    function license(uint256 id, uint256 price) public payable {
        // Check if licensable.
        License memory $ = licenses[id];
        if (bytes($.subject).length == 0) revert InvalidLicense();

        if ($.timeLastLicensed == 0) {
            // Inaugural license.
            if ((price + price * $.rate) / 10000 > msg.value)
                revert InvalidLicenseAmount();

            licenses[id].price = price;
            licenses[id].deposit = msg.value - price;
            licenses[id].holder = msg.sender;

            licenses[id].timeLastLicensed = uint40(block.timestamp);

            (bool success, ) = $.licensor.call{value: price}("");
            if (!success) revert TransferFailed();
        } else if (
            block.timestamp > $.timeLastLicensed &&
            $.timeLastLicensed + $.term / 3 > block.timestamp
            // Forced sell not possible. Still in use cycle.
        ) {
            revert LicenseInUse();
        } else if (
            $.timeLastLicensed > 0 &&
            $.timeLastLicensed + $.term > block.timestamp &&
            block.timestamp > $.timeLastLicensed + $.term / 3
        ) {
            // Forced sell possible. Use cycle passed.
            Bid memory _bid = getHighestBid(id);

            licenses[id].price = _bid.price;
            licenses[id].deposit = _bid.deposit - _bid.price;
            licenses[id].holder = _bid.bidder;

            licenses[id].timeLastLicensed = uint40(block.timestamp);

            // Collect license charges.
            bool success;
            uint256 collection = patronageOwed(id);
            if (collection >= $.deposit) {
                // Licensor collects new license price and previous deposit, if any.
                (success, ) = $.licensor.call{value: _bid.price + $.deposit}(
                    ""
                );
                if (!success) revert TransferFailed();
            } else {
                // Licensor collects new license price and previous deposit, if any.
                (success, ) = $.licensor.call{value: _bid.price + collection}(
                    ""
                );
                if (!success) revert TransferFailed();

                // Refund any deposit to previous license holder.
                (success, ) = $.holder.call{value: $.deposit - collection}("");
                if (!success) revert TransferFailed();
            }

            // Refund all bids.
            refundDeposits(id);
        }
    }

    /* -------------------------------------------------------------------------- */
    /*                                Collect Fees.                               */
    /* -------------------------------------------------------------------------- */

    /// @dev .
    function collect(uint256 id) public payable returns (uint256, uint256) {
        License memory $ = licenses[id];
        if ($.licensor != msg.sender) revert Unauthorized();

        uint256 collection = patronageOwed(id);

        if (collection > 0) {
            licenses[id].timeLastCollected = uint40(block.timestamp);

            if (collection >= $.deposit) {
                // Terminate license.
                delete licenses[id].price;
                delete licenses[id].deposit;
                delete licenses[id].holder;

                // Take deposit.
                (bool success, ) = $.licensor.call{value: $.deposit}("");
                if (!success) revert TransferFailed();

                return ($.deposit, 0);
            } else {
                // Take collection.
                (bool success, ) = $.licensor.call{value: collection}("");
                if (!success) revert TransferFailed();

                return (
                    collection,
                    licenses[id].deposit = $.deposit - collection
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
    function sharesReverted(uint256 id) public view returns (uint256) {
        License memory $ = licenses[id];
        uint256 shares = ((uint40(block.timestamp) - $.timeLastLicensed) /
            $.term) * 10000;
        return shares;
    }

    /// @dev Helper function to calculate patronage owed.
    // credit: simondlr  https://github.com/simondlr/thisartworkisalwaysonsale/blob/master/packages/hardhat/contracts/v1/ArtStewardV2.sol
    function patronageOwed(
        uint256 id
    ) public view returns (uint256 patronageDue) {
        License memory $ = licenses[id];

        return
            (($.price * (block.timestamp - $.timeLastCollected)) * $.rate) /
            10000 /
            365 days;
    }

    function getHighestBid(uint256 id) public view returns (Bid memory) {
        Bid memory $;
        Bid memory _$;
        uint256 length = bids[id].length;
        for (uint256 i; i < length; ++i) {
            _$ = bids[id][i];

            if (_$.deposit > licenses[id].price) {
                if (_$.price > $.price) {
                    $ = _$;
                }
            }
        }

        return $;
    }

    receive() external payable virtual {}
}
