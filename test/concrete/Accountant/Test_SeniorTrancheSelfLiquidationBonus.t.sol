// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { AssetClaims, Operation, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";
import { SelfLiquidationHarness } from "../../mocks/SelfLiquidationHarness.sol";
import { AccountantTestBase } from "../../utils/AccountantTestBase.sol";

/**
 * @title Test_SeniorTrancheSelfLiquidationBonus_Accountant
 * @notice Hand-derived scenarios for the senior tranche self-liquidation bonus through the SelfLiquidationHarness mock — the
 *         strict-less threshold gate, the bonus clamped by each of the three min-terms in turn, both
 *         U-neutral sourcing cases at both co-investment values, the early-outs, the
 *         denominator-positivity boundary, and the coverageUtilization non-increase invariant through a real
 *         accountant post-op
 * @dev The mock converts tranche units to NAV units 1:1, so every tranche-unit literal doubles as its NAV
 *      value. Every vector hand-derives its expected values and cross-asserts RoycoTestMath.seniorTrancheSelfLiquidationBonus.
 *      Existing coverage NOT duplicated: the post-op bonus split shapes, the bonus == total edge, and the
 *      bonus-exceeds-buffer panics live in test/concrete/Accountant/Test_PostOpSync_Accountant.t.sol
 */
contract Test_SeniorTrancheSelfLiquidationBonus_Accountant is AccountantTestBase {
    uint256 internal constant WAD_ = 1e18;
    uint256 internal constant LIQ_THRESHOLD = 1.1e18;

    SelfLiquidationHarness internal sll;

    function setUp() public {
        _deploy(false, _defaultParams());
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
        bool _coinvested,
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
        s.jtCoinvested = _coinvested;
        s.coverageUtilizationWAD = _coverageUtilizationWAD;
        s.coverageLiquidationUtilizationWAD = LIQ_THRESHOLD;
    }

    /// @dev Builds a redeeming ST user's claims (tranche units convert 1:1 to NAV units in the mock)
    function _claims(uint256 _stAssets, uint256 _jtAssets, uint256 _nav) internal pure returns (AssetClaims memory c) {
        c.stAssets = toTrancheUnits(_stAssets);
        c.jtAssets = toTrancheUnits(_jtAssets);
        c.nav = toNAVUnits(_nav);
    }

    /// @dev Builds the matching RoycoTestMath.seniorTrancheSelfLiquidationBonus input set (weighted = stAssets + (coinvested ? jtAssets : 0) under identity conversion)
    function _rtmIn(SyncedAccountingState memory _s, uint256 _bonusWAD, AssetClaims memory _c) internal pure returns (RoycoTestMath.SeniorTrancheSelfLiquidationBonusInputs memory in_) {
        in_.stRawNAV = toUint256(_s.stRawNAV);
        in_.jtRawNAV = toUint256(_s.jtRawNAV);
        in_.jtEffectiveNAV = toUint256(_s.jtEffectiveNAV);
        in_.jtCoinvested = _s.jtCoinvested;
        in_.coverageUtilizationWAD = _s.coverageUtilizationWAD;
        in_.coverageLiquidationUtilizationWAD = _s.coverageLiquidationUtilizationWAD;
        in_.bonusWAD = _bonusWAD;
        in_.userClaimNAV = toUint256(_c.nav);
        in_.stUserWeightedClaimNAV = toUint256(_c.stAssets) + (_s.jtCoinvested ? toUint256(_c.jtAssets) : 0);
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
        SyncedAccountingState memory s = _bonusState(1000e18, 90e18, 1000e18, 90e18, false, LIQ_THRESHOLD - 1);
        AssetClaims memory c = _claims(100e18, 0, 100e18);

        (AssetClaims memory out, NAV_UNIT bonus) = sll.applyBonus(s, c);

        assertEq(toUint256(bonus), 0, "no bonus below the threshold");
        _assertClaims(out, 100e18, 0, 100e18, "passthrough");
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonus(_rtmIn(s, 0.05e18, c)), 0, "RTM inactive below the threshold");
    }

    /**
     * The gate is a strict less-than (SelfLiquidationLogic.sol:41), so a coverage utilization EXACTLY at the
     * liquidation threshold activates the bonus.
     * desired = floor(100e18 * 0.01) = 1e18, jtEffectiveNAV = 90e18, U-neutral: jtClaimOnST = sat(90e18 - 90e18) = 0,
     * case 1 = floor(100e18 * 90e18 / (1000e18 - 90e18)) = 9_890_109_890_109_890_109 > 0 -> case 2
     * = floor(100e18 * 90e18 / 1000e18) = 9e18 -> bonus = min(1e18, 90e18, 9e18) = 1e18, sourced entirely from
     * JT's self-claim (jtClaimOnST is 0), so jtAssets carries the whole bonus
     */
    function test_SeniorTrancheSelfLiquidationBonus_ActiveAtExactThreshold() public {
        sll.setSelfLiquidationBonusWAD(0.01e18);
        SyncedAccountingState memory s = _bonusState(1000e18, 90e18, 1000e18, 90e18, false, LIQ_THRESHOLD);
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
     * coverageUtilization at these marks = ceil(1000e18 * 0.1e18 / 90e18) = 1_111_111_111_111_111_112 (breached).
     * desired = floor(100e18 * 0.05) = 5e18, jtEffectiveNAV = 90e18, U-neutral max = 9e18 (case 2, as in the
     * exact-threshold vector above) -> bonus = min(5e18, 90e18, 9e18) = 5e18, all from the JT self-claim
     */
    function test_SeniorTrancheSelfLiquidationBonus_DesiredBonusBinds() public {
        uint256 coverageUtilization = RoycoTestMath.computeCoverageUtilization(1000e18, 90e18, false, 0.1e18, 90e18);
        assertEq(coverageUtilization, 1_111_111_111_111_111_112, "hand-derived breached coverage utilization");
        sll.setSelfLiquidationBonusWAD(0.05e18);
        SyncedAccountingState memory s = _bonusState(1000e18, 90e18, 1000e18, 90e18, false, coverageUtilization);
        AssetClaims memory c = _claims(100e18, 0, 100e18);

        (AssetClaims memory out, NAV_UNIT bonus) = sll.applyBonus(s, c);

        assertEq(toUint256(bonus), 5e18, "desired bonus binds");
        _assertClaims(out, 100e18, 5e18, 105e18, "bonus from the JT self-claim");
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonus(_rtmIn(s, 0.05e18, c)), 5e18, "RTM desired-bound bonus");
    }

    /**
     * The jtEffectiveNAV min-term binds at a tiny JT buffer (SelfLiquidationLogic.sol:53). Derived lemma on its reachability: in a
     * conserved state the U-neutral max never exceeds jtEffectiveNAV (not coinvested: case 2 = (weighted + jtClaimOnST)
     * * jtEffectiveNAV / exposure with weighted <= stClaimOnST, so the numerator factor is <= exposure), with equality
     * exactly at the whole-tranche redeemer — so min-term 2 binds at that tie, pinned here.
     * State (stRawNAV 100e18, jtRawNAV 0, stEffectiveNAV 95e18, jtEffectiveNAV 5e18): jtClaimOnST = 5e18, weighted = stClaimOnST = 95e18.
     * desired = floor(95e18 * 0.5) = 47.5e18, case 1 = floor(95e18 * 5e18 / (100e18 - 5e18)) = 5e18
     * <= jtClaimOnST -> U-neutral = 5e18 -> bonus = min(47.5e18, 5e18, 5e18) = 5e18 == jtEffectiveNAV, and the whole
     * bonus sources from JT's claim on ST assets
     */
    function test_SeniorTrancheSelfLiquidationBonus_JTBufferBindsAtWholeTrancheRedeemerTie() public {
        sll.setSelfLiquidationBonusWAD(0.5e18);
        SyncedAccountingState memory s = _bonusState(100e18, 0, 95e18, 5e18, false, 1.2e18);
        AssetClaims memory c = _claims(95e18, 0, 95e18);

        (AssetClaims memory out, NAV_UNIT bonus) = sll.applyBonus(s, c);

        assertEq(toUint256(bonus), 5e18, "the entire junior buffer is the bonus");
        _assertClaims(out, 100e18, 0, 100e18, "bonus from JT's claim on ST assets");
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonus(_rtmIn(s, 0.5e18, c)), 5e18, "RTM jtEffectiveNAV-bound bonus");
    }

    /*//////////////////////////////////////////////////////////////////////
                THE U-NEUTRAL MAX AND ITS TWO CASES
    //////////////////////////////////////////////////////////////////////*/

    /**
     * U-neutral case 1 binds (SelfLiquidationLogic.sol:118-121) — the bonus fits entirely inside JT's claim on ST assets.
     * State (stRawNAV 100e18, jtRawNAV 20e18, stEffectiveNAV 60e18, jtEffectiveNAV 60e18): jtClaimOnST = 40e18, not coinvested.
     * desired = floor(40e18 * 1.0) = 40e18, case 1 = floor(20e18 * 60e18 / (100e18 - 60e18)) = 30e18
     * <= jtClaimOnST 40e18 -> U-neutral = 30e18 -> bonus = min(40e18, 60e18, 30e18) = 30e18, sourced entirely
     * from JT's claim on ST assets (stAssets leg)
     */
    function test_SeniorTrancheSelfLiquidationBonus_UtilizationNeutralCase1Binds_STAssetSourced() public {
        sll.setSelfLiquidationBonusWAD(1e18);
        SyncedAccountingState memory s = _bonusState(100e18, 20e18, 60e18, 60e18, false, 1.2e18);
        AssetClaims memory c = _claims(20e18, 0, 40e18);

        (AssetClaims memory out, NAV_UNIT bonus) = sll.applyBonus(s, c);

        assertEq(toUint256(bonus), 30e18, "case 1 U-neutral max binds");
        _assertClaims(out, 50e18, 0, 70e18, "bonus rides the stAssets leg only");
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonus(_rtmIn(s, 1e18, c)), 30e18, "RTM case 1 bonus");
    }

    /**
     * U-neutral case 2 (SelfLiquidationLogic.sol:123-128), not coinvested: case 1 overflows JT's claim on ST,
     * so the bonus crosses into the JT self-claim with the jtClaimOnST adjustment in the numerator.
     * Same state as case 1 above with weighted = 50e18: case 1 = floor(50e18 * 60e18 / 40e18) = 75e18 > jtClaimOnST
     * 40e18 -> case 2 = floor((50e18 + 40e18) * 60e18 / 100e18) = 54e18 -> bonus = min(60e18, 60e18, 54e18)
     * = 54e18, sourced 40e18 from JT's claim on ST (maxed) and 14e18 from the JT self-claim
     */
    function test_SeniorTrancheSelfLiquidationBonus_UtilizationNeutralCase2_NotCoinvested() public {
        sll.setSelfLiquidationBonusWAD(1e18);
        SyncedAccountingState memory s = _bonusState(100e18, 20e18, 60e18, 60e18, false, 1.2e18);
        AssetClaims memory c = _claims(50e18, 0, 60e18);

        (AssetClaims memory out, NAV_UNIT bonus) = sll.applyBonus(s, c);

        assertEq(toUint256(bonus), 54e18, "case 2 U-neutral max binds");
        _assertClaims(out, 90e18, 14e18, 114e18, "bonus split across both source legs");
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonus(_rtmIn(s, 1e18, c)), 54e18, "RTM case 2 bonus, not coinvested");
    }

    /**
     * U-neutral case 2, coinvested: the exposure includes jtRawNAV, the case-2 numerator drops the jtClaimOnST
     * adjustment, and the denominator subtracts jtEffectiveNAV.
     * Same raws (exposure = 120e18), weighted = 50e18: case 1 = floor(50e18 * 60e18 / (120e18 - 60e18)) = 50e18
     * > jtClaimOnST 40e18 -> case 2 = floor((50e18 + 0) * 60e18 / (120e18 - 60e18)) = 50e18 -> bonus
     * = min(60e18, 60e18, 50e18) = 50e18, sourced 40e18 from JT's claim on ST and 10e18 from the self-claim
     */
    function test_SeniorTrancheSelfLiquidationBonus_UtilizationNeutralCase2_Coinvested() public {
        sll.setSelfLiquidationBonusWAD(1e18);
        SyncedAccountingState memory s = _bonusState(100e18, 20e18, 60e18, 60e18, true, 1.2e18);
        AssetClaims memory c = _claims(50e18, 0, 60e18);

        (AssetClaims memory out, NAV_UNIT bonus) = sll.applyBonus(s, c);

        assertEq(toUint256(bonus), 50e18, "case 2 U-neutral max binds, coinvested");
        _assertClaims(out, 90e18, 10e18, 110e18, "bonus split across both source legs");
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonus(_rtmIn(s, 1e18, c)), 50e18, "RTM case 2 bonus, coinvested");
    }

    /*//////////////////////////////////////////////////////////////////////
                EARLY-OUTS AND THE DENOMINATOR LEMMA
    //////////////////////////////////////////////////////////////////////*/

    /**
     * The two U-neutral early-outs (SelfLiquidationLogic.sol:107, :116) zero the bonus with claim
     * passthrough — an exhausted junior buffer (jtEffectiveNAV 0, the wipeout coverageUtilization reading) and a zero weighted
     * claim against a positive NAV claim
     */
    function test_SeniorTrancheSelfLiquidationBonus_EarlyOuts_JTEffZeroAndWeightedZero() public {
        sll.setSelfLiquidationBonusWAD(0.5e18);

        // jtEffectiveNAV == 0: desired = 25e18 but every source cap is zero
        SyncedAccountingState memory s = _bonusState(100e18, 0, 100e18, 0, false, type(uint256).max);
        AssetClaims memory c = _claims(50e18, 0, 50e18);
        (AssetClaims memory out, NAV_UNIT bonus) = sll.applyBonus(s, c);
        assertEq(toUint256(bonus), 0, "no bonus from an exhausted junior buffer");
        _assertClaims(out, 50e18, 0, 50e18, "passthrough at jtEffectiveNAV 0");
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonus(_rtmIn(s, 0.5e18, c)), 0, "RTM jtEffectiveNAV early-out");

        // weighted == 0 with a positive NAV claim: desired = 5e18 but the U-neutral max is zero
        s = _bonusState(1000e18, 90e18, 1000e18, 90e18, false, 1.2e18);
        c = _claims(0, 0, 10e18);
        (out, bonus) = sll.applyBonus(s, c);
        assertEq(toUint256(bonus), 0, "no bonus without a weighted claim on real exposure");
        _assertClaims(out, 0, 0, 10e18, "passthrough at weighted 0");
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonus(_rtmIn(s, 0.5e18, c)), 0, "RTM weighted early-out");
    }

    /**
     * The denominator-positivity lemma at its nearest constructible boundary (SelfLiquidationLogic.sol:120).
     * For any real market an active bonus implies exposure > jtEffectiveNAV: activation needs coverageUtilization >= liqThreshold
     * > WAD (the threshold is validated > WAD at initialize) while coverageUtilization = ceil(exposure * minCov / jtEffectiveNAV)
     * with minCov < WAD, so exposure * minCov > jtEffectiveNAV forces exposure > jtEffectiveNAV — a state violating the
     * (exposure - jtEffectiveNAV) subtraction is unreachable. Pinned at the boundary exposure - jtEffectiveNAV = 1 wei:
     * state (stRawNAV 100e18, jtRawNAV 0, stEffectiveNAV 1, jtEffectiveNAV 100e18 - 1), weighted = stClaimOnST = 1, desired = 1.
     * case 1 = floor(1 * (100e18 - 1) / 1) = 100e18 - 1 <= jtClaimOnST 100e18 - 1 -> U-neutral = 100e18 - 1
     * -> bonus = min(1, 100e18 - 1, 100e18 - 1) = 1, no revert against the 1-wei denominator
     */
    function test_SeniorTrancheSelfLiquidationBonus_DenominatorPositivityBoundary() public {
        sll.setSelfLiquidationBonusWAD(1e18);
        SyncedAccountingState memory s = _bonusState(100e18, 0, 1, 100e18 - 1, false, 1.2e18);
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
     * SelfLiquidationLogic.sol:73-89, post-op at RoycoDayAccountant.sol:260-270) — the bonus is sized to be
     * utilization-neutral, so paying it can never worsen the market it is winding down.
     * Seed 1000e18/90e18 flat with 100e18 of LT depth:
     *   coverageUtilizationPre = ceil(1000e18 * 0.1e18 / 90e18) = 1_111_111_111_111_111_112 >= 1.1e18 (bonus active)
     * The redeeming user claims (100e18, 0, nav 100e18) at bonusWAD 0.05e18: bonus = min(5e18, 90e18, 9e18)
     * = 5e18 (the desired-bound vector above), sourced from the JT self-claim, so the post-op raws are
     * (900e18, 85e18) and the redemption reduces jtEffectiveNAV by exactly the bonus and stEffectiveNAV by the user claim:
     *   coverageUtilizationPost = ceil(900e18 * 0.1e18 / 85e18) = 1_058_823_529_411_764_706 <= coverageUtilizationPre
     * Production, the SelfLiquidationHarness mock, and RoycoTestMath must all agree on the bonus and both utilizations
     */
    function test_SeniorTrancheSelfLiquidationBonus_CoverageUtilizationNonIncreasingThroughPostOp() public {
        _seedSymmetric(1000e18, 90e18, 100e18);
        SyncedAccountingState memory pre = _checkpointState();
        assertEq(pre.coverageUtilizationWAD, 1_111_111_111_111_111_112, "hand-derived pre coverageUtilization, breached");

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
        assertEq(post.coverageUtilizationWAD, 1_058_823_529_411_764_706, "hand-derived post coverageUtilization");
        assertEq(post.coverageUtilizationWAD, RoycoTestMath.computeCoverageUtilization(900e18, 85e18, false, 0.1e18, 85e18), "RTM post coverageUtilization");
        assertLe(post.coverageUtilizationWAD, pre.coverageUtilizationWAD, "a bonus-carrying redemption never increases coverageUtilization");
    }
}
