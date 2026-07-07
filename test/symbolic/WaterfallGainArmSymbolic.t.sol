// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { IRoycoDayAccountant } from "../../src/interfaces/IRoycoDayAccountant.sol";
import { MarketState, SyncedAccountingState } from "../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../src/libraries/Units.sol";
import { WaterfallSyncDriver } from "../mocks/WaterfallSyncDriver.sol";

/**
 * @title WaterfallGainArmSymbolicSpec
 * @notice Native symbolic specs (`forge test --symbolic`) for the senior gain arm of the accountant's sync
 *         waterfall: the zero-senior-checkpoint PnL routing, the first-claim JT coverage impermanent loss
 *         recovery, the floored time-weighted premium slices and their yield share fees, the unreachability of
 *         the combined-premium cap revert, and the two-term conservation shape of the LT liquidity premium
 * @dev Every check seeds an explicit checkpoint straight into the accountant's storage through the sync driver
 *      and drives one pinned waterfall branch. Checkpoints are clean (raw NAV == effective NAV per tranche)
 *      unless the property is specifically about a dirty decomposition, so PnL attribution routes the senior
 *      delta one-to-one and each check controls the senior gain directly. Expected values are derived with
 *      plain checked multiply-and-divide on the bounded domain (NAVs up to 1e30 NAV wei, elapsed windows up to
 *      the uint32 clock range), never by re-running the production mulDiv path as its own expectation
 * @dev The block timestamp is pinned one second past the seeded premium payment clock by default so the
 *      same-block instantaneous yield share branch (which queries the external YDMs) is statically excluded:
 *      the waterfall under proof is then closed arithmetic over the supplied time-weighted accumulators
 */
contract WaterfallGainArmSymbolicSpec is Test {
    /// @dev Suite-wide NAV domain bound: 1e30 NAV wei (one trillion tokens at WAD precision)
    uint256 internal constant MAX_NAV = 1e30;

    /// @dev WAD fixed-point unit, 1e18 == 100%
    uint256 internal constant WAD = 1e18;

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
     * @dev Baseline checkpoint every check starts from: a perpetual market with no fixed-term machinery
     *      (duration 0 keeps the state transition on its unconditional perpetual arm, which never zeroes the
     *      premium or fee outputs), no coverage requirement (coverage utilization short-circuits to 0, far
     *      below the seeded liquidation threshold), zero fees, zero dust tolerances, and a premium payment
     *      clock stamped one second in the past so the elapsed window is exactly 1 second unless a check
     *      overrides the clock with its own symbolic value
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
                    ZERO SENIOR CHECKPOINT PNL ROUTING
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice When the last committed senior raw NAV is zero, a fresh positive senior raw NAV cannot be
     *         pro-rated against a zero-sized pool, so the sync routes the whole senior delta by who actually
     *         holds live claims: if the senior tranche has a positive effective NAV (its capital is currently
     *         parked inside JT's raw NAV), the entire appreciation belongs to seniors and juniors are untouched
     * @dev Economic why: the senior effective NAV is the senior holders' entitlement regardless of which pool
     *      currently backs it. Seeding a fresh senior pool from zero must credit those existing senior holders,
     *      not dilute the gain into the junior tranche through a division against a zero reference. The junior
     *      raw NAV is held flat so the senior delta is the only PnL in the sync, and the expected outputs are
     *      pure additions with no proportional math anywhere
     */
    function check_zeroSeniorCheckpointRoutesGainToSeniorWhenSeniorHasLiveClaims(uint256 jtRaw, uint256 stEff, uint256 gain) external {
        vm.assume(1 <= jtRaw && jtRaw <= MAX_NAV);
        // Senior holds a live claim, necessarily backed by JT's raw NAV since senior's own pool is empty
        // (conservation forces stEff + jtEff == 0 + jtRaw, so stEff can be at most jtRaw)
        vm.assume(1 <= stEff && stEff <= jtRaw);
        vm.assume(1 <= gain && gain <= MAX_NAV);
        uint256 jtEff = jtRaw - stEff;

        IRoycoDayAccountant.RoycoDayAccountantState memory seed = _baseSeed();
        seed.lastSTRawNAV = toNAVUnits(uint256(0));
        seed.lastJTRawNAV = toNAVUnits(jtRaw);
        seed.lastSTEffectiveNAV = toNAVUnits(stEff);
        seed.lastJTEffectiveNAV = toNAVUnits(jtEff);
        driver.seedCheckpoint(seed);

        // Senior pool marks from 0 to gain, junior pool is flat, no accrued yield shares
        (SyncedAccountingState memory state,,,) = driver.runSync(gain, jtRaw, 0, 0);

        // The whole senior appreciation lands with the live senior claims, junior is exactly flat
        assert(toUint256(state.stEffectiveNAV) == stEff + gain);
        assert(toUint256(state.jtEffectiveNAV) == jtEff);
        // No yield shares were accrued, so no slice of the gain leaves as a liquidity premium
        assert(toUint256(state.ltLiquidityPremium) == 0);
    }

    /**
     * @notice When the last committed senior raw NAV is zero and the senior tranche also has no effective NAV
     *         (no senior shares hold any entitlement), a fresh positive senior raw NAV is left as residual to
     *         the junior tranche instead of inflating a senior claim that nobody owns
     * @dev Economic why: crediting appreciation to a tranche with zero outstanding entitlement would create
     *      NAV backing no shares, which the next depositor could mint against for free. Leaving the delta as
     *      junior residual keeps every unit of NAV owned by someone. The junior protocol fee percentage is
     *      seeded zero so the junior gain books gross, keeping the expected form a pure addition
     */
    function check_zeroSeniorCheckpointLeavesGainWithJuniorWhenSeniorHasNoClaims(uint256 jtRaw, uint256 gain) external {
        vm.assume(jtRaw <= MAX_NAV);
        vm.assume(1 <= gain && gain <= MAX_NAV);

        IRoycoDayAccountant.RoycoDayAccountantState memory seed = _baseSeed();
        seed.lastSTRawNAV = toNAVUnits(uint256(0));
        seed.lastJTRawNAV = toNAVUnits(jtRaw);
        seed.lastSTEffectiveNAV = toNAVUnits(uint256(0));
        // Conservation: with both senior legs zero, junior's effective NAV is its whole raw NAV
        seed.lastJTEffectiveNAV = toNAVUnits(jtRaw);
        driver.seedCheckpoint(seed);

        (SyncedAccountingState memory state,,,) = driver.runSync(gain, jtRaw, 0, 0);

        // The unowned senior-pool appreciation lands with the junior tranche as residual
        assert(toUint256(state.jtEffectiveNAV) == jtRaw + gain);
        assert(toUint256(state.stEffectiveNAV) == 0);
        assert(toUint256(state.jtProtocolFee) == 0);
        assert(toUint256(state.ltLiquidityPremium) == 0);
    }

    /*//////////////////////////////////////////////////////////////////////
                    JT COVERAGE IL RECOVERY HAS FIRST CLAIM
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice JT coverage impermanent loss recovery has first claim on senior appreciation: a senior gain first
     *         repays the junior tranche exactly min(gain, impermanent loss), the ledger shrinks by that same
     *         amount, only the residual accrues to seniors, and no liquidity premium is paid while any part of
     *         the gain is still owed to juniors
     * @dev Economic why: coverage is a loan, not a gift. When juniors absorb a senior loss the ledger records
     *      the senior tranche's debt, and senior yield must clear that debt in full before any of it can be
     *      split as premiums, otherwise juniors would be paying the LT's liquidity premium out of their own
     *      unrecovered coverage. The market is seeded mid fixed-term (the state juniors are actually locked in
     *      while owed coverage) so the post-sync ledger is observable directly instead of being cleared by a
     *      perpetual transition
     */
    function check_impermanentLossRecoveryHasFirstClaimOnSeniorGain(uint256 stNAV, uint256 jtNAV, uint256 il, uint256 gain) external {
        vm.assume(1 <= stNAV && stNAV <= MAX_NAV);
        vm.assume(jtNAV <= MAX_NAV);
        vm.assume(1 <= il && il <= MAX_NAV);
        vm.assume(1 <= gain && gain <= MAX_NAV);

        IRoycoDayAccountant.RoycoDayAccountantState memory seed = _cleanSeed(stNAV, jtNAV);
        seed.lastJTCoverageImpermanentLoss = toNAVUnits(il);
        // Mid fixed-term: a nonzero term duration and an end timestamp still in the future, so an only
        // partially recovered ledger stays committed rather than being erased by a perpetual transition
        seed.lastMarketState = MarketState.FIXED_TERM;
        seed.fixedTermDurationSeconds = 1;
        seed.fixedTermEndTimestamp = 4_100_000_000;
        driver.seedCheckpoint(seed);

        (SyncedAccountingState memory state,,,) = driver.runSync(stNAV + gain, jtNAV, 0, 0);

        // First claim: juniors are repaid the smaller of the gain and what they are owed
        uint256 recovered = gain < il ? gain : il;
        assert(toUint256(state.jtCoverageImpermanentLoss) == il - recovered);
        assert(toUint256(state.jtEffectiveNAV) == jtNAV + recovered);
        // Seniors keep only the residual after the debt service
        assert(toUint256(state.stEffectiveNAV) == stNAV + (gain - recovered));
        // No accrued yield shares and an outstanding (or just-cleared) coverage debt: no liquidity premium
        assert(toUint256(state.ltLiquidityPremium) == 0);
    }

    /*//////////////////////////////////////////////////////////////////////
                    PREMIUMS ARE FLOORED TIME-WEIGHTED SLICES
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice With no coverage debt outstanding, a senior gain above the dust tolerance pays the JT risk
     *         premium and the LT liquidity premium as floored time-weighted slices of the gain: each premium is
     *         exactly floor(gain * accruedShare / (elapsed * WAD)), the junior tranche receives its slice as
     *         effective NAV, the senior tranche keeps everything except the junior slice (the LT premium stays
     *         inside senior effective NAV as a carve-out), and the sync reports the premiums as paid
     * @dev Economic why: the accrued accumulators are integrals of per-second yield shares over the window
     *      since the last payment, so dividing by elapsed * WAD turns them back into the average fraction of
     *      senior yield each junior-side tranche earned over that window. Flooring both slices shorts the
     *      premium takers by at most one wei each, in favor of the senior holders funding them. The expected
     *      slices are plain checked multiply-and-divide, exact on this domain because gain * accruedShare is
     *      at most 1e30 * 4e9 * 1e18, far below the uint256 ceiling
     */
    function check_premiumsAreFlooredTimeWeightedSlicesOfResidualGain(
        uint256 stNAV,
        uint256 jtNAV,
        uint256 gain,
        uint32 lastPay,
        uint256 twJT,
        uint256 twLT
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

        IRoycoDayAccountant.RoycoDayAccountantState memory seed = _cleanSeed(stNAV, jtNAV);
        seed.lastPremiumPaymentTimestamp = lastPay;
        driver.seedCheckpoint(seed);

        (SyncedAccountingState memory state,, bool premiumsPaid,) = driver.runSync(stNAV + gain, jtNAV, twJT, twLT);

        // Independently derived floored pro-rata slices (plain checked arithmetic, exact on this domain)
        uint256 jtRiskPremium = (gain * twJT) / (elapsed * WAD);
        uint256 ltLiquidityPremium = (gain * twLT) / (elapsed * WAD);

        // The junior tranche's risk premium is the only NAV that leaves the senior side
        assert(toUint256(state.jtEffectiveNAV) == jtNAV + jtRiskPremium);
        // The LT liquidity premium is reported at its exact slice but stays booked inside senior effective NAV
        assert(toUint256(state.ltLiquidityPremium) == ltLiquidityPremium);
        assert(toUint256(state.stEffectiveNAV) == stNAV + gain - jtRiskPremium);
        // A gain above the (zero) dust tolerance marks the premiums as paid, which resets the accrual window
        assert(premiumsPaid);
    }

    /*//////////////////////////////////////////////////////////////////////
                    THE COMBINED PREMIUM CAP CANNOT REVERT
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice As long as the accrued yield share accumulators respect the window budget (their sum is at most
     *         elapsed seconds worth of WAD), the sync's combined-premium guard cannot revert: the whole gain-arm
     *         sync completes, and the two floored premium slices together never exceed the senior gain
     * @dev Economic why: the guard exists so the two premiums can never draw more than 100% of senior yield,
     *      but a revert there would brick every sync (and with it every deposit and redemption) until the
     *      accumulators were somehow cleared, so it must be unreachable under the accrual invariant. Derivation
     *      that flooring keeps the sum under the gain, on outputs only: jtSlice * D <= gain * twJT and
     *      ltSlice * D <= gain * twLT with D = elapsed * WAD, so (jtSlice + ltSlice) * D <= gain * (twJT + twLT)
     *      <= gain * D, and dividing by D > 0 gives jtSlice + ltSlice <= gain. The budget side condition is the
     *      accrual-step property in YieldShareAccrualSymbolic.t.sol (which also owns the uint192 accumulator
     *      width caveat), consumed here as a vm.assume domain fact
     */
    function check_premiumCapGuardCannotRevertWhenAccruedSharesRespectTheWindowBudget(
        uint256 stNAV,
        uint256 jtNAV,
        uint256 gain,
        uint32 lastPay,
        uint256 twJT,
        uint256 twLT
    )
        external
    {
        vm.assume(1 <= stNAV && stNAV <= MAX_NAV);
        vm.assume(jtNAV <= MAX_NAV);
        vm.assume(1 <= gain && gain <= MAX_NAV);
        vm.assume(lastPay < SYNC_TIMESTAMP);
        uint256 elapsed = SYNC_TIMESTAMP - lastPay;
        vm.assume(twJT <= elapsed * WAD && twLT <= elapsed * WAD - twJT);

        driver.seedCheckpoint(_cleanSeed(stNAV, jtNAV));

        // The totality claim: no revert anywhere in the gain-arm sync, including the combined-premium guard
        (bool success, SyncedAccountingState memory state) = driver.tryRunSync(stNAV + gain, jtNAV, twJT, twLT);
        assert(success);

        // The cap itself, re-stated on the outputs: junior's premium is its effective NAV growth (nothing else
        // moves junior NAV in this pinned branch) and together with the LT slice it never exceeds the gain
        uint256 jtGrowth = toUint256(state.jtEffectiveNAV) - jtNAV;
        assert(toUint256(state.jtEffectiveNAV) >= jtNAV);
        assert(jtGrowth + toUint256(state.ltLiquidityPremium) <= gain);
    }

    /*//////////////////////////////////////////////////////////////////////
            DIVERGENCE CANDIDATE: DUST GAIN PAYS PREMIUMS WITHOUT A RESET
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice PINS A DIVERGENCE. A senior gain at or below the effective NAV dust tolerance still computes and
     *         books the JT risk premium (junior effective NAV grows by the full floored slice) and still
     *         reports the LT liquidity premium, while the sync reports the premiums as NOT paid. The committing
     *         caller resets the time-weighted accumulators and the premium payment clock only when the paid
     *         flag is true, so the very same accrual window remains intact and is drawn against again by the
     *         next sync: the dust-gated gain pays out without consuming the window that priced it
     * @dev Economic why this is a divergence worth pinning: the dust gate exists so rounding noise in the
     *      underlying marks does not masquerade as yield, but it only gates the paid flag (and with it the
     *      fees and the window reset), not the premium transfer itself. An accrued window can therefore be
     *      double-drawn: once against a dust gain, then again in full at the next real gain. Each draw is
     *      bounded by the dust tolerance per sync, but the leak repeats every sync that lands a dust-sized
     *      gain. This check pins the current behavior exactly, including all three protocol fees staying at
     *      zero because every fee is gated on the paid flag
     */
    function check_DIVERGENCE_candidate_dustGainPaysPremiumsButLeavesAccrualWindowUnreset(
        uint256 stNAV,
        uint256 jtNAV,
        uint256 dust,
        uint256 gain,
        uint256 twJT,
        uint256 twLT,
        uint64 stFee,
        uint64 jtYieldShareFee,
        uint64 ltYieldShareFee
    )
        external
    {
        vm.assume(1 <= stNAV && stNAV <= MAX_NAV);
        vm.assume(jtNAV <= MAX_NAV);
        // A dust-sized gain: positive, but at or below the seeded effective NAV dust tolerance
        vm.assume(1 <= dust && dust <= 1e12);
        vm.assume(1 <= gain && gain <= dust);
        // A one-second window with a live junior share, sized so the floored premium slice is at least 1 wei:
        // the strict witness that value actually moves while the paid flag stays false
        vm.assume(1 <= twJT && twJT <= WAD && twLT <= WAD - twJT);
        vm.assume(gain * twJT >= WAD);
        // Nonzero fee percentages are seeded to pin that every fee is gated off by the unpaid flag
        vm.assume(stFee <= WAD && jtYieldShareFee <= WAD && ltYieldShareFee <= WAD);

        IRoycoDayAccountant.RoycoDayAccountantState memory seed = _cleanSeed(stNAV, jtNAV);
        seed.effectiveNAVDustTolerance = toNAVUnits(dust);
        seed.stProtocolFeeWAD = stFee;
        seed.jtYieldShareProtocolFeeWAD = jtYieldShareFee;
        seed.ltYieldShareProtocolFeeWAD = ltYieldShareFee;
        driver.seedCheckpoint(seed);

        (SyncedAccountingState memory state,, bool premiumsPaid,) = driver.runSync(stNAV + gain, jtNAV, twJT, twLT);

        // The dust gate holds the paid flag false (the strict > boundary: gain == dust is still unpaid)
        assert(!premiumsPaid);
        // ... yet the junior risk premium is booked in full: real NAV moved from seniors to juniors
        uint256 jtRiskPremium = (gain * twJT) / WAD;
        assert(jtRiskPremium >= 1);
        assert(toUint256(state.jtEffectiveNAV) == jtNAV + jtRiskPremium);
        // ... and the liquidity premium is still reported for the kernel to mint against
        assert(toUint256(state.ltLiquidityPremium) == (gain * twLT) / WAD);
        assert(toUint256(state.stEffectiveNAV) == stNAV + gain - jtRiskPremium);
        // Every protocol fee is gated on the paid flag, so all three stay zero despite nonzero fee configs
        assert(toUint256(state.stProtocolFee) == 0);
        assert(toUint256(state.jtProtocolFee) == 0);
        assert(toUint256(state.ltProtocolFee) == 0);
    }

    /*//////////////////////////////////////////////////////////////////////
                    YIELD SHARE AND SENIOR FEES ARE FLOORED SLICES
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice On a premium-paying senior gain, each protocol fee is an exact floored percentage of its own
     *         leg: the JT yield share fee of the junior risk premium, the LT yield share fee of the liquidity
     *         premium, and the senior fee of the residual gain left after both premium slices are carved out
     * @dev Economic why: fees are reported (not deducted) by the sync and later minted as tranche shares, so a
     *      fee overstating its leg by even a wei would dilute holders beyond the configured percentage, and a
     *      fee taken on another leg's value would tax capital that never earned it. The expected values chain
     *      two independent plain divisions: first the premium slice out of the gain, then the fee slice out of
     *      that premium, both floored in favor of the tranche holders paying the fee
     */
    function check_yieldShareAndSeniorFeesAreFlooredSlicesOfEachLeg(
        uint256 stNAV,
        uint256 jtNAV,
        uint256 gain,
        uint32 lastPay,
        uint256 twJT,
        uint256 twLT,
        uint64 stFee,
        uint64 jtYieldShareFee,
        uint64 ltYieldShareFee
    )
        external
    {
        vm.assume(1 <= stNAV && stNAV <= MAX_NAV);
        vm.assume(jtNAV <= MAX_NAV);
        vm.assume(1 <= gain && gain <= MAX_NAV);
        vm.assume(lastPay < SYNC_TIMESTAMP);
        uint256 elapsed = SYNC_TIMESTAMP - lastPay;
        vm.assume(twJT <= elapsed * WAD && twLT <= elapsed * WAD - twJT);
        vm.assume(stFee <= WAD && jtYieldShareFee <= WAD && ltYieldShareFee <= WAD);

        IRoycoDayAccountant.RoycoDayAccountantState memory seed = _cleanSeed(stNAV, jtNAV);
        seed.lastPremiumPaymentTimestamp = lastPay;
        seed.stProtocolFeeWAD = stFee;
        seed.jtYieldShareProtocolFeeWAD = jtYieldShareFee;
        seed.ltYieldShareProtocolFeeWAD = ltYieldShareFee;
        driver.seedCheckpoint(seed);

        (SyncedAccountingState memory state,,,) = driver.runSync(stNAV + gain, jtNAV, twJT, twLT);

        // The two premium legs, derived independently as plain floored pro-rata slices of the gain
        uint256 jtRiskPremium = (gain * twJT) / (elapsed * WAD);
        uint256 ltLiquidityPremium = (gain * twLT) / (elapsed * WAD);

        // Each fee is the floored configured percentage of exactly its own leg and nothing else
        assert(toUint256(state.jtProtocolFee) == (jtRiskPremium * jtYieldShareFee) / WAD);
        assert(toUint256(state.ltProtocolFee) == (ltLiquidityPremium * ltYieldShareFee) / WAD);
        assert(toUint256(state.stProtocolFee) == ((gain - jtRiskPremium - ltLiquidityPremium) * stFee) / WAD);
    }

    /*//////////////////////////////////////////////////////////////////////
                    THE LT PREMIUM NEVER LEAVES SENIOR EFFECTIVE NAV
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The LT liquidity premium is a carve-out marker, never a NAV subtraction: over the whole gain arm
     *         the senior effective NAV grows by exactly the gain minus whatever the junior tranche received,
     *         and the reported liquidity premium is fully contained inside that senior growth. The waterfall
     *         stays two-term, with no third NAV leg for the liquidity tranche
     * @dev Economic why: the liquidity premium is paid by minting senior shares to the LT, so it is a transfer
     *      of senior share ownership, not of NAV, and it must remain covered senior value. If the premium were
     *      subtracted from senior effective NAV the conservation identity would need a third leg and the
     *      premium would silently leave the coverage perimeter. Stated as a linear identity purely on the sync
     *      outputs: whatever did not go to juniors stayed senior, premium included
     */
    function check_liquidityPremiumNeverLeavesSeniorEffectiveNAV(
        uint256 stNAV,
        uint256 jtNAV,
        uint256 gain,
        uint32 lastPay,
        uint256 twJT,
        uint256 twLT
    )
        external
    {
        vm.assume(1 <= stNAV && stNAV <= MAX_NAV);
        vm.assume(jtNAV <= MAX_NAV);
        vm.assume(1 <= gain && gain <= MAX_NAV);
        vm.assume(lastPay < SYNC_TIMESTAMP);
        uint256 elapsed = SYNC_TIMESTAMP - lastPay;
        vm.assume(twJT <= elapsed * WAD && twLT <= elapsed * WAD - twJT);

        IRoycoDayAccountant.RoycoDayAccountantState memory seed = _cleanSeed(stNAV, jtNAV);
        seed.lastPremiumPaymentTimestamp = lastPay;
        driver.seedCheckpoint(seed);

        (SyncedAccountingState memory state,,,) = driver.runSync(stNAV + gain, jtNAV, twJT, twLT);

        // Junior can only gain in this pinned branch (its raw NAV is flat and there is no coverage debt)
        assert(toUint256(state.jtEffectiveNAV) >= jtNAV);
        uint256 jtGrowth = toUint256(state.jtEffectiveNAV) - jtNAV;
        // Two-term conservation of the gain: everything not paid to juniors stayed inside senior effective NAV
        assert(toUint256(state.stEffectiveNAV) == stNAV + gain - jtGrowth);
        // The reported liquidity premium is contained inside the senior growth, never subtracted from it
        assert(toUint256(state.stEffectiveNAV) - stNAV >= toUint256(state.ltLiquidityPremium));
    }
}
