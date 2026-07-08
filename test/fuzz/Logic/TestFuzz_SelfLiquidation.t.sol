// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { AssetClaims, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { UtilizationLogic } from "../../../src/libraries/logic/UtilizationLogic.sol";
import { SelfLiquidationHarness } from "../../mocks/SelfLiquidationHarness.sol";

/**
 * @title TestFuzz_SelfLiquidation_Logic
 * @notice Fuzz property for the ST self-liquidation bonus: on any state whose coverageUtilizationWAD was
 *         produced by the production coverage-utilization math from that same state, applying the bonus
 *         never reverts — in particular the coverage-utilization-neutral cap's division by
 *         (totalCoveredExposure - jtEffectiveNAV) can never hit a zero or underflowing denominator
 * @dev The SelfLiquidationHarness converts tranche units to NAV units 1:1, so every tranche-unit bound
 *      below doubles as its NAV value
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
     * The self-liquidation bonus cap divides by (totalCoveredExposure - jtEffectiveNAV) once the liquidation
     * threshold is breached (SelfLiquidationLogic.sol:120), so its safety rests on a number-theoretic lemma
     * about the states that can actually breach: because the liquidation threshold is configured strictly
     * above 100% and minCoverage strictly below 100%, any breached state with a positive junior buffer must
     * have exposure strictly above that buffer, making the denominator strictly positive. The chain, written
     * out where it is asserted below:
     *   breach with jtEff > 0 means ceil(exposure * minCov / jtEff) >= threshold >= WAD + 1,
     *   and ceil(a/b) >= WAD + 1 forces a > WAD * b (if a <= WAD * b then a/b <= WAD so ceil(a/b) <= WAD),
     *   so exposure * minCov > WAD * jtEff; with minCov < WAD that gives exposure * WAD > WAD * jtEff,
     *   hence exposure > jtEff.
     * The state is deliberately fuzzed with NO breach assumption: the non-breach side pins the zero-bonus
     * early return and the breach side pins the lemma plus a revert-free bonus application capped at
     * min(floor(userNav * bonusRate / WAD), jtEff). coverageUtilizationWAD is computed by the production
     * UtilizationLogic from the same fuzzed NAVs, exactly as the accountant checkpoints it, so the input
     * space is precisely the states the kernel can hand to the bonus computation
     */
    function testFuzz_SeniorTrancheSelfLiquidationBonus_NeverRevertsWhenCoverageUtilizationComputedFromOwnState(
        uint256 _stRaw,
        uint256 _jtRaw,
        uint256 _jtEff,
        uint256 _minCov,
        uint256 _threshold,
        bool _jtCoinvested,
        uint256 _bonusWAD,
        uint256 _userStAssets,
        uint256 _userJtAssets,
        uint256 _userNav
    )
        public
    {
        _stRaw = bound(_stRaw, 0, MAX_NAV); // uniform over the full NAV range incl. the 0 edge
        _jtRaw = bound(_jtRaw, 0, MAX_NAV); // uniform over the full NAV range incl. the 0 edge
        _jtEff = bound(_jtEff, 0, MAX_NAV); // includes 0 => the infinite-utilization breach and the zero-buffer early return
        _minCov = bound(_minCov, 0, WAD - 1); // config invariant: minCoverageWAD is strictly below 100%, incl. the 0 edge
        _threshold = bound(_threshold, WAD + 1, 100 * WAD); // config invariant: the liquidation threshold is strictly above 100%
        _bonusWAD = bound(_bonusWAD, 0, WAD); // the full configurable bonus-rate range incl. both edges
        _userStAssets = bound(_userStAssets, 0, MAX_NAV); // redeeming user's claim on ST assets incl. the 0 edge
        _userJtAssets = bound(_userJtAssets, 0, MAX_NAV); // redeeming user's claim on JT assets incl. the 0 edge
        _userNav = bound(_userNav, 0, MAX_NAV); // redeeming user's NAV claim incl. the 0 edge

        // The utilization the accountant would checkpoint for exactly this state, from the production math
        uint256 coverageUtilizationWAD =
            UtilizationLogic._computeCoverageUtilization(toNAVUnits(_stRaw), toNAVUnits(_jtRaw), _jtCoinvested, _minCov, toNAVUnits(_jtEff));

        uint256 exposure = _stRaw + (_jtCoinvested ? _jtRaw : 0);
        if (coverageUtilizationWAD >= _threshold && _jtEff > 0) {
            // The lemma, step 1: a finite ceil'd utilization at or above a threshold of at least WAD + 1 forces
            // exposure * minCov > WAD * jtEff, because exposure * minCov <= WAD * jtEff would ceil to at most WAD.
            // No overflow: exposure * minCov <= 2e30 * (1e18 - 1) < 2e48 and WAD * jtEff <= 1e48
            assertGt(exposure * _minCov, WAD * _jtEff, "breach above 100% forces exposure * minCov > WAD * jtEff");
            // The lemma, step 2: minCov < WAD gives exposure * WAD > exposure * minCov > WAD * jtEff, so exposure > jtEff —
            // the bonus cap's denominator (exposure - jtEff) is strictly positive on every breach path it can run on
            assertGt(exposure, _jtEff, "breach above 100% with minCov below 100% forces exposure > jtEff");
        }

        // Build the state the kernel would hand to the bonus computation. NAV conservation pins
        // stEffectiveNAV = stRaw + jtRaw - jtEff; on any path past the breach gate the lemma above guarantees
        // exposure > jtEff so this is non-negative, and on the early-return paths the field is never read, so
        // the saturating clamp to 0 only fills states the computation ignores
        SyncedAccountingState memory state;
        state.stRawNAV = toNAVUnits(_stRaw);
        state.jtRawNAV = toNAVUnits(_jtRaw);
        state.stEffectiveNAV = toNAVUnits(_stRaw + _jtRaw > _jtEff ? _stRaw + _jtRaw - _jtEff : 0);
        state.jtEffectiveNAV = toNAVUnits(_jtEff);
        state.jtCoinvested = _jtCoinvested;
        state.minCoverageWAD = _minCov;
        state.coverageUtilizationWAD = coverageUtilizationWAD;
        state.coverageLiquidationUtilizationWAD = _threshold;

        AssetClaims memory userClaims;
        userClaims.stAssets = toTrancheUnits(_userStAssets);
        userClaims.jtAssets = toTrancheUnits(_userJtAssets);
        userClaims.nav = toNAVUnits(_userNav);

        sll.setSelfLiquidationBonusWAD(uint64(_bonusWAD));

        // The property: this call must return, never revert — a div-0 or underflow in the neutral-cap
        // denominator would brick every breached-market ST redemption, freezing exits exactly when the
        // market needs ST to self-liquidate
        (AssetClaims memory claimsWithBonus, NAV_UNIT bonusNAV) = sll.applyBonus(state, userClaims);
        uint256 bonus = toUint256(bonusNAV);

        if (coverageUtilizationWAD < _threshold) {
            // Below the liquidation threshold there is no bonus at all: the claims pass through untouched
            assertEq(bonus, 0, "no bonus below the liquidation threshold");
            assertEq(toUint256(claimsWithBonus.nav), _userNav, "claims pass through untouched below the threshold");
        } else {
            // The paid bonus never exceeds the junior buffer it is sourced from: paying more would strip
            // remaining LPs of coverage the buffer no longer holds
            assertLe(bonus, _jtEff, "bonus never exceeds the junior effective NAV sourcing it");
            // And never exceeds the configured rate on the redeemed NAV: bonus <= floor(userNav * rate / WAD)
            // is equivalent to bonus * WAD <= userNav * rate for integers.
            // No overflow: bonus <= jtEff <= 1e30 so bonus * WAD <= 1e48, and userNav * rate <= 1e30 * 1e18 = 1e48
            assertLe(bonus * WAD, _userNav * _bonusWAD, "bonus never exceeds the configured rate on the redeemed NAV");
            // Whatever bonus is paid lands wholly in the redeemer's NAV claim (the mock converts 1:1, so the
            // sourced ST and JT legs sum to the same NAV)
            assertEq(toUint256(claimsWithBonus.nav), _userNav + bonus, "the paid bonus lands in the redeemer's NAV claim");
        }
    }
}
