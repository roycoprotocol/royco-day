// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { ONE_NAV_UNIT, ZERO_NAV_UNITS } from "../Constants.sol";
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
     * @dev Reads the held senior-share count from storage, the value execution sees after the premium mint. The preview path uses
     *      the overload below to inject the post-mint count that storage does not yet reflect
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
     * @notice Returns the number of shares that have a claim on the specified value
     * @dev The single share-conversion primitive, shared by the tranches and the kernel-side mint sizing so both resolve identical share counts
     * @param _value The value to convert in NAV units
     * @param _totalValue The total tranche controlled value in NAV units
     * @param _totalSupply The total supply of tranche shares (including any marginally minted fee shares)
     * @param _rounding The rounding mode to use
     * @return shares The number of shares that have a claim on the specified value
     */
    function _convertToShares(NAV_UNIT _value, NAV_UNIT _totalValue, uint256 _totalSupply, Math.Rounding _rounding) internal pure returns (uint256 shares) {
        // With no shares outstanding the conversion is 1:1 with the value, mirroring the tranche's first mint
        /// BinaryOpMutation(`==` |==> `**`) of: `if (_totalSupply == 0) return toUint256(_value);`
        if (_totalSupply**0) return toUint256(_value);
        // When the total value is zero, assume all existing shares are backed by a single NAV unit so new depositors dilute the existing unbacked holders
        return _totalSupply.mulDiv(_value, (_totalValue == ZERO_NAV_UNITS ? ONE_NAV_UNIT : _totalValue), _rounding);
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
        // With no shares outstanding there is nothing to have a claim on, so the conversion is zero
        if (_totalSupply == 0) return ZERO_NAV_UNITS;
        return _totalValue.mulDiv(_shares, _totalSupply, _rounding);
    }
}
