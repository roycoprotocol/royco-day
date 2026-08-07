// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { MarketState } from "../../../src/libraries/Types.sol";
import { toNAVUnits } from "../../../src/libraries/Units.sol";
import { AdaptiveCurveYDM_V1 } from "../../../src/ydm/AdaptiveCurveYDM_V1.sol";
import { AdaptiveCurveYDM_V2 } from "../../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { AccountantTestBase } from "../../utils/AccountantTestBase.sol";

/**
 * @title Test_Uint32ClockWrap
 * @notice The uint32 clock-width behavior of the adaptive YDMs and the accountant. Every clock they persist is
 *         stamped as uint32(block.timestamp), so from the first second past 2^32 (February 2106) each stored
 *         stamp drops the 2^32 bit while block.timestamp keeps it. Every elapsed-time subtraction against such a
 *         stamp then reads 2^32 seconds (about 136 years) too long: adaptive curves are slammed to their
 *         configured bounds in one call, the same-block accrual guard misses so time-weighted yield share is
 *         minted in a zero-second window, and the premium payment window over-weights the accumulators until
 *         every gain-bearing sync reverts
 * @dev Each test asserts the past-horizon behavior and documents the sub-horizon dated behavior in an adjacent
 *      comment with independently derived bounds
 */
contract Test_Uint32ClockWrap is AccountantTestBase {
    /// @dev 2^32, the width of every persisted clock: the first second at which the truncated stamps disagree with block.timestamp
    uint256 internal constant TWO_POW_32 = 4_294_967_296;

    // =============================
    // The YDM adaptation clock wraps at uint32 and slams the curve to its bounds
    // =============================

    /**
     * @notice V2, downward: one real hour after the uint32 horizon, a below-target call slams the adaptive yield
     *         share at target from 0.1e18 straight to the 0.0001e18 floor, because the stored
     *         lastAdaptationTimestamp lost its 2^32 bit and the elapsed time reads 136 years instead of one hour
     * @dev With a correctly sized clock, an hour of full-speed downward adaptation decays the yield share at
     *      target by exp(-speed x 3600) where speed = 100e18 / 365 days = floor(1e20 / 31536000) = 3170979198376
     *      per second, an exponent of 3170979198376 x 3600 = 11415525114153600 (about 1.1% per hour). Since
     *      exp(-x) >= 1 - x, the correctly decayed value is at least
     *      0.1e18 x (1e18 - 11415525114153600) / 1e18 = 98858447488584640
     */
    function test_ydmAdaptationClock_wrapsAtUint32_slamsV2YieldShareToFloor() public {
        // Standalone V2 curve with this test as its market accountant: kink at 50% utilization,
        // yield shares 0.05e18 at zero utilization / 0.1e18 at target / 0.2e18 at full utilization
        AdaptiveCurveYDM_V2 ydm = new AdaptiveCurveYDM_V2(0.5e18, 0.0001e18, 1e18, (100e18 / uint256(365 days)));
        ydm.initializeYDMForMarket(0.05e18, 0.1e18, 0.2e18);
        assertEq(ydm.MIN_YIELD_SHARE_AT_TARGET_WAD(), 0.0001e18, "the V2 floor on the yield share at target is 0.0001e18 by construction");

        // Warp one step past the uint32 horizon and adapt once. A never-stamped curve treats elapsed as zero
        // (no adaptation), but the write-back stamps lastAdaptationTimestamp = uint32(2^32 + 1000) = 1000,
        // silently dropping the 2^32 bit that block.timestamp keeps
        vm.warp(TWO_POW_32 + 1000);
        uint256 out0 = ydm.yieldShare(MarketState.PERPETUAL, 0);
        // At zero utilization the additive curve subtracts the full 0.05e18 discount from the 0.1e18 target share
        assertEq(out0, 0.05e18, "first call prices the un-adapted curve at its zero-utilization anchor");
        (uint64 yT0, uint32 ts0,,) = ydm.accountantToCurve(address(this));
        assertEq(yT0, 0.1e18, "first call adapts nothing because the curve had never been stamped");
        assertEq(ts0, 1000, "the stored adaptation stamp truncates 4294968296 to its low 32 bits");

        // One REAL hour later, still at zero utilization (full-speed downward adaptation). The wrapped elapsed
        // reads block.timestamp - 1000 = 2^32 + 3600 = 4294970896 seconds, so the linear adaptation is
        // -3170979198376 x 4294970896 (about -1.36e22), far past the exponential's underflow-to-zero cutoff:
        // the new yield share at target computes to 0 and is clamped up to the floor. The curve's entire
        // adaptive memory — the market-force pricing of the premium — is destroyed by a single wrapped hour
        vm.warp(block.timestamp + 3600);
        uint256 out1 = ydm.yieldShare(MarketState.PERPETUAL, 0);

        (uint64 yT1,,,) = ydm.accountantToCurve(address(this));
        assertEq(yT1, ydm.MIN_YIELD_SHARE_AT_TARGET_WAD(), "the wrapped elapsed slams the yield share at target to the configured floor");
        assertEq(yT1, 0.0001e18, "the slammed value is the 0.0001e18 floor, not a decayed curve position");
        // An honest hour of decay leaves at least 98858447488584640 (derivation above), so the slammed value
        // is more than 988x below anywhere a correctly dated adaptation could have taken the curve
        assertLt(uint256(yT1) * 988, 98_858_447_488_584_640, "the slammed value sits over 988x below the correct one-hour decay floor");

        // The premium output collapses with it: the trapezoidal average of the yield share at target is
        // (0.1e18 + 0.0001e18 + 2 x 0.0001e18) / 4 = 25075000000000000, and subtracting the full 0.05e18
        // zero-utilization discount goes negative, so the returned share floors at 0 — the capital pool
        // being paid for its service would receive nothing despite only one hour passing
        assertEq(out1, 0, "the returned yield share bottoms out at zero for the pool being paid");
    }

    /**
     * @notice V1, upward: the mirror direction — one real hour after the uint32 horizon, an above-target call
     *         slams the adaptive yield share at target from 0.1e18 straight to the 1e18 ceiling, because the
     *         wrapped elapsed clamps the linear adaptation to the exponential's overflow guard and its
     *         exponential dwarfs every bound
     * @dev With a correctly sized clock, an hour of full-speed upward adaptation grows the yield share at target
     *      by exp(+speed x 3600) where speed = 50e18 / 365 days = floor(5e19 / 31536000) = 1585489599188 per
     *      second, an exponent of 1585489599188 x 3600 = 5707762557076800 (about +0.57% per hour). Since
     *      exp(x) <= 1 / (1 - x) for x in [0, 1), the correctly grown value is at most
     *      0.1e18 / (1 - 0.0057078) < 100600000000000000
     */
    function test_ydmAdaptationClock_wrapsAtUint32_slamsV1YieldShareToCeiling() public {
        // Standalone V1 curve: kink at 50% utilization, yield shares 0.1e18 at target / 0.2e18 at full
        // utilization, giving a multiplicative steepness of 2e18
        AdaptiveCurveYDM_V1 ydm = new AdaptiveCurveYDM_V1(0.5e18, 0.0001e18, 1e18, (50e18 / uint256(365 days)));
        ydm.initializeYDMForMarket(0.1e18, 0.2e18);
        assertEq(ydm.MAX_YIELD_SHARE_AT_TARGET_WAD(), 1e18, "the V1 ceiling on the yield share at target is 100% by construction");

        // First adaptation past the uint32 horizon: elapsed treated as zero, stamp truncated to the low 32 bits
        vm.warp(TWO_POW_32 + 1000);
        uint256 out0 = ydm.yieldShare(MarketState.PERPETUAL, 1e18);
        // At full utilization the multiplicative curve doubles the 0.1e18 target share (steepness 2e18)
        assertEq(out0, 0.2e18, "first call prices the un-adapted curve at its full-utilization anchor");
        (uint64 yT0, uint32 ts0,) = ydm.accountantToCurve(address(this));
        assertEq(yT0, 0.1e18, "first call adapts nothing because the curve had never been stamped");
        assertEq(ts0, 1000, "the stored adaptation stamp truncates 4294968296 to its low 32 bits");

        // One REAL hour later at full utilization (full-speed upward adaptation). The wrapped elapsed reads
        // 2^32 + 3600 seconds, the linear adaptation 1585489599188 x 4294970896 (about +6.8e21) is clamped to
        // the exponential overflow guard (about 135.3e18) whose exponential is about e^135, so the new yield
        // share at target overshoots everything and is clamped to the ceiling: the market instantly prices
        // its premium as if utilization had been critical for 136 straight years
        vm.warp(block.timestamp + 3600);
        uint256 out1 = ydm.yieldShare(MarketState.PERPETUAL, 1e18);

        (uint64 yT1,,) = ydm.accountantToCurve(address(this));
        assertEq(yT1, ydm.MAX_YIELD_SHARE_AT_TARGET_WAD(), "the wrapped elapsed slams the yield share at target to the configured ceiling");
        assertEq(yT1, 1e18, "the slammed value is the 100% ceiling, not a grown curve position");
        // An honest hour of growth stays below 100600000000000000 (derivation above), so the slammed value
        // sits more than 9x above anywhere a correctly dated adaptation could have taken the curve
        assertGt(uint256(yT1), 9 * 100_600_000_000_000_000, "the slammed value sits over 9x above the correct one-hour growth ceiling");

        // The output pins at 100% of senior yield: the trapezoidal average is (0.1e18 + 1e18 + 2 x 1e18) / 4
        // = 0.775e18 and the full-utilization curve doubles it to 1.55e18, capped at 1e18 — the paying
        // tranche would surrender its entire yield off one wrapped hour
        assertEq(out1, 1e18, "the returned yield share pins at 100% of the paying tranche's yield");
    }

    // =============================
    // The accountant's accrual clock and premium window wrap at uint32
    // =============================

    /**
     * @notice Accrual: past the uint32 horizon, a same-block re-sync accrues 2^32 seconds of time-weighted yield
     *         share, because the stored accrual stamp lost its 2^32 bit so the zero-elapsed same-block guard
     *         misses. This is the past-horizon twin of test_Accrual_sameBlockReaccrualIsNoop, which covers the
     *         no-op below the horizon
     * @dev The accumulators meter premium entitlement per second of service rendered. Zero real seconds pass
     *      here, so below the horizon the accrual is exactly zero. Past the horizon each accumulator jumps by
     *      rate x 2^32 = 0.1e18 x 4294967296 = 429496729600000000000000000, accruing 136 years of entitlement
     *      out of a zero-second window
     */
    function test_accrualClock_wrapsAtUint32_accruesFullPeriodSameBlock() public {
        _deploy(_defaultParams());

        // Land the first accrual past the uint32 horizon: it only initializes the clocks (no accrual, no YDM
        // consult) and stamps lastYieldShareAccrualTimestamp = uint32(2^32 + 5000) = 5000
        vm.warp(TWO_POW_32 + 5000);
        _seedAndInitAccrual();
        IRoycoDayAccountant.RoycoDayAccountantState memory s0 = accountant.getState();
        assertEq(s0.lastYieldShareAccrualTimestamp, 5000, "the stored accrual stamp truncates 4294972296 to its low 32 bits");
        assertEq(uint256(s0.twJTYieldShareAccruedWAD), 0, "clock initialization accrues no jt yield share");
        assertEq(uint256(s0.twLPTYieldShareAccruedWAD), 0, "clock initialization accrues no lt yield share");

        // Pin both instantaneous yield shares at 0.1e18 (jt below its 0.2e18 cap, lt exactly at its 0.1e18 cap)
        jtYDM.setRates(0.1e18);
        lptYDM.setRates(0.1e18);

        // Re-sync flat in the SAME block. Zero real time has passed, so this must be a no-op: no service
        // seconds were rendered, so no premium entitlement should accrue and the YDMs should not be consulted
        kernel.doPreOp(toNAVUnits(SEED_ST_EFF + SEED_JT_EFF));

        // Past the horizon: elapsed reads block.timestamp - 5000 = 2^32, the elapsed == 0 guard misses, both YDMs
        // are consulted, and each accumulator jumps by 0.1e18 x 4294967296 in a zero-second window
        IRoycoDayAccountant.RoycoDayAccountantState memory s1 = accountant.getState();
        assertEq(jtYDM.yieldShareCallCount(), 1, "the jt YDM is wrongly consulted for a zero-second window");
        assertEq(lptYDM.yieldShareCallCount(), 1, "the lt YDM is wrongly consulted for a zero-second window");
        assertEq(
            uint256(s1.twJTYieldShareAccruedWAD), 429_496_729_600_000_000_000_000_000, "jt accumulator jumps by rate x 2^32 despite zero real elapsed time"
        );
        assertEq(
            uint256(s1.twLPTYieldShareAccruedWAD), 429_496_729_600_000_000_000_000_000, "lt accumulator jumps by rate x 2^32 despite zero real elapsed time"
        );
        assertEq(s1.lastYieldShareAccrualTimestamp, 5000, "the re-stamp truncates back to the same low 32 bits, re-arming the wrap");
    }

    /**
     * @notice Premium window: past the uint32 horizon, with both premium caps at 0.1e18 (so at most 20% of any
     *         senior gain should ever leave as premiums), a handful of flat syncs poison the accumulators so
     *         badly that every subsequent gain-bearing sync reverts with PREMIUMS_EXCEED_SENIOR_YIELD — and the
     *         accumulators only reset when a premium is actually paid, which now can never happen, so the market
     *         cannot heal itself
     * @dev Each 1-second flat sync accrues rate x (2^32 + 1) per leg instead of rate x 1, while the premium
     *      payment window itself only over-reads by a single 2^32. Six such syncs stack a 6 x 2^32-scale
     *      numerator against a 1 x 2^32-scale window, so the premium fraction reads about 6 x cap = 0.6 per
     *      leg (1.2 combined) where the correct bound is the 0.1 cap per leg (0.2 combined)
     */
    function test_premiumWindow_wrapsAtUint32_gainSyncRevertsPremiumsExceedSeniorYield() public {
        // Deploy with both premium caps at 0.1e18: jt risk premium plus lt liquidity premium should together
        // never exceed 20% of a senior gain, which is what makes the revert below a pure clock artifact
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.maxJTYieldShareWAD = 0.1e18;
        p.maxLPTYieldShareWAD = 0.1e18;
        _deploy(p);

        // Initialize both clocks past the uint32 horizon: each stamps as uint32(2^32 + 5000) = 5000
        uint256 t0 = TWO_POW_32 + 5000;
        vm.warp(t0);
        _seedAndInitAccrual();
        jtYDM.setRates(0.1e18);
        lptYDM.setRates(0.1e18);

        // Six flat syncs spaced one real second apart. Each should accrue rate x 1s = 0.1e18 per leg (0.6e18
        // total), but every fresh stamp keeps losing its 2^32 bit, so each sync reads elapsed = 2^32 + 1 and
        // accrues 0.1e18 x 4294967297 per leg. After six: 6 x 0.1e18 x 4294967297 = 2576980378200000000000000000
        for (uint256 i = 1; i <= 6; ++i) {
            vm.warp(t0 + i);
            kernel.doPreOp(toNAVUnits(SEED_ST_EFF + SEED_JT_EFF));
        }
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(uint256(s.twJTYieldShareAccruedWAD), 2_576_980_378_200_000_000_000_000_000, "jt accumulator holds six phantom 2^32-second accruals");
        assertEq(uint256(s.twLPTYieldShareAccruedWAD), 2_576_980_378_200_000_000_000_000_000, "lt accumulator holds six phantom 2^32-second accruals");
        assertEq(s.lastPremiumPaymentTimestamp, 5000, "no premium was paid on the flat syncs so the payment window still opens at the truncated init stamp");

        // Zero the forward rates: even if the YDMs never award another basis point of yield share from here
        // on, the poison already banked in the accumulators is enough to brick the market
        jtYDM.setRates(0);
        lptYDM.setRates(0);

        // A modest +12e18 collateral gain one second later attributes deltaST = floor(12e18 * 1000e18 / 1200e18)
        // = 10e18 of senior gain. With a correctly sized clock the accumulators would hold six 1-second accruals
        // of 0.1e18 = 0.6e18 per leg over a 7-second window, so each premium would be
        // floor(10e18 x 0.6e18 / (7 x 1e18)) = 857142857142857142, about 0.086 x the senior gain per leg — well
        // within the gain. Past the horizon: the window reads block.timestamp - 5000 = 2^32 + 7 = 4294967303 seconds
        // against accumulators of 6 x 0.1e18 x (2^32 + 1), so each leg computes
        // floor(10e18 x 2576980378200000000000000000 / (4294967303 x 1e18)) = 5999999991618096842 and the two
        // legs sum to 11999999983236193684 > the 10e18 senior gain, tripping the premiums-exceed-senior-yield guard
        vm.warp(t0 + 7);
        vm.expectRevert(IRoycoDayAccountant.PREMIUMS_EXCEED_SENIOR_YIELD.selector);
        kernel.doPreOp(toNAVUnits(SEED_ST_EFF + SEED_JT_EFF + 12e18));

        // The brick is persistent: the accumulators only reset when premiums are actually paid, and every
        // gain-bearing sync now reverts before paying. The window grows one second per block against a
        // 6 x 2^32-scale numerator, so diluting the combined premium back under the gain would take on the
        // order of 1.2 x 2^32 seconds (about 163 more years). One block later the same gain still reverts
        vm.warp(t0 + 8);
        vm.expectRevert(IRoycoDayAccountant.PREMIUMS_EXCEED_SENIOR_YIELD.selector);
        kernel.doPreOp(toNAVUnits(SEED_ST_EFF + SEED_JT_EFF + 12e18));
    }
}
