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
