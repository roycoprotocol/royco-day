// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { BaseDeploymentTemplate } from "../../src/factory/templates/base/BaseDeploymentTemplate.sol";
import { EntryPointConfigurer } from "../../src/factory/templates/periphery/EntryPointConfigurer.sol";
import { MarketSyncerConfigurer } from "../../src/factory/templates/periphery/MarketSyncerConfigurer.sol";
import { IRoycoDayEntryPoint } from "../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoFactory } from "../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../src/interfaces/factory/IRoycoProtocolTemplate.sol";

/**
 * @title MockMarketRegistrationTemplate
 * @notice Minimal concrete template over the REAL BaseDeploymentTemplate + EntryPointConfigurer + MarketSyncerConfigurer:
 *         deployMarket returns a canned result naming externally deployed market components, and the post-registration
 *         hook applies queued entry point configs and a queued syncer registration through the real mixins
 * @dev Only deployMarket is canned: registration, the active-template window, the periphery mixins, and every
 *      factory-forwarded call are the production code paths. The market components themselves are deployed by the
 *      fixture (as production deploys implementations externally), which is why the result is injectable
 */
contract MockMarketRegistrationTemplate is BaseDeploymentTemplate, EntryPointConfigurer, MarketSyncerConfigurer {
    /// @dev The canned result deployMarket returns, set by the fixture before executeMarketDeployment
    IRoycoProtocolTemplate.DeploymentResult private _result;

    /// @dev Tranches queued for entry point configuration in the post-registration hook, cleared after application
    address[] private _queuedTranches;

    /// @dev Entry point configs paired index-aligned with `_queuedTranches`, cleared after application
    IRoycoDayEntryPoint.TrancheConfig[] private _queuedConfigs;

    /// @dev When set, the hook registers the result's kernel on the syncer, cleared after application
    bool private _kernelRegistrationQueued;

    /// @param _factory The Royco factory this template will be registered with
    /// @param _entryPoint The pre-deployed entry point singleton, must be bound to `_factory`
    /// @param _syncer The pre-deployed market syncer singleton
    constructor(
        IRoycoFactory _factory,
        address _entryPoint,
        address _syncer
    )
        BaseDeploymentTemplate(_factory)
        EntryPointConfigurer(_entryPoint, _factory)
        MarketSyncerConfigurer(_syncer)
    { }

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
    /// @dev Applies whatever was queued through the real periphery mixins, mirroring the production hook order
    function _postMarketRegistration(IRoycoProtocolTemplate.DeploymentResult calldata _deployedResult, bytes calldata) internal override(BaseDeploymentTemplate) {
        if (_queuedTranches.length > 0) {
            _configureEntryPointTrancheConfigs(ROYCO_FACTORY, _queuedTranches, _queuedConfigs);
            delete _queuedTranches;
            delete _queuedConfigs;
        }
        if (_kernelRegistrationQueued) {
            _registerMarketKernelOnSyncer(ROYCO_FACTORY, _deployedResult.kernel);
            _kernelRegistrationQueued = false;
        }
    }
}
