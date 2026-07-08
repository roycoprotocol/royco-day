// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { BaseAdaptiveCurveYDM } from "../../src/ydm/base/BaseAdaptiveCurveYDM.sol";

/**
 * @title AdaptiveYieldShareAtTargetExposer
 * @notice Thin exposer over the adaptive YDM base's internal yield-share-at-target adaptation step so the
 *         linear-adaptation clamp and the min/max yield share bounds are testable in isolation, without
 *         dragging the trapezoidal mid-point computation of the full yield share flow into the call
 * @dev The curve hooks are inert: the exposer never serves a market, it only forwards the internal
 *      computation. Constructor parameters mirror the base's so bounds and speed are freely configurable
 */
contract AdaptiveYieldShareAtTargetExposer is BaseAdaptiveCurveYDM {
    constructor(
        uint256 _targetUtilizationWAD,
        uint256 _minYieldShareAtTargetWAD,
        uint256 _maxYieldShareAtTargetWAD,
        uint256 _adaptationSpeedAtBoundaryWAD
    )
        BaseAdaptiveCurveYDM(_targetUtilizationWAD, _minYieldShareAtTargetWAD, _maxYieldShareAtTargetWAD, _adaptationSpeedAtBoundaryWAD)
    { }

    /// @notice Forwards to the base's internal post-adaptation yield share at target computation
    function computeYieldShareAtTarget(uint256 _lastYieldShareAtTargetWAD, int256 _linearAdaptationWAD) external view returns (uint256) {
        return _computeYieldShareAtTarget(_lastYieldShareAtTargetWAD, _linearAdaptationWAD);
    }

    /// @dev Inert curve hook, the exposer never computes a full yield share
    function _computeYieldShare(int256, uint256 _avgYieldShareAtTargetWAD) internal view override returns (uint256) {
        return _avgYieldShareAtTargetWAD;
    }

    /// @dev Inert read hook, the exposer holds no per-market curve state
    function _readAdaptiveCurve() internal view override returns (uint256, uint256) {
        return (0, 0);
    }

    /// @dev Inert write hook, the exposer holds no per-market curve state
    function _writeAdaptiveCurve(uint256, uint256) internal override { }
}
