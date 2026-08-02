// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { BaseDeploymentTemplate } from "../../src/factory/templates/base/BaseDeploymentTemplate.sol";
import { IRoycoFactory } from "../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../src/interfaces/factory/IRoycoProtocolTemplate.sol";

/**
 * @title MockDeployerProbeTemplate
 * @notice A concrete deployment template that records the factory's transient `marketDeployer` from inside both
 *         phases of the active-template window, and optionally pulls a seed from it exactly as the production
 *         template's `_seedPool` does, so tests can observe the transient's lifecycle mid-deployment
 */
contract MockDeployerProbeTemplate is BaseDeploymentTemplate {
    /// @notice Thrown by the hook when the probe is armed to fail, to observe the transient across an unwound deployment
    error PROBE_HOOK_REVERTED();

    /// @dev The canned result deployMarket returns
    IRoycoProtocolTemplate.DeploymentResult private _result;

    /// @notice The marketDeployer the factory reported during the deployMarket phase
    address public observedDeployerDuringDeployMarket;

    /// @notice The marketDeployer the factory reported during the postMarketRegistration phase
    address public observedDeployerDuringHook;

    /// @notice When nonzero, deployMarket pulls `seedAmount` of this asset from the factory's marketDeployer
    IERC20 public seedAsset;

    /// @notice The seed amount pulled from the marketDeployer when `seedAsset` is set
    uint256 public seedAmount;

    /// @notice When set, the post-registration hook reverts so the deployment unwinds
    bool public revertInHook;

    constructor(IRoycoFactory _factory) BaseDeploymentTemplate(_factory) { }

    function setDeploymentResult(IRoycoProtocolTemplate.DeploymentResult calldata _cannedResult) external {
        _result = _cannedResult;
    }

    function setSeed(IERC20 _seedAsset, uint256 _seedAmount) external {
        seedAsset = _seedAsset;
        seedAmount = _seedAmount;
    }

    function setRevertInHook(bool _revertInHook) external {
        revertInHook = _revertInHook;
    }

    /// @inheritdoc IRoycoProtocolTemplate
    /// @dev Records the transient marketDeployer and pulls the seed from it, never from any configured address
    function deployMarket(bytes calldata)
        external
        override(IRoycoProtocolTemplate)
        onlyRoycoFactory
        returns (IRoycoProtocolTemplate.DeploymentResult memory result)
    {
        observedDeployerDuringDeployMarket = ROYCO_FACTORY.marketDeployer();
        if (address(seedAsset) != address(0)) seedAsset.transferFrom(ROYCO_FACTORY.marketDeployer(), address(this), seedAmount);
        result = _result;
    }

    /// @inheritdoc BaseDeploymentTemplate
    /// @dev Records the transient again after the registry write, proving the binding spans the whole window
    function _postMarketRegistration(IRoycoProtocolTemplate.DeploymentResult calldata, bytes calldata) internal override(BaseDeploymentTemplate) {
        observedDeployerDuringHook = ROYCO_FACTORY.marketDeployer();
        if (revertInHook) revert PROBE_HOOK_REVERTED();
    }
}
