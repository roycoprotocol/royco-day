// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { TAG_LDM, TAG_YDM } from "../../../../src/factory/templates/base/Constants.sol";
import { AdaptiveCurveYDM_V1 } from "../../../../src/ydm/AdaptiveCurveYDM_V1.sol";
import { AdaptiveCurveYDM_V2 } from "../../../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { FixedYDM } from "../../../../src/ydm/FixedYDM.sol";
import { StaticCurveYDM } from "../../../../src/ydm/StaticCurveYDM.sol";
import { YDMType } from "../../../config/DeploymentTypes.sol";
import { DeployScriptBase } from "../../core/DeployScriptBase.sol";
import { YDMLib } from "../../utils/YDMLib.sol";

/**
 * @title DeployYDMsComponent
 * @notice Deploys (or reuses) the chain-wide yield distribution model set — one instance per shape AND per tranche
 *         slot (the accountant rejects a market whose junior and liquidity provider models are the same instance) —
 *         and registers each pair on the template by canonical shape name.
 * @dev The models are deployed at the protocol-wide target utilization (a constructor immutable), NOT per market. A
 *      market needing a different one is a different model set and a different template. Registration needs
 *      ADMIN_FACTORY_ROLE on the template's config surface — run before the renounce step. NOTE the model salts are
 *      environment-agnostic (no env suffix), preserved verbatim from the monolith.
 */
contract DeployYDMsComponent is DeployScriptBase {
    address internal TEMPLATE;

    constructor(address _template) {
        TEMPLATE = _template;
    }

    /// @notice Deploys + registers the model set under its own broadcast
    function execute(uint256 _deployerPrivateKey) public {
        vm.startBroadcast(_deployerPrivateKey);
        registerModels();
        vm.stopBroadcast();
    }

    /// @notice Deploys and registers the yield distribution models on the template, one pair per model shape
    /// @dev Callable inside an existing broadcast/prank context (tests standing a template up by hand)
    function registerModels() public {
        RoycoDayBalancerV3MarketDeploymentTemplate t = RoycoDayBalancerV3MarketDeploymentTemplate(TEMPLATE);
        for (uint256 i; i < 4; ++i) {
            YDMType ydmType = YDMType(i);
            string memory name = YDMLib.ydmTypeName(ydmType);
            address jtYdm = _deployModel("JT model  ", ydmType, YDMLib.YDM_TARGET_UTILIZATION_WAD, TAG_YDM);
            address lptYdm = _deployModel("LPT model ", ydmType, YDMLib.YDM_TARGET_UTILIZATION_WAD, TAG_LDM);
            if (t.jtYdms(name) == jtYdm && t.lptYdms(name) == lptYdm) continue;
            t.setYieldDistributionModels(name, jtYdm, lptYdm);
        }
    }

    /// @notice Deploys (or reuses) one yield distribution model instance for a shape and tranche slot
    /// @dev The slot tag keeps the junior and liquidity provider instances at distinct addresses even when their shape
    ///      and target utilization coincide, which the accountant requires
    function _deployModel(string memory _label, YDMType _ydmType, uint256 _targetUtilizationWAD, bytes32 _slotTag) internal returns (address model) {
        bytes memory creationCode;
        if (_ydmType == YDMType.StaticCurve) creationCode = type(StaticCurveYDM).creationCode;
        else if (_ydmType == YDMType.AdaptiveCurve_V1) creationCode = type(AdaptiveCurveYDM_V1).creationCode;
        else if (_ydmType == YDMType.AdaptiveCurve_V2) creationCode = type(AdaptiveCurveYDM_V2).creationCode;
        else if (_ydmType == YDMType.Fixed) creationCode = type(FixedYDM).creationCode;
        else revert YDMLib.UnsupportedYDMType(_ydmType);

        bool existed;
        (model, existed) = deployWithSanityChecks(
            keccak256(abi.encodePacked("ROYCO_YDM__", _slotTag, uint8(_ydmType))),
            abi.encodePacked(creationCode, YDMLib.ydmConstructorArgs(_ydmType, _targetUtilizationWAD)),
            false
        );
        _logDeploy(string.concat(_label, vm.toString(uint8(_ydmType))), model, existed);
    }
}
