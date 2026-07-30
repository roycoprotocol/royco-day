// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IRoycoDayAccountant } from "../../interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { Cache, CacheKey } from "../Cache.sol";
import { WAD } from "../Constants.sol";
import { AssetClaims, Operation, SyncedAccountingState, TrancheType } from "../Types.sol";
import { Math, NAV_UNIT, toUint256 } from "../Units.sol";
import { AssetLedgerLogic } from "./AssetLedgerLogic.sol";
import { FeeAndLiquidityPremiumLogic } from "./FeeAndLiquidityPremiumLogic.sol";
import { UtilizationLogic } from "./UtilizationLogic.sol";
import { ValuationLogic } from "./ValuationLogic.sol";

/**
 * @title AccountingSyncLogic
 * @author Waymont
 * @notice Tranche-accounting synchronization for a Royco market: the pre-op and post-op sync, protocol fee and liquidity-premium processing, the idle liquidity-premium reinvestment, and the sync preview
 */
library AccountingSyncLogic {
    // =============================
    // External Tranche Accounting and Synchronization Functions
    // =============================

    /**
     * @notice Synchronizes and persists the collateral NAV and the effective NAVs of both tranches
     * @dev Only executes a pre-op sync because there is no operation being executed in the same call as this sync
     * @dev Does not deploy the idle liquidity-premium senior shares
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
     * @notice Synchronizes and persists the collateral NAV and the effective NAVs of both tranches, returning the specified tranche's post-sync claims and supply
     * @dev Only executes a pre-op sync because there is no operation being executed in the same call as this sync
     * @dev Syncs every tranche exactly as `syncTrancheAccounting` does, the tranche type only scopes the claims and supply returned alongside the state
     * @dev The executed counterpart of `previewSyncTrancheAccountingFor`: the claims and supply are read after this sync has minted its
     *      premium and protocol fee shares, so no post-mint simulation is needed
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _trancheType An enumerator indicating which tranche to return claims and total tranche shares for
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     * @return claims The asset claims that the specified tranche has denominated in tranche-native units
     * @return totalTrancheShares The total number of shares that exist in the specified tranche after the post-sync mint of its accrued shares: the protocol fee shares for the senior and junior tranches, plus the liquidity premium shares for the senior tranche (the liquidity provider tranche mints none)
     */
    function syncTrancheAccountingFor(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        TrancheType _trancheType
    )
        external
        returns (SyncedAccountingState memory state, AssetClaims memory claims, uint256 totalTrancheShares)
    {
        // Execute a NAV accounting sync via the accountant to reconcile PNL, then read the specified tranche's post-mint claims and supply
        return _preOpSyncTrancheAccounting($, _immutables, _trancheType);
    }

    /**
     * @notice Syncs the tranche accounting and attempts to reinvest the liquidity provider tranche's idle liquidity-premium senior shares into its market-making inventory
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
        // Sync first to stage any newly accrued premium into the idle pile and commit the fresh senior state the reinvestment values against
        SyncedAccountingState memory state = _preOpSyncTrancheAccounting($, _immutables);
        // Reinvest the requested idle premium shares (type(uint256).max reinvests the entire idle balance) at this sync's post-mint senior share rate
        IRoycoDayKernel(address(this)).attemptLiquidityPremiumReinvestment(_stShares, state.stEffectiveNAV, IERC20(_immutables.seniorTranche).totalSupply());
        // Re-commit the LPT raw NAV: the reinvestment settled after the sync's commit, so the committed depth must reflect the freshly deployed LPT assets
        _commitLPTRawNAV($, _immutables, state);
    }

    /**
     * @notice Previews a synchronization of the collateral NAV and the effective NAVs of both tranches
     * @dev Does not mutate any state
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _trancheType An enumerator indicating which tranche to execute this preview for
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     * @return claims The asset claims that the specified tranche has denominated in tranche-native units
     * @return totalTrancheShares The total number of shares that exist in the specified tranche after the post-sync mint of its accrued shares: the protocol fee shares for the senior and junior tranches, plus the liquidity premium shares for the senior tranche (the liquidity provider tranche mints none)
     */
    function previewSyncTrancheAccountingFor(
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
        claims = AssetLedgerLogic._deriveTrancheAssetClaims($, _immutables, _trancheType, state);

        // Return the requested tranche claims and total shares after the sync mints its premium and protocol fee shares
        if (_trancheType == TrancheType.SENIOR) {
            // Compute ST share supply after the liquidity premium and the ST protocol fee shares are minted
            (,, totalTrancheShares) =
                FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(state, IERC20(_immutables.seniorTranche).totalSupply());
        } else if (_trancheType == TrancheType.JUNIOR) {
            // Compute JT share supply after the JT protocol fee shares are minted
            totalTrancheShares = IERC20(_immutables.juniorTranche).totalSupply();
            totalTrancheShares += ValuationLogic._convertToShares(
                state.jtProtocolFee, (state.jtEffectiveNAV - state.jtProtocolFee), totalTrancheShares, Math.Rounding.Floor
            );
        } else {
            // Simulate the liquidity premium senior-share mint (net of the LPT protocol fee, which is carved out as senior shares to the protocol) to value the LPT effective NAV
            (uint256 liquidityPremiumShares,, uint256 stTotalSupplyAfterMints) =
                FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(state, IERC20(_immutables.seniorTranche).totalSupply());
            // Update the simulated post-mint ST shares owned by LPT
            uint256 lptOwnedSeniorTrancheShares = $.lptOwnedSeniorTrancheShares + liquidityPremiumShares;
            claims.stShares = lptOwnedSeniorTrancheShares;
            claims.nav = ValuationLogic._getLiquidityProviderTrancheEffectiveNAV($, state.stEffectiveNAV, stTotalSupplyAfterMints, lptOwnedSeniorTrancheShares);
            // The LPT protocol fee no longer mints liquidity provider tranche shares, so this sync leaves the LPT share supply unchanged
            totalTrancheShares = IERC20(_immutables.liquidityProviderTranche).totalSupply();
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
        state = IRoycoDayAccountant(_immutables.accountant).previewSyncTrancheAccounting(ValuationLogic._getCollateralNAV($));
        // Refresh the liquidity provider tranche raw NAV and utilization in memory so the preview mirrors execution
        state.lptRawNAV = ValuationLogic._getLiquidityProviderTrancheRawNAV($);
        state.liquidityUtilizationWAD = UtilizationLogic._computeLiquidityUtilization(state.stEffectiveNAV, state.minLiquidityWAD, state.lptRawNAV);
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
        state = IRoycoDayAccountant(_immutables.accountant).preOpSyncTrancheAccounting(ValuationLogic._getCollateralNAV($));
        // Mint the fee and liquidity premium shares accrued by this sync, caching the senior share rate for any liquidity venue mark read
        FeeAndLiquidityPremiumLogic._processFeesAndLiquidityPremium($, _immutables, state);
        // Commit the liquidity provider tranche's fresh raw NAV against the post-sync market state
        _commitLPTRawNAV($, _immutables, state);
        // Signal the settled sync with the committed LPT mark and utilization in the state packet
        emit IRoycoDayKernel.PreOpTrancheAccountingSynced(state);
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
        state = IRoycoDayAccountant(_immutables.accountant).preOpSyncTrancheAccounting(ValuationLogic._getCollateralNAV($));
        // Mint the fee and liquidity premium shares accrued by this sync, caching the senior share rate for any liquidity venue mark read
        FeeAndLiquidityPremiumLogic._processFeesAndLiquidityPremium($, _immutables, state);
        // Commit the liquidity provider tranche's fresh raw NAV against the post-sync market state
        _commitLPTRawNAV($, _immutables, state);
        // Signal the settled sync with the committed LPT mark and utilization in the state packet
        emit IRoycoDayKernel.PreOpTrancheAccountingSynced(state);

        // Read the requested tranche's total supply after all shares (fees and premium) have been minted
        totalTrancheShares = IERC20(AssetLedgerLogic._getTrancheAddress(_immutables, _trancheType)).totalSupply();

        // Derive the asset claims for the specified tranche
        claims = AssetLedgerLogic._deriveTrancheAssetClaims($, _immutables, _trancheType, state);
    }

    /**
     * @notice The single post-operation accounting entrypoint for every deposit and redeem path
     * @notice Commits the final state of the accounting after the operation has executed and checks the market's coverage and liquidity requirements
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _op The operation being executed in between the pre and post synchronizations
     * @param _stSelfLiquidationBonusNAV The NAV of assets from JT effective NAV used as a bonus for ST redemptions (only nonzero if _op == ST_REDEMPTION)
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function _postOpSyncTrancheAccounting(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        Operation _op,
        NAV_UNIT _stSelfLiquidationBonusNAV
    )
        internal
        returns (SyncedAccountingState memory state)
    {
        // Execute the post-op sync on the accountant, committing the final state of the accounting
        // The LPT depth is priced live at the settled venue, a multi-asset preview prices at the frame mark it cached for its venue operation
        state = IRoycoDayAccountant(_immutables.accountant)
            .postOpSyncTrancheAccounting(
                _op, ValuationLogic._getCollateralNAV($), ValuationLogic._getLiquidityProviderTrancheRawNAV($), _stSelfLiquidationBonusNAV
            );

        // Enforce the coverage requirement for operations that can worsen coverage (add senior exposure or remove the junior loss-absorption buffer)
        if (_op == Operation.ST_DEPOSIT || _op == Operation.JT_REDEMPTION) {
            require(state.coverageUtilizationWAD <= WAD, IRoycoDayKernel.COVERAGE_REQUIREMENT_VIOLATED());
        }
        // Enforce the liquidity requirement for operations that can worsen liquidity (raise the senior exposure or reduce the venue's market-making depth)
        (bool inMultiAssetFlow,) = Cache._read(CacheKey.IN_MULTI_ASSET_FLOW);
        bool liquidityRequirementSatisfied = (state.liquidityUtilizationWAD <= WAD);
        if (_op == Operation.ST_DEPOSIT || _op == Operation.LPT_REDEMPTION) {
            if (inMultiAssetFlow && !liquidityRequirementSatisfied) {
                // Record the worsening leg's violation for the flow's exit instead of reverting, a later leg heals it
                Cache._write(CacheKey.PENDING_LIQUIDITY_VIOLATION, 1);
            } else {
                // A standalone operation has no downstream leg to heal a violation, so it enforces at its own settled state
                require(liquidityRequirementSatisfied, IRoycoDayKernel.LIQUIDITY_REQUIREMENT_VIOLATED());
            }
        }
        // A final leg that settles satisfied heals the recorded violation
        // An operation that only improves liquidity never records one, so a partial heal of an already violated market always completes
        if (inMultiAssetFlow && liquidityRequirementSatisfied && (_op == Operation.LPT_DEPOSIT || _op == Operation.ST_REDEMPTION)) {
            Cache._delete(CacheKey.PENDING_LIQUIDITY_VIOLATION);
        }

        // Refresh the cached senior share rate at the settled post-op state
        uint256 totalSTShares = IERC20(_immutables.seniorTranche).totalSupply();
        Cache._write(CacheKey.ST_SHARE_PRICE, toUint256(ValuationLogic._computeTrancheShareRate(totalSTShares, state.stEffectiveNAV)));

        // Deploy the accumulated idle liquidity-premium senior shares now that the operation has settled and its requirements are enforced
        if ($.lptOwnedSeniorTrancheShares != 0) {
            // Value the pile at the settled post-op senior state, a gated or unpriceable deployment defers inside the attempt and leaves the shares idle
            IRoycoDayKernel(address(this)).attemptLiquidityPremiumReinvestment(type(uint256).max, state.stEffectiveNAV, totalSTShares);
            // Re-commit the LPT raw NAV: the deployment settled after the post-op's commit, so the committed depth must reflect the freshly deployed LPT assets
            _commitLPTRawNAV($, _immutables, state);
        }

        // Signal the settled sync with the final LPT mark and utilization the operation left behind
        emit IRoycoDayKernel.PostOpTrancheAccountingSynced(_op, state);
    }

    /**
     * @notice Marks and commits the liquidity provider tranche's fresh raw NAV and refreshes the in-memory state packet
     * @dev Called wherever the depth may have moved under the committed mark: after a sync's fee and premium mints, or a reinvestment
     *      The committed liquidity provider tranche raw NAV stays out of the P&L waterfall and the senior share rate provider's dependency loop
     * @dev Prices the depth live at the venue oracle, a multi-asset deposit or redemption preview reads the frame mark it cached for its venue operation instead
     * @dev Refreshes the state packet in place so every downstream consumer reads the most up-to-date values
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _state The synced accounting state to refresh in place
     */
    function _commitLPTRawNAV(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        SyncedAccountingState memory _state
    )
        internal
    {
        // Get the post-sync LPT raw NAV
        NAV_UNIT lptRawNAV = ValuationLogic._getLiquidityProviderTrancheRawNAV($);
        // Commit the fresh LPT raw NAV in the accountant and the derived liquidity utilization in the state packet
        IRoycoDayAccountant(_immutables.accountant).commitLiquidityProviderTrancheRawNAV(lptRawNAV);
        _state.lptRawNAV = lptRawNAV;
        _state.liquidityUtilizationWAD = UtilizationLogic._computeLiquidityUtilization(_state.stEffectiveNAV, _state.minLiquidityWAD, lptRawNAV);
    }

    /// @notice Marks the start of a multi-asset composite flow so a worsening leg's post-op records a liquidity violation instead of enforcing it
    /// @dev Must be paired with _exitMultiAssetFlow, which unmarks the flow and enforces the requirement on the flow's final settled state
    function _enterMultiAssetFlow() internal {
        Cache._write(CacheKey.IN_MULTI_ASSET_FLOW, 1);
    }

    /// @notice Unmarks the settled multi-asset composite flow and enforces any recorded liquidity violation its later legs never healed
    /// @dev Must be called before the composite's preview revert so the requirement is enforced in preview and execution alike
    function _exitMultiAssetFlow() internal {
        Cache._delete(CacheKey.IN_MULTI_ASSET_FLOW);
        (bool pendingLiquidityViolation,) = Cache._read(CacheKey.PENDING_LIQUIDITY_VIOLATION);
        require(!pendingLiquidityViolation, IRoycoDayKernel.LIQUIDITY_REQUIREMENT_VIOLATED());
    }
}
