// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { WAD, WAD_INT } from "../libraries/Constants.sol";
import { BaseAdaptiveCurveYDM } from "./base/BaseAdaptiveCurveYDM.sol";

/**
 * @title AdaptiveCurveYDM_V1
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Royco's adaptive curve yield distribution model (YDM) V1
 * @dev A general-purpose model for paying a tranche's yield as a premium to a capital pool that provides a service to that tranche
 * @dev It is parameterized purely by the utilization of that service, so the same contract prices any tranche-yield premium
 * @dev Utilization is the fraction of the capital pool's service capacity that is currently in use: the ratio of demand for the service the pool provides to the pool's capacity to supply it, scaled to WAD precision
 * @dev At zero utilization the service is unused and the capital is abundant, so it earns the least. At WAD utilization demand equals the pool's full capacity. Demand beyond capacity is reported above WAD and capped to WAD here
 * @dev The premium rises with utilization so scarcer service is paid more, pulling additional capital into the pool
 * @dev The curve is an adaptive piece-wise function parameterized by the utilization, the steepness of the curve, a per-instance target utilization (the kink) supplied at construction, and the yield share at the kink (Y_T)
 * @dev The curve adapts its yield share at the kink up or down based on the market's relative delta from the target utilization over time. The slopes above and below the kink adapt with it
 */
contract AdaptiveCurveYDM_V1 is BaseAdaptiveCurveYDM {
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
     * @dev Must be greater than zero so the curve regions are well defined when utilization is zero
     * @param _targetUtilizationWAD The target utilization (the kink) for this model, in the range (0, 100%], scaled to WAD precision
     */
    constructor(uint256 _targetUtilizationWAD) BaseAdaptiveCurveYDM(_targetUtilizationWAD, 0.0001e18, WAD, 50e18 / uint256(365 days)) { }

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

    /**
     * @inheritdoc BaseAdaptiveCurveYDM
     * @dev Adaptive Curve Yield Distribution Model V1 (adaptive piecewise curve):
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
    function _computeYieldShare(int256 _normalizedDeltaFromTargetWAD, uint256 _avgYieldShareAtTargetWAD)
        internal
        view
        override
        returns (uint256 yieldShareWAD)
    {
        // Compute the coefficient based on the region of the curve that the market is currently in
        int256 steepnessWAD = int256(uint256(accountantToCurve[msg.sender].steepnessAfterTargetWAD));
        int256 coefficient = (_normalizedDeltaFromTargetWAD < 0)
            ? (WAD_INT - ((WAD_INT ** 2) / steepnessWAD))  // 1 - 1/S if below the target utilization
            : (steepnessWAD - WAD_INT); // S - 1 if at or above the target utilization

        yieldShareWAD = uint256((((coefficient * _normalizedDeltaFromTargetWAD / WAD_INT) + WAD_INT) * int256(_avgYieldShareAtTargetWAD)) / WAD_INT);
        if (yieldShareWAD > WAD) yieldShareWAD = WAD;
    }

    /// @inheritdoc BaseAdaptiveCurveYDM
    function _readAdaptiveCurve() internal view override returns (uint256 yieldShareAtTargetWAD, uint256 lastAdaptationTimestamp) {
        AdaptiveYieldCurve storage curve = accountantToCurve[msg.sender];
        return (curve.yieldShareAtTargetWAD, curve.lastAdaptationTimestamp);
    }

    /// @inheritdoc BaseAdaptiveCurveYDM
    function _writeAdaptiveCurve(uint256 _newYieldShareAtTargetWAD, uint256 _yieldShareWAD) internal override {
        // Apply the adaptations to the curve
        AdaptiveYieldCurve storage curve = accountantToCurve[msg.sender];
        curve.yieldShareAtTargetWAD = uint64(_newYieldShareAtTargetWAD);
        curve.lastAdaptationTimestamp = uint32(block.timestamp);

        emit YdmAdaptedOutput(msg.sender, _yieldShareWAD, _newYieldShareAtTargetWAD);
    }
}
