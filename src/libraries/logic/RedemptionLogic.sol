// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { PausableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { IRoycoDayAccountant } from "../../interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { ZERO_NAV_UNITS } from "../Constants.sol";
import { AssetClaims, DispatchMode, MarketState, SyncedAccountingState, TrancheType, toRedeemOperation } from "../Types.sol";
import { NAV_UNIT } from "../Units.sol";
import { AccountingSyncLogic } from "./AccountingSyncLogic.sol";
import { AssetLedgerLogic } from "./AssetLedgerLogic.sol";
import { BlacklistLogic } from "./BlacklistLogic.sol";
import { DispatchLogic } from "./DispatchLogic.sol";
import { SelfLiquidationLogic } from "./SelfLiquidationLogic.sol";

/**
 * @title RedemptionLogic
 * @author Waymont
 * @notice The in-kind tranche redemption flow and max-withdrawable reads for a Royco market
 * @dev Invoked by the kernel via delegatecall
 */
library RedemptionLogic {
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
     * @param _trancheType An enumerator indicating which tranche to redeem from
     * @param _mode The dispatch mode: SIMULATE computes the operation and unwinds every mutation by reverting with its result, EXECUTE settles it
     * @param _shares The number of shares to redeem
     * @param _caller The address that initiated the redemption
     * @param _owner The address whose tranche shares are burned for the redemption, the null address for a simulation's synthetic owner
     * @param _receiver The address that is receiving the assets
     * @return userAssetClaims The distribution of assets that were transferred to the receiver on redemption
     */
    function inkindRedeem(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        TrancheType _trancheType,
        DispatchMode _mode,
        uint256 _shares,
        address _caller,
        address _owner,
        address _receiver
    )
        public
        returns (AssetClaims memory userAssetClaims)
    {
        // Reject a zero-share redemption before any work
        require(_shares != 0, IRoycoDayKernel.MUST_REDEEM_NON_ZERO_SHARES());

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
        AccountingSyncLogic._postOpSyncTrancheAccounting($, _immutables, toRedeemOperation(_trancheType), stSelfLiquidationBonusNAV);

        // Remit the asset claims to the receiver
        AssetLedgerLogic._remitClaims(_immutables, userAssetClaims, _receiver);

        // A preview carries its result out via this revert, unwinding every mutation this flow made
        if (_mode == DispatchMode.SIMULATE) revert DispatchLogic.SIMULATION_RESULT(abi.encode(userAssetClaims));
    }

    // =============================
    // Tranche Max Withdrawable Functions
    // =============================

    /**
     * @notice Returns the maximum amount of assets that can be withdrawn in-kind from the specified tranche
     * @dev Redemptions are allowed only in a PERPETUAL market state
     * @dev ST redemptions are otherwise unrestricted: the senior claim never exceeds the collateral NAV under conservation, so its entire effective NAV is withdrawable
     * @dev JT withdrawals are bounded by the market's coverage requirement and LPT withdrawals by its liquidity requirement
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _trancheType An enumerator indicating which tranche to return the max withdrawable for
     * @param _owner The address that is withdrawing the assets
     * @return claimNAV The specified tranche's total notional claim on its assets, denominated in the kernel's NAV units
     * @return maxWithdrawableNAV The maximum amount of assets that can be withdrawn from the specified tranche, denominated in the kernel's NAV units
     * @return totalTrancheShares The total number of shares that exist in the specified tranche after the post-sync mint of its accrued shares
     */
    function inkindMaxWithdrawable(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        TrancheType _trancheType,
        address _owner
    )
        external
        view
        returns (NAV_UNIT claimNAV, NAV_UNIT maxWithdrawableNAV, uint256 totalTrancheShares)
    {
        // If the owner is blacklisted or the kernel is currently paused, return zero claims
        if (BlacklistLogic._isBlacklisted($, _owner) || PausableUpgradeable(address(this)).paused()) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);

        // Get the specified tranche's total claim on the market's assets
        SyncedAccountingState memory state;
        (state,, totalTrancheShares) = IRoycoDayKernel(address(this)).previewSyncTrancheAccountingFor(_trancheType);

        // Redemptions are disabled during a fixed-term market state
        if (state.marketState == MarketState.FIXED_TERM) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);

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
    }
}
