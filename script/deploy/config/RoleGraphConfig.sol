// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoleAssignmentAddresses } from "../../config/DeploymentTypes.sol";
import { EnvConfig } from "./EnvConfig.sol";

/**
 * @title RoleGraphConfig
 * @notice The role-holder addresses the role-graph script assigns per environment: in a test deployment every role
 *         resolves to the single test admin; in production each role points at its dedicated multisig.
 */
abstract contract RoleGraphConfig is EnvConfig {
    /// @dev TEST-ONLY override state: fixtures re-point every role at their own prankable wallets
    RoleAssignmentAddresses private _roleAddressesOverride;
    bool private _roleAddressesOverridden;
    address private _factoryAdminOverride;

    /// @notice TEST-ONLY: overrides the full role-assignment address set for this instance's lifetime
    function overrideRoleAssignmentAddressesForTest(RoleAssignmentAddresses memory _addresses) public {
        _roleAddressesOverride = _addresses;
        _roleAddressesOverridden = true;
    }

    /// @notice TEST-ONLY: overrides the ADMIN_ROLE recipient for this instance's lifetime
    function overrideFactoryAdminForTest(address _admin) public {
        _factoryAdminOverride = _admin;
    }

    /// @notice The account granted the AccessManager's ADMIN_ROLE at the end of the bootstrap
    function factoryAdmin(bool _isTest) public view returns (address) {
        if (_factoryAdminOverride != address(0)) return _factoryAdminOverride;
        return _isTest ? testDeploymentAdmin : ROOT_MULTISIG;
    }

    /// @notice The full role-assignment address set for the environment
    function roleAssignmentAddresses(bool _isTest) public view returns (RoleAssignmentAddresses memory) {
        if (_roleAddressesOverridden) return _roleAddressesOverride;
        address rootRole = _isTest ? testDeploymentAdmin : ROOT_MULTISIG;
        address guardian = _isTest ? testDeploymentAdmin : EXECUTOR_MULTISIG;
        address entryPointAdmin = _isTest ? testDeploymentAdmin : EXECUTOR_MULTISIG;
        address protocolFeeRecipient = _isTest ? testDeploymentAdmin : PROTOCOL_FEE_RECIPIENT;

        return RoleAssignmentAddresses({
            pauserAddress: rootRole,
            unpauserAddress: rootRole,
            upgraderAddress: rootRole,
            syncRoleAddress: rootRole,
            adminKernelAddress: rootRole,
            adminAccountantAddress: rootRole,
            adminProtocolFeeSetterAddress: rootRole,
            adminOracleAddress: rootRole,
            lpRoleAdminAddress: rootRole,
            guardianAddress: guardian,
            deployerAddress: DEPLOYER,
            deployerAdminAddress: rootRole,
            protocolFeeRecipientAddress: protocolFeeRecipient,
            balancerPoolManagerAddress: rootRole,
            marketOpsAddress: rootRole,
            marketReinvestLiquidityPremiumAddress: rootRole,
            adminEntryPointAddress: entryPointAdmin,
            entryPointFeeCollectorAddress: rootRole
        });
    }
}
