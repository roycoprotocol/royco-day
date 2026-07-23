// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { AssetClaims, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { UtilizationLogic } from "../../../src/libraries/logic/UtilizationLogic.sol";
import { SelfLiquidationHarness } from "../../mocks/SelfLiquidationHarness.sol";

/**
 * @title TestFuzz_SelfLiquidation_Logic
 * @notice Fuzz property for the ST self-liquidation bonus: on any state whose coverageUtilizationWAD was
 *         produced by the production coverage-utilization math from that same state, applying the bonus
 *         never reverts - in particular the coverage-utilization-neutral cap's division by stEffectiveNAV
 *         can never hit a zero denominator - and the paid bonus obeys the U-neutral bound
 *         floor(userNav * jtEffectiveNAV / stEffectiveNAV)
 * @dev The SelfLiquidationHarness converts collateral tranche units to NAV units 1:1, so every tranche-unit
 *      bound below doubles as its NAV value and the reported bonus equals the sized bonus exactly
 */
contract TestFuzz_SelfLiquidation_Logic is Test {
    /// @notice WAD fixed-point unit, 1e18 == 100%
    uint256 internal constant WAD = 1e18;

    /// @notice Suite-wide NAV ceiling
    uint256 internal constant MAX_NAV = 1e30;

    SelfLiquidationHarness internal sll;

    function setUp() public {
        sll = new SelfLiquidationHarness();
    }

    /**
     * The self-liquidation bonus cap divides by stEffectiveNAV once the liquidation threshold is breached
     * (under conservation stEffectiveNAV == collateralNAV - jtEffectiveNAV), so its safety rests on a
     * number-theoretic lemma about the states that can actually breach: because the liquidation threshold is
     * configured strictly above 100% and minCoverage strictly below 100%, any breached state with a positive
     * junior buffer must have collateral strictly above that buffer, making the senior denominator strictly
     * positive. The chain, written out where it is asserted below:
     *   breach with jtEff > 0 means ceil(collateral * minCov / jtEff) >= threshold >= WAD + 1,
     *   and ceil(a/b) >= WAD + 1 forces a > WAD * b (if a <= WAD * b then a/b <= WAD so ceil(a/b) <= WAD),
     *   so collateral * minCov > WAD * jtEff; with minCov < WAD that gives collateral * WAD > WAD * jtEff,
     *   hence collateral > jtEff, so stEff = collateral - jtEff > 0.
     * The state is deliberately fuzzed with NO breach assumption: the non-breach side pins the zero-bonus
     * early return and the breach side pins the lemma plus a revert-free bonus application capped at
     * min(floor(userNav * bonusRate / WAD), jtEff, floor(userNav * jtEff / stEff)). coverageUtilizationWAD
     * is computed by the production UtilizationLogic from the same fuzzed NAVs, exactly as the accountant
     * checkpoints it, so the input space is precisely the states the kernel can hand to the bonus computation
     */
    function testFuzz_SeniorTrancheSelfLiquidationBonus_NeverRevertsWhenCoverageUtilizationComputedFromOwnState(
        uint256 _collateral,
        uint256 _jtEff,
        uint256 _minCov,
        uint256 _threshold,
        uint256 _bonusWAD,
        uint256 _userCollateralAssets,
        uint256 _userNav
    )
        public
    {
        _collateral = bound(_collateral, 0, MAX_NAV); // uniform over the full NAV range incl. the 0 edge
        _jtEff = bound(_jtEff, 0, MAX_NAV); // includes 0 => the infinite-utilization breach and the zero-buffer early return
        _minCov = bound(_minCov, 0, WAD - 1); // config invariant: minCoverageWAD is strictly below 100%, incl. the 0 edge
        _threshold = bound(_threshold, WAD + 1, 100 * WAD); // config invariant: the liquidation threshold is strictly above 100%
        _bonusWAD = bound(_bonusWAD, 0, WAD); // the full configurable bonus-rate range incl. both edges
        _userCollateralAssets = bound(_userCollateralAssets, 0, MAX_NAV); // redeeming user's claim on collateral assets incl. the 0 edge
        _userNav = bound(_userNav, 0, MAX_NAV); // redeeming user's NAV claim incl. the 0 edge

        // The utilization the accountant would checkpoint for exactly this state, from the production math
        uint256 coverageUtilizationWAD = UtilizationLogic._computeCoverageUtilization(toNAVUnits(_collateral), _minCov, toNAVUnits(_jtEff));

        if (coverageUtilizationWAD >= _threshold && _jtEff > 0) {
            // The lemma, step 1: a finite ceil'd utilization at or above a threshold of at least WAD + 1 forces
            // collateral * minCov > WAD * jtEff, because collateral * minCov <= WAD * jtEff would ceil to at most WAD.
            // No overflow: collateral * minCov <= 1e30 * (1e18 - 1) < 1e48 and WAD * jtEff <= 1e48
            assertGt(_collateral * _minCov, WAD * _jtEff, "breach above 100% forces collateral * minCov > WAD * jtEff");
            // The lemma, step 2: minCov < WAD gives collateral * WAD > collateral * minCov > WAD * jtEff, so
            // collateral > jtEff - the bonus cap's denominator stEff = collateral - jtEff is strictly positive
            // on every breach path it can run on
            assertGt(_collateral, _jtEff, "breach above 100% with minCov below 100% forces collateral > jtEff");
        }

        // Build the state the kernel would hand to the bonus computation. NAV conservation pins
        // stEffectiveNAV = collateral - jtEff; on any path past the breach gate the lemma above guarantees
        // collateral > jtEff so this is non-negative, and on the early-return paths the field is never read, so
        // the saturating clamp to 0 only fills states the computation ignores
        uint256 stEff = _collateral > _jtEff ? _collateral - _jtEff : 0;
        SyncedAccountingState memory state;
        state.collateralNAV = toNAVUnits(_collateral);
        state.stEffectiveNAV = toNAVUnits(stEff);
        state.jtEffectiveNAV = toNAVUnits(_jtEff);
        state.minCoverageWAD = _minCov;
        state.coverageUtilizationWAD = coverageUtilizationWAD;
        state.coverageLiquidationUtilizationWAD = _threshold;

        AssetClaims memory userClaims;
        userClaims.collateralAssets = toTrancheUnits(_userCollateralAssets);
        userClaims.nav = toNAVUnits(_userNav);

        sll.setSelfLiquidationBonusWAD(uint64(_bonusWAD));

        // The property: this call must return, never revert - a div-0 in the neutral-cap denominator would
        // brick every breached-market ST redemption, freezing exits exactly when the market needs ST to
        // self-liquidate
        (AssetClaims memory claimsWithBonus, NAV_UNIT bonusNAV) = sll.applyBonus(state, userClaims);
        uint256 bonus = toUint256(bonusNAV);

        if (coverageUtilizationWAD < _threshold) {
            // Below the liquidation threshold there is no bonus at all: the claims pass through untouched
            assertEq(bonus, 0, "no bonus below the liquidation threshold");
            assertEq(toUint256(claimsWithBonus.nav), _userNav, "claims pass through untouched below the threshold");
            assertEq(toUint256(claimsWithBonus.collateralAssets), _userCollateralAssets, "collateral claim passes through untouched below the threshold");
        } else {
            // The paid bonus never exceeds the junior buffer it is sourced from: paying more would strip
            // remaining LPs of coverage the buffer no longer holds
            assertLe(bonus, _jtEff, "bonus never exceeds the junior effective NAV sourcing it");
            // And never exceeds the configured rate on the redeemed NAV: bonus <= floor(userNav * rate / WAD)
            // is equivalent to bonus * WAD <= userNav * rate for integers.
            // No overflow: bonus <= jtEff <= 1e30 so bonus * WAD <= 1e48, and userNav * rate <= 1e30 * 1e18 = 1e48
            assertLe(bonus * WAD, _userNav * _bonusWAD, "bonus never exceeds the configured rate on the redeemed NAV");
            // The U-neutral bound: paying more than floor(userNav * jtEff / stEff) would raise coverage
            // utilization for the LPs staying behind. The lemma above makes stEff > 0 whenever a nonzero
            // bonus is reachable (jtEff > 0), and a zero jtEff pays a zero bonus, so guard only the division
            if (stEff > 0) {
                assertLe(bonus, Math.mulDiv(_userNav, _jtEff, stEff), "bonus never exceeds the coverage-utilization-neutral bound");
            }
            // Whatever bonus is paid lands wholly in the redeemer's claims, granted in the single collateral
            // leg (the harness converts 1:1, so the granted assets equal the reported bonus NAV exactly)
            assertEq(toUint256(claimsWithBonus.nav), _userNav + bonus, "the paid bonus lands in the redeemer's NAV claim");
            assertEq(toUint256(claimsWithBonus.collateralAssets), _userCollateralAssets + bonus, "the paid bonus lands in the redeemer's collateral claim");
        }
    }
}
