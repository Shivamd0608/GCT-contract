// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/// @title GreenCreditToken
/// @notice ERC-1155 token contract for tokenized green credits with approval-based minting and revocation.
/// @dev Implements mint approvals with expiry, on-chain revocation, token freezing, batch operations, and base URI management.
contract GreenCreditToken is ERC1155, Ownable {

    enum CreditType { Green, Carbon, Water, Renewable }

    struct CreditInfo {
        CreditType creditType;     // Credit category
        string projectTitle;       // Max 30 chars
        string location;           // Optional
        string certificateHash;    // IPFS CID or proof (46-128 chars)
        bool exists;               // True if credit is registered
        bool revoked;              // True if credit revoked
    }

    struct MintApproval {
        uint256 amount;            // Approved amount
        uint256 expiry;            // Timestamp until approval is valid
    }

    // Storage
    mapping(uint256 => CreditInfo) private creditData;                  // tokenId => credit metadata
    mapping(address => mapping(uint256 => MintApproval)) public approvedMints; // user => tokenId => approval
    mapping(address => mapping(uint256 => bool)) public tokenFrozen;    // per-user frozen token
    mapping(uint256 => uint256) public totalSupply;                     // tokenId => total minted

    string private _baseURI;

    // Events
    event CreditRegistered(uint256 indexed tokenId, CreditType creditType, string projectTitle, string certificateHash);
    event MintApprovalGranted(address indexed user, uint256 indexed tokenId, uint256 amount, uint256 expiry);
    event MintApprovalRevoked(address indexed user, uint256 indexed tokenId);
    event TokenMinted(address indexed user, uint256 indexed tokenId, uint256 amount);
    event CreditRevoked(uint256 indexed tokenId);
    event TokensFrozen(address indexed user, uint256 indexed tokenId);
    event TokensUnfrozen(address indexed user, uint256 indexed tokenId);
    event BaseURIUpdated(string oldURI, string newURI);

    // Constructor
    constructor(string memory baseURI_) ERC1155(baseURI_) {
        _baseURI = baseURI_;
    }

    // -------------------------
    // Validation Helpers
    // -------------------------
    function _isValidProjectTitle(string memory title) internal pure returns (bool) {
        uint256 len = bytes(title).length;
        return len > 0 && len <= 30;
    }

    function _isValidCertificateHash(string memory hash) internal pure returns (bool) {
        uint256 len = bytes(hash).length;
        return len >= 46 && len <= 128;
    }

    // -------------------------
    // Credit Registration
    // -------------------------
    /// @notice Registers a new credit token
    /// @param tokenId Unique ID for the token
    /// @param creditType Credit category
    /// @param projectTitle Short project title (max 30 chars)
    /// @param location Optional location string
    /// @param certificateHash IPFS CID or other proof hash (46-128 chars)
    function registerCredit(
        uint256 tokenId,
        CreditType creditType,
        string calldata projectTitle,
        string calldata location,
        string calldata certificateHash
    ) external onlyOwner {
        require(!creditData[tokenId].exists, "Credit ID already exists");
        require(_isValidProjectTitle(projectTitle), "Project title too long or empty");
        require(_isValidCertificateHash(certificateHash), "Certificate hash invalid");

        creditData[tokenId] = CreditInfo({
            creditType: creditType,
            projectTitle: projectTitle,
            location: location,
            certificateHash: certificateHash,
            exists: true,
            revoked: false
        });

        emit CreditRegistered(tokenId, creditType, projectTitle, certificateHash);
    }

    // -------------------------
    // Mint Approval
    // -------------------------
    /// @notice Approve a user to mint a specific token
    function approveMint(address user, uint256 tokenId, uint256 amount, uint256 expiryTimestamp) external onlyOwner {
        require(user != address(0), "Invalid user address");
        require(creditData[tokenId].exists, "Token ID does not exist");
        require(!creditData[tokenId].revoked, "Credit is revoked");
        require(amount > 0, "Amount must be > 0");
        require(expiryTimestamp > block.timestamp, "Expiry must be future");

        approvedMints[user][tokenId] = MintApproval({
            amount: amount,
            expiry: expiryTimestamp
        });

        emit MintApprovalGranted(user, tokenId, amount, expiryTimestamp);
    }

    /// @notice Revoke an existing mint approval
    function revokeMintApproval(address user, uint256 tokenId) external onlyOwner {
        require(approvedMints[user][tokenId].amount > 0, "No approval exists");
        approvedMints[user][tokenId].amount = 0;
        approvedMints[user][tokenId].expiry = 0;
        emit MintApprovalRevoked(user, tokenId);
    }

    // -------------------------
    // Minting
    // -------------------------
    /// @notice Mint tokens using owner approval
    function mintApprovedToken(uint256 tokenId, uint256 amount) external {
        CreditInfo storage credit = creditData[tokenId];
        require(credit.exists, "Credit does not exist");
        require(!credit.revoked, "Credit is revoked");
        require(!tokenFrozen[msg.sender][tokenId], "Token frozen for user");

        MintApproval storage approval = approvedMints[msg.sender][tokenId];
        require(approval.amount > 0, "No mint approval");
        require(block.timestamp <= approval.expiry, "Approval expired");
        require(amount > 0 && amount <= approval.amount, "Amount exceeds approved");

        _mint(msg.sender, tokenId, amount, "");
        totalSupply[tokenId] += amount;

        // Clear approval safely
        approval.amount = 0;
        approval.expiry = 0;

        emit TokenMinted(msg.sender, tokenId, amount);
    }

    // -------------------------
    // Revocation and Freezing
    // -------------------------
    /// @notice Revoke a credit token entirely
    function revokeCredit(uint256 tokenId) external onlyOwner {
        require(creditData[tokenId].exists, "Credit does not exist");
        creditData[tokenId].revoked = true;
        emit CreditRevoked(tokenId);
    }

    /// @notice Freeze a user's specific token
    function freezeUserToken(address user, uint256 tokenId) external onlyOwner {
        tokenFrozen[user][tokenId] = true;
        emit TokensFrozen(user, tokenId);
    }

    /// @notice Unfreeze a user's specific token
    function unfreezeUserToken(address user, uint256 tokenId) external onlyOwner {
        tokenFrozen[user][tokenId] = false;
        emit TokensUnfrozen(user, tokenId);
    }

    // -------------------------
    // Base URI Management
    // -------------------------
    function setBaseURI(string memory newURI) external onlyOwner {
        emit BaseURIUpdated(_baseURI, newURI);
        _baseURI = newURI;
    }

    function uri(uint256 tokenId) public view override returns (string memory) {
        require(creditData[tokenId].exists, "Token does not exist");
        return string(abi.encodePacked(_baseURI, tokenId.toString(), ".json"));
    }

    // -------------------------
    // Read helpers
    // -------------------------
    function getCreditInfo(uint256 tokenId) external view returns (CreditInfo memory) {
        require(creditData[tokenId].exists, "Credit does not exist");
        return creditData[tokenId];
    }

    function isUserTokenFrozen(address user, uint256 tokenId) external view returns (bool) {
        return tokenFrozen[user][tokenId];
    }

    // -------------------------
    // ERC1155 Overrides
    // -------------------------
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // -------------------------
    // Reject ETH
    // -------------------------
    receive() external payable {
        revert("Contract does not accept ETH");
    }
}
