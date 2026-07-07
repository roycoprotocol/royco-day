// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { IRoycoDayAccountant } from "../../src/interfaces/IRoycoDayAccountant.sol";
import { MarketState, SyncedAccountingState } from "../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../src/libraries/Units.sol";
import { WaterfallSyncDriver } from "../mocks/WaterfallSyncDriver.sol";

/**
 * @title WaterfallConservationSymbolicSpec
 * @notice Native symbolic specs (`forge test --symbolic`) for whole-sync NAV conservation and totality across
 *         the four PnL quadrants of the accountant's waterfall: both tranches lose, senior loses while junior
 *         gains, senior gains while junior loses, and both tranches gain. Each check drives the entire sync
 *         (claims decomposition, PnL attribution, the JT and ST loss and gain arms, coverage, impermanent loss
 *         recovery, premiums, and fees) end to end from a general dirty checkpoint with cross-tranche claims
 *         admitted, and proves two things: the sync never reverts anywhere on the physical domain, and the
 *         two-term identity fresh raw total == effective total holds byte-for-byte on the outputs
 * @dev Why conservation must hold: every waterfall step is an internal transfer between the two effective NAV
 *      accumulators. Attribution splits the total raw PnL into a senior slice and a junior residual that sum to
 *      the total by construction, a junior loss debits only the junior accumulator, coverage moves value from
 *      the junior accumulator to absorb the senior loss one-for-one, impermanent loss recovery moves it back,
 *      and the premium slices shuffle a senior gain between the two accumulators without creating or destroying
 *      a wei. So the effective total moves by exactly the raw total's delta, and no value leaks or mints
 * @dev Why totality must hold: a revert in the sync bricks every deposit, redemption, and fee accrual until the
 *      state that caused it changes, so each checked subtraction has to be proven in range. Each pool's
 *      residual loss after attribution is bounded by the complementary tranche's claim on that pool (the
 *      attributed slice is a floored pro-rata piece of a claim that never exceeds the pool), so the junior loss
 *      can never exceed the junior effective NAV and the residual senior loss never exceeds the senior
 *      effective NAV, and the floored premium slices sum to at most the gain that funds them
 * @dev Checkpoints are general: the seeded effective NAVs need not match the raw NAVs (one tranche may hold a
 *      claim backed by the other's pool), only the checkpoint-level conservation identity is assumed, because
 *      the accountant enforces it on every commit so it is the reachable-state envelope. The coverage
 *      requirement is seeded zero and the fixed-term duration zero (the sync's conservation arithmetic reads
 *      neither: they only steer the post-conservation market state transition, which never touches the
 *      effective NAVs), and the block timestamp sits past the premium payment clock so the same-block branch
 *      that queries the external YDMs is statically excluded and the waterfall is closed arithmetic
 * @dev Solver notes: the two mixed quadrants run at a tightened 1e27 NAV bound (senior gain against junior
 *      loss and vice versa stack the premium and fee mulDivs on top of both loss arms); the both-lose quadrant
 *      never reaches the premium math and the both-gain quadrant never enters a loss arm, so both run at the
 *      full 1e30 suite bound
 */
contract WaterfallConservationSymbolicSpec is Test {
    /// @dev Suite-wide NAV domain bound: 1e30 NAV wei (one trillion tokens at WAD precision)
    uint256 internal constant MAX_NAV = 1e30;

    /// @dev Tightened NAV bound for the two mixed quadrants, which chain the most mulDivs (still 1e9 tokens)
    uint256 internal constant MAX_NAV_MIXED = 1e27;

    /// @dev WAD fixed-point unit, 1e18 == 100%
    uint256 internal constant WAD = 1e18;

    /// @dev Upper bound on the dust tolerances a market would realistically configure
    uint256 internal constant MAX_DUST = 1e12;

    /// @dev The concrete block timestamp every check runs at (fits the accountant's uint32 clocks)
    uint256 internal constant SYNC_TIMESTAMP = 4_000_000_000;

    WaterfallSyncDriver internal driver;

    function setUp() public {
        // The kernel address is irrelevant here: every check drives the internal preview, not the kernel entrypoints
        driver = new WaterfallSyncDriver(address(1), false);
        vm.warp(SYNC_TIMESTAMP);
    }

    /*//////////////////////////////////////////////////////////////////////
                            CHECKPOINT SEEDING
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @dev Seeds the general dirty checkpoint every quadrant check starts from. The junior effective NAV is
     *      derived as the conservation residual (raw total minus the senior effective NAV), so the seeded
     *      checkpoint always satisfies the identity the accountant enforces on every commit while leaving the
     *      cross-tranche claim split fully symbolic: a senior effective NAV above the senior raw NAV means
     *      seniors hold a claim backed by the junior pool, below it means juniors claim part of the senior pool.
     *      The market is a plain perpetual with no coverage requirement and no fixed-term machinery, all four
     *      protocol fee percentages symbolic, the effective NAV dust tolerance symbolic, and the premium payment
     *      clock symbolic in the past so the elapsed premium window spans the whole uint32 clock range
     */
    function _seedGeneralCheckpoint(
        uint256 _lastSTRaw,
        uint256 _lastJTRaw,
        uint256 _stEff,
        uint256 _il,
        uint32 _lastPay,
        uint256 _dust,
        uint64 _stFee,
        uint64 _jtFee,
        uint64 _jtYieldShareFee,
        uint64 _ltYieldShareFee
    )
        internal
    {
        IRoycoDayAccountant.RoycoDayAccountantState memory seed;
        seed.lastMarketState = MarketState.PERPETUAL;
        seed.coverageLiquidationUtilizationWAD = 2e18;
        seed.lastPremiumPaymentTimestamp = _lastPay;
        seed.lastSTRawNAV = toNAVUnits(_lastSTRaw);
        seed.lastJTRawNAV = toNAVUnits(_lastJTRaw);
        seed.lastSTEffectiveNAV = toNAVUnits(_stEff);
        // Checkpoint-level conservation: junior holds exactly what senior does not
        seed.lastJTEffectiveNAV = toNAVUnits(_lastSTRaw + _lastJTRaw - _stEff);
        seed.lastJTCoverageImpermanentLoss = toNAVUnits(_il);
        seed.effectiveNAVDustTolerance = toNAVUnits(_dust);
        seed.stProtocolFeeWAD = _stFee;
        seed.jtProtocolFeeWAD = _jtFee;
        seed.jtYieldShareProtocolFeeWAD = _jtYieldShareFee;
        seed.ltYieldShareProtocolFeeWAD = _ltYieldShareFee;
        driver.seedCheckpoint(seed);
    }

    /// @dev Runs the sync against the seeded checkpoint, asserts it completed without reverting anywhere, and
    ///      asserts the two-term conservation identity independently on the returned effective NAV outputs
    function _assertSyncSucceedsAndConserves(uint256 _freshSTRaw, uint256 _freshJTRaw, uint256 _twJT, uint256 _twLT) internal view {
        // Totality: no checked subtraction, premium cap guard, or conservation guard reverts anywhere in the sync
        (bool success, SyncedAccountingState memory state) = driver.tryRunSync(_freshSTRaw, _freshJTRaw, _twJT, _twLT);
        assert(success);
        // Conservation, re-stated independently on the outputs: the waterfall only transfers value between the
        // two effective NAV accumulators, so their total must equal the fresh raw total to the wei. Any leak
        // (value destroyed) or mint (value created) would break the redemption math of whichever tranche is on
        // the short side of it
        assert(toUint256(state.stEffectiveNAV) + toUint256(state.jtEffectiveNAV) == _freshSTRaw + _freshJTRaw);
    }

    /*//////////////////////////////////////////////////////////////////////
                        QUADRANT: BOTH TRANCHES LOSE
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice When both underlying pools mark down (or stay flat), the sync never reverts and conserves NAV:
     *         attribution splits each pool's loss pro-rata across the checkpointed claims, the junior tranche
     *         absorbs its own attributed loss plus coverage for the senior loss up to its whole buffer, and the
     *         senior tranche absorbs only the uncovered residual
     * @dev Economic why: the drawdown path is where the waterfall earns its keep, and a revert here would lock
     *      every holder into a falling market, so the loss arms must be total. The key subtraction safety is
     *      that a pool can lose at most its whole last raw NAV (a fresh mark cannot be negative), each tranche's
     *      attributed slice of that loss is a floored pro-rata piece of its claim on the pool, and the residual
     *      the other tranche eats is bounded by its own complementary claim, so no effective NAV is ever debited
     *      below zero. Bounds are tight at a full wipeout of both pools (fresh marks of zero), which this domain
     *      includes. Neither effective delta can be positive here, so the premium and fee math never runs and
     *      the accrued yield share accumulators and fee percentages are along only to pin that they stay inert
     */
    function check_syncConservesNAVAndNeverRevertsWhenBothTranchesLose(
        uint256 lastSTRaw,
        uint256 lastJTRaw,
        uint256 stEff,
        uint256 freshSTRaw,
        uint256 freshJTRaw,
        uint256 il,
        uint32 lastPay,
        uint256 twJT,
        uint256 twLT,
        uint256 dust,
        uint64 stFee,
        uint64 jtFee,
        uint64 jtYieldShareFee,
        uint64 ltYieldShareFee
    )
        external
    {
        vm.assume(lastSTRaw <= MAX_NAV && lastJTRaw <= MAX_NAV);
        // Cross-tranche claims admitted: the senior entitlement ranges over the whole checkpointed raw total
        vm.assume(stEff <= lastSTRaw + lastJTRaw);
        // Quadrant pin: each pool marks at or below its checkpoint (zero deltas admitted, wipeouts included)
        vm.assume(freshSTRaw <= lastSTRaw && freshJTRaw <= lastJTRaw);
        vm.assume(il <= MAX_NAV);
        vm.assume(dust <= MAX_DUST);
        vm.assume(stFee <= WAD && jtFee <= WAD && jtYieldShareFee <= WAD && ltYieldShareFee <= WAD);
        // Premium window budget: per-second yield shares sum to at most 100%, so the time-weighted accumulators
        // never exceed elapsed seconds worth of WAD (proven inductively by the accrual step property in
        // YieldShareAccrualSymbolic.t.sol and consumed here as a domain fact)
        vm.assume(lastPay < SYNC_TIMESTAMP);
        uint256 elapsed = SYNC_TIMESTAMP - lastPay;
        vm.assume(twJT <= elapsed * WAD && twLT <= elapsed * WAD - twJT);

        _seedGeneralCheckpoint(lastSTRaw, lastJTRaw, stEff, il, lastPay, dust, stFee, jtFee, jtYieldShareFee, ltYieldShareFee);
        _assertSyncSucceedsAndConserves(freshSTRaw, freshJTRaw, twJT, twLT);
    }

    /*//////////////////////////////////////////////////////////////////////
                QUADRANT: SENIOR LOSES WHILE JUNIOR GAINS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice When the senior pool marks down while the junior pool marks up, the sync never reverts and
     *         conserves NAV across the full interaction of both arms: the junior gain may be taxed a protocol
     *         fee, then immediately consumed as coverage for the senior loss (with the fee re-floored on the
     *         net gain), while cross-tranche claims can flip either effective delta's sign, so every pairing of
     *         the junior and senior loss and gain arms is reachable and proven together
     * @dev Economic why: this is the stress quadrant the product is sold on: junior yield arriving in the same
     *      sync as a senior drawdown must service coverage first, and the accounting must neither double-count
     *      the junior gain (once as NAV, once as coverage) nor destroy it. Conservation on the outputs is the
     *      one identity that catches both failure modes at once. Totality is the no-brick guarantee in the
     *      exact market state where holders most need to exit
     * @dev Solver note: runs at the tightened 1e27 NAV bound because a positive senior effective delta (via a
     *      senior claim on the gaining junior pool) reaches the premium and fee mulDiv stack on top of the two
     *      attribution mulDivs. If this check stays incomplete, split it by the sign of the senior effective
     *      delta and pin the accrued yield share accumulators to zero in the loss-side branch first
     */
    function check_syncConservesNAVAndNeverRevertsOnSeniorLossJuniorGain(
        uint256 lastSTRaw,
        uint256 lastJTRaw,
        uint256 stEff,
        uint256 freshSTRaw,
        uint256 freshJTRaw,
        uint256 il,
        uint32 lastPay,
        uint256 twJT,
        uint256 twLT,
        uint256 dust,
        uint64 stFee,
        uint64 jtFee,
        uint64 jtYieldShareFee,
        uint64 ltYieldShareFee
    )
        external
    {
        vm.assume(lastSTRaw <= MAX_NAV_MIXED && lastJTRaw <= MAX_NAV_MIXED);
        vm.assume(stEff <= lastSTRaw + lastJTRaw);
        // Quadrant pin: senior pool at or below its checkpoint, junior pool at or above it
        vm.assume(freshSTRaw <= lastSTRaw);
        vm.assume(lastJTRaw <= freshJTRaw && freshJTRaw <= MAX_NAV_MIXED);
        vm.assume(il <= MAX_NAV_MIXED);
        vm.assume(dust <= MAX_DUST);
        vm.assume(stFee <= WAD && jtFee <= WAD && jtYieldShareFee <= WAD && ltYieldShareFee <= WAD);
        // Premium window budget (see the both-lose quadrant for the derivation and its proof owner)
        vm.assume(lastPay < SYNC_TIMESTAMP);
        uint256 elapsed = SYNC_TIMESTAMP - lastPay;
        vm.assume(twJT <= elapsed * WAD && twLT <= elapsed * WAD - twJT);

        _seedGeneralCheckpoint(lastSTRaw, lastJTRaw, stEff, il, lastPay, dust, stFee, jtFee, jtYieldShareFee, ltYieldShareFee);
        _assertSyncSucceedsAndConserves(freshSTRaw, freshJTRaw, twJT, twLT);
    }

    /*//////////////////////////////////////////////////////////////////////
                QUADRANT: SENIOR GAINS WHILE JUNIOR LOSES
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice When the senior pool marks up while the junior pool marks down, the sync never reverts and
     *         conserves NAV: the junior tranche eats its attributed loss in full, while the senior gain first
     *         repays any junior coverage debt, then pays the floored risk and liquidity premium slices, whose
     *         sum can never exceed the gain that funds them, so the premium cap guard cannot trip
     * @dev Economic why: senior yield arriving while the junior pool bleeds is the recovery path: juniors must
     *      be made whole on outstanding coverage before a single wei is split as premiums, and the junior loss
     *      debit plus the coverage repayment credit must net inside the same conserved total. The premium cap
     *      safety is a pure flooring fact on the outputs: each slice times the window denominator is at most
     *      the gain times its accumulator, the accumulators sum to at most the window denominator, so the
     *      slices sum to at most the gain
     * @dev Solver note: runs at the tightened 1e27 NAV bound because the gain arm's premium and fee mulDivs
     *      stack on top of both attribution mulDivs and the junior loss arm. If this check stays incomplete,
     *      pin the accrued yield share accumulators to zero first (isolating the loss interaction), then split
     *      by whether the checkpointed senior raw NAV is zero
     */
    function check_syncConservesNAVAndNeverRevertsOnSeniorGainJuniorLoss(
        uint256 lastSTRaw,
        uint256 lastJTRaw,
        uint256 stEff,
        uint256 freshSTRaw,
        uint256 freshJTRaw,
        uint256 il,
        uint32 lastPay,
        uint256 twJT,
        uint256 twLT,
        uint256 dust,
        uint64 stFee,
        uint64 jtFee,
        uint64 jtYieldShareFee,
        uint64 ltYieldShareFee
    )
        external
    {
        vm.assume(lastSTRaw <= MAX_NAV_MIXED && lastJTRaw <= MAX_NAV_MIXED);
        vm.assume(stEff <= lastSTRaw + lastJTRaw);
        // Quadrant pin: senior pool at or above its checkpoint, junior pool at or below it
        vm.assume(lastSTRaw <= freshSTRaw && freshSTRaw <= MAX_NAV_MIXED);
        vm.assume(freshJTRaw <= lastJTRaw);
        vm.assume(il <= MAX_NAV_MIXED);
        vm.assume(dust <= MAX_DUST);
        vm.assume(stFee <= WAD && jtFee <= WAD && jtYieldShareFee <= WAD && ltYieldShareFee <= WAD);
        // Premium window budget (see the both-lose quadrant for the derivation and its proof owner)
        vm.assume(lastPay < SYNC_TIMESTAMP);
        uint256 elapsed = SYNC_TIMESTAMP - lastPay;
        vm.assume(twJT <= elapsed * WAD && twLT <= elapsed * WAD - twJT);

        _seedGeneralCheckpoint(lastSTRaw, lastJTRaw, stEff, il, lastPay, dust, stFee, jtFee, jtYieldShareFee, ltYieldShareFee);
        _assertSyncSucceedsAndConserves(freshSTRaw, freshJTRaw, twJT, twLT);
    }

    /*//////////////////////////////////////////////////////////////////////
                        QUADRANT: BOTH TRANCHES GAIN
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice When both underlying pools mark up (or stay flat), the sync never reverts and conserves NAV: the
     *         junior gain books directly, the senior gain flows through impermanent loss recovery and the
     *         floored premium slices, and every fee is reported without being deducted from any effective NAV,
     *         so the effective total still grows by exactly the combined raw appreciation
     * @dev Economic why: the yield path moves value through the most steps of any quadrant (recovery, the two
     *      premium slices, and up to four fee computations), and each step is a transfer or a report, never a
     *      deduction from the conserved total. Fees in particular are minted later as tranche shares, so a fee
     *      that leaked out of the effective total here would be paid twice: once as missing NAV now and once as
     *      diluted shares later. No loss arm is reachable in this quadrant (attribution of two non-negative
     *      deltas yields a non-negative senior slice and, by the residual construction, a non-negative junior
     *      slice), so no checked subtraction is at risk and the full 1e30 suite bound holds
     */
    function check_syncConservesNAVAndNeverRevertsWhenBothTranchesGain(
        uint256 lastSTRaw,
        uint256 lastJTRaw,
        uint256 stEff,
        uint256 freshSTRaw,
        uint256 freshJTRaw,
        uint256 il,
        uint32 lastPay,
        uint256 twJT,
        uint256 twLT,
        uint256 dust,
        uint64 stFee,
        uint64 jtFee,
        uint64 jtYieldShareFee,
        uint64 ltYieldShareFee
    )
        external
    {
        vm.assume(lastSTRaw <= MAX_NAV && lastJTRaw <= MAX_NAV);
        vm.assume(stEff <= lastSTRaw + lastJTRaw);
        // Quadrant pin: each pool marks at or above its checkpoint (zero deltas admitted)
        vm.assume(lastSTRaw <= freshSTRaw && freshSTRaw <= MAX_NAV);
        vm.assume(lastJTRaw <= freshJTRaw && freshJTRaw <= MAX_NAV);
        vm.assume(il <= MAX_NAV);
        vm.assume(dust <= MAX_DUST);
        vm.assume(stFee <= WAD && jtFee <= WAD && jtYieldShareFee <= WAD && ltYieldShareFee <= WAD);
        // Premium window budget (see the both-lose quadrant for the derivation and its proof owner)
        vm.assume(lastPay < SYNC_TIMESTAMP);
        uint256 elapsed = SYNC_TIMESTAMP - lastPay;
        vm.assume(twJT <= elapsed * WAD && twLT <= elapsed * WAD - twJT);

        _seedGeneralCheckpoint(lastSTRaw, lastJTRaw, stEff, il, lastPay, dust, stFee, jtFee, jtYieldShareFee, ltYieldShareFee);
        _assertSyncSucceedsAndConserves(freshSTRaw, freshJTRaw, twJT, twLT);
    }
}
