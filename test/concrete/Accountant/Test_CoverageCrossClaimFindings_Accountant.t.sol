// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { AccountantTestBase } from "../../utils/AccountantTestBase.sol";

/**
 * @title Test_CoverageCrossClaimFindings_Accountant
 * @notice Executable reproductions of two externally reported coverage-accounting behaviors of the sync waterfall
 *         (`_previewSyncTrancheAccounting`), pinned with exact wei-level assertions:
 *
 *         Finding 1 — a covered drawdown followed by full raw-NAV recovery is NOT neutral for JT. The ST cross-claim
 *         on JT's raw pool (`stClaimOnJTRawNAV`, minted when JT covers an ST loss) is attributed proportionally, so it
 *         appreciates with JT's raw recovery; that appreciation survives the nominal IL clawback as residual "ST yield"
 *         and is routed through the yield-share waterfall. Leak = crossClaimAppreciation * (1 - jtYieldShare)
 *
 *         Finding 2 — `jtCoverageImpermanentLoss` depends on sync cadence. The same raw-NAV decline booked in one sync
 *         vs two syncs lands on identical final raw AND effective NAVs but different IL ledgers: each intermediate
 *         checkpoint mints a cross-claim whose proportional share of the NEXT JT raw loss is reclassified as
 *         additional coverage. Since the IL has first claim on future ST gains, sync cadence shifts future recovery
 *         priority toward JT
 *
 * @dev These tests pin CURRENT behavior: they pass against today's code and serve as the executable spec for the
 *      internal tradeoff review. If a cross-claim-recovery fix (e.g. a jt_self_il ledger) lands, the pinned constants
 *      flip to the neutral values (Finding 1: 1000e18/300e18 round trip; Finding 2: path-independent IL)
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
                FINDING 1: COVERED ROUND TRIP LEAKS JT VALUE TO ST
    //////////////////////////////////////////////////////////////////////*/

    /**
     * FINDING 1 (headline): full raw-NAV recovery of a covered drawdown leaves JT below its starting effective NAV
     *
     * Derivation (all wei-exact):
     *   dip: deltaSTEff = -100e18 (covered, il 100e18, jtEff 170e18), deltaJTEff = -30e18 -> checkpoint 1000e18/170e18
     *   recovery: deltaSTClaimOnST = 100e18, deltaSTClaimOnJT = floor(30e18 * 100/270) = 11_111_111_111_111_111_111
     *     -> stGain = 111_111_111_111_111_111_111; il recovery claws back the NOMINAL 100e18 (il -> 0, jtEff += 100e18)
     *     -> residual 11_111_111_111_111_111_111 (the cross-claim's PROPORTIONAL appreciation) enters the premium
     *        waterfall as "ST yield": jtRiskPremium = 10% = 1_111_111_111_111_111_111, rest retained senior
     *   final: stEff = 1010e18, jtEff = 290e18 despite raw returning exactly to 1000e18/300e18
     *   leak = 300e18 - 290e18 = 10e18 = crossClaimAppreciation * (1 - jtYieldShare) = 11.11e18 * 0.9
     */
    function test_Finding1_CoveredRoundTripFullRecovery_LeavesJTBelowStart() public {
        _seedSymmetric(ST_RAW_0, JT_RAW_0, 0);
        _pinRates();

        // Dip -10%: fully covered ST loss books IL and enters the fixed term
        SyncedAccountingState memory dip = _dipSync();
        assertEq(toUint256(dip.stEffectiveNAV), 1000e18, "dip: ST fully covered by JT");
        assertEq(toUint256(dip.jtEffectiveNAV), 170e18, "dip: JT absorbs own 30e18 and covers 100e18");
        assertEq(toUint256(dip.jtCoverageImpermanentLoss), 100e18, "dip: nominal coverage booked as IL");
        assertEq(uint8(dip.marketState), uint8(MarketState.FIXED_TERM), "dip: covered loss enters fixed term");

        // Full raw recovery to the exact starting NAVs
        SyncedAccountingState memory rec = kernel.doPreOp(toNAVUnits(ST_RAW_0), toNAVUnits(JT_RAW_0));

        assertEq(toUint256(rec.jtCoverageImpermanentLoss), 0, "recovery: nominal IL fully clawed back");
        assertEq(uint8(rec.marketState), uint8(MarketState.PERPETUAL), "recovery: cleared IL ends the fixed term");
        // The finding: raw NAVs are exactly back at the start, effective NAVs are not
        assertEq(toUint256(rec.stEffectiveNAV), 1010e18, "FINDING 1: ST ends ABOVE its start after a pure round trip");
        assertEq(toUint256(rec.jtEffectiveNAV), 290e18, "FINDING 1: JT ends BELOW its start after a pure round trip");
        assertEq(toUint256(rec.stEffectiveNAV) + toUint256(rec.jtEffectiveNAV), ST_RAW_0 + JT_RAW_0, "NAV conservation holds throughout");

        // Mechanism: the leak is exactly the cross-claim's proportional appreciation net of the JT yield share
        uint256 jtRiskPremium = (CROSS_CLAIM_APPRECIATION * 0.1e18) / 1e18;
        assertEq(JT_RAW_0 - toUint256(rec.jtEffectiveNAV), CROSS_CLAIM_APPRECIATION - jtRiskPremium, "leak == crossClaimAppreciation * (1 - jtYieldShare)");
        assertEq(toUint256(rec.jtEffectiveNAV), 170e18 + JT_RESIDUAL_ON_RECOVERY + 100e18 + jtRiskPremium, "JT = buffer + residual + IL clawback + premium");
    }

    /**
     * FINDING 1 (control): the identical economic round trip is perfectly neutral when the dip is never observed
     * by a sync — proving the leak is created by the checkpoint itself, not by the price path
     */
    function test_Finding1_UnobservedDip_RoundTripIsNeutral() public {
        _seedSymmetric(ST_RAW_0, JT_RAW_0, 0);
        _pinRates();
        vm.warp(block.timestamp + 1 days);

        // The dip happened and recovered between syncs: the accountant only ever sees the flat endpoint
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(ST_RAW_0), toNAVUnits(JT_RAW_0));

        assertEq(toUint256(state.stEffectiveNAV), ST_RAW_0, "unobserved round trip: ST unchanged");
        assertEq(toUint256(state.jtEffectiveNAV), JT_RAW_0, "unobserved round trip: JT unchanged");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 0, "unobserved round trip: no IL");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "unobserved round trip: stays perpetual");
    }

    /**
     * FINDING 1 (mechanism boundaries): the leak scales exactly with (1 - jtYieldShare)
     *
     * jtYieldShare = 0: the full cross-claim appreciation is retained senior
     *   jtEff = 170e18 + 18_888_888_888_888_888_889 + 100e18 = 288_888_888_888_888_888_889
     */
    function test_Finding1_LeakAtZeroYieldShare_IsFullCrossClaimAppreciation() public {
        _seedSymmetric(ST_RAW_0, JT_RAW_0, 0);
        jtYDM.setPreviewYieldShareReturn(0);
        ltYDM.setPreviewYieldShareReturn(0);

        _dipSync();
        SyncedAccountingState memory rec = kernel.doPreOp(toNAVUnits(ST_RAW_0), toNAVUnits(JT_RAW_0));

        assertEq(toUint256(rec.jtEffectiveNAV), 170e18 + JT_RESIDUAL_ON_RECOVERY + 100e18, "leak is the full cross-claim appreciation at ys = 0");
        assertEq(toUint256(rec.stEffectiveNAV), ST_RAW_0 + CROSS_CLAIM_APPRECIATION, "ST retains the full cross-claim appreciation at ys = 0");
        assertEq(JT_RAW_0 - toUint256(rec.jtEffectiveNAV), CROSS_CLAIM_APPRECIATION, "leak == crossClaimAppreciation exactly");
    }

    /**
     * FINDING 1 (mechanism boundaries): at a 100% JT yield share the round trip IS neutral — the residual is only
     * MISLABELED as ST yield, and routing all of it back to JT restores exact neutrality (jtEff = 300e18, stEff = 1000e18).
     * This pins the closed form leak = crossClaimAppreciation * (1 - ys) at its zero
     */
    function test_Finding1_LeakAtFullYieldShare_RoundTripIsNeutral() public {
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
        assertEq(toUint256(rec.jtCoverageImpermanentLoss), 0, "ys = 100%: IL cleared");
    }

    /*//////////////////////////////////////////////////////////////////////
                FINDING 2: IL DEPENDS ON SYNC CADENCE
    //////////////////////////////////////////////////////////////////////*/

    /**
     * FINDING 2 (headline): the same decline booked in one sync vs two records different IL against identical
     * final raw AND effective NAVs
     *
     * Path A (1.00 -> 0.81, one sync): deltaSTEff = -190e18, deltaJTEff = -57e18
     *   -> JT absorbs 57e18, covers 190e18: stEff 1000e18, jtEff 53e18, il 190e18
     * Path B (1.00 -> 0.90 -> 0.81, two syncs): the intermediate checkpoint mints the 100e18 cross-claim, which then
     *   eats floor(27e18 * 100/270) = 10e18 of the second-leg JT raw loss (exact, no rounding):
     *   leg 2 deltaSTEff = -(90e18 + 10e18) = -100e18, deltaJTEff = -17e18
     *   -> JT absorbs 17e18, covers 100e18: stEff 1000e18, jtEff 53e18, il 100e18 + 100e18 = 200e18
     */
    function test_Finding2_ILDependsOnSyncCadence_DirectVsTwoStep() public {
        // Path A: single sync straight to the bottom
        _seedSymmetric(ST_RAW_0, JT_RAW_0, 0);
        _pinRates();
        SyncedAccountingState memory pathA = kernel.doPreOp(toNAVUnits(uint256(810e18)), toNAVUnits(uint256(243e18)));
        assertEq(toUint256(pathA.stEffectiveNAV), 1000e18, "path A: ST fully covered");
        assertEq(toUint256(pathA.jtEffectiveNAV), 53e18, "path A: JT absorbs 57e18 and covers 190e18");
        assertEq(toUint256(pathA.jtCoverageImpermanentLoss), 190e18, "path A: 190e18 IL in one sync");

        // Path B: fresh identical market, same decline observed at an intermediate checkpoint
        _freshSymmetricMarket();
        SyncedAccountingState memory mid = _dipSync();
        assertEq(toUint256(mid.jtCoverageImpermanentLoss), 100e18, "path B leg 1: 100e18 IL at the checkpoint");
        SyncedAccountingState memory pathB = kernel.doPreOp(toNAVUnits(uint256(810e18)), toNAVUnits(uint256(243e18)));

        // Identical economic endpoint...
        assertEq(toUint256(pathB.stEffectiveNAV), toUint256(pathA.stEffectiveNAV), "identical final ST effective NAV");
        assertEq(toUint256(pathB.jtEffectiveNAV), toUint256(pathA.jtEffectiveNAV), "identical final JT effective NAV");
        // ...different coverage ledger
        assertEq(toUint256(pathB.jtCoverageImpermanentLoss), 200e18, "FINDING 2: two-step path books 200e18 IL");
        assertEq(
            toUint256(pathB.jtCoverageImpermanentLoss) - toUint256(pathA.jtCoverageImpermanentLoss),
            (27e18 * 100e18) / 270e18,
            "IL delta == the cross-claim's proportional share of the second-leg JT raw loss"
        );
    }

    /**
     * FINDING 2 (consequence): the extra IL shifts future recovery priority toward JT. From the two identical-NAV
     * end states of the cadence test, apply the IDENTICAL +200e18 ST recovery sync:
     *
     * Path A (il 190e18): recovery 190e18, residual 10e18 through the waterfall (jt premium 1e18, lt premium 0.5e18)
     *   -> jtEff 53e18 + 190e18 + 1e18 = 244e18, stEff 1000e18 + 8.5e18 + 0.5e18 = 1009e18
     * Path B (il 200e18): recovery consumes the full gain, no waterfall
     *   -> jtEff 53e18 + 200e18 = 253e18, stEff 1000e18
     *
     * Same market inputs, JT ends 9e18 higher on path B: the extra checkpoint on the way down bought JT recovery
     * priority on the way up. Balancer pool operations trigger syncs, so checkpoint cadence is user-influenceable
     */
    function test_Finding2_ExtraIL_ShiftsRecoveryPriorityTowardJT() public {
        // Path A end state -> identical recovery sync
        _seedSymmetric(ST_RAW_0, JT_RAW_0, 0);
        _pinRates();
        kernel.doPreOp(toNAVUnits(uint256(810e18)), toNAVUnits(uint256(243e18)));
        SyncedAccountingState memory recA = kernel.doPreOp(toNAVUnits(uint256(1010e18)), toNAVUnits(uint256(243e18)));
        assertEq(toUint256(recA.jtCoverageImpermanentLoss), 0, "path A: IL cleared by the recovery");
        assertEq(toUint256(recA.jtEffectiveNAV), 244e18, "path A: 190e18 clawback + 1e18 premium on the 10e18 residual");
        assertEq(toUint256(recA.stEffectiveNAV), 1009e18, "path A: ST books 9e18 of the recovery as retained yield");

        // Path B end state -> the IDENTICAL recovery sync
        _freshSymmetricMarket();
        _dipSync();
        kernel.doPreOp(toNAVUnits(uint256(810e18)), toNAVUnits(uint256(243e18)));
        SyncedAccountingState memory recB = kernel.doPreOp(toNAVUnits(uint256(1010e18)), toNAVUnits(uint256(243e18)));
        assertEq(toUint256(recB.jtCoverageImpermanentLoss), 0, "path B: IL cleared by the recovery");
        assertEq(toUint256(recB.jtEffectiveNAV), 253e18, "path B: the full 200e18 gain claws back as IL recovery");
        assertEq(toUint256(recB.stEffectiveNAV), 1000e18, "path B: ST books none of the recovery");

        // The cadence-purchased priority: identical inputs, 9e18 more JT value on the two-step path
        assertEq(toUint256(recB.jtEffectiveNAV) - toUint256(recA.jtEffectiveNAV), 9e18, "FINDING 2: sync cadence shifted 9e18 of recovery priority to JT");
    }
}
