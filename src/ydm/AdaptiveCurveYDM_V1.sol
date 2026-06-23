// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { FixedPointMathLib } from "../../lib/solady/src/utils/FixedPointMathLib.sol";
import { IYDM, MarketState } from "../interfaces/IYDM.sol";
import { WAD, WAD_INT } from "../libraries/Constants.sol";
import { BaseYDM } from "./base/BaseYDM.sol";

/**
 * @title AdaptiveCurveYDM_V1
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Royco's adaptive curve yield distribution model (YDM) V1
 * @dev A general-purpose model for paying a tranche's yield as a premium to a capital pool that provides a service to that tranche
 * @dev It is parameterized purely by the utilization of that service, so the same contract prices any tranche-yield premium
 * @dev Utilization is the fraction of the capital pool's service capacity that is currently in use: the ratio of demand for the service the pool provides to the pool's capacity to supply it, scaled to WAD precision
 * @dev At zero utilization the service is unused and the capital is abundant, so it earns the least; at WAD utilization demand equals the pool's full capacity; demand beyond capacity is reported above WAD and capped to WAD here
 * @dev The premium rises with utilization so scarcer service is paid more, pulling additional capital into the pool
 * @dev The curve is an adaptive piece-wise function parameterized by the utilization, the steepness of the curve, a per-instance target utilization (the kink) supplied at construction, and the yield share at the kink (Y_T)
 * @dev The curve adapts its yield share at the kink up or down based on the market's relative delta from the target utilization over time; the slopes above and below the kink adapt with it
 * @dev Inspired by Morpho's AdaptiveCurveIrm: https://github.com/morpho-org/morpho-blue-irm
 */
contract AdaptiveCurveYDM_V1 is BaseYDM {
    /**
     * @notice The maximum speed at which the curve adapts per second scaled to WAD precision
     * @dev This represents how quickly the curve shifts up or down at the edges, 100% and 0% utilization respectively
     * @dev The actual speed that the curve shifts at is based on the current relative distance from the target utilization
     */
    int256 public constant MAX_ADAPTATION_SPEED_WAD = 50e18 / int256(365 days);

    /// @dev The minimum yield share at target utilization
    /// @dev Set to 1 basis point
    uint256 public constant MIN_YIELD_SHARE_AT_TARGET_WAD = 0.0001e18;

    /// @dev The maximum yield share at target utilization
    uint256 public constant MAX_YIELD_SHARE_AT_TARGET_WAD = WAD;

    /// @dev The maximum linear adaptation that can be applied to the curve.
    /// @dev This value is chosen to prevent overflows when computing expWAD
    int256 private constant MAX_LINEAR_ADAPTATION_WAD = 135_305_999_368_893_231_589 - 1;

    /**
     * @notice Represents the state of a market's YDM
     * @custom:field yieldShareAtTargetWAD - The current yield share at target utilization, scaled to WAD precision
     * @custom:field lastAdaptationTimestamp - The last time adaptations were applied to this market's curve
     * @custom:field steepnessAfterTargetWAD - The steepness of the curve for this market post-kink: ratio of yield share at 100% utilization to yield share at target
     */
    struct AdaptiveYieldCurve {
        uint64 yieldShareAtTargetWAD;
        uint32 lastAdaptationTimestamp;
        uint160 steepnessAfterTargetWAD;
    }

    /// @dev A mapping from market accountants to its market's current YDM curve
    /// @dev The curve is adapted by market forces over time
    mapping(address accountant => AdaptiveYieldCurve curve) public accountantToCurve;

    /**
     * @notice Emitted when the adaptive curve YDM is initialized for a market
     * @param accountant The accountant for the market that the YDM was initialized for
     * @param steepnessAfterTargetWAD The steepness of the curve for this market (ratio of yield share at 100% utilization to yield share at target), scaled to WAD precision
     * @param initialYieldShareAtTargetWAD The initial yield share at target utilization, scaled to WAD precision
     */
    event AdaptiveCurveYdmInitialized(address indexed accountant, uint256 steepnessAfterTargetWAD, uint256 initialYieldShareAtTargetWAD);

    /**
     * @notice Emitted when the yield share is updated and the curve is adapted (in a PERPETUAL state)
     * @param accountant The accountant for the market that the yield share was updated for
     * @param avgYieldShareWAD The average yield share during the period since the last adaptation (returned to the accountant)
     * @param newYieldShareAtTargetWAD The new yield share at the target utilization after applying adaptations
     */
    event YdmAdaptedOutput(address indexed accountant, uint256 avgYieldShareWAD, uint256 newYieldShareAtTargetWAD);

    /**
     * @notice Sets the per-instance target utilization (the kink) shared by every market this YDM serves
     * @dev Must be greater than zero so the curve regions are well defined when utilization is zero; concrete models may further constrain it
     * @param _targetUtilizationWAD The target utilization (the kink) for this model, in the range (0, 100%], scaled to WAD precision
     */
    constructor(uint256 _targetUtilizationWAD) BaseYDM(_targetUtilizationWAD) { }

    /**
     * @notice Initializes the YDM curve for a particular Royco market
     * @dev Must be called during the initialization of the accountant for the Royco market
     * @param _yieldShareAtTargetUtilWAD The initial yield share at target utilization, scaled to WAD precision
     * @param _yieldShareAtFullUtilWAD The initial yield share at 100% utilization, scaled to WAD precision
     */
    function initializeYDMForMarket(uint64 _yieldShareAtTargetUtilWAD, uint64 _yieldShareAtFullUtilWAD) external {
        // Ensure that the initial YDM curve is valid
        require(
            _yieldShareAtTargetUtilWAD >= MIN_YIELD_SHARE_AT_TARGET_WAD && _yieldShareAtTargetUtilWAD <= MAX_YIELD_SHARE_AT_TARGET_WAD
                && _yieldShareAtTargetUtilWAD <= _yieldShareAtFullUtilWAD && _yieldShareAtFullUtilWAD <= WAD,
            INVALID_YDM_INITIALIZATION()
        );

        // Initialize the YDM curve for this market
        AdaptiveYieldCurve storage curve = accountantToCurve[msg.sender];
        curve.yieldShareAtTargetWAD = _yieldShareAtTargetUtilWAD;
        curve.steepnessAfterTargetWAD = uint160((_yieldShareAtFullUtilWAD * WAD) / _yieldShareAtTargetUtilWAD);
        // Ensure that the last adaptation timestamp is zero on initialization: only pertains to reinitialization
        delete accountantToCurve[msg.sender].lastAdaptationTimestamp;

        emit AdaptiveCurveYdmInitialized(msg.sender, curve.steepnessAfterTargetWAD, _yieldShareAtTargetUtilWAD);
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

        // Apply the adaptations to the curve
        AdaptiveYieldCurve storage curve = accountantToCurve[msg.sender];
        curve.yieldShareAtTargetWAD = uint64(newYieldShareAtTargetWAD);
        curve.lastAdaptationTimestamp = uint32(block.timestamp);

        emit YdmAdaptedOutput(msg.sender, yieldShareWAD, uint256(newYieldShareAtTargetWAD));
    }

    /**
     * @notice Computes the yield share for a market at the given utilization, applying any pending adaptation
     * @dev Uses trapezoidal approximation to compute the average continuously adapting yield share for more accurate time-weighted results
     * @param _marketState The state of this Royco market (perpetual or fixed term); the curve only adapts in PERPETUAL
     * @param _utilizationWAD The utilization of the service the capital pool provides, scaled to WAD precision; bounded to WAD here
     * @return yieldShareWAD The share of the tranche's yield paid to the capital pool as a premium, scaled to WAD precision
     *                       It is implied that (WAD - yieldShareWAD) is retained by the paying tranche, excluding any protocol fees
     * @return newYieldShareAtTargetWAD The updated yield share at target utilization after adaptation, scaled to WAD precision
     */
    function _yieldShare(MarketState _marketState, uint256 _utilizationWAD) internal view returns (uint256 yieldShareWAD, uint256 newYieldShareAtTargetWAD) {
        // Bound the supplied utilization to 100%
        uint256 utilizationWAD = _utilizationWAD;
        if (utilizationWAD > WAD) utilizationWAD = WAD;

        // Compute the max delta from the target utilization in the region of the curve that the market is currently in (above or below the kink)
        uint256 maxDeltaFromTargetInRegionWAD = utilizationWAD > TARGET_UTILIZATION_WAD ? (WAD - TARGET_UTILIZATION_WAD) : TARGET_UTILIZATION_WAD;
        // Normalize the actual delta from the target utilization relative to the max delta in the current region
        int256 normalizedDeltaFromTargetWAD = ((int256(utilizationWAD) - int256(TARGET_UTILIZATION_WAD)) * WAD_INT) / int256(maxDeltaFromTargetInRegionWAD);

        // Retrieve the current YDM curve for the market
        AdaptiveYieldCurve memory curve = accountantToCurve[msg.sender];
        uint256 initialYieldShareAtTargetWAD = curve.yieldShareAtTargetWAD;
        require(initialYieldShareAtTargetWAD != 0, UNINITIALIZED_YDM());
        // Only adapt the curve if the market is in a perpetual state and market forces are enabled to affect utilization
        uint256 avgYieldShareAtTargetWAD;
        if (_marketState == MarketState.PERPETUAL) {
            // Compute the adaptation speed based on the normalized delta: scale the max adaptation speed by the relative delta from the target based on the region
            int256 currentAdaptationSpeedWAD = (MAX_ADAPTATION_SPEED_WAD * normalizedDeltaFromTargetWAD) / WAD_INT;
            // Compute the linear adaptation that will be applied to the curve based on the speed
            uint256 elapsed = curve.lastAdaptationTimestamp == 0 ? 0 : block.timestamp - curve.lastAdaptationTimestamp;
            int256 linearAdaptationWAD = currentAdaptationSpeedWAD * int256(elapsed);

            // Compute the new yield share at target utilization
            newYieldShareAtTargetWAD = _computeYieldShareAtTarget(initialYieldShareAtTargetWAD, linearAdaptationWAD);

            // Compute the average yield share at target utilization
            uint256 midYieldShareAtTargetWAD = _computeYieldShareAtTarget(initialYieldShareAtTargetWAD, linearAdaptationWAD / 2);
            avgYieldShareAtTargetWAD = (initialYieldShareAtTargetWAD + newYieldShareAtTargetWAD + (2 * midYieldShareAtTargetWAD)) / 4;
        } else {
            newYieldShareAtTargetWAD = avgYieldShareAtTargetWAD = initialYieldShareAtTargetWAD;
        }

        // Compute the YDM curve's output with the continuously adapting yield share since the last adaptation
        yieldShareWAD = _computeCurrentYieldShare(curve.steepnessAfterTargetWAD, normalizedDeltaFromTargetWAD, avgYieldShareAtTargetWAD);
    }

    /**
     * @notice Computes the yield share at target utilization for a market post-adaptation
     * @param _lastYieldShareAtTargetWAD The last recorded yield share at target utilization
     * @param _linearAdaptationWAD The linear adaptation to apply to the curve based on the normalized delta, time elapsed, and speed of adaptation
     * @return yieldShareAtTargetWAD The yield share at target utilization after applying the adaptation
     */
    function _computeYieldShareAtTarget(uint256 _lastYieldShareAtTargetWAD, int256 _linearAdaptationWAD) internal pure returns (uint256 yieldShareAtTargetWAD) {
        // Compute the new yield share at the target by applying the exponentiated linear adaptation to the previous yield share
        // Exponentiation ensures that the yield share is always non-negative
        // Clamp the linear adaptation to the maximum value to prevent overflows when applying expWAD
        _linearAdaptationWAD = _linearAdaptationWAD > MAX_LINEAR_ADAPTATION_WAD ? MAX_LINEAR_ADAPTATION_WAD : _linearAdaptationWAD;

        yieldShareAtTargetWAD = uint256((int256(_lastYieldShareAtTargetWAD) * FixedPointMathLib.expWad(_linearAdaptationWAD)) / WAD_INT);
        // Clamp the yield share to the market defined bounds
        if (yieldShareAtTargetWAD < MIN_YIELD_SHARE_AT_TARGET_WAD) return MIN_YIELD_SHARE_AT_TARGET_WAD;
        if (yieldShareAtTargetWAD > MAX_YIELD_SHARE_AT_TARGET_WAD) return MAX_YIELD_SHARE_AT_TARGET_WAD;
    }

    /**
     * @notice Computes the yield share at current utilization for a market post-adaptation
     * @param _steepnessWAD The steepness of the curve for this market (ratio of yield share at 100% utilization to yield share at target)
     * @param _normalizedDeltaFromTargetWAD The delta of the current utilization relative to target utilization, normalized as a ratio of absolute delta to max delta
     * @param _yieldShareAtTargetWAD The yield share at target utilization
     * @return yieldShareWAD The yield share at current utilization
     */
    function _computeCurrentYieldShare(
        uint256 _steepnessWAD,
        int256 _normalizedDeltaFromTargetWAD,
        uint256 _yieldShareAtTargetWAD
    )
        internal
        pure
        returns (uint256 yieldShareWAD)
    {
        /**
         * Adaptive Curve Yield Distribution Model (adaptive piecewise curve):
         *
         *   Y(U) = ((1 - 1/S) * Δ + 1) * Y_T   if U < U_T   (below target)
         *          ((S - 1) * Δ + 1) * Y_T     if U >= U_T  (at or above target)
         *
         * Y(U) → Share of the paying tranche's yield routed to the capital pool as a premium
         * U    → Utilization of the service the capital pool provides
         * U_T  → Target utilization (the kink), configured per instance via TARGET_UTILIZATION_WAD
         * S    → Steepness of the curve for this market (ratio of yield share at 100% utilization to yield share at target)
         * Δ    → Normalized delta from target utilization: Δ ∈ [-1, 1]
         *        Above target: Δ = (U - U_T) / (1 - U_T)
         *        Below target: Δ = (U - U_T) / U_T
         * Y_T  → yield share at target utilization (adapts over time based on market forces)
         *
         * Key properties:
         * - At U = U_T (target): Y(U) = Y_T
         * - At U = 1.0 (full):   Y(U) = S * Y_T
         * - At U = 0.0 (empty):  Y(U) = Y_T / S
         *
         * Adaptation mechanism:
         * - High utilization → Y_T adapts upward → entire curve scales up → the pool receives more yield to attract capital
         * - Low utilization  → Y_T adapts downward → entire curve scales down → the pool receives less yield as capital is abundant
         *
         * Steepness (S) is fixed at initialization and determines the curve's shape (ratio between yield share target and full utilization)
         * Y_T is the single adaptive parameter that shifts the curve vertically in response to market forces
         */

        // Compute the coefficient based on the region of the curve that the market is currently in
        int256 coefficient = _normalizedDeltaFromTargetWAD < 0
            ? WAD_INT - ((WAD_INT * WAD_INT) / int256(_steepnessWAD))  // 1 - 1/S if below the kink
            : int256(_steepnessWAD) - WAD_INT; // S - 1 if at or above the kink

        yieldShareWAD = uint256((((coefficient * _normalizedDeltaFromTargetWAD / WAD_INT) + WAD_INT) * int256(_yieldShareAtTargetWAD)) / WAD_INT);
        if (yieldShareWAD > WAD) yieldShareWAD = WAD;
    }
}
