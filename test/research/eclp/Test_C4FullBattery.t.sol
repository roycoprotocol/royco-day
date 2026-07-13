// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IGyroECLPPool } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/pool-gyro/IGyroECLPPool.sol";
import { FixedPoint } from "../../../lib/balancer-v3-monorepo/pkg/solidity-utils/contracts/math/FixedPoint.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { ECLPExitLiquidityBase } from "./Test_ECLPExitLiquidityPoolEconomics.t.sol";

/**
 * @title Test_C4FullBattery
 * @notice T9: the full T2-T7 battery re-run against candidate C4 (alpha = 1/1.02 ~ peg - 196 bp,
 *         lambda = 300, beta re-solved for the 99.99% tilt, 1 bp fee) — the band selected in the T8
 *         band-width study to make arb-driven restoration compelling (arbs are Day's only exit-liquidity
 *         restorer). The shipped suite's probe fixtures are A-band-specific, so each decision-critical
 *         measurement body is replicated here against C4 with C4's own probe fixtures (same 100-digit
 *         mpmath pipeline that reproduces every committed literal exactly). Contrast values quoted in
 *         comments are candidate A's recorded battery results.
 *
 *         Physics expected to differ from A (and measured here):
 *           - flow-impact "crumbs" scale with 1/density: C4's peak density is ~178x lower (lambda^2
 *             ratio), so sub-breakeven flow leaks more crumbs but the cadence-mismatch NASTY leak
 *             (arbers oscillating through the dense band) should shrink by roughly the same factor.
 *           - drained-state LP add/remove costs carry real price impact instead of A's ~0.
 *           - everything gated by the fee shield (steady-state zeros, genesis, whale) must be unchanged:
 *             beta - 1 = 0.0063 bp << 1 bp fee.
 *
 *         Regenerate: forge test --match-path test/research/eclp/Test_C4FullBattery.t.sol -vv | grep -E "METRIC|VERDICT"
 */
abstract contract C4BatteryBase is ECLPExitLiquidityBase {
    using FixedPoint for uint256;

    uint256 internal constant X0_C4B = 1_000_100_010_001_551_384_104; // ST at the peg for Y0 quote (pipeline)
    uint256 internal constant BETA_C4 = 1_000_000_630_371_029_932;
    /// Peak stable density per unit invariant for lambda = 300: lambda^2 * s / 2.
    uint256 internal constant RHO_PEAK_COEF_C4 = 31_820;

    address internal poolC4;

    function _eclpParamsC4() internal pure returns (IGyroECLPPool.EclpParams memory) {
        return IGyroECLPPool.EclpParams({
            alpha: 980_392_156_862_745_098,
            beta: 1_000_000_630_371_029_932,
            c: 707_106_781_186_547_524,
            s: 707_106_781_186_547_524,
            lambda: 300_000_000_000_000_000_000
        });
    }

    function _derivedParamsC4() internal pure returns (IGyroECLPPool.DerivedEclpParams memory) {
        return IGyroECLPPool.DerivedEclpParams({
            tauAlpha: IGyroECLPPool.Vector2({ x: -94_773_130_622_350_963_793_914_596_098_909_867_472, y: 31_906_953_976_191_491_143_951_247_353_299_655_382 }),
            tauBeta: IGyroECLPPool.Vector2({ x: 9_455_562_426_453_687_808_195_961_460_162_005, y: 99_999_999_552_961_694_941_282_054_418_046_780_509 }),
            u: 47_391_293_092_388_708_687_131_087_809_789_479_979,
            v: 65_953_476_764_576_592_967_841_298_631_431_128_073,
            w: 34_046_522_788_385_101_860_064_849_635_555_499_105,
            z: -47_381_837_529_962_254_999_333_612_177_959_912_994,
            dSq: 99_999_999_999_999_999_886_624_093_342_106_115_200
        });
    }

    function setUp() public virtual override {
        super.setUp();
        poolC4 = _createPool(_eclpParamsC4(), _derivedParamsC4(), false, bytes32(uint256(91)));
        address[4] memory actors = [lp, arber, exiter, address(this)];
        for (uint256 i = 0; i < 4; ++i) {
            vm.prank(actors[i]);
            IERC20(poolC4).approve(address(router), type(uint256).max);
        }
        router.initialize(poolC4, address(this), _tokens(), _two(X0_C4B, Y0));
        _useC4();
        assertApproxEqAbs(_spotPrice(), 1e18, 1e9, "C4 must initialize on the peg");
        assertApproxEqAbs(_stableShare(), 999_900_000_000_000_000, 1e12, "C4 must hold the 99.99% tilt at the peg");
    }

    function _useC4() internal {
        pool = poolC4;
    }

    /*//////////////////////////////////////////////////////////////////////////
                        C4 DRAIN ANCHORS (PIPELINE FIXTURES)
    //////////////////////////////////////////////////////////////////////////*/

    /// Pipeline-derived scaled spot at the C4 anchor (same consumed-quote ladder as the A-band anchors).
    function _c1AnchorSpot(uint256 i) internal pure returns (uint256) {
        if (i == 0) return 1e18;
        if (i == 1) return 998_378_906_117_078_151;
        if (i == 2) return 996_426_142_773_492_615;
        if (i == 3) return 993_299_391_412_224_142;
        return 986_323_639_708_372_321;
    }

    /// ST value share at the C4 anchor (model input for the fee+impact add-cost model).
    function _c1AnchorStShareWad(uint256 i) internal pure returns (uint256) {
        if (i == 0) return 1e14;
        if (i == 1) return 249_920_652_364_487_836;
        if (i == 2) return 499_574_069_344_651_135;
        if (i == 3) return 749_284_516_126_226_526;
        return 949_547_459_141_909_278;
    }

    /// Stable density at the C4 anchor, normalized to the peak (monotone decay toward alpha preserved).
    function _c1AnchorDensityWad(uint256 i) internal pure returns (uint256) {
        if (i == 0) return 1e18;
        if (i == 1) return 918_057_110_388_453_188;
        if (i == 2) return 685_005_712_308_800_831;
        if (i == 3) return 350_259_508_946_100_030;
        return 83_303_244_936_996_575;
    }

    /// Drain C4 to an anchor with a single exiter EXACT_OUT sell; assert the landing on the pipeline spot.
    function _drainC4(uint256 anchorId) internal {
        if (anchorId == 0) return;
        router.swapExactOut(pool, exiter, IERC20(address(st)), IERC20(address(quoteToken)), _anchorConsumed(anchorId), type(uint256).max);
        assertApproxEqAbs(_spotPrice(), _c1AnchorSpot(anchorId), 2e13, "the drain swap must land the spot on the pipeline-derived C4 anchor price");
    }

    /// Fee+impact model of the spot-numeraire add cost for C4 (the suite's model with C4 fixtures).
    function _c1AddCostModelBpE4(uint256 anchorId, uint256 sizeRaw) internal view returns (uint256) {
        uint256 w = _c1AnchorStShareWad(anchorId);
        uint256 rho = _invariant() / 1e18 * RHO_PEAK_COEF_C4 * _c1AnchorDensityWad(anchorId) / 1e18 * 1e18;
        uint256 dpWad = sizeRaw.mulDown(w) * 1e18 / rho;
        uint256 costWad = SWAP_FEE.mulDown(w) + w.mulDown(dpWad) / 2;
        return costWad / 1e10;
    }
}

/**
 * @notice T9/T2 — rate-update arbs on C4: sync daily across drain states, sync 12h, async 12h offset,
 *         the ST-daily/quote-weekly NASTY cadence, the static breakeven grid, and the standing discount.
 */
contract Test_C4Battery_Arbs is C4BatteryBase {
    using FixedPoint for uint256;

    /// Sync daily at 1 bp across all five drain anchors: steady-state extraction must stay ZERO on C4 —
    /// the fee-shield/one-way-drift logic is band-independent (A recorded literal zeros here too).
    function test_T9_T2_RateStepArb_SyncDaily1bpFee_AcrossDrainStates() public {
        for (uint256 i = 0; i < 5; ++i) {
            (uint256 snap, uint256 snapTs) = _snapState();
            _useC4();
            _drainC4(i);
            uint256 equil0 = _arbToFeeEdge();
            uint256 tvl = _poolTvlAtFair();
            (int256[] memory jumps, uint256[] memory profits, uint256 invFair) = _runSyncEvents(7);

            uint256 steadySum;
            for (uint256 e = 0; e < 7; ++e) {
                assertApproxEqAbs(jumps[e], int256(13_699), 100, "the sync-daily fair/oracle jump must be 1.3699 bp (rate arithmetic, band-independent)");
                if (e >= 2) steadySum += profits[e];
            }
            uint256 steadyAvg = steadySum / 5;
            assertGt(profits[0], 0, "the first post-equilibration update must recycle inventory for a positive one-time profit");
            assertLe(profits[0], invFair.mulDown(uint256(jumps[0]) * 1e10), "the one-time recycle cannot exceed inventory x jump");
            assertLe(steadyAvg, DUST_PROFIT, "steady-state per-update extraction must be zero on C4: the recycle is one-time");
            assertLe(_bpE4(steadyAvg * 365, tvl), 100_000, "VERDICT: sync-daily at 1 bp must not be a nasty arb on C4");
            _restoreState(snap, snapTs);

            _logMetric(
                "T9_ARB",
                string.concat(
                    "pool=C4|drain=",
                    _anchorLabel(i),
                    "|cadence=24h|equil_recycle=",
                    _u(equil0),
                    "|event1_recycle=",
                    _u(profits[0]),
                    "|steady_avg=",
                    _u(steadyAvg),
                    "|inv_fair=",
                    _u(invFair)
                )
            );
        }
        _logVerdict("T9_Q2_sync_daily_1bp_C4", "nasty=false", "steady_state_extraction~0_at_all_drain_states");
    }

    /// Async daily updates with the quote offset 12h (D0 and D50): beta-pinning must starve the arb on C4 too.
    function test_T9_T2_RateStepArb_AsyncDaily12hOffset() public {
        uint256[2] memory anchors = [uint256(0), 2];
        for (uint256 a = 0; a < 2; ++a) {
            (uint256 snap, uint256 snapTs) = _snapState();
            _useC4();
            _drainC4(anchors[a]);
            _arbToFeeEdge();
            uint256 tvl = _poolTvlAtFair();

            _setQuoteCadence(Q_STEP_12H, 12 hours);
            _warpTo(qMarkTs + 12 hours - 1);
            _runEvent(false, true);
            _setQuoteCadence(Q_STEP_1D, 1 days);

            uint256 steadySum;
            for (uint256 d = 0; d < 7; ++d) {
                _warpTo(stMarkTs + 1 days - 1);
                (, uint256 stP) = _runEvent(true, false);
                _warpTo(qMarkTs + 1 days - 1);
                (, uint256 qP) = _runEvent(false, true);
                if (d >= 2) {
                    assertLe(stP, DUST_PROFIT, "steady-state async ST-update events must find no extractable trade on C4");
                    assertLe(qP, DUST_PROFIT, "steady-state async quote-update events must find no extractable trade on C4");
                    steadySum += stP + qP;
                }
            }
            uint256 bpYr = _bpE4(steadySum * 365 / 5, tvl);
            assertLe(bpYr, 100_000, "VERDICT: async daily/12h-offset must not sustain repeatable extraction on C4");
            _restoreState(snap, snapTs);
            _logMetric("T9_ARB", string.concat("pool=C4|drain=", _anchorLabel(anchors[a]), "|cadence=async12h|steady_bp_yr_e4=", _u(bpYr)));
        }
        _logVerdict("T9_Q2_async_12h_offset_C4", "nasty=false", "beta_pinning_caps_the_snap;steady_extraction~0");
    }

    /**
     * @notice The A-band's one genuine hazard: ST daily / quote weekly at D50 (A recorded ~53.1 bp/yr NASTY).
     *         Extraction is arbers oscillating inventory through the band around the peg, which scales with
     *         the density there — C4's is ~178x lower, so the leak is predicted to COLLAPSE. Measured either
     *         way and classified against the same 10 bp/yr nasty threshold; no pre-registered A-band range.
     */
    function test_T9_T2_RateStepArb_StDailyQuoteWeekly() public {
        (uint256 snap, uint256 snapTs) = _snapState();
        _useC4();
        _drainC4(2);
        _arbToFeeEdge();
        uint256 tvl = _poolTvlAtFair();
        _setQuoteCadence(Q_STEP_7D, 7 days);

        uint256 week1;
        uint256 week2;
        uint256 qStaleE4;
        for (uint256 d = 1; d <= 14; ++d) {
            _warpTo(stMarkTs + 1 days - 1);
            bool weekly = d % 7 == 0;
            if (weekly) qStaleE4 = (_fairQRate() * 1e18 / qMark - 1e18) / 1e10;
            (, uint256 pr) = _runEvent(true, weekly);
            if (d <= 7) week1 += pr;
            else week2 += pr;
        }
        assertApproxEqAbs(qStaleE4, 57_534, 200, "the weekly quote staleness must be 5.7534 bp at the weekly mark (rate arithmetic)");
        uint256 bpYrE4 = _bpE4(week2 * 52, tvl);
        _restoreState(snap, snapTs);

        _logMetric(
            "T9_ARB",
            string.concat("pool=C4|drain=D50|cadence=st1d_q7d|week1_profit=", _u(week1), "|week2_profit=", _u(week2), "|arb_bp_yr_e4=", _u(bpYrE4))
        );
        _logVerdict(
            "T9_Q2_st_daily_quote_weekly_C4",
            bpYrE4 > 100_000 ? "nasty=true" : "nasty=false",
            string.concat("bp_yr_e4=", _u(bpYrE4), "|A_recorded=531000")
        );
    }

    /// Static breakeven grid: no cadence sustains steady-state extraction; one-time recycle monotone in staleness.
    function test_T9_T2_BreakevenCadence_StaticGrid() public {
        uint256[4] memory stSteps = [ST_STEP_6H, ST_STEP_12H, ST_STEP_1D, ST_STEP_2D];
        uint256[4] memory qSteps = [Q_STEP_6H, Q_STEP_12H, Q_STEP_1D, Q_STEP_2D];
        uint256[4] memory periods = [uint256(6 hours), 12 hours, 1 days, 2 days];
        string[4] memory labels = ["6h", "12h", "24h", "48h"];
        uint256[4] memory event1;

        for (uint256 c = 0; c < 4; ++c) {
            (uint256 snap, uint256 snapTs) = _snapState();
            _useC4();
            _drainC4(2);
            _arbToFeeEdge();
            _setStCadence(stSteps[c], periods[c]);
            _setQuoteCadence(qSteps[c], periods[c]);
            (, uint256[] memory profits,) = _runSyncEvents(3);
            event1[c] = profits[0];
            assertLe(profits[2], DUST_PROFIT, "no cadence sustains steady-state extraction on a static C4 pool");
            _restoreState(snap, snapTs);
            _logMetric("T9_BREAKEVEN", string.concat("pool=C4|cadence=", labels[c], "|event1_recycle=", _u(profits[0]), "|steady_event=", _u(profits[2])));
        }
        assertLe(event1[0], event1[1], "the one-time recycle margin must be nondecreasing in staleness (6h <= 12h)");
        assertLe(event1[1], event1[2], "the one-time recycle margin must be nondecreasing in staleness (12h <= 24h)");
        assertLe(event1[2], event1[3], "the one-time recycle margin must be nondecreasing in staleness (24h <= 48h)");
    }

    /// Standing discount (no rate steps): the T8 ladder's restock arb, re-asserted with the suite's checks.
    function test_T9_T2_StandingDiscountArb_AtDrainStates() public {
        for (uint256 i = 0; i < 5; ++i) {
            (uint256 snap, uint256 snapTs) = _snapState();
            _useC4();
            _drainC4(i);
            uint256 preSpot = _spotPrice();
            uint256 tvl = _poolTvlAtFair();
            uint256 profit = _arbToFeeEdge();
            uint256 postSpot = _spotPrice();

            if (i == 0) {
                assertLe(profit, DUST_PROFIT, "at the balance point the pool is at fair and the fee blocks any arb");
            } else {
                assertGt(profit, 0, "a drained C4 pool must offer a positive standing restock arb (the design goal)");
                assertGe(postSpot, 1e18 - 1e14 - 1e13, "the standing arb must run the spot up to the buy-side fee edge");
                assertLe(postSpot, 1e18 - 1e14 + 1e13, "the standing arb must stop at the buy-side fee edge");
            }
            _restoreState(snap, snapTs);
            _logMetric(
                "T9_DISCOUNT",
                string.concat(
                    "pool=C4|drain=",
                    _anchorLabel(i),
                    "|discount_bp_e4=",
                    _u((1e18 - preSpot) / 1e10),
                    "|arb_profit=",
                    _u(profit),
                    "|arb_profit_bp_tvl_e4=",
                    _u(_bpE4(profit, tvl)),
                    "|post_spot=",
                    _u(postSpot)
                )
            );
        }
    }
}

/**
 * @notice T9/T2 — the sustained-flow breakeven sweep on C4 (own contract so forge parallelizes the 9 grid
 *         simulations against the other batteries). C4's beta gap (0.0063 bp) pins every supra-breakeven
 *         point exactly like A's; the flow-impact crumbs at sub-breakeven points are structurally larger
 *         (impact ~ 1/density), so the materiality floor for the unpinned classification is C4-specific.
 */
contract Test_C4Battery_FlowBreakeven is C4BatteryBase {
    using FixedPoint for uint256;

    /// C4 crumb materiality ceiling: 0.5 bp/yr of TVL (A used 0.05 bp/yr; impact scales with 1/density).
    uint256 internal constant C4_CRUMB_CEILING_BP_YR_E4 = 5_000;

    function test_T9_T2_FlowBreakevenSweep() public {
        uint256[9] memory stSteps = [ST_STEP_6H, ST_STEP_12H, ST_STEP_1D, ST_STEP_6H, ST_STEP_12H, ST_STEP_1D, ST_STEP_2D, ST_STEP_1D, ST_STEP_2D];
        uint256[9] memory qSteps = [Q_STEP_6H, Q_STEP_12H, Q_STEP_1D, Q_STEP_6H, Q_STEP_12H, Q_STEP_1D, Q_STEP_2D, Q_STEP_1D, Q_STEP_2D];
        uint256[9] memory periods = [uint256(6 hours), 12 hours, 1 days, 6 hours, 12 hours, 1 days, 2 days, 1 days, 2 days];
        uint256[9] memory fees = [uint256(5e13), 5e13, 5e13, 1e14, 1e14, 1e14, 1e14, 1.5e14, 1.5e14];
        string[9] memory labels = ["6h@0.5bp", "12h@0.5bp", "24h@0.5bp", "6h@1bp", "12h@1bp", "24h@1bp", "48h@1bp", "24h@1.5bp", "48h@1.5bp"];
        uint256[9] memory bpYr;

        for (uint256 k = 0; k < 9; ++k) {
            (uint256 snap, uint256 snapTs) = _snapState();
            _useC4();
            (uint256 bpYrK, uint256 sProfit, uint256 spotEnd, uint256 stRawEnd) = _flowScenario(stSteps[k], qSteps[k], periods[k], fees[k]);
            _restoreState(snap, snapTs);
            bpYr[k] = bpYrK;

            uint256 jump = EXCESS_CARRY_PER_DAY * periods[k] / 1 days;
            bool supra = jump > fees[k];
            uint256 target = (1e18 + jump).mulDown(1e18 - fees[k]);
            bool pinned = supra && target >= BETA_C4; // every supra point is pinned: beta gap 0.0063 bp
            uint256 analyticE4 = pinned ? FLOW_PCT * (jump - fees[k]) / 1e18 * 365 / 1e10 : 0;
            if (pinned) {
                assertGt(bpYrK, FLOW_MATERIAL_BP_YR_E4, "a slower-than-breakeven cadence with beta pinning must extract materially under flow");
                assertGe(bpYrK + C4_CRUMB_CEILING_BP_YR_E4, analyticE4 * 3 / 10, "pinned supra extraction must be >= 0.3x the flow x (jump - fee) margin");
                assertLe(bpYrK, analyticE4 * 3 + C4_CRUMB_CEILING_BP_YR_E4, "pinned supra extraction must be <= 3x the margin plus the C4 crumb ceiling");
                assertGt(spotEnd, 1e18, "a pinned supra-breakeven pool must rest above the peg after every boundary arb");
                assertLe(stRawEnd, 1e19, "a beta-pinned supra-breakeven boundary arb must strip the ST leg to dust");
            } else {
                assertGt(sProfit, 0, "sub-breakeven C4 pools still leak the flow-impact crumb");
                assertLe(bpYrK, C4_CRUMB_CEILING_BP_YR_E4, "a sub-breakeven point must leak only flow-impact crumbs (C4 ceiling 0.5 bp/yr)");
                assertApproxEqAbs(spotEnd, target, 5e12, "a sub-breakeven C4 pool must rest at its analytic (1+jump)(1-fee) spot");
                assertGt(stRawEnd, 1e22, "a sub-breakeven C4 pool must retain its ST inventory");
            }
            _logMetric(
                "T9_FLOWBREAKEVEN",
                string.concat(
                    "pool=C4|grid=",
                    labels[k],
                    "|analytic_margin_bp_yr_e4=",
                    _u(analyticE4),
                    "|steady_bp_yr_e4=",
                    _u(bpYrK),
                    "|spot_end=",
                    _u(spotEnd),
                    "|st_raw_end=",
                    _u(stRawEnd),
                    "|regime=",
                    pinned ? "supra_pinned" : "sub"
                )
            );
        }

        // The breakeven bracket (fee / drift) is band-independent; re-assert it brackets the measured flips.
        assertLe(bpYr[3], bpYr[4] + C4_CRUMB_CEILING_BP_YR_E4, "flow extraction must be nondecreasing in the update interval (6h <= 12h at 1 bp)");
        assertLe(bpYr[4], bpYr[5] + C4_CRUMB_CEILING_BP_YR_E4, "flow extraction must be nondecreasing in the update interval (12h <= 24h at 1 bp)");
        assertLe(bpYr[5], bpYr[6] + C4_CRUMB_CEILING_BP_YR_E4, "flow extraction must be nondecreasing in the update interval (24h <= 48h at 1 bp)");
        _logVerdict("T9_Q2_flow_breakeven_C4", "breakeven=fee_div_excess_drift", "same_0.73d_at_1bp;sub_breakeven_leak=impact_crumbs_only");
    }
}

/**
 * @notice T9/T3 — single-sided stable LP statics on C4: one-way add costs across drain states and sizes
 *         against the fee+impact model with C4 fixtures, and the add/remove round trip per anchor.
 */
contract Test_C4Battery_LPStatics is C4BatteryBase {
    using FixedPoint for uint256;

    function test_T9_T3_SingleSidedStableAdd_AcrossDrainStatesAndSizes() public {
        uint256[3] memory sizePctWad = [uint256(1e15), 1e16, 5e16];
        for (uint256 i = 0; i < 5; ++i) {
            (uint256 snapOuter, uint256 snapOuterTs) = _snapState();
            _useC4();
            _drainC4(i);
            for (uint256 sIdx = 0; sIdx < 3; ++sIdx) {
                (uint256 snapInner, uint256 snapInnerTs) = _snapState();
                uint256 size = _poolTvlAtFair().mulDown(sizePctWad[sIdx]);
                uint256 model = _c1AddCostModelBpE4(i, size);
                (int256 costFair, int256 costSpot, uint256 bptOut) = _singleSidedAdd(size);

                if (i == 0) {
                    assertLt(costFair, 1000, "a single-sided quote add at C4's 99.99%-stable balance point must cost < 0.1 bp at fair");
                    assertGt(costFair, -1000, "the balance-point add cost cannot be meaningfully negative (spot == fair at the peg)");
                } else {
                    assertGe(costSpot, int256(model * 3 / 10), "the spot-numeraire add cost must be at least 0.3x the C4 fee+impact model");
                    assertLe(costSpot, int256(model * 3), "the spot-numeraire add cost must be at most 3x the C4 fee+impact model");
                }
                _restoreState(snapInner, snapInnerTs);
                _logMetric(
                    "T9_ADD",
                    string.concat(
                        "pool=C4|drain=",
                        _anchorLabel(i),
                        "|size_pct_e4=",
                        _u(sizePctWad[sIdx] / 1e12),
                        "|bpt_out=",
                        _u(bptOut),
                        "|addCost_fair_bp_e4=",
                        _i(costFair),
                        "|addCost_spot_bp_e4=",
                        _i(costSpot),
                        "|model_bp_e4=",
                        _u(model)
                    )
                );
            }
            _restoreState(snapOuter, snapOuterTs);
        }
    }

    function test_T9_T3_SingleSidedStableRoundTrip_AcrossDrainStates() public {
        int256 d0;
        for (uint256 i = 0; i < 5; ++i) {
            (uint256 snap, uint256 snapTs) = _snapState();
            _useC4();
            _drainC4(i);
            uint256 size = _poolTvlAtFair().mulDown(1e16);
            (, int256 costSpot, uint256 bptOut) = _singleSidedAdd(size);
            uint256 qOut = router.removeLiquiditySingleTokenExactIn(pool, lp, bptOut, _tokens(), 1, 0);
            int256 roundTripE4 = (int256(size) - int256(qOut)) * 1e8 / int256(size);

            assertGt(roundTripE4, 0, "the round trip must cost strictly more than zero");
            int256 oneWay = costSpot > 0 ? costSpot : int256(0);
            assertLe(roundTripE4, 2 * oneWay + 10_000, "the round trip must not exceed twice the one-way cost plus 1 bp of slack");
            if (i == 0) {
                d0 = roundTripE4;
                assertLt(roundTripE4, 50_000, "VERDICT input: the C4 balance-point round trip must cost < 5 bp");
            }
            _restoreState(snap, snapTs);
            _logMetric("T9_ROUNDTRIP", string.concat("pool=C4|drain=", _anchorLabel(i), "|oneWay_spot_bp_e4=", _i(costSpot), "|roundTrip_bp_e4=", _i(roundTripE4)));
        }
        _logVerdict("T9_Q3_round_trip_C4", "meaningful_loss_at_balance=false", string.concat("balance_point_roundTrip_bp_e4=", _i(d0)));
    }
}

/**
 * @notice T9/T3b — the 365-day single-sided-LP simulation on C4 (sync daily marks, 0.2%/day exit flow,
 *         3%/day stress week at day 180), identical procedure to the A/D year sim. C4's wide band converts
 *         part of the exiters' deeper haircuts into pool-side spread (the pool buys low from exiters, sells
 *         high to arbers), so the LP is predicted to do BETTER than A's +1.85 bp/yr.
 */
contract Test_C4Battery_YearSim is C4BatteryBase {
    using FixedPoint for uint256;

    function test_T9_T3_LPOneYear_SyncDailyUpdates_VsStableHoldBenchmark() public {
        (uint256 snap, uint256 snapTs) = _snapState();
        _useC4();
        uint256 deposit = 100_000e18;
        (, uint256 bpt) = router.addLiquidityUnbalanced(pool, lp, _tokens(), _two(0, deposit), 0);
        uint256 addCost = deposit.mulDown(_fairQRate()) - _bptFairValue(bpt);
        uint256 lpShareWad = bpt * 1e18 / IERC20(pool).totalSupply();

        int256 transferSum;
        uint256 arbSum;
        uint256 carrySum;
        uint256 clampedDays;
        uint256 sumTvl;
        uint256 avgStShareE4;
        for (uint256 d = 1; d <= 365; ++d) {
            _warpTo(stMarkTs + 12 hours);
            uint256 pct = (d >= 180 && d <= 186) ? 3e16 : 2e15;
            uint256 stAmt = _poolTvlAtFair().mulDown(pct) * 1e18 / _fairStRate();
            try router.swapExactIn(pool, exiter, IERC20(address(st)), IERC20(address(quoteToken)), stAmt, 0) returns (uint256 qOut) {
                transferSum += int256(stAmt.mulDown(_fairStRate())) - int256(qOut.mulDown(_fairQRate()));
            } catch {
                clampedDays++;
            }
            avgStShareE4 += _stValueShareBpE4();
            (uint256 stRawA,) = _rawBalances();
            uint256 carryA = stRawA.mulDown(_fairStRate());

            _warpTo(stMarkTs + 1 days - 1);
            arbSum += _arbToFeeEdge();
            (uint256 stRawB,) = _rawBalances();
            carrySum += lpShareWad.mulDown((carryA + stRawB.mulDown(_fairStRate())) / 2).mulDown(EXCESS_CARRY_PER_DAY);
            sumTvl += _poolTvlAtFair();

            _warpBy(1);
            _stepStOracle();
            _stepQuoteOracle();
        }
        avgStShareE4 /= 365;

        uint256 bptValPre = _bptFairValue(bpt);
        uint256[] memory outs = router.removeLiquidityProportional(pool, lp, bpt, _tokens());
        uint256 lpFinal = _valueAtFair(outs[0], outs[1]);
        uint256 removeCost = bptValPre > lpFinal ? bptValPre - lpFinal : 0;
        uint256 benchmark = deposit.mulDown(_fairQRate());

        int256 lpExcess = int256(lpFinal) - int256(benchmark);
        int256 lpExcessBpE4 = lpExcess * 1e8 / int256(benchmark);
        int256 explained = (transferSum - int256(arbSum)) * int256(lpShareWad) / 1e18 + int256(carrySum) - int256(addCost) - int256(removeCost);
        int256 residual = lpExcess - explained;
        uint256 arbBpYrE4 = _bpE4(arbSum, sumTvl / 365);

        assertLe(residual >= 0 ? residual : -residual, int256(deposit / 1e4), "the fair-value ledger must close to within 1 bp of the deposit");
        assertGe(lpExcessBpE4, -50_000, "VERDICT: the C4 single-sided stable LP must not lose more than 5 bp/yr vs holding the 3% stable");
        assertLe(arbBpYrE4, 100_000, "VERDICT: total arb extraction under sync daily updates with real flow must stay under 10 bp/yr on C4");
        assertEq(clampedDays, 0, "no exit-flow day may be clamped: C4's wider band absorbs the stress week with room to spare");
        _restoreState(snap, snapTs);

        _logMetric(
            "T9_SIM",
            string.concat(
                "pool=C4|lpExcess_bp_e4=",
                _i(lpExcessBpE4),
                "|exiter_transfer=",
                _i(transferSum),
                "|arber_profit=",
                _u(arbSum),
                "|excess_carry=",
                _u(carrySum),
                "|arb_bp_yr_e4=",
                _u(arbBpYrE4),
                "|avg_st_share_bp_e4=",
                _u(avgStShareE4),
                "|residual=",
                _i(residual)
            )
        );
        _logVerdict(
            "T9_Q3_lp_year_C4",
            lpExcessBpE4 >= -50_000 ? "meaningful_loss=no" : "meaningful_loss=yes",
            string.concat("lpExcess_bp_e4=", _i(lpExcessBpE4), "|A_recorded=+18500")
        );
    }
}

/**
 * @notice T9/T5+T6 — one-sided genesis and the whale add on C4. Both are pure fee-shield theorems
 *         (beta - 1 = 0.0063 bp << fee), so the A-band zeros must reproduce exactly. The min-fee
 *         diagnostic is C4's twist: at the 0.01 bp pool-minimum fee the shield still (barely) holds
 *         (0.01 > 0.0063), so unlike the 90/10 pool C4 loses nothing even with the shield thinned.
 */
contract Test_C4Battery_WhaleGenesis is C4BatteryBase {
    using FixedPoint for uint256;

    function test_T9_T6_OneSidedGenesis_StablesOnlyInit_FeeShieldsTheBand() public {
        uint256[3] memory seeds = [uint256(10_000e18), 100_000e18, 1_000_000e18];
        uint256[2] memory feesWad = [uint256(SWAP_FEE), 1e12]; // production 1 bp; pool-minimum 0.01 bp diagnostic
        for (uint256 f = 0; f < 2; ++f) {
            for (uint256 s = 0; s < 3; ++s) {
                (uint256 snap, uint256 snapTs) = _snapState();
                address g = _createPool(_eclpParamsC4(), _derivedParamsC4(), false, bytes32(uint256(910 + f * 10 + s)));
                router.initialize(g, address(this), _tokens(), _two(0, seeds[s]));
                pool = g;
                if (feesWad[f] != SWAP_FEE) vault.manualUnsafeSetStaticSwapFeePercentage(pool, feesWad[f]);

                uint256 tvl0 = _poolTvlAtFair();
                (uint256 profit,, bool sellSt) = _optimalArb();
                uint256 seederLoss = tvl0 > _poolTvlAtFair() ? tvl0 - _poolTvlAtFair() : 0;
                if (profit > DUST_PROFIT) {
                    // Execute it for real so the seeder loss below is the realized one.
                    (, uint256 amt, bool dir) = _optimalArb();
                    if (dir) router.swapExactIn(pool, arber, IERC20(address(st)), IERC20(address(quoteToken)), amt, 0);
                    else router.swapExactIn(pool, arber, IERC20(address(quoteToken)), IERC20(address(st)), amt, 0);
                    seederLoss = tvl0 > _poolTvlAtFair() ? tvl0 - _poolTvlAtFair() : 0;
                }
                assertLe(profit, DUST_PROFIT, "one-sided C4 genesis must offer no extractable arb: beta - 1 < fee at BOTH fee levels");
                assertLe(seederLoss, DUST_PROFIT, "the C4 seeder must keep 100.00% of a stables-only seed");
                _restoreState(snap, snapTs);
                _logMetric(
                    "T9_GENESIS",
                    string.concat(
                        "pool=C4|seed=",
                        _u(seeds[s]),
                        "|fee_bp_e4=",
                        _u(feesWad[f] / 1e10),
                        "|optimal_arb=",
                        _u(profit),
                        "|dir_sellSt=",
                        sellSt ? "1" : "0",
                        "|seeder_loss=",
                        _u(seederLoss)
                    )
                );
            }
        }
        _logVerdict("T9_Q6_genesis_C4", "loss=0_at_1bp_AND_at_min_fee", "beta_gap_0.0063bp_shielded_at_0.01bp_min_fee");
    }

    function test_T9_T5_WhaleAdd_1MSingleSidedOn500kPool() public {
        (uint256 snap, uint256 snapTs) = _snapState();
        address w = _createPool(_eclpParamsC4(), _derivedParamsC4(), false, bytes32(uint256(95)));
        vm.prank(lp);
        IERC20(w).approve(address(router), type(uint256).max);
        router.initialize(w, address(this), _tokens(), _two(X0_C4B / 20, Y0 / 20)); // $500k at the balance ratio
        pool = w;

        (int256 costFair, int256 costSpot, uint256 bptOut) = _singleSidedAdd(1_000_000e18); // 2x TVL
        (uint256 standingArb,,) = _optimalArb();
        uint256 spotAfter = _spotPrice();

        assertLe(standingArb, DUST_PROFIT, "the whale's displacement must land inside the fee shield: no standing arb on C4");
        assertLt(spotAfter, BETA_C4, "the post-add spot must remain under beta");
        assertLt(costFair < 0 ? -costFair : costFair, 10_000, "the 2x-TVL whale add must cost less than 1 bp at fair on C4");
        _restoreState(snap, snapTs);
        _logMetric(
            "T9_WHALE",
            string.concat(
                "pool=C4|add=1M_on_500k|costFair_bp_e4=",
                _i(costFair),
                "|costSpot_bp_e4=",
                _i(costSpot),
                "|bpt_out=",
                _u(bptOut),
                "|standing_arb=",
                _u(standingArb),
                "|spot_after=",
                _u(spotAfter)
            )
        );
        _logVerdict("T9_Q5_whale_C4", "no_standing_arb", string.concat("costFair_bp_e4=", _i(costFair), "|A_recorded=0.0000bp"));
    }
}

/**
 * @notice T9/T7 — the production marking calendar on C4: per-second (6h-checkpointed) quote marks,
 *         monthly ST marks, 3 cycles. The strip/carry-drag dynamics are tilt-driven (inventory share x
 *         5%/yr), so C4 must land at A's ~0.05 bp/yr — the wide band must NOT reopen the stale-mark leak.
 */
contract Test_C4Battery_ExtremeCadence is C4BatteryBase {
    using FixedPoint for uint256;

    uint256 internal constant ST_STEP_30D = 1_006_575_342_465_753_424;
    uint256 internal constant CHECKPOINT = 6 hours;
    uint256 internal constant CYCLE = 30 days;
    uint256 internal constant CYCLES = 3;
    uint256 internal constant CHECKPOINTS_PER_CYCLE = 120;
    uint256 internal constant EXITER_PROBE = 10_000e18;
    uint256 internal constant PROBE_CHECKPOINT = 60;
    /// Day-15 haircut from the pinned-pool identity 1 - beta(1-fee)/(1+drift(15d)), drift = 32.877 bp.
    uint256 internal constant PROBE_HAIRCUT_PREDICTION_E4 = 337_600;

    function test_T9_T7_ExtremeCadence_PerSecondQuote_MonthlyStMarks() public {
        (uint256 snap, uint256 ts0) = _snapState();
        _useC4();
        _setStCadence(ST_STEP_30D, CYCLE);
        _setQuoteCadence(Q_STEP_6H, CHECKPOINT);

        uint256 simStart = nowTs;
        (uint256 stRaw0,) = _rawBalances();
        uint256 stInventoryFair0 = stRaw0.mulDown(_fairStRate());
        uint256 tvl0 = _poolTvlAtFair();
        bool stripped;
        uint256 timeToStrip;
        uint256 pinnedCheckpoints;
        uint256 extraction;
        uint256 laterExtraction;
        uint256 snapReverseArb;
        int256 exiterHaircutE4;

        for (uint256 c = 0; c < CYCLES; ++c) {
            uint256 cycleStart = stMarkTs;
            uint256 cycleExtraction;
            for (uint256 k = 1; k <= CHECKPOINTS_PER_CYCLE; ++k) {
                _warpTo(cycleStart + k * CHECKPOINT);
                _stepQuoteOracle();
                uint256 p = _arbToFeeEdge();
                cycleExtraction += p;
                if (!stripped) {
                    (uint256 sr,) = _rawBalances();
                    if (sr < stRaw0 / 100) {
                        stripped = true;
                        timeToStrip = nowTs - simStart;
                    }
                } else if (p <= DUST_PROFIT) {
                    ++pinnedCheckpoints;
                }
                if (c == 0 && k == PROBE_CHECKPOINT) {
                    (uint256 ps, uint256 pts) = _snapState();
                    uint256 qOut = router.swapExactIn(pool, exiter, IERC20(address(st)), IERC20(address(quoteToken)), EXITER_PROBE, 0);
                    exiterHaircutE4 =
                        (int256(EXITER_PROBE.mulDown(_fairStRate())) - int256(qOut.mulDown(_fairQRate()))) * 1e8 / int256(EXITER_PROBE.mulDown(_fairStRate()));
                    _restoreState(ps, pts);
                }
            }
            _stepStOracle();
            uint256 rev = _arbToFeeEdge();
            snapReverseArb += rev;
            cycleExtraction += rev;
            extraction += cycleExtraction;
            if (c > 0) laterExtraction += cycleExtraction;
        }

        uint256 lpEnd = _poolTvlAtFair();
        uint256 benchEnd = X0_C4B.mulDown(_fairStRate()) + Y0.mulDown(_fairQRate());
        (uint256 stRawEnd,) = _rawBalances();
        uint256 strippedRaw = stRaw0 - stRawEnd;
        int256 lpNetWei = int256(lpEnd) - int256(benchEnd);
        int256 residualWei = (int256(benchEnd) - int256(lpEnd)) - int256(extraction);

        assertLe(timeToStrip, 1 days, "the ST leg must be stripped within a day of drift crossing the fee");
        assertLe(snapReverseArb, CYCLES * DUST_PROFIT, "beta*(1-fee) < 1 must fee-block the post-snap refill arb on C4");
        assertLe(laterExtraction, extraction / 10 + DUST_PROFIT, "cycles 2-3 must extract ~nothing: the one-time strip is the whole leak");
        assertLe(extraction, stInventoryFair0.mulDown(CYCLES * (ST_STEP_30D - 1e18)) * 2, "extraction must be capped by inventory x cumulative drift");
        assertGe(pinnedCheckpoints, (CYCLES * CHECKPOINTS_PER_CYCLE * 8) / 10, "the pool must sit pinned and inert for >= 80% of the horizon");
        assertLe(lpNetWei, int256(0), "the LP can never beat the hold benchmark under pure adverse cadence");
        assertApproxEqAbs(
            exiterHaircutE4,
            int256(PROBE_HAIRCUT_PREDICTION_E4),
            PROBE_HAIRCUT_PREDICTION_E4 / 10,
            "the C4 day-15 exiter haircut must match the pinned-pool execution identity within 10%"
        );
        _restoreState(snap, ts0);

        _logMetric(
            "T9_T7",
            string.concat(
                "pool=C4|extraction_total=",
                _u(extraction),
                "|time_to_strip_s=",
                _u(timeToStrip),
                "|pinned_checkpoints=",
                _u(pinnedCheckpoints),
                "|snap_reverse_arb=",
                _u(snapReverseArb),
                "|exiter_haircut_day15_bp_e4=",
                _i(exiterHaircutE4),
                "|lp_net_wei=",
                _i(lpNetWei),
                "|carry_drag_wei=",
                _i(residualWei),
                "|carry_drag_bp_yr_e4=",
                _u(_bpE4(uint256(residualWei > 0 ? residualWei : int256(0)) * 365 / 90, tvl0)),
                "|stripped_raw=",
                _u(strippedRaw)
            )
        );
        _logVerdict(
            "T9_T7_extreme_cadence_C4",
            "carry_drag_tilt_driven_not_band_driven",
            string.concat("carry_drag_bp_yr_e4=", _u(_bpE4(uint256(residualWei > 0 ? residualWei : int256(0)) * 365 / 90, tvl0)), "|A_recorded=500")
        );
    }
}
