// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { ERC20BurnableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import { PausableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IRoycoDayAccountant } from "../../interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { WAD, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../Constants.sol";
import { AssetClaims, MarketState, Operation, SyncedAccountingState, TrancheType } from "../Types.sol";
import { Math, NAV_UNIT, RoycoUnitsMath } from "../Units.sol";
import { AccountingSyncLogic } from "./AccountingSyncLogic.sol";
import { BlacklistLogic } from "./BlacklistLogic.sol";
import { DispatchLogic } from "./DispatchLogic.sol";
import { FeeAndLiquidityPremiumLogic } from "./FeeAndLiquidityPremiumLogic.sol";
import { SelfLiquidationLogic } from "./SelfLiquidationLogic.sol";
import { TrancheClaimsLogic } from "./TrancheClaimsLogic.sol";
import { ValuationLogic } from "./ValuationLogic.sol";

/**
 * @title RedemptionLogic
 * @author Waymont
 * @notice The senior, junior, and liquidity provider tranche redemption flows and max-withdrawable reads for a Royco market
 * @dev Invoked by the kernel via delegatecall
 */
library RedemptionLogic {
    using RoycoUnitsMath for NAV_UNIT;

    // =============================
    // Tranche Redeem Functions
    // =============================

    /**
     * @notice Processes the redemption of a specified number of shares from the senior tranche
     * @dev The function is expected to transfer the collateral assets directly to the receiver, based on the redemption claims
     * @dev ST redemptions are enabled if the market is in a PERPETUAL state
     * @param _isPreview Whether this is a preview of the operation which must not mutate state
     * @param _shares The number of shares to redeem
     * @param _receiver The address that is receiving the assets
     * @return userAssetClaims The distribution of assets that were transferred to the receiver on redemption
     */
    function stRedeem(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        bool _isPreview,
        uint256 _shares,
        address _receiver
    )
        external
        returns (AssetClaims memory userAssetClaims)
    {
        // Screen the asset receiver so redemption proceeds cannot be routed to a blacklisted account
        BlacklistLogic._enforceNotBlacklisted($, _receiver);

        SyncedAccountingState memory state;
        uint256 totalTrancheShares;
        // Execute an accounting sync to reconcile underlying PNL
        (state, userAssetClaims, totalTrancheShares) = AccountingSyncLogic._preOpSyncTrancheAccounting($, _immutables, TrancheType.SENIOR);
        // ST redemptions are disabled during a fixed-term market state
        require(state.marketState == MarketState.PERPETUAL, IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE());

        // Scale the cumulative tranche asset claims by the ratio of shares this user owns of the entire tranche
        // Protocol fee shares were minted in the pre-op sync, so the total tranche shares are up to date
        userAssetClaims = TrancheClaimsLogic._scaleAssetClaims(userAssetClaims, _shares, totalTrancheShares, true);

        // Apply any ST self-liquidation bonus to the redeeming user's asset claims and retrieve the bonus NAV applied
        NAV_UNIT stSelfLiquidationBonusNAV;
        (userAssetClaims, stSelfLiquidationBonusNAV) = SelfLiquidationLogic.applySeniorTrancheSelfLiquidationBonus($, state, userAssetClaims);

        // Withdraw the asset claims from each tranche with the self-liquidation bonus applied and transfer them to the receiver
        TrancheClaimsLogic._withdrawAssets($, _immutables, userAssetClaims, _receiver);

        // Execute a post-redeem sync on accounting
        AccountingSyncLogic._postOpSyncTrancheAccounting($, _immutables, Operation.ST_REDEEM, stSelfLiquidationBonusNAV, false);

        // A preview carries its result out via this revert, unwinding every mutation this flow made
        if (_isPreview) revert DispatchLogic.SIMULATION_RESULT(abi.encode(userAssetClaims));
    }

    /**
     * @notice Processes the redemption of a specified number of shares from the junior tranche
     * @dev The function is expected to transfer the collateral assets directly to the receiver, based on the redemption claims
     * @dev JT redemptions are enabled only in a PERPETUAL market state, granted that the market's coverage requirement is satisfied post-redemption
     * @param _isPreview Whether this is a preview of the operation which must not mutate state
     * @param _shares The number of shares to redeem
     * @param _receiver The address that is receiving the assets
     * @return userAssetClaims The distribution of assets that were transferred to the receiver on redemption
     */
    function jtRedeem(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        bool _isPreview,
        uint256 _shares,
        address _receiver
    )
        external
        returns (AssetClaims memory userAssetClaims)
    {
        // Screen the asset receiver so redemption proceeds cannot be routed to a blacklisted account
        BlacklistLogic._enforceNotBlacklisted($, _receiver);

        // Execute a pre-op sync on accounting
        SyncedAccountingState memory state;
        uint256 totalTrancheShares;
        (state, userAssetClaims, totalTrancheShares) = AccountingSyncLogic._preOpSyncTrancheAccounting($, _immutables, TrancheType.JUNIOR);
        // JT redemptions are disabled during a fixed-term market state
        require(state.marketState == MarketState.PERPETUAL, IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE());

        // Scale the cumulative tranche asset claims by the ratio of shares this user owns of the entire tranche
        // Protocol fee shares were minted in the pre-op sync, so the total tranche shares are up to date
        userAssetClaims = TrancheClaimsLogic._scaleAssetClaims(userAssetClaims, _shares, totalTrancheShares, true);

        // Withdraw the asset claims from each tranche and transfer them to the receiver
        TrancheClaimsLogic._withdrawAssets($, _immutables, userAssetClaims, _receiver);

        // Execute a post-redeem sync on accounting, enforcing the market's coverage requirement post-redemption
        AccountingSyncLogic._postOpSyncTrancheAccounting($, _immutables, Operation.JT_REDEEM, ZERO_NAV_UNITS, true);

        // A preview carries its result out via this revert, unwinding every mutation this flow made
        if (_isPreview) revert DispatchLogic.SIMULATION_RESULT(abi.encode(userAssetClaims));
    }

    /**
     * @notice Processes the redemption of a specified number of shares from the liquidity provider tranche
     * @dev LPT redemptions are enabled only in a PERPETUAL market state, granted that the market's liquidity requirement is satisfied post-redemption
     * @param _isPreview Whether this is a preview of the operation which must not mutate state
     * @param _shares The number of shares to redeem
     * @param _receiver The address that is receiving the assets
     * @return userAssetClaims The distribution of assets that were transferred to the receiver on redemption
     */
    function lptRedeem(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        bool _isPreview,
        uint256 _shares,
        address _receiver
    )
        external
        returns (AssetClaims memory userAssetClaims)
    {
        // Screen the asset receiver so redemption proceeds cannot be routed to a blacklisted account
        BlacklistLogic._enforceNotBlacklisted($, _receiver);

        // Execute a pre-op sync on accounting
        SyncedAccountingState memory state;
        uint256 totalTrancheShares;
        (state, userAssetClaims, totalTrancheShares) = AccountingSyncLogic._preOpSyncTrancheAccounting($, _immutables, TrancheType.LIQUIDITY_PROVIDER);
        // LPT redemptions are disabled during a fixed-term market state
        require(state.marketState == MarketState.PERPETUAL, IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE());

        // Scale the cumulative tranche asset claims by the ratio of shares this user owns of the entire tranche
        // Protocol fee shares were minted in the pre-op sync, so the total tranche shares are up to date
        userAssetClaims = TrancheClaimsLogic._scaleAssetClaims(userAssetClaims, _shares, totalTrancheShares, true);

        // Withdraw the asset claims from each tranche and transfer them to the receiver
        TrancheClaimsLogic._withdrawAssets($, _immutables, userAssetClaims, _receiver);

        // Execute a post-redeem sync on accounting, enforcing the market's liquidity requirement post-redemption
        AccountingSyncLogic._postOpSyncTrancheAccounting($, _immutables, Operation.LPT_REDEEM, ZERO_NAV_UNITS, true);

        // A preview carries its result out via this revert, unwinding every mutation this flow made
        if (_isPreview) revert DispatchLogic.SIMULATION_RESULT(abi.encode(userAssetClaims));
    }

    /**
     * @notice Atomically exits the liquidity provider tranche to the LPT assets' constituent assets: proportionally removes the LPT-asset slice,
     *         redeems the venue-held senior shares to collateral, and returns (collateral + quote) to the receiver
     * @dev LPT multi-asset redemptions are enabled only in a PERPETUAL market state, granted the market's liquidity requirement is satisfied post-redemption
     * @param _isPreview Whether this is a preview of the operation which must not mutate state
     * @param _lptShares The number of LPT shares being redeemed (used to size the proportional LPT-asset slice)
     * @param _minSTSharesOut The minimum senior tranche shares the proportional removal must return (slippage bound)
     * @param _minQuoteAssetsOut The minimum quote to return (slippage bound)
     * @param _receiver The address that receives the collateral and quote
     * @return stClaims The ST redemption asset claims transferred to the receiver (its collateral asset leg)
     * @return quoteAssets The quote assets returned to the receiver
     */
    function lptRedeemMultiAsset(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        bool _isPreview,
        uint256 _lptShares,
        uint256 _minSTSharesOut,
        uint256 _minQuoteAssetsOut,
        address _receiver
    )
        external
        returns (AssetClaims memory stClaims, uint256 quoteAssets)
    {
        // Screen the asset receiver so redemption proceeds cannot be routed to a blacklisted account, before any venue interaction
        BlacklistLogic._enforceNotBlacklisted($, _receiver);

        // Execute a pre-op sync, minting this period's liquidity premium into the kernel's held senior shares so the held pile and the LPT supply are consistent for sizing the redeemer's slice
        (SyncedAccountingState memory state, AssetClaims memory lptClaims, uint256 totalLPTShares) =
            AccountingSyncLogic._preOpSyncTrancheAccounting($, _immutables, TrancheType.LIQUIDITY_PROVIDER);
        // Multi-asset redemptions are disabled during a fixed-term market state
        require(state.marketState == MarketState.PERPETUAL, IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE());

        // An LPT share claims both LPT effective-NAV legs: the deployed LPT assets and the idle liquidity-premium senior shares
        // Compute the LPT assets
        AssetClaims memory userAssetClaims = TrancheClaimsLogic._scaleAssetClaims(lptClaims, _lptShares, totalLPTShares, true);
        // Mark the user's LPT asset claims as withdrawn
        TrancheClaimsLogic._withdrawAssets($, _immutables, userAssetClaims, address(this));

        // Remove the liquidity equivalent to the LPT assets the user has a claim on
        uint256 stSharesWithdrawn;
        NAV_UNIT postOpLPTRawNAV;
        (stSharesWithdrawn, quoteAssets, postOpLPTRawNAV) =
            IRoycoDayKernel(address(this)).removeLiquidity(_isPreview, userAssetClaims.lptAssets, _minSTSharesOut, _minQuoteAssetsOut, _receiver);

        // Redeem all of the redeemer's senior shares from the venue and from the uninvested liquidity premium
        uint256 stSharesToRedeem = stSharesWithdrawn + userAssetClaims.stShares;
        stClaims = TrancheClaimsLogic._scaleAssetClaims(
            TrancheClaimsLogic._deriveTrancheAssetClaims($, _immutables, TrancheType.SENIOR, state),
            stSharesToRedeem,
            IERC20(_immutables.seniorTranche).totalSupply(),
            true
        );

        // Apply any ST self-liquidation bonus to the redeeming user's ST shares claims and retrieve the bonus NAV applied
        NAV_UNIT stSelfLiquidationBonusNAV;
        (stClaims, stSelfLiquidationBonusNAV) = SelfLiquidationLogic.applySeniorTrancheSelfLiquidationBonus($, state, stClaims);

        // Burn the redeemed senior shares and withdraw the bonus-adjusted ST claims to the receiver
        // The quote assets were remitted in the liquidity removal above
        // A preview skips only the burn: the withdrawn senior shares never settled to this kernel and the burn feeds no post-op input
        // NOTE: The final post-op accounts for this ST redemption in addition to the preceding LPT redemption in one batch call
        if (!_isPreview) ERC20BurnableUpgradeable(_immutables.seniorTranche).burn(stSharesToRedeem);
        TrancheClaimsLogic._withdrawAssets($, _immutables, stClaims, _receiver);

        // Execute a post-redeem sync on accounting at the venue-marked LPT raw NAV with the applied ST liquidation bonus
        AccountingSyncLogic._postOpSyncTrancheAccounting($, _immutables, Operation.LPT_MULTI_ASSET_REDEEM, postOpLPTRawNAV, stSelfLiquidationBonusNAV, true);

        // A preview carries its result out via this revert, unwinding every mutation this flow made
        if (_isPreview) revert DispatchLogic.SIMULATION_RESULT(abi.encode(stClaims, quoteAssets));
    }

    // =============================
    // Tranche Max Withdrawable Functions
    // =============================

    /**
     * @notice Returns the maximum amount of assets that can be withdrawn from the senior tranche
     * @dev ST redemptions are allowed in PERPETUAL market states
     * @param _owner The address that is withdrawing the assets
     * @return stClaimNAV The senior tranche's total notional claim on the collateral NAV, denominated in kernel's NAV units
     * @return stMaxWithdrawableNAV The maximum amount of assets that can be withdrawn from the senior tranche, denominated in the kernel's NAV units
     * @return totalTrancheShares The total number of shares that exist in the senior tranche after the post-sync mint of its protocol fee shares and liquidity premium shares
     */
    function stMaxWithdrawable(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        address _owner
    )
        external
        view
        returns (NAV_UNIT stClaimNAV, NAV_UNIT stMaxWithdrawableNAV, uint256 totalTrancheShares)
    {
        // If the owner is blacklisted or the kernel is currently paused, return zero claims
        if (BlacklistLogic._isBlacklisted($, _owner) || PausableUpgradeable(address(this)).paused()) {
            return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);
        }

        // Get the senior tranche's total claim on the market's assets
        SyncedAccountingState memory state;
        (state,, totalTrancheShares) = IRoycoDayKernel(address(this)).previewSyncTrancheAccountingFor(TrancheType.SENIOR);

        // ST redemptions are disabled during a fixed-term market state
        if (state.marketState == MarketState.FIXED_TERM) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);

        // ST redemptions are otherwise unrestricted in a PERPETUAL state: the senior claim never exceeds the collateral NAV under conservation, so its entire effective NAV is withdrawable
        stClaimNAV = state.stEffectiveNAV;
        stMaxWithdrawableNAV = state.stEffectiveNAV;
    }

    /**
     * @notice Returns the maximum amount of assets that can be withdrawn from the junior tranche
     * @dev JT redemptions are allowed only in a PERPETUAL market state, granted that the market's coverage requirement is satisfied post-redemption
     * @param _owner The address that is withdrawing the assets
     * @return jtClaimNAV The junior tranche's total notional claim on the collateral NAV, denominated in kernel's NAV units
     * @return jtMaxWithdrawableNAV The maximum amount of assets that can be withdrawn from the junior tranche, denominated in the kernel's NAV units
     * @return totalTrancheShares The total number of shares that exist in the junior tranche after minting any protocol fee shares post-sync
     */
    function jtMaxWithdrawable(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        address _owner
    )
        external
        view
        returns (NAV_UNIT jtClaimNAV, NAV_UNIT jtMaxWithdrawableNAV, uint256 totalTrancheShares)
    {
        // If the owner is blacklisted or the kernel is currently paused, return zero claims
        if (BlacklistLogic._isBlacklisted($, _owner) || PausableUpgradeable(address(this)).paused()) {
            return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);
        }

        // Get the junior tranche's total claim on the market's assets
        SyncedAccountingState memory state;
        (state,, totalTrancheShares) = IRoycoDayKernel(address(this)).previewSyncTrancheAccountingFor(TrancheType.JUNIOR);

        // JT redemptions are disabled during a fixed-term market state
        if (state.marketState == MarketState.FIXED_TERM) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);

        // The junior tranche's total claim on the collateral NAV is exactly its effective NAV under NAV conservation
        jtClaimNAV = state.jtEffectiveNAV;

        // Get the max withdrawable JT assets in NAV units from the accountant considering the coverage requirement
        jtMaxWithdrawableNAV = IRoycoDayAccountant(_immutables.accountant).maxJTWithdrawal(state);
    }

    /**
     * @notice Returns the maximum amount of assets that can be withdrawn from the liquidity provider tranche
     * @param _owner The address that is withdrawing the assets
     * @return claimOnLPTNAV The notional claims on LPT assets that the liquidity provider tranche has denominated in kernel's NAV units
     * @return lptMaxWithdrawableNAV The maximum amount of assets that can be withdrawn from the liquidity provider tranche, denominated in the kernel's NAV units
     * @return totalTrancheShares The total number of shares that exist in the liquidity provider tranche
     */
    function lptMaxWithdrawable(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        address _owner
    )
        external
        view
        returns (NAV_UNIT claimOnLPTNAV, NAV_UNIT lptMaxWithdrawableNAV, uint256 totalTrancheShares)
    {
        // If the owner is blacklisted or the kernel is currently paused, return zero claims
        if (BlacklistLogic._isBlacklisted($, _owner) || PausableUpgradeable(address(this)).paused()) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);

        // Get the total claims the liquidity provider tranche has on its own assets
        SyncedAccountingState memory state;
        (state,, totalTrancheShares) = IRoycoDayKernel(address(this)).previewSyncTrancheAccountingFor(TrancheType.LIQUIDITY_PROVIDER);

        // LPT redemptions are disabled during a fixed-term market state
        if (state.marketState == MarketState.FIXED_TERM) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);

        // An in-kind redemption pulls a proportional slice of both LPT legs
        claimOnLPTNAV = state.lptRawNAV;
        // The withdrawal is bounded by the market's liquidity requirement
        lptMaxWithdrawableNAV = IRoycoDayAccountant(_immutables.accountant).maxLPTWithdrawal(state);
    }

    /**
     * @notice Returns the maximum amount of assets that can be withdrawn from the liquidity provider tranche via a multi-asset redemption
     * @dev A multi-asset redemption redeems the withdrawn and idle premium senior shares in-flow, reducing the liquidity requirement alongside the withdrawal
     *
     * @dev Liquidity Requirement: LPT_RAW_NAV >= (ST_EFFECTIVE_NAV * MIN_LIQUIDITY)
     * @dev Senior share redemption NAV per unit of LPT raw NAV withdrawn, r: SENIOR_SHARE_REDEMPTION_NAV / LPT_RAW_NAV
     * @dev Max assets withdrawable from LPT multi-asset, z: (LPT_RAW_NAV - z) = ((ST_EFFECTIVE_NAV - (z * r)) * MIN_LIQUIDITY)
     *      Isolate z: z = (LPT_RAW_NAV - (ST_EFFECTIVE_NAV * MIN_LIQUIDITY)) * LPT_RAW_NAV / (LPT_RAW_NAV - (SENIOR_SHARE_REDEMPTION_NAV * MIN_LIQUIDITY))
     *
     * @dev The idle liquidity premium senior shares are assumed unreinvested (the worst case): a reinvestment grows the LPT raw NAV
     *      and its withdrawable surplus by the same premium value, which can only raise the bound
     * @param _owner The address that is withdrawing the assets
     * @return claimOnLPTNAV The notional claims on LPT assets that the liquidity provider tranche has denominated in kernel's NAV units
     * @return lptMaxWithdrawableNAV The maximum amount of assets that can be withdrawn multi-asset, denominated in the kernel's NAV units
     * @return totalTrancheShares The total number of shares that exist in the liquidity provider tranche
     * @dev NON-VIEW: routes the venue removal through its execute-and-revert preview, which mutates no state net
     */
    function lptMaxWithdrawableMultiAsset(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        address _owner
    )
        external
        returns (NAV_UNIT claimOnLPTNAV, NAV_UNIT lptMaxWithdrawableNAV, uint256 totalTrancheShares)
    {
        // If the owner is blacklisted or the kernel is currently paused, return zero claims
        if (BlacklistLogic._isBlacklisted($, _owner) || PausableUpgradeable(address(this)).paused()) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);

        // Get the total claims the liquidity provider tranche has on its own assets
        SyncedAccountingState memory state;
        AssetClaims memory lptClaims;
        (state, lptClaims, totalTrancheShares) = IRoycoDayKernel(address(this)).previewSyncTrancheAccountingFor(TrancheType.LIQUIDITY_PROVIDER);

        // LPT redemptions are disabled during a fixed-term market state
        if (state.marketState == MarketState.FIXED_TERM) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);

        // A multi-asset redemption pulls a proportional slice of both LPT legs
        claimOnLPTNAV = state.lptRawNAV;
        // The withdrawal is bounded by the market's liquidity requirement
        NAV_UNIT lptWithdrawableNAV = IRoycoDayAccountant(_immutables.accountant).maxLPTWithdrawal(state);

        // Compute the senior tranche shares a proportional removal of the entire LPT asset holding would withdraw
        uint256 stSharesWithdrawn;
        if (lptClaims.lptAssets != ZERO_TRANCHE_UNITS) {
            (stSharesWithdrawn,,) = IRoycoDayKernel(address(this)).removeLiquidity(true, lptClaims.lptAssets, 0, 0, address(0));
        }

        // Value the withdrawn and idle premium senior shares at the post-sync senior share rate, rounding down so the requirement reduction is never overstated
        (,, uint256 totalSTShares) =
            FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(state, IERC20(_immutables.seniorTranche).totalSupply());
        NAV_UNIT stSharesRedeemedNAV =
            ValuationLogic._convertToValue((stSharesWithdrawn + lptClaims.stShares), totalSTShares, state.stEffectiveNAV, Math.Rounding.Floor);
        // Compute the reduction in the market's liquidity requirement from redeeming the senior shares in-flow
        NAV_UNIT liquidityRequirementReductionNAV = stSharesRedeemedNAV.mulDiv(state.minLiquidityWAD, WAD, Math.Rounding.Floor);

        // If the requirement reduction outpaces the withdrawal itself, the entire holding is withdrawable unless nothing is withdrawable in kind
        if (liquidityRequirementReductionNAV >= state.lptRawNAV) {
            lptMaxWithdrawableNAV = (lptWithdrawableNAV == ZERO_NAV_UNITS) ? ZERO_NAV_UNITS : state.lptRawNAV;
        } else {
            // Scale the in-kind withdrawable NAV by the requirement reduction, capped at the entire holding
            lptMaxWithdrawableNAV = RoycoUnitsMath.min(
                lptWithdrawableNAV.mulDiv(state.lptRawNAV, (state.lptRawNAV - liquidityRequirementReductionNAV), Math.Rounding.Floor), state.lptRawNAV
            );
        }
    }
}
