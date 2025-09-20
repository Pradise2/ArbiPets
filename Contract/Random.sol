// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/ConfirmedOwner.sol";

/**
 * @title Random
 * @dev Chainlink VRF integration for secure randomness in CryptoPets
 * @notice Provides verifiable random numbers for:
 * - Pet minting attributes
 * - Battle outcomes
 * - Breeding genetics
 * - Event drops
 * - Tournament brackets
 */
contract Random is VRFConsumerBaseV2, ConfirmedOwner {
    
    // Chainlink VRF configuration
    VRFCoordinatorV2Interface COORDINATOR;
    
    // VRF subscription configuration
    uint64 public subscriptionId;
    bytes32 public keyHash;
    uint32 public callbackGasLimit = 100000;
    uint16 public requestConfirmations = 3;
    
    // Request tracking
    struct RandomRequest {
        uint256 requestId;
        address requester;
        uint8 requestType; // 0=minting, 1=battle, 2=breeding, 3=event
        uint256 targetId; // Pet ID, Battle ID, etc.
        bool fulfilled;
        uint256[] randomWords;
        uint256 timestamp;
    }
    
    mapping(uint256 => RandomRequest) public requests;
    mapping(address => bool) public authorizedCallers;
    mapping(uint8 => uint32) public requestTypeToNumWords;
    
    // Events
    event RandomnessRequested(uint256 indexed requestId, address indexed requester, uint8 requestType, uint256 targetId);
    event RandomnessFulfilled(uint256 indexed requestId, uint256[] randomWords);
    event AuthorizedCallerAdded(address indexed caller);
    event AuthorizedCallerRemoved(address indexed caller);
    
    // Network-specific configurations
    // Ethereum Mainnet
    address constant VRF_COORDINATOR_MAINNET = 0x271682DEB8C4E0901D1a1550aD2e64D568E69909;
    bytes32 constant KEY_HASH_MAINNET = 0x8af398995b04c28e9951adb9721ef74c74f93e6a478f39e7e0777be13527e7ef;
    
    // Polygon Mainnet
    address constant VRF_COORDINATOR_POLYGON = 0xAE975071Be8F8eE67addBC1A82488F1C24858067;
    bytes32 constant KEY_HASH_POLYGON = 0x6e099d640cde6de9d40ac749b4b594126b0169747122711109c9985d47751f93;
    
    constructor(
        uint64 _subscriptionId,
        address _vrfCoordinator,
        bytes32 _keyHash
    ) VRFConsumerBaseV2(_vrfCoordinator) ConfirmedOwner(msg.sender) {
        COORDINATOR = VRFCoordinatorV2Interface(_vrfCoordinator);
        subscriptionId = _subscriptionId;
        keyHash = _keyHash;
        
        // Set default number of words for each request type
        requestTypeToNumWords[0] = 5; // Minting: rarity, element, stats variance
        requestTypeToNumWords[1] = 3; // Battle: outcome, critical hits, damage variance
        requestTypeToNumWords[2] = 4; // Breeding: genetics, mutations, traits
        requestTypeToNumWords[3] = 2; // Events: drop type, quantity
    }
    
    modifier onlyAuthorized() {
        require(authorizedCallers[msg.sender] || msg.sender == owner(), "Not authorized to request randomness");
        _;
    }
    
    // ============================================================================
    // ADMIN FUNCTIONS
    // ============================================================================
    
    function addAuthorizedCaller(address caller) external onlyOwner {
        require(caller != address(0), "Cannot authorize zero address");
        authorizedCallers[caller] = true;
        emit AuthorizedCallerAdded(caller);
    }
    
    function removeAuthorizedCaller(address caller) external onlyOwner {
        authorizedCallers[caller] = false;
        emit AuthorizedCallerRemoved(caller);
    }
    
    function setSubscriptionId(uint64 _subscriptionId) external onlyOwner {
        subscriptionId = _subscriptionId;
    }
    
    function setKeyHash(bytes32 _keyHash) external onlyOwner {
        keyHash = _keyHash;
    }
    
    function setCallbackGasLimit(uint32 _gasLimit) external onlyOwner {
        require(_gasLimit >= 50000 && _gasLimit <= 500000, "Gas limit out of range");
        callbackGasLimit = _gasLimit;
    }
    
    function setRequestConfirmations(uint16 _confirmations) external onlyOwner {
        require(_confirmations >= 1 && _confirmations <= 10, "Confirmations out of range");
        requestConfirmations = _confirmations;
    }
    
    function setRequestTypeNumWords(uint8 requestType, uint32 numWords) external onlyOwner {
        require(numWords > 0 && numWords <= 10, "Invalid number of words");
        requestTypeToNumWords[requestType] = numWords;
    }
    
    // ============================================================================
    // RANDOMNESS REQUEST FUNCTIONS
    // ============================================================================
    
    function requestRandomnessForMinting(uint256 petId) external onlyAuthorized returns (uint256) {
        return _requestRandomness(0, petId);
    }
    
    function requestRandomnessForBattle(uint256 battleId) external onlyAuthorized returns (uint256) {
        return _requestRandomness(1, battleId);
    }
    
    function requestRandomnessForBreeding(uint256 breedingId) external onlyAuthorized returns (uint256) {
        return _requestRandomness(2, breedingId);
    }
    
    function requestRandomnessForEvent(uint256 eventId) external onlyAuthorized returns (uint256) {
        return _requestRandomness(3, eventId);
    }
    
    function _requestRandomness(uint8 requestType, uint256 targetId) internal returns (uint256) {
        uint32 numWords = requestTypeToNumWords[requestType];
        require(numWords > 0, "Invalid request type");
        
        uint256 requestId = COORDINATOR.requestRandomWords(
            keyHash,
            subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            numWords
        );
        
        requests[requestId] = RandomRequest({
            requestId: requestId,
            requester: msg.sender,
            requestType: requestType,
            targetId: targetId,
            fulfilled: false,
            randomWords: new uint256[](0),
            timestamp: block.timestamp
        });
        
        emit RandomnessRequested(requestId, msg.sender, requestType, targetId);
        return requestId;
    }
    
    // ============================================================================
    // VRF CALLBACK
    // ============================================================================
    
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        require(requests[requestId].requestId == requestId, "Request not found");
        require(!requests[requestId].fulfilled, "Request already fulfilled");
        
        requests[requestId].randomWords = randomWords;
        requests[requestId].fulfilled = true;
        
        emit RandomnessFulfilled(requestId, randomWords);
        
        // Notify the requester contract about fulfilled randomness
        _notifyRequester(requestId);
    }
    
    function _notifyRequester(uint256 requestId) internal {
        RandomRequest memory request = requests[requestId];
        
        // Call back to the requesting contract with the random numbers
        // This allows the game contracts to continue their logic
        try IRandomnessConsumer(request.requester).onRandomnessFulfilled(
            requestId,
            request.requestType,
            request.targetId,
            request.randomWords
        ) {
            // Success - randomness processed by requesting contract
        } catch {
            // Failed to notify requester - they'll need to check manually
        }
    }
    
    // ============================================================================
    // UTILITY FUNCTIONS FOR GAME CONTRACTS
    // ============================================================================
    
    function generatePetAttributes(uint256[] memory randomWords) external pure returns (
        uint8 rarity,
        uint8 element,
        uint16 hpVariance,
        uint16 energyVariance,
        uint16 statVariance
    ) {
        require(randomWords.length >= 5, "Insufficient random words");
        
        // Determine rarity (weighted distribution)
        uint256 rarityRoll = randomWords[0] % 10000;
        if (rarityRoll < 6000) rarity = 0; // Common 60%
        else if (rarityRoll < 8500) rarity = 1; // Rare 25%
        else if (rarityRoll < 9700) rarity = 2; // Epic 12%
        else rarity = 3; // Legendary 3%
        
        element = uint8(randomWords[1] % 8);
        hpVariance = uint16(randomWords[2] % 30);
        energyVariance = uint16(randomWords[3] % 30);
        statVariance = uint16(randomWords[4] % 25);
    }
    
    function generateBattleOutcome(uint256[] memory randomWords, uint256 pet1Power, uint256 pet2Power) 
        external pure returns (uint256 winner, bool criticalHit, uint16 damageMultiplier) 
    {
        require(randomWords.length >= 3, "Insufficient random words");
        
        // Calculate base probabilities
        uint256 totalPower = pet1Power + pet2Power;
        uint256 pet1Chance = (pet1Power * 10000) / totalPower;
        
        uint256 outcomeRoll = randomWords[0] % 10000;
        winner = outcomeRoll < pet1Chance ? 1 : 2;
        
        // Check for critical hit (5% base chance)
        criticalHit = (randomWords[1] % 100) < 5;
        
        // Damage variance (80-120% of base)
        damageMultiplier = uint16(80 + (randomWords[2] % 41));
    }
    
    function generateBreedingGenetics(uint256[] memory randomWords, bytes32 parent1DNA, bytes32 parent2DNA) 
        external pure returns (bytes32 offspringDNA, bool hasRarityMutation, bool hasElementMutation, uint8 numTraits) 
    {
        require(randomWords.length >= 4, "Insufficient random words");
        
        // Combine parent DNA with randomness
        offspringDNA = keccak256(abi.encodePacked(parent1DNA, parent2DNA, randomWords[0]));
        
        // 5% chance for rarity mutation (increase)
        hasRarityMutation = (randomWords[1] % 100) < 5;
        
        // 1% chance for element mutation
        hasElementMutation = (randomWords[2] % 1000) < 10;
        
        // Number of traits (1-5, weighted towards lower numbers)
        uint256 traitRoll = randomWords[3] % 100;
        if (traitRoll < 40) numTraits = 1;
        else if (traitRoll < 70) numTraits = 2;
        else if (traitRoll < 85) numTraits = 3;
        else if (traitRoll < 95) numTraits = 4;
        else numTraits = 5;
    }
    
    function generateEventDrop(uint256[] memory randomWords) external pure returns (
        uint8 dropType, // 0=tokens, 1=NFT, 2=item
        uint256 quantity,
        uint8 rarity
    ) {
        require(randomWords.length >= 2, "Insufficient random words");
        
        // Drop type probability
        uint256 dropRoll = randomWords[0] % 100;
        if (dropRoll < 70) {
            dropType = 0; // Tokens 70%
            quantity = 50 + (randomWords[1] % 200); // 50-250 tokens
            rarity = 0;
        } else if (dropRoll < 95) {
            dropType = 2; // Item 25%
            quantity = 1;
            rarity = uint8(randomWords[1] % 3); // Common to Epic
        } else {
            dropType = 1; // NFT 5%
            quantity = 1;
            rarity = uint8((randomWords[1] % 100) < 10 ? 3 : 2); // Epic or Legendary
        }
    }
    
    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================
    
    function getRequest(uint256 requestId) external view returns (RandomRequest memory) {
        return requests[requestId];
    }
    
    function isRequestFulfilled(uint256 requestId) external view returns (bool) {
        return requests[requestId].fulfilled;
    }
    
    function getRandomWords(uint256 requestId) external view returns (uint256[] memory) {
        require(requests[requestId].fulfilled, "Request not yet fulfilled");
        return requests[requestId].randomWords;
    }
    
    function getRandomWord(uint256 requestId, uint256 index) external view returns (uint256) {
        require(requests[requestId].fulfilled, "Request not yet fulfilled");
        require(index < requests[requestId].randomWords.length, "Index out of bounds");
        return requests[requestId].randomWords[index];
    }
    
    // ============================================================================
    // EMERGENCY FUNCTIONS
    // ============================================================================
    
    function emergencyWithdraw() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
    
    // For manual fulfillment in case of VRF issues (testing/emergency)
    function manualFulfill(uint256 requestId, uint256[] calldata randomWords) external onlyOwner {
        require(!requests[requestId].fulfilled, "Already fulfilled");
        require(randomWords.length == requestTypeToNumWords[requests[requestId].requestType], "Invalid word count");
        
        requests[requestId].randomWords = randomWords;
        requests[requestId].fulfilled = true;
        
        emit RandomnessFulfilled(requestId, randomWords);
        _notifyRequester(requestId);
    }
    
    // ============================================================================
    // HELPER FUNCTIONS
    // ============================================================================
    
    function generateSecureSeed(uint256 nonce) external view returns (bytes32) {
        return keccak256(abi.encodePacked(
            block.timestamp,
            block.difficulty,
            block.coinbase,
            nonce,
            msg.sender
        ));
    }
    
    function expandRandomness(uint256 randomValue, uint256 n) external pure returns (uint256[] memory) {
        uint256[] memory expandedValues = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            expandedValues[i] = uint256(keccak256(abi.encode(randomValue, i)));
        }
        return expandedValues;
    }
}

/**
 * @title IRandomnessConsumer
 * @dev Interface for contracts that consume randomness
 */
interface IRandomnessConsumer {
    function onRandomnessFulfilled(
        uint256 requestId,
        uint8 requestType,
        uint256 targetId,
        uint256[] calldata randomWords
    ) external;
}
