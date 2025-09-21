// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./PetNFT.sol";
import "./GameToken.sol";
import "./PetBattle.sol";
import "./Random.sol";

/**
 * @title Tournament
 * @dev Advanced tournament system with brackets, seasons, and championships
 * @notice Features:
 * - Multiple tournament formats (single elimination, double elimination, round robin)
 * - Tiered tournaments by pet level and rarity
 * - Seasonal championships with special rewards
 * - Automated bracket generation and management
 * - Spectator betting system
 * - Prize pool distribution
 */
contract Tournament is Ownable, ReentrancyGuard, Pausable, IRandomnessConsumer {
    
    enum TournamentType { SINGLE_ELIMINATION, DOUBLE_ELIMINATION, ROUND_ROBIN, SWISS_SYSTEM }
    enum TournamentStatus { REGISTRATION, ACTIVE, COMPLETED, CANCELLED }
    enum TournamentTier { ROOKIE, AMATEUR, PROFESSIONAL, CHAMPION, LEGENDARY }
    enum MatchStatus { SCHEDULED, IN_PROGRESS, COMPLETED, DISPUTED }
    
    struct Tournament {
        uint256 id;
        string name;
        string description;
        TournamentType tournamentType;
        TournamentStatus status;
        TournamentTier tier;
        uint256 entryFee;           // Entry fee in PETS tokens
        uint256 prizePool;          // Total prize pool
        uint256 maxParticipants;    // Maximum number of participants
        uint256 currentParticipants; // Current registered participants
        uint32 registrationStart;
        uint32 registrationEnd;
        uint32 tournamentStart;
        uint32 tournamentEnd;
        uint8 minLevel;             // Minimum pet level required
        uint8 maxLevel;             // Maximum pet level allowed
        uint8 requiredRarity;       // Minimum rarity (255 = no requirement)
        uint8 requiredElement;      // Required element (255 = no requirement)
        address organizer;
        bool isSeasonalChampionship;
        uint256[] participantPets;
        mapping(address => bool) hasRegistered;
        mapping(uint256 => uint256) petToOwner; // petId => owner index
    }
    
    struct TournamentMatch {
        uint256 matchId;
        uint256 tournamentId;
        uint8 round;                // Round number
        uint8 bracket;              // Main bracket = 0, losers bracket = 1
        uint256 pet1;
        uint256 pet2;
        address player1;
        address player2;
        uint256 winner;             // Winning pet ID
        address winnerAddress;
        MatchStatus status;
        uint32 scheduledTime;
        uint256 battleId;           // Reference to PetBattle contract
        uint256 randomnessRequestId;
    }
    
    struct Bracket {
        uint256 tournamentId;
        uint8 currentRound;
        uint8 totalRounds;
        uint256[] currentMatches;
        mapping(uint8 => uint256[]) roundMatches; // round => matchIds
        mapping(address => bool) isEliminated;
        mapping(address => uint8) playerRanking;
    }
    
    struct PrizeStructure {
        uint256 firstPlace;         // Winner prize (basis points)
        uint256 secondPlace;        // Runner-up prize
        uint256 thirdPlace;         // Third place prize
        uint256 participationBonus; // Participation reward
        uint256 organizerFee;       // Fee to organizer
        uint256 platformFee;        // Fee to platform
    }
    
    struct SeasonData {
        uint256 seasonId;
        uint32 startTime;
        uint32 endTime;
        uint256 championshipTournamentId;
        mapping(address => uint256) playerPoints;
        mapping(address => uint8) tournamentWins;
        address[] qualifiedPlayers;
        bool isActive;
    }
    
    struct BettingPool {
        uint256 tournamentId;
        mapping(address => uint256) bets; // player => total bet amount
        mapping(address => mapping(address => uint256)) playerBets; // bettor => player => amount
        uint256 totalPool;
        bool bettingOpen;
        bool resolved;
    }
    
    // Contract references
    PetNFT public petContract;
    GameToken public gameToken;
    PetBattle public battleContract;
    Random public randomContract;
    
    // Storage
    mapping(uint256 => Tournament) public tournaments;
    mapping(uint256 => TournamentMatch) public matches;
    mapping(uint256 => Bracket) public brackets;
    mapping(uint256 => BettingPool) public bettingPools;
    mapping(uint256 => SeasonData) public seasons;
    mapping(uint256 => uint256) public randomRequestToMatch;
    
    // Tournament tracking
    mapping(address => uint256[]) public playerTournaments;
    mapping(address => uint256) public playerSeasonPoints;
    mapping(TournamentTier => uint256[]) public tierTournaments;
    
    // Counters
    uint256 public nextTournamentId = 1;
    uint256 public nextMatchId = 1;
    uint256 public nextSeasonId = 1;
    uint256 public currentSeasonId = 0;
    
    // Configuration
    PrizeStructure public defaultPrizeStructure;
    uint256 public platformFeePercentage = 500; // 5%
    uint256 public minimumPrizePool = 1000 * 10**18; // 1000 PETS
    uint32 public defaultRegistrationPeriod = 604800; // 7 days
    uint32 public defaultTournamentDuration = 1209600; // 14 days
    
    // Tier requirements
    mapping(TournamentTier => uint256) public tierMinLevel;
    mapping(TournamentTier => uint256) public tierMaxLevel;
    mapping(TournamentTier => uint256) public tierEntryFee;
    
    // Events
    event TournamentCreated(uint256 indexed tournamentId, string name, TournamentType tournamentType, TournamentTier tier);
    event PlayerRegistered(uint256 indexed tournamentId, address indexed player, uint256 indexed petId);
    event TournamentStarted(uint256 indexed tournamentId, uint256 participantCount);
    event MatchScheduled(uint256 indexed matchId, uint256 indexed tournamentId, uint256 pet1, uint256 pet2);
    event MatchCompleted(uint256 indexed matchId, uint256 winner, address winnerAddress);
    event TournamentCompleted(uint256 indexed tournamentId, address winner, uint256 prizeAmount);
    event BetPlaced(uint256 indexed tournamentId, address indexed bettor, address indexed player, uint256 amount);
    event SeasonStarted(uint256 indexed seasonId, uint32 duration);
    
    constructor(
        address _petContract,
        address _gameToken,
        address _battleContract,
        address _randomContract
    ) {
        petContract = PetNFT(_petContract);
        gameToken = GameToken(_gameToken);
        battleContract = PetBattle(_battleContract);
        randomContract = Random(_randomContract);
        
        _initializeDefaultSettings();
    }
    
    function _initializeDefaultSettings() internal {
        // Set default prize structure
        defaultPrizeStructure = PrizeStructure({
            firstPlace: 5000,        // 50% to winner
            secondPlace: 2500,       // 25% to runner-up
            thirdPlace: 1000,        // 10% to third place
            participationBonus: 1000, // 10% distributed to all participants
            organizerFee: 500,       // 5% to organizer
            platformFee: 500         // 5% to platform
        });
        
        // Set tier requirements
        tierMinLevel[TournamentTier.ROOKIE] = 1;
        tierMaxLevel[TournamentTier.ROOKIE] = 10;
        tierEntryFee[TournamentTier.ROOKIE] = 50 * 10**18;
        
        tierMinLevel[TournamentTier.AMATEUR] = 11;
        tierMaxLevel[TournamentTier.AMATEUR] = 25;
        tierEntryFee[TournamentTier.AMATEUR] = 200 * 10**18;
        
        tierMinLevel[TournamentTier.PROFESSIONAL] = 26;
        tierMaxLevel[TournamentTier.PROFESSIONAL] = 50;
        tierEntryFee[TournamentTier.PROFESSIONAL] = 500 * 10**18;
        
        tierMinLevel[TournamentTier.CHAMPION] = 51;
        tierMaxLevel[TournamentTier.CHAMPION] = 75;
        tierEntryFee[TournamentTier.CHAMPION] = 1000 * 10**18;
        
        tierMinLevel[TournamentTier.LEGENDARY] = 76;
        tierMaxLevel[TournamentTier.LEGENDARY] = 100;
        tierEntryFee[TournamentTier.LEGENDARY] = 2000 * 10**18;
    }
    
    // ============================================================================
    // TOURNAMENT CREATION
    // ============================================================================
    
    function createTournament(
        string calldata name,
        string calldata description,
        TournamentType tournamentType,
        TournamentTier tier,
        uint256 maxParticipants,
        uint32 registrationDuration,
        uint32 tournamentDuration,
        uint8 requiredRarity,
        uint8 requiredElement,
        bool isSeasonalChampionship
    ) external nonReentrant whenNotPaused returns (uint256) {
        
        require(bytes(name).length > 0 && bytes(name).length <= 100, "Invalid name length");
        require(maxParticipants >= 4 && maxParticipants <= 256, "Invalid participant count");
        require(maxParticipants & (maxParticipants - 1) == 0, "Participant count must be power of 2");
        
        uint256 entryFee = tierEntryFee[tier];
        uint256 tournamentId = nextTournamentId++;
        
        Tournament storage tournament = tournaments[tournamentId];
        tournament.id = tournamentId;
        tournament.name = name;
        tournament.description = description;
        tournament.tournamentType = tournamentType;
        tournament.status = TournamentStatus.REGISTRATION;
        tournament.tier = tier;
        tournament.entryFee = entryFee;
        tournament.prizePool = 0;
        tournament.maxParticipants = maxParticipants;
        tournament.currentParticipants = 0;
        tournament.registrationStart = uint32(block.timestamp);
        tournament.registrationEnd = uint32(block.timestamp) + registrationDuration;
        tournament.tournamentStart = tournament.registrationEnd;
        tournament.tournamentEnd = tournament.tournamentStart + tournamentDuration;
        tournament.minLevel = uint8(tierMinLevel[tier]);
        tournament.maxLevel = uint8(tierMaxLevel[tier]);
        tournament.requiredRarity = requiredRarity;
        tournament.requiredElement = requiredElement;
        tournament.organizer = msg.sender;
        tournament.isSeasonalChampionship = isSeasonalChampionship;
        
        // Initialize bracket
        brackets[tournamentId].tournamentId = tournamentId;
        brackets[tournamentId].currentRound = 0;
        brackets[tournamentId].totalRounds = _calculateTotalRounds(maxParticipants);
        
        // Initialize betting pool
        bettingPools[tournamentId].tournamentId = tournamentId;
        bettingPools[tournamentId].bettingOpen = true;
        
        tierTournaments[tier].push(tournamentId);
        
        emit TournamentCreated(tournamentId, name, tournamentType, tier);
        return tournamentId;
    }
    
    function _calculateTotalRounds(uint256 participants) internal pure returns (uint8) {
        uint8 rounds = 0;
        while (participants > 1) {
            participants = participants / 2;
            rounds++;
        }
        return rounds;
    }
    
    // ============================================================================
    // TOURNAMENT REGISTRATION
    // ============================================================================
    
    function registerForTournament(uint256 tournamentId, uint256 petId) external nonReentrant whenNotPaused {
        Tournament storage tournament = tournaments[tournamentId];
        require(tournament.id == tournamentId, "Tournament does not exist");
        require(tournament.status == TournamentStatus.REGISTRATION, "Registration not open");
        require(block.timestamp <= tournament.registrationEnd, "Registration period ended");
        require(tournament.currentParticipants < tournament.maxParticipants, "Tournament full");
        require(!tournament.hasRegistered[msg.sender], "Already registered");
        require(petContract.ownerOf(petId) == msg.sender, "Not pet owner");
        
        PetNFT.Pet memory pet = petContract.getPet(petId);
        
        // Validate pet requirements
        require(pet.level >= tournament.minLevel && pet.level <= tournament.maxLevel, "Pet level not in range");
        
        if (tournament.requiredRarity < 255) {
            require(pet.rarity >= tournament.requiredRarity, "Pet rarity too low");
        }
        
        if (tournament.requiredElement < 255) {
            require(pet.element == tournament.requiredElement, "Wrong element required");
        }
        
        // Check entry fee
        require(gameToken.balanceOf(msg.sender) >= tournament.entryFee, "Insufficient entry fee");
        
        // Transfer entry fee
        gameToken.transferFrom(msg.sender, address(this), tournament.entryFee);
        
        // Register player
        tournament.hasRegistered[msg.sender] = true;
        tournament.participantPets.push(petId);
        tournament.petToOwner[petId] = tournament.currentParticipants;
        tournament.currentParticipants++;
        tournament.prizePool += tournament.entryFee;
        
        playerTournaments[msg.sender].push(tournamentId);
        
        emit PlayerRegistered(tournamentId, msg.sender, petId);
        
        // Start tournament if full
        if (tournament.currentParticipants == tournament.maxParticipants) {
            _startTournament(tournamentId);
        }
    }
    
    // ============================================================================
    // TOURNAMENT MANAGEMENT
    // ============================================================================
    
    function startTournament(uint256 tournamentId) external {
        Tournament storage tournament = tournaments[tournamentId];
        require(tournament.organizer == msg.sender || msg.sender == owner(), "Not authorized");
        require(tournament.status == TournamentStatus.REGISTRATION, "Tournament not in registration");
        require(block.timestamp >= tournament.registrationEnd, "Registration period not ended");
        require(tournament.currentParticipants >= 4, "Not enough participants");
        
        _startTournament(tournamentId);
    }
    
    function _startTournament(uint256 tournamentId) internal {
        Tournament storage tournament = tournaments[tournamentId];
        tournament.status = TournamentStatus.ACTIVE;
        
        // Close betting
        bettingPools[tournamentId].bettingOpen = false;
        
        // Generate first round matches
        uint256 requestId = randomContract.requestRandomnessForEvent(tournamentId);
        randomRequestToMatch[requestId] = tournamentId;
        
        emit TournamentStarted(tournamentId, tournament.currentParticipants);
    }
    
    function onRandomnessFulfilled(
        uint256 requestId,
        uint8 requestType,
        uint256 targetId,
        uint256[] calldata randomWords
    ) external override {
        require(msg.sender == address(randomContract), "Only random contract can call");
        
        if (requestType == 3) { // Tournament bracket generation
            uint256 tournamentId = randomRequestToMatch[requestId];
            _generateBracket(tournamentId, randomWords[0]);
        }
    }
    
    function _generateBracket(uint256 tournamentId, uint256 randomSeed) internal {
        Tournament storage tournament = tournaments[tournamentId];
        Bracket storage bracket = brackets[tournamentId];
        
        // Shuffle participants
        uint256[] memory shuffledPets = _shuffleArray(tournament.participantPets, randomSeed);
        
        // Create first round matches
        bracket.currentRound = 1;
        uint256 matchesInRound = shuffledPets.length / 2;
        
        for (uint256 i = 0; i < matchesInRound; i++) {
            uint256 pet1 = shuffledPets[i * 2];
            uint256 pet2 = shuffledPets[i * 2 + 1];
            
            uint256 matchId = _createMatch(
                tournamentId,
                1, // Round 1
                0, // Main bracket
                pet1,
                pet2
            );
            
            bracket.roundMatches[1].push(matchId);
        }
        
        bracket.currentMatches = bracket.roundMatches[1];
    }
    
    function _shuffleArray(uint256[] memory array, uint256 seed) internal pure returns (uint256[] memory) {
        uint256[] memory shuffled = new uint256[](array.length);
        for (uint256 i = 0; i < array.length; i++) {
            shuffled[i] = array[i];
        }
        
        for (uint256 i = array.length - 1; i > 0; i--) {
            uint256 j = uint256(keccak256(abi.encode(seed, i))) % (i + 1);
            (shuffled[i], shuffled[j]) = (shuffled[j], shuffled[i]);
        }
        
        return shuffled;
    }
    
    function _createMatch(
        uint256 tournamentId,
        uint8 round,
        uint8 bracketType,
        uint256 pet1,
        uint256 pet2
    ) internal returns (uint256) {
        uint256 matchId = nextMatchId++;
        
        matches[matchId] = TournamentMatch({
            matchId: matchId,
            tournamentId: tournamentId,
            round: round,
            bracket: bracketType,
            pet1: pet1,
            pet2: pet2,
            player1: petContract.ownerOf(pet1),
            player2: petContract.ownerOf(pet2),
            winner: 0,
            winnerAddress: address(0),
            status: MatchStatus.SCHEDULED,
            scheduledTime: uint32(block.timestamp) + 3600, // 1 hour from now
            battleId: 0,
            randomnessRequestId: 0
        });
        
        emit MatchScheduled(matchId, tournamentId, pet1, pet2);
        return matchId;
    }
    
    // ============================================================================
    // MATCH EXECUTION
    // ============================================================================
    
    function executeMatch(uint256 matchId) external nonReentrant {
        TournamentMatch storage match = matches[matchId];
        require(match.status == MatchStatus.SCHEDULED, "Match not scheduled");
        require(block.timestamp >= match.scheduledTime, "Match not ready");
        
        match.status = MatchStatus.IN_PROGRESS;
        
        // Request randomness for match outcome
        uint256 requestId = randomContract.requestRandomnessForBattle(matchId);
        match.randomnessRequestId = requestId;
        randomRequestToMatch[requestId] = matchId;
    }
    
    function _resolveMatch(uint256 matchId, uint256[] memory randomWords) internal {
        TournamentMatch storage match = matches[matchId];
        
        // Get pet stats for battle calculation
        PetNFT.Pet memory pet1 = petContract.getPet(match.pet1);
        PetNFT.Pet memory pet2 = petContract.getPet(match.pet2);
        
        // Calculate battle power
        uint256 pet1Power = _calculateBattlePower(pet1);
        uint256 pet2Power = _calculateBattlePower(pet2);
        
        // Use randomness to determine winner
        uint256 totalPower = pet1Power + pet2Power;
        uint256 randomValue = randomWords[0] % totalPower;
        
        if (randomValue < pet1Power) {
            match.winner = match.pet1;
            match.winnerAddress = match.player1;
        } else {
            match.winner = match.pet2;
            match.winnerAddress = match.player2;
        }
        
        match.status = MatchStatus.COMPLETED;
        
        // Update bracket
        _advanceWinner(match.tournamentId, matchId, match.winner, match.winnerAddress);
        
        emit MatchCompleted(matchId, match.winner, match.winnerAddress);
    }
    
    function _calculateBattlePower(PetNFT.Pet memory pet) internal pure returns (uint256) {
        return (uint256(pet.strength) * 2 + 
                uint256(pet.speed) + 
                uint256(pet.defense) + 
                uint256(pet.intelligence)) * uint256(pet.level);
    }
    
    function _advanceWinner(uint256 tournamentId, uint256 matchId, uint256 winnerPet, address winnerAddress) internal {
        Bracket storage bracket = brackets[tournamentId];
        Tournament storage tournament = tournaments[tournamentId];
        
        // Check if round is complete
        bool roundComplete = true;
        for (uint256 i = 0; i < bracket.currentMatches.length; i++) {
            if (matches[bracket.currentMatches[i]].status != MatchStatus.COMPLETED) {
                roundComplete = false;
                break;
            }
        }
        
        if (roundComplete) {
            if (bracket.currentRound == bracket.totalRounds) {
                // Tournament complete
                _completeTournament(tournamentId, winnerAddress);
            } else {
                // Advance to next round
                _createNextRound(tournamentId);
            }
        }
    }
    
    function _createNextRound(uint256 tournamentId) internal {
        Bracket storage bracket = brackets[tournamentId];
        bracket.currentRound++;
        
        // Collect winners from current matches
        uint256[] memory winners = new uint256[](bracket.currentMatches.length);
        for (uint256 i = 0; i < bracket.currentMatches.length; i++) {
            winners[i] = matches[bracket.currentMatches[i]].winner;
        }
        
        // Create next round matches
        uint256 nextRoundMatches = winners.length / 2;
        delete bracket.currentMatches;
        
        for (uint256 i = 0; i < nextRoundMatches; i++) {
            uint256 matchId = _createMatch(
                tournamentId,
                bracket.currentRound,
                0,
                winners[i * 2],
                winners[i * 2 + 1]
            );
            
            bracket.roundMatches[bracket.currentRound].push(matchId);
            bracket.currentMatches.push(matchId);
        }
    }
    
    // ============================================================================
    // TOURNAMENT COMPLETION
    // ============================================================================
    
    function _completeTournament(uint256 tournamentId, address winner) internal {
        Tournament storage tournament = tournaments[tournamentId];
        tournament.status = TournamentStatus.COMPLETED;
        
        // Distribute prizes
        _distributePrizes(tournamentId, winner);
        
        // Update season points if applicable
        if (currentSeasonId > 0) {
            _updateSeasonPoints(tournamentId, winner);
        }
        
        uint256 winnerPrize = (tournament.prizePool * defaultPrizeStructure.firstPlace) / 10000;
        emit TournamentCompleted(tournamentId, winner, winnerPrize);
    }
    
    function _distributePrizes(uint256 tournamentId, address winner) internal {
        Tournament storage tournament = tournaments[tournamentId];
        uint256 prizePool = tournament.prizePool;
        
        // Calculate prize amounts
        uint256 winnerPrize = (prizePool * defaultPrizeStructure.firstPlace) / 10000;
        uint256 runnerUpPrize = (prizePool * defaultPrizeStructure.secondPlace) / 10000;
        uint256 thirdPlacePrize = (prizePool * defaultPrizeStructure.thirdPlace) / 10000;
        uint256 participationBonus = (prizePool * defaultPrizeStructure.participationBonus) / 10000;
        uint256 organizerFee = (prizePool * defaultPrizeStructure.organizerFee) / 10000;
        uint256 platformFee = (prizePool * defaultPrizeStructure.platformFee) / 10000;
        
        // Distribute prizes
        gameToken.mintPlayerRewards(winner, winnerPrize);
        
        // Find runner-up and third place (simplified - would need proper tracking)
        address runnerUp = _findRunnerUp(tournamentId);
        address thirdPlace = _findThirdPlace(tournamentId);
        
        if (runnerUp != address(0)) {
            gameToken.mintPlayerRewards(runnerUp, runnerUpPrize);
        }
        
        if (thirdPlace != address(0)) {
            gameToken.mintPlayerRewards(thirdPlace, thirdPlacePrize);
        }
        
        // Distribute participation bonus
        uint256 bonusPerPlayer = participationBonus / tournament.currentParticipants;
        for (uint256 i = 0; i < tournament.participantPets.length; i++) {
            address player = petContract.ownerOf(tournament.participantPets[i]);
            gameToken.mintPlayerRewards(player, bonusPerPlayer);
        }
        
        // Pay fees
        gameToken.mintPlayerRewards(tournament.organizer, organizerFee);
        gameToken.mintPlayerRewards(owner(), platformFee);
    }
    
    function _findRunnerUp(uint256 tournamentId) internal view returns (address) {
        // Simplified implementation - find opponent in final match
        Bracket storage bracket = brackets[tournamentId];
        if (bracket.roundMatches[bracket.totalRounds].length > 0) {
            uint256 finalMatchId = bracket.roundMatches[bracket.totalRounds][0];
            TournamentMatch storage finalMatch = matches[finalMatchId];
            
            if (finalMatch.winnerAddress == finalMatch.player1) {
                return finalMatch.player2;
            } else {
                return finalMatch.player1;
            }
        }
        return address(0);
    }
    
    function _findThirdPlace(uint256 tournamentId) internal view returns (address) {
        // Simplified - would need proper semifinal tracking
        return address(0);
    }
    
    // ============================================================================
    // BETTING SYSTEM
    // ============================================================================
    
    function placeBet(uint256 tournamentId, address player, uint256 amount) external nonReentrant {
        BettingPool storage pool = bettingPools[tournamentId];
        require(pool.bettingOpen, "Betting closed");
        require(tournaments[tournamentId].hasRegistered[player], "Player not registered");
        require(amount > 0, "Invalid bet amount");
        require(gameToken.balanceOf(msg.sender) >= amount, "Insufficient balance");
        
        gameToken.transferFrom(msg.sender, address(this), amount);
        
        pool.playerBets[msg.sender][player] += amount;
        pool.bets[player] += amount;
        pool.totalPool += amount;
        
        emit BetPlaced(tournamentId, msg.sender, player, amount);
    }
    
    // ============================================================================
    // SEASON MANAGEMENT
    // ============================================================================
    
    function startSeason(uint32 duration) external onlyOwner {
        uint256 seasonId = nextSeasonId++;
        currentSeasonId = seasonId;
        
        SeasonData storage season = seasons[seasonId];
        season.seasonId = seasonId;
        season.startTime = uint32(block.timestamp);
        season.endTime = uint32(block.timestamp) + duration;
        season.isActive = true;
        
        emit SeasonStarted(seasonId, duration);
    }
    
    function _updateSeasonPoints(uint256 tournamentId, address winner) internal {
        if (currentSeasonId == 0) return;
        
        Tournament storage tournament = tournaments[tournamentId];
        SeasonData storage season = seasons[currentSeasonId];
        
        // Award points based on tournament tier
        uint256 points = _getTierPoints(tournament.tier);
        season.playerPoints[winner] += points;
        season.tournamentWins[winner]++;
        
        playerSeasonPoints[winner] += points;
    }
    
    function _getTierPoints(TournamentTier tier) internal pure returns (uint256) {
        if (tier == TournamentTier.ROOKIE) return 100;
        if (tier == TournamentTier.AMATEUR) return 250;
        if (tier == TournamentTier.PROFESSIONAL) return 500;
        if (tier == TournamentTier.CHAMPION) return 1000;
        if (tier == TournamentTier.LEGENDARY) return 2500;
        return 0;
    }
    
    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================
    
    function getTournament(uint256 tournamentId) external view returns (
        uint256 id,
        string memory name,
        TournamentType tournamentType,
        TournamentStatus status,
        TournamentTier tier,
        uint256 entryFee,
        uint256 prizePool,
        uint256 maxParticipants,
        uint256 currentParticipants,
        uint32 registrationEnd,
        uint32 tournamentStart
    ) {
        Tournament storage tournament = tournaments[tournamentId];
        return (
            tournament.id,
            tournament.name,
            tournament.tournamentType,
            tournament.status,
            tournament.tier,
            tournament.entryFee,
            tournament.prizePool,
            tournament.maxParticipants,
            tournament.currentParticipants,
            tournament.registrationEnd,
            tournament.tournamentStart
        );
    }
    
    function getTournamentParticipants(uint256 tournamentId) external view returns (uint256[] memory) {
        return tournaments[tournamentId].participantPets;
    }
    
    function getMatch(uint256 matchId) external view returns (TournamentMatch memory) {
        return matches[matchId];
    }
    
    function getBracket(uint256 tournamentId) external view returns (
        uint8 currentRound,
        uint8 totalRounds,
        uint256[] memory currentMatches
    ) {
        Bracket storage bracket = brackets[tournamentId];
        return (bracket.currentRound, bracket.totalRounds, bracket.currentMatches);
    }
    
    function getRoundMatches(uint256 tournamentId, uint8 round) external view returns (uint256[] memory) {
        return brackets[tournamentId].roundMatches[round];
    }
    
    function getPlayerTournaments(address player) external view returns (uint256[] memory) {
        return playerTournaments[player];
    }
    
    function getTierTournaments(TournamentTier tier) external view returns (uint256[] memory) {
        return tierTournaments[tier];
    }
    
    function getSeasonData(uint256 seasonId) external view returns (
        uint256 id,
        uint32 startTime,
        uint32 endTime,
        uint256 championshipTournamentId,
        bool isActive
    ) {
        SeasonData storage season = seasons[seasonId];
        return (season.seasonId, season.startTime, season.endTime, season.championshipTournamentId, season.isActive);
    }
    
    function getPlayerSeasonPoints(uint256 seasonId, address player) external view returns (uint256) {
        return seasons[seasonId].playerPoints[player];
    }
    
    function getBettingPool(uint256 tournamentId) external view returns (
        uint256 totalPool,
        bool bettingOpen,
        bool resolved
    ) {
        BettingPool storage pool = bettingPools[tournamentId];
        return (pool.totalPool, pool.bettingOpen, pool.resolved);
    }
    
    function getPlayerBets(uint256 tournamentId, address bettor, address player) external view returns (uint256) {
        return bettingPools[tournamentId].playerBets[bettor][player];
    }
    
    function getActiveTournaments() external view returns (uint256[] memory) {
        uint256 count = 0;
        
        // Count active tournaments
        for (uint256 i = 1; i < nextTournamentId; i++) {
            if (tournaments[i].status == TournamentStatus.REGISTRATION || tournaments[i].status == TournamentStatus.ACTIVE) {
                count++;
            }
        }
        
        uint256[] memory activeTournaments = new uint256[](count);
        uint256 index = 0;
        
        // Fill array with active tournament IDs
        for (uint256 i = 1; i < nextTournamentId; i++) {
            if (tournaments[i].status == TournamentStatus.REGISTRATION || tournaments[i].status == TournamentStatus.ACTIVE) {
                activeTournaments[index] = i;
                index++;
            }
        }
        
        return activeTournaments;
    }
    
    // ============================================================================
    // ADMIN FUNCTIONS
    // ============================================================================
    
    function setPlatformFee(uint256 newFeePercentage) external onlyOwner {
        require(newFeePercentage <= 1000, "Fee too high"); // Max 10%
        platformFeePercentage = newFeePercentage;
    }
    
    function updatePrizeStructure(PrizeStructure calldata newStructure) external onlyOwner {
        require(
            newStructure.firstPlace + 
            newStructure.secondPlace + 
            newStructure.thirdPlace + 
            newStructure.participationBonus + 
            newStructure.organizerFee + 
            newStructure.platformFee == 10000,
            "Prize structure must sum to 100%"
        );
        defaultPrizeStructure = newStructure;
    }
    
    function setTierRequirements(
        TournamentTier tier,
        uint256 minLevel,
        uint256 maxLevel,
        uint256 entryFee
    ) external onlyOwner {
        require(minLevel <= maxLevel, "Invalid level range");
        tierMinLevel[tier] = minLevel;
        tierMaxLevel[tier] = maxLevel;
        tierEntryFee[tier] = entryFee;
    }
    
    function cancelTournament(uint256 tournamentId) external onlyOwner {
        Tournament storage tournament = tournaments[tournamentId];
        require(tournament.status != TournamentStatus.COMPLETED, "Cannot cancel completed tournament");
        
        tournament.status = TournamentStatus.CANCELLED;
        
        // Refund entry fees
        for (uint256 i = 0; i < tournament.participantPets.length; i++) {
            address player = petContract.ownerOf(tournament.participantPets[i]);
            gameToken.transfer(player, tournament.entryFee);
        }
    }
    
    function resolveDisputedMatch(uint256 matchId, uint256 winnerPet) external onlyOwner {
        TournamentMatch storage match = matches[matchId];
        require(match.status == MatchStatus.DISPUTED, "Match not disputed");
        
        if (winnerPet == match.pet1) {
            match.winner = match.pet1;
            match.winnerAddress = match.player1;
        } else if (winnerPet == match.pet2) {
            match.winner = match.pet2;
            match.winnerAddress = match.player2;
        } else {
            revert("Invalid winner pet");
        }
        
        match.status = MatchStatus.COMPLETED;
        _advanceWinner(match.tournamentId, matchId, match.winner, match.winnerAddress);
        
        emit MatchCompleted(matchId, match.winner, match.winnerAddress);
    }
    
    function endSeason() external onlyOwner {
        require(currentSeasonId > 0, "No active season");
        seasons[currentSeasonId].isActive = false;
        
        // Create championship tournament for top players
        _createChampionshipTournament(currentSeasonId);
        
        currentSeasonId = 0;
    }
    
    function _createChampionshipTournament(uint256 seasonId) internal {
        // Simplified implementation - would need proper leaderboard tracking
        uint256 championshipId = createTournament(
            "Season Championship",
            "Championship tournament for season winners",
            TournamentType.SINGLE_ELIMINATION,
            TournamentTier.LEGENDARY,
            16, // Top 16 players
            604800, // 1 week registration
            1209600, // 2 weeks duration
            255, // No rarity requirement
            255, // No element requirement
            true // Is seasonal championship
        );
        
        seasons[seasonId].championshipTournamentId = championshipId;
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
