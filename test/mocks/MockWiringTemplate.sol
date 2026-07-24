// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { BaseDeploymentTemplate } from "../../src/factory/templates/base/BaseDeploymentTemplate.sol";
import { IRoycoFactory } from "../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../src/interfaces/factory/IRoycoProtocolTemplate.sol";

/**
 * @title MockWiringTemplate
 * @notice A concrete deployment template that, inside the factory's active-template window, drives the factory's
 *         role-wiring primitives (`setMarketTargetFunctionRole`, `grantMarketRole`, `executeAsFactory`) or a
 *         reentrant `executeMarketDeployment` — so tests can exercise the factory's success-wiring path and its
 *         verbatim-bubbling / `NO_ACTIVE_TEMPLATE` revert branches off-fork (the production template exercises
 *         these only in the RPC-gated fork factory suite).
 */
contract MockWiringTemplate is BaseDeploymentTemplate {
    uint8 public constant MODE_WIRE = 0;
    uint8 public constant MODE_REENTER = 1;
    uint8 public constant MODE_EXEC_FAIL = 2;
    uint8 public constant MODE_WIRE_IN_HOOK = 3;
    uint8 public constant MODE_EXEC_FAIL_IN_HOOK = 4;

    uint8 public mode;
    address public wireTarget;
    bytes4 public wireSelector;
    uint64 public wireRole;
    address public wireAccount;
    IRoycoProtocolTemplate.DeploymentResult private _result;

    constructor(IRoycoFactory _factory) BaseDeploymentTemplate(_factory) { }

    function setMode(uint8 _mode) external {
        mode = _mode;
    }

    function setWireConfig(address _target, bytes4 _selector, uint64 _role, address _account) external {
        wireTarget = _target;
        wireSelector = _selector;
        wireRole = _role;
        wireAccount = _account;
    }

    function setDeploymentResult(IRoycoProtocolTemplate.DeploymentResult calldata _cannedResult) external {
        _result = _cannedResult;
    }

    /// @inheritdoc IRoycoProtocolTemplate
    function deployMarket(bytes calldata)
        external
        override(IRoycoProtocolTemplate)
        onlyRoycoFactory
        returns (IRoycoProtocolTemplate.DeploymentResult memory result)
    {
        if (mode == MODE_WIRE) {
            _wireOnce();
        } else if (mode == MODE_REENTER) {
            // Re-entering while this template is the active one trips the singleton guard.
            ROYCO_FACTORY.executeMarketDeployment(address(this), "");
        } else if (mode == MODE_EXEC_FAIL) {
            // A call to a selector this contract does not implement (no fallback) reverts with empty data, which
            // executeAsFactory's dispatch bubbles verbatim.
            ROYCO_FACTORY.executeAsFactory(address(this), hex"deadbeef");
        }
        result = _result;
    }

    /// @inheritdoc BaseDeploymentTemplate
    /// @dev In the hook modes, drives the factory's primitives from the post-registration hook phase — proving the
    ///      active-template window spans `postMarketRegistration` and that hook reverts bubble out of the deployment
    function _postMarketRegistration(IRoycoProtocolTemplate.DeploymentResult calldata, bytes calldata) internal override(BaseDeploymentTemplate) {
        if (mode == MODE_WIRE_IN_HOOK) {
            _wireOnce();
        } else if (mode == MODE_EXEC_FAIL_IN_HOOK) {
            ROYCO_FACTORY.executeAsFactory(address(this), hex"deadbeef");
        }
    }

    /// @dev Drives the factory's array-based role-wiring primitives with the single configured (target, selector, role, account) tuple
    function _wireOnce() private {
        address[] memory targets = new address[](1);
        bytes4[] memory selectors = new bytes4[](1);
        uint64[] memory roleIds = new uint64[](1);
        (targets[0], selectors[0], roleIds[0]) = (wireTarget, wireSelector, wireRole);
        ROYCO_FACTORY.setMarketTargetFunctionRole(targets, selectors, roleIds);

        uint64[] memory grantRoleIds = new uint64[](1);
        address[] memory grantAccounts = new address[](1);
        uint32[] memory grantExecutionDelays = new uint32[](1);
        (grantRoleIds[0], grantAccounts[0], grantExecutionDelays[0]) = (wireRole, wireAccount, 0);
        ROYCO_FACTORY.grantMarketRole(grantRoleIds, grantAccounts, grantExecutionDelays);
    }
}
