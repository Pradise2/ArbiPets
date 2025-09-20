// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./PetNFT.sol";

/**
 * @title PetMetadata
 * @dev Simple metadata contract that points to backend API for dynamic metadata
 * @notice This contract manages the base URI for pet metadata served from your backend
 */
contract PetMetadata is Ownable {
    
    // Contract references
    PetNFT public petContract;
    
    // Base URI for metadata API
    string public baseTokenURI;
    
    // Backup IPFS URI in case backend is down
    string public backupTokenURI;
    
    // Emergency metadata override for specific tokens
    mapping(uint256 => string) public customTokenURIs;
    mapping(uint256 => bool) public hasCustomURI;
    
    // Contract metadata for OpenSea
    string public contractURI;
    
    // Events
    event BaseTokenURIUpdated(string newBaseURI);
    event BackupTokenURIUpdated(string newBackupURI);
    event CustomTokenURISet(uint256 indexed petId, string customURI);
    event ContractURIUpdated(string newContractURI);
    
    constructor(
        address _petContract,
        string memory _baseTokenURI
    ) {
        petContract = PetNFT(_petContract);
        baseTokenURI = _baseTokenURI;
        
        // Set default contract metadata
        contractURI = string(abi.encodePacked(_baseTokenURI, "contract"));
    }
    
    /**
     * @dev Returns the token URI for a given pet ID
     * @param petId The ID of the pet
     * @return The complete metadata URI
     */
    function tokenURI(uint256 petId) external view returns (string memory) {
        require(petContract.ownerOf(petId) != address(0), "Pet does not exist");
        
        // Check for custom URI first
        if (hasCustomURI[petId]) {
            return customTokenURIs[petId];
        }
        
        // Return backend API URL
        return string(abi.encodePacked(
            baseTokenURI,
            "/",
            Strings.toString(petId)
        ));
    }
    
    /**
     * @dev Set the base URI for all tokens (points to your backend API)
     * @param _baseTokenURI New base URI (e.g., "https://api.cryptopets.io/metadata")
     */
    function setBaseTokenURI(string calldata _baseTokenURI) external onlyOwner {
        baseTokenURI = _baseTokenURI;
        emit BaseTokenURIUpdated(_baseTokenURI);
    }
    
    /**
     * @dev Set backup URI (usually IPFS) in case backend is unavailable
     * @param _backupTokenURI Backup URI for metadata
     */
    function setBackupTokenURI(string calldata _backupTokenURI) external onlyOwner {
        backupTokenURI = _backupTokenURI;
        emit BackupTokenURIUpdated(_backupTokenURI);
    }
    
    /**
     * @dev Set custom URI for specific pet (emergency override)
     * @param petId Pet ID to set custom URI for
     * @param customURI Custom metadata URI
     */
    function setCustomTokenURI(uint256 petId, string calldata customURI) external onlyOwner {
        require(petContract.ownerOf(petId) != address(0), "Pet does not exist");
        customTokenURIs[petId] = customURI;
        hasCustomURI[petId] = true;
        emit CustomTokenURISet(petId, customURI);
    }
    
    /**
     * @dev Remove custom URI for specific pet
     * @param petId Pet ID to remove custom URI for
     */
    function removeCustomTokenURI(uint256 petId) external onlyOwner {
        delete customTokenURIs[petId];
        hasCustomURI[petId] = false;
    }
    
    /**
     * @dev Set contract-level metadata URI for OpenSea
     * @param _contractURI URI for contract metadata
     */
    function setContractURI(string calldata _contractURI) external onlyOwner {
        contractURI = _contractURI;
        emit ContractURIUpdated(_contractURI);
    }
    
    /**
     * @dev Get the backup token URI
     * @param petId Pet ID
     * @return Backup metadata URI
     */
    function getBackupTokenURI(uint256 petId) external view returns (string memory) {
        require(bytes(backupTokenURI).length > 0, "No backup URI set");
        return string(abi.encodePacked(backupTokenURI, "/", Strings.toString(petId)));
    }
    
    /**
     * @dev Batch update custom URIs (for migration scenarios)
     * @param petIds Array of pet IDs
     * @param customURIs Array of custom URIs
     */
    function batchSetCustomTokenURIs(
        uint256[] calldata petIds, 
        string[] calldata customURIs
    ) external onlyOwner {
        require(petIds.length == customURIs.length, "Array length mismatch");
        
        for (uint256 i = 0; i < petIds.length; i++) {
            customTokenURIs[petIds[i]] = customURIs[i];
            hasCustomURI[petIds[i]] = true;
            emit CustomTokenURISet(petIds[i], customURIs[i]);
        }
    }
}

// Add this import at the top
import "@openzeppelin/contracts/utils/Strings.sol";
