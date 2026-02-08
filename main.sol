// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Lunar Harva Catalyst — Moonshot token launcher with trajectory lock and fuel allocation
/// @notice Fixed-supply ERC20 with launch phases, treasury allocation, and optional burn mechanics.
///         Deployed with preconfigured authority addresses; no post-deploy setup required.
/// @custom:inspiration Orbital mechanics and delta-v budgets; fuel allocation is irreversible once committed.
contract LunarHarvaCatalyst {
    // ─── Metadata (immutable) ─────────────────────────────────────────────────────
    string public constant TOKEN_NAME = "Harva Moon";
    string public constant TOKEN_SYMBOL = "HVMOON";
    uint8 public constant TOKEN_DECIMALS = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // ─── Authority (constructor-set, immutable) ───────────────────────────────────
    address public immutable authority;
    address public immutable treasury;
    address public immutable liquidityReserve;
    address public immutable burnVault;

    // ─── Launch configuration ───────────────────────────────────────────────────
    uint256 public immutable supplyCap;
    uint256 public immutable launchUnlockBlock;
    uint256 public constant TRAJECTORY_LOCK_BLOCKS = 412;
    uint256 public constant FUEL_ALLOCATION_BP = 892;   // basis points to liquidity reserve
    uint256 public constant TREASURY_BP = 108;
    uint256 private constant BP_DENOM = 10_000;

    bool public trajectoryCommitted;
    uint256 public ignitionBurnAmount;

    enum LaunchPhase { PreIgnition, TrajectoryLock, FuelAllocated, Live }
    LaunchPhase public currentPhase;

    struct MissionLogEntry {
        uint256 blockNumber;
        uint256 value;
        bytes32 tag;
    }
    MissionLogEntry[] private _missionLog;
    uint256 public constant MAX_MISSION_LOG_ENTRIES = 1992;

    mapping(address => uint256) public transferCountByAddress;
    uint256 public totalTransfers;

    uint256 public constant VESTING_CLIFF_BLOCKS = 720;
    uint256 public vestingStartBlock;
    mapping(address => uint256) public vestedAmount;
    mapping(address => uint256) public claimedVested;

    // ─── Custom errors (unique to this contract) ──────────────────────────────────
    error Catalyst_InvalidRecipient();
    error Catalyst_InsufficientBalance();
    error Catalyst_InsufficientAllowance();
    error Catalyst_ExceedsCap();
    error Catalyst_Unauthorized();
    error Catalyst_TrajectoryAlreadyCommitted();
    error Catalyst_LaunchWindowNotReached();
    error Catalyst_ZeroAmount();
    error Catalyst_InvalidAllocation();
    error Catalyst_MissionLogFull();
    error Catalyst_VestingNotStarted();
    error Catalyst_CliffNotReached();
    error Catalyst_NothingToClaim();
    error Catalyst_InvalidTag();
    error Catalyst_IndexOutOfBounds();

    // ─── Events (unique naming) ──────────────────────────────────────────────────
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event TrajectoryCommitted(uint256 atBlock, uint256 liquidityAllocation, uint256 treasuryAllocation);
    event IgnitionBurnExecuted(address indexed from, uint256 amount);
    event FuelAllocated(address indexed reserve, uint256 amount);
    event MissionLogged(uint256 indexed index, uint256 blockNumber, uint256 value, bytes32 tag);
    event VestingScheduled(address indexed beneficiary, uint256 amount);
    event VestingClaimed(address indexed beneficiary, uint256 amount);

    /// @dev Preconfigured deployment; all authority addresses and launch params set in constructor.
    ///      Supply cap: 888_888_888 * 10^18; launch unlocks after TRAJECTORY_LOCK_BLOCKS from deployment block.
    constructor() {
        authority    = address(0xa7F2E1c4B9d3e6f8A0b2C5D7e9F1a3B4c6D8e0F2);
        treasury     = address(0xB8c4D5e6F7a9b0C1d2E3f4A5b6C7d8E9f0A1b2C3);
        liquidityReserve = address(0xC9d5E6f7A8b0c1D2e3F4a5B6c7D8e9F0a1B2c3D4);
        burnVault    = address(0xD0e6F7a8B9c0d1E2f3A4b5C6d7E8f9A0b1C2d3E4);

        supplyCap = 888_888_888 * 1e18;
        launchUnlockBlock = block.number + TRAJECTORY_LOCK_BLOCKS;
        vestingStartBlock = block.number;

        currentPhase = LaunchPhase.PreIgnition;

        totalSupply = supplyCap;
        balanceOf[authority] = supplyCap;
        emit Transfer(address(0), authority, supplyCap);
    }

    modifier onlyAuthority() {
        if (msg.sender != authority) revert Catalyst_Unauthorized();
        _;
    }

    modifier afterLaunchUnlock() {
        if (block.number < launchUnlockBlock) revert Catalyst_LaunchWindowNotReached();
        _;
    }

    /// @notice Commit launch trajectory: allocate fuel to liquidity reserve and treasury from authority balance.
    function commitTrajectory() external onlyAuthority {
        if (trajectoryCommitted) revert Catalyst_TrajectoryAlreadyCommitted();

        uint256 allocatable = balanceOf[authority];
        if (allocatable == 0) revert Catalyst_ZeroAmount();

        uint256 toReserve = (allocatable * FUEL_ALLOCATION_BP) / BP_DENOM;
        uint256 toTreasury = (allocatable * TREASURY_BP) / BP_DENOM;
        if (toReserve + toTreasury > allocatable) revert Catalyst_InvalidAllocation();

        trajectoryCommitted = true;

        if (toReserve > 0 && liquidityReserve != address(0)) {
            balanceOf[authority] -= toReserve;
            balanceOf[liquidityReserve] += toReserve;
            emit Transfer(authority, liquidityReserve, toReserve);
            emit FuelAllocated(liquidityReserve, toReserve);
        }
