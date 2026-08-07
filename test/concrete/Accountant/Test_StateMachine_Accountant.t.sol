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
        _deploy(_defaultParams());
    }

    /**
     * a zero fixed-term duration configured at initialization keeps the market permanently perpetual: a
     * covered loss with il far above dust is erased on the sync with an exact reset event and never commences a term
     * Derivation: a -50e18 collateral loss on the flat 1200e18 checkpoint attributes
     * deltaST = -floor(50e18 * 1000e18 / 1200e18) = -41666666666666666666 with the JT residual
     * -8333333333333333334. The JT loss books il and the covered ST loss deepens it, so the whole loss lands
     * on JT: jtEff 150e18, would-be il 50e18, stEff unchanged. The zero-duration disjunct erases the il
     */
    function test_StateMachine_zeroDurationConfigNeverEntersFixedTerm() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.fixedTermDurationSeconds = 0;
        _deploy(p);
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        vm.recordLogs();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(toNAVUnits(uint256(50e18)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1150e18)));
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "permanently perpetual despite the covered loss");
        assertEq(toUint256(state.jtImpermanentLoss), 0, "il erased on the sync");
        assertEq(toUint256(state.jtEffectiveNAV), 150e18, "the whole covered loss lands on jt");
        assertEq(state.fixedTermEndTimestamp, 0, "no fixed term end stamped");
        assertEq(_countAccountantLogs(vm.getRecordedLogs(), IRoycoDayAccountant.FixedTermCommenced.selector), 0, "no term ever commences");
    }

    /**
     * the fixed term ends at the exact end == now boundary: the disjunct is an inclusive comparison
     * Events in emission order: FixedTermEnded from the transition, then the il reset of the full 100e18
     */
    function test_StateMachine_fixedTermEndsAtExactBoundary() public {
        _seedLargeIL();
        uint32 end = uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS);
        vm.warp(end);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(toNAVUnits(uint256(100e18)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1200e18)));
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "term ends exactly at its end timestamp");
        assertEq(toUint256(state.jtImpermanentLoss), 0, "il erased when the term elapses");
        assertEq(state.fixedTermEndTimestamp, 0, "end timestamp deleted");
        assertEq(accountant.getState().fixedTermEndTimestamp, 0, "committed end timestamp deleted");
    }

    /// one second before the end the fixed term persists with the il and end timestamp intact
    function test_StateMachine_fixedTermPersistsJustBeforeEnd() public {
        _seedLargeIL();
        uint32 end = uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS);
        vm.warp(end - 1);
        vm.recordLogs();
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1200e18)));
        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "term persists one second before its end");
        assertEq(toUint256(state.jtImpermanentLoss), 100e18, "il persists through the term");
        assertEq(state.fixedTermEndTimestamp, end, "end timestamp unchanged");
        assertEq(_countAccountantLogs(vm.getRecordedLogs(), IRoycoDayAccountant.FixedTermEnded.selector), 0, "no end event before the boundary");
    }

    /// well beyond the end timestamp the elapsed-term disjunct still fires
    function test_StateMachine_fixedTermEndsBeyondBoundary() public {
        _seedLargeIL();
        vm.warp(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS + 12_345);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1200e18)));
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "term ended after the end timestamp passed");
        assertEq(toUint256(state.jtImpermanentLoss), 0, "il erased");
        assertEq(state.fixedTermEndTimestamp, 0, "end timestamp deleted");
    }

    /**
     * the liquidation disjunct fires at exactly coverageUtilization == threshold, crafted with an exact division
     * Derivation: a -100e18 collateral loss on the large-IL 1200e18 checkpoint attributes
     * deltaST = -floor(100e18 * 1000e18 / 1200e18) = -83333333333333333333 with the JT residual
     * -16666666666666666667, all absorbed by JT under full coverage: jtEff 100e18, would-be il 200e18.
     * coverageUtilization = ceil(1100e18 * 0.1e18 / 100e18) = 1.1e18 exactly (110 / 100 divides at WAD
     * precision), landing exactly on the liquidation threshold and forcing perpetual mid fixed term
     */
    function test_StateMachine_liquidationUtilizationExactBoundaryForcesPerpetual() public {
        _seedLargeIL();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(toNAVUnits(uint256(200e18)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1100e18)));
        assertEq(state.coverageUtilizationWAD, DEFAULT_LIQUIDATION_UTILIZATION_WAD, "coverage utilization lands exactly on the threshold");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "liquidation breach forces perpetual");
        assertEq(toUint256(state.jtImpermanentLoss), 0, "il erased even mid fixed term");
        assertEq(toUint256(state.jtEffectiveNAV), 100e18, "coverage applied before the transition");
        assertEq(toUint256(state.stEffectiveNAV), 1000e18, "st fully covered");
        assertEq(state.fixedTermEndTimestamp, 0, "end timestamp deleted");
    }

    /**
     * just below the liquidation threshold the fixed term persists
     * Derivation: a -75e18 covered collateral loss lands wholly on JT (jtEff 125e18, il 175e18) and
     * coverageUtilization = ceil(1125e18 * 0.1e18 / 125e18) = 0.9e18 < 1.1e18, so the term persists
     */
    function test_StateMachine_belowLiquidationThresholdStaysFixedTerm() public {
        _seedLargeIL();
        uint32 end = uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1125e18)));
        assertEq(state.coverageUtilizationWAD, 0.9e18, "coverage utilization below the threshold");
        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "term persists below the liquidation threshold");
        assertEq(toUint256(state.jtImpermanentLoss), 175e18, "il accumulates instead of erasing");
        assertEq(state.fixedTermEndTimestamp, end, "end timestamp kept");
    }

    /**
     * A full junior wipeout (jtEffectiveNAV to 0 with a surviving senior claim) forces PERPETUAL. The surviving
     * senior claim is itself part of the collateral NAV the coverage requirement covers, so a zero junior buffer
     * drives coverage utilization to the type(uint256).max sentinel: the wipeout and liquidation disjuncts fire
     * together rather than the wipeout in isolation
     * Derivation from checkpoint (collateral 300e18, stEff 100e18, jtEff 200e18, il 100e18) with collateral -> 1 wei:
     *   deltaST = -floor((300e18 - 1) * 100e18 / 300e18) = -(100e18 - 1), JT residual loss = 200e18 exactly
     *   so jtEffectiveNAV = 0 with il = 300e18, the (100e18 - 1) st loss is uncovered leaving stEffectiveNAV = 1 wei
     */
    function test_StateMachine_juniorWipeoutForcesPerpetual() public {
        _seedState(100e18, 200e18, 100e18, SEED_LPT_RAW, MarketState.FIXED_TERM);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(toNAVUnits(uint256(300e18)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1)));
        assertEq(toUint256(state.stEffectiveNAV), 1, "st retains a single wei of live claim");
        assertEq(toUint256(state.jtEffectiveNAV), 0, "jt wiped out");
        assertEq(state.coverageUtilizationWAD, type(uint256).max, "a zero junior buffer over a live senior claim maxes coverage utilization");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "the junior wipeout forces perpetual");
        assertEq(toUint256(state.jtImpermanentLoss), 0, "il erased");
    }

    /**
     * a total wipe (both effective NAVs zero) trips the wipeout disjunct: the junior buffer is gone (partial
     * or total), so its dead restoration claim is extinguished and the market is forced perpetual mid-term
     * Derivation: collateral -> 0 attributes deltaST = -100e18 (uncovered once jt empties) and the JT
     * residual -200e18, landing stEff 0, jtEff 0 with a would-be il of 300e18 (100e18 carried plus the 200e18
     * wipeout loss). jtEffectiveNAV == 0 forces perpetual, erasing the 300e18 and clearing the term, so a
     * later zero-checkpoint recovery is a clean senior gain under the seniority tie-break
     */
    function test_StateMachine_emptyMarketWipeForcesPerpetualAndErases() public {
        _seedState(100e18, 200e18, 100e18, SEED_LPT_RAW, MarketState.FIXED_TERM);
        vm.expectEmit(false, false, false, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(toNAVUnits(uint256(300e18)));
        SyncedAccountingState memory state = kernel.doPreOp(ZERO_NAV_UNITS);
        assertEq(toUint256(state.stEffectiveNAV), 0, "st effective NAV empties");
        assertEq(toUint256(state.jtEffectiveNAV), 0, "jt effective NAV empties");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "the total wipe forces perpetual");
        assertEq(toUint256(state.jtImpermanentLoss), 0, "the dead restoration claim is erased");
        assertEq(state.fixedTermEndTimestamp, 0, "the term is cleared");
    }

    /**
     * a dust-sized drawdown from PERPETUAL is ERASED on the perpetual commit: the reset event fires with the
     * dust value, the ledger clears, and the next gain is a plain pro-rata gain, NOT a restoration of JT
     * Derivation (dust 70): a 50 wei collateral loss attributes deltaST = -floor(50 * 1000e18 / 1200e18) = -41
     * with the JT residual -9, all landing on JT under coverage: jtEff = 200e18 - 50 with a would-be il of 50.
     * il 50 <= dust 70 from PERPETUAL resolves PERPETUAL and every perpetual commit clears the IL ledger, so
     * the 50 is erased at commit. The +50 recovery then splits 41/9 pro-rata with no ledger to repay: ST keeps
     * its 41 (below dust so no fee or premiumsPaid) and JT keeps only its 9 residual, ending at 200e18 - 41
     */
    function test_StateMachine_dustDrawdownFromPerpetualErasedAtCommit() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.dustTolerance = toNAVUnits(uint256(70));
        _deploy(p);
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        // Covered loss of 50 wei: the perpetual commit erases the dust drawdown with its exact reset event
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(toNAVUnits(uint256(50)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_EFF + SEED_JT_EFF - 50));
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "dust drawdown never enters a fixed term");
        assertEq(toUint256(state.jtImpermanentLoss), 0, "a perpetual commit never carries a drawdown");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF - 50, "the covered loss stays realized on jt");
        assertEq(toUint256(accountant.getState().lastJTImpermanentLoss), 0, "committed ledger cleared");
        // The next gain is a plain gain: pro-rata split with nothing to restore and no further reset event
        vm.recordLogs();
        state = kernel.doPreOp(toNAVUnits(SEED_ST_EFF + SEED_JT_EFF));
        assertEq(toUint256(state.jtImpermanentLoss), 0, "no ledger to repay");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF - 41, "jt keeps only its 9 wei residual, not a restoration");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF + 41, "st keeps its attributed 41 wei share");
        assertEq(
            _countAccountantLogs(vm.getRecordedLogs(), IRoycoDayAccountant.JuniorTrancheImpermanentLossReset.selector),
            0,
            "a zero-ledger perpetual commit emits no reset"
        );
    }

    /**
     * a FIXED_TERM market that recovers down to 0 < il <= dust exits the term at that commit: the dust
     * disjunct erases the remainder (reset event) and deletes the end, and the next gain is a plain gain
     * Derivation (dust 70): a covered -100e18 loss enters the term (jtEff 100e18, il 100e18). The recovery to
     * 1200e18-50 is a gain of 100e18-50, fully consumed repaying the il down to exactly 50 (no fee books,
     * restoration is never fee'd), landing il 50 in (0, 70]: the dust disjunct resolves PERPETUAL, erases the
     * 50 wei, and ends the term. The final 50 wei gain from the erased checkpoint is a plain dust-sized gain
     * (stGain = floor(50 * 1000e18 / (1200e18-50)) = 41, jtGain 9, no fees at most dust, no premium reset)
     */
    function test_StateMachine_recoveryIntoDustBandErasesAndEndsTerm() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.dustTolerance = toNAVUnits(uint256(70));
        // The covered 100e18 loss below marks coverageUtilization ceil(1100e18 * 0.1 / 100e18) = 1.1e18: lift the
        // liquidation threshold clear of it so this test exercises the IL / dust-tolerance path rather than a liquidation breach
        p.coverageLiquidationUtilizationWAD = 1.5e18;
        _deploy(p);
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        // Enter the fixed term on a covered 100e18 loss
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1100e18)));
        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "loss above dust enters the term");
        // Recover into the dust band: the remainder is erased and the term ends at this commit
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(toNAVUnits(uint256(50)));
        state = kernel.doPreOp(toNAVUnits(uint256(1200e18 - 50)));
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "dust il exits the term at the commit");
        assertEq(toUint256(state.jtImpermanentLoss), 0, "the dust remainder is erased");
        assertEq(toUint256(state.jtEffectiveNAV), 200e18 - 50, "the repayment restores jt before the erasure");
        assertEq(toUint256(state.jtProtocolFee), 0, "no jt fee books, the gain was fully consumed by the repayment");
        assertEq(state.fixedTermEndTimestamp, 0, "end timestamp deleted");
        // The final 50 wei gain from the erased checkpoint is a plain gain, not a recovery
        state = kernel.doPreOp(toNAVUnits(uint256(1200e18)));
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "the market stays perpetual");
        assertEq(toUint256(state.jtImpermanentLoss), 0, "no il accrues on a gain");
        assertEq(toUint256(state.jtEffectiveNAV), 200e18 - 41, "jt takes the residual of the plain dust gain");
    }

    /**
     * fixed-term entry stamps end = now + duration with an exact FixedTermCommenced, and a re-sync inside the
     * term keeps the ORIGINAL end with no transition event even as the il deepens
     * Derivation: the -50e18 entry loss lands wholly on JT (jtEff 150e18, il 50e18). The deeper sync to 1140e18
     * is a further -10e18: deltaST = -floor(10e18 * 1000e18 / 1150e18) = -8695652173913043478 with the JT
     * residual -1304347826086956522, all landing on JT under coverage: il = 60e18
     */
    function test_StateMachine_fixedTermEntrySetsEndOnceAndKeepsOriginal() public {
        _seedAndInitAccrual();
        uint32 expectedEnd = uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermCommenced(expectedEnd);
        kernel.doPreOp(toNAVUnits(uint256(1150e18)));
        assertEq(accountant.getState().fixedTermEndTimestamp, expectedEnd, "entry stamps now plus duration");
        // A deeper covered loss 1000 seconds later keeps the original end and emits no transition event
        vm.warp(block.timestamp + 1000);
        vm.recordLogs();
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1140e18)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermCommenced.selector), 0, "no re-entry event inside the term");
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermEnded.selector), 0, "no exit event inside the term");
        assertEq(state.fixedTermEndTimestamp, expectedEnd, "original end kept on re-sync");
        assertEq(toUint256(state.jtImpermanentLoss), 60e18, "il deepened inside the term");
    }

    /**
     * a term-persisting gain sync keeps the FULL gain in jtEffectiveNAV with every fee and premium zero :
     * restoration is never fee'd, so no protocol take can exist while the term persists
     *
     * NOTE: a nonzero fee in a FIXED_TERM-landing sync is unreachable under the single-collateral attribution.
     * Any fee requires a residual gain, a residual gain requires the il to have fully recovered to zero, and a
     * zero il lands the sync in PERPETUAL. The old mixed-sign vector (senior loss with a junior gain) that
     * observed the FIXED_TERM fee zeroing directly is unrepresentable, so this pins the reachable half: the
     * whole gain reaches JT as recovery and the term reports zero fees and premium
     * Derivation: a +40e18 gain on the large-IL checkpoint splits deltaST = floor(40e18 * 1000e18 / 1200e18)
     * = 33333333333333333333 and JT residual 6666666666666666667, both fully consumed repaying the il:
     * il = 100e18 - 40e18 = 60e18, jtEff = 240e18, stEff unchanged, term persists
     */
    function test_StateMachine_fixedTermGainKeptWhollyByJTWithZeroFees() public {
        _seedLargeIL();
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1240e18)));
        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "partial recovery keeps the term");
        assertEq(toUint256(state.jtEffectiveNAV), 240e18, "jt keeps the full gain NAV as recovery");
        assertEq(toUint256(state.stEffectiveNAV), 1000e18, "st books none of the recovery");
        assertEq(toUint256(state.jtProtocolFee), 0, "no jt protocol fee in the term");
        assertEq(toUint256(state.stProtocolFee), 0, "no st protocol fee in the term");
        assertEq(toUint256(state.lptProtocolFee), 0, "no lt protocol fee in the term");
        assertEq(toUint256(state.lptLiquidityPremium), 0, "no lt premium in the term");
        assertEq(toUint256(state.jtImpermanentLoss), 60e18, "il repaid by exactly the gain");
    }

    /// transition events fire exactly once per edge and never on the PERPETUAL->PERPETUAL or FIXED->FIXED self-edges
    function test_StateMachine_transitionEventsExactlyOncePerEdge() public {
        _seedAndInitAccrual();
        // PERPETUAL -> FIXED_TERM
        vm.recordLogs();
        kernel.doPreOp(toNAVUnits(uint256(1150e18)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermCommenced.selector), 1, "entry edge emits exactly one commencement");
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermEnded.selector), 0, "entry edge emits no end");
        // FIXED_TERM -> FIXED_TERM
        vm.recordLogs();
        kernel.doPreOp(toNAVUnits(uint256(1140e18)));
        logs = vm.getRecordedLogs();
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermCommenced.selector), 0, "self-edge emits no commencement");
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermEnded.selector), 0, "self-edge emits no end");
        // FIXED_TERM -> PERPETUAL via full recovery (the +60e18 gain repays the il exactly)
        vm.recordLogs();
        kernel.doPreOp(toNAVUnits(SEED_ST_EFF + SEED_JT_EFF));
        logs = vm.getRecordedLogs();
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermCommenced.selector), 0, "exit edge emits no commencement");
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermEnded.selector), 1, "exit edge emits exactly one end");
        // PERPETUAL -> PERPETUAL
        vm.recordLogs();
        kernel.doPreOp(toNAVUnits(SEED_ST_EFF + SEED_JT_EFF));
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
     * Derivation: from the large-IL checkpoint, rates 0.05e18 / 0.02e18 over 500s give tw = (25e18, 10e18).
     * A +150e18 gain repays the 100e18 il off the top (jtEffectiveNAV 300e18, residual 50e18, basis 1300e18):
     * stGain = floor(50e18 * 1000e18 / 1300e18) = 38461538461538461538, jtGain = 11538461538461538462 books
     * jtFee 1153846153846153846. jtPrem = floor(stGain * 25e18 / (500 * 1e18)) = 1923076923076923076,
     * lptPrem = 769230769230769230, fees kept in the resulting PERPETUAL: jtFee += 192307692307692307
     * (total 1346153846153846153), lptFee 76923076923076923, st residual 35769230769230769232,
     * stFee 3576923076923076923, jtEff = 313461538461538461538, stEff = 1036538461538461538462
     */
    function test_StateMachine_premiumWindowResetOnFixedTermExit() public {
        _seedLargeIL();
        uint32 windowStart = uint32(block.timestamp);
        jtYDM.setYieldShareReturn(0.05e18);
        lptYDM.setYieldShareReturn(0.02e18);
        vm.warp(block.timestamp + 500);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1350e18)));
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "recovered market exits the term");
        assertEq(toUint256(state.jtEffectiveNAV), 313_461_538_461_538_461_538, "repayment plus the junior residual and time-weighted risk premium");
        assertEq(toUint256(state.lptLiquidityPremium), 769_230_769_230_769_230, "time-weighted liquidity premium");
        assertEq(toUint256(state.stEffectiveNAV), 1_036_538_461_538_461_538_462, "st residual plus the premium value retained senior");
        assertEq(toUint256(state.jtProtocolFee), 1_346_153_846_153_846_153, "jt residual and yield-share fees kept");
        assertEq(toUint256(state.lptProtocolFee), 76_923_076_923_076_923, "lt fee kept");
        assertEq(toUint256(state.stProtocolFee), 3_576_923_076_923_076_923, "st fee kept");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(s.twJTYieldShareAccruedWAD, 0, "jt accumulator reset on payment");
        assertEq(s.twLPTYieldShareAccruedWAD, 0, "lt accumulator reset on payment");
        // The expected clock is derived from windowStart rather than read from block.timestamp: the identical
        // pre-warp uint32(block.timestamp) read above gets CSE'd with a post-warp read under via-ir (TIMESTAMP is
        // frame-constant in the real EVM, so the optimizer may legally merge the reads across a vm.warp)
        assertEq(s.lastPremiumPaymentTimestamp, windowStart + 500, "premium clock advances on payment");
        assertGt(uint256(s.lastPremiumPaymentTimestamp), uint256(windowStart), "the window genuinely moved");
    }
}
