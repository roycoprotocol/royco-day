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
    uint256 internal constant SEED_COLLATERAL = SEED_ST_EFF + SEED_JT_EFF;

    function setUp() public {
        stranger = makeAddr("stranger");
        _deploy(_defaultParams());
    }

    /// the first-ever accrual initializes both timestamps, leaves the accumulators at zero, and never calls the YDMs
    function test_Accrual_firstSyncInitializesTimestampsWithoutYDMCalls() public {
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        jtYDM.setYieldShareReturn(0.15e18);
        lptYDM.setYieldShareReturn(0.05e18);
        vm.warp(block.timestamp + 123);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(s.lastYieldShareAccrualTimestamp, uint32(block.timestamp), "accrual timestamp initialized");
        assertEq(s.lastPremiumPaymentTimestamp, uint32(block.timestamp), "premium payment timestamp initialized");
        assertEq(s.twJTYieldShareAccruedWAD, 0, "jt accumulator untouched");
        assertEq(s.twLPTYieldShareAccruedWAD, 0, "lt accumulator untouched");
        assertEq(jtYDM.yieldShareCallCount(), 0, "jt ydm not consulted on first accrual");
        assertEq(lptYDM.yieldShareCallCount(), 0, "lt ydm not consulted on first accrual");
    }

    /**
     * Nuance pinned: NOTE: an earlier analysis claimed no premium can be paid on the first sync,
     * but the first accrual sets lastPremiumPaymentTimestamp to now, so a gain in that same first sync takes the
     * instantaneous branch (elapsed forced to 1s) and pays premiums from the preview rates
     *
     * Derivation with collateral gain 100e18, jt preview 0.1e18 (below the 0.2e18 cap), lt preview 0.05e18 (below the 0.1e18 cap):
     *   deltaST = floor(100e18 * 1000e18 / 1200e18) = 83_333_333_333_333_333_333, JT residual 16_666_666_666_666_666_667
     *   jtRiskPremium      = floor(deltaST * 0.1e18 / (1 * 1e18)) = 8_333_333_333_333_333_333
     *   lptLiquidityPremium = floor(deltaST * 0.05e18 / (1 * 1e18)) = 4_166_666_666_666_666_666
     *   jtEffectiveNAV = 200e18 + 16_666_666_666_666_666_667 + 8_333_333_333_333_333_333 = 225e18 exact
     *   stEffectiveNAV = 1000e18 + (deltaST - jtPrem - lptPrem) + lptPrem = 1075e18 exact
     */
    function test_Accrual_firstSyncGainPaysInstantaneousPremium() public {
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        jtYDM.setPreviewYieldShareReturn(0.1e18);
        lptYDM.setPreviewYieldShareReturn(0.05e18);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 100e18));
        assertEq(toUint256(state.jtEffectiveNAV), 225e18, "jt residual plus premium paid via instantaneous branch");
        assertEq(toUint256(state.lptLiquidityPremium), 4_166_666_666_666_666_666, "lt premium paid via instantaneous branch");
        assertEq(toUint256(state.stEffectiveNAV), 1075e18, "st retains residual plus lt premium value retained senior");
    }

    /// a same-block re-accrual is a no-op: the YDMs are not called and the accumulators and timestamp are unchanged
    function test_Accrual_sameBlockReaccrualIsNoop() public {
        _seedAndInitAccrual();
        jtYDM.setYieldShareReturn(0.15e18);
        lptYDM.setYieldShareReturn(0.05e18);
        vm.warp(block.timestamp + 1000);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        uint256 jtCalls = jtYDM.yieldShareCallCount();
        uint256 lptCalls = lptYDM.yieldShareCallCount();
        IRoycoDayAccountant.RoycoDayAccountantState memory before = accountant.getState();
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        IRoycoDayAccountant.RoycoDayAccountantState memory afterState = accountant.getState();
        assertEq(jtYDM.yieldShareCallCount(), jtCalls, "jt ydm not re-consulted in the same block");
        assertEq(lptYDM.yieldShareCallCount(), lptCalls, "lt ydm not re-consulted in the same block");
        assertEq(afterState.twJTYieldShareAccruedWAD, before.twJTYieldShareAccruedWAD, "jt accumulator unchanged");
        assertEq(afterState.twLPTYieldShareAccruedWAD, before.twLPTYieldShareAccruedWAD, "lt accumulator unchanged");
        assertEq(afterState.lastYieldShareAccrualTimestamp, before.lastYieldShareAccrualTimestamp, "accrual timestamp unchanged");
    }

    /**
     * the accrual adds min(yieldShare, max) * elapsed to each accumulator
     * Derivation: jt rate 0.15e18 < max 0.2e18 so raw, lt rate 0.5e18 > max 0.1e18 so capped
     *   twJT = 0.15e18 * 3600 = 540e18, twLPT = 0.1e18 * 3600 = 360e18
     */
    function test_Accrual_accruesTimeWeightedSharesWithCapBothSides() public {
        _seedAndInitAccrual();
        jtYDM.setYieldShareReturn(0.15e18);
        lptYDM.setYieldShareReturn(0.5e18);
        vm.warp(block.timestamp + 3600);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(s.twJTYieldShareAccruedWAD, uint128(0.15e18 * 3600), "jt accrues its raw sub-cap rate");
        assertEq(s.twLPTYieldShareAccruedWAD, uint128(0.1e18 * 3600), "lt rate capped at maxLPTYieldShareWAD");
        assertEq(s.lastYieldShareAccrualTimestamp, uint32(block.timestamp), "accrual timestamp advanced");
    }

    /// accumulators compound across windows when no premium is paid in between
    function test_Accrual_accumulatesAcrossWindowsWithoutPremiumPayment() public {
        _seedAndInitAccrual();
        jtYDM.setYieldShareReturn(0.15e18);
        lptYDM.setYieldShareReturn(0.05e18);
        vm.warp(block.timestamp + 3600);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        jtYDM.setYieldShareReturn(0.02e18);
        lptYDM.setYieldShareReturn(0.01e18);
        vm.warp(block.timestamp + 100);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        // twJT = 0.15e18 * 3600 + 0.02e18 * 100, twLPT = 0.05e18 * 3600 + 0.01e18 * 100
        assertEq(s.twJTYieldShareAccruedWAD, uint128(0.15e18 * 3600 + 0.02e18 * 100), "jt accumulator compounds");
        assertEq(s.twLPTYieldShareAccruedWAD, uint128(0.05e18 * 3600 + 0.01e18 * 100), "lt accumulator compounds");
    }

    /// the YDMs are consulted with the last market state and utilizations computed from the last-committed checkpoints
    function test_Accrual_ydmCalledWithLastCheckpointArgs() public {
        _seedAndInitAccrual();
        vm.warp(block.timestamp + 60);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        assertEq(uint8(jtYDM.lastYieldShareMarketState()), uint8(MarketState.PERPETUAL), "jt ydm sees the last market state");
        assertEq(jtYDM.lastYieldShareUtilizationWAD(), SEED_COVERAGE_UTILIZATION_WAD, "jt ydm sees the checkpoint coverage utilization");
        assertEq(uint8(lptYDM.lastYieldShareMarketState()), uint8(MarketState.PERPETUAL), "lt ydm sees the last market state");
        assertEq(lptYDM.lastYieldShareUtilizationWAD(), SEED_LIQUIDITY_UTILIZATION_WAD, "lt ydm sees the checkpoint liquidity utilization");
    }

    /**
     * in a FIXED_TERM market the accrual passes FIXED_TERM and the committed-checkpoint utilizations
     * Seed: the large-IL checkpoint (collateral 1200e18, stEff 1000e18, jtEff 200e18, il 100e18)
     * Derivation: coverageUtilization = ceil(1200e18 * 0.1e18 / 200e18) = 0.6e18,
     * liquidityUtilization = ceil(1000e18 * 0.05e18 / 100e18) = 0.5e18
     */
    function test_Accrual_ydmSeesFixedTermStateAndCheckpointUtilizations() public {
        _seedState(1000e18, 200e18, 100e18, SEED_LPT_RAW, MarketState.FIXED_TERM);
        vm.warp(block.timestamp + 3600);
        kernel.doPreOp(toNAVUnits(uint256(1200e18)));
        assertEq(uint8(jtYDM.lastYieldShareMarketState()), uint8(MarketState.FIXED_TERM), "jt ydm sees FIXED_TERM");
        assertEq(jtYDM.lastYieldShareUtilizationWAD(), 0.6e18, "coverage utilization from the committed checkpoint");
        assertEq(lptYDM.lastYieldShareUtilizationWAD(), 0.5e18, "liquidity utilization from checkpoints");
    }

    /// the accrual emits the tranche yield-share event with the capped shares and the new accumulators
    function test_Accrual_emitsYieldShareAccruedEvents() public {
        _seedAndInitAccrual();
        jtYDM.setYieldShareReturn(0.9e18);
        lptYDM.setYieldShareReturn(0.04e18);
        vm.warp(block.timestamp + 500);
        // jt capped: min(0.9e18, 0.2e18) = 0.2e18, lt raw: 0.04e18 below the 0.1e18 cap
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.YieldSharesAccrued(0.2e18, 0.2e18 * 500, 0.04e18, 0.04e18 * 500);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
    }

    /// the mutating accrual calls yieldShare while the preview twin calls previewYieldShare and writes nothing
    function test_Accrual_mutatingCallsYieldShareAndPreviewIsPure() public {
        _seedAndInitAccrual();
        jtYDM.setRates(0.05e18);
        lptYDM.setRates(0.03e18);
        vm.warp(block.timestamp + 250);
        bytes32 preHash = _stateHash();
        vm.expectCall(address(jtYDM), abi.encodeCall(IYDM.previewYieldShare, (MarketState.PERPETUAL, SEED_COVERAGE_UTILIZATION_WAD)));
        vm.expectCall(address(lptYDM), abi.encodeCall(IYDM.previewYieldShare, (MarketState.PERPETUAL, SEED_LIQUIDITY_UTILIZATION_WAD)));
        accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_COLLATERAL));
        assertEq(_stateHash(), preHash, "preview must not mutate storage");
        assertEq(jtYDM.yieldShareCallCount(), 0, "preview must not call the mutating yieldShare");
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        assertEq(jtYDM.yieldShareCallCount(), 1, "mutating accrual calls yieldShare on the jt ydm");
        assertEq(lptYDM.yieldShareCallCount(), 1, "mutating accrual calls yieldShare on the lt ydm");
    }

    /**
     * preview twin with lastUpdate == 0 returns (0, 0) accumulators so a previewed gain pays no premium
     * Derivation with collateral gain 40e18: elapsed since the zero premium timestamp is nonzero so the
     * instantaneous branch is skipped, tw accumulators are (0, 0), both premiums floor to 0.
     *   deltaST = floor(40e18 * 1000e18 / 1200e18) = 33_333_333_333_333_333_333, JT residual 6_666_666_666_666_666_667
     *   jtFee = floor(6_666_666_666_666_666_667 * 0.1e18 / 1e18) = 666_666_666_666_666_666 (residual above zero dust)
     *   stProtocolFee = floor(33_333_333_333_333_333_333 * 0.1e18 / 1e18) = 3_333_333_333_333_333_333
     */
    function test_Accrual_previewBeforeFirstAccrualPaysNoPremium() public {
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        jtYDM.setRates(0.2e18);
        lptYDM.setRates(0.1e18);
        vm.warp(block.timestamp + 100);
        SyncedAccountingState memory state = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_COLLATERAL + 40e18));
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF + 6_666_666_666_666_666_667, "jt books only its residual, no premium from a zeroed accrual clock");
        assertEq(toUint256(state.lptLiquidityPremium), 0, "no lt premium from a zeroed accrual clock");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF + 33_333_333_333_333_333_333, "st retains its full attributed gain");
        assertEq(toUint256(state.stProtocolFee), 3_333_333_333_333_333_333, "st fee on the retained gain");
        assertEq(toUint256(state.jtProtocolFee), 666_666_666_666_666_666, "jt fee on the residual gain");
    }

    /**
     * preview twin with elapsed == 0 returns the stored accumulators, ignoring the live preview rates
     * Derivation: window of 1000s at jt rate 0.05e18 and lt rate 0.03e18 accrues tw = (50e18, 30e18), elapsed since
     * the premium clock is 1000s, so a previewed collateral gain of 100e18 attributes deltaST 83_333_333_333_333_333_333
     * (JT residual 16_666_666_666_666_666_667) and pays
     *   jtPrem = floor(deltaST * 50e18 / (1000 * 1e18)) = 4_166_666_666_666_666_666
     *   lptPrem = floor(deltaST * 30e18 / (1000 * 1e18)) = 2_499_999_999_999_999_999
     *   jtEffectiveNAV = 200e18 + 16_666_666_666_666_666_667 + 4_166_666_666_666_666_666 = 220_833_333_333_333_333_333
     */
    function test_Accrual_previewSameBlockUsesStoredAccumulators() public {
        _seedAndInitAccrual();
        jtYDM.setRates(0.05e18);
        lptYDM.setRates(0.03e18);
        vm.warp(block.timestamp + 1000);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        // Hostile preview rates prove the elapsed == 0 arm ignores them in favor of the accumulators
        jtYDM.setPreviewYieldShareReturn(WAD);
        lptYDM.setPreviewYieldShareReturn(WAD);
        SyncedAccountingState memory state = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_COLLATERAL + 100e18));
        assertEq(toUint256(state.jtEffectiveNAV), 220_833_333_333_333_333_333, "jt residual plus premium from stored accumulators only");
        assertEq(toUint256(state.lptLiquidityPremium), 2_499_999_999_999_999_999, "lt premium from stored accumulators only");
    }

    /**
     * preview twin with elapsed > 0 returns accumulators plus capped share times elapsed
     * Derivation: window one accrues at (0.05e18, 0.03e18) for 1000s giving (5e19, 3e19), then preview rates change
     * to jt 0.08e18 and lt 0.2e18 (capped to 0.1e18) for a 500s un-accrued tail, so the preview accrual is
     *   twJT = 5e19 + 0.08e18 * 500 = 9e19 and twLPT = 3e19 + 0.1e18 * 500 = 8e19
     * with elapsed since the premium clock 1500s, a previewed collateral gain of 100e18 (deltaST
     * 83_333_333_333_333_333_333, JT residual 16_666_666_666_666_666_667) pays
     *   jtPrem = floor(deltaST * 9e19 / (1500 * 1e18)) = 4_999_999_999_999_999_999
     *   lptPrem = floor(deltaST * 8e19 / (1500 * 1e18)) = 4_444_444_444_444_444_444
     *   jtEffectiveNAV = 200e18 + 16_666_666_666_666_666_667 + 4_999_999_999_999_999_999 = 221_666_666_666_666_666_666
     */
    function test_Accrual_previewElapsedAddsCappedShareTimesElapsed() public {
        _seedAndInitAccrual();
        jtYDM.setRates(0.05e18);
        lptYDM.setRates(0.03e18);
        vm.warp(block.timestamp + 1000);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        jtYDM.setPreviewYieldShareReturn(0.08e18);
        lptYDM.setPreviewYieldShareReturn(0.2e18);
        vm.warp(block.timestamp + 500);
        bytes32 preHash = _stateHash();
        SyncedAccountingState memory state = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_COLLATERAL + 100e18));
        assertEq(toUint256(state.jtEffectiveNAV), 221_666_666_666_666_666_666, "jt residual plus premium from accumulator plus tail");
        assertEq(toUint256(state.lptLiquidityPremium), 4_444_444_444_444_444_444, "lt premium from capped tail rate");
        assertEq(_stateHash(), preHash, "preview must not mutate storage");
    }

    /// same-block preview and pre-op sync agree field-by-field on identical inputs
    function test_Accrual_previewParityWithPreOpSameBlock() public {
        _seedAndInitAccrual();
        jtYDM.setRates(0.05e18);
        lptYDM.setRates(0.03e18);
        vm.warp(block.timestamp + 1000);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        SyncedAccountingState memory previewed = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_COLLATERAL + 100e18));
        SyncedAccountingState memory executed = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 100e18));
        assertEq(keccak256(abi.encode(previewed)), keccak256(abi.encode(executed)), "preview must match execution exactly");
    }

    /**
     * the uint128 accumulators survive a 100-year window at a 100% yield share
     * Derivation: 1e18 * (100 * 365 days) = 1e18 * 3153600000 = 3.1536e27, far below 2^192
     */
    function test_Accrual_accumulatorNoOverflowAt100Years() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.maxJTYieldShareWAD = uint64(WAD);
        p.maxLPTYieldShareWAD = 0;
        _deploy(p);
        _seedAndInitAccrual();
        jtYDM.setYieldShareReturn(WAD);
        vm.warp(block.timestamp + 100 * 365 days);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        assertEq(accountant.getState().twJTYieldShareAccruedWAD, uint128(uint256(1e18) * 3_153_600_000), "century-scale accumulator exact");
    }

    /**
     * the uint128 accumulator's checked += fails loud once the running total would exceed its width
     * A market whose accrual window is never consumed (no gain sync ever pays premiums, so the accumulator is
     * never reset) grows by rate * elapsed forever. When the running total would pass type(uint128).max the
     * checked += reverts with an arithmetic panic, bricking every subsequent sync: a loud failure, in contrast
     * to the silent single-increment wrap covered by test_AccrualIncrementCastWrapsModuloUint128_DoesNotRevert
     * Derivation, from the accumulator width alone:
     *   type(uint128).max = 2^128 - 1 = 340282366920938463463374607431768211455
     *   E1 = floor((2^128 - 1) / 1e18) = 340282366920938463463, over 1e13 years of the config-capped WAD-per-second accrual
     *   first increment = 1e18 * E1 = 340282366920938463463000000000000000000
     *     which sits 374607431768211455 under the max, so the uint128 cast is lossless and the += from zero fits
     *   a second window of E1 seconds doubles the total: 2 * (1e18 * E1) > 2^128 - 1, so the checked += panics
     */
    function test_RevertIf_AccrualAccumulatorOverflowsUint128() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.maxJTYieldShareWAD = uint64(WAD);
        p.maxLPTYieldShareWAD = 0;
        _deploy(p);
        _seedAndInitAccrual();
        jtYDM.setYieldShareReturn(WAD);

        // First window: a flat sync (no gain, so nothing pays out or resets the window) lands the accumulator
        // just under the uint128 ceiling with a lossless cast
        uint256 elapsedOne = 340_282_366_920_938_463_463;
        vm.warp(block.timestamp + elapsedOne);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        assertEq(
            uint256(accountant.getState().twJTYieldShareAccruedWAD),
            340_282_366_920_938_463_463_000_000_000_000_000_000,
            "first window lands the accumulator just under the uint128 ceiling"
        );

        // The accrual clock is stored as a uint32, so at this timestamp it holds block.timestamp mod 2^32,
        // warp to storedClock + E1 (a forward warp here) so the next elapsed reads exactly E1 once more
        uint256 storedClock = accountant.getState().lastYieldShareAccrualTimestamp;
        vm.warp(storedClock + elapsedOne);
        // The second increment alone still fits uint128, but the running total 2 * (1e18 * E1) exceeds the
        // ceiling, so the checked += reverts: the sync bricks loudly instead of wrapping the accumulator to a
        // tiny value that would silently underpay the junior tranche's earned yield share
        vm.expectRevert(stdError.arithmeticError);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
    }

    /**
     * a single oversized increment does NOT revert: the explicit uint128() cast truncates before the checked add
     * The running-total add is checked, but each increment is cast to uint128 first, so one window with
     * 1e18 * elapsed >= 2^128 wraps modulo 2^128 and lands a dust accumulator instead of panicking: the junior
     * tranche's entire earned window silently collapses. The wrap, by hand:
     *   elapsed E = floor((2^128 - 1) / 1e18) + 1 = 340282366920938463464
     *   raw increment = 1e18 * E = 340282366920938463464000000000000000000
     *   2^128         =           340282366920938463463374607431768211456
     *   raw mod 2^128 = 625392568231788544, worth ~0.63 seconds of accrual at a 100% yield share
     * Reachability needs one un-synced window of over 1e13 years at the config-capped WAD-per-second rate, so
     * this is a latent width hazard rather than a live economic path, in asymmetry with the loud += overflow above
     */
    function test_AccrualIncrementCastWrapsModuloUint128_DoesNotRevert() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.maxJTYieldShareWAD = uint64(WAD);
        p.maxLPTYieldShareWAD = 0;
        _deploy(p);
        _seedAndInitAccrual();
        jtYDM.setYieldShareReturn(WAD);

        // One second past the largest lossless window: the raw increment exceeds 2^128 by
        // 625392568231788544, which is exactly what the cast leaves behind
        uint256 elapsed = 340_282_366_920_938_463_464;
        vm.warp(block.timestamp + elapsed);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        assertEq(
            uint256(accountant.getState().twJTYieldShareAccruedWAD), 625_392_568_231_788_544, "oversized increment wraps modulo 2^128 instead of reverting"
        );
    }

    /**
     * accrual-window contiguity over a fuzzed warp/sync/gain sequence, ghost-tracked
     * The accumulators reset iff premiums were paid, the premium timestamp updates iff they reset, and at all times
     * the accumulator equals cappedRate * (lastAccrualTimestamp - lastPremiumPaymentTimestamp)
     */
    function testFuzz_Accrual_windowContiguity(uint256 _rJT, uint256 _rLPT, uint256 _seed) public {
        _rJT = bound(_rJT, 0, uint256(DEFAULT_MAX_JT_YIELD_SHARE_WAD) * 2);
        _rLPT = bound(_rLPT, 0, uint256(DEFAULT_MAX_LPT_YIELD_SHARE_WAD) * 2);
        uint256 cappedJT = _rJT < DEFAULT_MAX_JT_YIELD_SHARE_WAD ? _rJT : DEFAULT_MAX_JT_YIELD_SHARE_WAD;
        uint256 cappedLPT = _rLPT < DEFAULT_MAX_LPT_YIELD_SHARE_WAD ? _rLPT : DEFAULT_MAX_LPT_YIELD_SHARE_WAD;
        jtYDM.setRates(_rJT);
        lptYDM.setRates(_rLPT);
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        uint256 collateralNAV = SEED_COLLATERAL;

        // Ghost model of the accrual window
        uint256 ghostTwJT;
        uint256 ghostTwLPT;
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
                    ghostTwLPT += cappedLPT * (nowTs - ghostLastAccrual);
                    ghostLastAccrual = nowTs;
                }
                bool gain = action == 2;
                if (gain) collateralNAV += 1e18;
                kernel.doPreOp(toNAVUnits(collateralNAV));
                if (gain) {
                    // A collateral gain always attributes a positive senior gain above the zero dust
                    // tolerance, so premiums pay and the window resets
                    ghostTwJT = 0;
                    ghostTwLPT = 0;
                    ghostLastPay = nowTs;
                }
                IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
                assertEq(uint256(s.twJTYieldShareAccruedWAD), ghostTwJT, "jt accumulator vs ghost");
                assertEq(uint256(s.twLPTYieldShareAccruedWAD), ghostTwLPT, "lt accumulator vs ghost");
                assertEq(uint256(s.lastPremiumPaymentTimestamp), ghostLastPay, "premium timestamp vs ghost");
                assertEq(uint256(s.lastYieldShareAccrualTimestamp), ghostLastAccrual, "accrual timestamp vs ghost");
                assertEq(uint256(s.twJTYieldShareAccruedWAD), cappedJT * (ghostLastAccrual - ghostLastPay), "jt window contiguity");
                assertEq(uint256(s.twLPTYieldShareAccruedWAD), cappedLPT * (ghostLastAccrual - ghostLastPay), "lt window contiguity");
            }
        }
    }

    /**
     * Adversarial replay: after a premium-paying time-weighted sync, an attacker submits a second gain sync in
     * the SAME block hoping the accrued window prices the second premium again. The payment zeroes the window,
     * so the second sync takes the instantaneous branch: it re-queries the preview rates fresh over a forced 1s
     * and prices them on its own attributed gain only: the consumed window can never pay twice
     * Derivation: rates 0.1e18 / 0.05e18 over 1000s give tw = (100e18, 50e18). The first +100e18 collateral gain
     * attributes deltaST = floor(100e18 * 1000e18 / 1200e18) = 83_333_333_333_333_333_333 (JT residual
     * 16_666_666_666_666_666_667) and pays jtPrem1 = floor(deltaST * 100e18 / (1000 * 1e18)) = 8_333_333_333_333_333_333
     * and lptPrem1 = 4_166_666_666_666_666_666, zeroing the window: jtEff 225e18 exact, stEff 1075e18 exact.
     * The second +100e18 gain attributes against the fresh (1300e18, stEff 1075e18) checkpoint:
     *   deltaST2 = floor(100e18 * 1075e18 / 1300e18) = 82_692_307_692_307_692_307, JT residual 17_307_692_307_692_307_693
     * With fresh preview rates 0.04e18 / 0.02e18 armed before the second sync (distinct from the consumed window's
     * 0.1e18 / 0.05e18 averages, so a replay is numerically distinguishable), the instantaneous branch pays
     *   jtPrem2 = floor(deltaST2 * 0.04e18 / 1e18) = 3_307_692_307_692_307_692
     *   lptPrem2 = floor(deltaST2 * 0.02e18 / 1e18) = 1_653_846_153_846_153_846
     *   (a window replay would have paid jtPrem2 = floor(deltaST2 * 100e18 / (1000 * 1e18)) = 8_269_230_769_230_769_230)
     *   jtEff2 = 225e18 + 17_307_692_307_692_307_693 + jtPrem2 = 245_615_384_615_384_615_385
     *   stEff2 = 1075e18 + deltaST2 - jtPrem2 = 1_154_384_615_384_615_384_615 (the lt premium stays a senior claim)
     */
    function test_Accrual_sameBlockSecondGainSyncCannotReplayPremiumWindow() public {
        _seedAndInitAccrual();
        jtYDM.setRates(0.1e18);
        lptYDM.setRates(0.05e18);
        vm.warp(block.timestamp + 1000);

        // First gain sync accrues and pays the time-weighted premium, consuming the window
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.YieldSharesAccrued(0.1e18, 100e18, 0.05e18, 50e18);
        SyncedAccountingState memory first = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 100e18));
        assertEq(toUint256(first.jtEffectiveNAV), 225e18, "first sync books the jt residual plus the time-weighted premium");
        assertEq(toUint256(first.lptLiquidityPremium), 4_166_666_666_666_666_666, "first sync pays the time-weighted lt premium");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(uint256(s.twJTYieldShareAccruedWAD), 0, "jt window consumed by the payment");
        assertEq(uint256(s.twLPTYieldShareAccruedWAD), 0, "lt window consumed by the payment");
        assertEq(uint256(s.lastPremiumPaymentTimestamp), block.timestamp, "payment stamped this block");

        // Same-block replay attempt: fresh preview rates prove the second premium prices instantaneously on the
        // second sync's own attributed gain, never on the consumed window's 0.1e18 / 0.05e18 averages
        jtYDM.setPreviewYieldShareReturn(0.04e18);
        lptYDM.setPreviewYieldShareReturn(0.02e18);
        SyncedAccountingState memory second = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 200e18));
        assertEq(toUint256(second.jtEffectiveNAV), 245_615_384_615_384_615_385, "second premium priced instantaneously on gain2 alone");
        assertEq(toUint256(second.lptLiquidityPremium), 1_653_846_153_846_153_846, "second lt premium priced instantaneously on gain2 alone");
        assertEq(toUint256(second.stEffectiveNAV), 1_154_384_615_384_615_384_615, "st retains its attributed gain net of the jt premium");
        s = accountant.getState();
        assertEq(uint256(s.twJTYieldShareAccruedWAD), 0, "jt window still empty, nothing replayed");
        assertEq(uint256(s.twLPTYieldShareAccruedWAD), 0, "lt window still empty, nothing replayed");
        assertEq(uint256(s.lastPremiumPaymentTimestamp), block.timestamp, "payment stamp unchanged in the same block");
        // Conservation across both syncs
        assertEq(toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV), SEED_COLLATERAL + 200e18, "conservation across the replay attempt");
    }
}
