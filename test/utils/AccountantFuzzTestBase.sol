// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayAccountant } from "../../src/interfaces/IRoycoDayAccountant.sol";
import { toUint256 } from "../../src/libraries/Units.sol";
import { AccountantTestBase } from "./AccountantTestBase.sol";
import { RoycoTestMath } from "./RoycoTestMath.sol";

/**
 * @title AccountantFuzzTestBase
 * @notice Shared mock-kernel fuzz base for the accountant property suite, extending AccountantTestBase's
 *         deploy and seeding surface with the mirror-input marshalling the fuzz properties need
 * @dev Checkpoints are always constructed through legal kernel calls (post-op deposits, pre-op syncs, LT
 *      commits), never through storage writes, so every fuzzed state is a state production can actually reach
 */
abstract contract AccountantFuzzTestBase is AccountantTestBase {
    /// @notice WAD fixed-point unit, 1e18 == 100%
    uint256 internal constant WAD = 1e18;

    /// @notice Suite-wide NAV ceiling for fuzzed inputs
    uint256 internal constant MAX_NAV = 1e30;

    /// @notice Ten years, the suite-wide ceiling on a fuzzed elapsed window
    uint256 internal constant MAX_ELAPSED = 3650 days;

    /// @dev Applies a signed basis-point move in [-10000, 10000] to a NAV amount, flooring the scaled product
    function _afterMove(uint256 _base, int256 _bps) internal pure returns (uint256) {
        return _base * uint256(int256(10_000) + _bps) / 10_000;
    }

    /**
     * @dev Re-derives the premium-window inputs the next sync will use from the committed accrual bookkeeping:
     *      each accumulator extends by min(instantaneous share, configured cap) x seconds since the last accrual,
     *      and the premium window is the time elapsed since the last premium payment. Only valid once a first
     *      sync has initialized the accrual timestamps (a fresh accountant holds zero timestamps and follows the
     *      first-sync initialization path instead)
     * @param _jtRate The pinned instantaneous JT yield share the mock JT YDM returns
     * @param _ltRate The pinned instantaneous LT yield share the mock LT YDM returns
     */
    function _premiumWindow(uint256 _jtRate, uint256 _ltRate) internal view returns (uint256 twJT, uint256 twLT, uint256 elapsedSincePayment) {
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        uint256 elapsedSinceAccrual = block.timestamp - s.lastYieldShareAccrualTimestamp;
        twJT = s.twJTYieldShareAccruedWAD + Math.min(_jtRate, DEFAULT_MAX_JT_YIELD_SHARE_WAD) * elapsedSinceAccrual;
        twLT = s.twLTYieldShareAccruedWAD + Math.min(_ltRate, DEFAULT_MAX_LT_YIELD_SHARE_WAD) * elapsedSinceAccrual;
        elapsedSincePayment = block.timestamp - s.lastPremiumPaymentTimestamp;
    }

    /**
     * @dev Marshals the committed checkpoint plus caller-supplied premium-window values into a complete
     *      RoycoTestMath.SyncInputs mirror for the sync about to run against (_stRawNew, _jtRawNew, _ltRawNew) marks.
     *      The premium-window values are caller-supplied because their bookkeeping differs between the
     *      first-ever sync (both timestamps initialize to now, forcing the instantaneous branch) and every
     *      later one (see _premiumWindow)
     */
    function _mirrorInput(
        uint256 _stRawNew,
        uint256 _jtRawNew,
        uint256 _ltRawNew,
        uint256 _twJT,
        uint256 _twLT,
        uint256 _elapsedSincePayment,
        uint256 _jtRate,
        uint256 _ltRate
    )
        internal
        view
        returns (RoycoTestMath.SyncInputs memory in_)
    {
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        in_.stRawNAVLast = toUint256(s.lastSTRawNAV);
        in_.jtRawNAVLast = toUint256(s.lastJTRawNAV);
        in_.stEffectiveNAVLast = toUint256(s.lastSTEffectiveNAV);
        in_.jtEffectiveNAVLast = toUint256(s.lastJTEffectiveNAV);
        in_.jtCoverageImpermanentLossLast = toUint256(s.lastJTCoverageImpermanentLoss);
        in_.marketStateLast = RoycoTestMath.MarketState(uint8(s.lastMarketState));
        in_.fixedTermEndTimestampLast = s.fixedTermEndTimestamp;
        in_.stRawNAVDelta = int256(_stRawNew) - int256(in_.stRawNAVLast);
        in_.jtRawNAVDelta = int256(_jtRawNew) - int256(in_.jtRawNAVLast);
        in_.ltRawNAVNew = _ltRawNew;
        in_.jtTwYieldShareAccrual = _twJT;
        in_.ltTwYieldShareAccrual = _twLT;
        in_.elapsedSincePremiumPayment = _elapsedSincePayment;
        in_.jtInstYieldShareWAD = _jtRate;
        in_.ltInstYieldShareWAD = _ltRate;
        in_.maxJTYieldShareWAD = DEFAULT_MAX_JT_YIELD_SHARE_WAD;
        in_.maxLTYieldShareWAD = DEFAULT_MAX_LT_YIELD_SHARE_WAD;
        in_.stProtocolFeeWAD = DEFAULT_PROTOCOL_FEE_WAD;
        in_.jtProtocolFeeWAD = DEFAULT_PROTOCOL_FEE_WAD;
        in_.jtYieldShareProtocolFeeWAD = DEFAULT_PROTOCOL_FEE_WAD;
        in_.ltYieldShareProtocolFeeWAD = DEFAULT_PROTOCOL_FEE_WAD;
        in_.nowTimestamp = block.timestamp;
        in_.fixedTermDuration = DEFAULT_FIXED_TERM_DURATION_SECONDS;
        in_.minCoverageWAD = DEFAULT_MIN_COVERAGE_WAD;
        in_.jtCoinvested = accountant.JT_COINVESTED();
        in_.coverageLiquidationUtilizationWAD = DEFAULT_LIQUIDATION_UTILIZATION_WAD;
        // Read the effective dust the deployed accountant actually enforces (it maintains the field as the sum
        // of the two configured raw-NAV dust tolerances) instead of hard-coding 0, so a suite that deploys with
        // nonzero dust tolerances feeds its mirror the same fee/premium dust gate production applies
        in_.effectiveDust = toUint256(s.effectiveNAVDustTolerance);
        in_.minLiquidityWAD = DEFAULT_MIN_LIQUIDITY_WAD;
    }
}
