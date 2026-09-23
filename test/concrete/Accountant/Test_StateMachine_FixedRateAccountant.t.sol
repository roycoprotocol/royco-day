// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Vm } from "../../../lib/forge-std/src/Test.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/accountant/IRoycoDayAccountant.sol";
import { IRoycoDayFixedRateAccountant } from "../../../src/interfaces/accountant/IRoycoDayFixedRateAccountant.sol";
import { ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { MarketState, Operation, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { FixedRateAccountantTestBase } from "../../utils/FixedRateAccountantTestBase.sol";

/**
 * @title Test_StateMachine_FixedRateAccountant
 * @notice The PERPETUAL / FIXED_TERM machine under fixed rate semantics: coupon drag alone locking the term,
 *         full restoration unlocking with no reset, term expiry crystallizing the unrecovered fronted coupon,
 *         the coupon-wipeout and liquidation forced-perpetual disjuncts, the grace-period and zero-duration
 *         lockout configs, dust-sized fronted coupon stickiness, and the il > 0 iff FIXED_TERM biconditional
 *         on every committed checkpoint
 */
contract Test_StateMachine_FixedRateAccountant is FixedRateAccountantTestBase {
    function setUp() public {
        _deploy(_defaultParams());
    }

    /*//////////////////////////////////////////////////////////////////////
                            SUITE HELPERS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @dev Shared committed-checkpoint assertions run after every settling sync: the checkpoint mirrors the
     * returned state, conservation holds on the commit, and il > 0 iff FIXED_TERM stays biconditional
     */
    function _assertCommittedCheckpoint(SyncedAccountingState memory _state) internal view {
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastCollateralNAV), toUint256(_state.collateralNAV), "committed collateral NAV mirrors the returned state");
        assertEq(toUint256(s.lastSTEffectiveNAV), toUint256(_state.stEffectiveNAV), "committed st effective NAV mirrors the returned state");
        assertEq(toUint256(s.lastJTEffectiveNAV), toUint256(_state.jtEffectiveNAV), "committed jt effective NAV mirrors the returned state");
        assertEq(toUint256(s.lastJTImpermanentLoss), toUint256(_state.jtImpermanentLoss), "committed il mirrors the returned state");
        assertEq(uint8(s.lastMarketState), uint8(_state.marketState), "committed market state mirrors the returned state");
        assertEq(s.fixedTermEndTimestamp, _state.fixedTermEndTimestamp, "committed term end mirrors the returned state");
        assertEq(toUint256(_state.collateralNAV), toUint256(_state.stEffectiveNAV) + toUint256(_state.jtEffectiveNAV), "conservation holds on the commit");
        assertEq(toUint256(s.lastJTImpermanentLoss) > 0, s.lastMarketState == MarketState.FIXED_TERM, "il > 0 iff FIXED_TERM on the committed checkpoint");
    }

    /// @dev Preview hash captured before the execute so every vector pins the byte-identical preview == execute contract
    function _previewHash(NAV_UNIT _collateralNAV) internal view returns (bytes32) {
        return keccak256(abi.encode(accountant.previewSyncTrancheAccounting(_collateralNAV)));
    }

    /**
     * @dev Drives the default flat seed into the canonical coupon-drag lock: a 100 second window settled by a
     * +1 wei gain
     * Derivation: couponDue = floor(1000e18 * 1e9 * 100 / 1e18) = 1e14. The 1 wei gain funds couponFromGain = 1
     * and JT fronts couponFromJT = 1e14 - 1, so couponPaid = 1e14, stEff = 1000e18 + 1e14,
     * jtEff = 200e18 - (1e14 - 1), and il = 1e14 - 1 > dust 0 locks FIXED_TERM
     * @return end The stamped fixed term end (the lock time plus the default duration)
     */
    function _lockViaCouponDrag() internal returns (uint32 end) {
        _seedAndInitAccrual();
        end = uint32(vm.getBlockTimestamp()) + 100 + DEFAULT_FIXED_TERM_DURATION_SECONDS;
        vm.warp(vm.getBlockTimestamp() + 100);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 1));
        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "lock helper: coupon drag locks the term");
        assertEq(toUint256(state.jtImpermanentLoss), 1e14 - 1, "lock helper: fronted coupon booked as il");
        assertEq(state.fixedTermEndTimestamp, end, "lock helper: end stamped");
    }

    /*//////////////////////////////////////////////////////////////////////
                            TESTS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * coupon drag alone locks the fixed term: a flat-ish market whose only movement is a +1 wei settlement
     * gain cannot fund the coupon, so JT fronts nearly all of it as il and the observation period commences
     * even though no principal loss ever occurred
     * Derivation: over the 100 second window couponDue = floor(1000e18 * 1e9 * 100 / 1e18) = 1e14. The gain
     * funds couponFromGain = 1 and JT fronts couponFromJT = min(1e14 - 1, 200e18) = 1e14 - 1, so
     * couponPaid = 1e14 with stFee = floor(1e14 * 0.1e18 / 1e18) = 1e13 (couponPaid > dust 0). The books land
     * stEff = 1000e18 + 1e14, jtEff = 200e18 - (1e14 - 1), il = 1e14 - 1 with the gain fully consumed, so no
     * repayment or excess runs and il > dust locks FIXED_TERM with end = now + duration
     */
    function test_StateMachine_couponDragAloneLocksFixedTerm() public {
        _seedAndInitAccrual();
        uint32 expectedEnd = uint32(vm.getBlockTimestamp()) + 100 + DEFAULT_FIXED_TERM_DURATION_SECONDS;
        vm.warp(vm.getBlockTimestamp() + 100);
        bytes32 previewHash = _previewHash(toNAVUnits(SEED_COLLATERAL + 1));
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermCommenced(expectedEnd);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 1));
        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "coupon drag alone locks the term");
        assertEq(toUint256(state.jtImpermanentLoss), 1e14 - 1, "jt fronts the whole coupon beyond the 1 wei gain");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF + 1e14, "the settled coupon folds into the senior claim");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF - (1e14 - 1), "the jt buffer funds the fronted coupon");
        assertEq(toUint256(state.stProtocolFee), 1e13, "coupon fee books above dust");
        assertEq(toUint256(state.lptLiquidityPremium), 0, "the gain is exhausted by the coupon so no premium");
        assertEq(state.fixedTermEndTimestamp, expectedEnd, "entry stamps now plus duration");
        assertEq(keccak256(abi.encode(state)), previewHash, "preview matches the executed sync");
        _assertCommittedCheckpoint(state);
    }

    /**
     * a later gain covering the in-flight coupon plus the full il repayment unlocks the term: FixedTermEnded
     * fires but JuniorTrancheImpermanentLossReset does NOT, since the repayment already zeroed the ledger and
     * a reset only signals a nonzero erasure
     * Derivation: from the locked checkpoint stEff = 1000e18 + 1e14 a second 100 second window owes
     * couponDue = floor((1000e18 + 1e14) * 1e9 * 100 / 1e18) = 1e14 + 1e7 (exact, no floor loss). The gain is
     * sized to couponDue + il = (1e14 + 1e7) + (1e14 - 1) = 200_000_009_999_999: the coupon settles fully from
     * the gain (stFee = floor((1e14 + 1e7) * 0.1e18 / 1e18) = 1e13 + 1e6), the remaining 1e14 - 1 repays the
     * il to exactly zero restoring jtEff = 200e18, and no excess remains so no premium or yield share fee
     * books. il = 0 <= dust exits the term at the commit with nothing left to erase
     */
    function test_StateMachine_fullRestorationUnlocksWithoutReset() public {
        _lockViaCouponDrag();
        uint256 nav = SEED_COLLATERAL + 1 + 200_000_009_999_999;
        vm.warp(vm.getBlockTimestamp() + 100);
        bytes32 previewHash = _previewHash(toNAVUnits(nav));
        vm.recordLogs();
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(nav));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermEnded.selector), 1, "exit edge emits exactly one end");
        assertEq(
            _countAccountantLogs(logs, IRoycoDayAccountant.JuniorTrancheImpermanentLossReset.selector),
            0,
            "full repayment leaves nothing to erase so no reset fires"
        );
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermCommenced.selector), 0, "no re-entry on the exit edge");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "full restoration unlocks the term");
        assertEq(toUint256(state.jtImpermanentLoss), 0, "il repaid to exactly zero");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF, "jt fully restored");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF + 1e14 + 1e14 + 1e7, "both windows' coupons folded senior");
        assertEq(toUint256(state.stProtocolFee), 1e13 + 1e6, "second window coupon fee");
        assertEq(toUint256(state.lptLiquidityPremium), 0, "the gain is exhausted by coupon and repayment");
        assertEq(state.fixedTermEndTimestamp, 0, "end timestamp deleted");
        assertEq(keccak256(abi.encode(state)), previewHash, "preview matches the executed sync");
        _assertCommittedCheckpoint(state);
    }

    /**
     * term expiry crystallizes the unrecovered fronted coupon: a flat sync past the end timestamp settles no
     * coupon (no NAV movement, the window keeps accruing) but its perpetual commit erases the residual il with
     * a reset carrying exactly the coupon JT fronted and never recovered
     * Derivation: the lock leaves il = 1e14 - 1 (the fronted coupon) with end = lockTime + 604800. Warping
     * past the end and syncing at the unchanged 1200e18 + 1 settles nothing, so the NAVs are untouched and the
     * elapsed-term disjunct erases the full 1e14 - 1
     */
    function test_StateMachine_termExpiryCrystallizesFrontedCoupon() public {
        uint32 end = _lockViaCouponDrag();
        vm.warp(uint256(end) + 5);
        bytes32 previewHash = _previewHash(toNAVUnits(SEED_COLLATERAL + 1));
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(toNAVUnits(uint256(1e14 - 1)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 1));
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "the elapsed term forces perpetual");
        assertEq(toUint256(state.jtImpermanentLoss), 0, "the unrecovered fronted coupon is crystallized");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF + 1e14, "the flat sync settles no further coupon");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF - (1e14 - 1), "jt keeps its realized drag loss");
        assertEq(toUint256(state.stProtocolFee), 0, "no settlement so no fee");
        assertEq(state.fixedTermEndTimestamp, 0, "end timestamp deleted");
        assertEq(keccak256(abi.encode(state)), previewHash, "preview matches the executed sync");
        _assertCommittedCheckpoint(state);
    }

    /**
     * a coupon consuming the whole junior buffer forces perpetual through the wipeout disjunct: JT underwrites
     * the rate to its full depth, the wiped buffer extinguishes the dead restoration claim, and the market
     * stays open instead of locking on the giant fronted il
     * Derivation: seed stEff 1000e18 with a thin jtEff of 1e15 (collateral 1000e18 + 1e15). Over 2000 seconds
     * couponDue = floor(1000e18 * 1e9 * 2000 / 1e18) = 2e15. A +1 wei settlement gain funds couponFromGain = 1
     * and JT fronts couponFromJT = min(2e15 - 1, 1e15) = 1e15 (its entire buffer), so couponPaid = 1e15 + 1
     * with stFee = floor((1e15 + 1) * 0.1e18 / 1e18) = 1e14 and the 1e15 - 1 coupon remainder forgiven.
     * jtEff = 0 with a would-be il of 1e15: the wipeout disjunct forces PERPETUAL, erases the il, and the zero
     * junior buffer over the live senior claim maxes coverage utilization
     */
    function test_StateMachine_couponWipeoutForcesPerpetual() public {
        _seedState(SEED_ST_EFF, 1e15, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        vm.warp(vm.getBlockTimestamp() + 2000);
        bytes32 previewHash = _previewHash(toNAVUnits(SEED_ST_EFF + 1e15 + 1));
        vm.recordLogs();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(toNAVUnits(uint256(1e15)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_EFF + 1e15 + 1));
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "the coupon wipeout forces perpetual");
        assertEq(toUint256(state.jtImpermanentLoss), 0, "il erased with the dead restoration claim");
        assertEq(toUint256(state.jtEffectiveNAV), 0, "the coupon consumes the whole junior buffer");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF + 1e15 + 1, "the funded coupon folds senior, the rest is forgiven");
        assertEq(toUint256(state.stProtocolFee), 1e14, "coupon fee books on the funded amount only");
        assertEq(state.coverageUtilizationWAD, type(uint256).max, "a zero junior buffer over a live senior claim maxes coverage utilization");
        assertEq(state.fixedTermEndTimestamp, 0, "no fixed term end stamped");
        assertEq(_countAccountantLogs(vm.getRecordedLogs(), IRoycoDayAccountant.FixedTermCommenced.selector), 0, "the wipeout never commences a term");
        assertEq(keccak256(abi.encode(state)), previewHash, "preview matches the executed sync");
        _assertCommittedCheckpoint(state);
    }

    /**
     * the post-deploy grace period blocks coupon-drag entry: the fronted coupon books, its il exceeds dust,
     * but the grace disjunct resolves PERPETUAL and the perpetual commit erases the fronted amount
     * Derivation (grace 1000): the standard drag vector settles couponPaid = 1e14 on the +1 wei gain 100
     * seconds after deployment (couponFromJT = 1e14 - 1, stFee = 1e13), and now = deploy + 100 is inside
     * deploy + 1000, so the market stays PERPETUAL, erases the 1e14 - 1, and never stamps an end
     */
    function test_StateMachine_gracePeriodBlocksCouponDragEntry() public {
        _deployWithGrace(_defaultParams(), 1000);
        _seedAndInitAccrual();
        vm.warp(vm.getBlockTimestamp() + 100);
        bytes32 previewHash = _previewHash(toNAVUnits(SEED_COLLATERAL + 1));
        vm.recordLogs();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(toNAVUnits(uint256(1e14 - 1)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 1));
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "grace blocks the coupon drag entry");
        assertEq(toUint256(state.jtImpermanentLoss), 0, "fronted coupon il erased inside grace");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF - (1e14 - 1), "the drag loss stays realized on jt");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF + 1e14, "the coupon still settles senior");
        assertEq(toUint256(state.stProtocolFee), 1e13, "the coupon fee still books inside grace");
        assertEq(state.fixedTermEndTimestamp, 0, "no fixed term end stamped");
        assertEq(_countAccountantLogs(vm.getRecordedLogs(), IRoycoDayAccountant.FixedTermCommenced.selector), 0, "no term commences inside grace");
        assertEq(keccak256(abi.encode(state)), previewHash, "preview matches the executed sync");
        _assertCommittedCheckpoint(state);
    }

    /**
     * a zero fixed-term duration never locks on coupon drag: the permanently perpetual config erases the
     * fronted coupon at every commit no matter how far it exceeds dust
     * Derivation: the standard drag vector (couponPaid = 1e14 on the +1 wei gain, couponFromJT = 1e14 - 1,
     * stFee = 1e13) lands a would-be il of 1e14 - 1, and the zero-duration disjunct erases it at the commit
     */
    function test_StateMachine_zeroDurationNeverLocksOnCouponDrag() public {
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _defaultParams();
        p.standardParams.fixedTermDurationSeconds = 0;
        _deploy(p);
        _seedAndInitAccrual();
        vm.warp(vm.getBlockTimestamp() + 100);
        bytes32 previewHash = _previewHash(toNAVUnits(SEED_COLLATERAL + 1));
        vm.recordLogs();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(toNAVUnits(uint256(1e14 - 1)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 1));
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "permanently perpetual despite the coupon drag");
        assertEq(toUint256(state.jtImpermanentLoss), 0, "fronted coupon il erased on the sync");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF - (1e14 - 1), "the drag loss stays realized on jt");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF + 1e14, "the coupon still settles senior");
        assertEq(state.fixedTermEndTimestamp, 0, "no fixed term end stamped");
        assertEq(_countAccountantLogs(vm.getRecordedLogs(), IRoycoDayAccountant.FixedTermCommenced.selector), 0, "no term ever commences");
        assertEq(keccak256(abi.encode(state)), previewHash, "preview matches the executed sync");
        _assertCommittedCheckpoint(state);
    }

    /**
     * the liquidation disjunct forces perpetual mid term even as coupon drag deepens the il: on a markdown the
     * loss is absorbed junior-first, THEN the coupon is fronted from what remains of the buffer, and the
     * post-waterfall coverage utilization breaching the threshold ends the term and erases the whole ledger
     * Derivation: from the large-il checkpoint (stEff 1000e18, jtEff 200e18, il 100e18, collateral 1200e18) a
     * -100e18 loss is fully absorbed by JT (jtEff 100e18, il 200e18). Then the 100 second window's coupon
     * couponDue = floor(1000e18 * 1e9 * 100 / 1e18) = 1e14 is fronted entirely from the remaining buffer:
     * jtEff = 100e18 - 1e14, il = 200e18 + 1e14, stEff = 1000e18 + 1e14, stFee = 1e13.
     * coverageUtilization = ceil(1100e18 * 0.1e18 / (100e18 - 1e14)) lands just above the 1.1e18 threshold
     * (the drag-shrunk buffer breaches where the pure 100e18 buffer would sit exactly on it), forcing
     * perpetual and erasing the full 200e18 + 1e14
     */
    function test_StateMachine_liquidationBreachForcesPerpetualUnderCouponDrag() public {
        _seedLargeIL();
        vm.warp(vm.getBlockTimestamp() + 100);
        bytes32 previewHash = _previewHash(toNAVUnits(uint256(1100e18)));
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(toNAVUnits(uint256(200e18 + 1e14)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1100e18)));
        assertEq(
            state.coverageUtilizationWAD,
            _specCoverageUtilization(1100e18, DEFAULT_MIN_COVERAGE_WAD, 100e18 - 1e14),
            "coverage utilization computed on the drag-shrunk buffer"
        );
        assertGe(state.coverageUtilizationWAD, DEFAULT_LIQUIDATION_UTILIZATION_WAD, "coverage utilization breaches the threshold");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "the liquidation breach forces perpetual mid term");
        assertEq(toUint256(state.jtImpermanentLoss), 0, "il erased even mid fixed term");
        assertEq(toUint256(state.jtEffectiveNAV), 100e18 - 1e14, "the buffer absorbs the loss then fronts the coupon");
        assertEq(toUint256(state.stEffectiveNAV), 1000e18 + 1e14, "st fully covered plus the fronted coupon");
        assertEq(toUint256(state.stProtocolFee), 1e13, "coupon fee books on the loss sync");
        assertEq(state.fixedTermEndTimestamp, 0, "end timestamp deleted");
        assertEq(keccak256(abi.encode(state)), previewHash, "preview matches the executed sync");
        _assertCommittedCheckpoint(state);
    }

    /**
     * a dust-sized fronted coupon never locks: with the dust tolerance at the coupon size the fronted il sits
     * inside the dust band and the perpetual commit erases it, and the coupon fee gate (couponPaid > dust)
     * holds the fee at zero too
     * Derivation (dust 1e14): the 100 second window settles couponPaid = 1e14 on the +1 wei gain with
     * couponFromJT = 1e14 - 1. couponPaid = 1e14 is not strictly above dust so no fee books, and
     * il = 1e14 - 1 <= 1e14 resolves PERPETUAL erasing the fronted amount at the commit
     */
    function test_StateMachine_dustFrontedCouponNeverLocks() public {
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _defaultParams();
        p.standardParams.dustTolerance = toNAVUnits(uint256(1e14));
        _deploy(p);
        _seedAndInitAccrual();
        vm.warp(vm.getBlockTimestamp() + 100);
        bytes32 previewHash = _previewHash(toNAVUnits(SEED_COLLATERAL + 1));
        vm.recordLogs();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(toNAVUnits(uint256(1e14 - 1)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 1));
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "a dust-sized fronted coupon never locks");
        assertEq(toUint256(state.jtImpermanentLoss), 0, "the dust fronted amount is erased at the commit");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF - (1e14 - 1), "the drag loss stays realized on jt");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF + 1e14, "the coupon still settles senior");
        assertEq(toUint256(state.stProtocolFee), 0, "couponPaid at most dust books no fee");
        assertEq(state.fixedTermEndTimestamp, 0, "no fixed term end stamped");
        assertEq(_countAccountantLogs(vm.getRecordedLogs(), IRoycoDayAccountant.FixedTermCommenced.selector), 0, "no term commences on dust drag");
        assertEq(keccak256(abi.encode(state)), previewHash, "preview matches the executed sync");
        _assertCommittedCheckpoint(state);
    }

    /**
     * clause 2, no senior capital to protect: with the senior fully redeemed the coupon is structurally zero
     * (it accrues on a zero base) and a junior loss cannot lock the market, the perpetual disjunct erases the
     * freshly booked impermanent loss at the commit
     * Derivation: seed 100e18/200e18, redeem the whole senior via post-op, then a 10e18 loss sync 100s later:
     * couponDue = 0 x 1e9 x 100 / 1e18 = 0, the junior absorbs the 10e18 as impermanent loss inside the
     * waterfall, and the stEffectiveNAV == 0 disjunct forces PERPETUAL with the 10e18 erased on the spot
     */
    function test_StateMachine_zeroSeniorCapitalForcesPerpetual() public {
        _seedState(100e18, 200e18, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        uint256 start = vm.getBlockTimestamp();
        kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(uint256(200e18)), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
        assertEq(toUint256(accountant.getState().lastSTEffectiveNAV), 0, "the senior is fully redeemed");

        vm.warp(start + 100);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(toNAVUnits(uint256(10e18)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(190e18)));
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "no senior capital to protect forces the perpetual state");
        assertEq(toUint256(state.jtEffectiveNAV), 190e18, "the junior absorbs the loss");
        assertEq(toUint256(state.jtImpermanentLoss), 0, "the perpetual commit erases the fresh impermanent loss");
        assertEq(toUint256(state.stEffectiveNAV), 0, "a zero senior base accrues no coupon");
        _assertCommittedCheckpoint(state);
    }
}
