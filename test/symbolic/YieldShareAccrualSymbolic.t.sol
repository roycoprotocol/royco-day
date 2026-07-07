// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { IRoycoDayAccountant } from "../../src/interfaces/IRoycoDayAccountant.sol";
import { MarketState } from "../../src/libraries/Types.sol";
import { SettableYDM } from "../mocks/SettableYDM.sol";
import { WaterfallSyncDriver } from "../mocks/WaterfallSyncDriver.sol";

/**
 * @title YieldShareAccrualSymbolicSpec
 * @notice Native symbolic specs (`forge test --symbolic`) for the accountant's time-weighted yield share
 *         accrual and its configuration cap: the first-ever accrual returns zero and stamps both clocks, a
 *         same-block accrual is a pure read, one accrual step adds exactly the capped instantaneous yield
 *         share times the elapsed seconds to each accumulator, the two accumulators together can never
 *         outgrow the elapsed window's 100%-of-yield budget (the inductive fact the premium cap guard in the
 *         sync waterfall depends on), the view-path accrual preview matches the mutating accrual, and the
 *         max yield share configuration is accepted exactly when the two maxima sum to at most 100%
 * @dev Every check seeds the accountant's clocks, accumulators, and yield share caps straight into storage
 *      through the sync driver and points both YDM slots at settable mocks, so each accrual is closed
 *      arithmetic over a mocked instantaneous yield share. The coverage and liquidity requirements are
 *      seeded zero, which short-circuits both utilization reads to constants and keeps the utilization
 *      math out of these properties (it is owned by its own symbolic file). The block timestamp is pinned
 *      to a concrete value inside the uint32 clock range and the seeded clocks range symbolically below it,
 *      so elapsed windows cover the whole physical span from one second to the full clock width. Expected
 *      values are derived with plain checked multiply on the bounded domain (capped shares fit uint64,
 *      elapsed fits uint32, so every product is far below 2^96), never by re-running the production path
 */
contract YieldShareAccrualSymbolicSpec is Test {
    /// @dev WAD fixed-point unit, 1e18 == 100%
    uint256 internal constant WAD = 1e18;

    /// @dev The concrete block timestamp every check runs at (fits the accountant's uint32 clocks)
    uint256 internal constant SYNC_TIMESTAMP = 4_000_000_000;

    /// @dev Accumulator headroom bound: increments are below 2^96, so any accumulator at or below 2^190
    ///      accepts an accrual step without overflowing its uint192 storage field
    uint192 internal constant MAX_ACCUMULATOR = uint192(2 ** 190);

    WaterfallSyncDriver internal driver;
    SettableYDM internal jtYdm;
    SettableYDM internal ltYdm;

    function setUp() public {
        // The kernel address is irrelevant here: every check drives the internal accrual, not the kernel entrypoints
        driver = new WaterfallSyncDriver(address(1), false);
        // Distinct settable YDMs so the junior and liquidity legs carry independent symbolic yield shares
        jtYdm = new SettableYDM();
        ltYdm = new SettableYDM();
        vm.warp(SYNC_TIMESTAMP);
    }

    /*//////////////////////////////////////////////////////////////////////
                            CHECKPOINT SEEDING
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @dev Seeds exactly the state the accrual reads: the two clocks, the two time-weighted accumulators,
     *      the two per-tranche yield share caps, the two YDM addresses, and a perpetual market state. Every
     *      NAV field and both the coverage and liquidity requirements stay zero, so the utilization inputs
     *      the YDMs receive are constants and the mocked yield share is the only symbolic YDM-side input
     */
    function _accrualSeed(
        uint32 _lastAccrual,
        uint32 _lastPay,
        uint192 _twJT,
        uint192 _twLT,
        uint64 _maxJT,
        uint64 _maxLT
    )
        internal
        view
        returns (IRoycoDayAccountant.RoycoDayAccountantState memory seed)
    {
        seed.lastMarketState = MarketState.PERPETUAL;
        seed.lastYieldShareAccrualTimestamp = _lastAccrual;
        seed.lastPremiumPaymentTimestamp = _lastPay;
        seed.twJTYieldShareAccruedWAD = _twJT;
        seed.twLTYieldShareAccruedWAD = _twLT;
        seed.maxJTYieldShareWAD = _maxJT;
        seed.maxLTYieldShareWAD = _maxLT;
        seed.jtYDM = address(jtYdm);
        seed.ltYDM = address(ltYdm);
    }

    /*//////////////////////////////////////////////////////////////////////
                        BOOTSTRAP: FIRST ACCRUAL IS THE ZERO BASIS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The very first accrual of a market (a zero accrual clock) returns zero for both time-weighted
     *         yield shares, stamps both the accrual clock and the premium payment clock to the current block,
     *         leaves the stored accumulators untouched, and never consults a YDM. The preview path returns the
     *         same zero pair. This is the induction basis of the accrual budget: the very first premium window
     *         opens empty, so no yield share can be back-charged for time before the market existed
     * @dev Economic why: before the first accrual there is no window over which senior yield was earned, so
     *      any nonzero accrual here would price a premium for coverage or liquidity that was never provided.
     *      Both YDM mocks are poisoned with the maximum representable yield share so that if the accrual ever
     *      reached the YDM-consulting step path from a zero clock (elapsed would be the whole timestamp), the
     *      returned pair could not be zero and the assertion would expose it. The premium payment clock and
     *      both accumulators are symbolic to prove the bootstrap ignores whatever they hold
     */
    function check_firstAccrualReturnsZeroAndStampsBothClocks(uint192 twJT, uint192 twLT, uint32 lastPay) external {
        // Poisoned YDM outputs: unreachable on the bootstrap branch, loudly nonzero if it were ever taken
        jtYdm.setYieldShare(type(uint256).max);
        ltYdm.setYieldShare(type(uint256).max);
        driver.seedCheckpoint(_accrualSeed(0, lastPay, twJT, twLT, type(uint64).max, type(uint64).max));

        // The view path agrees with the basis: zero accrued yield share before the first stamp
        (uint192 previewJT, uint192 previewLT) = driver.previewPremiumYieldShareAccrual();
        assert(previewJT == 0 && previewLT == 0);

        (uint192 accruedJT, uint192 accruedLT) = driver.accruePremiumYieldShares();
        assert(accruedJT == 0 && accruedLT == 0);

        // Both clocks are stamped to the current block, whatever the payment clock previously held: the first
        // premium window starts now, with zero accrued width behind it
        IRoycoDayAccountant.RoycoDayAccountantState memory state = driver.getState();
        assert(state.lastYieldShareAccrualTimestamp == uint32(SYNC_TIMESTAMP));
        assert(state.lastPremiumPaymentTimestamp == uint32(SYNC_TIMESTAMP));
        // The stored accumulators are not rewritten by the bootstrap: it stamps clocks and reports zero
        assert(state.twJTYieldShareAccruedWAD == twJT);
        assert(state.twLTYieldShareAccruedWAD == twLT);
    }

    /*//////////////////////////////////////////////////////////////////////
                        SAME-BLOCK ACCRUAL IS A PURE READ
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice An accrual in the same block as the previous one (zero elapsed time) returns exactly the stored
     *         accumulators, changes no storage, and never consults a YDM, and the preview path returns the
     *         identical pair. Any number of syncs inside one block therefore price against the same accrued
     *         window, and no intra-block replay can widen a premium
     * @dev Economic why: the accumulators are integrals of per-second yield shares over wall-clock time, and
     *      zero seconds contributes zero area no matter what the instantaneous yield share is. If the
     *      same-block path consulted the YDMs at all, an attacker able to move the YDM output intra-block
     *      (through utilization-moving operations) could re-price an already-accrued window. Both YDM mocks
     *      are poisoned with the maximum representable yield share so the zero-second window is the only
     *      thing keeping the outputs equal to the stored accumulators
     */
    function check_sameBlockAccrualIsIdempotent(uint192 twJT, uint192 twLT, uint32 lastPay, uint64 maxJT, uint64 maxLT) external {
        jtYdm.setYieldShare(type(uint256).max);
        ltYdm.setYieldShare(type(uint256).max);
        // The accrual clock already sits at the current block, so this accrual's elapsed window is zero wide
        driver.seedCheckpoint(_accrualSeed(uint32(SYNC_TIMESTAMP), lastPay, twJT, twLT, maxJT, maxLT));

        (uint192 previewJT, uint192 previewLT) = driver.previewPremiumYieldShareAccrual();
        (uint192 accruedJT, uint192 accruedLT) = driver.accruePremiumYieldShares();

        // Both paths report exactly the stored accumulators: a zero-width window accrues nothing
        assert(previewJT == twJT && previewLT == twLT);
        assert(accruedJT == twJT && accruedLT == twLT);

        // Storage is bit-identical: accumulators unchanged, both clocks unchanged
        IRoycoDayAccountant.RoycoDayAccountantState memory state = driver.getState();
        assert(state.twJTYieldShareAccruedWAD == twJT);
        assert(state.twLTYieldShareAccruedWAD == twLT);
        assert(state.lastYieldShareAccrualTimestamp == uint32(SYNC_TIMESTAMP));
        assert(state.lastPremiumPaymentTimestamp == lastPay);
    }

    /*//////////////////////////////////////////////////////////////////////
                ONE ACCRUAL STEP ADDS CAPPED SHARE TIMES ELAPSED
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice One accrual step over a positive elapsed window adds exactly min(instantaneous yield share,
     *         configured maximum) times the elapsed seconds to each tranche's accumulator, advances the
     *         accrual clock to the current block, and leaves the premium payment clock alone (only a
     *         committed premium payment may close a window). The YDM's raw output ranges over the full
     *         uint256 and the cap is what bounds the accrual
     * @dev Economic why: the accumulator is the integral of the capped per-second yield share, so one step
     *      must add exactly the rectangle capped-share times elapsed, and the cap is the governance-set
     *      ceiling on what fraction of senior yield each tranche may earn per second, applied before any
     *      time weighting so a hostile or buggy YDM cannot out-accrue it. The expected increment is a plain
     *      checked multiply: the capped share fits uint64 and elapsed fits uint32, so the product is below
     *      2^96 and the production cast of the increment into the uint192 accumulator field is lossless on
     *      this whole domain. That losslessness holds structurally (uint64 cap times uint32 clock width),
     *      so widening either the yield share cap field or the clock fields would need this re-proved.
     *      Accumulators start at or below 2^190 so the checked accumulator addition has headroom
     */
    /// forge-config: default.symbolic.solver = "bitwuzla"
    function check_accrualAddsExactlyCappedShareTimesElapsed(
        uint256 yJT,
        uint256 yLT,
        uint64 maxJT,
        uint64 maxLT,
        uint192 twJT,
        uint192 twLT,
        uint32 lastAccrual
    )
        external
    {
        // A positive elapsed window anywhere in the uint32 clock range
        vm.assume(1 <= lastAccrual && lastAccrual < SYNC_TIMESTAMP);
        vm.assume(twJT <= MAX_ACCUMULATOR && twLT <= MAX_ACCUMULATOR);
        uint256 elapsed = SYNC_TIMESTAMP - lastAccrual;

        jtYdm.setYieldShare(yJT);
        ltYdm.setYieldShare(yLT);
        driver.seedCheckpoint(_accrualSeed(lastAccrual, lastAccrual, twJT, twLT, maxJT, maxLT));

        (uint192 accruedJT, uint192 accruedLT) = driver.accruePremiumYieldShares();

        // Independently derived increments: the cap binds first, then the plain checked multiply by elapsed
        uint256 cappedJT = yJT < maxJT ? yJT : maxJT;
        uint256 cappedLT = yLT < maxLT ? yLT : maxLT;
        assert(uint256(accruedJT) == uint256(twJT) + cappedJT * elapsed);
        assert(uint256(accruedLT) == uint256(twLT) + cappedLT * elapsed);

        // The returned pair is the committed pair, the accrual clock advances to now, and the premium payment
        // clock is untouched: accrual widens the open window, only a paid premium may close it
        IRoycoDayAccountant.RoycoDayAccountantState memory state = driver.getState();
        assert(state.twJTYieldShareAccruedWAD == accruedJT);
        assert(state.twLTYieldShareAccruedWAD == accruedLT);
        assert(state.lastYieldShareAccrualTimestamp == uint32(SYNC_TIMESTAMP));
        assert(state.lastPremiumPaymentTimestamp == lastAccrual);
    }

    /*//////////////////////////////////////////////////////////////////////
                THE ACCRUED SUM NEVER OUTGROWS THE WINDOW BUDGET
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The inductive step of the accrual budget: if the two accumulators together are within the budget
     *         of the window accrued so far (at most one WAD per second between the premium payment clock and
     *         the accrual clock) and the two configured maxima sum to at most WAD, then after one more accrual
     *         step the accumulators are within the budget of the extended window (one WAD per second between
     *         the premium payment clock and now). Together with the zero basis proved by the bootstrap check,
     *         this bounds every reachable accumulator pair by elapsed-seconds times WAD
     * @dev Economic why: the accumulators are what the sync waterfall divides by the window width to recover
     *      the average fraction of senior yield owed as the JT risk and LT liquidity premiums, so their sum
     *      exceeding one WAD per second would mean the two premiums together could draw more than 100% of the
     *      senior gain, which is exactly the state whose combined-premium guard would brick every sync. The
     *      derivation is linear: each increment is capped-share times elapsed, capped shares sum to at most
     *      WAD (any valid configuration pair does, so the bound survives a mid-window cap change), hence the
     *      increments sum to at most WAD times elapsed, and adding that to the hypothesis telescopes the two
     *      windows into one. The gain-arm premium properties in WaterfallGainArmSymbolic.t.sol consume this
     *      bound as their accrued-accumulator domain fact
     */
    /// forge-config: default.symbolic.solver = "bitwuzla"
    function check_accruedShareSumNeverExceedsElapsedBudget(
        uint256 yJT,
        uint256 yLT,
        uint64 maxJT,
        uint64 maxLT,
        uint192 twJT,
        uint192 twLT,
        uint32 lastPay,
        uint32 lastAccrual
    )
        external
    {
        // A live window: the premium payment clock opened it, the accrual clock has advanced within it, and
        // this step extends it by at least one second (the zero-second arm is a pure read, proved idempotent
        // by its own check, and the budget's right side only grows with time, so induction holds there too)
        vm.assume(1 <= lastAccrual && lastAccrual < SYNC_TIMESTAMP);
        vm.assume(lastPay <= lastAccrual);
        // The configuration cap accepted by the config validation: the maxima sum to at most 100%
        vm.assume(uint256(maxJT) + uint256(maxLT) <= WAD);
        // The inductive hypothesis: the sum accrued so far fits the window accrued so far
        vm.assume(uint256(twJT) + uint256(twLT) <= uint256(lastAccrual - lastPay) * WAD);

        jtYdm.setYieldShare(yJT);
        ltYdm.setYieldShare(yLT);
        driver.seedCheckpoint(_accrualSeed(lastAccrual, lastPay, twJT, twLT, maxJT, maxLT));

        (uint192 accruedJT, uint192 accruedLT) = driver.accruePremiumYieldShares();

        // The extended window's budget holds: at most one WAD of combined yield share per elapsed second
        // since the last premium payment
        assert(uint256(accruedJT) + uint256(accruedLT) <= (SYNC_TIMESTAMP - uint256(lastPay)) * WAD);
    }

    /*//////////////////////////////////////////////////////////////////////
                    PREVIEW ACCRUAL MATCHES MUTATING ACCRUAL
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice On a positive elapsed window, the view-path accrual preview returns exactly the pair the
     *         mutating accrual then commits, for any YDM output, any caps, and any starting accumulators
     *         with headroom, provided the YDM itself answers its preview and its mutating query identically
     *         in the same block (the mocks here do by construction, and the same-block parity of the real
     *         YDM implementations is owned by their own symbolic files)
     * @dev Economic why: the preview is what redemption and deposit quoting surfaces price against, while
     *      the mutating accrual is what the committed sync books, so any wedge between the two would let a
     *      caller be quoted one premium and settled another within the same block. The two paths must
     *      therefore run byte-equal arithmetic: same elapsed window, same cap application, same increment,
     *      differing only in whether the result is written back
     */
    function check_previewAccrualMatchesMutatingAccrual(
        uint256 yJT,
        uint256 yLT,
        uint64 maxJT,
        uint64 maxLT,
        uint192 twJT,
        uint192 twLT,
        uint32 lastAccrual
    )
        external
    {
        vm.assume(1 <= lastAccrual && lastAccrual < SYNC_TIMESTAMP);
        vm.assume(twJT <= MAX_ACCUMULATOR && twLT <= MAX_ACCUMULATOR);

        jtYdm.setYieldShare(yJT);
        ltYdm.setYieldShare(yLT);
        driver.seedCheckpoint(_accrualSeed(lastAccrual, lastAccrual, twJT, twLT, maxJT, maxLT));

        // Preview first (a pure read), then the mutating accrual against the identical starting state
        (uint192 previewJT, uint192 previewLT) = driver.previewPremiumYieldShareAccrual();
        (uint192 accruedJT, uint192 accruedLT) = driver.accruePremiumYieldShares();

        // What was quoted is what was booked
        assert(previewJT == accruedJT);
        assert(previewLT == accruedLT);
    }

    /*//////////////////////////////////////////////////////////////////////
                    THE YIELD SHARE CONFIGURATION CAP
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The yield share configuration is accepted exactly when the maximum JT and LT yield shares sum
     *         to at most WAD, computed over the full mathematical sum with no wraparound: every pair whose
     *         true sum exceeds 100% is rejected, including pairs whose uint64 addition would overflow
     * @dev Economic why: the two maxima are per-second ceilings on the fractions of senior yield the risk
     *      and liquidity premiums may draw, so their sum exceeding 100% would let the accrued accumulators
     *      outgrow the window budget and reach the sync's combined-premium guard, bricking the market. This
     *      cap is the root assumption behind the accrual budget induction above. The expected form is the
     *      independent widened sum in uint256, so it also pins the overflow polarity as safe: a pair whose
     *      uint64 sum wraps reverts with an arithmetic panic instead of the configuration error, which is
     *      still a rejection, never an acceptance
     */
    function check_maxYieldSharesAcceptedIffSumWithinWAD(uint64 maxJT, uint64 maxLT) external view {
        bool accepted;
        try driver.validateYieldShareConfig(maxJT, maxLT) {
            accepted = true;
        } catch {
            accepted = false;
        }

        // Acceptance if and only if the true (widened, wrap-free) sum fits within 100% of senior yield
        assert(accepted == (uint256(maxJT) + uint256(maxLT) <= WAD));
    }
}
