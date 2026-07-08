// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// =============================================================================
// RolesConfiguration — canonical registry of Royco protocol role IDs
// =============================================================================

// ═══════════════════════════════════════════════════════════════════════════════
// COMMON ROLES
// ═══════════════════════════════════════════════════════════════════════════════

uint64 constant ADMIN_ROLE = type(uint64).min; // From AccessManager.sol
uint64 constant PUBLIC_ROLE = type(uint64).max; // From AccessManager.sol
uint64 constant ADMIN_PAUSER_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_PAUSER_ROLE"))));
uint64 constant ADMIN_UNPAUSER_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_UNPAUSER_ROLE"))));
uint64 constant ADMIN_UPGRADER_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_UPGRADER_ROLE"))));

// ═══════════════════════════════════════════════════════════════════════════════
// TRANCHE ROLES
// ═══════════════════════════════════════════════════════════════════════════════

uint64 constant ST_LP_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ST_LP_ROLE"))));
uint64 constant JT_LP_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_JT_LP_ROLE"))));
uint64 constant LT_LP_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_LT_LP_ROLE"))));
uint64 constant BURNER_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_BURNER_ROLE"))));

// ═══════════════════════════════════════════════════════════════════════════════
// KERNEL ROLES
// ═══════════════════════════════════════════════════════════════════════════════

uint64 constant SYNC_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_SYNC_ROLE"))));
uint64 constant ADMIN_KERNEL_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_KERNEL_ROLE"))));
uint64 constant ADMIN_MARKET_OPS_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_MARKET_OPS_ROLE"))));
uint64 constant ADMIN_REINVESTMENT_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_REINVESTMENT_ROLE"))));

// ═══════════════════════════════════════════════════════════════════════════════
// ACCOUNTANT ROLES
// ═══════════════════════════════════════════════════════════════════════════════

uint64 constant ADMIN_ACCOUNTANT_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_ACCOUNTANT_ROLE"))));
uint64 constant ADMIN_PROTOCOL_FEE_SETTER_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_PROTOCOL_FEE_SETTER_ROLE"))));

// ═══════════════════════════════════════════════════════════════════════════════
// QUOTER ROLES
// ═══════════════════════════════════════════════════════════════════════════════

uint64 constant ADMIN_ORACLE_QUOTER_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_ORACLE_QUOTER_ROLE"))));

/// @dev The role for the manual conversion-rate override (setConversionRate): setting the ST-asset conversion rate directly
///      is a pricing change, a consequential operation, so it waits the long delay. Repointing the oracle source
///      (setChainlinkOracle) stays operational under ADMIN_ORACLE_QUOTER_ROLE.
uint64 constant ADMIN_CONVERSION_RATE_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_CONVERSION_RATE_ROLE"))));

// ═══════════════════════════════════════════════════════════════════════════════
// ENTRY POINT ROLES
// ═══════════════════════════════════════════════════════════════════════════════

uint64 constant ADMIN_ENTRY_POINT_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_ENTRY_POINT_ROLE"))));
uint64 constant ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE"))));

// ═══════════════════════════════════════════════════════════════════════════════
// BALANCER V3 POOL MANAGER ROLE
// ═══════════════════════════════════════════════════════════════════════════════

uint64 constant ADMIN_BALANCER_POOL_MANAGER_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_BALANCER_POOL_MANAGER_ROLE"))));

// ═══════════════════════════════════════════════════════════════════════════════
// FACTORY ROLES
// ═══════════════════════════════════════════════════════════════════════════════

uint64 constant ADMIN_FACTORY_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_FACTORY_ROLE"))));
uint64 constant DEPLOYER_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_DEPLOYER_ROLE"))));
uint64 constant DEPLOYER_ROLE_ADMIN_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_DEPLOYER_ROLE_ADMIN_ROLE"))));

// ═══════════════════════════════════════════════════════════════════════════════
// META ROLES
// ═══════════════════════════════════════════════════════════════════════════════

uint64 constant LP_ROLE_ADMIN_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_LP_ROLE_ADMIN_ROLE"))));

// ═══════════════════════════════════════════════════════════════════════════════
// BLACKLIST ROLES
// ═══════════════════════════════════════════════════════════════════════════

/// @dev The role for the instant, protective blacklist add (blacklistAccounts): fast to block a threat, so it carries no delay.
uint64 constant ADMIN_BLACKLIST_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_BLACKLIST_ROLE"))));

/// @dev The role for the delayed blacklist removal (unblacklistAccounts): removing an account's protection is operational,
///      not a system-security change, so it waits the short delay and cannot take effect without notice.
uint64 constant ADMIN_UNBLACKLIST_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_UNBLACKLIST_ROLE"))));

/// @dev The role for the screening-source change (setSanctionsList): repointing the Chainalysis sanctions source changes
///      how every account is screened, a system-level change, so it waits the long delay.
uint64 constant ADMIN_SANCTIONS_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_SANCTIONS_ROLE"))));

// ═══════════════════════════════════════════════════════════════════════════
// GUARDIAN ROLE
// ═══════════════════════════════════════════════════════════════════════════════

uint64 constant GUARDIAN_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_GUARDIAN_ROLE"))));
