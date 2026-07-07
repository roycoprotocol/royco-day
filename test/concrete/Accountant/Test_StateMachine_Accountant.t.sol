// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Vm } from "../../../lib/forge-std/src/Test.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { AccountantTestBase } from "../../utils/AccountantTestBase.sol";

/**
 * @title Test_StateMachine_Accountant
 * @notice The PERPETUAL / FIXED_TERM machine: the zero-duration permanently-perpetual config, the exact
 *         term-end boundary, the liquidation and wipeout forced-perpetual disjuncts, dust-IL stickiness,
 *         single-stamp term entry, the transition-event edges, and the premium-window reset on exit
 */
contract Test_StateMachine_Accountant is AccountantTestBase {
    function setUp() public {
        stranger = makeAddr("stranger");
        _deploy(false, _defaultParams());
    }

    /**
     * a zero fixed-term duration configured at initialization keeps the market permanently perpetual — a
     * covered loss with il far above dust is erased on the sync with an exact reset event and never commences a term
     */
    function test_StateMachine_zeroDurationConfigNeverEntersFixedTerm() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.fixedTermDurationSeconds = 0;
        _deploy(false, p);
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        vm.recordLogs();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(toNAVUnits(uint256(50e18)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(950e18)), toNAVUnits(SEED_JT_RAW));
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "permanently perpetual despite the covered loss");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 0, "il erased on the sync");
        assertEq(toUint256(state.jtEffectiveNAV), 150e18, "coverage still applied to jt");
        assertEq(state.fixedTermEndTimestamp, 0, "no fixed term end stamped");
        assertEq(_countAccountantLogs(vm.getRecordedLogs(), IRoycoDayAccountant.FixedTermCommenced.selector), 0, "no term ever commences");
    }

    /**
     * the fixed term ends at the exact end == now boundary — the disjunct is an inclusive comparison
     * Events in emission order: FixedTermEnded from the transition, then the il reset of the full 100e18
     */
    function test_StateMachine_fixedTermEndsAtExactBoundary() public {
        _seedLargeIL();
        uint32 end = uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS);
        vm.warp(end);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(toNAVUnits(uint256(100e18)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(900e18)), toNAVUnits(uint256(300e18)));
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "term ends exactly at its end timestamp");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 0, "il erased when the term elapses");
        assertEq(state.fixedTermEndTimestamp, 0, "end timestamp deleted");
        assertEq(accountant.getState().fixedTermEndTimestamp, 0, "committed end timestamp deleted");
    }

    /// one second before the end the fixed term persists with the il and end timestamp intact
    function test_StateMachine_fixedTermPersistsJustBeforeEnd() public {
        _seedLargeIL();
        uint32 end = uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS);
        vm.warp(end - 1);
        vm.recordLogs();
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(900e18)), toNAVUnits(uint256(300e18)));
        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "term persists one second before its end");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 100e18, "il persists through the term");
        assertEq(state.fixedTermEndTimestamp, end, "end timestamp unchanged");
        assertEq(_countAccountantLogs(vm.getRecordedLogs(), IRoycoDayAccountant.FixedTermEnded.selector), 0, "no end event before the boundary");
    }

    /// well beyond the end timestamp the elapsed-term disjunct still fires
    function test_StateMachine_fixedTermEndsBeyondBoundary() public {
        _seedLargeIL();
        vm.warp(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS + 12_345);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(900e18)), toNAVUnits(uint256(300e18)));
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "term ended after the end timestamp passed");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 0, "il erased");
        assertEq(state.fixedTermEndTimestamp, 0, "end timestamp deleted");
    }

    /**
     * the liquidation disjunct fires at exactly coverageUtilization == threshold, crafted with an exact division
     * Derivation: a 130e18 senior raw loss is fully covered so jtEffectiveNAV = 70e18 and stRawNAV = 770e18:
     * coverageUtilization = ceil(770e18 * 0.1e18 / 70e18) = 1.1e18 exactly (77 / 70 divides at WAD precision), so the
     * would-be il of 230e18 is erased and the market is forced perpetual mid fixed term
     */
    function test_StateMachine_liquidationUtilizationExactBoundaryForcesPerpetual() public {
        _seedLargeIL();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(toNAVUnits(uint256(230e18)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(770e18)), toNAVUnits(uint256(300e18)));
        assertEq(state.coverageUtilizationWAD, DEFAULT_LIQUIDATION_UTILIZATION_WAD, "coverage utilization lands exactly on the threshold");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "liquidation breach forces perpetual");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 0, "il erased even mid fixed term");
        assertEq(toUint256(state.jtEffectiveNAV), 70e18, "coverage applied before the transition");
        assertEq(toUint256(state.stEffectiveNAV), 1000e18, "st fully covered");
        assertEq(state.fixedTermEndTimestamp, 0, "end timestamp deleted");
    }

    /**
     * just below the liquidation threshold the fixed term persists
     * Derivation: a 120e18 covered loss leaves jtEffectiveNAV = 80e18 and coverageUtilization = ceil(780e18 * 0.1e18 / 80e18) = 0.975e18 < 1.1e18
     */
    function test_StateMachine_belowLiquidationThresholdStaysFixedTerm() public {
        _seedLargeIL();
        uint32 end = uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(780e18)), toNAVUnits(uint256(300e18)));
        assertEq(state.coverageUtilizationWAD, 0.975e18, "coverage utilization below the threshold");
        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "term persists below the liquidation threshold");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 220e18, "il accumulates instead of erasing");
        assertEq(state.fixedTermEndTimestamp, end, "end timestamp kept");
    }

    /**
     * the wipeout disjunct in true isolation — the senior raw NAV collapses to zero so the coverage
     * utilization reads 0 (no exposure) and cannot be the trigger, leaving jtEffectiveNAV == 0 && stEffectiveNAV > 0 as the only
     * firing disjunct
     * Derivation from checkpoint (0, 300e18, 100e18, 200e18, il 100e18) with jtRawNAV -> 1 wei:
     *   attrST = -floor(299999999999999999999 / 3) = -99999999999999999999, jt residual loss = 200e18 exactly
     *   so jtEffectiveNAV = 0, the 99999999999999999999 st loss is uncovered leaving stEffectiveNAV = 1 wei
     */
    function test_StateMachine_wipeoutDisjunctInIsolation() public {
        _seedState(0, 300e18, 100e18, 200e18, 100e18, SEED_LT_RAW, MarketState.FIXED_TERM);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(toNAVUnits(uint256(100e18)));
        SyncedAccountingState memory state = kernel.doPreOp(ZERO_NAV_UNITS, toNAVUnits(uint256(1)));
        assertEq(toUint256(state.stEffectiveNAV), 1, "st retains a single wei of live claim");
        assertEq(toUint256(state.jtEffectiveNAV), 0, "jt wiped out");
        assertEq(state.coverageUtilizationWAD, 0, "no exposure so the liquidation disjunct cannot be the trigger");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "wipeout alone forces perpetual");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 0, "il erased");
    }

    /**
     * a fully empty market (both effective NAVs zero) does NOT trip the wipeout disjunct — with il above
     * dust the other branches keep it in FIXED_TERM
     */
    function test_StateMachine_emptyMarketDoesNotForcePerpetual() public {
        _seedState(0, 300e18, 100e18, 200e18, 100e18, SEED_LT_RAW, MarketState.FIXED_TERM);
        uint32 end = uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS);
        SyncedAccountingState memory state = kernel.doPreOp(ZERO_NAV_UNITS, ZERO_NAV_UNITS);
        assertEq(toUint256(state.stEffectiveNAV), 0, "st effective NAV empties");
        assertEq(toUint256(state.jtEffectiveNAV), 0, "jt effective NAV empties");
        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "empty market stays in its term");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 100e18, "il persists in the empty market");
        assertEq(state.fixedTermEndTimestamp, end, "end timestamp kept");
    }

    /**
     * a dust-sized il in a PERPETUAL market persists un-erased across syncs and recovers organically on the
     * next gain without any reset event
     */
    function test_StateMachine_dustILPersistsInPerpetualAndRecovers() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stNAVDustTolerance = toNAVUnits(uint256(30));
        p.jtNAVDustTolerance = toNAVUnits(uint256(40));
        _deploy(false, p);
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        // Covered loss of 50 wei: il = 50 <= dust 70 stays PERPETUAL with the il persisted for later recovery
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW - 50), toNAVUnits(SEED_JT_RAW));
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "dust il never enters a fixed term");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 50, "dust il persists, not erased");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW - 50, "coverage applied");
        // Organic recovery on the next gain, with no il reset event
        vm.recordLogs();
        state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 0, "dust il recovered by the gain");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW, "jt made whole");
        assertEq(
            _countAccountantLogs(vm.getRecordedLogs(), IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset.selector),
            0,
            "organic recovery is not an il reset"
        );
    }

    /**
     * a FIXED_TERM market that recovers down to 0 < il <= dust stays FIXED_TERM (stickiness) with fees and
     * the lt premium zeroed, then transitions to PERPETUAL with FixedTermEnded only once the il reaches exactly zero
     * Derivation (dust 30 + 40 = 70): a covered 100e18 loss enters the term; then a mixed sync with
     * dST = +(90e18 - 50) and dJT = +20e18 attributes floor(20e18 * 100e18 / 200e18) = 10e18 of the jt gain to st,
     * so the st-side gain is exactly 100e18 - 50 and recovery leaves il = 50 (jt keeps its 10e18 residual gain,
     * fee zeroed); a final 50 wei gain zeroes the il and ends the term
     */
    function test_StateMachine_fixedTermStickyWithDustILThenEndsAtZero() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stNAVDustTolerance = toNAVUnits(uint256(30));
        p.jtNAVDustTolerance = toNAVUnits(uint256(40));
        _deploy(false, p);
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        // Enter the fixed term on a covered 100e18 loss
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(900e18)), toNAVUnits(SEED_JT_RAW));
        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "loss above dust enters the term");
        uint32 end = state.fixedTermEndTimestamp;
        // Recover into the dust band: stays FIXED_TERM, jt gain NAV kept, its fee zeroed
        state = kernel.doPreOp(toNAVUnits(uint256(990e18 - 50)), toNAVUnits(uint256(220e18)));
        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "dust il keeps the term sticky");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 50, "il recovered into the dust band");
        assertEq(toUint256(state.jtEffectiveNAV), 210e18 - 50, "recovery plus the jt residual gain");
        assertEq(toUint256(state.jtProtocolFee), 0, "jt fee zeroed while the term is sticky");
        assertEq(state.fixedTermEndTimestamp, end, "end timestamp kept");
        // Full recovery to exactly zero il ends the term
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        state = kernel.doPreOp(toNAVUnits(uint256(990e18)), toNAVUnits(uint256(220e18)));
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "zero il ends the sticky term");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 0, "il fully recovered");
        assertEq(state.fixedTermEndTimestamp, 0, "end timestamp deleted");
    }

    /**
     * fixed-term entry stamps end = now + duration with an exact FixedTermCommenced, and a re-sync inside the
     * term keeps the ORIGINAL end with no transition event even as the il deepens
     */
    function test_StateMachine_fixedTermEntrySetsEndOnceAndKeepsOriginal() public {
        _seedAndInitAccrual();
        uint32 expectedEnd = uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermCommenced(expectedEnd);
        kernel.doPreOp(toNAVUnits(uint256(950e18)), toNAVUnits(SEED_JT_RAW));
        assertEq(accountant.getState().fixedTermEndTimestamp, expectedEnd, "entry stamps now plus duration");
        // A deeper covered loss 1000 seconds later keeps the original end and emits no transition event
        vm.warp(block.timestamp + 1000);
        vm.recordLogs();
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(940e18)), toNAVUnits(SEED_JT_RAW));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermCommenced.selector), 0, "no re-entry event inside the term");
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermEnded.selector), 0, "no exit event inside the term");
        assertEq(state.fixedTermEndTimestamp, expectedEnd, "original end kept on re-sync");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 60e18, "il deepened inside the term");
    }

    /**
     * the FIXED_TERM zeroing asymmetry — a junior net gain earned in the term-entering sync keeps its full
     * NAV in jtEffectiveNAV (including the value the protocol would have fee'd) while the protocol fee itself is zeroed
     *
     * NOTE: a nonzero jtRiskPremium in a FIXED_TERM-landing sync is unreachable — any premium
     * requires a residual senior gain, which requires the coverage impermanent loss to have fully recovered to
     * zero, which lands the sync in PERPETUAL where fees are kept. The kept-NAV / zeroed-fee asymmetry is
     * therefore pinned via the junior net gain, the only premium-like NAV that can coexist with a resulting term
     */
    function test_StateMachine_fixedTermZeroingKeepsJTGainNAVWhileZeroingFee() public {
        _seedAndInitAccrual();
        // dST = -10e18, dJT = +50e18: the jt fee books 5e18 and recomputes to 4e18 on the post-coverage 40e18 net
        // gain, then the FIXED_TERM entry zeroes it while jtEffectiveNAV keeps the full 50e18 gain less the 10e18 coverage
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(990e18)), toNAVUnits(uint256(250e18)));
        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "covered loss enters the term");
        assertEq(toUint256(state.jtEffectiveNAV), 240e18, "jt keeps its full gain NAV including the would-be fee");
        assertEq(toUint256(state.jtProtocolFee), 0, "jt protocol fee zeroed in the term");
        assertEq(toUint256(state.stProtocolFee), 0, "st protocol fee zeroed in the term");
        assertEq(toUint256(state.ltProtocolFee), 0, "lt protocol fee zeroed in the term");
        assertEq(toUint256(state.ltLiquidityPremium), 0, "lt premium zeroed in the term");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 10e18, "coverage il booked");
    }

    /// transition events fire exactly once per edge and never on the PERPETUAL->PERPETUAL or FIXED->FIXED self-edges
    function test_StateMachine_transitionEventsExactlyOncePerEdge() public {
        _seedAndInitAccrual();
        // PERPETUAL -> FIXED_TERM
        vm.recordLogs();
        kernel.doPreOp(toNAVUnits(uint256(950e18)), toNAVUnits(SEED_JT_RAW));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermCommenced.selector), 1, "entry edge emits exactly one commencement");
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermEnded.selector), 0, "entry edge emits no end");
        // FIXED_TERM -> FIXED_TERM
        vm.recordLogs();
        kernel.doPreOp(toNAVUnits(uint256(940e18)), toNAVUnits(SEED_JT_RAW));
        logs = vm.getRecordedLogs();
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermCommenced.selector), 0, "self-edge emits no commencement");
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermEnded.selector), 0, "self-edge emits no end");
        // FIXED_TERM -> PERPETUAL via full recovery
        vm.recordLogs();
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        logs = vm.getRecordedLogs();
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermCommenced.selector), 0, "exit edge emits no commencement");
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermEnded.selector), 1, "exit edge emits exactly one end");
        // PERPETUAL -> PERPETUAL
        vm.recordLogs();
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        logs = vm.getRecordedLogs();
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermCommenced.selector), 0, "perpetual self-edge emits no commencement");
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermEnded.selector), 0, "perpetual self-edge emits no end");
    }

    /**
     * the premium accrual window resets on payment independently of the market state at the start of the sync
     *
     * NOTE: premiumsPaid with a RESULTING fixed term is unreachable (premiums require the il to
     * have fully recovered to zero, which lands PERPETUAL), so the reset-regardless property is pinned on a
     * premium-paying sync that starts in FIXED_TERM and crosses to PERPETUAL
     * Derivation: from the 100e18-il term checkpoint, rates 0.05e18 / 0.02e18 over 500s give tw = (25e18, 10e18);
     * a 150e18 gain recovers the il and pays on the 50e18 residual: jtPrem = floor(50e18 * 25e18 / (500 * 1e18))
     * = 2.5e18, ltPrem = 1e18, fees kept in the resulting PERPETUAL: jtFee 0.25e18, ltFee 0.1e18,
     * stFee = floor(46.5e18 * 0.1) = 4.65e18
     */
    function test_StateMachine_premiumWindowResetOnFixedTermExit() public {
        _seedLargeIL();
        uint32 windowStart = uint32(block.timestamp);
        jtYDM.setYieldShareReturn(0.05e18);
        ltYDM.setYieldShareReturn(0.02e18);
        vm.warp(block.timestamp + 500);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1050e18)), toNAVUnits(uint256(300e18)));
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "recovered market exits the term");
        assertEq(toUint256(state.jtEffectiveNAV), 302.5e18, "recovery plus the time-weighted risk premium");
        assertEq(toUint256(state.ltLiquidityPremium), 1e18, "time-weighted liquidity premium");
        assertEq(toUint256(state.stEffectiveNAV), 1047.5e18, "st residual plus the premium value retained senior");
        assertEq(toUint256(state.jtProtocolFee), 0.25e18, "jt yield-share fee kept");
        assertEq(toUint256(state.ltProtocolFee), 0.1e18, "lt fee kept");
        assertEq(toUint256(state.stProtocolFee), 4.65e18, "st fee kept");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(s.twJTYieldShareAccruedWAD, 0, "jt accumulator reset on payment");
        assertEq(s.twLTYieldShareAccruedWAD, 0, "lt accumulator reset on payment");
        // The expected clock is derived from windowStart rather than read from block.timestamp: the identical
        // pre-warp uint32(block.timestamp) read above gets CSE'd with a post-warp read under via-ir (TIMESTAMP is
        // frame-constant in the real EVM, so the optimizer may legally merge the reads across a vm.warp)
        assertEq(s.lastPremiumPaymentTimestamp, windowStart + 500, "premium clock advances on payment");
        assertGt(uint256(s.lastPremiumPaymentTimestamp), uint256(windowStart), "the window genuinely moved");
    }
}
