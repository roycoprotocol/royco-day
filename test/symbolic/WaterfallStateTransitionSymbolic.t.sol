// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { IRoycoDayAccountant } from "../../src/interfaces/IRoycoDayAccountant.sol";
import { MarketState, SyncedAccountingState } from "../../src/libraries/Types.sol";
import { NAV_UNIT, toNAVUnits, toUint256 } from "../../src/libraries/Units.sol";
import { WaterfallSyncDriver } from "../mocks/WaterfallSyncDriver.sol";

/**
 * @title WaterfallStateTransitionSymbolicSpec
 * @notice Native symbolic specs (`forge test --symbolic`) for the market state transition step at the tail of
 *         the accountant's sync waterfall: a fixed-term result always reports a zero liquidity premium and all
 *         three protocol fees as zero (even when the waterfall booked a junior gain fee moments earlier), a
 *         premium-paying sync can never land the market in a fixed-term state, the perpetual-forcing conditions
 *         (a zero fixed-term duration, and a junior wipe-out with live seniors) erase the JT coverage
 *         impermanent loss ledger exactly and clear the fixed-term end timestamp, and a dust-sized residual
 *         ledger holds an existing fixed term open until the ledger is restored to exactly zero
 * @dev Every check seeds an explicit checkpoint straight into the accountant's storage through the sync driver
 *      and pins one transition arm with vm.assume. Checkpoints are clean (raw NAV == effective NAV per tranche)
 *      so PnL attribution routes each tranche's raw delta one-to-one and each check controls the senior and
 *      junior deltas directly. The minimum coverage requirement is seeded zero throughout, which short-circuits
 *      the coverage utilization to zero: this is sound for these properties because the premium-and-fee zeroing
 *      and the impermanent loss bookkeeping inside every transition arm read no coverage configuration, and it
 *      keeps the liquidation-utilization forcing condition (owned by the concrete state-machine and utilization
 *      suites) statically false so each remaining condition can be pinned in isolation
 * @dev The block timestamp is pinned one second past the seeded premium payment clock so the same-block
 *      instantaneous yield share branch (which queries the external YDMs) is statically excluded and the
 *      waterfall under proof is closed arithmetic. The two time-driven transition conditions (a fixed term
 *      elapsing, and the liquidation-utilization breach) are pure clock and utilization plumbing with no new
 *      arithmetic, and are owned by the concrete post-op state grid and the fork fixed-term suites
 */
contract WaterfallStateTransitionSymbolicSpec is Test {
    /// @dev Suite-wide NAV domain bound: 1e30 NAV wei (one trillion tokens at WAD precision)
    uint256 internal constant MAX_NAV = 1e30;

    /// @dev Suite-wide dust tolerance domain bound
    uint256 internal constant MAX_DUST = 1e12;

    /// @dev WAD fixed-point unit, 1e18 == 100%
    uint256 internal constant WAD = 1e18;

    /// @dev The concrete block timestamp every check runs at (fits the accountant's uint32 clocks)
    uint256 internal constant SYNC_TIMESTAMP = 4_000_000_000;

    /// @dev A fixed-term end timestamp strictly in the future of every sync, so a seeded fixed term never
    ///      exits through the elapsed-term condition and the arm under proof stays pinned
    uint32 internal constant FIXED_TERM_END = 4_100_000_000;

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
     * @dev Baseline checkpoint every check starts from: a perpetual market, no coverage requirement (coverage
     *      utilization short-circuits to 0, far below the seeded liquidation threshold, so the liquidation
     *      forcing condition is statically false), zero fees, zero dust tolerances, and a premium payment
     *      clock stamped one second in the past so the elapsed premium window is exactly 1 second
     */
    function _baseSeed() internal pure returns (IRoycoDayAccountant.RoycoDayAccountantState memory seed) {
        seed.lastMarketState = MarketState.PERPETUAL;
        seed.coverageLiquidationUtilizationWAD = 2e18;
        seed.lastPremiumPaymentTimestamp = uint32(SYNC_TIMESTAMP - 1);
    }

    /// @dev Seeds a clean checkpoint: each tranche's effective NAV equals its raw NAV, so the claims
    ///      decomposition is fully self-backed and PnL attribution routes each tranche's raw delta one-to-one
    function _cleanSeed(uint256 _stNAV, uint256 _jtNAV) internal pure returns (IRoycoDayAccountant.RoycoDayAccountantState memory seed) {
        seed = _baseSeed();
        seed.lastSTRawNAV = toNAVUnits(_stNAV);
        seed.lastSTEffectiveNAV = toNAVUnits(_stNAV);
        seed.lastJTRawNAV = toNAVUnits(_jtNAV);
        seed.lastJTEffectiveNAV = toNAVUnits(_jtNAV);
    }

    /// @dev Seeds a clean checkpoint mid fixed-term: a nonzero term duration and an end timestamp still in the
    ///      future, so neither the permanent-perpetual nor the elapsed-term condition can force the transition
    function _midFixedTermSeed(uint256 _stNAV, uint256 _jtNAV) internal pure returns (IRoycoDayAccountant.RoycoDayAccountantState memory seed) {
        seed = _cleanSeed(_stNAV, _jtNAV);
        seed.lastMarketState = MarketState.FIXED_TERM;
        seed.fixedTermDurationSeconds = 1;
        seed.fixedTermEndTimestamp = FIXED_TERM_END;
    }

    /*//////////////////////////////////////////////////////////////////////
                A FIXED-TERM RESULT ZEROES THE PREMIUM AND ALL FEES
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice A sync that lands the market in a fixed-term state reports a zero LT liquidity premium and zero
     *         senior, junior, and LT protocol fees, even when the waterfall computed a strictly positive junior
     *         gain fee moments earlier: entering coverage protection cancels every value extraction the sync
     *         would otherwise report, while the junior gain itself stays booked in junior effective NAV
     * @dev Economic why: a fixed term exists because juniors are owed unrecovered coverage, and while that debt
     *      is outstanding no capital may be skimmed out of the market: paying the liquidity premium or minting
     *      fee shares against NAV that seniors still owe juniors would extract value senior yield has not yet
     *      earned back. Only the four reported extraction fields are cancelled: the junior gain (and any risk
     *      premium) already folded into junior effective NAV is real coverage buffer and is deliberately not
     *      unwound. The scenario drives a junior gain alongside a fully covered senior loss, sized so the
     *      recomputed junior fee is at least one wei before the transition ((jtGain - stLoss) * jtFee >= WAD
     *      guarantees floor((jtGain - stLoss) * jtFee / WAD) >= 1), so the zeroing provably cancels a real fee
     */
    function check_fixedTermResultReportsZeroPremiumAndAllFees(
        uint256 stNAV,
        uint256 jtNAV,
        uint256 stLoss,
        uint256 jtGain,
        uint256 dust,
        uint64 jtFee
    )
        external
    {
        vm.assume(1 <= stNAV && stNAV <= MAX_NAV);
        vm.assume(jtNAV <= MAX_NAV);
        vm.assume(dust <= MAX_DUST);
        vm.assume(jtFee <= WAD);
        // The senior loss is physical (bounded by the senior pool) and leaves a coverage debt above dust, so
        // the transition lands in the fresh fixed-term entry arm rather than exiting perpetual
        vm.assume(dust < stLoss && stLoss <= stNAV);
        // The junior gain strictly exceeds the coverage it provides plus dust, so the junior buffer survives
        // (no wipe-out forcing) and the fee recomputed on the gain net of coverage clears its own dust gate
        vm.assume(stLoss + dust < jtGain && jtGain <= MAX_NAV);
        // The floored junior fee slice on the net gain is at least one wei: the zeroing has real work to do
        vm.assume((jtGain - stLoss) * jtFee >= WAD);

        IRoycoDayAccountant.RoycoDayAccountantState memory seed = _cleanSeed(stNAV, jtNAV);
        // A nonzero term duration arms the fixed-term machinery (a zero duration would force perpetual)
        seed.fixedTermDurationSeconds = 1;
        seed.effectiveNAVDustTolerance = toNAVUnits(dust);
        seed.jtProtocolFeeWAD = jtFee;
        driver.seedCheckpoint(seed);

        // Junior gains, senior loses, and the junior buffer fully covers the senior loss
        (SyncedAccountingState memory state,, bool premiumsPaid,) = driver.runSync(stNAV - stLoss, jtNAV + jtGain, 0, 0);

        // The above-dust coverage debt pushes the perpetual market into a fixed term
        assert(state.marketState == MarketState.FIXED_TERM);
        // Every reported extraction is cancelled: the liquidity premium and all three protocol fees are zero,
        // including the junior gain fee that was strictly positive before the transition step
        assert(toUint256(state.ltLiquidityPremium) == 0);
        assert(toUint256(state.stProtocolFee) == 0);
        assert(toUint256(state.jtProtocolFee) == 0);
        assert(toUint256(state.ltProtocolFee) == 0);
        // The junior gain net of the coverage it lent stays booked: cancelling the fee report does not unwind NAV
        assert(toUint256(state.jtEffectiveNAV) == jtNAV + jtGain - stLoss);
        // The coverage lent is the fully covered senior loss, and seniors are made whole by it
        assert(toUint256(state.jtCoverageImpermanentLoss) == stLoss);
        assert(toUint256(state.stEffectiveNAV) == stNAV);
        // Entering the fixed term from a perpetual state stamps the end one full duration ahead
        assert(state.fixedTermEndTimestamp == uint32(SYNC_TIMESTAMP + 1));
        // A pure senior loss can never mark premiums as distributed
        assert(!premiumsPaid);
    }

    /**
     * @notice The dust-held continuation of an existing fixed term zeroes the reported extractions the same way
     *         a fresh entry does: a junior gain fee booked by the waterfall while the residual coverage debt
     *         sits inside the dust tolerance is cancelled by the transition, and the market stays fixed-term
     *         with its original end timestamp untouched
     * @dev Economic why: the dust-hold arm exists so the market re-enters perpetual only with the ledger at
     *      exactly zero (a full dust buffer restored), and while it holds the market is still in coverage
     *      protection, so the no-extraction rule applies identically. The scenario keeps the senior pool flat
     *      (the residual debt is untouched by the sync) and drives only a junior gain whose fee is at least one
     *      wei before the transition (jtGain * jtFee >= WAD guarantees floor(jtGain * jtFee / WAD) >= 1)
     */
    function check_dustHeldFixedTermResultZeroesABookedJuniorGainFee(
        uint256 stNAV,
        uint256 jtNAV,
        uint256 il0,
        uint256 dust,
        uint256 jtGain,
        uint64 jtFee
    )
        external
    {
        vm.assume(1 <= stNAV && stNAV <= MAX_NAV);
        vm.assume(jtNAV <= MAX_NAV);
        // A live residual coverage debt within the dust tolerance: the exact dust-hold window
        vm.assume(1 <= dust && dust <= MAX_DUST);
        vm.assume(1 <= il0 && il0 <= dust);
        // A junior gain above dust whose floored fee slice is at least one wei before the transition
        vm.assume(dust < jtGain && jtGain <= MAX_NAV);
        vm.assume(jtFee <= WAD && jtGain * jtFee >= WAD);

        IRoycoDayAccountant.RoycoDayAccountantState memory seed = _midFixedTermSeed(stNAV, jtNAV);
        seed.lastJTCoverageImpermanentLoss = toNAVUnits(il0);
        seed.effectiveNAVDustTolerance = toNAVUnits(dust);
        seed.jtProtocolFeeWAD = jtFee;
        driver.seedCheckpoint(seed);

        // Senior flat (the residual debt is untouched), junior gains
        (SyncedAccountingState memory state,,, NAV_UNIT erased) = driver.runSync(stNAV, jtNAV + jtGain, 0, 0);

        // The dust-sized residual debt holds the fixed term open
        assert(state.marketState == MarketState.FIXED_TERM);
        // The junior gain fee that was strictly positive before the transition is cancelled with the rest
        assert(toUint256(state.ltLiquidityPremium) == 0);
        assert(toUint256(state.stProtocolFee) == 0);
        assert(toUint256(state.jtProtocolFee) == 0);
        assert(toUint256(state.ltProtocolFee) == 0);
        // The gain itself stays booked and nothing touches the ledger or the seniors
        assert(toUint256(state.jtEffectiveNAV) == jtNAV + jtGain);
        assert(toUint256(state.jtCoverageImpermanentLoss) == il0);
        assert(toUint256(state.stEffectiveNAV) == stNAV);
        // Holding an existing term never restamps or clears its end timestamp, and nothing was erased
        assert(state.fixedTermEndTimestamp == FIXED_TERM_END);
        assert(toUint256(erased) == 0);
    }

    /*//////////////////////////////////////////////////////////////////////
                A PREMIUM-PAYING SYNC ALWAYS LANDS PERPETUAL
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice A sync that pays the risk and liquidity premiums out of a mid fixed-term market always lands the
     *         market in a perpetual state with a zero coverage impermanent loss ledger, and the transition
     *         itself erases nothing: the ledger was already cleared by the recovery inside the waterfall
     * @dev Economic why: impermanent loss recovery has first claim on senior appreciation, so a residual gain
     *      large enough to clear the premium dust gate exists only after the coverage debt is repaid in full.
     *      A cleared ledger then always resolves to a perpetual result (either through a forcing condition or
     *      through the zero-ledger arm), so the fixed-term zeroing of the premium and fees can never destroy a
     *      premium that was actually paid: the two outcomes are mutually exclusive by construction, and the
     *      zeroed fields in a fixed-term result are only ever a junior gain fee or true zeros. The erased
     *      amount returning zero is the witness that the debt was economically repaid by senior yield inside
     *      the waterfall, not administratively written off by the transition
     */
    function check_residualSeniorGainForcesAPerpetualResult(
        uint256 stNAV,
        uint256 jtNAV,
        uint256 il0,
        uint256 gain,
        uint256 dust,
        uint256 twJT,
        uint256 twLT
    )
        external
    {
        vm.assume(1 <= stNAV && stNAV <= MAX_NAV);
        vm.assume(jtNAV <= MAX_NAV);
        vm.assume(il0 <= MAX_NAV);
        vm.assume(1 <= gain && gain <= MAX_NAV);
        vm.assume(dust <= MAX_DUST);
        // The accrual budget over the pinned 1-second premium window: per-second yield shares are capped to
        // sum to at most 100%, so the accumulators can never exceed one second's worth of WAD (proven
        // inductively by the accrual-step property in YieldShareAccrualSymbolic.t.sol, consumed as a domain fact)
        vm.assume(twJT <= WAD && twLT <= WAD - twJT);

        IRoycoDayAccountant.RoycoDayAccountantState memory seed = _midFixedTermSeed(stNAV, jtNAV);
        seed.lastJTCoverageImpermanentLoss = toNAVUnits(il0);
        seed.effectiveNAVDustTolerance = toNAVUnits(dust);
        driver.seedCheckpoint(seed);

        (SyncedAccountingState memory state,, bool premiumsPaid, NAV_UNIT erased) = driver.runSync(stNAV + gain, jtNAV, twJT, twLT);

        // The implication on outputs: whenever premiums were marked as distributed, the market cannot have
        // stayed fixed-term, the ledger is exactly zero, the end timestamp is cleared, and nothing was erased
        if (premiumsPaid) {
            assert(state.marketState == MarketState.PERPETUAL);
            assert(toUint256(state.jtCoverageImpermanentLoss) == 0);
            assert(state.fixedTermEndTimestamp == 0);
            assert(toUint256(erased) == 0);
        }
    }

    /**
     * @notice A sync that pays the premiums out of a perpetual market with the fixed-term machinery armed
     *         keeps the market perpetual: paying yield out and simultaneously entering coverage protection is
     *         impossible within one sync, because a fixed-term entry requires an above-dust coverage debt and
     *         the premium dust gate requires that same debt to have been repaid to exactly zero first
     * @dev Economic why: this is the perpetual-entry face of the same first-claim argument as the mid
     *      fixed-term check above, and together they prove the zeroing in the fixed-term arms never cancels a
     *      liquidity premium or senior fee that real yield produced. The seeded ledger is symbolic (including
     *      values a real perpetual market could carry mid-recovery), so the proof covers every checkpoint the
     *      committing caller could have persisted
     */
    function check_residualSeniorGainKeepsAPerpetualMarketPerpetual(
        uint256 stNAV,
        uint256 jtNAV,
        uint256 il0,
        uint256 gain,
        uint256 dust,
        uint256 twJT,
        uint256 twLT
    )
        external
    {
        vm.assume(1 <= stNAV && stNAV <= MAX_NAV);
        vm.assume(jtNAV <= MAX_NAV);
        vm.assume(il0 <= MAX_NAV);
        vm.assume(1 <= gain && gain <= MAX_NAV);
        vm.assume(dust <= MAX_DUST);
        vm.assume(twJT <= WAD && twLT <= WAD - twJT);

        IRoycoDayAccountant.RoycoDayAccountantState memory seed = _cleanSeed(stNAV, jtNAV);
        // The fixed-term machinery is armed (a nonzero duration), so a fixed-term entry is genuinely reachable
        // from this checkpoint on a large enough covered loss: the proof rules it out only for premium payers
        seed.fixedTermDurationSeconds = 1;
        seed.lastJTCoverageImpermanentLoss = toNAVUnits(il0);
        seed.effectiveNAVDustTolerance = toNAVUnits(dust);
        driver.seedCheckpoint(seed);

        (SyncedAccountingState memory state,, bool premiumsPaid, NAV_UNIT erased) = driver.runSync(stNAV + gain, jtNAV, twJT, twLT);

        if (premiumsPaid) {
            assert(state.marketState == MarketState.PERPETUAL);
            assert(toUint256(state.jtCoverageImpermanentLoss) == 0);
            assert(state.fixedTermEndTimestamp == 0);
            assert(toUint256(erased) == 0);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
            PERPETUAL FORCING ERASES THE IMPERMANENT LOSS LEDGER EXACTLY
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice A market with a zero fixed-term duration is permanently perpetual: every sync lands perpetual,
     *         erases the entire coverage impermanent loss ledger (the carried debt plus any coverage lent this
     *         very sync) exactly, and clears the fixed-term end timestamp, no matter how large the senior loss
     * @dev Economic why: a zero duration means the issuer never granted juniors a protection window, so a
     *      coverage debt has no fixed term to be repaid within and carrying it would gate premiums and lock
     *      tranches for a protection product that was never sold. The erased amount returned to the caller is
     *      the carried ledger plus min(stLoss, jtNAV), the coverage the junior buffer lent inside this sync,
     *      derived independently as a plain minimum. The end timestamp is seeded nonzero deliberately, so the
     *      cleared field is proven to be an active write and not a pass on an already-zero slot
     */
    function check_zeroFixedTermDurationErasesTheILLedgerExactly(uint256 stNAV, uint256 jtNAV, uint256 il0, uint256 stLoss) external {
        vm.assume(1 <= stNAV && stNAV <= MAX_NAV);
        vm.assume(jtNAV <= MAX_NAV);
        vm.assume(il0 <= MAX_NAV);
        // A physical senior loss: bounded by the senior pool it is marked against
        vm.assume(1 <= stLoss && stLoss <= stNAV);

        IRoycoDayAccountant.RoycoDayAccountantState memory seed = _cleanSeed(stNAV, jtNAV);
        // Permanently perpetual: the duration stays at its zero default; the stale end timestamp is seeded
        // nonzero to prove the transition actively clears it
        seed.lastJTCoverageImpermanentLoss = toNAVUnits(il0);
        seed.fixedTermEndTimestamp = FIXED_TERM_END;
        driver.seedCheckpoint(seed);

        // Senior loses, junior flat: the junior buffer lends coverage inside this sync
        (SyncedAccountingState memory state,,, NAV_UNIT erased) = driver.runSync(stNAV - stLoss, jtNAV, 0, 0);

        // The coverage lent this sync is the smaller of the loss and the junior buffer (plain minimum)
        uint256 coverageLent = stLoss < jtNAV ? stLoss : jtNAV;

        // Forced perpetual with the whole ledger, old debt and fresh coverage alike, erased exactly
        assert(state.marketState == MarketState.PERPETUAL);
        assert(toUint256(erased) == il0 + coverageLent);
        assert(toUint256(state.jtCoverageImpermanentLoss) == 0);
        assert(state.fixedTermEndTimestamp == 0);
    }

    /**
     * @notice A senior loss that wipes out the junior buffer entirely while seniors retain value forces a mid
     *         fixed-term market into a perpetual state, erasing the entire ledger (the carried debt plus the
     *         junior buffer consumed as coverage this sync) exactly and clearing the end timestamp
     * @dev Economic why: with the junior buffer at zero there is no coverage left to protect, so holding the
     *      fixed term would lock seniors into a market whose protection is spent: they must be free to withdraw
     *      and the yield model must be free to attract fresh junior capital, and a debt owed to a tranche with
     *      no remaining claim is unrecoverable bookkeeping. With the minimum coverage seeded zero the coverage
     *      utilization short-circuits to zero below the liquidation threshold, and the term end is still in the
     *      future, so the junior wipe-out is provably the one condition forcing this transition. The whole
     *      junior buffer is consumed because the loss is at least its size, so the erased amount is exactly
     *      il0 + jtNAV with no minimum left to take
     */
    function check_juniorWipeOutErasesTheILLedgerExactly(uint256 stNAV, uint256 jtNAV, uint256 il0, uint256 stLoss) external {
        vm.assume(1 <= jtNAV && jtNAV <= MAX_NAV);
        vm.assume(il0 <= MAX_NAV);
        // The senior loss consumes the entire junior buffer but stays physical (bounded by the senior pool),
        // which also keeps seniors alive: stEff' = stNAV - stLoss + jtNAV >= jtNAV >= 1
        vm.assume(jtNAV <= stLoss && stLoss <= stNAV && stNAV <= MAX_NAV);

        IRoycoDayAccountant.RoycoDayAccountantState memory seed = _midFixedTermSeed(stNAV, jtNAV);
        seed.lastJTCoverageImpermanentLoss = toNAVUnits(il0);
        driver.seedCheckpoint(seed);

        (SyncedAccountingState memory state,,, NAV_UNIT erased) = driver.runSync(stNAV - stLoss, jtNAV, 0, 0);

        // The wipe-out witness: the junior buffer is spent to zero while seniors retain positive value
        assert(toUint256(state.jtEffectiveNAV) == 0);
        assert(toUint256(state.stEffectiveNAV) == stNAV + jtNAV - stLoss);
        // Forced perpetual mid-term with the whole ledger erased exactly and the end timestamp cleared
        assert(state.marketState == MarketState.PERPETUAL);
        assert(toUint256(erased) == il0 + jtNAV);
        assert(toUint256(state.jtCoverageImpermanentLoss) == 0);
        assert(state.fixedTermEndTimestamp == 0);
    }

    /*//////////////////////////////////////////////////////////////////////
            DUST RESIDUAL DEBT HOLDS THE FIXED TERM UNTIL EXACTLY ZERO
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice A senior gain that only partially repays the coverage debt, leaving a residual within the dust
     *         tolerance, holds an existing fixed term open: the market stays fixed-term with its original end
     *         timestamp, the ledger carries the exact remainder, the recovery is booked to juniors, and no
     *         premium or fee is reported
     * @dev Economic why: exiting to perpetual on a merely dust-sized (rather than exactly zero) ledger would
     *      let the market re-enter its unprotected state while still owing juniors, and repeated dust-boundary
     *      crossings would bleed the ledger's last wei-level claims: holding until exactly zero guarantees a
     *      fresh perpetual state always starts with a full dust buffer. The expected remainder is the plain
     *      difference il0 - gain, since recovery has first claim on the whole gain when the gain is below the
     *      debt, leaving nothing for premiums (their zeroing here is the boundary face of the fresh-entry check)
     */
    function check_dustILKeepsFixedTermUntilFullyRestored(uint256 stNAV, uint256 jtNAV, uint256 il0, uint256 gain, uint256 dust) external {
        vm.assume(1 <= stNAV && stNAV <= MAX_NAV);
        vm.assume(jtNAV <= MAX_NAV);
        vm.assume(1 <= dust && dust <= MAX_DUST);
        // A partial recovery whose residual debt lands inside the dust window: 0 < il0 - gain <= dust
        vm.assume(1 <= gain && gain < il0 && il0 <= MAX_NAV);
        vm.assume(il0 - gain <= dust);

        IRoycoDayAccountant.RoycoDayAccountantState memory seed = _midFixedTermSeed(stNAV, jtNAV);
        seed.lastJTCoverageImpermanentLoss = toNAVUnits(il0);
        seed.effectiveNAVDustTolerance = toNAVUnits(dust);
        driver.seedCheckpoint(seed);

        (SyncedAccountingState memory state,, bool premiumsPaid, NAV_UNIT erased) = driver.runSync(stNAV + gain, jtNAV, 0, 0);

        // The dust-sized remainder holds the term open with its original end timestamp, and nothing is erased:
        // every repaid wei moved economically, from senior yield to the junior buffer
        assert(state.marketState == MarketState.FIXED_TERM);
        assert(toUint256(state.jtCoverageImpermanentLoss) == il0 - gain);
        assert(state.fixedTermEndTimestamp == FIXED_TERM_END);
        assert(toUint256(erased) == 0);
        // The whole gain lands with juniors as recovery, seniors keep nothing, and no extraction is reported
        assert(toUint256(state.jtEffectiveNAV) == jtNAV + gain);
        assert(toUint256(state.stEffectiveNAV) == stNAV);
        assert(!premiumsPaid);
        assert(toUint256(state.ltLiquidityPremium) == 0);
        assert(toUint256(state.stProtocolFee) == 0);
        assert(toUint256(state.jtProtocolFee) == 0);
        assert(toUint256(state.ltProtocolFee) == 0);
    }

    /**
     * @notice A senior gain that repays the coverage debt in full exits the fixed term to a perpetual state
     *         with the end timestamp cleared, and the transition erases nothing: the debt was repaid
     *         economically by the recovery inside the waterfall, wei for wei
     * @dev Economic why: this is the other face of the dust-hold boundary above, together pinning the exact
     *      exit condition as a ledger of zero and not merely within dust. Juniors receive exactly their debt
     *      (il0), seniors keep the entire residual (gain - il0), so the exit never costs juniors a wei of what
     *      they were owed. The yield share accumulators are held at zero so the residual books to seniors with
     *      no premium arithmetic, isolating the boundary itself
     */
    function check_fullILRestorationExitsFixedTermToPerpetual(uint256 stNAV, uint256 jtNAV, uint256 il0, uint256 gain, uint256 dust) external {
        vm.assume(1 <= stNAV && stNAV <= MAX_NAV);
        vm.assume(jtNAV <= MAX_NAV);
        vm.assume(dust <= MAX_DUST);
        // A full recovery: the gain covers the entire debt, possibly with a senior residual left over
        vm.assume(1 <= il0 && il0 <= gain && gain <= MAX_NAV);

        IRoycoDayAccountant.RoycoDayAccountantState memory seed = _midFixedTermSeed(stNAV, jtNAV);
        seed.lastJTCoverageImpermanentLoss = toNAVUnits(il0);
        seed.effectiveNAVDustTolerance = toNAVUnits(dust);
        driver.seedCheckpoint(seed);

        (SyncedAccountingState memory state,,, NAV_UNIT erased) = driver.runSync(stNAV + gain, jtNAV, 0, 0);

        // A ledger restored to exactly zero exits the term: perpetual, end timestamp cleared, nothing erased
        assert(state.marketState == MarketState.PERPETUAL);
        assert(toUint256(state.jtCoverageImpermanentLoss) == 0);
        assert(state.fixedTermEndTimestamp == 0);
        assert(toUint256(erased) == 0);
        // Juniors are made exactly whole and seniors keep the entire residual
        assert(toUint256(state.jtEffectiveNAV) == jtNAV + il0);
        assert(toUint256(state.stEffectiveNAV) == stNAV + gain - il0);
    }
}
