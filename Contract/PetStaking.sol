// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "./PetNFT.sol";
import "./GameToken.sol";

/**
 * @title PetStaking
 * @dev Staking contract for earning PETS tokens with pet NFTs
 * @notice Features:
 * - Multiple staking pools with different reward rates
 * - Rarity-based multipliers
 * - Lock periods for bonus rewards
 * - Element-based seasonal events
 * - Compound staking for increased yields
 */
contract PetStaking is Ownable, ReentrancyGuard, Pausable, IERC721Receiver {
    
    struct StakingPool {
        uint256 poolId;
        string name;
        uint256 baseRewardRate;     // PETS per second per pet
        uint256 lockPeriod;         // Minimum lock time in seconds
        uint256 bonusMultiplier;    // Bonus multiplier for this pool (100 = no bonus)
        uint256 maxPetsPerUser;     // Maximum pets per user in this pool
        uint8 requiredRarity;       // Minimum rarity required (255 = no requirement)
        uint8 requiredElement;      // Required element (255 = no requirement)
        bool isActive;
        uint256 totalStaked;
        uint256 totalStakers;
    }
    
    struct StakedPet {
        uint256 petId;
        uint256 poolId;
        address owner;
        uint256 stakedAt;
        uint256 lockedUntil;
        uint256 lastRewardClaim;
        uint256 pendingRewards;
        bool isCompounding;         // Auto-compound rewards
        uint16 rarityMultiplier;    // Cached rarity multiplier
    }
    
    struct UserStaking {
        uint256[] stakedPets;
        uint256 totalRewardsEarned;
        uint256 totalRewardsClaimed;
        uint32 firstStakeTime;
        uint16 loyaltyMultiplier;   // Loyalty bonus based on staking duration
    }
    
    // Contract references
    PetNFT public petContract;
    GameToken public gameToken;
    
    // Staking storage
    mapping(uint256 => StakingPool) public stakingPools;
    mapping(uint256 => StakedPet) public stakedPets;
    mapping(address => UserStaking) public userStaking;
    mapping(uint256 => mapping(address => uint256)) public userPoolStakeCount;
    mapping(uint256 => bool) public isPetStaked;
    
    // Pool management
    uint256 public nextPoolId = 1;
    uint256 public totalPetsStaked;
    uint256 public totalRewardsDistributed;
    
    // Rarity multipliers (basis points: 100 = 1%)
    uint16[4] public rarityMultipliers = [10000, 12000, 15000, 20000]; // 100%, 120%, 150%, 200%
    
    // Loyalty system
    uint256 public constant LOYALTY_TIER_DURATION = 2592000; // 30 days
    uint16[5] public loyaltyMultipliers = [10000, 10500, 11000, 11500, 12000]; // Max 120%
    
    // Emergency controls
    bool public emergencyWithdrawEnabled = false;
    
    // Events
    event PetStaked(address indexed user, uint256 indexed petId, uint256 indexed poolId);
    event PetUnstaked(address indexed user, uint256 indexed petId, uint256 rewards);
    event RewardsClaimed(address indexed user, uint256 amount);
    event PoolCreated(uint256 indexed poolId, string name, uint256 baseRewardRate);
    event PoolUpdated(uint256 indexed poolId, uint256 newRewardRate);
    event CompoundingToggled(address indexed user, uint256 indexed petId, bool enabled);
    
    constructor(
        address _petContract,
        address _gameToken
    ) {
        petContract = PetNFT(_petContract);
        gameToken = GameToken(_gameToken);
        
        _createDefaultPools();
    }
    
    function _createDefaultPools() internal {
        // Basic staking pool - no requirements
        _createPool(
            "Basic Staking",
            1157407407407, // ~100 PETS per day
            0,             // No lock period
            10000,         // No bonus
            50,            // Max 50 pets per user
            255,           // No rarity requirement
            255            // No element requirement
        );
        
        // Premium pool - higher rewards, longer lock
        _createPool(
            "Premium Lock",
            3472222222222, // ~300 PETS per day
            2592000,       // 30 day lock
            15000,         // 50% bonus
            20,            // Max 20 pets per user
            1,             // Rare or better required
            255            // No element requirement
        );
        
        // Elite pool - highest rewards, longest lock, legendary only
        _createPool(
            "Elite Vault",
            11574074074074, // ~1000 PETS per day
            7776000,        // 90 day lock
            25000,          // 150% bonus
            5,              // Max 5 pets per user
            3,              // Legendary required
            255             // No element requirement
        );
    }
    
    // ============================================================================
    // STAKING FUNCTIONS
    // ============================================================================
    
    function stakePet(uint256 petId, uint256 poolId) external nonReentrant whenNotPaused {
        require(petContract.ownerOf(petId) == msg.sender, "Not pet owner");
        require(!isPetStaked[petId], "Pet already staked");
        require(stakingPools[poolId].isActive, "Pool not active");
        
        StakingPool storage pool = stakingPools[poolId];
        PetNFT.Pet memory pet = petContract.getPet(petId);
        
        _validateStakingRequirements(pool, pet, msg.sender);
        
        // Transfer pet to staking contract
        petContract.transferFrom(msg.sender, address(this), petId);
        
        // Calculate lock period
        uint256 lockedUntil = block.timestamp + pool.lockPeriod;
        
        // Create staking record
        stakedPets[petId] = StakedPet({
            petId: petId,
            poolId: poolId,
            owner: msg.sender,
            stakedAt: block.timestamp,
            lockedUntil: lockedUntil,
            lastRewardClaim: block.timestamp,
            pendingRewards: 0,
            isCompounding: false,
            rarityMultiplier: rarityMultipliers[pet.rarity]
        });
        
        // Update user staking info
        if (userStaking[msg.sender].firstStakeTime == 0) {
            userStaking[msg.sender].firstStakeTime = uint32(block.timestamp);
        }
        userStaking[msg.sender].stakedPets.push(petId);
        
        // Update pool and global counters
        isPetStaked[petId] = true;
        userPoolStakeCount[poolId][msg.sender]++;
        pool.totalStaked++;
        if (userPoolStakeCount[poolId][msg.sender] == 1) {
            pool.totalStakers++;
        }
        totalPetsStaked++;
        
        emit PetStaked(msg.sender, petId, poolId);
    }
    
    function stakePetBatch(uint256[] calldata petIds, uint256 poolId) external nonReentrant whenNotPaused {
        require(petIds.length > 0 && petIds.length <= 20, "Invalid batch size");
        
        for (uint256 i = 0; i < petIds.length; i++) {
            _stakePetInternal(petIds[i], poolId, msg.sender);
        }
    }
    
    function _stakePetInternal(uint256 petId, uint256 poolId, address owner) internal {
        require(petContract.ownerOf(petId) == owner, "Not pet owner");
        require(!isPetStaked[petId], "Pet already staked");
        require(stakingPools[poolId].isActive, "Pool not active");
        
        StakingPool storage pool = stakingPools[poolId];
        PetNFT.Pet memory pet = petContract.getPet(petId);
        
        _validateStakingRequirements(pool, pet, owner);
        
        petContract.transferFrom(owner, address(this), petId);
        
        uint256 lockedUntil = block.timestamp + pool.lockPeriod;
        
        stakedPets[petId] = StakedPet({
            petId: petId,
            poolId: poolId,
            owner: owner,
            stakedAt: block.timestamp,
            lockedUntil: lockedUntil,
            lastRewardClaim: block.timestamp,
            pendingRewards: 0,
            isCompounding: false,
            rarityMultiplier: rarityMultipliers[pet.rarity]
        });
        
        if (userStaking[owner].firstStakeTime == 0) {
            userStaking[owner].firstStakeTime = uint32(block.timestamp);
        }
        userStaking[owner].stakedPets.push(petId);
        
        isPetStaked[petId] = true;
        userPoolStakeCount[poolId][owner]++;
        pool.totalStaked++;
        if (userPoolStakeCount[poolId][owner] == 1) {
            pool.totalStakers++;
        }
        totalPetsStaked++;
        
        emit PetStaked(owner, petId, poolId);
    }
    
    function _validateStakingRequirements(
        StakingPool storage pool,
        PetNFT.Pet memory pet,
        address user
    ) internal view {
        require(userPoolStakeCount[pool.poolId][user] < pool.maxPetsPerUser, "Pool limit reached");
        
        if (pool.requiredRarity < 255) {
            require(pet.rarity >= pool.requiredRarity, "Pet rarity too low");
        }
        
        if (pool.requiredElement < 255) {
            require(pet.element == pool.requiredElement, "Wrong element required");
        }
    }
    
    // ============================================================================
    // UNSTAKING FUNCTIONS
    // ============================================================================
    
    function unstakePet(uint256 petId) external nonReentrant {
        StakedPet storage stake = stakedPets[petId];
        require(stake.owner == msg.sender, "Not stake owner");
        require(block.timestamp >= stake.lockedUntil || emergencyWithdrawEnabled, "Still locked");
        
        // Calculate and claim pending rewards
        uint256 rewards = _calculatePendingRewards(petId);
        if (rewards > 0) {
            _claimRewards(msg.sender, petId, rewards);
        }
        
        // Update pool counters
        StakingPool storage pool = stakingPools[stake.poolId];
        pool.totalStaked--;
        userPoolStakeCount[stake.poolId][msg.sender]--;
        if (userPoolStakeCount[stake.poolId][msg.sender] == 0) {
            pool.totalStakers--;
        }
        totalPetsStaked--;
        
        // Remove from user's staked pets array
        _removeStakedPet(msg.sender, petId);
        
        // Return pet to owner
        petContract.transferFrom(address(this), msg.sender, petId);
        
        // Clean up staking record
        isPetStaked[petId] = false;
        delete stakedPets[petId];
        
        emit PetUnstaked(msg.sender, petId, rewards);
    }
    
    function unstakePetBatch(uint256[] calldata petIds) external nonReentrant {
        uint256 totalRewards = 0;
        
        for (uint256 i = 0; i < petIds.length; i++) {
            StakedPet storage stake = stakedPets[petIds[i]];
            require(stake.owner == msg.sender, "Not stake owner");
            require(block.timestamp >= stake.lockedUntil || emergencyWithdrawEnabled, "Still locked");
            
            uint256 rewards = _calculatePendingRewards(petIds[i]);
            totalRewards += rewards;
            
            _unstakePetInternal(petIds[i], msg.sender);
        }
        
        if (totalRewards > 0) {
            gameToken.mintPlayerRewards(msg.sender, totalRewards);
            userStaking[msg.sender].totalRewardsClaimed += totalRewards;
            totalRewardsDistributed += totalRewards;
        }
    }
    
    function _unstakePetInternal(uint256 petId, address owner) internal {
        StakedPet storage stake = stakedPets[petId];
        
        StakingPool storage pool = stakingPools[stake.poolId];
        pool.totalStaked--;
        userPoolStakeCount[stake.poolId][owner]--;
        if (userPoolStakeCount[stake.poolId][owner] == 0) {
            pool.totalStakers--;
        }
        totalPetsStaked--;
        
        _removeStakedPet(owner, petId);
        petContract.transferFrom(address(this), owner, petId);
        
        isPetStaked[petId] = false;
        delete stakedPets[petId];
        
        emit PetUnstaked(owner, petId, 0);
    }
    
    // ============================================================================
    // REWARD FUNCTIONS
    // ============================================================================
    
    function claimRewards(uint256[] calldata petIds) external nonReentrant {
        uint256 totalRewards = 0;
        
        for (uint256 i = 0; i < petIds.length; i++) {
            require(stakedPets[petIds[i]].owner == msg.sender, "Not stake owner");
            uint256 rewards = _calculatePendingRewards(petIds[i]);
            if (rewards > 0) {
                totalRewards += rewards;
                stakedPets[petIds[i]].lastRewardClaim = block.timestamp;
                stakedPets[petIds[i]].pendingRewards = 0;
            }
        }
        
        if (totalRewards > 0) {
            _claimRewards(msg.sender, 0, totalRewards);
        }
    }
    
    function claimAllRewards() external nonReentrant {
        uint256[] memory userPets = userStaking[msg.sender].stakedPets;
        uint256 totalRewards = 0;
        
        for (uint256 i = 0; i < userPets.length; i++) {
            uint256 petId = userPets[i];
            if (isPetStaked[petId] && stakedPets[petId].owner == msg.sender) {
                uint256 rewards = _calculatePendingRewards(petId);
                if (rewards > 0) {
                    totalRewards += rewards;
                    stakedPets[petId].lastRewardClaim = block.timestamp;
                    stakedPets[petId].pendingRewards = 0;
                }
            }
        }
        
        if (totalRewards > 0) {
            _claimRewards(msg.sender, 0, totalRewards);
        }
    }
    
    function _claimRewards(address user, uint256 petId, uint256 amount) internal {
        gameToken.mintPlayerRewards(user, amount);
        userStaking[user].totalRewardsClaimed += amount;
        userStaking[user].totalRewardsEarned += amount;
        totalRewardsDistributed += amount;
        
        emit RewardsClaimed(user, amount);
    }
    
    // ============================================================================
    // CALCULATION FUNCTIONS
    // ============================================================================
    
    function _calculatePendingRewards(uint256 petId) internal view returns (uint256) {
        StakedPet storage stake = stakedPets[petId];
        if (stake.owner == address(0)) return 0;
        
        StakingPool storage pool = stakingPools[stake.poolId];
        uint256 timeStaked = block.timestamp - stake.lastRewardClaim;
        
        // Base rewards
        uint256 baseRewards = timeStaked * pool.baseRewardRate;
        
        // Apply rarity multiplier
        uint256 rarityRewards = (baseRewards * stake.rarityMultiplier) / 10000;
        
        // Apply pool bonus
        uint256 poolRewards = (rarityRewards * pool.bonusMultiplier) / 10000;
        
        // Apply loyalty multiplier
        uint256 loyaltyMultiplier = _calculateLoyaltyMultiplier(stake.owner);
        uint256 finalRewards = (poolRewards * loyaltyMultiplier) / 10000;
        
        return finalRewards + stake.pendingRewards;
    }
    
    function _calculateLoyaltyMultiplier(address user) internal view returns (uint256) {
        if (userStaking[user].firstStakeTime == 0) return loyaltyMultipliers[0];
        
        uint256 stakingDuration = block.timestamp - userStaking[user].firstStakeTime;
        uint256 loyaltyTier = stakingDuration / LOYALTY_TIER_DURATION;
        
        if (loyaltyTier >= loyaltyMultipliers.length) {
            loyaltyTier = loyaltyMultipliers.length - 1;
        }
        
        return loyaltyMultipliers[loyaltyTier];
    }
    
    // ============================================================================
    // COMPOUNDING FUNCTIONS
    // ============================================================================
    
    function toggleCompounding(uint256 petId) external {
        require(stakedPets[petId].owner == msg.sender, "Not stake owner");
        
        StakedPet storage stake = stakedPets[petId];
        stake.isCompounding = !stake.isCompounding;
        
        emit CompoundingToggled(msg.sender, petId, stake.isCompounding);
    }
    
    function compoundRewards(uint256[] calldata petIds) external nonReentrant {
        for (uint256 i = 0; i < petIds.length; i++) {
            StakedPet storage stake = stakedPets[petIds[i]];
            require(stake.owner == msg.sender, "Not stake owner");
            require(stake.isCompounding, "Compounding not enabled");
            
            uint256 rewards = _calculatePendingRewards(petIds[i]);
            if (rewards > 0) {
                stake.pendingRewards += rewards;
                stake.lastRewardClaim = block.timestamp;
            }
        }
    }
    
    // ============================================================================
    // POOL MANAGEMENT
    // ============================================================================
    
    function _createPool(
        string memory name,
        uint256 baseRewardRate,
        uint256 lockPeriod,
        uint256 bonusMultiplier,
        uint256 maxPetsPerUser,
        uint8 requiredRarity,
        uint8 requiredElement
    ) internal returns (uint256) {
        uint256 poolId = nextPoolId++;
        
        stakingPools[poolId] = StakingPool({
            poolId: poolId,
            name: name,
            baseRewardRate: baseRewardRate,
            lockPeriod: lockPeriod,
            bonusMultiplier: bonusMultiplier,
            maxPetsPerUser: maxPetsPerUser,
            requiredRarity: requiredRarity,
            requiredElement: requiredElement,
            isActive: true,
            totalStaked: 0,
            totalStakers: 0
        });
        
        emit PoolCreated(poolId, name, baseRewardRate);
        return poolId;
    }
    
    function createPool(
        string calldata name,
        uint256 baseRewardRate,
        uint256 lockPeriod,
        uint256 bonusMultiplier,
        uint256 maxPetsPerUser,
        uint8 requiredRarity,
        uint8 requiredElement
    ) external onlyOwner returns (uint256) {
        return _createPool(name, baseRewardRate, lockPeriod, bonusMultiplier, maxPetsPerUser, requiredRarity, requiredElement);
    }
    
    function updatePoolRewardRate(uint256 poolId, uint256 newRewardRate) external onlyOwner {
        require(stakingPools[poolId].poolId != 0, "Pool does not exist");
        stakingPools[poolId].baseRewardRate = newRewardRate;
        emit PoolUpdated(poolId, newRewardRate);
    }
    
    function togglePool(uint256 poolId) external onlyOwner {
        require(stakingPools[poolId].poolId != 0, "Pool does not exist");
        stakingPools[poolId].isActive = !stakingPools[poolId].isActive;
    }
    
    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================
    
    function getPendingRewards(uint256 petId) external view returns (uint256) {
        return _calculatePendingRewards(petId);
    }
    
    function getUserStakedPets(address user) external view returns (uint256[] memory) {
        return userStaking[user].stakedPets;
    }
    
    function getStakingPool(uint256 poolId) external view returns (StakingPool memory) {
        return stakingPools[poolId];
    }
    
    function getUserPoolStakeCount(address user, uint256 poolId) external view returns (uint256) {
        return userPoolStakeCount[poolId][user];
    }
    
    function getUserTotalPendingRewards(address user) external view returns (uint256) {
        uint256[] memory userPets = userStaking[user].stakedPets;
        uint256 totalRewards = 0;
 
