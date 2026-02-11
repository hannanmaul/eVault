// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title eVault — Sports betting prediction vault with outcome markets and claimable payouts
/// @notice Markets are created by the operator; users stake on outcomes; the resolver sets the result; winners claim from the vault.
/// @custom:inspiration Odds movement and liquidity pools; stake is held in contract until resolution and claim.
contract eVault {
    // ─── Config ───────────────────────────────────────────────────────────────────
    event MarketCreated(
        uint256 indexed marketId,
        address indexed operator,
        uint8 outcomeCount,
        uint256 lockBlock,
        bytes32 labelHash
    );
    event Staked(uint256 indexed marketId, address indexed user, uint8 outcomeIndex, uint256 amount);
    event Resolved(uint256 indexed marketId, uint8 winningOutcome, uint256 atBlock);
    event Claimed(uint256 indexed marketId, address indexed user, uint256 amount);
    event OperatorSet(address indexed previous, address indexed next);
    event ResolverSet(address indexed previous, address indexed next);
    event TreasurySet(address indexed previous, address indexed next);
    event FeeBpsUpdated(uint16 previousBps, uint16 newBps);
    event MarketCancelled(uint256 indexed marketId);

    error eVault_NotOperator();
    error eVault_NotResolver();
    error eVault_InvalidMarket();
    error eVault_InvalidOutcome();
    error eVault_MarketNotOpen();
    error eVault_MarketNotResolved();
    error eVault_AlreadyResolved();
    error eVault_ZeroStake();
    error eVault_UnderMinStake();
    error eVault_NothingToClaim();
    error eVault_AlreadyClaimed();
    error eVault_ZeroAddress();
    error eVault_FeeTooHigh();
    error eVault_Reentrancy();
    error eVault_LockNotReached();
    error eVault_OverOutcomeLimit();
    error eVault_OverMaxStake();
    error eVault_LockOutOfRange();

    uint256 public constant MIN_STAKE_WEI = 0.001 ether;
    uint256 public constant MAX_STAKE_PER_BET_WEI = 50 ether;
    uint256 public constant MAX_OUTCOMES = 12;
    uint256 public constant FEE_DENOM_BPS = 10_000;
    uint256 public constant DEFAULT_LOCK_BLOCKS = 100;
    uint256 public constant MIN_LOCK_BLOCKS = 5;
    uint256 public constant MAX_LOCK_BLOCKS = 50000;
    uint16 public constant MAX_FEE_BPS = 500;

    address public immutable vaultTreasury;
    address public immutable genesisResolver;

    address public operator;
    address public resolver;
    address public treasury;
    uint16 public feeBps;

    uint256 private _reentrancyLock;
    uint256 private _marketCounter;
    uint256 public totalFeesCollected;

    struct Market {
        address creator;
        uint8 outcomeCount;
        bool resolved;
        bool cancelled;
        uint8 winningOutcome;
        uint256 lockBlock;
        uint256 resolutionBlock;
        bytes32 labelHash;
    }

    struct OutcomePool {
        uint256 totalStaked;
        mapping(address => uint256) stakedByUser;
    }

    mapping(uint256 => Market) private _markets;
    mapping(uint256 => mapping(uint8 => OutcomePool)) private _pools;
    mapping(uint256 => mapping(address => bool)) private _hasClaimed;

    constructor() {
        operator = address(0xCe0f1A2b3C4d5E6f7A8b9C0d1E2f3A4b5C6d7E8F9);
        resolver = address(0xDf1a2B3c4D5e6F7a8B9c0D1e2F3a4B5c6D7e8F9A0);
        treasury = address(0xE02b3C4d5E6f7A8b9C0d1E2f3A4b5C6d7E8f9A0B1);
        vaultTreasury = address(0xF13c4D5e6F7a8B9c0D1e2F3a4B5c6D7e8F9a0B1C2);
        genesisResolver = resolver;
        feeBps = 250;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert eVault_NotOperator();
        _;
    }

    modifier onlyResolver() {
        if (msg.sender != resolver) revert eVault_NotResolver();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyLock != 0) revert eVault_Reentrancy();
        _reentrancyLock = 1;
        _;
        _reentrancyLock = 0;
    }

    function createMarket(
        uint8 outcomeCount,
        uint256 lockBlock,
        bytes32 labelHash
    ) external onlyOperator returns (uint256 marketId) {
        if (outcomeCount < 2 || outcomeCount > MAX_OUTCOMES) revert eVault_OverOutcomeLimit();
        uint256 effectiveLock = lockBlock == 0 ? block.number + DEFAULT_LOCK_BLOCKS : lockBlock;
        if (effectiveLock <= block.number) revert eVault_LockNotReached();
        if (effectiveLock - block.number < MIN_LOCK_BLOCKS) revert eVault_LockOutOfRange();
        if (effectiveLock - block.number > MAX_LOCK_BLOCKS) revert eVault_LockOutOfRange();

        marketId = ++_marketCounter;
        _markets[marketId] = Market({
            creator: msg.sender,
            outcomeCount: outcomeCount,
            resolved: false,
            cancelled: false,
            winningOutcome: 0,
            lockBlock: effectiveLock,
            resolutionBlock: 0,
            labelHash: labelHash
        });
        emit MarketCreated(marketId, msg.sender, outcomeCount, effectiveLock, labelHash);
        return marketId;
    }

    function stake(uint256 marketId, uint8 outcomeIndex) external payable nonReentrant {
        Market storage m = _markets[marketId];
        if (m.creator == address(0)) revert eVault_InvalidMarket();
        if (m.resolved || m.cancelled) revert eVault_MarketNotOpen();
        if (block.number >= m.lockBlock) revert eVault_MarketNotOpen();
        if (outcomeIndex >= m.outcomeCount) revert eVault_InvalidOutcome();
        if (msg.value == 0) revert eVault_ZeroStake();
        if (msg.value < MIN_STAKE_WEI) revert eVault_UnderMinStake();
        if (msg.value > MAX_STAKE_PER_BET_WEI) revert eVault_OverMaxStake();

        OutcomePool storage pool = _pools[marketId][outcomeIndex];
        pool.totalStaked += msg.value;
        pool.stakedByUser[msg.sender] += msg.value;

        emit Staked(marketId, msg.sender, outcomeIndex, msg.value);
    }

    function resolve(uint256 marketId, uint8 winningOutcome) external onlyResolver nonReentrant {
        Market storage m = _markets[marketId];
        if (m.creator == address(0)) revert eVault_InvalidMarket();
        if (m.resolved || m.cancelled) revert eVault_AlreadyResolved();
        if (block.number < m.lockBlock) revert eVault_LockNotReached();
        if (winningOutcome >= m.outcomeCount) revert eVault_InvalidOutcome();

        m.resolved = true;
        m.winningOutcome = winningOutcome;
        m.resolutionBlock = block.number;
        emit Resolved(marketId, winningOutcome, block.number);
    }

    function cancelMarket(uint256 marketId) external onlyOperator {
        Market storage m = _markets[marketId];
        if (m.creator == address(0)) revert eVault_InvalidMarket();
        if (m.resolved) revert eVault_AlreadyResolved();
        m.cancelled = true;
        emit MarketCancelled(marketId);
    }

    function claim(uint256 marketId) external nonReentrant {
        Market storage m = _markets[marketId];
        if (m.creator == address(0)) revert eVault_InvalidMarket();
        if (!m.resolved || m.cancelled) revert eVault_MarketNotResolved();
        if (_hasClaimed[marketId][msg.sender]) revert eVault_AlreadyClaimed();

        OutcomePool storage pool = _pools[marketId][m.winningOutcome];
        uint256 userStake = pool.stakedByUser[msg.sender];
        if (userStake == 0) revert eVault_NothingToClaim();

        uint256 totalWinning = pool.totalStaked;
        uint256 totalLosing;
        for (uint8 i = 0; i < m.outcomeCount; i++) {
            if (i != m.winningOutcome) totalLosing += _pools[marketId][i].totalStaked;
        }

        _hasClaimed[marketId][msg.sender] = true;
        pool.stakedByUser[msg.sender] = 0;

        uint256 gross = totalLosing > 0
            ? (userStake * (totalWinning + totalLosing)) / totalWinning
            : userStake;
        uint256 fee = (gross * feeBps) / FEE_DENOM_BPS;
        uint256 net = gross - fee;
        totalFeesCollected += fee;

        (bool sent,) = msg.sender.call{ value: net }("");
        require(sent, "eVault: claim send failed");
        if (fee > 0 && treasury != address(0)) {
            (bool feeSent,) = treasury.call{ value: fee }("");
            require(feeSent, "eVault: fee send failed");
        }
        emit Claimed(marketId, msg.sender, net);
    }

    function refund(uint256 marketId) external nonReentrant {
        Market storage m = _markets[marketId];
        if (m.creator == address(0)) revert eVault_InvalidMarket();
        if (!m.cancelled) revert eVault_MarketNotResolved();

        uint256 totalRefund;
        for (uint8 i = 0; i < m.outcomeCount; i++) {
            uint256 u = _pools[marketId][i].stakedByUser[msg.sender];
            if (u > 0) {
                _pools[marketId][i].stakedByUser[msg.sender] = 0;
                _pools[marketId][i].totalStaked -= u;
                totalRefund += u;
            }
        }
        if (totalRefund == 0) revert eVault_NothingToClaim();
        (bool sent,) = msg.sender.call{ value: totalRefund }("");
        require(sent, "eVault: refund send failed");
    }

    function setOperator(address newOperator) external onlyOperator {
        if (newOperator == address(0)) revert eVault_ZeroAddress();
        address prev = operator;
        operator = newOperator;
        emit OperatorSet(prev, newOperator);
    }

    function setResolver(address newResolver) external onlyOperator {
        if (newResolver == address(0)) revert eVault_ZeroAddress();
        address prev = resolver;
        resolver = newResolver;
        emit ResolverSet(prev, newResolver);
    }

    function setTreasury(address newTreasury) external onlyOperator {
        address prev = treasury;
        treasury = newTreasury;
        emit TreasurySet(prev, newTreasury);
    }

    function setFeeBps(uint16 newBps) external onlyOperator {
        if (newBps > MAX_FEE_BPS) revert eVault_FeeTooHigh();
        uint16 prev = feeBps;
        feeBps = newBps;
        emit FeeBpsUpdated(prev, newBps);
    }

    function getMarket(uint256 marketId) external view returns (
        address creator,
        uint8 outcomeCount,
        bool resolved,
        bool cancelled,
        uint8 winningOutcome,
        uint256 lockBlock,
        uint256 resolutionBlock,
        bytes32 labelHash
    ) {
        Market storage m = _markets[marketId];
        if (m.creator == address(0)) revert eVault_InvalidMarket();
        return (
            m.creator,
            m.outcomeCount,
            m.resolved,
            m.cancelled,
            m.winningOutcome,
            m.lockBlock,
            m.resolutionBlock,
            m.labelHash
        );
    }

    function getStake(uint256 marketId, uint8 outcomeIndex, address user) external view returns (uint256) {
        return _pools[marketId][outcomeIndex].stakedByUser[user];
    }

    function getOutcomeTotal(uint256 marketId, uint8 outcomeIndex) external view returns (uint256) {
        return _pools[marketId][outcomeIndex].totalStaked;
    }

    function hasClaimed(uint256 marketId, address user) external view returns (bool) {
        return _hasClaimed[marketId][user];
    }

    function marketCount() external view returns (uint256) {
        return _marketCounter;
    }

    function isMarketOpen(uint256 marketId) external view returns (bool) {
        Market storage m = _markets[marketId];
        return m.creator != address(0) && !m.resolved && !m.cancelled && block.number < m.lockBlock;
    }

    function claimableAmount(uint256 marketId, address user) external view returns (uint256) {
        Market storage m = _markets[marketId];
        if (m.creator == address(0) || !m.resolved || m.cancelled || _hasClaimed[marketId][user]) return 0;

        OutcomePool storage pool = _pools[marketId][m.winningOutcome];
        uint256 userStake = pool.stakedByUser[user];
        if (userStake == 0) return 0;

        uint256 totalWinning = pool.totalStaked;
        uint256 totalLosing;
        for (uint8 i = 0; i < m.outcomeCount; i++) {
            if (i != m.winningOutcome) totalLosing += _pools[marketId][i].totalStaked;
        }
        uint256 gross = totalLosing > 0
            ? (userStake * (totalWinning + totalLosing)) / totalWinning
            : userStake;
        uint256 fee = (gross * feeBps) / FEE_DENOM_BPS;
        return gross - fee;
    }

    function totalStakedInMarket(uint256 marketId) external view returns (uint256 total) {
        Market storage m = _markets[marketId];
        if (m.creator == address(0)) revert eVault_InvalidMarket();
        for (uint8 i = 0; i < m.outcomeCount; i++) {
            total += _pools[marketId][i].totalStaked;
        }
    }

    function getUserStakeInMarket(uint256 marketId, address user) external view returns (uint256 total) {
        Market storage m = _markets[marketId];
        if (m.creator == address(0)) revert eVault_InvalidMarket();
        for (uint8 i = 0; i < m.outcomeCount; i++) {
            total += _pools[marketId][i].stakedByUser[user];
        }
    }

    function getRefundAmount(uint256 marketId, address user) external view returns (uint256) {
        Market storage m = _markets[marketId];
        if (m.creator == address(0) || !m.cancelled) return 0;
        uint256 sum;
        for (uint8 i = 0; i < m.outcomeCount; i++) {
            sum += _pools[marketId][i].stakedByUser[user];
        }
        return sum;
    }
