// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { FixedPointMathLib } from "../../lib/solady/src/utils/FixedPointMathLib.sol";
import { IYDM, MarketState } from "../interfaces/IYDM.sol";
import { WAD, WAD_INT } from "../libraries/Constants.sol";
import { BaseYDM } from "./base/BaseYDM.sol";

/**
 * @title AdaptiveCurveYDM_V2
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Royco's adaptive curve yield distribution model (YDM) V2
 * @dev A general-purpose model for paying a tranche's yield as a premium to a capital pool that provides a service to that tranche
 * @dev It is parameterized purely by the utilization of that service, so the same contract prices any tranche-yield premium
 * @dev Utilization is the fraction of the capital pool's service capacity that is currently in use: the ratio of demand for the service the pool provides to the pool's capacity to supply it, scaled to WAD precision
 * @dev At zero utilization the service is unused and the capital is abundant, so it earns the least; at WAD utilization demand equals the pool's full capacity; demand beyond capacity is reported above WAD and capped to WAD here
 * @dev The premium rises with utilization so scarcer service is paid more, pulling additional capital into the pool
 * @dev The curve is an adaptive piece-wise function parameterized by the utilization, static slopes, a per-instance target utilization (the kink) supplied at construction, and the yield share at the kink (Y_T)
 * @dev The curve adapts its yield share at the kink (Y_T) up or down based on the market's relative delta from the target utilization over time; the slopes above and below the target remain static, so only Y_T adapts, translating the curve vertically and providing fixed premiums/discounts to Y_T at each utilization level
 */
contract AdaptiveCurveYDM_V2 is BaseYDM {
    /**
     * @notice The maximum value for the maximum speed at which a market's curve can adapt at per second, scaled to WAD precision
     * @dev This represents how quickly the curve shifts up or down at the edges, 100% and 0% utilization respectively
     * @dev The actual speed that the curve shifts at is based on the current relative distance from the target utilization
     */
    uint256 public constant MAX_CURVE_ADAPTATION_SPEED_WAD = 100e18 / uint256(365 days);

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
     * @custom:field maxAdaptationSpeedWAD - The max adaptation speed of the curve at the boundaries of utilization (0% and 100%), scaled to WAD precision
     * @custom:field discountToTargetAtZeroUtilWAD - The fixed discount to yield share at target utilization given at 0% utilization, scaled to WAD precision
     * @custom:field premiumToTargetAtFullUtilWAD - The fixed premium to yield share at target utilization given at 100% utilization, scaled to WAD precision
     *
     */
    struct AdaptiveYieldCurve {
        uint64 yieldShareAtTargetWAD;
        uint32 lastAdaptationTimestamp;
        uint64 maxAdaptationSpeedWAD;
        uint64 discountToTargetAtZeroUtilWAD;
        uint64 premiumToTargetAtFullUtilWAD;
    }

    /// @dev A mapping from market accountants to its market's current YDM curve
    /// @dev The curve is adapted by market forces over time
    mapping(address accountant => AdaptiveYieldCurve curve) public accountantToCurve;

    /**
     * @notice Emitted when the adaptive curve YDM is initialized for a market
     * @param accountant The accountant for the market that the YDM was initialized for
     * @param discountToTargetAtZeroUtilWAD The fixed discount below Y_T at 0% utilization (Y_T - Y_0), scaled to WAD
     * @param yieldShareAtTargetUtilWAD The initial yield share at target utilization, scaled to WAD precision
     * @param premiumToTargetAtFullUtilWAD The fixed premium above Y_T at 100% utilization (Y_100 - Y_T), scaled to WAD
     * @param maxAdaptationSpeedWAD The max adaptation speed of the curve at the boundaries of utilization (0% and 100%), scaled to WAD precision
     */
    event AdaptiveCurveYdmInitialized(
        address indexed accountant,
        uint256 discountToTargetAtZeroUtilWAD,
        uint256 yieldShareAtTargetUtilWAD,
        uint256 premiumToTargetAtFullUtilWAD,
        uint256 maxAdaptationSpeedWAD
    );

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
     * @param _yieldShareAtZeroUtilWAD The initial yield share at 0% utilization, scaled to WAD precision
     * @param _yieldShareAtTargetUtilWAD The initial yield share at target utilization, scaled to WAD precision
     * @param _yieldShareAtFullUtilWAD The initial yield share at 100% utilization, scaled to WAD precision
     * @param _maxAdaptationSpeedWAD The max adaptation speed of the curve at the boundaries of utilization (0% and 100%), scaled to WAD precision
     */
    function initializeYDMForMarket(
        uint64 _yieldShareAtZeroUtilWAD,
        uint64 _yieldShareAtTargetUtilWAD,
        uint64 _yieldShareAtFullUtilWAD,
        uint64 _maxAdaptationSpeedWAD
    )
        external
    {
        // Ensure that the YDM curve is valid
        require(
            _yieldShareAtTargetUtilWAD >= MIN_YIELD_SHARE_AT_TARGET_WAD && _yieldShareAtZeroUtilWAD <= _yieldShareAtTargetUtilWAD
                && _yieldShareAtTargetUtilWAD <= _yieldShareAtFullUtilWAD && _yieldShareAtFullUtilWAD <= WAD
                && _maxAdaptationSpeedWAD <= MAX_CURVE_ADAPTATION_SPEED_WAD,
            INVALID_YDM_INITIALIZATION()
        );

        // Initialize the YDM curve for this market
        AdaptiveYieldCurve storage curve = accountantToCurve[msg.sender];
        curve.yieldShareAtTargetWAD = _yieldShareAtTargetUtilWAD;
        curve.maxAdaptationSpeedWAD = _maxAdaptationSpeedWAD;
        curve.discountToTargetAtZeroUtilWAD = (_yieldShareAtTargetUtilWAD - _yieldShareAtZeroUtilWAD);
        curve.premiumToTargetAtFullUtilWAD = (_yieldShareAtFullUtilWAD - _yieldShareAtTargetUtilWAD);
        // Ensure that the last adaptation timestamp is zero on initialization: only pertains to reinitialization
        delete accountantToCurve[msg.sender].lastAdaptationTimestamp;

        emit AdaptiveCurveYdmInitialized(
            msg.sender, curve.discountToTargetAtZeroUtilWAD, _yieldShareAtTargetUtilWAD, curve.premiumToTargetAtFullUtilWAD, _maxAdaptationSpeedWAD
        );
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
     * @return newYieldShareAtTargetWAD The updated yield share at target utilization after adaptation, scaled to WAD
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
            int256 currentAdaptationSpeedWAD = (int256(uint256(curve.maxAdaptationSpeedWAD)) * normalizedDeltaFromTargetWAD) / WAD_INT;
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

        /**
         * Adaptive Curve Yield Distribution Model (adaptive piecewise curve):
         *
         *   Y(U) = Y_T + (Δ * FD_T)   if U < U_T   (below target)
         *          Y_T + (Δ * FP_T)   if U >= U_T  (at or above target)
         *
         * Y(U) → Share of the paying tranche's yield routed to the capital pool as a premium
         * U    → Utilization of the service the capital pool provides
         * U_T  → Target utilization (the kink), configured per instance via TARGET_UTILIZATION_WAD
         * Δ    → Normalized delta from target utilization: Δ ∈ [-1, 1]
         *        Above target: Δ = (U - U_T) / (1 - U_T)
         *        Below target: Δ = (U - U_T) / U_T
         * FD_T → Fixed Discount to Target: the spread below Y_T at 0% utilization (Y_T - Y_0)
         * FP_T → Fixed Premium to Target: the spread above Y_T at 100% utilization (Y_100 - Y_T)
         * Y_T  → yield share at target utilization (adapts over time based on market forces)
         *
         * Key properties:
         * - At U = U_T (target): Y(U) = Y_T
         * - At U = 1.0 (full):   Y(U) = Y_T + FP_T = Y_100
         * - At U = 0.0 (empty):  Y(U) = Y_T - FD_T = Y_0
         *
         * Adaptation mechanism:
         * - High utilization → Y_T adapts upward → entire curve translates up → the pool receives more yield to attract capital
         * - Low utilization  → Y_T adapts downward → entire curve translates down → the pool receives less yield as capital is abundant
         *
         * FD_T and FP_T are fixed at initialization; the spreads from Y_T remain constant
         * Y_T is the single adaptive parameter that shifts the curve vertically in response to market forces
         */

        // Compute the YDM curve's output with the continuously adapting yield share since the last adaptation
        // Compute the adjustment to the yield share at target depending on the normalized delta from target utilization
        uint256 maxAdjustment = (normalizedDeltaFromTargetWAD < 0 ? curve.discountToTargetAtZeroUtilWAD : curve.premiumToTargetAtFullUtilWAD);
        int256 adjustmentToYieldShareAtTargetWAD = ((normalizedDeltaFromTargetWAD * int256(maxAdjustment)) / WAD_INT);

        // Apply the adjustment and bound the yield share between 0% and 100%
        int256 signedYieldShareWAD = int256(avgYieldShareAtTargetWAD) + adjustmentToYieldShareAtTargetWAD;
        if (signedYieldShareWAD <= 0) {
            yieldShareWAD = 0;
        } else {
            yieldShareWAD = uint256(signedYieldShareWAD);
            if (yieldShareWAD > WAD) yieldShareWAD = WAD;
        }
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
}
