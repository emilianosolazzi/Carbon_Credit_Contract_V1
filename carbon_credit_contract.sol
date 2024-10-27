// SPDX-License-Identifier: MIT
pragma solidity  0.8.26;
// Coded by Emiliano Solazzi, 2024
// Unauthorized use or reproduction of this content is strictly prohibited. All rights reserved to Emiliano Solazzi. Violators may be subject to legal action.

import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@prb/math/contracts/PRBMathUD60x18.sol";

/**
 * @title CarbonCreditTokenomicsContract
 * @dev Enhanced carbon credit trading system with staking, slashing, batch operations, cross-chain functionality, and governance features.
 */
contract CarbonCreditTokenomicsContract is 
    Initializable, 
    ERC1155Upgradeable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable, 
    PausableUpgradeable, 
    UUPSUpgradeable,
    ERC165 
{
    using CountersUpgradeable for CountersUpgradeable.Counter;
    using PRBMathUD60x18 for uint256;
    using SafeERC20 for IERC20;

    // Constants - packed for gas optimization
    uint96 public constant BASIS_POINTS = 10000;
    uint96 public constant MAX_FEE_PERCENT = 1000; // 10%
    uint96 public constant MAX_REWARD_PERCENT = 1500; // 15%
    uint128 public constant MAX_STAKE_AMOUNT = 1000000 * 1e18;
    uint128 public constant MAX_STAKE_DURATION = 365 days;
    uint128 public constant MINIMUM_STAKE_DURATION = 1 days;
    uint256 public constant MAX_BULK_ROLE_ASSIGNMENTS = 50;
    uint256 public slashApprovalThreshold;

    // Roles
    bytes32 public constant ROLE_ADMIN = DEFAULT_ADMIN_ROLE;
    bytes32 public constant ROLE_VALIDATOR = keccak256("ROLE_VALIDATOR");
    bytes32 public constant ROLE_MINTER = keccak256("ROLE_MINTER");
    bytes32 public constant ROLE_FRACTIONALIZER = keccak256("ROLE_FRACTIONALIZER");
    bytes32 public constant ROLE_BURNER = keccak256("ROLE_BURNER");
    bytes32 public constant ROLE_PAUSER = keccak256("ROLE_PAUSER");

    // State variables
    address public treasury; // mutable variable
    uint256 public transferFeePercent;
    uint256 public stakingRewardPercent;
    uint256 public totalSupply;
    CountersUpgradeable.Counter private _proposalCounter;
    mapping(bytes32 => uint256) public timeLocks; // Timelock mechanism

    // Structs
    struct Stake {
        uint128 amount;
        uint64 startTime;
        bool isActive;
    }

    struct CarbonCreditData {
        uint128 totalAmount;
        uint128 fractionalizedAmount;
        uint64 issuanceDate;
        bool isValidated;
        string projectName;
        string projectCountry;
    }

    struct SlashProposal {
        address staker;
        uint256 tokenId;
        uint256 slashAmount;
        uint256 proposedAt;
        uint256 validatorApprovals;
        mapping(address => bool) hasApproved;
        bool isExecuted;
    }

    // Mappings
    mapping(address => mapping(uint256 => Stake)) public stakes;
    mapping(uint256 => CarbonCreditData) public carbonCreditData;
    mapping(uint256 => SlashProposal) public slashProposals;

    // Events
    event SlashProposed(
        uint256 indexed proposalId, 
        address indexed staker, 
        uint256 indexed tokenId, 
        uint256 amount, 
        address proposer
    );
    event SlashApproved(
        uint256 indexed proposalId, 
        address indexed validator
    );
    event SlashExecuted(
        uint256 indexed proposalId, 
        address indexed staker, 
        uint256 indexed tokenId, 
        uint256 slashAmount
    );
    event TreasuryUpdated(
        address indexed oldTreasury, 
        address indexed newTreasury
    );
    event ActionPaused(
        bytes32 indexed actionType
    );
    event TokenRecovered(
        address indexed token, 
        address indexed to, 
        uint256 amount
    );
    event TransferFeeUpdated(
        uint256 newFeePercent
    );
    event StakingRewardUpdated(
        uint256 newRewardPercent
    );
    event MetadataUpdated(
        uint256 indexed tokenId, 
        string newURI
    );
    event ValidationStatusChanged(
        uint256 indexed tokenId, 
        bool status
    );
    event StakeSlashed(
        address indexed staker, 
        uint256 indexed tokenId, 
        uint256 slashAmount
    );
    event CarbonCreditMinted(
        uint256 indexed tokenId, 
        address indexed recipient, 
        uint256 amount, 
        string metadataURI
    );
    event CarbonCreditStaked(
        address indexed staker, 
        uint256 indexed tokenId, 
        uint256 amount
    );
    event CarbonCreditUnstaked(
        address indexed staker, 
        uint256 indexed tokenId, 
        uint256 amount, 
        uint256 reward
    );

    // Errors
    error InvalidAmount();
    error TokenNotExists();
    error StakeNotFound();
    error DurationTooShort();
    error DurationTooLong();
    error AmountTooLarge();
    error InvalidAddress();
    error URITooLong();
    error ProposalExpired();
    error InsufficientApprovals();
    error Unauthorized();
    error AlreadyApproved();

    modifier withTimelock(bytes32 operation) {
        require(timeLocks[operation] < block.timestamp, "Time locked");
        _;
    }

    /**
     * @dev Initializes the contract with required parameters and initial role assignments.
     */
    function initialize(
        string memory baseURI, 
        address _treasury,
        address[] memory validators,
        address[] memory minters,
        uint256 _slashApprovalThreshold
    ) public initializer {
        require(_treasury != address(0), "Invalid treasury address");
        require(_slashApprovalThreshold > 0, "Invalid threshold");

        __ERC1155_init(baseURI);
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(ROLE_ADMIN, _msgSender());
        _grantRole(ROLE_FRACTIONALIZER, _msgSender());
        _grantRole(ROLE_BURNER, _msgSender());
        _grantRole(ROLE_PAUSER, _msgSender());

        // Assign roles with address validation
        for (uint i = 0; i < validators.length && i < MAX_BULK_ROLE_ASSIGNMENTS; i++) {
            require(validators[i] != address(0), "Validator address invalid");
            _grantRole(ROLE_VALIDATOR, validators[i]);
        }
        for (uint i = 0; i < minters.length && i < MAX_BULK_ROLE_ASSIGNMENTS; i++) {
            require(minters[i] != address(0), "Minter address invalid");
            _grantRole(ROLE_MINTER, minters[i]);
        }

        treasury = _treasury;
        transferFeePercent = 500; // 5%
        stakingRewardPercent = 1000; // 10%
        slashApprovalThreshold = _slashApprovalThreshold;
    }

    /**
     * @dev Override supportsInterface to handle multiple inheritance.
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC1155Upgradeable, AccessControlUpgradeable, ERC165)
        returns (bool)
    {
        return super.supportsInterface(interfaceId) || interfaceId == type(IERC165).interfaceId;
    }

    /**
     * @dev Authorize contract upgrades for UUPS proxy pattern.
     */
    function _authorizeUpgrade(address newImplementation) 
        internal 
        override 
        onlyRole(ROLE_ADMIN) 
    {}

    /**
     * @dev Stake carbon credits to earn rewards, with balance check.
     */
    function stake(uint256 tokenId, uint128 amount, uint64 duration) external whenNotPaused nonReentrant {
        require(balanceOf(_msgSender(), tokenId) >= amount, "Insufficient balance");
        require(duration >= MINIMUM_STAKE_DURATION && duration <= MAX_STAKE_DURATION, "Invalid stake duration");
        require(amount > 0 && amount <= MAX_STAKE_AMOUNT, "Invalid stake amount");

        stakes[_msgSender()][tokenId] = Stake({
            amount: amount,
            startTime: uint64(block.timestamp),
            isActive: true
        });

        emit CarbonCreditStaked(_msgSender(), tokenId, amount);
    }

    /**
     * @dev Slash staked credits by validator proposal and approval.
     */
    function proposeSlash(uint256 tokenId, address staker, uint256 amount) external onlyRole(ROLE_VALIDATOR) whenNotPaused nonReentrant {
        SlashProposal storage proposal = slashProposals[tokenId];
        proposal.staker = staker;
        proposal.tokenId = tokenId;
        proposal.slashAmount = amount;
        proposal.proposedAt = block.timestamp;
        proposal.isExecuted = false;

        emit SlashProposed(_proposalCounter.current(), staker, tokenId, amount, _msgSender());
        _proposalCounter.increment();
    }

    /**
     * @dev Approve a slash proposal.
     */
    function approveSlash(uint256 tokenId) external onlyRole(ROLE_VALIDATOR) nonReentrant {
        SlashProposal storage proposal = slashProposals[tokenId];
        require(!proposal.hasApproved[_msgSender()], "Already approved");
        proposal.validatorApprovals += 1;
        proposal.hasApproved[_msgSender()] = true;

        emit SlashApproved(_proposalCounter.current() - 1, _msgSender());

        if (proposal.validatorApprovals >= slashApprovalThreshold) {
            executeSlash(tokenId);
        }
    }

    /**
     * @dev Execute a slash proposal after threshold approvals following CEI pattern.
     */
    function executeSlash(uint256 tokenId) internal nonReentrant {
        SlashProposal storage proposal = slashProposals[tokenId];
        require(proposal.validatorApprovals >= slashApprovalThreshold, "Insufficient approvals");
        require(!proposal.isExecuted, "Already executed");

        Stake storage stakeInfo = stakes[proposal.staker][tokenId];
        require(stakeInfo.amount >= proposal.slashAmount, "Insufficient staked amount");

        // Update state first (CEI pattern)
        stakeInfo.amount -= uint128(proposal.slashAmount);
        proposal.isExecuted = true;

        emit SlashExecuted(_proposalCounter.current() - 1, proposal.staker, tokenId, proposal.slashAmount);
    }

    /**
     * @dev Update treasury address with timelock.
     */
    function updateTreasury(address newTreasury) external onlyRole(ROLE_ADMIN) withTimelock(keccak256("UPDATE_TREASURY")) {
        require(newTreasury != address(0), "Invalid treasury address");
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    /**
     * @dev Batch stake operation for scalability (Placeholder).
     */
    function batchStake(uint256[] calldata tokenIds, uint128[] calldata amounts, uint64[] calldata durations) external whenNotPaused nonReentrant {
        require(tokenIds.length == amounts.length && amounts.length == durations.length, "Array length mismatch");
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(balanceOf(_msgSender(), tokenIds[i]) >= amounts[i], "Insufficient balance for batch stake");
            stakes[_msgSender()][tokenIds[i]] = Stake({
                amount: amounts[i],
                startTime: uint64(block.timestamp),
                isActive: true
            });
            emit CarbonCreditStaked(_msgSender(), tokenIds[i], amounts[i]);
        }
    }

    uint256[50] private __gap; // Increased for future upgrades
}
