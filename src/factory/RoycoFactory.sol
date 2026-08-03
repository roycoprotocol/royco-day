// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { AccessManagedUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";
import { BeaconProxy } from "../../lib/openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol";
import { CREATE3 } from "../../lib/solady/src/utils/CREATE3.sol";
import { RoycoUUPSBase } from "../base/RoycoUUPSBase.sol";
import { IRoycoDayEntryPoint } from "../interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoDayKernel } from "../interfaces/IRoycoDayKernel.sol";
import { IBaseTemplate } from "../interfaces/factory/IBaseTemplate.sol";
import { IRoycoFactory } from "../interfaces/factory/IRoycoFactory.sol";
import { IRoycoFactoryGatekeeper } from "../interfaces/factory/IRoycoFactoryGatekeeper.sol";
import { IRoycoProtocolTemplate } from "../interfaces/factory/IRoycoProtocolTemplate.sol";
import { DispatchMode } from "../libraries/Types.sol";
import { DispatchLogic } from "../libraries/logic/DispatchLogic.sol";

/**
 * @title RoycoFactory
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Extensible template-driven factory for Royco markets
 */
contract RoycoFactory is AccessManagedUpgradeable, RoycoUUPSBase, IRoycoFactory {
    using DispatchLogic for address;

    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoFactoryV2State")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROYCO_FACTORY_STORAGE_SLOT = 0x40ecf137e43ccc3fb8e0ec956edc7094cfc159472690a44f90b2be053a987500;

    /// @inheritdoc IRoycoFactory
    address public immutable override(IRoycoFactory) ROYCO_FACTORY_GATEKEEPER;

    /// @dev Holds the address of the template currently inside an `executeMarketDeployment` window, `address(0)` otherwise
    address private transient _activeTemplate;

    /// @dev The account that initiated the in-flight market deployment, held transiently so the active template can pull the genesis seed from it
    address private transient _marketDeployer;

    // ═══════════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Only the currently-running template can call
    /// @dev Invariant: the active template is always enabled
    modifier onlyActiveTemplate() {
        require(msg.sender == _activeTemplate, ONLY_ACTIVE_TEMPLATE());
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTION + INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @param _roycoFactoryGatekeeper The gatekeeper this factory routes market target configuration through
    constructor(address _roycoFactoryGatekeeper) {
        require(_roycoFactoryGatekeeper != address(0), FACTORY_GATEKEEPER_CANNOT_BE_ZERO_ADDRESS());
        ROYCO_FACTORY_GATEKEEPER = _roycoFactoryGatekeeper;
        _disableInitializers();
    }

    /// @notice Initializes the factory proxy against a pre-deployed `RoycoAccessManager`
    /// @param _roycoAccessManager Pre-deployed access manager whose gatekeeper must already point back at this factory
    function initialize(address _roycoAccessManager) external initializer {
        require(_roycoAccessManager != address(0), ACCESS_MANAGER_CANNOT_BE_ZERO_ADDRESS());
        require(_roycoAccessManager.code.length > 0, ACCESS_MANAGER_HAS_NO_CODE());

        // Verify the gatekeeper points back at this factory
        require(IRoycoFactoryGatekeeper(ROYCO_FACTORY_GATEKEEPER).ROYCO_ACCESS_MANAGER() == _roycoAccessManager, FACTORY_GATEKEEPER_MISMATCH());

        // Wire the factory's authority to the specified access manager
        __RoycoBase_init(_roycoAccessManager);
    }

    /// @inheritdoc IRoycoFactory
    function ROYCO_AUTHORITY() external view override(IRoycoFactory) returns (address) {
        return authority();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IRoycoFactory
    function registerTemplate(address _template) external override(IRoycoFactory) whenNotPaused restricted {
        require(_template != address(0), TEMPLATE_CANNOT_BE_ZERO_ADDRESS());

        RoycoFactoryState storage $ = _getRoycoFactoryStorage();
        require(!$.isTemplateEnabled[_template], TEMPLATE_ALREADY_REGISTERED());

        // Sanity: template was constructed pointing at this factory
        require(address(IBaseTemplate(_template).ROYCO_FACTORY()) == address(this), TEMPLATE_BOUND_TO_DIFFERENT_FACTORY());

        $.isTemplateEnabled[_template] = true;
        emit TemplateRegistered(_template);
    }

    /// @inheritdoc IRoycoFactory
    function disableTemplate(address _template) external override(IRoycoFactory) restricted {
        _getRoycoFactoryStorage().isTemplateEnabled[_template] = false;
        emit TemplateDisabled(_template);
    }

    /// @inheritdoc IRoycoFactory
    function isTemplateEnabled(address _template) external view override(IRoycoFactory) returns (bool) {
        return _getRoycoFactoryStorage().isTemplateEnabled[_template];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYER ENTRYPOINT
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IRoycoFactory
    function executeMarketDeployment(
        address _template,
        bytes calldata _params
    )
        external
        override(IRoycoFactory)
        restricted
        whenNotPaused
        returns (IRoycoProtocolTemplate.DeploymentResult memory result)
    {
        RoycoFactoryState storage $ = _getRoycoFactoryStorage();

        require($.isTemplateEnabled[_template], TEMPLATE_NOT_ENABLED());
        require(_activeTemplate == address(0), NO_ACTIVE_TEMPLATE());

        // Bind the active template and the deployment's initiator (the genesis seed's funder)
        _activeTemplate = _template;
        _marketDeployer = msg.sender;

        // Deploy the market
        result = IBaseTemplate(_template).deployMarket(_params);

        // A valid market must have a kernel, a senior tranche, and at least one counterparty tranche: senior capital needs a junior buffer or a liquidity venue to trade against
        require(
            result.kernel != address(0) && result.seniorTranche != address(0) && result.juniorTranche != address(0)
                && result.liquidityProviderTranche != address(0),
            INVALID_DEPLOYMENT_RESULT()
        );

        // Register each deployed tranche against the market's kernel, guarding the optional slots so the null address never registers as a tranche
        $.trancheToKernel[result.seniorTranche] = result.kernel;
        $.trancheToKernel[result.juniorTranche] = result.kernel;
        $.trancheToKernel[result.liquidityProviderTranche] = result.kernel;

        // Configure the market's periphery, may read trancheToKernel mapping set above.
        IBaseTemplate(_template).postMarketRegistration(result, _params);

        // Explicitly clear for clarity: transient storage auto-clears at the end of the transaction as a backstop
        _activeTemplate = address(0);
        _marketDeployer = address(0);

        emit MarketDeploymentCompleted(_template, msg.sender, result);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEMPLATE-CALLABLE PRIMITIVES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IRoycoFactory
    function marketDeployer() external view override(IRoycoFactory) returns (address) {
        return _marketDeployer;
    }

    /// @inheritdoc IRoycoFactory
    function deployDeterministicProxyFromTemplate(
        address _beacon,
        bytes calldata _initData,
        bytes32 _salt
    )
        external
        override(IRoycoFactory)
        onlyActiveTemplate
        whenNotPaused
        returns (address deployed, bool alreadyDeployed)
    {
        // Check if the proxy already exists at the predicted address
        deployed = CREATE3.predictDeterministicAddress(_salt);
        if (deployed.code.length > 0) return (deployed, true);

        // Deploy the proxy
        bytes memory creationCode = abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(_beacon, _initData));
        deployed = CREATE3.deployDeterministic(creationCode, _salt);
        return (deployed, false);
    }

    /// @inheritdoc IRoycoFactory
    function predictDeterministicAddress(bytes32 _salt) external view override(IRoycoFactory) returns (address) {
        return CREATE3.predictDeterministicAddress(_salt);
    }

    /// @inheritdoc IRoycoFactory
    function setMarketTargetFunctionRole(
        address _target,
        bytes4[] calldata _selectors,
        uint64[] calldata _roleIds
    )
        external
        override(IRoycoFactory)
        whenNotPaused
        onlyActiveTemplate
    {
        IRoycoFactoryGatekeeper(ROYCO_FACTORY_GATEKEEPER).configureFreshTarget(_target, _selectors, _roleIds);
    }

    /// @inheritdoc IRoycoFactory
    function configureMarketPeriphery(
        address[] calldata _tranches,
        IRoycoDayEntryPoint.TrancheConfig[] calldata _configs,
        address _kernel
    )
        external
        override(IRoycoFactory)
        whenNotPaused
        onlyActiveTemplate
    {
        IRoycoFactoryGatekeeper(ROYCO_FACTORY_GATEKEEPER).configureMarketPeriphery(_tranches, _configs, _kernel);
    }

    /// @inheritdoc IRoycoFactory
    function executeAsFactory(
        address _target,
        bytes calldata _data
    )
        external
        override(IRoycoFactory)
        whenNotPaused
        onlyActiveTemplate
        returns (bytes memory result)
    {
        // The access manager is never a legitimate target for an arbitrary call
        require(_target != authority() && _target != ROYCO_FACTORY_GATEKEEPER, FACTORY_CALL_TARGET_FORBIDDEN());

        // Forward as an execution dispatch
        return _target._dispatch(DispatchMode.EXECUTE, _data);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GETTERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IRoycoFactory
    function trancheToKernel(address _tranche) external view override(IRoycoFactory) returns (address kernel) {
        return _getRoycoFactoryStorage().trancheToKernel[_tranche];
    }

    /// @inheritdoc IRoycoFactory
    function getMarket(address _tranche)
        external
        view
        override(IRoycoFactory)
        returns (address seniorTranche, address juniorTranche, address liquidityProviderTranche, address kernel, address accountant)
    {
        kernel = _getRoycoFactoryStorage().trancheToKernel[_tranche];
        // Unknown tranche: every component resolves to zero
        if (kernel == address(0)) return (address(0), address(0), address(0), address(0), address(0));
        // The kernel's immutables are the single source of truth for the market's contract set
        IRoycoDayKernel dayKernel = IRoycoDayKernel(kernel);
        return (dayKernel.seniorTranche(), dayKernel.juniorTranche(), dayKernel.liquidityProviderTranche(), kernel, dayKernel.accountant());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════════════

    function _getRoycoFactoryStorage() private pure returns (IRoycoFactory.RoycoFactoryState storage $) {
        assembly ("memory-safe") {
            $.slot := ROYCO_FACTORY_STORAGE_SLOT
        }
    }
}

