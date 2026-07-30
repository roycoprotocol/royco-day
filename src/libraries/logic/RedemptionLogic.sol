// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { PausableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IRoycoDayAccountant } from "../../interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { Cache, CacheKey } from "../Cache.sol";
import { WAD, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../Constants.sol";
import { AssetClaims, DispatchMode, MarketState, SyncedAccountingState, TrancheType, toRedemptionOperation } from "../Types.sol";
import { Math, NAV_UNIT, RoycoUnitsMath, toUint256 } from "../Units.sol";
import { AccountingSyncLogic } from "./AccountingSyncLogic.sol";
import { AssetLedgerLogic } from "./AssetLedgerLogic.sol";
import { BlacklistLogic } from "./BlacklistLogic.sol";
import { DispatchLogic } from "./DispatchLogic.sol";
import { FeeAndLiquidityPremiumLogic } from "./FeeAndLiquidityPremiumLogic.sol";
import { SelfLiquidationLogic } from "./SelfLiquidationLogic.sol";
import { ValuationLogic } from "./ValuationLogic.sol";

/**
 * @title RedemptionLogic
 * @author Waymont
 * @notice The in-kind and multi-asset tranche redemption flows and max-withdrawable reads for a Royco market
 * @dev Invoked by the kernel via delegatecall
 */
library RedemptionLogic {
    using RoycoUnitsMath for NAV_UNIT;

    // =============================
    // Tranche Redeem Functions
    // =============================

    /**
     * @notice Processes the in-kind redemption of a specified number of shares of the specified tranche's own assets
     * @dev The function is expected to transfer the redeemed assets directly to the receiver, based on the redemption claims
     * @dev Screens the caller, owner, and receiver against the market's blacklist so no blacklisted account can initiate, source, or receive the redemption
     * @dev Burns the owner's shares after scaling their claims against the pre-burn supply
     * @dev A null owner is a simulation's synthetic owner holding no real shares, so only it skips the burn
     * @dev Redemptions are enabled only in a PERPETUAL market state, the JT redemption granted that the market's coverage requirement
     *      and the LPT redemption granted that the market's liquidity requirement are satisfied post-redemption
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _mode The dispatch mode: SIMULATE computes the operation and unwinds every mutation by reverting with its result, EXECUTE settles it
     * @param _trancheType An enumerator indicating which tranche to redeem from
     * @param _shares The number of shares to redeem
     * @param _caller The address that initiated the redemption
     * @param _owner The address whose tranche shares are burned for the redemption, the null address for a simulation's synthetic owner
     * @param _receiver The address that is receiving the assets
     * @return userAssetClaims The distribution of assets that were transferred to the receiver on redemption
     */
    function inkindRedeem(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        DispatchMode _mode,
        TrancheType _trancheType,
        uint256 _shares,
        address _caller,
        address _owner,
        address _receiver
    )
        public
        returns (AssetClaims memory userAssetClaims)
    {
        // Reject a zero-share redemption before any work
        require(_shares != 0, IRoycoDayKernel.MUST_REDEMPTION_NON_ZERO_SHARES());

        // Screen the redemption's involved accounts against the market's blacklist so no blacklisted account can initiate, source, or receive the redemption
        BlacklistLogic._enforceNotBlacklisted($, _caller, _owner, _receiver);

        uint256 totalTrancheShares;
        // Execute an accounting sync to reconcile underlying PNL and read the redeemed tranche's post-mint claims and supply
        SyncedAccountingState memory state;
        (state, userAssetClaims, totalTrancheShares) = AccountingSyncLogic._preOpSyncTrancheAccounting($, _immutables, _trancheType);
        // Redemptions are disabled during a fixed-term market state
        require(state.marketState == MarketState.PERPETUAL, IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE());

        // Scale the cumulative tranche asset claims by the ratio of shares this user owns of the entire tranche
        // Protocol fee shares were minted in the pre-op sync, so the total tranche shares are up to date
        userAssetClaims = AssetLedgerLogic._scaleAssetClaims(userAssetClaims, _shares, totalTrancheShares, true);

        // Apply any ST self-liquidation bonus to the redeeming user's asset claims and retrieve the bonus NAV applied
        NAV_UNIT stSelfLiquidationBonusNAV;
        if (_trancheType == TrancheType.SENIOR) {
            (userAssetClaims, stSelfLiquidationBonusNAV) = SelfLiquidationLogic.applySeniorTrancheSelfLiquidationBonus($, state, userAssetClaims);
        }

        // Debit the withdrawn asset claims from the tranche ledgers
        AssetLedgerLogic._debitAssets($, userAssetClaims);

        // Burn the owner's redeemed shares, their claims were scaled against the pre-burn supply above
        // A null owner is a simulation's synthetic owner holding no real shares, so only it skips the burn, which feeds no downstream input in this flow
        // The tranche's allowance gate makes a null owner unreachable in execution, so a skipped burn never skips ownership enforcement
        if (_owner != address(0)) IRoycoVaultTranche(AssetLedgerLogic._getTrancheAddress(_immutables, _trancheType)).kernelBurn(_owner, _shares);

        // Execute a post-redeem sync on accounting, enforcing the market's requirements against the redemption's settled state
        AccountingSyncLogic._postOpSyncTrancheAccounting($, _immutables, toRedemptionOperation(_trancheType), stSelfLiquidationBonusNAV);

        // Remit the asset claims to the receiver
        AssetLedgerLogic._remitClaims(_immutables, userAssetClaims, _receiver);

        // A preview carries its result out via this revert, unwinding every mutation this flow made
        if (_mode == DispatchMode.SIMULATE) revert DispatchLogic.SIMULATION_RESULT(abi.encode(userAssetClaims));
    }

    /**
     * @notice Atomically exits the liquidity provider tranche to the LPT assets' constituent assets: proportionally removes the LPT-asset slice,
     *         redeems the venue-held senior shares to collateral, and returns (collateral + quote) to the receiver
     * @dev Composes the shared redemption legs: an in-kind LPT redemption to the kernel, the proportional venue removal of the redeemed slice, and a senior redemption of the withdrawn and idle premium shares
     * @dev Burns the owner's LPT shares after scaling their claims against the pre-burn supply
     * @dev The flow's intermediate legs defer the liquidity requirement to the final leg's settled state, whose unhealed violation the end-of-flow gate reverts on
     * @dev LPT multi-asset redemptions are enabled only in a PERPETUAL market state, granted the market's liquidity requirement is satisfied post-redemption
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _mode The dispatch mode: SIMULATE computes the operation and unwinds every mutation by reverting with its result, EXECUTE settles it
     * @param _lptShares The number of LPT shares being redeemed (used to size the proportional LPT-asset slice)
     * @param _minSTSharesOut The minimum senior tranche shares the proportional removal must return (slippage bound)
     * @param _minQuoteAssetsOut The minimum quote to return (slippage bound)
     * @param _caller The address that initiated the redemption
     * @param _owner The address whose LPT shares are burned for the redemption, the null address for a simulation's synthetic owner
     * @param _receiver The address that receives the collateral and quote
     * @return stClaims The ST redemption asset claims transferred to the receiver (its collateral asset leg)
     * @return quoteAssets The quote assets returned to the receiver
     */
    function lptRedeemMultiAsset(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        DispatchMode _mode,
        uint256 _lptShares,
        uint256 _minSTSharesOut,
        uint256 _minQuoteAssetsOut,
        address _caller,
        address _owner,
        address _receiver
    )
        external
        returns (AssetClaims memory stClaims, uint256 quoteAssets)
    {
        // Mark the multi-asset flow, whose exit below judges the liquidity requirement at the flow's final settled state
        AccountingSyncLogic._enterMultiAssetFlow();

        // LPT leg: an in-kind LPT redemption of the owner's shares to the kernel itself, leaving the redeemed LPT assets and idle premium senior shares in its custody
        // Its in-flow post-op waives the liquidity requirement the ST leg's post-op enforces on this flow's final settled state
        // All legs run settled in preview and execution alike, this flow's own result revert unwinds them in a preview
        AssetClaims memory lptAssetClaims =
            inkindRedeem($, _immutables, DispatchMode.EXECUTE, TrancheType.LIQUIDITY_PROVIDER, _lptShares, _caller, _owner, address(this));

        // Remove the redeemed LPT assets from the liquidity venue: the senior shares return to the kernel and the quote goes to the receiver
        // The removal settles in both modes since the kernel custodies the BPT, so the ST leg delivers senior shares even in a preview
        uint256 stSharesWithdrawn;
        NAV_UNIT lptAssetPrice;
        (stSharesWithdrawn, quoteAssets, lptAssetPrice) =
            IRoycoDayKernel(address(this)).removeLiquidity(DispatchMode.EXECUTE, lptAssetClaims.lptAssets, _minSTSharesOut, _minQuoteAssetsOut, _receiver);

        // Cache the venue's post-remove price for a preview, the generic flow never assumes the venue leaves live-priceable post-remove state
        // Execution caches nothing: the downstream legs price the settled post-remove venue live at the same mark
        if (_mode == DispatchMode.SIMULATE) Cache._write(CacheKey.LPT_ASSET_PRICE, toUint256(lptAssetPrice));

        // ST leg: a senior redemption of the venue-withdrawn and idle premium shares the kernel holds to collateral for the receiver, skipped when it holds none
        // Its in-flow post-op enforces the liquidity requirement against this flow's final settled state, after the senior unwind shrank the requirement the removal's depth exit raised
        stSharesWithdrawn += lptAssetClaims.stShares;
        if (stSharesWithdrawn != 0) {
            stClaims = inkindRedeem($, _immutables, DispatchMode.EXECUTE, TrancheType.SENIOR, stSharesWithdrawn, _caller, address(this), _receiver);
        }

        // Exit the settled multi-asset flow, reverting on a pending liquidity violation its final settled state never healed
        AccountingSyncLogic._exitMultiAssetFlow();

        // A preview carries its result out via this revert, unwinding every mutation this flow made
        if (_mode == DispatchMode.SIMULATE) revert DispatchLogic.SIMULATION_RESULT(abi.encode(stClaims, quoteAssets));
    }

    // =============================
    // Tranche Max Withdrawable Functions
    // =============================

    /**
     * @notice Returns the maximum number of shares that can be redeemed in-kind from the specified tranche, unbounded by any owner's balance
     * @dev Redemptions are allowed only in a PERPETUAL market state
     * @dev ST redemptions are otherwise unrestricted: the senior claim never exceeds the collateral NAV under conservation, so its entire effective NAV is withdrawable
     * @dev JT withdrawals are bounded by the market's coverage requirement and LPT withdrawals by its liquidity requirement
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _trancheType An enumerator indicating which tranche to return the max redeemable shares for
     * @param _owner The address that is redeeming the shares
     * @return maxRedeemableShares The maximum number of shares that can be redeemed from the specified tranche
     */
    function inkindMaxRedeemable(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        TrancheType _trancheType,
        address _owner
    )
        external
        view
        returns (uint256 maxRedeemableShares)
    {
        // If the owner is blacklisted or the kernel is currently paused, nothing is redeemable
        if (BlacklistLogic._isBlacklisted($, _owner) || PausableUpgradeable(address(this)).paused()) return 0;

        // Get the specified tranche's total claim on the market's assets
        SyncedAccountingState memory state;
        uint256 totalTrancheShares;
        (state,, totalTrancheShares) = IRoycoDayKernel(address(this)).previewSyncTrancheAccountingFor(_trancheType);

        // Redemptions are disabled during a fixed-term market state
        if (state.marketState == MarketState.FIXED_TERM) return 0;

        NAV_UNIT claimNAV;
        NAV_UNIT maxWithdrawableNAV;
        if (_trancheType == TrancheType.SENIOR) {
            // ST redemptions are otherwise unrestricted in a PERPETUAL state: the senior claim never exceeds the collateral NAV under conservation, so its entire effective NAV is withdrawable
            claimNAV = state.stEffectiveNAV;
            maxWithdrawableNAV = state.stEffectiveNAV;
        } else if (_trancheType == TrancheType.JUNIOR) {
            // The junior tranche's total claim on the collateral NAV is exactly its effective NAV under NAV conservation
            claimNAV = state.jtEffectiveNAV;
            // The withdrawal is bounded by the market's coverage requirement
            maxWithdrawableNAV = IRoycoDayAccountant(_immutables.accountant).maxJTWithdrawal(state);
        } else {
            // An in-kind redemption pulls a proportional slice of both LPT legs
            claimNAV = state.lptRawNAV;
            // The withdrawal is bounded by the market's liquidity requirement
            maxWithdrawableNAV = IRoycoDayAccountant(_immutables.accountant).maxLPTWithdrawal(state);
        }

        // With no claim on the assets nothing is redeemable
        if (claimNAV == ZERO_NAV_UNITS) return 0;

        // Price the withdrawable NAV into shares through the same virtual shares primitive as deposits and _scaleAssetClaims
        maxRedeemableShares = ValuationLogic._convertToShares(maxWithdrawableNAV, claimNAV, totalTrancheShares, Math.Rounding.Floor);
    }

    /**
     * @notice Returns the maximum number of shares that can be redeemed from the liquidity provider tranche via a multi-asset redemption, unbounded by any owner's balance
     * @dev A multi-asset redemption redeems the withdrawn and idle premium senior shares in-flow, reducing the liquidity requirement alongside the withdrawal
     *
     * @dev Liquidity Requirement: LPT_RAW_NAV >= (ST_EFFECTIVE_NAV * MIN_LIQUIDITY)
     * @dev Senior share redemption NAV per unit of LPT raw NAV withdrawn, r: SENIOR_SHARE_REDEMPTION_NAV / LPT_RAW_NAV
     * @dev Max assets withdrawable from LPT multi-asset, z: (LPT_RAW_NAV - z) = ((ST_EFFECTIVE_NAV - (z * r)) * MIN_LIQUIDITY)
     *      Isolate z: z = (LPT_RAW_NAV - (ST_EFFECTIVE_NAV * MIN_LIQUIDITY)) * LPT_RAW_NAV / (LPT_RAW_NAV - (SENIOR_SHARE_REDEMPTION_NAV * MIN_LIQUIDITY))
     *
     * @dev NON-VIEW: routes the venue removal through its execute-and-revert preview, which mutates no state net
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _owner The address that is redeeming the shares
     * @return maxRedeemableShares The maximum number of shares that can be redeemed multi-asset from the liquidity provider tranche
     */
    function lptMaxRedeemableMultiAsset(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        address _owner
    )
        external
        returns (uint256 maxRedeemableShares)
    {
        // If the owner is blacklisted or the kernel is currently paused, nothing is redeemable
        if (BlacklistLogic._isBlacklisted($, _owner) || PausableUpgradeable(address(this)).paused()) return 0;

        // Get the total claims the liquidity provider tranche has on its own assets
        SyncedAccountingState memory state;
        AssetClaims memory lptClaims;
        uint256 totalTrancheShares;
        (state, lptClaims, totalTrancheShares) = IRoycoDayKernel(address(this)).previewSyncTrancheAccountingFor(TrancheType.LIQUIDITY_PROVIDER);

        // LPT redemptions are disabled during a fixed-term market state
        if (state.marketState == MarketState.FIXED_TERM) return 0;

        // Compute the senior tranche shares a proportional removal of the entire LPT asset holding would withdraw
        uint256 stSharesWithdrawn;
        if (lptClaims.lptAssets != ZERO_TRANCHE_UNITS) {
            NAV_UNIT lptAssetPrice;
            (stSharesWithdrawn,, lptAssetPrice) = IRoycoDayKernel(address(this)).removeLiquidity(DispatchMode.SIMULATE, lptClaims.lptAssets, 0, 0, address(0));

            // Re-mark the depth at the removal's post-remove mark, the mark the real flow's final settled gate enforces at
            // Cache the mark only around this conversion so no price leaks into the rest of the transaction
            Cache._write(CacheKey.LPT_ASSET_PRICE, toUint256(lptAssetPrice));
            state.lptRawNAV = ValuationLogic._getLiquidityProviderTrancheRawNAV($);
            Cache._delete(CacheKey.LPT_ASSET_PRICE);
        }

        // A multi-asset redemption pulls a proportional slice of both LPT legs
        // The claim and the withdrawal bound share the post-remove mark so their ratio sizes the redeemable share fraction exactly
        NAV_UNIT claimOnLPTNAV = state.lptRawNAV;
        // The withdrawal is bounded by the market's liquidity requirement
        NAV_UNIT lptWithdrawableNAV = IRoycoDayAccountant(_immutables.accountant).maxLPTWithdrawal(state);

        // Value the withdrawn and idle premium senior shares at the post-sync senior share rate, rounding down so the requirement reduction is never overstated
        (,, uint256 totalSTShares) =
            FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(state, IERC20(_immutables.seniorTranche).totalSupply());
        NAV_UNIT stSharesRedeemedNAV =
            ValuationLogic._convertToValue((stSharesWithdrawn + lptClaims.stShares), totalSTShares, state.stEffectiveNAV, Math.Rounding.Floor);
        // Compute the reduction in the market's liquidity requirement from redeeming the senior shares in-flow
        NAV_UNIT liquidityRequirementReductionNAV = stSharesRedeemedNAV.mulDiv(state.minLiquidityWAD, WAD, Math.Rounding.Floor);

        // If the requirement reduction outpaces the withdrawal itself, the entire holding is withdrawable unless nothing is withdrawable in kind
        NAV_UNIT lptMaxWithdrawableNAV;
        if (liquidityRequirementReductionNAV >= state.lptRawNAV) {
            lptMaxWithdrawableNAV = (lptWithdrawableNAV == ZERO_NAV_UNITS) ? ZERO_NAV_UNITS : state.lptRawNAV;
        } else {
            // Scale the in-kind withdrawable NAV by the requirement reduction, capped at the entire holding
            lptMaxWithdrawableNAV = RoycoUnitsMath.min(
                lptWithdrawableNAV.mulDiv(state.lptRawNAV, (state.lptRawNAV - liquidityRequirementReductionNAV), Math.Rounding.Floor), state.lptRawNAV
            );
        }

        // With no claim on the assets nothing is redeemable
        if (claimOnLPTNAV == ZERO_NAV_UNITS) return 0;

        // Price the withdrawable NAV into shares through the same virtual shares primitive as deposits and _scaleAssetClaims
        maxRedeemableShares = ValuationLogic._convertToShares(lptMaxWithdrawableNAV, claimOnLPTNAV, totalTrancheShares, Math.Rounding.Floor);
    }
}
