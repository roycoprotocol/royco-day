// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {
    ADMIN_ACCOUNTANT_ROLE,
    ADMIN_KERNEL_ROLE,
    ADMIN_ORACLE_QUOTER_ROLE,
    ADMIN_PAUSER_ROLE,
    ADMIN_PROTOCOL_FEE_SETTER_ROLE,
    ADMIN_ROLE,
    ADMIN_UPGRADER_ROLE,
    BURNER_ROLE,
    DEPLOYER_ROLE,
    DEPLOYER_ROLE_ADMIN_ROLE,
    GUARDIAN_ROLE,
    JT_LP_ROLE,
    LP_ROLE_ADMIN_ROLE,
    ST_LP_ROLE,
    SYNC_ROLE,
    TRANSFER_AGENT_ROLE
} from "../../src/factory/RolesConfiguration.sol";

/**
 * @title RoleConfigUtils
 * @notice Provides the legacy `RoleConfig` struct and `getRoleConfig` lookup that used to live on the
 *         `RolesConfiguration` contract. Now that `RolesConfiguration.sol` is a file of free role-id
 *         constants, scripts that need the per-role admin/guardian/delay configuration inherit this
 *         helper instead.
 */
abstract contract RoleConfigUtils {
    /// @dev Alias retained for scripts that referenced the legacy private `_ADMIN_ROLE` constant.
    uint64 internal constant _ADMIN_ROLE = ADMIN_ROLE;

    /// @notice Configuration for a single role
    struct RoleConfig {
        uint64 adminRole; // The role that can grant/revoke this role (0 for ADMIN_ROLE)
        uint64 guardianRole; // The role that can cancel operations for this role
        uint32 executionDelay; // Delay in seconds before role operations take effect
    }

    /// @notice Error when an unknown role is requested
    error UNKNOWN_ROLE(uint64 role);

    /**
     * @notice Returns the admin/guardian/delay configuration for a role.
     * @param role The role to get configuration for
     * @return config The role configuration
     */
    function getRoleConfig(uint64 role) public pure returns (RoleConfig memory config) {
        if (role == ADMIN_PAUSER_ROLE) {
            return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        } else if (role == ADMIN_UPGRADER_ROLE) {
            return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 2 days });
        } else if (role == ST_LP_ROLE || role == JT_LP_ROLE) {
            return RoleConfig({ adminRole: LP_ROLE_ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        } else if (role == LP_ROLE_ADMIN_ROLE) {
            return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        } else if (role == SYNC_ROLE) {
            return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        } else if (role == ADMIN_KERNEL_ROLE) {
            return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 2 days });
        } else if (role == ADMIN_ACCOUNTANT_ROLE) {
            return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 2 days });
        } else if (role == ADMIN_PROTOCOL_FEE_SETTER_ROLE) {
            return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 2 days });
        } else if (role == ADMIN_ORACLE_QUOTER_ROLE) {
            return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        } else if (role == GUARDIAN_ROLE) {
            return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: ADMIN_ROLE, executionDelay: 0 });
        } else if (role == DEPLOYER_ROLE) {
            return RoleConfig({ adminRole: DEPLOYER_ROLE_ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        } else if (role == DEPLOYER_ROLE_ADMIN_ROLE) {
            return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        } else if (role == TRANSFER_AGENT_ROLE) {
            return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: ADMIN_ROLE, executionDelay: 0 });
        } else if (role == BURNER_ROLE) {
            return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: ADMIN_ROLE, executionDelay: 0 });
        } else {
            revert UNKNOWN_ROLE(role);
        }
    }
}
