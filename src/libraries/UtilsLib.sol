// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { WAD, ZERO_NAV_UNITS } from "./Constants.sol";
import { AssetClaims } from "./Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, UnitsMathLib } from "./Units.sol";

/**
 * @title UtilsLib
 * @author Waymont
 * @notice A library providing utility functions for the Royco protocol
 */
library UtilsLib {
    using UnitsMathLib for NAV_UNIT;
    using UnitsMathLib for TRANCHE_UNIT;
    using UnitsMathLib for uint256;

    /**
     * @notice Computes the coverage utilization of the Royco market given the market's state
     * @dev Informally: (total coverage required for exposure) / (loss absorption buffer)
     * @dev Formally: COVERAGE_UTILIZATION = ((ST_RAW_NAV + (JT_RAW_NAV * β)) * MIN_COVERAGE) / JT_EFFECTIVE_NAV
     * @dev Rounding favors ensuring senior tranche protection
     * @param _stRawNAV The raw net asset value of the senior tranche invested assets
     * @param _jtRawNAV The raw net asset value of the junior tranche invested assets
     * @param _betaWAD The JT's sensitivity to the same downside stress that affects ST, scaled to WAD precision
     *                 For example, beta is 0 when JT is in the RFR and 1 when JT is in the same opportunity as senior
     * @param _minCoverageWAD The ratio of current total exposure that is expected to be protected by the market's junior capital, scaled to WAD precision
     * @param _jtEffectiveNAV The junior tranche net asset value after absorbing JT losses, providing coverage to ST, and accruing JT yield and ST yield share (risk premium)
     * @return coverageUtilizationWAD The coverage utilization of the Royco market, scaled to WAD precision
     */
    function computeCoverageUtilization(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        uint256 _betaWAD,
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
        NAV_UNIT totalCoveredExposure = (_stRawNAV + _jtRawNAV.mulDiv(_betaWAD, WAD, Math.Rounding.Ceil));
        // If there is no exposure to provide coverage for, there is nothing the junior buffer needs to protect, so the coverage utilization is 0
        if (totalCoveredExposure == ZERO_NAV_UNITS) return 0;
        // If there is no remaining JT loss-absorption buffer but covered exposure exists, coverage utilization is effectively infinite
        if (_jtEffectiveNAV == ZERO_NAV_UNITS) return type(uint256).max;
        // Return the computed coverage utilization, rounding in favor of the senior tranche
        coverageUtilizationWAD = totalCoveredExposure.mulDiv(_minCoverageWAD, _jtEffectiveNAV, Math.Rounding.Ceil);
    }

    /**
     * @notice Computes the liquidity utilization of the Royco market given the market's state
     * @dev Informally: (total required market making inventory) / (market making inventory)
     * @dev Formally: LIQUIDITY_UTILIZATION = (ST_EFFECTIVE_NAV * MIN_LIQUIDITY) / LT_RAW_NAV
     * @dev Rounding favors ensuring senior tranche liquidity
     * @param _stEffectiveNAV The total net asset value that the senior tranche is entitled to
     * @param _minLiquidityWAD The percentage of the senior tranche NAV that must be in the liquidity tranche's market making inventory, scaled to WAD precision
     * @param _ltRawNAV The raw net asset value of the liquidity tranche's market making inventory (the Balancer BPT)
     * @return liquidityUtilizationWAD The liquidity utilization of the Royco market, scaled to WAD precision
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
        // If there is no senior tranche value to market make or no minimum liquidity requirement, the liquidity utilization is 0
        if (_stEffectiveNAV == ZERO_NAV_UNITS || _minLiquidityWAD == 0) return 0;
        // If there is no market making inventory in the liquidity tranche but there is a minimum required inventory value, the liquidity utilization is effectively infinite
        if (_ltRawNAV == ZERO_NAV_UNITS) return type(uint256).max;
        // Compute the liquidity utilization, rounding in favor of the senior tranche
        liquidityUtilizationWAD = _stEffectiveNAV.mulDiv(_minLiquidityWAD, _ltRawNAV, Math.Rounding.Ceil);
    }

    /**
     * @notice Scales the claims on ST and JT assets of a tranche by a given shares assuming total shares in a vault
     * @param _claims The claims on ST and JT assets of the tranche
     * @param _shares The number of shares to scale the claims by
     * @param _totalTrancheShares The total number of shares that exist in the tranche
     * @return scaledClaims The scaled claims on ST and JT assets of the tranche
     */
    function scaleAssetClaims(AssetClaims memory _claims, uint256 _shares, uint256 _totalTrancheShares)
        internal
        pure
        returns (AssetClaims memory scaledClaims)
    {
        scaledClaims.nav = _claims.nav.mulDiv(_shares, _totalTrancheShares, Math.Rounding.Floor);
        scaledClaims.stAssets = _claims.stAssets.mulDiv(_shares, _totalTrancheShares, Math.Rounding.Floor);
        scaledClaims.jtAssets = _claims.jtAssets.mulDiv(_shares, _totalTrancheShares, Math.Rounding.Floor);
        scaledClaims.ltAssets = _claims.ltAssets.mulDiv(_shares, _totalTrancheShares, Math.Rounding.Floor);
    }

    /**
     * @notice Scales the claims on ST and JT assets of a tranche by a given NAV ratio
     * @param _claims The claims on ST and JT assets of the tranche
     * @param _navNumerator The NAV to use for the numerator
     * @param _navDenominator The NAV to use for the denominator
     * @return scaledClaims The scaled claims on ST and JT assets of the tranche
     */
    function scaleAssetClaims(
        AssetClaims memory _claims,
        NAV_UNIT _navNumerator,
        NAV_UNIT _navDenominator
    )
        internal
        pure
        returns (AssetClaims memory scaledClaims)
    {
        scaledClaims.nav = _claims.nav.mulDiv(_navNumerator, _navDenominator, Math.Rounding.Floor);
        scaledClaims.stAssets = _claims.stAssets.mulDiv(_navNumerator, _navDenominator, Math.Rounding.Floor);
        scaledClaims.jtAssets = _claims.jtAssets.mulDiv(_navNumerator, _navDenominator, Math.Rounding.Floor);
        scaledClaims.ltAssets = _claims.ltAssets.mulDiv(_navNumerator, _navDenominator, Math.Rounding.Floor);
    }
}
