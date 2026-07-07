// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { WAD } from "../../src/libraries/Constants.sol";
import { SyncedAccountingState } from "../../src/libraries/Types.sol";
import { NAV_UNIT, toNAVUnits, toUint256 } from "../../src/libraries/Units.sol";
import { AccountantMaxViewsDriver } from "../mocks/AccountantMaxViewsDriver.sol";

/**
 * @title AccountantMaxViewsSymbolicSpec
 * @notice Native symbolic specs for the accountant's three max-capacity views: the largest senior deposit that
 *         keeps both the coverage and liquidity requirements satisfied, the largest junior withdrawal that keeps
 *         coverage satisfied, and the largest liquidity-tranche withdrawal that keeps the senior liquidity floor
 *         satisfied. The load-bearing guarantees: with no requirements set a senior deposit is unrestricted and
 *         otherwise the cap is the binding of its two arms, depositing the coverage cap leaves post-deposit
 *         coverage utilization at or below one, depositing the liquidity cap leaves post-deposit liquidity
 *         utilization at or below one, an LT withdrawal returns the full pool depth exactly when ungated or in
 *         liquidation and otherwise leaves the liquidity floor intact and is tight to one wei, and a junior
 *         withdrawal returns zero on each degenerate early arm, never divides by a zero coverage-retention
 *         factor, and splits its total without over-paying
 * @dev Run with `forge test --symbolic --match-path test/symbolic/AccountantMaxViewsSymbolic.t.sol`. Functions
 *      prefixed check_ are discovered only under --symbolic. Domain: NAVs and requirements up to 1e30 wei
 *      (one trillion whole 18-decimal tokens, beyond any underwritable market). Every expected value is derived
 *      independently and division-free. The native engine models a single executed floored/ceiled mulDiv by its
 *      defining bracket (quotient-times-divisor versus dividend) but falls back to a hard-arithmetic heuristic
 *      on any other symbolic-times-symbolic product, so the soundness proofs are decomposed into a linear cap
 *      step plus that one modeled bracket: the requirement intermediate is re-executed through an identical
 *      mulDiv shim (never assumed as a fresh bracket, never re-run as its own expectation) so the engine can
 *      relate the returned cap to it linearly, and the requirement's product bound is exactly the shim mulDiv's
 *      own bracket
 * @dev Recorded incomplete-fallback owner: the two maxJTWithdrawal coverage-soundness end-to-end checks
 *      (check_withdrawingMaxJTRespectsCoverageWhen*) exercise a four-deep floored/ceiled mulDiv chain whose
 *      recombination exceeds the engine's hard-arithmetic heuristic and cannot be closed symbolically here; they
 *      are retained as the specification of the property but their empirical side is carried by the invariant
 *      gate-boundary park-and-probe suite plus the fuzz one-wei bracketing of the junior-withdrawal coverage
 *      gate. The divisor-positivity and split-bound arithmetic that back the safety of that chain are proved in
 *      full below through their shim-executed lemmas
 */
contract AccountantMaxViewsSymbolicSpec is Test {
    /// @dev Suite-wide NAV and requirement domain bound: 1e30 wei
    uint256 internal constant MAX_NAV = 1e30;

    /// @dev Dust-tolerance domain bound (worst-case quoting/rounding dust)
    uint256 internal constant MAX_DUST = 1e12;

    /// @dev A concrete mid-range requirement fraction (half of WAD), pinned where a symbolic divisor is not the property under test
    uint256 internal constant HALF_WAD = WAD / 2;

    AccountantMaxViewsDriver internal driver;

    function setUp() public {
        // The kernel address is immaterial to the pure max views; any non-zero address satisfies the constructor
        driver = new AccountantMaxViewsDriver(address(1), false);
    }

    /// @dev Marshals only the accounting-state fields the three max views read; the rest default to zero
    function _state(
        uint256 _stRaw,
        uint256 _jtRaw,
        uint256 _ltRaw,
        uint256 _stEff,
        uint256 _jtEff,
        uint256 _minCoverageWAD,
        bool _jtCoinvested,
        uint256 _minLiquidityWAD,
        uint256 _coverageUtilizationWAD,
        uint256 _coverageLiquidationUtilizationWAD
    )
        internal
        pure
        returns (SyncedAccountingState memory s)
    {
        s.stRawNAV = toNAVUnits(_stRaw);
        s.jtRawNAV = toNAVUnits(_jtRaw);
        s.ltRawNAV = toNAVUnits(_ltRaw);
        s.stEffectiveNAV = toNAVUnits(_stEff);
        s.jtEffectiveNAV = toNAVUnits(_jtEff);
        s.minCoverageWAD = _minCoverageWAD;
        s.jtCoinvested = _jtCoinvested;
        s.minLiquidityWAD = _minLiquidityWAD;
        s.coverageUtilizationWAD = _coverageUtilizationWAD;
        s.coverageLiquidationUtilizationWAD = _coverageLiquidationUtilizationWAD;
    }

    /*//////////////////////////////////////////////////////////////////////
                    MAX ST DEPOSIT: SENTINELS AND BINDING ARM
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice With neither a coverage nor a liquidity requirement configured, a senior deposit is unrestricted:
     *         maxSTDeposit returns the sentinel maximum. A market that guarantees no coverage and no secondary
     *         liquidity places no ceiling on senior capacity, so the view must not manufacture a bound out of
     *         the current NAVs
     * @dev Both requirement branches are skipped, so each arm stays at its MAX_NAV_UNITS sentinel and their
     *      minimum is that sentinel. Pure branch equivalence, no arithmetic: the expected value is the maximum
     *      uint256, derived directly from the two disabled arms
     */
    function check_maxSTDepositIsUnrestrictedWhenNeitherRequirementIsSet(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 ltRaw,
        uint256 stEff,
        uint256 jtEff,
        bool coinvest,
        uint256 stDust,
        uint256 jtDust
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && ltRaw <= MAX_NAV && stEff <= MAX_NAV && jtEff <= MAX_NAV);
        vm.assume(stDust <= MAX_DUST && jtDust <= MAX_DUST);
        driver.setDustTolerances(toNAVUnits(stDust), toNAVUnits(jtDust));

        // Both requirements disabled: no coverage floor and no liquidity floor
        uint256 result = toUint256(driver.maxSTDeposit(_state(stRaw, jtRaw, ltRaw, stEff, jtEff, 0, coinvest, 0, 0, 0)));

        // An unconstrained market must report the full sentinel capacity, not a NAV-derived bound
        assert(result == type(uint256).max);
    }

    /**
     * @notice When both requirements are configured the senior cap is exactly the binding of its coverage arm
     *         and its liquidity arm: the smaller of the two independent single-requirement caps. Neither
     *         requirement may be silently dropped, and the tighter one must always win
     * @dev The two arm values are read back through the production function itself, each isolated by zeroing the
     *      other requirement (a disabled requirement leaves its arm at the sentinel maximum, so the minimum
     *      selects the enabled arm). The full-requirement result is then asserted equal to the minimum of those
     *      two production-observed arms, so the expected form is a plain minimum with no re-derivation of either
     *      arm's internal mulDiv. The two requirement fractions are pinned to a concrete mid-range value because
     *      the min-selection wiring is independent of the specific fraction, and a concrete divisor keeps the
     *      three isolated mulDivs by-constant and tractable; the NAVs and dusts stay fully symbolic
     */
    function check_maxSTDepositIsTheBindingOfItsCoverageAndLiquidityArms(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 ltRaw,
        uint256 stEff,
        uint256 jtEff,
        bool coinvest,
        uint256 stDust,
        uint256 jtDust
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && ltRaw <= MAX_NAV && stEff <= MAX_NAV && jtEff <= MAX_NAV);
        vm.assume(stDust <= MAX_DUST && jtDust <= MAX_DUST);
        driver.setDustTolerances(toNAVUnits(stDust), toNAVUnits(jtDust));

        // Both requirements active at the same concrete mid-range fraction: the function computes both arms
        uint256 full = toUint256(driver.maxSTDeposit(_state(stRaw, jtRaw, ltRaw, stEff, jtEff, HALF_WAD, coinvest, HALF_WAD, 0, 0)));
        // Coverage arm isolated: disabling liquidity leaves the liquidity arm at the sentinel so coverage binds
        uint256 covArm = toUint256(driver.maxSTDeposit(_state(stRaw, jtRaw, ltRaw, stEff, jtEff, HALF_WAD, coinvest, 0, 0, 0)));
        // Liquidity arm isolated: disabling coverage leaves the coverage arm at the sentinel so liquidity binds
        uint256 liqArm = toUint256(driver.maxSTDeposit(_state(stRaw, jtRaw, ltRaw, stEff, jtEff, 0, coinvest, HALF_WAD, 0, 0)));

        // The two-requirement cap is exactly the tighter of the two single-requirement caps
        assert(full == (covArm < liqArm ? covArm : liqArm));
    }

    /*//////////////////////////////////////////////////////////////////////
                    MAX ST DEPOSIT: COVERAGE SOUNDNESS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Depositing the coverage-arm cap into senior leaves the coverage requirement satisfied when the
     *         junior tranche is co-invested: the post-deposit covered exposure, scaled by the minimum coverage
     *         fraction, still fits inside the junior loss-absorption buffer. Proved as two composing lemmas
     *         whose conjunction is the coverage inequality (stRaw + x + jtRaw) * minCov <= jtEff * WAD
     * @dev The coverage arm is isolated by disabling liquidity. The maximum covered value floor(jtEff*WAD/minCov)
     *      is re-executed through the identical mulDiv shim as coverageMax. Lemma one (linear): the returned cap
     *      x is a saturating subtraction of the co-invested exposure, standing senior, and both dusts from that
     *      same maximum, so stRaw + x + jtRaw is at most coverageMax. Lemma two (the shim mulDiv's own floor
     *      bracket): coverageMax * minCov is at most jtEff * WAD. Multiplying lemma one through by minCov and
     *      chaining lemma two yields the coverage inequality; both lemmas are asserted directly and division-free
     */
    function check_maxSTDepositCoverageArmKeepsCoverageSatisfiedWhenJuniorCoinvested(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 stEff,
        uint256 jtEff,
        uint256 minCov,
        uint256 stDust,
        uint256 jtDust
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && stEff <= MAX_NAV && jtEff <= MAX_NAV);
        vm.assume(1 <= minCov && minCov <= WAD);
        vm.assume(stDust <= MAX_DUST && jtDust <= MAX_DUST);
        driver.setDustTolerances(toNAVUnits(stDust), toNAVUnits(jtDust));

        // The maximum covered value the coverage arm subtracts from, re-executed through the identical mulDiv
        uint256 coverageMax = driver.mulDivFloor(jtEff, WAD, minCov);
        // Isolate the coverage arm by disabling the liquidity requirement; junior is co-invested
        uint256 x = toUint256(driver.maxSTDeposit(_state(stRaw, jtRaw, 0, stEff, jtEff, minCov, true, 0, 0, 0)));
        vm.assume(x > 0);

        // Lemma one (linear): the cap never lifts covered exposure past the coverage-implied maximum
        assert(stRaw + x + jtRaw <= coverageMax);
        // Lemma two (the shim floor bracket): that maximum scaled by coverage still fits the junior buffer
        assert(coverageMax * minCov <= jtEff * WAD);
    }

    /**
     * @notice Depositing the coverage-arm cap into senior leaves the coverage requirement satisfied when the
     *         junior tranche is isolated (not co-invested): only the senior mark counts toward covered exposure,
     *         and the scaled post-deposit exposure still fits the junior buffer
     * @dev Same two-lemma decomposition as the co-invested case, with the junior raw NAV dropped from the
     *      exposure term because an isolated junior does not share senior downside. Lemma one asserts
     *      stRaw + x is at most coverageMax; lemma two is the shim floor bracket coverageMax * minCov <= jtEff*WAD
     */
    function check_maxSTDepositCoverageArmKeepsCoverageSatisfiedWhenJuniorIsolated(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 stEff,
        uint256 jtEff,
        uint256 minCov,
        uint256 stDust,
        uint256 jtDust
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && stEff <= MAX_NAV && jtEff <= MAX_NAV);
        vm.assume(1 <= minCov && minCov <= WAD);
        vm.assume(stDust <= MAX_DUST && jtDust <= MAX_DUST);
        driver.setDustTolerances(toNAVUnits(stDust), toNAVUnits(jtDust));

        uint256 coverageMax = driver.mulDivFloor(jtEff, WAD, minCov);
        // Isolate the coverage arm by disabling the liquidity requirement; junior is not co-invested
        uint256 x = toUint256(driver.maxSTDeposit(_state(stRaw, jtRaw, 0, stEff, jtEff, minCov, false, 0, 0, 0)));
        vm.assume(x > 0);

        // Lemma one (linear): the cap never lifts the senior mark past the coverage-implied maximum
        assert(stRaw + x <= coverageMax);
        // Lemma two (the shim floor bracket): that maximum scaled by coverage still fits the junior buffer
        assert(coverageMax * minCov <= jtEff * WAD);
    }

    /*//////////////////////////////////////////////////////////////////////
                    MAX ST DEPOSIT: LIQUIDITY SOUNDNESS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Depositing the liquidity-arm cap into senior leaves the liquidity requirement satisfied: the
     *         post-deposit senior effective NAV, scaled by the minimum liquidity fraction, still fits inside the
     *         market-making pool depth. Proved as the two composing lemmas of (stEff + x) * minLiq <= ltRaw * WAD
     * @dev The liquidity arm is isolated by disabling coverage. The maximum senior effective value
     *      floor(ltRaw*WAD/minLiq) is re-executed through the identical mulDiv shim as liquidityMax. Lemma one
     *      (linear): the returned cap x is a saturating subtraction of the standing senior effective mark and
     *      the senior dust from that maximum, so stEff + x is at most liquidityMax. Lemma two (the shim floor
     *      bracket): liquidityMax * minLiq is at most ltRaw * WAD. The two together give the liquidity inequality
     */
    function check_maxSTDepositLiquidityArmKeepsLiquiditySatisfied(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 ltRaw,
        uint256 stEff,
        uint256 jtEff,
        uint256 minLiq,
        bool coinvest,
        uint256 stDust,
        uint256 jtDust
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && ltRaw <= MAX_NAV && stEff <= MAX_NAV && jtEff <= MAX_NAV);
        vm.assume(1 <= minLiq && minLiq <= WAD);
        vm.assume(stDust <= MAX_DUST && jtDust <= MAX_DUST);
        driver.setDustTolerances(toNAVUnits(stDust), toNAVUnits(jtDust));

        // The maximum senior effective value the liquidity arm subtracts from, re-executed through the shim
        uint256 liquidityMax = driver.mulDivFloor(ltRaw, WAD, minLiq);
        // Isolate the liquidity arm by disabling the coverage requirement
        uint256 x = toUint256(driver.maxSTDeposit(_state(stRaw, jtRaw, ltRaw, stEff, jtEff, 0, coinvest, minLiq, 0, 0)));
        vm.assume(x > 0);

        // Lemma one (linear): the cap never lifts senior effective past the liquidity-implied maximum
        assert(stEff + x <= liquidityMax);
        // Lemma two (the shim floor bracket): that maximum scaled by the requirement still fits the pool depth
        assert(liquidityMax * minLiq <= ltRaw * WAD);
    }

    /*//////////////////////////////////////////////////////////////////////
                    MAX LT WITHDRAWAL: FULL-DEPTH BYPASS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice With no liquidity requirement configured, the entire market-making depth is withdrawable: the LT
     *         cap is the whole pool raw NAV. A market that guarantees no secondary liquidity places no floor
     *         under the LT, so nothing is held back
     * @dev The first disjunct of the gate short-circuits and returns ltRawNAV verbatim. Pure branch equivalence,
     *      no arithmetic: the expected value is the supplied pool depth
     */
    function check_maxLTWithdrawalReturnsFullDepthWhenNoLiquidityRequirement(
        uint256 stEff,
        uint256 ltRaw,
        uint256 covUtil,
        uint256 covLiqUtil,
        uint256 stDust
    )
        external
    {
        vm.assume(stEff <= MAX_NAV && ltRaw <= MAX_NAV);
        vm.assume(stDust <= MAX_DUST);
        driver.setDustTolerances(toNAVUnits(stDust), toNAVUnits(uint256(0)));

        // No liquidity requirement: the gate's first disjunct fires
        uint256 result = toUint256(driver.maxLTWithdrawal(_state(0, 0, ltRaw, stEff, 0, 0, false, 0, covUtil, covLiqUtil)));

        // The full pool depth is releasable
        assert(result == ltRaw);
    }

    /**
     * @notice Once coverage has breached its liquidation threshold, the entire market-making depth is
     *         withdrawable regardless of the liquidity requirement: the LT cap is the whole pool raw NAV. In a
     *         wind-down the senior tranche is being liquidated, so locking secondary liquidity protects no one
     *         and every LT holder may exit fully. The boundary is inclusive: equality at the threshold releases
     * @dev The second disjunct (coverageUtilization at or above the liquidation threshold) short-circuits and
     *      returns ltRawNAV verbatim, with the liquidity requirement left active to show it is overridden. Pure
     *      branch equivalence, no arithmetic: the expected value is the supplied pool depth
     */
    function check_maxLTWithdrawalReturnsFullDepthWhenCoverageInLiquidation(
        uint256 stEff,
        uint256 ltRaw,
        uint256 minLiq,
        uint256 covUtil,
        uint256 covLiqUtil,
        uint256 stDust
    )
        external
    {
        vm.assume(stEff <= MAX_NAV && ltRaw <= MAX_NAV);
        vm.assume(1 <= minLiq && minLiq <= WAD);
        // Coverage at or above its liquidation threshold: the market is winding senior down (boundary included)
        vm.assume(covUtil >= covLiqUtil);
        vm.assume(stDust <= MAX_DUST);
        driver.setDustTolerances(toNAVUnits(stDust), toNAVUnits(uint256(0)));

        // Liquidity requirement active but overridden by the liquidation state
        uint256 result = toUint256(driver.maxLTWithdrawal(_state(0, 0, ltRaw, stEff, 0, minLiq, false, minLiq, covUtil, covLiqUtil)));

        // Every LT holder may exit the full depth during a coverage wind-down
        assert(result == ltRaw);
    }

    /*//////////////////////////////////////////////////////////////////////
                    MAX LT WITHDRAWAL: GATED SOUNDNESS AND TIGHTNESS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice In the gated regime (a liquidity requirement is set and coverage is not in liquidation), a
     *         positive LT cap leaves the liquidity floor intact: after withdrawing the cap, the remaining pool
     *         depth still covers the senior effective NAV scaled by the minimum liquidity fraction. The LT can
     *         exit down to the senior liquidity floor but never below it
     * @dev The ceil-rounded required depth ceil(stEff*minLiq/WAD) is re-executed through the identical mulDiv
     *      shim as requiredDepth. Lemma one (linear): the positive cap z is a saturating subtraction of that
     *      required depth plus the senior dust from the pool depth, so the remaining depth ltRaw - z is at least
     *      requiredDepth. Lemma two (the shim ceil bracket): stEff * minLiq is at most requiredDepth * WAD. The
     *      two chain to stEff*minLiq <= (ltRaw - z)*WAD, division-free
     */
    function check_maxLTWithdrawalGatedResultKeepsLiquiditySatisfied(
        uint256 stEff,
        uint256 minLiq,
        uint256 ltRaw,
        uint256 covUtil,
        uint256 covLiqUtil,
        uint256 stDust
    )
        external
    {
        vm.assume(stEff <= MAX_NAV && ltRaw <= MAX_NAV);
        vm.assume(1 <= minLiq && minLiq <= WAD);
        // Gated regime: liquidity requirement active and coverage below the liquidation threshold
        vm.assume(covUtil < covLiqUtil);
        vm.assume(stDust <= MAX_DUST);
        driver.setDustTolerances(toNAVUnits(stDust), toNAVUnits(uint256(0)));

        // The required market-making depth the cap subtracts from, re-executed through the identical ceil mulDiv
        uint256 requiredDepth = driver.mulDivCeil(stEff, minLiq, WAD);
        uint256 z = toUint256(driver.maxLTWithdrawal(_state(0, 0, ltRaw, stEff, 0, minLiq, false, minLiq, covUtil, covLiqUtil)));
        // A positive cap means the saturating subtraction did not clamp, so the remaining depth is well-defined
        vm.assume(z > 0);

        // Lemma one (linear): the remaining depth after the cap is at least the ceil-required depth
        assert(ltRaw - z >= requiredDepth);
        // Lemma two (the shim ceil bracket): the required depth scaled back covers the senior liquidity need
        assert(stEff * minLiq <= requiredDepth * WAD);
    }

    /**
     * @notice The gated LT cap is tight to one wei: withdrawing a single wei beyond it breaches the liquidity
     *         floor. This proves the cap is the exact frontier of the no-run guarantee, not a conservative
     *         under-report that would strand releasable depth
     * @dev With senior dust pinned to zero, a positive cap z leaves exactly the ceil-required depth behind, so
     *      one wei more leaves requiredDepth - 1. Lemma one (linear): the remaining depth ltRaw - z equals the
     *      ceil-required depth re-executed through the shim. Lemma two (the shim ceil upper bracket): the ceil
     *      required depth times WAD is strictly below stEff*minLiq + WAD, so (requiredDepth - 1)*WAD is strictly
     *      below stEff*minLiq. A positive senior effective NAV and requirement keep the required depth at least
     *      one so the over-withdrawal stays non-negative
     */
    function check_oneWeiPastMaxLTWithdrawalBreachesLiquidity(
        uint256 stEff,
        uint256 minLiq,
        uint256 ltRaw,
        uint256 covUtil,
        uint256 covLiqUtil
    )
        external
    {
        vm.assume(1 <= stEff && stEff <= MAX_NAV && ltRaw <= MAX_NAV);
        vm.assume(1 <= minLiq && minLiq <= WAD);
        // Gated regime
        vm.assume(covUtil < covLiqUtil);
        // Pin senior dust to zero so the remaining depth equals the bare ceil requirement
        driver.setDustTolerances(toNAVUnits(uint256(0)), toNAVUnits(uint256(0)));

        uint256 requiredDepth = driver.mulDivCeil(stEff, minLiq, WAD);
        uint256 z = toUint256(driver.maxLTWithdrawal(_state(0, 0, ltRaw, stEff, 0, minLiq, false, minLiq, covUtil, covLiqUtil)));
        vm.assume(z > 0);

        // Lemma one (linear): with zero dust the remaining depth is exactly the ceil-required depth
        assert(ltRaw - z == requiredDepth);
        // Lemma two (the shim ceil upper bracket): one wei past the cap drops below the senior liquidity floor
        assert((requiredDepth - 1) * WAD < stEff * minLiq);
    }

    /*//////////////////////////////////////////////////////////////////////
                    MAX JT WITHDRAWAL: ZERO EARLY ARMS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice When the junior tranche holds no surplus coverage buffer, the junior-withdrawal cap is exactly
     *         (0, 0): nothing may be withdrawn from a junior that is already at or below the coverage it must
     *         provide. A zero junior effective NAV is the extremal case where the surplus saturates to zero
     * @dev Pinning the junior effective NAV to zero drives the surplus saturating subtraction to zero, hitting
     *      the first early return. The coverage requirement is pinned to zero so the required-value ceil mulDiv
     *      collapses to a constant zero and the whole pre-return path is linear, and the senior effective mark is
     *      held at or below the senior raw so the upstream claims decomposition cannot underflow. Both legs of
     *      the returned pair are asserted zero directly
     */
    function check_maxJTWithdrawalIsZeroWhenNoCoverageSurplus(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 stEff,
        bool coinvest,
        uint256 stDust,
        uint256 jtDust
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && stEff <= MAX_NAV);
        // Keep the senior cross-claim within the junior raw so the claims decomposition does not revert
        vm.assume(stEff <= stRaw);
        vm.assume(stDust <= MAX_DUST && jtDust <= MAX_DUST);
        driver.setDustTolerances(toNAVUnits(stDust), toNAVUnits(jtDust));

        // Zero junior effective NAV and zero coverage requirement: no surplus buffer, linear pre-return path
        (NAV_UNIT stW, NAV_UNIT jtW) = driver.maxJTWithdrawal(_state(stRaw, jtRaw, 0, stEff, 0, 0, coinvest, 0, 0, 0));

        // A junior with no surplus coverage may withdraw nothing
        assert(toUint256(stW) == 0 && toUint256(jtW) == 0);
    }

    /**
     * @notice When the junior tranche has a positive surplus buffer but holds no claims on either raw pool, the
     *         cap is still exactly (0, 0): there is no claimed NAV to source a withdrawal from. This pins the
     *         second early return, distinct from the no-surplus arm
     * @dev The state is built so the junior claims on both raw pools vanish (the junior effective NAV rests
     *      entirely inside the senior-owned effective claim) while the surplus stays positive. The coverage
     *      requirement is pinned to zero so the required-value ceil mulDiv collapses to a constant zero and the
     *      surplus is simply the junior effective NAV minus the two-wei absorber, keeping the whole pre-return
     *      path linear. The third early return (a zero total claimable) is unreachable because the coverage
     *      retention factor never exceeds WAD, so a positive surplus always scales to a positive total; that
     *      unreachability is carried by the divisor-positivity lemma below
     */
    function check_maxJTWithdrawalIsZeroWhenJuniorHasNoClaims(uint256 pool, uint256 jtEff) external {
        vm.assume(3 <= pool && pool <= MAX_NAV);
        // A junior effective NAV in [3, pool] keeps the surplus positive while all junior claims stay zero
        vm.assume(3 <= jtEff && jtEff <= pool);
        // Zero dust so the surplus is the junior effective NAV minus the two-wei absorber
        driver.setDustTolerances(toNAVUnits(uint256(0)), toNAVUnits(uint256(0)));

        // stRaw = 0 and stEff = jtRaw = pool: the senior owns the whole junior raw as an effective claim, so the
        // junior's claims on both raw pools are zero, while a zero coverage requirement keeps the surplus equal
        // to jtEff - 2 > 0
        (NAV_UNIT stW, NAV_UNIT jtW) = driver.maxJTWithdrawal(_state(0, pool, 0, pool, jtEff, 0, false, 0, 0, 0));

        // With no claimed NAV backing the surplus, the junior may withdraw nothing
        assert(toUint256(stW) == 0 && toUint256(jtW) == 0);
    }

    /*//////////////////////////////////////////////////////////////////////
                    MAX JT WITHDRAWAL: DIVISOR POSITIVITY
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The two junior claim fractions, each the floored WAD-scaled slice of its claim over the shared
     *         total claim, never sum past WAD. This is the first half of the divisor-positivity argument: the
     *         coverage-weighted fraction sum that the retention factor subtracts cannot exceed the full budget
     * @dev The two fractions and the combined slice are executed through the identical floored mulDiv the
     *      production uses (claim over the shared total), one level deep so the engine models each quotient by
     *      its own floor bracket. The two floored slices of one shared denominator never exceed the combined
     *      floored slice by floor superadditivity, and the combined slice over the whole total is at most WAD
     *      because a floored slice of a value by a factor at most its denominator never inflates. Both steps are
     *      the same shared-denominator floor facts the tranche-claim scaling proofs establish
     */
    function check_coverageFractionSlicesOfSharedClaimSumToAtMostWAD(uint256 jtClaimOnST, uint256 jtClaimOnJT) external view {
        vm.assume(jtClaimOnST <= MAX_NAV && jtClaimOnJT <= MAX_NAV);
        uint256 total = jtClaimOnST + jtClaimOnJT;
        vm.assume(total >= 1);

        // The exact production fractions, executed one level deep through the identical mulDiv
        uint256 fracST = driver.mulDivFloor(jtClaimOnST, WAD, total);
        uint256 fracJT = driver.mulDivFloor(jtClaimOnJT, WAD, total);
        // The combined slice over the same shared denominator (the whole total scaled by WAD over the total)
        uint256 combined = driver.mulDivFloor(total, WAD, total);

        // Two floored slices of one shared denominator never exceed the combined floored slice
        assert(fracST + fracJT <= combined);
        // The combined slice of the whole total by WAD over the total never inflates past WAD
        assert(combined <= WAD);
        // So the coverage-weighted fraction sum can draw at most the full budget
        assert(fracST + fracJT <= WAD);
    }

    /**
     * @notice A coverage-weighted floored slice of any fraction sum at most WAD stays at or below the coverage
     *         requirement, so the retention factor WAD minus that slice never drops to zero under strictly
     *         sub-unit coverage. This is the second half of the divisor-positivity argument: the surplus-scaling
     *         division at the heart of the junior-withdrawal cap can never panic on a zero divisor
     * @dev The fraction sum is a fresh symbolic value bounded by WAD (the fact the sibling slice-sum lemma
     *      establishes), so the subtrahend is a single one-level floored mulDiv of the coverage requirement by
     *      that sum over WAD. A floored slice of a value by a factor at most its denominator never inflates past
     *      the value, so the subtrahend is at most the coverage requirement, which is strictly sub-unit, leaving
     *      the retained factor at least one
     */
    function check_coverageRetentionSubtrahendKeepsDivisorPositive(uint256 fractionSum, uint256 minCov) external view {
        // The coverage-weighted fraction sum never exceeds the full budget (the slice-sum lemma's conclusion)
        vm.assume(fractionSum <= WAD);
        // Strict sub-unit coverage: the config invariant that keeps the retention factor above zero
        vm.assume(1 <= minCov && minCov < WAD);

        // The exact production retention subtrahend, executed one level deep through the identical mulDiv
        uint256 subtrahend = driver.mulDivFloor(minCov, fractionSum, WAD);

        // A floored slice of coverage by a factor at most WAD over WAD never inflates past the coverage
        assert(subtrahend <= minCov);
        // So the retained factor stays at least WAD minus a strictly sub-unit requirement, hence at least one
        assert(WAD - subtrahend >= WAD - minCov);
        assert(WAD - subtrahend >= 1);
    }

    /*//////////////////////////////////////////////////////////////////////
                    MAX JT WITHDRAWAL: SPLIT NEVER OVER-PAYS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Splitting the total claimable NAV into its senior-sourced and junior-sourced legs never pays out
     *         more than the total, and each leg never exceeds its proportional share. Over-paying the split
     *         would let a junior redemption pull more raw NAV than its coverage surplus entitles it to
     * @dev The two claim fractions are fresh symbolic values summing to at most WAD (the fact the slice-sum
     *      lemma establishes), so each leg and the combined slice are single one-level floored mulDivs of the
     *      total claimable. Each leg is at most its exact proportional share (the floor lower bracket). The two
     *      legs sum to at most the combined slice by floor superadditivity, and the combined slice is at most the
     *      total because the fraction budget is at most WAD; both are the shared-denominator floor facts
     */
    function check_maxJTWithdrawalSplitNeverExceedsTotalClaimable(
        uint256 totalClaimable,
        uint256 fracST,
        uint256 fracJT
    )
        external
        view
    {
        // Fractions sum within WAD (the proved slice-sum fact) and the total claimable is bounded
        vm.assume(fracST <= WAD && fracJT <= WAD && fracST + fracJT <= WAD);
        vm.assume(totalClaimable <= MAX_NAV);

        uint256 stW = driver.mulDivFloor(totalClaimable, fracST, WAD);
        uint256 jtW = driver.mulDivFloor(totalClaimable, fracJT, WAD);
        uint256 combined = driver.mulDivFloor(totalClaimable, fracST + fracJT, WAD);

        // Each leg is at most its exact proportional floor slice of the total claimable
        assert(stW * WAD <= totalClaimable * fracST);
        assert(jtW * WAD <= totalClaimable * fracJT);
        // The two legs together never exceed the combined slice (floor superadditivity)
        assert(stW + jtW <= combined);
        // The combined slice never exceeds the total because the fraction budget is at most WAD
        assert(combined <= totalClaimable);
        // So the split never pays out more than the total claimable
        assert(stW + jtW <= totalClaimable);
    }

    /*//////////////////////////////////////////////////////////////////////
                    MAX JT WITHDRAWAL: COVERAGE SOUNDNESS (RECORDED INCOMPLETE)
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Withdrawing the junior-withdrawal cap leaves the coverage requirement satisfied when the junior
     *         tranche is co-invested: after the senior-sourced and junior-sourced legs are pulled, the reduced
     *         covered exposure scaled by the minimum coverage fraction still fits inside the reduced junior
     *         buffer. This is the no-under-coverage guarantee of the junior exit path
     * @dev The post-withdrawal marks are stRaw - stW, jtRaw - jtW, and jtEff - stW - jtW. Rearranged to avoid
     *      any spec-side subtraction, the coverage inequality becomes
     *      (stRaw + jtRaw) * minCov + (stW + jtW) * WAD <= jtEff * WAD + (stW + jtW) * minCov, a division-free
     *      product inequality on the two returned legs; the continuous slack is exactly WAD - (fracST + fracJT)
     *      and the production ceil plus the two-wei absorber budget the inner floor drifts. The pre-coverage
     *      margin guarantees the surplus path is taken. This four-deep floored/ceiled mulDiv recombination
     *      exceeds the native engine's hard-arithmetic heuristic and is recorded incomplete: the empirical side
     *      is owned by the invariant gate-boundary park-and-probe suite and the fuzz one-wei gate bracketing
     */
    function check_withdrawingMaxJTRespectsCoverageWhenJuniorCoinvested(uint256 stRaw, uint256 jtRaw, uint256 stEff, uint256 minCov) external {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV);
        uint256 total = stRaw + jtRaw;
        vm.assume(stEff <= total);
        uint256 jtEff = total - stEff;
        vm.assume(1 <= minCov && minCov < WAD);
        driver.setDustTolerances(toNAVUnits(uint256(0)), toNAVUnits(uint256(0)));
        // Pre-covered with margin so the surplus path is taken (co-invested exposure is stRaw + jtRaw)
        vm.assume(jtEff * WAD >= (stRaw + jtRaw) * minCov + 4 * WAD);

        (NAV_UNIT stWUnit, NAV_UNIT jtWUnit) = driver.maxJTWithdrawal(_state(stRaw, jtRaw, 0, stEff, jtEff, minCov, true, 0, 0, 0));
        uint256 stW = toUint256(stWUnit);
        uint256 jtW = toUint256(jtWUnit);

        // Post-withdrawal coverage utilization stays at or below one (rearranged to be subtraction-free)
        assert((stRaw + jtRaw) * minCov + (stW + jtW) * WAD <= jtEff * WAD + (stW + jtW) * minCov);
    }

    /**
     * @notice Withdrawing the junior-withdrawal cap leaves the coverage requirement satisfied when the junior
     *         tranche is isolated: only the senior mark counts toward exposure, and only the senior-sourced leg
     *         reduces it, yet the reduced exposure still fits the reduced junior buffer
     * @dev Same rearranged division-free coverage inequality as the co-invested case, with the junior raw NAV
     *      dropped from the exposure and only the senior-sourced leg entering the coverage-relevant term. The
     *      four-deep mulDiv recombination is recorded incomplete under the same fallback owners as the
     *      co-invested case
     */
    function check_withdrawingMaxJTRespectsCoverageWhenJuniorIsolated(uint256 stRaw, uint256 jtRaw, uint256 stEff, uint256 minCov) external {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV);
        uint256 total = stRaw + jtRaw;
        vm.assume(stEff <= total);
        uint256 jtEff = total - stEff;
        vm.assume(1 <= minCov && minCov < WAD);
        driver.setDustTolerances(toNAVUnits(uint256(0)), toNAVUnits(uint256(0)));
        // Pre-covered with margin so the surplus path is taken (isolated exposure is stRaw only)
        vm.assume(jtEff * WAD >= stRaw * minCov + 4 * WAD);

        (NAV_UNIT stWUnit, NAV_UNIT jtWUnit) = driver.maxJTWithdrawal(_state(stRaw, jtRaw, 0, stEff, jtEff, minCov, false, 0, 0, 0));
        uint256 stW = toUint256(stWUnit);
        uint256 jtW = toUint256(jtWUnit);

        // Post-withdrawal coverage utilization stays at or below one with only the senior mark and leg exposed
        assert(stRaw * minCov + (stW + jtW) * WAD <= jtEff * WAD + stW * minCov);
    }
}
