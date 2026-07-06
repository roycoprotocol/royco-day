// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IRoycoDayAccountant } from "../../interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { AssetClaims, Operation, SyncedAccountingState, TrancheType } from "../Types.sol";
import { Math, NAV_UNIT } from "../Units.sol";
import { FeeAndLiquidityPremiumLogic } from "./FeeAndLiquidityPremiumLogic.sol";
import { TrancheClaimsLogic } from "./TrancheClaimsLogic.sol";
import { UtilizationLogic } from "./UtilizationLogic.sol";
import { ValuationLogic } from "./ValuationLogic.sol";

/**
 * @title AccountingSyncLogic
 * @author Waymont
 * @notice Tranche-accounting synchronization for a Royco market: the pre-op and post-op sync, protocol fee and liquidity-premium
 *         processing, the idle liquidity-premium reinvestment, and the sync preview
 */
library AccountingSyncLogic {
    // =============================
    // External Tranche Accounting and Synchronization Functions
    // =============================

    /**
     * @notice Synchronizes and persists the raw and effective NAVs of both tranches
     * @dev Only executes a pre-op sync because there is no operation being executed in the same call as this sync
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function syncTrancheAccounting(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables
    )
        external
        returns (SyncedAccountingState memory state)
    {
        // Execute a NAV accounting sync via the accountant to reconcile PNL
        return _preOpSyncTrancheAccounting($, _immutables);
    }

    /**
     * @notice Syncs the tranche accounting and attempts to reinvest the liquidity tranche's idle liquidity-premium senior shares into its market-making inventory
     * @dev Values the reinvested shares against the freshly synced senior share rate, so a smaller amount can clear the venue's slippage gate when reinvesting the entire idle balance would not
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _stShares The amount of idle liquidity-premium senior shares to reinvest, or type(uint256).max to reinvest the entire idle balance
     */
    function reinvestLiquidityPremium(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        uint256 _stShares
    )
        external
    {
        // Sync first so the reinvestment values the idle premium shares against fresh committed senior state (and stages any newly accrued premium)
        SyncedAccountingState memory state = _preOpSyncTrancheAccounting($, _immutables);
        // Reinvest the requested idle premium shares (type(uint256).max reinvests the entire idle balance) at this sync's post-mint senior share rate
        IRoycoDayKernel(address(this)).attemptLiquidityPremiumReinvestment(_stShares, state.stEffectiveNAV, IERC20(_immutables.seniorTranche).totalSupply());
        // Re-commit the LT raw NAV: the reinvestment settled after the sync's commit, so the committed depth must reflect the freshly deployed LT assets
        _commitPostSyncLiquidityTrancheRawNAV($, _immutables, state);
    }

    /**
     * @notice Previews a synchronization of the raw and effective NAVs of both tranches
     * @dev Does not mutate any state
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _trancheType An enumerator indicating which tranche to execute this preview for
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     * @return claims The claims on ST and JT assets that the specified tranche has denominated in tranche-native units
     * @return totalTrancheShares The total number of shares that exist in the specified tranche after the post-sync mint of its accrued shares: the protocol fee shares for every tranche, plus the liquidity premium shares for the senior tranche
     */
    function previewSyncTrancheAccounting(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        TrancheType _trancheType
    )
        external
        view
        returns (SyncedAccountingState memory state, AssetClaims memory claims, uint256 totalTrancheShares)
    {
        // Preview an accounting sync via the accountant
        state = _previewSyncTrancheAccounting($, _immutables);

        // Derive the asset claims for this tranche
        claims = TrancheClaimsLogic._deriveTrancheAssetClaims($, _immutables, _trancheType, state);

        // Return the requested tranche claims and total shares after the sync mints its premium and protocol fee shares
        if (_trancheType == TrancheType.SENIOR) {
            // Compute ST share supply after the liquidity premium and the ST protocol fee shares are minted
            (,, totalTrancheShares) =
                FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(state, IERC20(_immutables.seniorTranche).totalSupply());
        } else if (_trancheType == TrancheType.JUNIOR) {
            // Compute JT share supply after the JT protocol fee shares are minted
            uint256 jtTotalSupply = IERC20(_immutables.juniorTranche).totalSupply();
            totalTrancheShares = jtTotalSupply
                + ValuationLogic._convertToShares(state.jtProtocolFee, (state.jtEffectiveNAV - state.jtProtocolFee), jtTotalSupply, Math.Rounding.Floor);
        } else {
            // Compute LT share supply after the LT protocol fee shares are minted
            (uint256 liquidityPremiumShares,, uint256 stTotalSupplyAfterMints) =
                FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(state, IERC20(_immutables.seniorTranche).totalSupply());
            // Update the simulated post-mint ST shares owned by LT
            uint256 ltOwnedSeniorTrancheShares = $.ltOwnedSeniorTrancheShares + liquidityPremiumShares;
            claims.stShares = ltOwnedSeniorTrancheShares;
            NAV_UNIT ltEffectiveNAV =
                ValuationLogic._getLiquidityTrancheEffectiveNAV($, state.stEffectiveNAV, stTotalSupplyAfterMints, ltOwnedSeniorTrancheShares);
            uint256 ltTotalSupply = IERC20(_immutables.liquidityTranche).totalSupply();
            totalTrancheShares = ltTotalSupply
                + ValuationLogic._convertToShares(state.ltProtocolFee, (ltEffectiveNAV - state.ltProtocolFee), ltTotalSupply, Math.Rounding.Floor);
        }
    }

    // =============================
    // Internal Tranche Accounting Synchronization Functions
    // =============================

    /**
     * @notice Previews an accounting sync via the accountant
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function _previewSyncTrancheAccounting(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables
    )
        internal
        view
        returns (SyncedAccountingState memory state)
    {
        // Preview a senior/junior accounting sync via the accountant
        state = IRoycoDayAccountant(_immutables.accountant)
            .previewSyncTrancheAccounting(ValuationLogic._getSeniorTrancheRawNAV($), ValuationLogic._getJuniorTrancheRawNAV($));
        // Refresh the liquidity tranche raw NAV and utilization in memory so the preview mirrors execution
        state.ltRawNAV = ValuationLogic._getLiquidityTrancheRawNAV($);
        state.liquidityUtilizationWAD = UtilizationLogic._computeLiquidityUtilization(state.stEffectiveNAV, state.minLiquidityWAD, state.ltRawNAV);
    }

    /**
     * @notice Invokes the accountant to do a pre-operation (deposit and withdrawal) NAV sync and mints any protocol fee shares accrued
     * @dev A sync must be executed before every NAV mutating operation (deposit and withdrawal)
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function _preOpSyncTrancheAccounting(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables
    )
        internal
        returns (SyncedAccountingState memory state)
    {
        // Execute the pre-op PnL synchronization via the accountant
        state = IRoycoDayAccountant(_immutables.accountant)
            .preOpSyncTrancheAccounting(ValuationLogic._getSeniorTrancheRawNAV($), ValuationLogic._getJuniorTrancheRawNAV($));
        // Mint the fee and liquidity premium shares accrued by this sync, caching the senior share rate for any liquidity venue before the premium is reinvested
        FeeAndLiquidityPremiumLogic._processFeesAndLiquidityPremium($, _immutables, state);
        // Commit the liquidity tranche's fresh raw NAV against the post-sync market state
        _commitPostSyncLiquidityTrancheRawNAV($, _immutables, state);
    }

    /**
     * @notice Invokes the accountant to do a NAV sync and mints any protocol fee shares accrued
     * @dev A sync must be executed before every NAV mutating operation (deposit and withdrawal)
     * @notice Returns the asset claims and total tranche shares after minting any fees for the specified tranche
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _trancheType An enumerator indicating which tranche to return claims and total tranche shares for
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     * @return claims The cumulative asset claims that the specified tranche is entitled to
     * @return totalTrancheShares The total shares outstanding in the specified tranche after minting any protocol fee shares
     */
    function _preOpSyncTrancheAccounting(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        TrancheType _trancheType
    )
        internal
        returns (SyncedAccountingState memory state, AssetClaims memory claims, uint256 totalTrancheShares)
    {
        // Execute the pre-op PnL synchronization via the accountant
        state = IRoycoDayAccountant(_immutables.accountant)
            .preOpSyncTrancheAccounting(ValuationLogic._getSeniorTrancheRawNAV($), ValuationLogic._getJuniorTrancheRawNAV($));
        // Mint the fee and liquidity premium shares accrued by this sync, caching the senior share rate for any liquidity venue before the premium is reinvested
        FeeAndLiquidityPremiumLogic._processFeesAndLiquidityPremium($, _immutables, state);
        // Commit the liquidity tranche's fresh raw NAV against the post-sync market state
        _commitPostSyncLiquidityTrancheRawNAV($, _immutables, state);

        // Read the requested tranche's total supply after all shares (fees and premium) have been minted
        if (_trancheType == TrancheType.SENIOR) totalTrancheShares = IERC20(_immutables.seniorTranche).totalSupply();
        else if (_trancheType == TrancheType.JUNIOR) totalTrancheShares = IERC20(_immutables.juniorTranche).totalSupply();
        else totalTrancheShares = IERC20(_immutables.liquidityTranche).totalSupply();

        // Derive the asset claims for the specified tranche
        claims = TrancheClaimsLogic._deriveTrancheAssetClaims($, _immutables, _trancheType, state);
    }

    /**
     * @notice The single post-operation accounting entrypoint for every deposit and redeem path
     * @notice Commits the final state of the accounting after the operation has executed and checks the market's coverage and liquidity requirements
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _op The operation being executed in between the pre and post synchronizations
     * @param _stSelfLiquidationBonusNAV The NAV of assets from JT effective NAV used as a bonus for ST redemptions (only nonzero if _op == ST_REDEEM || LT_REDEEM)
     * @param _enforceCoverageAndLiquidityRequirements Whether to enforce the market's coverage and liquidity requirements applicable to the operation
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function _postOpSyncTrancheAccounting(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        Operation _op,
        NAV_UNIT _stSelfLiquidationBonusNAV,
        bool _enforceCoverageAndLiquidityRequirements
    )
        internal
        returns (SyncedAccountingState memory state)
    {
        // Execute the post-op sync on the accountant, committing the final state of the accounting and enforcing the market's requirements if specified
        state = IRoycoDayAccountant(_immutables.accountant)
            .postOpSyncTrancheAccounting(
                _op,
                ValuationLogic._getSeniorTrancheRawNAV($),
                ValuationLogic._getJuniorTrancheRawNAV($),
                ValuationLogic._getLiquidityTrancheRawNAV($),
                _stSelfLiquidationBonusNAV,
                _enforceCoverageAndLiquidityRequirements
            );
    }

    /**
     * @notice Marks and commits the liquidity tranche's fresh raw NAV and refreshes the in-memory state packet
     * @dev Called after a sync has committed the senior/junior NAVs and this kernel has minted any fee shares (and after any liquidity
     *      tranche venue mutation has settled), so the freshly marked liquidity tranche raw NAV reflects the final post-mint depth and
     *      senior share rate. The committed liquidity tranche raw NAV stays out of the P&L waterfall and the senior share rate provider's dependency loop
     * @dev Refreshes the state packet in place so every downstream consumer reads the most up-to-date values
     * @param _state The synced accounting state to refresh in place
     */
    function _commitPostSyncLiquidityTrancheRawNAV(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        SyncedAccountingState memory _state
    )
        internal
    {
        // Get the post-sync LT raw NAV
        NAV_UNIT ltRawNAV = ValuationLogic._getLiquidityTrancheRawNAV($);
        // Commit the fresh LT raw NAV in the accountant and the derived liquidity utilization in the state packet
        IRoycoDayAccountant(_immutables.accountant).commitLiquidityTrancheRawNAV(ltRawNAV);
        _state.ltRawNAV = ltRawNAV;
        /// AssignmentMutation(`UtilizationLogic._computeLiquidityUtilization(_state.stEffectiveNAV, _state.minLiquidityWAD, ltRawNAV)` |==> `(-1)`) of: `_state.liquidityUtilizationWAD = UtilizationLogic._computeLiquidityUtilization(_state.stEffectiveNAV, _state.minLiquidityWAD, ltRawNAV);`
        _state.liquidityUtilizationWAD = (-1);
    }
}
