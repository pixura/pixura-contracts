pragma solidity 0.6.12;

import "openzeppelin-solidity/contracts/token/ERC721/IERC721.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/access/Ownable.sol";
import "./IERC721CreatorRoyalty.sol";
import "./Marketplace/IMarketplaceSettings.sol";
import "./Payments.sol";
import "./ISuperRareMarketplace.sol";

contract SuperRareMarketplace is Ownable, Payments, ISuperRareMarketplace {
    using SafeMath for uint256;

    /////////////////////////////////////////////////////////////////////////
    // Structs
    /////////////////////////////////////////////////////////////////////////
    // A reserve auction.
    struct Auction {
        address payable auctionCreator;
        uint256 creationBlock;
        uint256 lengthOfAuction;
        uint256 startingBlock;
        uint256 reservePrice;
        uint256 minimumBid;
        bytes32 auctionType;
    }

    // The active bid for a given token, contains the bidder, the marketplace fee at the time of the bid, and the amount of wei placed on the token
    struct ActiveBid {
        address payable bidder;
        uint8 marketplaceFee;
        uint256 amount;
    }

    // The sale price for a given token containing the seller and the amount of wei to be sold for
    struct SalePrice {
        address payable seller;
        uint256 amount;
    }

    /////////////////////////////////////////////////////////////////////////
    // Interfaces
    /////////////////////////////////////////////////////////////////////////

    // Marketplace Settings Interface
    IMarketplaceSettings public iMarketplaceSettings;

    // Creator Royalty Interface
    IERC721CreatorRoyalty public iERC721CreatorRoyalty;

    /////////////////////////////////////////////////////////////////////////
    // Constants
    /////////////////////////////////////////////////////////////////////////

    // Types of Auctions
    bytes32 public constant COLDIE_AUCTION = "COLDIE_AUCTION";
    bytes32 public constant SCHEDULED_AUCTION = "SCHEDULED_AUCTION";
    bytes32 public constant NO_AUCTION = bytes32(0);

    /////////////////////////////////////////////////////////////////////////
    // Marketplace State Variables
    /////////////////////////////////////////////////////////////////////////

    // Mapping from ERC721 contract to mapping of tokenId to sale price.
    mapping(address => mapping(uint256 => SalePrice)) private tokenPrices;

    // Mapping of ERC721 contract to mapping of token ID to mapping of bidder to current bid.
    mapping(address => mapping(uint256 => mapping(address => ActiveBid))) private tokenCurrentBids;

    // Mapping of ERC721 contract to mapping of token ID to mapping of bidders.
    mapping(address => mapping(uint256 => address[])) private bidders;

    /////////////////////////////////////////////////////////////////////////
    // Auction State Variables
    /////////////////////////////////////////////////////////////////////////

    // Mapping from ERC721 contract to mapping of tokenId to Auctions.
    mapping(address => mapping(uint256 => Auction)) private auctions;

    // Mapping of ERC721 contract to mapping of token ID to the current bid amount.
    mapping(address => mapping(uint256 => ActiveBid)) private currentBids;

    // Number of blocks to begin refreshing auction lengths
    uint256 public auctionLengthExtension;

    // Max Length that an auction can be
    uint256 public maxLength;

    // A minimum increase in bid amount when out bidding someone.
    uint8 public minimumBidIncreasePercentage; // 10 = 10%

    /////////////////////////////////////////////////////////////////////////////
    // Events
    /////////////////////////////////////////////////////////////////////////////
    event Sold(
        address indexed _originContract,
        address indexed _buyer,
        address indexed _seller,
        uint256 _amount,
        uint256 _tokenId
    );

    event SetSalePrice(
        address indexed _originContract,
        uint256 _amount,
        uint256 _tokenId
    );

    event Bid(
        address indexed _originContract,
        address indexed _bidder,
        uint256 _amount,
        uint256 _tokenId
    );

    event AcceptBid(
        address indexed _originContract,
        address indexed _bidder,
        address indexed _seller,
        uint256 _amount,
        uint256 _tokenId
    );

    event CancelBid(
        address indexed _originContract,
        address indexed _bidder,
        uint256 _amount,
        uint256 _tokenId
    );

    /////////////////////////////////////////////////////////////////////////
    // Constructor
    /////////////////////////////////////////////////////////////////////////
    /**
     * @dev Initializes the contract setting the market settings and creator royalty interfaces.
     * @param _iMarketSettings address to set as iMarketplaceSettings.
     * @param _iERC721CreatorRoyalty address to set as iERC721CreatorRoyalty.
     */
    constructor(address _iMarketSettings, address _iERC721CreatorRoyalty)
        public
    {
        require(
            _iMarketSettings != address(0),
            "constructor::Cannot have null address for _iMarketSettings"
        );

        require(
            _iERC721CreatorRoyalty != address(0),
            "constructor::Cannot have null address for _iERC721CreatorRoyalty"
        );

        // Set iMarketSettings
        iMarketplaceSettings = IMarketplaceSettings(_iMarketSettings);

        // Set iERC721CreatorRoyalty
        iERC721CreatorRoyalty = IERC721CreatorRoyalty(_iERC721CreatorRoyalty);
    }

    /////////////////////////////////////////////////////////////////////////
    // setIMarketplaceSettings
    /////////////////////////////////////////////////////////////////////////
    /**
     * @dev Admin function to set the marketplace settings.
     * Rules:
     * - only owner
     * - _address != address(0)
     * @param _address address of the IMarketplaceSettings.
     */
    function setMarketplaceSettings(address _address) public onlyOwner {
        require(
            _address != address(0),
            "setMarketplaceSettings::Cannot have null address for _iMarketSettings"
        );

        iMarketplaceSettings = IMarketplaceSettings(_address);
    }

    /////////////////////////////////////////////////////////////////////////
    // setIERC721CreatorRoyalty
    /////////////////////////////////////////////////////////////////////////
    /**
     * @dev Admin function to set the IERC721CreatorRoyalty.
     * Rules:
     * - only owner
     * - _address != address(0)
     * @param _address address of the IERC721CreatorRoyalty.
     */
    function setIERC721CreatorRoyalty(address _address) public onlyOwner {
        require(
            _address != address(0),
            "setIERC721CreatorRoyalty::Cannot have null address for _iERC721CreatorRoyalty"
        );

        iERC721CreatorRoyalty = IERC721CreatorRoyalty(_address);
    }

    /////////////////////////////////////////////////////////////////////////
    // Modifiers (as functions)
    /////////////////////////////////////////////////////////////////////////
    /**
     * @dev Checks that the token owner is approved for the ERC721Market
     * @param _originContract address of the contract storing the token.
     * @param _tokenId uint256 ID of the token
     */
    function ownerMustHaveMarketplaceApproved(
        address _originContract,
        uint256 _tokenId
    ) public view {
        IERC721 erc721 = IERC721(_originContract);
        address owner = erc721.ownerOf(_tokenId);
        require(
            erc721.isApprovedForAll(owner, address(this)),
            "owner must have approved contract"
        );
    }

    /**
     * @dev Checks that the token is owned by the sender
     * @param _originContract address of the contract storing the token.
     * @param _tokenId uint256 ID of the token
     */
    function senderMustBeTokenOwner(address _originContract, uint256 _tokenId)
        public
        view
    {
        IERC721 erc721 = IERC721(_originContract);
        require(
            erc721.ownerOf(_tokenId) == msg.sender,
            "sender must be the token owner"
        );
    }

    /////////////////////////////////////////////////////////////////////////
    // setSalePrice
    /////////////////////////////////////////////////////////////////////////
    /**
     * @dev Set the token for sale. The owner of the token must be the sender and have the marketplace approved.
     * @param _originContract address of the contract storing the token.
     * @param _tokenId uint256 ID of the token
     * @param _amount uint256 wei value that the item is for sale
     */
    function setSalePrice(
        address _originContract,
        uint256 _tokenId,
        uint256 _amount
    ) external override {
        // The owner of the token must have the marketplace approved
        ownerMustHaveMarketplaceApproved(_originContract, _tokenId);

        // The sender must be the token owner
        senderMustBeTokenOwner(_originContract, _tokenId);

        if (_amount == 0) {
            // Set not for sale and exit
            _resetTokenPrice(_originContract, _tokenId);
            emit SetSalePrice(_originContract, _amount, _tokenId);
            return;
        }

        tokenPrices[_originContract][_tokenId] = SalePrice(msg.sender, _amount);
        emit SetSalePrice(_originContract, _amount, _tokenId);
    }

    /////////////////////////////////////////////////////////////////////////
    // safeBuy
    /////////////////////////////////////////////////////////////////////////
    /**
     * @dev Purchase the token with the expected amount. The current token owner must have the marketplace approved.
     * @param _originContract address of the contract storing the token.
     * @param _tokenId uint256 ID of the token
     * @param _amount uint256 wei amount expecting to purchase the token for.
     */
    function safeBuy(
        address _originContract,
        uint256 _tokenId,
        uint256 _amount
    ) external override payable {
        // Make sure the tokenPrice is the expected amount
        require(
            tokenPrices[_originContract][_tokenId].amount == _amount,
            "safeBuy::Purchase amount must equal expected amount"
        );
        buy(_originContract, _tokenId);
    }

    /////////////////////////////////////////////////////////////////////////
    // buy
    /////////////////////////////////////////////////////////////////////////
    /**
     * @dev Purchases the token if it is for sale.
     * @param _originContract address of the contract storing the token.
     * @param _tokenId uint256 ID of the token.
     */
    function buy(address _originContract, uint256 _tokenId) public override payable {
        // The owner of the token must have the marketplace approved
        ownerMustHaveMarketplaceApproved(_originContract, _tokenId);

        // Check that the person who set the price still owns the token.
        require(
            _priceSetterStillOwnsTheToken(_originContract, _tokenId),
            "buy::Current token owner must be the person to have the latest price."
        );

        SalePrice memory sp = tokenPrices[_originContract][_tokenId];

        // Check that token is for sale.
        require(sp.amount > 0, "buy::Tokens priced at 0 are not for sale.");

        // Check that enough ether was sent.
        require(
            tokenPriceFeeIncluded(_originContract, _tokenId) == msg.value,
            "buy::Must purchase the token for the correct price"
        );

        // Get token contract details.
        IERC721 erc721 = IERC721(_originContract);
        address tokenOwner = erc721.ownerOf(_tokenId);

        // Wipe the token price.
        _resetTokenPrice(_originContract, _tokenId);

        // Transfer token.
        erc721.safeTransferFrom(tokenOwner, msg.sender, _tokenId);

        // If the buyer had an existing bid, return it
        if (_addressHasBidOnToken(msg.sender, _originContract, _tokenId)) {
            _refundBid(_originContract, msg.sender, _tokenId);
        }

        // Payout all parties.
        address payable owner = _makePayable(owner());
        Payments.payout(
            sp.amount,
            !iMarketplaceSettings.hasERC721TokenSold(_originContract, _tokenId),
            iMarketplaceSettings.getMarketplaceFeePercentage(),
            iERC721CreatorRoyalty.getERC721TokenRoyaltyPercentage(
                _originContract,
                _tokenId
            ),
            iMarketplaceSettings.getERC721ContractPrimarySaleFeePercentage(
                _originContract
            ),
            _makePayable(tokenOwner),
            owner,
            iERC721CreatorRoyalty.tokenCreator(_originContract, _tokenId),
            owner
        );

        // Set token as sold
        iMarketplaceSettings.markERC721Token(_originContract, _tokenId, true);

        emit Sold(_originContract, msg.sender, tokenOwner, sp.amount, _tokenId);
    }

    /////////////////////////////////////////////////////////////////////////
    // tokenPrice
    /////////////////////////////////////////////////////////////////////////
    /**
     * @dev Gets the sale price of the token
     * @param _originContract address of the contract storing the token.
     * @param _tokenId uint256 ID of the token
     * @return uint256 sale price of the token
     */
    function tokenPrice(address _originContract, uint256 _tokenId)
        external
        view
        override
        returns (uint256)
    {
        // The owner of the token must have the marketplace approved
        ownerMustHaveMarketplaceApproved(_originContract, _tokenId); // TODO: Make sure to write test to verify that this returns 0 when it fails

        if (_priceSetterStillOwnsTheToken(_originContract, _tokenId)) {
            return tokenPrices[_originContract][_tokenId].amount;
        }
        return 0;
    }

    /////////////////////////////////////////////////////////////////////////
    // tokenPriceFeeIncluded
    /////////////////////////////////////////////////////////////////////////
    /**
     * @dev Gets the sale price of the token including the marketplace fee.
     * @param _originContract address of the contract storing the token.
     * @param _tokenId uint256 ID of the token
     * @return uint256 sale price of the token including the fee.
     */
    function tokenPriceFeeIncluded(address _originContract, uint256 _tokenId)
        public
        view
        override
        returns (uint256)
    {
        // The owner of the token must have the marketplace approved
        ownerMustHaveMarketplaceApproved(_originContract, _tokenId); // TODO: Make sure to write test to verify that this returns 0 when it fails

        if (_priceSetterStillOwnsTheToken(_originContract, _tokenId)) {
            return
                tokenPrices[_originContract][_tokenId].amount.add(
                    iMarketplaceSettings.calculateMarketplaceFee(
                        tokenPrices[_originContract][_tokenId].amount
                    )
                );
        }
        return 0;
    }

    /////////////////////////////////////////////////////////////////////////
    // offer
    /////////////////////////////////////////////////////////////////////////
    /**
     * @dev Places an offer on a token.
     * @param _newBidAmount uint256 value in wei to bid.
     * @param _originContract address of the contract storing the token.
     * @param _tokenId uint256 ID of the token
     */
    function offer(
        uint256 _newBidAmount,
        address _originContract,
        uint256 _tokenId
    ) external override payable {
        // Check that bid is greater than 0. Currently removing bid increase requirements for now.
        require(_newBidAmount > 0, "bid::Cannot bid 0 Wei.");

        // Check that enough ether was sent.
        uint256 requiredCost =
            _newBidAmount.add(
                iMarketplaceSettings.calculateMarketplaceFee(_newBidAmount)
            );
        require(
            requiredCost == msg.value,
            "offer::Must purchase the token for the correct price."
        );

        // Check that bidder is not owner.
        IERC721 erc721 = IERC721(_originContract);
        address tokenOwner = erc721.ownerOf(_tokenId);
        require(tokenOwner != msg.sender, "bid::Bidder cannot be owner.");

        // Do not refund previous bidders per the multi-offers spec unless the
        // buyer already had an existing bid, in which case return it
        if (_addressHasBidOnToken(msg.sender, _originContract, _tokenId)) {
            _refundBid(_originContract, msg.sender, _tokenId);
        }

        // Set the new bid.
        _setBid(_newBidAmount, msg.sender, _originContract, _tokenId);

        emit Offer(_originContract, msg.sender, _newBidAmount, _tokenId);
    }

    /////////////////////////////////////////////////////////////////////////
    // safeAcceptOffer
    /////////////////////////////////////////////////////////////////////////
    /**
     * @dev Accept the offer on the token with the expected bid amount.
     * @param _originContract address of the contract storing the token.
     * @param _bidder address of the winning bidder
     * @param _tokenId uint256 ID of the token
     * @param _amount uint256 wei amount of the bid
     */
    function safeAcceptOffer(
        address _originContract,
        address payable _bidder,
        uint256 _tokenId,
        uint256 _amount
    ) external override {
        // Make sure accepting bid is the expected amount
        require(
            tokenCurrentBids[_originContract][_tokenId][_bidder].amount == _amount,
            "safeAcceptOffer::Bid amount must equal expected amount"
        );
        acceptOffer(_originContract, _bidder, _tokenId);
    }

    /////////////////////////////////////////////////////////////////////////
    // acceptOffer
    /////////////////////////////////////////////////////////////////////////
    /**
     * @dev Accept the offer on the token.
     * @param _originContract address of the contract storing the token.
     * @param _bidder address of the winning bidder
     * @param _tokenId uint256 ID of the token
     */
    function acceptOffer(address _originContract, address payable _bidder, uint256 _tokenId)
        public
        override
    {
        // The owner of the token must have the marketplace approved
        ownerMustHaveMarketplaceApproved(_originContract, _tokenId);

        // The sender must be the token owner
        senderMustBeTokenOwner(_originContract, _tokenId);

        // Check that a bid exists for a given address.
        require(
            _tokenHasBidFromBidder(_originContract, _bidder, _tokenId),
            "acceptOffer::No bid from that address."
        );

        // Get current bid on token
        ActiveBid memory currentBid =
            tokenCurrentBids[_originContract][_tokenId][_bidder];

        // Wipe the token price and bid.
        _resetTokenPrice(_originContract, _tokenId);
        // Reset the winning bid
        _resetBid(_originContract, _bidder, _tokenId);
        // Reset and refund all the other bids
        _refundAndResetAllBids(_originContract, _tokenId);

        // Transfer token.
        IERC721 erc721 = IERC721(_originContract);
        erc721.safeTransferFrom(msg.sender, currentBid.bidder, _tokenId);

        // Payout all parties.
        address payable owner = _makePayable(owner());
        Payments.payout(
            currentBid.amount,
            !iMarketplaceSettings.hasERC721TokenSold(_originContract, _tokenId),
            iMarketplaceSettings.getMarketplaceFeePercentage(),
            iERC721CreatorRoyalty.getERC721TokenRoyaltyPercentage(
                _originContract,
                _tokenId
            ),
            iMarketplaceSettings.getERC721ContractPrimarySaleFeePercentage(
                _originContract
            ),
            msg.sender,
            owner,
            iERC721CreatorRoyalty.tokenCreator(_originContract, _tokenId),
            owner
        );

        iMarketplaceSettings.markERC721Token(_originContract, _tokenId, true);

        emit AcceptOffer(
            _originContract,
            currentBid.bidder,
            msg.sender,
            currentBid.amount,
            _tokenId
        );
    }

    /////////////////////////////////////////////////////////////////////////
    // cancelOffer
    /////////////////////////////////////////////////////////////////////////
    /**
     * @dev Cancel the offer on the token.
     * @param _originContract address of the contract storing the token.
     * @param _tokenId uint256 ID of the token.
     */
    function cancelOffer(address _originContract, uint256 _tokenId) external override {
        // Check that the sender has a current bid.
        require(
            _addressHasBidOnToken(msg.sender, _originContract, _tokenId),
            "cancelOffer::Cannot cancel a bid if sender hasn't made one."
        );

        // Refund the bidder.
        _refundBid(_originContract, msg.sender, _tokenId);

        emit CancelOffer(
            _originContract,
            msg.sender,
            tokenCurrentBids[_originContract][_tokenId][msg.sender].amount,
            _tokenId
        );
    }

    /////////////////////////////////////////////////////////////////////////
    // currentBidDetailsOfToken
    /////////////////////////////////////////////////////////////////////////
    /**
     * @dev Function to get current bids and bidders of a token.
     * @param _originContract address of ERC721 contract.
     * @param _tokenId uint256 id of the token.
     * @return address[] bidders
     * @return uint256[] bid amounts
     */
    function currentBidDetailsOfToken(address _originContract, uint256 _tokenId)
        public
        view
        override
        returns (address[] memory, uint256[] memory)
    {
        address[] memory currentBidders = bidders[_originContract][_tokenId];
        uint256[] memory bidAmounts = new uint256[](currentBidders.length);
        // Get bid amounts from the list of bidders
        for (uint i = 0; i < currentBidders.length; i++) {
            bidAmounts[i] = tokenCurrentBids[_originContract][_tokenId][currentBidders[i]].amount;
        }
        return (
            currentBidders,
            bidAmounts
        );
    }

    /////////////////////////////////////////////////////////////////////////
    // _priceSetterStillOwnsTheToken
    /////////////////////////////////////////////////////////////////////////
    /**
     * @dev Checks that the token is owned by the same person who set the sale price.
     * @param _originContract address of the contract storing the token.
     * @param _tokenId uint256 id of the.
     */
    function _priceSetterStillOwnsTheToken(
        address _originContract,
        uint256 _tokenId
    ) public view returns (bool) {
        IERC721 erc721 = IERC721(_originContract);
        return
            erc721.ownerOf(_tokenId) ==
            tokenPrices[_originContract][_tokenId].seller;
    }

    /////////////////////////////////////////////////////////////////////////
    // _resetTokenPrice
    /////////////////////////////////////////////////////////////////////////
    /**
     * @dev public function to set token price to 0 for a given contract.
     * @param _originContract address of ERC721 contract.
     * @param _tokenId uin256 id of the token.
     */
    function _resetTokenPrice(address _originContract, uint256 _tokenId)
        public
    {
        tokenPrices[_originContract][_tokenId] = SalePrice(address(0), 0);
    }

    /////////////////////////////////////////////////////////////////////////
    // _addressHasBidOnToken
    /////////////////////////////////////////////////////////////////////////
    /**
     * @dev public function see if the given address has an existing bid on a token.
     * @param _bidder address that may have a current bid.
     * @param _originContract address of ERC721 contract.
     * @param _tokenId uin256 id of the token.
     */
    function _addressHasBidOnToken(
        address _bidder,
        address _originContract,
        uint256 _tokenId
    ) public view returns (bool) {
        return tokenCurrentBids[_originContract][_tokenId][_bidder].bidder == _bidder;
    }

    /////////////////////////////////////////////////////////////////////////
    // _tokenHasBid
    /////////////////////////////////////////////////////////////////////////
    /**
     * @dev public function see if the token has an existing bid.
     * @param _originContract address of ERC721 contract.
     * @param _bidder address of the bidder
     * @param _tokenId uin256 id of the token.
     */
    function _tokenHasBidFromBidder(address _originContract, address _bidder, uint256 _tokenId)
        public
        view
        returns (bool)
    {
        return tokenCurrentBids[_originContract][_tokenId][_bidder].bidder != address(0);
    }

    /////////////////////////////////////////////////////////////////////////
    // _refundBid
    /////////////////////////////////////////////////////////////////////////
    /**
     * @dev public function to return an existing bid on a token to the
     *      bidder and reset bid.
     * @param _originContract address of ERC721 contract.
     * @param _bidder address of the bidder.
     * @param _tokenId uin256 id of the token.
     */
    function _refundBid(address _originContract, address payable _bidder, uint256 _tokenId) public {
        ActiveBid memory currentBid =
            tokenCurrentBids[_originContract][_tokenId][_bidder];
        if (currentBid.bidder == address(0)) {
            return;
        }
        _resetBid(_originContract, _bidder, _tokenId);
        Payments.refund(
            currentBid.marketplaceFee,
            currentBid.bidder,
            currentBid.amount
        );
    }

    /////////////////////////////////////////////////////////////////////////
    // _resetBid
    /////////////////////////////////////////////////////////////////////////
    /**
     * @dev public function to reset bid by setting bidder and bid to 0.
     * @param _originContract address of ERC721 contract.
     * @param _tokenId uin256 id of the token.
     */
    function _resetBid(address _originContract, address _bidder, uint256 _tokenId) public {
        tokenCurrentBids[_originContract][_tokenId][_bidder] = ActiveBid(
            address(0),
            0,
            0
        );
        _removeBidder(_originContract, _bidder, _tokenId);
    }

    /////////////////////////////////////////////////////////////////////////
    // _refundAndResetAllBids
    /////////////////////////////////////////////////////////////////////////
    /**
     * @dev public function to reset and refunds all bids for a token.
     * @param _originContract address of ERC721 contract.
     * @param _tokenId uin256 id of the token.
     */
    function _refundAndResetAllBids(address _originContract, uint256 _tokenId) public {
        address[] memory currentBidders = bidders[_originContract][_tokenId];
        for (uint i = 0; i < currentBidders.length; i++) {
            ActiveBid memory currentBid =
                tokenCurrentBids[_originContract][_tokenId][currentBidders[i]];
            // Clear the bid
            tokenCurrentBids[_originContract][_tokenId][currentBidders[i]] = ActiveBid(
                address(0),
                0,
                0
            );
            // Refund bid
            Payments.refund(
                currentBid.marketplaceFee,
                currentBid.bidder,
                currentBid.amount
            );
        }
        delete bidders[_originContract][_tokenId];
    }

    /////////////////////////////////////////////////////////////////////////
    // _setBid
    /////////////////////////////////////////////////////////////////////////
    /**
     * @dev public function to set a bid.
     * @param _amount uint256 value in wei to bid. Does not include marketplace fee.
     * @param _bidder address of the bidder.
     * @param _originContract address of ERC721 contract.
     * @param _tokenId uin256 id of the token.
     */
    function _setBid(
        uint256 _amount,
        address payable _bidder,
        address _originContract,
        uint256 _tokenId
    ) public {
        // Check bidder not 0 address.
        require(_bidder != address(0), "Bidder cannot be 0 address.");

        // Check if user has bidded before and if not, add to list of bidders
        if (tokenCurrentBids[_originContract][_tokenId][_bidder].bidder == address(0)) {
            bidders[_originContract][_tokenId].push(_bidder);
        }
        // Set bid.
        tokenCurrentBids[_originContract][_tokenId][_bidder] = ActiveBid(
            _bidder,
            iMarketplaceSettings.getMarketplaceFeePercentage(),
            _amount
        );
    }

    /////////////////////////////////////////////////////////////////////////
    // _makePayable
    /////////////////////////////////////////////////////////////////////////
    /**
     * @dev public function to set a bid.
     * @param _address non-payable address
     * @return payable address
     */
    function _makePayable(address _address)
        public
        pure
        returns (address payable)
    {
        return address(uint160(_address));
    }

    /////////////////////////////////////////////////////////////////////////
    // _removeBidder
    /////////////////////////////////////////////////////////////////////////
    /**
     * @dev public function to remove a single bid from the bidders array for a token.
     * @param _originContract address of ERC721 contract.
     * @param _bidder address of the bidder to be removed
     * @param _tokenId uin256 id of the token.
     */
    function _removeBidder(address _originContract, address _bidder, uint256 _tokenId) public {
        address[] memory currentBidders = bidders[_originContract][_tokenId];
        if (currentBidders.length > 1) {
            uint i = 0;
            while (currentBidders[i] != _bidder) {
                i++;
            }
            bidders[_originContract][_tokenId][i] = currentBidders[currentBidders.length-1];
        }
        bidders[_originContract][_tokenId].pop();
    }

    /////////////////////////////////////////////////////////////////////////
    // getHighestBidderAndBid
    /////////////////////////////////////////////////////////////////////////
    /**
     * @dev Gets the highest bidder and bid amount for a token.
     * @param _originContract address of ERC721 contract.
     * @param _tokenId uin256 id of the token.
     * @return address highest bidder
     * @return uint256 highest bid amount
     */
    function getHighestBidderAndBid(address _originContract, uint256 _tokenId)
        external
        view
        override
        returns (address payable, uint256)
    {
        if (bidders[_originContract][_tokenId].length == 0) {
            return (address(0), 0);
        }
        address[] memory currentBidders = bidders[_originContract][_tokenId];
        ActiveBid memory highestBid = tokenCurrentBids[_originContract][_tokenId][currentBidders[0]];
        for (uint i = 1; i < currentBidders.length; i++) {
            if (tokenCurrentBids[_originContract][_tokenId][currentBidders[i]].amount > highestBid.amount) {
                highestBid = tokenCurrentBids[_originContract][_tokenId][currentBidders[i]];
            }
        }
        return (highestBid.bidder, highestBid.amount);
    }

}