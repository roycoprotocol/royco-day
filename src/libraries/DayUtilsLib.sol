// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { ZERO_NAV_UNITS } from "./Constants.sol";
import { NAV_UNIT, UnitsMathLib } from "./Units.sol";

/**
 * @title DayUtilsLib
 * @author Waymont
 * @notice A library providing utility functions for the Royco Day protocol
 */
library DayUtilsLib {
    using UnitsMathLib for NAV_UNIT;

    /**
     * @notice Computes the liquidity utilization of the Royco market given the market's state
     * @dev Informally: (total required market making inventory) / (market making inventory)
     * @dev Formally: LIQUIDITY_UTILIZATION = (ST_EFFECTIVE_NAV * MIN_LIQUIDITY) / LT_RAW_NAV
     * @dev Rounding favors ensuring senior tranche liquidity
     * @param _stEffectiveNAV The total net asset value that the senior tranche is entitled to
     * @param _minLiquidityWAD The ratio of current value that the senior tranche is entitled to that is expected to be in the liquidity tranche's market making inventory, scaled to WAD precision
     * @param _ltRawNAV The junior tranche net asset value after absorbing JT losses, providing coverage to ST, and accruing JT yield and ST yield share (risk premium)
     * @return liquidityUtilizationWAD The coverageUtilization of the Royco market, scaled to WAD precision
     */
    function computeLiquidityUtilization(
        NAV_UNIT _stEffectiveNAV,
        uint256 _minLiquidityWAD,
        NAV_UNIT _ltRawNAV
    )
        internal
        pure
        returns (uint256 liquidityUtilizationWAD)
    {
        // If there is no senior tranche value to market make or no minimum requirement, the liquidity utilization is 0
        if (_stEffectiveNAV == ZERO_NAV_UNITS || _minLiquidityWAD == 0) return 0;
        // If there is no market making inventory in the liquidity tranche but there is a minimum required inventory value, the liquidity utilization is effectively infinite
        if (_ltRawNAV == ZERO_NAV_UNITS) return type(uint256).max;
        // Compute the liquidity utilization, rounding in favor of the senior tranche
        liquidityUtilizationWAD = _stEffectiveNAV.mulDiv(_minLiquidityWAD, _ltRawNAV, Math.Rounding.Ceil);
    }
}
