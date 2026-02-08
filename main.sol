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

