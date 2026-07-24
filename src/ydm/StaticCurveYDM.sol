// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { SafeCast } from "../../lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import { IYDM, MarketState } from "../interfaces/IYDM.sol";
import { WAD } from "../libraries/Constants.sol";
import { BaseYDM } from "./base/BaseYDM.sol";

/**
 * @title StaticCurveYDM
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Royco's static curve yield distribution model (YDM)
 * @dev A general-purpose model for paying a tranche's yield as a premium to a capital pool that provides a service to that tranche
 * @dev It is parameterized purely by the utilization of that service, so the same contract prices any tranche-yield premium
 * @dev Utilization is the fraction of the capital pool's service capacity that is currently in use: the ratio of demand for the service the pool provides to the pool's capacity to supply it, scaled to WAD precision
 * @dev At zero utilization the service is unused and the capital is abundant, so it earns the least
 * @dev At WAD utilization demand equals the pool's full capacity, demand beyond capacity is reported above WAD and capped to WAD here
 * @dev The premium rises with utilization so scarcer service is paid more, pulling additional capital into the pool
 * @dev The curve is a piece-wise function parameterized by the utilization and a per-instance target utilization (the kink) supplied at construction
 */
contract StaticCurveYDM is BaseYDM {
    using Math for uint256;

    /**
     * @notice Represents the state of a market's YDM
     * @custom:field yieldShareAtZeroUtilWAD - The yield share at zero utilization, scaled to WAD precision
     * @custom:field slopeLtTargetUtilWAD - The slope when the market's utilization is less than the target utilization, scaled to WAD precision
     * @custom:field yieldShareAtTargetWAD - The yield share at target utilization, scaled to WAD precision
     * @custom:field slopeGteTargetUtilWAD - The slope when the market's utilization is greater than or equal to the target utilization, scaled to WAD precision
     */
    struct StaticYieldCurve {
        uint64 yieldShareAtZeroUtilWAD;
        uint64 slopeLtTargetUtilWAD;
        uint64 yieldShareAtTargetWAD;
        uint64 slopeGteTargetUtilWAD;
    }

    /// @dev A mapping from market accountants to its market's current YDM curve
    /// @dev The curve is static
    mapping(address accountant => StaticYieldCurve curve) public accountantToCurve;

    /**
     * @notice Emitted when the static curve YDM is initialized for a market
     * @param accountant The accountant for the market that the YDM was initialized for
     * @param yieldShareAtZeroUtilWAD The yield share at zero utilization, scaled to WAD precision
     * @param slopeLtTargetUtilWAD The slope when the market's utilization is less than the target utilization, scaled to WAD precision
     * @param slopeGteTargetUtilWAD The slope when the market's utilization is greater than or equal to the target utilization, scaled to WAD precision
     */
    event StaticCurveYdmInitialized(address indexed accountant, uint256 yieldShareAtZeroUtilWAD, uint256 slopeLtTargetUtilWAD, uint256 slopeGteTargetUtilWAD);

    /**
     * @notice Emitted when the yield share is updated
     * @param accountant The accountant for the market that the yield share was updated for
     * @param yieldShareWAD The yield share output (returned to the accountant)
     */
    event YdmOutput(address indexed accountant, uint256 yieldShareWAD);

    /**
     * @notice Sets the per-instance target utilization (the kink) shared by every market this YDM serves
     * @dev Must be greater than zero so the curve regions are well defined when utilization is zero
     * @param _targetUtilizationWAD The target utilization (the kink) for this model, in the range (0, 100%], scaled to WAD precision
     */
    constructor(uint256 _targetUtilizationWAD) BaseYDM(_targetUtilizationWAD) { }

    /**
     * @notice Initializes the YDM curve for a particular Royco market
     * @dev Must be called during the initialization of the accountant for the Royco market
     * @dev Setting all three initialization parameters to the same value emulates a fixed yield share YDM
     * @param _yieldShareAtZeroUtilWAD The yield share at 0% utilization, scaled to WAD precision
     * @param _yieldShareAtTargetWAD The yield share at target utilization, scaled to WAD precision
     * @param _yieldShareAtFullUtilWAD The yield share at 100% utilization, scaled to WAD precision
     */
    function initializeYDMForMarket(uint64 _yieldShareAtZeroUtilWAD, uint64 _yieldShareAtTargetWAD, uint64 _yieldShareAtFullUtilWAD) external {
        // Ensure that the static YDM curve is valid
        require(
            _yieldShareAtZeroUtilWAD <= _yieldShareAtTargetWAD && _yieldShareAtTargetWAD <= _yieldShareAtFullUtilWAD && _yieldShareAtFullUtilWAD <= WAD
                && _yieldShareAtTargetWAD > 0,
            INVALID_YDM_INITIALIZATION()
        );

        // Initialize the YDM curve for this market (all four fields pack into one storage slot)
        StaticYieldCurve storage curve = accountantToCurve[msg.sender];
        curve.yieldShareAtZeroUtilWAD = _yieldShareAtZeroUtilWAD;
        curve.slopeLtTargetUtilWAD = _computeSlope(_yieldShareAtZeroUtilWAD, _yieldShareAtTargetWAD, 0, TARGET_UTILIZATION_WAD);
        curve.yieldShareAtTargetWAD = _yieldShareAtTargetWAD;
        curve.slopeGteTargetUtilWAD = _computeSlope(_yieldShareAtTargetWAD, _yieldShareAtFullUtilWAD, TARGET_UTILIZATION_WAD, WAD);

        emit StaticCurveYdmInitialized(msg.sender, _yieldShareAtZeroUtilWAD, curve.slopeLtTargetUtilWAD, curve.slopeGteTargetUtilWAD);
    }

    /// @inheritdoc IYDM
    function previewYieldShare(MarketState, uint256 _utilizationWAD) external view override(IYDM) returns (uint256) {
        return _yieldShare(_utilizationWAD);
    }

    /// @inheritdoc IYDM
    function yieldShare(MarketState, uint256 _utilizationWAD) external override(IYDM) returns (uint256 yieldShareWAD) {
        yieldShareWAD = _yieldShare(_utilizationWAD);
        emit YdmOutput(msg.sender, yieldShareWAD);
    }

    /// @dev View helper to compute the instantaneous yield share at the given utilization based on the defined static curve
    function _yieldShare(uint256 _utilizationWAD) internal view returns (uint256) {
        /**
         * Yield Distribution Model (piecewise curve):
         *
         *   Y(U) = Y_0 + S_lt * U                if U < U_T  (below target)
         *        = Y_T + S_gte * (U - U_T)       if U >= U_T (at or above target)
         *
         * Y(U)  → Share of the paying tranche's yield routed to the capital pool as a premium
         * U     → Utilization of the service the capital pool provides
         * U_T   → Target utilization (the kink), configured per instance via TARGET_UTILIZATION_WAD
         * Y_0   → Yield share at zero utilization
         * Y_T   → Yield share at target utilization
         * S_lt  → Slope below target utilization: (Y_T - Y_0) / U_T
         * S_gte → Slope at or above target utilization: (Y_full - Y_T) / (1 - U_T)
         *
         * Below the target, the yield allocation rises from Y_0 based on S_lt
         * At or above the target, the allocation rises from Y_T based on S_gte, penalizing high utilization and
         * incentivizing more capital into the pool or less demand on its service
         * Output is capped at 100% when utilization reaches or exceeds 100%.
         */

        // Bound the supplied utilization to 100%
        uint256 utilizationWAD = _utilizationWAD;
        if (utilizationWAD > WAD) utilizationWAD = WAD;

        // Retrieve the static curve for this market
        StaticYieldCurve storage curve = accountantToCurve[msg.sender];
        uint256 yieldShareAtTargetWAD = curve.yieldShareAtTargetWAD;
        require(yieldShareAtTargetWAD != 0, UNINITIALIZED_YDM());
        // Compute Y(U), rounding down in favor of the paying tranche
        if (utilizationWAD < TARGET_UTILIZATION_WAD) {
            // If utilization is below the target (kink), apply the first leg of Y(U)
            return uint256(curve.slopeLtTargetUtilWAD).mulDiv(utilizationWAD, WAD, Math.Rounding.Floor) + curve.yieldShareAtZeroUtilWAD;
        } else {
            // If utilization is at or above the target (kink), apply the second leg of Y(U)
            return uint256(curve.slopeGteTargetUtilWAD).mulDiv((utilizationWAD - TARGET_UTILIZATION_WAD), WAD, Math.Rounding.Floor) + yieldShareAtTargetWAD;
        }
    }

    /**
     * @notice Computes the slope between two points on the curve: (y1 - y0) / (x1 - x0)
     * @param _y0WAD Y coordinate for point 0, scaled to WAD precision
     * @param _y1WAD Y coordinate for point 1, scaled to WAD precision
     * @param _x0WAD X coordinate for point 0, scaled to WAD precision
     * @param _x1WAD X coordinate for point 1, scaled to WAD precision
     * @return slopeWAD The slope of the line, scaled to WAD precision
     */
    function _computeSlope(uint256 _y0WAD, uint256 _y1WAD, uint256 _x0WAD, uint256 _x1WAD) internal pure returns (uint64 slopeWAD) {
        slopeWAD = SafeCast.toUint64((_y1WAD - _y0WAD).mulDiv(WAD, (_x1WAD - _x0WAD), Math.Rounding.Floor));
    }
}
