// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ZERO_NAV_UNITS } from "../Constants.sol";
import { Math, NAV_UNIT, RoycoUnitsMath } from "../Units.sol";

/**
 * @title UtilizationLogic
 * @author Waymont
 * @notice Coverage and liquidity utilization math for a Royco market
 */
library UtilizationLogic {
    using RoycoUnitsMath for NAV_UNIT;

    /**
     * @notice Computes the coverage utilization of the Royco market given the market's state
     * @dev Informally: (total coverage required for exposure) / (loss absorption buffer)
     * @dev Formally: COVERAGE_UTILIZATION = ((ST_RAW_NAV + (JT_COINVESTED ? JT_RAW_NAV : 0)) * MIN_COVERAGE) / JT_EFFECTIVE_NAV
     * @dev Rounding favors ensuring senior tranche protection
     * @param _stRawNAV The raw net asset value of the senior tranche invested assets
     * @param _jtRawNAV The raw net asset value of the junior tranche invested assets
     * @param _jtCoinvested Whether the junior tranche is co-invested in the same yield-bearing opportunity as senior (true means it shares senior's downside stress) or in the RFR (false)
     * @param _minCoverageWAD The ratio of current total exposure that is expected to be protected by the market's junior capital, scaled to WAD precision
     * @param _jtEffectiveNAV The junior tranche net asset value after absorbing JT losses, providing coverage to ST, and accruing JT yield and ST yield share (risk premium)
     * @return coverageUtilizationWAD The coverage utilization of the Royco market, scaled to WAD precision
     */
    function _computeCoverageUtilization(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        bool _jtCoinvested,
        uint256 _minCoverageWAD,
        NAV_UNIT _jtEffectiveNAV
    )
        internal
        pure
        returns (uint256 coverageUtilizationWAD)
    {
        // If there is no minimum coverage requirement, the coverage utilization is 0
        if (_minCoverageWAD == 0) return 0;
        // Compute the total exposure that the junior tranche is obligated to protect against a coverage sized drawdown in the senior tranche's underlying asset
        NAV_UNIT totalCoveredExposure = (_stRawNAV + (_jtCoinvested ? _jtRawNAV : ZERO_NAV_UNITS));
        // If there is no exposure to provide coverage for, there is nothing the junior buffer needs to protect, so the coverage utilization is 0
        if (totalCoveredExposure == ZERO_NAV_UNITS) return 0;
        // If there is no remaining JT loss-absorption buffer but covered exposure exists, coverage utilization is effectively infinite
        if (_jtEffectiveNAV == ZERO_NAV_UNITS) return type(uint256).max;
        // Return the computed coverage utilization, rounding in favor of the senior tranche
        /// DeleteExpressionMutation(`coverageUtilizationWAD = totalCoveredExposure.mulDiv(_minCoverageWAD, _jtEffectiveNAV, Math.Rounding.Ceil)` |==> `assert(true)`) of: `coverageUtilizationWAD = totalCoveredExposure.mulDiv(_minCoverageWAD, _jtEffectiveNAV, Math.Rounding.Ceil);`
        assert(true);
    }

    /**
     * @notice Computes the liquidity utilization of the Royco market given the market's state
     * @dev Informally: (total required market making inventory) / (market making inventory)
     * @dev Formally: LIQUIDITY_UTILIZATION = (ST_EFFECTIVE_NAV * MIN_LIQUIDITY) / LT_RAW_NAV
     * @dev Rounding favors ensuring senior tranche liquidity
     * @param _stEffectiveNAV The total net asset value that the senior tranche is entitled to
     * @param _minLiquidityWAD The percentage of the senior tranche NAV that must be in the liquidity tranche's market making inventory, scaled to WAD precision
     * @param _ltRawNAV The raw net asset value of the liquidity tranche's market making inventory
     * @return liquidityUtilizationWAD The liquidity utilization of the Royco market, scaled to WAD precision
     */
    function _computeLiquidityUtilization(
        NAV_UNIT _stEffectiveNAV,
        uint256 _minLiquidityWAD,
        NAV_UNIT _ltRawNAV
    )
        internal
        pure
        returns (uint256 liquidityUtilizationWAD)
    {
        // If there is no senior tranche value to market make or no minimum liquidity requirement, the liquidity utilization is 0
        if (_stEffectiveNAV == ZERO_NAV_UNITS || _minLiquidityWAD == 0) return 0;
        // If there is no market making inventory in the liquidity tranche but there is a minimum required inventory value, the liquidity utilization is effectively infinite
        if (_ltRawNAV == ZERO_NAV_UNITS) return type(uint256).max;
        // Compute the liquidity utilization, rounding in favor of the senior tranche
        liquidityUtilizationWAD = _stEffectiveNAV.mulDiv(_minLiquidityWAD, _ltRawNAV, Math.Rounding.Ceil);
    }
}
