// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoProtocolTemplate } from "./IRoycoProtocolTemplate.sol";

/**
 * @title IRoycoFactory
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Interface for the template-driven Royco market factory.
 */
interface IRoycoFactory {
    /**
     * @notice Storage state for the template-driven factory.
     * @custom:storage-location erc7201:Royco.storage.RoycoFactoryV2State
     * @custom:field isTemplateEnabled - Whether a template is registered + enabled.
     * @custom:field seniorTrancheToJuniorTranche - Maps a market's senior tranche to its junior tranche.
     * @custom:field juniorTrancheToSeniorTranche - Maps a market's junior tranche to its senior tranche.
     */
    struct RoycoFactoryState {
        mapping(address template => bool enabled) isTemplateEnabled;
        mapping(address seniorTranche => address juniorTranche) seniorTrancheToJuniorTranche;
        mapping(address juniorTranche => address seniorTranche) juniorTrancheToSeniorTranche;
    }

    /// @notice Emitted when a template is registered and enabled.
    event TemplateRegistered(address indexed template);
    /// @notice Emitted when a template is disabled.
    event TemplateDisabled(address indexed template);
    /// @notice Emitted when a market deployment window is opened for a template.
    event MarketDeploymentStarted(address indexed template, address indexed deployer);
    /// @notice Emitted when a market deployment completes and is verified.
    event MarketDeploymentCompleted(address indexed template, IRoycoProtocolTemplate.DeploymentResult result);

    /// @notice Thrown when a factory primitive is called by anything other than the active template.
    error ONLY_ACTIVE_TEMPLATE();
    /// @notice Thrown when the supplied access manager is the zero address.
    error ACCESS_MANAGER_CANNOT_BE_ZERO_ADDRESS();
    /// @notice Thrown when the supplied access manager has no code.
    error ACCESS_MANAGER_HAS_NO_CODE();
    /// @notice Thrown when the factory does not hold ADMIN_ROLE on the supplied access manager.
    error FACTORY_NOT_ADMIN_ON_ACCESS_MANAGER();
    /// @notice Thrown when registering the zero address as a template.
    error TEMPLATE_CANNOT_BE_ZERO_ADDRESS();
    /// @notice Thrown when registering an already-registered template.
    error TEMPLATE_ALREADY_REGISTERED();
    /// @notice Thrown when the template's bound factory is not this factory.
    error TEMPLATE_BOUND_TO_DIFFERENT_FACTORY();
    /// @notice Thrown when deploying via a template that is not enabled.
    error TEMPLATE_NOT_ENABLED();
    /// @notice Thrown when a deployment is started while another is in progress.
    error NO_ACTIVE_TEMPLATE();
    /// @notice Thrown when a factory-forwarded call reverts.
    error FACTORY_CALL_FAILED(bytes returnData);

    /// @notice Returns the AccessManager that governs this factory and its markets.
    function ROYCO_AUTHORITY() external view returns (address);

    /**
     * @notice Registers + enables a template and loads its component creation codes.
     * @param _template The template to register.
     * @param _componentIds The component IDs the template will store.
     * @param _creationCodes The creation code for each component, index-aligned with `_componentIds`.
     */
    function registerTemplate(address _template, bytes32[] calldata _componentIds, bytes[] calldata _creationCodes) external;

    /// @notice Disables a registered template.
    function disableTemplate(address _template) external;

    /// @notice Returns whether a template is registered + enabled.
    function isTemplateEnabled(address _template) external view returns (bool);

    /**
     * @notice Deploys a market via an enabled template and verifies its wiring.
     * @param _template The enabled template to run.
     * @param _params The ABI-encoded template-specific params.
     * @return result The deployed market's contracts.
     */
    function executeMarketDeployment(address _template, bytes calldata _params) external returns (IRoycoProtocolTemplate.DeploymentResult memory result);

    /// @notice CREATE3-deploys a contract from creation code. Callable only by the active template.
    function deployDeterministicContract(bytes calldata _creationCode, bytes32 _salt) external returns (address deployed, bool alreadyDeployed);

    /// @notice CREATE3-deploys an ERC1967 proxy. Callable only by the active template.
    function deployDeterministicProxy(
        address _implementation,
        bytes calldata _initData,
        bytes32 _salt
    )
        external
        returns (address deployed, bool alreadyDeployed);

    /// @notice Predicts the CREATE3 address for a salt.
    function predictDeterministicAddress(bytes32 _salt) external view returns (address);

    /// @notice Binds a target's selector to a role on the AccessManager. Callable only by the active template.
    function setMarketTargetFunctionRole(address _target, bytes4 _selector, uint64 _roleId) external;

    /// @notice Grants a role on the AccessManager. Callable only by the active template.
    function grantMarketRole(uint64 _roleId, address _account, uint32 _executionDelay) external;

    /// @notice Forwards an arbitrary call as the factory. Callable only by the active template.
    function executeAsFactory(address _target, bytes calldata _data) external returns (bytes memory result);

    /// @notice Returns the junior tranche paired with a senior tranche.
    function seniorTrancheToJuniorTranche(address _seniorTranche) external view returns (address juniorTranche);

    /// @notice Returns the senior tranche paired with a junior tranche.
    function juniorTrancheToSeniorTranche(address _juniorTranche) external view returns (address seniorTranche);
}
