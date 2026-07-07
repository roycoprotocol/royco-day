// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { IRoycoDayAccountant } from "../../src/interfaces/IRoycoDayAccountant.sol";
import { MarketState, SyncedAccountingState } from "../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../src/libraries/Units.sol";
import { AttributionExposer } from "../mocks/AttributionExposer.sol";
import { SettableYDM } from "../mocks/SettableYDM.sol";
import { TrancheClaimsExposer } from "../mocks/TrancheClaimsExposer.sol";
import { WaterfallSyncDriver } from "../mocks/WaterfallSyncDriver.sol";

/**
 * @title AccountantSyncLemmasSymbolicSpec
 * @notice Native symbolic specs (`forge test --symbolic`) for the compositional safety lemmas of the tranche
 *         accounting sync: the per-pool residual-loss bound of the pro-rata attribution, the theorems that
 *         neither tranche's attributed loss can ever exceed its own effective NAV (the underflow shields of
 *         the two loss arms of the waterfall), the same-block instantaneous premium cap, and the containment
 *         lemmas that keep the senior protocol fee plus the liquidity premium inside senior effective NAV and
 *         the junior protocol fee inside junior effective NAV on every fee-bearing branch
 * @dev The loss lemmas are proven compositionally: each check rebuilds the sync's attribution step out of the
 *      production claims decomposition and the production attribution helper (driven through their external
 *      exposers), so the lemma quantifies over exactly the arithmetic the sync executes, while the bound on
 *      the spec side is always derived independently (linear claim identities and floor reasoning on outputs,
 *      never a re-run of the production mulDiv chain as its own expectation). The premium and fee lemmas
 *      drive the full waterfall through the sync driver with one pinned branch per check
 * @dev Domain: NAVs up to 1e30 NAV wei (one trillion whole 18-decimal tokens, beyond any underwritable
 *      market), fee and yield-share fractions up to WAD, elapsed premium windows up to the uint32 clock
 *      range. Checkpoints injected into the driver or the claims decomposition always satisfy the two-term
 *      conservation identity (raw NAV sum equals effective NAV sum), which every committed sync enforces, so
 *      conservation is the reachable-state envelope rather than a narrowing. The decomposition's totality and
 *      partition identities under conservation are proven in TrancheClaimsSymbolic.t.sol and consumed here
 * @dev The block timestamp is pinned past the seeded premium payment clock for the time-weighted checks so
 *      the same-block instantaneous yield share branch is statically excluded, and pinned exactly at the
 *      premium payment clock for the same-block check so that branch (and only that branch) is exercised
 *      against settable YDMs returning unconstrained symbolic yield shares
 */
contract AccountantSyncLemmasSymbolicSpec is Test {
    /// @dev Suite-wide NAV domain bound: 1e30 NAV wei (one trillion tokens at WAD precision)
    uint256 internal constant MAX_NAV = 1e30;

    /// @dev WAD fixed-point unit, 1e18 == 100%
    uint256 internal constant WAD = 1e18;

    /// @dev The concrete block timestamp every check runs at (fits the accountant's uint32 clocks)
    uint256 internal constant SYNC_TIMESTAMP = 4_000_000_000;

    WaterfallSyncDriver internal driver;
    TrancheClaimsExposer internal claims;
    AttributionExposer internal attribution;
    SettableYDM internal jtYDM;
    SettableYDM internal ltYDM;

    function setUp() public {
        // The kernel address is irrelevant here: every check drives the internal preview, not the kernel entrypoints
        driver = new WaterfallSyncDriver(address(1), false);
        claims = new TrancheClaimsExposer();
        attribution = new AttributionExposer();
        jtYDM = new SettableYDM();
        ltYDM = new SettableYDM();
        vm.warp(SYNC_TIMESTAMP);
    }

    /*//////////////////////////////////////////////////////////////////////
                            CHECKPOINT SEEDING
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @dev Baseline checkpoint every driver-based check starts from: a perpetual market with no fixed-term
     *      machinery (duration 0 keeps the state transition on its unconditional perpetual arm, which never
     *      zeroes the premium or fee outputs), no coverage requirement (coverage utilization short-circuits
     *      to 0, far below the seeded liquidation threshold), zero fees, zero dust tolerances, and a premium
     *      payment clock stamped one second in the past so the elapsed window is exactly 1 second unless a
     *      check overrides the clock with its own value
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

    /*//////////////////////////////////////////////////////////////////////
                    RESIDUAL LOSS BOUNDED BY THE COMPLEMENTARY CLAIM
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice When a pool loses at most its whole last checkpoint NAV, the part of the loss NOT attributed to
     *         the claimant's floored pro-rata slice never exceeds the complementary claim (the checkpoint NAV
     *         minus the claimant's claim). The sync charges each pool's unattributed loss to the residual
     *         tranche, so this is the per-pool inductive core of both loss-arm underflow shields: the residual
     *         side is never charged more loss than the slice of the pool it actually owns
     * @dev Derivation, independent of the production path: the attributed magnitude a is the floor of
     *      m * c / L, so a * L > m * c - L (the floor undershoots by less than one denominator). Then
     *      (m - a) * L < m * L - m * c + L = m * (L - c) + L <= L * (L - c) + L using m <= L, so dividing by
     *      L >= 1 gives m - a < (L - c) + 1, hence m - a <= L - c. Tight at m == L, where the residual is
     *      exactly the complementary claim. A zero claim short-circuits to a zero slice and the bound reduces
     *      to m <= L, the pinned physical loss bound. The padding inputs route the query past the engine's
     *      built-in arithmetic heuristic (which cannot conclude on division-shaped queries) to the SMT solver
     */
    function check_lossLeftUnattributedByProRataSliceNeverExceedsComplementaryClaim(uint256 lossMag, uint256 claim, uint256 lastRaw, uint256 p1, uint256 p2) external view {
        // A live checkpoint, a claim on part of it, and a physical loss (a pool cannot lose more than it holds)
        vm.assume(1 <= lastRaw && lastRaw <= MAX_NAV);
        vm.assume(claim <= lastRaw);
        vm.assume(1 <= lossMag && lossMag <= lastRaw);
        vm.assume(p1 <= 3 && p2 <= 3);

        // The production floored pro-rata slice of the loss, as a negative attributed delta
        int256 attributed = attribution.attribute(-int256(lossMag), claim + p1 - p1, lastRaw + p2 - p2);
        assert(attributed <= 0);
        uint256 attributedMagnitude = uint256(-attributed);

        // Why this matters: the waterfall books each pool's loss as claimant slice plus residual. If the
        // residual could exceed the complementary claim, the residual tranche's checked effective NAV
        // subtraction downstream could underflow and brick the sync in a drawdown, the worst possible moment
        assert(lossMag - attributedMagnitude <= lastRaw - claim);
    }

    /*//////////////////////////////////////////////////////////////////////
                    JUNIOR LOSS NEVER EXCEEDS JUNIOR EFFECTIVE NAV
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Rebuilding the sync's PnL attribution exactly as it executes on a live senior checkpoint (claims
     *         decomposed from a conserving checkpoint, each pool's delta sliced pro-rata to the senior claim,
     *         junior taking the residual), a negative junior effective delta never exceeds the junior
     *         effective NAV in magnitude. This is the theorem behind the junior loss arm's unchecked-looking
     *         subtraction: junior can be charged at most everything it owns, never more
     * @dev Derivation: junior's delta is the sum of the two per-pool residuals. On a pool loss (magnitude at
     *      most the pool's checkpoint NAV, forced physically because a fresh raw NAV cannot be negative) the
     *      residual charged to junior is at most the complementary claim (the residual lemma above), and on a
     *      pool gain the residual is non-negative because the floored senior slice never exceeds the whole
     *      delta. The complementary claims are lastSTRaw - stClaimOnST == jtClaimOnST and lastJTRaw -
     *      stClaimOnJT == jtClaimOnJT, which by the decomposition's partition identity under conservation sum
     *      to exactly the junior effective NAV. Hence the junior loss is bounded by jtEff, tight when both
     *      pools are wiped out
     */
    function check_juniorLossNeverExceedsJuniorEffectiveNAVOnLiveSeniorCheckpoint(
        uint256 lastSTRaw,
        uint256 lastJTRaw,
        uint256 stEff,
        uint256 jtEff,
        uint256 stRawFresh,
        uint256 jtRawFresh
    )
        external
        view
    {
        // A conserving checkpoint with a live senior pool (the zero-checkpoint routing arm is pinned separately)
        vm.assume(1 <= lastSTRaw && lastSTRaw <= MAX_NAV && lastJTRaw <= MAX_NAV);
        vm.assume(stEff <= MAX_NAV && jtEff <= MAX_NAV);
        vm.assume(lastSTRaw + lastJTRaw == stEff + jtEff);
        // Fresh marks anywhere on the physical domain: losses are automatically bounded by each pool's checkpoint
        vm.assume(stRawFresh <= MAX_NAV && jtRawFresh <= MAX_NAV);

        // The production claims decomposition of the checkpoint (total under conservation, proven separately)
        (uint256 stClaimOnST, uint256 stClaimOnJT,,) = claims.computeSTandJTClaimsOnRawNAVs(lastSTRaw, lastJTRaw, stEff, jtEff);

        // Rebuild the attribution step exactly as the sync executes it: senior takes the floored pro-rata
        // slice of each pool's delta, junior takes whatever is left of the total
        int256 deltaSTRaw = int256(stRawFresh) - int256(lastSTRaw);
        int256 deltaJTRaw = int256(jtRawFresh) - int256(lastJTRaw);
        int256 deltaSTEff = attribution.attribute(deltaSTRaw, stClaimOnST, lastSTRaw) + attribution.attribute(deltaJTRaw, stClaimOnJT, lastJTRaw);
        int256 deltaJTEff = (deltaSTRaw + deltaJTRaw) - deltaSTEff;

        // Pin the junior loss regime
        vm.assume(deltaJTEff < 0);

        // Why this matters: the junior loss arm subtracts this magnitude from junior effective NAV with a
        // checked subtraction. If the bound failed, a sufficiently deep drawdown would revert every sync
        // (and with it every deposit and redemption) exactly when exits matter most
        assert(uint256(-deltaJTEff) <= jtEff);
    }

    /**
     * @notice When the last senior checkpoint pool is empty but seniors hold live effective claims (their
     *         capital is currently parked inside the junior pool), the sync routes the whole fresh senior pool
     *         delta to seniors and slices the junior pool's delta against the senior cross-claim. Junior's
     *         residual loss under this routing still never exceeds the junior effective NAV
     * @dev Derivation: with an empty senior pool, conservation forces the junior pool to back both tranches
     *      (lastJTRaw == stEff + jtEff), the senior cross-claim on the junior pool is exactly stEff, and the
     *      routed senior pool delta is non-negative (a fresh raw NAV cannot be below the zero checkpoint) so
     *      it never contributes junior loss. Junior's only loss source is the junior pool residual, bounded by
     *      the complementary claim lastJTRaw - stEff == jtEff per the residual lemma
     */
    function check_juniorLossNeverExceedsJuniorEffectiveNAVOnZeroSeniorCheckpointWithLiveSeniorClaims(
        uint256 stEff,
        uint256 jtEff,
        uint256 stRawFresh,
        uint256 jtRawFresh
    )
        external
        view
    {
        // Senior pool empty at the checkpoint, senior claims live: conservation pins the junior pool size
        vm.assume(1 <= stEff && stEff <= MAX_NAV && jtEff <= MAX_NAV);
        uint256 lastJTRaw = stEff + jtEff;
        vm.assume(stRawFresh <= MAX_NAV && jtRawFresh <= MAX_NAV);

        (, uint256 stClaimOnJT,,) = claims.computeSTandJTClaimsOnRawNAVs(0, lastJTRaw, stEff, jtEff);

        // The zero-senior-checkpoint routing arm the sync takes when seniors hold live claims: the whole
        // (necessarily non-negative) senior pool delta goes to seniors, the junior pool delta is pro-rated
        int256 deltaSTRaw = int256(stRawFresh);
        int256 deltaJTRaw = int256(jtRawFresh) - int256(lastJTRaw);
        int256 deltaSTEff = deltaSTRaw + attribution.attribute(deltaJTRaw, stClaimOnJT, lastJTRaw);
        int256 deltaJTEff = (deltaSTRaw + deltaJTRaw) - deltaSTEff;

        vm.assume(deltaJTEff < 0);

        // Junior's loss comes only from the junior pool residual, capped by junior's own slice of that pool
        assert(uint256(-deltaJTEff) <= jtEff);
    }

    /**
     * @notice When the last senior checkpoint pool is empty and seniors hold no effective claims either, the
     *         sync zeroes the senior routing (a fresh senior pool seeded against zero senior entitlement is
     *         left as junior residual) and the senior cross-claim on the junior pool is zero, so the senior
     *         effective delta is exactly zero and junior absorbs both pool deltas whole. Junior's loss is then
     *         at most the junior pool's own drawdown, which conservation caps at the junior effective NAV
     * @dev Derivation: with both senior legs zero, conservation forces lastJTRaw == jtEff, the senior claim on
     *      the junior pool saturates to zero (so the production attribution short-circuits to a zero slice),
     *      and the routed senior delta is zeroed by the no-live-claims arm. Junior's delta collapses to the
     *      raw total: the senior pool contributes only gains (a fresh raw NAV cannot be negative) and the
     *      junior pool cannot lose more than lastJTRaw == jtEff. This arm also witnesses that no senior loss
     *      can form here, which is why the senior loss lemma below only needs the live-claims arms
     */
    function check_juniorLossNeverExceedsJuniorEffectiveNAVOnZeroSeniorCheckpointWithNoSeniorClaims(uint256 jtEff, uint256 stRawFresh, uint256 jtRawFresh) external view {
        // Senior pool and senior claims both empty: conservation pins the junior pool to the junior claims
        vm.assume(jtEff <= MAX_NAV);
        vm.assume(stRawFresh <= MAX_NAV && jtRawFresh <= MAX_NAV);

        (, uint256 stClaimOnJT,,) = claims.computeSTandJTClaimsOnRawNAVs(0, jtEff, 0, jtEff);

        // The routing arm with no live senior claims zeroes the senior pool's contribution to seniors, and
        // the production attribution returns a zero slice against the (necessarily zero) senior cross-claim
        int256 deltaSTRaw = int256(stRawFresh);
        int256 deltaJTRaw = int256(jtRawFresh) - int256(jtEff);
        int256 deltaSTEff = int256(0) + attribution.attribute(deltaJTRaw, stClaimOnJT, jtEff);
        int256 deltaJTEff = (deltaSTRaw + deltaJTRaw) - deltaSTEff;

        // No senior claims means no senior movement at all: the senior loss arm is unreachable from this arm
        assert(deltaSTEff == 0);
        // Junior takes both pools whole, and its loss is capped by its own pool, which it fully owns
        if (deltaJTEff < 0) assert(uint256(-deltaJTEff) <= jtEff);
    }

    /*//////////////////////////////////////////////////////////////////////
                    SENIOR LOSS NEVER EXCEEDS SENIOR EFFECTIVE NAV
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Rebuilding the sync's PnL attribution on a live senior checkpoint, a negative senior effective
     *         delta never exceeds the senior effective NAV in magnitude. This is the underflow shield of the
     *         senior loss arm: after junior coverage absorbs what it can, the residual senior loss is
     *         subtracted from senior effective NAV with a checked subtraction, and this lemma guarantees that
     *         subtraction is safe even when junior provides no coverage at all
     * @dev Derivation: senior's delta is the sum of its two floored pro-rata slices. Each slice's negative
     *      part is bounded in magnitude by its own claim (the floor of m * c / L is at most c whenever the
     *      loss magnitude m is at most the pool L, which holds physically because a fresh raw NAV cannot be
     *      negative), and each slice's positive part only helps. The two claims sum to exactly the senior
     *      effective NAV by the decomposition's partition identity under conservation, so the combined senior
     *      loss is at most stEff, tight when both pools are wiped out
     */
    function check_seniorLossNeverExceedsSeniorEffectiveNAVOnLiveSeniorCheckpoint(
        uint256 lastSTRaw,
        uint256 lastJTRaw,
        uint256 stEff,
        uint256 jtEff,
        uint256 stRawFresh,
        uint256 jtRawFresh
    )
        external
        view
    {
        vm.assume(1 <= lastSTRaw && lastSTRaw <= MAX_NAV && lastJTRaw <= MAX_NAV);
        vm.assume(stEff <= MAX_NAV && jtEff <= MAX_NAV);
        vm.assume(lastSTRaw + lastJTRaw == stEff + jtEff);
        vm.assume(stRawFresh <= MAX_NAV && jtRawFresh <= MAX_NAV);

        (uint256 stClaimOnST, uint256 stClaimOnJT,,) = claims.computeSTandJTClaimsOnRawNAVs(lastSTRaw, lastJTRaw, stEff, jtEff);

        int256 deltaSTRaw = int256(stRawFresh) - int256(lastSTRaw);
        int256 deltaJTRaw = int256(jtRawFresh) - int256(lastJTRaw);
        int256 deltaSTEff = attribution.attribute(deltaSTRaw, stClaimOnST, lastSTRaw) + attribution.attribute(deltaJTRaw, stClaimOnJT, lastJTRaw);

        // Pin the senior loss regime
        vm.assume(deltaSTEff < 0);

        // Why this matters: with junior coverage exhausted the whole residual loss lands on senior effective
        // NAV via a checked subtraction, so a violation would brick every sync in an uncovered drawdown
        assert(uint256(-deltaSTEff) <= stEff);
    }

    /**
     * @notice When the last senior checkpoint pool is empty but seniors hold live effective claims, the routed
     *         senior pool delta is non-negative and senior's only loss source is its pro-rata slice of the
     *         junior pool's drawdown, which never exceeds its cross-claim on that pool and therefore never
     *         exceeds the senior effective NAV
     * @dev Derivation: conservation with an empty senior pool forces lastJTRaw == stEff + jtEff and the senior
     *      cross-claim on the junior pool is exactly stEff. The junior pool's loss magnitude is physically at
     *      most lastJTRaw, so senior's floored slice of it is at most its claim stEff, and the non-negative
     *      routed senior pool delta can only shrink the combined loss. The remaining sub-arm (zero checkpoint
     *      pool and zero senior claims) is covered by the junior-loss check above, which proves the senior
     *      effective delta is identically zero there, so no senior loss can form at all
     */
    function check_seniorLossNeverExceedsSeniorEffectiveNAVOnZeroSeniorCheckpoint(uint256 stEff, uint256 jtEff, uint256 stRawFresh, uint256 jtRawFresh) external view {
        vm.assume(1 <= stEff && stEff <= MAX_NAV && jtEff <= MAX_NAV);
        uint256 lastJTRaw = stEff + jtEff;
        vm.assume(stRawFresh <= MAX_NAV && jtRawFresh <= MAX_NAV);

        (, uint256 stClaimOnJT,,) = claims.computeSTandJTClaimsOnRawNAVs(0, lastJTRaw, stEff, jtEff);

        // The live-claims routing arm: the whole non-negative senior pool delta plus the junior pool slice
        int256 deltaSTRaw = int256(stRawFresh);
        int256 deltaJTRaw = int256(jtRawFresh) - int256(lastJTRaw);
        int256 deltaSTEff = deltaSTRaw + attribution.attribute(deltaJTRaw, stClaimOnJT, lastJTRaw);

        vm.assume(deltaSTEff < 0);

        // Senior's loss can only come from its junior pool slice, whose magnitude is capped by its claim
        assert(uint256(-deltaSTEff) <= stEff);
    }

    /*//////////////////////////////////////////////////////////////////////
                    SAME-BLOCK INSTANTANEOUS PREMIUMS RESPECT THE CAP
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice When the last premium payment happened in the same block, the sync prices the premiums off the
     *         instantaneous YDM outputs instead of the time-weighted accumulators, clamping each output to its
     *         configured maximum yield share. As long as the two maximums sum to at most 100% (which the
     *         config validation enforces at initialization and on every update), the sync never reverts on the
     *         combined-premium guard and the two premiums together never exceed the senior gain, no matter
     *         what the YDMs return, however absurd
     * @dev Economic why: the same-block branch is the one place where the premium inputs come from live
     *      external calls rather than the audited accrual pipeline, so it must be robust to arbitrary and even
     *      adversarial YDM outputs. The min-clamp against the configured maximums is the only defense, and
     *      this check proves it is sufficient. Derivation on outputs: each premium slice is the floor of
     *      gain * share / WAD with share clamped to its maximum, so sliceJT * WAD <= gain * maxJT and
     *      sliceLT * WAD <= gain * maxLT, summing to (sliceJT + sliceLT) * WAD <= gain * (maxJT + maxLT)
     *      <= gain * WAD, and dividing by WAD gives sliceJT + sliceLT <= gain. Junior's premium is read back
     *      as its effective NAV growth (nothing else moves junior NAV in this pinned gain branch)
     */
    function check_sameBlockInstantaneousPremiumsNeverTripTheCapNorExceedTheSeniorGain(
        uint256 stNAV,
        uint256 jtNAV,
        uint256 gain,
        uint256 jtYieldShare,
        uint256 ltYieldShare,
        uint64 maxJTShare,
        uint64 maxLTShare
    )
        external
    {
        vm.assume(1 <= stNAV && stNAV <= MAX_NAV);
        vm.assume(jtNAV <= MAX_NAV);
        vm.assume(1 <= gain && gain <= MAX_NAV);
        // The configured maximum yield shares respect the joint cap the config validation enforces
        vm.assume(uint256(maxJTShare) + uint256(maxLTShare) <= WAD);

        // The YDM outputs are fully unconstrained symbolic values: the clamp must carry the proof alone
        jtYDM.setYieldShare(jtYieldShare);
        ltYDM.setYieldShare(ltYieldShare);

        IRoycoDayAccountant.RoycoDayAccountantState memory seed = _cleanSeed(stNAV, jtNAV);
        // The premium payment clock is stamped at the current block, pinning the same-block branch that
        // queries the instantaneous yield shares from the external YDMs
        seed.lastPremiumPaymentTimestamp = uint32(SYNC_TIMESTAMP);
        seed.jtYDM = address(jtYDM);
        seed.ltYDM = address(ltYDM);
        seed.maxJTYieldShareWAD = maxJTShare;
        seed.maxLTYieldShareWAD = maxLTShare;
        driver.seedCheckpoint(seed);

        // The supplied time-weighted accumulators are ignored on this branch, so they are passed as zero
        (bool success, SyncedAccountingState memory state) = driver.tryRunSync(stNAV + gain, jtNAV, 0, 0);
        // The combined-premium guard cannot revert: a revert would brick every sync until the clock advances
        assert(success);

        // The cap restated on the outputs: junior's premium plus the liquidity premium never exceed the gain
        assert(toUint256(state.jtEffectiveNAV) >= jtNAV);
        uint256 jtGrowth = toUint256(state.jtEffectiveNAV) - jtNAV;
        assert(jtGrowth + toUint256(state.ltLiquidityPremium) <= gain);
    }

    /*//////////////////////////////////////////////////////////////////////
            SENIOR FEE PLUS LIQUIDITY PREMIUM FIT INSIDE SENIOR NAV
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice On a premium-paying senior gain with no coverage debt outstanding, the marshaled senior protocol
     *         fee plus the marshaled liquidity premium never exceed the marshaled senior effective NAV. The
     *         kernel later carves both out of senior effective NAV to size the share mints, so this lemma is
     *         what guarantees that carve-out subtraction can never underflow
     * @dev Derivation on the gain arm's own arithmetic: after the junior risk premium slice leaves, the
     *      residual gain r satisfies stEff' == stEff + r + ltPremium where ltPremium was already carved out
     *      of r's predecessor, and the senior fee is a floored fraction (at most WAD) of r, so
     *      stFee <= r and stFee + ltPremium <= r + ltPremium <= stEff'. The bound is independent of the
     *      checkpoint NAVs because the fee and the premium are both funded by the same sync's gain, which is
     *      itself booked into senior effective NAV before the state is marshaled
     */
    function check_seniorFeePlusLiquidityPremiumFitWithinSeniorEffectiveNAVWithNoCoverageDebt(
        uint256 stNAV,
        uint256 jtNAV,
        uint256 gain,
        uint32 lastPay,
        uint256 twJT,
        uint256 twLT,
        uint64 stFee
    )
        external
    {
        vm.assume(1 <= stNAV && stNAV <= MAX_NAV);
        vm.assume(jtNAV <= MAX_NAV);
        vm.assume(1 <= gain && gain <= MAX_NAV);
        // The elapsed premium window: anywhere from 1 second to the whole uint32 clock range
        vm.assume(lastPay < SYNC_TIMESTAMP);
        uint256 elapsed = SYNC_TIMESTAMP - lastPay;
        // The accrual budget: per-second yield shares are capped to sum to at most 100%, so the time-weighted
        // accumulators can never exceed elapsed seconds worth of WAD (proven inductively by the accrual step
        // property in YieldShareAccrualSymbolic.t.sol and consumed here as a domain fact)
        vm.assume(twJT <= elapsed * WAD && twLT <= elapsed * WAD - twJT);
        vm.assume(stFee <= WAD);

        IRoycoDayAccountant.RoycoDayAccountantState memory seed = _cleanSeed(stNAV, jtNAV);
        seed.lastPremiumPaymentTimestamp = lastPay;
        seed.stProtocolFeeWAD = stFee;
        driver.seedCheckpoint(seed);

        (SyncedAccountingState memory state,,,) = driver.runSync(stNAV + gain, jtNAV, twJT, twLT);

        // Why this matters: the kernel prices the senior fee shares and the LT premium shares against the
        // senior effective NAV net of both legs, so this sum exceeding the NAV would revert the commit path
        assert(toUint256(state.stProtocolFee) + toUint256(state.ltLiquidityPremium) <= toUint256(state.stEffectiveNAV));
    }

    /**
     * @notice When outstanding junior coverage debt consumes the entire senior gain, no premium is paid and no
     *         fee is taken: the marshaled liquidity premium and senior protocol fee are both exactly zero, so
     *         they trivially fit inside the senior effective NAV. Coverage debt repayment has first claim on
     *         senior appreciation, and value owed back to juniors must never leak out as fees or premiums
     * @dev The market is seeded mid fixed-term (the state juniors are actually locked in while owed coverage)
     *      with a nonzero senior fee percentage and live accrued yield shares over a one-second window, so the
     *      zeros are witnessed against a configuration that would pay both legs if any residual gain survived
     *      the debt service. The recovery leaves no residual, the premium block is never entered, and the
     *      marshaled state carries the zeros regardless of whether the impermanent loss ledger fully clears
     */
    function check_seniorFeeAndLiquidityPremiumStayZeroWhenCoverageDebtConsumesTheWholeGain(
        uint256 stNAV,
        uint256 jtNAV,
        uint256 il,
        uint256 gain,
        uint256 twJT,
        uint256 twLT,
        uint64 stFee
    )
        external
    {
        vm.assume(1 <= stNAV && stNAV <= MAX_NAV);
        vm.assume(jtNAV <= MAX_NAV);
        // The recovery fully consumes the gain: the debt is at least as large as the appreciation
        vm.assume(1 <= gain && gain <= MAX_NAV);
        vm.assume(gain <= il && il <= MAX_NAV);
        // Live accrued shares over the baseline one-second window, respecting the accrual budget
        vm.assume(twJT <= WAD && twLT <= WAD - twJT);
        vm.assume(stFee <= WAD);

        IRoycoDayAccountant.RoycoDayAccountantState memory seed = _cleanSeed(stNAV, jtNAV);
        seed.lastJTCoverageImpermanentLoss = toNAVUnits(il);
        seed.stProtocolFeeWAD = stFee;
        // Mid fixed-term: a nonzero term duration and an end timestamp still in the future, so the partially
        // recovered debt ledger stays committed rather than being erased by a perpetual transition
        seed.lastMarketState = MarketState.FIXED_TERM;
        seed.fixedTermDurationSeconds = 1;
        seed.fixedTermEndTimestamp = 4_100_000_000;
        driver.seedCheckpoint(seed);

        (SyncedAccountingState memory state,,,) = driver.runSync(stNAV + gain, jtNAV, twJT, twLT);

        // The whole gain went to debt service: nothing left to fee or to pay premiums from
        assert(toUint256(state.ltLiquidityPremium) == 0);
        assert(toUint256(state.stProtocolFee) == 0);
        // The containment lemma holds vacuously on this branch
        assert(toUint256(state.stProtocolFee) + toUint256(state.ltLiquidityPremium) <= toUint256(state.stEffectiveNAV));
    }

    /*//////////////////////////////////////////////////////////////////////
                    JUNIOR FEE FITS INSIDE JUNIOR EFFECTIVE NAV
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice On a pure junior gain (senior flat), the marshaled junior protocol fee never exceeds the
     *         marshaled junior effective NAV. The commit path later subtracts the junior fee from the junior
     *         effective NAV to price the fee shares, so this lemma is that subtraction's underflow shield
     * @dev Derivation: the fee is a floored fraction (at most WAD) of the junior net gain, so it is at most
     *      the gain itself, and the whole gain is booked into junior effective NAV before the state is
     *      marshaled, so fee <= gain <= jtEff + gain == jtEff'
     */
    function check_juniorFeeNeverExceedsJuniorEffectiveNAVOnJuniorGain(uint256 stNAV, uint256 jtNAV, uint256 jtGain, uint64 jtFee) external {
        vm.assume(1 <= stNAV && stNAV <= MAX_NAV);
        vm.assume(jtNAV <= MAX_NAV);
        vm.assume(1 <= jtGain && jtGain <= MAX_NAV);
        vm.assume(jtFee <= WAD);

        IRoycoDayAccountant.RoycoDayAccountantState memory seed = _cleanSeed(stNAV, jtNAV);
        seed.jtProtocolFeeWAD = jtFee;
        driver.seedCheckpoint(seed);

        // Senior marks flat, junior pool appreciates: only the junior gain arm runs
        (SyncedAccountingState memory state,,,) = driver.runSync(stNAV, jtNAV + jtGain, 0, 0);

        assert(toUint256(state.jtProtocolFee) <= toUint256(state.jtEffectiveNAV));
    }

    /**
     * @notice When a junior gain and a senior loss land in the same sync, junior coverage of the senior loss
     *         claws the fee base back down: the fee is recomputed on the junior gain net of the coverage
     *         provided (saturating at zero when coverage swallows the whole gain), and the recomputed fee
     *         never exceeds the junior effective NAV that remains after the coverage leaves
     * @dev Derivation: let c be the coverage applied, the smaller of the senior loss and the junior buffer
     *      after its gain. The recomputed fee is a floored fraction of max(gain - c, 0). If c <= gain the fee
     *      is at most gain - c, and junior's marshaled NAV is jtEff + gain - c, which dominates because
     *      jtEff >= 0. If c > gain the fee base saturates to zero and the fee is zero. Either way the commit
     *      path's junior fee subtraction is safe. Without the recomputation a fee sized on the gross gain
     *      could exceed what junior actually kept, taxing juniors on value they surrendered as coverage
     */
    function check_juniorFeeNeverExceedsJuniorEffectiveNAVWhenCoverageShrinksTheFeeBase(
        uint256 stNAV,
        uint256 jtNAV,
        uint256 jtGain,
        uint256 stLoss,
        uint64 jtFee
    )
        external
    {
        vm.assume(1 <= stNAV && stNAV <= MAX_NAV);
        vm.assume(jtNAV <= MAX_NAV);
        vm.assume(1 <= jtGain && jtGain <= MAX_NAV);
        // A physical senior loss: the pool cannot lose more than its checkpoint
        vm.assume(1 <= stLoss && stLoss <= stNAV);
        vm.assume(jtFee <= WAD);

        IRoycoDayAccountant.RoycoDayAccountantState memory seed = _cleanSeed(stNAV, jtNAV);
        seed.jtProtocolFeeWAD = jtFee;
        driver.seedCheckpoint(seed);

        // Junior pool appreciates while the senior pool draws down in the same sync
        (SyncedAccountingState memory state,,,) = driver.runSync(stNAV - stLoss, jtNAV + jtGain, 0, 0);

        assert(toUint256(state.jtProtocolFee) <= toUint256(state.jtEffectiveNAV));
    }

    /**
     * @notice On a premium-paying senior gain with junior flat, the junior protocol fee consists solely of the
     *         yield share fee on the junior risk premium, and it never exceeds the junior effective NAV. The
     *         premium is the only junior NAV movement in this branch, so the fee on it must fit inside it
     * @dev Derivation: the yield share fee is a floored fraction (at most WAD) of the junior risk premium, so
     *      it is at most the premium itself, and the premium is booked into junior effective NAV before the
     *      state is marshaled, so fee <= premium <= jtEff + premium == jtEff'
     */
    function check_juniorFeeNeverExceedsJuniorEffectiveNAVOnSeniorGainYieldShareFee(
        uint256 stNAV,
        uint256 jtNAV,
        uint256 gain,
        uint32 lastPay,
        uint256 twJT,
        uint256 twLT,
        uint64 jtYieldShareFee
    )
        external
    {
        vm.assume(1 <= stNAV && stNAV <= MAX_NAV);
        vm.assume(jtNAV <= MAX_NAV);
        vm.assume(1 <= gain && gain <= MAX_NAV);
        vm.assume(lastPay < SYNC_TIMESTAMP);
        uint256 elapsed = SYNC_TIMESTAMP - lastPay;
        // The accrual budget consumed as a domain fact (proven in YieldShareAccrualSymbolic.t.sol)
        vm.assume(twJT <= elapsed * WAD && twLT <= elapsed * WAD - twJT);
        vm.assume(jtYieldShareFee <= WAD);

        IRoycoDayAccountant.RoycoDayAccountantState memory seed = _cleanSeed(stNAV, jtNAV);
        seed.lastPremiumPaymentTimestamp = lastPay;
        seed.jtYieldShareProtocolFeeWAD = jtYieldShareFee;
        driver.seedCheckpoint(seed);

        (SyncedAccountingState memory state,,,) = driver.runSync(stNAV + gain, jtNAV, twJT, twLT);

        // Why this matters: the commit path subtracts the junior fee from junior effective NAV to price the
        // fee shares against the remaining junior value, so the fee exceeding the NAV would brick the sync
        assert(toUint256(state.jtProtocolFee) <= toUint256(state.jtEffectiveNAV));
    }
}
