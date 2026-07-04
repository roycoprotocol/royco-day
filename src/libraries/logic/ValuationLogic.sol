// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { ZERO_NAV_UNITS } from "../Constants.sol";
import { Math, NAV_UNIT, UnitsMathLib, toNAVUnits, toUint256 } from "../Units.sol";

/**
 * @title ValuationLogic
 * @author Waymont
 * @notice Tranche NAV valuation for a Royco market: the raw ST/JT/LT NAV reads, the LT effective NAV, and NAV-to-shares conversion
 * @dev Invoked by the kernel via delegatecall
 */
library ValuationLogic {
    using UnitsMathLib for NAV_UNIT;
    using UnitsMathLib for uint256;

    // =============================
    // Internal Utility Functions
    // =============================

    /// @notice Returns the raw net asset value of the senior tranche denominated in the NAV units (USD, BTC, etc.) for this kernel
    /// @return stRawNAV The pure net asset value of the senior tranche invested assets
    function _getSeniorTrancheRawNAV(IRoycoDayKernel.RoycoDayKernelState storage $) internal view returns (NAV_UNIT stRawNAV) {
        // Get the yield bearing assets owned by ST and convert them to NAV units via the configured quoter
        return IRoycoDayKernel(address(this)).stConvertTrancheUnitsToNAVUnits($.stOwnedYieldBearingAssets);
    }

    /// @notice Returns the raw net asset value of the junior tranche denominated in the NAV units (USD, BTC, etc.) for this kernel
    /// @return jtRawNAV The pure net asset value of the junior tranche invested assets
    function _getJuniorTrancheRawNAV(IRoycoDayKernel.RoycoDayKernelState storage $) internal view returns (NAV_UNIT jtRawNAV) {
        // Get the yield bearing assets owned by JT and convert them to NAV units via the configured quoter
        return IRoycoDayKernel(address(this)).jtConvertTrancheUnitsToNAVUnits($.jtOwnedYieldBearingAssets);
    }

    /// @notice Returns the raw net asset value of the liquidity tranche denominated in the NAV units (USD, BTC, etc.) for this kernel
    /// @return ltRawNAV The pure net asset value of the liquidity tranche invested assets
    function _getLiquidityTrancheRawNAV(IRoycoDayKernel.RoycoDayKernelState storage $) internal view returns (NAV_UNIT ltRawNAV) {
        // Get the yield bearing assets owned by LT and convert them to NAV units via the configured quoter
        return IRoycoDayKernel(address(this)).ltConvertTrancheUnitsToNAVUnits($.ltOwnedYieldBearingAssets);
    }

    /**
     * @notice Returns the effective net asset value (NAV) of the liquidity tranche denominated in the NAV units (USD, BTC, etc.) for this kernel
     * @dev The effective NAV is the liquidity tranche's deployed market-making inventory (its raw NAV) plus the value of the
     *      senior tranche shares it holds from accumulated, not yet reinvested, liquidity premium payments
     * @dev Reads the held senior-share count from storage, the value execution sees after the premium mint; the preview path uses
     *      the overload below to inject the post-mint count that storage does not yet reflect
     * @dev The senior NAV and share supply must be mutually consistent: the post-sync effective NAV against the
     *      post-carve-out-mint total supply, so the held senior shares are valued at the correct NAV per share
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

        // The LT effective NAV is the sum of the NAVs of its market-making inventory and ST shares
        return (ltRawNAV + _stEffectiveNAV.mulDiv(_ltOwnedSeniorTrancheShares, _totalSeniorTrancheShares, Math.Rounding.Floor));
    }

    /**
     * @notice Converts a NAV value to a tranche share count, mirroring `RoycoVaultTranche._convertToShares`
     * @dev Used to compute the fair senior share count to mint when seeding the venue so it matches a tranche-side mint
     * @param _nav The NAV value being converted to shares
     * @param _totalTrancheNAV The tranche's total controlled NAV (the per-share denominator)
     * @param _totalSupply The tranche's total share supply (including any minted protocol fee shares)
     * @return shares The share count for the specified NAV value, rounded down
     */
    function _navToShares(NAV_UNIT _nav, NAV_UNIT _totalTrancheNAV, uint256 _totalSupply) internal pure returns (uint256 shares) {
        // With no shares outstanding the conversion is 1:1 with the NAV value, mirroring the tranche's first mint
        if (_totalSupply == 0) return toUint256(_nav);
        // When the total tranche NAV is zero, assume the existing supply is backed by a single NAV unit, mirroring the tranche's boundary
        shares = _totalSupply.mulDiv(_nav, (_totalTrancheNAV == ZERO_NAV_UNITS ? toNAVUnits(uint256(1)) : _totalTrancheNAV), Math.Rounding.Floor);
    }
}
