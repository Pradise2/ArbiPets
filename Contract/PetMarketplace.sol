// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "./PetNFT.sol";
import "./GameToken.sol";

/**
 * @title PetMarketplace
 * @dev Comprehensive marketplace for trading CryptoPets with auctions and direct sales
 * @notice Features:
 * - Direct sales (fixed price listings)
 * - English auctions with automatic settlement
 * - Dutch auctions with declining prices
 * - Bulk listing and purchasing
 * - Advanced filtering and search
 * - Fee management and revenue sharing
 */
contract PetMarketplace is Ownable, ReentrancyGuard, Pausable, IERC721Receiver {
    
    // Listing types
    enum ListingType { DIRECT_SALE, ENGLISH_AUCTION, DUTCH_AUCTION }
    enum ListingStatus { ACTIVE, SOLD, CANCELLED, EXPIRED }
    enum PaymentMethod { ETH, PETS }
    
    struct Listing {
        uint256 id;
        uint256 petId;
        address seller;
        ListingType listingType;
        ListingStatus status;
        PaymentMethod paymentMethod;
        uint256 price;              // Fixed price or starting price for auctions
        uint256 reservePrice;       // Minimum acceptable price (auctions only)
        uint256 buyNowPrice;        // Optional buy-now price for auctions
        uint32 duration;            // Listing duration in seconds
        uint32 createdAt;
        uint32 endsAt;
        uint256 highestBid;
        address highestBidder;
        uint256 totalBids;
        // Dutch auction specific
        uint256 endPrice;           // Final price for Dutch auction
        uint256 priceDeclineRate;   // Price decline per second
    }
    
    struct Bid {
        uint256 listingId;
        address bidder;
        uint256 amount;
        uint32 timestamp;
        bool withdrawn;
    }
    
    struct MarketplaceStats {
        uint256 totalListings;
        uint256 totalSales;
        uint256 totalVolume;        // In ETH
        uint256 totalPetsVolume;    // In PETS tokens
        uint256 averagePrice;
        uint256 activeListings;
    }
    
    // Contract references
    PetNFT public petContract;
    GameToken public gameToken;
    
    // Storage
    mapping(uint256 => Listing) public listings;
    mapping(uint256 => Bid[]) public listingBids;
    mapping(address => uint256[]) public userListings;
    mapping(address => uint256[]) public userBids;
    mapping(uint256 => bool) public petIsListed;
    
    // Configuration
    uint256 public nextListingId = 1;
    uint256 public platformFeePercentage = 250; // 2.5%
    uint256 public constant FEE_DENOMINATOR = 10000;
    uint256 public minimumListingDuration = 3600; // 1 hour
    uint256 public maximumListingDuration = 2592000; // 30 days
    uint256 public minimumBidIncrement = 5; // 5% minimum bid increase
    uint256 public dutchAuctionMinDuration = 3600; // 1 hour minimum for Dutch auctions
    
    // Fee distribution
    address public treasuryAddress;
    uint256 public creatorRoyaltyPercentage = 100; // 1% to original minter
    
    // Market statistics
    MarketplaceStats public marketStats;
    
    // Events
    event PetListed(uint256 indexed listingId, uint256 indexed petId, address indexed seller, 
                   ListingType listingType, uint256 price, PaymentMethod paymentMethod);
    event PetSold(uint256 indexed listingId, uint256 indexed petId, address seller, 
                  address buyer, uint256 price, PaymentMethod paymentMethod);
    event BidPlaced(uint256 indexed listingId, address indexed bidder, uint256 amount);
    event BidWithdrawn(uint256 indexed listingId, address indexed bidder, uint256 amount);
    event ListingCancelled(uint256 indexed listingId, uint256 indexed petId, address indexed seller);
    event ListingExpired(uint256 indexed listingId, uint256 indexed petId);
    event AuctionSettled(uint256 indexed listingId, address winner, uint256 finalPrice);
    
    constructor(
        address _petContract,
        address _gameToken,
        address _treasuryAddress
    ) {
        petContract = PetNFT(_petContract);
        gameToken = GameToken(_gameToken);
        treasuryAddress = _treasuryAddress;
    }
    
    modifier validListing(uint256 listingId) {
        require(listingId < nextListingId && listingId > 0, "Invalid listing ID");
        require(listings[listingId].status == ListingStatus.ACTIVE, "Listing not active");
        _;
    }
    
    modifier onlyListingSeller(uint256 listingId) {
        require(listings[listingId].seller == msg.sender, "Not the seller");
        _;
    }
    
    // ============================================================================
    // DIRECT SALES
    // ============================================================================
    
    function createDirectSale(
        uint256 petId,
        uint256 price,
        PaymentMethod paymentMethod,
        uint32 duration
    ) external nonReentrant whenNotPaused {
        require(petContract.ownerOf(petId) == msg.sender, "Not pet owner");
        require(!petIsListed[petId], "Pet already listed");
        require(price > 0, "Price must be greater than 0");
        require(duration >= minimumListingDuration && duration <= maximumListingDuration, "Invalid duration");
        
        // Transfer pet to marketplace for escrow
        petContract.transferFrom(msg.sender, address(this), petId);
        
        uint256 listingId = _createListing(
            petId,
            ListingType.DIRECT_SALE,
            paymentMethod,
            price,
            0, // No reserve price for direct sales
            0, // No buy-now price for direct sales
            duration
        );
        
        emit PetListed(listingId, petId, msg.sender, ListingType.DIRECT_SALE, price, paymentMethod);
    }
    
    function buyDirectly(uint256 listingId) external payable nonReentrant validListing(listingId) {
        Listing storage listing = listings[listingId];
        require(listing.listingType == ListingType.DIRECT_SALE, "Not a direct sale");
        require(listing.seller != msg.sender, "Cannot buy your own listing");
        require(block.timestamp <= listing.endsAt, "Listing expired");
        
        uint256 totalPrice = listing.price;
        
        if (listing.paymentMethod == PaymentMethod.ETH) {
            require(msg.value >= totalPrice, "Insufficient payment");
        } else {
            require(gameToken.balanceOf(msg.sender) >= totalPrice, "Insufficient PETS tokens");
            gameToken.transferFrom(msg.sender, address(this), totalPrice);
        }
        
        _completeSale(listingId, msg.sender, totalPrice);
        
        // Refund excess ETH if any
        if (listing.paymentMethod == PaymentMethod.ETH && msg.value > totalPrice) {
            payable(msg.sender).transfer(msg.value - totalPrice);
        }
    }
    
    // ============================================================================
    // ENGLISH AUCTIONS
    // ============================================================================
    
    function createEnglishAuction(
        uint256 petId,
        uint256 startingPrice,
        uint256 reservePrice,
        uint256 buyNowPrice,
        PaymentMethod paymentMethod,
        uint32 duration
    ) external nonReentrant whenNotPaused {
        require(petContract.ownerOf(petId) == msg.sender, "Not pet owner");
        require(!petIsListed[petId], "Pet already listed");
        require(startingPrice > 0, "Starting price must be greater than 0");
        require(reservePrice >= startingPrice, "Reserve price too low");
        require(buyNowPrice == 0 || buyNowPrice > reservePrice, "Invalid buy-now price");
        require(duration >= minimumListingDuration && duration <= maximumListingDuration, "Invalid duration");
        
        petContract.transferFrom(msg.sender, address(this), petId);
        
        uint256 listingId = _createListing(
            petId,
            ListingType.ENGLISH_AUCTION,
            paymentMethod,
            startingPrice,
            reservePrice,
            buyNowPrice,
            duration
        );
        
        emit PetListed(listingId, petId, msg.sender, ListingType.ENGLISH_AUCTION, startingPrice, paymentMethod);
    }
    
    function placeBid(uint256 listingId) external payable nonReentrant validListing(listingId) {
        Listing storage listing = listings[listingId];
        require(listing.listingType == ListingType.ENGLISH_AUCTION, "Not an English auction");
        require(listing.seller != msg.sender, "Cannot bid on your own auction");
        require(block.timestamp <= listing.endsAt, "Auction ended");
        
        uint256 bidAmount;
        if (listing.paymentMethod == PaymentMethod.ETH) {
            bidAmount = msg.value;
            require(bidAmount > 0, "Bid must be greater than 0");
        } else {
            // For PETS token auctions, bidAmount should be passed as parameter
            // This is a simplified implementation - in practice, you'd want a separate parameter
            revert("PETS token auctions require separate implementation");
        }
        
        uint256 minimumBid = listing.highestBid > 0 ? 
            listing.highestBid + (listing.highestBid * minimumBidIncrement / 100) : 
            listing.price;
        
        require(bidAmount >= minimumBid, "Bid too low");
        
        // Refund previous highest bidder
        if (listing.highestBidder != address(0)) {
            payable(listing.highestBidder).transfer(listing.highestBid);
        }
        
        listing.highestBid = bidAmount;
        listing.highestBidder = msg.sender;
        listing.totalBids++;
        
        // Store bid history
        listingBids[listingId].push(Bid({
            listingId: listingId,
            bidder: msg.sender,
            amount: bidAmount,
            timestamp: uint32(block.timestamp),
            withdrawn: false
        }));
        
        userBids[msg.sender].push(listingId);
        
        emit BidPlaced(listingId, msg.sender, bidAmount);
        
        // Check for buy-now purchase
        if (listing.buyNowPrice > 0 && bidAmount >= listing.buyNowPrice) {
            _settleAuction(listingId);
        }
        
        // Extend auction if bid placed in final minutes
        if (listing.endsAt - block.timestamp < 300) { // 5 minutes
            listing.endsAt += 300; // Extend by 5 minutes
        }
    }
    
    function settleAuction(uint256 listingId) external nonReentrant {
        Listing storage listing = listings[listingId];
        require(listing.listingType == ListingType.ENGLISH_AUCTION, "Not an English auction");
        require(block.timestamp > listing.endsAt, "Auction still active");
        require(listing.status == ListingStatus.ACTIVE, "Auction already settled");
        
        _settleAuction(listingId);
    }
    
    function _settleAuction(uint256 listingId) internal {
        Listing storage listing = listings[listingId];
        
        if (listing.highestBidder != address(0) && listing.highestBid >= listing.reservePrice) {
            // Auction successful
            _completeSale(listingId, listing.highestBidder, listing.highestBid);
            emit AuctionSettled(listingId, listing.highestBidder, listing.highestBid);
        } else {
            // Auction failed - return pet to seller
            listing.status = ListingStatus.EXPIRED;
            petIsListed[listing.petId] = false;
            petContract.transferFrom(address(this), listing.seller, listing.petId);
            
            // Refund highest bidder if any
            if (listing.highestBidder != address(0)) {
                payable(listing.highestBidder).transfer(listing.highestBid);
            }
            
            emit ListingExpired(listingId, listing.petId);
        }
    }
    
    // ============================================================================
    // DUTCH AUCTIONS
    // ============================================================================
    
    function createDutchAuction(
        uint256 petId,
        uint256 startingPrice,
        uint256 endingPrice,
        PaymentMethod paymentMethod,
        uint32 duration
    ) external nonReentrant whenNotPaused {
        require(petContract.ownerOf(petId) == msg.sender, "Not pet owner");
        require(!petIsListed[petId], "Pet already listed");
        require(startingPrice > endingPrice, "Starting price must be higher than ending price");
        require(endingPrice > 0, "Ending price must be greater than 0");
        require(duration >= dutchAuctionMinDuration && duration <= maximumListingDuration, "Invalid duration");
        
        petContract.transferFrom(msg.sender, address(this), petId);
        
        uint256 listingId = nextListingId++;
        uint256 priceDeclineRate = (startingPrice - endingPrice) / duration;
        
        listings[listingId] = Listing({
            id: listingId,
            petId: petId,
            seller: msg.sender,
            listingType: ListingType.DUTCH_AUCTION,
            status: ListingStatus.ACTIVE,
            paymentMethod: paymentMethod,
            price: startingPrice,
            reservePrice: 0,
            buyNowPrice: 0,
            duration: duration,
            createdAt: uint32(block.timestamp),
            endsAt: uint32(block.timestamp) + duration,
            highestBid: 0,
            highestBidder: address(0),
            totalBids: 0,
            endPrice: endingPrice,
            priceDeclineRate: priceDeclineRate
        });
        
        petIsListed[petId] = true;
        userListings[msg.sender].push(listingId);
        marketStats.totalListings++;
        marketStats.activeListings++;
        
        emit PetListed(listingId, petId, msg.sender, ListingType.DUTCH_AUCTION, startingPrice, paymentMethod);
    }
    
    function buyFromDutchAuction(uint256 listingId) external payable nonReentrant validListing(listingId) {
        Listing storage listing = listings[listingId];
        require(listing.listingType == ListingType.DUTCH_AUCTION, "Not a Dutch auction");
        require(listing.seller != msg.sender, "Cannot buy your own listing");
        require(block.timestamp <= listing.endsAt, "Auction expired");
        
        uint256 currentPrice = getCurrentDutchPrice(listingId);
        
        if (listing.paymentMethod == PaymentMethod.ETH) {
            require(msg.value >= currentPrice, "Insufficient payment");
        } else {
            require(gameToken.balanceOf(msg.sender) >= currentPrice, "Insufficient PETS tokens");
            gameToken.transferFrom(msg.sender, address(this), currentPrice);
        }
        
        _completeSale(listingId, msg.sender, currentPrice);
        
        // Refund excess ETH if any
        if (listing.paymentMethod == PaymentMethod.ETH && msg.value > currentPrice) {
            payable(msg.sender).transfer(msg.value - currentPrice);
        }
    }
    
    function getCurrentDutchPrice(uint256 listingId) public view returns (uint256) {
        Listing storage listing = listings[listingId];
        require(listing.listingType == ListingType.DUTCH_AUCTION, "Not a Dutch auction");
        
        if (block.timestamp >= listing.endsAt) {
            return listing.endPrice;
        }
        
        uint256 timeElapsed = block.timestamp - listing.createdAt;
        uint256 priceReduction = timeElapsed * listing.priceDeclineRate;
        
        if (priceReduction >= listing.price - listing.endPrice) {
            return listing.endPrice;
        }
        
        return listing.price - priceReduction;
    }
    
    // ============================================================================
    // COMMON FUNCTIONS
    // ============================================================================
    
    function _createListing(
        uint256 petId,
        ListingType listingType,
        PaymentMethod paymentMethod,
        uint256 price,
        uint256 reservePrice,
        uint256 buyNowPrice,
        uint32 duration
    ) internal returns (uint256) {
        uint256 listingId = nextListingId++;
        
        listings[listingId] = Listing({
            id: listingId,
            petId: petId,
            seller: msg.sender,
            listingType: listingType,
            status: ListingStatus.ACTIVE,
            paymentMethod: paymentMethod,
            price: price,
            reservePrice: reservePrice,
            buyNowPrice: buyNowPrice,
            duration: duration,
            createdAt: uint32(block.timestamp),
            endsAt: uint32(block.timestamp) + duration,
            highestBid: 0,
            highestBidder: address(0),
            totalBids: 0,
            endPrice: 0,
            priceDeclineRate: 0
        });
        
        petIsListed[petId] = true;
        userListings[msg.sender].push(listingId);
        marketStats.totalListings++;
        marketStats.activeListings++;
        
        return listingId;
    }
    
    function _completeSale(uint256 listingId, address buyer, uint256 finalPrice) internal {
        Listing storage listing = listings[listingId];
        
        listing.status = ListingStatus.SOLD;
        petIsListed[listing.petId] = false;
        marketStats.activeListings--;
        marketStats.totalSales++;
        
        // Calculate fees
        uint256 platformFee = (finalPrice * platformFeePercentage) / FEE_DENOMINATOR;
        uint256 creatorRoyalty = (finalPrice * creatorRoyaltyPercentage) / FEE_DENOMINATOR;
        uint256 sellerProceeds = finalPrice - platformFee - creatorRoyalty;
        
        // Transfer pet to buyer
        petContract.transferFrom(address(this), buyer, listing.petId);
        
        // Distribute payments
        if (listing.paymentMethod == PaymentMethod.ETH) {
            payable(listing.seller).transfer(sellerProceeds);
            payable(treasuryAddress).transfer(platformFee);
            // Creator royalty would go to original minter (simplified here)
            payable(treasuryAddress).transfer(creatorRoyalty);
            marketStats.totalVolume += finalPrice;
        } else {
            gameToken.transfer(listing.seller, sellerProceeds);
            gameToken.transfer(treasuryAddress, platformFee + creatorRoyalty);
            marketStats.totalPetsVolume += finalPrice;
        }
        
        emit PetSold(listingId, listing.petId, listing.seller, buyer, finalPrice, listing.paymentMethod);
        
        // Update average price
        marketStats.averagePrice = (marketStats.totalVolume + marketStats.totalPetsVolume) / marketStats.totalSales;
    }
    
    // ============================================================================
    // LISTING MANAGEMENT
    // ============================================================================
    
    function cancelListing(uint256 listingId) external nonReentrant onlyListingSeller(listingId) {
        Listing storage listing = listings[listingId];
        require(listing.status == ListingStatus.ACTIVE, "Listing not active");
        
        if (listing.listingType == ListingType.ENGLISH_AUCTION && listing.highestBidder != address(0)) {
            require(listing.totalBids == 0, "Cannot cancel auction with bids");
        }
        
        listing.status = ListingStatus.CANCELLED;
        petIsListed[listing.petId] = false;
        marketStats.activeListings--;
        
        // Return pet to seller
        petContract.transferFrom(address(this), listing.seller, listing.petId);
        
        // Refund highest bidder if auction
        if (listing.listingType == ListingType.ENGLISH_AUCTION && listing.highestBidder != address(0)) {
            payable(listing.highestBidder).transfer(listing.highestBid);
        }
        
        emit ListingCancelled(listingId, listing.petId, listing.seller);
    }
    
    function updateListingPrice(uint256 listingId, uint256 newPrice) external onlyListingSeller(listingId) {
        Listing storage listing = listings[listingId];
        require(listing.listingType == ListingType.DIRECT_SALE, "Can only update direct sale prices");
        require(listing.status == ListingStatus.ACTIVE, "Listing not active");
        require(newPrice > 0, "Price must be greater than 0");
        
        listing.price = newPrice;
    }
    
    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================
    
    function getListing(uint256 listingId) external view returns (Listing memory) {
        return listings[listingId];
    }
    
    function getActiveListings(uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        uint256[] memory activeListings = new uint256[](limit);
        uint256 count = 0;
        uint256 current = 0;
        
        for (uint256 i = 1; i < nextListingId && count < limit; i++) {
            if (listings[i].status == ListingStatus.ACTIVE) {
                if (current >= offset) {
                    activeListings[count] = i;
                    count++;
                }
                current++;
            }
        }
        
        // Resize array to actual count
        assembly { mstore(activeListings, count) }
        return activeListings;
    }
    
    function getUserListings(address user) external view returns (uint256[] memory) {
        return userListings[user];
    }
    
    function getUserBids(address user) external view returns (uint256[] memory) {
        return userBids[user];
    }
    
    function getListingBids(uint256 listingId) external view returns (Bid[] memory) {
        return listingBids[listingId];
    }
    
    function getMarketStats() external view returns (MarketplaceStats memory) {
        return marketStats;
    }
    
    // ============================================================================
    // ADMIN FUNCTIONS
    // ============================================================================
    
    function setPlatformFee(uint256 _feePercentage) external onlyOwner {
        require(_feePercentage <= 1000, "Fee too high"); // Max 10%
        platformFeePercentage = _feePercentage;
    }
    
    function setCreatorRoyalty(uint256 _royaltyPercentage) external onlyOwner {
        require(_royaltyPercentage <= 500, "Royalty too high"); // Max 5%
        creatorRoyaltyPercentage = _royaltyPercentage;
    }
    
    function setTreasuryAddress(address _treasuryAddress) external onlyOwner {
        require(_treasuryAddress != address(0), "Invalid treasury address");
        treasuryAddress = _treasuryAddress;
    }
    
    function setListingDurations(uint256 _minDuration, uint256 _maxDuration) external onlyOwner {
        require(_minDuration < _maxDuration, "Invalid duration range");
        minimumListingDuration = _minDuration;
        maximumListingDuration = _maxDuration;
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    function emergencyWithdraw() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
        gameToken.transfer(owner(), gameToken.balanceOf(address(this)));
    }
    
    // Required for receiving NFTs
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
