// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayFixedRateAccountant } from "../../../src/interfaces/accountant/IRoycoDayFixedRateAccountant.sol";
import { ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { Operation, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { FixedRateAccountantFuzzTestBase } from "../../utils/FixedRateAccountantFuzzTestBase.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";

/**
 * @title TestFuzz_FixedAccrualWindows_FixedRateAccountant
 * @notice Fuzz properties for the fixed rate accountant's dual clock bookkeeping under interleaved syncs,
 *         deposits, redemptions, and warps: the time-weighted LPT accumulator integrates the capped yield
 *         share over a contiguous window that starts at the last premium payment, extends to the last sync
 *         with no gaps and no double-counting, and resets exactly when a sync pays the premium - never on
 *         losses, flat syncs, coupon-only settlements, or post-ops - while the coupon clock restamps on
 *         every NAV-moving sync and only there, so the two clocks move independently through one sync
 * @dev The model tracks the expected accumulator, clocks, and premiums-paid outcomes step by step, with each
 *      sync's outcome taken from the independent RoycoTestMath fixed mirror rather than from production. The
 *      model lives in contract storage purely to keep stack frames small - every fuzz run starts from a
 *      fresh state, so no data leaks between runs
 */
contract TestFuzz_FixedAccrualWindows_FixedRateAccountant is FixedRateAccountantFuzzTestBase {
    /// @dev The fuzzed constant yield share the mock LPT YDM pins for the whole run
    uint256 internal pinnedLPTRate;

    /// @dev The expected accrual and settlement bookkeeping, carried across the fuzzed steps
    uint256 internal modelTwLPT;
    uint256 internal modelLastAccrual;
    uint256 internal modelLastPayment;
    uint256 internal modelCouponClock;

    /// @dev The running marks the next step moves from
    uint256 internal collateralNAV;
    uint256 internal lptRawNAV;

    /**
     * Scenario: a seeded market lives through eight fuzzed steps, each an arbitrary warp followed by one of
     * a flat sync, a gain sync, a loss sync, a senior or junior deposit, or a senior redemption. The premium
     * a gain sync pays is the excess weighted by accumulator / window, so the accounting is only fair if the
     * accumulator covers exactly the window it is divided by, and the coupon is only fair if its window runs
     * exactly from the last NAV-moving sync: a skipped stretch under-pays, a double-counted one over-pays,
     * and a reset or restamp at the wrong step silently changes the APY. After every step the accountant's
     * accumulator, all three clocks, and the settled NAVs must match the mirror-driven step model, and the
     * accumulator must equal the capped constant share integrated over exactly [last premium payment, last
     * accrual] - the closed form only a contiguous window satisfies.
     */
    function testFuzz_AccrualWindows_ContiguousAndResetOnlyWhenPremiumsPay(
        uint256 _stEff0,
        uint256 _jtEff0,
        uint256 _lptRaw0,
        uint256 _rate,
        uint256 _lptRate,
        uint256[8] memory _warps,
        uint256[8] memory _actions,
        uint256[8] memory _moves
    )
        public
    {
        _prepareMarket(_stEff0, _jtEff0, _lptRaw0, _rate, _lptRate);
        for (uint256 i = 0; i < 8; ++i) {
            _step(_warps[i], _actions[i], _moves[i]);
        }
    }

    /**
     * Scenario: an attacker lands a second gain sync in the very same block as the one that just paid the
     * premium, hoping the spent accrual window is read twice and the liquidity provider tranche is paid twice
     * out of one excess. Zero elapsed time means zero fresh accrual, so the accumulator must not grow between
     * the two syncs and the second sync's premium must be derived from an empty (or unchanged) window - never
     * from re-reading the accrual the first sync already consumed.
     */
    function testFuzz_AccrualWindows_SameBlockRepeatGainSyncCannotReuseTheSpentWindow(
        uint256 _stEff0,
        uint256 _jtEff0,
        uint256 _lptRaw0,
        uint256 _rate,
        uint256 _lptRate,
        uint256 _window,
        uint256 _gain1,
        uint256 _gain2
    )
        public
    {
        _prepareMarket(_stEff0, _jtEff0, _lptRaw0, _rate, _lptRate);

        // A real accrual window from one second to the ten-year suite ceiling, then the first gain sync
        vm.warp(vm.getBlockTimestamp() + bound(_window, 1, MAX_ELAPSED));
        _stepSync(int256(bound(_gain1, 1, 10_000))); // +0.01% to +100% gain: pays unless the coupon consumes it
        _assertWindowBookkeeping();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantState memory afterFirst = accountant.getRoycoDayFixedRateAccountantState();

        // The attack: a second gain sync with zero elapsed time (the mirror inside _stepSync re-derives the
        // exact premium this sync may pay from the unchanged model window)
        _stepSync(int256(bound(_gain2, 1, 10_000))); // +0.01% to +100% same-block follow-up gain
        _assertWindowBookkeeping();

        // Zero elapsed time accrues nothing: the accumulator can only shrink (a payout reset), never grow
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantState memory afterSecond = accountant.getRoycoDayFixedRateAccountantState();
        assertLe(
            uint256(afterSecond.twLPTYieldShareAccruedWAD),
            uint256(afterFirst.twLPTYieldShareAccruedWAD),
            "a same-block repeat sync must not grow the liquidity accumulator"
        );
        assertEq(
            uint256(afterSecond.lastYieldShareAccrualTimestamp),
            uint256(afterFirst.lastYieldShareAccrualTimestamp),
            "the accrual timestamp must not move within one block"
        );
    }

    /**
     * Scenario: nothing touches the market for the full ten-year fuzz ceiling, then a gain sync lands. The
     * accumulator entering that sync must equal the capped constant share integrated over exactly the whole
     * idle stretch - a decade of inactivity neither forfeits accrued premium (an under-read) nor inflates it
     * (an overflow or double-count) - and the sync must settle its payout and its decade-long coupon window
     * from exactly that stretch.
     */
    function testFuzz_AccrualWindows_MaxElapsedWindowAccruesExactlyThenSettles(
        uint256 _stEff0,
        uint256 _jtEff0,
        uint256 _lptRaw0,
        uint256 _rate,
        uint256 _lptRate,
        uint256 _gain
    )
        public
    {
        _prepareMarket(_stEff0, _jtEff0, _lptRaw0, _rate, _lptRate);

        // The first-ever sync only initializes the accrual clock (it accrues nothing by construction)
        _stepSync(0);
        _assertWindowBookkeeping();

        // The maximal idle stretch this suite models, with no interaction in between
        vm.warp(vm.getBlockTimestamp() + MAX_ELAPSED);

        // Pin the window the next sync will read: capped share x the full ten-year stretch, exact arithmetic
        (uint256 twLPT, uint256 elapsedSincePayment) = _premiumWindow(pinnedLPTRate);
        assertEq(twLPT, Math.min(pinnedLPTRate, DEFAULT_MAX_LPT_YIELD_SHARE_WAD) * MAX_ELAPSED, "the liquidity accumulator must cover the entire idle decade");
        assertEq(elapsedSincePayment, MAX_ELAPSED, "the premium window must span the entire idle decade");

        // The gain sync settles against that maximal window; _stepSync asserts the payout via the mirror
        _stepSync(int256(bound(_gain, 1, 10_000))); // +0.01% to +100% gain after the decade of inactivity
        _assertWindowBookkeeping();
    }

    /**
     * Scenario: a gain sync whose entire gain is consumed by the coupon settles the coupon and restamps the
     * coupon clock, but pays no premium: the accumulator and the premium payment clock must be untouched even
     * though the sync settled. The two clocks the fixed flavor persists move independently through one sync,
     * and conflating them would either forfeit the LPT's accrued window on every coupon-only settlement or
     * hold the coupon window open past its settlement.
     */
    function testFuzz_AccrualWindows_CouponOnlySettlementRestampsCouponClockNotPremiumClock(uint256 _lptRate, uint256 _window, uint256 _gain) public {
        // The default seeded market with the default rate: a live coupon demand over any nonzero window
        _prepareMarket(SEED_ST_EFF, SEED_JT_EFF, SEED_LPT_RAW, DEFAULT_ST_FIXED_RATE_PER_SECOND_WAD, _lptRate);
        _stepSync(0);
        _assertWindowBookkeeping();

        // A window long enough that the coupon demand is at least one wei at the default rate and seed
        uint256 window = bound(_window, 1, MAX_ELAPSED);
        vm.warp(vm.getBlockTimestamp() + window);
        uint256 couponDue = Math.mulDiv(SEED_ST_EFF, DEFAULT_ST_FIXED_RATE_PER_SECOND_WAD * window, WAD);

        // A gain of at most the coupon demand: the coupon consumes the whole gain, so no excess distributes
        uint256 gain = bound(_gain, 1, couponDue);
        uint256 couponClockBefore = modelCouponClock;
        (uint256 twBefore,) = _premiumWindow(pinnedLPTRate);
        _stepSyncAbsolute(collateralNAV + gain);
        _assertWindowBookkeeping();

        // The coupon clock restamped and the premium bookkeeping survived: the two clocks diverged in one sync
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantState memory sFixed = accountant.getRoycoDayFixedRateAccountantState();
        assertEq(uint256(sFixed.lastCouponSettlementTimestamp), vm.getBlockTimestamp(), "a coupon-only settlement must restamp the coupon clock");
        assertGt(uint256(sFixed.lastCouponSettlementTimestamp), couponClockBefore, "the coupon clock must have moved off the previous settlement");
        assertEq(uint256(sFixed.twLPTYieldShareAccruedWAD), twBefore, "a coupon-only settlement must not touch the accrued premium window");
        assertEq(uint256(sFixed.lastPremiumPaymentTimestamp), modelLastPayment, "a coupon-only settlement must not stamp the premium payment clock");
    }

    /// @dev Bounds the seed inputs, deploys the market with the pinned rates, seeds it, and starts the model
    function _prepareMarket(uint256 _stEff0, uint256 _jtEff0, uint256 _lptRaw0, uint256 _rate, uint256 _lptRate) internal {
        uint256 stEff0 = bound(_stEff0, 0, MAX_NAV); // full NAV range incl. the empty-tranche edge
        uint256 jtEff0 = bound(_jtEff0, 0, MAX_NAV); // full NAV range incl. the uncovered-market edge
        lptRawNAV = bound(_lptRaw0, 0, MAX_NAV); // full NAV range incl. the no-depth edge
        uint256 rate = bound(_rate, 0, 5e9); // zero-coupon through five times the default fixed rate
        pinnedLPTRate = bound(_lptRate, 0, WAD); // full YDM output range, the accountant caps it at the configured max

        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _defaultParams();
        p.stFixedRatePerSecondWAD = uint64(rate);
        _deploy(p);
        lptYDM.setRates(pinnedLPTRate);
        _seedSymmetric(stEff0, jtEff0, lptRawNAV);
        collateralNAV = stEff0 + jtEff0;
        // The coupon clock is stamped once at initialization, in the deploy block alongside the seeding
        modelCouponClock = vm.getBlockTimestamp();
    }

    /// @dev Warps, dispatches one fuzzed step (sync, deposit, or redemption), and asserts the bookkeeping after it
    function _step(uint256 _warp, uint256 _action, uint256 _move) internal {
        // Same-block (0) through a year per step, so windows span multiple syncs and same-block interleavings stay in play
        vm.warp(vm.getBlockTimestamp() + bound(_warp, 0, 365 days));
        // Uniform: flat sync, gain sync, loss sync, senior deposit, junior deposit, senior redemption
        uint256 action = bound(_action, 0, 5);
        if (action == 0) {
            _stepSync(0);
        } else if (action == 1) {
            // Gain of +0.01% to +100%: pays the premium unless the repayment and the coupon consume it
            _stepSync(int256(bound(_move, 1, 10_000)));
        } else if (action == 2) {
            // Loss of -0.01% to -100%: never pays, the accumulator must keep growing
            _stepSync(-int256(bound(_move, 1, 10_000)));
        } else if (action == 5) {
            // A senior redemption runs the post-op path, which must leave every clock untouched. The amount
            // is clamped to the live senior claim, falling back to a flat sync when there is none to redeem
            uint256 committedStEff = toUint256(accountant.getState().lastSTEffectiveNAV);
            if (committedStEff == 0) _stepSync(0);
            else _stepRedeemST(bound(_move, 1, committedStEff));
        } else {
            // Deposits run the post-op path, which must leave the accrual bookkeeping completely untouched
            _stepDeposit(action == 3, bound(_move, 1, MAX_NAV));
        }
        _assertWindowBookkeeping();
    }

    /// @dev Runs one pre-op sync moving the collateral by the signed basis points
    function _stepSync(int256 _bps) internal {
        _stepSyncAbsolute(_afterMove(collateralNAV, _bps));
    }

    /**
     * @dev Runs one pre-op sync to the absolute collateral mark, asserting the sync output against the mirror
     *      driven by the modeled window, then applies the mirror's outcomes to the model: the accumulator
     *      zeroes and the payment clock advances only when the premium pays, and the coupon clock restamps
     *      only when the collateral NAV moved
     */
    function _stepSyncAbsolute(uint256 _collateralNew) internal {
        _modelAccrual();
        RoycoTestMath.FixedSyncOutputs memory out = _syncAndAssertPayout(_collateralNew);

        // The reset rule: a paid premium closes the accrual window, anything else leaves it accruing
        if (out.premiumsPaid) {
            modelTwLPT = 0;
            modelLastPayment = vm.getBlockTimestamp();
        }
        // The restamp rule: a NAV movement settles the coupon window, a flat sync leaves it open
        if (out.couponSettled) modelCouponClock = vm.getBlockTimestamp();
        collateralNAV = _collateralNew;
    }

    /**
     * @dev Derives the expected sync output from the modeled windows through the independent mirror, executes
     *      the sync plus the liquidity commit, and asserts the premium- and coupon-bearing fields
     */
    function _syncAndAssertPayout(uint256 _collateralNew) internal returns (RoycoTestMath.FixedSyncOutputs memory out) {
        RoycoTestMath.FixedSyncInputs memory in_ =
            _fixedMirrorInput(_collateralNew, lptRawNAV, modelTwLPT, vm.getBlockTimestamp() - modelLastPayment, pinnedLPTRate);
        // The mirror prices the coupon window from the model's clock, so a production clock drift is caught in NAV
        in_.elapsedSinceCouponSettlement = vm.getBlockTimestamp() - modelCouponClock;
        out = RoycoTestMath.syncFixedRateTrancheAccounting(in_);

        SyncedAccountingState memory st = kernel.doPreOp(toNAVUnits(_collateralNew));
        kernel.doCommit(toNAVUnits(lptRawNAV));

        // The coupon and the premium folded into the effective NAVs tie the modeled windows to the sync's payout
        assertEq(toUint256(st.stEffectiveNAV), out.stEffectiveNAV, "sync step: senior effective NAV must fold in exactly the modeled coupon and premium");
        assertEq(toUint256(st.jtEffectiveNAV), out.jtEffectiveNAV, "sync step: junior effective NAV must fold in exactly the modeled coupon and premium");
        assertEq(toUint256(st.jtImpermanentLoss), out.jtImpermanentLoss, "sync step: impermanent loss must come from the modeled windows");
        assertEq(toUint256(st.lptLiquidityPremium), out.lptLiquidityPremium, "sync step: liquidity premium must come from the modeled window");
        assertEq(toUint256(st.stProtocolFee), out.stProtocolFee, "sync step: senior fee must price the modeled coupon");
    }

    /**
     * @dev Models the accrual a sync performs before its tranche accounting: a first-ever sync initializes
     *      both premium timestamps and accrues nothing, every later sync extends the accumulator by the
     *      capped pinned share x seconds since the last accrual (a same-block sync extends by nothing)
     */
    function _modelAccrual() internal {
        if (modelLastAccrual == 0) {
            modelLastAccrual = vm.getBlockTimestamp();
            modelLastPayment = vm.getBlockTimestamp();
        } else if (vm.getBlockTimestamp() > modelLastAccrual) {
            modelTwLPT += Math.min(pinnedLPTRate, DEFAULT_MAX_LPT_YIELD_SHARE_WAD) * (vm.getBlockTimestamp() - modelLastAccrual);
            modelLastAccrual = vm.getBlockTimestamp();
        }
    }

    /// @dev Runs one post-op deposit through the kernel passthrough, which must not touch any clock or window
    function _stepDeposit(bool _seniorSide, uint256 _add) internal {
        Operation op = _seniorSide ? Operation.ST_DEPOSIT : Operation.JT_DEPOSIT;
        collateralNAV += _add;
        kernel.doPostOp(op, toNAVUnits(collateralNAV), toNAVUnits(lptRawNAV), ZERO_NAV_UNITS);
    }

    /// @dev Runs one post-op senior redemption through the kernel passthrough, which must not touch any clock or window
    function _stepRedeemST(uint256 _redeem) internal {
        collateralNAV -= _redeem;
        kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(collateralNAV), toNAVUnits(lptRawNAV), ZERO_NAV_UNITS);
    }

    /// @dev Asserts the accountant's window bookkeeping equals the model and satisfies the contiguity closed form
    function _assertWindowBookkeeping() internal view {
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantState memory sFixed = accountant.getRoycoDayFixedRateAccountantState();
        assertEq(uint256(sFixed.twLPTYieldShareAccruedWAD), modelTwLPT, "window: liquidity accumulator diverged from the step model");
        assertEq(uint256(sFixed.lastYieldShareAccrualTimestamp), modelLastAccrual, "window: last accrual timestamp diverged from the step model");
        assertEq(uint256(sFixed.lastPremiumPaymentTimestamp), modelLastPayment, "window: last premium payment timestamp diverged from the step model");
        assertEq(uint256(sFixed.lastCouponSettlementTimestamp), modelCouponClock, "window: the coupon clock diverged from the step model");

        // Contiguity closed form: with a constant pinned share, the accumulator equals the capped share
        // integrated over exactly [lastPayment, lastAccrual]. A skipped stretch reads low, a double-counted
        // one reads high, and a reset without a payment breaks the window start
        uint256 window = uint256(sFixed.lastYieldShareAccrualTimestamp) - uint256(sFixed.lastPremiumPaymentTimestamp);
        assertEq(
            uint256(sFixed.twLPTYieldShareAccruedWAD),
            Math.min(pinnedLPTRate, DEFAULT_MAX_LPT_YIELD_SHARE_WAD) * window,
            "window: liquidity accumulator != capped share x contiguous window"
        );
    }
}
