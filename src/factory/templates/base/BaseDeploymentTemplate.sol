// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { RoycoDayAccountant } from "../../../accountant/RoycoDayAccountant.sol";
import { IRoycoDayAccountant } from "../../../interfaces/IRoycoDayAccountant.sol";
import { IRoycoVaultTranche } from "../../../interfaces/IRoycoVaultTranche.sol";
import { IBaseTemplate } from "../../../interfaces/factory/IBaseTemplate.sol";
import { IRoycoFactory } from "../../../interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../../interfaces/factory/IRoycoProtocolTemplate.sol";
import { RoycoSeniorTranche } from "../../../tranches/RoycoSeniorTranche.sol";

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
abstract contract BaseDeploymentTemplate is IBaseTemplate {
    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Thrown when a market proxy was already deployed at its CREATE3 address, signals a `marketId`
     *         collision that would re-use the pre-existing contract instead of producing a fresh market
     */
    error MARKET_COMPONENT_ALREADY_DEPLOYED(address deployedAt, bytes32 salt);

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

    /**
     * @notice A role grant applied after deployment (e.g. SYNC_ROLE → accountant)
     * @custom:field roleId - The role id to grant
     * @custom:field account - The account receiving the role
     * @custom:field executionDelay - The access-manager execution delay in seconds applied to the grant
     */
    struct RoleGrant {
        uint64 roleId;
        address account;
        uint32 executionDelay;
    }

    /**
     * @notice The full role-wiring config a template applies via `_applyRoleBindings`
     * @custom:field targetBindings - The per-target selector→role maps to install
     * @custom:field postInitGrants - The role grants to apply after deployment and initialization
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

    /// @param _factory The Royco factory this template will be registered with
    constructor(IRoycoFactory _factory) {
        require(address(_factory) != address(0), ROYCO_FACTORY_CANNOT_BE_ZERO_ADDRESS());
        ROYCO_FACTORY = _factory;
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
     * @param _marketId Caller-supplied stable identifier for the market
     * @param _componentTag E.g. `bytes32("ST")`, `bytes32("JT")`, `bytes32("KERNEL")`,
     *        `bytes32("ACCOUNTANT")`, `bytes32("BALANCER_HOOK")`
     */
    function _marketComponentSalt(bytes32 _marketId, bytes32 _componentTag) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("ROYCO_MARKET_", _marketId, _componentTag));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys an ERC1967 proxy pointing at `_impl` with `_initData`, via the factory's active-template primitive
    /// @dev Reverts if a contract already exists at the CREATE3 address, every market proxy must be a fresh deployment
    function _deployProxy(address _impl, bytes memory _initData, bytes32 _salt) internal returns (address proxy) {
        bool alreadyDeployed;
        (proxy, alreadyDeployed) = ROYCO_FACTORY.deployDeterministicProxyFromTemplate(_impl, _initData, _salt);
        require(!alreadyDeployed, MARKET_COMPONENT_ALREADY_DEPLOYED(proxy, _salt));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INIT DATA BUILDERS (standard Constants)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Builds `initialize(...)` calldata for a tranche proxy from its canonical init params, forcing the market authority
    /// @dev The caller-supplied `initialAuthority` is ignored/overwritten, the market's authority is always the factory's authority
    function _encodeTrancheInitData(IRoycoVaultTranche.RoycoTrancheInitParams memory _params) internal view returns (bytes memory) {
        _params.initialAuthority = ROYCO_FACTORY.ROYCO_AUTHORITY();
        return abi.encodeCall(RoycoSeniorTranche.initialize, (_params));
    }

    /**
     * @notice Builds `initialize(...)` calldata for an accountant proxy from its canonical init params
     * @dev The caller supplies the full accountant configuration (including both the JT and LT YDM initialization data, so
     *      both YDMs are initialized), the template injects only the deployment-derived YDM addresses and the market authority
     * @param _params The accountant's canonical init params (its `jtYDM`/`ltYDM` fields are overwritten with the deployed instances)
     * @param _jtYdm The JT YDM (risk-premium model) instance
     * @param _ltYdm The LT YDM (liquidity-premium model / LDM) instance, a distinct instance from `_jtYdm`
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

    /// @notice Applies every binding in `_bindings` by calling back into the factory
    function _applyRoleBindings(RoleBindings memory _bindings) internal {
        // Flatten every (target, selector, roleId) triple across all target bindings into index-aligned arrays, then
        // install them in a single factory call
        uint256 nTargets = _bindings.targetBindings.length;
        uint256 totalSelectors;
        for (uint256 i; i < nTargets; ++i) {
            require(_bindings.targetBindings[i].selectors.length == _bindings.targetBindings[i].roleIds.length, LENGTH_MISMATCH());
            totalSelectors += _bindings.targetBindings[i].selectors.length;
        }

        address[] memory targets = new address[](totalSelectors);
        bytes4[] memory selectors = new bytes4[](totalSelectors);
        uint64[] memory roleIds = new uint64[](totalSelectors);
        uint256 k;
        for (uint256 i; i < nTargets; ++i) {
            TargetBinding memory tb = _bindings.targetBindings[i];
            uint256 m = tb.selectors.length;
            for (uint256 j; j < m; ++j) {
                targets[k] = tb.target;
                selectors[k] = tb.selectors[j];
                roleIds[k] = tb.roleIds[j];
                ++k;
            }
        }
        ROYCO_FACTORY.setMarketTargetFunctionRole(targets, selectors, roleIds);

        // Flatten the post-init grants into index-aligned arrays and apply them in a single factory call
        uint256 nGrants = _bindings.postInitGrants.length;
        uint64[] memory grantRoleIds = new uint64[](nGrants);
        address[] memory grantAccounts = new address[](nGrants);
        uint32[] memory grantExecutionDelays = new uint32[](nGrants);
        for (uint256 i; i < nGrants; ++i) {
            RoleGrant memory g = _bindings.postInitGrants[i];
            grantRoleIds[i] = g.roleId;
            grantAccounts[i] = g.account;
            grantExecutionDelays[i] = g.executionDelay;
        }
        ROYCO_FACTORY.grantMarketRole(grantRoleIds, grantAccounts, grantExecutionDelays);
    }
}
