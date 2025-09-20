// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./PetNFT.sol";
import "./GameToken.sol";

/**
 * @title PetDAO
 * @dev Decentralized governance system for the CryptoPets ecosystem
 * @notice Features:
 * - Proposal creation and voting system
 * - Multi-tier voting power (PETS tokens + NFT ownership + staking)
 * - Timelock execution for critical changes
 * - Delegation system for voting power
 * - Treasury management and fund allocation
 * - Emergency proposals for critical issues
 */
contract PetDAO is Ownable, ReentrancyGuard, Pausable {
    
    // Proposal types
    enum ProposalType { 
        PARAMETER_CHANGE,    // Game parameter adjustments
        TREASURY_ALLOCATION, // Fund allocation proposals
        CONTRACT_UPGRADE,    // Smart contract upgrades
        FEATURE_ADDITION,    // New feature implementations
        EMERGENCY,           // Emergency interventions
        COMMUNITY_GRANT,     // Community funding proposals
        PARTNERSHIP,         // Strategic partnerships
        TOKEN_ECONOMICS      // Tokenomics changes
    }
    
    enum ProposalStatus { 
        PENDING,    // Proposal created, voting not started
        ACTIVE,     // Currently being voted on
        SUCCEEDED,  // Passed vote, ready for execution
        EXECUTED,   // Successfully executed
        DEFEATED,   // Failed to pass
        CANCELLED,  // Cancelled by proposer or admin
        EXPIRED,    // Voting period expired
        QUEUED      // Waiting in timelock
    }
    
    enum VoteType { AGAINST, FOR, ABSTAIN }
    
    struct Proposal {
        uint256 id;
        address proposer;
        ProposalType proposalType;
        ProposalStatus status;
        string title;
        string description;
        string[] targets;           // Contract addresses to call
        bytes[] calldatas;          // Function calls to execute
        uint256[] values;           // ETH values to send
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        uint256 totalVotes;
        uint32 startBlock;
        uint32 endBlock;
        uint32 createdAt;
        uint32 executionDelay;      // Timelock delay in seconds
        uint32 earliestExecution;   // Earliest execution time
        bool executed;
        mapping(address => Receipt) receipts; // Voting receipts
    }
    
    struct Receipt {
        bool hasVoted;
        VoteType support;
        uint256 votes;
        string reason;
    }
    
    struct Delegation {
        address delegate;
        uint256 delegatedVotes;
        uint32 delegatedAt;
    }
    
    struct TreasuryAllocation {
        uint256 proposalId;
        address recipient;
        uint256 amount;
        string purpose;
        bool executed;
        uint32 scheduledFor;
    }
    
    struct VotingPowerSnapshot {
        uint256 tokenBalance;
        uint256 nftBalance;
        uint256 stakingPower;
        uint256 delegatedPower;
        uint256 totalPower;
        uint32 blockNumber;
    }
    
    // Contract references
    PetNFT public petContract;
    GameToken public gameToken;
    
    // Governance parameters
    uint256 public proposalThreshold = 100000 * 10**18; // 100K PETS to create proposal
    uint256 public quorumVotes = 500000 * 10**18;      // 500K votes needed for quorum
    uint256 public votingPeriod = 17280;                // ~3 days in blocks (15s blocks)
    uint256 public votingDelay = 1;                     // Blocks before voting starts
    uint256 public timelockDelay = 172800;              // 48 hours for execution delay
    uint256 public emergencyTimelockDelay = 3600;      // 1 hour for emergency proposals
    
    // Voting power multipliers
    uint256 public tokenVotingPower = 1;                // 1 vote per PETS token
    uint256 public nftVotingPower = 1000 * 10**18;     // 1000 votes per NFT
    uint256 public stakingMultiplier = 150;             // 150% voting power for stakers
    uint256 public rarityMultiplier = 200;              // 200% multiplier for rare NFTs
    
    // Proposal storage
    mapping(uint256 => Proposal) public proposals;
    mapping(address => Delegation) public delegations;
    mapping(address => uint256) public delegatedVoteCounts;
    mapping(uint256 => TreasuryAllocation) public treasuryAllocations;
    mapping(address => VotingPowerSnapshot[]) public votingPowerHistory;
    
    // Proposal counters and tracking
    uint256 public nextProposalId = 1;
    uint256[] public activeProposals;
    uint256[] public executedProposals;
    
    // Treasury management
    uint256 public treasuryBalance;
    address public treasuryMultisig;
    mapping(address => bool) public emergencyExecutors;
    
    // Proposal categories and limits
    mapping(ProposalType => uint256) public proposalCooldowns;
    mapping(ProposalType => uint256) public lastProposalTime;
    mapping(address => mapping(ProposalType => uint32)) public userProposalCounts;
    
    // Events
    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, ProposalType proposalType, string title);
    event VoteCast(address indexed voter, uint256 indexed proposalId, VoteType support, uint256 votes, string reason);
    event ProposalExecuted(uint256 indexed proposalId, bool success);
    event ProposalQueued(uint256 indexed proposalId, uint32 executionTime);
    event ProposalCancelled(uint256 indexed proposalId);
    event VotingPowerDelegated(address indexed delegator, address indexed delegate, uint256 votes);
    event TreasuryAllocationScheduled(uint256 indexed proposalId, address recipient, uint256 amount);
    event EmergencyExecutorAdded(address indexed executor);
    event GovernanceParametersUpdated(uint256 proposalThreshold, uint256 quorumVotes, uint256 votingPeriod);
    
    constructor(
        address _petContract,
        address _gameToken,
        address _treasuryMultisig
    ) {
        petContract = PetNFT(_petContract);
        gameToken = GameToken(_gameToken);
        treasuryMultisig = _treasuryMultisig;
        
        // Initialize proposal cooldowns
        proposalCooldowns[ProposalType.PARAMETER_CHANGE] = 86400;      // 1 day
        proposalCooldowns[ProposalType.TREASURY_ALLOCATION] = 604800;  // 7 days
        proposalCooldowns[ProposalType.CONTRACT_UPGRADE] = 1209600;    // 14 days
        proposalCooldowns[ProposalType.TOKEN_ECONOMICS] = 2592000;     // 30 days
        
        // Add owner as emergency executor
        emergencyExecutors[owner()] = true;
    }
    
    modifier onlyEmergencyExecutor() {
        require(emergencyExecutors[msg.sender], "Not authorized for emergency execution");
        _;
    }
    
    // ============================================================================
    // PROPOSAL CREATION
    // ============================================================================
    
    function propose(
        ProposalType proposalType,
        string calldata title,
        string calldata description,
        string[] calldata targets,
        bytes[] calldata calldatas,
        uint256[] calldata values
    ) external nonReentrant whenNotPaused returns (uint256) {
        require(getVotingPower(msg.sender) >= proposalThreshold, "Insufficient voting power to propose");
        require(bytes(title).length > 0, "Title cannot be empty");
        require(bytes(description).length > 0, "Description cannot be empty");
        require(targets.length == calldatas.length && targets.length == values.length, "Array length mismatch");
        require(targets.length > 0, "Must have at least one action");
        
        // Check proposal cooldowns
        if (proposalCooldowns[proposalType] > 0) {
            require(
                block.timestamp >= lastProposalTime[proposalType] + proposalCooldowns[proposalType],
                "Proposal type on cooldown"
            );
        }
        
        // Check user proposal limits (prevent spam)
        require(userProposalCounts[msg.sender][proposalType] < 5, "Too many proposals of this type");
        
        uint256 proposalId = nextProposalId++;
        uint32 startBlock = uint32(block.number) + uint32(votingDelay);
        uint32 endBlock = startBlock + uint32(votingPeriod);
        
        // Determine execution delay based on proposal type
        uint32 executionDelay = proposalType == ProposalType.EMERGENCY ? 
            uint32(emergencyTimelockDelay) : uint32(timelockDelay);
        
        // Create proposal storage (mappings initialized separately)
        proposals[proposalId].id = proposalId;
        proposals[proposalId].proposer = msg.sender;
        proposals[proposalId].proposalType = proposalType;
        proposals[proposalId].status = ProposalStatus.PENDING;
        proposals[proposalId].title = title;
        proposals[proposalId].description = description;
        proposals[proposalId].targets = targets;
        proposals[proposalId].calldatas = calldatas;
        proposals[proposalId].values = values;
        proposals[proposalId].startBlock = startBlock;
        proposals[proposalId].endBlock = endBlock;
        proposals[proposalId].createdAt = uint32(block.timestamp);
        proposals[proposalId].executionDelay = executionDelay;
        
        // Update tracking
        activeProposals.push(proposalId);
        lastProposalTime[proposalType] = block.timestamp;
        userProposalCounts[msg.sender][proposalType]++;
        
        emit ProposalCreated(proposalId, msg.sender, proposalType, title);
        return proposalId;
    }
    
    function createEmergencyProposal(
        string calldata title,
        string calldata description,
        string[] calldata targets,
        bytes[] calldata calldatas,
        uint256[] calldata values
    ) external onlyEmergencyExecutor returns (uint256) {
        uint256 proposalId = nextProposalId++;
        uint32 startBlock = uint32(block.number) + 1; // Immediate voting
        uint32 endBlock = startBlock + uint32(votingPeriod / 3); // Shorter voting period
        
        proposals[proposalId].id = proposalId;
        proposals[proposalId].proposer = msg.sender;
        proposals[proposalId].proposalType = ProposalType.EMERGENCY;
        proposals[proposalId].status = ProposalStatus.ACTIVE;
        proposals[proposalId].title = title;
        proposals[proposalId].description = description;
        proposals[proposalId].targets = targets;
        proposals[proposalId].calldatas = calldatas;
        proposals[proposalId].values = values;
        proposals[proposalId].startBlock = startBlock;
        proposals[proposalId].endBlock = endBlock;
        proposals[proposalId].createdAt = uint32(block.timestamp);
        proposals[proposalId].executionDelay = uint32(emergencyTimelockDelay);
        
        activeProposals.push(proposalId);
        
        emit ProposalCreated(proposalId, msg.sender, ProposalType.EMERGENCY, title);
        return proposalId;
    }
    
    // ============================================================================
    // VOTING SYSTEM
    // ============================================================================
    
    function castVote(uint256 proposalId, VoteType support) external nonReentrant {
        _castVote(msg.sender, proposalId, support, "");
    }
    
    function castVoteWithReason(uint256 proposalId, VoteType support, string calldata reason) external nonReentrant {
        _castVote(msg.sender, proposalId, support, reason);
    }
    
    function _castVote(address voter, uint256 proposalId, VoteType support, string memory reason) internal {
        require(state(proposalId) == ProposalStatus.ACTIVE, "Proposal not active");
        require(!proposals[proposalId].receipts[voter].hasVoted, "Already voted");
        
        uint256 votes = getVotingPowerAt(voter, proposals[proposalId].startBlock);
        require(votes > 0, "No voting power");
        
        // Record the vote
        proposals[proposalId].receipts[voter] = Receipt({
            hasVoted: true,
            support: support,
            votes: votes,
            reason: reason
        });
        
        // Update vote tallies
        if (support == VoteType.FOR) {
            proposals[proposalId].forVotes += votes;
        } else if (support == VoteType.AGAINST) {
            proposals[proposalId].againstVotes += votes;
        } else {
            proposals[proposalId].abstainVotes += votes;
        }
        
        proposals[proposalId].totalVotes += votes;
        
        emit VoteCast(voter, proposalId, support, votes, reason);
    }
    
    function castVoteBySig(
        uint256 proposalId,
        VoteType support,
        address voter,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("CryptoPets DAO")),
                block.chainid,
                address(this)
            )
        );
        
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Ballot(uint256 proposalId,uint8 support,address voter)"),
                proposalId,
                uint8(support),
                voter
            )
        );
        
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        address signatory = ecrecover(digest, v, r, s);
        require(signatory == voter, "Invalid signature");
        
        _castVote(voter, proposalId, support, "");
    }
    
    // ============================================================================
    // PROPOSAL EXECUTION
    // ============================================================================
    
    function queue(uint256 proposalId) external {
        require(state(proposalId) == ProposalStatus.SUCCEEDED, "Proposal not succeeded");
        
        uint32 executionTime = uint32(block.timestamp) + proposals[proposalId].executionDelay;
        proposals[proposalId].earliestExecution = executionTime;
        proposals[proposalId].status = ProposalStatus.QUEUED;
        
        emit ProposalQueued(proposalId, executionTime);
    }
    
    function execute(uint256 proposalId) external nonReentrant {
        require(state(proposalId) == ProposalStatus.QUEUED, "Proposal not queued");
        require(block.timestamp >= proposals[proposalId].earliestExecution, "Timelock not expired");
        
        proposals[proposalId].status = ProposalStatus.EXECUTED;
        proposals[proposalId].executed = true;
        
        // Execute all actions in the proposal
        bool success = true;
        for (uint256 i = 0; i < proposals[proposalId].targets.length; i++) {
            (bool actionSuccess,) = _executeAction(
                proposals[proposalId].targets[i],
                proposals[proposalId].values[i],
                proposals[proposalId].calldatas[i]
            );
            success = success && actionSuccess;
        }
        
        // Handle treasury allocations
        if (proposals[proposalId].proposalType == ProposalType.TREASURY_ALLOCATION) {
            _processTreasuryAllocation(proposalId);
        }
        
        // Remove from active proposals
        _removeFromActiveProposals(proposalId);
        executedProposals.push(proposalId);
        
        emit ProposalExecuted(proposalId, success);
    }
    
    function _executeAction(string memory target, uint256 value, bytes memory data) internal returns (bool, bytes memory) {
        address targetAddress = _parseAddress(target);
        return targetAddress.call{value: value}(data);
    }
    
    function _parseAddress(string memory addressStr) internal pure returns (address) {
        bytes memory addressBytes = bytes(addressStr);
        require(addressBytes.length == 42, "Invalid address format");
        
        uint160 result = 0;
        for (uint i = 2; i < 42; i++) {
            result *= 16;
            uint8 b = uint8(addressBytes[i]);
            if (b >= 48 && b <= 57) {
                result += b - 48;
            } else if (b >= 65 && b <= 70) {
                result += b - 55;
            } else if (b >= 97 && b <= 102) {
                result += b - 87;
            }
        }
        return address(result);
    }
    
    function _processTreasuryAllocation(uint256 proposalId) internal {
        // This would extract allocation details from proposal data
        // Simplified implementation
        treasuryAllocations[proposalId] = TreasuryAllocation({
            proposalId: proposalId,
            recipient: address(0), // Would be extracted from proposal
            amount: 0,             // Would be extracted from proposal
            purpose: "",           // Would be extracted from proposal
            executed: false,
            scheduledFor: uint32(block.timestamp)
        });
        
        emit TreasuryAllocationScheduled(proposalId, address(0), 0);
    }
    
    // ============================================================================
    // DELEGATION SYSTEM
    // ============================================================================
    
    function delegate(address delegatee) external {
        _delegate(msg.sender, delegatee);
    }
    
    function delegateBySig(
        address delegatee,
        address delegator,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(block.timestamp <= expiry, "Signature expired");
        
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("CryptoPets DAO")),
                block.chainid,
                address(this)
            )
        );
        
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Delegation(address delegatee,address delegator,uint256 nonce,uint256 expiry)"),
                delegatee,
                delegator,
                nonce,
                expiry
            )
        );
        
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        address signatory = ecrecover(digest, v, r, s);
        require(signatory == delegator, "Invalid signature");
        
        _delegate(delegator, delegatee);
    }
    
    function _delegate(address delegator, address delegatee) internal {
        address currentDelegate = delegations[delegator].delegate;
        uint256 delegatorBalance = getVotingPower(delegator);
        
        // Remove votes from current delegate
        if (currentDelegate != address(0)) {
            delegatedVoteCounts[currentDelegate] -= delegations[delegator].delegatedVotes;
        }
        
        // Set new delegation
        delegations[delegator] = Delegation({
            delegate: delegatee,
            delegatedVotes: delegatorBalance,
            delegatedAt: uint32(block.timestamp)
        });
        
        // Add votes to new delegate
        if (delegatee != address(0)) {
            delegatedVoteCounts[delegatee] += delegatorBalance;
        }
        
        emit VotingPowerDelegated(delegator, delegatee, delegatorBalance);
    }
    
    // ============================================================================
    // VOTING POWER CALCULATIONS
    // ============================================================================
    
    function getVotingPower(address account) public view returns (uint256) {
        return getVotingPowerAt(account, block.number);
    }
    
    function getVotingPowerAt(address account, uint256 blockNumber) public view returns (uint256) {
        uint256 tokenBalance = gameToken.balanceOf(account);
        uint256 nftBalance = petContract.balanceOf(account);
        
        // Base voting power from tokens and NFTs
        uint256 tokenVotes = tokenBalance * tokenVotingPower;
        uint256 nftVotes = nftBalance * nftVotingPower;
        
        // Apply rarity multipliers for NFTs
        uint256 rarityBonus = _calculateRarityBonus(account);
        
        // Apply staking multiplier (simplified - would check actual staking contract)
        uint256 stakingBonus = _calculateStakingBonus(account);
        
        // Calculate total base power
        uint256 basePower = tokenVotes + nftVotes + rarityBonus + stakingBonus;
        
        // Add delegated votes
        uint256 delegatedPower = delegatedVoteCounts[account];
        
        return basePower + delegatedPower;
    }
    
    function _calculateRarityBonus(address account) internal view returns (uint256) {
        uint256 bonus = 0;
        uint256 balance = petContract.balanceOf(account);
        
        for (uint256 i = 0; i < balance; i++) {
            uint256 petId = petContract.tokenOfOwnerByIndex(account, i);
            PetNFT.Pet memory pet = petContract.getPet(petId);
            
            if (pet.rarity >= 2) { // Epic or Legendary
                bonus += nftVotingPower * rarityMultiplier / 100;
            }
        }
        
        return bonus;
    }
    
    function _calculateStakingBonus(address account) internal view returns (uint256) {
        // Simplified - would integrate with actual staking contract
        // For now, assume some staking bonus based on token balance
        uint256 tokenBalance = gameToken.balanceOf(account);
        return (tokenBalance * stakingMultiplier / 100) - tokenBalance;
    }
    
    // ============================================================================
    // PROPOSAL STATE MANAGEMENT
    // ============================================================================
    
    function state(uint256 proposalId) public view returns (ProposalStatus) {
        require(proposalId < nextProposalId && proposalId > 0, "Invalid proposal");
        
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.executed) {
            return ProposalStatus.EXECUTED;
        } else if (proposal.status == ProposalStatus.CANCELLED) {
            return ProposalStatus.CANCELLED;
        } else if (proposal.status == ProposalStatus.QUEUED) {
            return ProposalStatus.QUEUED;
        } else if (block.number <= proposal.startBlock) {
            return ProposalStatus.PENDING;
        } else if (block.number <= proposal.endBlock) {
            return ProposalStatus.ACTIVE;
        } else if (proposal.forVotes <= proposal.againstVotes || proposal.totalVotes < quorumVotes) {
            return ProposalStatus.DEFEATED;
        } else {
            return ProposalStatus.SUCCEEDED;
        }
    }
    
    function cancel(uint256 proposalId) external {
        require(
            msg.sender == proposals[proposalId].proposer || msg.sender == owner(),
            "Only proposer or admin can cancel"
        );
        require(
            state(proposalId) == ProposalStatus.PENDING || state(proposalId) == ProposalStatus.ACTIVE,
            "Cannot cancel executed proposal"
        );
        
        proposals[proposalId].status = ProposalStatus.CANCELLED;
        _removeFromActiveProposals(proposalId);
        
        emit ProposalCancelled(proposalId);
    }
    
    function _removeFromActiveProposals(uint256 proposalId) internal {
        for (uint256 i = 0; i < activeProposals.length; i++) {
            if (activeProposals[i] == proposalId) {
                activeProposals[i] = activeProposals[activeProposals.length - 1];
                activeProposals.pop();
                break;
            }
        }
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
        uint256 forVotes,
        uint256 againstVotes,
        uint256 abstainVotes,
        uint32 startBlock,
        uint32 endBlock,
        uint32 createdAt
    ) {
        Proposal storage proposal = proposals[proposalId];
        return (
            proposal.id,
            proposal.proposer,
            proposal.proposalType,
            state(proposalId),
            proposal.title,
            proposal.description,
            proposal.forVotes,
            proposal.againstVotes,
            proposal.abstainVotes,
            proposal.startBlock,
            proposal.endBlock,
            proposal.createdAt
        );
    }
    
    function getProposalActions(uint256 proposalId) external view returns (
        string[] memory targets,
        bytes[] memory calldatas,
        uint256[] memory values
    ) {
        return (
            proposals[proposalId].targets,
            proposals[proposalId].calldatas,
            proposals[proposalId].values
        );
    }
    
    function getActiveProposals() external view returns (uint256[] memory) {
        return activeProposals;
    }
    
    function getExecutedProposals() external view returns (uint256[] memory) {
        return executedProposals;
    }
    
    function getReceipt(uint256 proposalId, address voter) external view returns (Receipt memory) {
        return proposals[proposalId].receipts[voter];
    }
    
    function getDelegation(address account) external view returns (Delegation memory) {
        return delegations[account];
    }
    
    // ============================================================================
    // ADMIN FUNCTIONS
    // ============================================================================
    
    function updateGovernanceParameters(
        uint256 _proposalThreshold,
        uint256 _quorumVotes,
        uint256 _votingPeriod,
        uint256 _votingDelay,
        uint256 _timelockDelay
    ) external onlyOwner {
        proposalThreshold = _proposalThreshold;
        quorumVotes = _quorumVotes;
        votingPeriod = _votingPeriod;
        votingDelay = _votingDelay;
        timelockDelay = _timelockDelay;
        
        emit GovernanceParametersUpdated(_proposalThreshold, _quorumVotes, _votingPeriod);
    }
    
    function updateVotingPowerMultipliers(
        uint256 _tokenVotingPower,
        uint256 _nftVotingPower,
        uint256 _stakingMultiplier,
        uint256 _rarityMultiplier
    ) external onlyOwner {
        tokenVotingPower = _tokenVotingPower;
        nftVotingPower = _nftVotingPower;
        stakingMultiplier = _stakingMultiplier;
        rarityMultiplier = _rarityMultiplier;
    }
    
    function addEmergencyExecutor(address executor) external onlyOwner {
        emergencyExecutors[executor] = true;
        emit EmergencyExecutorAdded(executor);
    }
    
    function removeEmergencyExecutor(address executor) external onlyOwner {
        emergencyExecutors[executor] = false;
    }
    
    function setTreasuryMultisig(address _treasuryMultisig) external onlyOwner {
        require(_treasuryMultisig != address(0), "Invalid treasury address");
        treasuryMultisig = _treasuryMultisig;
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    // ============================================================================
    // TREASURY MANAGEMENT
    // ============================================================================
    
    function depositToTreasury() external payable {
        treasuryBalance += msg.value;
    }
    
    function withdrawFromTreasury(address payable recipient, uint256 amount) external {
        require(msg.sender == treasuryMultisig, "Only treasury multisig can withdraw");
        require(amount <= treasuryBalance, "Insufficient treasury balance");
        
        treasuryBalance -= amount;
        recipient.transfer(amount);
    }
    
    function getTreasuryBalance() external view returns (uint256) {
        return treasuryBalance;
    }
    
    // ============================================================================
    // EMERGENCY FUNCTIONS
    // ============================================================================
    
    function emergencyPause() external onlyEmergencyExecutor {
        _pause();
    }
    
    function emergencyExecute(
        address target,
        uint256 value,
        bytes calldata data
    ) external onlyEmergencyExecutor returns (bool, bytes memory) {
        return target.call{value: value}(data);
    }
}
