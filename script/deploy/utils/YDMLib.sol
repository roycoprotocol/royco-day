// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Strings } from "../../../lib/openzeppelin-contracts/contracts/utils/Strings.sol";
import { AdaptiveCurveYDM_V1 } from "../../../src/ydm/AdaptiveCurveYDM_V1.sol";
import { AdaptiveCurveYDM_V2 } from "../../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { FixedYDM } from "../../../src/ydm/FixedYDM.sol";
import { StaticCurveYDM } from "../../../src/ydm/StaticCurveYDM.sol";
import { AdaptiveCurveYDM_V1_Params, AdaptiveCurveYDM_V2_Params, FixedYDMParams, StaticCurveYDMParams, YDMType } from "../../config/DeploymentTypes.sol";

/**
 * @title YDMLib
 * @notice The single home for everything that maps the script-side `YDMType` enum onto the deployed yield
 *         distribution models: the canonical registry names, the constructor args each model shape is deployed with,
 *         and the per-market initialization data encoding.
 * @dev Shared by the YDM deployment script (which instantiates the chain-wide model set) and the market deployment
 *      script (which encodes each market's curve into the accountant's initialization data) — keeping the two in one
 *      place is what guarantees a market can only reference a model shape the chain actually deploys.
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

    /// @notice The standardized AdaptiveCurveYDM_V2 boundary adaptation speed grid (per year): every 10/year from 10
    ///         to 100, each registered on the template as "ADAPTIVE_CURVE_V2_<speed>"
    function adaptiveV2SpeedVariantsPerYear() internal pure returns (uint256[10] memory) {
        return [uint256(10), 20, 30, 40, 50, 60, 70, 80, 90, 100];
    }

    /// @notice The template registry name for a V2 speed variant, e.g. "ADAPTIVE_CURVE_V2_40"
    function adaptiveV2VariantName(uint256 _speedPerYear) internal pure returns (string memory) {
        return string.concat("ADAPTIVE_CURVE_V2_", Strings.toString(_speedPerYear));
    }

    /// @notice The deployment salt for a V2 speed variant instance in a tranche slot
    function adaptiveV2VariantSalt(bytes32 _slotTag, uint256 _speedPerYear) internal pure returns (bytes32) {
        if (_speedPerYear == 100) return keccak256(abi.encodePacked("ROYCO_YDM__", _slotTag, uint8(YDMType.AdaptiveCurve_V2)));
        return keccak256(abi.encodePacked("ROYCO_YDM__", _slotTag, uint8(YDMType.AdaptiveCurve_V2), "_SPEED_", _speedPerYear));
    }

    /// @notice The constructor args for a V2 speed variant: canonical target utilization and bounds, variant speed
    function adaptiveV2VariantConstructorArgs(uint256 _targetUtilizationWAD, uint256 _speedPerYear) internal pure returns (bytes memory) {
        return abi.encode(
            _targetUtilizationWAD,
            ADAPTIVE_YDM_MIN_YIELD_SHARE_AT_TARGET_WAD,
            ADAPTIVE_YDM_MAX_YIELD_SHARE_AT_TARGET_WAD,
            _speedPerYear * 1e18 / uint256(365 days)
        );
    }

    /// @notice Thrown when a YDM type has no deployment mapping
    error UnsupportedYDMType(YDMType ydmType);

    /// @notice The canonical registry name for a model shape, shared by registration and market params
    /// @dev The template keys its registry by name, so this is the single place the enum crosses into that namespace
    function ydmTypeName(YDMType _ydmType) internal pure returns (string memory) {
        if (_ydmType == YDMType.StaticCurve) return "STATIC_CURVE";
        else if (_ydmType == YDMType.AdaptiveCurve_V1) return "ADAPTIVE_CURVE_V1";
        // The canonical V2 pair (100/year) follows the standardized speed-suffixed scheme; live chains bootstrapped
        // before the rename also carry the same instances under the legacy "ADAPTIVE_CURVE_V2" name
        else if (_ydmType == YDMType.AdaptiveCurve_V2) return adaptiveV2VariantName(100);
        else if (_ydmType == YDMType.Fixed) return "FIXED";
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

    /// @notice Builds a market's YDM initialization data for its curve parameters
    function buildYDMInitializationData(YDMType _ydmType, bytes memory _ydmSpecificParams) internal pure returns (bytes memory ydmInitializationData) {
        if (_ydmType == YDMType.StaticCurve) {
            StaticCurveYDMParams memory ydmParams = abi.decode(_ydmSpecificParams, (StaticCurveYDMParams));
            ydmInitializationData = abi.encodeCall(
                StaticCurveYDM.initializeYDMForMarket,
                (ydmParams.yieldShareAtZeroUtilWAD, ydmParams.yieldShareAtTargetUtilWAD, ydmParams.yieldShareAtFullUtilWAD)
            );
        } else if (_ydmType == YDMType.AdaptiveCurve_V1) {
            AdaptiveCurveYDM_V1_Params memory ydmParams = abi.decode(_ydmSpecificParams, (AdaptiveCurveYDM_V1_Params));
            ydmInitializationData =
                abi.encodeCall(AdaptiveCurveYDM_V1.initializeYDMForMarket, (ydmParams.yieldShareAtTargetUtilWAD, ydmParams.yieldShareAtFullUtilWAD));
        } else if (_ydmType == YDMType.AdaptiveCurve_V2) {
            AdaptiveCurveYDM_V2_Params memory ydmParams = abi.decode(_ydmSpecificParams, (AdaptiveCurveYDM_V2_Params));
            ydmInitializationData = abi.encodeCall(
                AdaptiveCurveYDM_V2.initializeYDMForMarket,
                (ydmParams.yieldShareAtZeroUtilWAD, ydmParams.yieldShareAtTargetUtilWAD, ydmParams.yieldShareAtFullUtilWAD)
            );
        } else if (_ydmType == YDMType.Fixed) {
            FixedYDMParams memory ydmParams = abi.decode(_ydmSpecificParams, (FixedYDMParams));
            ydmInitializationData = abi.encodeCall(FixedYDM.initializeYDMForMarket, (ydmParams.fixedYieldShareWAD));
        } else {
            revert UnsupportedYDMType(_ydmType);
        }
    }
}
