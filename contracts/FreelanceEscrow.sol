// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title FreelanceEscrow
 * @notice Escrow contract untuk platform freelance dengan pembayaran crypto
 * @dev Supports multiple tokens (USDT, USDC, dll) dengan milestone-based payments
 */
contract FreelanceEscrow is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ========== ENUMS ==========
    
    enum EscrowStatus {
        CREATED,      // Escrow dibuat, belum ada deposit
        FUNDED,       // Dana sudah masuk escrow
        IN_PROGRESS,  // Ada partial release (milestone)
        COMPLETED,    // Semua dana released
        REFUNDED,     // Dana dikembalikan ke depositor
        DISPUTED      // Ada dispute, butuh resolusi
    }

    enum DisputeOutcome {
        RELEASE_TO_FREELANCER,
        REFUND_TO_COMPANY,
        SPLIT_50_50
    }

    // ========== STRUCTS ==========
    
    struct EscrowContract {
        uint256 contractId;           // Unique ID (match backend DB)
        address depositor;            // Company wallet address
        address beneficiary;          // Freelancer wallet address
        address token;                // Token ERC20 address (USDT/USDC)
        uint256 totalAmount;          // Total escrow amount
        uint256 releasedAmount;       // Amount yang sudah di-release
        uint256 refundedAmount;       // Amount yang sudah di-refund
        EscrowStatus status;          // Current status
        uint256 createdAt;            // Block timestamp saat dibuat
        uint256 fundedAt;             // Block timestamp saat funded
        uint256 deadline;             // Project deadline (block number)
        bytes32 jobHash;              // IPFS hash job details (opsional)
        bool disputed;                // Flag dispute
        string disputeReason;         // Alasan dispute
    }

    struct Milestone {
        uint256 milestoneId;
        string description;
        uint256 amount;
        bool completed;               // Freelancer sudah submit
        bool paid;                    // Company sudah release payment
        uint256 completedAt;
        uint256 paidAt;
    }

    // ========== STATE VARIABLES ==========
    
    // Counter untuk generate unique escrow ID
    uint256 public escrowCounter;
    
    // Platform fee (dalam basis points: 250 = 2.5%)
    uint256 public platformFeeRate = 250; // 2.5%
    uint256 public constant FEE_DENOMINATOR = 10000;
    
    // Minimum escrow amount (dalam token base unit, contoh: 1 USDC = 1e6)
    uint256 public minEscrowAmount = 10 * 1e6; // 10 USDC minimum
    
    // Maximum deadline (dalam blocks, ~180 hari jika 12s per block)
    uint256 public constant MAX_DEADLINE = 1296000; // ~180 days
    
    // Grace period untuk dispute setelah deadline
    uint256 public constant DISPUTE_GRACE_PERIOD = 50400; // ~7 days
    
    // Mapping escrow ID => EscrowContract
    mapping(uint256 => EscrowContract) public escrows;
    
    // Mapping escrow ID => array of Milestones
    mapping(uint256 => Milestone[]) public escrowMilestones;
    
    // Mapping user address => array of escrow IDs (untuk tracking)
    mapping(address => uint256[]) public userEscrows;
    
    // Whitelist token yang diperbolehkan
    mapping(address => bool) public allowedTokens;
    
    // Platform fee yang terkumpul per token
    mapping(address => uint256) public collectedFees;

    // ========== EVENTS ==========
    
    event EscrowCreated(
        uint256 indexed escrowId,
        uint256 indexed contractId,
        address indexed depositor,
        address beneficiary,
        address token,
        uint256 totalAmount,
        uint256 deadline
    );
    
    event EscrowFunded(
        uint256 indexed escrowId,
        uint256 amount,
        uint256 timestamp
    );
    
    event MilestoneCreated(
        uint256 indexed escrowId,
        uint256 indexed milestoneId,
        string description,
        uint256 amount
    );
    
    event MilestoneCompleted(
        uint256 indexed escrowId,
        uint256 indexed milestoneId,
        uint256 timestamp
    );
    
    event FundsReleased(
        uint256 indexed escrowId,
        uint256 amount,
        address indexed beneficiary,
        uint256 platformFee,
        uint256 timestamp
    );
    
    event FundsRefunded(
        uint256 indexed escrowId,
        uint256 amount,
        address indexed depositor,
        uint256 timestamp
    );
    
    event DisputeRaised(
        uint256 indexed escrowId,
        address indexed initiator,
        string reason,
        uint256 timestamp
    );
    
    event DisputeResolved(
        uint256 indexed escrowId,
        DisputeOutcome outcome,
        uint256 timestamp
    );
    
    event TokenWhitelisted(address indexed token, bool status);
    
    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);
    
    event PlatformFeeWithdrawn(address indexed token, uint256 amount);

    // ========== MODIFIERS ==========
    
    modifier escrowExists(uint256 _escrowId) {
        require(_escrowId < escrowCounter, "Escrow does not exist");
        _;
    }
    
    modifier onlyDepositor(uint256 _escrowId) {
        require(
            escrows[_escrowId].depositor == msg.sender,
            "Only depositor can call"
        );
        _;
    }
    
    modifier onlyBeneficiary(uint256 _escrowId) {
        require(
            escrows[_escrowId].beneficiary == msg.sender,
            "Only beneficiary can call"
        );
        _;
    }
    
    modifier onlyParties(uint256 _escrowId) {
        require(
            escrows[_escrowId].depositor == msg.sender ||
            escrows[_escrowId].beneficiary == msg.sender,
            "Only escrow parties can call"
        );
        _;
    }
    
    modifier notDisputed(uint256 _escrowId) {
        require(!escrows[_escrowId].disputed, "Escrow is disputed");
        _;
    }

    // ========== CONSTRUCTOR ==========
    
    constructor() {
        // Escrow counter mulai dari 0
        escrowCounter = 0;
    }

    // ========== ADMIN FUNCTIONS ==========
    
    /**
     * @notice Whitelist token yang diperbolehkan untuk escrow
     * @param _token Address token ERC20
     * @param _status true = allow, false = disallow
     */
    function setTokenWhitelist(address _token, bool _status) external onlyOwner {
        require(_token != address(0), "Invalid token address");
        allowedTokens[_token] = _status;
        emit TokenWhitelisted(_token, _status);
    }
    
    /**
     * @notice Update platform fee rate
     * @param _newFeeRate Fee baru dalam basis points (250 = 2.5%)
     */
    function setPlatformFeeRate(uint256 _newFeeRate) external onlyOwner {
        require(_newFeeRate <= 1000, "Fee too high (max 10%)");
        uint256 oldFee = platformFeeRate;
        platformFeeRate = _newFeeRate;
        emit PlatformFeeUpdated(oldFee, _newFeeRate);
    }
    
    /**
     * @notice Update minimum escrow amount
     * @param _newMinAmount Minimum amount baru (dalam token base unit)
     */
    function setMinEscrowAmount(uint256 _newMinAmount) external onlyOwner {
        minEscrowAmount = _newMinAmount;
    }
    
    /**
     * @notice Withdraw platform fee yang terkumpul
     * @param _token Token address untuk withdraw
     */
    function withdrawPlatformFee(address _token) external onlyOwner nonReentrant {
        uint256 amount = collectedFees[_token];
        require(amount > 0, "No fees to withdraw");
        
        collectedFees[_token] = 0;
        IERC20(_token).safeTransfer(owner(), amount);
        
        emit PlatformFeeWithdrawn(_token, amount);
    }
    
    /**
     * @notice Pause contract (emergency stop)
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @notice Unpause contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ========== CORE ESCROW FUNCTIONS ==========
    
    /**
     * @notice Create escrow baru
     * @param _contractId ID dari backend database (untuk sync)
     * @param _beneficiary Freelancer wallet address
     * @param _token Token address (USDT/USDC)
     * @param _totalAmount Total amount escrow
     * @param _deadline Project deadline (block number)
     * @param _jobHash IPFS hash job details (opsional)
     * @return escrowId ID escrow yang dibuat
     */
    function createEscrow(
        uint256 _contractId,
        address _beneficiary,
        address _token,
        uint256 _totalAmount,
        uint256 _deadline,
        bytes32 _jobHash
    ) external whenNotPaused returns (uint256) {
        // Input validation
        require(_beneficiary != address(0), "Invalid beneficiary address");
        require(_beneficiary != msg.sender, "Beneficiary cannot be depositor");
        require(_token != address(0), "Invalid token address");
        require(allowedTokens[_token], "Token not whitelisted");
        require(_totalAmount >= minEscrowAmount, "Amount below minimum");
        require(
            _deadline > block.number && _deadline <= block.number + MAX_DEADLINE,
            "Invalid deadline"
        );
        
        // Create escrow struct
        uint256 escrowId = escrowCounter;
        escrows[escrowId] = EscrowContract({
            contractId: _contractId,
            depositor: msg.sender,
            beneficiary: _beneficiary,
            token: _token,
            totalAmount: _totalAmount,
            releasedAmount: 0,
            refundedAmount: 0,
            status: EscrowStatus.CREATED,
            createdAt: block.timestamp,
            fundedAt: 0,
            deadline: _deadline,
            jobHash: _jobHash,
            disputed: false,
            disputeReason: ""
        });
        
        // Track escrow untuk user
        userEscrows[msg.sender].push(escrowId);
        userEscrows[_beneficiary].push(escrowId);
        
        // Increment counter
        escrowCounter++;
        
        emit EscrowCreated(
            escrowId,
            _contractId,
            msg.sender,
            _beneficiary,
            _token,
            _totalAmount,
            _deadline
        );
        
        return escrowId;
    }
    
    /**
     * @notice Deposit funds ke escrow
     * @dev Depositor harus approve token dulu sebelum call fungsi ini
     * @param _escrowId ID escrow
     */
    function depositFunds(uint256 _escrowId)
        external
        escrowExists(_escrowId)
        onlyDepositor(_escrowId)
        whenNotPaused
        nonReentrant
    {
        EscrowContract storage escrow = escrows[_escrowId];
        
        // Validasi status
        require(escrow.status == EscrowStatus.CREATED, "Escrow already funded");
        require(block.number <= escrow.deadline, "Deadline passed");
        
        // Transfer token dari depositor ke contract
        IERC20(escrow.token).safeTransferFrom(
            msg.sender,
            address(this),
            escrow.totalAmount
        );
        
        // Update state
        escrow.status = EscrowStatus.FUNDED;
        escrow.fundedAt = block.timestamp;
        
        emit EscrowFunded(_escrowId, escrow.totalAmount, block.timestamp);
    }
    
    /**
     * @notice Release funds ke freelancer (full atau partial)
     * @param _escrowId ID escrow
     * @param _amount Amount yang mau di-release
     */
    function releaseFunds(uint256 _escrowId, uint256 _amount)
        external
        escrowExists(_escrowId)
        onlyDepositor(_escrowId)
        notDisputed(_escrowId)
        whenNotPaused
        nonReentrant
    {
        _releaseInternal(_escrowId, _amount);
    }
    
    /**
     * @notice Internal function untuk release funds (untuk reusability)
     * @param _escrowId ID escrow
     * @param _amount Amount yang mau di-release
     */
    function _releaseInternal(uint256 _escrowId, uint256 _amount) internal {
        EscrowContract storage escrow = escrows[_escrowId];
        
        // Validasi status
        require(
            escrow.status == EscrowStatus.FUNDED ||
            escrow.status == EscrowStatus.IN_PROGRESS,
            "Invalid escrow status"
        );
        
        // Validasi amount
        require(_amount > 0, "Amount must be greater than 0");
        uint256 remainingAmount = escrow.totalAmount - escrow.releasedAmount;
        require(_amount <= remainingAmount, "Amount exceeds remaining balance");
        
        // Calculate platform fee
        uint256 platformFee = (_amount * platformFeeRate) / FEE_DENOMINATOR;
        uint256 amountToFreelancer = _amount - platformFee;
        
        // Update state BEFORE transfer (CEI pattern)
        escrow.releasedAmount += _amount;
        collectedFees[escrow.token] += platformFee;
        
        // Update status
        if (escrow.releasedAmount == escrow.totalAmount) {
            escrow.status = EscrowStatus.COMPLETED;
        } else {
            escrow.status = EscrowStatus.IN_PROGRESS;
        }
        
        // Transfer token ke freelancer
        IERC20(escrow.token).safeTransfer(escrow.beneficiary, amountToFreelancer);
        
        emit FundsReleased(
            _escrowId,
            amountToFreelancer,
            escrow.beneficiary,
            platformFee,
            block.timestamp
        );
    }
    
    /**
     * @notice Refund dana ke depositor (jika deadline lewat atau dispute resolved)
     * @param _escrowId ID escrow
     */
    function refundDepositor(uint256 _escrowId)
        external
        escrowExists(_escrowId)
        whenNotPaused
        nonReentrant
    {
        EscrowContract storage escrow = escrows[_escrowId];
        
        // Hanya depositor atau owner yang bisa refund
        require(
            msg.sender == escrow.depositor || msg.sender == owner(),
            "Not authorized"
        );
        
        // Validasi status
        require(
            escrow.status == EscrowStatus.FUNDED ||
            escrow.status == EscrowStatus.IN_PROGRESS,
            "Cannot refund from this status"
        );
        
        // Validasi deadline (harus lewat + grace period)
        require(
            block.number > escrow.deadline + DISPUTE_GRACE_PERIOD,
            "Deadline not passed yet"
        );
        
        // Calculate refund amount
        uint256 refundAmount = escrow.totalAmount - escrow.releasedAmount;
        require(refundAmount > 0, "No funds to refund");
        
        // Update state BEFORE transfer
        escrow.refundedAmount = refundAmount;
        escrow.status = EscrowStatus.REFUNDED;
        
        // Transfer token back to depositor
        IERC20(escrow.token).safeTransfer(escrow.depositor, refundAmount);
        
        emit FundsRefunded(_escrowId, refundAmount, escrow.depositor, block.timestamp);
    }

    // ========== MILESTONE FUNCTIONS ==========
    
    /**
     * @notice Create milestone untuk escrow
     * @param _escrowId ID escrow
     * @param _description Deskripsi milestone
     * @param _amount Amount milestone
     */
    function createMilestone(
        uint256 _escrowId,
        string calldata _description,
        uint256 _amount
    ) external escrowExists(_escrowId) onlyDepositor(_escrowId) {
        EscrowContract storage escrow = escrows[_escrowId];
        
        require(
            escrow.status == EscrowStatus.CREATED ||
            escrow.status == EscrowStatus.FUNDED,
            "Cannot create milestone in this status"
        );
        
        require(_amount > 0, "Milestone amount must be greater than 0");
        require(bytes(_description).length > 0, "Description cannot be empty");
        
        // Get current milestones
        Milestone[] storage milestones = escrowMilestones[_escrowId];
        
        // Calculate total milestone amount
        uint256 totalMilestoneAmount = _amount;
        for (uint256 i = 0; i < milestones.length; i++) {
            totalMilestoneAmount += milestones[i].amount;
        }
        
        require(
            totalMilestoneAmount <= escrow.totalAmount,
            "Total milestone exceeds escrow amount"
        );
        
        // Create milestone
        uint256 milestoneId = milestones.length;
        milestones.push(Milestone({
            milestoneId: milestoneId,
            description: _description,
            amount: _amount,
            completed: false,
            paid: false,
            completedAt: 0,
            paidAt: 0
        }));
        
        emit MilestoneCreated(_escrowId, milestoneId, _description, _amount);
    }
    
    /**
     * @notice Mark milestone sebagai completed (dipanggil freelancer)
     * @param _escrowId ID escrow
     * @param _milestoneId ID milestone
     */
    function completeMilestone(uint256 _escrowId, uint256 _milestoneId)
        external
        escrowExists(_escrowId)
        onlyBeneficiary(_escrowId)
    {
        Milestone[] storage milestones = escrowMilestones[_escrowId];
        require(_milestoneId < milestones.length, "Milestone does not exist");
        
        Milestone storage milestone = milestones[_milestoneId];
        require(!milestone.completed, "Milestone already completed");
        require(!milestone.paid, "Milestone already paid");
        
        milestone.completed = true;
        milestone.completedAt = block.timestamp;
        
        emit MilestoneCompleted(_escrowId, _milestoneId, block.timestamp);
    }
    
    /**
     * @notice Release payment untuk milestone yang completed
     * @param _escrowId ID escrow
     * @param _milestoneId ID milestone
     */
    function releaseMilestonePayment(uint256 _escrowId, uint256 _milestoneId)
        external
        escrowExists(_escrowId)
        onlyDepositor(_escrowId)
        notDisputed(_escrowId)
        whenNotPaused
        nonReentrant
    {
        Milestone[] storage milestones = escrowMilestones[_escrowId];
        require(_milestoneId < milestones.length, "Milestone does not exist");
        
        Milestone storage milestone = milestones[_milestoneId];
        require(milestone.completed, "Milestone not completed yet");
        require(!milestone.paid, "Milestone already paid");
        
        // Mark as paid
        milestone.paid = true;
        milestone.paidAt = block.timestamp;
        
        // Release funds using internal function
        _releaseInternal(_escrowId, milestone.amount);
    }

    // ========== DISPUTE FUNCTIONS ==========
    
    /**
     * @notice Raise dispute untuk escrow
     * @param _escrowId ID escrow
     * @param _reason Alasan dispute
     */
    function raiseDispute(uint256 _escrowId, string calldata _reason)
        external
        escrowExists(_escrowId)
        onlyParties(_escrowId)
    {
        EscrowContract storage escrow = escrows[_escrowId];
        
        require(!escrow.disputed, "Dispute already raised");
        require(
            escrow.status == EscrowStatus.FUNDED ||
            escrow.status == EscrowStatus.IN_PROGRESS,
            "Cannot dispute in this status"
        );
        require(bytes(_reason).length > 0, "Reason cannot be empty");
        
        escrow.disputed = true;
        escrow.disputeReason = _reason;
        
        emit DisputeRaised(_escrowId, msg.sender, _reason, block.timestamp);
    }
    
    /**
     * @notice Resolve dispute (hanya owner/platform)
     * @param _escrowId ID escrow
     * @param _outcome Outcome dispute
     */
    function resolveDispute(uint256 _escrowId, DisputeOutcome _outcome)
        external
        escrowExists(_escrowId)
        onlyOwner
        nonReentrant
    {
        EscrowContract storage escrow = escrows[_escrowId];
        
        require(escrow.disputed, "No dispute to resolve");
        require(
            escrow.status == EscrowStatus.FUNDED ||
            escrow.status == EscrowStatus.IN_PROGRESS,
            "Cannot resolve in this status"
        );
        
        uint256 remainingAmount = escrow.totalAmount - escrow.releasedAmount;
        require(remainingAmount > 0, "No funds to distribute");
        
        // Clear dispute flag
        escrow.disputed = false;
        escrow.disputeReason = ""; // Clear dispute reason
        if (_outcome == DisputeOutcome.RELEASE_TO_FREELANCER) {
            // Release semua remaining funds ke freelancer
            escrow.releasedAmount = escrow.totalAmount;
            escrow.status = EscrowStatus.COMPLETED;
            
            uint256 platformFee = (remainingAmount * platformFeeRate) / FEE_DENOMINATOR;
            uint256 amountToFreelancer = remainingAmount - platformFee;
            
            collectedFees[escrow.token] += platformFee;
            IERC20(escrow.token).safeTransfer(escrow.beneficiary, amountToFreelancer);
            
        } else if (_outcome == DisputeOutcome.REFUND_TO_COMPANY) {
            // Refund semua remaining funds ke depositor
            escrow.refundedAmount = remainingAmount;
            escrow.status = EscrowStatus.REFUNDED;
            
            IERC20(escrow.token).safeTransfer(escrow.depositor, remainingAmount);
            
        } else if (_outcome == DisputeOutcome.SPLIT_50_50) {
            // Split 50-50 antara depositor dan beneficiary
            uint256 halfAmount = remainingAmount / 2;
            uint256 platformFee = (halfAmount * platformFeeRate) / FEE_DENOMINATOR;
            uint256 amountToFreelancer = halfAmount - platformFee;
            
            escrow.releasedAmount += halfAmount;
            escrow.refundedAmount = remainingAmount - halfAmount;
            escrow.status = EscrowStatus.COMPLETED;
            
            collectedFees[escrow.token] += platformFee;
            IERC20(escrow.token).safeTransfer(escrow.beneficiary, amountToFreelancer);
            IERC20(escrow.token).safeTransfer(escrow.depositor, escrow.refundedAmount);
        }
        
        emit DisputeResolved(_escrowId, _outcome, block.timestamp);
    }

    // ========== VIEW FUNCTIONS ==========
    
    /**
     * @notice Get escrow details
     * @param _escrowId ID escrow
     */
    function getEscrow(uint256 _escrowId)
        external
        view
        escrowExists(_escrowId)
        returns (EscrowContract memory)
    {
        return escrows[_escrowId];
    }
    
    /**
     * @notice Get all milestones untuk escrow
     * @param _escrowId ID escrow
     */
    function getMilestones(uint256 _escrowId)
        external
        view
        escrowExists(_escrowId)
        returns (Milestone[] memory)
    {
        return escrowMilestones[_escrowId];
    }
    
    /**
     * @notice Get user escrows (dengan pagination)
     * @param _user User address
     * @param _offset Offset untuk pagination
     * @param _limit Limit jumlah results
     */
    function getUserEscrows(address _user, uint256 _offset, uint256 _limit)
        external
        view
        returns (uint256[] memory)
    {
        uint256[] memory allEscrows = userEscrows[_user];
        
        if (_offset >= allEscrows.length) {
            return new uint256[](0);
        }
        
        uint256 end = _offset + _limit;
        if (end > allEscrows.length) {
            end = allEscrows.length;
        }
        
        uint256[] memory result = new uint256[](end - _offset);
        for (uint256 i = _offset; i < end; i++) {
            result[i - _offset] = allEscrows[i];
        }
        
        return result;
    }
    
    /**
     * @notice Get remaining balance dalam escrow
     * @param _escrowId ID escrow
     */
    function getRemainingBalance(uint256 _escrowId)
        external
        view
        escrowExists(_escrowId)
        returns (uint256)
    {
        EscrowContract storage escrow = escrows[_escrowId];
        return escrow.totalAmount - escrow.releasedAmount - escrow.refundedAmount;
    }
    
    /**
     * @notice Check apakah escrow dapat di-refund
     * @param _escrowId ID escrow
     */
    function canRefund(uint256 _escrowId)
        external
        view
        escrowExists(_escrowId)
        returns (bool)
    {
        EscrowContract storage escrow = escrows[_escrowId];
        
        return (
            (escrow.status == EscrowStatus.FUNDED || escrow.status == EscrowStatus.IN_PROGRESS) &&
            block.number > escrow.deadline + DISPUTE_GRACE_PERIOD &&
            escrow.totalAmount > escrow.releasedAmount
            
        );
    }
}