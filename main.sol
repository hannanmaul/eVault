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
