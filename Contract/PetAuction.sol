// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "./PetNFT.sol";
import "./GameToken.sol";
import "./Random.sol";

/**
 * @title PetAuction
 * @dev Specialized auction house with unique mechanics for CryptoPets
 * @notice Features:
 * - Mystery box auctions (blind bidding on unknown pets)
 * - Breeding rights auctions (temporary breeding access)
 * - Trait-specific auctions with filters
 * - Group auctions (multiple pets in one auction)
 * - Reverse auctions (seller competition)
 * - Charity auctions with donation matching
 * - Sniping protection with time extensions
 * - Bid mining rewards for participation
 */
contract PetAuction is Ownable, ReentrancyGuard, Pausable, IERC721Receiver, IRandomnessConsumer {
    
    enum AuctionType {
        STANDARD,           // Regular auction
        MYSTERY_BOX,        // Hidden pet details until auction ends
        BREEDING_RIGHTS,    // Temporary breeding access auction
        GROUP_AUCTION,      // Multiple pets in one auction
        REVERSE_AUCTION,    // Multiple sellers, buyers choose
        CHARITY,            // Proceeds go to charity
        FLASH_AUCTION,      // Very short duration with bonuses
        TRAIT_SPECIFIC      // Auctions filtered by specific traits
    }
    
    enum AuctionStatus {
        ACTIVE,
        ENDED,
        CANCELLED,
        MYSTERY_REVEALING,  // Mystery box in reveal phase
        CHARITY_MATCHING    // Charity auction in matching phase
    }
    
    struct Auction {
        uint256 id;
        AuctionType auctionType;
        AuctionStatus status;
        address seller;
        uint256[] petIds;           // Multiple pets for group auctions
        uint256 startingBid;
        uint256 currentBid;
        address currentBidder;
        uint256 bidCount;
        uint32 startTime;
        uint32 endTime;
        uint32 originalEndTime;     // For tracking extensions
        bool hasReservePrice;
        uint256 reservePrice;
        bool reserveMet;
        // Mystery box specific
        bytes32 mysteryHash;        // Hash of hidden details
        bool mysteryRevealed;
        uint256 revealRandomnessId;
        // Breeding rights specific
        uint32 breedingDuration;    // How long buyer gets breeding rights
        uint8 maxBreedings;         // Max number of breedings allowed
        // Charity specific
        address charityAddress;
        uint256 charityPercentage;  // Percentage going to charity
        uint256 matchingPool;       // Additional matching funds
        // Group auction specific
        uint256 minGroupSize;       // Minimum pets to sell
        mapping(uint256 => bool) individualReserves; // Per-pet reserves
    }
    
    struct Bid {
        address bidder;
        uint256 amount;
        uint32 timestamp;
        bool isAutomatic;           // From autobid system
        uint256 maxBid;             // For proxy bidding
    }
    
    struct MysteryBoxTemplate {
        string name;
        uint8 minRarity;
        uint8 maxRarity;
        uint8[] possibleElements;
        uint16 minLevel;
        uint16 maxLevel;
        string[] guaranteedTraits;
        uint256 revealDelay;        // Time before reveal after auction end
    }
    
    struct BreedingRights {
        uint256 auctionId;
        uint256 petId;
        address rightsHolder;
        uint32 expiresAt;
        uint8 breedingsUsed;
        uint8 maxBreedings;
        bool active;
    }
    
    struct ReverseAuction {
        uint256 id;
        address buyer;
        string petRequirements;     // JSON string of requirements
        uint256 maxPrice;
        uint32 endTime;
        uint256 offerCount;
        uint256 bestOfferId;
        address bestSeller;
        mapping(address => uint256) sellerOffers; // seller => offer amount
    }
    
    struct TraitFilter {
        string traitName;
        bool required;              // Must have this trait
        uint8 minValue;             // For numeric traits
        uint8 maxValue;             // For numeric traits
    }
    
    // Contract references
    PetNFT public petContract;
    GameToken public gameToken;
    Random public randomContract;
    
    // Storage
    mapping(uint256 => Auction) public auctions;
    mapping(uint256 => Bid[]) public auctionBids;
    mapping(uint256 => MysteryBoxTemplate) public mysteryTemplates;
    mapping(uint256 => BreedingRights) public breedingRights;
    mapping(uint256 => ReverseAuction) public reverseAuctions;
    mapping(uint256 => uint256) public randomRequestToAuction;
    
    // Auction management
    uint256 public nextAuctionId = 1;
    uint256 public nextReverseAuctionId = 1;
    uint256 public nextMysteryTemplateId = 1;
    uint256[] public activeAuctions;
    uint256[] public endedAuctions;
    
    // Auto-bidding system
    mapping(address => mapping(uint256 => uint256)) public autoBidLimits; // user => auction => max bid
    mapping(address => uint256) public bidMiningRewards; // Rewards for active bidding
    
    // Platform configuration
    uint256 public platformFeePercentage = 250; // 2.5%
    uint256 public minimumBidIncrement = 50; // 5%
    uint256 public snipeProtectionTime = 300; // 5 minutes
    uint256 public maxTimeExtension = 1800; // 30 minutes max extension
    address public treasuryAddress;
    address public charityMatchingPool;
    
    // Bid mining configuration
    uint256 public bidMiningRate = 10 * 10**18; // 10 PETS per bid
    uint256 public dailyBidMiningCap = 500 * 10**18; // 500 PETS per day max
    mapping(address => uint256) public dailyBidMiningEarned;
    mapping(address => uint32) public lastBidMiningReset;
    
    // Events
    event AuctionCreated(uint256 indexed auctionId, AuctionType auctionType, address indexed seller, uint256[] petIds);
    event BidPlaced(uint256 indexed auctionId, address indexed bidder, uint256 amount, bool isAutomatic);
    event AuctionEnded(uint256 indexed auctionId, address winner, uint256 finalPrice);
    event AuctionExtended(uint256 indexed auctionId, uint32 newEndTime, uint32 extensionTime);
    event MysteryBoxRevealed(uint256 indexed auctionId, uint256 petId, uint8 rarity, uint8 element);
    event BreedingRightsGranted(uint256 indexed auctionId, address indexed buyer, uint256 petId, uint32 duration);
    event CharityDonation(uint256 indexed auctionId, address charity, uint256 amount, uint256 matchedAmount);
    event BidMiningReward(address indexed bidder, uint256 reward);
    event ReverseAuctionCreated(uint256 indexed reverseAuctionId, address indexed buyer, uint256 maxPrice);
    
    constructor(
        address _petContract,
        address _gameToken,
        address _randomContract,
        address _treasuryAddress,
        address _charityMatchingPool
    ) {
        petContract = PetNFT(_petContract);
        gameToken = GameToken(_gameToken);
        randomContract = Random(_randomContract);
        treasuryAddress = _treasuryAddress;
        charityMatchingPool = _charityMatchingPool;
        
        _createDefaultMysteryTemplates();
    }
    
    function _createDefaultMysteryTemplates() internal {
        // Common mystery box
        mysteryTemplates[nextMysteryTemplateId] = MysteryBoxTemplate({
            name: "Common Mystery Box",
            minRarity: 0,
            maxRarity: 1,
            possibleElements: [0, 1, 2, 3], // Fire, Water, Earth, Air
            minLevel: 1,
            maxLevel: 25,
            guaranteedTraits: new string[](0),
            revealDelay: 300 // 5 minutes
        });
        nextMysteryTemplateId++;
        
        // Legendary mystery box
        mysteryTemplates[nextMysteryTemplateId] = MysteryBoxTemplate({
            name: "Legendary Mystery Box",
            minRarity: 2,
            maxRarity: 3,
            possibleElements: [4, 5, 6, 7], // Electric, Mystic, Light, Dark
            minLevel: 25,
            maxLevel: 100,
            guaranteedTraits: new string[](1),
            revealDelay: 600 // 10 minutes
        });
        mysteryTemplates[nextMysteryTemplateId].guaranteedTraits[0] = "Ancient";
        nextMysteryTemplateId++;
    }
    
    // ============================================================================
    // STANDARD AUCTIONS
    // ============================================================================
    
    function createStandardAuction(
        uint256 petId,
        uint256 startingBid,
        uint256 reservePrice,
        uint32 duration
    ) external nonReentrant whenNotPaused returns (uint256) {
        require(petContract.ownerOf(petId) == msg.sender, "Not pet owner");
        require(startingBid > 0, "Invalid starting bid");
        require(duration >= 3600 && duration <= 604800, "Invalid duration"); // 1 hour to 1 week
        
        uint256 auctionId = nextAuctionId++;
        uint32 endTime = uint32(block.timestamp) + duration;
        
        // Create auction
        auctions[auctionId].id = auctionId;
        auctions[auctionId].auctionType = AuctionType.STANDARD;
        auctions[auctionId].status = AuctionStatus.ACTIVE;
        auctions[auctionId].seller = msg.sender;
        auctions[auctionId].petIds.push(petId);
        auctions[auctionId].startingBid = startingBid;
        auctions[auctionId].currentBid = 0;
        auctions[auctionId].startTime = uint32(block.timestamp);
        auctions[auctionId].endTime = endTime;
        auctions[auctionId].originalEndTime = endTime;
        auctions[auctionId].hasReservePrice = reservePrice > 0;
        auctions[auctionId].reservePrice = reservePrice;
        
        // Transfer pet to auction contract
        petContract.transferFrom(msg.sender, address(this), petId);
        
        activeAuctions.push(auctionId);
        
        emit AuctionCreated(auctionId, AuctionType.STANDARD, msg.sender, auctions[auctionId].petIds);
        return auctionId;
    }
    
    function placeBid(uint256 auctionId, uint256 bidAmount) external nonReentrant whenNotPaused {
        _placeBid(auctionId, msg.sender, bidAmount, false, 0);
    }
    
    function placeAutoBid(uint256 auctionId, uint256 bidAmount, uint256 maxBid) external nonReentrant whenNotPaused {
        require(maxBid >= bidAmount, "Max bid must be >= current bid");
        autoBidLimits[msg.sender][auctionId] = maxBid;
        _placeBid(auctionId, msg.sender, bidAmount, true, maxBid);
    }
    
    function _placeBid(uint256 auctionId, address bidder, uint256 bidAmount, bool isAutomatic, uint256 maxBid) internal {
        Auction storage auction = auctions[auctionId];
        require(auction.status == AuctionStatus.ACTIVE, "Auction not active");
        require(block.timestamp < auction.endTime, "Auction ended");
        require(bidder != auction.seller, "Seller cannot bid");
        require(bidAmount >= auction.startingBid, "Bid below starting price");
        
        // Calculate minimum bid required
        uint256 minBid = auction.currentBid == 0 ? 
            auction.startingBid : 
            auction.currentBid + (auction.currentBid * minimumBidIncrement / 1000);
        
        require(bidAmount >= minBid, "Bid increment too small");
        require(gameToken.balanceOf(bidder) >= bidAmount, "Insufficient balance");
        
        // Refund previous bidder
        if (auction.currentBidder != address(0)) {
            gameToken.transfer(auction.currentBidder, auction.currentBid);
        }
        
        // Collect new bid
        gameToken.transferFrom(bidder, address(this), bidAmount);
        
        // Update auction
        auction.currentBid = bidAmount;
        auction.currentBidder = bidder;
        auction.bidCount++;
        
        // Check reserve price
        if (auction.hasReservePrice && bidAmount >= auction.reservePrice) {
            auction.reserveMet = true;
        }
        
        // Store bid history
        auctionBids[auctionId].push(Bid({
            bidder: bidder,
            amount: bidAmount,
            timestamp: uint32(block.timestamp),
            isAutomatic: isAutomatic,
            maxBid: maxBid
        }));
        
        // Sniping protection - extend auction if bid placed in final minutes
        if (auction.endTime - block.timestamp < snipeProtectionTime) {
            uint32 extension = snipeProtectionTime;
            if (auction.endTime + extension > auction.originalEndTime + maxTimeExtension) {
                extension = auction.originalEndTime + uint32(maxTimeExtension) - auction.endTime;
            }
            
            if (extension > 0) {
                auction.endTime += extension;
                emit AuctionExtended(auctionId, auction.endTime, extension);
            }
        }
        
        // Award bid mining rewards
        _awardBidMiningReward(bidder);
        
        emit BidPlaced(auctionId, bidder, bidAmount, isAutomatic);
        
        // Trigger automatic counter-bids
        _processAutomaticBids(auctionId);
    }
    
    function _processAutomaticBids(uint256 auctionId) internal {
        Auction storage auction = auctions[auctionId];
        
        // Find users with auto-bid limits higher than current bid
        // Simplified implementation - in production, maintain a sorted list
        for (uint256 i = 0; i < auctionBids[auctionId].length; i++) {
            address potentialBidder = auctionBids[auctionId][i].bidder;
            uint256 maxBid = autoBidLimits[potentialBidder][auctionId];
            
            if (potentialBidder != auction.currentBidder && 
                maxBid > auction.currentBid &&
                gameToken.balanceOf(potentialBidder) >= maxBid) {
                
                uint256 nextBid = auction.currentBid + (auction.currentBid * minimumBidIncrement / 1000);
                if (nextBid <= maxBid && block.timestamp < auction.endTime) {
                    _placeBid(auctionId, potentialBidder, nextBid, true, maxBid);
                    break; // Only one auto-bid per transaction
                }
            }
        }
    }
    
    // ============================================================================
    // MYSTERY BOX AUCTIONS
    // ============================================================================
    
    function createMysteryBoxAuction(
        uint256 templateId,
        uint256 startingBid,
        uint32 duration
    ) external onlyOwner returns (uint256) {
        require(mysteryTemplates[templateId].minRarity <= mysteryTemplates[templateId].maxRarity, "Invalid template");
        
        uint256 auctionId = nextAuctionId++;
        
        auctions[auctionId].id = auctionId;
        auctions[auctionId].auctionType = AuctionType.MYSTERY_BOX;
        auctions[auctionId].status = AuctionStatus.ACTIVE;
        auctions[auctionId].seller = address(this); // Platform is seller
        auctions[auctionId].startingBid = startingBid;
        auctions[auctionId].startTime = uint32(block.timestamp);
        auctions[auctionId].endTime = uint32(block.timestamp) + duration;
        auctions[auctionId].originalEndTime = uint32(block.timestamp) + duration;
        
        // Create mystery hash
        auctions[auctionId].mysteryHash = keccak256(abi.encodePacked(
            templateId,
            block.timestamp,
            block.difficulty,
            auctionId
        ));
        
        activeAuctions.push(auctionId);
        
        uint256[] memory emptyArray = new uint256[](0);
        emit AuctionCreated(auctionId, AuctionType.MYSTERY_BOX, address(this), emptyArray);
        return auctionId;
    }
    
    function revealMysteryBox(uint256 auctionId) external nonReentrant {
        Auction storage auction = auctions[auctionId];
        require(auction.auctionType == AuctionType.MYSTERY_BOX, "Not mystery box");
        require(auction.status == AuctionStatus.ENDED, "Auction not ended");
        require(!auction.mysteryRevealed, "Already revealed");
        require(block.timestamp >= auction.endTime + mysteryTemplates[1].revealDelay, "Reveal delay not passed");
        
        auction.status = AuctionStatus.MYSTERY_REVEALING;
        
        // Request randomness for pet generation
        uint256 requestId = randomContract.requestRandomnessForMinting(auctionId);
        auction.revealRandomnessId = requestId;
        randomRequestToAuction[requestId] = auctionId;
    }
    
    function onRandomnessFulfilled(
        uint256 requestId,
        uint8 requestType,
        uint256 targetId,
        uint256[] calldata randomWords
    ) external override {
        require(msg.sender == address(randomContract), "Only random contract");
        
        if (requestType == 0) { // Minting randomness
            uint256 auctionId = randomRequestToAuction[requestId];
            _completeMysteryBoxReveal(auctionId, randomWords);
        }
    }
    
    function _completeMysteryBoxReveal(uint256 auctionId, uint256[] memory randomWords) internal {
        Auction storage auction = auctions[auctionId];
        require(auction.status == AuctionStatus.MYSTERY_REVEALING, "Not in revealing state");
        
        // Generate pet based on mystery template (simplified)
        MysteryBoxTemplate storage template = mysteryTemplates[1]; // Use first template for now
        
        uint8 rarity = template.minRarity + uint8(randomWords[0] % (template.maxRarity - template.minRarity + 1));
        uint8 element = template.possibleElements[randomWords[1] % template.possibleElements.length];
        
        // Mint pet to auction winner
        if (auction.currentBidder != address(0) && auction.reserveMet) {
            uint256 petId = petContract.mintPetForBreeding(
                auction.currentBidder,
                "Mystery Pet",
                "Mystery Species",
                rarity,
                element,
                keccak256(abi.encodePacked(randomWords[0], randomWords[1])),
                0,
                0
            );
            
            auction.petIds.push(petId);
            auction.mysteryRevealed = true;
            auction.status = AuctionStatus.ENDED;
            
            emit MysteryBoxRevealed(auctionId, petId, rarity, element);
        }
    }
    
    // ============================================================================
    // BREEDING RIGHTS AUCTIONS
    // ============================================================================
    
    function createBreedingRightsAuction(
        uint256 petId,
        uint256 startingBid,
        uint32 breedingDuration,
        uint8 maxBreedings,
        uint32 auctionDuration
    ) external nonReentrant whenNotPaused returns (uint256) {
        require(petContract.ownerOf(petId) == msg.sender, "Not pet owner");
        require(breedingDuration >= 86400 && breedingDuration <= 2592000, "Invalid breeding duration"); // 1 day to 30 days
        require(maxBreedings > 0 && maxBreedings <= 5, "Invalid max breedings");
        
        uint256 auctionId = nextAuctionId++;
        
        auctions[auctionId].id = auctionId;
        auctions[auctionId].auctionType = AuctionType.BREEDING_RIGHTS;
        auctions[auctionId].status = AuctionStatus.ACTIVE;
        auctions[auctionId].seller = msg.sender;
        auctions[auctionId].petIds.push(petId);
        auctions[auctionId].startingBid = startingBid;
        auctions[auctionId].startTime = uint32(block.timestamp);
        auctions[auctionId].endTime = uint32(block.timestamp) + auctionDuration;
        auctions[auctionId].originalEndTime = uint32(block.timestamp) + auctionDuration;
        auctions[auctionId].breedingDuration = breedingDuration;
        auctions[auctionId].maxBreedings = maxBreedings;
        
        activeAuctions.push(auctionId);
        
        emit AuctionCreated(auctionId, AuctionType.BREEDING_RIGHTS, msg.sender, auctions[auctionId].petIds);
        return auctionId;
    }
    
    function _completeBreedingRightsAuction(uint256 auctionId) internal {
        Auction storage auction = auctions[auctionId];
        
        if (auction.currentBidder != address(0) && (!auction.hasReservePrice || auction.reserveMet)) {
            // Grant breeding rights
            breedingRights[auctionId] = BreedingRights({
                auctionId: auctionId,
                petId: auction.petIds[0],
                rightsHolder: auction.currentBidder,
                expiresAt: uint32(block.timestamp) + auction.breedingDuration,
                breedingsUsed: 0,
                maxBreedings: auction.maxBreedings,
                active: true
            });
            
            // Transfer payment to seller (minus fees)
            uint256 platformFee = (auction.currentBid * platformFeePercentage) / 10000;
            uint256 sellerAmount = auction.currentBid - platformFee;
            
            gameToken.transfer(auction.seller, sellerAmount);
            gameToken.transfer(treasuryAddress, platformFee);
            
            emit BreedingRightsGranted(auctionId, auction.currentBidder, auction.petIds[0], auction.breedingDuration);
        }
    }
    
    // ============================================================================
    // GROUP AUCTIONS
    // ============================================================================
    
    function createGroupAuction(
        uint256[] calldata petIds,
        uint256 startingBid,
        uint256 minGroupSize,
        uint32 duration
    ) external nonReentrant whenNotPaused returns (uint256) {
        require(petIds.length >= 2 && petIds.length <= 10, "Invalid group size");
        require(minGroupSize <= petIds.length, "Min group size too large");
        
        // Verify ownership of all pets
        for (uint256 i = 0; i < petIds.length; i++) {
            require(petContract.ownerOf(petIds[i]) == msg.sender, "Not owner of all pets");
        }
        
        uint256 auctionId = nextAuctionId++;
        
        auctions[auctionId].id = auctionId;
        auctions[auctionId].auctionType = AuctionType.GROUP_AUCTION;
        auctions[auctionId].status = AuctionStatus.ACTIVE;
        auctions[auctionId].seller = msg.sender;
        auctions[auctionId].startingBid = startingBid;
        auctions[auctionId].startTime = uint32(block.timestamp);
        auctions[auctionId].endTime = uint32(block.timestamp) + duration;
        auctions[auctionId].originalEndTime = uint32(block.timestamp) + duration;
        auctions[auctionId].minGroupSize = minGroupSize;
        
        // Transfer all pets to auction contract
        for (uint256 i = 0; i < petIds.length; i++) {
            auctions[auctionId].petIds.push(petIds[i]);
            petContract.transferFrom(msg.sender, address(this), petIds[i]);
        }
        
        activeAuctions.push(auctionId);
        
        emit AuctionCreated(auctionId, AuctionType.GROUP_AUCTION, msg.sender, auctions[auctionId].petIds);
        return auctionId;
    }
    
    // ============================================================================
    // CHARITY AUCTIONS
    // ============================================================================
    
    function createCharityAuction(
        uint256 petId,
        uint256 startingBid,
        address charityAddress,
        uint256 charityPercentage,
        uint32 duration
    ) external nonReentrant whenNotPaused returns (uint256) {
        require(petContract.ownerOf(petId) == msg.sender, "Not pet owner");
        require(charityAddress != address(0), "Invalid charity address");
        require(charityPercentage >= 10 && charityPercentage <= 100, "Invalid charity percentage");
        
        uint256 auctionId = nextAuctionId++;
        
        auctions[auctionId].id = auctionId;
        auctions[auctionId].auctionType = AuctionType.CHARITY;
        auctions[auctionId].status = AuctionStatus.ACTIVE;
        auctions[auctionId].seller = msg.sender;
        auctions[auctionId].petIds.push(petId);
        auctions[auctionId].startingBid = startingBid;
        auctions[auctionId].startTime = uint32(block.timestamp);
        auctions[auctionId].endTime = uint32(block.timestamp) + duration;
        auctions[auctionId].originalEndTime = uint32(block.timestamp) + duration;
        auctions[auctionId].charityAddress = charityAddress;
        auctions[auctionId].charityPercentage = charityPercentage;
        
        petContract.transferFrom(msg.sender, address(this), petId);
        activeAuctions.push(auctionId);
        
        emit AuctionCreated(auctionId, AuctionType.CHARITY, msg.sender, auctions[auctionId].petIds);
        return auctionId;
    }
    
    function _completeCharityAuction(uint256 auctionId) internal {
        Auction storage auction = auctions[auctionId];
        
        if (auction.currentBidder != address(0)) {
            uint256 charityAmount = (auction.currentBid * auction.charityPercentage) / 100;
            uint256 matchingAmount = auction.matchingPool > charityAmount ? charityAmount : auction.matchingPool;
            uint256 totalCharity = charityAmount + matchingAmount;
            uint256 sellerAmount = auction.currentBid - charityAmount;
            
            // Transfer pet to winner
            petContract.transferFrom(address(this), auction.currentBidder, auction.petIds[0]);
            
            // Distribute funds
            gameToken.transfer(auction.charityAddress, totalCharity);
            gameToken.transfer(auction.seller, sellerAmount);
            
            // Reduce matching pool
            auction.matchingPool -= matchingAmount;
            
            emit CharityDonation(auctionId, auction.charityAddress, charityAmount, matchingAmount);
        }
    }
    
    // ============================================================================
    // REVERSE AUCTIONS
    // ============================================================================
    
    function createReverseAuction(
        string calldata petRequirements,
        uint256 maxPrice,
        uint32 duration
    ) external nonReentrant whenNotPaused returns (uint256) {
        require(bytes(petRequirements).length > 0, "Requirements cannot be empty");
        require(maxPrice > 0, "Max price must be positive");
        require(gameToken.balanceOf(msg.sender) >= maxPrice, "Insufficient balance");
        
        uint256 reverseAuctionId = nextReverseAuctionId++;
        
        reverseAuctions[reverseAuctionId].id = reverseAuctionId;
        reverseAuctions[reverseAuctionId].buyer = msg.sender;
        reverseAuctions[reverseAuctionId].petRequirements = petRequirements;
        reverseAuctions[reverseAuctionId].maxPrice = maxPrice;
        reverseAuctions[reverseAuctionId].endTime = uint32(block.timestamp) + duration;
        
        // Escrow the max price
        gameToken.transferFrom(msg.sender, address(this), maxPrice);
        
        emit ReverseAuctionCreated(reverseAuctionId, msg.sender, maxPrice);
        return reverseAuctionId;
    }
    
    function submitReverseAuctionOffer(
        uint256 reverseAuctionId,
        uint256 petId,
        uint256 offerPrice
    ) external nonReentrant {
        ReverseAuction storage rAuction = reverseAuctions[reverseAuctionId];
        require(block.timestamp < rAuction.endTime, "Reverse auction ended");
        require(petContract.ownerOf(petId) == msg.sender, "Not pet owner");
        require(offerPrice <= rAuction.maxPrice, "Offer exceeds max price");
        require(rAuction.sellerOffers[msg.sender
