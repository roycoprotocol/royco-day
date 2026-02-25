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
     * @notice Computes the utilization of the Royco market given the market's state
     * @dev Informally: total covered exposure / junior loss absorbtion buffer
     * @dev Formally: Utilization = ((ST_RAW_NAV + (JT_RAW_NAV * β)) * COV) / JT_EFFECTIVE_NAV
     * @param _stRawNAV The raw net asset value of the senior tranche invested assets
     * @param _jtRawNAV The raw net asset value of the junior tranche invested assets
     * @param _betaWAD The JT's sensitivity to the same downside stress that affects ST, scaled to WAD precision
     *                 For example, beta is 0 when JT is in the RFR and 1 when JT is in the same opportunity as senior
     * @param _coverageWAD The ratio of current total exposure that is expected to be protected by the market's junior capital, scaled to WAD precision
     * @param _jtEffectiveNAV The junior tranche net asset value after absorbing JT losses, providing coverage to ST, and accruing JT yield and ST yield share (risk premium)
     * @return utilization The utilization of the Royco market, scaled to WAD precision
     */
    function computeUtilization(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        uint256 _betaWAD,
        uint256 _coverageWAD,
        NAV_UNIT _jtEffectiveNAV
    )
        internal
        pure
        returns (uint256 utilization)
    {
        // If there is no senior capital to protect, utilization is 0
        if (_stRawNAV == ZERO_NAV_UNITS) return 0;
        // If there is no remaining JT loss-absorption buffer, utilization is effectively infinite
        if (_jtEffectiveNAV == ZERO_NAV_UNITS) return type(uint256).max;
        // Round in favor of ensuring senior tranche protection
        utilization = _coverageWAD.mulDiv((_stRawNAV + _jtRawNAV.mulDiv(_betaWAD, WAD, Math.Rounding.Ceil)), _jtEffectiveNAV, Math.Rounding.Ceil);
    }

    /**
     * @notice Computes the loan to value (LTV) of the Royco market given the market's state
     * @dev Informally: DEBT / (DEBT + EQUITY)
     * @dev Formally:
     *      DEBT = (ST_EFFECTIVE_NAV + ST_IL)
     *      EQUITY = JT_EFFECTIVE_NAV
     *      LTV = (ST_EFFECTIVE_NAV + ST_IL) / ((ST_EFFECTIVE_NAV + ST_IL) + JT_EFFECTIVE_NAV)
     * @param _stEffectiveNAV The senior tranche net asset value after receiving coverage, ST yield distribution, and ST losses
     * @param _stImpermanentLoss The impermanent loss that the senior tranche has suffered after exhausting JT's loss-absorption buffer
     * @param _jtEffectiveNAV The junior tranche net asset value after giving coverage, JT yield, ST yield distribution, and JT losses
     * @return ltvWAD The loan to value (LTV) of the Royco market, scaled to WAD precision
     */
    function computeLTV(NAV_UNIT _stEffectiveNAV, NAV_UNIT _stImpermanentLoss, NAV_UNIT _jtEffectiveNAV) internal pure returns (uint256 ltvWAD) {
        // Compute debt and value (debt + equity)
        NAV_UNIT debt = (_stEffectiveNAV + _stImpermanentLoss);
        NAV_UNIT value = (debt + _jtEffectiveNAV);
        // If total value is zero, LTV is undefined
        if (value == ZERO_NAV_UNITS) return type(uint256).max;
        // Round in favor of ensuring senior tranche protection
        ltvWAD = WAD.mulDiv(debt, value, Math.Rounding.Ceil);
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
    }

    /**
     * @notice Scales the claims on ST and JT assets of a tranche by a given shares assuming total shares in a vault
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
    }
}
