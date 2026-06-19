// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IYDM, MarketState } from "../interfaces/IYDM.sol";
import { TARGET_COVERAGE_UTILIZATION_WAD, WAD } from "../libraries/Constants.sol";
import { NAV_UNIT } from "../libraries/Units.sol";
import { DawnUtilsLib } from "../libraries/DawnUtilsLib.sol";

/**
 * @title StaticCurveYDM
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Royco's static curve yield distribution model (YDM)
 * @dev Responsible for computing the yield distribution between the senior and junior tranches of a Royco market
 * @dev The curve is defined as piece-wise function parameterized by the coverageUtilization of a Royco market
 */
contract StaticCurveYDM is IYDM {
    using Math for uint256;

    /**
     * @notice Represents the state of a market's YDM
     * @custom:field yieldShareAtZeroUtilWAD - The JT yield share at zero coverageUtilization, scaled to WAD precision
     * @custom:field slopeLtTargetUtilWAD - The slope when the market's coverageUtilization is less than the target coverageUtilization, scaled to WAD precision
     * @custom:field yieldShareAtTargetWAD - The JT yield share at target coverageUtilization, scaled to WAD precision
     * @custom:field slopeGteTargetUtilWAD - The slope when the market's coverageUtilization is greater than or equal to the target coverageUtilization, scaled to WAD precision
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
     * @param yieldShareAtZeroUtilWAD The JT yield share at zero coverageUtilization, scaled to WAD precision
     * @param slopeLtTargetUtilWAD The slope when the market's coverageUtilization is less than the target coverageUtilization, scaled to WAD precision
     * @param slopeGteTargetUtilWAD The slope when the market's coverageUtilization is greater than or equal to the target coverageUtilization, scaled to WAD precision
     */
    event StaticCurveYdmInitialized(address indexed accountant, uint256 yieldShareAtZeroUtilWAD, uint256 slopeLtTargetUtilWAD, uint256 slopeGteTargetUtilWAD);

    /**
     * @notice Emitted when the JT yield share is updated
     * @param accountant The accountant for the market that the yield share was updated for
     * @param yieldShareWAD The JT yield share output (returned to the accountant)
     */
    event YdmOutput(address indexed accountant, uint256 yieldShareWAD);

    /**
     * @notice Initializes the YDM curve for a particular Royco market
     * @dev Must be called during the initialization of the accountant for the Royco market
     * @dev Setting all three initialization parameters to the same value emulates a fixed JT yield share YDM
     * @param _yieldShareAtZeroUtilWAD The JT yield share at 0% coverageUtilization, scaled to WAD precision
     * @param _yieldShareAtTargetWAD The JT yield share at target coverageUtilization, scaled to WAD precision
     * @param _yieldShareAtFullUtilWAD The JT yield share at 100% coverageUtilization, scaled to WAD precision
     */
    function initializeYDMForMarket(uint64 _yieldShareAtZeroUtilWAD, uint64 _yieldShareAtTargetWAD, uint64 _yieldShareAtFullUtilWAD) external {
        // Ensure that the static YDM curve is valid
        require(
            _yieldShareAtZeroUtilWAD <= _yieldShareAtTargetWAD && _yieldShareAtTargetWAD <= _yieldShareAtFullUtilWAD
                && _yieldShareAtFullUtilWAD <= WAD && _yieldShareAtTargetWAD > 0,
            INVALID_YDM_INITIALIZATION()
        );

        // Initialize the YDM curve for this market (2 SSTOREs: slot0 = y0 + slopeLt, slot1 = yT + slopeGte)
        StaticYieldCurve storage curve = accountantToCurve[msg.sender];
        curve.yieldShareAtZeroUtilWAD = _yieldShareAtZeroUtilWAD;
        curve.slopeLtTargetUtilWAD = _computeSlope(_yieldShareAtZeroUtilWAD, _yieldShareAtTargetWAD, 0, TARGET_COVERAGE_UTILIZATION_WAD);
        curve.yieldShareAtTargetWAD = _yieldShareAtTargetWAD;
        curve.slopeGteTargetUtilWAD = _computeSlope(_yieldShareAtTargetWAD, _yieldShareAtFullUtilWAD, TARGET_COVERAGE_UTILIZATION_WAD, WAD);

        emit StaticCurveYdmInitialized(msg.sender, _yieldShareAtZeroUtilWAD, curve.slopeLtTargetUtilWAD, curve.slopeGteTargetUtilWAD);
    }

    /// @inheritdoc IYDM
    function previewYieldShare(
        MarketState,
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        uint256 _betaWAD,
        uint256 _minCoverageWAD,
        NAV_UNIT _jtEffectiveNAV
    )
        external
        view
        override(IYDM)
        returns (uint256)
    {
        return _yieldShare(_stRawNAV, _jtRawNAV, _betaWAD, _minCoverageWAD, _jtEffectiveNAV);
    }

    /// @inheritdoc IYDM
    function yieldShare(
        MarketState,
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
        yieldShareWAD = _yieldShare(_stRawNAV, _jtRawNAV, _betaWAD, _minCoverageWAD, _jtEffectiveNAV);
        emit YdmOutput(msg.sender, yieldShareWAD);
    }

    /// @dev View helper to compute the instantaneous JT yield share based on the defined static curve
    function _yieldShare(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        uint256 _betaWAD,
        uint256 _minCoverageWAD,
        NAV_UNIT _jtEffectiveNAV
    )
        internal
        view
        returns (uint256)
    {
        /**
         * Yield Distribution Model (piecewise curve):
         *
         *   Y(U) = Y_0 + S_lt * U                if U < 0.9  (below target)
         *        = Y_T + S_gte * (U - 0.9)       if U >= 0.9 (at or above target)
         *
         * Y(U)  → Percentage of ST yield paid to the junior tranche
         * U     → CoverageUtilization = ((ST_RAW_NAV + (JT_RAW_NAV * β)) * COV) / JT_EFFECTIVE_NAV
         * Y_0   → JT yield share at zero coverageUtilization
         * Y_T   → JT yield share at target (90%) coverageUtilization
         * S_lt  → Slope below target coverageUtilization: (Y_T - Y_0) / 0.9
         * S_gte → Slope at or above target coverageUtilization: (Y_full - Y_T) / 0.1
         *
         * Below 90% coverageUtilization, JT yield allocation rises from Y_0 based on S_lt.
         * At or above 90% coverageUtilization, JT yield allocation rises from Y_T based on S_gte,
         * penalizing high coverageUtilization and incentivizing JT deposits or ST withdrawals.
         * Output is capped at 100% when coverageUtilization reaches or exceeds 100%.
         */

        // Compute the coverageUtilization of the market and bound it to 100%
        uint256 coverageUtilizationWAD = DawnUtilsLib.computeCoverageUtilization(_stRawNAV, _jtRawNAV, _betaWAD, _minCoverageWAD, _jtEffectiveNAV);
        if (coverageUtilizationWAD > WAD) coverageUtilizationWAD = WAD;

        // Retrieve the static curve for this market
        StaticYieldCurve storage curve = accountantToCurve[msg.sender];
        uint256 yieldShareAtTargetWAD = curve.yieldShareAtTargetWAD;
        require(yieldShareAtTargetWAD != 0, UNINITIALIZED_YDM());
        // Compute Y(U), rounding in favor the senior tranche
        if (coverageUtilizationWAD < TARGET_COVERAGE_UTILIZATION_WAD) {
            // If coverageUtilization is below the target (kink), apply the first leg of Y(U)
            return uint256(curve.slopeLtTargetUtilWAD).mulDiv(coverageUtilizationWAD, WAD, Math.Rounding.Floor) + curve.yieldShareAtZeroUtilWAD;
        } else {
            // If coverageUtilization is at or above the target (kink), apply the second leg of Y(U)
            return uint256(curve.slopeGteTargetUtilWAD).mulDiv((coverageUtilizationWAD - TARGET_COVERAGE_UTILIZATION_WAD), WAD, Math.Rounding.Floor) + yieldShareAtTargetWAD;
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
        slopeWAD = uint64((_y1WAD - _y0WAD).mulDiv(WAD, (_x1WAD - _x0WAD), Math.Rounding.Floor));
    }
}
