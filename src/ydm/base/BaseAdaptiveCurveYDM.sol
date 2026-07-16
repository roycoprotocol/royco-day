// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { FixedPointMathLib } from "../../../lib/solady/src/utils/FixedPointMathLib.sol";
import { IYDM, MarketState } from "../../interfaces/IYDM.sol";
import { WAD, WAD_INT } from "../../libraries/Constants.sol";
import { BaseYDM } from "./BaseYDM.sol";

/**
 * @title BaseAdaptiveCurveYDM
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Shared engine for Royco's adaptive curve yield distribution models (YDMs)
 * @dev A general-purpose model for paying a tranche's yield as a premium to a capital pool that provides a service to that tranche
 * @dev It is parameterized purely by the utilization of that service, so the same contract prices any tranche-yield premium
 * @dev Utilization is the fraction of the capital pool's service capacity that is currently in use: the ratio of demand for the service the pool provides to the pool's capacity to supply it, scaled to WAD precision
 * @dev At zero utilization the service is unused and the capital is abundant, so it earns the least
 * @dev At WAD utilization demand equals the pool's full capacity, demand beyond capacity is reported above WAD and capped to WAD here
 * @dev The premium rises with utilization so scarcer service is paid more, pulling additional capital into the pool
 * @dev The curve adapts its yield share at the kink (Y_T) up or down based on the market's relative delta from the target utilization over time
 * @dev This base owns the model-agnostic machinery: the exponential, time- and distance-weighted adaptation of Y_T (bounded and overflow-safe), the trapezoidal time-averaging of Y_T over the elapsed period, and the read/adapt/commit flow of yieldShare and previewYieldShare
 * @dev A concrete model supplies only its per-market storage and its curve shape via the abstract hooks _readAdaptiveCurve, _computeYieldShare, and _writeAdaptiveCurve
 * @dev Inspired by Morpho's AdaptiveCurveIrm: https://github.com/morpho-org/morpho-blue-irm/blob/main/src/adaptive-curve-irm/AdaptiveCurveIrm.sol
 */
abstract contract BaseAdaptiveCurveYDM is BaseYDM {
    /// @notice The maximum allowed adaptation speed per second, scaled to WAD precision
    /// @dev A deploy-time ceiling on ADAPTATION_SPEED_AT_BOUNDARY_WAD that keeps the speed math safely within int256
    uint256 public constant MAX_ADAPTATION_SPEED_WAD = 100e18 / uint256(365 days);

    /// @dev The maximum linear adaptation the curve can apply: one below Solady expWad's overflow threshold, so expWad never reverts
    /// @dev Derivation: https://github.com/Vectorized/solady/blob/acd959aa4bd04720d640bf4e6a5c71037510cc4b/src/utils/FixedPointMathLib.sol#L215-L217
    int256 internal constant MAX_LINEAR_ADAPTATION_WAD = (135_305_999_368_893_231_589 - 1);

    /// @notice The speed at which the curve adapts per second when utilization sits at a boundary of its region (0% or 100%), scaled to WAD precision
    /// @dev The actual adaptation speed scales linearly with the normalized distance from the target utilization, reaching this value only at the region's boundary
    uint256 public immutable ADAPTATION_SPEED_AT_BOUNDARY_WAD;

    /// @notice The minimum yield share at target utilization the adaptation can decay to, scaled to WAD precision
    /// @dev Configured per instance, and must be greater than zero so an initialized market's yield share at target is never the uninitialized sentinel (zero)
    uint256 public immutable MIN_YIELD_SHARE_AT_TARGET_WAD;

    /// @notice The maximum yield share at target utilization the adaptation can grow to, scaled to WAD precision
    /// @dev Configured per instance, bounded to WAD
    uint256 public immutable MAX_YIELD_SHARE_AT_TARGET_WAD;

    /**
     * @notice Sets the per-instance target utilization (the kink), the bounds on the adaptive yield share at target, and the boundary adaptation speed
     * @dev Must be greater than zero so the curve regions are well defined when utilization is zero, concrete models may further constrain it
     * @param _targetUtilizationWAD The target utilization (the kink) for this model, in the range (0, 100%], scaled to WAD precision
     * @param _minYieldShareAtTargetWAD The minimum yield share at target utilization, in the range (0, _maxYieldShareAtTargetWAD], scaled to WAD precision
     * @param _maxYieldShareAtTargetWAD The maximum yield share at target utilization, in the range [_minYieldShareAtTargetWAD, WAD], scaled to WAD precision
     * @param _adaptationSpeedAtBoundaryWAD The speed at which the curve adapts per second at 0% and 100% utilization, in the range (0, MAX_ADAPTATION_SPEED_WAD], scaled to WAD precision
     */
    constructor(
        uint256 _targetUtilizationWAD,
        uint256 _minYieldShareAtTargetWAD,
        uint256 _maxYieldShareAtTargetWAD,
        uint256 _adaptationSpeedAtBoundaryWAD
    )
        BaseYDM(_targetUtilizationWAD)
    {
        require(
            _minYieldShareAtTargetWAD > 0 && _minYieldShareAtTargetWAD <= _maxYieldShareAtTargetWAD && _maxYieldShareAtTargetWAD <= WAD
                && _adaptationSpeedAtBoundaryWAD > 0 && _adaptationSpeedAtBoundaryWAD <= MAX_ADAPTATION_SPEED_WAD,
            INVALID_YDM_INITIALIZATION()
        );
        MIN_YIELD_SHARE_AT_TARGET_WAD = _minYieldShareAtTargetWAD;
        MAX_YIELD_SHARE_AT_TARGET_WAD = _maxYieldShareAtTargetWAD;
        ADAPTATION_SPEED_AT_BOUNDARY_WAD = _adaptationSpeedAtBoundaryWAD;
    }

    /// @inheritdoc IYDM
    function previewYieldShare(MarketState _marketState, uint256 _utilizationWAD) external view override(IYDM) returns (uint256 yieldShareWAD) {
        // Compute and return the current yield share post-adaptation
        (yieldShareWAD,) = _yieldShare(_marketState, _utilizationWAD);
    }

    /// @inheritdoc IYDM
    function yieldShare(MarketState _marketState, uint256 _utilizationWAD) external override(IYDM) returns (uint256 yieldShareWAD) {
        // Compute the current yield share and the new position of the curve post-adaptation
        uint256 newYieldShareAtTargetWAD;
        (yieldShareWAD, newYieldShareAtTargetWAD) = _yieldShare(_marketState, _utilizationWAD);

        // Persist the adapted curve position and emit the concrete model's adaptation event
        _writeAdaptiveCurve(newYieldShareAtTargetWAD, yieldShareWAD);
    }

    /**
     * @notice Computes the yield share for a market at the given utilization, applying any pending adaptation
     * @dev Uses trapezoidal approximation to compute the average continuously adapting yield share for more accurate time-weighted results
     * @param _marketState The state of this Royco market (perpetual or fixed term), the curve only adapts in PERPETUAL
     * @param _utilizationWAD The utilization of the service the capital pool provides, scaled to WAD precision, bounded to WAD here
     * @return yieldShareWAD The share of the tranche's yield paid to the capital pool as a premium, scaled to WAD precision
     *                       It is implied that (WAD - yieldShareWAD) is retained by the paying tranche, excluding any protocol fees
     * @return newYieldShareAtTargetWAD The updated yield share at target utilization after adaptation, scaled to WAD precision
     */
    function _yieldShare(MarketState _marketState, uint256 _utilizationWAD) internal view returns (uint256 yieldShareWAD, uint256 newYieldShareAtTargetWAD) {
        // Bound the supplied utilization to 100%
        _utilizationWAD = ((_utilizationWAD > WAD) ? WAD : _utilizationWAD);

        // Compute the max delta from the target utilization in the region of the curve that the market is currently in (above or below the kink)
        uint256 maxDeltaFromTargetInRegionWAD = _utilizationWAD > TARGET_UTILIZATION_WAD ? (WAD - TARGET_UTILIZATION_WAD) : TARGET_UTILIZATION_WAD;
        // Normalize the actual delta from the target utilization relative to the max delta in the current region
        int256 normalizedDeltaFromTargetWAD = ((int256(_utilizationWAD) - int256(TARGET_UTILIZATION_WAD)) * WAD_INT) / int256(maxDeltaFromTargetInRegionWAD);

        // Retrieve the concrete model's yield share at target and last adaptation timestamp for the market
        (uint256 initialYieldShareAtTargetWAD, uint256 lastAdaptationTimestamp) = _readAdaptiveCurve();
        require(initialYieldShareAtTargetWAD != 0, UNINITIALIZED_YDM());
        // Only adapt the curve if the market is in a perpetual state, where market forces can affect utilization
        uint256 avgYieldShareAtTargetWAD;
        if (_marketState == MarketState.PERPETUAL) {
            // Compute the adaptation speed based on the normalized delta: scale the boundary adaptation speed by the relative delta from the target based on the region
            int256 currentAdaptationSpeedWAD = (int256(ADAPTATION_SPEED_AT_BOUNDARY_WAD) * normalizedDeltaFromTargetWAD) / WAD_INT;
            // Compute the linear adaptation that will be applied to the curve based on the speed
            uint256 elapsed = lastAdaptationTimestamp == 0 ? 0 : block.timestamp - lastAdaptationTimestamp;
            int256 linearAdaptationWAD = currentAdaptationSpeedWAD * int256(elapsed);

            // Compute the new yield share at target utilization
            newYieldShareAtTargetWAD = _computeYieldShareAtTarget(initialYieldShareAtTargetWAD, linearAdaptationWAD);

            // Compute the average yield share at target utilization
            uint256 midYieldShareAtTargetWAD = _computeYieldShareAtTarget(initialYieldShareAtTargetWAD, linearAdaptationWAD / 2);
            avgYieldShareAtTargetWAD = (initialYieldShareAtTargetWAD + newYieldShareAtTargetWAD + (2 * midYieldShareAtTargetWAD)) / 4;
        } else {
            newYieldShareAtTargetWAD = avgYieldShareAtTargetWAD = initialYieldShareAtTargetWAD;
        }

        // Compute the concrete model's curve output with the continuously adapting yield share since the last adaptation
        yieldShareWAD = _computeYieldShare(normalizedDeltaFromTargetWAD, avgYieldShareAtTargetWAD);
    }

    /**
     * @notice Computes the yield share at target utilization for a market post-adaptation
     * @param _lastYieldShareAtTargetWAD The last recorded yield share at target utilization
     * @param _linearAdaptationWAD The linear adaptation to apply to the curve based on the normalized delta, time elapsed, and speed of adaptation
     * @return yieldShareAtTargetWAD The yield share at target utilization after applying the adaptation
     */
    function _computeYieldShareAtTarget(uint256 _lastYieldShareAtTargetWAD, int256 _linearAdaptationWAD) internal view returns (uint256 yieldShareAtTargetWAD) {
        // Compute the new yield share at the target by applying the exponentiated linear adaptation to the previous yield share
        // Exponentiation ensures that the yield share is always non-negative
        // Clamp the linear adaptation to the maximum value to prevent overflows when applying expWAD
        _linearAdaptationWAD = _linearAdaptationWAD > MAX_LINEAR_ADAPTATION_WAD ? MAX_LINEAR_ADAPTATION_WAD : _linearAdaptationWAD;

        yieldShareAtTargetWAD = FixedPointMathLib.fullMulDiv(_lastYieldShareAtTargetWAD, uint256(FixedPointMathLib.expWad(_linearAdaptationWAD)), WAD);
        // Clamp the yield share to the market defined bounds
        if (yieldShareAtTargetWAD < MIN_YIELD_SHARE_AT_TARGET_WAD) return MIN_YIELD_SHARE_AT_TARGET_WAD;
        if (yieldShareAtTargetWAD > MAX_YIELD_SHARE_AT_TARGET_WAD) return MAX_YIELD_SHARE_AT_TARGET_WAD;
    }

    /**
     * @notice Validates the curve anchors an adaptive market initializes with: the yield share at target sits within the market's
     *         adaptive bounds, and the curve is monotonic across the zero, target, and full utilization anchors
     * @param _yieldShareAtZeroUtilWAD The initial yield share at 0% utilization, scaled to WAD precision
     * @param _yieldShareAtTargetUtilWAD The initial yield share at target utilization, scaled to WAD precision
     * @param _yieldShareAtFullUtilWAD The initial yield share at 100% utilization, scaled to WAD precision
     */
    function _validateYDMInitialization(uint256 _yieldShareAtZeroUtilWAD, uint256 _yieldShareAtTargetUtilWAD, uint256 _yieldShareAtFullUtilWAD) internal view {
        require(
            _yieldShareAtTargetUtilWAD >= MIN_YIELD_SHARE_AT_TARGET_WAD && _yieldShareAtTargetUtilWAD <= MAX_YIELD_SHARE_AT_TARGET_WAD
                && _yieldShareAtZeroUtilWAD <= _yieldShareAtTargetUtilWAD && _yieldShareAtTargetUtilWAD <= _yieldShareAtFullUtilWAD
                && _yieldShareAtFullUtilWAD <= WAD,
            INVALID_YDM_INITIALIZATION()
        );
    }

    /**
     * @notice Computes the concrete model's curve output at the current utilization
     * @param _normalizedDeltaFromTargetWAD The normalized signed distance of the current utilization from the target, in [-WAD, WAD]
     * @param _avgYieldShareAtTargetWAD The time-averaged yield share at target over the elapsed period, scaled to WAD precision
     * @return yieldShareWAD The curve's yield share output at the current utilization, scaled to WAD precision and bounded to WAD
     */
    function _computeYieldShare(int256 _normalizedDeltaFromTargetWAD, uint256 _avgYieldShareAtTargetWAD) internal view virtual returns (uint256 yieldShareWAD);

    /**
     * @notice Reads the concrete model's yield share at target and last adaptation timestamp for a market
     * @return yieldShareAtTargetWAD The current yield share at target utilization (zero iff the market's curve is uninitialized), scaled to WAD precision
     * @return lastAdaptationTimestamp The timestamp of the last adaptation (zero iff the curve has never been adapted)
     */
    function _readAdaptiveCurve() internal view virtual returns (uint256 yieldShareAtTargetWAD, uint256 lastAdaptationTimestamp);

    /**
     * @notice Persists the adapted curve position and emits the concrete model's adaptation event
     * @param _newYieldShareAtTargetWAD The adapted yield share at target utilization to store, scaled to WAD precision
     * @param _yieldShareWAD The yield share output returned to the accountant this call, scaled to WAD precision
     */
    function _writeAdaptiveCurve(uint256 _newYieldShareAtTargetWAD, uint256 _yieldShareWAD) internal virtual;
}
