// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./PetNFT.sol";
import "./GameToken.sol";
import "./Random.sol";

/**
 * @title PetBattle
 * @dev Advanced battle system for CryptoPets with tournaments and rankings
 * @notice Features:
 * - 1v1 battles with wagering
 * - Tournament system
 * - Ranked matchmaking
 * - Battle history and statistics
 * - Element advantages/disadvantages
 */
contract PetBattle is Ownable, ReentrancyGuard, Pausable, IRandomnessConsumer {
    
    // Battle configuration
    struct Battle {
        uint256 id;
        uint256 pet1;
        uint256 pet2;
        address player1;
        address player2;
        uint256 wager;
        uint8 status; // 0=Open, 1=InProgress, 2=Finished, 3=Cancelled
        uint256 winner; // Pet ID of winner
        uint32 startTime;
        uint32 endTime;
        uint256 randomnessRequestId;
        BattleStats stats;
    }
    
    struct BattleStats {
        uint16 pet1DamageDealt;
        uint16 pet2DamageDealt;
        uint8 pet1CriticalHits;
        uint8 pet2CriticalHits;
        uint8 totalRounds;
        bool pet1UsedSpecial;
        bool pet2UsedSpecial;
    }
    
    // Tournament system
    struct Tournament {
        uint256 id;
        string name;
        uint256 entryFee;
        uint256 prizePool;
        uint8 maxParticipants;
        uint8 currentParticipants;
        uint32 registrationEnd;
        uint32 tournamentStart;
        uint8 status; // 0=Registration, 1=InProgress, 2=Finished
        address winner;
        uint256[] participants;
        mapping(uint8 => uint256[]) rounds; // round => battle IDs
    }
    
    // Ranking system
    struct PlayerRanking {
        address player;
        uint32 rating;
        uint16 wins;
        uint16 losses;
        uint16 winStreak;
        uint16 bestWinStreak;
        uint32 lastBattleTime;
        uint8 tier; // 0=Bronze, 1=Silver, 2=Gold, 3=Platinum, 4=Diamond, 5=Master
    }
    
    // Element effectiveness matrix (attacker vs defender)
    // 0=Fire, 1=Water, 2=Earth, 3=Air, 4=Electric, 5=Mystic, 6=Light, 7=Dark
    uint8[8][8] public elementMatrix;
    
    // Contract references
    PetNFT public petContract;
    GameToken public gameToken;
    Random public randomContract;
    
    // Battle storage
    mapping(uint256 => Battle) public battles;
    mapping(uint256 => uint256) public petInBattle; // petId => battleId
    mapping(uint256 => uint256) public randomRequestToBattle;
    
    // Tournament storage
    mapping(uint256 => Tournament) public tournaments;
    mapping(uint256 => mapping(address => bool)) public tournamentParticipants;
    
    // Ranking storage
    mapping(address => PlayerRanking) public playerRankings;
    address[] public rankedPlayers;
    
    // Configuration
    uint256 public nextBattleId = 1;
    uint256 public nextTournamentId = 1;
    uint256 public battleFee = 0.001 ether;
    uint256 public platformFeePercentage = 5; // 5% of wagers
    uint256 public minWager = 10 * 10**18; // 10 PETS
    uint256 public maxWager = 10000 * 10**18; // 10,000 PETS
    
    // Battle requirements
    uint32 public constant BATTLE_TIMEOUT = 3600; // 1 hour
    uint16 public constant MIN_ENERGY_FOR_BATTLE = 30;
    uint16 public constant ENERGY_COST_PER_BATTLE = 25;
    
    // Events
    event BattleCreated(uint256 indexed battleId, uint256 indexed pet1, address indexed player1, uint256 wager);
    event BattleJoined(uint256 indexed battleId, uint256 indexed pet2, address indexed player2);
    event BattleFinished(uint256 indexed battleId, uint256 winner, address winnerOwner, BattleStats stats);
    event TournamentCreated(uint256 indexed tournamentId, string name, uint256 entryFee, uint8 maxParticipants);
    event TournamentJoined(uint256 indexed tournamentId, address indexed player, uint256 petId);
    event RankingUpdated(address indexed player, uint32 newRating, uint8 newTier);
    
    constructor(
        address _petContract,
        address _gameToken,
        address _randomContract
    ) {
        petContract = PetNFT(_petContract);
        gameToken = GameToken(_gameToken);
        randomContract = Random(_randomContract);
        
        _initializeElementMatrix();
        _initializeRankingTiers();
    }
    
    function _initializeElementMatrix() internal {
        // Initialize element effectiveness (100 = normal, 150 = super effective, 75 = not very effective)
        // Fire vs [Fire, Water, Earth, Air, Electric, Mystic, Light, Dark]
        elementMatrix[0] = [100, 75, 150, 100, 100, 100, 100, 100];
        // Water vs [Fire, Water, Earth, Air, Electric, Mystic, Light, Dark]
        elementMatrix[1] = [150, 100, 75, 100, 75, 100, 100, 100];
        // Earth vs [Fire, Water, Earth, Air, Electric, Mystic, Light, Dark]
        elementMatrix[2] = [75, 150, 100, 75, 150, 100, 100, 100];
        // Air vs [Fire, Water, Earth, Air, Electric, Mystic, Light, Dark]
        elementMatrix[3] = [100, 100, 150, 100, 75, 100, 100, 100];
        // Electric vs [Fire, Water, Earth, Air, Electric, Mystic, Light, Dark]
        elementMatrix[4] = [100, 150, 75, 150, 100, 100, 100, 100];
        // Mystic vs [Fire, Water, Earth, Air, Electric, Mystic, Light, Dark]
        elementMatrix[5] = [100, 100, 100, 100, 100, 100, 150, 75];
        // Light vs [Fire, Water, Earth, Air, Electric, Mystic, Light, Dark]
        elementMatrix[6] = [100, 100, 100, 100, 100, 75, 100, 150];
        // Dark vs [Fire, Water, Earth, Air, Electric, Mystic, Light, Dark]
        elementMatrix[7] = [100, 100, 100, 100, 100, 150, 75, 100];
    }
    
    function _initializeRankingTiers() internal {
        // Initialize default ranking for contract owner
        playerRankings[owner()] = PlayerRanking({
            player: owner(),
            rating: 1000,
            wins: 0,
            losses: 0,
            winStreak: 0,
            bestWinStreak: 0,
            lastBattleTime: 0,
            tier: 0
        });
    }
    
    // ============================================================================
    // BATTLE CREATION AND MANAGEMENT
    // ============================================================================
    
    function createBattle(uint256 petId, uint256 wager) external payable nonReentrant whenNotPaused {
        require(petContract.ownerOf(petId) == msg.sender, "Not pet owner");
        require(petInBattle[petId] == 0, "Pet already in battle");
        require(msg.value >= battleFee, "Insufficient battle fee");
        require(wager >= minWager && wager <= maxWager, "Invalid wager amount");
        require(gameToken.balanceOf(msg.sender) >= wager, "Insufficient tokens for wager");
        
        PetNFT.Pet memory pet = petContract.getPet(petId);
        require(pet.hp > 0, "Pet has no HP");
        require(pet.energy >= MIN_ENERGY_FOR_BATTLE, "Pet too tired for battle");
        require(pet.level >= 5, "Pet level too low for battles");
        
        uint256 battleId = nextBattleId++;
        
        battles[battleId] = Battle({
            id: battleId,
            pet1: petId,
            pet2: 0,
            player1: msg.sender,
            player2: address(0),
            wager: wager,
            status: 0,
            winner: 0,
            startTime: 0,
            endTime: 0,
            randomnessRequestId: 0,
            stats: BattleStats({
                pet1DamageDealt: 0,
                pet2DamageDealt: 0,
                pet1CriticalHits: 0,
                pet2CriticalHits: 0,
                totalRounds: 0,
                pet1UsedSpecial: false,
                pet2UsedSpecial: false
            })
        });
        
        petInBattle[petId] = battleId;
        
        if (wager > 0) {
            gameToken.transferFrom(msg.sender, address(this), wager);
        }
        
        emit BattleCreated(battleId, petId, msg.sender, wager);
    }
    
    function joinBattle(uint256 battleId, uint256 petId) external nonReentrant whenNotPaused {
        require(petContract.ownerOf(petId) == msg.sender, "Not pet owner");
        require(petInBattle[petId] == 0, "Pet already in battle");
        
        Battle storage battle = battles[battleId];
        require(battle.status == 0, "Battle not available");
        require(battle.player1 != msg.sender, "Cannot battle yourself");
        
        PetNFT.Pet memory pet = petContract.getPet(petId);
        require(pet.hp > 0, "Pet has no HP");
        require(pet.energy >= MIN_ENERGY_FOR_BATTLE, "Pet too tired for battle");
        require(pet.level >= 5, "Pet level too low for battles");
        
        if (battle.wager > 0) {
            require(gameToken.balanceOf(msg.sender) >= battle.wager, "Insufficient tokens for wager");
            gameToken.transferFrom(msg.sender, address(this), battle.wager);
        }
        
        battle.pet2 = petId;
        battle.player2 = msg.sender;
        battle.status = 1;
        battle.startTime = uint32(block.timestamp);
        
        petInBattle[petId] = battleId;
        
        // Request randomness for battle
        uint256 requestId = randomContract.requestRandomnessForBattle(battleId);
        battle.randomnessRequestId = requestId;
        randomRequestToBattle[requestId] = battleId;
        
        emit BattleJoined(battleId, petId, msg.sender);
    }
    
    function cancelBattle(uint256 battleId) external nonReentrant {
        Battle storage battle = battles[battleId];
        require(battle.player1 == msg.sender, "Not battle creator");
        require(battle.status == 0, "Battle cannot be cancelled");
        require(block.timestamp <= battle.startTime + BATTLE_TIMEOUT, "Battle expired");
        
        // Refund wager
        if (battle.wager > 0) {
            gameToken.transfer(msg.sender, battle.wager);
        }
        
        battle.status = 3; // Cancelled
        petInBattle[battle.pet1] = 0;
    }
    
    // ============================================================================
    // RANDOMNESS CALLBACK AND BATTLE EXECUTION
    // ============================================================================
    
    function onRandomnessFulfilled(
        uint256 requestId,
        uint8 requestType,
        uint256 targetId,
        uint256[] calldata randomWords
    ) external override {
        require(msg.sender == address(randomContract), "Only random contract can call");
        require(requestType == 1, "Invalid request type for battles");
        
        uint256 battleId = randomRequestToBattle[requestId];
        require(battleId != 0, "Battle not found for request");
        
        _executeBattle(battleId, randomWords);
    }
    
    function _executeBattle(uint256 battleId, uint256[] memory randomWords) internal {
        Battle storage battle = battles[battleId];
        require(battle.status == 1, "Battle not in progress");
        
        PetNFT.Pet memory pet1 = petContract.getPet(battle.pet1);
        PetNFT.Pet memory pet2 = petContract.getPet(battle.pet2);
        
        // Calculate battle powers with element effectiveness
        uint256 pet1Power = _calculateBattlePower(pet1);
        uint256 pet2Power = _calculateBattlePower(pet2);
        
        // Apply element effectiveness
        uint8 elementEffectiveness1 = elementMatrix[pet1.element][pet2.element];
        uint8 elementEffectiveness2 = elementMatrix[pet2.element][pet1.element];
        
        pet1Power = (pet1Power * elementEffectiveness1) / 100;
        pet2Power = (pet2Power * elementEffectiveness2) / 100;
        
        // Execute battle rounds with randomness
        BattleStats memory stats = _simulateBattleRounds(pet1Power, pet2Power, randomWords);
        battle.stats = stats;
        
        // Determine winner based on battle simulation
        uint256 winner;
        address winnerAddr;
        address loserAddr;
        
        if (stats.pet1DamageDealt > stats.pet2DamageDealt) {
            winner = battle.pet1;
            winnerAddr = battle.player1;
            loserAddr = battle.player2;
        } else {
            winner = battle.pet2;
            winnerAddr = battle.player2;
            loserAddr = battle.player1;
        }
        
        // Update pet stats
        pet1.battleWins = winner == battle.pet1 ? pet1.battleWins + 1 : pet1.battleWins;
        pet1.battleLosses = winner == battle.pet1 ? pet1.battleLosses : pet1.battleLosses + 1;
        pet1.energy -= ENERGY_COST_PER_BATTLE;
        pet1.experience += winner == battle.pet1 ? 75 : 25;
        
        pet2.battleWins = winner == battle.pet2 ? pet2.battleWins + 1 : pet2.battleWins;
        pet2.battleLosses = winner == battle.pet2 ? pet2.battleLosses : pet2.battleLosses + 1;
        pet2.energy -= ENERGY_COST_PER_BATTLE;
        pet2.experience += winner == battle.pet2 ? 75 : 25;
        
        petContract.updatePetStats(battle.pet1, pet1);
        petContract.updatePetStats(battle.pet2, pet2);
        
        // Handle rewards and ranking updates
        _processRewards(battle, winnerAddr, loserAddr);
        _updateRankings(winnerAddr, loserAddr);
        
        battle.winner = winner;
        battle.status = 2;
        battle.endTime = uint32(block.timestamp);
        
        // Clear battle references
        petInBattle[battle.pet1] = 0;
        petInBattle[battle.pet2] = 0;
        delete randomRequestToBattle[battle.randomnessRequestId];
        
        emit BattleFinished(battleId, winner, winnerAddr, stats);
    }
    
    function _simulateBattleRounds(
        uint256 pet1Power,
        uint256 pet2Power,
        uint256[] memory randomWords
    ) internal pure returns (BattleStats memory) {
        
        BattleStats memory stats;
        uint256 pet1HP = 100;
        uint256 pet2HP = 100;
        uint8 round = 0;
        
        while (pet1HP > 0 && pet2HP > 0 && round < 10) {
            uint256 randomIndex = round % randomWords.length;
            uint256 roundRandom = randomWords[randomIndex];
            
            // Pet1 attacks
            uint16 damage1 = uint16((pet1Power / 10) + (roundRandom % 20));
            bool crit1 = (roundRandom % 100) < 10; // 10% crit chance
            if (crit1) {
                damage1 = (damage1 * 150) / 100;
                stats.pet1CriticalHits++;
            }
            
            pet2HP = pet2HP > damage1 ? pet2HP - damage1 : 0;
            stats.pet1DamageDealt += damage1;
            
            if (pet2HP == 0) break;
            
            // Pet2 attacks
            uint256 roundRandom2 = uint256(keccak256(abi.encode(roundRandom, round)));
            uint16 damage2 = uint16((pet2Power / 10) + (roundRandom2 % 20));
            bool crit2 = (roundRandom2 % 100) < 10;
            if (crit2) {
                damage2 = (damage2 * 150) / 100;
                stats.pet2CriticalHits++;
            }
            
            pet1HP = pet1HP > damage2 ? pet1HP - damage2 : 0;
            stats.pet2DamageDealt += damage2;
            
            round++;
        }
        
        stats.totalRounds = round;
        return stats;
    }
    
    function _processRewards(Battle memory battle, address winner, address loser) internal {
        if (battle.wager > 0) {
            uint256 totalWager = battle.wager * 2;
            uint256 platformFee = (totalWager * platformFeePercentage) / 100;
            uint256 winnerReward = totalWager - platformFee;
            
            gameToken.transfer(winner, winnerReward);
            gameToken.transfer(owner(), platformFee);
        }
        
        // Mint battle rewards
        gameToken.mintPlayerRewards(winner, 150 * 10**18); // 150 PETS for winner
        gameToken.mintPlayerRewards(loser, 50 * 10**18);   // 50 PETS for participation
    }
    
    function _updateRankings(address winner, address loser) internal {
        PlayerRanking storage winnerRank = playerRankings[winner];
        PlayerRanking storage loserRank = playerRankings[loser];
        
        // Initialize if first battle
        if (winnerRank.player == address(0)) {
            winnerRank.player = winner;
            winnerRank.rating = 1000;
            rankedPlayers.push(winner);
        }
        if (loserRank.player == address(0)) {
            loserRank.player = loser;
            loserRank.rating = 1000;
            rankedPlayers.push(loser);
        }
        
        // ELO-style rating calculation
        uint32 ratingChange = _calculateRatingChange(winnerRank.rating, loserRank.rating);
        
        winnerRank.rating += ratingChange;
        winnerRank.wins++;
        winnerRank.winStreak++;
        winnerRank.bestWinStreak = winnerRank.winStreak > winnerRank.bestWinStreak ? 
            winnerRank.winStreak : winnerRank.bestWinStreak;
        winnerRank.lastBattleTime = uint32(block.timestamp);
        winnerRank.tier = _calculateTier(winnerRank.rating);
        
        loserRank.rating = loserRank.rating > ratingChange ? loserRank.rating - ratingChange : 0;
        loserRank.losses++;
        loserRank.winStreak = 0;
        loserRank.lastBattleTime = uint32(block.timestamp);
        loserRank.tier = _calculateTier(loserRank.rating);
        
        emit RankingUpdated(winner, winnerRank.rating, winnerRank.tier);
        emit RankingUpdated(loser, loserRank.rating, loserRank.tier);
    }
    
    // ============================================================================
    // UTILITY FUNCTIONS
    // ============================================================================
    
    function _calculateBattlePower(PetNFT.Pet memory pet) internal pure returns (uint256) {
        return (uint256(pet.strength) * 3 + 
                uint256(pet.speed) * 2 + 
                uint256(pet.defense) * 2 + 
                uint256(pet.intelligence)) * uint256(pet.level);
    }
    
    function _calculateRatingChange(uint32 winnerRating, uint32 loserRating) internal pure returns (uint32) {
        uint32 baseDelta = 32;
        if (winnerRating > loserRating) {
            uint32 diff = winnerRating - loserRating;
            return baseDelta > diff / 20 ? baseDelta - diff / 20 : 1;
        } else {
            uint32 diff = loserRating - winnerRating;
            return baseDelta + diff / 20;
        }
    }
    
    function _calculateTier(uint32 rating) internal pure returns (uint8) {
        if (rating >= 2000) return 5; // Master
        if (rating >= 1600) return 4; // Diamond  
        if (rating >= 1300) return 3; // Platinum
        if (rating >= 1100) return 2; // Gold
        if (rating >= 900) return 1;  // Silver
        return 0; // Bronze
    }
    
    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================
    
    function getBattle(uint256 battleId) external view returns (Battle memory) {
        return battles[battleId];
    }
    
    function getOpenBattles(uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        uint256[] memory openBattles = new uint256[](limit);
        uint256 count = 0;
        uint256 current = 0;
        
        for (uint256 i = 1; i < nextBattleId && count < limit; i++) {
            if (battles[i].status == 0) {
                if (current >= offset) {
                    openBattles[count] = i;
                    count++;
                }
                current++;
            }
        }
        
        // Resize array to actual count
        assembly { mstore(openBattles, count) }
        return openBattles;
    }
    
    function getPlayerRanking(address player) external view returns (PlayerRanking memory) {
        return playerRankings[player];
    }
    
    function getLeaderboard(uint256 limit) external view returns (address[] memory) {
        // Simple implementation - in production, use a more efficient data structure
        address[] memory leaderboard = new address[](limit);
        uint256 count = 0;
        
        // This is inefficient for large datasets - consider implementing a heap or sorted list
        for (uint256 i = 0; i < rankedPlayers.length && count < limit; i++) {
            leaderboard[count] = rankedPlayers[i];
            count++;
        }
        
        return leaderboard;
    }
    
    // ============================================================================
    // ADMIN FUNCTIONS
    // ============================================================================
    
    function setBattleFee(uint256 _battleFee) external onlyOwner {
        battleFee = _battleFee;
    }
    
    function setPlatformFeePercentage(uint256 _feePercentage) external onlyOwner {
        require(_feePercentage <= 10, "Fee too high");
        platformFeePercentage = _feePercentage;
    }
    
    function setWagerLimits(uint256 _minWager, uint256 _maxWager) external onlyOwner {
        require(_minWager < _maxWager, "Invalid wager limits");
        minWager = _minWager;
        maxWager = _maxWager;
    }
    
    function updateElementMatrix(uint8 attacker, uint8 defender, uint8 effectiveness) external onlyOwner {
        require(attacker < 8 && defender < 8, "Invalid element");
        require(effectiveness >= 50 && effectiveness <= 200, "Invalid effectiveness");
        elementMatrix[attacker][defender] = effectiveness;
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    function emergencyWithdraw() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
}
