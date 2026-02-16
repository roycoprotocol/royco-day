// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { WAD_DECIMALS } from "../../../libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../../libraries/Units.sol";
import { RoycoKernel } from "../RoycoKernel.sol";

/**
 * @title InKindAssetsQuoter
 * @notice Quoter for markets where both tranche assets are in-kind in value (can have identical or different precisions)
 * @dev The NAV is expressed in tranche units with WAD (18 decimals) precision
 * @dev Supported use-cases include:
 *      1. Both tranches in the same assets (eg USDC)
 *      2. Tranches in USDC and USDT (USD pegged assets with 6 decimals of precision)
 *      3. Tranches in USDC and USDS (USD pegged assets with 6 and 18 decimals of precision respectively)
 */
abstract contract InKindAssetsQuoter is RoycoKernel {
    /// @notice The scaling factor to convert ST tranche units to and from WAD precision
    uint256 internal immutable ST_SCALE_FACTOR_TO_WAD;

    /// @notice The scaling factor to convert JT tranche units to and from WAD precision
    uint256 internal immutable JT_SCALE_FACTOR_TO_WAD;

    /// @notice Constructs the quoter for in-kind tranche assets
    /// @dev Assumes that the two assets are pegged to the same asset, currency, commodity, etc.
    constructor() {
        // Get the decimals for each tranche's base asset and ensure they are less than or equal to WAD decimals of precision
        uint8 stDecimals = IERC20Metadata(ST_ASSET).decimals();
        uint8 jtDecimals = IERC20Metadata(JT_ASSET).decimals();
        require(stDecimals <= WAD_DECIMALS && jtDecimals <= WAD_DECIMALS, UNSUPPORTED_DECIMALS());

        // Compute the scaling factor that will scale each tranche's asset quantities to and from WAD precision
        // The NAV unit of this quoter is the tranche asset (the same for both tranches)
        ST_SCALE_FACTOR_TO_WAD = 10 ** (WAD_DECIMALS - stDecimals);
        JT_SCALE_FACTOR_TO_WAD = 10 ** (WAD_DECIMALS - jtDecimals);
    }

    /// @inheritdoc RoycoKernel
    /// @dev Scale the ST asset quantity up to NAV units (WAD precision)
    function stConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _stAssets) public view override(RoycoKernel) returns (NAV_UNIT nav) {
        return toNAVUnits(toUint256(_stAssets) * ST_SCALE_FACTOR_TO_WAD);
    }

    /// @inheritdoc RoycoKernel
    /// @dev Scale the JT asset quantity up to NAV units (WAD precision)
    function jtConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _jtAssets) public view override(RoycoKernel) returns (NAV_UNIT nav) {
        return toNAVUnits(toUint256(_jtAssets) * JT_SCALE_FACTOR_TO_WAD);
    }

    /// @inheritdoc RoycoKernel
    /// @dev Scale the NAV quantity (WAD precision) down to ST asset units, rounding down
    function stConvertNAVUnitsToTrancheUnits(NAV_UNIT _nav) public view override(RoycoKernel) returns (TRANCHE_UNIT stAssets) {
        return toTrancheUnits(toUint256(_nav) / ST_SCALE_FACTOR_TO_WAD);
    }

    /// @inheritdoc RoycoKernel
    /// @dev Scale the NAV quantity (WAD precision) down to JT asset units, rounding down
    function jtConvertNAVUnitsToTrancheUnits(NAV_UNIT _nav) public view override(RoycoKernel) returns (TRANCHE_UNIT jtAssets) {
        return toTrancheUnits(toUint256(_nav) / JT_SCALE_FACTOR_TO_WAD);
    }

    /// @inheritdoc RoycoKernel
    /// @dev Does nothing for this quoter
    function _initializeQuoterCache() internal pure virtual override(RoycoKernel) { }

    /// @inheritdoc RoycoKernel
    /// @dev Does nothing for this quoter
    function _clearQuoterCache() internal pure virtual override(RoycoKernel) { }
}
