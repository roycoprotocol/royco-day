// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { DeployScriptBase } from "../../core/DeployScriptBase.sol";
import { YDMLib } from "../../utils/YDMLib.sol";
import { YDMSelection } from "./DayMarketTypes.sol";

/**
 * @title YDMDeployer
 * @notice Deploys (or reuses) a market's yield distribution model instance from its config selection, at the
 *         chain-wide CREATE2 salt for the shape, so every market selecting the same shape shares one instance.
 * @dev A mixin: inherited by the market script, which auto-deploys an unset model selection. The models are deployed
 *      at the protocol-wide target utilization (a constructor immutable) and key their curves per accountant and
 *      tranche type, so sharing an instance across markets and across the junior and liquidity provider slots is
 *      safe. NOTE the model salts are environment-agnostic (no env suffix).
 */
abstract contract YDMDeployer is DeployScriptBase {
    /// @notice CREATE2-deploys (or reuses) the yield distribution model instance for a market's selected shape
    function deployYDM(string memory _label, YDMSelection memory _selection) public returns (address model) {
        bool existed;
        (model, existed) = deployWithSanityChecks(
            keccak256(abi.encodePacked("ROYCO_YDM_", uint8(_selection.ydmType))),
            abi.encodePacked(YDMLib.ydmCreationCode(_selection.ydmType), YDMLib.ydmConstructorArgs(_selection.ydmType, YDMLib.YDM_TARGET_UTILIZATION_WAD)),
            false
        );
        _logDeploy(string.concat(_label, vm.toString(uint8(_selection.ydmType))), model, existed);
    }
}
