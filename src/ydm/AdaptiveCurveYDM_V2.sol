// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { WAD, WAD_INT } from "../libraries/Constants.sol";
import { BaseAdaptiveCurveYDM } from "./base/BaseAdaptiveCurveYDM.sol";

/**
 * @title AdaptiveCurveYDM_V2
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Royco's adaptive curve yield distribution model (YDM) V2
 * @dev A general-purpose model for paying a tranche's yield as a premium to a capital pool that provides a service to that tranche
 * @dev It is parameterized purely by the utilization of that service, so the same contract prices any tranche-yield premium
 * @dev Utilization is the fraction of the capital pool's service capacity that is currently in use: the ratio of demand for the service the pool provides to the pool's capacity to supply it, scaled to WAD precision
 * @dev At zero utilization the service is unused and the capital is abundant, so it earns the least
 * @dev At WAD utilization demand equals the pool's full capacity, demand beyond capacity is reported above WAD and capped to WAD here
 * @dev The premium rises with utilization so scarcer service is paid more, pulling additional capital into the pool
 * @dev The curve is an adaptive piece-wise function parameterized by the utilization, static slopes, a per-instance target utilization (the kink) supplied at construction, and the yield share at the kink (Y_T)
 * @dev The curve adapts its yield share at the kink (Y_T) up or down based on the market's relative delta from the target utilization over time, the slopes above and below the target remain static, so only Y_T adapts, translating the curve vertically and providing fixed premiums/discounts to Y_T at each utilization level
 */
contract AdaptiveCurveYDM_V2 is BaseAdaptiveCurveYDM {
    /**
     * @notice Represents the state of a market's YDM
     * @custom:field yieldShareAtTargetWAD - The current yield share at target utilization, scaled to WAD precision
     * @custom:field lastAdaptationTimestamp - The last time adaptations were applied to this market's curve
     * @custom:field discountToTargetAtZeroUtilWAD - The fixed discount to yield share at target utilization given at 0% utilization, scaled to WAD precision
     * @custom:field premiumToTargetAtFullUtilWAD - The fixed premium to yield share at target utilization given at 100% utilization, scaled to WAD precision
     */
    struct AdaptiveYieldCurve {
        uint64 yieldShareAtTargetWAD;
        uint32 lastAdaptationTimestamp;
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
     */
    event AdaptiveCurveYdmInitialized(
        address indexed accountant, uint256 discountToTargetAtZeroUtilWAD, uint256 yieldShareAtTargetUtilWAD, uint256 premiumToTargetAtFullUtilWAD
    );

    /**
     * @notice Emitted when the yield share is updated and the curve is adapted (in a PERPETUAL state)
     * @param accountant The accountant for the market that the yield share was updated for
     * @param avgYieldShareWAD The average yield share during the period since the last adaptation (returned to the accountant)
     * @param newYieldShareAtTargetWAD The new yield share at the target utilization after applying adaptations
     */
    event YdmAdaptedOutput(address indexed accountant, uint256 avgYieldShareWAD, uint256 newYieldShareAtTargetWAD);

    /**
     * @notice Sets the per-instance target utilization (the kink), the bounds on the adaptive yield share at target, and the boundary adaptation speed shared by every market this YDM serves
     * @dev Must be greater than zero so the curve regions are well defined when utilization is zero
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
        BaseAdaptiveCurveYDM(_targetUtilizationWAD, _minYieldShareAtTargetWAD, _maxYieldShareAtTargetWAD, _adaptationSpeedAtBoundaryWAD)
    { }

    /**
     * @notice Initializes the YDM curve for a particular Royco market
     * @dev Must be called during the initialization of the accountant for the Royco market
     * @param _yieldShareAtZeroUtilWAD The initial yield share at 0% utilization, scaled to WAD precision
     * @param _yieldShareAtTargetUtilWAD The initial yield share at target utilization, scaled to WAD precision
     * @param _yieldShareAtFullUtilWAD The initial yield share at 100% utilization, scaled to WAD precision
     */
    function initializeYDMForMarket(uint64 _yieldShareAtZeroUtilWAD, uint64 _yieldShareAtTargetUtilWAD, uint64 _yieldShareAtFullUtilWAD) external {
        // Ensure that the YDM curve is valid
        _validateYDMInitialization(_yieldShareAtZeroUtilWAD, _yieldShareAtTargetUtilWAD, _yieldShareAtFullUtilWAD);

        // Initialize the YDM curve for this market
        AdaptiveYieldCurve storage curve = accountantToCurve[msg.sender];
        curve.yieldShareAtTargetWAD = _yieldShareAtTargetUtilWAD;
        curve.discountToTargetAtZeroUtilWAD = (_yieldShareAtTargetUtilWAD - _yieldShareAtZeroUtilWAD);
        curve.premiumToTargetAtFullUtilWAD = (_yieldShareAtFullUtilWAD - _yieldShareAtTargetUtilWAD);
        // Ensure that the last adaptation timestamp is zero on initialization: only pertains to reinitialization
        delete accountantToCurve[msg.sender].lastAdaptationTimestamp;

        emit AdaptiveCurveYdmInitialized(msg.sender, curve.discountToTargetAtZeroUtilWAD, _yieldShareAtTargetUtilWAD, curve.premiumToTargetAtFullUtilWAD);
    }

    /**
     * @inheritdoc BaseAdaptiveCurveYDM
     * @dev Adaptive Curve Yield Distribution Model V2 (adaptive piecewise curve):
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
     * FD_T and FP_T are fixed at initialization, so the spreads from Y_T remain constant
     * Y_T is the single adaptive parameter that shifts the curve vertically in response to market forces
     */
    function _computeYieldShare(int256 _normalizedDeltaFromTargetWAD, uint256 _avgYieldShareAtTargetWAD)
        internal
        view
        override
        returns (uint256 yieldShareWAD)
    {
        // Compute the adjustment to the yield share at target depending on the normalized delta from target utilization
        AdaptiveYieldCurve storage curve = accountantToCurve[msg.sender];
        uint256 maxAdjustment = (_normalizedDeltaFromTargetWAD < 0 ? curve.discountToTargetAtZeroUtilWAD : curve.premiumToTargetAtFullUtilWAD);
        int256 adjustmentToYieldShareAtTargetWAD = ((_normalizedDeltaFromTargetWAD * int256(maxAdjustment)) / WAD_INT);

        // Apply the adjustment and bound the yield share between 0% and 100%
        int256 signedYieldShareWAD = int256(_avgYieldShareAtTargetWAD) + adjustmentToYieldShareAtTargetWAD;
        // Apply the floor and ceil for the outputted yield share
        if (signedYieldShareWAD <= 0) return 0;
        else if (signedYieldShareWAD >= WAD_INT) return WAD;
        else return uint256(signedYieldShareWAD);
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
