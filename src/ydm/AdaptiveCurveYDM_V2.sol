// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { FixedPointMathLib } from "../../lib/solady/src/utils/FixedPointMathLib.sol";
import { IYDM, MarketState } from "../interfaces/IYDM.sol";
import { TARGET_COVERAGE_UTILIZATION_WAD, TARGET_COVERAGE_UTILIZATION_WAD_INT, WAD, WAD_INT } from "../libraries/Constants.sol";
import { NAV_UNIT } from "../libraries/Units.sol";
import { DawnUtilsLib } from "../libraries/DawnUtilsLib.sol";

/**
 * @title AdaptiveCurveYDM_V2
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Royco's adaptive curve yield distribution model (YDM) V2
 * @dev Responsible for computing the yield distribution between the senior and junior tranches of a Royco market
 * @dev The curve is defined as an adaptive piece-wise function parameterized by the coverageUtilization of a Royco market, static slopes, and yield share at the kink (Y_T)
 * @dev The curve adapts its yield share at the kink (Y_T) up or down based on the market's relative delta from target coverageUtilization over time
 * @dev The slopes above/below the target coverageUtilization remain static: only Y_T adapts, translating the curve vertically
 * @dev This provides fixed premiums/discounts to Y_T at each coverageUtilization level
 */
contract AdaptiveCurveYDM_V2 is IYDM {
    /**
     * @notice The maximum value for the maximum speed at which a market's curve can adapt at per second, scaled to WAD precision
     * @dev This represents how quickly the curve shifts up or down at the edges, 100% and 0% coverageUtilization respectively
     * @dev The actual speed that the curve shifts at is based on the current relative distance from the target coverageUtilization
     */
    uint256 public constant MAX_CURVE_ADAPTATION_SPEED_WAD = 100e18 / uint256(365 days);

    /// @dev The minimum JT yield share at target coverageUtilization
    /// @dev Set to 1 basis point
    uint256 public constant MIN_JT_YIELD_SHARE_AT_TARGET_WAD = 0.0001e18;

    /// @dev The maximum JT yield share at target coverageUtilization
    uint256 public constant MAX_JT_YIELD_SHARE_AT_TARGET_WAD = WAD;

    /// @dev The maximum linear adaptation that can be applied to the curve.
    /// @dev This value is chosen to prevent overflows when computing expWAD
    int256 private constant MAX_LINEAR_ADAPTATION_WAD = 135_305_999_368_893_231_589 - 1;

    /**
     * @notice Represents the state of a market's YDM
     * @custom:field yieldShareAtTargetWAD - The current JT yield share at target coverageUtilization, scaled to WAD precision
     * @custom:field lastAdaptationTimestamp - The last time adaptations were applied to this market's curve
     * @custom:field maxAdaptationSpeedWAD - The max adaptation speed of the curve at the boundaries of coverageUtilization (0% and 100%), scaled to WAD precision
     * @custom:field discountToTargetAtZeroUtilWAD - The fixed discount to JT yield share at target coverageUtilization given at 0% coverageUtilization, scaled to WAD precision
     * @custom:field premiumToTargetAtFullUtilWAD - The fixed premium to JT yield share at target coverageUtilization given at 100% coverageUtilization, scaled to WAD precision
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
     * @param discountToTargetAtZeroUtilWAD The fixed discount below Y_T at 0% coverageUtilization (Y_T - Y_0), scaled to WAD
     * @param yieldShareAtTargetUtilWAD The initial JT yield share at target coverageUtilization, scaled to WAD precision
     * @param premiumToTargetAtFullUtilWAD The fixed premium above Y_T at 100% coverageUtilization (Y_100 - Y_T), scaled to WAD
     * @param maxAdaptationSpeedWAD The max adaptation speed of the curve at the boundaries of coverageUtilization (0% and 100%), scaled to WAD precision
     */
    event AdaptiveCurveYdmInitialized(
        address indexed accountant,
        uint256 discountToTargetAtZeroUtilWAD,
        uint256 yieldShareAtTargetUtilWAD,
        uint256 premiumToTargetAtFullUtilWAD,
        uint256 maxAdaptationSpeedWAD
    );

    /**
     * @notice Emitted when the JT yield share is updated and the curve is adapted (in a PERPETUAL state)
     * @param accountant The accountant for the market that the yield share was updated for
     * @param avgYieldShareWAD The average JT yield share during the period since the last adaptation (returned to the accountant)
     * @param newYieldShareAtTargetWAD The new JT yield share at the target coverageUtilization after applying adaptations
     */
    event YdmAdaptedOutput(address indexed accountant, uint256 avgYieldShareWAD, uint256 newYieldShareAtTargetWAD);

    /**
     * @notice Initializes the YDM curve for a particular Royco market
     * @dev Must be called during the initialization of the accountant for the Royco market
     * @param _yieldShareAtZeroUtilWAD The initial JT yield share at 0% coverageUtilization, scaled to WAD precision
     * @param _yieldShareAtTargetUtilWAD The initial JT yield share at target coverageUtilization, scaled to WAD precision
     * @param _yieldShareAtFullUtilWAD The initial JT yield share at 100% coverageUtilization, scaled to WAD precision
     * @param _maxAdaptationSpeedWAD The max adaptation speed of the curve at the boundaries of coverageUtilization (0% and 100%), scaled to WAD precision
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
            _yieldShareAtTargetUtilWAD >= MIN_JT_YIELD_SHARE_AT_TARGET_WAD && _yieldShareAtZeroUtilWAD <= _yieldShareAtTargetUtilWAD
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
    function previewYieldShare(
        MarketState _marketState,
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        uint256 _betaWAD,
        uint256 _minCoverageWAD,
        NAV_UNIT _jtEffectiveNAV
    )
        external
        view
        override(IYDM)
        returns (uint256 yieldShareWAD)
    {
        // Compute and return the current JT yield share post-adaptation
        (yieldShareWAD,) = _yieldShare(_marketState, _stRawNAV, _jtRawNAV, _betaWAD, _minCoverageWAD, _jtEffectiveNAV);
    }

    /// @inheritdoc IYDM
    function yieldShare(
        MarketState _marketState,
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        uint256 _betaWAD,
        uint256 _minCoverageWAD,
        NAV_UNIT _jtEffectiveNAV
    )
        external
        override(IYDM)
        returns (uint256 yieldShareWAD)
    {
        // Compute the current JT yield share and the new position of the curve and post-adaptation
        uint256 newYieldShareAtTargetWAD;
        (yieldShareWAD, newYieldShareAtTargetWAD) = _yieldShare(_marketState, _stRawNAV, _jtRawNAV, _betaWAD, _minCoverageWAD, _jtEffectiveNAV);

        // Apply the adaptations to the curve
        AdaptiveYieldCurve storage curve = accountantToCurve[msg.sender];
        curve.yieldShareAtTargetWAD = uint64(newYieldShareAtTargetWAD);
        curve.lastAdaptationTimestamp = uint32(block.timestamp);

        emit YdmAdaptedOutput(msg.sender, yieldShareWAD, uint256(newYieldShareAtTargetWAD));
    }

    /**
     * @notice Computes the JT yield share for a market, applying any pending adaptation
     * @dev Uses trapezoidal approximation to compute the average continuously adapting yield share for more accurate time-weighted results
     * @param _marketState The state of this Royco market (perpetual or fixed term)
     * @param _stRawNAV The raw net asset value of the senior tranche invested assets
     * @param _jtRawNAV The raw net asset value of the junior tranche invested assets
     * @param _betaWAD The JT's sensitivity to the same downside stress that affects ST scaled to WAD precision
     *                 For example, beta is 0 when JT is in the RFR and 1 when JT is in the same opportunity as senior
     * @param _minCoverageWAD The ratio of current exposure that is expected to be covered by the junior capital scaled to WAD precision
     * @param _jtEffectiveNAV JT's net asset value after applying provided coverage, JT yield, ST yield distribution, and JT losses
     *                        Equivalent to its remaining loss-absorption buffer to cover ST's and its own drawdowns
     * @return yieldShareWAD The percentage of the ST's yield allocated to its JT, scaled to WAD precision
     *                         It is implied that (WAD - yieldShareWAD) will be the percentage allocated to ST, excluding any protocol fees
     * @return newYieldShareAtTargetWAD The updated yield share at target coverageUtilization after adaptation, scaled to WAD
     */
    function _yieldShare(
        MarketState _marketState,
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        uint256 _betaWAD,
        uint256 _minCoverageWAD,
        NAV_UNIT _jtEffectiveNAV
    )
        internal
        view
        returns (uint256 yieldShareWAD, uint256 newYieldShareAtTargetWAD)
    {
        // Compute the coverageUtilization of the market and bound it to 100%
        uint256 coverageUtilizationWAD = DawnUtilsLib.computeCoverageUtilization(_stRawNAV, _jtRawNAV, _betaWAD, _minCoverageWAD, _jtEffectiveNAV);
        if (coverageUtilizationWAD > WAD) coverageUtilizationWAD = WAD;

        // Compute the max delta from the target coverageUtilization in the region of the curve that the market is currently in (above or below the kink)
        uint256 maxDeltaFromTargetInRegionWAD = coverageUtilizationWAD > TARGET_COVERAGE_UTILIZATION_WAD ? (WAD - TARGET_COVERAGE_UTILIZATION_WAD) : TARGET_COVERAGE_UTILIZATION_WAD;
        // Normalize the actual delta from the target coverageUtilization relative to the max delta in the current region
        int256 normalizedDeltaFromTargetWAD = ((int256(coverageUtilizationWAD) - TARGET_COVERAGE_UTILIZATION_WAD_INT) * WAD_INT) / int256(maxDeltaFromTargetInRegionWAD);

        // Retrieve the current YDM curve for the market
        AdaptiveYieldCurve memory curve = accountantToCurve[msg.sender];
        uint256 initialYieldShareAtTargetWAD = curve.yieldShareAtTargetWAD;
        require(initialYieldShareAtTargetWAD != 0, UNINITIALIZED_YDM());
        // Only adapt the curve if the market is in a perpetual state and market forces are enabled to affect coverageUtilization
        uint256 avgYieldShareAtTargetWAD;
        if (_marketState == MarketState.PERPETUAL) {
            // Compute the adaptation speed based on the normalized delta: scale the max adaptation speed by the relative delta from the target based on the region
            int256 currentAdaptationSpeedWAD = (int256(uint256(curve.maxAdaptationSpeedWAD)) * normalizedDeltaFromTargetWAD) / WAD_INT;
            // Compute the linear adaptation that will be applied to the curve based on the speed
            uint256 elapsed = curve.lastAdaptationTimestamp == 0 ? 0 : block.timestamp - curve.lastAdaptationTimestamp;
            int256 linearAdaptationWAD = currentAdaptationSpeedWAD * int256(elapsed);

            // Compute the new JT yield share at target coverageUtilization
            newYieldShareAtTargetWAD = _computeYieldShareAtTarget(initialYieldShareAtTargetWAD, linearAdaptationWAD);

            // Compute the average JT yield share at target coverageUtilization
            uint256 midYieldShareAtTargetWAD = _computeYieldShareAtTarget(initialYieldShareAtTargetWAD, linearAdaptationWAD / 2);
            avgYieldShareAtTargetWAD = (initialYieldShareAtTargetWAD + newYieldShareAtTargetWAD + (2 * midYieldShareAtTargetWAD)) / 4;
        } else {
            newYieldShareAtTargetWAD = avgYieldShareAtTargetWAD = initialYieldShareAtTargetWAD;
        }

        /**
         * Adaptive Curve Yield Distribution Model (adaptive piecewise curve):
         *
         *   Y(U) = Y_T + (Δ * FD_T)   if U < 0.9   (below target)
         *          Y_T + (Δ * FP_T)   if U >= 0.9  (at or above target)
         *
         * Y(U) → Percentage of ST yield paid to the junior tranche
         * U    → CoverageUtilization = ((ST_RAW_NAV + (JT_RAW_NAV * β)) * COV) / JT_EFFECTIVE_NAV
         * Δ    → Normalized delta from target coverageUtilization: Δ ∈ [-1, 1]
         *        Above target: Δ = (U - 0.9) / 0.1
         *        Below target: Δ = (U - 0.9) / 0.9
         * FD_T → Fixed Discount to Target: the spread below Y_T at 0% coverageUtilization (Y_T - Y_0)
         * FP_T → Fixed Premium to Target: the spread above Y_T at 100% coverageUtilization (Y_100 - Y_T)
         * Y_T  → JT yield share at target coverageUtilization (adapts over time based on market forces)
         *
         * Key properties:
         * - At U = 0.9 (target): Y(U) = Y_T
         * - At U = 1.0 (full):   Y(U) = Y_T + FP_T = Y_100
         * - At U = 0.0 (empty):  Y(U) = Y_T - FD_T = Y_0
         *
         * Adaptation mechanism:
         * - High coverageUtilization → Y_T adapts upward → entire curve translates up → JT receives more yield to attract deposits
         * - Low coverageUtilization  → Y_T adapts downward → entire curve translates down → JT receives less yield as capital is abundant
         *
         * FD_T and FP_T are fixed at initialization; the spreads from Y_T remain constant
         * Y_T is the single adaptive parameter that shifts the curve vertically in response to market forces
         */

        // Compute the YDM curve's output with the continuously adapting JT yield share since the last adaptation
        // Compute the adjustment to the JT yield share at target depending on the normalized delta from target coverageUtilization
        uint256 maxAdjustment = (normalizedDeltaFromTargetWAD < 0 ? curve.discountToTargetAtZeroUtilWAD : curve.premiumToTargetAtFullUtilWAD);
        int256 adjustmentToYieldShareAtTargetWAD = ((normalizedDeltaFromTargetWAD * int256(maxAdjustment)) / WAD_INT);

        // Apply the adjustment and bound the JT yield share between 0% and 100%
        int256 signedYieldShareWAD = int256(avgYieldShareAtTargetWAD) + adjustmentToYieldShareAtTargetWAD;
        if (signedYieldShareWAD <= 0) {
            yieldShareWAD = 0;
        } else {
            yieldShareWAD = uint256(signedYieldShareWAD);
            if (yieldShareWAD > WAD) yieldShareWAD = WAD;
        }
    }

    /**
     * @notice Computes the JT yield share at target coverageUtilization for a market post-adaptation
     * @param _lastYieldShareAtTargetWAD The last recorded JT yield share at target coverageUtilization
     * @param _linearAdaptationWAD The linear adaptation to apply to the curve based on the normalized delta, time elapsed, and speed of adaptation
     * @return yieldShareAtTargetWAD The JT yield share at target coverageUtilization after applying the adaptation
     */
    function _computeYieldShareAtTarget(
        uint256 _lastYieldShareAtTargetWAD,
        int256 _linearAdaptationWAD
    )
        internal
        pure
        returns (uint256 yieldShareAtTargetWAD)
    {
        // Compute the new JT yield share at the target by applying the exponentiated linear adaptation to the previous yield share
        // Exponentiation ensures that the JT yield share is always non-negative
        // Clamp the linear adaptation to the maximum value to prevent overflows when applying expWAD
        _linearAdaptationWAD = _linearAdaptationWAD > MAX_LINEAR_ADAPTATION_WAD ? MAX_LINEAR_ADAPTATION_WAD : _linearAdaptationWAD;

        yieldShareAtTargetWAD = uint256((int256(_lastYieldShareAtTargetWAD) * FixedPointMathLib.expWad(_linearAdaptationWAD)) / WAD_INT);
        // Clamp the JT yield share to the market defined bounds
        if (yieldShareAtTargetWAD < MIN_JT_YIELD_SHARE_AT_TARGET_WAD) return MIN_JT_YIELD_SHARE_AT_TARGET_WAD;
        if (yieldShareAtTargetWAD > MAX_JT_YIELD_SHARE_AT_TARGET_WAD) return MAX_JT_YIELD_SHARE_AT_TARGET_WAD;
    }
}
