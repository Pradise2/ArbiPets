// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./PetNFT.sol";
import "./GameToken.sol";
import "./Random.sol";

/**
 * @title PetBreeding
 * @dev Advanced breeding system with genetics, mutations, and evolution
 * @notice Features:
 * - Cross-element breeding with mutations
 * - Genetic trait inheritance and combinations
 * - Breeding cooldowns and costs
 * - Special breeding events and bonuses
 * - Lineage tracking and pedigree system
 */
contract PetBreeding is Ownable, ReentrancyGuard, Pausable, IRandomnessConsumer {
    
    struct BreedingRequest {
        uint256 id;
        uint256 parent1;
        uint256 parent2;
        address owner;
        uint32 initiatedTime;
        uint32 readyTime;
        bool completed;
        uint256 randomnessRequestId;
        BreedingModifiers modifiers;
    }
    
    struct BreedingModifiers {
        bool usedBreedingBoost;    // Premium item to reduce time
        bool usedMutationSerum;    // Increases mutation chance
        bool usedRarityEssence;    // Guarantees rarity inheritance
        uint8 breedingFacility;    // 0=basic, 1=advanced, 2=premium
    }
    
    struct GeneticProfile {
        bytes32 dominantGenes;     // Primary genetic markers
        bytes32 recessiveGenes;    // Secondary genetic markers
        uint8[8] elementAffinity;  // Affinity scores for each element
        uint16[6] statPotential;   // Max potential for each stat
        string[] inheritableTraits;
        uint8 generationNumber;
        uint8 mutationCount;
    }
    
    struct BreedingCombination {
        uint8 element1;
        uint8 element2;
        uint8 resultElement;
        uint8 mutationChance;      // Out of 100
        bool isSpecialCombination;
        string resultSpecies;
    }
    
    // Contract references
    PetNFT public petContract;
    GameToken public gameToken;
    Random public randomContract;
    
    // Breeding storage
    mapping(uint256 => BreedingRequest) public breedingRequests;
    mapping(uint256 => uint256) public petBreeding; // petId => requestId
    mapping(uint256 => uint256) public randomRequestToBreeding;
    mapping(uint256 => GeneticProfile) public petGeneticProfiles;
    
    // Breeding combinations and results
    mapping(bytes32 => BreedingCombination) public breedingCombinations;
    bytes32[] public registeredCombinations;
    
    // Configuration
    uint256 public nextRequestId = 1;
    uint256 public breedingBaseCost = 100 * 10**18; // 100 PETS
    uint32 public baseBreedingCooldown = 172800; // 48 hours
    uint8 public maxBreedCount = 5;
    uint8 public maxGenerations = 10;
    
    // Breeding facility costs
    uint256[3] public facilityUpgradeCosts = [0, 500 * 10**18, 2000 * 10**18];
    uint32[3] public facilityCooldownReductions = [0, 14400, 43200]; // 0h, 4h, 12h
    
    // Special items and boosts
    uint256 public breedingBoostCost = 200 * 10**18;    // Reduces time by 50%
    uint256 public mutationSerumCost = 500 * 10**18;    // +20% mutation chance
    uint256 public rarityEssenceCost = 1000 * 10**18;   // Guarantees rare+ offspring
    
    // Events
    event BreedingInitiated(uint256 indexed requestId, uint256 parent1, uint256 parent2, address owner);
    event BreedingCompleted(uint256 indexed requestId, uint256 newPetId, bool hadMutation);
    event GeneticProfileCreated(uint256 indexed petId, uint8 generation, uint8 mutationCount);
    event SpecialBreedingCombination(uint256 indexed requestId, string resultSpecies, uint8 resultElement);
    event BreedingBoostUsed(uint256 indexed requestId, address user, uint8 boostType);
    
    constructor(
        address _petContract,
        address _gameToken,
        address _randomContract
    ) {
        petContract = PetNFT(_petContract);
        gameToken = GameToken(_gameToken);
        randomContract = Random(_randomContract);
        
        _initializeBreedingCombinations();
    }
    
    function _initializeBreedingCombinations() internal {
        // Fire + Water = Steam (Mystic)
        _addBreedingCombination(0, 1, 5, 15, true, "Steam Dragon");
        
        // Earth + Air = Crystal (Light)
        _addBreedingCombination(2, 3, 6, 12, true, "Crystal Wing");
        
        // Electric + Mystic = Plasma (Dark)
        _addBreedingCombination(4, 5, 7, 20, true, "Plasma Beast");
        
        // Light + Dark = Void (Special mutation)
        _addBreedingCombination(6, 7, 5, 25, true, "Void Walker");
        
        // Same element combinations (higher mutation chance)
        for (uint8 i = 0; i < 8; i++) {
            _addBreedingCombination(i, i, i, 8, false, "");
        }
        
        // Cross-element combinations (standard)
        _addBreedingCombination(0, 2, 0, 5, false, ""); // Fire + Earth = Fire
        _addBreedingCombination(1, 3, 1, 5, false, ""); // Water + Air = Water
        _addBreedingCombination(0, 4, 4, 7, false, ""); // Fire + Electric = Electric
        _addBreedingCombination(1, 2, 2, 5, false, ""); // Water + Earth = Earth
    }
    
    function _addBreedingCombination(
        uint8 element1,
        uint8 element2,
        uint8 result,
        uint8 mutationChance,
        bool isSpecial,
        string memory species
    ) internal {
        bytes32 key1 = keccak256(abi.encodePacked(element1, element2));
        bytes32 key2 = keccak256(abi.encodePacked(element2, element1));
        
        BreedingCombination memory combo = BreedingCombination({
            element1: element1,
            element2: element2,
            resultElement: result,
            mutationChance: mutationChance,
            isSpecialCombination: isSpecial,
            resultSpecies: species
        });
        
        breedingCombinations[key1] = combo;
        breedingCombinations[key2] = combo;
        registeredCombinations.push(key1);
    }
    
    // ============================================================================
    // GENETIC PROFILE MANAGEMENT
    // ============================================================================
    
    function createGeneticProfile(uint256 petId) external {
        require(petContract.ownerOf(petId) == msg.sender || msg.sender == address(petContract), "Not authorized");
        require(petGeneticProfiles[petId].dominantGenes == bytes32(0), "Profile already exists");
        
        PetNFT.Pet memory pet = petContract.getPet(petId);
        
        // Generate genetic profile from pet DNA
        GeneticProfile memory profile = _generateGeneticProfile(pet);
        petGeneticProfiles[petId] = profile;
        
        emit GeneticProfileCreated(petId, profile.generationNumber, profile.mutationCount);
    }
    
    function _generateGeneticProfile(PetNFT.Pet memory pet) internal pure returns (GeneticProfile memory) {
        uint256 dnaInt = uint256(pet.dna);
        
        GeneticProfile memory profile;
        profile.dominantGenes = bytes32(dnaInt);
        profile.recessiveGenes = bytes32(dnaInt >> 128);
        profile.generationNumber = pet.parent1 == 0 ? 0 : 1; // Will be calculated properly in breeding
        profile.mutationCount = 0;
        
        // Generate element affinities (higher for pet's element)
        for (uint8 i = 0; i < 8; i++) {
            if (i == pet.element) {
                profile.elementAffinity[i] = 80 + uint8((dnaInt >> (i * 8)) % 20);
            } else {
                profile.elementAffinity[i] = 10 + uint8((dnaInt >> (i * 8)) % 30);
            }
        }
        
        // Generate stat potentials
        profile.statPotential[0] = pet.maxHp + uint16((dnaInt % 50));
        profile.statPotential[1] = pet.maxEnergy + uint16(((dnaInt >> 16) % 50));
        profile.statPotential[2] = pet.strength + uint16(((dnaInt >> 32) % 30));
        profile.statPotential[3] = pet.speed + uint16(((dnaInt >> 48) % 30));
        profile.statPotential[4] = pet.intelligence + uint16(((dnaInt >> 64) % 30));
        profile.statPotential[5] = pet.defense + uint16(((dnaInt >> 80) % 30));
        
        return profile;
    }
    
    // ============================================================================
    // BREEDING INITIATION
    // ============================================================================
    
    function initiateBreeding(
        uint256 parent1Id,
        uint256 parent2Id,
        BreedingModifiers memory modifiers
    ) external nonReentrant whenNotPaused {
        require(petContract.ownerOf(parent1Id) == msg.sender, "Not owner of parent1");
        require(petContract.ownerOf(parent2Id) == msg.sender, "Not owner of parent2");
        require(parent1Id != parent2Id, "Cannot breed with self");
        require(petBreeding[parent1Id] == 0, "Parent1 already breeding");
        require(petBreeding[parent2Id] == 0, "Parent2 already breeding");
        
        PetNFT.Pet memory pet1 = petContract.getPet(parent1Id);
        PetNFT.Pet memory pet2 = petContract.getPet(parent2Id);
        
        _validateBreedingRequirements(pet1, pet2);
        
        // Calculate total breeding cost
        uint256 totalCost = _calculateBreedingCost(modifiers);
        require(gameToken.balanceOf(msg.sender) >= totalCost, "Insufficient tokens");
        
        gameToken.transferFrom(msg.sender, address(this), totalCost);
        
        // Create genetic profiles if they don't exist
        if (petGeneticProfiles[parent1Id].dominantGenes == bytes32(0)) {
            petGeneticProfiles[parent1Id] = _generateGeneticProfile(pet1);
        }
        if (petGeneticProfiles[parent2Id].dominantGenes == bytes32(0)) {
            petGeneticProfiles[parent2Id] = _generateGeneticProfile(pet2);
        }
        
        uint256 requestId = nextRequestId++;
        uint32 breedingTime = _calculateBreedingTime(modifiers);
        
        breedingRequests[requestId] = BreedingRequest({
            id: requestId,
            parent1: parent1Id,
            parent2: parent2Id,
            owner: msg.sender,
            initiatedTime: uint32(block.timestamp),
            readyTime: uint32(block.timestamp) + breedingTime,
            completed: false,
            randomnessRequestId: 0,
            modifiers: modifiers
        });
        
        petBreeding[parent1Id] = requestId;
        petBreeding[parent2Id] = requestId;
        
        emit BreedingInitiated(requestId, parent1Id, parent2Id, msg.sender);
        
        if (modifiers.usedBreedingBoost) {
            emit BreedingBoostUsed(requestId, msg.sender, 0);
        }
    }
    
    function _validateBreedingRequirements(PetNFT.Pet memory pet1, PetNFT.Pet memory pet2) internal view {
        require(pet1.level >= 10, "Parent1 level too low");
        require(pet2.level >= 10, "Parent2 level too low");
        require(pet1.breedCount < maxBreedCount, "Parent1 breed limit reached");
        require(pet2.breedCount < maxBreedCount, "Parent2 breed limit reached");
        require(pet1.happiness >= 90, "Parent1 not happy enough");
        require(pet2.happiness >= 90, "Parent2 not happy enough");
        require(pet1.parent1 != pet2.id && pet1.parent2 != pet2.id, "Cannot breed with parent");
        require(pet2.parent1 != pet1.id && pet2.parent2 != pet1.id, "Cannot breed with parent");
        require(pet1.parent1 != pet2.parent1 || pet1.parent1 == 0, "Cannot breed siblings");
    }
    
    function _calculateBreedingCost(BreedingModifiers memory modifiers) internal view returns (uint256) {
        uint256 cost = breedingBaseCost;
        
        if (modifiers.usedBreedingBoost) cost += breedingBoostCost;
        if (modifiers.usedMutationSerum) cost += mutationSerumCost;
        if (modifiers.usedRarityEssence) cost += rarityEssenceCost;
        if (modifiers.breedingFacility > 0) cost += facilityUpgradeCosts[modifiers.breedingFacility];
        
        return cost;
    }
    
    function _calculateBreedingTime(BreedingModifiers memory modifiers) internal view returns (uint32) {
        uint32 time = baseBreedingCooldown;
        
        if (modifiers.breedingFacility > 0) {
            time -= facilityCooldownReductions[modifiers.breedingFacility];
        }
        
        if (modifiers.usedBreedingBoost) {
            time = time / 2; // 50% time reduction
        }
        
        return time;
    }
    
    // ============================================================================
    // BREEDING COMPLETION
    // ============================================================================
    
    function completeBreeding(uint256 requestId) external nonReentrant {
        BreedingRequest storage request = breedingRequests[requestId];
        require(request.owner == msg.sender, "Not request owner");
        require(!request.completed, "Already completed");
        require(block.timestamp >= request.readyTime, "Breeding not ready");
        
        // Request randomness for breeding
        uint256 randomnessRequestId = randomContract.requestRandomnessForBreeding(requestId);
        request.randomnessRequestId = randomnessRequestId;
        randomRequestToBreeding[randomnessRequestId] = requestId;
    }
    
    function onRandomnessFulfilled(
        uint256 randomnessRequestId,
        uint8 requestType,
        uint256 targetId,
        uint256[] calldata randomWords
    ) external override {
        require(msg.sender == address(randomContract), "Only random contract can call");
        require(requestType == 2, "Invalid request type for breeding");
        
        uint256 requestId = randomRequestToBreeding[randomnessRequestId];
        require(requestId != 0, "Breeding request not found");
        
        _executeBreeding(requestId, randomWords);
    }
    
    function _executeBreeding(uint256 requestId, uint256[] memory randomWords) internal {
        BreedingRequest storage request = breedingRequests[requestId];
        
        PetNFT.Pet memory parent1 = petContract.getPet(request.parent1);
        PetNFT.Pet memory parent2 = petContract.getPet(request.parent2);
        
        GeneticProfile memory profile1 = petGeneticProfiles[request.parent1];
        GeneticProfile memory profile2 = petGeneticProfiles[request.parent2];
        
        // Generate offspring attributes
        OffspringData memory offspring = _generateOffspring(
            parent1, parent2, profile1, profile2, request.modifiers, randomWords
        );
        
        // Update parent breed counts
        parent1.breedCount++;
        parent2.breedCount++;
        petContract.updatePetStats(request.parent1, parent1);
        petContract.updatePetStats(request.parent2, parent2);
        
        // Mint new pet
        uint256 newPetId = petContract.mintPetForBreeding(
            request.owner,
            offspring.name,
            offspring.species,
            offspring.rarity,
            offspring.element,
            offspring.dna,
            request.parent1,
            request.parent2
        );
        
        // Create genetic profile for offspring
        petGeneticProfiles[newPetId] = offspring.geneticProfile;
        
        request.completed = true;
        petBreeding[request.parent1] = 0;
        petBreeding[request.parent2] = 0;
        
        emit BreedingCompleted(requestId, newPetId, offspring.hadMutation);
        
        if (offspring.isSpecialCombination) {
            emit SpecialBreedingCombination(requestId, offspring.species, offspring.element);
        }
    }
    
    struct OffspringData {
        string name;
        string species;
        uint8 rarity;
        uint8 element;
        bytes32 dna;
        GeneticProfile geneticProfile;
        bool hadMutation;
        bool isSpecialCombination;
    }
    
    function _generateOffspring(
        PetNFT.Pet memory parent1,
        PetNFT.Pet memory parent2,
        GeneticProfile memory profile1,
        GeneticProfile memory profile2,
        BreedingModifiers memory modifiers,
        uint256[] memory randomWords
    ) internal view returns (OffspringData memory) {
        
        OffspringData memory offspring;
        
        // Generate new DNA by combining parents
        offspring.dna = keccak256(abi.encodePacked(
            parent1.dna,
            parent2.dna,
            block.timestamp,
            randomWords[0]
        ));
        
        // Determine element through breeding combinations
        bytes32 combinationKey = keccak256(abi.encodePacked(parent1.element, parent2.element));
        BreedingCombination memory combo = breedingCombinations[combinationKey];
        
        offspring.element = combo.resultElement;
        offspring.isSpecialCombination = combo.isSpecialCombination;
        
        if (combo.isSpecialCombination) {
            offspring.species = combo.resultSpecies;
        } else {
            offspring.species = "Hybrid";
        }
        
        // Calculate mutation chance
        uint8 mutationChance = combo.mutationChance;
        if (modifiers.usedMutationSerum) mutationChance += 20;
        
        // Check for mutations
        offspring.hadMutation = (randomWords[1] % 100) < mutationChance;
        
        if (offspring.hadMutation) {
            // Element mutation
            if ((randomWords[2] % 100) < 30) {
                offspring.element = uint8(randomWords[2] % 8);
            }
        }
        
        // Determine rarity
        if (modifiers.usedRarityEssence) {
            offspring.rarity = parent1.rarity > parent2.rarity ? parent1.rarity : parent2.rarity;
        } else {
            offspring.rarity = _calculateOffspringRarity(parent1.rarity, parent2.rarity, randomWords[3]);
        }
        
        // Generate genetic profile
        offspring.geneticProfile = _generateOffspringGenetics(
            profile1, profile2, offspring.element, offspring.hadMutation, randomWords
        );
        
        offspring.name = "Offspring";
        
        return offspring;
    }
    
    function _calculateOffspringRarity(uint8 rarity1, uint8 rarity2, uint256 randomValue) internal pure returns (uint8) {
        uint8 maxRarity = rarity1 > rarity2 ? rarity1 : rarity2;
        uint8 minRarity = rarity1 < rarity2 ? rarity1 : rarity2;
        
        uint256 roll = randomValue % 100;
        
        // Higher chance to inherit higher rarity
        if (roll < 40) return maxRarity;
        if (roll < 70) return minRarity;
        if (roll < 85) return maxRarity > 0 ? maxRarity - 1 : 0;
        if (roll < 95) return maxRarity < 3 ? maxRarity + 1 : 3;
        
        // 5% chance for maximum rarity
        return 3;
    }
    
    function _generateOffspringGenetics(
        GeneticProfile memory profile1,
        GeneticProfile memory profile2,
        uint8 element,
        bool hadMutation,
        uint256[] memory randomWords
    ) internal pure returns (GeneticProfile memory) {
        
        GeneticProfile memory offspring;
        
        // Combine genetic material
        offspring.dominantGenes = keccak256(abi.encodePacked(profile1.dominantGenes, randomWords[0]));
        offspring.recessiveGenes = keccak256(abi.encodePacked(profile2.recessiveGenes, randomWords[1]));
        
        // Calculate generation
        offspring.generationNumber = (profile1.generationNumber > profile2.generationNumber ? 
            profile1.generationNumber : profile2.generationNumber) + 1;
        
        offspring.mutationCount = profile1.mutationCount + profile2.mutationCount;
        if (hadMutation) offspring.mutationCount++;
        
        // Inherit element affinities with some variance
        for (uint8 i = 0; i < 8; i++) {
            uint8 avg = (profile1.elementAffinity[i] + profile2.elementAffinity[i]) / 2;
            uint8 variance = uint8((randomWords[i % randomWords.length] >> (i * 8)) % 20) - 10;
            offspring.elementAffinity[i] = uint8(int8(avg) + int8(variance));
            
            // Boost affinity for offspring's element
            if (i == element) {
                offspring.elementAffinity[i] += 20;
            }
        }
        
        // Inherit stat potentials
        for (uint8 i = 0; i < 6; i++) {
            uint16 avg = (profile1.statPotential[i] + profile2.statPotential[i]) / 2;
            uint16 variance = uint16((randomWords[i % randomWords.length] >> (i * 16)) % 30) - 15;
            offspring.statPotential[i] = uint16(int16(avg) + int16(variance));
        }
        
        return offspring;
    }
    
    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================
    
    function getBreedingRequest(uint256 requestId) external view returns (BreedingRequest memory) {
        return breedingRequests[requestId];
    }
    
    function getGeneticProfile(uint256 petId) external view returns (GeneticProfile memory) {
        return petGeneticProfiles[petId];
    }
    
    function getBreedingCombination(uint8 element1, uint8 element2) external view returns (BreedingCombination memory) {
        bytes32 key = keccak256(abi.encodePacked(element1, element2));
        return breedingCombinations[key];
    }
    
    function canBreed(uint256 petId1, uint256 petId2) external view returns (bool, string memory) {
        if (petContract.ownerOf(petId1) != petContract.ownerOf(petId2)) {
            return (false, "Different owners");
        }
        
        PetNFT.Pet memory pet1 = petContract.getPet(petId1);
        PetNFT.Pet memory pet2 = petContract.getPet(petId2);
        
        if (pet1.level < 10 || pet2.level < 10) return (false, "Level too low");
        if (pet1.breedCount >= maxBreedCount || pet2.breedCount >= maxBreedCount) return (false, "Breed limit reached");
        if (pet1.happiness < 90 || pet2.happiness < 90) return (false, "Not happy enough");
        if (petBreeding[petId1] != 0 || petBreeding[petId2] != 0) return (false, "Already breeding");
        
        return (true, "");
    }
    
    function calculateBreedingCost(BreedingModifiers memory modifiers) external view returns (uint256) {
        return _calculateBreedingCost(modifiers);
    }
    
    function calculateBreedingTime(BreedingModifiers memory modifiers) external view returns (uint32) {
        return _calculateBreedingTime(modifiers);
    }
    
    // ============================================================================
    // ADMIN FUNCTIONS
    // ============================================================================
    
    function addBreedingCombination(
        uint8 element1,
        uint8 element2,
        uint8 result,
        uint8 mutationChance,
        bool isSpecial,
        string memory species
    ) external onlyOwner {
        _addBreedingCombination(element1, element2, result, mutationChance, isSpecial, species);
    }
    
    function setBreedingCosts(
        uint256 _baseCost,
        uint256 _boostCost,
        uint256 _serumCost,
        uint256 _essenceCost
    ) external onlyOwner {
        breedingBaseCost = _baseCost;
        breedingBoostCost = _boostCost;
        mutationSerumCost = _serumCost;
        rarityEssenceCost = _essenceCost;
    }
    
    function setBreedingParameters(
        uint32 _cooldown,
        uint8 _maxBreeds,
        uint8 _maxGenerations
    ) external onlyOwner {
        baseBreedingCooldown = _cooldown;
        maxBreedCount = _maxBreeds;
        maxGenerations = _maxGenerations;
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    function emergencyWithdraw() external onlyOwner {
        gameToken.transfer(owner(), gameToken.balanceOf(address(this)));
    }
}
