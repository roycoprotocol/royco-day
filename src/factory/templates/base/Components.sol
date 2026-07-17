// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

// =============================================================================
// Components, canonical namespace of SSTORE2 component IDs used by Royco
// market deployment templates
//
// Component IDs are `bytes32` hashes derived via `keccak256(bytes("ROYCO_COMPONENT_*"))`
// Using hashes (instead of small integers) prevents accidental collisions when
// templates evolve independently and lets new templates introduce new components
// without coordinating an ID-space allocation with this file's authors
// =============================================================================

// ─── Standardized (shared by every template) ────────────────────────────────

bytes32 constant COMPONENT_ID_SENIOR_TRANCHE_IMPL = keccak256("ROYCO_COMPONENT_SENIOR_TRANCHE_IMPL");
bytes32 constant COMPONENT_ID_JUNIOR_TRANCHE_IMPL = keccak256("ROYCO_COMPONENT_JUNIOR_TRANCHE_IMPL");
bytes32 constant COMPONENT_ID_LIQUIDITY_TRANCHE_IMPL = keccak256("ROYCO_COMPONENT_LIQUIDITY_TRANCHE_IMPL");
bytes32 constant COMPONENT_ID_ACCOUNTANT_IMPL = keccak256("ROYCO_COMPONENT_ACCOUNTANT_IMPL");
bytes32 constant COMPONENT_ID_YDM_STATIC_CURVE = keccak256("ROYCO_COMPONENT_YDM_STATIC_CURVE");
bytes32 constant COMPONENT_ID_YDM_ADAPTIVE_CURVE_V1 = keccak256("ROYCO_COMPONENT_YDM_ADAPTIVE_CURVE_V1");
bytes32 constant COMPONENT_ID_YDM_ADAPTIVE_CURVE_V2 = keccak256("ROYCO_COMPONENT_YDM_ADAPTIVE_CURVE_V2");

// ─── Day-Balancer ────────────────────────────────────────────────────────────

/// @dev The real kernel-bound Balancer V3 pool hook (`RoycoDayBalancerV3Hooks`)
bytes32 constant COMPONENT_ID_DAY_BALANCER_HOOKS = keccak256("ROYCO_COMPONENT_DAY_BALANCER_HOOKS");

// ─── Day kernels ─────────────────────────────────────────────────────────────

/// @dev Creation-code id for `Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel`
bytes32 constant COMPONENT_ID_DAY_KERNEL_IDENTICAL_ERC4626_CHAINLINK = keccak256("ROYCO_COMPONENT_DAY_KERNEL_IDENTICAL_ERC4626_CHAINLINK");

/// @dev Creation-code id for `Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel`
bytes32 constant COMPONENT_ID_DAY_KERNEL_IDENTICAL_MAKINA_CHAINLINK = keccak256("ROYCO_COMPONENT_DAY_KERNEL_IDENTICAL_MAKINA_CHAINLINK");

/// @dev Creation-code id for `Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3_BPTOracle_LT_Kernel`
bytes32 constant COMPONENT_ID_DAY_KERNEL_IDENTICAL_CHAINLINK_TO_ADMIN = keccak256("ROYCO_COMPONENT_DAY_KERNEL_IDENTICAL_CHAINLINK_TO_ADMIN");

/// @dev Creation-code id for `Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_BalancerV3_BPTOracle_LT_Kernel`
bytes32 constant COMPONENT_ID_DAY_KERNEL_IDENTICAL_AA_IDLE_CDO_VIRTUAL_PRICE = keccak256("ROYCO_COMPONENT_DAY_KERNEL_IDENTICAL_AA_IDLE_CDO_VIRTUAL_PRICE");

// ─── Market component salt tags ──────────────────────────────────────────────

bytes32 constant TAG_ST_PROXY = "ST";
bytes32 constant TAG_JT_PROXY = "JT";
bytes32 constant TAG_LT_PROXY = "LT";
bytes32 constant TAG_KERNEL_PROXY = "KERNEL";
bytes32 constant TAG_ACCOUNTANT_PROXY = "ACCOUNTANT";
bytes32 constant TAG_ST_IMPL = "ST_IMPL";
bytes32 constant TAG_JT_IMPL = "JT_IMPL";
bytes32 constant TAG_LT_IMPL = "LT_IMPL";
bytes32 constant TAG_KERNEL_IMPL = "KERNEL_IMPL";
bytes32 constant TAG_ACCOUNTANT_IMPL = "ACCOUNTANT_IMPL";
bytes32 constant TAG_YDM = "YDM";
bytes32 constant TAG_LDM = "LDM";
bytes32 constant TAG_BALANCER_HOOK = "BALANCER_HOOK";
bytes32 constant TAG_BALANCER_HOOK_IMPL = "BALANCER_HOOK_IMPL";
bytes32 constant TAG_BALANCER_V3_POOL = "BALANCER_V3_POOL";
