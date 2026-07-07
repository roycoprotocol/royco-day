// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { IYDM } from "../../../src/interfaces/IYDM.sol";
import { WAD, ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";
import { AccountantTestBase } from "../../utils/AccountantTestBase.sol";

/**
 * @title Test_SyncTrancheAccounting_Accountant
 * @notice The tranche accounting sync scenarios: every (ST loss/flat/gain) x (JT loss/flat/gain) shape
 *         across the six committed IL/state regimes, the PnL attribution arms, the JT fee recomputation,
 *         coverage, IL recovery, the premium branches, and NAV conservation — every scenario asserted
 *         against a hand-derived literal, the RoycoTestMath mirror, and the committed checkpoint at once
 */
contract Test_SyncTrancheAccounting_Accountant is AccountantTestBase {
    function setUp() public {
        stranger = makeAddr("stranger");
        _deploy(false, _defaultParams());
    }

    /// @dev Fully hand-derived expectation for one sync vector, asserted field-by-field by _runSyncVector
    struct ExpectedSync {
        uint256 stEffectiveNAV;
        uint256 jtEffectiveNAV;
        uint256 il;
        uint256 ltPrem;
        uint256 stFee;
        uint256 jtFee;
        uint256 ltFee;
        MarketState marketState;
        uint32 fixedTermEndTimestamp;
    }

    /**
     * @dev Scenario runner: previews then executes the identical sync, asserts preview == execution
     * byte-for-byte (the one allowed both-sides-production assertion), asserts every returned field against the
     * hand-derived expectation, then re-reads the committed checkpoint and asserts exact NAV conservation plus
     * returned-vs-persisted equality
     *
     * The coverage utilization is asserted against the documented formula ceil(stRawNAV * minCoverage / jtEffectiveNAV)
     * evaluated with test-local math on the hand-derived jt effective NAV (JT_COINVESTED is false in every scenario deployment)
     */
    function _runSyncVector(uint256 _stRawNew, uint256 _jtRawNew, ExpectedSync memory _e) internal {
        IRoycoDayAccountant.RoycoDayAccountantState memory pre = accountant.getState();
        SyncedAccountingState memory previewed = accountant.previewSyncTrancheAccounting(toNAVUnits(_stRawNew), toNAVUnits(_jtRawNew));
        // The committed sync must emit TrancheAccountingSynced with the exact hand-derived resulting state
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.TrancheAccountingSynced(_expectedSyncedState(pre, _stRawNew, _jtRawNew, _e));
        SyncedAccountingState memory executed = kernel.doPreOp(toNAVUnits(_stRawNew), toNAVUnits(_jtRawNew));
        assertEq(keccak256(abi.encode(previewed)), keccak256(abi.encode(executed)), "vector: preview must match execution exactly");

        assertEq(uint8(executed.marketState), uint8(_e.marketState), "vector: market state");
        assertEq(toUint256(executed.stRawNAV), _stRawNew, "vector: st raw NAV passthrough");
        assertEq(toUint256(executed.jtRawNAV), _jtRawNew, "vector: jt raw NAV passthrough");
        assertEq(toUint256(executed.ltRawNAV), 0, "vector: lt raw NAV placeholder");
        assertEq(toUint256(executed.stEffectiveNAV), _e.stEffectiveNAV, "vector: st effective NAV");
        assertEq(toUint256(executed.jtEffectiveNAV), _e.jtEffectiveNAV, "vector: jt effective NAV");
        assertEq(toUint256(executed.jtCoverageImpermanentLoss), _e.il, "vector: jt coverage impermanent loss");
        assertEq(toUint256(executed.ltLiquidityPremium), _e.ltPrem, "vector: lt liquidity premium");
        assertEq(toUint256(executed.stProtocolFee), _e.stFee, "vector: st protocol fee");
        assertEq(toUint256(executed.jtProtocolFee), _e.jtFee, "vector: jt protocol fee");
        assertEq(toUint256(executed.ltProtocolFee), _e.ltFee, "vector: lt protocol fee");
        assertEq(executed.coverageUtilizationWAD, _expectedCoverageUtilization(_stRawNew, _e.jtEffectiveNAV), "vector: coverage utilization");
        assertEq(executed.liquidityUtilizationWAD, 0, "vector: liquidity utilization placeholder");
        assertEq(executed.fixedTermEndTimestamp, _e.fixedTermEndTimestamp, "vector: fixed term end timestamp");

        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(
            toUint256(s.lastSTRawNAV) + toUint256(s.lastJTRawNAV),
            toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV),
            "vector: committed NAV conservation"
        );
        assertEq(toUint256(s.lastSTEffectiveNAV), _e.stEffectiveNAV, "vector: committed st effective NAV");
        assertEq(toUint256(s.lastJTEffectiveNAV), _e.jtEffectiveNAV, "vector: committed jt effective NAV");
        assertEq(toUint256(s.lastJTCoverageImpermanentLoss), _e.il, "vector: committed il");
        assertEq(uint8(s.lastMarketState), uint8(_e.marketState), "vector: committed market state");
        assertEq(s.fixedTermEndTimestamp, _e.fixedTermEndTimestamp, "vector: committed fixed term end");

        _crossAssertSyncMirror(pre, _stRawNew, _jtRawNew, executed);
    }

    /**
     * @dev Assembles the full SyncedAccountingState the sync must emit in TrancheAccountingSynced, from the
     * hand-derived expectation plus the pre-sync config fields. The lt raw NAV and liquidity utilization are
     * zero placeholders on the pre-op path (the kernel commits the fresh LT mark after the sync)
     */
    function _expectedSyncedState(
        IRoycoDayAccountant.RoycoDayAccountantState memory _pre,
        uint256 _stRawNew,
        uint256 _jtRawNew,
        ExpectedSync memory _e
    )
        internal
        view
        returns (SyncedAccountingState memory st)
    {
        st.marketState = _e.marketState;
        st.stRawNAV = toNAVUnits(_stRawNew);
        st.jtRawNAV = toNAVUnits(_jtRawNew);
        st.ltRawNAV = ZERO_NAV_UNITS;
        st.stEffectiveNAV = toNAVUnits(_e.stEffectiveNAV);
        st.jtEffectiveNAV = toNAVUnits(_e.jtEffectiveNAV);
        st.jtCoverageImpermanentLoss = toNAVUnits(_e.il);
        st.ltLiquidityPremium = toNAVUnits(_e.ltPrem);
        st.stProtocolFee = toNAVUnits(_e.stFee);
        st.jtProtocolFee = toNAVUnits(_e.jtFee);
        st.ltProtocolFee = toNAVUnits(_e.ltFee);
        st.coverageUtilizationWAD = _expectedCoverageUtilization(_stRawNew, _e.jtEffectiveNAV);
        st.liquidityUtilizationWAD = 0;
        st.fixedTermEndTimestamp = _e.fixedTermEndTimestamp;
        st.minCoverageWAD = _pre.minCoverageWAD;
        st.jtCoinvested = accountant.JT_COINVESTED();
        st.coverageLiquidationUtilizationWAD = _pre.coverageLiquidationUtilizationWAD;
        st.minLiquidityWAD = _pre.minLiquidityWAD;
    }

    /**
     * @dev Builds the RoycoTestMath.SyncInputs for one sync from the pre-sync committed checkpoint, mirroring
     * the accrual model on the test side: when time elapsed since the last accrual, the mock YDMs' MUTATING rates (capped
     * at the configured maxima) are accrued onto the stored accumulators exactly as production does before the
     * sync consumes them. Same-block syncs pass the stored accumulators through unchanged
     */
    function _buildSyncInputs(
        IRoycoDayAccountant.RoycoDayAccountantState memory _pre,
        uint256 _stRawNew,
        uint256 _jtRawNew
    )
        internal
        view
        returns (RoycoTestMath.SyncInputs memory in_)
    {
        in_.stRawNAVLast = toUint256(_pre.lastSTRawNAV);
        in_.jtRawNAVLast = toUint256(_pre.lastJTRawNAV);
        in_.stEffectiveNAVLast = toUint256(_pre.lastSTEffectiveNAV);
        in_.jtEffectiveNAVLast = toUint256(_pre.lastJTEffectiveNAV);
        in_.jtCoverageImpermanentLossLast = toUint256(_pre.lastJTCoverageImpermanentLoss);
        in_.marketStateLast = RoycoTestMath.MarketState(uint8(_pre.lastMarketState));
        in_.fixedTermEndTimestampLast = _pre.fixedTermEndTimestamp;
        in_.stRawNAVDelta = int256(_stRawNew) - int256(in_.stRawNAVLast);
        in_.jtRawNAVDelta = int256(_jtRawNew) - int256(in_.jtRawNAVLast);
        // The kernel re-commits the unchanged LT mark after the sync in this suite
        in_.ltRawNAVNew = toUint256(_pre.lastLTRawNAV);
        // Mirror-side accrual: stored accumulators plus one capped mutating-rate window (first-ever accrual
        // initializes the clock and contributes nothing)
        in_.jtTwYieldShareAccrual = _pre.twJTYieldShareAccruedWAD;
        in_.ltTwYieldShareAccrual = _pre.twLTYieldShareAccruedWAD;
        if (_pre.lastYieldShareAccrualTimestamp != 0 && block.timestamp > _pre.lastYieldShareAccrualTimestamp) {
            uint256 elapsed = block.timestamp - _pre.lastYieldShareAccrualTimestamp;
            uint256 jtRate = jtYDM.yieldShareReturn();
            uint256 ltRate = ltYDM.yieldShareReturn();
            in_.jtTwYieldShareAccrual += (jtRate > _pre.maxJTYieldShareWAD ? _pre.maxJTYieldShareWAD : jtRate) * elapsed;
            in_.ltTwYieldShareAccrual += (ltRate > _pre.maxLTYieldShareWAD ? _pre.maxLTYieldShareWAD : ltRate) * elapsed;
        }
        // A first-ever accrual stamps lastPremiumPaymentTimestamp to now, so the premium window reads 0
        in_.elapsedSincePremiumPayment = _pre.lastYieldShareAccrualTimestamp == 0 ? 0 : block.timestamp - _pre.lastPremiumPaymentTimestamp;
        in_.jtInstYieldShareWAD = jtYDM.previewYieldShareReturn();
        in_.ltInstYieldShareWAD = ltYDM.previewYieldShareReturn();
        in_.maxJTYieldShareWAD = _pre.maxJTYieldShareWAD;
        in_.maxLTYieldShareWAD = _pre.maxLTYieldShareWAD;
        in_.stProtocolFeeWAD = _pre.stProtocolFeeWAD;
        in_.jtProtocolFeeWAD = _pre.jtProtocolFeeWAD;
        in_.jtYieldShareProtocolFeeWAD = _pre.jtYieldShareProtocolFeeWAD;
        in_.ltYieldShareProtocolFeeWAD = _pre.ltYieldShareProtocolFeeWAD;
        in_.nowTimestamp = block.timestamp;
        in_.fixedTermDuration = _pre.fixedTermDurationSeconds;
        in_.minCoverageWAD = _pre.minCoverageWAD;
        in_.jtCoinvested = accountant.JT_COINVESTED();
        in_.coverageLiquidationUtilizationWAD = _pre.coverageLiquidationUtilizationWAD;
        in_.effectiveDust = toUint256(_pre.effectiveNAVDustTolerance);
        in_.minLiquidityWAD = _pre.minLiquidityWAD;
    }

    /**
     * @dev Cross-asserts one executed sync against the independent RoycoTestMath.syncTrancheAccounting mirror field-by-field,
     * so every scenario is pinned by three sources at once: production, the hand-derived literal, and the
     * RoycoTestMath mirror. Also asserts the premiumsPaid side effects (accumulator reset and premium-payment stamp)
     * against the committed state, then commits the unchanged LT mark and asserts the mirror's post-commit
     * ltRawNAV / liquidity-utilization view
     */
    function _crossAssertSyncMirror(
        IRoycoDayAccountant.RoycoDayAccountantState memory _pre,
        uint256 _stRawNew,
        uint256 _jtRawNew,
        SyncedAccountingState memory _executed
    )
        internal
    {
        RoycoTestMath.SyncInputs memory in_ = _buildSyncInputs(_pre, _stRawNew, _jtRawNew);
        RoycoTestMath.SyncOutputs memory m = RoycoTestMath.syncTrancheAccounting(in_);

        assertEq(m.stRawNAV, toUint256(_executed.stRawNAV), "mirror: st raw NAV");
        assertEq(m.jtRawNAV, toUint256(_executed.jtRawNAV), "mirror: jt raw NAV");
        assertEq(m.stEffectiveNAV, toUint256(_executed.stEffectiveNAV), "mirror: st effective NAV");
        assertEq(m.jtEffectiveNAV, toUint256(_executed.jtEffectiveNAV), "mirror: jt effective NAV");
        assertEq(m.jtCoverageImpermanentLoss, toUint256(_executed.jtCoverageImpermanentLoss), "mirror: jt coverage impermanent loss");
        assertEq(m.ltLiquidityPremium, toUint256(_executed.ltLiquidityPremium), "mirror: lt liquidity premium");
        assertEq(m.stProtocolFee, toUint256(_executed.stProtocolFee), "mirror: st protocol fee");
        assertEq(m.jtProtocolFee, toUint256(_executed.jtProtocolFee), "mirror: jt protocol fee");
        assertEq(m.ltProtocolFee, toUint256(_executed.ltProtocolFee), "mirror: lt protocol fee");
        assertEq(m.coverageUtilizationWAD, _executed.coverageUtilizationWAD, "mirror: coverage utilization");
        assertEq(uint8(m.marketState), uint8(_executed.marketState), "mirror: market state");
        assertEq(m.fixedTermEndTimestamp, uint256(_executed.fixedTermEndTimestamp), "mirror: fixed term end");

        // premiumsPaid side effects (RoycoDayAccountant): reset both accumulators and stamp the payment timestamp,
        // otherwise the post-accrual accumulators persist and the payment window keeps running
        IRoycoDayAccountant.RoycoDayAccountantState memory post = accountant.getState();
        if (m.premiumsPaid) {
            assertEq(uint256(post.twJTYieldShareAccruedWAD), 0, "mirror: jt accumulator reset on premium payment");
            assertEq(uint256(post.twLTYieldShareAccruedWAD), 0, "mirror: lt accumulator reset on premium payment");
            assertEq(uint256(post.lastPremiumPaymentTimestamp), block.timestamp, "mirror: premium payment stamped");
        } else {
            assertEq(uint256(post.twJTYieldShareAccruedWAD), in_.jtTwYieldShareAccrual, "mirror: jt accumulator persists unpaid");
            assertEq(uint256(post.twLTYieldShareAccruedWAD), in_.ltTwYieldShareAccrual, "mirror: lt accumulator persists unpaid");
            uint256 expectedStamp = _pre.lastYieldShareAccrualTimestamp == 0 ? block.timestamp : _pre.lastPremiumPaymentTimestamp;
            assertEq(uint256(post.lastPremiumPaymentTimestamp), expectedStamp, "mirror: premium payment stamp unchanged");
        }

        // Post-commit view commit the unchanged LT mark, then the committed lastLTRawNAV
        // must equal the mirror's pass-through and the mirror's liquidity utilization is the RTM.liquidityUtilization view
        kernel.doCommit(_pre.lastLTRawNAV);
        assertEq(toUint256(accountant.getState().lastLTRawNAV), m.ltRawNAV, "mirror: committed lt raw NAV pass-through");
        assertEq(m.liquidityUtilizationWAD, RoycoTestMath.computeLiquidityUtilization(m.stEffectiveNAV, in_.minLiquidityWAD, in_.ltRawNAVNew), "mirror: post-commit liquidity utilization");
    }

    /// @dev Independent coverage utilization math: ceil(stRawNAV * 0.1e18 / jtEffectiveNAV) with the default minimum coverage and no co-investment
    function _expectedCoverageUtilization(uint256 _stRaw, uint256 _jtEff) internal pure returns (uint256) {
        uint256 requiredCoverageNAV = _stRaw * uint256(DEFAULT_MIN_COVERAGE_WAD);
        if (requiredCoverageNAV == 0) return 0;
        if (_jtEff == 0) return type(uint256).max;
        return (requiredCoverageNAV + _jtEff - 1) / _jtEff;
    }

    /*----------------------------------------------------------------------
                SYNC SCENARIOS — IL == 0, PERPETUAL (zero dust tolerance)
    ----------------------------------------------------------------------*/

    /**
     * Sync scenario (ST loss, JT loss, IL 0): symmetric claims route each delta to its own tranche
     * Derivation: jtEffectiveNAV = 200e18 - 20e18 = 180e18, then coverage = min(50e18, 180e18) = 50e18 fully absorbs the
     * ST loss: jtEffectiveNAV = 130e18, il = 50e18, stEffectiveNAV unchanged. il > 0 dust forces FIXED_TERM entry (end = now + duration)
     * and zeroes all fees (none accrued anyway)
     */
    function test_Sync_NoIL_STLossJTLoss() public {
        _seedNoIL();
        _runSyncVector(
            950e18,
            180e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 130e18,
                il: 50e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (ST loss, JT flat, IL 0)
     * Derivation: coverage = min(50e18, 200e18) = 50e18, jtEffectiveNAV = 150e18, il = 50e18, stEffectiveNAV unchanged, FIXED_TERM entry
     */
    function test_Sync_NoIL_STLossJTFlat() public {
        _seedNoIL();
        _runSyncVector(
            950e18,
            200e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 150e18,
                il: 50e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (ST loss, JT gain, IL 0): the fee recomputation arm where coverage exceeds the JT gain
     * Derivation: jt gain 20e18 books jtFee = floor(20e18 * 0.1) = 2e18 and jtEffectiveNAV = 220e18, then coverage
     * = min(50e18, 220e18) = 50e18 recomputes jtNetGain = satSub(20e18 - 50e18) = 0 <= dust so jtFee = 0,
     * jtEffectiveNAV = 170e18, il = 50e18, stEffectiveNAV unchanged, FIXED_TERM entry (fees zeroed regardless)
     */
    function test_Sync_NoIL_STLossJTGain() public {
        _seedNoIL();
        _runSyncVector(
            950e18,
            220e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 170e18,
                il: 50e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (ST flat, JT loss, IL 0): a pure JT loss reduces jt effective NAV exactly with no coverage or IL move
     * Derivation: jtEffectiveNAV = 200e18 - 20e18 = 180e18, market stays PERPETUAL
     */
    function test_Sync_NoIL_STFlatJTLoss() public {
        _seedNoIL();
        _runSyncVector(
            1000e18,
            180e18,
            ExpectedSync({ stEffectiveNAV: 1000e18, jtEffectiveNAV: 180e18, il: 0, ltPrem: 0, stFee: 0, jtFee: 0, ltFee: 0, marketState: MarketState.PERPETUAL, fixedTermEndTimestamp: 0 })
        );
    }

    /// Sync scenario (ST flat, JT flat, IL 0): the no-op sync leaves every field at the checkpoint (coverageUtilization exactly 0.5e18)
    function test_Sync_NoIL_STFlatJTFlat() public {
        _seedNoIL();
        _runSyncVector(
            1000e18,
            200e18,
            ExpectedSync({ stEffectiveNAV: 1000e18, jtEffectiveNAV: 200e18, il: 0, ltPrem: 0, stFee: 0, jtFee: 0, ltFee: 0, marketState: MarketState.PERPETUAL, fixedTermEndTimestamp: 0 })
        );
        // Literal anchor for the independent ceil helper: 1000e18 * 0.1e18 / 200e18 divides exactly to 0.5e18
        assertEq(_expectedCoverageUtilization(1000e18, 200e18), 0.5e18, "anchor: exact-division coverage utilization");
    }

    /**
     * Sync scenario (ST flat, JT gain, IL 0): jt gain above dust takes the JT protocol fee and stays PERPETUAL
     * Derivation: jtNetGain = 20e18 > 0 dust so jtFee = floor(20e18 * 0.1e18 / 1e18) = 2e18, jtEffectiveNAV = 220e18
     */
    function test_Sync_NoIL_STFlatJTGain() public {
        _seedNoIL();
        _runSyncVector(
            1000e18,
            220e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18, jtEffectiveNAV: 220e18, il: 0, ltPrem: 0, stFee: 0, jtFee: 2e18, ltFee: 0, marketState: MarketState.PERPETUAL, fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (ST gain, JT loss, IL 0): instantaneous premiums on the senior gain alongside a junior loss
     * Derivation: jtEffectiveNAV = 180e18 after the 20e18 JT loss. ST gain 50e18 with no IL to recover pays premiums via the
     * instantaneous branch (elapsed forced to 1s, preview rates 0.1e18 / 0.05e18):
     *   jtRiskPremium      = floor(50e18 * 0.1e18 / 1e18)  = 5e18   -> jtEffectiveNAV = 185e18, jt yield-share fee floor(5e18 * 0.1) = 0.5e18
     *   ltLiquidityPremium = floor(50e18 * 0.05e18 / 1e18) = 2.5e18 -> ltFee = floor(2.5e18 * 0.1) = 0.25e18
     *   st residual = 50e18 - 5e18 - 2.5e18 = 42.5e18 -> stFee = floor(42.5e18 * 0.1) = 4.25e18
     *   stEffectiveNAV = 1000e18 + 42.5e18 + 2.5e18 (premium stays a senior claim) = 1045e18
     */
    function test_Sync_NoIL_STGainJTLoss() public {
        _seedNoIL();
        _runSyncVector(
            1050e18,
            180e18,
            ExpectedSync({
                stEffectiveNAV: 1045e18,
                jtEffectiveNAV: 185e18,
                il: 0,
                ltPrem: 2.5e18,
                stFee: 4.25e18,
                jtFee: 0.5e18,
                ltFee: 0.25e18,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (ST gain, JT flat, IL 0)
     * Derivation: identical premium math to the ST-gain/JT-loss scenario on a 50e18 gain, jtEffectiveNAV = 200e18 + 5e18 = 205e18, stEffectiveNAV = 1045e18
     */
    function test_Sync_NoIL_STGainJTFlat() public {
        _seedNoIL();
        _runSyncVector(
            1050e18,
            200e18,
            ExpectedSync({
                stEffectiveNAV: 1045e18,
                jtEffectiveNAV: 205e18,
                il: 0,
                ltPrem: 2.5e18,
                stFee: 4.25e18,
                jtFee: 0.5e18,
                ltFee: 0.25e18,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (ST gain, JT gain, IL 0): the JT fee compounds the net-gain fee and the yield-share fee
     * Derivation: jt gain 20e18 -> jtFee = 2e18, jtEffectiveNAV = 220e18. ST gain 50e18 premium math as the ST-gain/JT-loss scenario:
     * jtRiskPremium 5e18 adds floor(5e18 * 0.1) = 0.5e18 so jtFee = 2.5e18 total and jtEffectiveNAV = 225e18, stEffectiveNAV = 1045e18
     */
    function test_Sync_NoIL_STGainJTGain() public {
        _seedNoIL();
        _runSyncVector(
            1050e18,
            220e18,
            ExpectedSync({
                stEffectiveNAV: 1045e18,
                jtEffectiveNAV: 225e18,
                il: 0,
                ltPrem: 2.5e18,
                stFee: 4.25e18,
                jtFee: 2.5e18,
                ltFee: 0.25e18,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /*----------------------------------------------------------------------
        SYNC SCENARIOS — 0 < IL <= dust, PERPETUAL (dust st 3 + jt 4 = 7, il = 5)
    ----------------------------------------------------------------------*/

    /**
     * Sync scenario (ST loss, JT loss, dust IL): attribution floors the 5 wei senior cross-claim out of the JT delta
     * Derivation: attrST(dJT) = -floor(20e18 * 5 / 200e18) = 0 so dJTEff = -20e18 and dSTEff = -50e18
     * jtEffectiveNAV = 200e18 - 5 - 20e18, coverage = 50e18: jtEffectiveNAV = 130e18 - 5, il = 5 + 50e18, stEffectiveNAV = 1000e18 + 5
     * il > dust 7 forces FIXED_TERM entry
     */
    function test_Sync_DustIL_STLossJTLoss() public {
        _seedDustIL();
        _runSyncVector(
            950e18,
            180e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18 + 5,
                jtEffectiveNAV: 130e18 - 5,
                il: 50e18 + 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (ST loss, JT flat, dust IL)
     * Derivation: coverage = 50e18 on top of the persisted 5 wei il: jtEffectiveNAV = 150e18 - 5, il = 50e18 + 5, FIXED_TERM entry
     */
    function test_Sync_DustIL_STLossJTFlat() public {
        _seedDustIL();
        _runSyncVector(
            950e18,
            200e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18 + 5,
                jtEffectiveNAV: 150e18 - 5,
                il: 50e18 + 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (ST loss, JT gain, dust IL): coverage exceeds the jt gain so the recomputed fee saturates to zero
     * Derivation: jt gain 20e18 > dust 7 books jtFee = 2e18, coverage 50e18 recomputes jtNetGain = satSub(20e18 - 50e18) = 0
     * so jtFee = 0, jtEffectiveNAV = 200e18 - 5 + 20e18 - 50e18 = 170e18 - 5, il = 50e18 + 5, FIXED_TERM entry
     */
    function test_Sync_DustIL_STLossJTGain() public {
        _seedDustIL();
        _runSyncVector(
            950e18,
            220e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18 + 5,
                jtEffectiveNAV: 170e18 - 5,
                il: 50e18 + 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (ST flat, JT loss, dust IL): the dust il persists un-erased through a PERPETUAL sync —
     * a sub-dust senior claim is carried forward, never written off, so a junior loss cannot launder it away
     * Derivation: dJTEff = -20e18 (zero attribution to the 5 wei claim), jtEffectiveNAV = 180e18 - 5, il stays 5 <= dust 7
     */
    function test_Sync_DustIL_STFlatJTLoss() public {
        _seedDustIL();
        _runSyncVector(
            1000e18,
            180e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18 + 5, jtEffectiveNAV: 180e18 - 5, il: 5, ltPrem: 0, stFee: 0, jtFee: 0, ltFee: 0, marketState: MarketState.PERPETUAL, fixedTermEndTimestamp: 0
            })
        );
    }

    /// Sync scenario (ST flat, JT flat, dust IL): the checkpoint is untouched and the 5 wei dust il persists in PERPETUAL
    function test_Sync_DustIL_STFlatJTFlat() public {
        _seedDustIL();
        _runSyncVector(
            1000e18,
            200e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18 + 5, jtEffectiveNAV: 200e18 - 5, il: 5, ltPrem: 0, stFee: 0, jtFee: 0, ltFee: 0, marketState: MarketState.PERPETUAL, fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (ST flat, JT gain, dust IL): the fee is kept in PERPETUAL and the dust il persists
     * Derivation: jtNetGain = 20e18 > dust 7 so jtFee = 2e18, jtEffectiveNAV = 220e18 - 5, il stays 5
     */
    function test_Sync_DustIL_STFlatJTGain() public {
        _seedDustIL();
        _runSyncVector(
            1000e18,
            220e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18 + 5, jtEffectiveNAV: 220e18 - 5, il: 5, ltPrem: 0, stFee: 0, jtFee: 2e18, ltFee: 0, marketState: MarketState.PERPETUAL, fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (ST gain, JT loss, dust IL): dust il recovery first, then awkward premium floors on the 50e18 - 5 residual
     * Derivation: jtEffectiveNAV = 200e18 - 5 - 20e18, recovery = min(50e18, 5) = 5: il = 0, jtEffectiveNAV = 180e18, stGain = 50e18 - 5
     *   jtRiskPremium      = floor((50e18 - 5) * 0.1e18 / 1e18)  = floor(4999999999999999999.5)  = 5e18 - 1
     *   ltLiquidityPremium = floor((50e18 - 5) * 0.05e18 / 1e18) = floor(2499999999999999999.75) = 2.5e18 - 1
     *   jtFee = floor((5e18 - 1) * 0.1)   = 0.5e18 - 1, ltFee = floor((2.5e18 - 1) * 0.1) = 0.25e18 - 1
     *   st residual = (50e18 - 5) - (5e18 - 1) - (2.5e18 - 1) = 42.5e18 - 3 -> stFee = floor((42.5e18 - 3) * 0.1) = 4.25e18 - 1
     *   stEffectiveNAV = (1000e18 + 5) + (42.5e18 - 3) + (2.5e18 - 1) = 1045e18 + 1, jtEffectiveNAV = 180e18 + 5e18 - 1 = 185e18 - 1
     */
    function test_Sync_DustIL_STGainJTLoss() public {
        _seedDustIL();
        _runSyncVector(
            1050e18,
            180e18,
            ExpectedSync({
                stEffectiveNAV: 1045e18 + 1,
                jtEffectiveNAV: 185e18 - 1,
                il: 0,
                ltPrem: 2.5e18 - 1,
                stFee: 4.25e18 - 1,
                jtFee: 0.5e18 - 1,
                ltFee: 0.25e18 - 1,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (ST gain, JT flat, dust IL)
     * Derivation: recovery 5 restores jtEffectiveNAV to 200e18, premium floors as the dust-IL ST-gain/JT-loss scenario, jtEffectiveNAV = 205e18 - 1, stEffectiveNAV = 1045e18 + 1
     */
    function test_Sync_DustIL_STGainJTFlat() public {
        _seedDustIL();
        _runSyncVector(
            1050e18,
            200e18,
            ExpectedSync({
                stEffectiveNAV: 1045e18 + 1,
                jtEffectiveNAV: 205e18 - 1,
                il: 0,
                ltPrem: 2.5e18 - 1,
                stFee: 4.25e18 - 1,
                jtFee: 0.5e18 - 1,
                ltFee: 0.25e18 - 1,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (ST gain, JT gain, dust IL)
     * Derivation: jt gain 20e18 -> fee 2e18, recovery 5 -> jtEffectiveNAV = 220e18, premiums as the dust-IL ST-gain/JT-loss scenario so
     * jtEffectiveNAV = 225e18 - 1, jtFee = 2e18 + (0.5e18 - 1) = 2.5e18 - 1, stEffectiveNAV = 1045e18 + 1
     */
    function test_Sync_DustIL_STGainJTGain() public {
        _seedDustIL();
        _runSyncVector(
            1050e18,
            220e18,
            ExpectedSync({
                stEffectiveNAV: 1045e18 + 1,
                jtEffectiveNAV: 225e18 - 1,
                il: 0,
                ltPrem: 2.5e18 - 1,
                stFee: 4.25e18 - 1,
                jtFee: 2.5e18 - 1,
                ltFee: 0.25e18 - 1,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /*----------------------------------------------------------------------
        SYNC SCENARIOS — IL > dust (cross-claim FIXED_TERM checkpoint)
    ----------------------------------------------------------------------*/

    /**
     * Sync scenario (ST loss, JT loss, large IL): cross-claim attribution splits the JT loss one third to ST
     * Derivation: attrST(dJT) = -floor(20e18 * 100e18 / 300e18) = -6666666666666666666
     *   dSTEff = -50e18 - 6666666666666666666 = -56666666666666666666, dJTEff = -70e18 - dSTEff = -13333333333333333334
     *   jtEffectiveNAV = 200e18 - 13333333333333333334 = 186666666666666666666, coverage = min(56.66e18, jtEffectiveNAV) fully covers:
     *   jtEffectiveNAV = 130e18, il = 100e18 + 56666666666666666666, stEffectiveNAV = 1000e18, market stays FIXED_TERM (original end kept)
     */
    function test_Sync_LargeIL_STLossJTLoss() public {
        _seedLargeIL();
        _runSyncVector(
            850e18,
            280e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 130e18,
                il: 156_666_666_666_666_666_666,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (ST loss, JT flat, large IL)
     * Derivation: full ST claim on its own raw NAV so dSTEff = -50e18, coverage 50e18: jtEffectiveNAV = 150e18, il = 150e18
     */
    function test_Sync_LargeIL_STLossJTFlat() public {
        _seedLargeIL();
        _runSyncVector(
            850e18,
            300e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 150e18,
                il: 150e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (ST loss, JT gain, large IL): the cross-claim variant of the coverage-exceeds-gain fee arm
     * Derivation: attrST(dJT) = +6666666666666666666 so dSTEff = -43333333333333333334 and
     *   dJTEff = -30e18 - dSTEff = +13333333333333333334: jtFee = floor(13333333333333333334 * 0.1) = 1333333333333333333
     *   coverage 43333333333333333334 recomputes jtNetGain = satSub to 0 -> jtFee = 0
     *   jtEffectiveNAV = 200e18 + 13333333333333333334 - 43333333333333333334 = 170e18, il = 143333333333333333334, stEffectiveNAV = 1000e18
     */
    function test_Sync_LargeIL_STLossJTGain() public {
        _seedLargeIL();
        _runSyncVector(
            850e18,
            320e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 170e18,
                il: 143_333_333_333_333_333_334,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (ST flat, JT loss, large IL): a pure JT loss still bleeds into ST via its cross-claim and gets covered
     * Derivation: dSTEff = -6666666666666666666, dJTEff = -13333333333333333334
     *   jtEffectiveNAV = 186666666666666666666, coverage = 6666666666666666666: jtEffectiveNAV = 180e18, il = 106666666666666666666
     */
    function test_Sync_LargeIL_STFlatJTLoss() public {
        _seedLargeIL();
        _runSyncVector(
            900e18,
            280e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 180e18,
                il: 106_666_666_666_666_666_666,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /// Sync scenario (ST flat, JT flat, large IL): the FIXED_TERM checkpoint persists unchanged, original end kept, no events
    function test_Sync_LargeIL_STFlatJTFlat() public {
        _seedLargeIL();
        _runSyncVector(
            900e18,
            300e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 200e18,
                il: 100e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (ST flat, JT gain, large IL): ST's attributed share of the JT gain goes to il recovery, jt fee zeroed by FIXED_TERM
     * Derivation: dSTEff = +6666666666666666666, dJTEff = +13333333333333333334 (jtFee 1333333333333333333 pre-zeroing)
     *   recovery = min(6666666666666666666, 100e18): il = 93333333333333333334, jtEffectiveNAV = 200e18 + 13333333333333333334
     *   + 6666666666666666666 = 220e18, stGain = 0 so no premiums, stEffectiveNAV = 1000e18, FIXED_TERM zeroes the jt fee
     */
    function test_Sync_LargeIL_STFlatJTGain() public {
        _seedLargeIL();
        _runSyncVector(
            900e18,
            320e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 220e18,
                il: 93_333_333_333_333_333_334,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (ST gain, JT loss, large IL): the cross-claim ST-gain/JT-loss scenario, gain fully consumed by il recovery
     * Derivation: attrST(dJT) = -6666666666666666666 so dSTEff = 50e18 - 6666666666666666666 = 43333333333333333334
     *   dJTEff = 30e18 - dSTEff = -13333333333333333334: jtEffectiveNAV = 186666666666666666666
     *   recovery = min(43333333333333333334, 100e18) = full gain: il = 56666666666666666666, jtEffectiveNAV = 230e18, stGain = 0
     */
    function test_Sync_LargeIL_STGainJTLoss() public {
        _seedLargeIL();
        _runSyncVector(
            950e18,
            280e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 230e18,
                il: 56_666_666_666_666_666_666,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (ST gain, JT flat, large IL): partial il recovery with no premium (gain < il)
     * Derivation: recovery = min(50e18, 100e18) = 50e18: il = 50e18, jtEffectiveNAV = 250e18, stGain = 0, stEffectiveNAV = 1000e18
     */
    function test_Sync_LargeIL_STGainJTFlat() public {
        _seedLargeIL();
        _runSyncVector(
            950e18,
            300e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 250e18,
                il: 50e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (ST gain, JT gain, large IL): the cross-claim ST-gain/JT-gain scenario, jt fee zeroed by FIXED_TERM
     * Derivation: attrST(dJT) = +6666666666666666666 so dSTEff = 56666666666666666666 and dJTEff = 13333333333333333334
     *   jt gain books fee 1333333333333333333 (zeroed by FIXED_TERM), jtEffectiveNAV = 213333333333333333334
     *   recovery = full 56666666666666666666: il = 43333333333333333334, jtEffectiveNAV = 270e18, stGain = 0, stEffectiveNAV = 1000e18
     */
    function test_Sync_LargeIL_STGainJTGain() public {
        _seedLargeIL();
        _runSyncVector(
            950e18,
            320e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 270e18,
                il: 43_333_333_333_333_333_334,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /*----------------------------------------------------------------------
        SYNC SCENARIOS — IL == 0, FIXED_TERM
    ----------------------------------------------------------------------*/

    /*
     * Checkpoint stRawNAV 1000e18-1, jtRawNAV 100e18, stEffectiveNAV 1000e18, jtEffectiveNAV 100e18-1, il 0, zero dust, FIXED_TERM with
     * end T0+D. Claims: stClaimOnJTRaw = 1 wei, stClaimOnSTRaw = 1000e18-1 (= lastRaw so ST deltas attribute 1:1),
     * and a 20e18 JT delta attributes floor(20e18 * 1 / 100e18) = 0 to ST, so dSTEff = dST and dJTEff = dJT.
     */

    /**
     * Sync scenario (ST loss, JT loss, IL 0, FIXED_TERM): coverage on top of a JT loss tips the small JT buffer past the
     * liquidation threshold, forcing PERPETUAL with full il erasure
     * Derivation: dST = -(50e18-1), dJT = -20e18. jtEffectiveNAV = 100e18-1 - 20e18 = 80e18-1. coverage
     * = min(50e18-1, 80e18-1) = 50e18-1 so jtEffectiveNAV = 30e18, would-be il = 50e18-1, stEffectiveNAV unchanged 1000e18.
     * then coverageUtilization = ceil(950e18 * 0.1e18 / 30e18) = 3166666666666666667 >= liqThreshold 1.1e18 so the FORCED
     * PERPETUAL disjunct fires (the liquidation disjunct): il ERASED (reset event 50e18-1), end deleted.
     * NOTE: the liquidation disjunct governs here — production and the RoycoTestMath mirror both
     * force PERPETUAL instead of keeping the term
     */
    function test_Sync_FixedTermNoIL_STLossJTLoss() public {
        _seedNoILFixedTerm();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(toNAVUnits(uint256(50e18 - 1)));
        _runSyncVector(
            950e18,
            80e18,
            ExpectedSync({ stEffectiveNAV: 1000e18, jtEffectiveNAV: 30e18, il: 0, ltPrem: 0, stFee: 0, jtFee: 0, ltFee: 0, marketState: MarketState.PERPETUAL, fixedTermEndTimestamp: 0 })
        );
    }

    /**
     * Sync scenario (ST loss, JT flat, IL 0, FIXED_TERM): liquidation-forced PERPETUAL, as in the ST-loss/JT-loss scenario
     * Derivation: coverage = min(50e18-1, 100e18-1) = 50e18-1 so jtEffectiveNAV = 50e18, would-be il = 50e18-1, stEffectiveNAV
     * unchanged. then coverageUtilization = ceil(950e18 * 0.1e18 / 50e18) = 1.9e18 >= 1.1e18 forces PERPETUAL, il erased
     */
    function test_Sync_FixedTermNoIL_STLossJTFlat() public {
        _seedNoILFixedTerm();
        _runSyncVector(
            950e18,
            100e18,
            ExpectedSync({ stEffectiveNAV: 1000e18, jtEffectiveNAV: 50e18, il: 0, ltPrem: 0, stFee: 0, jtFee: 0, ltFee: 0, marketState: MarketState.PERPETUAL, fixedTermEndTimestamp: 0 })
        );
    }

    /**
     * Sync scenario (ST loss, JT gain, IL 0, FIXED_TERM): fee-recompute arm plus the liquidation-forced PERPETUAL
     * (the liquidation disjunct governs, as in the ST-loss/JT-loss scenario)
     * Derivation: the jt gain 20e18 books provisional jtFee 2e18, jtEffectiveNAV = 120e18-1. coverage = 50e18-1 recomputes
     * jtNetGain = satSub(20e18 - (50e18-1)) = 0 <= dust so jtFee = 0, jtEffectiveNAV = 70e18, would-be il = 50e18-1.
     * then coverageUtilization = ceil(950e18 * 0.1e18 / 70e18) = 1357142857142857143 >= 1.1e18 forces PERPETUAL, il erased
     */
    function test_Sync_FixedTermNoIL_STLossJTGain() public {
        _seedNoILFixedTerm();
        _runSyncVector(
            950e18,
            120e18,
            ExpectedSync({ stEffectiveNAV: 1000e18, jtEffectiveNAV: 70e18, il: 0, ltPrem: 0, stFee: 0, jtFee: 0, ltFee: 0, marketState: MarketState.PERPETUAL, fixedTermEndTimestamp: 0 })
        );
    }

    /**
     * Sync scenario (ST flat, JT loss, IL 0, FIXED_TERM): liquidation-forced PERPETUAL, not the il == 0
     * branch — the forced disjunct is evaluated first and lands an identical outcome
     * Derivation: dJT = -20e18 attributes 0 to the 1-wei cross-claim so jtEffectiveNAV = 80e18-1, il stays 0. The state resolution evaluates
     * the forced disjuncts first (RoycoDayAccountant): coverageUtilization = ceil((1000e18-1) * 0.1e18 / (80e18-1)) = 1.25e18 + 1 wei
     * >= 1.1e18, so PERPETUAL is FORCED with IL erasure before the il == 0 branch is ever reached, the
     * erased il is already 0 (so no reset event), end deleted
     */
    function test_Sync_FixedTermNoIL_STFlatJTLoss() public {
        _seedNoILFixedTerm();
        _runSyncVector(
            1000e18 - 1,
            80e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18, jtEffectiveNAV: 80e18 - 1, il: 0, ltPrem: 0, stFee: 0, jtFee: 0, ltFee: 0, marketState: MarketState.PERPETUAL, fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (ST flat, JT flat, IL 0, FIXED_TERM): the pure state-machine scenario — a flat sync exits the term
     * Derivation: zero deltas so no sync legs run, initial FIXED_TERM with il == 0 lands PERPETUAL
     * (RoycoDayAccountant), end deleted, FixedTermEnded emitted, and NO il-reset event (nothing was erased)
     */
    function test_Sync_FixedTermNoIL_STFlatJTFlat() public {
        _seedNoILFixedTerm();
        vm.recordLogs();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        _runSyncVector(
            1000e18 - 1,
            100e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18, jtEffectiveNAV: 100e18 - 1, il: 0, ltPrem: 0, stFee: 0, jtFee: 0, ltFee: 0, marketState: MarketState.PERPETUAL, fixedTermEndTimestamp: 0
            })
        );
        assertEq(
            _countAccountantLogs(vm.getRecordedLogs(), IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset.selector),
            0,
            "flat term exit erases nothing"
        );
    }

    /**
     * Sync scenario (ST flat, JT gain, IL 0, FIXED_TERM): the JT net-gain fee SURVIVES the term exit
     * Derivation: jtNetGain 20e18 > dust 0 books jtFee 2e18, jtEffectiveNAV = 120e18-1. il stays 0 so the market exits to
     * PERPETUAL, whose branch does NOT zero fees — pins that fee zeroing is a property of FIXED_TERM-committing
     * syncs only
     */
    function test_Sync_FixedTermNoIL_STFlatJTGain() public {
        _seedNoILFixedTerm();
        _runSyncVector(
            1000e18 - 1,
            120e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18, jtEffectiveNAV: 120e18 - 1, il: 0, ltPrem: 0, stFee: 0, jtFee: 2e18, ltFee: 0, marketState: MarketState.PERPETUAL, fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (ST gain, JT loss, IL 0, FIXED_TERM): a +1 wei gain floor rides through the premium math intact
     * Derivation: dST = +(50e18+1) so stGain = 50e18+1 (no il to recover). Instantaneous premiums:
     *   jtRiskPremium = floor((50e18+1) * 0.1e18 / 1e18) = 5e18, ltLiquidityPremium = floor((50e18+1) * 0.05) = 2.5e18
     *   jtFee = floor(5e18 * 0.1) = 0.5e18, ltFee = 0.25e18, residual = 42.5e18+1, stFee = floor((42.5e18+1) * 0.1) = 4.25e18
     *   stEffectiveNAV = 1000e18 + (42.5e18+1) + 2.5e18 = 1045e18+1, jtEffectiveNAV = (100e18-1) - 20e18 + 5e18 = 85e18-1
     * Conservation: 1050e18 + 80e18 == (1045e18+1) + (85e18-1). il 0 exits to PERPETUAL with premiums and fees intact
     */
    function test_Sync_FixedTermNoIL_STGainJTLoss() public {
        _seedNoILFixedTerm();
        _runSyncVector(
            1050e18,
            80e18,
            ExpectedSync({
                stEffectiveNAV: 1045e18 + 1,
                jtEffectiveNAV: 85e18 - 1,
                il: 0,
                ltPrem: 2.5e18,
                stFee: 4.25e18,
                jtFee: 0.5e18,
                ltFee: 0.25e18,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (ST gain, JT flat, IL 0, FIXED_TERM)
     * Derivation: identical premium math to the ST-gain/JT-loss scenario, jtEffectiveNAV = (100e18-1) + 5e18 = 105e18-1, stEffectiveNAV = 1045e18+1
     */
    function test_Sync_FixedTermNoIL_STGainJTFlat() public {
        _seedNoILFixedTerm();
        _runSyncVector(
            1050e18,
            100e18,
            ExpectedSync({
                stEffectiveNAV: 1045e18 + 1,
                jtEffectiveNAV: 105e18 - 1,
                il: 0,
                ltPrem: 2.5e18,
                stFee: 4.25e18,
                jtFee: 0.5e18,
                ltFee: 0.25e18,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (ST gain, JT gain, IL 0, FIXED_TERM): both JT fee parts accrue and survive the term exit
     * Derivation: the jt gain 20e18 books jtFee 2e18 (jtEffectiveNAV 120e18-1), premium math as the ST-gain/JT-loss scenario adds 0.5e18 so
     * jtFee = 2.5e18 total, jtEffectiveNAV = 125e18-1, stEffectiveNAV = 1045e18+1. Premiums imply PERPETUAL
     */
    function test_Sync_FixedTermNoIL_STGainJTGain() public {
        _seedNoILFixedTerm();
        _runSyncVector(
            1050e18,
            120e18,
            ExpectedSync({
                stEffectiveNAV: 1045e18 + 1,
                jtEffectiveNAV: 125e18 - 1,
                il: 0,
                ltPrem: 2.5e18,
                stFee: 4.25e18,
                jtFee: 2.5e18,
                ltFee: 0.25e18,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /*----------------------------------------------------------------------
        SYNC SCENARIOS — 0 < IL <= dust, FIXED_TERM
    ----------------------------------------------------------------------*/

    /*
     * Checkpoint stRawNAV 1000e18-5, jtRawNAV 200e18, stEffectiveNAV 1000e18, jtEffectiveNAV 200e18-5, il 5, dust (st 3, jt 4, effective
     * 7), FIXED_TERM with end T0+D. Claims: stClaimOnJTRaw = 5, stClaimOnSTRaw = 1000e18-5 (= lastRaw so ST
     * deltas attribute 1:1), and a 20e18 JT delta attributes floor(20e18 * 5 / 200e18) = 0 to ST.
     */

    /**
     * Sync scenario (ST loss, JT loss, dust IL, FIXED_TERM): staging offsets cancel to round outputs
     * Derivation: dST = -(50e18-5), dJT = -20e18. jtEffectiveNAV = 180e18-5. coverage = 50e18-5 so
     * jtEffectiveNAV = 130e18, il = 5 + (50e18-5) = 50e18, stEffectiveNAV unchanged. il 50e18 > dust 7: stays FIXED_TERM, end kept
     */
    function test_Sync_FixedTermDustIL_STLossJTLoss() public {
        _seedDustILFixedTerm();
        _runSyncVector(
            950e18,
            180e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 130e18,
                il: 50e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (ST loss, JT flat, dust IL, FIXED_TERM)
     * Derivation: coverage = 50e18-5 so jtEffectiveNAV = (200e18-5) - (50e18-5) = 150e18, il = 50e18, stEffectiveNAV unchanged
     */
    function test_Sync_FixedTermDustIL_STLossJTFlat() public {
        _seedDustILFixedTerm();
        _runSyncVector(
            950e18,
            200e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 150e18,
                il: 50e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (ST loss, JT gain, dust IL, FIXED_TERM): fee recompute saturates to zero inside the sticky term
     * Derivation: the jt gain 20e18 > dust 7 books jtFee 2e18 (jtEffectiveNAV 220e18-5), coverage 50e18-5 recomputes
     * jtNetGain = satSub(20e18 - (50e18-5)) = 0 so jtFee = 0, jtEffectiveNAV = 170e18, il = 50e18
     */
    function test_Sync_FixedTermDustIL_STLossJTGain() public {
        _seedDustILFixedTerm();
        _runSyncVector(
            950e18,
            220e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 170e18,
                il: 50e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (ST flat, JT loss, dust IL, FIXED_TERM): dust il sticks and the term persists through a JT loss
     * Derivation: dJTEff = -20e18 (zero attribution to the 5-wei claim) so jtEffectiveNAV = 180e18-5, il stays 5 in
     * (0, dust 7] with initial FIXED_TERM: sticky branch keeps the term and the original end (RoycoDayAccountant)
     */
    function test_Sync_FixedTermDustIL_STFlatJTLoss() public {
        _seedDustILFixedTerm();
        _runSyncVector(
            1000e18 - 5,
            180e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 180e18 - 5,
                il: 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (ST flat, JT flat, dust IL, FIXED_TERM): the pure dust-IL stickiness scenario
     * Derivation: zero deltas, il 5 in (0, 7] with initial FIXED_TERM stays FIXED_TERM with the ORIGINAL end,
     * all fee and premium fields zero (nothing accrued). Pins RoycoDayAccountant in isolation
     */
    function test_Sync_FixedTermDustIL_STFlatJTFlat() public {
        _seedDustILFixedTerm();
        _runSyncVector(
            1000e18 - 5,
            200e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 200e18 - 5,
                il: 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (ST flat, JT gain, dust IL, FIXED_TERM): the sticky branch zeroes a LIVE jt fee — the only live arm
     * of the FIXED_TERM fee zeroing
     * Derivation: jtNetGain 20e18 > dust 7 books provisional jtFee 2e18, no ST move so il stays 5 and the
     * sticky-dust branch ZEROES the fee (RoycoDayAccountant). jtEffectiveNAV = 220e18-5 (the gain NAV is kept, only the fee drops)
     */
    function test_Sync_FixedTermDustIL_STFlatJTGain() public {
        _seedDustILFixedTerm();
        _runSyncVector(
            1000e18 - 5,
            220e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 220e18 - 5,
                il: 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (ST gain, JT loss, dust IL, FIXED_TERM): recovery-to-zero then premiums, exiting the term
     * Derivation: dST = +(50e18+5). jtEffectiveNAV = 180e18-5. recovery: rec = min(50e18+5, 5) = 5 so il = 0,
     * jtEffectiveNAV = 180e18, stGain = 50e18 exactly (offsets cancel). Premiums and fees identical to the no-IL ST-gain/JT-loss scenario:
     * jtPrem 5e18, ltPrem 2.5e18, jtFee 0.5e18, ltFee 0.25e18, stFee 4.25e18, stEffectiveNAV = 1045e18, jtEffectiveNAV = 185e18.
     * Conservation: 1050e18 + 180e18 == 1045e18 + 185e18. il 0 with initial FIXED_TERM: PERPETUAL, end deleted
     */
    function test_Sync_FixedTermDustIL_STGainJTLoss() public {
        _seedDustILFixedTerm();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        _runSyncVector(
            1050e18,
            180e18,
            ExpectedSync({
                stEffectiveNAV: 1045e18,
                jtEffectiveNAV: 185e18,
                il: 0,
                ltPrem: 2.5e18,
                stFee: 4.25e18,
                jtFee: 0.5e18,
                ltFee: 0.25e18,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (ST gain, JT flat, dust IL, FIXED_TERM)
     * Derivation: rec 5 restores jtEffectiveNAV to 200e18, then jtPrem 5e18 lands jtEffectiveNAV = 205e18, stEffectiveNAV = 1045e18
     */
    function test_Sync_FixedTermDustIL_STGainJTFlat() public {
        _seedDustILFixedTerm();
        _runSyncVector(
            1050e18,
            200e18,
            ExpectedSync({
                stEffectiveNAV: 1045e18,
                jtEffectiveNAV: 205e18,
                il: 0,
                ltPrem: 2.5e18,
                stFee: 4.25e18,
                jtFee: 0.5e18,
                ltFee: 0.25e18,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (ST gain, JT gain, dust IL, FIXED_TERM): both JT fee parts with recovery, exiting the term
     * Derivation: the jt gain 20e18 > 7 books jtFee 2e18 (jtEffectiveNAV 220e18-5), rec 5 lands 220e18, jtPrem 5e18 adds
     * 0.5e18 fee so jtFee = 2.5e18, jtEffectiveNAV = 225e18, stEffectiveNAV = 1045e18, PERPETUAL exit
     */
    function test_Sync_FixedTermDustIL_STGainJTGain() public {
        _seedDustILFixedTerm();
        _runSyncVector(
            1050e18,
            220e18,
            ExpectedSync({
                stEffectiveNAV: 1045e18,
                jtEffectiveNAV: 225e18,
                il: 0,
                ltPrem: 2.5e18,
                stFee: 4.25e18,
                jtFee: 2.5e18,
                ltFee: 0.25e18,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /*----------------------------------------------------------------------
        SYNC SCENARIOS — IL > dust, PERPETUAL (re-classified by the dust shrink)
    ----------------------------------------------------------------------*/

    /*
     * The dust-IL perpetual checkpoint (1000e18 / 200e18 / 1000e18+5 / 200e18-5, il 5, PERPETUAL) with both dust tolerances
     * shrunk to 0 by the setters, so the SAME persisted il 5 now EXCEEDS the effective dust. Claims and
     * attribution identical to the dust-IL scenarios (dSTEff = dST, dJTEff = dJT). Fee dust gates now trigger at > 0 instead of
     * > 7 — same fee outcomes at these magnitudes.
     */

    /**
     * Sync scenario (ST loss, JT loss, IL > dust, PERPETUAL)
     * Derivation: as in the dust-IL ST-loss/JT-loss scenario — jtEffectiveNAV = 200e18-5 - 20e18, coverage 50e18: jtEffectiveNAV = 130e18-5, il = 50e18+5,
     * stEffectiveNAV = 1000e18+5, FIXED_TERM entry (end = now + duration)
     */
    function test_Sync_ShrunkDustIL_STLossJTLoss() public {
        _seedShrunkDustIL();
        _runSyncVector(
            950e18,
            180e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18 + 5,
                jtEffectiveNAV: 130e18 - 5,
                il: 50e18 + 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (ST loss, JT flat, IL > dust, PERPETUAL)
     * Derivation: coverage 50e18 on top of the persisted il 5: jtEffectiveNAV = 150e18-5, il = 50e18+5, FIXED_TERM entry
     */
    function test_Sync_ShrunkDustIL_STLossJTFlat() public {
        _seedShrunkDustIL();
        _runSyncVector(
            950e18,
            200e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18 + 5,
                jtEffectiveNAV: 150e18 - 5,
                il: 50e18 + 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (ST loss, JT gain, IL > dust, PERPETUAL): fee recompute saturates to zero on the FIXED_TERM entry
     * Derivation: the jt gain 20e18 > dust 0 books jtFee 2e18, coverage 50e18 recomputes it to 0,
     * jtEffectiveNAV = 170e18-5, il = 50e18+5, FIXED_TERM entry
     */
    function test_Sync_ShrunkDustIL_STLossJTGain() public {
        _seedShrunkDustIL();
        _runSyncVector(
            950e18,
            220e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18 + 5,
                jtEffectiveNAV: 170e18 - 5,
                il: 50e18 + 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (ST flat, JT loss, IL > dust, PERPETUAL): the re-classified il 5 tips the market into FIXED_TERM
     * Derivation: jtEffectiveNAV = 180e18-5, il stays 5 which now EXCEEDS dust 0, so the else-FIXED_TERM branch fires
     * from PERPETUAL: end = now + duration (contrast the dust-IL perpetual scenario, where the same il 5 persisted)
     */
    function test_Sync_ShrunkDustIL_STFlatJTLoss() public {
        _seedShrunkDustIL();
        _runSyncVector(
            1000e18,
            180e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18 + 5,
                jtEffectiveNAV: 180e18 - 5,
                il: 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (ST flat, JT flat, IL > dust, PERPETUAL): the regime's distinctive scenario — a FLAT sync flips the state
     * Derivation: zero deltas, post-sync il 5 > dust 0 lands the else-FIXED_TERM branch, entering FROM
     * PERPETUAL so end = now + duration and FixedTermCommenced is emitted (RoycoDayAccountant). The market flips on NO
     * PnL, purely because the dust setters re-classified the persisted il
     */
    function test_Sync_ShrunkDustIL_STFlatJTFlat() public {
        _seedShrunkDustIL();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermCommenced(uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS));
        _runSyncVector(
            1000e18,
            200e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18 + 5,
                jtEffectiveNAV: 200e18 - 5,
                il: 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (ST flat, JT gain, IL > dust, PERPETUAL): the FIXED_TERM entry zeroes a live jt fee
     * Derivation: jtNetGain 20e18 > dust 0 books provisional jtFee 2e18, il stays 5 > 0 so the else-FIXED_TERM
     * branch zeroes it on entry. jtEffectiveNAV = 220e18-5 (gain NAV kept, fee dropped)
     */
    function test_Sync_ShrunkDustIL_STFlatJTGain() public {
        _seedShrunkDustIL();
        _runSyncVector(
            1000e18,
            220e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18 + 5,
                jtEffectiveNAV: 220e18 - 5,
                il: 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (ST gain, JT loss, IL > dust, PERPETUAL): recovery then the dust-IL-identical awkward premium floors
     * Derivation: numbers match the dust-IL ST-gain/JT-loss scenario exactly — the dust change is invisible since stGain 50e18-5 > 7 > 0:
     * rec 5 (il 0, jtEffectiveNAV 180e18), jtPrem = floor((50e18-5) * 0.1) = 5e18-1, ltPrem = 2.5e18-1,
     * jtFee = 0.5e18-1, ltFee = 0.25e18-1, residual 42.5e18-3, stFee = 4.25e18-1,
     * stEffectiveNAV = 1045e18+1, jtEffectiveNAV = 185e18-1, PERPETUAL
     */
    function test_Sync_ShrunkDustIL_STGainJTLoss() public {
        _seedShrunkDustIL();
        _runSyncVector(
            1050e18,
            180e18,
            ExpectedSync({
                stEffectiveNAV: 1045e18 + 1,
                jtEffectiveNAV: 185e18 - 1,
                il: 0,
                ltPrem: 2.5e18 - 1,
                stFee: 4.25e18 - 1,
                jtFee: 0.5e18 - 1,
                ltFee: 0.25e18 - 1,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (ST gain, JT flat, IL > dust, PERPETUAL)
     * Derivation: as in the dust-IL ST-gain/JT-flat scenario — rec 5 restores jtEffectiveNAV to 200e18, premiums as the shrunk-dust ST-gain/JT-loss scenario, jtEffectiveNAV = 205e18-1, stEffectiveNAV = 1045e18+1
     */
    function test_Sync_ShrunkDustIL_STGainJTFlat() public {
        _seedShrunkDustIL();
        _runSyncVector(
            1050e18,
            200e18,
            ExpectedSync({
                stEffectiveNAV: 1045e18 + 1,
                jtEffectiveNAV: 205e18 - 1,
                il: 0,
                ltPrem: 2.5e18 - 1,
                stFee: 4.25e18 - 1,
                jtFee: 0.5e18 - 1,
                ltFee: 0.25e18 - 1,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (ST gain, JT gain, IL > dust, PERPETUAL)
     * Derivation: as in the dust-IL ST-gain/JT-gain scenario — jt gain fee 2e18 plus the premium fee 0.5e18-1 so jtFee = 2.5e18-1,
     * jtEffectiveNAV = 225e18-1, stEffectiveNAV = 1045e18+1, PERPETUAL
     */
    function test_Sync_ShrunkDustIL_STGainJTGain() public {
        _seedShrunkDustIL();
        _runSyncVector(
            1050e18,
            220e18,
            ExpectedSync({
                stEffectiveNAV: 1045e18 + 1,
                jtEffectiveNAV: 225e18 - 1,
                il: 0,
                ltPrem: 2.5e18 - 1,
                stFee: 4.25e18 - 1,
                jtFee: 2.5e18 - 1,
                ltFee: 0.25e18 - 1,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /*----------------------------------------------------------------------
        AUXILIARY SYNC SCENARIOS — exhaustion, recovery boundaries, premium branches
    ----------------------------------------------------------------------*/

    /**
     * Sync scenario (loss past JT exhaustion with an uncovered residual + wipeout erasure): from the flat no-IL checkpoint,
     * sync (700e18, 200e18)
     * Derivation: stLoss 300e18, coverage = min(300e18, 200e18) = 200e18 so jtEffectiveNAV = 0, would-be il 200e18,
     * residual 100e18 hits senior: stEffectiveNAV = 900e18. coverageUtilization = uint256 max (jtEffectiveNAV == 0 against a positive
     * requirement), and the wipeout disjunct (jtEffectiveNAV == 0 with stEffectiveNAV > 0) forces PERPETUAL with the full il
     * ERASED (reset event 200e18), end 0. Conservation: 700e18 + 200e18 == 900e18 + 0.
     * Pins the pipeline lemma: an uncovered loss implies wipeout and can never commit FIXED_TERM
     */
    function test_Sync_UncoveredResidualLossWipeoutForcesPerpetual() public {
        _seedNoIL();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(toNAVUnits(uint256(200e18)));
        _runSyncVector(
            700e18,
            200e18,
            ExpectedSync({ stEffectiveNAV: 900e18, jtEffectiveNAV: 0, il: 0, ltPrem: 0, stFee: 0, jtFee: 0, ltFee: 0, marketState: MarketState.PERPETUAL, fixedTermEndTimestamp: 0 })
        );
    }

    /**
     * Sync scenario (exhaustion exactly at the boundary): from the flat no-IL checkpoint, sync (800e18, 200e18)
     * Derivation: stLoss 200e18 == jtEffectiveNAV so coverage = 200e18, jtEffectiveNAV = 0, residual 0, stEffectiveNAV stays 1000e18,
     * would-be il 200e18 erased by the wipeout disjunct, PERPETUAL, end 0. Distinguishes "fully covered but
     * buffer emptied" (stEffectiveNAV intact) from the uncovered-residual scenario
     */
    function test_Sync_ExhaustionAtExactBoundaryFullyCoveredWipeout() public {
        _seedNoIL();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(toNAVUnits(uint256(200e18)));
        _runSyncVector(
            800e18,
            200e18,
            ExpectedSync({ stEffectiveNAV: 1000e18, jtEffectiveNAV: 0, il: 0, ltPrem: 0, stFee: 0, jtFee: 0, ltFee: 0, marketState: MarketState.PERPETUAL, fixedTermEndTimestamp: 0 })
        );
    }

    /**
     * Sync scenario (gain exactly == il, the recovery boundary with no premiums): from the large-IL fixed-term checkpoint,
     * sync (1000e18, 300e18)
     * Derivation: dST = +100e18, rec = min(100e18, il 100e18) = 100e18 so il = 0, jtEffectiveNAV = 300e18, stGain = 0
     * and the premium block is SKIPPED (premiumsPaid false, accumulators NOT reset — asserted by the runner's
     * premiumsPaid side-effect check). il 0 with initial FIXED_TERM: PERPETUAL, end 0, FixedTermEnded
     */
    function test_Sync_GainExactlyEqualToILRecoveryBoundary() public {
        _seedLargeIL();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        _runSyncVector(
            1000e18,
            300e18,
            ExpectedSync({ stEffectiveNAV: 1000e18, jtEffectiveNAV: 300e18, il: 0, ltPrem: 0, stFee: 0, jtFee: 0, ltFee: 0, marketState: MarketState.PERPETUAL, fixedTermEndTimestamp: 0 })
        );
    }

    /**
     * Sync scenario (gain == il + 1 wei: 1-wei premium floors with premiumsPaid true): from the large-IL fixed-term checkpoint,
     * sync (1000e18 + 1, 300e18)
     * Derivation: rec = 100e18 leaves stGain = 1. premiumsPaid = (1 > dust 0) = true, yet every floored term floors
     * to zero: jtPrem = floor(1 * 0.1) = 0, ltPrem = 0, stFee = floor(1 * 0.1) = 0. stEffectiveNAV = 1000e18+1,
     * jtEffectiveNAV = 300e18, PERPETUAL. Pins that premiumsPaid true with all-zero premiums and fees still resets the
     * accumulators and stamps lastPremiumPaymentTimestamp (RoycoDayAccountant) — the runner's side-effect check
     * asserts the reset path was taken, and the mirror's premiumsPaid flag is pinned true below
     */
    function test_Sync_GainOneWeiAboveILZeroPremiumsStillPay() public {
        _seedLargeIL();
        IRoycoDayAccountant.RoycoDayAccountantState memory pre = accountant.getState();
        _runSyncVector(
            1000e18 + 1,
            300e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18 + 1, jtEffectiveNAV: 300e18, il: 0, ltPrem: 0, stFee: 0, jtFee: 0, ltFee: 0, marketState: MarketState.PERPETUAL, fixedTermEndTimestamp: 0
            })
        );
        // Pin the mirror's dust-gate outcome explicitly: the 1-wei gain clears the zero dust tolerance
        RoycoTestMath.SyncOutputs memory m = RoycoTestMath.syncTrancheAccounting(_buildSyncInputs(pre, 1000e18 + 1, 300e18));
        assertTrue(m.premiumsPaid, "one-wei gain above zero dust pays premiums");
    }

    /**
     * Sync scenario (time-weighted twin of the instantaneous gain sync): flat no-IL seed, mutating rates jt 0.1e18 / lt 0.05e18, warp +1 day, sync
     * (1050e18, 200e18) — identical outputs to the instantaneous ST-gain/JT-flat scenario through the OTHER premium branch (real elapsed)
     * Derivation: accrual twJT = 0.1e18 * 86400 = 8640e18 and twLT = 0.05e18 * 86400 = 4320e18 (both events
     * asserted), elapsed = 86400 so jtPrem = floor(50e18 * 8640e18 / (86400 * 1e18)) = 5e18 and ltPrem = 2.5e18.
     * Fees as the instantaneous ST-gain/JT-flat scenario: jtFee 0.5e18, ltFee 0.25e18, stFee 4.25e18, stEffectiveNAV 1045e18, jtEffectiveNAV 205e18, PERPETUAL.
     * The runner's premiumsPaid check asserts both accumulators reset and the payment stamped at the warped time
     */
    function test_Sync_TimeWeightedPremiumBranchMatchesInstantaneousGainSync() public {
        _seedNoIL();
        jtYDM.setYieldShareReturn(0.1e18);
        ltYDM.setYieldShareReturn(0.05e18);
        vm.warp(block.timestamp + 86_400);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheYieldShareAccrued(0.1e18, 8640e18);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.LiquidityTrancheYieldShareAccrued(0.05e18, 4320e18);
        _runSyncVector(
            1050e18,
            200e18,
            ExpectedSync({
                stEffectiveNAV: 1045e18,
                jtEffectiveNAV: 205e18,
                il: 0,
                ltPrem: 2.5e18,
                stFee: 4.25e18,
                jtFee: 0.5e18,
                ltFee: 0.25e18,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (two-window time-weighted averaging + the accrual-side cap): flat no-IL seed, 12h at rate jt 0.1e18 accrued
     * by a flat sync (which pays nothing and does NOT reset), then 12h at a hostile jt rate 0.5e18 CAPPED to
     * maxJT 0.2e18 at accrual (RoycoDayAccountant), then sync (1050e18, 200e18)
     * Derivation: twJT = 0.1e18 * 43200 + 0.2e18 * 43200 = 12960e18 over elapsed 86400 since the last payment
     * (the flat sync never stamps one), so jtPrem = floor(50e18 * 12960e18 / (86400 * 1e18)) = floor(50e18 * 0.15)
     * = 7.5e18. twLT = 0.05e18 * 86400 = 4320e18 so ltPrem = 2.5e18. jtFee = 0.75e18, ltFee = 0.25e18,
     * residual = 40e18 so stFee = 4e18, stEffectiveNAV = 1000e18 + 40e18 + 2.5e18 = 1042.5e18, jtEffectiveNAV = 207.5e18.
     * Conservation: 1050e18 + 200e18 == 1042.5e18 + 207.5e18. Pins the sum(share * dt) / elapsed averaging
     */
    function test_Sync_TwoWindowTimeWeightedAveragingWithAccrualCap() public {
        _seedNoIL();
        // Mutating and preview rates aligned so the preview-path accrual matches execution byte-for-byte
        jtYDM.setRates(0.1e18);
        ltYDM.setRates(0.05e18);
        // t0 read through an external call: a plain block.timestamp local is rematerialized at use-site by
        // via-ir and would read the warped time (the seed stamped this to the current block's timestamp)
        uint256 t0 = accountant.getState().lastPremiumPaymentTimestamp;
        assertEq(t0, block.timestamp, "seed stamped the premium payment clock this block");
        vm.warp(t0 + 43_200);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        // The flat sync accrues window 1 without paying or resetting: the payment window keeps running from t0
        IRoycoDayAccountant.RoycoDayAccountantState memory mid = accountant.getState();
        assertEq(uint256(mid.twJTYieldShareAccruedWAD), 0.1e18 * 43_200, "window 1 accrued");
        assertEq(uint256(mid.twLTYieldShareAccruedWAD), 0.05e18 * 43_200, "lt window 1 accrued");
        assertEq(uint256(mid.lastPremiumPaymentTimestamp), t0, "flat sync never stamps a premium payment");
        // Window 2 at a hostile mutating rate, clamped to the 0.2e18 max at accrual
        jtYDM.setRates(0.5e18);
        vm.warp(t0 + 86_400);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheYieldShareAccrued(0.2e18, 12_960e18);
        _runSyncVector(
            1050e18,
            200e18,
            ExpectedSync({
                stEffectiveNAV: 1042.5e18,
                jtEffectiveNAV: 207.5e18,
                il: 0,
                ltPrem: 2.5e18,
                stFee: 4e18,
                jtFee: 0.75e18,
                ltFee: 0.25e18,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /*----------------------------------------------------------------------
                        PNL ATTRIBUTION
    ----------------------------------------------------------------------*/

    /**
     * with a JT cross-claim (jtEffectiveNAV > jtRawNAV from a paid risk premium), a senior raw loss is shared with JT
     * in proportion to its claim on the senior raw NAV
     * Seed (route 3): 1000e18 / 200e18 / 980e18 / 220e18 so jtClaimOnSTRaw = 20e18 and stClaimOnSTRaw = 980e18
     * Derivation for a 100e18 ST raw loss: attrST = -floor(100e18 * 980e18 / 1000e18) = -98e18, residual -2e18 to JT
     *   jtEffectiveNAV = 220e18 - 2e18 = 218e18, coverage = min(98e18, 218e18) = 98e18: jtEffectiveNAV = 120e18, il = 98e18, stEffectiveNAV = 980e18
     */
    function test_Sync_jtCrossClaimSharesSTRawLoss() public {
        _seedState(1000e18, 200e18, 980e18, 220e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(900e18)), toNAVUnits(uint256(200e18)));
        assertEq(toUint256(state.stEffectiveNAV), 980e18, "st keeps its cross-claim NAV under full coverage");
        assertEq(toUint256(state.jtEffectiveNAV), 120e18, "jt bears its attributed share plus the coverage");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 98e18, "il equals coverage applied to st's attributed loss");
        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "covered loss forces fixed term");
    }

    /**
     * with a JT cross-claim, a senior raw gain is shared with JT in proportion to its claim
     * Derivation for a 100e18 ST raw gain: attrST = floor(100e18 * 980e18 / 1000e18) = 98e18, residual +2e18 to JT
     *   jt gain 2e18 -> jtFee = 0.2e18, jtEffectiveNAV = 222e18. ST gain 98e18 pays instantaneous premiums (rates 0.1e18 / 0.05e18):
     *   jtRiskPremium = 9.8e18 (jtFee += 0.98e18 = 1.18e18, jtEffectiveNAV = 231.8e18), ltLiquidityPremium = 4.9e18 (ltFee 0.49e18)
     *   st residual = 98e18 - 9.8e18 - 4.9e18 = 83.3e18 -> stFee = 8.33e18, stEffectiveNAV = 980e18 + 83.3e18 + 4.9e18 = 1068.2e18
     */
    function test_Sync_jtCrossClaimSharesSTRawGain() public {
        _seedState(1000e18, 200e18, 980e18, 220e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        jtYDM.setPreviewYieldShareReturn(0.1e18);
        ltYDM.setPreviewYieldShareReturn(0.05e18);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1100e18)), toNAVUnits(uint256(200e18)));
        assertEq(toUint256(state.stEffectiveNAV), 1068.2e18, "st effective NAV from attributed gain and premium share-mint legs");
        assertEq(toUint256(state.jtEffectiveNAV), 231.8e18, "jt effective NAV from residual gain plus risk premium");
        assertEq(toUint256(state.ltLiquidityPremium), 4.9e18, "lt premium on st's attributed gain only");
        assertEq(toUint256(state.stProtocolFee), 8.33e18, "st fee on the retained residual");
        assertEq(toUint256(state.jtProtocolFee), 1.18e18, "jt fee compounds net-gain and yield-share fees");
        assertEq(toUint256(state.ltProtocolFee), 0.49e18, "lt fee on the liquidity premium");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "gain sync stays perpetual");
    }

    /**
     * lastSTRawNAV == 0 with stEffectiveNAV > 0 routes the entire senior raw delta to ST
     * Seed: 0 / 300e18 / 100e18 / 200e18 with il 100e18 (senior fully backed by the junior raw NAV)
     * Derivation for a 50e18 ST raw gain: routed to ST, so il recovery = 50e18 (il -> 50e18, jtEffectiveNAV -> 250e18) and
     * no jt fee — routing to JT instead would leave il at 100e18 and take a junior net-gain fee
     */
    function test_Sync_zeroLastSTRawRoutesDeltaToSTWhenSTEffPositive() public {
        _seedState(0, 300e18, 100e18, 200e18, 100e18, SEED_LT_RAW, MarketState.FIXED_TERM);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(50e18)), toNAVUnits(uint256(300e18)));
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 50e18, "gain routed to st recovers il");
        assertEq(toUint256(state.jtEffectiveNAV), 250e18, "jt receives the recovery, not a raw gain");
        assertEq(toUint256(state.stEffectiveNAV), 100e18, "st effective NAV unchanged through recovery");
        assertEq(toUint256(state.jtProtocolFee), 0, "no junior net-gain fee: the delta was st's");
    }

    /**
     * lastSTRawNAV == 0 with stEffectiveNAV == 0 routes nothing to ST, the delta lands on JT as residual
     * Derivation for a 50e18 ST raw gain: jt net gain 50e18 -> jtFee = 5e18, jtEffectiveNAV = 250e18, stEffectiveNAV stays 0
     */
    function test_Sync_zeroLastSTRawRoutesDeltaToJTWhenSTEffZero() public {
        _seedState(0, 200e18, 0, 200e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(50e18)), toNAVUnits(uint256(200e18)));
        assertEq(toUint256(state.stEffectiveNAV), 0, "no live senior claims so st receives nothing");
        assertEq(toUint256(state.jtEffectiveNAV), 250e18, "residual delta lands on jt");
        assertEq(toUint256(state.jtProtocolFee), 5e18, "junior net-gain fee on the routed delta");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "no il so the market stays perpetual");
    }

    /// a zero delta on a cross-claim checkpoint short-circuits the attribution and the sync is a pure no-op
    function test_Sync_zeroDeltaShortCircuitsAttribution() public {
        _seedState(1000e18, 200e18, 980e18, 220e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1000e18)), toNAVUnits(uint256(200e18)));
        assertEq(toUint256(state.stEffectiveNAV), 980e18, "st effective NAV unchanged");
        assertEq(toUint256(state.jtEffectiveNAV), 220e18, "jt effective NAV unchanged");
        assertEq(toUint256(state.stProtocolFee) + toUint256(state.jtProtocolFee) + toUint256(state.ltProtocolFee), 0, "no fees on a flat sync");
    }

    /**
     * a junior raw delta against lastJTRawNAV == 0 short-circuits without a division-by-zero panic
     * NOTE the claim == 0 and lastRaw == 0 short-circuits coincide on the public surface: conservation bounds
     * stClaimOnJTRaw = stEffectiveNAV - stRawNAV = jtRawNAV - jtEffectiveNAV <= jtRawNAV, so a zero junior raw NAV forces a zero senior claim on it
     */
    function test_Sync_zeroLastJTRawShortCircuitsAttribution() public {
        _seedState(1000e18, 0, 1000e18, 0, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1000e18)), toNAVUnits(uint256(50e18)));
        assertEq(toUint256(state.stEffectiveNAV), 1000e18, "nothing attributed to st from the fresh junior value");
        assertEq(toUint256(state.jtEffectiveNAV), 50e18, "the junior delta lands wholly on jt");
        assertEq(toUint256(state.jtProtocolFee), 5e18, "junior net-gain fee taken");
    }

    /**
     * floor-split additivity on junior raw gains — ST takes exactly its floored proportional share of the
     * delta, JT absorbs the rounding residual, and the split always sums to the full delta
     */
    function testFuzz_Sync_attributionFloorSplitAdditivity_jtGain(uint256 _cross, uint256 _gain) public {
        // Bounds: the cross-claim spans [0, jtRawNAV/2] so the seeding loss stays fully covered and clear of the
        // liquidation disjunct, and the gain spans [0, 1e30] (the strategy magnitude bound); both uniform via bound
        _cross = bound(_cross, 0, 150e18);
        _gain = bound(_gain, 0, 1e30);
        uint256 stRawNAV = 1000e18;
        uint256 jtRawNAV = 300e18;
        _seedState(stRawNAV, jtRawNAV, stRawNAV + _cross, jtRawNAV - _cross, 0, SEED_LT_RAW, MarketState.PERPETUAL);

        // Independent floor math: ST's claim on the junior raw NAV is the cross-claim
        uint256 expectedAttrToST = (_gain * _cross) / jtRawNAV;

        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(stRawNAV), toNAVUnits(jtRawNAV + _gain));
        assertLe(expectedAttrToST, _gain, "attributed magnitude bounded by the delta");
        assertEq(toUint256(state.stEffectiveNAV), stRawNAV + _cross + expectedAttrToST, "st takes exactly its floored share");
        assertEq(toUint256(state.jtEffectiveNAV), jtRawNAV - _cross + (_gain - expectedAttrToST), "jt absorbs the rounding residual");
        assertEq(toUint256(state.stEffectiveNAV) + toUint256(state.jtEffectiveNAV), stRawNAV + jtRawNAV + _gain, "additivity: the split sums to the delta");
    }

    /*----------------------------------------------------------------------
                        THE JT LEG
    ----------------------------------------------------------------------*/

    /**
     * junior raw losses never underflow the junior effective NAV from any cross-claim
     * checkpoint — a panic anywhere in this sweep is a REAL finding — and the final NAVs match an independent
     * floor-and-min coverage model
     */
    function testFuzz_Sync_jtLossAttributionNeverUnderflows(uint256 _cross, uint256 _loss) public {
        // Bounds: the cross-claim spans [0, jtRawNAV/2] to keep the seed reachable, the loss spans the entire junior
        // raw NAV [0, jtRawNAV] to probe the exhaustion boundary; both uniform via bound
        _cross = bound(_cross, 0, 150e18);
        _loss = bound(_loss, 0, 300e18);
        uint256 stRawNAV = 1000e18;
        uint256 jtRawNAV = 300e18;
        _seedState(stRawNAV, jtRawNAV, stRawNAV + _cross, jtRawNAV - _cross, _cross, SEED_LT_RAW, _cross > 0 ? MarketState.FIXED_TERM : MarketState.PERPETUAL);

        // Independent model: floored attribution, junior absorbs its residual loss, coverage = min(st loss, jt buffer)
        uint256 attrToST = (_loss * _cross) / jtRawNAV;
        uint256 jtResidualLoss = _loss - attrToST;
        uint256 jtEffAfterLoss = (jtRawNAV - _cross) - jtResidualLoss;
        uint256 coverageApplied = attrToST < jtEffAfterLoss ? attrToST : jtEffAfterLoss;
        uint256 expectedJTEff = jtEffAfterLoss - coverageApplied;
        uint256 expectedSTEff = (stRawNAV + _cross) - (attrToST - coverageApplied);

        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(stRawNAV), toNAVUnits(jtRawNAV - _loss));
        assertEq(toUint256(state.jtEffectiveNAV), expectedJTEff, "jt effective NAV vs independent model");
        assertEq(toUint256(state.stEffectiveNAV), expectedSTEff, "st effective NAV vs independent model");
        assertEq(toUint256(state.stEffectiveNAV) + toUint256(state.jtEffectiveNAV), stRawNAV + jtRawNAV - _loss, "conservation under junior losses");
    }

    /**
     * the junior net-gain fee gates on strict dust excess — a gain of exactly the effective dust tolerance
     * takes no fee, one wei more takes the floored fee
     * Derivation with dust tolerances st 30 + jt 40 = 70: gain 70 -> no fee, then gain 71 -> floor(71 * 0.1e18 / 1e18) = 7
     */
    function test_Sync_jtGainFeeDustBoundary() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stNAVDustTolerance = toNAVUnits(uint256(30));
        p.jtNAVDustTolerance = toNAVUnits(uint256(40));
        _deploy(false, p);
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW + 70));
        assertEq(toUint256(state.jtProtocolFee), 0, "gain equal to the dust tolerance takes no fee");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + 70, "gain NAV still booked");
        state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW + 141));
        assertEq(toUint256(state.jtProtocolFee), 7, "one wei above dust takes the floored fee");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + 141, "gain NAV booked in full, fee not NAV-deducted");
    }

    /**
     * junior net-gain fee floor exactness at an awkward value
     * Derivation: floor(12345678901234567 * 0.1e18 / 1e18) = 1234567890123456 (the trailing 7 truncates)
     */
    function test_Sync_jtGainFeeFloorExactness() public {
        _seedAndInitAccrual();
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW + 12_345_678_901_234_567));
        assertEq(toUint256(state.jtProtocolFee), 1_234_567_890_123_456, "fee floors the awkward product");
    }

    /*----------------------------------------------------------------------
                JT FEE RECOMPUTATION AFTER COVERAGE
    ----------------------------------------------------------------------*/

    /// @dev Deploys a permanently-perpetual market (zero fixed-term duration) so fee fields survive loss syncs observably
    function _deployPermanentlyPerpetual(uint256 _stDust, uint256 _jtDust) internal {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.fixedTermDurationSeconds = 0;
        p.stNAVDustTolerance = toNAVUnits(_stDust);
        p.jtNAVDustTolerance = toNAVUnits(_jtDust);
        _deploy(false, p);
    }

    /**
     * coverage eats part of the junior gain and the fee is recomputed on the reduced net gain
     * Derivation (permanently perpetual so the fee is observable): jt gain 50e18 books fee 5e18, coverage 20e18
     * recomputes jtNetGain = 30e18 > 0 dust so jtFee = floor(30e18 * 0.1e18 / 1e18) = 3e18; jtEffectiveNAV = 230e18, il erased
     */
    function test_Sync_jtFeeRecomputedOnReducedNetGain() public {
        _deployPermanentlyPerpetual(0, 0);
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(toNAVUnits(uint256(20e18)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(980e18)), toNAVUnits(uint256(250e18)));
        assertEq(toUint256(state.jtProtocolFee), 3e18, "fee recomputed on the post-coverage net gain");
        assertEq(toUint256(state.jtEffectiveNAV), 230e18, "jt effective NAV nets the gain against coverage");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 0, "permanently-perpetual erases the il");
    }

    /**
     * the recomputed net gain at or below dust zeroes the fee
     * Derivation with dust 30 + 40 = 70: jt gain 100 books fee 10, coverage 40 recomputes jtNetGain = 60 <= 70 -> fee 0
     */
    function test_Sync_jtFeeZeroedWhenReducedNetGainWithinDust() public {
        _deployPermanentlyPerpetual(30, 40);
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW - 40), toNAVUnits(SEED_JT_RAW + 100));
        assertEq(toUint256(state.jtProtocolFee), 0, "fee zeroed once the reduced net gain is dust");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + 60, "jt nets the gain against the covered loss");
    }

    /**
     * coverage exceeding the junior gain saturates the net gain to zero and zeroes the fee
     * Derivation: jt gain 20e18 books fee 2e18, coverage 50e18 saturates jtNetGain to 0 -> fee 0; jtEffectiveNAV = 170e18
     */
    function test_Sync_jtFeeZeroedWhenCoverageExceedsGain() public {
        _deployPermanentlyPerpetual(0, 0);
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(950e18)), toNAVUnits(uint256(220e18)));
        assertEq(toUint256(state.jtProtocolFee), 0, "fee zeroed on a saturated net gain");
        assertEq(toUint256(state.jtEffectiveNAV), 170e18, "jt effective NAV nets gain against the larger coverage");
    }

    /**
     * with no fee booked on the junior gain (gain within dust), coverage skips the recomputation entirely
     * Derivation with dust 70: jt gain 50 books no fee, coverage 30 leaves the fee at zero; jtEffectiveNAV = 200e18 + 20
     */
    function test_Sync_jtFeeRecomputationSkippedWithoutPriorFee() public {
        _deployPermanentlyPerpetual(30, 40);
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW - 30), toNAVUnits(SEED_JT_RAW + 50));
        assertEq(toUint256(state.jtProtocolFee), 0, "no prior fee so nothing to recompute");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + 20, "gain netted against coverage");
    }

    /*----------------------------------------------------------------------
                ST LOSS COVERAGE REGIMES
    ----------------------------------------------------------------------*/

    /**
     * partial coverage with a residual senior loss — coverage is capped by the junior buffer
     * Derivation: st loss 250e18, coverage = min(250e18, 200e18) = 200e18 exhausts jt (jtEffectiveNAV = 0, il = 200e18),
     * residual 50e18 hits st (stEffectiveNAV = 950e18). The wipeout disjunct then forces PERPETUAL and erases the il
     */
    function test_Sync_partialCoverageResidualLossHitsST() public {
        _seedAndInitAccrual();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(toNAVUnits(uint256(200e18)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(750e18)), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(state.stEffectiveNAV), 950e18, "st bears only the uncovered residual");
        assertEq(toUint256(state.jtEffectiveNAV), 0, "jt buffer fully consumed");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 0, "il erased by the wipeout transition");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "wipeout forces perpetual");
    }

    /**
     * a zero junior buffer provides no coverage — the coverageApplied != 0 guard takes the false arm
     * Derivation: jtEffectiveNAV 0, st loss 100e18 lands entirely on st (stEffectiveNAV = 900e18), il stays 0
     */
    function test_Sync_zeroJTBufferProvidesNoCoverage() public {
        _seedState(1000e18, 0, 1000e18, 0, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(900e18)), ZERO_NAV_UNITS);
        assertEq(toUint256(state.stEffectiveNAV), 900e18, "uncovered loss hits st in full");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 0, "no coverage so no il accrues");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "market stays perpetual");
    }

    /*----------------------------------------------------------------------
                ST GAIN: RECOVERY, PREMIUMS, FEES
    ----------------------------------------------------------------------*/

    /**
     * a gain equal to the il recovers it exactly, pays no premium or fee, and ends the fixed term
     * Derivation: gain 100e18 == il 100e18 -> il = 0, jtEffectiveNAV = 300e18, residual gain 0 so the premium block is
     * skipped, and the organic recovery emits no il reset event (nothing is erased)
     */
    function test_Sync_ilRecoveryExactGainEndsFixedTerm() public {
        _seedLargeIL();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1000e18)), toNAVUnits(uint256(300e18)));
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 0, "il fully recovered");
        assertEq(toUint256(state.jtEffectiveNAV), 300e18, "recovery credited to jt");
        assertEq(toUint256(state.stEffectiveNAV), 1000e18, "st effective NAV unchanged");
        assertEq(toUint256(state.jtProtocolFee) + toUint256(state.stProtocolFee) + toUint256(state.ltProtocolFee), 0, "no fee on pure recovery");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "recovered market returns to perpetual");
    }

    /**
     * a gain above the il pays premiums only on the residual, via the instantaneous branch with the
     * FIXED_TERM initial state and last-committed checkpoint utilizations as the exact YDM preview arguments
     * Derivation: gain 150e18, recovery 100e18 leaves stGain 50e18; checkpoint utils coverageUtilization = ceil(900e18 * 0.1e18
     * / 200e18) = 0.45e18 and liquidityUtilization = ceil(1000e18 * 0.05e18 / 100e18) = 0.5e18; premiums 5e18 / 2.5e18, fees kept
     * because the recovered market lands PERPETUAL: jtFee 0.5e18, ltFee 0.25e18, stFee = floor(42.5e18 * 0.1) = 4.25e18
     */
    function test_Sync_ilRecoveryThenPremiumOnResidualWithExactYDMArgs() public {
        _seedLargeIL();
        vm.expectCall(address(jtYDM), abi.encodeCall(IYDM.previewYieldShare, (MarketState.FIXED_TERM, 0.45e18)));
        vm.expectCall(address(ltYDM), abi.encodeCall(IYDM.previewYieldShare, (MarketState.FIXED_TERM, 0.5e18)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1050e18)), toNAVUnits(uint256(300e18)));
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 0, "il fully recovered first");
        assertEq(toUint256(state.jtEffectiveNAV), 305e18, "recovery plus the risk premium on the residual only");
        assertEq(toUint256(state.ltLiquidityPremium), 2.5e18, "liquidity premium on the residual only");
        assertEq(toUint256(state.stEffectiveNAV), 1045e18, "st retains residual plus the premium value retained senior");
        assertEq(toUint256(state.jtProtocolFee), 0.5e18, "jt yield-share fee kept in the resulting perpetual state");
        assertEq(toUint256(state.ltProtocolFee), 0.25e18, "lt fee kept");
        assertEq(toUint256(state.stProtocolFee), 4.25e18, "st fee on the retained residual");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "full recovery ends the fixed term");
    }

    /**
     * the same-block instantaneous branch queries previewYieldShare with the initial market state and
     * last-committed checkpoint utilizations, and prices the premium at the preview rate over a forced 1s window
     * Derivation: gain 100e18 at preview rates 0.07e18 / 0.03e18 -> premiums 7e18 / 3e18
     */
    function test_Sync_instantaneousPremiumUsesPreviewRatesWithCheckpointArgs() public {
        _seedAndInitAccrual();
        jtYDM.setPreviewYieldShareReturn(0.07e18);
        ltYDM.setPreviewYieldShareReturn(0.03e18);
        vm.expectCall(address(jtYDM), abi.encodeCall(IYDM.previewYieldShare, (MarketState.PERPETUAL, SEED_COVERAGE_UTILIZATION_WAD)));
        vm.expectCall(address(ltYDM), abi.encodeCall(IYDM.previewYieldShare, (MarketState.PERPETUAL, SEED_LIQUIDITY_UTILIZATION_WAD)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW + 100e18), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + 7e18, "instantaneous jt risk premium");
        assertEq(toUint256(state.ltLiquidityPremium), 3e18, "instantaneous lt liquidity premium");
    }

    /// the instantaneous branch caps hostile preview rates at the configured maximum yield shares
    function test_Sync_instantaneousPremiumCapsHostilePreviewRates() public {
        _seedAndInitAccrual();
        jtYDM.setPreviewYieldShareReturn(WAD);
        ltYDM.setPreviewYieldShareReturn(WAD);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW + 100e18), toNAVUnits(SEED_JT_RAW));
        // Capped at maxJT 0.2e18 and maxLT 0.1e18: premiums floor(100e18 * 0.2) = 20e18 and floor(100e18 * 0.1) = 10e18
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + 20e18, "jt premium capped at maxJTYieldShareWAD");
        assertEq(toUint256(state.ltLiquidityPremium), 10e18, "lt premium capped at maxLTYieldShareWAD");
    }

    /**
     * with an elapsed premium window the time-weighted accumulators price the premium and the hostile preview
     * rates are never consulted (they would cap to 20e18 / 10e18 if the instantaneous branch ran)
     * Derivation: rates 0.15e18 / 0.05e18 over 1000s: twJT = 150e18, jtPrem = floor(100e18 * 150e18 / (1000 * 1e18)) = 15e18, ltPrem = 5e18
     */
    function test_Sync_elapsedPremiumUsesTimeWeightedAccumulators() public {
        _seedAndInitAccrual();
        jtYDM.setYieldShareReturn(0.15e18);
        ltYDM.setYieldShareReturn(0.05e18);
        jtYDM.setPreviewYieldShareReturn(WAD);
        ltYDM.setPreviewYieldShareReturn(WAD);
        vm.warp(block.timestamp + 1000);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW + 100e18), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + 15e18, "time-weighted jt risk premium");
        assertEq(toUint256(state.ltLiquidityPremium), 5e18, "time-weighted lt liquidity premium");
    }

    /**
     * the premiumsPaid gate is a strict dust comparison — a dust-sized gain still pays premium NAV but takes
     * no fees and leaves the accrual window intact, while one wei more takes fees and resets the window
     * Derivation with dust 30 + 40 = 70, rates 0.1e18 / 0.05e18 over 100s (twJT 10e18, twLT 5e18):
     *   gain 70: jtPrem = floor(70 * 10e18 / (100 * 1e18)) = 7, ltPrem = floor(70 * 5e18 / 100e18) = 3, no fees, no reset
     *   The 7 wei phase-one premium leaves jtEffectiveNAV = jtRawNAV + 7, a 7 wei JT cross-claim on the senior raw NAV, so the
     *   next attribution floor skims 1 wei of the senior delta to JT: a raw gain of 72 attributes
     *   floor(72 * ((1000e18 + 70) - 7) / (1000e18 + 70)) = 71 to ST (the dust + 1 senior gain) and 1 wei to JT
     *   Then over a further 50s (tw compounds un-reset to 15e18 / 7.5e18, window 150s), senior gain 71:
     *   jtPrem = floor(71 * 15e18 / 150e18) = 7, ltPrem = floor(71 * 7.5e18 / 150e18) = 3, stFee = floor(61 * 0.1) = 6
     *   (the jt and lt fee floors are 0 at this magnitude, and the 1 wei jt gain is below dust so it takes no fee),
     *   jtEffectiveNAV = jtRawNAV + 7 + 1 + 7 = jtRawNAV + 15, accumulators reset and the premium clock advances to windowStart + 150
     */
    function test_Sync_premiumsPaidDustGateBothSides() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stNAVDustTolerance = toNAVUnits(uint256(30));
        p.jtNAVDustTolerance = toNAVUnits(uint256(40));
        _deploy(false, p);
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        uint32 windowStart = uint32(block.timestamp);
        jtYDM.setYieldShareReturn(0.1e18);
        ltYDM.setYieldShareReturn(0.05e18);

        vm.warp(block.timestamp + 100);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW + 70), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + 7, "dust-sized gain still pays the jt premium NAV");
        assertEq(toUint256(state.ltLiquidityPremium), 3, "dust-sized gain still pays the lt premium NAV");
        assertEq(toUint256(state.stProtocolFee) + toUint256(state.jtProtocolFee) + toUint256(state.ltProtocolFee), 0, "no fees at or below dust");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(s.twJTYieldShareAccruedWAD, 10e18, "accumulator not reset at the dust boundary");
        assertEq(s.lastPremiumPaymentTimestamp, windowStart, "premium clock untouched at the dust boundary");

        vm.warp(block.timestamp + 50);
        state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW + 142), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + 15, "compounded window premium plus the attributed wei on the second gain");
        assertEq(toUint256(state.ltLiquidityPremium), 3, "compounded window lt premium");
        assertEq(toUint256(state.stProtocolFee), 6, "st fee taken one wei above dust");
        s = accountant.getState();
        assertEq(s.twJTYieldShareAccruedWAD, 0, "jt accumulator reset once premiums are paid");
        assertEq(s.twLTYieldShareAccruedWAD, 0, "lt accumulator reset once premiums are paid");
        // The expected clock is derived from windowStart rather than read from block.timestamp: an identical
        // pre-warp uint32(block.timestamp) read exists above and via-ir legally CSEs TIMESTAMP within a frame
        assertEq(s.lastPremiumPaymentTimestamp, windowStart + 150, "premium clock advances on payment");
    }

    /**
     * premium floor exactness at awkward prime-adjacent values, pinned to hand-worked literals
     * The rate accrues time-weighted over a single window, so rate and window both carry the same
     * elapsed = 3607 (prime) and the ratio reduces exactly to floor(gain * rate / 1e18). Worked by hand
     * with gain 999_999_999_999_999_937 (prime) and both rates below their caps:
     *   999999999999999937 * 123456789012345677 = 123456789012345669_222222292222222349 -> jtPrem = 123_456_789_012_345_669
     *   999999999999999937 * 98765432109876543  =  98765432109876536_777777777077777791 -> ltPrem =  98_765_432_109_876_536
     * Both products leave a nonzero 18-digit fractional tail, so any rounding other than a floor
     * (ceil, half-up) would land exactly one wei high — the premiums must never round senior gain up
     */
    function test_Sync_premiumFloorExactnessAtAwkwardValues() public {
        _seedAndInitAccrual();
        uint256 rateJT = 123_456_789_012_345_677;
        uint256 rateLT = 98_765_432_109_876_543;
        uint256 elapsed = 3607;
        uint256 gain = 999_999_999_999_999_937;
        jtYDM.setYieldShareReturn(rateJT);
        ltYDM.setYieldShareReturn(rateLT);
        vm.warp(block.timestamp + elapsed);
        // Hand-derived literals from the header derivation — the sub-wei tails (…349 and …791) are floored away
        uint256 expectedJTPremium = 123_456_789_012_345_669;
        uint256 expectedLTPremium = 98_765_432_109_876_536;
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW + gain), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + expectedJTPremium, "jt premium floors exactly");
        assertEq(toUint256(state.ltLiquidityPremium), expectedLTPremium, "lt premium floors exactly");
        // Senior residual by hand: 999_999_999_999_999_937 - 123_456_789_012_345_669 = 876_543_210_987_654_268
        // (only the jt premium leaves the senior side, the lt premium re-labels value that stays senior)
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_RAW + 876_543_210_987_654_268, "st keeps the residual plus the lt premium value retained senior");
    }

    /**
     * the zero-premium guards take their false arms independently — a zero jt premium skips the jt yield-share
     * fee entirely while a nonzero lt premium still pays, and vice versa
     */
    function test_Sync_zeroPremiumGuardBranchesBothSides() public {
        _seedAndInitAccrual();
        // Side 1: jt rate 0, lt rate 0.05e18 on a 100e18 gain: ltPrem 5e18 (fee 0.5e18), stFee = floor(95e18 * 0.1) = 9.5e18
        jtYDM.setPreviewYieldShareReturn(0);
        ltYDM.setPreviewYieldShareReturn(0.05e18);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1100e18)), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW, "zero jt premium leaves jt untouched");
        assertEq(toUint256(state.jtProtocolFee), 0, "no jt yield-share fee without a premium");
        assertEq(toUint256(state.ltLiquidityPremium), 5e18, "lt premium still paid");
        assertEq(toUint256(state.ltProtocolFee), 0.5e18, "lt fee on its premium");
        assertEq(toUint256(state.stProtocolFee), 9.5e18, "st fee on the retained gain");
        assertEq(toUint256(state.stEffectiveNAV), 1100e18, "st retains gain plus the lt share mint");
        // Side 2 (same block, fresh premium window): jt rate 0.1e18, lt rate 0 on another 100e18 gain
        jtYDM.setPreviewYieldShareReturn(0.1e18);
        ltYDM.setPreviewYieldShareReturn(0);
        state = kernel.doPreOp(toNAVUnits(uint256(1200e18)), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + 10e18, "jt premium paid");
        assertEq(toUint256(state.jtProtocolFee), 1e18, "jt yield-share fee on its premium");
        assertEq(toUint256(state.ltLiquidityPremium), 0, "zero lt premium");
        assertEq(toUint256(state.ltProtocolFee), 0, "no lt fee without a premium");
        assertEq(toUint256(state.stProtocolFee), 9e18, "st fee on the 90e18 residual");
    }

    /**
     * LT premium coverage-neutrality — an identical market with a zero lt share produces byte-identical
     * senior and junior effective NAVs and coverage utilization: the premium only re-labels senior-retained value
     */
    function test_Sync_ltPremiumCoverageNeutralViaCounterfactual() public {
        _seedNoIL();
        SyncedAccountingState memory withLT = kernel.doPreOp(toNAVUnits(uint256(1050e18)), toNAVUnits(SEED_JT_RAW));

        // Counterfactual: fresh identical deployment and seed with the lt share zeroed
        _deploy(false, _defaultParams());
        _seedAndInitAccrual();
        jtYDM.setPreviewYieldShareReturn(0.1e18);
        ltYDM.setPreviewYieldShareReturn(0);
        SyncedAccountingState memory withoutLT = kernel.doPreOp(toNAVUnits(uint256(1050e18)), toNAVUnits(SEED_JT_RAW));

        assertEq(toUint256(withLT.stEffectiveNAV), toUint256(withoutLT.stEffectiveNAV), "st effective NAV identical: premium stays inside stEffectiveNAV");
        assertEq(toUint256(withLT.jtEffectiveNAV), toUint256(withoutLT.jtEffectiveNAV), "jt effective NAV untouched by the lt premium");
        assertEq(withLT.coverageUtilizationWAD, withoutLT.coverageUtilizationWAD, "coverage utilization identical");
        assertEq(toUint256(withLT.ltLiquidityPremium), 2.5e18, "factual lt premium paid");
        assertEq(toUint256(withoutLT.ltLiquidityPremium), 0, "counterfactual pays none");
        assertEq(toUint256(withLT.stProtocolFee), 4.25e18, "st fee shrinks by the premium value retained senior");
        assertEq(toUint256(withoutLT.stProtocolFee), 4.5e18, "counterfactual st fee on the full residual");
    }

    /// @dev Stratified hostile YDM output: a third sub-WAD, a third between WAD and 1e24, a third the uint256 maximum
    function _strataRate(uint256 _seed) internal pure returns (uint256) {
        uint256 strata = _seed % 3;
        if (strata == 0) return bound(_seed, 0, WAD);
        if (strata == 1) return bound(_seed, WAD, 1e24);
        return type(uint256).max;
    }

    /**
     * PREMIUMS_EXCEED_SENIOR_YIELD is unreachable — with the yield shares capped at accrual and the caps
     * summing to exactly WAD, hostile YDM outputs (up to uint256 max) can never push the combined premiums past
     * the senior gain on either the time-weighted or the instantaneous branch. Any revert here is a REAL finding
     */
    function testFuzz_Sync_premiumsNeverExceedSeniorYield(uint256 _rateJT, uint256 _rateLT, uint256 _elapsed, uint256 _gain1, uint256 _gain2) public {
        // Deploy at the joint cap maxJT + maxLT == WAD, the tightest legal configuration
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.maxJTYieldShareWAD = 0.6e18;
        p.maxLTYieldShareWAD = 0.4e18;
        _deploy(false, p);
        // Rates stratified across three decades (sub-WAD, WAD..1e24, uint256 max) to include absurd outputs;
        // elapsed uniform up to a decade, gains uniform within the 1e30 strategy magnitude bound
        _rateJT = _strataRate(_rateJT);
        _rateLT = _strataRate(_rateLT);
        _elapsed = bound(_elapsed, 1, 3650 days);
        _gain1 = bound(_gain1, 1, 1e30);
        _gain2 = bound(_gain2, 1, 1e30);
        _seedAndInitAccrual();
        jtYDM.setRates(_rateJT);
        ltYDM.setRates(_rateLT);
        vm.warp(block.timestamp + _elapsed);

        // Time-weighted branch
        SyncedAccountingState memory first = kernel.doPreOp(toNAVUnits(SEED_ST_RAW + _gain1), toNAVUnits(SEED_JT_RAW));
        uint256 jtPremium = toUint256(first.jtEffectiveNAV) - SEED_JT_RAW;
        assertLe(jtPremium + toUint256(first.ltLiquidityPremium), _gain1, "time-weighted premiums bounded by the senior gain");

        // Instantaneous branch: a second gain in the same block right after the premium payment
        SyncedAccountingState memory second = kernel.doPreOp(toNAVUnits(SEED_ST_RAW + _gain1 + _gain2), toNAVUnits(SEED_JT_RAW));
        uint256 jtPremium2 = toUint256(second.jtEffectiveNAV) - toUint256(first.jtEffectiveNAV);
        assertLe(jtPremium2 + toUint256(second.ltLiquidityPremium), _gain2, "instantaneous premiums bounded by the senior gain");
    }

    /**
     * exact two-term NAV conservation on every committed sync from any reachable cross-claim checkpoint —
     * the NAV_CONSERVATION_VIOLATION revert arm is unreachable from conserved checkpoints (a revert or a drift
     * of even one wei here is a REAL finding)
     */
    function testFuzz_Sync_conservationOnEveryCommittedSync(
        uint256 _stRaw0,
        uint256 _jtRaw0,
        uint256 _cross,
        uint256 _stRaw1,
        uint256 _jtRaw1,
        uint256 _elapsed
    )
        public
    {
        // Bounds: raw NAVs within the 1e30 strategy magnitude bound; jtRaw0 at least half of stRaw0 and the
        // cross-claim capped at half of jtRaw0 keep the seeding loss fully covered and clear of the liquidation
        // and wipeout disjuncts; the fresh NAVs sweep [0, 2x] around the checkpoint; all uniform via bound
        _stRaw0 = bound(_stRaw0, 1e18, 1e30);
        _jtRaw0 = bound(_jtRaw0, _stRaw0 / 2 + 1, 1e30);
        _cross = bound(_cross, 0, _jtRaw0 / 2);
        _stRaw1 = bound(_stRaw1, 0, _stRaw0 * 2);
        _jtRaw1 = bound(_jtRaw1, 0, _jtRaw0 * 2);
        _elapsed = bound(_elapsed, 0, 365 days);
        _seedState(_stRaw0, _jtRaw0, _stRaw0 + _cross, _jtRaw0 - _cross, _cross, SEED_LT_RAW, _cross > 0 ? MarketState.FIXED_TERM : MarketState.PERPETUAL);
        jtYDM.setRates(0.2e18);
        ltYDM.setRates(0.1e18);
        vm.warp(block.timestamp + _elapsed);

        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(_stRaw1), toNAVUnits(_jtRaw1));
        assertEq(toUint256(state.stEffectiveNAV) + toUint256(state.jtEffectiveNAV), _stRaw1 + _jtRaw1, "returned state conserves NAV exactly");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV), _stRaw1 + _jtRaw1, "committed checkpoint conserves NAV exactly");
    }

    /**
     * Adversarial fee-floor dust griefing: a keeper who controls sync cadence splits a 90 wei senior gain into
     * ten 9 wei syncs so every stProtocolFee floors to zero — floor(9 * 0.1e18 / 1e18) = 0 — while a single
     * 90 wei sync would book floor(90 * 0.1e18 / 1e18) = 9. Pins that the per-sync fee leakage is strictly
     * bounded by 1/feeRate - 1 wei per sync (9 wei at a 10% fee), so dust-splitting cannot scale into a
     * material fee theft, and NAV itself is never leaked: the full 90 wei gain lands in stEffectiveNAV either way
     */
    function test_Sync_FeeFloorDustGriefing_SplitGainsAvoidOnlyBoundedFee() public {
        _seedAndInitAccrual();
        jtYDM.setPreviewYieldShareReturn(0);
        ltYDM.setPreviewYieldShareReturn(0);
        uint256 totalFees;
        for (uint256 i = 1; i <= 10; ++i) {
            SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW + 9 * i), toNAVUnits(SEED_JT_RAW));
            totalFees += toUint256(state.stProtocolFee);
            assertEq(toUint256(state.stProtocolFee), 0, "each 9 wei gain floors its fee to zero");
        }
        assertEq(totalFees, 0, "the ten-way split pays no fee at all");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTEffectiveNAV), SEED_ST_RAW + 90, "the full split gain still lands in stEffectiveNAV");
        assertEq(toUint256(s.lastJTEffectiveNAV), SEED_JT_RAW, "jt untouched by the zero-premium splits");

        // Counterfactual: the identical 90 wei gain in one sync books the floored 9 wei fee
        _deploy(false, _defaultParams());
        _seedAndInitAccrual();
        jtYDM.setPreviewYieldShareReturn(0);
        ltYDM.setPreviewYieldShareReturn(0);
        SyncedAccountingState memory single = kernel.doPreOp(toNAVUnits(SEED_ST_RAW + 90), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(single.stProtocolFee), 9, "the single sync books the floored fee");
        assertEq(toUint256(single.stEffectiveNAV), SEED_ST_RAW + 90, "identical NAV outcome either way");
    }
}
