// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// =============================================================================
// Components — canonical namespace of SSTORE2 component IDs used by Royco
// market deployment templates.
//
// Component IDs are `bytes32` hashes derived via `keccak256(bytes("ROYCO_COMPONENT_*"))`.
// Using hashes (instead of small integers) prevents accidental collisions when
// templates evolve independently and lets new templates introduce new components
// without coordinating an ID-space allocation with this file's authors.
// =============================================================================

// ─── Standardized (shared by every template) ────────────────────────────────

bytes32 constant COMPONENT_ID_SENIOR_TRANCHE_IMPL = keccak256("ROYCO_COMPONENT_SENIOR_TRANCHE_IMPL");
bytes32 constant COMPONENT_ID_JUNIOR_TRANCHE_IMPL = keccak256("ROYCO_COMPONENT_JUNIOR_TRANCHE_IMPL");
bytes32 constant COMPONENT_ID_LIQUIDITY_TRANCHE_IMPL = keccak256("ROYCO_COMPONENT_LIQUIDITY_TRANCHE_IMPL");
bytes32 constant COMPONENT_ID_ACCOUNTANT_IMPL = keccak256("ROYCO_COMPONENT_ACCOUNTANT_IMPL");
bytes32 constant COMPONENT_ID_YDM_ADAPTIVE_CURVE_V2 = keccak256("ROYCO_COMPONENT_YDM_ADAPTIVE_CURVE_V2");

// ─── Day-Balancer ────────────────────────────────────────────────────────────

/// @dev The real kernel-bound Balancer V3 pool hook (`RoycoDayBalancerV3Hooks`).
bytes32 constant COMPONENT_ID_DAY_BALANCER_HOOKS = keccak256("ROYCO_COMPONENT_DAY_BALANCER_HOOKS");

// ─── Day kernels ─────────────────────────────────────────────────────────────

/// @dev Creation-code id for `Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel`.
bytes32 constant COMPONENT_ID_DAY_KERNEL_IDENTICAL_ERC4626_CHAINLINK = keccak256("ROYCO_COMPONENT_DAY_KERNEL_IDENTICAL_ERC4626_CHAINLINK");
