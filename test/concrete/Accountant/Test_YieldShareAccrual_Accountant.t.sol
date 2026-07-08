// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { stdError } from "../../../lib/forge-std/src/StdError.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { IYDM } from "../../../src/interfaces/IYDM.sol";
import { WAD } from "../../../src/libraries/Constants.sol";
import { MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { AccountantTestBase } from "../../utils/AccountantTestBase.sol";

/**
 * @title Test_YieldShareAccrual_Accountant
 * @notice The time-weighted yield-share accrual bookkeeping: first-sync clock initialization, the
 *         same-block no-op, capped accrual on both sides, the YDM consultation arguments, the accrual
 *         events, the preview twin's three branches, and window contiguity under a fuzzed sequence
 */
contract Test_YieldShareAccrual_Accountant is AccountantTestBase {
    function setUp() public {
        stranger = makeAddr("stranger");
        _deploy(false, _defaultParams());
    }

    /// the first-ever accrual initializes both timestamps, leaves the accumulators at zero, and never calls the YDMs
    function test_Accrual_firstSyncInitializesTimestampsWithoutYDMCalls() public {
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        jtYDM.setYieldShareReturn(0.15e18);
        ltYDM.setYieldShareReturn(0.05e18);
        vm.warp(block.timestamp + 123);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(s.lastYieldShareAccrualTimestamp, uint32(block.timestamp), "accrual timestamp initialized");
        assertEq(s.lastPremiumPaymentTimestamp, uint32(block.timestamp), "premium payment timestamp initialized");
        assertEq(s.twJTYieldShareAccruedWAD, 0, "jt accumulator untouched");
        assertEq(s.twLTYieldShareAccruedWAD, 0, "lt accumulator untouched");
        assertEq(jtYDM.yieldShareCallCount(), 0, "jt ydm not consulted on first accrual");
        assertEq(ltYDM.yieldShareCallCount(), 0, "lt ydm not consulted on first accrual");
    }

    /**
     * Nuance pinned — NOTE: an earlier analysis claimed no premium can be paid on the first sync,
     * but the first accrual sets lastPremiumPaymentTimestamp to now, so a gain in that same first sync takes the
     * instantaneous branch (elapsed forced to 1s) and pays premiums from the preview rates
     *
     * Derivation with gain g = 100e18, jt preview 0.1e18 (below the 0.2e18 cap), lt preview 0.05e18 (below the 0.1e18 cap):
     *   jtRiskPremium      = floor(100e18 * 0.1e18 / (1 * 1e18)) = 10e18
     *   ltLiquidityPremium = floor(100e18 * 0.05e18 / (1 * 1e18)) = 5e18
     *   jtEffectiveNAV = 200e18 + 10e18 = 210e18, stEffectiveNAV = 1000e18 + (100e18 - 10e18 - 5e18) + 5e18 = 1090e18
     */
    function test_Accrual_firstSyncGainPaysInstantaneousPremium() public {
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        jtYDM.setPreviewYieldShareReturn(0.1e18);
        ltYDM.setPreviewYieldShareReturn(0.05e18);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW + 100e18), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(state.jtEffectiveNAV), 210e18, "jt premium paid via instantaneous branch");
        assertEq(toUint256(state.ltLiquidityPremium), 5e18, "lt premium paid via instantaneous branch");
        assertEq(toUint256(state.stEffectiveNAV), 1090e18, "st retains residual plus lt premium value retained senior");
    }

    /// a same-block re-accrual is a no-op — the YDMs are not called and the accumulators and timestamp are unchanged
    function test_Accrual_sameBlockReaccrualIsNoop() public {
        _seedAndInitAccrual();
        jtYDM.setYieldShareReturn(0.15e18);
        ltYDM.setYieldShareReturn(0.05e18);
        vm.warp(block.timestamp + 1000);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        uint256 jtCalls = jtYDM.yieldShareCallCount();
        uint256 ltCalls = ltYDM.yieldShareCallCount();
        IRoycoDayAccountant.RoycoDayAccountantState memory before = accountant.getState();
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        IRoycoDayAccountant.RoycoDayAccountantState memory afterState = accountant.getState();
        assertEq(jtYDM.yieldShareCallCount(), jtCalls, "jt ydm not re-consulted in the same block");
        assertEq(ltYDM.yieldShareCallCount(), ltCalls, "lt ydm not re-consulted in the same block");
        assertEq(afterState.twJTYieldShareAccruedWAD, before.twJTYieldShareAccruedWAD, "jt accumulator unchanged");
        assertEq(afterState.twLTYieldShareAccruedWAD, before.twLTYieldShareAccruedWAD, "lt accumulator unchanged");
        assertEq(afterState.lastYieldShareAccrualTimestamp, before.lastYieldShareAccrualTimestamp, "accrual timestamp unchanged");
    }

    /**
     * the accrual adds min(yieldShare, max) * elapsed to each accumulator
     * Derivation: jt rate 0.15e18 < max 0.2e18 so raw, lt rate 0.5e18 > max 0.1e18 so capped
     *   twJT = 0.15e18 * 3600 = 540e18, twLT = 0.1e18 * 3600 = 360e18
     */
    function test_Accrual_accruesTimeWeightedSharesWithCapBothSides() public {
        _seedAndInitAccrual();
        jtYDM.setYieldShareReturn(0.15e18);
        ltYDM.setYieldShareReturn(0.5e18);
        vm.warp(block.timestamp + 3600);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(s.twJTYieldShareAccruedWAD, uint192(0.15e18 * 3600), "jt accrues its raw sub-cap rate");
        assertEq(s.twLTYieldShareAccruedWAD, uint192(0.1e18 * 3600), "lt rate capped at maxLTYieldShareWAD");
        assertEq(s.lastYieldShareAccrualTimestamp, uint32(block.timestamp), "accrual timestamp advanced");
    }

    /// accumulators compound across windows when no premium is paid in between
    function test_Accrual_accumulatesAcrossWindowsWithoutPremiumPayment() public {
        _seedAndInitAccrual();
        jtYDM.setYieldShareReturn(0.15e18);
        ltYDM.setYieldShareReturn(0.05e18);
        vm.warp(block.timestamp + 3600);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        jtYDM.setYieldShareReturn(0.02e18);
        ltYDM.setYieldShareReturn(0.01e18);
        vm.warp(block.timestamp + 100);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        // twJT = 0.15e18 * 3600 + 0.02e18 * 100, twLT = 0.05e18 * 3600 + 0.01e18 * 100
        assertEq(s.twJTYieldShareAccruedWAD, uint192(0.15e18 * 3600 + 0.02e18 * 100), "jt accumulator compounds");
        assertEq(s.twLTYieldShareAccruedWAD, uint192(0.05e18 * 3600 + 0.01e18 * 100), "lt accumulator compounds");
    }

    /// the YDMs are consulted with the last market state and utilizations computed from the last-committed checkpoints
    function test_Accrual_ydmCalledWithLastCheckpointArgs() public {
        _seedAndInitAccrual();
        vm.warp(block.timestamp + 60);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        assertEq(uint8(jtYDM.lastYieldShareMarketState()), uint8(MarketState.PERPETUAL), "jt ydm sees the last market state");
        assertEq(jtYDM.lastYieldShareUtilizationWAD(), SEED_COVERAGE_UTILIZATION_WAD, "jt ydm sees the checkpoint coverage utilization");
        assertEq(uint8(ltYDM.lastYieldShareMarketState()), uint8(MarketState.PERPETUAL), "lt ydm sees the last market state");
        assertEq(ltYDM.lastYieldShareUtilizationWAD(), SEED_LIQUIDITY_UTILIZATION_WAD, "lt ydm sees the checkpoint liquidity utilization");
    }

    /**
     * in a FIXED_TERM market the accrual passes FIXED_TERM and the cross-claim checkpoint utilizations
     * Seed: deposits 1000e18/300e18 then a covered 100e18 loss lands (900e18, 300e18, 1000e18, 200e18, il 100e18)
     * Derivation: coverageUtilization = ceil(900e18 * 0.1e18 / 200e18) = 0.45e18, liquidityUtilization = ceil(1000e18 * 0.05e18 / 100e18) = 0.5e18
     */
    function test_Accrual_ydmSeesFixedTermStateAndCrossClaimUtilizations() public {
        _seedState(900e18, 300e18, 1000e18, 200e18, 100e18, SEED_LT_RAW, MarketState.FIXED_TERM);
        vm.warp(block.timestamp + 3600);
        kernel.doPreOp(toNAVUnits(uint256(900e18)), toNAVUnits(uint256(300e18)));
        assertEq(uint8(jtYDM.lastYieldShareMarketState()), uint8(MarketState.FIXED_TERM), "jt ydm sees FIXED_TERM");
        assertEq(jtYDM.lastYieldShareUtilizationWAD(), 0.45e18, "coverage utilization from cross-claim checkpoints");
        assertEq(ltYDM.lastYieldShareUtilizationWAD(), 0.5e18, "liquidity utilization from checkpoints");
    }

    /// the accrual emits both yield-share events with the capped share and the new accumulator
    function test_Accrual_emitsYieldShareAccruedEvents() public {
        _seedAndInitAccrual();
        jtYDM.setYieldShareReturn(0.9e18);
        ltYDM.setYieldShareReturn(0.04e18);
        vm.warp(block.timestamp + 500);
        // jt capped: min(0.9e18, 0.2e18) = 0.2e18, lt raw: 0.04e18 below the 0.1e18 cap
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheYieldShareAccrued(0.2e18, 0.2e18 * 500);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.LiquidityTrancheYieldShareAccrued(0.04e18, 0.04e18 * 500);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
    }

    /// the mutating accrual calls yieldShare while the preview twin calls previewYieldShare and writes nothing
    function test_Accrual_mutatingCallsYieldShareAndPreviewIsPure() public {
        _seedAndInitAccrual();
        jtYDM.setRates(0.05e18);
        ltYDM.setRates(0.03e18);
        vm.warp(block.timestamp + 250);
        bytes32 preHash = _stateHash();
        vm.expectCall(address(jtYDM), abi.encodeCall(IYDM.previewYieldShare, (MarketState.PERPETUAL, SEED_COVERAGE_UTILIZATION_WAD)));
        vm.expectCall(address(ltYDM), abi.encodeCall(IYDM.previewYieldShare, (MarketState.PERPETUAL, SEED_LIQUIDITY_UTILIZATION_WAD)));
        accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        assertEq(_stateHash(), preHash, "preview must not mutate storage");
        assertEq(jtYDM.yieldShareCallCount(), 0, "preview must not call the mutating yieldShare");
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        assertEq(jtYDM.yieldShareCallCount(), 1, "mutating accrual calls yieldShare on the jt ydm");
        assertEq(ltYDM.yieldShareCallCount(), 1, "mutating accrual calls yieldShare on the lt ydm");
    }

    /**
     * preview twin with lastUpdate == 0 returns (0, 0) accumulators so a previewed gain pays no premium
     * Derivation with gain 40e18: elapsed since the zero premium timestamp is nonzero so the instantaneous branch
     * is skipped, tw accumulators are (0, 0), both premiums floor to 0, stProtocolFee = floor(40e18 * 0.1e18 / 1e18) = 4e18
     */
    function test_Accrual_previewBeforeFirstAccrualPaysNoPremium() public {
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        jtYDM.setRates(0.2e18);
        ltYDM.setRates(0.1e18);
        vm.warp(block.timestamp + 100);
        SyncedAccountingState memory state = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_ST_RAW + 40e18), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW, "no jt premium from a zeroed accrual clock");
        assertEq(toUint256(state.ltLiquidityPremium), 0, "no lt premium from a zeroed accrual clock");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_RAW + 40e18, "full gain retained by st");
        assertEq(toUint256(state.stProtocolFee), 4e18, "st fee on the retained gain");
    }

    /**
     * preview twin with elapsed == 0 returns the stored accumulators, ignoring the live preview rates
     * Derivation: window of 1000s at jt rate 0.05e18 and lt rate 0.03e18 accrues tw = (5e19, 3e19), elapsed since
     * the premium clock is 1000s, so a previewed gain of 100e18 pays
     *   jtPrem = floor(100e18 * 5e19 / (1000 * 1e18)) = 5e18 and ltPrem = floor(100e18 * 3e19 / (1000 * 1e18)) = 3e18
     */
    function test_Accrual_previewSameBlockUsesStoredAccumulators() public {
        _seedAndInitAccrual();
        jtYDM.setRates(0.05e18);
        ltYDM.setRates(0.03e18);
        vm.warp(block.timestamp + 1000);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        // Hostile preview rates prove the elapsed == 0 arm ignores them in favor of the accumulators
        jtYDM.setPreviewYieldShareReturn(WAD);
        ltYDM.setPreviewYieldShareReturn(WAD);
        SyncedAccountingState memory state = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_ST_RAW + 100e18), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + 5e18, "jt premium from stored accumulators only");
        assertEq(toUint256(state.ltLiquidityPremium), 3e18, "lt premium from stored accumulators only");
    }

    /**
     * preview twin with elapsed > 0 returns accumulators plus capped share times elapsed
     * Derivation: window one accrues at (0.05e18, 0.03e18) for 1000s giving (5e19, 3e19), then preview rates change
     * to jt 0.08e18 and lt 0.2e18 (capped to 0.1e18) for a 500s un-accrued tail, so the preview accrual is
     *   twJT = 5e19 + 0.08e18 * 500 = 9e19 and twLT = 3e19 + 0.1e18 * 500 = 8e19
     * with elapsed since the premium clock 1500s, a previewed gain of 100e18 pays
     *   jtPrem = floor(100e18 * 9e19 / (1500 * 1e18)) = 6e18
     *   ltPrem = floor(100e18 * 8e19 / (1500 * 1e18)) = floor(16e18 / 3) = 5333333333333333333
     */
    function test_Accrual_previewElapsedAddsCappedShareTimesElapsed() public {
        _seedAndInitAccrual();
        jtYDM.setRates(0.05e18);
        ltYDM.setRates(0.03e18);
        vm.warp(block.timestamp + 1000);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        jtYDM.setPreviewYieldShareReturn(0.08e18);
        ltYDM.setPreviewYieldShareReturn(0.2e18);
        vm.warp(block.timestamp + 500);
        bytes32 preHash = _stateHash();
        SyncedAccountingState memory state = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_ST_RAW + 100e18), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + 6e18, "jt premium from accumulator plus tail");
        assertEq(toUint256(state.ltLiquidityPremium), 5_333_333_333_333_333_333, "lt premium from capped tail rate");
        assertEq(_stateHash(), preHash, "preview must not mutate storage");
    }

    /// same-block preview and pre-op sync agree field-by-field on identical inputs
    function test_Accrual_previewParityWithPreOpSameBlock() public {
        _seedAndInitAccrual();
        jtYDM.setRates(0.05e18);
        ltYDM.setRates(0.03e18);
        vm.warp(block.timestamp + 1000);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        SyncedAccountingState memory previewed = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_ST_RAW + 100e18), toNAVUnits(SEED_JT_RAW));
        SyncedAccountingState memory executed = kernel.doPreOp(toNAVUnits(SEED_ST_RAW + 100e18), toNAVUnits(SEED_JT_RAW));
        assertEq(keccak256(abi.encode(previewed)), keccak256(abi.encode(executed)), "preview must match execution exactly");
    }

    /**
     * the uint192 accumulators survive a 100-year window at a 100% yield share
     * Derivation: 1e18 * (100 * 365 days) = 1e18 * 3153600000 = 3.1536e27, far below 2^192
     */
    function test_Accrual_accumulatorNoOverflowAt100Years() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.maxJTYieldShareWAD = uint64(WAD);
        p.maxLTYieldShareWAD = 0;
        _deploy(false, p);
        _seedAndInitAccrual();
        jtYDM.setYieldShareReturn(WAD);
        vm.warp(block.timestamp + 100 * 365 days);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        assertEq(accountant.getState().twJTYieldShareAccruedWAD, uint192(uint256(1e18) * 3_153_600_000), "century-scale accumulator exact");
    }

    /**
     * the uint192 accumulator's checked += fails loud once the running total would exceed its width
     * A market whose accrual window is never consumed (no gain sync ever pays premiums, so the accumulator is
     * never reset) grows by rate * elapsed forever. When the running total would pass type(uint192).max the
     * checked += reverts with an arithmetic panic, bricking every subsequent sync — a loud failure, in contrast
     * to the silent single-increment wrap covered by test_AccrualIncrementCastWrapsModuloUint192_DoesNotRevert
     * Derivation, from the accumulator width alone:
     *   type(uint192).max = 2^192 - 1 = 6277101735386680763835789423207666416102355444464034512895
     *   E1 = floor((2^192 - 1) / 1e18) - 1 = 6277101735386680763835789423207666416101
     *   first increment = 1e18 * E1 = 6277101735386680763835789423207666416101000000000000000000
     *     which sits 1355444464034512895 under the max, so the uint192 cast is lossless and the += from zero fits
     *   a second window of E1 seconds doubles the total: 2 * (1e18 * E1) > 2^192 - 1, so the checked += panics
     */
    function test_RevertIf_AccrualAccumulatorOverflowsUint192() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.maxJTYieldShareWAD = uint64(WAD);
        p.maxLTYieldShareWAD = 0;
        _deploy(false, p);
        _seedAndInitAccrual();
        jtYDM.setYieldShareReturn(WAD);

        // First window: a flat sync (no gain, so nothing pays out or resets the window) lands the accumulator
        // just under the uint192 ceiling with a lossless cast
        uint256 elapsedOne = 6_277_101_735_386_680_763_835_789_423_207_666_416_101;
        vm.warp(block.timestamp + elapsedOne);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        assertEq(
            uint256(accountant.getState().twJTYieldShareAccruedWAD),
            6_277_101_735_386_680_763_835_789_423_207_666_416_101_000_000_000_000_000_000,
            "first window lands the accumulator just under the uint192 ceiling"
        );

        // The accrual clock is stored as a uint32, so at this timestamp it holds block.timestamp mod 2^32,
        // warp to storedClock + E1 (a forward warp here) so the next elapsed reads exactly E1 once more
        uint256 storedClock = accountant.getState().lastYieldShareAccrualTimestamp;
        vm.warp(storedClock + elapsedOne);
        // The second increment alone still fits uint192, but the running total 2 * (1e18 * E1) exceeds the
        // ceiling, so the checked += reverts: the sync bricks loudly instead of wrapping the accumulator to a
        // tiny value that would silently underpay the junior tranche's earned yield share
        vm.expectRevert(stdError.arithmeticError);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
    }

    /**
     * a single oversized increment does NOT revert: the explicit uint192() cast truncates before the checked add
     * The running-total add is checked, but each increment is cast to uint192 first, so one window with
     * 1e18 * elapsed >= 2^192 wraps modulo 2^192 and lands a dust accumulator instead of panicking — the junior
     * tranche's entire earned window silently collapses. The wrap, by hand:
     *   elapsed E = floor((2^192 - 1) / 1e18) + 1 = 6277101735386680763835789423207666416103
     *   raw increment = 1e18 * E = 6277101735386680763835789423207666416103000000000000000000
     *   2^192         =            6277101735386680763835789423207666416102355444464034512896
     *   raw mod 2^192 = 644555535965487104, worth ~0.64 seconds of accrual at a 100% yield share
     * Reachability needs one un-synced window of ~2e32 years, so this is a latent width hazard rather than a
     * live economic path, in asymmetry with the loud += overflow above
     */
    function test_AccrualIncrementCastWrapsModuloUint192_DoesNotRevert() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.maxJTYieldShareWAD = uint64(WAD);
        p.maxLTYieldShareWAD = 0;
        _deploy(false, p);
        _seedAndInitAccrual();
        jtYDM.setYieldShareReturn(WAD);

        // One second past the largest lossless window: the raw increment exceeds 2^192 by
        // 644555535965487104, which is exactly what the cast leaves behind
        uint256 elapsed = 6_277_101_735_386_680_763_835_789_423_207_666_416_103;
        vm.warp(block.timestamp + elapsed);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        assertEq(
            uint256(accountant.getState().twJTYieldShareAccruedWAD),
            644_555_535_965_487_104,
            "oversized increment wraps modulo 2^192 instead of reverting"
        );
    }

    /**
     * accrual-window contiguity over a fuzzed warp/sync/gain sequence, ghost-tracked
     * The accumulators reset iff premiums were paid, the premium timestamp updates iff they reset, and at all times
     * the accumulator equals cappedRate * (lastAccrualTimestamp - lastPremiumPaymentTimestamp)
     */
    function testFuzz_Accrual_windowContiguity(uint256 _rJT, uint256 _rLT, uint256 _seed) public {
        _rJT = bound(_rJT, 0, uint256(DEFAULT_MAX_JT_YIELD_SHARE_WAD) * 2);
        _rLT = bound(_rLT, 0, uint256(DEFAULT_MAX_LT_YIELD_SHARE_WAD) * 2);
        uint256 cappedJT = _rJT < DEFAULT_MAX_JT_YIELD_SHARE_WAD ? _rJT : DEFAULT_MAX_JT_YIELD_SHARE_WAD;
        uint256 cappedLT = _rLT < DEFAULT_MAX_LT_YIELD_SHARE_WAD ? _rLT : DEFAULT_MAX_LT_YIELD_SHARE_WAD;
        jtYDM.setRates(_rJT);
        ltYDM.setRates(_rLT);
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        uint256 stRawNAV = SEED_ST_RAW;

        // Ghost model of the accrual window
        uint256 ghostTwJT;
        uint256 ghostTwLT;
        uint256 ghostLastPay;
        uint256 ghostLastAccrual;
        for (uint256 i; i < 8; ++i) {
            uint256 roll = uint256(keccak256(abi.encode(_seed, i)));
            uint256 action = roll % 3;
            if (action == 0) {
                vm.warp(block.timestamp + ((roll >> 8) % 3 days) + 1);
            } else {
                uint256 nowTs = block.timestamp;
                if (ghostLastAccrual == 0) {
                    ghostLastAccrual = nowTs;
                    ghostLastPay = nowTs;
                } else {
                    ghostTwJT += cappedJT * (nowTs - ghostLastAccrual);
                    ghostTwLT += cappedLT * (nowTs - ghostLastAccrual);
                    ghostLastAccrual = nowTs;
                }
                bool gain = action == 2;
                if (gain) stRawNAV += 1e18;
                kernel.doPreOp(toNAVUnits(stRawNAV), toNAVUnits(SEED_JT_RAW));
                if (gain) {
                    // A senior gain above the zero dust tolerance pays premiums, resetting the window
                    ghostTwJT = 0;
                    ghostTwLT = 0;
                    ghostLastPay = nowTs;
                }
                IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
                assertEq(uint256(s.twJTYieldShareAccruedWAD), ghostTwJT, "jt accumulator vs ghost");
                assertEq(uint256(s.twLTYieldShareAccruedWAD), ghostTwLT, "lt accumulator vs ghost");
                assertEq(uint256(s.lastPremiumPaymentTimestamp), ghostLastPay, "premium timestamp vs ghost");
                assertEq(uint256(s.lastYieldShareAccrualTimestamp), ghostLastAccrual, "accrual timestamp vs ghost");
                assertEq(uint256(s.twJTYieldShareAccruedWAD), cappedJT * (ghostLastAccrual - ghostLastPay), "jt window contiguity");
                assertEq(uint256(s.twLTYieldShareAccruedWAD), cappedLT * (ghostLastAccrual - ghostLastPay), "lt window contiguity");
            }
        }
    }

    /**
     * Adversarial replay: after a premium-paying time-weighted sync, an attacker submits a second gain sync in
     * the SAME block hoping the accrued window prices the second premium again. The payment zeroes the window,
     * so the second sync takes the instantaneous branch: it re-queries the preview rates fresh over a forced 1s
     * and prices them on its own attributed gain only — the consumed window can never pay twice
     * Derivation: rates 0.1e18 / 0.05e18 over 1000s give tw = (100e18, 50e18), the first 100e18 gain pays
     *   jtPrem1 = floor(100e18 * 100e18 / (1000 * 1e18)) = 10e18 and ltPrem1 = 5e18, zeroing the window
     * The checkpoints are now stRaw 1100e18, jtRaw 200e18, stEff 1090e18, jtEff 210e18: the 10e18 jt premium is
     * a jt claim on st's raw pool, so the second 100e18 raw gain attributes pro-rata across those claims:
     *   stGain2 = floor(100e18 * 1090e18 / 1100e18) = 99090909090909090909, jtBase2 = the 909090909090909091 residual
     * With fresh preview rates 0.04e18 / 0.02e18 armed before the second sync (distinct from the consumed window's
     * 0.1e18 / 0.05e18 averages, so a replay is numerically distinguishable), the instantaneous branch pays
     *   jtPrem2 = floor(stGain2 * 0.04e18 / 1e18) = 3963636363636363636
     *   ltPrem2 = floor(stGain2 * 0.02e18 / 1e18) = 1981818181818181818
     *   (a window replay would have paid jtPrem2 = floor(stGain2 * 100e18 / (1000 * 1e18)) = 9909090909090909090)
     *   jtEff2 = 210e18 + jtBase2 + jtPrem2 = 214872727272727272727
     *   stEff2 = 1090e18 + stGain2 - jtPrem2 = 1185127272727272727273 (the lt premium stays a senior claim)
     */
    function test_Accrual_sameBlockSecondGainSyncCannotReplayPremiumWindow() public {
        _seedAndInitAccrual();
        jtYDM.setRates(0.1e18);
        ltYDM.setRates(0.05e18);
        vm.warp(block.timestamp + 1000);

        // First gain sync accrues and pays the time-weighted premium, consuming the window
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheYieldShareAccrued(0.1e18, 100e18);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.LiquidityTrancheYieldShareAccrued(0.05e18, 50e18);
        SyncedAccountingState memory first = kernel.doPreOp(toNAVUnits(SEED_ST_RAW + 100e18), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(first.jtEffectiveNAV), SEED_JT_RAW + 10e18, "first sync pays the time-weighted jt premium");
        assertEq(toUint256(first.ltLiquidityPremium), 5e18, "first sync pays the time-weighted lt premium");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(uint256(s.twJTYieldShareAccruedWAD), 0, "jt window consumed by the payment");
        assertEq(uint256(s.twLTYieldShareAccruedWAD), 0, "lt window consumed by the payment");
        assertEq(uint256(s.lastPremiumPaymentTimestamp), block.timestamp, "payment stamped this block");

        // Same-block replay attempt: fresh preview rates prove the second premium prices instantaneously on the
        // second sync's own attributed gain, never on the consumed window's 0.1e18 / 0.05e18 averages
        jtYDM.setPreviewYieldShareReturn(0.04e18);
        ltYDM.setPreviewYieldShareReturn(0.02e18);
        SyncedAccountingState memory second = kernel.doPreOp(toNAVUnits(SEED_ST_RAW + 200e18), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(second.jtEffectiveNAV), 214_872_727_272_727_272_727, "second premium priced instantaneously on gain2 alone");
        assertEq(toUint256(second.ltLiquidityPremium), 1_981_818_181_818_181_818, "second lt premium priced instantaneously on gain2 alone");
        assertEq(toUint256(second.stEffectiveNAV), 1_185_127_272_727_272_727_273, "st retains its attributed gain net of the jt premium");
        s = accountant.getState();
        assertEq(uint256(s.twJTYieldShareAccruedWAD), 0, "jt window still empty, nothing replayed");
        assertEq(uint256(s.twLTYieldShareAccruedWAD), 0, "lt window still empty, nothing replayed");
        assertEq(uint256(s.lastPremiumPaymentTimestamp), block.timestamp, "payment stamp unchanged in the same block");
        // Conservation across both syncs
        assertEq(
            toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV), SEED_ST_RAW + 200e18 + SEED_JT_RAW, "conservation across the replay attempt"
        );
    }
}
