// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoDayAccountant } from "../../src/accountant/RoycoDayAccountant.sol";
import { MarketState, SyncedAccountingState } from "../../src/libraries/Types.sol";
import { NAV_UNIT, toNAVUnits } from "../../src/libraries/Units.sol";

/**
 * @title WaterfallSyncDriver
 * @notice Test driver over RoycoDayAccountant that seeds arbitrary checkpoints straight into the accountant's
 *         ERC-7201 storage and drives the internal sync waterfall, the yield share accrual, and the yield share
 *         config validation from an external call frame
 * @dev The kernel address is constructor-supplied so a test can act as the kernel for the pre-op and post-op
 *      sync entrypoints (call them directly with the kernel set to the test contract, or prank as the configured
 *      kernel address)
 * @dev seedCheckpoint bypasses initialize entirely: it writes the full accountant state field set (the checkpointed
 *      collateral NAV, the effective NAVs, the JT impermanent loss ledger, the time-weighted yield share
 *      accumulators, the max yield shares, all four protocol fee percentages, the market state and fixed-term
 *      fields, the accrual and premium payment clocks, the YDM addresses, and the dust tolerance) so any
 *      reachable or hypothetical checkpoint can be pinned exactly
 * @dev The maxSTDeposit, maxJTWithdrawal, and maxLPTWithdrawal views are already external on the accountant and
 *      read the seeded dust tolerance from storage, so they are driven directly with a marshaled state struct
 */
contract WaterfallSyncDriver is RoycoDayAccountant {
    constructor(address _kernel) RoycoDayAccountant(_kernel) { }

    /// @notice Writes the full accountant state field set into ERC-7201 storage as the last committed checkpoint
    function seedCheckpoint(RoycoDayAccountantState calldata _seed) external {
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        // Protocol fee percentages
        $.stProtocolFeeWAD = _seed.stProtocolFeeWAD;
        $.jtProtocolFeeWAD = _seed.jtProtocolFeeWAD;
        $.jtYieldShareProtocolFeeWAD = _seed.jtYieldShareProtocolFeeWAD;
        $.lptYieldShareProtocolFeeWAD = _seed.lptYieldShareProtocolFeeWAD;
        // Coverage, liquidity, and fixed-term configuration
        $.minCoverageWAD = _seed.minCoverageWAD;
        $.fixedTermDurationSeconds = _seed.fixedTermDurationSeconds;
        $.minLiquidityWAD = _seed.minLiquidityWAD;
        $.coverageLiquidationUtilizationWAD = _seed.coverageLiquidationUtilizationWAD;
        // Market state and clocks
        $.lastMarketState = _seed.lastMarketState;
        $.fixedTermEndTimestamp = _seed.fixedTermEndTimestamp;
        $.lastYieldShareAccrualTimestamp = _seed.lastYieldShareAccrualTimestamp;
        $.lastPremiumPaymentTimestamp = _seed.lastPremiumPaymentTimestamp;
        // Yield distribution models
        $.jtYDM = _seed.jtYDM;
        $.lptYDM = _seed.lptYDM;
        // Time-weighted yield share accumulators and their caps
        $.twJTYieldShareAccruedWAD = _seed.twJTYieldShareAccruedWAD;
        $.maxJTYieldShareWAD = _seed.maxJTYieldShareWAD;
        $.twLPTYieldShareAccruedWAD = _seed.twLPTYieldShareAccruedWAD;
        $.maxLPTYieldShareWAD = _seed.maxLPTYieldShareWAD;
        // Checkpointed NAVs and the JT impermanent loss ledger
        $.lastCollateralNAV = _seed.lastCollateralNAV;
        $.lastSTEffectiveNAV = _seed.lastSTEffectiveNAV;
        $.lastJTEffectiveNAV = _seed.lastJTEffectiveNAV;
        $.lastJTImpermanentLoss = _seed.lastJTImpermanentLoss;
        $.lastLPTRawNAV = _seed.lastLPTRawNAV;
        // Dust tolerance
        $.dustTolerance = _seed.dustTolerance;
    }

    /**
     * @notice Runs the sync waterfall preview against the seeded checkpoint with explicitly supplied
     *         time-weighted yield share accumulators, without committing the result
     * @param _collateralNAV The fresh mark-to-market value of the coinvested collateral
     * @param _twJTYieldShareAccruedWAD The time-weighted JT yield share since the last premium payment, scaled to WAD precision
     * @param _twLPTYieldShareAccruedWAD The time-weighted LPT yield share since the last premium payment, scaled to WAD precision
     * @return state The post-sync accounting state the waterfall produces
     * @return initialMarketState The market state the sync transitions from
     * @return premiumsPaid Whether the JT risk and LPT liquidity premiums were paid out of ST yield
     * @return jtImpermanentLossErased The JT impermanent loss the sync erased
     */
    function runSync(
        uint256 _collateralNAV,
        uint256 _twJTYieldShareAccruedWAD,
        uint256 _twLPTYieldShareAccruedWAD
    )
        external
        view
        returns (SyncedAccountingState memory state, MarketState initialMarketState, bool premiumsPaid, NAV_UNIT jtImpermanentLossErased)
    {
        return _previewSyncTrancheAccounting(toNAVUnits(_collateralNAV), _twJTYieldShareAccruedWAD, _twLPTYieldShareAccruedWAD);
    }

    /// @notice Totality twin of runSync via an external self-call, surfacing a revert anywhere in the waterfall as a false success flag
    /// @dev On failure the returned state is the zero-initialized struct and must not be inspected
    function tryRunSync(
        uint256 _collateralNAV,
        uint256 _twJTYieldShareAccruedWAD,
        uint256 _twLPTYieldShareAccruedWAD
    )
        external
        view
        returns (bool success, SyncedAccountingState memory state)
    {
        try this.runSync(_collateralNAV, _twJTYieldShareAccruedWAD, _twLPTYieldShareAccruedWAD) returns (
            SyncedAccountingState memory synced, MarketState, bool, NAV_UNIT
        ) {
            return (true, synced);
        } catch {
            return (false, state);
        }
    }

    /// @notice Drives the mutating yield share accrual against the seeded clocks, YDMs, and accumulators
    function accruePremiumYieldShares() external returns (uint128 twJTYieldShareAccruedWAD, uint128 twLPTYieldShareAccruedWAD) {
        return _accruePremiumYieldShares();
    }

    /// @notice Drives the view-path yield share accrual against the seeded clocks, YDMs, and accumulators
    function previewPremiumYieldShareAccrual() external view returns (uint128 twJTYieldShareAccruedWAD, uint128 twLPTYieldShareAccruedWAD) {
        return _previewPremiumYieldShareAccrual();
    }

    /// @notice External shim over the internal yield share config validation, reverting exactly when it does
    function validateYieldShareConfig(uint64 _maxJTYieldShareWAD, uint64 _maxLPTYieldShareWAD) external pure {
        _validateYieldShareConfig(_maxJTYieldShareWAD, _maxLPTYieldShareWAD);
    }
}
