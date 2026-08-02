// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IRoycoProtocolTemplate } from "./IRoycoProtocolTemplate.sol";

/**
 * @title IRoycoFactory
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Interface for the template-driven Royco market factory
 */
interface IRoycoFactory {
    /**
     * @notice Storage state for the template-driven factory
     * @custom:storage-location erc7201:Royco.storage.RoycoFactoryV2State
     * @custom:field isTemplateEnabled - Whether a template is registered + enabled
     * @custom:field trancheToKernel - Maps each of a market's tranches (senior, junior, and liquidity) to the market's kernel
     */
    struct RoycoFactoryState {
        mapping(address template => bool enabled) isTemplateEnabled;
        mapping(address tranche => address kernel) trancheToKernel;
    }

    /// @notice Emitted when a template is registered and enabled
    event TemplateRegistered(address indexed template);

    /// @notice Emitted when a template is disabled
    event TemplateDisabled(address indexed template);

    /// @notice Emitted when a market deployment completes
    event MarketDeploymentCompleted(address indexed template, address indexed deployer, IRoycoProtocolTemplate.DeploymentResult result);

    /// @notice Thrown when a factory primitive is called by anything other than the active template
    error ONLY_ACTIVE_TEMPLATE();

    /// @notice Thrown when the supplied access manager is the zero address
    error ACCESS_MANAGER_CANNOT_BE_ZERO_ADDRESS();

    /// @notice Thrown when the supplied access manager has no code
    error ACCESS_MANAGER_HAS_NO_CODE();

    /// @notice Thrown when this factory's gatekeeper holds authority over a different access manager
    error FACTORY_GATEKEEPER_MISMATCH();

    /// @notice Thrown when constructing the factory without a gatekeeper
    error FACTORY_GATEKEEPER_CANNOT_BE_ZERO_ADDRESS();

    /// @notice Thrown when registering the zero address as a template
    error TEMPLATE_CANNOT_BE_ZERO_ADDRESS();

    /// @notice Thrown when registering an already-registered template
    error TEMPLATE_ALREADY_REGISTERED();

    /// @notice Thrown when the template's bound factory is not this factory
    error TEMPLATE_BOUND_TO_DIFFERENT_FACTORY();

    /// @notice Thrown when deploying via a template that is not enabled
    error TEMPLATE_NOT_ENABLED();

    /// @notice Thrown when a deployment is started while another is in progress
    error NO_ACTIVE_TEMPLATE();

    /// @notice Thrown when a factory-forwarded call targets the access manager, which is only administrable through the typed role primitives
    error FACTORY_CALL_TARGET_FORBIDDEN();

    /// @notice Thrown when a template returns a deployment result with a zero tranche or kernel address
    error INVALID_DEPLOYMENT_RESULT();

    /// @notice Thrown when index-aligned array arguments have mismatched lengths
    error LENGTH_MISMATCH();

    /// @notice Returns the AccessManager that governs this factory and its markets
    function ROYCO_AUTHORITY() external view returns (address);

    /// @notice The gatekeeper this factory routes market target configuration through, fixed at construction
    function ROYCO_FACTORY_GATEKEEPER() external view returns (address gatekeeper);

    /**
     * @notice Registers + enables a pre-initialized template
     * @dev The deployer initializes the template (loading its component creation codes) directly, before registering
     * @param _template The template to register
     */
    function registerTemplate(address _template) external;

    /// @notice Disables a registered template
    function disableTemplate(address _template) external;

    /// @notice Returns whether a template is registered + enabled
    function isTemplateEnabled(address _template) external view returns (bool);

    /**
     * @notice Deploys a market via an enabled template and verifies its wiring
     * @param _template The enabled template to run
     * @param _params The ABI-encoded template-specific params
     * @return result The deployed market's contracts
     */
    function executeMarketDeployment(address _template, bytes calldata _params) external returns (IRoycoProtocolTemplate.DeploymentResult memory result);

    /// @notice CREATE3-deploys a beacon proxy, callable only by the active template
    function deployDeterministicProxyFromTemplate(
        address _beacon,
        bytes calldata _initData,
        bytes32 _salt
    )
        external
        returns (address deployed, bool alreadyDeployed);

    /// @notice Predicts the CREATE3 address for a salt
    function predictDeterministicAddress(bytes32 _salt) external view returns (address);

    /**
     * @notice Binds one target's selectors to their roles on the AccessManager, callable only by the active template
     * @param _target The contract whose functions are being access-gated
     * @param _selectors The function selectors to bind, index-aligned with `_roleIds`
     * @param _roleIds The role id required to call each corresponding selector, index-aligned with `_selectors`
     */
    function setMarketTargetFunctionRole(address _target, bytes4[] calldata _selectors, uint64[] calldata _roleIds) external;

    /**
     * @notice Grants each role to an account on the AccessManager, callable only by the active template
     * @dev The three arrays are index-aligned: `_roleIds[i]` is granted to `_accounts[i]` with `_executionDelays[i]`
     * @dev ADMIN_ROLE is a forbidden grant
     * @param _roleIds The role ids to grant, index-aligned with `_accounts`/`_executionDelays`
     * @param _accounts The accounts receiving each role, index-aligned with `_roleIds`/`_executionDelays`
     * @param _executionDelays The access-manager execution delay applied to each grant, index-aligned with `_roleIds`/`_accounts`
     */
    function grantMarketRole(uint64[] calldata _roleIds, address[] calldata _accounts, uint32[] calldata _executionDelays) external;

    /**
     * @notice Forwards an arbitrary call as the factory, callable only by the active template
     * @dev The access manager is a forbidden target: role grants and bindings go through the typed role primitives
     * @dev A target failure bubbles verbatim
     */
    function executeAsFactory(address _target, bytes calldata _data) external returns (bytes memory result);

    /// @notice Returns the kernel a factory-deployed tranche belongs to (zero for unknown addresses)
    function trancheToKernel(address _tranche) external view returns (address kernel);

    /**
     * @notice Resolves a whole market from ANY one of its three tranches
     * @param _tranche Any of the market's senior, junior, or liquidity provider tranche addresses
     * @return seniorTranche The market's senior tranche (zero if `_tranche` is unknown)
     * @return juniorTranche The market's junior tranche (zero if `_tranche` is unknown)
     * @return liquidityProviderTranche The market's liquidity provider tranche (zero if `_tranche` is unknown)
     * @return kernel The market's kernel (zero if `_tranche` is unknown)
     * @return accountant The market's accountant (zero if `_tranche` is unknown)
     */
    function getMarket(address _tranche)
        external
        view
        returns (address seniorTranche, address juniorTranche, address liquidityProviderTranche, address kernel, address accountant);
}
