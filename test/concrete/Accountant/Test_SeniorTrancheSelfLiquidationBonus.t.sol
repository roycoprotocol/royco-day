// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AssetClaims, Operation, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";
import { SelfLiquidationHarness } from "../../mocks/SelfLiquidationHarness.sol";
import { AccountantTestBase } from "../../utils/AccountantTestBase.sol";

/**
 * @title Test_SeniorTrancheSelfLiquidationBonus_Accountant
 * @notice Hand-derived scenarios for the senior tranche self-liquidation bonus through the SelfLiquidationHarness mock — the
 *         strict-less threshold gate, the bonus clamped by each of the three min-terms in turn, the above-WAD
 *         config clamp, both U-neutral bonus source legs, the early-outs, the
 *         denominator-positivity boundary, and the coverageUtilization non-increase invariant through a real
 *         accountant post-op
 * @dev The mock converts tranche units to NAV units 1:1, so every tranche-unit literal doubles as its NAV
 *      value. Every vector hand-derives its expected values and cross-asserts RoycoTestMath.seniorTrancheSelfLiquidationBonus.
 *      Existing coverage NOT duplicated: the post-op bonus split shapes, the bonus == total edge, and the
 *      bonus-exceeds-buffer panics live in test/concrete/Accountant/Test_PostOpSync_Accountant.t.sol
 */
contract Test_SeniorTrancheSelfLiquidationBonus_Accountant is AccountantTestBase {
    uint256 internal constant LIQ_THRESHOLD = 1.1e18;

    SelfLiquidationHarness internal sll;

    function setUp() public {
        _deploy(_defaultParams());
        sll = new SelfLiquidationHarness();
    }

    /*//////////////////////////////////////////////////////////////////////
                            VECTOR BUILDERS
    //////////////////////////////////////////////////////////////////////*/

    /// @dev Builds the minimal synced state the bonus computation reads, with the utilizations supplied directly
    function _bonusState(
        uint256 _stRaw,
        uint256 _jtRaw,
        uint256 _stEff,
        uint256 _jtEff,
        uint256 _coverageUtilizationWAD
    )
        internal
        pure
        returns (SyncedAccountingState memory s)
    {
        s.stRawNAV = toNAVUnits(_stRaw);
        s.jtRawNAV = toNAVUnits(_jtRaw);
        s.stEffectiveNAV = toNAVUnits(_stEff);
        s.jtEffectiveNAV = toNAVUnits(_jtEff);
        s.coverageUtilizationWAD = _coverageUtilizationWAD;
        s.coverageLiquidationUtilizationWAD = LIQ_THRESHOLD;
    }

    /// @dev Builds a redeeming ST user's claims (tranche units convert 1:1 to NAV units in the mock)
    function _claims(uint256 _stAssets, uint256 _jtAssets, uint256 _nav) internal pure returns (AssetClaims memory c) {
        c.stAssets = toTrancheUnits(_stAssets);
        c.jtAssets = toTrancheUnits(_jtAssets);
        c.nav = toNAVUnits(_nav);
    }

    /// @dev Builds the matching RoycoTestMath.seniorTrancheSelfLiquidationBonus input set (weighted = stAssets + jtAssets under identity conversion)
    function _rtmIn(SyncedAccountingState memory _s, uint256 _bonusWAD, AssetClaims memory _c) internal pure returns (RoycoTestMath.SeniorTrancheSelfLiquidationBonusInputs memory in_) {
        in_.stRawNAV = toUint256(_s.stRawNAV);
        in_.jtRawNAV = toUint256(_s.jtRawNAV);
        in_.jtEffectiveNAV = toUint256(_s.jtEffectiveNAV);
        in_.coverageUtilizationWAD = _s.coverageUtilizationWAD;
        in_.coverageLiquidationUtilizationWAD = _s.coverageLiquidationUtilizationWAD;
        in_.bonusWAD = _bonusWAD;
        in_.userClaimNAV = toUint256(_c.nav);
    }

    /// @dev Asserts the five claim fields match the expected literals
    function _assertClaims(AssetClaims memory _c, uint256 _stAssets, uint256 _jtAssets, uint256 _nav, string memory _tag) internal pure {
        assertEq(toUint256(_c.stAssets), _stAssets, string.concat(_tag, ": stAssets"));
        assertEq(toUint256(_c.jtAssets), _jtAssets, string.concat(_tag, ": jtAssets"));
        assertEq(toUint256(_c.ltAssets), 0, string.concat(_tag, ": ltAssets"));
        assertEq(_c.stShares, 0, string.concat(_tag, ": stShares"));
        assertEq(toUint256(_c.nav), _nav, string.concat(_tag, ": nav"));
    }

    /*//////////////////////////////////////////////////////////////////////
                            THE THRESHOLD GATE
    //////////////////////////////////////////////////////////////////////*/

    /**
     * One wei below the liquidation threshold the bonus is inactive (SelfLiquidationLogic.sol:41) — zero
     * bonus and byte-exact claim passthrough, no matter how large the desired bonus is, so a healthy market
     * can never leak a bonus
     */
    function test_SeniorTrancheSelfLiquidationBonus_InactiveOneBelowThreshold() public {
        sll.setSelfLiquidationBonusWAD(0.05e18);
        SyncedAccountingState memory s = _bonusState(1000e18, 90e18, 1000e18, 90e18, LIQ_THRESHOLD - 1);
        AssetClaims memory c = _claims(100e18, 0, 100e18);

        (AssetClaims memory out, NAV_UNIT bonus) = sll.applyBonus(s, c);

        assertEq(toUint256(bonus), 0, "no bonus below the threshold");
        _assertClaims(out, 100e18, 0, 100e18, "passthrough");
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonus(_rtmIn(s, 0.05e18, c)), 0, "RTM inactive below the threshold");
    }

    /**
     * The gate is a strict less-than (SelfLiquidationLogic.sol:41), so a coverage utilization EXACTLY at the
     * liquidation threshold activates the bonus.
     * desired = floor(100e18 * 0.01) = 1e18, jtEffectiveNAV = 90e18, U-neutral max
     * = floor(100e18 * 90e18 / (1090e18 - 90e18)) = 9e18 -> bonus = min(1e18, 90e18, 9e18) = 1e18, sourced entirely from
     * JT's self-claim (jtClaimOnST = sat(90e18 - 90e18) = 0), so jtAssets carries the whole bonus
     */
    function test_SeniorTrancheSelfLiquidationBonus_ActiveAtExactThreshold() public {
        sll.setSelfLiquidationBonusWAD(0.01e18);
        SyncedAccountingState memory s = _bonusState(1000e18, 90e18, 1000e18, 90e18, LIQ_THRESHOLD);
        AssetClaims memory c = _claims(100e18, 0, 100e18);

        (AssetClaims memory out, NAV_UNIT bonus) = sll.applyBonus(s, c);

        assertEq(toUint256(bonus), 1e18, "bonus active at the exact threshold");
        _assertClaims(out, 100e18, 1e18, 101e18, "bonus from the JT self-claim");
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonus(_rtmIn(s, 0.01e18, c)), 1e18, "RTM exact-threshold activation");
    }

    /*//////////////////////////////////////////////////////////////////////
                    DESIRED AND JT-BUFFER MIN-TERMS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * The desired bonus binds when it undercuts both caps (SelfLiquidationLogic.sol:44, :53).
     * coverageUtilization at these marks = ceil((1000e18 + 90e18) * 0.1e18 / 90e18) = 1_211_111_111_111_111_112 (breached).
     * desired = floor(100e18 * 0.05) = 5e18, jtEffectiveNAV = 90e18, U-neutral max = 9e18 (as in the
     * exact-threshold vector above) -> bonus = min(5e18, 90e18, 9e18) = 5e18, all from the JT self-claim
     */
    function test_SeniorTrancheSelfLiquidationBonus_DesiredBonusBinds() public {
        uint256 coverageUtilization = RoycoTestMath.computeCoverageUtilization(1000e18, 90e18, 0.1e18, 90e18);
        assertEq(coverageUtilization, 1_211_111_111_111_111_112, "hand-derived breached coverage utilization");
        sll.setSelfLiquidationBonusWAD(0.05e18);
        SyncedAccountingState memory s = _bonusState(1000e18, 90e18, 1000e18, 90e18, coverageUtilization);
        AssetClaims memory c = _claims(100e18, 0, 100e18);

        (AssetClaims memory out, NAV_UNIT bonus) = sll.applyBonus(s, c);

        assertEq(toUint256(bonus), 5e18, "desired bonus binds");
        _assertClaims(out, 100e18, 5e18, 105e18, "bonus from the JT self-claim");
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonus(_rtmIn(s, 0.05e18, c)), 5e18, "RTM desired-bound bonus");
    }

    /**
     * The jtEffectiveNAV min-term binds at a tiny JT buffer (SelfLiquidationLogic.sol:53). Derived lemma on its reachability: in a
     * conserved state the U-neutral max never exceeds jtEffectiveNAV (a redeemer's claim NAV is at most stEffectiveNAV
     * = exposure - jtEffectiveNAV, so nav * jtEffectiveNAV / (exposure - jtEffectiveNAV) <= jtEffectiveNAV), with equality
     * exactly at the whole-tranche redeemer — so min-term 2 binds at that tie, pinned here.
     * State (stRawNAV 100e18, jtRawNAV 0, stEffectiveNAV 95e18, jtEffectiveNAV 5e18): jtClaimOnST = 5e18, claim NAV = 95e18.
     * desired = floor(95e18 * 0.5) = 47.5e18, U-neutral max = floor(95e18 * 5e18 / (100e18 - 5e18)) = 5e18
     * -> bonus = min(47.5e18, 5e18, 5e18) = 5e18 == jtEffectiveNAV, and the whole
     * bonus sources from JT's claim on ST assets
     */
    function test_SeniorTrancheSelfLiquidationBonus_JTBufferBindsAtWholeTrancheRedeemerTie() public {
        sll.setSelfLiquidationBonusWAD(0.5e18);
        SyncedAccountingState memory s = _bonusState(100e18, 0, 95e18, 5e18, 1.2e18);
        AssetClaims memory c = _claims(95e18, 0, 95e18);

        (AssetClaims memory out, NAV_UNIT bonus) = sll.applyBonus(s, c);

        assertEq(toUint256(bonus), 5e18, "the entire junior buffer is the bonus");
        _assertClaims(out, 100e18, 0, 100e18, "bonus from JT's claim on ST assets");
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonus(_rtmIn(s, 0.5e18, c)), 5e18, "RTM jtEffectiveNAV-bound bonus");
    }

    /**
     * A bonus configuration above 100% of the redeemed NAV — the config slot is a raw uint64 with no
     * upper-bound validation, so 200% and even the ~1844% ceiling are storable — can never pay past the
     * junior buffer or the coverage-utilization-neutral cap (SelfLiquidationLogic.sol:53 clamps by both).
     * The oversized desired term drops out of the min entirely, so both expected caps below are derived from
     * the junior buffer and the U' <= U inequality alone, never from the configured multiple.
     * State (stRawNAV 100e18, jtRawNAV 20e18, stEffectiveNAV 60e18, jtEffectiveNAV 60e18): exposure = 120e18,
     * jtClaimOnST = 60e18 - 20e18 = 40e18. Breached: minCoverage 0.72e18 gives
     * coverageUtilization = ceil(120e18 * 0.72e18 / 60e18) = 1.44e18 >= the 1.1e18 liquidation threshold.
     * The redeemer claims (stAssets 50e18, jtAssets 0, nav 50e18).
     * Cap A, the junior buffer: jtEffectiveNAV = 60e18 — JT cannot fund a bonus it does not hold.
     * Cap B, the U-neutral max, from (BONUS_ST + BONUS_JT) * (exposure - jtEff) <= jtEff * redemptionNAV:
     *   Cap B = floor(50e18 * 60e18 / (120e18 - 60e18)) = 50e18.
     * Paid bonus = min(60e18, 50e18) = 50e18 at BOTH oversized configs, riding 40e18 on the stAssets leg
     * (JT's claim on ST assets, maxed) and 10e18 on the jtAssets leg. Post-redemption marks:
     * stRaw = 100e18 - 50e18 - 40e18 = 10e18 and jtRaw = jtEff = 20e18 - 10e18 = 10e18, so
     * U' = ceil(20e18 * 0.72e18 / 10e18) = 1.44e18 == U exactly — the clamp is tight, and one more bonus
     * wei (jtEff 10e18 - 1) would give ceil((20e18 - 1) * 0.72e18 / (10e18 - 1)) = 1.44e18 + 1 > U.
     * An above-WAD config therefore cannot eat past the junior buffer or worsen the coverage of the LPs
     * who stay behind
     */
    function test_SeniorTrancheSelfLiquidationBonus_AboveWADBonusClampedToJuniorBufferAndNeutralCap() public {
        uint256 coverageUtilizationPre = RoycoTestMath.computeCoverageUtilization(100e18, 20e18, 0.72e18, 60e18);
        assertEq(coverageUtilizationPre, 1.44e18, "hand-derived breached coverage utilization");
        SyncedAccountingState memory s = _bonusState(100e18, 20e18, 60e18, 60e18, coverageUtilizationPre);
        AssetClaims memory c = _claims(50e18, 0, 50e18);

        // 200% of the redeemed NAV: desired = 100e18 dwarfs both caps, paid = min(60e18, 50e18) = 50e18
        sll.setSelfLiquidationBonusWAD(2e18);
        (AssetClaims memory out, NAV_UNIT bonus) = sll.applyBonus(s, c);
        assertEq(toUint256(bonus), 50e18, "200% config clamps to the smaller of the two caps");
        _assertClaims(out, 90e18, 10e18, 100e18, "clamped bonus split across both source legs");
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonus(_rtmIn(s, 2e18, c)), 50e18, "RTM 200% clamp");

        // The largest storable config (~1844% of the redeemed NAV) pays exactly the same clamped bonus
        sll.setSelfLiquidationBonusWAD(type(uint64).max);
        (out, bonus) = sll.applyBonus(s, c);
        assertEq(toUint256(bonus), 50e18, "max-uint64 config clamps identically");
        _assertClaims(out, 90e18, 10e18, 100e18, "identical clamped claim legs at the max config");
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonus(_rtmIn(s, type(uint64).max, c)), 50e18, "RTM max-uint64 clamp");

        // Recompute coverage utilization on the post-redemption marks (stRaw 10e18 after the 50e18 redemption
        // leg and the 40e18 ST-sourced bonus leave, jtRaw = jtEff = 10e18 after the 10e18 JT-sourced bonus
        // leaves): U' == U byte-exact, so paying the clamped bonus is utilization-neutral even under an
        // above-WAD config
        uint256 coverageUtilizationPost = RoycoTestMath.computeCoverageUtilization(10e18, 10e18, 0.72e18, 10e18);
        assertEq(coverageUtilizationPost, 1.44e18, "hand-derived post coverage utilization, exactly neutral");
        assertLe(coverageUtilizationPost, coverageUtilizationPre, "an above-WAD config never increases coverage utilization");
        // The cap is maximally tight: one extra bonus wei out of the JT self-claim would leave jtEff at
        // 10e18 - 1 and push utilization to ceil((20e18 - 1) * 0.72e18 / (10e18 - 1)) = 1.44e18 + 1, strictly above U
        assertEq(
            RoycoTestMath.computeCoverageUtilization(10e18, 10e18 - 1, 0.72e18, 10e18 - 1),
            1.44e18 + 1,
            "one more bonus wei would increase coverage utilization"
        );
    }

    /*//////////////////////////////////////////////////////////////////////
                THE U-NEUTRAL MAX AND ITS TWO SOURCE LEGS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * The U-neutral max binds and the bonus fits entirely inside JT's claim on ST assets (SelfLiquidationLogic.sol:60).
     * State (stRawNAV 100e18, jtRawNAV 20e18, stEffectiveNAV 80e18, jtEffectiveNAV 40e18): exposure = 120e18, jtClaimOnST = 20e18.
     * desired = floor(16e18 * 1.0) = 16e18, U-neutral max = floor(16e18 * 40e18 / (120e18 - 40e18)) = 8e18
     * -> bonus = min(16e18, 40e18, 8e18) = 8e18 <= jtClaimOnST 20e18, sourced entirely
     * from JT's claim on ST assets (stAssets leg)
     */
    function test_SeniorTrancheSelfLiquidationBonus_UtilizationNeutralMaxBinds_STAssetSourced() public {
        sll.setSelfLiquidationBonusWAD(1e18);
        SyncedAccountingState memory s = _bonusState(100e18, 20e18, 80e18, 40e18, 1.2e18);
        AssetClaims memory c = _claims(16e18, 0, 16e18);

        (AssetClaims memory out, NAV_UNIT bonus) = sll.applyBonus(s, c);

        assertEq(toUint256(bonus), 8e18, "U-neutral max binds");
        _assertClaims(out, 24e18, 0, 24e18, "bonus rides the stAssets leg only");
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonus(_rtmIn(s, 1e18, c)), 8e18, "RTM stAssets-sourced bonus");
    }

    /**
     * The U-neutral max binds and the bonus overflows JT's claim on ST assets, crossing into the JT
     * self-claim (SelfLiquidationLogic.sol:60-61).
     * Same state as above with claim NAV 60e18: U-neutral max = floor(60e18 * 40e18 / (120e18 - 40e18)) = 30e18
     * -> bonus = min(60e18, 40e18, 30e18) = 30e18 > jtClaimOnST 20e18, sourced 20e18 from JT's claim on ST
     * (maxed) and 10e18 from the JT self-claim
     */
    function test_SeniorTrancheSelfLiquidationBonus_UtilizationNeutralMaxBinds_SplitAcrossBothSourceLegs() public {
        sll.setSelfLiquidationBonusWAD(1e18);
        SyncedAccountingState memory s = _bonusState(100e18, 20e18, 80e18, 40e18, 1.2e18);
        AssetClaims memory c = _claims(60e18, 0, 60e18);

        (AssetClaims memory out, NAV_UNIT bonus) = sll.applyBonus(s, c);

        assertEq(toUint256(bonus), 30e18, "U-neutral max binds across both source legs");
        _assertClaims(out, 80e18, 10e18, 90e18, "bonus split across both source legs");
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonus(_rtmIn(s, 1e18, c)), 30e18, "RTM split-sourced bonus");
    }

    /*//////////////////////////////////////////////////////////////////////
                EARLY-OUTS AND THE DENOMINATOR LEMMA
    //////////////////////////////////////////////////////////////////////*/

    /**
     * The two U-neutral zero paths (SelfLiquidationLogic.sol:100, :103) zero the bonus with claim
     * passthrough — an exhausted junior buffer (jtEffectiveNAV 0, the wipeout coverageUtilization reading, zeroes the
     * U-neutral product) and a zero NAV claim (the :100 early-out)
     */
    function test_SeniorTrancheSelfLiquidationBonus_EarlyOuts_JTEffZeroAndZeroClaim() public {
        sll.setSelfLiquidationBonusWAD(0.5e18);

        // jtEffectiveNAV == 0: desired = 25e18 but every source cap is zero
        SyncedAccountingState memory s = _bonusState(100e18, 0, 100e18, 0, type(uint256).max);
        AssetClaims memory c = _claims(50e18, 0, 50e18);
        (AssetClaims memory out, NAV_UNIT bonus) = sll.applyBonus(s, c);
        assertEq(toUint256(bonus), 0, "no bonus from an exhausted junior buffer");
        _assertClaims(out, 50e18, 0, 50e18, "passthrough at jtEffectiveNAV 0");
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonus(_rtmIn(s, 0.5e18, c)), 0, "RTM jtEffectiveNAV early-out");

        // nav == 0: a zero claim earns nothing even in a breached market
        s = _bonusState(1000e18, 90e18, 1000e18, 90e18, 1.2e18);
        c = _claims(0, 0, 0);
        (out, bonus) = sll.applyBonus(s, c);
        assertEq(toUint256(bonus), 0, "no bonus on a zero NAV claim");
        _assertClaims(out, 0, 0, 0, "passthrough at nav 0");
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonus(_rtmIn(s, 0.5e18, c)), 0, "RTM zero-claim early-out");
    }

    /**
     * The denominator-positivity lemma at its nearest constructible boundary (SelfLiquidationLogic.sol:103).
     * For any real market an active bonus implies exposure > jtEffectiveNAV: activation needs coverageUtilization >= liqThreshold
     * > WAD (the threshold is validated > WAD at initialize) while coverageUtilization = ceil(exposure * minCov / jtEffectiveNAV)
     * with minCov < WAD, so exposure * minCov > jtEffectiveNAV forces exposure > jtEffectiveNAV — a state violating the
     * (exposure - jtEffectiveNAV) subtraction is unreachable. Pinned at the boundary exposure - jtEffectiveNAV = 1 wei:
     * state (stRawNAV 100e18, jtRawNAV 0, stEffectiveNAV 1, jtEffectiveNAV 100e18 - 1), claim NAV = 1, desired = 1.
     * U-neutral max = floor(1 * (100e18 - 1) / 1) = 100e18 - 1
     * -> bonus = min(1, 100e18 - 1, 100e18 - 1) = 1, no revert against the 1-wei denominator
     */
    function test_SeniorTrancheSelfLiquidationBonus_DenominatorPositivityBoundary() public {
        sll.setSelfLiquidationBonusWAD(1e18);
        SyncedAccountingState memory s = _bonusState(100e18, 0, 1, 100e18 - 1, 1.2e18);
        AssetClaims memory c = _claims(1, 0, 1);

        (AssetClaims memory out, NAV_UNIT bonus) = sll.applyBonus(s, c);

        assertEq(toUint256(bonus), 1, "bonus computes cleanly at the 1-wei denominator boundary");
        _assertClaims(out, 2, 0, 2, "bonus from JT's claim on ST assets");
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonus(_rtmIn(s, 1e18, c)), 1, "RTM boundary bonus");
    }

    /*//////////////////////////////////////////////////////////////////////
            COVUTIL NON-INCREASE THROUGH A REAL POST-OP
    //////////////////////////////////////////////////////////////////////*/

    /**
     * A bonus-carrying ST redemption never increases the coverage utilization (derivation at
     * SelfLiquidationLogic.sol:72-85, post-op at RoycoDayAccountant.sol:252-260) — the bonus is sized to be
     * utilization-neutral, so paying it can never worsen the market it is winding down.
     * Seed 1000e18/90e18 flat with 100e18 of LT depth:
     *   coverageUtilizationPre = ceil((1000e18 + 90e18) * 0.1e18 / 90e18) = 1_211_111_111_111_111_112 >= 1.1e18 (bonus active)
     * The redeeming user claims (100e18, 0, nav 100e18) at bonusWAD 0.05e18: bonus = min(5e18, 90e18, 9e18)
     * = 5e18 (the desired-bound vector above), sourced from the JT self-claim, so the post-op raws are
     * (900e18, 85e18) and the redemption reduces jtEffectiveNAV by exactly the bonus and stEffectiveNAV by the user claim:
     *   coverageUtilizationPost = ceil((900e18 + 85e18) * 0.1e18 / 85e18) = 1_158_823_529_411_764_706 <= coverageUtilizationPre
     * Production, the SelfLiquidationHarness mock, and RoycoTestMath must all agree on the bonus and both utilizations
     */
    function test_SeniorTrancheSelfLiquidationBonus_CoverageUtilizationNonIncreasingThroughPostOp() public {
        _seedSymmetric(1000e18, 90e18, 100e18);
        SyncedAccountingState memory pre = _checkpointState();
        assertEq(pre.coverageUtilizationWAD, 1_211_111_111_111_111_112, "hand-derived pre coverageUtilization, breached");

        // Three-way agreement on the bonus for the redeeming user's claims
        sll.setSelfLiquidationBonusWAD(0.05e18);
        AssetClaims memory c = _claims(100e18, 0, 100e18);
        (AssetClaims memory out, NAV_UNIT bonus) = sll.applyBonus(pre, c);
        assertEq(toUint256(bonus), 5e18, "hand-derived bonus");
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonus(_rtmIn(pre, 0.05e18, c)), 5e18, "RTM bonus");
        _assertClaims(out, 100e18, 5e18, 105e18, "bonus rides the JT self-claim leg");

        // Execute the redemption: the user claim leaves stRawNAV and the bonus leaves jtRawNAV
        SyncedAccountingState memory post = kernel.doPostOp(
            Operation.ST_REDEEM, toNAVUnits(uint256(900e18)), toNAVUnits(uint256(85e18)), toNAVUnits(uint256(100e18)), toNAVUnits(uint256(5e18)), true
        );
        assertEq(toUint256(post.jtEffectiveNAV), 85e18, "jtEffectiveNAV reduced by exactly the bonus");
        assertEq(toUint256(post.stEffectiveNAV), 900e18, "stEffectiveNAV reduced by the claim net of the bonus");
        assertEq(post.coverageUtilizationWAD, 1_158_823_529_411_764_706, "hand-derived post coverageUtilization");
        assertEq(post.coverageUtilizationWAD, RoycoTestMath.computeCoverageUtilization(900e18, 85e18, 0.1e18, 85e18), "RTM post coverageUtilization");
        assertLe(post.coverageUtilizationWAD, pre.coverageUtilizationWAD, "a bonus-carrying redemption never increases coverageUtilization");
    }
}
