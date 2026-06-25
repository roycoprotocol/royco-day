// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { WAD, ZERO_NAV_UNITS } from "./Constants.sol";
import { AccountingCheckpoint, MarketState, MarketStateTransitionParams, PnLWaterfallParams, SyncedAccountingState } from "./Types.sol";
import { Math, NAV_UNIT, UnitsMathLib, toNAVUnits } from "./Units.sol";
import { UtilsLib } from "./UtilsLib.sol";

/**
 * @title AccountingLib
 * @author Waymont
 * @notice A library containing accounting functions for the Royco protocol
 */
library AccountingLib {
    using UnitsMathLib for NAV_UNIT;
    using UnitsMathLib for uint256;

    /// @notice Thrown when a set of tranche NAVs violates the NAV conservation invariant: raw and effective NAVs must sum to the same total
    error NAV_CONSERVATION_VIOLATION();

    /// @notice Thrown when the combined risk and liquidity premiums exceed the senior gain they are drawn from: the JT and LT yield shares must sum to at most 100% of senior appreciation
    error PREMIUMS_EXCEED_SENIOR_YIELD();

    /**
     * @notice Attributes each tranche's raw NAV delta across the checkpointed claims that each tranche holds on the raw NAVs, producing the signed effective NAV delta for each tranche
     * @dev The first step of a sync's PnL waterfall: it converts the raw NAV deltas (the unrealized PNL of the underlying investment(s)) into effective NAV deltas, which the waterfall then settles (loss -> coverage IL recovery -> yield split)
     * @param _stRawNAV The senior tranche's current raw NAV: the mark-to-market value of its invested assets
     * @param _jtRawNAV The junior tranche's current raw NAV: the mark-to-market value of its invested assets
     * @param _lastSTRawNAV The senior tranche's last recorded raw NAV (excluding any coverage taken and yield shared): the reference its raw NAV delta is measured against
     * @param _lastJTRawNAV The junior tranche's last recorded raw NAV (excluding any coverage given and yield shared): the reference its raw NAV delta is measured against
     * @param _lastSTEffectiveNAV The senior tranche's last recorded effective NAV (including any prior applied coverage, ST yield distribution, and uncovered losses)
     * @param _lastJTEffectiveNAV The junior tranche's last recorded effective NAV (including any prior provided coverage, JT yield, ST yield distribution, and JT losses)
     * @return deltaSTEffectiveNAV The signed delta to the senior tranche's effective NAV from this sync's PNL: the sum of ST's claim-weighted shares of each tranche's raw NAV PNL
     * @return deltaJTEffectiveNAV The signed delta to the junior tranche's effective NAV from this sync's PNL: the residual of the total PNL after ST's attribution, which absorbs all rounding drift
     */
    function applyProfitAndLossAttribution(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        NAV_UNIT _lastSTRawNAV,
        NAV_UNIT _lastJTRawNAV,
        NAV_UNIT _lastSTEffectiveNAV,
        NAV_UNIT _lastJTEffectiveNAV
    )
        internal
        pure
        returns (int256 deltaSTEffectiveNAV, int256 deltaJTEffectiveNAV)
    {
        // Compute the deltas for each tranche's effective NAV based on their last checkpointed economic claims on each tranche's raw NAVs
        // Last cross-tranche claims (the NAV that can't be funded by the tranche's own raw NAV)
        NAV_UNIT stClaimOnJTRawNAV = UnitsMathLib.saturatingSub(_lastSTEffectiveNAV, _lastSTRawNAV);
        NAV_UNIT jtClaimOnSTRawNAV = UnitsMathLib.saturatingSub(_lastJTEffectiveNAV, _lastJTRawNAV);
        // Last self-backed portion of the senior tranche's claim (the NAV funded by ST's own raw NAV)
        // NOTE: NAV conservation guarantees that this cannot underflow
        NAV_UNIT stClaimOnSTRawNAV = (_lastSTRawNAV - jtClaimOnSTRawNAV);

        // Compute the deltas in the raw NAVs of each tranche
        // The deltas represent the unrealized PNL of the underlying investment since the last NAV checkpoints
        int256 deltaSTRawNAV = UnitsMathLib.computeNAVDelta(_stRawNAV, _lastSTRawNAV);
        int256 deltaJTRawNAV = UnitsMathLib.computeNAVDelta(_jtRawNAV, _lastJTRawNAV);

        // Attribute each raw NAV's signed PNL to ST in proportion to its claim against that raw NAV
        // The resulting deltas are rounded down: in favor of seniors on losses and juniors on gains
        // When the last ST raw NAV is zero, conservation forces ST's claim on its raw NAV to zero: route the delta to ST if it has live effective claims, else leave it as residual to JT to avoid inflating NAV against zero ST shares outstanding
        int256 deltaSTClaimOnSTRawNAV = _lastSTRawNAV == ZERO_NAV_UNITS
            ? (_lastSTEffectiveNAV > ZERO_NAV_UNITS ? deltaSTRawNAV : int256(0))
            : _attributeDeltaToClaimOnRawNAV(deltaSTRawNAV, stClaimOnSTRawNAV, _lastSTRawNAV);
        int256 deltaSTClaimOnJTRawNAV = _attributeDeltaToClaimOnRawNAV(deltaJTRawNAV, stClaimOnJTRawNAV, _lastJTRawNAV);

        // ST's effective NAV delta is the sum of its claim-weighted shares of each pool's PNL and JT's effective NAV delta is computed as the residual
        // NOTE: NAV conservation holds: positive and negative rounding drift is absorbed by juniors
        deltaSTEffectiveNAV = deltaSTClaimOnSTRawNAV + deltaSTClaimOnJTRawNAV;
        deltaJTEffectiveNAV = (deltaSTRawNAV + deltaJTRawNAV) - deltaSTEffectiveNAV;
    }

    /**
     * @notice Synchronizes the tranche NAVs and the JT coverage impermanent loss based on the unrealized PNL of the underlying investment(s)
     * @dev Attributes each tranche's raw NAV delta across the checkpointed claims, then settles the deltas through the PnL waterfall (loss -> coverage IL recovery -> yield split)
     * @param _stRawNAV The senior tranche's current raw NAV: the mark-to-market value of its invested assets
     * @param _jtRawNAV The junior tranche's current raw NAV: the mark-to-market value of its invested assets
     * @param _ltRawNAV The liquidity tranche's current raw NAV: the mark-to-market value of its invested assets
     * @param _params The fixed inputs of the waterfall: the checkpoint, pre-resolved YDM outputs, fee rates, and dust tolerance
     * @return postPnLWaterfallCheckpoint The post-waterfall checkpoint: the current raw NAVs alongside the settled effective NAVs and JT coverage impermanent loss
     * @return ltLiquidityPremium The liquidity premium paid to LT out of ST yield in this sync: minted as senior tranche shares to LT (coverage-neutral, so it remains within ST effective NAV)
     * @return stProtocolFee The protocol fee accrued on ST yield in this sync (gross: not netted out of the effective NAVs)
     * @return jtProtocolFee The protocol fee accrued on JT yield and the JT yield share in this sync (gross: not netted out of the effective NAVs)
     * @return ltProtocolFee The protocol fee accrued on LT yield and the LT yield share in this sync (gross: not netted out of the effective NAVs)
     * @return premiumsPaid A boolean indicating whether the JT risk and LT liquidity premiums were paid out of ST yield
     */
    function applyProfitAndLossWaterfall(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        NAV_UNIT _ltRawNAV,
        PnLWaterfallParams memory _params
    )
        internal
        pure
        returns (
            AccountingCheckpoint memory postPnLWaterfallCheckpoint,
            NAV_UNIT ltLiquidityPremium,
            NAV_UNIT stProtocolFee,
            NAV_UNIT jtProtocolFee,
            NAV_UNIT ltProtocolFee,
            bool premiumsPaid
        )
    {
        // Cache the checkpointed effective NAV for each tranche
        NAV_UNIT stEffectiveNAV = _params.checkpoint.stEffectiveNAV;
        NAV_UNIT jtEffectiveNAV = _params.checkpoint.jtEffectiveNAV;

        // Apply the profit and loss attribution based on the current claims on NAVs that each tranche holds
        (int256 deltaSTEffectiveNAV, int256 deltaJTEffectiveNAV) =
            applyProfitAndLossAttribution(_stRawNAV, _jtRawNAV, _params.checkpoint.stRawNAV, _params.checkpoint.jtRawNAV, stEffectiveNAV, jtEffectiveNAV);

        // The net JT gains. The JT protocol fee accrued is calculated using this NAV.
        NAV_UNIT jtNetGain = ZERO_NAV_UNITS;
        // Mark both the tranche NAVs to market
        /// @dev STEP_APPLY_JT_LOSS: The JT assets depreciated in value
        if (deltaJTEffectiveNAV < 0) {
            /// @dev STEP_JT_ABSORB_LOSS: JT's remaning loss-absorption buffer incurs its loss fully
            // NOTE: The PnL attribution step above guarantees that this will not underflow
            NAV_UNIT jtLoss = toNAVUnits(-deltaJTEffectiveNAV);
            jtEffectiveNAV = (jtEffectiveNAV - jtLoss);
            /// @dev STEP_APPLY_JT_GAIN: The JT assets appreciated in value
        } else if (deltaJTEffectiveNAV > 0) {
            jtNetGain = toNAVUnits(deltaJTEffectiveNAV);
            // Compute the protocol fee taken on this JT yield accrual if it is not attributable to any rounding/dust
            if (jtNetGain > _params.effectiveNAVDustTolerance) jtProtocolFee = jtNetGain.mulDiv(_params.jtProtocolFeeWAD, WAD, Math.Rounding.Floor);
            // Book the gains to the JT
            jtEffectiveNAV = (jtEffectiveNAV + jtNetGain);
        }

        // Cache the checkpointed JT coverage impermanent loss
        NAV_UNIT jtCoverageImpermanentLoss = _params.checkpoint.jtCoverageImpermanentLoss;
        /// @dev STEP_APPLY_ST_LOSS: The ST assets depreciated in value
        if (deltaSTEffectiveNAV < 0) {
            NAV_UNIT stLoss = toNAVUnits(-deltaSTEffectiveNAV);
            /// @dev STEP_APPLY_JT_COVERAGE_TO_ST: Apply any possible coverage to ST provided by JT's loss-absorption buffer
            NAV_UNIT coverageApplied = UnitsMathLib.min(stLoss, jtEffectiveNAV);
            if (coverageApplied != ZERO_NAV_UNITS) {
                // If there was a JT protocol fee taken on their appreciation, recalculate it using the JT net gain after applying coverage applied
                if (jtProtocolFee != ZERO_NAV_UNITS) {
                    jtNetGain = jtNetGain.saturatingSub(coverageApplied);
                    jtProtocolFee =
                        (jtNetGain > _params.effectiveNAVDustTolerance) ? jtNetGain.mulDiv(_params.jtProtocolFeeWAD, WAD, Math.Rounding.Floor) : ZERO_NAV_UNITS;
                }
                // Apply the coverage to JT effective NAV
                jtEffectiveNAV = (jtEffectiveNAV - coverageApplied);
                // Any coverage provided is a ST liability to JT
                jtCoverageImpermanentLoss = (jtCoverageImpermanentLoss + coverageApplied);
                stLoss = stLoss - coverageApplied;
            }
            /// @dev STEP_ST_INCURS_RESIDUAL_LOSSES: Apply any uncovered losses by JT to ST
            if (stLoss != ZERO_NAV_UNITS) stEffectiveNAV = (stEffectiveNAV - stLoss);
            /// @dev STEP_APPLY_ST_GAIN: The ST assets appreciated in value
        } else if (deltaSTEffectiveNAV > 0) {
            NAV_UNIT stGain = toNAVUnits(deltaSTEffectiveNAV);
            /// @dev STEP_JT_COVERAGE_IMPERMANENT_LOSS_RECOVERY: First, recover any JT coverage inflicted impermanent losses (first claim on ST appreciation)
            NAV_UNIT jtCoverageImpermanentLossRecovery = UnitsMathLib.min(stGain, jtCoverageImpermanentLoss);
            if (jtCoverageImpermanentLossRecovery != ZERO_NAV_UNITS) {
                // Recover as much of the JT coverage impermanent loss as possible
                jtCoverageImpermanentLoss = (jtCoverageImpermanentLoss - jtCoverageImpermanentLossRecovery);
                // Apply the JT coverage IL recovery
                jtEffectiveNAV = (jtEffectiveNAV + jtCoverageImpermanentLossRecovery);
                stGain = (stGain - jtCoverageImpermanentLossRecovery);
            }
            /// @dev STEP_DISTRIBUTE_YIELD: There is no remaining JT coverage impermanent loss that ST yield is obligated to repay, the residual gains will be used to distribute yield to both tranches
            if (stGain != ZERO_NAV_UNITS) {
                // Mark yield as distributed if the gain is not attributable to any rounding/dust
                if (stGain > _params.effectiveNAVDustTolerance) premiumsPaid = true;
                // If the last premium payments happened in the same block, use the instantaneous yield shares
                // Else, use the time-weighted average yield shares since the last premium payments
                NAV_UNIT jtRiskPremium;
                if (_params.elapsedSinceLastPremiumPayments == 0) {
                    jtRiskPremium = stGain.mulDiv(_params.instantaneousJTYieldShareWAD, WAD, Math.Rounding.Floor);
                    ltLiquidityPremium = stGain.mulDiv(_params.instantaneousLTYieldShareWAD, WAD, Math.Rounding.Floor);
                } else {
                    jtRiskPremium = stGain.mulDiv(_params.twJTYieldShareAccruedWAD, (_params.elapsedSinceLastPremiumPayments * WAD), Math.Rounding.Floor);
                    ltLiquidityPremium = stGain.mulDiv(_params.twLTYieldShareAccruedWAD, (_params.elapsedSinceLastPremiumPayments * WAD), Math.Rounding.Floor);
                }
                // The combined premiums can never exceed the senior gain: the JT and LT yield shares are each capped so that they sum to at most 100% of senior appreciation
                require((jtRiskPremium + ltLiquidityPremium) <= stGain, PREMIUMS_EXCEED_SENIOR_YIELD());
                // Apply the risk premium to JT's effective NAV
                if (jtRiskPremium != ZERO_NAV_UNITS) {
                    // Compute the protocol fee taken on the yield share accrual if it is not attributable to any rounding/dust
                    if (premiumsPaid) {
                        jtProtocolFee = (jtProtocolFee + jtRiskPremium.mulDiv(_params.jtYieldShareProtocolFeeWAD, WAD, Math.Rounding.Floor));
                    }
                    jtEffectiveNAV = (jtEffectiveNAV + jtRiskPremium);
                    stGain = (stGain - jtRiskPremium);
                }
                // Pay the liquidity premium to LT: it is minted as senior shares to LT, so it remains a senior claim within ST effective NAV (coverage-neutral) and is carved out of the residual only to size plain ST's retained yield and protocol fee
                if (ltLiquidityPremium != ZERO_NAV_UNITS) {
                    // Compute the protocol fee taken on the yield share accrual if it is not attributable to any rounding/dust
                    if (premiumsPaid) {
                        ltProtocolFee = ltLiquidityPremium.mulDiv(_params.ltYieldShareProtocolFeeWAD, WAD, Math.Rounding.Floor);
                    }
                    stGain = (stGain - ltLiquidityPremium);
                }
                // Compute the protocol fee taken on this ST yield accrual if it is not attributable to any rounding/dust
                if (premiumsPaid) stProtocolFee = stGain.mulDiv(_params.stProtocolFeeWAD, WAD, Math.Rounding.Floor);
                // Book the residual gain to the ST, including the liquidity premium that remains a senior claim now owned by LT (coverage neutral, so the two-term NAV conservation holds)
                // The liquidity premium is used to mint ST shares to the LT
                stEffectiveNAV = (stEffectiveNAV + stGain + ltLiquidityPremium);
            }
        }

        // Compute the delta in the LT's raw NAV since the last checkpoint
        int256 deltaLTRawNAV = UnitsMathLib.computeNAVDelta(_ltRawNAV, _params.checkpoint.ltRawNAV);
        /// @dev STEP_APPLY_LT_GAIN: The LT assets appreciated in value
        if (deltaLTRawNAV > 0) {
            NAV_UNIT ltGain = toNAVUnits(deltaLTRawNAV);
            // Compute the protocol fee taken on this LT yield accrual if it is not attributable to any rounding/dust
            if (ltGain > _params.ltNAVDustTolerance) {
                ltProtocolFee = (ltProtocolFee + ltGain.mulDiv(_params.ltProtocolFeeWAD, WAD, Math.Rounding.Floor));
            }
        }
        /// @dev STEP_NOP_LT_LOSS: The LT assets losing value is a NOP since these assets aren't use to fulfill any obligations, and they are always owned by the LT

        // Enforce the NAV conservation invariant
        enforceNAVConservation(_stRawNAV, _jtRawNAV, stEffectiveNAV, jtEffectiveNAV);

        // Marshal the post-waterfall checkpoint and return it to the caller alongside the fees accrued
        postPnLWaterfallCheckpoint = AccountingCheckpoint({
            stRawNAV: _stRawNAV,
            jtRawNAV: _jtRawNAV,
            ltRawNAV: _ltRawNAV,
            stEffectiveNAV: stEffectiveNAV,
            jtEffectiveNAV: jtEffectiveNAV,
            jtCoverageImpermanentLoss: jtCoverageImpermanentLoss
        });
    }

    /**
     * @notice Determines the market state resulting from a sync, applies its state-dependent bookkeeping, and marshals the post-sync accounting state
     * @dev Runs once per sync, after the PnL waterfall has settled the tranche NAVs; none of its effects feed back into the effective NAVs
     * @dev Computes the market's coverage and liquidity utilization internally from the post-waterfall checkpoint and the coverage and liquidity configuration
     * @dev Erases the JT coverage IL and zeroes the liquidity premium and protocol fees in the marshaled state where the transition demands it; all inputs are read-only
     * @dev Resulting market state:
     *      1. Forced Perpetual: The fixed-term duration is set to 0 (permanently perpetual), current fixed-term elapsed, or liquidation utilization threshold has been breached (under/un-collateralized)
     *      2. Normal Perpetual: JT coverage IL is within dust tolerance (staying perpetual) or fully recovered (exiting fixed-term for perpetual)
     *      3. Fixed-term: The JT coverage IL is above the dust tolerance of the market, fixed-term duration hasn't elapsed, and liquidation utilization threshold hasn't been breached
     * @param _initialMarketState The market state persisted by the last committed sync (the transition's origin state)
     * @param _params The inputs of the transition: the post-waterfall checkpoint, the fees accrued, and the market's coverage and fixed-term configuration
     * @return state The complete post-sync accounting state: the resulting market state alongside the synced NAVs, JT coverage impermanent loss, fees, and metrics
     * @return jtCoverageImpermanentLossErased The JT coverage impermanent loss erased (reset to 0) by a forced perpetual transition
     */
    function applyStateTransition(
        MarketState _initialMarketState,
        MarketStateTransitionParams memory _params
    )
        internal
        pure
        returns (SyncedAccountingState memory state, NAV_UNIT jtCoverageImpermanentLossErased)
    {
        // Compute the market's coverage utilization against the post-waterfall JT effective NAV
        uint256 coverageUtilizationWAD = UtilsLib.computeCoverageUtilization(
            _params.postPnLWaterfallCheckpoint.stRawNAV,
            _params.postPnLWaterfallCheckpoint.jtRawNAV,
            _params.betaWAD,
            _params.minCoverageWAD,
            _params.postPnLWaterfallCheckpoint.jtEffectiveNAV
        );

        // Compute the market's liquidity utilization against the post-waterfall ST effective NAV and the LT's market-making inventory
        uint256 liquidityUtilizationWAD = UtilsLib.computeLiquidityUtilization(
            _params.postPnLWaterfallCheckpoint.stEffectiveNAV, _params.minLiquidityWAD, _params.postPnLWaterfallCheckpoint.ltRawNAV
        );

        // Cache the premium and fees accrued by the waterfall: zeroed below if the resulting market state pays no premium and takes no fees
        NAV_UNIT ltLiquidityPremium = _params.ltLiquidityPremium;
        NAV_UNIT stProtocolFee = _params.stProtocolFee;
        NAV_UNIT jtProtocolFee = _params.jtProtocolFee;
        NAV_UNIT ltProtocolFee = _params.ltProtocolFee;

        MarketState resultingMarketState;
        uint32 fixedTermEndTimestamp = _params.fixedTermEndTimestamp;
        NAV_UNIT jtCoverageImpermanentLoss = _params.postPnLWaterfallCheckpoint.jtCoverageImpermanentLoss;
        // If the market is permanently perpetual, the fixed-term elapsed, or under/uncollateralized, the market must be in a perpetual state
        if (
            _params.fixedTermDurationSeconds == 0 || (_initialMarketState == MarketState.FIXED_TERM && fixedTermEndTimestamp <= _params.currentTimestamp)
                || coverageUtilizationWAD >= _params.liquidationCoverageUtilizationWAD
                || (_params.postPnLWaterfallCheckpoint.jtEffectiveNAV == ZERO_NAV_UNITS && _params.postPnLWaterfallCheckpoint.stEffectiveNAV > ZERO_NAV_UNITS)
        ) {
            // JT coverage impermanent loss has to be explicitly cleared in this branch:
            // If the fixed-term duration is 0, the market is permanently in a perpetual state and never incurs any JT coverage IL
            // If the current fixed-term has elapsed, the market needs to transition to a perpetual state since the transient JT protection period is complete
            // If the market is under/uncollateralized, ST needs to be able to withdraw to avoid/book losses and the YDM needs to kick in to reinstate proper collateralization
            jtCoverageImpermanentLossErased = jtCoverageImpermanentLoss;
            jtCoverageImpermanentLoss = ZERO_NAV_UNITS;
            // Transition to a perpetual state
            resultingMarketState = MarketState.PERPETUAL;
            fixedTermEndTimestamp = 0;
            // If the market has less than dust coverage provided by JT
        } else if (jtCoverageImpermanentLoss <= _params.effectiveNAVDustTolerance) {
            // JT coverage IL is either nonexistent or can be attributed to dust ST losses (eg. rounding in the underlying ST NAV)
            // If market was in a perpetual state or the coverage IL was completely wiped, transition to a perpetual state
            if (_initialMarketState == MarketState.PERPETUAL || jtCoverageImpermanentLoss == ZERO_NAV_UNITS) {
                // Transition to a perpetual state
                resultingMarketState = MarketState.PERPETUAL;
                fixedTermEndTimestamp = 0;
                // If market was in a fixed-term state, remain in it until dust tolerance is completely restored
            } else {
                // This ensures that we always have a buffer of at least the dust tolerance when entering a fresh perpetual state
                resultingMarketState = MarketState.FIXED_TERM;
                // The liquidity premium is not paid and fees are not taken in a fixed-term state
                ltLiquidityPremium = ZERO_NAV_UNITS;
                stProtocolFee = ZERO_NAV_UNITS; // Formality: Should naturally never be non-zero in a fixed-term state
                jtProtocolFee = ZERO_NAV_UNITS;
                ltProtocolFee = ZERO_NAV_UNITS;
            }
        } else {
            resultingMarketState = MarketState.FIXED_TERM;
            // The liquidity premium is not paid and fees are not taken in a fixed-term state
            ltLiquidityPremium = ZERO_NAV_UNITS;
            stProtocolFee = ZERO_NAV_UNITS; // Formality: Should naturally never be non-zero in a fixed-term state
            jtProtocolFee = ZERO_NAV_UNITS;
            ltProtocolFee = ZERO_NAV_UNITS;
            // If the market was in a perpetual state, update the fixed-term end timestamp
            if (_initialMarketState == MarketState.PERPETUAL) fixedTermEndTimestamp = uint32(_params.currentTimestamp + _params.fixedTermDurationSeconds);
        }

        // Marshal the post-sync state and return it to the caller
        state = SyncedAccountingState({
            marketState: resultingMarketState,
            stRawNAV: _params.postPnLWaterfallCheckpoint.stRawNAV,
            jtRawNAV: _params.postPnLWaterfallCheckpoint.jtRawNAV,
            stEffectiveNAV: _params.postPnLWaterfallCheckpoint.stEffectiveNAV,
            jtEffectiveNAV: _params.postPnLWaterfallCheckpoint.jtEffectiveNAV,
            jtCoverageImpermanentLoss: jtCoverageImpermanentLoss,
            ltLiquidityPremium: ltLiquidityPremium,
            stProtocolFee: stProtocolFee,
            jtProtocolFee: jtProtocolFee,
            ltProtocolFee: ltProtocolFee,
            coverageUtilizationWAD: coverageUtilizationWAD,
            liquidityUtilizationWAD: liquidityUtilizationWAD,
            fixedTermEndTimestamp: fixedTermEndTimestamp,
            minCoverageWAD: _params.minCoverageWAD,
            betaWAD: _params.betaWAD,
            liquidationCoverageUtilizationWAD: _params.liquidationCoverageUtilizationWAD,
            minLiquidityWAD: _params.minLiquidityWAD
        });
    }

    /**
     * @notice Enforces the NAV conservation invariant on an accounting checkpoint
     * @param _checkpoint The accounting checkpoint to validate
     */
    function enforceNAVConservation(AccountingCheckpoint memory _checkpoint) internal pure {
        enforceNAVConservation(_checkpoint.stRawNAV, _checkpoint.jtRawNAV, _checkpoint.stEffectiveNAV, _checkpoint.jtEffectiveNAV);
    }

    /**
     * @notice Enforces the NAV conservation invariant: the raw NAVs and the effective NAVs must sum to the same total at wei precision
     * @param _stRawNAV The senior tranche's raw NAV
     * @param _jtRawNAV The junior tranche's raw NAV
     * @param _stEffectiveNAV The senior tranche's effective NAV
     * @param _jtEffectiveNAV The junior tranche's effective NAV
     */
    function enforceNAVConservation(NAV_UNIT _stRawNAV, NAV_UNIT _jtRawNAV, NAV_UNIT _stEffectiveNAV, NAV_UNIT _jtEffectiveNAV) internal pure {
        require((_stRawNAV + _jtRawNAV) == (_stEffectiveNAV + _jtEffectiveNAV), NAV_CONSERVATION_VIOLATION());
    }

    /**
     * @notice Attributes a portion of a signed raw NAV delta to a tranche based on its proportional claim on the raw NAV
     * @param _delta The signed raw NAV delta to attribute
     * @param _claimOnTrancheRawNAV The tranche's claim against the raw NAV
     * @param _lastTrancheRawNAV The total raw NAV of the pool at the last checkpoint
     * @return attributedDelta The signed share of the delta attributable to the claim holder
     */
    function _attributeDeltaToClaimOnRawNAV(
        int256 _delta,
        NAV_UNIT _claimOnTrancheRawNAV,
        NAV_UNIT _lastTrancheRawNAV
    )
        internal
        pure
        returns (int256 attributedDelta)
    {
        // No NAV to attribute to the tranche if any operand is zero
        if (_delta == 0 || _claimOnTrancheRawNAV == ZERO_NAV_UNITS || _lastTrancheRawNAV == ZERO_NAV_UNITS) return 0;

        // Work in unsigned magnitudes for the proportional split, then re-apply the original sign
        // Floor on the magnitude routes the leftover wei from rounding into the complementary tranche
        uint256 absDelta = _delta < 0 ? uint256(-_delta) : uint256(_delta);
        uint256 attributedMagnitude = absDelta.mulDiv(_claimOnTrancheRawNAV, _lastTrancheRawNAV, Math.Rounding.Floor);
        attributedDelta = _delta < 0 ? -int256(attributedMagnitude) : int256(attributedMagnitude);
    }
}
