// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./PetNFT.sol";
import "./GameToken.sol";

/**
 * @title PetDAO
 * @dev Decentralized governance system for CryptoPets community
 * @notice Features:
 * - Proposal creation and voting system
 * - Tiered voting power based on pet ownership and staking
 * - Treasury management and fund allocation
 * - Multi-stage proposal lifecycle
 * - Quorum and approval thresholds
 */
contract PetDAO is Ownable, ReentrancyGuard, Pausable {
    
    enum ProposalType { 
        GAME_PARAMETER,     // Modify game mechanics (breeding costs, battle rewards, etc.)
        TREASURY_SPEND,     // Allocate treasury funds
        NEW_FEATURE,        // Add new game features
        PARTNERSHIP,        // Strategic partnerships
        EMERGENCY_ACTION,   // Emergency interventions
        CONSTITUTION        // Change DAO rules
    }
    
    enum ProposalStatus {
        PENDING,           // Waiting for voting period to start
        ACTIVE,            // Currently accepting votes
        SUCCEEDED,         // Passed all requirements
        DEFEATED,          // Failed to meet requirements
        QUEUED,            // Waiting for execution delay
        EXECUTED,          // Successfully executed
        CANCELLED,         // Cancelled by proposer or admin
        EXPIRED            // Expired without execution
    }
    
    enum VoteChoice { AGAINST, FOR, ABSTAIN }
    
    struct Proposal {
        uint256 id;
        address proposer;
        ProposalType proposalType;
        ProposalStatus status;
        string title;
        string description;
        string[] actions;           // Encoded function calls
        uint256 startBlock;
        uint256 endBlock;
        uint256 executionDelay;     // Delay before execution (timelock)
        uint256 executionDeadline;  // Deadline for execution
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        uint256 totalVotingPower;
        uint256 quorumRequired;
        uint256 approvalThreshold;  // Percentage needed to pass (basis points)
        bool executed;
        mapping(address => Vote) votes;
    }
    
    struct Vote {
        bool hasVoted;
        VoteChoice choice;
        uint256 votingPower;
        uint256 timestamp;
        string reason;
    }
    
    struct VoterProfile {
        uint256 totalVotingPower;
        uint256 delegatedPower;
        uint256 proposalsCreated;
        uint256 votesParticipated;
        address delegate;           // Address to delegate voting power to
        uint256 lastActiveBlock;
    }
    
    struct TreasuryAllocation {
        uint256 amount;
        address recipient;
        string purpose;
        bool executed;
        uint256 executionBlock;
    }
    
    // Contract references
    PetNFT public petContract;
    GameToken public gameToken;
    
    // Governance storage
    mapping(uint256 => Proposal) public proposals;
    mapping(address => VoterProfile) public voterProfiles;
    mapping(address => mapping(uint256 => bool)) public hasVotedOnProposal;
    mapping(uint256 => TreasuryAllocation) public treasuryAllocations;
    
    // Delegation tracking
    mapping(address => address[]) public delegators; // delegate => delegators[]
    mapping(address => uint256) public delegatedVotingPower;
    
    // Configuration
    uint256 public nextProposalId = 1;
    uint256 public nextAllocationId = 1;
    
    // Voting parameters
    uint256 public proposalThreshold = 100000 * 10**18; // 100k PETS to create proposal
    uint256 public votingDelay = 17280; // ~3 days in blocks (assuming 15s blocks)
    uint256 public votingPeriod = 46080; // ~8 days in blocks
    uint256 public executionDelay = 17280; // ~3 days delay before execution
    uint256 public executionWindow = 86400; // ~15 days window for execution
    
    // Quorum and approval thresholds by proposal type (basis points: 10000 = 100%)
    mapping(ProposalType => uint256) public quorumThresholds;
    mapping(ProposalType => uint256) public approvalThresholds;
    
    // Voting power calculation weights
    uint256 public constant TOKEN_VOTING_WEIGHT = 1;      // 1 vote per PETS token
    uint256 public constant PET_VOTING_WEIGHT = 1000;     // 1000 votes per pet
    uint256 public constant RARITY_MULTIPLIER_BASE = 1000; // Base for rarity calculations
    
    // Treasury management
    address public treasuryAddress;
    uint256 public totalTreasuryAllocated;
    
    // Events
    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, ProposalType proposalType, string title);
    event VoteCast(uint256 indexed proposalId, address indexed voter, VoteChoice choice, uint256 votingPower, string reason);
    event ProposalExecuted(uint256 indexed proposalId, address indexed executor);
    event ProposalCancelled(uint256 indexed proposalId, address indexed canceller);
    event VotingPowerDelegated(address indexed delegator, address indexed delegate, uint256 power);
    event TreasuryAllocationExecuted(uint256 indexed allocationId, address recipient, uint256 amount);
    
    constructor(
        address _petContract,
        address _gameToken,
        address _treasuryAddress
    ) {
        petContract = PetNFT(_petContract);
        gameToken = GameToken(_gameToken);
        treasuryAddress = _treasuryAddress;
        
        _initializeGovernanceParameters();
    }
    
    function _initializeGovernanceParameters() internal {
        // Set quorum thresholds (percentage of total voting power)
        quorumThresholds[ProposalType.GAME_PARAMETER] = 500;    // 5%
        quorumThresholds[ProposalType.TREASURY_SPEND] = 1000;   // 10%
        quorumThresholds[ProposalType.NEW_FEATURE] = 750;       // 7.5%
        quorumThresholds[ProposalType.PARTNERSHIP] = 1500;      // 15%
        quorumThresholds[ProposalType.EMERGENCY_ACTION] = 2000; // 20%
        quorumThresholds[ProposalType.CONSTITUTION] = 2500;     // 25%
        
        // Set approval thresholds (percentage of votes cast)
        approvalThresholds[ProposalType.GAME_PARAMETER] = 6000;    // 60%
        approvalThresholds[ProposalType.TREASURY_SPEND] = 6500;    // 65%
        approvalThresholds[ProposalType.NEW_FEATURE] = 5500;       // 55%
        approvalThresholds[ProposalType.PARTNERSHIP] = 7000;       // 70%
        approvalThresholds[ProposalType.EMERGENCY_ACTION] = 7500;  // 75%
        approvalThresholds[ProposalType.CONSTITUTION] = 8000;      // 80%
    }
    
    // ============================================================================
    // VOTING POWER CALCULATION
    // ============================================================================
    
    function calculateVotingPower(address voter) public view returns (uint256) {
        uint256 totalPower = 0;
        
        // Token-based voting power
        uint256 tokenBalance = gameToken.balanceOf(voter);
        totalPower += tokenBalance * TOKEN_VOTING_WEIGHT / 10**18;
        
        // Pet-based voting power
        uint256 petCount = petContract.balanceOf(voter);
        
        for (uint256 i = 0; i < petCount; i++) {
            uint256 petId = petContract.tokenOfOwnerByIndex(voter, i);
            PetNFT.Pet memory pet = petContract.getPet(petId);
            
            // Base pet voting power
            uint256 petPower = PET_VOTING_WEIGHT;
            
            // Rarity multiplier
            uint256[] memory rarityMultipliers = new uint256[](4);
            rarityMultipliers[0] = 1000;  // Common: 1x
            rarityMultipliers[1] = 1500;  // Rare: 1.5x
            rarityMultipliers[2] = 2000;  // Epic: 2x
            rarityMultipliers[3] = 3000;  // Legendary: 3x
            
            petPower = (petPower * rarityMultipliers[pet.rarity]) / RARITY_MULTIPLIER_BASE;
            
            // Level bonus (1% per level)
            petPower += (petPower * pet.level) / 100;
            
            // Genesis pet bonus (50% extra)
            if (pet.isGenesis) {
                petPower += petPower / 2;
            }
            
            totalPower += petPower;
        }
        
        // Add delegated power
        totalPower += delegatedVotingPower[voter];
        
        return totalPower;
    }
    
    function getTotalVotingPower() public view returns (uint256) {
        uint256 totalSupply = gameToken.totalSupply();
        uint256 totalPets = petContract.totalSupply();
        
        // Simplified calculation - in practice, would need more sophisticated tracking
        return (totalSupply * TOKEN_VOTING_WEIGHT / 10**18) + (totalPets * PET_VOTING_WEIGHT);
    }
    
    // ============================================================================
    // PROPOSAL CREATION
    // ============================================================================
    
    function createProposal(
        ProposalType proposalType,
        string calldata title,
        string calldata description,
        string[] calldata actions
    ) external nonReentrant whenNotPaused returns (uint256) {
        
        uint256 voterPower = calculateVotingPower(msg.sender);
        require(voterPower >= proposalThreshold, "Insufficient voting power to create proposal");
        
        require(bytes(title).length > 0 && bytes(title).length <= 200, "Invalid title length");
        require(bytes(description).length > 0 && bytes(description).length <= 5000, "Invalid description length");
        require(actions.length > 0 && actions.length <= 10, "Invalid actions count");
        
        uint256 proposalId = nextProposalId++;
        uint256 startBlock = block.number + votingDelay;
        uint256 endBlock = startBlock + votingPeriod;
        
        Proposal storage proposal = proposals[proposalId];
        proposal.id = proposalId;
        proposal.proposer = msg.sender;
        proposal.proposalType = proposalType;
        proposal.status = ProposalStatus.PENDING;
        proposal.title = title;
        proposal.description = description;
        proposal.actions = actions;
        proposal.startBlock = startBlock;
        proposal.endBlock = endBlock;
        proposal.executionDelay = executionDelay;
        proposal.executionDeadline = endBlock + executionDelay + executionWindow;
        proposal.totalVotingPower = getTotalVotingPower();
        proposal.quorumRequired = (proposal.totalVotingPower * quorumThresholds[proposalType]) / 10000;
        proposal.approvalThreshold = approvalThresholds[proposalType];
        
        // Update voter profile
        voterProfiles[msg.sender].proposalsCreated++;
        voterProfiles[msg.sender].lastActiveBlock = block.number;
        
        emit ProposalCreated(proposalId, msg.sender, proposalType, title);
        return proposalId;
    }
    
    // ============================================================================
    // VOTING SYSTEM
    // ============================================================================
    
    function castVote(
        uint256 proposalId,
        VoteChoice choice,
        string calldata reason
    ) external nonReentrant whenNotPaused {
        
        Proposal storage proposal = proposals[proposalId];
        require(proposal.id == proposalId, "Proposal does not exist");
        require(block.number >= proposal.startBlock, "Voting has not started");
        require(block.number <= proposal.endBlock, "Voting has ended");
        require(!proposal.votes[msg.sender].hasVoted, "Already voted on this proposal");
        
        uint256 votingPower = calculateVotingPower(msg.sender);
        require(votingPower > 0, "No voting power");
        
        // Update proposal status if needed
        if (proposal.status == ProposalStatus.PENDING) {
            proposal.status = ProposalStatus.ACTIVE;
        }
        
        // Record vote
        proposal.votes[msg.sender] = Vote({
            hasVoted: true,
            choice: choice,
            votingPower: votingPower,
            timestamp: block.timestamp,
            reason: reason
        });
        
        // Update vote tallies
        if (choice == VoteChoice.FOR) {
            proposal.forVotes += votingPower;
        } else if (choice == VoteChoice.AGAINST) {
            proposal.againstVotes += votingPower;
        } else {
            proposal.abstainVotes += votingPower;
        }
        
        // Update voter profile
        voterProfiles[msg.sender].votesParticipated++;
        voterProfiles[msg.sender].lastActiveBlock = block.number;
        
        emit VoteCast(proposalId, msg.sender, choice, votingPower, reason);
    }
    
    function castVoteBatch(
        uint256[] calldata proposalIds,
        VoteChoice[] calldata choices,
        string[] calldata reasons
    ) external nonReentrant whenNotPaused {
        require(proposalIds.length == choices.length, "Array length mismatch");
        require(proposalIds.length == reasons.length, "Array length mismatch");
        require(proposalIds.length <= 10, "Too many proposals");
        
        for (uint256 i = 0; i < proposalIds.length; i++) {
            _castVoteInternal(proposalIds[i], choices[i], reasons[i]);
        }
    }
    
    function _castVoteInternal(uint256 proposalId, VoteChoice choice, string memory reason) internal {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.id == proposalId, "Proposal does not exist");
        require(block.number >= proposal.startBlock, "Voting has not started");
        require(block.number <= proposal.endBlock, "Voting has ended");
        require(!proposal.votes[msg.sender].hasVoted, "Already voted on this proposal");
        
        uint256 votingPower = calculateVotingPower(msg.sender);
        require(votingPower > 0, "No voting power");
        
        if (proposal.status == ProposalStatus.PENDING) {
            proposal.status = ProposalStatus.ACTIVE;
        }
        
        proposal.votes[msg.sender] = Vote({
            hasVoted: true,
            choice: choice,
            votingPower: votingPower,
            timestamp: block.timestamp,
            reason: reason
        });
        
        if (choice == VoteChoice.FOR) {
            proposal.forVotes += votingPower;
        } else if (choice == VoteChoice.AGAINST) {
            proposal.againstVotes += votingPower;
        } else {
            proposal.abstainVotes += votingPower;
        }
        
        voterProfiles[msg.sender].votesParticipated++;
        voterProfiles[msg.sender].lastActiveBlock = block.number;
        
        emit VoteCast(proposalId, msg.sender, choice, votingPower, reason);
    }
    
    // ============================================================================
    // VOTE DELEGATION
    // ============================================================================
    
    function delegate(address delegate) external {
        require(delegate != msg.sender, "Cannot delegate to yourself");
        require(delegate != address(0), "Cannot delegate to zero address");
        
        address currentDelegate = voterProfiles[msg.sender].delegate;
        uint256 votingPower = calculateVotingPower(msg.sender);
        
        // Remove from current delegate
        if (currentDelegate != address(0)) {
            delegatedVotingPower[currentDelegate] -= voterProfiles[msg.sender].delegatedPower;
            _removeDelegator(currentDelegate, msg.sender);
        }
        
        // Add to new delegate
        voterProfiles[msg.sender].delegate = delegate;
        voterProfiles[msg.sender].delegatedPower = votingPower;
        delegatedVotingPower[delegate] += votingPower;
        delegators[delegate].push(msg.sender);
        
        emit VotingPowerDelegated(msg.sender, delegate, votingPower);
    }
    
    function undelegate() external {
        address currentDelegate = voterProfiles[msg.sender].delegate;
        require(currentDelegate != address(0), "Not currently delegating");
        
        uint256 delegatedPower = voterProfiles[msg.sender].delegatedPower;
        
        // Remove delegation
        delegatedVotingPower[currentDelegate] -= delegatedPower;
        _removeDelegator(currentDelegate, msg.sender);
        
        voterProfiles[msg.sender].delegate = address(0);
        voterProfiles[msg.sender].delegatedPower = 0;
        
        emit VotingPowerDelegated(msg.sender, address(0), delegatedPower);
    }
    
    function _removeDelegator(address delegate, address delegator) internal {
        address[] storage dels = delegators[delegate];
        for (uint256 i = 0; i < dels.length; i++) {
            if (dels[i] == delegator) {
                dels[i] = dels[dels.length - 1];
                dels.pop();
                break;
            }
        }
    }
    
    // ============================================================================
    // PROPOSAL EXECUTION
    // ============================================================================
    
    function finalizeProposal(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.id == proposalId, "Proposal does not exist");
        require(block.number > proposal.endBlock, "Voting still active");
        require(proposal.status == ProposalStatus.ACTIVE, "Proposal not in active state");
        
        uint256 totalVotes = proposal.forVotes + proposal.againstVotes + proposal.abstainVotes;
        
        // Check quorum
        bool quorumMet = totalVotes >= proposal.quorumRequired;
        
        // Check approval threshold
        uint256 approvalVotes = proposal.forVotes + proposal.abstainVotes;
        bool approvalMet = totalVotes > 0 && (approvalVotes * 10000) / totalVotes >= proposal.approvalThreshold;
        
        if (quorumMet && approvalMet) {
            proposal.status = ProposalStatus.SUCCEEDED;
        } else {
            proposal.status = ProposalStatus.DEFEATED;
        }
    }
    
    function queueProposal(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.status == ProposalStatus.SUCCEEDED, "Proposal not succeeded");
        require(block.number >= proposal.endBlock + proposal.executionDelay, "Execution delay not met");
        
        proposal.status = ProposalStatus.QUEUED;
    }
    
    function executeProposal(uint256 proposalId) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.status == ProposalStatus.QUEUED, "Proposal not queued");
        require(block.timestamp <= proposal.executionDeadline, "Execution window expired");
        require(!proposal.executed, "Already executed");
        
        proposal.executed = true;
        proposal.status = ProposalStatus.EXECUTED;
        
        // Execute treasury allocations if applicable
        if (proposal.proposalType == ProposalType.TREASURY_SPEND) {
            _executeTreasuryAllocation(proposalId);
        }
        
        emit ProposalExecuted(proposalId, msg.sender);
    }
    
    function _executeTreasuryAllocation(uint256 proposalId) internal {
        // This is a simplified implementation
        // In practice, would parse actions array for specific allocations
        uint256 allocationId = nextAllocationId++;
        
        treasuryAllocations[allocationId] = TreasuryAllocation({
            amount: 0, // Would be parsed from actions
            recipient: address(0), // Would be parsed from actions
            purpose: "Treasury allocation", // Would be parsed from actions
            executed: false,
            executionBlock: block.number
        });
    }
    
    function cancelProposal(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.id == proposalId, "Proposal does not exist");
        require(msg.sender == proposal.proposer || msg.sender == owner(), "Not authorized to cancel");
        require(proposal.status == ProposalStatus.PENDING || proposal.status == ProposalStatus.ACTIVE, "Cannot cancel proposal");
        
        proposal.status = ProposalStatus.CANCELLED;
        emit ProposalCancelled(proposalId, msg.sender);
    }
    
    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================
    
    function getProposal(uint256 proposalId) external view returns (
        uint256 id,
        address proposer,
        ProposalType proposalType,
        ProposalStatus status,
        string memory title,
        string memory description,
        uint256 startBlock,
        uint256 endBlock,
        uint256 forVotes,
        uint256 againstVotes,
        uint256 abstainVotes,
        uint256 totalVotingPower,
        uint256 quorumRequired
    ) {
        Proposal storage proposal = proposals[proposalId];
        return (
            proposal.id,
            proposal.proposer,
            proposal.proposalType,
            proposal.status,
            proposal.title,
            proposal.description,
            proposal.startBlock,
            proposal.endBlock,
            proposal.forVotes,
            proposal.againstVotes,
            proposal.abstainVotes,
            proposal.totalVotingPower,
            proposal.quorumRequired
        );
    }
    
    function getProposalActions(uint256 proposalId) external view returns (string[] memory) {
        return proposals[proposalId].actions;
    }
    
    function getVote(uint256 proposalId, address voter) external view returns (
        bool hasVoted,
        VoteChoice choice,
        uint256 votingPower,
        uint256 timestamp,
        string memory reason
    ) {
        Vote storage vote = proposals[proposalId].votes[voter];
        return (vote.hasVoted, vote.choice, vote.votingPower, vote.timestamp, vote.reason);
    }
    
    function getVoterProfile(address voter) external view returns (VoterProfile memory) {
        return voterProfiles[voter];
    }
    
    function getDelegators(address delegate) external view returns (address[] memory) {
        return delegators[delegate];
    }
    
    function proposalNeedsQueuing(uint256 proposalId) external view returns (bool) {
        Proposal storage proposal = proposals[proposalId];
        return proposal.status == ProposalStatus.SUCCEEDED && 
               block.number >= proposal.endBlock + proposal.executionDelay;
    }
    
    function proposalCanExecute(uint256 proposalId) external view returns (bool) {
        Proposal storage proposal = proposals[proposalId];
        return proposal.status == ProposalStatus.QUEUED && 
               block.timestamp <= proposal.executionDeadline && 
               !proposal.executed;
    }
    
    // ============================================================================
    // ADMIN FUNCTIONS
    // ============================================================================
    
    function setProposalThreshold(uint256 newThreshold) external onlyOwner {
        proposalThreshold = newThreshold;
    }
    
    function setVotingDelay(uint256 newDelay) external onlyOwner {
        votingDelay = newDelay;
    }
    
    function setVotingPeriod(uint256 newPeriod) external onlyOwner {
        votingPeriod = newPeriod;
    }
    
    function setExecutionDelay(uint256 newDelay) external onlyOwner {
        executionDelay = newDelay;
    }
    
    function setQuorumThreshold(ProposalType proposalType, uint256 newThreshold) external onlyOwner {
        require(newThreshold <= 5000, "Quorum threshold too high"); // Max 50%
        quorumThresholds[proposalType] = newThreshold;
    }
    
    function setApprovalThreshold(ProposalType proposalType, uint256 newThreshold) external onlyOwner {
        require(newThreshold >= 5000 && newThreshold <= 9000, "Invalid approval threshold"); // 50-90%
        approvalThresholds[proposalType] = newThreshold;
    }
    
    function setTreasuryAddress(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Invalid treasury address");
        treasuryAddress = newTreasury;
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    function emergencyCancel(uint256 proposalId) external onlyOwner {
        proposals[proposalId].status = ProposalStatus.CANCELLED;
        emit ProposalCancelled(proposalId, msg.sender);
    }
}
