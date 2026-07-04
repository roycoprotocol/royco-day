// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Initializable } from "../../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import { SSTORE2 } from "../../../../lib/solady/src/utils/SSTORE2.sol";
import { RoycoDayAccountant } from "../../../accountant/RoycoDayAccountant.sol";
import { IRoycoDayAccountant } from "../../../interfaces/IRoycoDayAccountant.sol";
import { IRoycoVaultTranche } from "../../../interfaces/IRoycoVaultTranche.sol";
import { IBaseTemplate } from "../../../interfaces/factory/IBaseTemplate.sol";
import { IRoycoFactory } from "../../../interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../../interfaces/factory/IRoycoProtocolTemplate.sol";
import { RoycoSeniorTranche } from "../../../tranches/RoycoSeniorTranche.sol";
import {
    COMPONENT_ID_ACCOUNTANT_IMPL,
    COMPONENT_ID_JUNIOR_TRANCHE_IMPL,
    COMPONENT_ID_LIQUIDITY_TRANCHE_IMPL,
    COMPONENT_ID_SENIOR_TRANCHE_IMPL,
    COMPONENT_ID_YDM_ADAPTIVE_CURVE_V2
} from "./Components.sol";

/**
 * @title BaseDeploymentTemplate
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Abstract base every Royco protocol template inherits from. Standardizes:
 *           - Component param shapes (ST / JT / Accountant / YDM) so concrete templates
 *             share a vocabulary for the bits that don't vary across recipes.
 *           - SSTORE2-backed bytecode storage loaded once via factory-driven `initialize`.
 *           - Salt-derivation helper (`_marketComponentSalt`).
 *           - Internal deployment helpers that call back into the factory's primitives.
 *           - A declarative role-bindings struct + a generic `_applyRoleBindings` loop.
 */
abstract contract BaseDeploymentTemplate is Initializable, IBaseTemplate {
    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Thrown when a market component (everything except YDM) was already deployed at
     *         its CREATE3 address — signals a `marketId` collision that would re-use the
     *         pre-existing contract instead of producing a fresh market.
     */
    error MARKET_COMPONENT_ALREADY_DEPLOYED(address deployedAt, bytes32 salt);

    // ═══════════════════════════════════════════════════════════════════════════
    // DECLARATIVE ROLE BINDINGS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice One target's selector→role map.
     * @dev `selectors[i]` is bound to `roleIds[i]`. Lengths must match.
     * @custom:field target - The contract whose functions are being access-gated.
     * @custom:field selectors - The function selectors on `target` to bind, index-aligned with `roleIds`.
     * @custom:field roleIds - The role id required to call each corresponding selector, index-aligned with `selectors`.
     */
    struct TargetBinding {
        address target;
        bytes4[] selectors;
        uint64[] roleIds;
    }

    /**
     * @notice A role grant applied after deployment (e.g. SYNC_ROLE → accountant).
     * @custom:field roleId - The role id to grant.
     * @custom:field account - The account receiving the role.
     * @custom:field executionDelay - The access-manager execution delay in seconds applied to the grant.
     */
    struct RoleGrant {
        uint64 roleId;
        address account;
        uint32 executionDelay;
    }

    /**
     * @notice The full role-wiring config a template applies via `_applyRoleBindings`.
     * @custom:field targetBindings - The per-target selector→role maps to install.
     * @custom:field postInitGrants - The role grants to apply after deployment and initialization.
     */
    struct RoleBindings {
        TargetBinding[] targetBindings;
        RoleGrant[] postInitGrants;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // IMMUTABLE STATE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IBaseTemplate
    IRoycoFactory public immutable override(IBaseTemplate) ROYCO_FACTORY;

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev SSTORE2 pointer table — one pointer per component ID, set during `initialize`.
    mapping(bytes32 componentId => address sstore2Pointer) private _bytecodePointers;

    // ═══════════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Gates a function to be callable only by the factory this template is bound to.
    modifier onlyRoycoFactory() {
        require(msg.sender == address(ROYCO_FACTORY), ONLY_ROYCO_FACTORY());
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR + INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @param _factory The Royco factory this template will be registered with.
    constructor(IRoycoFactory _factory) {
        require(address(_factory) != address(0), ROYCO_FACTORY_CANNOT_BE_ZERO_ADDRESS());
        ROYCO_FACTORY = _factory;
    }

    /// @inheritdoc IRoycoProtocolTemplate
    function initialize(bytes32[] calldata _componentIds, bytes[] calldata _creationCodes) external override(IRoycoProtocolTemplate) initializer {
        require(_componentIds.length == _creationCodes.length, LENGTH_MISMATCH());

        uint256 n = _componentIds.length;
        for (uint256 i; i < n; ++i) {
            bytes32 id = _componentIds[i];
            require(_bytecodePointers[id] == address(0), CREATION_CODE_ALREADY_SET(id));
            require(_creationCodes[i].length > 0, CREATION_CODE_CANNOT_BE_EMPTY(id));
            _bytecodePointers[id] = SSTORE2.write(_creationCodes[i]);
        }
    }

    /// @inheritdoc IBaseTemplate
    function bytecodePointer(bytes32 _componentId) external view override(IBaseTemplate) returns (address) {
        return _bytecodePointers[_componentId];
    }

    /// @inheritdoc IBaseTemplate
    function isInitialized() external view override(IBaseTemplate) returns (bool) {
        return _getInitializedVersion() > 0;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SALT DERIVATION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Per-market component salt. Same `(marketId, componentTag)` always produces the
     *         same address regardless of template.
     * @param _marketId Caller-supplied stable identifier for the market.
     * @param _componentTag E.g. `bytes32("ST")`, `bytes32("JT")`, `bytes32("KERNEL")`,
     *        `bytes32("ACCOUNTANT")`, `bytes32("HOOKS")`.
     */
    function _marketComponentSalt(bytes32 _marketId, bytes32 _componentTag) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("ROYCO_MARKET_", _marketId, _componentTag));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Reads a previously-loaded creation code via SSTORE2.
    function _readCreationCode(bytes32 _componentId) internal view returns (bytes memory) {
        address ptr = _bytecodePointers[_componentId];
        require(ptr != address(0), CREATION_CODE_NOT_SET(_componentId));
        return SSTORE2.read(ptr);
    }

    /**
     * @notice Deploys an impl whose creation code lives at `_componentId`, with no constructor args.
     * @dev Reverts if a contract already exists at the CREATE3 address — every market component
     *      must be a fresh deployment. The YDM is the only exception and uses `_deployYDM`.
     */
    function _deployImpl(bytes32 _componentId, bytes32 _salt) internal returns (address impl) {
        return _deployImpl(_componentId, "", _salt);
    }

    /// @notice Deploys an impl whose creation code lives at `_componentId`, with ABI-encoded constructor args appended.
    /// @dev Reverts if a contract already exists at the CREATE3 address.
    function _deployImpl(bytes32 _componentId, bytes memory _ctorArgs, bytes32 _salt) internal returns (address impl) {
        bytes memory creationCode = abi.encodePacked(_readCreationCode(_componentId), _ctorArgs);
        bool alreadyDeployed;
        (impl, alreadyDeployed) = ROYCO_FACTORY.deployDeterministicContract(creationCode, _salt);
        require(!alreadyDeployed, MARKET_COMPONENT_ALREADY_DEPLOYED(impl, _salt));
    }

    /// @notice Deploys an ERC1967 proxy pointing at `_impl` with `_initData`.
    /// @dev Reverts if a contract already exists at the CREATE3 address.
    function _deployProxy(address _impl, bytes memory _initData, bytes32 _salt) internal returns (address proxy) {
        bool alreadyDeployed;
        (proxy, alreadyDeployed) = ROYCO_FACTORY.deployDeterministicProxy(_impl, _initData, _salt);
        require(!alreadyDeployed, MARKET_COMPONENT_ALREADY_DEPLOYED(proxy, _salt));
    }

    /**
     * @notice Deploys an adaptive-curve YDM instance at the caller-supplied salt, pinning its target utilization (the curve kink).
     * @dev The registered creation code is the bare `AdaptiveCurveYDM_V2` bytecode; the target utilization is a constructor arg
     *      appended here (per market), rather than baked into the registered creation code.
     * @param _salt The CREATE3 salt for this YDM instance
     * @param _targetUtilizationWAD The utilization at which the YDM curve's "target" yield share applies, scaled to WAD
     */
    function _deployYDM(bytes32 _salt, uint256 _targetUtilizationWAD) internal returns (address ydm, bool alreadyDeployed) {
        bytes memory creationCode = _readCreationCode(COMPONENT_ID_YDM_ADAPTIVE_CURVE_V2);
        (ydm, alreadyDeployed) = ROYCO_FACTORY.deployDeterministicContract(abi.encodePacked(creationCode, abi.encode(_targetUtilizationWAD)), _salt);
    }

    /// @notice Deploys the senior-tranche impl, pinning its (asset, kernel) immutables.
    function _deploySeniorTrancheImpl(address _asset, address _kernel, bytes32 _salt) internal returns (address impl) {
        return _deployImpl(COMPONENT_ID_SENIOR_TRANCHE_IMPL, abi.encode(_asset, _kernel), _salt);
    }

    /// @notice Deploys the junior-tranche impl, pinning its (asset, kernel) immutables.
    function _deployJuniorTrancheImpl(address _asset, address _kernel, bytes32 _salt) internal returns (address impl) {
        return _deployImpl(COMPONENT_ID_JUNIOR_TRANCHE_IMPL, abi.encode(_asset, _kernel), _salt);
    }

    /// @notice Deploys the liquidity-tranche impl, pinning its (asset, kernel) immutables.
    function _deployLiquidityTrancheImpl(address _asset, address _kernel, bytes32 _salt) internal returns (address impl) {
        return _deployImpl(COMPONENT_ID_LIQUIDITY_TRANCHE_IMPL, abi.encode(_asset, _kernel), _salt);
    }

    /// @notice Deploys the accountant impl for a given kernel and the junior tranche's fixed co-investment configuration.
    function _deployAccountantImpl(address _kernel, bool _jtCoinvested, bytes32 _salt) internal returns (address impl) {
        return _deployImpl(COMPONENT_ID_ACCOUNTANT_IMPL, abi.encode(_kernel, _jtCoinvested), _salt);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INIT DATA BUILDERS (standard components)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Builds `initialize(...)` calldata for a tranche proxy from its canonical init params, forcing the market authority.
    /// @dev The caller-supplied `initialAuthority` is ignored/overwritten — the market's authority is always the factory's authority.
    function _encodeTrancheInitData(IRoycoVaultTranche.RoycoTrancheInitParams memory _params) internal view returns (bytes memory) {
        _params.initialAuthority = ROYCO_FACTORY.ROYCO_AUTHORITY();
        return abi.encodeCall(RoycoSeniorTranche.initialize, (_params));
    }

    /**
     * @notice Builds `initialize(...)` calldata for an accountant proxy from its canonical init params.
     * @dev The caller supplies the full accountant configuration (including both the JT and LT YDM initialization data, so
     *      both YDMs are initialized); the template injects only the deployment-derived YDM addresses and the market authority.
     * @param _params The accountant's canonical init params (its `jtYDM`/`ltYDM` fields are overwritten with the deployed instances).
     * @param _jtYdm The JT YDM (risk-premium model) instance.
     * @param _ltYdm The LT YDM (liquidity-premium model / LDM) instance; a distinct instance from `_jtYdm`.
     */
    function _encodeAccountantInitData(
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory _params,
        address _jtYdm,
        address _ltYdm
    )
        internal
        view
        returns (bytes memory)
    {
        _params.jtYDM = _jtYdm;
        _params.ltYDM = _ltYdm;
        return abi.encodeCall(RoycoDayAccountant.initialize, (_params, ROYCO_FACTORY.ROYCO_AUTHORITY()));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ROLE BINDING APPLICATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Applies every binding in `_bindings` by calling back into the factory.
    function _applyRoleBindings(RoleBindings memory _bindings) internal {
        // Go through each target binding and apply the selectors to the target.
        uint256 nTargets = _bindings.targetBindings.length;
        for (uint256 i; i < nTargets; ++i) {
            TargetBinding memory tb = _bindings.targetBindings[i];
            require(tb.selectors.length == tb.roleIds.length, LENGTH_MISMATCH());
            uint256 m = tb.selectors.length;
            for (uint256 j; j < m; ++j) {
                ROYCO_FACTORY.setMarketTargetFunctionRole(tb.target, tb.selectors[j], tb.roleIds[j]);
            }
        }

        // Go through each post-init grant and apply the role to the account.
        uint256 nGrants = _bindings.postInitGrants.length;
        for (uint256 i; i < nGrants; ++i) {
            RoleGrant memory g = _bindings.postInitGrants[i];
            ROYCO_FACTORY.grantMarketRole(g.roleId, g.account, g.executionDelay);
        }
    }
}
