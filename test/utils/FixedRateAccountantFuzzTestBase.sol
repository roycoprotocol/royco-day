// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayAccountant } from "../../src/interfaces/accountant/IRoycoDayAccountant.sol";
import { IRoycoDayFixedRateAccountant } from "../../src/interfaces/accountant/IRoycoDayFixedRateAccountant.sol";
import { toUint256 } from "../../src/libraries/Units.sol";
import { FixedRateAccountantTestBase } from "./FixedRateAccountantTestBase.sol";
import { RoycoTestMath } from "./RoycoTestMath.sol";

/**
 * @title FixedRateAccountantFuzzTestBase
 * @notice Shared mock-kernel fuzz base for the fixed rate accountant property suite, extending
 *         FixedRateAccountantTestBase's deploy and seeding surface with the mirror-input marshalling the
 *         fuzz properties need
 * @dev Checkpoints are always constructed through legal kernel calls (post-op deposits, pre-op syncs, LPT
 *      commits), never through storage writes, so every fuzzed state is a state production can actually reach
 */
abstract contract FixedRateAccountantFuzzTestBase is FixedRateAccountantTestBase {
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
     *      the accumulator extends by min(instantaneous share, configured cap) x seconds since the last accrual,
     *      and the premium window is the time elapsed since the last premium payment. Only valid once a first
     *      sync has initialized the accrual timestamps (a fresh accountant holds zero timestamps and follows the
     *      first-sync initialization path instead)
     * @param _lptRate The pinned instantaneous LPT yield share the mock LPT YDM returns
     */
    function _premiumWindow(uint256 _lptRate) internal view returns (uint256 twLPT, uint256 elapsedSincePayment) {
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantState memory sFixed = accountant.getRoycoDayFixedRateAccountantState();
        uint256 elapsedSinceAccrual = vm.getBlockTimestamp() - sFixed.lastYieldShareAccrualTimestamp;
        twLPT = sFixed.twLPTYieldShareAccruedWAD + Math.min(_lptRate, sFixed.maxLPTYieldShareWAD) * elapsedSinceAccrual;
        elapsedSincePayment = vm.getBlockTimestamp() - sFixed.lastPremiumPaymentTimestamp;
    }

    /**
     * @dev Marshals the committed checkpoint plus caller-supplied premium-window values into a complete
     *      RoycoTestMath.FixedSyncInputs mirror for the sync about to run against (_collateralNew, _lptRawNew)
     *      marks. The coupon window is read from the committed coupon settlement clock, so the mirror prices
     *      exactly the in-flight window production will settle. The premium-window values are caller-supplied
     *      because their bookkeeping differs between the first-ever sync (both timestamps initialize to now,
     *      forcing the instantaneous branch) and every later one (see _premiumWindow)
     */
    function _fixedMirrorInput(
        uint256 _collateralNew,
        uint256 _lptRawNew,
        uint256 _twLPT,
        uint256 _elapsedSincePayment,
        uint256 _lptRate
    )
        internal
        view
        returns (RoycoTestMath.FixedSyncInputs memory in_)
    {
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantState memory sFixed = accountant.getRoycoDayFixedRateAccountantState();
        in_.collateralNAVLast = toUint256(s.lastCollateralNAV);
        in_.stEffectiveNAVLast = toUint256(s.lastSTEffectiveNAV);
        in_.jtEffectiveNAVLast = toUint256(s.lastJTEffectiveNAV);
        in_.jtImpermanentLossLast = toUint256(s.lastJTImpermanentLoss);
        in_.marketStateLast = RoycoTestMath.MarketState(uint8(s.lastMarketState));
        in_.fixedTermEndTimestampLast = s.fixedTermEndTimestamp;
        in_.collateralNAVDelta = int256(_collateralNew) - int256(in_.collateralNAVLast);
        in_.lptRawNAVNew = _lptRawNew;
        in_.stFixedRatePerSecondWAD = sFixed.stFixedRatePerSecondWAD;
        in_.elapsedSinceCouponSettlement = vm.getBlockTimestamp() - sFixed.lastCouponSettlementTimestamp;
        in_.lptTwYieldShareAccrual = _twLPT;
        in_.elapsedSincePremiumPayment = _elapsedSincePayment;
        in_.lptInstYieldShareWAD = _lptRate;
        in_.maxLPTYieldShareWAD = sFixed.maxLPTYieldShareWAD;
        in_.stProtocolFeeWAD = s.stProtocolFeeWAD;
        in_.jtYieldShareProtocolFeeWAD = s.jtYieldShareProtocolFeeWAD;
        in_.lptYieldShareProtocolFeeWAD = s.lptYieldShareProtocolFeeWAD;
        in_.nowTimestamp = vm.getBlockTimestamp();
        in_.fixedTermDuration = s.fixedTermDurationSeconds;
        in_.minCoverageWAD = s.minCoverageWAD;
        in_.coverageLiquidationUtilizationWAD = s.coverageLiquidationUtilizationWAD;
        // Read the dust tolerance the deployed accountant actually enforces instead of hard-coding 0, so a suite
        // that deploys with a nonzero dust tolerance feeds its mirror the same fee/premium dust gate production applies
        in_.dustTolerance = toUint256(s.dustTolerance);
        in_.minLiquidityWAD = s.minLiquidityWAD;
    }
}
