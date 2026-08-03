// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { BaseDeploymentTemplate } from "../../src/factory/templates/base/BaseDeploymentTemplate.sol";
import { IRoycoDayEntryPoint } from "../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoFactory } from "../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../src/interfaces/factory/IRoycoProtocolTemplate.sol";

/**
 * @title MockMarketRegistrationTemplate
 * @notice Minimal concrete template over the REAL BaseDeploymentTemplate: deployMarket returns a canned result naming
 *         externally deployed market components, and the post-registration hook drives the queued periphery
 *         configuration through the factory's real `configureMarketPeriphery` primitive into the gatekeeper
 * @dev Only deployMarket is canned: registration, the active-template window, and the whole periphery path through
 *      the factory and gatekeeper are the production code paths. The market components themselves are deployed by the
 *      fixture (as production deploys implementations externally), which is why the result is injectable
 */
contract MockMarketRegistrationTemplate is BaseDeploymentTemplate {
    /// @dev The canned result deployMarket returns, set by the fixture before executeMarketDeployment
    IRoycoProtocolTemplate.DeploymentResult private _result;

    /// @dev Tranches queued for entry point configuration in the post-registration hook, cleared after application
    address[] private _queuedTranches;

    /// @dev Entry point configs paired index-aligned with `_queuedTranches`, cleared after application
    IRoycoDayEntryPoint.TrancheConfig[] private _queuedConfigs;

    /// @dev When set, the hook registers the result's kernel on the syncer, cleared after application
    bool private _kernelRegistrationQueued;

    /// @param _factory The Royco factory this template will be registered with
    /// @dev The entry point and syncer are pinned by the gatekeeper, not by a template
    constructor(IRoycoFactory _factory) BaseDeploymentTemplate(_factory) { }

    /// @notice Sets the DeploymentResult the next deployMarket call returns
    /// @param _cannedResult The externally deployed component set to hand back to the factory
    function setDeploymentResult(IRoycoProtocolTemplate.DeploymentResult calldata _cannedResult) external {
        _result = _cannedResult;
    }

    /// @notice Queues tranche configs for the next deployment's post-registration hook to apply via the real mixin
    /// @param _tranches The tranches to configure, a zero address marks an absent tranche the mixin must drop
    /// @param _configs The entry point configuration for each tranche, index-aligned with `_tranches`
    function queueTrancheConfigs(address[] calldata _tranches, IRoycoDayEntryPoint.TrancheConfig[] calldata _configs) external {
        delete _queuedTranches;
        delete _queuedConfigs;
        for (uint256 i = 0; i < _tranches.length; ++i) {
            _queuedTranches.push(_tranches[i]);
            _queuedConfigs.push(_configs[i]);
        }
    }

    /// @notice Queues the result kernel's syncer registration for the next deployment's post-registration hook
    function queueKernelRegistrationOnSyncer() external {
        _kernelRegistrationQueued = true;
    }

    /// @inheritdoc IRoycoProtocolTemplate
    /// @dev Ignores its params and returns the canned result, the components are externally deployed
    function deployMarket(bytes calldata)
        external
        view
        override(IRoycoProtocolTemplate)
        onlyRoycoFactory
        returns (IRoycoProtocolTemplate.DeploymentResult memory result)
    {
        result = _result;
    }

    /// @inheritdoc BaseDeploymentTemplate
    /// @dev Drives whatever was queued through the real factory primitive, mirroring the production hook
    function _postMarketRegistration(IRoycoProtocolTemplate.DeploymentResult calldata _deployedResult, bytes calldata) internal override(BaseDeploymentTemplate) {
        if (_queuedTranches.length == 0 && !_kernelRegistrationQueued) return;
        ROYCO_FACTORY.configureMarketPeriphery(_queuedTranches, _queuedConfigs, _deployedResult.kernel);
        delete _queuedTranches;
        delete _queuedConfigs;
        _kernelRegistrationQueued = false;
    }
}
