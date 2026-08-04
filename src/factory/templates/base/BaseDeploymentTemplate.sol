// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { AccessManaged } from "../../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManaged.sol";
import { RoycoDayAccountant } from "../../../accountant/RoycoDayAccountant.sol";
import { IRoycoAuth } from "../../../interfaces/IRoycoAuth.sol";
import { IRoycoDayAccountant } from "../../../interfaces/IRoycoDayAccountant.sol";
import { IRoycoVaultTranche } from "../../../interfaces/IRoycoVaultTranche.sol";
import { IBaseTemplate } from "../../../interfaces/factory/IBaseTemplate.sol";
import { IRoycoFactory } from "../../../interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../../interfaces/factory/IRoycoProtocolTemplate.sol";
import { MAX_PROTOCOL_FEE_WAD } from "../../../libraries/Constants.sol";
import { RoycoSeniorTranche } from "../../../tranches/RoycoSeniorTranche.sol";
import { _resolveMarketAuthority } from "./Utils.sol";

/**
 * @title BaseDeploymentTemplate
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Abstract base every Royco protocol template inherits from, standardizing:
 *           - Component param shapes (ST / JT / Accountant / YDM) so concrete templates
 *             share a vocabulary for the bits that don't vary across recipes
 *           - A proxy-deployment helper that calls back into the factory's primitives
 *           - Init-data builders that force the market authority
 *           - A declarative role-bindings struct + a generic `_applyRoleBindings` loop
 * @dev Market implementations (tranches, accountant, kernel, YDMs, hook) are deployed externally by the deployer and
 *      passed into the template via the params blob. The template deploys only proxies (via the factory) and wires and
 *      verifies the market
 */
abstract contract BaseDeploymentTemplate is IBaseTemplate, AccessManaged {
    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Thrown when a market proxy was already deployed at its CREATE3 address, signals a `marketId`
    ///         collision that would re-use the pre-existing contract instead of producing a fresh market
    error MARKET_COMPONENT_ALREADY_DEPLOYED(address deployedAt, bytes32 salt);

    /// @notice Thrown when a protocol fee exceeds the maximum the accountant would accept
    error INVALID_PROTOCOL_FEE_CONFIG();

    /// @notice Thrown when a junior and a liquidity provider yield distribution model share an instance, which the accountant rejects
    error YIELD_DISTRIBUTION_MODELS_NOT_DISTINCT();

    /// @notice Thrown when a market selects a yield distribution model shape this template has no instances for
    error YDM_NOT_REGISTERED(string ydmType);

    /// @notice Thrown when registering a model shape under an empty name
    error INVALID_YDM_TYPE();

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Emitted when the protocol fee set every future market is deployed with changes
    event ProtocolFeeConfigUpdated(ProtocolFeeConfig config);

    /// @notice Emitted when the recipient every future market pays its protocol fees to changes
    event ProtocolFeeRecipientUpdated(address protocolFeeRecipient);

    /**
     * @notice Emitted when a model shape's instances are registered or replaced
     * @param ydmType The model shape's name
     * @param jtYdm The junior tranche's model instance for this shape
     * @param lptYdm The liquidity provider tranche's model instance for this shape
     */
    event YieldDistributionModelsRegistered(string ydmType, address jtYdm, address lptYdm);

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL POLICY
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice The protocol fee set every market this template deploys is initialized with
     * @dev Packs into one slot: each fee is bounded by `MAX_PROTOCOL_FEE_WAD` (1e18), well inside a uint64
     * @custom:field stProtocolFeeWAD - The share of senior yield taken as protocol fee, scaled to WAD
     * @custom:field jtProtocolFeeWAD - The share of junior yield taken as protocol fee, scaled to WAD
     * @custom:field jtYieldShareProtocolFeeWAD - The share of the junior risk premium taken as protocol fee, scaled to WAD
     * @custom:field lptYieldShareProtocolFeeWAD - The share of the liquidity premium taken as protocol fee, scaled to WAD
     */
    struct ProtocolFeeConfig {
        uint64 stProtocolFeeWAD;
        uint64 jtProtocolFeeWAD;
        uint64 jtYieldShareProtocolFeeWAD;
        uint64 lptYieldShareProtocolFeeWAD;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DECLARATIVE ROLE BINDINGS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice One target's selector→role map
     * @dev `selectors[i]` is bound to `roleIds[i]`, lengths must match
     * @custom:field target - The contract whose functions are being access-gated
     * @custom:field selectors - The function selectors on `target` to bind, index-aligned with `roleIds`
     * @custom:field roleIds - The role id required to call each corresponding selector, index-aligned with `selectors`
     */
    struct TargetBinding {
        address target;
        bytes4[] selectors;
        uint64[] roleIds;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // IMMUTABLE STATE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IBaseTemplate
    IRoycoFactory public immutable override(IBaseTemplate) ROYCO_FACTORY;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIGURATION STATE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The protocol fees every future market is deployed with
    ProtocolFeeConfig public protocolFeeConfig;

    /// @notice The address every future market remits its protocol fee shares to
    address public protocolFeeRecipient;

    /// @notice The junior tranche's yield distribution model instance for each registered model shape
    mapping(string ydmType => address ydm) public jtYdms;

    /// @notice The liquidity provider tranche's model instance for each registered model shape
    mapping(string ydmType => address ydm) public lptYdms;

    // ═══════════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Gates a function to be callable only by the factory this template is bound to
    modifier onlyRoycoFactory() {
        require(msg.sender == address(ROYCO_FACTORY), ONLY_ROYCO_FACTORY());
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    /// @param _factory The Royco factory this template will be registered with, and the source of the market authority
    /// @param _protocolFeeConfig The protocol fees every market this template deploys starts with
    /// @param _protocolFeeRecipient The address every market this template deploys remits its protocol fees to
    /// @dev Both configuration values run through the same internal setters the admin path uses, so construction and
    ///      mutation can never validate differently
    constructor(
        IRoycoFactory _factory,
        ProtocolFeeConfig memory _protocolFeeConfig,
        address _protocolFeeRecipient
    )
        AccessManaged(_resolveMarketAuthority(_factory))
    {
        ROYCO_FACTORY = _factory;
        _setProtocolFeeConfig(_protocolFeeConfig);
        _setProtocolFeeRecipient(_protocolFeeRecipient);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIGURATION ADMIN
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Sets the protocol fees every FUTURE market is deployed with
     * @param _config The new fee set, each bounded by `MAX_PROTOCOL_FEE_WAD`
     */
    function setProtocolFeeConfig(ProtocolFeeConfig calldata _config) external restricted {
        _setProtocolFeeConfig(_config);
    }

    /**
     * @notice Sets the address every FUTURE market remits its protocol fee shares to
     * @param _protocolFeeRecipient The new recipient
     */
    function setProtocolFeeRecipient(address _protocolFeeRecipient) external restricted {
        _setProtocolFeeRecipient(_protocolFeeRecipient);
    }

    /**
     * @notice Registers the junior and liquidity provider model instances for one model shape
     * @param _ydmType The model shape's name, which markets select by
     * @param _jtYdm The junior tranche's model instance for this shape
     * @param _lptYdm The liquidity provider tranche's model instance for this shape
     */
    function setYieldDistributionModels(string calldata _ydmType, address _jtYdm, address _lptYdm) external restricted {
        require(bytes(_ydmType).length != 0, INVALID_YDM_TYPE());
        require(_jtYdm != address(0) && _lptYdm != address(0), IRoycoAuth.NULL_ADDRESS());
        require(_jtYdm != _lptYdm, YIELD_DISTRIBUTION_MODELS_NOT_DISTINCT());

        jtYdms[_ydmType] = _jtYdm;
        lptYdms[_ydmType] = _lptYdm;
        emit YieldDistributionModelsRegistered(_ydmType, _jtYdm, _lptYdm);
    }

    /**
     * @notice Returns the junior tranche's yield distribution model instance for a shape
     * @param _ydmType The model shape the market selected
     * @return ydm The junior tranche model instance this template deploys markets against
     */
    function jtYdmFor(string memory _ydmType) public view returns (address ydm) {
        ydm = jtYdms[_ydmType];
        require(ydm != address(0), YDM_NOT_REGISTERED(_ydmType));
    }

    /**
     * @notice Returns the liquidity provider tranche's yield distribution model instance for a shape
     * @param _ydmType The model shape the market selected
     * @return ydm The liquidity provider tranche model instance this template deploys markets against
     */
    function lptYdmFor(string memory _ydmType) public view returns (address ydm) {
        ydm = lptYdms[_ydmType];
        require(ydm != address(0), YDM_NOT_REGISTERED(_ydmType));
    }

    /// @dev The one place the fee set is validated and written, shared by construction and the admin setter
    function _setProtocolFeeConfig(ProtocolFeeConfig memory _config) internal {
        require(
            _config.stProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD && _config.jtProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD
                && _config.jtYieldShareProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD && _config.lptYieldShareProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD,
            INVALID_PROTOCOL_FEE_CONFIG()
        );
        protocolFeeConfig = _config;
        emit ProtocolFeeConfigUpdated(_config);
    }

    /// @dev The one place the recipient is validated and written, shared by construction and the admin setter
    function _setProtocolFeeRecipient(address _protocolFeeRecipient) internal {
        require(_protocolFeeRecipient != address(0), IRoycoAuth.NULL_ADDRESS());
        protocolFeeRecipient = _protocolFeeRecipient;
        emit ProtocolFeeRecipientUpdated(_protocolFeeRecipient);
    }

    /// @inheritdoc IRoycoProtocolTemplate
    function postMarketRegistration(DeploymentResult calldata _result, bytes calldata _params) external override(IRoycoProtocolTemplate) onlyRoycoFactory {
        _postMarketRegistration(_result, _params);
    }

    /**
     * @notice Configures pre-deployed periphery singletons for a just-deployed market.
     * @param _result The market's deployment result, as returned by `deployMarket`
     * @param _params The same ABI-encoded template-specific params passed to `deployMarket`
     */
    function _postMarketRegistration(DeploymentResult calldata _result, bytes calldata _params) internal virtual;

    // ═══════════════════════════════════════════════════════════════════════════
    // SALT DERIVATION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Per-market component salt, same `(marketId, componentTag)` always produces the
     *         same address regardless of template
     * @param _baseSalt The base salt for the market
     * @param _componentTag E.g. `bytes32("ST")`, `bytes32("JT")`, `bytes32("KERNEL")`,
     *        `bytes32("ACCOUNTANT")`, `bytes32("BALANCER_HOOK")`
     */
    function _marketComponentSalt(bytes32 _baseSalt, bytes32 _componentTag) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("ROYCO_MARKET_", _baseSalt, _componentTag));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys a beacon proxy reading from `_beacon` with `_initData`, via the factory's active-template primitive
    /// @dev Reverts if a contract already exists at the CREATE3 address, every market proxy must be a fresh deployment
    function _deployProxy(address _beacon, bytes memory _initData, bytes32 _salt) internal returns (address proxy) {
        bool alreadyDeployed;
        (proxy, alreadyDeployed) = ROYCO_FACTORY.deployDeterministicProxyFromTemplate(_beacon, _initData, _salt);
        require(!alreadyDeployed, MARKET_COMPONENT_ALREADY_DEPLOYED(proxy, _salt));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INIT DATA BUILDERS (standard Constants)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Builds `initialize(...)` calldata for a tranche proxy from the deployer's params
     * @param _params The tranche's deployer-supplied params
     * @param _kernel The market's kernel, which the tranche routes every operation through
     * @param _asset The tranche's underlying asset
     */
    function _encodeTrancheInitData(TrancheDeploymentParams memory _params, address _kernel, address _asset) internal view returns (bytes memory) {
        return abi.encodeCall(
            RoycoSeniorTranche.initialize,
            (IRoycoVaultTranche.RoycoTrancheInitParams({
                    name: _params.name, symbol: _params.symbol, initialAuthority: ROYCO_FACTORY.ROYCO_AUTHORITY(), kernel: _kernel, asset: _asset
                }))
        );
    }

    /**
     * @notice Builds `initialize(...)` calldata for an accountant proxy from the deployer's params
     * @param _params The accountant's deployer-supplied params
     * @param _kernel The market's kernel, the only caller permitted to drive the accountant's synchronization
     * @param _jtYdm The JT YDM (risk-premium model) instance
     * @param _lptYdm The LPT YDM (liquidity-premium model / LDM) instance, a distinct instance from `_jtYdm`
     */
    function _encodeAccountantInitData(
        AccountantDeploymentParams memory _params,
        address _kernel,
        address _jtYdm,
        address _lptYdm
    )
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(
            RoycoDayAccountant.initialize,
            (IRoycoDayAccountant.RoycoDayAccountantInitParams({
                    kernel: _kernel,
                    initialAuthority: ROYCO_FACTORY.ROYCO_AUTHORITY(),
                    fixedTermGracePeriodSeconds: _params.fixedTermGracePeriodSeconds,
                    minCoverageWAD: _params.minCoverageWAD,
                    coverageLiquidationUtilizationWAD: _params.coverageLiquidationUtilizationWAD,
                    minLiquidityWAD: _params.minLiquidityWAD,
                    jtYDM: _jtYdm,
                    jtYDMInitializationData: _params.jtYDMInitializationData,
                    lptYDM: _lptYdm,
                    lptYDMInitializationData: _params.lptYDMInitializationData,
                    maxJTYieldShareWAD: _params.maxJTYieldShareWAD,
                    maxLPTYieldShareWAD: _params.maxLPTYieldShareWAD,
                    fixedTermDurationSeconds: _params.fixedTermDurationSeconds,
                    dustTolerance: _params.dustTolerance,
                    stProtocolFeeWAD: protocolFeeConfig.stProtocolFeeWAD,
                    jtProtocolFeeWAD: protocolFeeConfig.jtProtocolFeeWAD,
                    jtYieldShareProtocolFeeWAD: protocolFeeConfig.jtYieldShareProtocolFeeWAD,
                    lptYieldShareProtocolFeeWAD: protocolFeeConfig.lptYieldShareProtocolFeeWAD
                }))
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ROLE BINDING APPLICATION
    // ═══════════════════════════════════════════════════════════════════════════

    ///  @notice Applies every binding in `_bindings` by calling back into the factory
    function _applyRoleBindings(TargetBinding[] memory _targetBindings) internal {
        uint256 numTargets = _targetBindings.length;
        for (uint256 i; i < numTargets; ++i) {
            TargetBinding memory binding = _targetBindings[i];
            uint256 numSelectors = binding.selectors.length;
            require(numSelectors == binding.roleIds.length, LENGTH_MISMATCH());
            if (numSelectors == 0) continue;
            ROYCO_FACTORY.setMarketTargetFunctionRole(binding.target, binding.selectors, binding.roleIds);
        }
    }
}
