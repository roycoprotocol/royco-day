// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/accountant/IRoycoDayAccountant.sol";
import { IRoycoDayFixedRateAccountant } from "../../../src/interfaces/accountant/IRoycoDayFixedRateAccountant.sol";
import { MAX_PROTOCOL_FEE_WAD, WAD, ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { MockFixedRateAccountantKernel } from "../../mocks/MockFixedRateAccountantKernel.sol";
import { MockRecordingYDM } from "../../mocks/MockRecordingYDM.sol";
import { FixedRateAccountantTestBase } from "../../utils/FixedRateAccountantTestBase.sol";

/**
 * @title Test_Setters_FixedRateAccountant
 * @notice Every fixed rate setter's validation boundary, event, and state write: the unbounded senior fixed rate
 *         with its old-rate settlement of pending movements and its whole-window retroactivity, the max LPT
 *         yield share cap and its non-retroactive lowering, the best-effort-synced LPT YDM setter, the
 *         unconditionally rejected junior tranche protocol fee, and the inherited shared setters
 */
contract Test_Setters_FixedRateAccountant is FixedRateAccountantTestBase {
    function setUp() public {
        stranger = makeAddr("stranger");
        _deploy(_defaultParams());
    }

    /// the senior fixed rate is validation-free: the full uint64 range writes with the event, zero included
    function test_SetSeniorTrancheFixedRate_eventWriteAndUnboundedRate() public {
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayFixedRateAccountant.SeniorTrancheFixedRateUpdated(type(uint64).max);
        accountant.setSeniorTrancheFixedRate(type(uint64).max);
        assertEq(accountant.getRoycoDayFixedRateAccountantState().stFixedRatePerSecondWAD, type(uint64).max, "rate written at the uint64 maximum");
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayFixedRateAccountant.SeniorTrancheFixedRateUpdated(0);
        accountant.setSeniorTrancheFixedRate(0);
        assertEq(accountant.getRoycoDayFixedRateAccountantState().stFixedRatePerSecondWAD, 0, "rate shrinks back to zero");
    }

    /**
     * a rate change with a pending NAV movement settles the old window at the OLD rate before the new rate lands
     * Derivation: flat 1000e18/200e18 seed, 1000s window, sync NAV 1200e18 + 2e15. The setter's pre-call sync
     * observes the movement and settles couponDue = floor(1000e18 * 1e9 * 1000 / 1e18) = 1e15 at the outgoing
     * rate (the incoming 3e9 would owe 3e15). The 2e15 gain funds the coupon fully and JT keeps the 1e15 excess
     * (the premium clock lazy-initializes this block so the instantaneous branch prices the mock's zero LPT
     * share), so stEffectiveNAV = 1000e18 + 1e15 and jtEffectiveNAV = 200e18 + 1e15, and the settlement restamps
     * the coupon window before the new rate's first accrual second
     */
    function test_SetSeniorTrancheFixedRate_pendingMovementSettlesOldWindowAtOldRate() public {
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        vm.warp(vm.getBlockTimestamp() + 1000);
        kernel.setSyncMode(MockFixedRateAccountantKernel.SyncMode.SYNC);
        kernel.setSyncNAV(toNAVUnits(SEED_COLLATERAL + 2e15));

        // Preview parity for the settling bracket sync: the preview prices the same old-rate coupon
        SyncedAccountingState memory preview = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_COLLATERAL + 2e15));
        assertEq(toUint256(preview.stEffectiveNAV), SEED_ST_EFF + 1e15, "preview prices the old-rate coupon");
        assertEq(toUint256(preview.jtEffectiveNAV), SEED_JT_EFF + 1e15, "preview books the excess to jt");

        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayFixedRateAccountant.SeniorTrancheFixedRateUpdated(uint64(3e9));
        accountant.setSeniorTrancheFixedRate(uint64(3e9));

        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTEffectiveNAV), SEED_ST_EFF + 1e15, "old window settled at the old rate");
        assertEq(toUint256(s.lastJTEffectiveNAV), SEED_JT_EFF + 1e15, "jt keeps the excess above the old-rate coupon");
        assertEq(toUint256(s.lastCollateralNAV), SEED_COLLATERAL + 2e15, "movement committed by the bracket sync");
        assertEq(toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV), SEED_COLLATERAL + 2e15, "conservation");
        assertEq(toUint256(s.lastJTImpermanentLoss), 0, "no il booked (biconditional with perpetual)");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.PERPETUAL), "market stays perpetual");
        assertEq(accountant.getRoycoDayFixedRateAccountantState().stFixedRatePerSecondWAD, 3e9, "new rate written after the settlement");
        assertEq(_couponWindowStart(), vm.getBlockTimestamp(), "settlement restamps the coupon window");
        assertEq(kernel.syncCallCount(), 2, "hard sync brackets ran on both sides");
    }

    /**
     * a mid-window rate change with no pending movement reprices the WHOLE in-flight window at the NEW rate
     * Derivation: the window opens at deployment. 1000s in, a flat bracket sync (sync NAV = the committed
     * 1200e18) settles nothing and does not restamp, then the body writes the 2e9 rate. 500s later a +4e15 gain
     * settles couponDue = floor(1000e18 * 2e9 * 1500 / 1e18) = 3e15 across the full 1500s window, not the
     * per-segment 1e12 * 1000 + 2e12 * 500 = 2e15 split, pinning the documented retroactivity. The gain funds
     * the coupon and JT keeps the 1e15 remainder (the accrued LPT share is zero so no liquidity premium), with
     * stProtocolFee = floor(3e15 * 0.1e18 / 1e18) = 3e14 and jtProtocolFee = floor(1e15 * 0.1e18 / 1e18) = 1e14
     */
    function test_SetSeniorTrancheFixedRate_midWindowChangeRepricesWholeWindowAtNewRate() public {
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        uint256 windowStart = _couponWindowStart();
        vm.warp(vm.getBlockTimestamp() + 1000);
        kernel.setSyncMode(MockFixedRateAccountantKernel.SyncMode.SYNC);
        kernel.setSyncNAV(toNAVUnits(SEED_COLLATERAL));
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayFixedRateAccountant.SeniorTrancheFixedRateUpdated(uint64(2e9));
        accountant.setSeniorTrancheFixedRate(uint64(2e9));
        assertEq(_couponWindowStart(), windowStart, "flat bracket sync leaves the window running");

        vm.warp(vm.getBlockTimestamp() + 500);
        SyncedAccountingState memory preview = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_COLLATERAL + 4e15));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 4e15));
        assertEq(keccak256(abi.encode(preview)), keccak256(abi.encode(state)), "preview == execute");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF + 3e15, "whole window coupon priced at the new rate");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF + 1e15, "jt keeps the excess above the repriced coupon");
        assertEq(toUint256(state.stProtocolFee), 3e14, "st fee on the repriced coupon");
        assertEq(toUint256(state.jtProtocolFee), 1e14, "jt fee on the retained excess");
        assertEq(toUint256(state.stEffectiveNAV) + toUint256(state.jtEffectiveNAV), SEED_COLLATERAL + 4e15, "conservation");
        assertEq(toUint256(state.jtImpermanentLoss), 0, "no il on a funded coupon (biconditional with perpetual)");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "market stays perpetual");

        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTEffectiveNAV), SEED_ST_EFF + 3e15, "st checkpoint committed");
        assertEq(toUint256(s.lastJTEffectiveNAV), SEED_JT_EFF + 1e15, "jt checkpoint committed");
        assertEq(_couponWindowStart(), vm.getBlockTimestamp(), "settlement restamps the coupon window");
    }

    /// setMaxLPTYieldShare reverts above WAD and passes at exactly WAD with event and write
    function test_SetMaxLPTYieldShare_boundaryEventWrite() public {
        vm.expectRevert(IRoycoDayFixedRateAccountant.INVALID_MAX_YIELD_SHARE_CONFIG.selector);
        accountant.setMaxLPTYieldShare(uint64(WAD + 1));
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayFixedRateAccountant.MaxLPTYieldShareUpdated(uint64(WAD));
        accountant.setMaxLPTYieldShare(uint64(WAD));
        assertEq(accountant.getRoycoDayFixedRateAccountantState().maxLPTYieldShareWAD, uint64(WAD), "max lpt yield share written at the WAD boundary");
    }

    /**
     * Adversarial cap grief: an operator lowers the max LPT yield share to zero AFTER a high-rate window has
     * accrued, hoping (or fearing) the already-earned window reprices to nothing. The setter's own pre-body
     * sync accrues the window at the OLD cap, and the payment branch prices from the stored accumulator without
     * re-capping, so the earned premium survives the cap change and caps are never retroactive
     * Derivation: hostile rate 0.5e18 capped at accrual to 0.1e18 over 1000s gives tw = 100e18. The post-setter
     * +100e18 gain first settles the coupon floor(1000e18 * 1e9 * 1000 / 1e18) = 1e15 from the gain
     * (stProtocolFee = floor(1e15 * 0.1e18 / 1e18) = 1e14), leaving excess = 100e18 - 1e15 = 99999e15, then
     * lptLiquidityPremium = floor(99999e15 * 100e18 / (1000 * 1e18)) = 9999900000000000000 and JT keeps the
     * complement 99999e15 - 9999900000000000000 = 89999100000000000000:
     *   stEffectiveNAV = 1000e18 + 1e15 + 9999900000000000000 = 1010000900000000000000
     *   jtEffectiveNAV = 200e18 + 89999100000000000000 = 289999100000000000000 (conservation: 1300e18)
     *   lptFee = floor(9999900000000000000 * 0.1e18 / 1e18) = 999990000000000000
     *   jtFee = floor(89999100000000000000 * 0.1e18 / 1e18) = 8999910000000000000
     */
    function test_SetMaxLPTYieldShare_loweringCapDoesNotEraseAccruedWindow() public {
        _seedAndInitAccrual();
        lptYDM.setRates(0.5e18);
        vm.warp(vm.getBlockTimestamp() + 1000);

        // The hard-sync setter accrues the window at the old cap before its body lowers it to zero
        kernel.setSyncMode(MockFixedRateAccountantKernel.SyncMode.SYNC);
        kernel.setSyncNAV(toNAVUnits(SEED_COLLATERAL));
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayFixedRateAccountant.LPTYieldShareAccrued(0.1e18, 100e18);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayFixedRateAccountant.MaxLPTYieldShareUpdated(0);
        accountant.setMaxLPTYieldShare(0);
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantState memory sFixed = accountant.getRoycoDayFixedRateAccountantState();
        assertEq(uint256(sFixed.twLPTYieldShareAccruedWAD), 100e18, "window accrued at the old cap before the body");
        assertEq(sFixed.maxLPTYieldShareWAD, 0, "cap lowered to zero");

        // The same-block gain still pays the premium earned under the old cap
        SyncedAccountingState memory preview = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_COLLATERAL + 100e18));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 100e18));
        assertEq(keccak256(abi.encode(preview)), keccak256(abi.encode(state)), "preview == execute");
        assertEq(toUint256(state.stEffectiveNAV), 1_010_000_900_000_000_000_000, "st keeps the coupon plus the lt premium leg");
        assertEq(toUint256(state.jtEffectiveNAV), 289_999_100_000_000_000_000, "jt keeps the complement of the pre-change window premium");
        assertEq(toUint256(state.lptLiquidityPremium), 9_999_900_000_000_000_000, "lt premium priced from the pre-change window");
        assertEq(toUint256(state.stProtocolFee), 1e14, "st fee on the coupon");
        assertEq(toUint256(state.jtProtocolFee), 8_999_910_000_000_000_000, "jt fee on the retained complement");
        assertEq(toUint256(state.lptProtocolFee), 999_990_000_000_000_000, "lt fee on the earned premium");
        assertEq(toUint256(state.stEffectiveNAV) + toUint256(state.jtEffectiveNAV), SEED_COLLATERAL + 100e18, "conservation");
        assertEq(toUint256(state.jtImpermanentLoss), 0, "no il on a pure gain (biconditional with perpetual)");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "market stays perpetual");

        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        sFixed = accountant.getRoycoDayFixedRateAccountantState();
        assertEq(toUint256(s.lastSTEffectiveNAV), 1_010_000_900_000_000_000_000, "st checkpoint committed");
        assertEq(toUint256(s.lastJTEffectiveNAV), 289_999_100_000_000_000_000, "jt checkpoint committed");
        assertEq(uint256(sFixed.twLPTYieldShareAccruedWAD), 0, "window consumed by the payment");
        assertEq(sFixed.lastPremiumPaymentTimestamp, uint32(vm.getBlockTimestamp()), "premium clock restamped by the payment");
        assertEq(sFixed.lastCouponSettlementTimestamp, uint32(vm.getBlockTimestamp()), "settlement restamps the coupon window");
    }

    /// setLiquidityProviderTrancheYDM under a NONE-mode kernel: the best-effort sync reaches the kernel and the new YDM is re-initialized, written, and announced
    function test_SetLiquidityProviderTrancheYDM_bestEffortSyncEventWriteAndInit() public {
        MockRecordingYDM fresh = new MockRecordingYDM();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayFixedRateAccountant.LiquidityProviderTrancheYDMUpdated(address(fresh));
        accountant.setLiquidityProviderTrancheYDM(address(fresh), abi.encodeCall(MockRecordingYDM.initializeModel, (hex"abcd")));
        assertEq(accountant.getRoycoDayFixedRateAccountantState().lptYDM, address(fresh), "lt ydm written");
        assertEq(fresh.initializeCallCount(), 1, "new ydm re-initialized");
        assertEq(fresh.lastInitializePayload(), hex"abcd", "payload forwarded verbatim");
        assertEq(kernel.syncCallCount(), 1, "best-effort sync reached the kernel");
    }

    /// a sync-bricking kernel does not brick the YDM setter: the best-effort sync swallows the revert while a hard-sync setter stays bricked
    function test_SetLiquidityProviderTrancheYDM_toleratesRevertingKernelSync() public {
        kernel.setSyncMode(MockFixedRateAccountantKernel.SyncMode.REVERT);
        // Contrast: a hard-sync setter bubbles the kernel revert
        vm.expectRevert(MockFixedRateAccountantKernel.KERNEL_SYNC_REVERTED.selector);
        accountant.setMaxLPTYieldShare(uint64(0.2e18));

        MockRecordingYDM fresh = new MockRecordingYDM();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayFixedRateAccountant.LiquidityProviderTrancheYDMUpdated(address(fresh));
        accountant.setLiquidityProviderTrancheYDM(address(fresh), "");
        assertEq(accountant.getRoycoDayFixedRateAccountantState().lptYDM, address(fresh), "lt ydm written despite the reverting sync");
        assertEq(kernel.syncCallCount(), 0, "kernel sync reverted before counting");
    }

    /// setLiquidityProviderTrancheYDM initialization data paths (skipped when empty, forwarded verbatim, reverting payload bubbled)
    function test_SetLiquidityProviderTrancheYDM_initDataPaths() public {
        MockRecordingYDM silent = new MockRecordingYDM();
        accountant.setLiquidityProviderTrancheYDM(address(silent), "");
        assertEq(silent.initializeCallCount(), 0, "empty data makes no init call");

        MockRecordingYDM initialized = new MockRecordingYDM();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayFixedRateAccountant.LiquidityProviderTrancheYDMUpdated(address(initialized));
        accountant.setLiquidityProviderTrancheYDM(address(initialized), abi.encodeCall(MockRecordingYDM.initializeModel, (hex"beef")));
        assertEq(initialized.initializeCallCount(), 1, "non-empty data initializes");
        assertEq(initialized.lastInitializePayload(), hex"beef", "payload forwarded verbatim");
        assertEq(accountant.getRoycoDayFixedRateAccountantState().lptYDM, address(initialized), "lt ydm written");

        MockRecordingYDM reverting = new MockRecordingYDM();
        reverting.setRevertOnInitialize(true);
        vm.expectRevert(MockRecordingYDM.YDM_INIT_REVERTED.selector);
        accountant.setLiquidityProviderTrancheYDM(address(reverting), abi.encodeCall(MockRecordingYDM.initializeModel, (hex"")));
    }

    /// setLiquidityProviderTrancheYDM rejects the null address
    function test_RevertIf_SetLiquidityProviderTrancheYDMNull() public {
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        accountant.setLiquidityProviderTrancheYDM(address(0), "");
    }

    /// the junior tranche protocol fee knob is inert in this flavor: rejected unconditionally for admin and stranger alike
    function test_RevertIf_SetJuniorTrancheProtocolFeeUnconditionally() public {
        vm.expectRevert(IRoycoDayFixedRateAccountant.INVALID_PROTOCOL_FEE_CONFIG.selector);
        accountant.setJuniorTrancheProtocolFee(0);
        vm.expectRevert(IRoycoDayFixedRateAccountant.INVALID_PROTOCOL_FEE_CONFIG.selector);
        accountant.setJuniorTrancheProtocolFee(uint64(MAX_PROTOCOL_FEE_WAD));
        // The override drops the authorization gate entirely, so a stranger sees the same config rejection
        vm.prank(stranger);
        vm.expectRevert(IRoycoDayFixedRateAccountant.INVALID_PROTOCOL_FEE_CONFIG.selector);
        accountant.setJuniorTrancheProtocolFee(uint64(1));
        assertEq(accountant.getState().jtProtocolFeeWAD, 0, "jt fee stays pinned at zero");
    }

    /// ST protocol fee setter boundary, event, and write
    function test_SetSeniorTrancheProtocolFee_boundaryEventWrite() public {
        vm.expectRevert(IRoycoDayAccountant.MAX_PROTOCOL_FEE_EXCEEDED.selector);
        accountant.setSeniorTrancheProtocolFee(uint64(MAX_PROTOCOL_FEE_WAD + 1));
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.SeniorTrancheProtocolFeeUpdated(uint64(MAX_PROTOCOL_FEE_WAD));
        accountant.setSeniorTrancheProtocolFee(uint64(MAX_PROTOCOL_FEE_WAD));
        assertEq(accountant.getState().stProtocolFeeWAD, uint64(MAX_PROTOCOL_FEE_WAD), "st fee written at max boundary");
    }

    /// JT yield-share protocol fee setter boundary, event, and write
    function test_SetJTYieldShareProtocolFee_boundaryEventWrite() public {
        vm.expectRevert(IRoycoDayAccountant.MAX_PROTOCOL_FEE_EXCEEDED.selector);
        accountant.setJTYieldShareProtocolFee(uint64(MAX_PROTOCOL_FEE_WAD + 1));
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheYieldShareProtocolFeeUpdated(uint64(MAX_PROTOCOL_FEE_WAD));
        accountant.setJTYieldShareProtocolFee(uint64(MAX_PROTOCOL_FEE_WAD));
        assertEq(accountant.getState().jtYieldShareProtocolFeeWAD, uint64(MAX_PROTOCOL_FEE_WAD), "jt ys fee written at max boundary");
    }

    /// LPT yield-share protocol fee setter boundary, event, and write
    function test_SetLPTYieldShareProtocolFee_boundaryEventWrite() public {
        vm.expectRevert(IRoycoDayAccountant.MAX_PROTOCOL_FEE_EXCEEDED.selector);
        accountant.setLPTYieldShareProtocolFee(uint64(MAX_PROTOCOL_FEE_WAD + 1));
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.LiquidityProviderTrancheYieldShareProtocolFeeUpdated(uint64(MAX_PROTOCOL_FEE_WAD));
        accountant.setLPTYieldShareProtocolFee(uint64(MAX_PROTOCOL_FEE_WAD));
        assertEq(accountant.getState().lptYieldShareProtocolFeeWAD, uint64(MAX_PROTOCOL_FEE_WAD), "lt ys fee written at max boundary");
    }

    /// setMinCoverage reverts at exactly WAD and passes at WAD - 1 with event and write
    function test_SetMinCoverage_boundaryEventWrite() public {
        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        accountant.setMinCoverage(uint64(WAD));
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.MinCoverageUpdated(uint64(WAD - 1));
        accountant.setMinCoverage(uint64(WAD - 1));
        assertEq(accountant.getState().minCoverageWAD, uint64(WAD - 1), "minCoverage written at boundary");
    }

    /// setLiquidationCoverageUtilization reverts at exactly WAD and passes at WAD + 1 with event and write
    function test_SetLiquidationCoverageUtilization_boundaryEventWrite() public {
        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        accountant.setLiquidationCoverageUtilization(WAD);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.LiquidationCoverageUtilizationUpdated(WAD + 1);
        accountant.setLiquidationCoverageUtilization(WAD + 1);
        assertEq(accountant.getState().coverageLiquidationUtilizationWAD, WAD + 1, "liquidation utilization written at boundary");
    }

    /// setMinLiquidity reverts at exactly WAD and passes at WAD - 1 with event and write
    function test_SetMinLiquidity_boundaryEventWrite() public {
        vm.expectRevert(IRoycoDayAccountant.INVALID_LIQUIDITY_CONFIG.selector);
        accountant.setMinLiquidity(uint64(WAD));
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.MinLiquidityUpdated(uint64(WAD - 1));
        accountant.setMinLiquidity(uint64(WAD - 1));
        assertEq(accountant.getState().minLiquidityWAD, uint64(WAD - 1), "minLiquidity written at boundary");
    }

    /// a nonzero duration update mid-FIXED_TERM changes only the duration, leaving IL, state, and end timestamp intact
    function test_SetFixedTermDuration_nonzeroKeepsFixedTermState() public {
        _seedState(1000e18, 200e18, 100e18, SEED_LPT_RAW, MarketState.FIXED_TERM);
        uint32 endBefore = accountant.getState().fixedTermEndTimestamp;
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermDurationUpdated(uint24(1_209_600));
        accountant.setFixedTermDuration(uint24(1_209_600));
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(s.fixedTermDurationSeconds, 1_209_600, "duration written");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.FIXED_TERM), "market state untouched");
        assertEq(toUint256(s.lastJTImpermanentLoss), 100e18, "il untouched");
        assertEq(s.fixedTermEndTimestamp, endBefore, "end timestamp untouched");
    }

    /// a zero duration erases IL, forces PERPETUAL mid-FIXED_TERM, deletes the end timestamp, and the next sync stays perpetual
    function test_SetFixedTermDuration_zeroForcesPerpetualAndErasesIL() public {
        _seedState(1000e18, 200e18, 100e18, SEED_LPT_RAW, MarketState.FIXED_TERM);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(toNAVUnits(uint256(100e18)));
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermDurationUpdated(0);
        accountant.setFixedTermDuration(0);
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(s.fixedTermDurationSeconds, 0, "duration zeroed");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.PERPETUAL), "forced perpetual");
        assertEq(toUint256(s.lastJTImpermanentLoss), 0, "il erased");
        assertEq(s.fixedTermEndTimestamp, 0, "end timestamp deleted");

        // A fresh covered loss on the next sync is erased on the spot and the market stays perpetual
        // The junior buffer absorbs the whole 50e18 loss first (min(loss, jtEffectiveNAV) with jtEffectiveNAV
        // 200e18), the zero-elapsed window owes no coupon, so jtEffectiveNAV = 150e18 with a 50e18 il that the
        // permanently-perpetual branch erases within the same sync
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(toNAVUnits(uint256(50e18)));
        kernel.doPreOp(toNAVUnits(uint256(1150e18)));
        s = accountant.getState();
        assertEq(uint8(s.lastMarketState), uint8(MarketState.PERPETUAL), "sync respects permanently-perpetual");
        assertEq(toUint256(s.lastJTImpermanentLoss), 0, "il erased on sync");
        assertEq(toUint256(s.lastJTEffectiveNAV), 150e18, "coverage still applied to jt");
    }

    /// the IL reset event fires from the zero-duration setter even when the erased amount is zero
    function test_SetFixedTermDuration_zeroEmitsResetEventEvenWhenILZero() public {
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(ZERO_NAV_UNITS);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermDurationUpdated(0);
        accountant.setFixedTermDuration(0);
    }

    /// the dust setter writes the tolerance, emits, and a second write overwrites cleanly
    function test_SetDustTolerance_eventAndWrite() public {
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.DustToleranceUpdated(toNAVUnits(uint256(5)));
        accountant.setDustTolerance(toNAVUnits(uint256(5)));
        assertEq(toUint256(accountant.getState().dustTolerance), 5, "dust written");
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.DustToleranceUpdated(toNAVUnits(uint256(7)));
        accountant.setDustTolerance(toNAVUnits(uint256(7)));
        assertEq(toUint256(accountant.getState().dustTolerance), 7, "dust overwritten");
    }
}
