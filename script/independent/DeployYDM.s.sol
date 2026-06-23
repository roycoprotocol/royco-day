// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AdaptiveCurveYDM_V1 } from "../../src/ydm/AdaptiveCurveYDM_V1.sol";
import { AdaptiveCurveYDM_V2 } from "../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { StaticCurveYDM } from "../../src/ydm/StaticCurveYDM.sol";
import { DeployScript } from "../Deploy.s.sol";

/// @dev Deploys an independent (shared, per-accountant adaptive) instance of the specified YDM implementation.
contract DeployYDMScript is DeployScript {
    /// @dev The YDM type to deploy an instance of
    YDMType ydmType = YDMType.AdaptiveCurve_V2;

    /// @dev The target (coverage) utilization WAD baked into the YDM curve (90%).
    uint256 internal constant TARGET_UTILIZATION_WAD = 0.9e18;

    function run() external override {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        _deployYDMImpl(ydmType);
        vm.stopBroadcast();
    }

    /// @dev Deploys the YDM implementation contract matching `_ydmType`.
    function _deployYDMImpl(YDMType _ydmType) internal returns (address ydm) {
        if (_ydmType == YDMType.StaticCurve) {
            ydm = address(new StaticCurveYDM(TARGET_UTILIZATION_WAD));
        } else if (_ydmType == YDMType.AdaptiveCurve_V1) {
            ydm = address(new AdaptiveCurveYDM_V1(TARGET_UTILIZATION_WAD));
        } else if (_ydmType == YDMType.AdaptiveCurve_V2) {
            ydm = address(new AdaptiveCurveYDM_V2(TARGET_UTILIZATION_WAD));
        } else {
            revert UnsupportedYDMType(_ydmType);
        }
    }
}
