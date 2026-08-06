// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AdaptiveCurveYDM_V1 } from "../../../src/ydm/AdaptiveCurveYDM_V1.sol";
import { AdaptiveCurveYDM_V2 } from "../../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { FixedYDM } from "../../../src/ydm/FixedYDM.sol";
import { StaticCurveYDM } from "../../../src/ydm/StaticCurveYDM.sol";
import { TrancheType } from "../../../src/libraries/Types.sol";
import { AdaptiveCurveYDM_V1_Params, AdaptiveCurveYDM_V2_Params, FixedYDMParams, StaticCurveYDMParams, YDMType } from "../../config/DeploymentTypes.sol";

/**
 * @title YDMLib
 * @notice The single home for everything that maps the script-side `YDMType` enum onto the deployed yield
 *         distribution models: the creation code and constructor args each model shape is deployed with, and the
 *         per-market initialization data encoding.
 * @dev Used by the market deployment script, which deploys (or reuses) each market's model instances and encodes
 *      each curve into the accountant's initialization data. Keeping deployment and encoding in one place is what
 *      guarantees a market can only reference a model shape the pipeline actually deploys.
 */
library YDMLib {
    /// @notice The protocol-wide target utilization every YDM instance is deployed at
    uint256 internal constant YDM_TARGET_UTILIZATION_WAD = 0.9e18;

    /// @notice The adaptive curve YDMs' canonical adaptation bounds: the yield share at target adapts within [0.01%, 100%]
    uint256 internal constant ADAPTIVE_YDM_MIN_YIELD_SHARE_AT_TARGET_WAD = 0.0001e18;
    uint256 internal constant ADAPTIVE_YDM_MAX_YIELD_SHARE_AT_TARGET_WAD = 1e18;

    /// @notice The adaptive curve YDMs' canonical boundary adaptation speeds, per second at 0% and 100% utilization
    uint256 internal constant ADAPTIVE_YDM_V1_ADAPTATION_SPEED_WAD = 50e18 / uint256(365 days);
    uint256 internal constant ADAPTIVE_YDM_V2_ADAPTATION_SPEED_WAD = 100e18 / uint256(365 days);

    /// @notice Thrown when a YDM type has no deployment mapping
    error UnsupportedYDMType(YDMType ydmType);

    /// @notice The creation code for a model shape
    function ydmCreationCode(YDMType _ydmType) internal pure returns (bytes memory creationCode) {
        if (_ydmType == YDMType.StaticCurve) return type(StaticCurveYDM).creationCode;
        else if (_ydmType == YDMType.AdaptiveCurve_V1) return type(AdaptiveCurveYDM_V1).creationCode;
        else if (_ydmType == YDMType.AdaptiveCurve_V2) return type(AdaptiveCurveYDM_V2).creationCode;
        else if (_ydmType == YDMType.Fixed) return type(FixedYDM).creationCode;
        else revert UnsupportedYDMType(_ydmType);
    }

    /// @notice Builds the ABI-encoded constructor args for a YDM model at the given target utilization
    function ydmConstructorArgs(YDMType _ydmType, uint256 _targetUtilizationWAD) internal pure returns (bytes memory) {
        if (_ydmType == YDMType.StaticCurve) {
            return abi.encode(_targetUtilizationWAD);
        } else if (_ydmType == YDMType.AdaptiveCurve_V1) {
            return abi.encode(
                _targetUtilizationWAD,
                ADAPTIVE_YDM_MIN_YIELD_SHARE_AT_TARGET_WAD,
                ADAPTIVE_YDM_MAX_YIELD_SHARE_AT_TARGET_WAD,
                ADAPTIVE_YDM_V1_ADAPTATION_SPEED_WAD
            );
        } else if (_ydmType == YDMType.AdaptiveCurve_V2) {
            return abi.encode(
                _targetUtilizationWAD,
                ADAPTIVE_YDM_MIN_YIELD_SHARE_AT_TARGET_WAD,
                ADAPTIVE_YDM_MAX_YIELD_SHARE_AT_TARGET_WAD,
                ADAPTIVE_YDM_V2_ADAPTATION_SPEED_WAD
            );
        }
        // The fixed model has no concept of a target utilization and takes no constructor args
        else if (_ydmType == YDMType.Fixed) {
            return "";
        } else {
            revert UnsupportedYDMType(_ydmType);
        }
    }

    /// @notice Builds a market's YDM initialization data for the curve of one premium-receiving tranche type
    function buildYDMInitializationData(
        TrancheType _trancheType,
        YDMType _ydmType,
        bytes memory _ydmSpecificParams
    )
        internal
        pure
        returns (bytes memory ydmInitializationData)
    {
        if (_ydmType == YDMType.StaticCurve) {
            StaticCurveYDMParams memory ydmParams = abi.decode(_ydmSpecificParams, (StaticCurveYDMParams));
            ydmInitializationData = abi.encodeCall(
                StaticCurveYDM.initializeYDMForMarket,
                (_trancheType, ydmParams.yieldShareAtZeroUtilWAD, ydmParams.yieldShareAtTargetUtilWAD, ydmParams.yieldShareAtFullUtilWAD)
            );
        } else if (_ydmType == YDMType.AdaptiveCurve_V1) {
            AdaptiveCurveYDM_V1_Params memory ydmParams = abi.decode(_ydmSpecificParams, (AdaptiveCurveYDM_V1_Params));
            ydmInitializationData = abi.encodeCall(
                AdaptiveCurveYDM_V1.initializeYDMForMarket, (_trancheType, ydmParams.yieldShareAtTargetUtilWAD, ydmParams.yieldShareAtFullUtilWAD)
            );
        } else if (_ydmType == YDMType.AdaptiveCurve_V2) {
            AdaptiveCurveYDM_V2_Params memory ydmParams = abi.decode(_ydmSpecificParams, (AdaptiveCurveYDM_V2_Params));
            ydmInitializationData = abi.encodeCall(
                AdaptiveCurveYDM_V2.initializeYDMForMarket,
                (_trancheType, ydmParams.yieldShareAtZeroUtilWAD, ydmParams.yieldShareAtTargetUtilWAD, ydmParams.yieldShareAtFullUtilWAD)
            );
        } else if (_ydmType == YDMType.Fixed) {
            FixedYDMParams memory ydmParams = abi.decode(_ydmSpecificParams, (FixedYDMParams));
            ydmInitializationData = abi.encodeCall(FixedYDM.initializeYDMForMarket, (_trancheType, ydmParams.fixedYieldShareWAD));
        } else {
            revert UnsupportedYDMType(_ydmType);
        }
    }
}
