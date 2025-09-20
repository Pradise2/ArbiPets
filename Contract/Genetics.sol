// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title Genetics
 * @dev Library for complex genetic calculations in pet breeding
 * @notice Provides helper functions for:
 * - DNA manipulation and combination
 * - Stat inheritance algorithms
 * - Mutation probability calculations
 * - Trait dominance and recessiveness
 * - Element affinity calculations
 */
library Genetics {
    
    // Constants for genetic calculations
    uint256 constant DNA_SEGMENTS = 8;
    uint256 constant MUTATION_BASE_RATE = 5; // 5%
    uint256 constant STAT_VARIANCE = 15; // +/- 15%
    uint256 constant DOMINANT_INHERITANCE_RATE = 60; // 60%
    
    struct GeneticData {
        bytes32 dominantGenes;
        bytes32 recessiveGenes;
        uint8[8] elementAffinities;
        uint16[6] statPotentials;
        uint8 generation;
        uint8 mutationCount;
    }
    
    struct BreedingParameters {
        uint256 parent1DNA;
        uint256 parent2DNA;
        uint8 parent1Element;
        uint8 parent2Element;
        uint8 parent1Rarity;
        uint8 parent2Rarity;
        uint16[6] parent1Stats;
        uint16[6] parent2Stats;
        uint256 randomSeed;
        bool forceMutation;
        bool guaranteeRareOffspring;
    }
    
    struct BreedingResult {
        bytes32 offspringDNA;
        uint8 element;
        uint8 rarity;
        uint16[6] stats;
        bool hadMutation;
        uint8 mutationType; // 0=none, 1=element, 2=rarity, 3=stats, 4=multiple
        uint8 inheritedTraitCount;
    }
    
    // ============================================================================
    // DNA MANIPULATION
    // ============================================================================
    
    /**
     * @dev Combines two parent DNA sequences using crossover and mutation
     * @param parent1DNA First parent's DNA
     * @param parent2DNA Second parent's DNA
     * @param crossoverPoints Array of crossover points for genetic recombination
     * @param mutationRate Chance of mutation per gene segment (0-100)
     * @param randomSeed Random number for deterministic results
     * @return Combined offspring DNA
     */
    function combineDNA(
        bytes32 parent1DNA,
        bytes32 parent2DNA,
        uint8[] memory crossoverPoints,
        uint8 mutationRate,
        uint256 randomSeed
    ) external pure returns (bytes32) {
        uint256 offspring = 0;
        uint256 seed = randomSeed;
        
        // Perform genetic crossover
        for (uint256 i = 0; i < DNA_SEGMENTS; i++) {
            uint256 segmentSize = 256 / DNA_SEGMENTS;
            uint256 startBit = i * segmentSize;
            
            // Determine which parent contributes this segment
            bool useParent1 = _shouldInheritFromParent1(i, crossoverPoints, seed);
            
            uint256 segment;
            if (useParent1) {
                segment = _extractDNASegment(uint256(parent1DNA), startBit, segmentSize);
            } else {
                segment = _extractDNASegment(uint256(parent2DNA), startBit, segmentSize);
            }
            
            // Check for mutation
            seed = uint256(keccak256(abi.encode(seed, i)));
            if ((seed % 100) < mutationRate) {
                segment = _mutateDNASegment(segment, seed);
            }
            
            offspring |= (segment << startBit);
        }
        
        return bytes32(offspring);
    }
    
    /**
     * @dev Extracts a specific segment from DNA
     * @param dna Full DNA sequence
     * @param startBit Starting bit position
     * @param segmentSize Size of segment in bits
     * @return Extracted DNA segment
     */
    function _extractDNASegment(
        uint256 dna,
        uint256 startBit,
        uint256 segmentSize
    ) internal pure returns (uint256) {
        uint256 mask = (1 << segmentSize) - 1;
        return (dna >> startBit) & mask;
    }
    
    /**
     * @dev Applies random mutation to a DNA segment
     * @param segment Original DNA segment
     * @param seed Random seed for mutation
     * @return Mutated DNA segment
     */
    function _mutateDNASegment(uint256 segment, uint256 seed) internal pure returns (uint256) {
        // Flip random bits in the segment
        uint256 mutationMask = seed % (1 << 32); // Use lower 32 bits
        return segment ^ mutationMask;
    }
    
    /**
     * @dev Determines inheritance pattern based on crossover points
     * @param segmentIndex Current DNA segment index
     * @param crossoverPoints Array of crossover positions
     * @param seed Random seed for tie-breaking
     * @return True if parent1 should contribute this segment
     */
    function _shouldInheritFromParent1(
        uint256 segmentIndex,
        uint8[] memory crossoverPoints,
        uint256 seed
    ) internal pure returns (bool) {
        bool fromParent1 = true;
        
        // Switch parent at each crossover point
        for (uint256 i = 0; i < crossoverPoints.length; i++) {
            if (segmentIndex >= crossoverPoints[i]) {
                fromParent1 = !fromParent1;
            }
        }
        
        // Add some randomness for segments not affected by crossover
        if (crossoverPoints.length == 0) {
            fromParent1 = (uint256(keccak256(abi.encode(seed, segmentIndex))) % 100) < DOMINANT_INHERITANCE_RATE;
        }
        
        return fromParent1;
    }
    
    // ============================================================================
    // STAT INHERITANCE
    // ============================================================================
    
    /**
     * @dev Calculates offspring stats based on parent stats and genetic factors
     * @param parent1Stats Parent 1's stats [HP, Energy, Str, Spd, Int, Def]
     * @param parent2Stats Parent 2's stats
     * @param offspringDNA Generated offspring DNA
     * @param generation Offspring generation number
     * @return Calculated offspring stats
     */
    function calculateOffspringStats(
        uint16[6] memory parent1Stats,
        uint16[6] memory parent2Stats,
        bytes32 offspringDNA,
        uint8 generation
    ) external pure returns (uint16[6] memory) {
        uint16[6] memory offspringStats;
        uint256 dnaInt = uint256(offspringDNA);
        
        for (uint256 i = 0; i < 6; i++) {
            // Base inheritance (average of parents)
            uint16 baseValue = (parent1Stats[i] + parent2Stats[i]) / 2;
            
            // Apply genetic variance
            uint256 varianceSeed = (dnaInt >> (i * 32)) & 0xFFFFFFFF;
            int16 variance = int16(int256(varianceSeed % (STAT_VARIANCE * 2 + 1))) - int16(STAT_VARIANCE);
            
            // Apply generation bonus (small improvement over generations)
            uint16 generationBonus = generation > 0 ? generation * 2 : 0;
            
            // Calculate final stat with bounds checking
            int32 finalStat = int32(int16(baseValue)) + int32(variance) + int32(int16(generationBonus));
            
            if (finalStat < 10) finalStat = 10; // Minimum stat value
            if (finalStat > 500) finalStat = 500; // Maximum stat value
            
            offspringStats[i] = uint16(uint32(finalStat));
        }
        
        return offspringStats;
    }
    
    /**
     * @dev Calculates stat potentials based on genetic profile
     * @param currentStats Current pet stats
     * @param dna Pet's DNA
     * @param rarity Pet's rarity level
     * @return Maximum potential for each stat
     */
    function calculateStatPotentials(
        uint16[6] memory currentStats,
        bytes32 dna,
        uint8 rarity
    ) external pure returns (uint16[6] memory) {
        uint16[6] memory potentials;
        uint256 dnaInt = uint256(dna);
        
        // Base multiplier increases with rarity
        uint16[4] memory rarityMultipliers = [uint16(120), 140, 160, 200]; // 120%-200% of current
        uint16 multiplier = rarityMultipliers[rarity];
        
        for (uint256 i = 0; i < 6; i++) {
            // Calculate potential based on current stat and genetic markers
            uint256 geneticFactor = (dnaInt >> (i * 40)) & 0xFFFFFFFFFF;
            uint16 geneticModifier = uint16((geneticFactor % 50) + 75); // 75-125% modifier
            
            uint32 potential = (uint32(currentStats[i]) * multiplier * geneticModifier) / 10000;
            potentials[i] = potential > 1000 ? 1000 : uint16(potential); // Cap at 1000
        }
        
        return potentials;
    }
    
    // ============================================================================
    // ELEMENT AND RARITY CALCULATIONS
    // ============================================================================
    
    /**
     * @dev Determines offspring element based on parents and breeding rules
     * @param parent1Element First parent's element
     * @param parent2Element Second parent's element
     * @param dna Offspring DNA for randomness
     * @param forcedElement Optional forced element (255 = no force)
     * @return Offspring element
     */
    function determineOffspringElement(
        uint8 parent1Element,
        uint8 parent2Element,
        bytes32 dna,
        uint8 forcedElement
    ) external pure returns (uint8) {
        if (forcedElement < 8) return forcedElement;
        
        uint256 seed = uint256(dna) % 100;
        
        // Same element breeding - 90% chance of same element
        if (parent1Element == parent2Element) {
            if (seed < 90) return parent1Element;
            return uint8(uint256(dna) % 8); // 10% chance of random element
        }
        
        // Different elements - check for special combinations
        uint8 specialElement = _getSpecialCombination(parent1Element, parent2Element);
        if (specialElement < 8 && seed < 25) { // 25% chance for special combinations
            return specialElement;
        }
        
        // Normal inheritance - favor one parent
        if (seed < 50) return parent1Element;
        return parent2Element;
    }
    
    /**
     * @dev Gets special element combinations
     * @param element1 First element
     * @param element2 Second element
     * @return Special combination element (255 if none)
     */
    function _getSpecialCombination(uint8 element1, uint8 element2) internal pure returns (uint8) {
        // Fire + Water = Mystic
        if ((element1 == 0 && element2 == 1) || (element1 == 1 && element2 == 0)) return 5;
        
        // Earth + Air = Light
        if ((element1 == 2 && element2 == 3) || (element1 == 3 && element2 == 2)) return 6;
        
        // Electric + Mystic = Dark
        if ((element1 == 4 && element2 == 5) || (element1 == 5 && element2 == 4)) return 7;
        
        // Light + Dark = Mystic (rare transcendence)
        if ((element1 == 6 && element2 == 7) || (element1 == 7 && element2 == 6)) return 5;
        
        return 255; // No special combination
    }
    
    /**
     * @dev Calculates offspring rarity based on parents and genetic factors
     * @param parent1Rarity First parent's rarity
     * @param parent2Rarity Second parent's rarity
     * @param dna Offspring DNA
     * @param guaranteeRare Force rare or better outcome
     * @return Offspring rarity
     */
    function calculateOffspringRarity(
        uint8 parent1Rarity,
        uint8 parent2Rarity,
        bytes32 dna,
        bool guaranteeRare
    ) external pure returns (uint8) {
        uint8 maxRarity = parent1Rarity > parent2Rarity ? parent1Rarity : parent2Rarity;
        uint8 minRarity = parent1Rarity < parent2Rarity ? parent1Rarity : parent2Rarity;
        
        uint256 seed = uint256(dna) % 100;
        
        if (guaranteeRare && maxRarity == 0) maxRarity = 1;
        
        // Inheritance probabilities
        if (seed < 50) return maxRarity; // 50% chance of higher parent rarity
        if (seed < 75) return minRarity; // 25% chance of lower parent rarity
        if (seed < 90) { // 15% chance of rarity improvement
            return maxRarity < 3 ? maxRarity + 1 : maxRarity;
        }
        if (seed < 95) { // 5% chance of rarity decline
            return minRarity > 0 ? minRarity - 1 : 0;
        }
        
        // 5% chance of maximum rarity
        return 3;
    }
    
    // ============================================================================
    // MUTATION CALCULATIONS
    // ============================================================================
    
    /**
     * @dev Calculates mutation probability and type
     * @param parent1Generation First parent generation
     * @param parent2Generation Second parent generation
     * @param parent1Mutations First parent mutation count
     * @param parent2Mutations Second parent mutation count
     * @param baseRate Base mutation rate percentage
     * @param dna Offspring DNA for randomness
     * @return hasMutation Whether mutation occurred
     * @return mutationType Type of mutation (0=none, 1=element, 2=rarity, 3=stats)
     */
    function calculateMutationChance(
        uint8 parent1Generation,
        uint8 parent2Generation,
        uint8 parent1Mutations,
        uint8 parent2Mutations,
        uint8 baseRate,
        bytes32 dna
    ) external pure returns (bool hasMutation, uint8 mutationType) {
        uint256 seed = uint256(dna) % 1000;
        
        // Calculate mutation rate based on lineage
        uint256 mutationRate = baseRate;
        
        // Higher generation = slightly higher mutation rate
        uint8 avgGeneration = (parent1Generation + parent2Generation) / 2;
        mutationRate += avgGeneration * 2;
        
        // More mutations in lineage = higher rate
        uint8 totalMutations = parent1Mutations + parent2Mutations;
        mutationRate += totalMutations * 3;
        
        // Cap mutation rate
        if (mutationRate > 50) mutationRate = 50;
        
        hasMutation = seed < (mutationRate * 10);
        
        if (hasMutation) {
            // Determine mutation type
            uint256 typeRoll = seed % 100;
            if (typeRoll < 40) mutationType = 3; // Stats mutation (40%)
            else if (typeRoll < 70) mutationType = 1; // Element mutation (30%)
            else if (typeRoll < 90) mutationType = 2; // Rarity mutation (20%)
            else mutationType = 4; // Multiple mutations (10%)
        } else {
            mutationType = 0;
        }
    }
    
    // ============================================================================
    // TRAIT INHERITANCE
    // ============================================================================
    
    /**
     * @dev Determines which traits offspring inherits from parents
     * @param parent1Traits Array of parent 1's trait names
     * @param parent2Traits Array of parent 2's trait names
     * @param dna Offspring DNA for randomness
     * @param maxTraits Maximum number of traits offspring can have
     * @return inheritedTraits Array of inherited trait names
     */
    function inheritTraits(
        string[] memory parent1Traits,
        string[] memory parent2Traits,
        bytes32 dna,
        uint8 maxTraits
    ) external pure returns (string[] memory inheritedTraits) {
        uint256 seed = uint256(dna);
        uint256 totalParentTraits = parent1Traits.length + parent2Traits.length;
        
        // Create temporary array to hold all possible traits
        string[] memory allTraits = new string[](totalParentTraits);
        
        // Combine parent traits
        uint256 index = 0;
        for (uint256 i = 0; i < parent1Traits.length; i++) {
            allTraits[index++] = parent1Traits[i];
        }
        for (uint256 i = 0; i < parent2Traits.length; i++) {
            allTraits[index++] = parent2Traits[i];
        }
        
        // Determine number of traits to inherit
        uint8 numTraits = uint8(((seed % 100) * maxTraits) / 100);
        if (numTraits == 0) numTraits = 1; // At least one trait
        if (numTraits > totalParentTraits) numTraits = uint8(totalParentTraits);
        
        inheritedTraits = new string[](numTraits);
        
        // Randomly select traits (simplified - doesn't handle duplicates)
        for (uint256 i = 0; i < numTraits; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 traitIndex = seed % allTraits.length;
            inheritedTraits[i] = allTraits[traitIndex];
        }
    }
    
    // ============================================================================
    // BREEDING COMPATIBILITY
    // ============================================================================
    
    /**
     * @dev Calculates breeding compatibility score between two pets
     * @param pet1Element First pet's element
     * @param pet2Element Second pet's element
     * @param pet1Rarity First pet's rarity
     * @param pet2Rarity Second pet's rarity
     * @param pet1Generation First pet's generation
     * @param pet2Generation Second pet's generation
     * @return compatibility Compatibility score (0-100)
     * @return bonusMultiplier Breeding bonus multiplier (100 = no bonus)
     */
    function calculateBreedingCompatibility(
        uint8 pet1Element,
        uint8 pet2Element,
        uint8 pet1Rarity,
        uint8 pet2Rarity,
        uint8 pet1Generation,
        uint8 pet2Generation
    ) external pure returns (uint8 compatibility, uint16 bonusMultiplier) {
        compatibility = 50; // Base compatibility
        bonusMultiplier = 100; // Base multiplier
        
        // Element compatibility
        if (pet1Element == pet2Element) {
            compatibility += 20; // Same element bonus
        } else if (_getSpecialCombination(pet1Element, pet2Element) < 8) {
            compatibility += 30; // Special combination bonus
            bonusMultiplier += 25; // 25% bonus for special combinations
        } else {
            compatibility += 10; // Different elements still compatible
        }
        
        // Rarity compatibility
        uint8 rarityDiff = pet1Rarity > pet2Rarity ? 
            pet1Rarity - pet2Rarity : pet2Rarity - pet1Rarity;
        
        if (rarityDiff == 0) {
            compatibility += 15; // Same rarity bonus
        } else if (rarityDiff == 1) {
            compatibility += 10; // Adjacent rarity bonus
        } else {
            compatibility -= rarityDiff * 5; // Penalty for big rarity gaps
        }
        
        // Generation compatibility (closer generations are better)
        uint8 genDiff = pet1Generation > pet2Generation ? 
            pet1Generation - pet2Generation : pet2Generation - pet1Generation;
        
        if (genDiff <= 2) {
            compatibility += 10;
        } else {
            compatibility -= genDiff * 2;
        }
        
        // Ensure compatibility is within bounds
        if (compatibility > 100) compatibility = 100;
        if (compatibility < 10) compatibility = 10;
        
        // High compatibility gives breeding bonuses
        if (compatibility >= 80) bonusMultiplier += 20;
        else if (compatibility >= 60) bonusMultiplier += 10;
    }
}
