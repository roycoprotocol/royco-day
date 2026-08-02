// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { BaseDeploymentTemplate } from "../../src/factory/templates/base/BaseDeploymentTemplate.sol";
import { IRoycoFactory } from "../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../src/interfaces/factory/IRoycoProtocolTemplate.sol";

/**
 * @title MockPrimitivesProbeTemplate
 * @notice A concrete deployment template that drives one configured factory primitive from inside its own
 *         active-template window: proxy deployment via the real `_deployProxy` helper, role-bindings application via
 *         the real `_applyRoleBindings` loop, an arbitrary `executeAsFactory` call, or the same call attempted
 *         through a PEER template that is not the active one
 */
contract MockPrimitivesProbeTemplate is BaseDeploymentTemplate {
    /// @notice What the template does inside its deployment window
    enum ProbeAction {
        NONE,
        DEPLOY_PROXY,
        DEPLOY_PROXY_HELPER_TWICE,
        DEPLOY_PROXY_DIRECT_TWICE,
        APPLY_ROLE_BINDINGS,
        EXEC_AS_FACTORY,
        CALL_PEER
    }

    /// @dev The canned result deployMarket returns
    IRoycoProtocolTemplate.DeploymentResult private _result;

    /// @notice The action the next deployment window performs
    ProbeAction public action;

    /// @notice The beacon proxy deployments read their implementation through
    address public proxyBeacon;

    /// @notice The CREATE3 salt for proxy deployments
    bytes32 public proxySalt;

    /// @notice ABI-encoded RoleBindings for the APPLY_ROLE_BINDINGS action
    bytes public encodedRoleBindings;

    /// @notice The target for the EXEC_AS_FACTORY and CALL_PEER actions
    address public execTarget;

    /// @notice The calldata for the EXEC_AS_FACTORY and CALL_PEER actions
    bytes public execData;

    /// @notice The peer template the CALL_PEER action routes through
    MockPrimitivesProbeTemplate public peer;

    /// @notice The proxy the last successful DEPLOY_PROXY-family action produced
    address public lastDeployedProxy;

    /// @notice Whether the second direct deployment reported the proxy as already deployed
    bool public lastAlreadyDeployed;

    constructor(IRoycoFactory _factory) BaseDeploymentTemplate(_factory) { }

    function setDeploymentResult(IRoycoProtocolTemplate.DeploymentResult calldata _cannedResult) external {
        _result = _cannedResult;
    }

    function setAction(ProbeAction _action) external {
        action = _action;
    }

    function setProxyConfig(address _beacon, bytes32 _salt) external {
        proxyBeacon = _beacon;
        proxySalt = _salt;
    }

    /// @notice Sets the RoleBindings for APPLY_ROLE_BINDINGS, passed ABI-encoded so the fixture builds them in memory
    function setEncodedRoleBindings(bytes calldata _encodedRoleBindings) external {
        encodedRoleBindings = _encodedRoleBindings;
    }

    function setExecConfig(address _target, bytes calldata _data) external {
        execTarget = _target;
        execData = _data;
    }

    function setPeer(MockPrimitivesProbeTemplate _peer) external {
        peer = _peer;
    }

    /// @notice Calls the factory's executeAsFactory as THIS template, used as the peer leg of CALL_PEER
    /// @dev When this template is not the active one the factory must reject the call
    function attemptExecuteAsFactory(address _target, bytes calldata _data) external returns (bytes memory) {
        return ROYCO_FACTORY.executeAsFactory(_target, _data);
    }

    /// @inheritdoc IRoycoProtocolTemplate
    function deployMarket(bytes calldata)
        external
        override(IRoycoProtocolTemplate)
        onlyRoycoFactory
        returns (IRoycoProtocolTemplate.DeploymentResult memory result)
    {
        if (action == ProbeAction.DEPLOY_PROXY) {
            lastDeployedProxy = _deployProxy(proxyBeacon, "", proxySalt);
        } else if (action == ProbeAction.DEPLOY_PROXY_HELPER_TWICE) {
            // The helper's freshness rule must convert the second deployment into MARKET_COMPONENT_ALREADY_DEPLOYED
            _deployProxy(proxyBeacon, "", proxySalt);
            _deployProxy(proxyBeacon, "", proxySalt);
        } else if (action == ProbeAction.DEPLOY_PROXY_DIRECT_TWICE) {
            // The raw factory primitive reports an existing proxy instead of reverting
            (lastDeployedProxy,) = ROYCO_FACTORY.deployDeterministicProxyFromTemplate(proxyBeacon, "", proxySalt);
            (lastDeployedProxy, lastAlreadyDeployed) = ROYCO_FACTORY.deployDeterministicProxyFromTemplate(proxyBeacon, "", proxySalt);
        } else if (action == ProbeAction.APPLY_ROLE_BINDINGS) {
            _applyRoleBindings(abi.decode(encodedRoleBindings, (RoleBindings)));
        } else if (action == ProbeAction.EXEC_AS_FACTORY) {
            ROYCO_FACTORY.executeAsFactory(execTarget, execData);
        } else if (action == ProbeAction.CALL_PEER) {
            peer.attemptExecuteAsFactory(execTarget, execData);
        }
        result = _result;
    }

    /// @inheritdoc BaseDeploymentTemplate
    function _postMarketRegistration(IRoycoProtocolTemplate.DeploymentResult calldata, bytes calldata) internal override(BaseDeploymentTemplate) { }
}
