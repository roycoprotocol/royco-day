// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { WaterfallSyncDriver } from "../mocks/WaterfallSyncDriver.sol";
import { IRoycoDayAccountant } from "../../src/interfaces/IRoycoDayAccountant.sol";
import { MarketState, SyncedAccountingState } from "../../src/libraries/Types.sol";
import { NAV_UNIT, toNAVUnits, toUint256 } from "../../src/libraries/Units.sol";

/**
 * @title WaterfallLossArmSymbolic
 * @notice Native symbolic specs for the senior-loss arm of the tranche accounting sync waterfall: on a senior
 *         drawdown the junior tranche's loss-absorption buffer covers exactly the smaller of the senior loss
 *         and the remaining junior effective NAV, the covered amount is booked to the JT coverage impermanent
 *         loss ledger wei-for-wei, only the uncovered residual ever touches senior effective NAV, and when the
 *         junior tranche gained on the same sync its protocol fee is recomputed on the gain net of the coverage
 *         it just surrendered (with the dust gate re-applied), so the protocol never charges a performance fee
 *         on junior yield that was immediately consumed protecting seniors
 * @dev Run with `forge test --symbolic --match-path test/symbolic/WaterfallLossArmSymbolic.t.sol`. Functions
 *      prefixed check_ are discovered only under --symbolic. All four checks verify with the default z3 profile.
 *      Every check seeds a clean checkpoint (last raw NAV == last effective NAV per tranche), which makes the
 *      claim decomposition cross-claim-free and the PnL attribution an exact 1:1 routing (each tranche's raw
 *      delta lands wholly on its own effective NAV), so the loss-arm arithmetic under proof is isolated with no
 *      pro-rata flooring burden from the attribution layer. Config collapse: zero minimum coverage (coverage
 *      utilization short-circuits to zero) and a zero fixed-term duration (the sync deterministically lands
 *      PERPETUAL, which erases the coverage IL ledger into the erased-amount return where it stays observable,
 *      and never zeroes fees). Domain: NAVs and deltas up to 1e30 wei, dust tolerances up to 1e12, fee
 *      percentages up to WAD. Expected values are plain checked multiply-and-divide (products cap at 1e48,
 *      far below 2^256), never a re-run of the production mulDiv
 */
contract WaterfallLossArmSymbolic is Test {
    /// @dev Suite-wide NAV domain bound: 1e30 NAV wei
    uint256 internal constant MAX_NAV = 1e30;
    /// @dev Suite-wide dust tolerance domain bound
    uint256 internal constant MAX_DUST = 1e12;
    uint256 internal constant WAD = 1e18;

    WaterfallSyncDriver internal driver;

    function setUp() public {
        driver = new WaterfallSyncDriver(address(1), false);
    }

    /**
     * @notice Seeds a clean checkpoint: each tranche's last raw NAV equals its last effective NAV, so the sync
     *         under test attributes each fresh raw delta 1:1 to its own tranche with no cross-tranche claims.
     *         Coverage config is collapsed (zero minimum coverage, zero fixed-term duration) so the market
     *         deterministically stays PERPETUAL and the loss-arm arithmetic is the only thing under proof.
     *         The senior and both yield-share protocol fees are pinned at nonzero 10% so a zero fee output in
     *         the assertions below is structural (the fee legs never ran), not an artifact of zero fee config
     */
    function _seedCleanCheckpoint(uint256 _stNAV, uint256 _jtNAV, uint256 _il, uint64 _jtFeeWAD, uint256 _dust) internal {
        driver.seedCheckpoint(
            IRoycoDayAccountant.RoycoDayAccountantState({
                stProtocolFeeWAD: 1e17,
                jtProtocolFeeWAD: _jtFeeWAD,
                jtYieldShareProtocolFeeWAD: 1e17,
                ltYieldShareProtocolFeeWAD: 1e17,
                minCoverageWAD: 0,
                fixedTermDurationSeconds: 0,
                lastMarketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0,
                lastYieldShareAccrualTimestamp: 0,
                lastPremiumPaymentTimestamp: 0,
                jtYDM: address(0),
                ltYDM: address(0),
                minLiquidityWAD: 0,
                twJTYieldShareAccruedWAD: 0,
                maxJTYieldShareWAD: 0,
                twLTYieldShareAccruedWAD: 0,
                maxLTYieldShareWAD: 0,
                coverageLiquidationUtilizationWAD: 2e18,
                lastSTRawNAV: toNAVUnits(_stNAV),
                lastJTRawNAV: toNAVUnits(_jtNAV),
                lastSTEffectiveNAV: toNAVUnits(_stNAV),
                lastJTEffectiveNAV: toNAVUnits(_jtNAV),
                lastJTCoverageImpermanentLoss: toNAVUnits(_il),
                lastLTRawNAV: toNAVUnits(uint256(0)),
                stNAVDustTolerance: toNAVUnits(uint256(0)),
                jtNAVDustTolerance: toNAVUnits(uint256(0)),
                effectiveNAVDustTolerance: toNAVUnits(_dust)
            })
        );
    }

    /*//////////////////////////////////////////////////////////////////////
                COVERAGE IS THE MIN OF THE LOSS AND THE JT BUFFER
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice On a pure senior drawdown (junior flat), the junior buffer absorbs exactly the smaller of the
     *         senior loss and the junior effective NAV, that covered amount is simultaneously booked to the
     *         JT coverage impermanent loss ledger as junior's claim on future senior recoveries, senior books
     *         only the uncovered residual, and no premium or protocol fee of any kind is produced on the way
     *         down. Tight at both ends: a loss inside the buffer leaves senior books untouched, and a loss
     *         past the buffer drains the junior to exactly zero before senior loses its first wei
     * @dev The loss is bounded by the senior checkpoint NAV (a pool cannot lose more than it holds), which is
     *      what keeps every checked subtraction in the arm from underflowing. The zero fixed-term duration
     *      pins the PERPETUAL transition, which erases the coverage IL ledger the same sync, so the booking is
     *      asserted on the erased-amount return (prior ledger plus this sync's coverage) and the carried
     *      ledger is asserted zero. Fully linear: no mulDiv executes anywhere on this path
     */
    function check_jtCoverageAppliedIsMinOfSeniorLossAndJuniorBuffer(
        uint256 stNAV,
        uint256 jtNAV,
        uint256 il,
        uint256 loss,
        uint256 dust
    )
        external
    {
        vm.assume(1 <= stNAV && stNAV <= MAX_NAV);
        vm.assume(jtNAV <= MAX_NAV);
        vm.assume(il <= MAX_NAV);
        vm.assume(dust <= MAX_DUST);
        // Pin the senior-loss arm with a flat junior: the loss is physical (at most the whole senior pool)
        vm.assume(1 <= loss && loss <= stNAV);

        _seedCleanCheckpoint(stNAV, jtNAV, il, 1e17, dust);
        (SyncedAccountingState memory state,, bool premiumsPaid, NAV_UNIT ilErased) = driver.runSync(stNAV - loss, jtNAV, 0, 0);

        // Why the min: junior is first-loss capital, so it eats the drawdown until its buffer is gone and not a
        // wei further, and senior is only ever charged what the buffer could not cover. This single expression
        // is the entire seniority guarantee of the capital structure
        uint256 expectedCoverage = loss < jtNAV ? loss : jtNAV;

        // Junior pays exactly the covered amount out of its effective NAV
        assert(toUint256(state.jtEffectiveNAV) == jtNAV - expectedCoverage);
        // Senior books only the residual the buffer could not absorb (zero whenever the loss fits the buffer)
        assert(toUint256(state.stEffectiveNAV) == stNAV - (loss - expectedCoverage));
        // Every wei of coverage becomes junior's claim on future senior recoveries: the ledger grows by exactly
        // the covered amount before the PERPETUAL transition (zero fixed-term duration) erases it into the
        // erased-amount return, so nothing is silently dropped between the booking and the erasure
        assert(toUint256(ilErased) == il + expectedCoverage);
        assert(toUint256(state.jtCoverageImpermanentLoss) == 0);
        // A drawdown pays nobody: no premium marks yield as distributed and no fee leg runs, even though every
        // fee percentage is configured nonzero. Fees on the way down would be value extracted from loss-bearers
        assert(!premiumsPaid);
        assert(toUint256(state.ltLiquidityPremium) == 0);
        assert(toUint256(state.stProtocolFee) == 0);
        assert(toUint256(state.jtProtocolFee) == 0);
        assert(toUint256(state.ltProtocolFee) == 0);
        assert(state.marketState == MarketState.PERPETUAL);
    }

    /*//////////////////////////////////////////////////////////////////////
            JT FEE IS RECOMPUTED ON THE GAIN NET OF COVERAGE PROVIDED
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice When the junior tranche gains while the senior tranche loses on the same sync, the junior
     *         protocol fee initially booked on the full gain is thrown away and recomputed on the gain net of
     *         the coverage junior just provided: the fee is the floored jtProtocolFeeWAD slice of
     *         (gain - coverage), pinned here to the sub-arm where that net gain still clears the dust gate.
     *         The protocol only ever charges a performance fee on yield the junior actually keeps
     * @dev The initial fee is forced nonzero via gain * feeWAD >= WAD (a floored slice is at least one wei
     *      exactly when the product reaches the WAD denominator), which is what arms the recompute. Expected
     *      fee is plain multiply-and-divide: net gain and fee percentage products cap at 1e48. Coverage below
     *      the gain forces coverage == loss (the junior buffer, swollen by the gain, always exceeds the gain
     *      itself), so junior remains whole on its principal and only its fresh yield is tapped
     */
    function check_juniorFeeIsRecomputedOnGainNetOfCoverageWhenNetGainStaysAboveDust(
        uint256 stNAV,
        uint256 jtNAV,
        uint256 loss,
        uint256 gain,
        uint256 jtFeeWAD,
        uint256 dust
    )
        external
    {
        vm.assume(1 <= stNAV && stNAV <= MAX_NAV);
        vm.assume(jtNAV <= MAX_NAV);
        vm.assume(dust <= MAX_DUST);
        // Pin the mixed quadrant: senior loses (physically bounded), junior gains above the dust gate
        vm.assume(1 <= loss && loss <= stNAV);
        vm.assume(1 <= gain && gain <= MAX_NAV && gain > dust);
        // A nonzero fee percentage whose floored slice of the gain is at least one wei, so the sync books an
        // initial junior fee and the coverage step must revisit it
        vm.assume(1 <= jtFeeWAD && jtFeeWAD <= WAD);
        vm.assume(gain * jtFeeWAD >= WAD);

        // Coverage is the smaller of the senior loss and the junior buffer after its gain landed
        uint256 expectedCoverage = loss < jtNAV + gain ? loss : jtNAV + gain;
        // Sub-arm: the net gain survives coverage and still clears the dust gate, so a fee is genuinely due
        vm.assume(expectedCoverage < gain && gain - expectedCoverage > dust);

        _seedCleanCheckpoint(stNAV, jtNAV, 0, uint64(jtFeeWAD), dust);
        (SyncedAccountingState memory state,, bool premiumsPaid,) = driver.runSync(stNAV - loss, jtNAV + gain, 0, 0);

        // Why the recompute: coverage has a prior claim on junior's sync gain, so the fee base is what junior
        // keeps after protecting seniors. Charging the full-gain fee would make the protocol senior to the
        // coverage obligation and extract fees from capital that was never junior yield
        uint256 netGain = gain - expectedCoverage;
        assert(toUint256(state.jtProtocolFee) == (netGain * jtFeeWAD) / WAD);

        // Bookkeeping around the fee: junior nets its gain minus the coverage it surrendered, senior books
        // only the uncovered residual of its loss
        assert(toUint256(state.jtEffectiveNAV) == jtNAV + gain - expectedCoverage);
        assert(toUint256(state.stEffectiveNAV) == stNAV - (loss - expectedCoverage));
        // Senior lost, so no senior yield exists to pay premiums or the senior-side fees from
        assert(!premiumsPaid);
        assert(toUint256(state.ltLiquidityPremium) == 0);
        assert(toUint256(state.stProtocolFee) == 0);
        assert(toUint256(state.ltProtocolFee) == 0);
    }

    /**
     * @notice When the coverage junior provides on a mixed sync consumes its gain down to (or past) the dust
     *         tolerance, the initially booked junior protocol fee is zeroed outright: the recompute re-applies
     *         the dust gate to the net gain, so a junior left with only rounding-level yield after covering
     *         seniors pays no fee at all, even though a fee-worthy gain was on its books mid-sync
     * @dev Same pinning as the recompute check but with coverage at or above gain - dust, which drives the
     *      saturating net gain to at most the dust tolerance and selects the zeroing sub-arm. Covers the full
     *      wipe (coverage >= gain, net gain saturates to zero) and the dust remnant in one branch since both
     *      land on the same zero-fee assignment
     */
    function check_juniorFeeIsZeroedWhenCoverageConsumesTheGainDownToDust(
        uint256 stNAV,
        uint256 jtNAV,
        uint256 loss,
        uint256 gain,
        uint256 jtFeeWAD,
        uint256 dust
    )
        external
    {
        vm.assume(1 <= stNAV && stNAV <= MAX_NAV);
        vm.assume(jtNAV <= MAX_NAV);
        vm.assume(dust <= MAX_DUST);
        vm.assume(1 <= loss && loss <= stNAV);
        vm.assume(1 <= gain && gain <= MAX_NAV && gain > dust);
        // Arm the recompute with a genuinely booked initial fee, exactly as in the sibling check
        vm.assume(1 <= jtFeeWAD && jtFeeWAD <= WAD);
        vm.assume(gain * jtFeeWAD >= WAD);

        // Sub-arm: coverage eats the gain down to at most dust (including entirely, where the saturating
        // subtraction floors the net gain at zero rather than underflowing into junior principal)
        uint256 expectedCoverage = loss < jtNAV + gain ? loss : jtNAV + gain;
        vm.assume(expectedCoverage + dust >= gain);

        _seedCleanCheckpoint(stNAV, jtNAV, 0, uint64(jtFeeWAD), dust);
        (SyncedAccountingState memory state,,,) = driver.runSync(stNAV - loss, jtNAV + gain, 0, 0);

        // Why zero and not the stale fee: the initial fee was priced on yield junior did not get to keep.
        // Letting it stand would charge junior a fee for the privilege of absorbing senior losses, inverting
        // the risk premium it is owed for exactly that service
        assert(toUint256(state.jtProtocolFee) == 0);

        // The NAV bookkeeping is unaffected by the fee zeroing: junior still nets gain minus coverage and
        // senior still books only the uncovered residual
        assert(toUint256(state.jtEffectiveNAV) == jtNAV + gain - expectedCoverage);
        assert(toUint256(state.stEffectiveNAV) == stNAV - (loss - expectedCoverage));
    }

    /**
     * @notice A junior gain at or below the dust tolerance books no initial fee, and the coverage step then
     *         leaves the fee untouched at zero: the recompute only ever runs downward from a nonzero initially
     *         booked fee. This asymmetry is intended and safe, because coverage can only shrink the net gain,
     *         so a fee that started at zero could never legitimately become positive after coverage
     * @dev Pins the dust-gated arm: gain at most the dust tolerance means the initial fee assignment is
     *      skipped entirely, so the coverage block's fee revisit (guarded on a nonzero booked fee) is
     *      statically bypassed no matter how large the configured fee percentage is
     */
    function check_juniorFeeStaysZeroWhenTheDustGateBookedNoInitialFee(
        uint256 stNAV,
        uint256 jtNAV,
        uint256 loss,
        uint256 gain,
        uint256 jtFeeWAD,
        uint256 dust
    )
        external
    {
        vm.assume(1 <= stNAV && stNAV <= MAX_NAV);
        vm.assume(jtNAV <= MAX_NAV);
        vm.assume(dust <= MAX_DUST);
        vm.assume(1 <= loss && loss <= stNAV);
        // Pin the dust-gated junior gain: nonzero but within the tolerance, so no initial fee is booked
        vm.assume(1 <= gain && gain <= dust);
        vm.assume(1 <= jtFeeWAD && jtFeeWAD <= WAD);

        _seedCleanCheckpoint(stNAV, jtNAV, 0, uint64(jtFeeWAD), dust);
        (SyncedAccountingState memory state,,,) = driver.runSync(stNAV - loss, jtNAV + gain, 0, 0);

        // Why this matters: a dust-sized junior gain is attributable to rounding in the underlying marks, not
        // real yield, so no fee is due on it, and the coverage step must not resurrect a fee out of nothing
        assert(toUint256(state.jtProtocolFee) == 0);

        // Coverage and the NAV moves proceed normally around the silent fee path
        uint256 expectedCoverage = loss < jtNAV + gain ? loss : jtNAV + gain;
        assert(toUint256(state.jtEffectiveNAV) == jtNAV + gain - expectedCoverage);
        assert(toUint256(state.stEffectiveNAV) == stNAV - (loss - expectedCoverage));
    }
}
