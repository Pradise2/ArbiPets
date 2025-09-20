// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title GameToken (PETS)
 * @dev ERC-20 utility token for the CryptoPets ecosystem with tokenomics
 * @notice Token Distribution:
 * - Player Rewards: 40% (4B tokens)
 * - Team & Advisors: 15% (1.5B tokens) - 6mo cliff, 36mo vesting
 * - Foundation Treasury: 15% (1.5B tokens)
 * - Liquidity & Market Making: 15% (1.5B tokens)
 * - Strategic Sale & Partners: 10% (1B tokens) - 3mo cliff, 24mo vesting
 * - Public Sale / Community: 5% (500M tokens)
 */
contract GameToken is ERC20, ERC20Burnable, Ownable, Pausable, ReentrancyGuard {
    
    // Token allocation constants
    uint256 public constant MAX_SUPPLY = 10_000_000_000 * 10**18; // 10 billion
    uint256 public constant PLAYER_REWARDS_ALLOCATION = 4_000_000_000 * 10**18; // 40%
    uint256 public constant TEAM_ALLOCATION = 1_500_000_000 * 10**18; // 15%
    uint256 public constant FOUNDATION_ALLOCATION = 1_500_000_000 * 10**18; // 15%
    uint256 public constant LIQUIDITY_ALLOCATION = 1_500_000_000 * 10**18; // 15%
    uint256 public constant STRATEGIC_ALLOCATION = 1_000_000_000 * 10**18; // 10%
    uint256 public constant PUBLIC_ALLOCATION = 500_000_000 * 10**18; // 5%
    
    // Vesting parameters
    uint256 public constant TEAM_CLIFF_DURATION = 180 days; // 6 months
    uint256 public constant TEAM_VESTING_DURATION = 1080 days; // 36 months
    uint256 public constant STRATEGIC_CLIFF_DURATION = 90 days; // 3 months
    uint256 public constant STRATEGIC_VESTING_DURATION = 720 days; // 24 months
    
    // Contract deployment time
    uint256 public immutable deploymentTime;
    
    // Allocation tracking
    uint256 public playerRewardsMinted;
    uint256 public teamTokensMinted;
    uint256 public foundationTokensMinted;
    uint256 public liquidityTokensMinted;
    uint256 public strategicTokensMinted;
    uint256 public publicTokensMinted;
    
    // Vesting tracking
    mapping(address => uint256) public teamVestingAmount;
    mapping(address => uint256) public teamVestingClaimed;
    mapping(address => uint256) public strategicVestingAmount;
    mapping(address => uint256) public strategicVestingClaimed;
    
    // Authorized addresses
    mapping(address => bool) public minters; // Game contracts that can mint player rewards
    mapping(address => bool) public teamMembers;
    mapping(address => bool) public strategicPartners;
    address public foundationTreasury;
    address public liquidityManager;
    
    // Events
    event MinterAdded(address indexed minter);
    event MinterRemoved(address indexed minter);
    event PlayerRewardsMinted(address indexed to, uint256 amount, address indexed minter);
    event TeamVestingSet(address indexed member, uint256 amount);
    event StrategicVestingSet(address indexed partner, uint256 amount);
    event VestedTokensClaimed(address indexed beneficiary, uint256 amount, string vestingType);
    event FoundationTreasurySet(address indexed treasury);
    event LiquidityManagerSet(address indexed manager);
    
    constructor() ERC20("CryptoPets Token", "PETS") {
        deploymentTime = block.timestamp;
        
        // Mint public allocation immediately to deployer for distribution
        _mint(msg.sender, PUBLIC_ALLOCATION);
        publicTokensMinted = PUBLIC_ALLOCATION;
    }
    
    // ============================================================================
    // ADMIN FUNCTIONS
    // ============================================================================
    
    function setFoundationTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Cannot set zero address");
        foundationTreasury = _treasury;
        emit FoundationTreasurySet(_treasury);
    }
    
    function setLiquidityManager(address _manager) external onlyOwner {
        require(_manager != address(0), "Cannot set zero address");
        liquidityManager = _manager;
        emit LiquidityManagerSet(_manager);
    }
    
    function addMinter(address minter) external onlyOwner {
        require(minter != address(0), "Cannot add zero address");
        minters[minter] = true;
        emit MinterAdded(minter);
    }
    
    function removeMinter(address minter) external onlyOwner {
        minters[minter] = false;
        emit MinterRemoved(minter);
    }
    
    // ============================================================================
    // VESTING SETUP
    // ============================================================================
    
    function setTeamVesting(address[] calldata members, uint256[] calldata amounts) external onlyOwner {
        require(members.length == amounts.length, "Arrays length mismatch");
        
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalAmount += amounts[i];
        }
        
        require(teamTokensMinted + totalAmount <= TEAM_ALLOCATION, "Exceeds team allocation");
        
        for (uint256 i = 0; i < members.length; i++) {
            require(members[i] != address(0), "Cannot set zero address");
            teamMembers[members[i]] = true;
            teamVestingAmount[members[i]] += amounts[i];
            emit TeamVestingSet(members[i], amounts[i]);
        }
        
        teamTokensMinted += totalAmount;
    }
    
    function setStrategicVesting(address[] calldata partners, uint256[] calldata amounts) external onlyOwner {
        require(partners.length == amounts.length, "Arrays length mismatch");
        
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalAmount += amounts[i];
        }
        
        require(strategicTokensMinted + totalAmount <= STRATEGIC_ALLOCATION, "Exceeds strategic allocation");
        
        for (uint256 i = 0; i < partners.length; i++) {
            require(partners[i] != address(0), "Cannot set zero address");
            strategicPartners[partners[i]] = true;
            strategicVestingAmount[partners[i]] += amounts[i];
            emit StrategicVestingSet(partners[i], amounts[i]);
        }
        
        strategicTokensMinted += totalAmount;
    }
    
    // ============================================================================
    // MINTING FUNCTIONS
    // ============================================================================
    
    function mintPlayerRewards(address to, uint256 amount) external whenNotPaused {
        require(minters[msg.sender], "Not authorized to mint");
        require(to != address(0), "Cannot mint to zero address");
        require(playerRewardsMinted + amount <= PLAYER_REWARDS_ALLOCATION, "Exceeds player rewards allocation");
        
        _mint(to, amount);
        playerRewardsMinted += amount;
        emit PlayerRewardsMinted(to, amount, msg.sender);
    }
    
    function mintFoundationTokens(uint256 amount) external onlyOwner {
        require(foundationTreasury != address(0), "Foundation treasury not set");
        require(foundationTokensMinted + amount <= FOUNDATION_ALLOCATION, "Exceeds foundation allocation");
        
        _mint(foundationTreasury, amount);
        foundationTokensMinted += amount;
    }
    
    function mintLiquidityTokens(uint256 amount) external {
        require(msg.sender == liquidityManager || msg.sender == owner(), "Not authorized");
        require(liquidityManager != address(0), "Liquidity manager not set");
        require(liquidityTokensMinted + amount <= LIQUIDITY_ALLOCATION, "Exceeds liquidity allocation");
        
        _mint(liquidityManager, amount);
        liquidityTokensMinted += amount;
    }
    
    // ============================================================================
    // VESTING CLAIM FUNCTIONS
    // ============================================================================
    
    function claimTeamTokens() external nonReentrant {
        require(teamMembers[msg.sender], "Not a team member");
        
        uint256 claimable = calculateTeamClaimable(msg.sender);
        require(claimable > 0, "No tokens to claim");
        
        teamVestingClaimed[msg.sender] += claimable;
        _mint(msg.sender, claimable);
        
        emit VestedTokensClaimed(msg.sender, claimable, "team");
    }
    
    function claimStrategicTokens() external nonReentrant {
        require(strategicPartners[msg.sender], "Not a strategic partner");
        
        uint256 claimable = calculateStrategicClaimable(msg.sender);
        require(claimable > 0, "No tokens to claim");
        
        strategicVestingClaimed[msg.sender] += claimable;
        _mint(msg.sender, claimable);
        
        emit VestedTokensClaimed(msg.sender, claimable, "strategic");
    }
    
    // ============================================================================
    // VESTING CALCULATIONS
    // ============================================================================
    
    function calculateTeamClaimable(address member) public view returns (uint256) {
        if (!teamMembers[member]) return 0;
        
        uint256 elapsed = block.timestamp - deploymentTime;
        
        // Check if cliff period has passed
        if (elapsed < TEAM_CLIFF_DURATION) return 0;
        
        uint256 totalVested;
        if (elapsed >= TEAM_CLIFF_DURATION + TEAM_VESTING_DURATION) {
            // Fully vested
            totalVested = teamVestingAmount[member];
        } else {
            // Partially vested (linear after cliff)
            uint256 vestingElapsed = elapsed - TEAM_CLIFF_DURATION;
            totalVested = (teamVestingAmount[member] * vestingElapsed) / TEAM_VESTING_DURATION;
        }
        
        return totalVested - teamVestingClaimed[member];
    }
    
    function calculateStrategicClaimable(address partner) public view returns (uint256) {
        if (!strategicPartners[partner]) return 0;
        
        uint256 elapsed = block.timestamp - deploymentTime;
        
        // Check if cliff period has passed
        if (elapsed < STRATEGIC_CLIFF_DURATION) return 0;
        
        uint256 totalVested;
        if (elapsed >= STRATEGIC_CLIFF_DURATION + STRATEGIC_VESTING_DURATION) {
            // Fully vested
            totalVested = strategicVestingAmount[partner];
        } else {
            // Partially vested (linear after cliff)
            uint256 vestingElapsed = elapsed - STRATEGIC_CLIFF_DURATION;
            totalVested = (strategicVestingAmount[partner] * vestingElapsed) / STRATEGIC_VESTING_DURATION;
        }
        
        return totalVested - strategicVestingClaimed[partner];
    }
    
    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================
    
    function getRemainingAllocation(string calldata allocationType) external view returns (uint256) {
        bytes32 typeHash = keccak256(abi.encodePacked(allocationType));
        
        if (typeHash == keccak256(abi.encodePacked("player"))) {
            return PLAYER_REWARDS_ALLOCATION - playerRewardsMinted;
        } else if (typeHash == keccak256(abi.encodePacked("team"))) {
            return TEAM_ALLOCATION - teamTokensMinted;
        } else if (typeHash == keccak256(abi.encodePacked("foundation"))) {
            return FOUNDATION_ALLOCATION - foundationTokensMinted;
        } else if (typeHash == keccak256(abi.encodePacked("liquidity"))) {
            return LIQUIDITY_ALLOCATION - liquidityTokensMinted;
        } else if (typeHash == keccak256(abi.encodePacked("strategic"))) {
            return STRATEGIC_ALLOCATION - strategicTokensMinted;
        } else if (typeHash == keccak256(abi.encodePacked("public"))) {
            return PUBLIC_ALLOCATION - publicTokensMinted;
        }
        
        return 0;
    }
    
    function getAllocationStatus() external view returns (
        uint256 playerMinted,
        uint256 teamMinted,
        uint256 foundationMinted,
        uint256 liquidityMinted,
        uint256 strategicMinted,
        uint256 publicMinted,
        uint256 totalMinted
    ) {
        return (
            playerRewardsMinted,
            teamTokensMinted,
            foundationTokensMinted,
            liquidityTokensMinted,
            strategicTokensMinted,
            publicTokensMinted,
            totalSupply()
        );
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
    
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        super._beforeTokenTransfer(from, to, amount);
        require(!paused(), "Token transfers are paused");
    }
}
