// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { IYDM } from "../../../src/interfaces/IYDM.sol";
import { WAD } from "../../../src/libraries/Constants.sol";
import { MarketState } from "../../../src/libraries/Types.sol";
import { StaticCurveYDM } from "../../../src/ydm/StaticCurveYDM.sol";

/**
 * @title Test_StaticCurveYDMInitDivergences
 * @notice Pinning tests for two StaticCurveYDM lifecycle divergences surfaced by the 2026-07-07 re-audit.
 *         Neither is in FINDINGS.md (findings 3-33); both assert CURRENT behavior and document the
 *         spec-expected behavior in a comment, per the repo's `test_FINDING_<n>` convention.
 * @dev Every expected value is hand-derived from src/ydm/StaticCurveYDM.sol and src/ydm/base/BaseYDM.sol.
 */
contract Test_StaticCurveYDMInitDivergences is Test {
    address constant ACCOUNTANT = address(0xACC0);

    // =====================================================================
    // Finding 34 — StaticCurveYDM with TARGET == WAD bricks initializeYDMForMarket
    // =====================================================================
    //
    // Spec / intent: BaseYDM documents the target utilization (the kink) range as (0, 100%], and its
    //   constructor accepts `_targetUtilizationWAD <= WAD` (src/ydm/base/BaseYDM.sol:25-28). So a static
    //   YDM configured at a 100% (WAD) target is a documented-valid construction and should be usable.
    //
    // Production does: construction at TARGET == WAD succeeds, but the FIRST initializeYDMForMarket call
    //   for any market reverts. `initializeYDMForMarket` computes the upper-segment slope via
    //   `_computeSlope(yT, yFull, TARGET_UTILIZATION_WAD, WAD)` (StaticCurveYDM.sol:86), and _computeSlope
    //   divides by `(_x1WAD - _x0WAD) = WAD - TARGET_UTILIZATION_WAD` (StaticCurveYDM.sol:151). At
    //   TARGET == WAD that denominator is 0, so `Math.mulDiv` reverts (division by zero). The static YDM
    //   is therefore permanently un-initializable at a 100% target — a latent deploy-time brick on a
    //   configuration the BaseYDM bound accepts. (The adaptive models are unaffected: their `WAD - TARGET`
    //   branch is unreachable because utilization is capped at WAD and never exceeds TARGET == WAD.)
    //
    // Where: src/ydm/StaticCurveYDM.sol:86 (the upper-segment slope call), :151 (the WAD - TARGET divisor);
    //        src/ydm/base/BaseYDM.sol:26 (permits _targetUtilizationWAD == WAD).
    // Recommended fix / decision: reject TARGET == WAD in the StaticCurveYDM constructor (it collapses the
    //   upper segment), or special-case the upper slope to 0 when TARGET == WAD.
    function test_FINDING_34_staticCurveTargetWAD_bricksInitializeYDMForMarket() public {
        // Construction at a 100% target is accepted by the shared BaseYDM (0, WAD] gate.
        StaticCurveYDM ydm = new StaticCurveYDM(WAD);
        assertEq(ydm.TARGET_UTILIZATION_WAD(), WAD, "TARGET == WAD constructs successfully");

        // But initializing a market's curve reverts: the upper-segment slope divides by (WAD - TARGET) == 0.
        // Params (1e17, 5e17, 9e17) satisfy the ordering require; the revert originates in _computeSlope's
        // Math.mulDiv division-by-zero, not the input validation.
        vm.prank(ACCOUNTANT);
        vm.expectRevert(); // Math.mulDiv division-by-zero panic (WAD - TARGET == 0)
        ydm.initializeYDMForMarket(1e17, 5e17, 9e17);
    }

    /// Control: an otherwise-identical static YDM at a moderate (sub-WAD) target initializes cleanly,
    /// isolating TARGET == WAD as the sole trigger of the div-by-zero brick.
    /// Note (secondary edge, not the finding): a target very close to WAD instead bricks init via a
    /// uint64 slope overflow — `_computeSlope`'s SafeCast.toUint64 reverts when (WAD - TARGET) is tiny
    /// enough to blow the slope past 2^64-1 (e.g. TARGET = WAD-1 with the params below yields 4e35).
    function test_FINDING_34_control_subWADTarget_initializesCleanly() public {
        StaticCurveYDM ydm = new StaticCurveYDM(8e17);
        vm.prank(ACCOUNTANT);
        ydm.initializeYDMForMarket(1e17, 5e17, 9e17); // no revert
        (,, uint64 yT,) = ydm.accountantToCurve(ACCOUNTANT);
        assertEq(yT, 5e17, "curve initialized at a sub-WAD target");
    }

    // =====================================================================
    // Finding 35 — a static YDM attached without initialization bricks the sync hot path
    // =====================================================================
    //
    // Spec / intent: the accountant's _initializeYDM (RoycoDayAccountant.sol) only invokes
    //   initializeYDMForMarket when the supplied init calldata is non-empty; it performs no
    //   post-condition check that the curve was actually initialized. An empty-calldata attach therefore
    //   leaves the curve uninitialized, and the model's uninitialized sentinel is `yieldShareAtTargetWAD == 0`.
    //
    // Production does: a StaticCurveYDM whose curve was never initialized for `msg.sender` reverts
    //   UNINITIALIZED_YDM on the first yieldShare/previewYieldShare (StaticCurveYDM.sol _yieldShare guard).
    //   Because the accountant calls the YDM on every premium accrual, an empty-calldata attach (or any
    //   non-reverting attach that skips initialization) bricks the sync hot path until an admin re-sets the
    //   YDM with proper init data. This unit test pins the model-level revert that underlies that brick; the
    //   adaptive-model equivalent is covered in Test_BaseAdaptiveCurveYDM.t.sol but the static model was not.
    //
    // Where: src/ydm/StaticCurveYDM.sol (the `yieldShareAtTargetWAD != 0` UNINITIALIZED_YDM guard);
    //        src/accountant/RoycoDayAccountant.sol _initializeYDM (empty-calldata branch, no init post-check).
    // Recommended fix / decision: have _initializeYDM require a non-empty init payload (or verify the curve
    //   reads initialized) so a YDM can never be attached in the uninitialized state.
    function test_FINDING_35_staticCurveAttachedWithoutInit_revertsUninitializedOnYieldShare() public {
        StaticCurveYDM ydm = new StaticCurveYDM(5e17);

        // No initializeYDMForMarket call for ACCOUNTANT: the curve for this sender is the zero sentinel.
        vm.prank(ACCOUNTANT);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        ydm.previewYieldShare(MarketState.PERPETUAL, WAD);
    }
}
