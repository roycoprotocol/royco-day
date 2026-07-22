// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { MAX_MINT_DILUTION_WAD, VIRTUAL_ASSETS, VIRTUAL_SHARES, WAD, ZERO_NAV_UNITS } from "../Constants.sol";
import { Math, NAV_UNIT, RoycoUnitsMath, toUint256 } from "../Units.sol";

/**
 * @title ValuationLogic
 * @author Waymont
 * @notice Tranche NAV valuation for a Royco market: the raw ST/JT/LT NAV reads, the LT effective NAV, and NAV-to-shares conversion
 * @dev Invoked by the kernel via delegatecall
 */
library ValuationLogic {
    using RoycoUnitsMath for NAV_UNIT;
    using RoycoUnitsMath for uint256;

    /**
     * @notice Returns the raw net asset value of the senior tranche denominated in the NAV units (USD, BTC, etc.) for this kernel
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @return stRawNAV The pure net asset value of the senior tranche invested assets
     */
    function _getSeniorTrancheRawNAV(IRoycoDayKernel.RoycoDayKernelState storage $) internal view returns (NAV_UNIT stRawNAV) {
        // Get the yield bearing assets owned by ST and convert them to NAV units via the configured quoter
        return IRoycoDayKernel(address(this)).stConvertTrancheUnitsToNAVUnits($.stOwnedYieldBearingAssets);
    }

    /**
     * @notice Returns the raw net asset value of the junior tranche denominated in the NAV units (USD, BTC, etc.) for this kernel
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @return jtRawNAV The pure net asset value of the junior tranche invested assets
     */
    function _getJuniorTrancheRawNAV(IRoycoDayKernel.RoycoDayKernelState storage $) internal view returns (NAV_UNIT jtRawNAV) {
        // Get the yield bearing assets owned by JT and convert them to NAV units via the configured quoter
        return IRoycoDayKernel(address(this)).jtConvertTrancheUnitsToNAVUnits($.jtOwnedYieldBearingAssets);
    }

    /**
     * @notice Returns the raw net asset value of the liquidity tranche denominated in the NAV units (USD, BTC, etc.) for this kernel
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @return ltRawNAV The pure net asset value of the liquidity tranche invested assets
     */
    function _getLiquidityTrancheRawNAV(IRoycoDayKernel.RoycoDayKernelState storage $) internal view returns (NAV_UNIT ltRawNAV) {
        // Get the yield bearing assets owned by LT and convert them to NAV units via the configured quoter
        return IRoycoDayKernel(address(this)).ltConvertTrancheUnitsToNAVUnits($.ltOwnedYieldBearingAssets);
    }

    /**
     * @notice Returns the effective net asset value (NAV) of the liquidity tranche denominated in the NAV units (USD, BTC, etc.) for this kernel
     * @dev The effective NAV is the liquidity tranche's deployed market-making inventory (its raw NAV) plus the value of the
     *      senior tranche shares it holds from accumulated, not yet reinvested, liquidity premium payments
     * @dev Reads the held senior-share count from storage, the value execution sees after the premium mint
     *      The preview path uses the overload below to inject the post-mint count that storage does not yet reflect
     * @dev The senior NAV and share supply must be mutually consistent: the post-sync effective NAV against the
     *      post-carve-out-mint total supply, so the held senior shares are valued at the correct NAV per share
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _stEffectiveNAV The senior tranche's post-sync effective NAV: the total NAV backing all senior shares after reconciling unrealized PnL
     * @param _totalSeniorTrancheShares The total senior tranche shares outstanding after minting the premium and protocol fee shares
     * @return ltEffectiveNAV The effective net asset value of the liquidity tranche
     */
    function _getLiquidityTrancheEffectiveNAV(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        NAV_UNIT _stEffectiveNAV,
        uint256 _totalSeniorTrancheShares
    )
        internal
        view
        returns (NAV_UNIT ltEffectiveNAV)
    {
        // Value the held senior shares using the count committed to storage (the value execution sees after the premium mint)
        return _getLiquidityTrancheEffectiveNAV($, _stEffectiveNAV, _totalSeniorTrancheShares, $.ltOwnedSeniorTrancheShares);
    }

    /**
     * @notice Returns the effective net asset value of the liquidity tranche for an explicitly supplied held senior-share count
     * @dev The preview path supplies the post-mint held-share count (current storage plus this sync's premium shares) before the
     *      premium mint commits it to storage, so the previewed LT effective NAV matches the value execution computes from storage
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _stEffectiveNAV The senior tranche's post-sync effective NAV: the total NAV backing all senior shares after reconciling unrealized PnL
     * @param _totalSeniorTrancheShares The total senior tranche shares outstanding after minting the premium and protocol fee shares
     * @param _ltOwnedSeniorTrancheShares The senior tranche shares held by the liquidity tranche from accumulated liquidity premium payments
     * @return ltEffectiveNAV The effective net asset value of the liquidity tranche
     */
    function _getLiquidityTrancheEffectiveNAV(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        NAV_UNIT _stEffectiveNAV,
        uint256 _totalSeniorTrancheShares,
        uint256 _ltOwnedSeniorTrancheShares
    )
        internal
        view
        returns (NAV_UNIT ltEffectiveNAV)
    {
        // Get the value of LT's market-making inventory
        NAV_UNIT ltRawNAV = _getLiquidityTrancheRawNAV($);

        // If there are no held senior shares or no senior shares outstanding, the effective NAV is just the raw NAV
        if (_ltOwnedSeniorTrancheShares == 0 || _totalSeniorTrancheShares == 0) return ltRawNAV;

        // The LT effective NAV is the sum of the NAVs of its market-making inventory and its held ST shares
        return (ltRawNAV + _convertToValue(_ltOwnedSeniorTrancheShares, _totalSeniorTrancheShares, _stEffectiveNAV, Math.Rounding.Floor));
    }

    /**
     * @notice Returns the number of shares that have a claim on the specified value, clamped by the protocol's max mint dilution
     * @dev The single share-conversion primitive, shared by the tranches and the kernel-side mint sizing so both resolve identical share counts
     * @dev The mint-dilution clamp: any single mint may own at most MAX_MINT_DILUTION_WAD / WAD of the POST-mint supply, leaving
     *      pre-existing holders at least the complementary (WAD − MAX_MINT_DILUTION_WAD) / WAD sliver
     *      The minted shares therefore
     *      never exceed cap = ⌊supply · MAX_MINT_DILUTION_WAD / (WAD − MAX_MINT_DILUTION_WAD)⌋ (derivation:
     *      minted·WAD ≤ MAX_MINT_DILUTION_WAD·(supply + minted) ⟺ minted·(WAD − MAX_MINT_DILUTION_WAD) ≤ supply·MAX_MINT_DILUTION_WAD)
     * @dev With no shares outstanding the conversion stays 1:1 (a bootstrap mint dilutes nobody, so the clamp is exempt)
     * @param _value The value to convert in NAV units
     * @param _totalValue The total tranche controlled value in NAV units
     * @param _totalSupply The total supply of tranche shares (including any marginally minted fee shares)
     * @param _rounding The rounding mode to use for the fair-priced (unclamped) branch
     * @return shares The number of shares that have a claim on the specified value
     */
    function _convertToShares(NAV_UNIT _value, NAV_UNIT _totalValue, uint256 _totalSupply, Math.Rounding _rounding) internal pure returns (uint256 shares) {
        // A genuinely fresh tranche (no shares AND no backing) mints 1:1
        if (_totalSupply == 0 && _totalValue == ZERO_NAV_UNITS) return toUint256(_value);
        // The effective supply is the total supply plus the virtual shares
        uint256 effectiveSupply = _totalSupply + VIRTUAL_SHARES;
        NAV_UNIT denominator = _totalValue + VIRTUAL_ASSETS;
        // The overflow-free bind test, run before the fair-shares division.
        // fair > cap ⟺ value·(WAD − MAX_MINT_DILUTION_WAD) > denominator·MAX_MINT_DILUTION_WAD
        //           ⟺ ⌈value·(WAD − MAX_MINT_DILUTION_WAD) / MAX_MINT_DILUTION_WAD⌉ > denominator
        if (_value.mulDiv((WAD - MAX_MINT_DILUTION_WAD), MAX_MINT_DILUTION_WAD, Math.Rounding.Ceil) > denominator) {
            // The mint binds the clamp: the mint owns at most MAX_MINT_DILUTION_WAD of the post-mint EFFECTIVE supply
            return Math.mulDiv(effectiveSupply, MAX_MINT_DILUTION_WAD, (WAD - MAX_MINT_DILUTION_WAD));
        }
        return effectiveSupply.mulDiv(_value, denominator, _rounding);
    }

    /**
     * @notice Returns the value (in NAV units) that the specified amount of shares have a claim on
     * @dev The single value-conversion primitive, the inverse of _convertToShares, so a share count and its value round-trip consistently
     * @param _shares The number of shares to convert
     * @param _totalSupply The total supply of tranche shares (including any marginally minted fee shares)
     * @param _totalValue The total tranche controlled value in NAV units
     * @param _rounding The rounding mode to use
     * @return value The value in NAV units that the shares have a claim on
     */
    function _convertToValue(uint256 _shares, uint256 _totalSupply, NAV_UNIT _totalValue, Math.Rounding _rounding) internal pure returns (NAV_UNIT value) {
        // A fresh tranche (no shares, no backing) has nothing to claim
        if (_totalSupply == 0 && _totalValue == ZERO_NAV_UNITS) return ZERO_NAV_UNITS;
        return (_totalValue + VIRTUAL_ASSETS).mulDiv(_shares, _totalSupply + VIRTUAL_SHARES, _rounding);
    }

    /**
     * @notice Returns a tranche share rate: the NAV-unit value of one whole tranche share at the given tranche's total share supply and effective NAV
     * @param _trancheTotalSupply The total tranche share supply the rate is computed against (for the senior tranche, the post-mint supply)
     * @param _trancheEffectiveNAV The tranche's effective NAV backing all of its shares
     * @return rate The NAV-unit value of one whole tranche share, rounded down
     */
    function _computeTrancheShareRate(uint256 _trancheTotalSupply, NAV_UNIT _trancheEffectiveNAV) internal pure returns (NAV_UNIT rate) {
        return _convertToValue(WAD, _trancheTotalSupply, _trancheEffectiveNAV, Math.Rounding.Floor);
    }
}
