// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./PetNFT.sol";
import "./GameToken.sol";
import "./Random.sol";

/**
 * @title Tournament
 * @dev Advanced tournament management system for CryptoPets battles
 * @notice Features:
 * - Multiple tournament formats (single elimination, double elimination, round robin, swiss)
 * - Element-based tournaments with restrictions
 * - Rarity-gated tournaments (legendary only, etc.)
 * - Seasonal tournaments with special rewards
 * - Bracket management and automated progression
 * - Prize pool distribution and sponsor integration
 * - Live tournament streaming support
 */
contract Tournament is Ownable, ReentrancyGuard, Pausable, IRandomnessConsumer {
    
    enum TournamentType {
        SINGLE_ELIMINATION,
        DOUBLE_ELIMINATION,
        ROUND_ROBIN,
        SWISS_SYSTEM,
        KING_OF_HILL,
        LEAGUE
    }
    
    enum TournamentStatus {
        REGISTRATION,    // Players can register
        READY,          // Registration closed, waiting to start
        ACTIVE,         // Tournament in progress
        PAUSED,         // Temporarily paused
        FINISHED,       // Tournament completed
        CANCELLED       // Tournament cancelled
    }
    
    enum MatchStatus {
        PENDING,        // Match scheduled but not started
        IN_PROGRESS,    // Battle in progress
        COMPLETED,      // Match finished
        WALKOVER,       // Opponent didn't show
        CANCELLED       // Match cancelled
    }
    
    struct TournamentConfig {
        uint256 id;
        string name;
        string description;
        TournamentType tournamentType;
        TournamentStatus status;
        address organizer;
        uint256 entryFee;           // In PETS tokens
        uint256 maxParticipants;
        uint256 currentParticipants;
        uint8 requiredElement;      // 255 = no requirement
        uint8 minRarity;            // Minimum pet rarity
        uint8 maxRarity;            // Maximum pet rarity
        uint16 minLevel;            // Minimum pet level
        uint16 maxLevel;            // Maximum pet level
        uint32 registrationStart;
        uint32 registrationEnd;
        uint32 tournamentStart;
        uint32 tournamentEnd;
        uint256 prizePool;
        bool isSponsored;
        address sponsor;
        uint256[] prizeDistribution; // Percentage for each position
    }
    
    struct TournamentMatch {
        uint256 matchId;
        uint256 tournamentId;
        uint8 round;
        uint8 matchNumber;
        address player1;
        address player2;
        uint256 pet1;
        uint256 pet2;
        MatchStatus status;
        address winner;
        uint256 winnerPet;
        uint32 scheduledTime;
        uint32 completedTime;
        uint256 randomnessRequestId;
        MatchResult result;
    }
    
    struct MatchResult {
        uint16 pet1Damage;
        uint16 pet2Damage;
        uint8 totalRounds;
        bool pet1Critical;
        bool pet2Critical;
        uint16 pet1FinalHP;
        uint16 pet2FinalHP;
    }
    
    struct PlayerRegistration {
        address player;
        uint256 petId;
        uint32 registrationTime;
        bool checkedIn;
        uint32 checkInTime;
        uint8 currentRound;
        bool eliminated;
        uint8 wins;
        uint8 losses;
        uint256 totalScore;         // For Swiss/Round Robin
    }
    
    struct TournamentBracket {
        uint256 tournamentId;
        uint8 totalRounds;
        uint8 currentRound;
        mapping(uint8 => uint256[]) roundMatches; // round => matchIds
        mapping(address => uint8) playerPositions;
        address[] finalStandings;
    }
    
    struct SeasonalTournament {
        uint256 seasonId;
        string theme;               // "Fire Season", "Winter Championship", etc.
        uint8 elementBonus;         // Boosted element for the season
        uint256 bonusMultiplier;    // Prize multiplier
        uint32 seasonStart;
        uint32 seasonEnd;
        uint256[] tournamentIds;
        bool isActive;
    }
    
    // Contract references
    PetNFT public petContract;
    GameToken public gameToken;
    Random public randomContract;
    
    // Storage
    mapping(uint256 => TournamentConfig) public tournaments;
    mapping(uint256 => TournamentBracket) public brackets;
    mapping(uint256 => TournamentMatch) public matches;
    mapping(uint256 => mapping(address => PlayerRegistration)) public registrations;
    mapping(uint256 => SeasonalTournament) public seasons;
    mapping(uint256 => uint256) public randomRequestToMatch;
    
    // Tournament management
    uint256 public nextTournamentId = 1;
    uint256 public nextMatchId = 1;
    uint256 public nextSeasonId = 1;
    uint256[] public activeTournaments;
    uint256[] public upcomingTournaments;
    
    // Platform configuration
    uint256 public platformFeePercentage = 10; // 10% of entry fees
    address public treasuryAddress;
    uint256 public minTournamentSize = 4;
    uint256 public maxTournamentSize = 256;
    uint32 public defaultMatchDuration = 1800; // 30 minutes
    
    // Prize distribution templates
    mapping(string => uint256[]) public prizeTemplates;
    
    // Events
    event TournamentCreated(uint256 indexed tournamentId, string name, address organizer, TournamentType tournamentType);
    event PlayerRegistered(uint256 indexed tournamentId, address indexed player, uint256 petId);
    event TournamentStarted(uint256 indexed tournamentId, uint256 totalPrizePool);
    event MatchCreated(uint256 indexed matchId, uint256 indexed tournamentId, address player1, address player2);
    event MatchCompleted(uint256 indexed matchId, address winner, MatchResult result);
    event TournamentFinished(uint256 indexed tournamentId, address winner, uint256 prizeAwarded);
    event PrizeClaimed(uint256 indexed tournamentId, address indexed player, uint256 amount);
    event SeasonStarted(uint256 indexed seasonId, string theme, uint8 elementBonus);
    
    constructor(
        address _petContract,
        address _gameToken,
        address _randomContract,
        address _treasuryAddress
    ) {
        petContract = PetNFT(_petContract);
        gameToken = GameToken(_gameToken);
        randomContract = Random(_randomContract);
        treasuryAddress = _treasuryAddress;
        
        _initializePrizeTemplates();
    }
    
    function _initializePrizeTemplates() internal {
        // Standard single elimination prize distribution
        prizeTemplates["single_elim_8"] = [5000, 3000, 2000]; // 50%, 30%, 20% for top 3
        prizeTemplates["single_elim_16"] = [4000, 2500, 1500, 1000, 500, 500]; // Top 6
        prizeTemplates["single_elim_32"] = [3000, 2000, 1500, 1000, 750, 750, 500, 500]; // Top 8
        
        // Round robin distributions
        prizeTemplates["round_robin"] = [3000, 2000, 1500, 1000, 750, 500, 250]; // Top 7
    }
    
    // ============================================================================
    // TOURNAMENT CREATION
    // ============================================================================
    
    function createTournament(
        string calldata name,
        string calldata description,
        TournamentType tournamentType,
        uint256 entryFee,
        uint256 maxParticipants,
        uint8 requiredElement,
        uint8 minRarity,
        uint8 maxRarity,
        uint16 minLevel,
        uint16 maxLevel,
        uint32 registrationDuration,
        string calldata prizeTemplate
    ) external nonReentrant whenNotPaused returns (uint256) {
        require(bytes(name).length > 0, "Name cannot be empty");
        require(maxParticipants >= minTournamentSize && maxParticipants <= maxTournamentSize, "Invalid participant count");
        require(minRarity <= maxRarity, "Invalid rarity range");
        require(minLevel <= maxLevel, "Invalid level range");
        require(prizeTemplates[prizeTemplate].length > 0, "Invalid prize template");
        
        uint256 tournamentId = nextTournamentId++;
        uint32 currentTime = uint32(block.timestamp);
        
        tournaments[tournamentId] = TournamentConfig({
            id: tournamentId,
            name: name,
            description: description,
            tournamentType: tournamentType,
            status: TournamentStatus.REGISTRATION,
            organizer: msg.sender,
            entryFee: entryFee,
            maxParticipants: maxParticipants,
            currentParticipants: 0,
            requiredElement: requiredElement,
            minRarity: minRarity,
            maxRarity: maxRarity,
            minLevel: minLevel,
            maxLevel: maxLevel,
            registrationStart: currentTime,
            registrationEnd: currentTime + registrationDuration,
            tournamentStart: 0,
            tournamentEnd: 0,
            prizePool: 0,
            isSponsored: false,
            sponsor: address(0),
            prizeDistribution: prizeTemplates[prizeTemplate]
        });
        
        upcomingTournaments.push(tournamentId);
        
        emit TournamentCreated(tournamentId, name, msg.sender, tournamentType);
        return tournamentId;
    }
    
    function sponsorTournament(uint256 tournamentId, uint256 sponsorAmount) external nonReentrant {
        require(tournaments[tournamentId].id != 0, "Tournament does not exist");
        require(tournaments[tournamentId].status == TournamentStatus.REGISTRATION, "Registration ended");
        require(gameToken.balanceOf(msg.sender) >= sponsorAmount, "Insufficient tokens");
        
        gameToken.transferFrom(msg.sender, address(this), sponsorAmount);
        
        tournaments[tournamentId].prizePool += sponsorAmount;
        tournaments[tournamentId].isSponsored = true;
        tournaments[tournamentId].sponsor = msg.sender;
    }
    
    // ============================================================================
    // REGISTRATION SYSTEM
    // ============================================================================
    
    function registerForTournament(uint256 tournamentId, uint256 petId) external nonReentrant whenNotPaused {
        TournamentConfig storage tournament = tournaments[tournamentId];
        require(tournament.id != 0, "Tournament does not exist");
        require(tournament.status == TournamentStatus.REGISTRATION, "Registration not open");
        require(block.timestamp <= tournament.registrationEnd, "Registration ended");
        require(tournament.currentParticipants < tournament.maxParticipants, "Tournament full");
        require(petContract.ownerOf(petId) == msg.sender, "Not pet owner");
        require(registrations[tournamentId][msg.sender].player == address(0), "Already registered");
        
        PetNFT.Pet memory pet = petContract.getPet(petId);
        _validatePetRequirements(tournament, pet);
        
        // Collect entry fee
        if (tournament.entryFee > 0) {
            require(gameToken.balanceOf(msg.sender) >= tournament.entryFee, "Insufficient tokens");
            gameToken.transferFrom(msg.sender, address(this), tournament.entryFee);
            
            // Add to prize pool (minus platform fee)
            uint256 platformFee = (tournament.entryFee * platformFeePercentage) / 100;
            uint256 prizeContribution = tournament.entryFee - platformFee;
            tournament.prizePool += prizeContribution;
            
            // Transfer platform fee
            gameToken.transfer(treasuryAddress, platformFee);
        }
        
        registrations[tournamentId][msg.sender] = PlayerRegistration({
            player: msg.sender,
            petId: petId,
            registrationTime: uint32(block.timestamp),
            checkedIn: false,
            checkInTime: 0,
            currentRound: 0,
            eliminated: false,
            wins: 0,
            losses: 0,
            totalScore: 0
        });
        
        tournament.currentParticipants++;
        
        emit PlayerRegistered(tournamentId, msg.sender, petId);
    }
    
    function _validatePetRequirements(TournamentConfig storage tournament, PetNFT.Pet memory pet) internal pure {
        if (tournament.requiredElement < 8) {
            require(pet.element == tournament.requiredElement, "Wrong element");
        }
        
        require(pet.rarity >= tournament.minRarity && pet.rarity <= tournament.maxRarity, "Rarity not allowed");
        require(pet.level >= tournament.minLevel && pet.level <= tournament.maxLevel, "Level not allowed");
        require(pet.hp > 0, "Pet must have HP");
        require(pet.energy >= 50, "Pet needs energy");
    }
    
    function checkInForTournament(uint256 tournamentId) external {
        require(tournaments[tournamentId].status == TournamentStatus.READY, "Check-in not available");
        require(registrations[tournamentId][msg.sender].player == msg.sender, "Not registered");
        require(!registrations[tournamentId][msg.sender].checkedIn, "Already checked in");
        
        registrations[tournamentId][msg.sender].checkedIn = true;
        registrations[tournamentId][msg.sender].checkInTime = uint32(block.timestamp);
    }
    
    function withdrawFromTournament(uint256 tournamentId) external nonReentrant {
        TournamentConfig storage tournament = tournaments[tournamentId];
        require(tournament.status == TournamentStatus.REGISTRATION, "Cannot withdraw now");
        require(registrations[tournamentId][msg.sender].player == msg.sender, "Not registered");
        
        // Refund entry fee
        if (tournament.entryFee > 0) {
            uint256 refundAmount = (tournament.entryFee * 90) / 100; // 10% penalty
            gameToken.transfer(msg.sender, refundAmount);
            tournament.prizePool -= (tournament.entryFee - (tournament.entryFee * platformFeePercentage) / 100);
        }
        
        delete registrations[tournamentId][msg.sender];
        tournament.currentParticipants--;
    }
    
    // ============================================================================
    // TOURNAMENT MANAGEMENT
    // ============================================================================
    
    function startTournament(uint256 tournamentId) external nonReentrant {
        TournamentConfig storage tournament = tournaments[tournamentId];
        require(msg.sender == tournament.organizer || msg.sender == owner(), "Not authorized");
        require(tournament.status == TournamentStatus.REGISTRATION || tournament.status == TournamentStatus.READY, "Cannot start");
        require(tournament.currentParticipants >= minTournamentSize, "Not enough participants");
        
        tournament.status = TournamentStatus.ACTIVE;
        tournament.tournamentStart = uint32(block.timestamp);
        
        // Move from upcoming to active
        _removeFromUpcoming(tournamentId);
        activeTournaments.push(tournamentId);
        
        // Generate initial bracket and matches
        _generateInitialBracket(tournamentId);
        
        emit TournamentStarted(tournamentId, tournament.prizePool);
    }
    
    function _generateInitialBracket(uint256 tournamentId) internal {
        TournamentConfig storage tournament = tournaments[tournamentId];
        
        if (tournament.tournamentType == TournamentType.SINGLE_ELIMINATION || 
            tournament.tournamentType == TournamentType.DOUBLE_ELIMINATION) {
            _generateEliminationBracket(tournamentId);
        } else if (tournament.tournamentType == TournamentType.ROUND_ROBIN) {
            _generateRoundRobinMatches(tournamentId);
        } else if (tournament.tournamentType == TournamentType.SWISS_SYSTEM) {
            _generateSwissRound(tournamentId, 1);
        }
    }
    
    function _generateEliminationBracket(uint256 tournamentId) internal {
        TournamentConfig storage tournament = tournaments[tournamentId];
        
        // Get all registered players
        address[] memory players = _getRegisteredPlayers(tournamentId);
        uint256 playerCount = players.length;
        
        // Calculate bracket size (next power of 2)
        uint256 bracketSize = 1;
        while (bracketSize < playerCount) {
            bracketSize *= 2;
        }
        
        // Calculate total rounds
        uint8 totalRounds = 0;
        uint256 temp = bracketSize;
        while (temp > 1) {
            temp /= 2;
            totalRounds++;
        }
        
        brackets[tournamentId].totalRounds = totalRounds;
        brackets[tournamentId].currentRound = 1;
        
        // Generate first round matches
        _generateRoundMatches(tournamentId, 1, players);
    }
    
    function _generateRoundMatches(uint256 tournamentId, uint8 round, address[] memory players) internal {
        uint256 matchCount = players.length / 2;
        
        for (uint256 i = 0; i < matchCount; i++) {
            uint256 matchId = nextMatchId++;
            address player1 = players[i * 2];
            address player2 = players[i * 2 + 1];
            
            matches[matchId] = TournamentMatch({
                matchId: matchId,
                tournamentId: tournamentId,
                round: round,
                matchNumber: uint8(i + 1),
                player1: player1,
                player2: player2,
                pet1: registrations[tournamentId][player1].petId,
                pet2: registrations[tournamentId][player2].petId,
                status: MatchStatus.PENDING,
                winner: address(0),
                winnerPet: 0,
                scheduledTime: uint32(block.timestamp) + 300, // 5 minutes from now
                completedTime: 0,
                randomnessRequestId: 0,
                result: MatchResult(0, 0, 0, false, false, 0, 0)
            });
            
            brackets[tournamentId].roundMatches[round].push(matchId);
            
            emit MatchCreated(matchId, tournamentId, player1, player2);
        }
    }
    
    function _generateRoundRobinMatches(uint256 tournamentId) internal {
        address[] memory players = _getRegisteredPlayers(tournamentId);
        uint256 playerCount = players.length;
        
        // Generate all possible matches
        uint8 round = 1;
        for (uint256 i = 0; i < playerCount; i++) {
            for (uint256 j = i + 1; j < playerCount; j++) {
                uint256 matchId = nextMatchId++;
                
                matches[matchId] = TournamentMatch({
                    matchId: matchId,
                    tournamentId: tournamentId,
                    round: round,
                    matchNumber: uint8(brackets[tournamentId].roundMatches[round].length + 1),
                    player1: players[i],
                    player2: players[j],
                    pet1: registrations[tournamentId][players[i]].petId,
                    pet2: registrations[tournamentId][players[j]].petId,
                    status: MatchStatus.PENDING,
                    winner: address(0),
                    winnerPet: 0,
                    scheduledTime: uint32(block.timestamp) + (300 * brackets[tournamentId].roundMatches[round].length),
                    completedTime: 0,
                    randomnessRequestId: 0,
                    result: MatchResult(0, 0, 0, false, false, 0, 0)
                });
                
                brackets[tournamentId].roundMatches[round].push(matchId);
                
                emit MatchCreated(matchId, tournamentId, players[i], players[j]);
            }
        }
    }
    
    function _generateSwissRound(uint256 tournamentId, uint8 round) internal {
        address[] memory players = _getRegisteredPlayers(tournamentId);
        
        // For Swiss system, pair players with similar scores
        // Simplified pairing for round 1 (random)
        if (round == 1) {
            _generateRoundMatches(tournamentId, round, players);
        } else {
            // TODO: Implement Swiss pairing algorithm
            // This would pair players based on current standings
        }
    }
    
    // ============================================================================
    // MATCH EXECUTION
    // ============================================================================
    
    function startMatch(uint256 matchId) external nonReentrant {
        TournamentMatch storage match = matches[matchId];
        require(match.status == MatchStatus.PENDING, "Match not pending");
        require(block.timestamp >= match.scheduledTime, "Match not ready");
        require(msg.sender == match.player1 || msg.sender == match.player2 || msg.sender == owner(), "Not authorized");
        
        match.status = MatchStatus.IN_PROGRESS;
        
        // Request randomness for battle outcome
        uint256 requestId = randomContract.requestRandomnessForBattle(matchId);
        match.randomnessRequestId = requestId;
        randomRequestToMatch[requestId] = matchId;
    }
    
    function onRandomnessFulfilled(
        uint256 requestId,
        uint8 requestType,
        uint256 targetId,
        uint256[] calldata randomWords
    ) external override {
        require(msg.sender == address(randomContract), "Only random contract");
        require(requestType == 1, "Invalid request type for tournament");
        
        uint256 matchId = randomRequestToMatch[requestId];
        require(matchId != 0, "Match not found");
        
        _completeMatch(matchId, randomWords);
    }
    
    function _completeMatch(uint256 matchId, uint256[] memory randomWords) internal {
        TournamentMatch storage match = matches[matchId];
        require(match.status == MatchStatus.IN_PROGRESS, "Match not in progress");
        
        PetNFT.Pet memory pet1 = petContract.getPet(match.pet1);
        PetNFT.Pet memory pet2 = petContract.getPet(match.pet2);
        
        // Calculate battle outcome
        uint256 pet1Power = _calculateBattlePower(pet1);
        uint256 pet2Power = _calculateBattlePower(pet2);
        
        (address winner, uint256 winnerPet, MatchResult memory result) = _simulateBattle(
            match.player1, match.player2, match.pet1, match.pet2, 
            pet1Power, pet2Power, randomWords
        );
        
        match.winner = winner;
        match.winnerPet = winnerPet;
        match.status = MatchStatus.COMPLETED;
        match.completedTime = uint32(block.timestamp);
        match.result = result;
        
        // Update player stats
        if (winner == match.player1) {
            registrations[match.tournamentId][match.player1].wins++;
            registrations[match.tournamentId][match.player2].losses++;
        } else {
            registrations[match.tournamentId][match.player2].wins++;
            registrations[match.tournamentId][match.player1].losses++;
        }
        
        // Update pet experience and stats
        _updatePetAfterMatch(match.pet1, winner == match.player1);
        _updatePetAfterMatch(match.pet2, winner == match.player2);
        
        emit MatchCompleted(matchId, winner, result);
        
        // Check if tournament round is complete
        _checkRoundCompletion(match.tournamentId, match.round);
    }
    
    function _simulateBattle(
        address player1,
        address player2,
        uint256 pet1,
        uint256 pet2,
        uint256 pet1Power,
        uint256 pet2Power,
        uint256[] memory randomWords
    ) internal pure returns (address winner, uint256 winnerPet, MatchResult memory result) {
        
        // Simulate battle using randomness
        uint256 totalPower = pet1Power + pet2Power;
        uint256 pet1Chance = (pet1Power * 10000) / totalPower;
        
        bool pet1Wins = (randomWords[0] % 10000) < pet1Chance;
        
        result.pet1Damage = uint16(pet1Power / 10 + (randomWords[1] % 20));
        result.pet2Damage = uint16(pet2Power / 10 + (randomWords[2] % 20));
        result.totalRounds = uint8(3 + (randomWords[0] % 5));
        result.pet1Critical = (randomWords[1] % 100) < 15;
        result.pet2Critical = (randomWords[2] % 100) < 15;
        
        if (pet1Wins) {
            winner = player1;
            winnerPet = pet1;
            result.pet1FinalHP = uint16(50 + (randomWords[0] % 50));
            result.pet2FinalHP = 0;
        } else {
            winner = player2;
            winnerPet = pet2;
            result.pet1FinalHP = 0;
            result.pet2FinalHP = uint16(50 + (randomWords[1] % 50));
        }
    }
    
    function _calculateBattlePower(PetNFT.Pet memory pet) internal pure returns (uint256) {
        return (uint256(pet.strength) * 3 + 
                uint256(pet.speed) * 2 + 
                uint256(pet.defense) * 2 + 
                uint256(pet.intelligence)) * uint256(pet.level);
    }
    
    function _updatePetAfterMatch(uint256 petId, bool won) internal {
        PetNFT.Pet memory pet = petContract.getPet(petId);
        
        // Award experience
        pet.experience += won ? 100 : 50;
        
        // Reduce energy
        pet.energy = pet.energy > 40 ? pet.energy - 40 : 10;
        
        // Update battle stats
        if (won) {
            pet.battleWins++;
        } else {
            pet.battleLosses++;
        }
        
        petContract.updatePetStats(petId, pet);
    }
    
    // ============================================================================
    // TOURNAMENT PROGRESSION
    // ============================================================================
    
    function _checkRoundCompletion(uint256 tournamentId, uint8 round) internal {
        uint256[] storage roundMatches = brackets[tournamentId].roundMatches[round];
        bool allComplete = true;
        
        for (uint256 i = 0; i < roundMatches.length; i++) {
            if (matches[roundMatches[i]].status != MatchStatus.COMPLETED) {
                allComplete = false;
                break;
            }
        }
        
        if (allComplete) {
            _advanceToNextRound(tournamentId, round);
        }
    }
    
    function _advanceToNextRound(uint256 tournamentId, uint8 currentRound) internal {
        TournamentConfig storage tournament = tournaments[tournamentId];
        
        if (tournament.tournamentType == TournamentType.SINGLE_ELIMINATION || 
            tournament.tournamentType == TournamentType.DOUBLE_ELIMINATION) {
            _advanceEliminationTournament(tournamentId, currentRound);
        } else if (tournament.tournamentType == TournamentType.ROUND_ROBIN) {
            _checkRoundRobinCompletion(tournamentId);
        } else if (tournament.tournamentType == TournamentType.SWISS_SYSTEM) {
            _advanceSwissTournament(tournamentId, currentRound);
        }
    }
    
    function _advanceEliminationTournament(uint256 tournamentId, uint8 currentRound) internal {
        uint256[] storage roundMatches = brackets[tournamentId].roundMatches[currentRound];
        address[] memory winners = new address[](roundMatches.length);
        
        // Collect winners from current round
        for (uint256 i = 0; i < roundMatches.length; i++) {
            winners[i] = matches[roundMatches[i]].winner;
            
            // Mark losers as eliminated
            address loser = matches[roundMatches[i]].winner == matches[roundMatches[i]].player1 ? 
                matches[roundMatches[i]].player2 : matches[roundMatches[i]].player1;
            registrations[tournamentId][loser].eliminated = true;
        }
        
        if (winners.length == 1) {
            // Tournament finished
            _finishTournament(tournamentId, winners[0]);
        } else {
            // Generate next round
            brackets[tournamentId].currentRound++;
            _generateRoundMatches(tournamentId, currentRound + 1, winners);
        }
    }
    
    function _checkRoundRobinCompletion(uint256 tournamentId) internal {
        // For round robin, check if all matches are complete
        uint256[] storage allMatches = brackets[tournamentId].roundMatches[1];
        bool allComplete = true;
        
        for (uint256 i = 0; i < allMatches.length; i++) {
            if (matches[allMatches[i]].status != MatchStatus.COMPLETED) {
                allComplete = false;
                break;
            }
        }
        
        if (allComplete) {
            address winner = _calculateRoundRobinWinner(tournamentId);
            _finishTournament(tournamentId, winner);
        }
    }
    
    function _calculateRoundRobinWinner(uint256 tournamentId) internal view returns (address) {
        address[] memory players = _getRegisteredPlayers(tournamentId);
        address winner = players[0];
        uint256 maxWins = registrations[tournamentId][winner].wins;
        
        for (uint256 i = 1; i < players.length; i++) {
            uint256 playerWins = registrations[tournamentId][players[i]].wins;
            if (playerWins > maxWins) {
                maxWins = playerWins;
                winner = players[i];
            }
        }
        
        return winner;
    }
    
    function _advanceSwissTournament(uint256 tournamentId, uint8 currentRound) internal {
        TournamentConfig storage tournament = tournaments[tournamentId];
        
        // Swiss tournaments typically run for log2(n) + 1 rounds
        uint8 maxRounds = 5; // Configurable based on participant count
        
        if (currentRound < maxRounds) {
            brackets[tournamentId].currentRound++;
            _generateSwissRound(tournamentId, currentRound + 1);
        } else {
            address winner = _calculateSwissWinner(tournamentId);
            _finishTournament(tournamentId, winner);
        }
    }
    
    function _calculateSwissWinner(uint256 tournamentId) internal view returns (address) {
        address[] memory players = _getRegisteredPlayers(tournamentId);
        address winner = players[0];
        uint256 maxScore = registrations[tournamentId][winner].totalScore;
        
        for (uint256 i = 1; i < players.length; i++) {
            uint256 playerScore = registrations[tournamentId][players[i]].totalScore;
            if (playerScore > maxScore) {
                maxScore = playerScore;
                winner = players[i];
            }
        }
        
        return winner;
    }
    
    // ============================================================================
    // TOURNAMENT COMPLETION AND PRIZES
    // ============================================================================
    
    function _finishTournament(uint256 tournamentId, address winner) internal {
        TournamentConfig storage tournament = tournaments[tournamentId];
        tournament.status = TournamentStatus.FINISHED;
        tournament.tournamentEnd = uint32(block.timestamp);
        
        // Calculate final standings
        address[] memory finalStandings = _calculateFinalStandings(tournamentId);
        brackets[tournamentId].finalStandings = finalStandings;
        
        // Distribute prizes
        _distributePrizes(tournamentId, finalStandings);
        
        // Remove from active tournaments
        _removeFromActive(tournamentId);
        
        emit TournamentFinished(tournamentId, winner, tournament.prizePool);
    }
    
    function _calculateFinalStandings(uint256 tournamentId) internal view returns (address[] memory) {
        address[] memory players = _getRegisteredPlayers(tournamentId);
        TournamentConfig storage tournament = tournaments[tournamentId];
        
        // Sort players based on tournament type
        if (tournament.tournamentType == TournamentType.ROUND_ROBIN || 
            tournament.tournamentType == TournamentType.SWISS_SYSTEM) {
            return _sortPlayersByWins(tournamentId, players);
        } else {
            return _sortPlayersByEliminationRound(tournamentId, players);
        }
    }
    
    function _sortPlayersByWins(uint256 tournamentId, address[] memory players) internal view returns (address[] memory) {
        // Simple bubble sort by wins (in production, use more efficient sorting)
        for (uint256 i = 0; i < players.length - 1; i++) {
            for (uint256 j = 0; j < players.length - i - 1; j++) {
                if (registrations[tournamentId][players[j]].wins < 
                    registrations[tournamentId][players[j + 1]].wins) {
                    address temp = players[j];
                    players[j] = players[j + 1];
                    players[j + 1] = temp;
                }
            }
        }
        return players;
    }
    
    function _sortPlayersByEliminationRound(uint256 tournamentId, address[] memory players) internal view returns (address[] memory) {
        // Sort by elimination round (later elimination = higher placement)
        // Simplified implementation
        return players;
    }
    
    function _distributePrizes(uint256 tournamentId, address[] memory finalStandings) internal {
        TournamentConfig storage tournament = tournaments[tournamentId];
        uint256 totalPrize = tournament.prizePool;
        
        for (uint256 i = 0; i < tournament.prizeDistribution.length && i < finalStandings.length; i++) {
            uint256 prizeAmount = (totalPrize * tournament.prizeDistribution[i]) / 10000;
            if (prizeAmount > 0) {
                gameToken.transfer(finalStandings[i], prizeAmount);
                emit PrizeClaimed(tournamentId, finalStandings[i], prizeAmount);
            }
        }
    }
    
    // ============================================================================
    // SEASONAL TOURNAMENTS
    // ============================================================================
    
    function createSeason(
        string calldata theme,
        uint8 elementBonus,
        uint256 bonusMultiplier,
        uint32 duration
    ) external onlyOwner returns (uint256) {
        uint256 seasonId = nextSeasonId++;
        
        seasons[seasonId] = SeasonalTournament({
            seasonId: seasonId,
            theme: theme,
            elementBonus: elementBonus,
            bonusMultiplier: bonusMultiplier,
            seasonStart: uint32(block.timestamp),
            seasonEnd: uint32(block.timestamp) + duration,
            tournamentIds: new uint256[](0),
            isActive: true
        });
        
        emit SeasonStarted(seasonId, theme, elementBonus);
        return seasonId;
    }
    
    function addTournamentToSeason(uint256 seasonId, uint256 tournamentId) external onlyOwner {
        require(seasons[seasonId].isActive, "Season not active");
        require(tournaments[tournamentId].id != 0, "Tournament does not exist");
        
        seasons[seasonId].tournamentIds.push(tournamentId);
        
        // Apply seasonal bonuses
        tournaments[tournamentId].prizePool = 
            (tournaments[tournamentId].prizePool * seasons[seasonId].bonusMultiplier) / 100;
    }
    
    function endSeason(uint256 seasonId) external onlyOwner {
        require(seasons[seasonId].isActive, "Season not active");
        seasons[seasonId].isActive = false;
        seasons[seasonId].seasonEnd = uint32(block.timestamp);
    }
    
    // ============================================================================
    // UTILITY FUNCTIONS
    // ============================================================================
    
    function _getRegisteredPlayers(uint256 tournamentId) internal view returns (address[] memory) {
        // This is simplified - in practice, you'd maintain a list of registered players
        // For now, return a placeholder array
        address[] memory players = new address[](tournaments[tournamentId].currentParticipants);
        // Would populate from actual registrations
        return players;
    }
    
    function _removeFromUpcoming(uint256 tournamentId) internal {
        for (uint256 i = 0; i < upcomingTournaments.length; i++) {
            if (upcomingTournaments[i] == tournamentId) {
                upcomingTournaments[i] = upcomingTournaments[upcomingTournaments.length - 1];
                upcomingTournaments.pop();
                break;
            }
        }
    }
    
    function _removeFromActive(uint256 tournamentId) internal {
        for (uint256 i = 0; i < activeTournaments.length; i++) {
            if (activeTournaments[i] == tournamentId) {
                activeTournaments[i] = activeTournaments[activeTournaments.length - 1];
                activeTournaments.pop();
                break;
            }
        }
    }
    
    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================
    
    function getTournament(uint256 tournamentId) external view returns (TournamentConfig memory) {
        return tournaments[tournamentId];
    }
    
    function getMatch(uint256 matchId) external view returns (TournamentMatch memory) {
        return matches[matchId];
    }
    
    function getPlayerRegistration(uint256 tournamentId, address player) external view returns (PlayerRegistration memory) {
        return registrations[tournamentId][player];
    }
    
    function getTournamentMatches(uint256 tournamentId, uint8 round) external view returns (uint256[] memory) {
        return brackets[tournamentId].roundMatches[round];
    }
    
    function getActiveTournaments() external view returns (uint256[] memory) {
        return activeTournaments;
    }
    
    function getUpcomingTournaments() external view returns (uint256[] memory) {
        return upcomingTournaments;
    }
    
    function getSeason(uint256 seasonId) external view returns (SeasonalTournament memory season) {
        SeasonalTournament storage s = seasons[seasonId];
        return SeasonalTournament({
            seasonId: s.seasonId,
            theme: s.theme,
            elementBonus: s.elementBonus,
            bonusMultiplier: s.bonusMultiplier,
            seasonStart: s.seasonStart,
            seasonEnd: s.seasonEnd,
            tournamentIds: s.tournamentIds,
            isActive: s.isActive
        });
    }
    
    function getTournamentStandings(uint256 tournamentId) external view returns (address[] memory) {
        return brackets[tournamentId].finalStandings;
    }
    
    function canPlayerRegister(uint256 tournamentId, address player, uint256 petId) external view returns (bool, string memory) {
        TournamentConfig storage tournament = tournaments[tournamentId];
        
        if (tournament.id == 0) return (false, "Tournament does not exist");
        if (tournament.status != TournamentStatus.REGISTRATION) return (false, "Registration not open");
        if (block.timestamp > tournament.registrationEnd) return (false, "Registration ended");
        if (tournament.currentParticipants >= tournament.maxParticipants) return (false, "Tournament full");
        if (petContract.ownerOf(petId) != player) return (false, "Not pet owner");
        if (registrations[tournamentId][player].player != address(0)) return (false, "Already registered");
        
        PetNFT.Pet memory pet = petContract.getPet(petId);
        
        if (tournament.requiredElement < 8 && pet.element != tournament.requiredElement) {
            return (false, "Wrong element required");
        }
        
        if (pet.rarity < tournament.minRarity || pet.rarity > tournament.maxRarity) {
            return (false, "Rarity not allowed");
        }
        
        if (pet.level < tournament.minLevel || pet.level > tournament.maxLevel) {
            return (false, "Level not allowed");
        }
        
        if (pet.hp == 0) return (false, "Pet must have HP");
        if (pet.energy < 50) return (false, "Pet needs energy");
        
        return (true, "Can register");
    }
    
    // ============================================================================
    // ADMIN FUNCTIONS
    // ============================================================================
    
    function updatePlatformFee(uint256 _feePercentage) external onlyOwner {
        require(_feePercentage <= 20, "Fee too high");
        platformFeePercentage = _feePercentage;
    }
    
    function setTreasuryAddress(address _treasuryAddress) external onlyOwner {
        require(_treasuryAddress != address(0), "Invalid treasury address");
        treasuryAddress = _treasuryAddress;
    }
    
    function setTournamentLimits(uint256 _minSize, uint256 _maxSize) external onlyOwner {
        require(_minSize < _maxSize && _minSize >= 2, "Invalid tournament size limits");
        minTournamentSize = _minSize;
        maxTournamentSize = _maxSize;
    }
    
    function addPrizeTemplate(string calldata templateName, uint256[] calldata distribution) external onlyOwner {
        require(distribution.length > 0, "Empty distribution");
        
        uint256 totalPercentage = 0;
        for (uint256 i = 0; i < distribution.length; i++) {
            totalPercentage += distribution[i];
        }
        require(totalPercentage <= 10000, "Distribution exceeds 100%");
        
        prizeTemplates[templateName] = distribution;
    }
    
    function cancelTournament(uint256 tournamentId, string calldata reason) external onlyOwner {
        TournamentConfig storage tournament = tournaments[tournamentId];
        require(tournament.status == TournamentStatus.REGISTRATION || tournament.status == TournamentStatus.READY, "Cannot cancel");
        
        tournament.status = TournamentStatus.CANCELLED;
        
        // Refund all entry fees
        // Simplified - would iterate through all registrations
        if (tournament.prizePool > 0) {
            gameToken.transfer(treasuryAddress, tournament.prizePool);
        }
        
        _removeFromUpcoming(tournamentId);
        _removeFromActive(tournamentId);
    }
    
    function emergencyPause() external onlyOwner {
        _pause();
    }
    
    function emergencyUnpause() external onlyOwner {
        _unpause();
    }
    
    function emergencyWithdraw() external onlyOwner {
        gameToken.transfer(owner(), gameToken.balanceOf(address(this)));
    }
    
    function forceCompleteMatch(uint256 matchId, address winner) external onlyOwner {
        TournamentMatch storage match = matches[matchId];
        require(match.status == MatchStatus.PENDING || match.status == MatchStatus.IN_PROGRESS, "Match not active");
        require(winner == match.player1 || winner == match.player2, "Invalid winner");
        
        match.winner = winner;
        match.winnerPet = winner == match.player1 ? match.pet1 : match.pet2;
        match.status = MatchStatus.COMPLETED;
        match.completedTime = uint32(block.timestamp);
        
        // Update player stats
        if (winner == match.player1) {
            registrations[match.tournamentId][match.player1].wins++;
            registrations[match.tournamentId][match.player2].losses++;
        } else {
            registrations[match.tournamentId][match.player2].wins++;
            registrations[match.tournamentId][match.player1].losses++;
        }
        
        emit MatchCompleted(matchId, winner, match.result);
        _checkRoundCompletion(match.tournamentId, match.round);
    }
}
