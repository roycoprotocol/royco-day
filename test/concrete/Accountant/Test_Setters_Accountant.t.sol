// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { MAX_PROTOCOL_FEE_WAD, WAD, ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { MockAccountantKernel } from "../../mocks/MockAccountantKernel.sol";
import { MockRecordingYDM } from "../../mocks/MockRecordingYDM.sol";
import { AccountantTestBase } from "../../utils/AccountantTestBase.sol";

/**
 * @title Test_Setters_Accountant
 * @notice Every restricted setter's validation boundary, event, and state write, the fixed-term-duration
 *         setter's permanently-perpetual round trip, the single dust-tolerance setter, and the YDM setter
 *         identity and initialization-data paths
 */
contract Test_Setters_Accountant is AccountantTestBase {
    function setUp() public {
        stranger = makeAddr("stranger");
        _deploy(_defaultParams());
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
        assertEq(s.maxLPTYieldShareWAD, 0.4e18, "maxLPT written");
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
        // Attribution of the 50e18 collateral loss at checkpoint 1000e18/200e18: deltaST = floor(50e18 * 1000e18 / 1200e18)
        // and JT takes the residual, then JT covers the whole ST leg, so the full 50e18 lands on jtEffectiveNAV as IL
        // and the permanently-perpetual branch erases the resulting 50e18 IL within the same sync
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

    /**
     * a raised dust tolerance changes the next sync's dust gate
     * Derivation: a +60 wei collateral gain at checkpoint 1000e18/200e18 attributes deltaST = floor(60 * 1000e18 / 1200e18)
     * = 50 to ST with JT taking the residual 10. Above a 0 dust tolerance the 10 wei JT gain takes
     * jtProtocolFee = floor(10 * 0.1e18 / 1e18) = 1 wei. After raising the dust tolerance to 10 the next +60 wei
     * gain splits identically (the post-sync ratio (1000e18 + 50) / (1200e18 + 60) is exactly 5/6), so the 10 wei
     * JT gain equals the tolerance and the strict > gate takes no fee
     */
    function test_SetDustTolerance_affectsNextSyncDustGate() public {
        _seedAndInitAccrual();
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_EFF + SEED_JT_EFF + 60));
        assertEq(toUint256(state.jtProtocolFee), 1, "fee taken above zero dust");
        accountant.setDustTolerance(toNAVUnits(uint256(10)));
        state = kernel.doPreOp(toNAVUnits(SEED_ST_EFF + SEED_JT_EFF + 120));
        assertEq(toUint256(state.jtProtocolFee), 0, "gain equal to dust takes no fee");
    }

    /**
     * the single dust tolerance has no upper-bound validation and no derived sum to overflow: the setter
     * accepts the entire uint256 range and the write is exact, so the old two-setter checked-add panic
     * surface is gone by construction
     */
    function test_SetDustTolerance_acceptsFullUint256Range() public {
        accountant.setDustTolerance(toNAVUnits(type(uint256).max));
        assertEq(toUint256(accountant.getState().dustTolerance), type(uint256).max, "dust accepts the uint256 maximum");
        accountant.setDustTolerance(ZERO_NAV_UNITS);
        assertEq(toUint256(accountant.getState().dustTolerance), 0, "dust shrinks back to zero");
    }

    /**
     * The dust setter accepts economically absurd tolerances with no upper bound. Dust exists to suppress
     * rounding artifacts of a few wei, but a 1e45 tolerance (far above any NAV in the market, no overflow) makes
     * EVERY gain and EVERY coverage loss read as dust, which silently disables three unrelated protections at
     * once:
     * 1. Protocol fees: a genuine 100e18 collateral gain still pays the JT risk premium and LPT liquidity premium,
     *    but the fee-taking gates (each attributed gain must exceed the dust tolerance) never open, so st/jt/lt
     *    fees are all zero where the configured 10% fee would otherwise take them
     * 2. Premium-window resets: because the senior gain reads as dust, the premiums are never marked as paid, so
     *    the time-weighted accumulators are not reset and the last premium payment timestamp does not advance,
     *    leaving the same earned window to be paid again on every subsequent gain
     * 3. FIXED_TERM entry and the IL ledger: a genuine coverage loss that wipes about half the junior buffer
     *    leaves a drawdown below the tolerance, so the market resolves PERPETUAL and the erasure rule wipes
     *    the IL ledger at commit — the fixed-term observation window never engages AND the senior never owes
     *    the drawdown back as a recovery
     */
    function test_HugeDustTolerance_SuppressesProtocolFeesPremiumResetsAndFixedTermEntry() public {
        // Flat 1000e18 / 200e18 market with the accrual and premium clocks initialized this block
        _seedAndInitAccrual();
        uint32 premiumClockBefore = accountant.getState().lastPremiumPaymentTimestamp;

        // An absurd but non-overflowing dust tolerance: 1e45 dwarfs every NAV this market will ever hold
        accountant.setDustTolerance(toNAVUnits(uint256(1e45)));
        assertEq(toUint256(accountant.getState().dustTolerance), 1e45, "dust written at 1e45");

        // Accrue a 1000s premium window at yield shares jt 0.1e18 / lt 0.05e18 (both below their caps 0.2e18 / 0.1e18)
        jtYDM.setRates(0.1e18);
        lptYDM.setRates(0.05e18);
        vm.warp(block.timestamp + 1000);

        // A genuine +100e18 collateral gain attributes deltaST = floor(100e18 * 1000e18 / 1200e18) = 83333333333333333333
        // to ST with JT taking the residual 16666666666666666667. Accrued windows twJT = 0.1e18 * 1000 = 100e18 and
        // twLPT = 0.05e18 * 1000 = 50e18 pay jtRiskPremium = floor(deltaST * 100e18 / (1000 * 1e18)) = 8333333333333333333
        // and lptLiquidityPremium = 4166666666666666666 out of the senior gain, so
        // jtEffectiveNAV = 200e18 + 16666666666666666667 + 8333333333333333333 = 225e18 and
        // stEffectiveNAV = 1000e18 + (deltaST - jtPrem - lptPrem) + lptPrem = 1075e18 (conservation: 1300e18)
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_EFF + SEED_JT_EFF + 100e18));
        assertEq(toUint256(state.jtEffectiveNAV), 225e18, "jt keeps its attributed gain and the still-paid risk premium");
        assertEq(toUint256(state.lptLiquidityPremium), 4_166_666_666_666_666_666, "lt liquidity premium is still paid");
        assertEq(toUint256(state.stEffectiveNAV), 1075e18, "st keeps the residual plus the lt premium leg");

        // With zero dust this exact sync takes jt fee floor(16666666666666666667 * 0.1) + floor(8333333333333333333 * 0.1)
        // = 2499999999999999999, lt fee floor(4166666666666666666 * 0.1) = 416666666666666666, and st fee
        // floor(70833333333333333334 * 0.1) = 7083333333333333333, all strictly positive, but every attributed
        // gain reads as dust against 1e45 so every fee is skipped
        assertEq(toUint256(state.jtProtocolFee), 0, "jt fee skipped because the gain reads as dust");
        assertEq(toUint256(state.lptProtocolFee), 0, "lt fee skipped because the gain reads as dust");
        assertEq(toUint256(state.stProtocolFee), 0, "st fee skipped because the gain reads as dust");

        // The premiums were paid but never marked as paid: the earned window survives to be paid again
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(uint256(s.twJTYieldShareAccruedWAD), 100e18, "jt accumulator not reset by the paid premium");
        assertEq(uint256(s.twLPTYieldShareAccruedWAD), 50e18, "lt accumulator not reset by the paid premium");
        assertEq(s.lastPremiumPaymentTimestamp, premiumClockBefore, "premium payment clock frozen");

        // A genuine -110e18 collateral loss at checkpoint 1075e18 / 225e18 (collateral 1300e18):
        // deltaST = floor(110e18 * 1075e18 / 1300e18) = 90961538461538461538 with the JT residual
        // 19038461538461538462 booked directly as drawdown, and the whole ST leg is covered by the junior buffer,
        // so jtEffectiveNAV = 225e18 - 19038461538461538462 - 90961538461538461538 = 115e18 with a 110e18 drawdown.
        // Coverage utilization = ceil(1190e18 * 0.1e18 / 115e18) = 1034782608695652174 stays below the
        // 1.1e18 liquidation threshold, so the resolution comes from the dust disjunct, not a liquidation breach:
        // 110e18 <= 1e45 with the initial state PERPETUAL resolves PERPETUAL, and the PERPETUAL commit erases
        // the whole 110e18 from the IL ledger on the spot (the reset event fires with the erased value)
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(toNAVUnits(uint256(110e18)));
        state = kernel.doPreOp(toNAVUnits(uint256(1190e18)));
        assertEq(toUint256(state.jtEffectiveNAV), 115e18, "junior buffer absorbed its residual and covered the whole st leg");
        assertEq(toUint256(state.jtImpermanentLoss), 0, "the perpetual commit erases the whole drawdown from the il ledger");
        assertEq(state.coverageUtilizationWAD, 1_034_782_608_695_652_174, "sub-threshold coverage utilization");

        // With zero dust a 110e18 il enters FIXED_TERM to protect the junior tranche while senior repays it,
        // but 110e18 <= 1e45 reads as dust so the market never leaves PERPETUAL despite the real loss, and the
        // biconditional PERPETUAL <=> il == 0 holds because the commit erased the drawdown outright
        s = accountant.getState();
        assertEq(uint8(s.lastMarketState), uint8(MarketState.PERPETUAL), "fixed-term observation period never engages");
        assertEq(toUint256(s.lastJTImpermanentLoss), 0, "perpetual checkpoint carries no il (biconditional invariant)");
    }

    /// setJuniorTrancheYDM rejects the current LPT YDM
    function test_RevertIf_SetJuniorTrancheYDMEqualsLPTYDM() public {
        vm.expectRevert(IRoycoDayAccountant.YDMS_CANNOT_BE_IDENTICAL.selector);
        accountant.setJuniorTrancheYDM(address(lptYDM), "");
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

    /// setLiquidityProviderTrancheYDM rejects the current JT YDM
    function test_RevertIf_SetLiquidityProviderTrancheYDMEqualsJTYDM() public {
        vm.expectRevert(IRoycoDayAccountant.YDMS_CANNOT_BE_IDENTICAL.selector);
        accountant.setLiquidityProviderTrancheYDM(address(jtYDM), "");
    }

    /// re-setting the current LPT YDM is allowed
    function test_SetLiquidityProviderTrancheYDM_allowsCurrentLPTYDM() public {
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.LiquidityProviderTrancheYDMUpdated(address(lptYDM));
        accountant.setLiquidityProviderTrancheYDM(address(lptYDM), "");
        assertEq(accountant.getState().lptYDM, address(lptYDM), "lt ydm unchanged");
    }

    /// setLiquidityProviderTrancheYDM rejects the null address
    function test_RevertIf_SetLiquidityProviderTrancheYDMNull() public {
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        accountant.setLiquidityProviderTrancheYDM(address(0), "");
    }

    /// setLiquidityProviderTrancheYDM initialization data paths
    function test_SetLiquidityProviderTrancheYDM_initDataPaths() public {
        MockRecordingYDM silent = new MockRecordingYDM();
        accountant.setLiquidityProviderTrancheYDM(address(silent), "");
        assertEq(silent.initializeCallCount(), 0, "empty data makes no init call");

        MockRecordingYDM initialized = new MockRecordingYDM();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.LiquidityProviderTrancheYDMUpdated(address(initialized));
        accountant.setLiquidityProviderTrancheYDM(address(initialized), abi.encodeCall(MockRecordingYDM.initializeModel, (hex"beef")));
        assertEq(initialized.initializeCallCount(), 1, "non-empty data initializes");
        assertEq(initialized.lastInitializePayload(), hex"beef", "payload forwarded verbatim");
        assertEq(accountant.getState().lptYDM, address(initialized), "lt ydm written");

        MockRecordingYDM reverting = new MockRecordingYDM();
        reverting.setRevertOnInitialize(true);
        vm.expectRevert(
            abi.encodeWithSelector(IRoycoDayAccountant.FAILED_TO_INITIALIZE_YDM.selector, abi.encodeWithSelector(MockRecordingYDM.YDM_INIT_REVERTED.selector))
        );
        accountant.setLiquidityProviderTrancheYDM(address(reverting), abi.encodeCall(MockRecordingYDM.initializeModel, (hex"")));
    }

    /**
     * Adversarial cap grief: an operator lowers both max yield shares to zero AFTER a high-rate window has
     * accrued, hoping (or fearing) the already-earned window reprices to nothing. The setter's own pre-body
     * sync accrues the window at the OLD caps, and the payment branch prices from the stored accumulators
     * without re-capping, so the earned premium survives the cap change — caps are never retroactive
     * Derivation: hostile rates 0.5e18 capped at accrual to (0.2e18, 0.1e18) over 1000s give tw = (200e18, 100e18).
     * The post-setter +100e18 collateral gain attributes deltaST = floor(100e18 * 1000e18 / 1200e18)
     * = 83333333333333333333 to ST with JT taking the residual 16666666666666666667, and the senior gain pays
     * jtPrem = floor(deltaST * 200e18 / (1000 * 1e18)) = 16666666666666666666 and lptPrem = 8333333333333333333:
     *   jtEffectiveNAV = 200e18 + 16666666666666666667 + 16666666666666666666 = 233333333333333333333
     *   stEffectiveNAV = 1000e18 + (deltaST - jtPrem - lptPrem) + lptPrem = 1066666666666666666667
     *   jtFee = floor(16666666666666666667 * 0.1) + floor(jtPrem * 0.1) = 3333333333333333332
     *   lptFee = floor(lptPrem * 0.1) = 833333333333333333, stFee = floor(58333333333333333334 * 0.1) = 5833333333333333333
     */
    function test_SetMaxYieldShares_loweringCapDoesNotEraseAccruedWindow() public {
        _seedAndInitAccrual();
        jtYDM.setRates(0.5e18);
        lptYDM.setRates(0.5e18);
        vm.warp(block.timestamp + 1000);

        // The hard-sync setter accrues the window at the old caps before its body lowers them to zero
        kernel.setSyncMode(MockAccountantKernel.SyncMode.SYNC);
        kernel.setSyncNAV(toNAVUnits(SEED_ST_EFF + SEED_JT_EFF));
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.YieldSharesAccrued(0.2e18, 200e18, 0.1e18, 100e18);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.MaxYieldSharesUpdated(0, 0);
        accountant.setMaxYieldShares(0, 0);
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(uint256(s.twJTYieldShareAccruedWAD), 200e18, "jt window accrued at the old cap before the body");
        assertEq(uint256(s.twLPTYieldShareAccruedWAD), 100e18, "lt window accrued at the old cap before the body");
        assertEq(s.maxJTYieldShareWAD, 0, "jt cap lowered to zero");
        assertEq(s.maxLPTYieldShareWAD, 0, "lt cap lowered to zero");

        // The same-block gain still pays the premium earned under the old caps
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_EFF + SEED_JT_EFF + 100e18));
        assertEq(toUint256(state.jtEffectiveNAV), 233_333_333_333_333_333_333, "jt keeps its attributed gain plus the pre-change-window premium");
        assertEq(toUint256(state.lptLiquidityPremium), 8_333_333_333_333_333_333, "lt premium priced from the pre-change window");
        assertEq(toUint256(state.stEffectiveNAV), 1_066_666_666_666_666_666_667, "st keeps residual plus the lt premium leg");
        assertEq(toUint256(state.jtProtocolFee), 3_333_333_333_333_333_332, "jt fee on the attributed gain and the earned premium");
        assertEq(toUint256(state.lptProtocolFee), 833_333_333_333_333_333, "lt fee on the earned premium");
        assertEq(toUint256(state.stProtocolFee), 5_833_333_333_333_333_333, "st fee on the retained residual");
        s = accountant.getState();
        assertEq(uint256(s.twJTYieldShareAccruedWAD), 0, "window consumed by the payment");
        assertEq(uint256(s.twLPTYieldShareAccruedWAD), 0, "lt window consumed by the payment");
    }
}
