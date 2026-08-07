// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {
    ADMIN_ACCOUNTANT_ROLE,
    ADMIN_BALANCER_POOL_MANAGER_ROLE,
    ADMIN_BLACKLIST_ROLE,
    ADMIN_ENTRY_POINT_ROLE,
    ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE,
    ADMIN_FACTORY_ROLE,
    ADMIN_KERNEL_ROLE,
    ADMIN_MARKET_OPS_ROLE,
    ADMIN_MARKET_REINVEST_LIQUIDITY_PREMIUM_ROLE,
    ADMIN_ORACLE_ROLE,
    ADMIN_PAUSER_ROLE,
    ADMIN_PROTOCOL_FEE_SETTER_ROLE,
    ADMIN_ROLE,
    ADMIN_UNPAUSER_ROLE,
    ADMIN_UPGRADER_ROLE,
    GUARDIAN_ROLE,
    JT_LP_ROLE,
    LPT_LP_ROLE,
    LP_ROLE_ADMIN_ROLE,
    ST_LP_ROLE,
    SYNC_ROLE
} from "../../../src/factory/Roles.sol";
import { RoleAssignment, RoleAssignmentAddresses, RoleConfig } from "../../config/DeploymentTypes.sol";
import { EnvConfig } from "./EnvConfig.sol";

/// @title RoleGraphConfig
abstract contract RoleGraphConfig is EnvConfig {
    error UnknownRole(uint64 role);

    // ═══════════════════════════════════════════════════════════════════════════
    // DELAY TIERS (kerchkoffs `src/registry/Roles.sol` — grant delays stay 0; only execution delays are used)
    // ═══════════════════════════════════════════════════════════════════════════

    uint32 internal constant DELAY_IMMEDIATE = 0;
    uint32 internal constant DELAY_SHORT = 24 hours;
    uint32 internal constant DELAY_ROOT = 72 hours;

    /// @dev TEST-ONLY override state: fixtures re-point every role at their own prankable wallets
    RoleAssignmentAddresses private _roleAddressesOverride;
    bool private _roleAddressesOverridden;
    address private _factoryAdminOverride;

    /// @notice TEST-ONLY: overrides the full role-assignment address set for this instance's lifetime
    function overrideRoleAssignmentAddressesForTest(RoleAssignmentAddresses memory _addresses) public {
        _roleAddressesOverride = _addresses;
        _roleAddressesOverridden = true;
    }

    /// @notice TEST-ONLY: overrides the ADMIN_ROLE recipient for this instance's lifetime (also drops the prod
    ///         admin lockdown delay to 0, so fixtures can drive admin-gated setup synchronously)
    function overrideFactoryAdminForTest(address _admin) public {
        _factoryAdminOverride = _admin;
    }

    /// @notice The account granted the AccessManager's ADMIN_ROLE at the end of the bootstrap
    function factoryAdmin(bool _isTest) public view returns (address) {
        if (_factoryAdminOverride != address(0)) return _factoryAdminOverride;
        return _isTest ? testDeploymentAdmin : FNDN;
    }

    /// @notice The execution delay on the factory admin's ADMIN_ROLE membership: the kerchkoffs "lockdown" — FNDN's
    ///         admin ops run at 72h and are intentionally non-cancellable by any other party. Test deployments and
    ///         fixture overrides stay at 0 so admin-gated setup runs synchronously
    function factoryAdminExecutionDelay(bool _isTest) public view returns (uint32) {
        if (_isTest || _factoryAdminOverride != address(0)) return DELAY_IMMEDIATE;
        return DELAY_ROOT;
    }

    /// @notice The full role-assignment address set for the environment
    function roleAssignmentAddresses(bool _isTest) public view returns (RoleAssignmentAddresses memory) {
        if (_roleAddressesOverridden) return _roleAddressesOverride;
        address way = _isTest ? testDeploymentAdmin : WAY;
        address fndn = _isTest ? testDeploymentAdmin : FNDN;
        address pauser = _isTest ? testDeploymentAdmin : WAY_PAUSE;
        address guardianVeto = _isTest ? testDeploymentAdmin : FNDN_VETO;
        address lpOperator = _isTest ? testDeploymentAdmin : AUTO;

        return RoleAssignmentAddresses({
            pauserAddress: pauser,
            unpauserAddress: fndn,
            upgraderAddress: way,
            syncRoleAddress: way,
            adminKernelAddress: way,
            adminAccountantAddress: way,
            adminProtocolFeeSetterAddress: way,
            adminOracleAddress: way,
            adminOracleEmergencyAddress: fndn,
            lpRoleAdminAddress: way,
            lpRoleAdminOperatorAddress: lpOperator,
            guardianAddress: fndn,
            guardianVetoAddress: guardianVeto,
            lpRoleHolderAddress: fndn,
            balancerPoolManagerAddress: way,
            marketOpsAddress: way,
            marketReinvestLiquidityPremiumAddress: way,
            adminEntryPointAddress: way,
            entryPointFeeCollectorAddress: fndn
        });
    }

    /// @notice Builds the role assignments the apply script grants, combining the address surface with the role table
    function generateRolesAssignments(RoleAssignmentAddresses memory _addresses) public pure returns (RoleAssignment[] memory roleAssignments) {
        roleAssignments = new RoleAssignment[](22);
        roleAssignments[0] = _assignment(ADMIN_PAUSER_ROLE, _addresses.pauserAddress);
        roleAssignments[1] = _assignment(ADMIN_UPGRADER_ROLE, _addresses.upgraderAddress);
        roleAssignments[2] = _assignment(SYNC_ROLE, _addresses.syncRoleAddress);
        roleAssignments[3] = _assignment(ADMIN_KERNEL_ROLE, _addresses.adminKernelAddress);
        roleAssignments[4] = _assignment(ADMIN_ACCOUNTANT_ROLE, _addresses.adminAccountantAddress);
        roleAssignments[5] = _assignment(ADMIN_PROTOCOL_FEE_SETTER_ROLE, _addresses.adminProtocolFeeSetterAddress);
        roleAssignments[6] = _assignment(ADMIN_ORACLE_ROLE, _addresses.adminOracleAddress);
        roleAssignments[7] = _assignment(LP_ROLE_ADMIN_ROLE, _addresses.lpRoleAdminAddress);
        roleAssignments[8] = _assignment(ST_LP_ROLE, _addresses.lpRoleHolderAddress);
        roleAssignments[9] = _assignment(JT_LP_ROLE, _addresses.lpRoleHolderAddress);
        roleAssignments[10] = _assignment(GUARDIAN_ROLE, _addresses.guardianAddress);
        roleAssignments[11] = _assignment(ADMIN_UNPAUSER_ROLE, _addresses.unpauserAddress);
        roleAssignments[12] = _assignment(LPT_LP_ROLE, _addresses.lpRoleHolderAddress);
        roleAssignments[13] = _assignment(ADMIN_BALANCER_POOL_MANAGER_ROLE, _addresses.balancerPoolManagerAddress);
        roleAssignments[14] = _assignment(ADMIN_MARKET_OPS_ROLE, _addresses.marketOpsAddress);
        roleAssignments[15] = _assignment(ADMIN_BLACKLIST_ROLE, _addresses.marketOpsAddress);
        roleAssignments[16] = _assignment(ADMIN_ENTRY_POINT_ROLE, _addresses.adminEntryPointAddress);
        roleAssignments[17] = _assignment(ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE, _addresses.entryPointFeeCollectorAddress);
        roleAssignments[18] = _assignment(ADMIN_MARKET_REINVEST_LIQUIDITY_PREMIUM_ROLE, _addresses.marketReinvestLiquidityPremiumAddress);
        roleAssignments[19] = _assignment(GUARDIAN_ROLE, _addresses.guardianVetoAddress);
        roleAssignments[20] = _assignmentWithDelay(ADMIN_ORACLE_ROLE, _addresses.adminOracleEmergencyAddress, DELAY_IMMEDIATE);
        roleAssignments[21] = _assignment(LP_ROLE_ADMIN_ROLE, _addresses.lpRoleAdminOperatorAddress);
    }

    function _assignment(uint64 _role, address _assignee) private pure returns (RoleAssignment memory) {
        RoleConfig memory cfg = getRoleConfig(_role);
        return _assignmentWithDelay(_role, _assignee, cfg.executionDelay);
    }

    /// @dev For co-holds whose delay differs from the role table's
    function _assignmentWithDelay(uint64 _role, address _assignee, uint32 _executionDelay) private pure returns (RoleAssignment memory) {
        RoleConfig memory cfg = getRoleConfig(_role);
        return RoleAssignment({ role: _role, roleAdminRole: cfg.adminRole, assignee: _assignee, executionDelay: _executionDelay });
    }

    /// @notice The admin/guardian/execution-delay configuration for a role
    function getRoleConfig(uint64 role) public pure returns (RoleConfig memory) {
        if (role == ADMIN_PAUSER_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: DELAY_IMMEDIATE });
        if (role == ADMIN_UPGRADER_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: DELAY_ROOT });
        if (role == ST_LP_ROLE || role == JT_LP_ROLE) {
            return RoleConfig({ adminRole: LP_ROLE_ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: DELAY_IMMEDIATE });
        }
        if (role == LP_ROLE_ADMIN_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: DELAY_IMMEDIATE });
        if (role == SYNC_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: DELAY_IMMEDIATE });
        if (role == ADMIN_KERNEL_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: DELAY_ROOT });
        if (role == ADMIN_ACCOUNTANT_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: DELAY_ROOT });
        if (role == ADMIN_PROTOCOL_FEE_SETTER_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: DELAY_ROOT });
        if (role == ADMIN_ORACLE_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: DELAY_ROOT });
        if (role == GUARDIAN_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: ADMIN_ROLE, executionDelay: DELAY_IMMEDIATE });
        if (role == ADMIN_FACTORY_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: DELAY_ROOT });
        if (role == ADMIN_UNPAUSER_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: DELAY_IMMEDIATE });
        if (role == LPT_LP_ROLE) return RoleConfig({ adminRole: LP_ROLE_ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: DELAY_IMMEDIATE });
        if (role == ADMIN_BALANCER_POOL_MANAGER_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: DELAY_ROOT });
        if (role == ADMIN_MARKET_OPS_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: DELAY_ROOT });
        if (role == ADMIN_MARKET_REINVEST_LIQUIDITY_PREMIUM_ROLE) {
            return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: DELAY_IMMEDIATE });
        }
        if (role == ADMIN_BLACKLIST_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: DELAY_ROOT });
        if (role == ADMIN_ENTRY_POINT_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: DELAY_SHORT });
        if (role == ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE) {
            return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: DELAY_IMMEDIATE });
        }
        revert UnknownRole(role);
    }
}
