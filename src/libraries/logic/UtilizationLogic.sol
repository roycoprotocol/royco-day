// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
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
     * @dev Formally: COVERAGE_UTILIZATION = (COLLATERAL_NAV * MIN_COVERAGE) / JT_EFFECTIVE_NAV
     * @dev Rounding favors ensuring senior tranche protection
     * @param _collateralNAV The mark-to-market value of the coinvested collateral backing the senior and junior tranches
     * @param _minCoverageWAD The ratio of current total exposure that is expected to be protected by the market's junior capital, scaled to WAD precision
     * @param _jtEffectiveNAV The junior tranche net asset value after absorbing JT losses, providing coverage to ST, and accruing JT yield and ST yield share (risk premium)
     * @return coverageUtilizationWAD The coverage utilization of the Royco market, scaled to WAD precision
     */
    function _computeCoverageUtilization(
        NAV_UNIT _collateralNAV,
        uint256 _minCoverageWAD,
        NAV_UNIT _jtEffectiveNAV
    )
        internal
        pure
        returns (uint256 coverageUtilizationWAD)
    {
        // If there is no minimum coverage requirement or no collateral to provide coverage for, the coverage utilization is 0
        if (_minCoverageWAD == 0 || _collateralNAV == ZERO_NAV_UNITS) return 0;
        // If there is no remaining JT loss-absorption buffer but collateral exists, coverage utilization is effectively infinite
        if (_jtEffectiveNAV == ZERO_NAV_UNITS) return type(uint256).max;
        // Return the computed coverage utilization, rounding in favor of the senior tranche
        coverageUtilizationWAD = _collateralNAV.mulDiv(_minCoverageWAD, _jtEffectiveNAV, Math.Rounding.Ceil);
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
