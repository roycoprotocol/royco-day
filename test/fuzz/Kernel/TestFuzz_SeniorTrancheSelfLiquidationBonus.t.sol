// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { AssetClaims, MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { MarketFuzzTestBase } from "../../utils/MarketFuzzTestBase.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";

/**
 * @title TestFuzz_SeniorTrancheSelfLiquidationBonus_Kernel
 * @notice Fuzzes the senior tranche self-liquidation bonus through the full production redemption stack: once coverage
 *         utilization breaches the liquidation threshold, a redeeming senior LP receives exactly the derived
 *         bonus on top of its pro-rata claims, and paying that bonus can never increase coverage utilization
 *         (the anti-bank-run property: one LP's exit sweetener must not eat into coverage for those who stay),
 *         both at the deployed 1% config and across the setter's full validated range up to WAD - 1 (~100%)
 * @dev The market is driven into liquidation with a fuzzed shared drawdown at a fixed 30% junior seed ratio.
 *      With jt = 0.3 x st, a drawdown r in [-23%, -20.8%] leaves the junior buffer positive but thin:
 *      jtEffectiveNAV = 0.3 x st x r - st x (1 - r) and coverage utilization 1.3 x st x r x 0.2 / jtEffectiveNAV evaluates to at least
 *      (1.3 x 0.792 x 0.2) / (0.3 x 0.792 - 0.208) = 6.956 at the shallow end, above the 6.4667 liquidation
 *      threshold, and the buffer only thins (utilization only grows) as the drawdown deepens toward the
 *      junior-exhaustion point at -23.077%
 */
contract TestFuzz_SeniorTrancheSelfLiquidationBonus_Kernel is MarketFuzzTestBase {
    using Math for uint256;

    /**
     * @dev The liquidation coverage utilization threshold this fixture deploys every market with, pinned against
     *      the live config in each fuzz body. Why the fuzzed drawdown band always breaches it: with a 20% minimum
     *      coverage and a junior seed of 0.3 x st, a shared drawdown r marks coverage utilization at
     *      1.3 x (1 - r) x 0.2 / (0.3 x (1 - r) - r), which crosses 6.4667 at r = 20.62% and only grows as the
     *      drawdown deepens, so the band's shallow end of r = 20.8% (utilization 0.20592 / 0.0296 = 6.9568)
     *      already sits past the threshold
     */
    uint256 internal constant LIQUIDATION_COVERAGE_THRESHOLD_WAD = 6.4667e18;

    /// @dev The self-liquidation bonus this fixture deploys every market with: 1% of the redeemed claim NAV
    uint64 internal constant CONFIGURED_BONUS_WAD = 0.01e18;

    /**
     * Scenario: a covered drawdown breaches the liquidation threshold (which forces the market PERPETUAL so
     * withdrawals stay open), then a senior LP redeems a fuzzed slice. The payout must be the pro-rata claims
     * plus exactly the mirror-derived bonus - min(1% of the claim NAV, the junior buffer, the largest bonus
     * that keeps coverage utilization from rising) - sourced from the junior tranche's own assets (the junior
     * tranche holds no cross-claim on senior raw NAV after paying coverage). Afterwards the committed marks
     * must show coverage utilization at or below its pre-redemption value.
     */
    function testFuzz_SeniorTrancheSelfLiquidationBonus_PaysExactBonusAndNeverRaisesCoverageUtilization(
        uint256 _stSeed,
        uint256 _drawdownBps,
        uint256 _sharesSeed
    )
        public
    {
        uint256 st = bound(_stSeed, 1e18, 1e26); // uniform over 8 orders of magnitude of senior seed size
        // uniform drawdowns from -23% to -20.8%: always past the liquidation threshold, never exhausting the
        // junior buffer (exhaustion sits at -23.077% for the 30% junior ratio)
        uint256 drawdownBps = bound(_drawdownBps, 2080, 2300);
        uint256 jt = st * 3 / 10;
        _seedFlatMarket(st, jt, 0);

        applySTPnL(-int256(drawdownBps));
        SyncedAccountingState memory state = _sync();

        // Committed drawdown marks, pinned against the hand-derived quoter outputs: the loss is fully covered,
        // so the senior tranche keeps its full effective NAV and the junior buffer absorbs the entire hit
        uint256 rate = 1e18 - drawdownBps * 1e14;
        assertEq(toUint256(state.stRawNAV), st.mulDiv(rate, 1e18), "the senior raw mark must be the seed at the drawn-down rate");
        assertEq(toUint256(state.stEffectiveNAV), st, "a fully covered loss leaves the senior effective NAV whole");
        uint256 covPre = state.coverageUtilizationWAD;
        // Guard the constant against fixture drift, then confirm the band derivation: every drawdown in
        // [-23%, -20.8%] leaves coverage utilization at 6.9568 or above, past the configured threshold
        assertEq(state.coverageLiquidationUtilizationWAD, LIQUIDATION_COVERAGE_THRESHOLD_WAD, "the deployed liquidation threshold must match the pinned config");
        assertGe(covPre, LIQUIDATION_COVERAGE_THRESHOLD_WAD, "the drawdown must breach the liquidation coverage threshold by construction");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "a liquidation breach forces the market PERPETUAL so withdrawals stay open");

        // The senior tranche's total claims: its own raw NAV plus the coverage cross-claim on junior raw NAV
        // (stEffectiveNAV - stRawNAV), each floored through the quoter into vault shares. No mints happened on the loss
        // sync, so the senior supply is still the seed
        assertEq(seniorTranche.totalSupply(), st, "no premium or fee shares mint on a covered-loss sync");
        uint256 stClaimOnJTRaw = st - toUint256(state.stRawNAV);
        uint256 totalSTAssets = toUint256(state.stRawNAV).mulDiv(1e18, rate);
        uint256 totalJTAssets = stClaimOnJTRaw.mulDiv(1e18, rate);

        // The redeemer's base slice and the exact bonus the production stack must pay on top of it. The dust
        // floor of 1e6 share wei keeps the payout above the zero-asset threshold the accountant rejects
        uint256 shares = bound(_sharesSeed, 1e6, st); // dust-to-full-exit slices, small slices exercise the zero-bonus floor path
        uint256 baseNav = st.mulDiv(shares, st);
        uint256 baseSTAssets = totalSTAssets.mulDiv(shares, st);
        uint256 baseJTAssets = totalJTAssets.mulDiv(shares, st);
        assertEq(kernel.getState().stSelfLiquidationBonusWAD, CONFIGURED_BONUS_WAD, "the deployed bonus config must match the pinned 1% rate");
        uint256 expectedBonus = RoycoTestMath.seniorTrancheSelfLiquidationBonus(
            RoycoTestMath.SeniorTrancheSelfLiquidationBonusInputs({
                stRawNAV: toUint256(state.stRawNAV),
                jtRawNAV: toUint256(state.jtRawNAV),
                jtEffectiveNAV: toUint256(state.jtEffectiveNAV),
                jtCoinvested: true,
                coverageUtilizationWAD: covPre,
                coverageLiquidationUtilizationWAD: LIQUIDATION_COVERAGE_THRESHOLD_WAD,
                bonusWAD: CONFIGURED_BONUS_WAD,
                userClaimNAV: baseNav,
                // The redeemer's claim on real exposure: each floored asset leg priced back at the drawn-down
                // vault rate, i.e. the raw NAV this redemption actually pulls out of the covered exposure
                stUserWeightedClaimNAV: baseSTAssets.mulDiv(rate, 1e18) + baseJTAssets.mulDiv(rate, 1e18)
            })
        );

        // Independent caps on the mirrored bonus, derived without re-running the sizing formula: the bonus is a
        // sweetener paid out of the junior buffer, so it can never exceed the configured 1% of the claim NAV nor
        // the junior buffer itself. Tighter still: by two-term conservation the covered exposure minus the junior
        // buffer is exactly the senior seed (stRaw + jtRaw - jtEff == stEff == st, since the covered loss just
        // shuffles value from junior to senior), so the utilization-neutral cap - the redeemed raw exposure times
        // the junior buffer over what remains covering it - is at most claim x jtEffectiveNAV / st, under 3% of
        // the claim across this whole drawdown band
        assertLe(expectedBonus, baseNav / 100, "the bonus can never exceed the configured 1% of the redeemed claim NAV");
        assertLe(expectedBonus, toUint256(state.jtEffectiveNAV), "the bonus can never exceed the junior buffer that sources it");
        assertLe(
            expectedBonus,
            baseNav.mulDiv(toUint256(state.jtEffectiveNAV), st),
            "the bonus can never exceed the claim scaled by the junior buffer per unit of senior seed"
        );

        uint256 balBefore = stJtVault.balanceOf(ST_PROVIDER);
        _expectBonusBoostedRedeemEvent(baseSTAssets, baseJTAssets, baseNav, expectedBonus, rate, shares);
        vm.prank(ST_PROVIDER);
        AssetClaims memory claims = seniorTranche.redeem(shares, ST_PROVIDER, ST_PROVIDER);

        // Exact payout: the bonus lands on the junior-asset leg because the junior tranche's claims sit
        // entirely on its own raw NAV here (it holds no cross-claim on senior raw NAV to source from first)
        assertEq(toUint256(claims.nav), baseNav + expectedBonus, "the redeemed NAV must be the pro-rata slice plus exactly the derived bonus");
        assertEq(toUint256(claims.stAssets), baseSTAssets, "the senior-asset leg must be the unboosted pro-rata slice");
        assertEq(
            toUint256(claims.jtAssets), baseJTAssets + expectedBonus.mulDiv(1e18, rate), "the junior-asset leg must carry the bonus at the drawn-down rate"
        );
        assertEq(
            stJtVault.balanceOf(ST_PROVIDER) - balBefore,
            toUint256(claims.stAssets) + toUint256(claims.jtAssets),
            "the wallet delta must equal both claimed legs exactly"
        );

        // The anti-bank-run property: coverage utilization on the committed post-redemption marks never
        // exceeds its pre-redemption value (up to the unavoidable ceil-rounding envelope), so the bonus can
        // never worsen the remaining LPs' coverage
        uint256 jtEffPost = toUint256(accountant.getState().lastJTEffectiveNAV);
        uint256 covPost = RoycoTestMath.computeCoverageUtilization(
            toUint256(accountant.getState().lastSTRawNAV), toUint256(accountant.getState().lastJTRawNAV), true, 0.2e18, jtEffPost
        );
        _assertCoverageUtilizationNeutralWithinCeilRounding(covPre, covPost, jtEffPost);
    }

    /**
     * Scenario: governance stores the largest self-liquidation bonuses the kernel accepts. The setter validates
     * strictly below WAD (RoycoDayKernel.setSeniorTrancheSelfLiquidationBonus reverts INVALID_SELF_LIQUIDATION_BONUS
     * at 100%+), so this fuzz drives the upper half of the storable range [50%, WAD - 1] through the full
     * redemption stack. The clamp - not the config - must be what protects remaining LPs: the paid bonus lands at
     * min(desired, junior buffer, the largest bonus that keeps coverage utilization from rising), so even a
     * near-100% config cannot let one exiting senior LP drain coverage from everyone who stays (bank-run
     * neutrality across the entire validated setter range).
     */
    function testFuzz_SelfLiquidationBonus_MaxValidConfigNeverIncreasesCoverageUtilization(
        uint256 _stSeed,
        uint256 _drawdownBps,
        uint256 _sharesSeed,
        uint256 _bonusSeed
    )
        public
    {
        uint256 st = bound(_stSeed, 1e18, 1e26); // uniform over 8 orders of magnitude of senior seed size
        // The same drawdown band as the sibling fuzz: always past the liquidation threshold (see the constant's
        // derivation), never exhausting the junior buffer (exhaustion sits at -23.077% for the 30% junior ratio)
        uint256 drawdownBps = bound(_drawdownBps, 2080, 2300);
        uint256 jt = st * 3 / 10;
        _seedFlatMarket(st, jt, 0);

        applySTPnL(-int256(drawdownBps));
        SyncedAccountingState memory state = _sync();

        uint256 covPre = state.coverageUtilizationWAD;
        assertEq(state.coverageLiquidationUtilizationWAD, LIQUIDATION_COVERAGE_THRESHOLD_WAD, "the deployed liquidation threshold must match the pinned config");
        assertGe(covPre, LIQUIDATION_COVERAGE_THRESHOLD_WAD, "the drawdown must breach the liquidation coverage threshold by construction");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "a liquidation breach forces the market PERPETUAL so withdrawals stay open");

        // The setter caps the bonus strictly below WAD (exactly 1e18 reverts INVALID_SELF_LIQUIDATION_BONUS).
        // Drive the maximal end of the valid range so the redemption clamp is still shown to keep an exiting
        // senior LP from raising coverage utilization even at a just-under-100% bonus.
        uint64 bonusWAD = uint64(bound(_bonusSeed, 0.5e18, 1e18 - 1));
        vm.prank(KERNEL_ADMIN);
        kernel.setSeniorTrancheSelfLiquidationBonus(bonusWAD);

        // The loss is fully covered, so the senior effective NAV stays whole and one senior share redeems
        // exactly one NAV wei (supply == effective NAV == the seed, no mints happen on a covered-loss sync)
        uint256 rate = 1e18 - drawdownBps * 1e14;
        assertEq(toUint256(state.stEffectiveNAV), st, "a fully covered loss leaves the senior effective NAV whole");
        assertEq(seniorTranche.totalSupply(), st, "no premium or fee shares mint on a covered-loss sync");

        // The junior buffer, derived from two-term conservation rather than read blind: the covered loss only
        // shuffles value from junior to senior, so jtEff == stRaw + jtRaw - stEff with stEff == st, and
        // equivalently the covered exposure minus the junior buffer is exactly the senior seed
        uint256 jtEffHand = st.mulDiv(rate, 1e18) + jt.mulDiv(rate, 1e18) - st;
        assertEq(toUint256(state.jtEffectiveNAV), jtEffHand, "the junior buffer must equal the conservation-derived mark");

        // The redeemer's base slice, pro-rata over the still-whole senior effective NAV
        uint256 shares = bound(_sharesSeed, 1e6, st); // dust-to-full-exit slices, small slices exercise the floor paths
        uint256 baseNav = shares;
        uint256 baseSTAssets = toUint256(state.stRawNAV).mulDiv(1e18, rate).mulDiv(shares, st);
        uint256 baseJTAssets = (st - toUint256(state.stRawNAV)).mulDiv(1e18, rate).mulDiv(shares, st);

        // The exact bonus the stack must pay: min(desired, junior buffer, utilization-neutral max), mirrored
        // with the fuzzed above-WAD config in place of the deployed 1% rate
        uint256 expectedBonus = RoycoTestMath.seniorTrancheSelfLiquidationBonus(
            RoycoTestMath.SeniorTrancheSelfLiquidationBonusInputs({
                stRawNAV: toUint256(state.stRawNAV),
                jtRawNAV: toUint256(state.jtRawNAV),
                jtEffectiveNAV: jtEffHand,
                jtCoinvested: true,
                coverageUtilizationWAD: covPre,
                coverageLiquidationUtilizationWAD: LIQUIDATION_COVERAGE_THRESHOLD_WAD,
                bonusWAD: bonusWAD,
                userClaimNAV: baseNav,
                // The redeemer's claim on real exposure: each floored asset leg priced back at the drawn-down
                // vault rate, i.e. the raw NAV this redemption actually pulls out of the covered exposure
                stUserWeightedClaimNAV: baseSTAssets.mulDiv(rate, 1e18) + baseJTAssets.mulDiv(rate, 1e18)
            })
        );

        // Independent caps derived without the sizing formula: the config demands up to just under the full
        // claim over again (bonusWAD in [0.5e18, WAD - 1] so desired is 50-100% of baseNav), but the
        // utilization-neutral cap is at most the claim scaled by the junior buffer per unit of senior seed -
        // under 3% of the claim across this band, because the redeemed raw exposure is at most the claim and
        // what remains covering the buffer is exactly st. The demanded bonus therefore NEVER pays in full,
        // and the payout stays inside the junior buffer
        assertLe(expectedBonus, baseNav.mulDiv(jtEffHand, st), "the bonus can never exceed the claim scaled by the junior buffer per unit of senior seed");
        assertLe(expectedBonus, jtEffHand, "the bonus can never exceed the junior buffer that sources it");
        assertLt(expectedBonus, baseNav, "a near-100% configured bonus must still pay out only a small fraction of the claim");

        uint256 balBefore = stJtVault.balanceOf(ST_PROVIDER);
        _expectBonusBoostedRedeemEvent(baseSTAssets, baseJTAssets, baseNav, expectedBonus, rate, shares);
        vm.prank(ST_PROVIDER);
        AssetClaims memory claims = seniorTranche.redeem(shares, ST_PROVIDER, ST_PROVIDER);

        // Exact payout: the clamped bonus lands on the junior-asset leg (the junior tranche holds no cross-claim
        // on senior raw NAV here to source from first) and the wallet delta matches both legs
        assertEq(toUint256(claims.nav), baseNav + expectedBonus, "the redeemed NAV must be the pro-rata slice plus exactly the clamped bonus");
        assertEq(toUint256(claims.stAssets), baseSTAssets, "the senior-asset leg must be the unboosted pro-rata slice");
        assertEq(
            toUint256(claims.jtAssets), baseJTAssets + expectedBonus.mulDiv(1e18, rate), "the junior-asset leg must carry the bonus at the drawn-down rate"
        );
        assertEq(
            stJtVault.balanceOf(ST_PROVIDER) - balBefore,
            toUint256(claims.stAssets) + toUint256(claims.jtAssets),
            "the wallet delta must equal both claimed legs exactly"
        );

        // Bank-run neutrality across the whole unvalidated setter range: coverage utilization on the committed
        // post-redemption marks never exceeds its pre-redemption value, so no configured bonus - however
        // absurd - can worsen the remaining LPs' coverage
        uint256 jtEffPost = toUint256(accountant.getState().lastJTEffectiveNAV);
        uint256 covPost = RoycoTestMath.computeCoverageUtilization(
            toUint256(accountant.getState().lastSTRawNAV), toUint256(accountant.getState().lastJTRawNAV), true, 0.2e18, jtEffPost
        );
        _assertCoverageUtilizationNeutralWithinCeilRounding(covPre, covPost, jtEffPost);
    }

    /**
     * @notice Asserts the anti-bank-run neutrality property to wei precision, allowing only the ceil-rounding
     *         envelope the bonus clamp cannot avoid. Coverage utilization is ceil(coveredExposure x minCoverage /
     *         jtEffectiveNAV), and the bonus is sized so this ratio is non-increasing in EXACT arithmetic. The
     *         redemption, however, settles the residual marks through floor conversions on both tranches' asset
     *         legs (the base slice plus the bonus leg), which leaves the committed coveredExposure numerator a
     *         single rounding wei above the exact utilization-neutral exposure (the drawdown fuzz confirms this
     *         excess is exactly 1 wei in every dust-regime breach observed). Each such numerator wei lifts the
     *         ceil by at most ceil(minCoverage / jtEffectiveNAV), so post coverage utilization can only exceed
     *         the pre value by that envelope, which blows up only when a near-total exit shrinks jtEffectiveNAV to
     *         dust and the ceil turns hypersensitive. A GENUINE neutrality breach scales with the paid bonus
     *         (orders of magnitude larger, since the bonus is a macroscopic fraction of jtEffectiveNAV) and still
     *         fails this bound. The 2-wei slack is a safety margin of one extra rounding wei over the observed
     *         1-wei excess, covering any compounding of the independent floor conversions along the two-tranche,
     *         two-leg removal without approaching a real breach
     * @param _covPre The pre-redemption coverage utilization
     * @param _covPost The post-redemption coverage utilization on the committed marks
     * @param _jtEffPost The committed post-redemption junior effective NAV, the ceil-division denominator
     */
    function _assertCoverageUtilizationNeutralWithinCeilRounding(uint256 _covPre, uint256 _covPost, uint256 _jtEffPost) private pure {
        uint256 roundingSlackWei = 2;
        uint256 toleranceWAD = _jtEffPost == 0 ? 0 : Math.mulDiv(roundingSlackWei, 0.2e18, _jtEffPost, Math.Rounding.Ceil);
        assertLe(
            _covPost, _covPre + toleranceWAD, "paying the self-liquidation bonus must never increase coverage utilization beyond the ceil-rounding envelope"
        );
    }

    /// @notice Arms the exact-args Redeem event check: the emitted claims must be the pro-rata slice with the
    ///         derived bonus landing on the junior-asset leg at the drawn-down rate (kept out of the fuzz body
    ///         to stay under the via-ir stack limit)
    function _expectBonusBoostedRedeemEvent(
        uint256 _baseSTAssets,
        uint256 _baseJTAssets,
        uint256 _baseNav,
        uint256 _expectedBonus,
        uint256 _rate,
        uint256 _shares
    )
        private
    {
        AssetClaims memory expectedClaims;
        expectedClaims.stAssets = toTrancheUnits(_baseSTAssets);
        expectedClaims.jtAssets = toTrancheUnits(_baseJTAssets + _expectedBonus.mulDiv(1e18, _rate));
        expectedClaims.nav = toNAVUnits(_baseNav + _expectedBonus);
        vm.expectEmit(true, true, true, true, address(seniorTranche));
        emit IRoycoVaultTranche.Redeem(ST_PROVIDER, ST_PROVIDER, expectedClaims, _shares);
    }
}
