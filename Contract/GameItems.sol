// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./PetNFT.sol";
import "./GameToken.sol";

/**
 * @title GameItems
 * @dev ERC1155 contract for consumable items, power-ups, and equipment in CryptoPets
 * @notice Features:
 * - Multiple item categories (consumables, equipment, cosmetics, materials)
 * - Crafting system for creating advanced items
 * - Item effects and stat modifications
 * - Limited edition items and seasonal drops
 * - Item marketplace integration
 */
contract GameItems is ERC1155, Ownable, ReentrancyGuard, Pausable {
    
    enum ItemType { CONSUMABLE, EQUIPMENT, COSMETIC, MATERIAL, SPECIAL }
    enum ItemRarity { COMMON, RARE, EPIC, LEGENDARY, MYTHICAL }
    
    struct GameItem {
        uint256 itemId;
        string name;
        string description;
        ItemType itemType;
        ItemRarity rarity;
        uint256 price;              // Price in PETS tokens
        uint256 maxSupply;          // 0 = unlimited
        uint256 totalMinted;
        bool isActive;              // Can be purchased/used
        bool isLimitedEdition;
        uint32 duration;            // Effect duration in seconds (0 = permanent/instant)
        ItemEffects effects;
    }
    
    struct ItemEffects {
        int16 hpModifier;           // HP boost/reduction
        int16 energyModifier;       // Energy boost/reduction
        int16 happinessModifier;    // Happiness boost/reduction
        int16 strengthModifier;     // Strength boost/reduction
        int16 speedModifier;        // Speed boost/reduction
        int16 intelligenceModifier; // Intelligence boost/reduction
        int16 defenseModifier;      // Defense boost/reduction
        int16 expMultiplier;        // Experience multiplier (100 = no change)
        uint16 healingPower;        // Instant healing amount
        uint16 energyRestore;       // Instant energy restore
        bool preventsDeath;         // Saves pet from knockout
        bool grantsImmunity;        // Temporary battle immunity
    }
    
    struct CraftingRecipe {
        uint256 resultItemId;
        uint256[] materialItemIds;
        uint256[] materialAmounts;
        uint256 craftingCost;       // Additional PETS cost
        uint256 craftingTime;       // Time to craft in seconds
        uint256 successRate;        // Success rate out of 10000 (100%)
        bool isActive;
    }
    
    struct ActiveEffect {
        uint256 itemId;
        uint256 petId;
        address owner;
        uint32 appliedAt;
        uint32 expiresAt;
        ItemEffects effects;
    }
    
    struct CraftingOrder {
        uint256 orderId;
        uint256 recipeId;
        address crafter;
        uint32 startTime;
        uint32 completeTime;
        bool completed;
        bool claimed;
    }
    
    // Contract references
    PetNFT public petContract;
    GameToken public gameToken;
    
    // Storage
    mapping(uint256 => GameItem) public gameItems;
    mapping(uint256 => CraftingRecipe) public craftingRecipes;
    mapping(uint256 => ActiveEffect) public activeEffects;
    mapping(uint256 => CraftingOrder) public craftingOrders;
    
    // Active effects tracking
    mapping(uint256 => uint256[]) public petActiveEffects; // petId => effectIds
    mapping(address => uint256[]) public userCraftingOrders;
    
    // Counters
    uint256 public nextItemId = 1;
    uint256 public nextRecipeId = 1;
    uint256 public nextEffectId = 1;
    uint256 public nextOrderId = 1;
    
    // Item shop configuration
    bool public shopEnabled = true;
    address public shopTreasury;
    
    // Events
    event ItemCreated(uint256 indexed itemId, string name, ItemType itemType, ItemRarity rarity);
    event ItemPurchased(address indexed buyer, uint256 indexed itemId, uint256 amount, uint256 totalCost);
    event ItemUsed(address indexed user, uint256 indexed itemId, uint256 indexed petId, uint256 effectId);
    event CraftingStarted(address indexed crafter, uint256 indexed orderId, uint256 recipeId);
    event CraftingCompleted(address indexed crafter, uint256 indexed orderId, uint256 resultItemId, bool success);
    event EffectExpired(uint256 indexed effectId, uint256 indexed petId);
    
    constructor(
        address _petContract,
        address _gameToken,
        address _shopTreasury,
        string memory _baseURI
    ) ERC1155(_baseURI) {
        petContract = PetNFT(_petContract);
        gameToken = GameToken(_gameToken);
        shopTreasury = _shopTreasury;
        
        _createDefaultItems();
        _createDefaultRecipes();
    }
    
    function _createDefaultItems() internal {
        // Basic consumables
        _createItem(
            "Health Potion",
            "Restores 50 HP instantly",
            ItemType.CONSUMABLE,
            ItemRarity.COMMON,
            50 * 10**18,  // 50 PETS
            0,            // Unlimited supply
            false,        // Not limited edition
            0,            // Instant effect
            ItemEffects({
                hpModifier: 0,
                energyModifier: 0,
                happinessModifier: 0,
                strengthModifier: 0,
                speedModifier: 0,
                intelligenceModifier: 0,
                defenseModifier: 0,
                expMultiplier: 100,
                healingPower: 50,
                energyRestore: 0,
                preventsDeath: false,
                grantsImmunity: false
            })
        );
        
        _createItem(
            "Energy Drink",
            "Restores 30 energy instantly",
            ItemType.CONSUMABLE,
            ItemRarity.COMMON,
            30 * 10**18,  // 30 PETS
            0,
            false,
            0,
            ItemEffects({
                hpModifier: 0,
                energyModifier: 0,
                happinessModifier: 5,
                strengthModifier: 0,
                speedModifier: 0,
                intelligenceModifier: 0,
                defenseModifier: 0,
                expMultiplier: 100,
                healingPower: 0,
                energyRestore: 30,
                preventsDeath: false,
                grantsImmunity: false
            })
        );
        
        // Training boosters
        _createItem(
            "Strength Elixir",
            "Increases strength by 10 for 1 hour",
            ItemType.CONSUMABLE,
            ItemRarity.RARE,
            200 * 10**18, // 200 PETS
            0,
            false,
            3600,         // 1 hour duration
            ItemEffects({
                hpModifier: 0,
                energyModifier: 0,
                happinessModifier: 0,
                strengthModifier: 10,
                speedModifier: 0,
                intelligenceModifier: 0,
                defenseModifier: 0,
                expMultiplier: 100,
                healingPower: 0,
                energyRestore: 0,
                preventsDeath: false,
                grantsImmunity: false
            })
        );
        
        _createItem(
            "XP Booster",
            "Doubles experience gain for 2 hours",
            ItemType.CONSUMABLE,
            ItemRarity.EPIC,
            500 * 10**18, // 500 PETS
            0,
            false,
            7200,         // 2 hours
            ItemEffects({
                hpModifier: 0,
                energyModifier: 0,
                happinessModifier: 10,
                strengthModifier: 0,
                speedModifier: 0,
                intelligenceModifier: 0,
                defenseModifier: 0,
                expMultiplier: 200, // Double XP
                healingPower: 0,
                energyRestore: 0,
                preventsDeath: false,
                grantsImmunity: false
            })
        );
        
        // Special items
        _createItem(
            "Phoenix Feather",
            "Prevents pet death once",
            ItemType.SPECIAL,
            ItemRarity.LEGENDARY,
            2000 * 10**18, // 2000 PETS
            100,           // Limited to 100
            true,
            0,             // Instant/permanent
            ItemEffects({
                hpModifier: 0,
                energyModifier: 0,
                happinessModifier: 0,
                strengthModifier: 0,
                speedModifier: 0,
                intelligenceModifier: 0,
                defenseModifier: 0,
                expMultiplier: 100,
                healingPower: 0,
                energyRestore: 0,
                preventsDeath: true,
                grantsImmunity: false
            })
        );
        
        // Crafting materials
        _createItem(
            "Magic Essence",
            "Mystical crafting material",
            ItemType.MATERIAL,
            ItemRarity.RARE,
            100 * 10**18, // 100 PETS
            0,
            false,
            0,
            ItemEffects({
                hpModifier: 0,
                energyModifier: 0,
                happinessModifier: 0,
                strengthModifier: 0,
                speedModifier: 0,
                intelligenceModifier: 0,
                defenseModifier: 0,
                expMultiplier: 100,
                healingPower: 0,
                energyRestore: 0,
                preventsDeath: false,
                grantsImmunity: false
            })
        );
        
        _createItem(
            "Dragon Scale",
            "Rare crafting material from dragons",
            ItemType.MATERIAL,
            ItemRarity.EPIC,
            300 * 10**18, // 300 PETS
            0,
            false,
            0,
            ItemEffects({
                hpModifier: 0,
                energyModifier: 0,
                happinessModifier: 0,
                strengthModifier: 0,
                speedModifier: 0,
                intelligenceModifier: 0,
                defenseModifier: 0,
                expMultiplier: 100,
                healingPower: 0,
                energyRestore: 0,
                preventsDeath: false,
                grantsImmunity: false
            })
        );
    }
    
    function _createDefaultRecipes() internal {
        // Super Health Potion recipe
        uint256[] memory materials1 = new uint256[](2);
        materials1[0] = 1; // Health Potion
        materials1[1] = 6; // Magic Essence
        
        uint256[] memory amounts1 = new uint256[](2);
        amounts1[0] = 3; // 3 Health Potions
        amounts1[1] = 1; // 1 Magic Essence
        
        _createCraftingRecipe(
            8, // Result: Super Health Potion (to be created)
            materials1,
            amounts1,
            100 * 10**18, // 100 PETS crafting cost
            1800,         // 30 minutes
            8500          // 85% success rate
        );
    }
    
    // ============================================================================
    // ITEM MANAGEMENT
    // ============================================================================
    
    function _createItem(
        string memory name,
        string memory description,
        ItemType itemType,
        ItemRarity rarity,
        uint256 price,
        uint256 maxSupply,
        bool isLimitedEdition,
        uint32 duration,
        ItemEffects memory effects
    ) internal returns (uint256) {
        uint256 itemId = nextItemId++;
        
        gameItems[itemId] = GameItem({
            itemId: itemId,
            name: name,
            description: description,
            itemType: itemType,
            rarity: rarity,
            price: price,
            maxSupply: maxSupply,
            totalMinted: 0,
            isActive: true,
            isLimitedEdition: isLimitedEdition,
            duration: duration,
            effects: effects
        });
        
        emit ItemCreated(itemId, name, itemType, rarity);
        return itemId;
    }
    
    function createItem(
        string calldata name,
        string calldata description,
        ItemType itemType,
        ItemRarity rarity,
        uint256 price,
        uint256 maxSupply,
        bool isLimitedEdition,
        uint32 duration,
        ItemEffects calldata effects
    ) external onlyOwner returns (uint256) {
        return _createItem(name, description, itemType, rarity, price, maxSupply, isLimitedEdition, duration, effects);
    }
    
    function updateItemPrice(uint256 itemId, uint256 newPrice) external onlyOwner {
        require(gameItems[itemId].itemId != 0, "Item does not exist");
        gameItems[itemId].price = newPrice;
    }
    
    function toggleItemActive(uint256 itemId) external onlyOwner {
        require(gameItems[itemId].itemId != 0, "Item does not exist");
        gameItems[itemId].isActive = !gameItems[itemId].isActive;
    }
    
    // ============================================================================
    // ITEM SHOP
    // ============================================================================
    
    function purchaseItem(uint256 itemId, uint256 amount) external nonReentrant whenNotPaused {
        require(shopEnabled, "Shop is disabled");
        require(gameItems[itemId].isActive, "Item not available");
        require(amount > 0, "Amount must be greater than 0");
        
        GameItem storage item = gameItems[itemId];
        
        // Check supply limit
        if (item.maxSupply > 0) {
            require(item.totalMinted + amount <= item.maxSupply, "Exceeds maximum supply");
        }
        
        uint256 totalCost = item.price * amount;
        require(gameToken.balanceOf(msg.sender) >= totalCost, "Insufficient PETS tokens");
        
        // Transfer payment
        gameToken.transferFrom(msg.sender, shopTreasury, totalCost);
        
        // Mint items to buyer
        _mint(msg.sender, itemId, amount, "");
        
        // Update supply tracking
        item.totalMinted += amount;
        
        emit ItemPurchased(msg.sender, itemId, amount, totalCost);
    }
    
    function purchaseItemBatch(
        uint256[] calldata itemIds,
        uint256[] calldata amounts
    ) external nonReentrant whenNotPaused {
        require(shopEnabled, "Shop is disabled");
        require(itemIds.length == amounts.length, "Array length mismatch");
        require(itemIds.length > 0, "Empty arrays");
        
        uint256 totalCost = 0;
        
        // Calculate total cost and validate
        for (uint256 i = 0; i < itemIds.length; i++) {
            uint256 itemId = itemIds[i];
            uint256 amount = amounts[i];
            
            require(gameItems[itemId].isActive, "Item not available");
            require(amount > 0, "Amount must be greater than 0");
            
            GameItem storage item = gameItems[itemId];
            
            if (item.maxSupply > 0) {
                require(item.totalMinted + amount <= item.maxSupply, "Exceeds maximum supply");
            }
            
            totalCost += item.price * amount;
        }
        
        require(gameToken.balanceOf(msg.sender) >= totalCost, "Insufficient PETS tokens");
        
        // Transfer payment
        gameToken.transferFrom(msg.sender, shopTreasury, totalCost);
        
        // Mint items
        for (uint256 i = 0; i < itemIds.length; i++) {
            _mint(msg.sender, itemIds[i], amounts[i], "");
            gameItems[itemIds[i]].totalMinted += amounts[i];
            emit ItemPurchased(msg.sender, itemIds[i], amounts[i], gameItems[itemIds[i]].price * amounts[i]);
        }
    }
    
    // ============================================================================
    // ITEM USAGE
    // ============================================================================
    
    function useItem(uint256 itemId, uint256 petId) external nonReentrant whenNotPaused {
        require(balanceOf(msg.sender, itemId) > 0, "You don't own this item");
        require(petContract.ownerOf(petId) == msg.sender, "Not pet owner");
        
        GameItem storage item = gameItems[itemId];
        require(item.itemType == ItemType.CONSUMABLE || item.itemType == ItemType.SPECIAL, "Item not consumable");
        
        PetNFT.Pet memory pet = petContract.getPet(petId);
        
        // Burn the item
        _burn(msg.sender, itemId, 1);
        
        // Apply item effects
        uint256 effectId = _applyItemEffects(itemId, petId, pet, item);
        
        emit ItemUsed(msg.sender, itemId, petId, effectId);
    }
    
    function _applyItemEffects(
        uint256 itemId,
        uint256 petId,
        PetNFT.Pet memory pet,
        GameItem storage item
    ) internal returns (uint256 effectId) {
        
        // Apply instant effects
        if (item.effects.healingPower > 0) {
            pet.hp = _min(pet.hp + item.effects.healingPower, pet.maxHp);
        }
        
        if (item.effects.energyRestore > 0) {
            pet.energy = _min(pet.energy + item.effects.energyRestore, pet.maxEnergy);
        }
        
        if (item.effects.happinessModifier != 0) {
            if (item.effects.happinessModifier > 0) {
                pet.happiness = _min(pet.happiness + uint16(item.effects.happinessModifier), 100);
            } else {
                pet.happiness = pet.happiness > uint16(-item.effects.happinessModifier) ? 
                    pet.happiness - uint16(-item.effects.happinessModifier) : 0;
            }
        }
        
        // Apply permanent stat modifiers (for equipment)
        if (item.duration == 0 && _hasStatModifiers(item.effects)) {
            _applyPermanentStatModifiers(pet, item.effects);
        }
        
        // Update pet stats
        petContract.updatePetStats(petId, pet);
        
        // Create timed effect if duration > 0
        if (item.duration > 0) {
            effectId = nextEffectId++;
            uint32 expiresAt = uint32(block.timestamp) + item.duration;
            
            activeEffects[effectId] = ActiveEffect({
                itemId: itemId,
                petId: petId,
                owner: msg.sender,
                appliedAt: uint32(block.timestamp),
                expiresAt: expiresAt,
                effects: item.effects
            });
            
            petActiveEffects[petId].push(effectId);
        }
        
        return effectId;
    }
    
    function _hasStatModifiers(ItemEffects memory effects) internal pure returns (bool) {
        return effects.strengthModifier != 0 || 
               effects.speedModifier != 0 || 
               effects.intelligenceModifier != 0 || 
               effects.defenseModifier != 0 ||
               effects.hpModifier != 0 ||
               effects.energyModifier != 0;
    }
    
    function _applyPermanentStatModifiers(PetNFT.Pet memory pet, ItemEffects memory effects) internal pure {
        if (effects.hpModifier != 0) {
            if (effects.hpModifier > 0) {
                pet.maxHp += uint16(effects.hpModifier);
                pet.hp += uint16(effects.hpModifier);
            }
        }
        
        if (effects.energyModifier != 0) {
            if (effects.energyModifier > 0) {
                pet.maxEnergy += uint16(effects.energyModifier);
                pet.energy += uint16(effects.energyModifier);
            }
        }
        
        if (effects.strengthModifier != 0) {
            if (effects.strengthModifier > 0) {
                pet.strength += uint16(effects.strengthModifier);
            }
        }
        
        if (effects.speedModifier != 0) {
            if (effects.speedModifier > 0) {
                pet.speed += uint16(effects.speedModifier);
            }
        }
        
        if (effects.intelligenceModifier != 0) {
            if (effects.intelligenceModifier > 0) {
                pet.intelligence += uint16(effects.intelligenceModifier);
            }
        }
        
        if (effects.defenseModifier != 0) {
            if (effects.defenseModifier > 0) {
                pet.defense += uint16(effects.defenseModifier);
            }
        }
    }
    
    // ============================================================================
    // EFFECT MANAGEMENT
    // ============================================================================
    
    function removeExpiredEffects(uint256[] calldata effectIds) external {
        for (uint256 i = 0; i < effectIds.length; i++) {
            uint256 effectId = effectIds[i];
            ActiveEffect storage effect = activeEffects[effectId];
            
            require(effect.petId != 0, "Effect does not exist");
            require(block.timestamp >= effect.expiresAt, "Effect not expired");
            
            // Remove from pet's active effects
            _removeEffectFromPet(effect.petId, effectId);
            
            // Clean up effect
            delete activeEffects[effectId];
            
            emit EffectExpired(effectId, effect.petId);
        }
    }
    
    function _removeEffectFromPet(uint256 petId, uint256 effectId) internal {
        uint256[] storage effects = petActiveEffects[petId];
        for (uint256 i = 0; i < effects.length; i++) {
            if (effects[i] == effectId) {
                effects[i] = effects[effects.length - 1];
                effects.pop();
                break;
            }
        }
    }
    
    // ============================================================================
    // CRAFTING SYSTEM
    // ============================================================================
    
    function _createCraftingRecipe(
        uint256 resultItemId,
        uint256[] memory materialItemIds,
        uint256[] memory materialAmounts,
        uint256 craftingCost,
        uint256 craftingTime,
        uint256 successRate
    ) internal returns (uint256) {
        uint256 recipeId = nextRecipeId++;
        
        craftingRecipes[recipeId] = CraftingRecipe({
            resultItemId: resultItemId,
            materialItemIds: materialItemIds,
            materialAmounts: materialAmounts,
            craftingCost: craftingCost,
            craftingTime: craftingTime,
            successRate: successRate,
            isActive: true
        });
        
        return recipeId;
    }
    
    function startCrafting(uint256 recipeId) external nonReentrant whenNotPaused {
        CraftingRecipe storage recipe = craftingRecipes[recipeId];
        require(recipe.isActive, "Recipe not active");
        require(gameItems[recipe.resultItemId].itemId != 0, "Result item does not exist");
        
        // Check materials
        for (uint256 i = 0; i < recipe.materialItemIds.length; i++) {
            require(
                balanceOf(msg.sender, recipe.materialItemIds[i]) >= recipe.materialAmounts[i],
                "Insufficient materials"
            );
        }
        
        // Check crafting cost
        if (recipe.craftingCost > 0) {
            require(gameToken.balanceOf(msg.sender) >= recipe.craftingCost, "Insufficient PETS tokens");
            gameToken.transferFrom(msg.sender, shopTreasury, recipe.craftingCost);
        }
        
        // Consume materials
        for (uint256 i = 0; i < recipe.materialItemIds.length; i++) {
            _burn(msg.sender, recipe.materialItemIds[i], recipe.materialAmounts[i]);
        }
        
        uint256 orderId = nextOrderId++;
        uint32 completeTime = uint32(block.timestamp) + uint32(recipe.craftingTime);
        
        craftingOrders[orderId] = CraftingOrder({
            orderId: orderId,
            recipeId: recipeId,
            crafter: msg.sender,
            startTime: uint32(block.timestamp),
            completeTime: completeTime,
            completed: false,
            claimed: false
        });
        
        userCraftingOrders[msg.sender].push(orderId);
        
        emit CraftingStarted(msg.sender, orderId, recipeId);
    }
    
    function completeCrafting(uint256 orderId) external nonReentrant {
        CraftingOrder storage order = craftingOrders[orderId];
        require(order.crafter == msg.sender, "Not your crafting order");
        require(!order.completed, "Already completed");
        require(block.timestamp >= order.completeTime, "Crafting not finished");
        
        CraftingRecipe storage recipe = craftingRecipes[order.recipeId];
        
        // Determine success
        bool success = (uint256(keccak256(abi.encodePacked(block.timestamp, block.difficulty, orderId))) % 10000) < recipe.successRate;
        
        order.completed = true;
        
        if (success) {
            // Mint result item
            _mint(msg.sender, recipe.resultItemId, 1, "");
            gameItems[recipe.resultItemId].totalMinted += 1;
        }
        
        emit CraftingCompleted(msg.sender, orderId, recipe.resultItemId, success);
    }
    
    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================
    
    function getGameItem(uint256 itemId) external view returns (GameItem memory) {
        return gameItems[itemId];
    }
    
    function getCraftingRecipe(uint256 recipeId) external view returns (CraftingRecipe memory) {
        return craftingRecipes[recipeId];
    }
    
    function getActiveEffect(uint256 effectId) external view returns (ActiveEffect memory) {
        return activeEffects[effectId];
    }
    
    function getPetActiveEffects(uint256 petId) external view returns (uint256[] memory) {
        return petActiveEffects[petId];
    }
    
    function getUserCraftingOrders(address user) external view returns (uint256[] memory) {
        return userCraftingOrders[user];
    }
    
    function calculateItemEffectsOnPet(uint256 petId) external view returns (
        int16 totalHpModifier,
        int16 totalEnergyModifier,
        int16 totalStrengthModifier,
        int16 totalSpeedModifier,
        int16 totalIntelligenceModifier,
        int16 totalDefenseModifier,
        int16 totalExpMultiplier
    ) {
        uint256[] memory effects = petActiveEffects[petId];
        totalExpMultiplier = 100; // Base multiplier
        
        for (uint256 i = 0; i < effects.length; i++) {
            ActiveEffect storage effect = activeEffects[effects[i]];
            if (block.timestamp < effect.expiresAt) {
                totalHpModifier += effect.effects.hpModifier;
                totalEnergyModifier += effect.effects.energyModifier;
                totalStrengthModifier += effect.effects.strengthModifier;
                totalSpeedModifier += effect.effects.speedModifier;
                totalIntelligenceModifier += effect.effects.intelligenceModifier;
                totalDefenseModifier += effect.effects.defenseModifier;
                if (effect.effects.expMultiplier != 100) {
                    totalExpMultiplier = (totalExpMultiplier * effect.effects.expMultiplier) / 100;
                }
            }
        }
    }
    
    // ============================================================================
    // UTILITY FUNCTIONS
    // ============================================================================
    
    function _min(uint16 a, uint16 b) internal pure returns (uint16) {
        return a < b ? a : b;
    }
    
    // ============================================================================
    // ADMIN FUNCTIONS
    // ============================================================================
    
    function setShopEnabled(bool enabled) external onlyOwner {
        shopEnabled = enabled;
    }
    
    function setShopTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Invalid treasury address");
        shopTreasury = newTreasury;
    }
    
    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        _setURI(newBaseURI);
    }
    
    function mintItemToUser(address user, uint256 itemId, uint256 amount) external onlyOwner {
        _mint(user, itemId, amount, "");
        gameItems[itemId].totalMinted += amount;
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
