// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { MAX_FIXED_TERM_SECONDS, MAX_PROTOCOL_FEE_WAD, WAD, ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { MockAccountantKernel } from "../../mocks/MockAccountantKernel.sol";
import { MockRecordingYDM } from "../../mocks/MockRecordingYDM.sol";
import { AccountantTestBase } from "../../utils/AccountantTestBase.sol";

/**
 * @title Test_Setters_Accountant
 * @notice Every restricted setter's validation boundary, event, and state write, the fixed-term-duration
 *         setter's permanently-perpetual round trip, the dust-tolerance recompute, and the YDM setter
 *         identity and initialization-data paths
 */
contract Test_Setters_Accountant is AccountantTestBase {
    function setUp() public {
        stranger = makeAddr("stranger");
        _deploy(false, _defaultParams());
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

    /// JT protocol fee setter boundary, event, and write
    function test_SetJuniorTrancheProtocolFee_boundaryEventWrite() public {
        vm.expectRevert(IRoycoDayAccountant.MAX_PROTOCOL_FEE_EXCEEDED.selector);
        accountant.setJuniorTrancheProtocolFee(uint64(MAX_PROTOCOL_FEE_WAD + 1));
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheProtocolFeeUpdated(uint64(MAX_PROTOCOL_FEE_WAD));
        accountant.setJuniorTrancheProtocolFee(uint64(MAX_PROTOCOL_FEE_WAD));
        assertEq(accountant.getState().jtProtocolFeeWAD, uint64(MAX_PROTOCOL_FEE_WAD), "jt fee written at max boundary");
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

    /// LT yield-share protocol fee setter boundary, event, and write
    function test_SetLTYieldShareProtocolFee_boundaryEventWrite() public {
        vm.expectRevert(IRoycoDayAccountant.MAX_PROTOCOL_FEE_EXCEEDED.selector);
        accountant.setLTYieldShareProtocolFee(uint64(MAX_PROTOCOL_FEE_WAD + 1));
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.LiquidityTrancheYieldShareProtocolFeeUpdated(uint64(MAX_PROTOCOL_FEE_WAD));
        accountant.setLTYieldShareProtocolFee(uint64(MAX_PROTOCOL_FEE_WAD));
        assertEq(accountant.getState().ltYieldShareProtocolFeeWAD, uint64(MAX_PROTOCOL_FEE_WAD), "lt ys fee written at max boundary");
    }

    /// setMinCoverage reverts at exactly WAD and passes at WAD - 1 with event and write
    function test_SetMinCoverage_boundaryEventWrite() public {
        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        accountant.setMinCoverage(uint64(WAD));
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.CoverageUpdated(uint64(WAD - 1));
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
        emit IRoycoDayAccountant.LiquidityUpdated(uint64(WAD - 1));
        accountant.setMinLiquidity(uint64(WAD - 1));
        assertEq(accountant.getState().minLiquidityWAD, uint64(WAD - 1), "minLiquidity written at boundary");
    }

    /// setMaxYieldShares reverts above a WAD sum and passes at exactly WAD with event and write
    function test_SetMaxYieldShares_boundaryEventWrite() public {
        vm.expectRevert(IRoycoDayAccountant.INVALID_MAX_YIELD_SHARE_CONFIG.selector);
        accountant.setMaxYieldShares(0.6e18, 0.4e18 + 1);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.MaxYieldSharesUpdated(0.6e18, 0.4e18);
        accountant.setMaxYieldShares(0.6e18, 0.4e18);
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(s.maxJTYieldShareWAD, 0.6e18, "maxJT written");
        assertEq(s.maxLTYieldShareWAD, 0.4e18, "maxLT written");
    }

    /// a nonzero duration update mid-FIXED_TERM changes only the duration, leaving IL, state, and end timestamp intact
    function test_SetFixedTermDuration_nonzeroKeepsFixedTermState() public {
        _seedState(900e18, 300e18, 1000e18, 200e18, 100e18, SEED_LT_RAW, MarketState.FIXED_TERM);
        uint32 endBefore = accountant.getState().fixedTermEndTimestamp;
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermDurationUpdated(uint24(MAX_FIXED_TERM_SECONDS));
        accountant.setFixedTermDuration(uint24(MAX_FIXED_TERM_SECONDS));
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(s.fixedTermDurationSeconds, uint24(MAX_FIXED_TERM_SECONDS), "duration written");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.FIXED_TERM), "market state untouched");
        assertEq(toUint256(s.lastJTCoverageImpermanentLoss), 100e18, "il untouched");
        assertEq(s.fixedTermEndTimestamp, endBefore, "end timestamp untouched");
    }

    /// a zero duration erases IL, forces PERPETUAL mid-FIXED_TERM, deletes the end timestamp, and the next sync stays perpetual
    function test_SetFixedTermDuration_zeroForcesPerpetualAndErasesIL() public {
        _seedState(900e18, 300e18, 1000e18, 200e18, 100e18, SEED_LT_RAW, MarketState.FIXED_TERM);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(toNAVUnits(uint256(100e18)));
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermDurationUpdated(0);
        accountant.setFixedTermDuration(0);
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(s.fixedTermDurationSeconds, 0, "duration zeroed");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.PERPETUAL), "forced perpetual");
        assertEq(toUint256(s.lastJTCoverageImpermanentLoss), 0, "il erased");
        assertEq(s.fixedTermEndTimestamp, 0, "end timestamp deleted");

        // A fresh covered loss on the next sync is erased on the spot and the market stays perpetual
        // Attribution: jtEffectiveNAV 200e18 < jtRawNAV 300e18 so all of the 50e18 ST raw loss lands on ST, is covered by JT,
        // and the permanently-perpetual branch erases the resulting 50e18 IL within the same sync
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(toNAVUnits(uint256(50e18)));
        kernel.doPreOp(toNAVUnits(uint256(850e18)), toNAVUnits(uint256(300e18)));
        s = accountant.getState();
        assertEq(uint8(s.lastMarketState), uint8(MarketState.PERPETUAL), "sync respects permanently-perpetual");
        assertEq(toUint256(s.lastJTCoverageImpermanentLoss), 0, "il erased on sync");
        assertEq(toUint256(s.lastJTEffectiveNAV), 150e18, "coverage still applied to jt");
    }

    /// the IL reset event fires from the zero-duration setter even when the erased amount is zero
    function test_SetFixedTermDuration_zeroEmitsResetEventEvenWhenILZero() public {
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(ZERO_NAV_UNITS);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermDurationUpdated(0);
        accountant.setFixedTermDuration(0);
    }

    /// a duration above the protocol-wide cap reverts, so no market can commit users past the maximum fixed term
    function test_SetFixedTermDuration_revertsAboveMax() public {
        vm.expectRevert(IRoycoDayAccountant.FIXED_TERM_DURATION_EXCEEDS_MAX.selector);
        accountant.setFixedTermDuration(uint24(MAX_FIXED_TERM_SECONDS + 1));
    }

    /// durations at and below the protocol-wide cap are accepted and written
    function test_SetFixedTermDuration_succeedsAtAndBelowMax() public {
        accountant.setFixedTermDuration(uint24(MAX_FIXED_TERM_SECONDS));
        assertEq(accountant.getState().fixedTermDurationSeconds, uint24(MAX_FIXED_TERM_SECONDS), "duration at the cap written");
        accountant.setFixedTermDuration(uint24(MAX_FIXED_TERM_SECONDS - 1));
        assertEq(accountant.getState().fixedTermDurationSeconds, uint24(MAX_FIXED_TERM_SECONDS - 1), "duration below the cap written");
    }

    /// each dust setter writes its tolerance, emits, and recomputes the cached effective sum
    function test_SetDustTolerances_recomputeEffectiveTolerance() public {
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.SeniorTrancheDustToleranceUpdated(toNAVUnits(uint256(5)));
        accountant.setSeniorTrancheDustTolerance(toNAVUnits(uint256(5)));
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.stNAVDustTolerance), 5, "st dust written");
        assertEq(toUint256(s.effectiveNAVDustTolerance), 5, "effective dust recomputed after st update");
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheDustToleranceUpdated(toNAVUnits(uint256(7)));
        accountant.setJuniorTrancheDustTolerance(toNAVUnits(uint256(7)));
        s = accountant.getState();
        assertEq(toUint256(s.jtNAVDustTolerance), 7, "jt dust written");
        assertEq(toUint256(s.effectiveNAVDustTolerance), 12, "effective dust recomputed after jt update");
    }

    /**
     * a raised dust tolerance changes the next sync's dust gate
     * Derivation: a 10 wei JT gain above a 0 dust tolerance takes jtProtocolFee = floor(10 * 0.1e18 / 1e18) = 1 wei,
     * and after raising the JT dust tolerance to 10 the identical gain equals the tolerance so no fee is taken
     */
    function test_SetDustTolerances_affectNextSyncDustGate() public {
        _seedAndInitAccrual();
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW + 10));
        assertEq(toUint256(state.jtProtocolFee), 1, "fee taken above zero dust");
        accountant.setJuniorTrancheDustTolerance(toNAVUnits(uint256(10)));
        state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW + 20));
        assertEq(toUint256(state.jtProtocolFee), 0, "gain equal to dust takes no fee");
    }

    /// setJuniorTrancheYDM rejects the current LT YDM
    function test_RevertIf_SetJuniorTrancheYDMEqualsLTYDM() public {
        vm.expectRevert(IRoycoDayAccountant.YDMS_CANNOT_BE_IDENTICAL.selector);
        accountant.setJuniorTrancheYDM(address(ltYDM), "");
    }

    /// only cross-identity is checked, so re-setting the current JT YDM is allowed
    function test_SetJuniorTrancheYDM_allowsCurrentJTYDM() public {
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheYDMUpdated(address(jtYDM));
        accountant.setJuniorTrancheYDM(address(jtYDM), "");
        assertEq(accountant.getState().jtYDM, address(jtYDM), "jt ydm unchanged");
    }

    /// setJuniorTrancheYDM rejects the null address
    function test_RevertIf_SetJuniorTrancheYDMNull() public {
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        accountant.setJuniorTrancheYDM(address(0), "");
    }

    /// setJuniorTrancheYDM initialization data paths (skipped when empty, forwarded verbatim, reverting payload bubbled)
    function test_SetJuniorTrancheYDM_initDataPaths() public {
        MockRecordingYDM silent = new MockRecordingYDM();
        accountant.setJuniorTrancheYDM(address(silent), "");
        assertEq(silent.initializeCallCount(), 0, "empty data makes no init call");

        MockRecordingYDM initialized = new MockRecordingYDM();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheYDMUpdated(address(initialized));
        accountant.setJuniorTrancheYDM(address(initialized), abi.encodeCall(MockRecordingYDM.initializeModel, (hex"abcd")));
        assertEq(initialized.initializeCallCount(), 1, "non-empty data initializes");
        assertEq(initialized.lastInitializePayload(), hex"abcd", "payload forwarded verbatim");
        assertEq(accountant.getState().jtYDM, address(initialized), "jt ydm written");

        MockRecordingYDM reverting = new MockRecordingYDM();
        reverting.setRevertOnInitialize(true);
        vm.expectRevert(
            abi.encodeWithSelector(IRoycoDayAccountant.FAILED_TO_INITIALIZE_YDM.selector, abi.encodeWithSelector(MockRecordingYDM.YDM_INIT_REVERTED.selector))
        );
        accountant.setJuniorTrancheYDM(address(reverting), abi.encodeCall(MockRecordingYDM.initializeModel, (hex"")));
    }

    /// setLiquidityTrancheYDM rejects the current JT YDM
    function test_RevertIf_SetLiquidityTrancheYDMEqualsJTYDM() public {
        vm.expectRevert(IRoycoDayAccountant.YDMS_CANNOT_BE_IDENTICAL.selector);
        accountant.setLiquidityTrancheYDM(address(jtYDM), "");
    }

    /// re-setting the current LT YDM is allowed
    function test_SetLiquidityTrancheYDM_allowsCurrentLTYDM() public {
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.LiquidityTrancheYDMUpdated(address(ltYDM));
        accountant.setLiquidityTrancheYDM(address(ltYDM), "");
        assertEq(accountant.getState().ltYDM, address(ltYDM), "lt ydm unchanged");
    }

    /// setLiquidityTrancheYDM rejects the null address
    function test_RevertIf_SetLiquidityTrancheYDMNull() public {
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        accountant.setLiquidityTrancheYDM(address(0), "");
    }

    /// setLiquidityTrancheYDM initialization data paths
    function test_SetLiquidityTrancheYDM_initDataPaths() public {
        MockRecordingYDM silent = new MockRecordingYDM();
        accountant.setLiquidityTrancheYDM(address(silent), "");
        assertEq(silent.initializeCallCount(), 0, "empty data makes no init call");

        MockRecordingYDM initialized = new MockRecordingYDM();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.LiquidityTrancheYDMUpdated(address(initialized));
        accountant.setLiquidityTrancheYDM(address(initialized), abi.encodeCall(MockRecordingYDM.initializeModel, (hex"beef")));
        assertEq(initialized.initializeCallCount(), 1, "non-empty data initializes");
        assertEq(initialized.lastInitializePayload(), hex"beef", "payload forwarded verbatim");
        assertEq(accountant.getState().ltYDM, address(initialized), "lt ydm written");

        MockRecordingYDM reverting = new MockRecordingYDM();
        reverting.setRevertOnInitialize(true);
        vm.expectRevert(
            abi.encodeWithSelector(IRoycoDayAccountant.FAILED_TO_INITIALIZE_YDM.selector, abi.encodeWithSelector(MockRecordingYDM.YDM_INIT_REVERTED.selector))
        );
        accountant.setLiquidityTrancheYDM(address(reverting), abi.encodeCall(MockRecordingYDM.initializeModel, (hex"")));
    }

    /**
     * Adversarial cap grief: an operator lowers both max yield shares to zero AFTER a high-rate window has
     * accrued, hoping (or fearing) the already-earned window reprices to nothing. The setter's own pre-body
     * sync accrues the window at the OLD caps, and the payment branch prices from the stored accumulators
     * without re-capping, so the earned premium survives the cap change — caps are never retroactive
     * Derivation: hostile rates 0.5e18 capped at accrual to (0.2e18, 0.1e18) over 1000s give tw = (200e18, 100e18);
     * the post-setter 100e18 gain pays jtPrem = floor(100e18 * 200e18 / (1000 * 1e18)) = 20e18 and ltPrem = 10e18,
     * with fees jtFee = 2e18, ltFee = 1e18, stFee = floor((100e18 - 30e18) * 0.1) = 7e18
     */
    function test_SetMaxYieldShares_loweringCapDoesNotEraseAccruedWindow() public {
        _seedAndInitAccrual();
        jtYDM.setRates(0.5e18);
        ltYDM.setRates(0.5e18);
        vm.warp(block.timestamp + 1000);

        // The hard-sync setter accrues the window at the old caps before its body lowers them to zero
        kernel.setSyncMode(MockAccountantKernel.SyncMode.SYNC);
        kernel.setSyncNAVs(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheYieldShareAccrued(0.2e18, 200e18);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.LiquidityTrancheYieldShareAccrued(0.1e18, 100e18);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.MaxYieldSharesUpdated(0, 0);
        accountant.setMaxYieldShares(0, 0);
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(uint256(s.twJTYieldShareAccruedWAD), 200e18, "jt window accrued at the old cap before the body");
        assertEq(uint256(s.twLTYieldShareAccruedWAD), 100e18, "lt window accrued at the old cap before the body");
        assertEq(s.maxJTYieldShareWAD, 0, "jt cap lowered to zero");
        assertEq(s.maxLTYieldShareWAD, 0, "lt cap lowered to zero");

        // The same-block gain still pays the premium earned under the old caps
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW + 100e18), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + 20e18, "jt premium priced from the pre-change window");
        assertEq(toUint256(state.ltLiquidityPremium), 10e18, "lt premium priced from the pre-change window");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_RAW + 100e18 - 20e18, "st keeps residual plus the lt premium leg");
        assertEq(toUint256(state.jtProtocolFee), 2e18, "jt yield-share fee on the earned premium");
        assertEq(toUint256(state.ltProtocolFee), 1e18, "lt fee on the earned premium");
        assertEq(toUint256(state.stProtocolFee), 7e18, "st fee on the retained residual");
        s = accountant.getState();
        assertEq(uint256(s.twJTYieldShareAccruedWAD), 0, "window consumed by the payment");
        assertEq(uint256(s.twLTYieldShareAccruedWAD), 0, "lt window consumed by the payment");
    }
}
