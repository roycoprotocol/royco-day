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
 *         `FACTORY_CALL_FAILED` / `NO_ACTIVE_TEMPLATE` revert branches off-fork (the production template exercises
 *         these only in the RPC-gated fork factory suite).
 */
contract MockWiringTemplate is BaseDeploymentTemplate {
    uint8 public constant MODE_WIRE = 0;
    uint8 public constant MODE_REENTER = 1;
    uint8 public constant MODE_EXEC_FAIL = 2;

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
            ROYCO_FACTORY.setMarketTargetFunctionRole(wireTarget, wireSelector, wireRole);
            ROYCO_FACTORY.grantMarketRole(wireRole, wireAccount, 0);
        } else if (mode == MODE_REENTER) {
            // Re-entering while this template is the active one trips the singleton guard.
            ROYCO_FACTORY.executeMarketDeployment(address(this), "");
        } else {
            // A call to a selector this contract does not implement (no fallback) reverts, so the factory's
            // executeAsFactory sees success == false and reverts FACTORY_CALL_FAILED.
            ROYCO_FACTORY.executeAsFactory(address(this), hex"deadbeef");
        }
        result = _result;
    }
}
