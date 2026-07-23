// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { AccountantTestBase } from "../../utils/AccountantTestBase.sol";

/**
 * @title Test_CoverageCrossClaimFindings_Accountant
 * @notice Executable resolutions of two externally reported coverage-accounting findings against the sync waterfall
 *         (`_previewSyncTrancheAccounting`), pinned with exact wei-level assertions. Both findings are CLOSED by the
 *         drawdown impermanent-loss semantics (JT losses book IL in the JT PnL branch and JT gains recover it first):
 *
 *         Finding 1 (resolved) — a covered drawdown followed by full raw-NAV recovery is exactly neutral for JT. The
 *         ST cross-claim's proportional appreciation on JT's raw recovery no longer survives the IL clawback as
 *         residual "ST yield": the IL carries JT's full drawdown, so the recovery consumes the entire senior gain
 *         and JT returns to its exact starting effective NAV, independent of the configured yield shares
 *
 *         Finding 2 (resolved) — `jtImpermanentLoss` no longer depends on sync cadence. The IL is JT's drawdown from
 *         its high-water mark (300e18 - jtEffectiveNAV here), a pure function of the committed effective NAV, so the
 *         same decline booked in one sync vs two lands on the identical ledger and an identical recovery sync
 *         produces identical outcomes: intermediate checkpoints buy no recovery priority
 *
 * @dev These pins are the neutral values the original findings spec required of a cross-claim-recovery fix
 *      (Finding 1: the exact 1000e18/300e18 round trip; Finding 2: path-independent IL). A regression back toward
 *      nominal-coverage IL accounting flips them loudly
 * @dev Deploys with `coverageLiquidationUtilizationWAD = 2.5e18` (defaults elsewhere): Finding 2's deep leg sits at
 *      coverageUtilization = ceil(0.1e18 * (810e18 + 243e18) / 53e18) ~ 1.987e18, which would breach the default
 *      1.1e18 threshold and erase the IL under test (the liquidation disjunct forces PERPETUAL and resets the ledger)
 */
contract Test_CoverageCrossClaimFindings_Accountant is AccountantTestBase {
    /// @dev Raised liquidation threshold so the deep drawdown legs keep their IL instead of tripping the erasure disjunct
    uint256 internal constant FINDINGS_LIQUIDATION_UTILIZATION_WAD = 2.5e18;

    // Shared scenario constants: symmetric 1000/300 market, -10% shared-asset drawdown checkpoints
    uint256 internal constant ST_RAW_0 = 1000e18;
    uint256 internal constant JT_RAW_0 = 300e18;

    // Recovery-sync attribution at the dip checkpoint (stRaw 900e18, jtRaw 270e18, stEff 1000e18, jtEff 170e18):
    //   cross-claim stClaimOnJTRawNAV = 1000e18 - 900e18 = 100e18
    //   deltaSTClaimOnJTRawNAV = floor(30e18 * 100e18 / 270e18) = 11_111_111_111_111_111_111 (the cross-claim appreciation)
    //   deltaJTEffectiveNAV = 130e18 - (100e18 + 11_111_111_111_111_111_111) = 18_888_888_888_888_888_889 (JT residual)
    uint256 internal constant CROSS_CLAIM_APPRECIATION = 11_111_111_111_111_111_111;
    uint256 internal constant JT_RESIDUAL_ON_RECOVERY = 18_888_888_888_888_888_889;

    function setUp() public {
        _deploy(_findingsParams());
    }

    /// @dev Default params with only the liquidation threshold raised (see the contract natspec for why)
    function _findingsParams() internal pure returns (IRoycoDayAccountant.RoycoDayAccountantInitParams memory p) {
        p = _defaultParams();
        p.coverageLiquidationUtilizationWAD = FINDINGS_LIQUIDATION_UTILIZATION_WAD;
    }

    /// @dev Pins deterministic instantaneous yield shares: jt 10%, lt 5% (all syncs run same-block, so the premium
    ///      branch is the instantaneous one and prices exactly at these preview rates)
    function _pinRates() internal {
        jtYDM.setPreviewYieldShareReturn(0.1e18);
        ltYDM.setPreviewYieldShareReturn(0.05e18);
    }

    /// @dev Fresh accountant + symmetric 1000/300 seed + pinned rates (used for the A/B path comparisons)
    function _freshSymmetricMarket() internal {
        _deploy(_findingsParams());
        _seedSymmetric(ST_RAW_0, JT_RAW_0, 0);
        _pinRates();
    }

    /// @dev The -10% covered dip sync: ST loses 100e18 (fully covered by JT), JT absorbs its own 30e18
    function _dipSync() internal returns (SyncedAccountingState memory state) {
        state = kernel.doPreOp(toNAVUnits(uint256(900e18)), toNAVUnits(uint256(270e18)));
    }

    /*//////////////////////////////////////////////////////////////////////
            FINDING 1 (RESOLVED): COVERED ROUND TRIPS ARE JT-NEUTRAL
    //////////////////////////////////////////////////////////////////////*/

    /**
     * FINDING 1 (headline, resolved): full raw-NAV recovery of a covered drawdown returns JT exactly to its start
     *
     * Derivation (all wei-exact):
     *   dip: deltaJTEff = -30e18 books il 30e18, deltaSTEff = -100e18 is covered (il 130e18, jtEff 170e18)
     *   recovery: deltaSTClaimOnST = 100e18, deltaSTClaimOnJT = floor(30e18 * 100/270) = 11_111_111_111_111_111_111
     *     -> stGain = 111_111_111_111_111_111_111; JT's own gain 18_888_888_888_888_888_889 recovers il to
     *        130e18 - 18_888_888_888_888_888_889 = 111_111_111_111_111_111_111 = stGain EXACTLY, so the recovery
     *        consumes the entire senior gain: no residual enters the premium waterfall
     *   final: stEff = 1000e18, jtEff = 300e18, il = 0 with raw back at exactly 1000e18/300e18
     */
    function test_Finding1_CoveredRoundTripFullRecovery_MakesJTExactlyWhole() public {
        _seedSymmetric(ST_RAW_0, JT_RAW_0, 0);
        _pinRates();

        // Dip -10%: the JT loss books as impermanent, coverage deepens it, and the market enters the fixed term
        SyncedAccountingState memory dip = _dipSync();
        assertEq(toUint256(dip.stEffectiveNAV), 1000e18, "dip: ST fully covered by JT");
        assertEq(toUint256(dip.jtEffectiveNAV), 170e18, "dip: JT absorbs own 30e18 and covers 100e18");
        assertEq(toUint256(dip.jtImpermanentLoss), 130e18, "dip: the full JT drawdown booked as IL");
        assertEq(uint8(dip.marketState), uint8(MarketState.FIXED_TERM), "dip: covered loss enters fixed term");

        // Full raw recovery to the exact starting NAVs
        SyncedAccountingState memory rec = kernel.doPreOp(toNAVUnits(ST_RAW_0), toNAVUnits(JT_RAW_0));

        assertEq(toUint256(rec.jtImpermanentLoss), 0, "recovery: the drawdown IL fully recovered");
        assertEq(uint8(rec.marketState), uint8(MarketState.PERPETUAL), "recovery: cleared IL ends the fixed term");
        // The resolution: raw NAVs are exactly back at the start and so are the effective NAVs
        assertEq(toUint256(rec.stEffectiveNAV), ST_RAW_0, "FINDING 1 RESOLVED: ST ends exactly at its start after a pure round trip");
        assertEq(toUint256(rec.jtEffectiveNAV), JT_RAW_0, "FINDING 1 RESOLVED: JT ends exactly at its start after a pure round trip");
        assertEq(toUint256(rec.stEffectiveNAV) + toUint256(rec.jtEffectiveNAV), ST_RAW_0 + JT_RAW_0, "NAV conservation holds throughout");

        // Mechanism: after JT's own gain recovers its share, the remaining IL equals the senior gain exactly,
        // so the clawback consumes all of it and the cross-claim appreciation never leaks into the waterfall
        assertEq(100e18 + CROSS_CLAIM_APPRECIATION, 130e18 - JT_RESIDUAL_ON_RECOVERY, "stGain == il after JT's own recovery, wei-exact");
    }

    /**
     * FINDING 1 (control): the identical economic round trip is also neutral when the dip is never observed
     * by a sync — with the drawdown IL the observed and unobserved paths now land on the same endpoint
     */
    function test_Finding1_UnobservedDip_RoundTripIsNeutral() public {
        _seedSymmetric(ST_RAW_0, JT_RAW_0, 0);
        _pinRates();
        vm.warp(block.timestamp + 1 days);

        // The dip happened and recovered between syncs: the accountant only ever sees the flat endpoint
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(ST_RAW_0), toNAVUnits(JT_RAW_0));

        assertEq(toUint256(state.stEffectiveNAV), ST_RAW_0, "unobserved round trip: ST unchanged");
        assertEq(toUint256(state.jtEffectiveNAV), JT_RAW_0, "unobserved round trip: JT unchanged");
        assertEq(toUint256(state.jtImpermanentLoss), 0, "unobserved round trip: no IL");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "unobserved round trip: stays perpetual");
    }

    /**
     * FINDING 1 (mechanism boundaries): neutrality no longer depends on the yield share. The recovery consumes
     * the entire senior gain before the premium waterfall runs, so at ys = 0 (where the original finding leaked
     * the FULL cross-claim appreciation) the round trip is exactly neutral
     */
    function test_Finding1_ZeroYieldShare_RoundTripStillNeutral() public {
        _seedSymmetric(ST_RAW_0, JT_RAW_0, 0);
        jtYDM.setPreviewYieldShareReturn(0);
        ltYDM.setPreviewYieldShareReturn(0);

        _dipSync();
        SyncedAccountingState memory rec = kernel.doPreOp(toNAVUnits(ST_RAW_0), toNAVUnits(JT_RAW_0));

        assertEq(toUint256(rec.jtEffectiveNAV), JT_RAW_0, "ys = 0: JT made exactly whole");
        assertEq(toUint256(rec.stEffectiveNAV), ST_RAW_0, "ys = 0: ST exactly back at start");
        assertEq(toUint256(rec.jtImpermanentLoss), 0, "ys = 0: IL fully recovered");
    }

    /**
     * FINDING 1 (mechanism boundaries): the ys = 100% endpoint that was already neutral under the original
     * accounting stays neutral, pinning that the closed form leak = 0 now holds across the whole ys range
     */
    function test_Finding1_FullYieldShare_RoundTripStillNeutral() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _findingsParams();
        p.maxJTYieldShareWAD = 1e18;
        p.maxLTYieldShareWAD = 0;
        _deploy(p);
        _seedSymmetric(ST_RAW_0, JT_RAW_0, 0);
        jtYDM.setPreviewYieldShareReturn(1e18);
        ltYDM.setPreviewYieldShareReturn(0);

        _dipSync();
        SyncedAccountingState memory rec = kernel.doPreOp(toNAVUnits(ST_RAW_0), toNAVUnits(JT_RAW_0));

        assertEq(toUint256(rec.jtEffectiveNAV), JT_RAW_0, "ys = 100%: JT made exactly whole");
        assertEq(toUint256(rec.stEffectiveNAV), ST_RAW_0, "ys = 100%: ST exactly back at start");
        assertEq(toUint256(rec.jtImpermanentLoss), 0, "ys = 100%: IL cleared");
    }

    /*//////////////////////////////////////////////////////////////////////
            FINDING 2 (RESOLVED): IL IS INDEPENDENT OF SYNC CADENCE
    //////////////////////////////////////////////////////////////////////*/

    /**
     * FINDING 2 (headline, resolved): the same decline booked in one sync vs two records the IDENTICAL IL
     * against identical final raw and effective NAVs — the ledger is JT's drawdown 300e18 - jtEffectiveNAV,
     * a pure function of the committed state
     *
     * Path A (1.00 -> 0.81, one sync): deltaJTEff = -57e18 books il 57e18, coverage 190e18 deepens it
     *   -> stEff 1000e18, jtEff 53e18, il 247e18
     * Path B (1.00 -> 0.90 -> 0.81, two syncs): leg 1 lands il 130e18 (30e18 JT loss + 100e18 coverage); leg 2
     *   attributes floor(27e18 * 100/270) = 10e18 of the JT raw loss to the cross-claim (exact, no rounding):
     *   deltaJTEff = -17e18 deepens il to 147e18 and coverage 100e18 lands it at 247e18
     *   -> stEff 1000e18, jtEff 53e18, il 247e18: the same drawdown, the same ledger
     */
    function test_Finding2_ILIsPathIndependent_DirectVsTwoStep() public {
        // Path A: single sync straight to the bottom
        _seedSymmetric(ST_RAW_0, JT_RAW_0, 0);
        _pinRates();
        SyncedAccountingState memory pathA = kernel.doPreOp(toNAVUnits(uint256(810e18)), toNAVUnits(uint256(243e18)));
        assertEq(toUint256(pathA.stEffectiveNAV), 1000e18, "path A: ST fully covered");
        assertEq(toUint256(pathA.jtEffectiveNAV), 53e18, "path A: JT absorbs 57e18 and covers 190e18");
        assertEq(toUint256(pathA.jtImpermanentLoss), 247e18, "path A: the full 247e18 drawdown in one sync");

        // Path B: fresh identical market, same decline observed at an intermediate checkpoint
        _freshSymmetricMarket();
        SyncedAccountingState memory mid = _dipSync();
        assertEq(toUint256(mid.jtImpermanentLoss), 130e18, "path B leg 1: the 130e18 drawdown at the checkpoint");
        SyncedAccountingState memory pathB = kernel.doPreOp(toNAVUnits(uint256(810e18)), toNAVUnits(uint256(243e18)));

        // Identical economic endpoint...
        assertEq(toUint256(pathB.stEffectiveNAV), toUint256(pathA.stEffectiveNAV), "identical final ST effective NAV");
        assertEq(toUint256(pathB.jtEffectiveNAV), toUint256(pathA.jtEffectiveNAV), "identical final JT effective NAV");
        // ...and the IDENTICAL coverage ledger
        assertEq(toUint256(pathB.jtImpermanentLoss), toUint256(pathA.jtImpermanentLoss), "FINDING 2 RESOLVED: sync cadence cannot move the IL ledger");
        assertEq(toUint256(pathB.jtImpermanentLoss), JT_RAW_0 - toUint256(pathB.jtEffectiveNAV), "the IL is exactly JT's drawdown from its high-water mark");
    }

    /**
     * FINDING 2 (consequence, resolved): identical recovery syncs from the two identical end states produce
     * identical outcomes — intermediate checkpoints buy no recovery priority. From either path's end state
     * (stRaw 810e18, jtRaw 243e18, eff 1000e18/53e18, il 247e18), apply the IDENTICAL +200e18 ST recovery sync:
     *   deltaSTEff = +200e18, recovery = min(200e18, 247e18) = 200e18 consumes the full gain
     *   -> jtEff 53e18 + 200e18 = 253e18, stEff 1000e18, il 47e18, no waterfall on either path
     */
    function test_Finding2_IdenticalRecovery_NoCadenceAdvantage() public {
        // Path A end state -> identical recovery sync
        _seedSymmetric(ST_RAW_0, JT_RAW_0, 0);
        _pinRates();
        kernel.doPreOp(toNAVUnits(uint256(810e18)), toNAVUnits(uint256(243e18)));
        SyncedAccountingState memory recA = kernel.doPreOp(toNAVUnits(uint256(1010e18)), toNAVUnits(uint256(243e18)));
        assertEq(toUint256(recA.jtImpermanentLoss), 47e18, "path A: the recovery repays 200e18 of the 247e18 drawdown");
        assertEq(toUint256(recA.jtEffectiveNAV), 253e18, "path A: the full gain claws back to JT");
        assertEq(toUint256(recA.stEffectiveNAV), 1000e18, "path A: ST books none of the recovery as yield");

        // Path B end state -> the IDENTICAL recovery sync
        _freshSymmetricMarket();
        _dipSync();
        kernel.doPreOp(toNAVUnits(uint256(810e18)), toNAVUnits(uint256(243e18)));
        SyncedAccountingState memory recB = kernel.doPreOp(toNAVUnits(uint256(1010e18)), toNAVUnits(uint256(243e18)));
        assertEq(toUint256(recB.jtImpermanentLoss), 47e18, "path B: the identical ledger after the identical recovery");
        assertEq(toUint256(recB.jtEffectiveNAV), 253e18, "path B: the identical clawback");
        assertEq(toUint256(recB.stEffectiveNAV), 1000e18, "path B: ST books none of the recovery");

        // The resolution: identical inputs, identical outputs, zero cadence-purchased priority
        assertEq(toUint256(recB.jtEffectiveNAV), toUint256(recA.jtEffectiveNAV), "FINDING 2 RESOLVED: sync cadence shifts no recovery value");
    }
}
