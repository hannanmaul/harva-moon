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
        if (toTreasury > 0 && treasury != address(0)) {
            balanceOf[authority] -= toTreasury;
            balanceOf[treasury] += toTreasury;
            emit Transfer(authority, treasury, toTreasury);
        }
        currentPhase = LaunchPhase.FuelAllocated;
        emit TrajectoryCommitted(block.number, toReserve, toTreasury);
    }

    /// @notice Append a mission log entry (authority only). Tag can be keccak256 of a label.
    function logMission(uint256 value, bytes32 tag) external onlyAuthority {
        if (_missionLog.length >= MAX_MISSION_LOG_ENTRIES) revert Catalyst_MissionLogFull();
        _missionLog.push(MissionLogEntry({ blockNumber: block.number, value: value, tag: tag }));
        emit MissionLogged(_missionLog.length - 1, block.number, value, tag);
    }

    /// @notice Schedule vesting for a beneficiary from authority balance. Callable only before trajectory commit.
    ///         Tokens are escrowed in this contract until claimed.
    function scheduleVesting(address beneficiary, uint256 amount) external onlyAuthority {
        if (trajectoryCommitted) revert Catalyst_TrajectoryAlreadyCommitted();
        if (beneficiary == address(0)) revert Catalyst_InvalidRecipient();
        if (amount == 0) revert Catalyst_ZeroAmount();
        if (balanceOf[authority] < amount) revert Catalyst_InsufficientBalance();

        balanceOf[authority] -= amount;
        balanceOf[address(this)] += amount;
        vestedAmount[beneficiary] += amount;
        emit Transfer(authority, address(this), amount);
        emit VestingScheduled(beneficiary, amount);
    }

    /// @notice Claim vested tokens after cliff. Linear vest over 7776 blocks from vestingStartBlock + cliff.
    function claimVested() external {
        if (block.number < vestingStartBlock) revert Catalyst_VestingNotStarted();
        if (block.number < vestingStartBlock + VESTING_CLIFF_BLOCKS) revert Catalyst_CliffNotReached();

        uint256 total = vestedAmount[msg.sender];
        uint256 alreadyClaimed = claimedVested[msg.sender];
        if (total <= alreadyClaimed) revert Catalyst_NothingToClaim();

        uint256 elapsed = block.number - vestingStartBlock - VESTING_CLIFF_BLOCKS;
        uint256 vestDuration = 7776;
        uint256 claimable = total;
        if (elapsed < vestDuration) {
            claimable = (total * elapsed) / vestDuration;
        }
        claimable -= alreadyClaimed;
        if (claimable == 0) revert Catalyst_NothingToClaim();

        claimedVested[msg.sender] += claimable;
        balanceOf[address(this)] -= claimable;
        balanceOf[msg.sender] += claimable;
        emit Transfer(address(this), msg.sender, claimable);
        emit VestingClaimed(msg.sender, claimable);
    }

    /// @notice Execute ignition burn: authority may burn from own balance into burnVault (or dead address).
    function executeIgnitionBurn(uint256 amount) external onlyAuthority {
        if (amount == 0) revert Catalyst_ZeroAmount();
        if (balanceOf[authority] < amount) revert Catalyst_InsufficientBalance();

        address target = burnVault != address(0) ? burnVault : address(0x000000000000000000000000000000000000dEaD);
        balanceOf[authority] -= amount;
        balanceOf[target] += amount;
        ignitionBurnAmount += amount;
        emit Transfer(authority, target, amount);
        emit IgnitionBurnExecuted(authority, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 current = allowance[from][msg.sender];
        if (current != type(uint256).max) {
            if (current < amount) revert Catalyst_InsufficientAllowance();
            allowance[from][msg.sender] = current - amount;
        }
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert Catalyst_InvalidRecipient();
        if (from == address(0)) revert Catalyst_InvalidRecipient();
        if (balanceOf[from] < amount) revert Catalyst_InsufficientBalance();

        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        totalTransfers += 1;
        transferCountByAddress[from] += 1;
        transferCountByAddress[to] += 1;
        emit Transfer(from, to, amount);
    }

    function missionLogLength() external view returns (uint256) {
        return _missionLog.length;
    }

    function getMissionLogEntry(uint256 index) external view returns (uint256 blockNumber, uint256 value, bytes32 tag) {
        if (index >= _missionLog.length) revert Catalyst_IndexOutOfBounds();
        MissionLogEntry storage e = _missionLog[index];
        return (e.blockNumber, e.value, e.tag);
    }

    function getClaimableVested(address account) external view returns (uint256) {
        if (block.number < vestingStartBlock || block.number < vestingStartBlock + VESTING_CLIFF_BLOCKS) return 0;
        uint256 total = vestedAmount[account];
        uint256 alreadyClaimed = claimedVested[account];
        if (total <= alreadyClaimed) return 0;
        uint256 elapsed = block.number - vestingStartBlock - VESTING_CLIFF_BLOCKS;
        uint256 vestDuration = 7776;
        uint256 claimable = total;
        if (elapsed < vestDuration) claimable = (total * elapsed) / vestDuration;
        return claimable - alreadyClaimed;
    }

    function name() external pure returns (string memory) { return TOKEN_NAME; }
    function symbol() external pure returns (string memory) { return TOKEN_SYMBOL; }
    function decimals() external pure returns (uint8) { return TOKEN_DECIMALS; }

    /// @notice Block number at which launch phase unlocks.
    function getLaunchUnlockBlock() external view returns (uint256) {
        return launchUnlockBlock;
    }

    /// @notice Whether the launch window has been reached.
    function isLaunchUnlocked() external view returns (bool) {
        return block.number >= launchUnlockBlock;
    }

    /// @notice Total amount ever sent to burn via executeIgnitionBurn.
    function totalIgnitionBurned() external view returns (uint256) {
        return ignitionBurnAmount;
    }
}

