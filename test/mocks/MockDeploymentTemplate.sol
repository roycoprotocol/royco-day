// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { BaseDeploymentTemplate } from "../../src/factory/templates/base/BaseDeploymentTemplate.sol";
import { IRoycoFactory } from "../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../src/interfaces/factory/IRoycoProtocolTemplate.sol";

/**
 * @title MockDeploymentTemplate
 * @notice Minimal concrete deployment template bound to a real RoycoFactory: deployMarket returns a caller-settable
 *         DeploymentResult so tests can hand the factory arbitrary component sets (including zero tranche members)
 * @dev When deployMarket receives nonempty params it decodes (bytes32 salt, uint256 targetUtilizationWAD) and drives
 *      the base's internal _deployYDM helper inside the factory's active-template window, recording the outcome, so
 *      tests can exercise the YDM salt-reuse path through the production entrypoint
 */
contract MockDeploymentTemplate is BaseDeploymentTemplate {
    /// @dev The canned result deployMarket returns, set by the test before executeMarketDeployment
    IRoycoProtocolTemplate.DeploymentResult private _result;

    /// @notice The YDM address returned by the last params-driven _deployYDM call
    address public lastDeployedYDM;

    /// @notice Whether the last params-driven _deployYDM call reused an instance already deployed at the salt
    bool public lastYDMAlreadyDeployed;

    /// @notice Binds the template to the factory that will drive it
    /// @param _factory The Royco factory this template will be registered with
    constructor(IRoycoFactory _factory) BaseDeploymentTemplate(_factory) { }

    /// @notice Sets the DeploymentResult the next deployMarket call returns
    /// @param _cannedResult The component set to hand back to the factory
    function setDeploymentResult(IRoycoProtocolTemplate.DeploymentResult calldata _cannedResult) external {
        _result = _cannedResult;
    }

    /// @inheritdoc IRoycoProtocolTemplate
    /// @dev Nonempty params decode as (bytes32 salt, uint256 targetUtilizationWAD) and drive _deployYDM before returning the canned result
    function deployMarket(bytes calldata _params)
        external
        override(IRoycoProtocolTemplate)
        onlyRoycoFactory
        returns (IRoycoProtocolTemplate.DeploymentResult memory result)
    {
        if (_params.length != 0) {
            (bytes32 salt, uint256 targetUtilizationWAD) = abi.decode(_params, (bytes32, uint256));
            (lastDeployedYDM, lastYDMAlreadyDeployed) = _deployYDM(salt, targetUtilizationWAD);
        }
        result = _result;
    }
}
