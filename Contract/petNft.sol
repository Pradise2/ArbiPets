// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./GameToken.sol";

/**
 * @title PetNFT
 * @dev Main ERC-721 contract for CryptoPets with full game mechanics
 * @notice Each pet is a unique NFT with stats, traits, and breeding capabilities
 */
contract PetNFT is ERC721, ERC721Enumerable, ERC721URIStorage, Ownable, ReentrancyGuard, Pausable {
    
    // Pet struct containing all pet data
    struct Pet {
        uint256 id;
        string name;
        string species;
        uint8 level;
        uint8 rarity; // 0=Common, 1=Rare, 2=Epic, 3=Legendary
        uint8 element; // 0=Fire, 1=Water, 2=Earth, 3=Air, 4=Electric, 5=Mystic, 6=Light, 7=Dark
        uint16 hp;
        uint16 maxHp;
        uint16 energy;
        uint16 maxEnergy;
        uint16 happiness;
        uint32 experience;
        uint32 maxExp;
        uint16 strength;
        uint16 speed;
        uint16 intelligence;
        uint16 defense;
        uint32 lastFed;
        uint32 lastTrained;
        uint32 birthTime;
        uint16 battleWins;
        uint16 battleLosses;
        uint8 breedCount;
        uint256 parent1;
        uint256 parent2;
        bytes32 dna;
        bool isGenesis; // First generation pets
    }
    
    // Pet traits system
    struct PetTraits {
        string[] traits;
        uint8 traitCount;
    }
    
    // Constants
    uint256 public constant MAX_LEVEL = 100;
    uint256 public constant MAX_BREED_COUNT = 5;
    uint256 public constant FEED_COOLDOWN = 3600; // 1 hour
    uint256 public constant TRAIN_COOLDOWN = 7200; // 2 hours
    uint256 public constant HAPPINESS_DECAY_RATE = 86400; // 24 hours for 1 happiness point
    
    // Minting configuration
    uint256 public mintPrice = 0.05 ether;
    uint256 public maxSupply = 50000;
    uint256 public genesisSupply = 5000;
    uint256 public currentGenesisMinted = 0;
    
    // Game token integration
    GameToken public gameToken;
    
    // Pet storage
    mapping(uint256 => Pet) public pets;
    mapping(uint256 => PetTraits) public petTraits;
    mapping(uint256 => mapping(string => bool)) public petHasTrait;
    
    // Authorization for game contracts
    mapping(address => bool) public authorizedContracts;
    
    // Pet counter
    uint256 public nextPetId = 1;
    
    // Rarity rates for minting (out of 10000)
    uint16[4] public rarityRates = [6000, 2500, 1200, 300]; // Common, Rare, Epic, Legendary
    
    // Base stats by rarity
    uint16[4] public baseStatsMultiplier = [50, 65, 80, 100];
    
    // Events
    event PetMinted(uint256 indexed petId, address indexed owner, string name, uint8 rarity, bool isGenesis);
    event PetLevelUp(uint256 indexed petId, uint8 newLevel, address indexed owner);
    event PetFed(uint256 indexed petId, uint16 happinessGain, uint16 energyGain);
    event PetTrained(uint256 indexed petId, uint8 statType, uint16 statGain, uint32 expGain);
    event PetStatsUpdated(uint256 indexed petId, address indexed updater);
    event PetEvolved(uint256 indexed petId, string newSpecies, uint8 newRarity);
    
    constructor(address _gameToken) ERC721("CryptoPets", "CPET") {
        gameToken = GameToken(_gameToken);
    }
    
    modifier onlyAuthorized() {
        require(authorizedContracts[msg.sender] || msg.sender == owner(), "Not authorized");
        _;
    }
    
    modifier petExists(uint256 petId) {
        require(_exists(petId), "Pet does not exist");
        _;
    }
    
    modifier onlyPetOwner(uint256 petId) {
        require(ownerOf(petId) == msg.sender, "Not pet owner");
        _;
    }
    
    // ============================================================================
    // ADMIN FUNCTIONS
    // ============================================================================
    
    function addAuthorizedContract(address contractAddr) external onlyOwner {
        authorizedContracts[contractAddr] = true;
    }
    
    function removeAuthorizedContract(address contractAddr) external onlyOwner {
        authorizedContracts[contractAddr] = false;
    }
    
    function setMintPrice(uint256 _mintPrice) external onlyOwner {
        mintPrice = _mintPrice;
    }
    
    function setRarityRates(uint16[4] calldata _rates) external onlyOwner {
        uint256 total = 0;
        for (uint256 i = 0; i < 4; i++) {
            total += _rates[i];
        }
        require(total == 10000, "Rates must sum to 10000");
        rarityRates = _rates;
    }
    
    function setBaseURI(string memory baseURI) external onlyOwner {
        // Implementation would set the base URI for metadata
    }
    
    // ============================================================================
    // MINTING FUNCTIONS
    // ============================================================================
    
    function mintPet(
        string memory name,
        string memory species
    ) external payable nonReentrant whenNotPaused {
        require(msg.value >= mintPrice, "Insufficient payment");
        require(bytes(name).length > 0, "Name cannot be empty");
        require(bytes(species).length > 0, "Species cannot be empty");
        require(totalSupply() < maxSupply, "Max supply reached");
        
        uint256 petId = nextPetId++;
        bool isGenesis = currentGenesisMinted < genesisSupply;
        
        if (isGenesis) {
            currentGenesisMinted++;
        }
        
        // Generate random attributes
        bytes32 dna = keccak256(abi.encodePacked(
            block.timestamp,
            block.difficulty,
            msg.sender,
            petId,
            name
        ));
        
        uint8 rarity = _determineRarity(dna);
        uint8 element = uint8(uint256(dna) % 8);
        
        // Generate base stats
        (uint16 hp, uint16 energy, uint16 str, uint16 spd, uint16 intel, uint16 def) = 
            _generateBaseStats(rarity, dna);
        
        // Create pet
        pets[petId] = Pet({
            id: petId,
            name: name,
            species: species,
            level: 1,
            rarity: rarity,
            element: element,
            hp: hp,
            maxHp: hp,
            energy: energy,
            maxEnergy: energy,
            happiness: 100,
            experience: 0,
            maxExp: _calculateExpRequirement(1),
            strength: str,
            speed: spd,
            intelligence: intel,
            defense: def,
            lastFed: uint32(block.timestamp),
            lastTrained: 0,
            birthTime: uint32(block.timestamp),
            battleWins: 0,
            battleLosses: 0,
            breedCount: 0,
            parent1: 0,
            parent2: 0,
            dna: dna,
            isGenesis: isGenesis
        });
        
        // Generate traits
        _generateTraits(petId, rarity, element, dna);
        
        _safeMint(msg.sender, petId);
        emit PetMinted(petId, msg.sender, name, rarity, isGenesis);
        
        // Refund excess payment
        if (msg.value > mintPrice) {
            payable(msg.sender).transfer(msg.value - mintPrice);
        }
    }
    
    function mintPetForBreeding(
        address to,
        string memory name,
        string memory species,
        uint8 rarity,
        uint8 element,
        bytes32 dna,
        uint256 parent1,
        uint256 parent2
    ) external onlyAuthorized returns (uint256) {
        require(totalSupply() < maxSupply, "Max supply reached");
        
        uint256 petId = nextPetId++;
        
        // Generate stats for bred pet
        (uint16 hp, uint16 energy, uint16 str, uint16 spd, uint16 intel, uint16 def) = 
            _generateBreedStats(parent1, parent2, rarity, dna);
        
        pets[petId] = Pet({
            id: petId,
            name: name,
            species: species,
            level: 1,
            rarity: rarity,
            element: element,
            hp: hp,
            maxHp: hp,
            energy: energy,
            maxEnergy: energy,
            happiness: 100,
            experience: 0,
            maxExp: _calculateExpRequirement(1),
            strength: str,
            speed: spd,
            intelligence: intel,
            defense: def,
            lastFed: uint32(block.timestamp),
            lastTrained: 0,
            birthTime: uint32(block.timestamp),
            battleWins: 0,
            battleLosses: 0,
            breedCount: 0,
            parent1: parent1,
            parent2: parent2,
            dna: dna,
            isGenesis: false
        });
        
        _generateTraits(petId, rarity, element, dna);
        _safeMint(to, petId);
        
        emit PetMinted(petId, to, name, rarity, false);
        return petId;
    }
    
    // ============================================================================
    // PET CARE FUNCTIONS
    // ============================================================================
    
    function feedPet(uint256 petId) external petExists(petId) onlyPetOwner(petId) nonReentrant {
        Pet storage pet = pets[petId];
        require(block.timestamp >= pet.lastFed + FEED_COOLDOWN, "Pet not hungry yet");
        
        // Calculate happiness and energy gains
        uint16 happinessGain = 10;
        uint16 energyGain = 20;
        
        // Apply bonuses for higher rarity pets
        if (pet.rarity >= 2) { // Epic or Legendary
            happinessGain += 5;
            energyGain += 10;
        }
        
        pet.happiness = _min(pet.happiness + happinessGain, 100);
        pet.energy = _min(pet.energy + energyGain, pet.maxEnergy);
        pet.lastFed = uint32(block.timestamp);
        
        // Reward player with tokens
        uint256 tokenReward = 10 * 10**18; // 10 PETS
        gameToken.mintPlayerRewards(msg.sender, tokenReward);
        
        emit PetFed(petId, happinessGain, energyGain);
    }
    
    function trainPet(uint256 petId, uint8 statType) external petExists(petId) onlyPetOwner(petId) nonReentrant {
        Pet storage pet = pets[petId];
        require(block.timestamp >= pet.lastTrained + TRAIN_COOLDOWN, "Pet tired from training");
        require(pet.energy >= 30, "Pet too tired to train");
        require(statType < 4, "Invalid stat type");
        
        uint256 trainingCost = 50 * 10**18; // 50 PETS
        require(gameToken.balanceOf(msg.sender) >= trainingCost, "Insufficient PETS tokens");
        
        // Transfer training cost
        gameToken.transferFrom(msg.sender, address(this), trainingCost);
        
        // Apply training effects
        pet.energy -= 30;
        pet.lastTrained = uint32(block.timestamp);
        
        uint16 statGain = 2;
        uint32 expGain = 25;
        
        // Happiness affects training efficiency
        if (pet.happiness >= 80) {
            statGain += 1;
            expGain += 10;
        }
        
        // Apply stat gains
        if (statType == 0) pet.strength += statGain;
        else if (statType == 1) pet.speed += statGain;
        else if (statType == 2) pet.intelligence += statGain;
        else if (statType == 3) pet.defense += statGain;
        
        pet.experience += expGain;
        
        emit PetTrained(petId, statType, statGain, expGain);
        
        // Check for level up
        _checkLevelUp(petId);
    }
    
    // ============================================================================
    // GAME MECHANICS
    // ============================================================================
    
    function _checkLevelUp(uint256 petId) internal {
        Pet storage pet = pets[petId];
        
        if (pet.experience >= pet.maxExp && pet.level < MAX_LEVEL) {
            pet.level++;
            pet.experience = pet.experience - pet.maxExp;
            pet.maxExp = _calculateExpRequirement(pet.level);
            
            // Stat increases on level up
            uint16 hpGain = 5 + pet.level / 5;
            uint16 energyGain = 3 + pet.level / 10;
            uint16 statGain = 2 + pet.level / 10;
            
            pet.maxHp += hpGain;
            pet.maxEnergy += energyGain;
            pet.strength += statGain;
            pet.speed += statGain;
            pet.intelligence += statGain;
            pet.defense += statGain;
            
            // Restore some HP and energy
            pet.hp = _min(pet.hp + hpGain, pet.maxHp);
            pet.energy = _min(pet.energy + energyGain, pet.maxEnergy);
            
            emit PetLevelUp(petId, pet.level, ownerOf(petId));
            
            // Check for evolution at certain levels
            _checkEvolution(petId);
        }
    }
    
    function _checkEvolution(uint256 petId) internal {
        Pet storage pet = pets[petId];
        
        // Evolution conditions: level milestones + high happiness
        bool canEvolve = false;
        uint8 newRarity = pet.rarity;
        
        if (pet.level >= 25 && pet.happiness >= 90 && pet.rarity == 0) {
            canEvolve = true;
            newRarity = 1; // Common to Rare
        } else if (pet.level >= 50 && pet.happiness >= 95 && pet.rarity == 1) {
            canEvolve = true;
            newRarity = 2; // Rare to Epic
        } else if (pet.level >= 75 && pet.happiness >= 100 && pet.rarity == 2) {
            canEvolve = true;
            newRarity = 3; // Epic to Legendary
        }
        
        if (canEvolve) {
            pet.rarity = newRarity;
            string memory newSpecies = string(abi.encodePacked("Evolved ", pet.species));
            pet.species = newSpecies;
            
            // Boost stats for evolution
            uint16 statBoost = (newRarity + 1) * 10;
            pet.strength += statBoost;
            pet.speed += statBoost;
            pet.intelligence += statBoost;
            pet.defense += statBoost;
            pet.maxHp += statBoost * 2;
            pet.maxEnergy += statBoost;
            
            emit PetEvolved(petId, newSpecies, newRarity);
        }
    }
    
    // ============================================================================
    // UTILITY FUNCTIONS
    // ============================================================================
    
    function updatePetStats(uint256 petId, Pet memory newStats) external onlyAuthorized petExists(petId) {
        pets[petId] = newStats;
        emit PetStatsUpdated(petId, msg.sender);
    }
    
    function updateHappiness(uint256 petId) external petExists(petId) {
        Pet storage pet = pets[petId];
        uint256 timePassed = block.timestamp - pet.lastFed;
        uint256 happinessDecay = timePassed / HAPPINESS_DECAY_RATE;
        
        if (happinessDecay > 0 && pet.happiness > happinessDecay) {
            pet.happiness -= uint16(happinessDecay);
        } else if (happinessDecay > 0) {
            pet.happiness = 0;
        }
    }
    
    function _determineRarity(bytes32 dna) internal view returns (uint8) {
        uint256 roll = uint256(dna) % 10000;
        uint256 cumulative = 0;
        
        for (uint8 i = 0; i < 4; i++) {
            cumulative += rarityRates[i];
            if (roll < cumulative) {
                return i;
            }
        }
        
        return 0; // Fallback to common
    }
    
    function _generateBaseStats(uint8 rarity, bytes32 dna) internal view returns (
        uint16 hp, uint16 energy, uint16 str, uint16 spd, uint16 intel, uint16 def
    ) {
        uint256 seed = uint256(dna);
        uint16 baseMultiplier = baseStatsMultiplier[rarity];
        
        hp = baseMultiplier + uint16((seed % 30));
        energy = baseMultiplier + uint16(((seed >> 16) % 30));
        str = baseMultiplier + uint16(((seed >> 32) % 25));
        spd = baseMultiplier + uint16(((seed >> 48) % 25));
        intel = baseMultiplier + uint16(((seed >> 64) % 25));
        def = baseMultiplier + uint16(((seed >> 80) % 25));
    }
    
    function _generateBreedStats(uint256 parent1Id, uint256 parent2Id, uint8 rarity, bytes32 dna) internal view returns (
        uint16 hp, uint16 energy, uint16 str, uint16 spd, uint16 intel, uint16 def
    ) {
        Pet memory p1 = pets[parent1Id];
        Pet memory p2 = pets[parent2Id];
        uint256 seed = uint256(dna);
        
        // Inherit average of parents' stats with some randomness
        hp = uint16((p1.maxHp + p2.maxHp) / 2 + (seed % 20) - 10);
        energy = uint16((p1.maxEnergy + p2.maxEnergy) / 2 + ((seed >> 16) % 20) - 10);
        str = uint16((p1.strength + p2.strength) / 2 + ((seed >> 32) % 15) - 7);
        spd = uint16((p1.speed + p2.speed) / 2 + ((seed >> 48) % 15) - 7);
        intel = uint16((p1.intelligence + p2.intelligence) / 2 + ((seed >> 64) % 15) - 7);
        def = uint16((p1.defense + p2.defense) / 2 + ((seed >> 80) % 15) - 7);
        
        // Apply rarity bonus
        uint16 rarityBonus = baseStatsMultiplier[rarity] / 2;
        hp += rarityBonus;
        energy += rarityBonus;
        str += rarityBonus / 2;
        spd += rarityBonus / 2;
        intel += rarityBonus / 2;
        def += rarityBonus / 2;
    }
    
    function _generateTraits(uint256 petId, uint8 rarity, uint8 element, bytes32 dna) internal {
        string[20] memory possibleTraits = [
            "Fire Breath", "Water Walking", "Earth Shake", "Wind Speed",
            "Lightning Strike", "Mystic Vision", "Light Healing", "Shadow Step",
            "Golden Eyes", "Silver Claws", "Diamond Scales", "Crystal Horn",
            "Night Vision", "Telepathy", "Regeneration", "Berserker",
            "Wise", "Lucky", "Brave", "Ancient"
        ];
        
        uint256 seed = uint256(dna);
        uint8 numTraits = 1 + rarity; // More traits for higher rarity
        
        for (uint8 i = 0; i < numTraits && i < 5; i++) {
            uint256 traitIndex = (seed >> (i * 8)) % possibleTraits.length;
            string memory trait = possibleTraits[traitIndex];
            
            if (!petHasTrait[petId][trait]) {
                petTraits[petId].traits.push(trait);
                petHasTrait[petId][trait] = true;
                petTraits[petId].traitCount++;
            }
        }
    }
    
    function _calculateExpRequirement(uint8 level) internal pure returns (uint32) {
        return uint32(1000 * level * level / 2);
    }
    
    function _min(uint16 a, uint16 b) internal pure returns (uint16) {
        return a < b ? a : b;
    }
    
    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================
    
    function getPet(uint256 petId) external view petExists(petId) returns (Pet memory) {
        return pets[petId];
    }
    
    function getPetTraits(uint256 petId) external view petExists(petId) returns (string[] memory) {
        return petTraits[petId].traits;
    }
    
    function getPlayerPets(address player) external view returns (uint256[] memory) {
        uint256 balance = balanceOf(player);
        uint256[] memory playerPets = new uint256[](balance);
        
        for (uint256 i = 0; i < balance; i++) {
            playerPets[i] = tokenOfOwnerByIndex(player, i);
        }
        
        return playerPets;
    }
    
    function getPetsByRarity(uint8 rarity) external view returns (uint256[] memory) {
        uint256 count = 0;
        for (uint256 i = 1; i < nextPetId; i++) {
            if (_exists(i) && pets[i].rarity == rarity) {
                count++;
            }
        }
        
        uint256[] memory rarityPets = new uint256[](count);
        uint256 index = 0;
        
        for (uint256 i = 1; i < nextPetId; i++) {
            if (_exists(i) && pets[i].rarity == rarity) {
                rarityPets[index] = i;
                index++;
            }
        }
        
        return rarityPets;
    }
    
    // ============================================================================
    // EMERGENCY FUNCTIONS
    // ============================================================================
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    function withdraw() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
    
    // ============================================================================
    // OVERRIDE FUNCTIONS
    // ============================================================================
    
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal override(ERC721, ERC721Enumerable) {
        super._beforeTokenTransfer(from, to, tokenId);
        require(!paused(), "Token transfers are paused");
    }
    
    function _burn(uint256 tokenId) internal override(ERC721, ERC721URIStorage) {
        super._burn(tokenId);
    }
    
    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }
    
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC721Enumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
