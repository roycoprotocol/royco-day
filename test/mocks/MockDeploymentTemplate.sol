// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { BaseDeploymentTemplate } from "../../src/factory/templates/base/BaseDeploymentTemplate.sol";
import { IRoycoFactory } from "../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../src/interfaces/factory/IRoycoProtocolTemplate.sol";

/**
 * @title MockDeploymentTemplate
 * @notice Minimal concrete deployment template bound to a real RoycoFactory: deployMarket returns a caller-settable
 *         DeploymentResult so tests can hand the factory arbitrary component sets (including zero tranche members)
 */
contract MockDeploymentTemplate is BaseDeploymentTemplate {
    /// @dev The canned result deployMarket returns, set by the test before executeMarketDeployment
    IRoycoProtocolTemplate.DeploymentResult private _result;

    /// @notice Binds the template to the factory that will drive it
    /// @param _factory The Royco factory this template will be registered with
    constructor(IRoycoFactory _factory) BaseDeploymentTemplate(_factory) { }

    /// @notice Sets the DeploymentResult the next deployMarket call returns
    /// @param _cannedResult The component set to hand back to the factory
    function setDeploymentResult(IRoycoProtocolTemplate.DeploymentResult calldata _cannedResult) external {
        _result = _cannedResult;
    }

    /// @inheritdoc IRoycoProtocolTemplate
    /// @dev Ignores its params and returns the canned result
    function deployMarket(bytes calldata)
        external
        override(IRoycoProtocolTemplate)
        onlyRoycoFactory
        returns (IRoycoProtocolTemplate.DeploymentResult memory result)
    {
        result = _result;
    }

    /// @inheritdoc BaseDeploymentTemplate
    /// @dev No periphery to configure for the canned-result mock
    function _postMarketRegistration(IRoycoProtocolTemplate.DeploymentResult calldata, bytes calldata) internal override(BaseDeploymentTemplate) { }
}
