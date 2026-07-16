// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoSeniorTranche } from "../../interfaces/IRoycoSeniorTranche.sol";
import { IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { Cache, CacheKey } from "../Cache.sol";
import { ZERO_NAV_UNITS } from "../Constants.sol";
import { SyncedAccountingState } from "../Types.sol";
import { Math, NAV_UNIT, toUint256 } from "../Units.sol";
import { ValuationLogic } from "./ValuationLogic.sol";

/**
 * @title FeeAndLiquidityPremiumLogic
 * @author Waymont
 * @notice The post-sync protocol fee and liquidity-premium share mint for a Royco market: the premium/fee split and the mint orchestration
 */
library FeeAndLiquidityPremiumLogic {
    /**
     * @notice Mints the protocol fee shares and the liquidity premium shares accrued by a pre-op sync
     * @dev The liquidity premium is senior yield routed to the LT: it is minted as senior tranche shares the kernel holds for the
     *      liquidity tranche, leaving the senior raw NAV (and thus coverage) unchanged, so the mint is coverage-neutral
     * @dev The premium and ST protocol fee are priced jointly against the pre-sync senior supply, so neither dilutes the other
     * @dev The LT protocol fee is minted last to value the fee against the final ST share supply and LT owned ST shares
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _state The synced accounting state whose accrued liquidity premium and protocol fees are minted
     */
    function _processFeesAndLiquidityPremium(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        SyncedAccountingState memory _state
    )
        internal
    {
        address protocolFeeRecipient = $.protocolFeeRecipient;

        // Split the senior effective NAV into its two senior-share carve-outs (the liquidity premium and the ST protocol fee)
        // at one joint price against the pre-sync senior supply, so neither carve-out dilutes the other
        (uint256 liquidityPremiumShares, uint256 stProtocolFeeShares, uint256 stTotalSupplyAfterMints) =
            _computeSTFeeAndLiquidityPremiumSharesToMint(_state, IERC20(_immutables.seniorTranche).totalSupply());

        // Cache the senior share rate at this sync's post-mint value before the reinvestment (or any venue mark read) consumes it, so an inline senior share move cannot shift the venue's senior-leg mark
        Cache._write(CacheKey.ST_SHARE_RATE, toUint256(ValuationLogic._computeTrancheShareRate(stTotalSupplyAfterMints, _state.stEffectiveNAV)));

        // Mint the liquidity premium as senior tranche shares held by the kernel on behalf of the liquidity tranche
        // The premium is already booked into the senior effective NAV, so minting these shares only reassigns senior appreciation to the LT
        if (liquidityPremiumShares != 0) {
            IRoycoSeniorTranche(_immutables.seniorTranche).mintLiquidityPremiumShares(address(this), liquidityPremiumShares);
            $.ltOwnedSeniorTrancheShares += liquidityPremiumShares;
            // Attempt to deploy the entire staged premium into the LT's market-making inventory, valuing the idle senior shares at the synced senior share rate (effective NAV over the post-mint supply)
            IRoycoDayKernel(address(this)).attemptLiquidityPremiumReinvestment(type(uint256).max, _state.stEffectiveNAV, stTotalSupplyAfterMints);
        }
        // Mint the ST protocol fee shares to the protocol fee recipient, priced identically to the premium shares minted above
        if (stProtocolFeeShares != 0) {
            IRoycoVaultTranche(_immutables.seniorTranche).mintProtocolFeeShares(protocolFeeRecipient, stProtocolFeeShares);
        }
        // If JT fees were accrued, price them against the post-fee junior NAV (the fee dilutes existing holders) and mint to the recipient
        if (_state.jtProtocolFee != ZERO_NAV_UNITS) {
            uint256 jtProtocolFeeShares = ValuationLogic._convertToShares(
                _state.jtProtocolFee, (_state.jtEffectiveNAV - _state.jtProtocolFee), IERC20(_immutables.juniorTranche).totalSupply(), Math.Rounding.Floor
            );
            IRoycoVaultTranche(_immutables.juniorTranche).mintProtocolFeeShares(protocolFeeRecipient, jtProtocolFeeShares);
        }
        // If LT fees were accrued, price them against the post-fee LT effective NAV (its market-making depth plus the idle premium) and mint to the recipient
        if (_state.ltProtocolFee != ZERO_NAV_UNITS) {
            uint256 ltProtocolFeeShares = ValuationLogic._convertToShares(
                _state.ltProtocolFee,
                (ValuationLogic._getLiquidityTrancheEffectiveNAV($, _state.stEffectiveNAV, stTotalSupplyAfterMints) - _state.ltProtocolFee),
                IERC20(_immutables.liquidityTranche).totalSupply(),
                Math.Rounding.Floor
            );
            IRoycoVaultTranche(_immutables.liquidityTranche).mintProtocolFeeShares(protocolFeeRecipient, ltProtocolFeeShares);
        }
    }

    /**
     * @notice Computes the senior tranche shares minted for this sync's senior yield split: the LT liquidity premium and the ST protocol fee
     * @dev Both the premium and the fee are reallocations of value already booked into the senior effective NAV (no assets enter or
     *      leave), so minting them is NAV-neutral and coverage-neutral: the premium reassigns senior appreciation to the LT and the fee to the protocol
     * @dev Both are priced over the same pre-sync supply against one shared denominator, the NAV the pre-existing shares retain net of the premium and fee, so neither dilutes the other
     * @param _state The synced accounting state carrying the senior effective NAV, the liquidity premium, and the ST protocol fee
     * @param _stTotalSupply The total senior tranche share supply before this sync mints the premium and fee shares
     * @return liquidityPremiumShares The senior shares to mint as the LT liquidity premium, rounded down
     * @return stProtocolFeeShares The senior shares to mint as the ST protocol fee, rounded down
     * @return stTotalSupplyAfterMints The total senior tranche supply after minting the premium and fee shares
     */
    function _computeSTFeeAndLiquidityPremiumSharesToMint(
        SyncedAccountingState memory _state,
        uint256 _stTotalSupply
    )
        internal
        pure
        returns (uint256 liquidityPremiumShares, uint256 stProtocolFeeShares, uint256 stTotalSupplyAfterMints)
    {
        // The pre-existing senior shares retain the senior effective NAV net of the premium and fee
        // NOTE: The waterfall enforces that the ST effective NAV is inclusive of the LT premium and ST fees, so the subtraction never underflows
        NAV_UNIT retainedSeniorNAV = (_state.stEffectiveNAV - _state.ltLiquidityPremium - _state.stProtocolFee);

        // Convert each carve-out into senior shares against the retained NAV over the pre-sync supply (the zero-NAV boundary is handled in _convertToShares)
        liquidityPremiumShares = ValuationLogic._convertToShares(_state.ltLiquidityPremium, retainedSeniorNAV, _stTotalSupply, Math.Rounding.Floor);
        stProtocolFeeShares = ValuationLogic._convertToShares(_state.stProtocolFee, retainedSeniorNAV, _stTotalSupply, Math.Rounding.Floor);
        stTotalSupplyAfterMints = (_stTotalSupply + liquidityPremiumShares + stProtocolFeeShares);
    }
}
