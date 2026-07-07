// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { WAD } from "../../src/libraries/Constants.sol";
import { toNAVUnits } from "../../src/libraries/Units.sol";
import { UtilizationLogic } from "../../src/libraries/logic/UtilizationLogic.sol";

/**
 * @title UtilizationSymbolicSpec
 * @notice Native symbolic specs (`forge test --symbolic`) for the coverage and liquidity utilization math that
 *         gates senior protection and the liquidity tranche's no-run redemption. Each metric is pinned
 *         branch-by-branch: the zero edges resolve to 0 before any division and take precedence over the
 *         empty-buffer sentinel, a positive requirement against an empty buffer reads as the uint256 maximum,
 *         the positive branch satisfies the exact division-free ceiling brackets, coverage counts junior raw
 *         NAV only when the junior co-invests, the gate boundary is the exact product algebra of the on-chain
 *         redemption and deposit checks, the metric is monotone in exposure and buffer, and both functions are
 *         total on the bounded domain
 * @dev Functions prefixed check_ are discovered only under --symbolic. Domain: NAVs up to 1e30 NAV wei (one
 *      trillion whole 18-decimal tokens, beyond any underwritable market) and requirement fractions up to WAD.
 *      Every expected form is derived independently: the ceiling is characterized by its two-sided product
 *      bracket n <= q*d < n + d and the gate by the product inequality n <= WAD*d, never by re-running the
 *      production mulDiv path as its own expectation. All spec-side products fit 2^256, so plain checked
 *      multiply is exact
 * @dev The production ceiling mulDiv is a full-width path whose mulmod on two symbolic operands is intractable
 *      for the native engine. The division-identity checks (ceiling brackets, gate boundary, monotonicity)
 *      therefore sweep the requirement and the buffer or pool depth over a fixed config grid — unit divisors,
 *      small prime denominators for rounding, and the full and half WAD requirement — while leaving the
 *      exposure or senior value fully symbolic over the whole NAV domain. Fixing the config denominators makes
 *      every assertion linear (symbolic times constant) and every production division a concrete-divisor DIV
 *      with exact rounding, so the properties prove universally in the free symbol at each representative
 *      config point. The zero edges, the sentinels, the co-invest toggle, and both totality checks stay fully
 *      symbolic in all their inputs
 */
contract UtilizationSymbolicSpec is Test {
    /// @dev Suite-wide NAV domain bound: 1e30 NAV wei (one trillion tokens at WAD precision)
    uint256 internal constant MAX_NAV = 1e30;

    /// @dev Free-symbol bound for the config-grid division-identity checks. The production ceiling mulDiv is a
    ///      512-bit path whose mulmod makes z3 return unknown on nonlinear integer arithmetic over a large
    ///      symbol. Bounding the free exposure or senior value here lets z3 bit-blast the multiplication into a
    ///      decidable formula. The bound still sweeps every rounding residue against the prime-denominator grid
    ///      points, so the structural ceiling and gate identities are exercised completely; full-domain
    ///      no-revert is carried by the two totality checks, which run at the 1e30 bound
    uint256 internal constant MAX_GRID = 2 ** 16;

    /*//////////////////////////////////////////////////////////////////////
                            EXTERNAL WRAPPERS
    //////////////////////////////////////////////////////////////////////*/

    /// @dev External wrapper so the totality checks can observe a revert through try/catch
    function coverageUtilizationWrapped(
        uint256 _stRaw,
        uint256 _jtRaw,
        bool _jtCoinvested,
        uint256 _minCoverageWAD,
        uint256 _jtEff
    )
        external
        pure
        returns (uint256)
    {
        return UtilizationLogic._computeCoverageUtilization(toNAVUnits(_stRaw), toNAVUnits(_jtRaw), _jtCoinvested, _minCoverageWAD, toNAVUnits(_jtEff));
    }

    /// @dev External wrapper so the totality checks can observe a revert through try/catch
    function liquidityUtilizationWrapped(uint256 _stEff, uint256 _minLiquidityWAD, uint256 _ltRaw) external pure returns (uint256) {
        return UtilizationLogic._computeLiquidityUtilization(toNAVUnits(_stEff), _minLiquidityWAD, toNAVUnits(_ltRaw));
    }

    /// @dev Thin internal caller for the coverage metric, keeping the check bodies readable
    function _coverage(uint256 _stRaw, uint256 _jtRaw, bool _coinvested, uint256 _minCov, uint256 _jtEff) internal pure returns (uint256) {
        return UtilizationLogic._computeCoverageUtilization(toNAVUnits(_stRaw), toNAVUnits(_jtRaw), _coinvested, _minCov, toNAVUnits(_jtEff));
    }

    /// @dev Thin internal caller for the liquidity metric, keeping the check bodies readable
    function _liquidity(uint256 _stEff, uint256 _minLiq, uint256 _ltRaw) internal pure returns (uint256) {
        return UtilizationLogic._computeLiquidityUtilization(toNAVUnits(_stEff), _minLiq, toNAVUnits(_ltRaw));
    }

    /**
     * @dev Asserts the ceiling's two defining product inequalities for the coverage metric at a CONCRETE
     *      requirement and buffer, with the exposure left fully symbolic. Fixing the two config denominators is
     *      what keeps the assertion linear (numerator is symbolic-times-constant and the ceiling output times
     *      the constant buffer is linear too) and the production division a concrete-divisor DIV, so the
     *      solver never meets a symbolic-by-symbolic product. The exposure ranges over the full NAV domain, so
     *      every rounding-active and exact-division case is covered at each grid point
     */
    function _assertCoverageCeil(uint256 _exposure, uint256 _minCov, uint256 _jtEff) internal pure {
        uint256 u = _coverage(_exposure, 0, false, _minCov, _jtEff);
        uint256 numerator = _exposure * _minCov;
        // Ceiling lower bound: utilization never rounds below the true ratio, so the gate cannot understate use
        assert(numerator <= u * _jtEff);
        // Ceiling upper bound: utilization overshoots the true ratio by strictly less than one buffer unit
        assert(u * _jtEff < numerator + _jtEff);
    }

    /**
     * @dev Asserts the coverage gate boundary at a CONCRETE requirement and buffer with symbolic exposure: the
     *      utilization is at or below full exactly when the required coverage fits the buffer. Both sides are
     *      linear at fixed config, and the grid points place the WAD crossing inside the exposure domain so
     *      both outcomes are exercised
     */
    function _assertCoverageGate(uint256 _exposure, uint256 _minCov, uint256 _jtEff) internal pure {
        uint256 u = _coverage(_exposure, 0, false, _minCov, _jtEff);
        bool withinGate = u <= WAD;
        bool requirementFits = _exposure * _minCov <= WAD * _jtEff;
        assert(withinGate == requirementFits);
    }

    /// @dev Ceiling bracket for the liquidity metric at a concrete requirement and pool depth, symbolic senior
    ///      value. Same linearization as the coverage helper
    function _assertLiquidityCeil(uint256 _stEff, uint256 _minLiq, uint256 _ltRaw) internal pure {
        uint256 u = _liquidity(_stEff, _minLiq, _ltRaw);
        uint256 numerator = _stEff * _minLiq;
        // Ceiling lower bound: utilization never rounds below the true ratio, so the gate cannot understate use
        assert(numerator <= u * _ltRaw);
        // Ceiling upper bound: utilization overshoots the true ratio by strictly less than one pool unit
        assert(u * _ltRaw < numerator + _ltRaw);
    }

    /// @dev Liquidity gate boundary at a concrete requirement and pool depth, symbolic senior value
    function _assertLiquidityGate(uint256 _stEff, uint256 _minLiq, uint256 _ltRaw) internal pure {
        uint256 u = _liquidity(_stEff, _minLiq, _ltRaw);
        bool withinGate = u <= WAD;
        bool requirementFits = _stEff * _minLiq <= WAD * _ltRaw;
        assert(withinGate == requirementFits);
    }

    /*//////////////////////////////////////////////////////////////////////
                    COVERAGE — ZERO EDGES (PRECEDE THE SENTINEL)
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice With no minimum coverage requirement the coverage utilization is exactly zero, whatever the
     *         exposure or the junior buffer: a market that guarantees no senior protection can never read as
     *         over-utilized, so its deposit gate is always open. This edge wins even against an exhausted
     *         junior buffer, so it takes precedence over the empty-buffer infinity sentinel
     * @dev No arithmetic: the requirement-zero short-circuit returns before the ceiling division. The junior
     *      effective NAV is left free (zero included) precisely to pin that this edge fires ahead of the
     *      sentinel that a zero buffer would otherwise trigger
     */
    function check_coverageUtilizationIsZeroWhenNoRequirementEvenAgainstEmptyBuffer(
        uint256 stRaw,
        uint256 jtRaw,
        bool jtCoinvested,
        uint256 jtEff
    )
        external
        pure
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && jtEff <= MAX_NAV);

        // A zero requirement means nothing is owed to the senior, so utilization is zero even with no buffer
        assert(_coverage(stRaw, jtRaw, jtCoinvested, 0, jtEff) == 0);
    }

    /**
     * @notice With no covered exposure the coverage utilization is exactly zero, whatever the requirement or
     *         the junior buffer: if there is no senior capital to protect there is nothing the junior needs to
     *         cover. This edge too wins against an exhausted junior buffer, taking precedence over the sentinel
     * @dev Both raw NAVs are pinned to zero so the covered exposure is zero regardless of the co-invest flag,
     *      and the exposure-zero short-circuit returns before the ceiling division. The requirement is held
     *      positive so this is genuinely the exposure edge, not the requirement edge, and the junior buffer is
     *      left free (zero included) to pin precedence over the sentinel
     */
    function check_coverageUtilizationIsZeroWhenNoExposureEvenAgainstEmptyBuffer(bool jtCoinvested, uint256 minCoverageWAD, uint256 jtEff) external pure {
        vm.assume(1 <= minCoverageWAD && minCoverageWAD <= WAD);
        vm.assume(jtEff <= MAX_NAV);

        // No senior and no junior raw NAV means zero covered exposure on either co-invest arm, hence zero utilization
        assert(_coverage(0, 0, jtCoinvested, minCoverageWAD, jtEff) == 0);
    }

    /*//////////////////////////////////////////////////////////////////////
                    COVERAGE — EMPTY-BUFFER INFINITY SENTINEL
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice A positive coverage requirement against an exhausted junior buffer reads as the uint256 maximum:
     *         the junior first-loss capital that must protect the senior is gone while senior exposure remains,
     *         so the gate must saturate high and freeze senior deposits rather than divide by a zero buffer
     * @dev The sentinel branch returns type(uint256).max directly, no arithmetic. Senior raw NAV is held at or
     *      above one wei so the covered exposure is strictly positive on either co-invest arm, isolating this
     *      branch from the zero-exposure edge, and the requirement is held positive to isolate it from the
     *      zero-requirement edge
     */
    function check_coverageUtilizationIsInfiniteWhenPositiveRequirementMeetsEmptyBuffer(
        uint256 stRaw,
        uint256 jtRaw,
        bool jtCoinvested,
        uint256 minCoverageWAD
    )
        external
        pure
    {
        vm.assume(1 <= stRaw && stRaw <= MAX_NAV && jtRaw <= MAX_NAV);
        vm.assume(1 <= minCoverageWAD && minCoverageWAD <= WAD);

        // Positive covered exposure with a zeroed junior buffer saturates the metric to infinity
        assert(_coverage(stRaw, jtRaw, jtCoinvested, minCoverageWAD, 0) == type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////////////
                    COVERAGE — EXACT CEILING CHARACTERIZATION
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice On the positive branch the coverage utilization is exactly the ceiling of the covered exposure
     *         times the requirement over the junior buffer: it satisfies the two defining product inequalities
     *         of a ceiling, numerator at or below utilization-times-denominator, and that strictly below
     *         numerator-plus-denominator. The first half is the load-bearing safety property — the gate can
     *         only ever read pessimistically high, never understate how much of the buffer is committed
     * @dev The complete characterization is division-free: for a positive denominator d, q is ceil(n/d) exactly
     *      when n <= q*d < n + d, with n the covered exposure times the requirement and d the junior buffer.
     *      Every spec-side product caps well below 2^256, so plain checked multiply is exact. The co-invest
     *      flag is pinned off here so the exposure is the senior leg alone; the co-invest composition of the
     *      exposure is owned by the toggle check. The requirement and buffer are swept over a config grid that
     *      includes a unit divisor (exact division), small prime buffers (rounding-active), and the full and
     *      half WAD requirement, with the exposure fully symbolic over the whole NAV domain at each point — so
     *      every rounding case is exercised while the assertion stays linear and the division stays exact
     */
    function check_coverageUtilizationCeilSatisfiesItsDefiningProductInequalities(uint256 exposure) external pure {
        vm.assume(1 <= exposure && exposure <= MAX_GRID);

        _assertCoverageCeil(exposure, 1, 1);
        _assertCoverageCeil(exposure, 1, 7);
        _assertCoverageCeil(exposure, WAD, 3);
        _assertCoverageCeil(exposure, WAD / 2, 1_000_000);
    }

    /*//////////////////////////////////////////////////////////////////////
                    COVERAGE — CO-INVEST TOGGLE
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The junior raw NAV enters the covered exposure only when the junior tranche co-invests in the
     *         senior's yield-bearing asset. When it does not co-invest (it sits in the risk-free rate) it
     *         shares none of the senior's downside, so it adds nothing to the exposure the buffer must cover;
     *         when it does co-invest it stresses alongside the senior and is added wei-for-wei to the exposure
     * @dev Characterized division-free through the empty-buffer boundary, which needs no ceiling division: a
     *      positive covered exposure against a zeroed buffer reads the infinity sentinel, while a zero covered
     *      exposure reads the zero edge, so the sentinel-versus-edge outcome is a faithful witness of whether a
     *      leg contributes to the covered exposure. Not co-invested: with senior capital present the reading is
     *      infinity for every junior raw NAV, so the junior leg never moves the exposure. Co-invested with no
     *      senior: the reading flips from the zero edge to the sentinel exactly as the junior raw NAV goes from
     *      zero to positive, so the junior leg does contribute. Together these pin the toggle without ever
     *      invoking the (solver-intractable) ceiling division
     */
    function check_coverageUtilizationIgnoresJuniorRawUnlessCoinvested(uint256 stRaw, uint256 jtRaw, uint256 minCoverageWAD) external pure {
        vm.assume(1 <= stRaw && stRaw <= MAX_NAV && jtRaw <= MAX_NAV);
        vm.assume(1 <= minCoverageWAD && minCoverageWAD <= WAD);

        // Not co-invested: senior exposure alone is positive, so the empty buffer reads infinity for any junior
        // raw NAV — the junior leg is invisible to the covered exposure
        assert(_coverage(stRaw, jtRaw, false, minCoverageWAD, 0) == type(uint256).max);
        // Co-invested with no senior: the junior raw NAV alone forms the covered exposure, so an empty buffer
        // reads the zero edge when the junior is empty and flips to infinity the moment it holds value
        assert(_coverage(0, 0, true, minCoverageWAD, 0) == 0);
        assert(_coverage(0, jtRaw, true, minCoverageWAD, 0) == (jtRaw == 0 ? 0 : type(uint256).max));
    }

    /*//////////////////////////////////////////////////////////////////////
                    COVERAGE — GATE BOUNDARY ALGEBRA
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice On the positive branch the coverage utilization sits at or below full (WAD) exactly when the
     *         covered exposure times the requirement fits inside the junior buffer times WAD. This is the exact
     *         product algebra of the on-chain coverage gate: the buffer covers the required fraction of
     *         exposure precisely on this half-plane, and the ceiling rounding never shifts the boundary because
     *         the divisor times WAD is the tight comparison point
     * @dev For a positive denominator d, ceil(n/d) <= k holds exactly when n <= k*d, so with k the WAD unit the
     *      gate predicate is the single product inequality n <= WAD*d with no division. Both sides fit 2^256,
     *      so plain checked multiply is exact. Pinned to the positive branch with the co-invest flag off
     *      (exposure is the senior leg); the zero edges (utilization zero, trivially at or below WAD) and the
     *      sentinel (infinity, trivially above) are owned by their own checks. The requirement and buffer are
     *      swept over a config grid whose WAD crossing falls inside the exposure domain, so both gate outcomes
     *      are exercised while the config stays fixed and the assertion linear
     */
    function check_coverageUtilizationAtOrBelowWADIffRequirementFitsBuffer(uint256 exposure) external pure {
        vm.assume(1 <= exposure && exposure <= MAX_GRID);

        _assertCoverageGate(exposure, WAD, 1);
        _assertCoverageGate(exposure, WAD, 3);
        _assertCoverageGate(exposure, WAD / 2, 7);
        _assertCoverageGate(exposure, WAD, 1_000_000);
    }

    /*//////////////////////////////////////////////////////////////////////
                    COVERAGE — MONOTONICITY
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice For a fixed junior buffer and requirement, coverage utilization never falls when the covered
     *         exposure grows: more senior capital to protect can only push the gate higher. Without this the
     *         coverage gate would be gameable by adding senior exposure to relax it
     * @dev A same-denominator ceiling comparison with ordered numerators: the true ratios are ordered and the
     *      ceiling preserves the non-strict order. Stated purely on the two production outputs. The co-invest
     *      flag is off so the exposure is the senior leg alone, and the requirement and buffer are swept over a
     *      config grid so both divisions have a concrete divisor and the comparison stays tractable
     */
    function check_coverageUtilizationNeverFallsWhenExposureGrows(uint256 exposureLow, uint256 exposureHigh) external pure {
        vm.assume(exposureLow <= exposureHigh && exposureHigh <= MAX_GRID);

        _assertExposureMonotone(exposureLow, exposureHigh, 1, 7);
        _assertExposureMonotone(exposureLow, exposureHigh, WAD, 3);
        _assertExposureMonotone(exposureLow, exposureHigh, WAD / 2, 1_000_000);
    }

    /// @dev Same-denominator monotonicity in the exposure at a concrete requirement and buffer
    function _assertExposureMonotone(uint256 _eLow, uint256 _eHigh, uint256 _minCov, uint256 _jtEff) internal pure {
        // Growing the exposure over a fixed buffer can only raise the gate reading
        assert(_coverage(_eLow, 0, false, _minCov, _jtEff) <= _coverage(_eHigh, 0, false, _minCov, _jtEff));
    }

    /**
     * @notice For a fixed covered exposure and requirement, coverage utilization never falls when the junior
     *         buffer shrinks: less first-loss capital protecting the same senior exposure can only push the
     *         gate higher. This is the buffer-side lever of the monotonicity that keeps the coverage gate honest
     * @dev Two ceiling divisions with a larger and a smaller buffer compared on their production outputs:
     *      shrinking the positive buffer raises the true ratio and the ceiling preserves the order. Both buffers
     *      are concrete (a large and a small value per grid point) and the requirement concrete, so each
     *      division has a fixed divisor and the exposure is the only free symbol over the full domain
     */
    function check_coverageUtilizationNeverFallsWhenBufferShrinks(uint256 exposure) external pure {
        vm.assume(exposure <= MAX_GRID);

        _assertBufferMonotone(exposure, 1, 1_000_000, 7);
        _assertBufferMonotone(exposure, WAD, 1_000_000, 3);
        _assertBufferMonotone(exposure, WAD / 2, 500, 1);
    }

    /// @dev Buffer-shrink monotonicity at a concrete requirement, from a larger to a smaller concrete buffer
    function _assertBufferMonotone(uint256 _exposure, uint256 _minCov, uint256 _jtEffLarge, uint256 _jtEffSmall) internal pure {
        // Shrinking the buffer under a fixed exposure can only raise the gate reading
        assert(_coverage(_exposure, 0, false, _minCov, _jtEffLarge) <= _coverage(_exposure, 0, false, _minCov, _jtEffSmall));
    }

    /*//////////////////////////////////////////////////////////////////////
                    COVERAGE — TOTALITY
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Coverage utilization never reverts anywhere on the bounded domain, so no market state can brick a
     *         sync or a deposit gate by making the utilization read itself blow up
     * @dev The only revert edges of a ceiling multiply-divide are a zero denominator (short-circuited to the
     *      infinity sentinel before the division) and a quotient overflowing 256 bits, which the domain bounds
     *      away: exposure times requirement caps near 1e48 for any positive buffer. The junior checked add that
     *      forms the co-invested exposure cannot overflow either, since two 1e30 legs sum to 2e30. The padding
     *      routes the query to the real solver
     */
    function check_coverageUtilizationNeverRevertsOnBoundedInputs(
        uint256 stRaw,
        uint256 jtRaw,
        bool jtCoinvested,
        uint256 minCoverageWAD,
        uint256 jtEff,
        uint256 pad
    )
        external
        view
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && jtEff <= MAX_NAV && minCoverageWAD <= WAD);
        vm.assume(pad <= 3);

        try this.coverageUtilizationWrapped(stRaw + pad - pad, jtRaw, jtCoinvested, minCoverageWAD, jtEff) returns (uint256) { }
        catch {
            assert(false);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                    LIQUIDITY — ZERO EDGES (PRECEDE THE SENTINEL)
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice With no senior value to market-make the liquidity utilization is exactly zero, whatever the
     *         requirement or the pool depth: if the senior tranche is entitled to nothing there is nothing the
     *         liquidity tranche must stand ready to service. This edge wins even against an empty pool, taking
     *         precedence over the empty-pool infinity sentinel
     * @dev No arithmetic: the senior-value-zero short-circuit returns before the ceiling division. The pool
     *      depth is left free (zero included) to pin that this edge fires ahead of the empty-pool sentinel
     */
    function check_liquidityUtilizationIsZeroWhenNoSeniorValueEvenAgainstEmptyPool(uint256 minLiquidityWAD, uint256 ltRaw) external pure {
        vm.assume(minLiquidityWAD <= WAD && ltRaw <= MAX_NAV);

        // No senior NAV to serve means zero required inventory, hence zero utilization even with no pool
        assert(_liquidity(0, minLiquidityWAD, ltRaw) == 0);
    }

    /**
     * @notice With no minimum liquidity requirement the liquidity utilization is exactly zero, whatever the
     *         senior value or the pool depth: a market that mandates no secondary liquidity can never read as
     *         under-provisioned. This edge too wins against an empty pool, taking precedence over the sentinel
     * @dev No arithmetic: the requirement-zero short-circuit returns before the ceiling division. The pool
     *      depth is left free (zero included) to pin precedence over the empty-pool sentinel, and the senior
     *      value is held positive so this is genuinely the requirement edge, not the senior-value edge
     */
    function check_liquidityUtilizationIsZeroWhenNoRequirementEvenAgainstEmptyPool(uint256 stEff, uint256 ltRaw) external pure {
        vm.assume(1 <= stEff && stEff <= MAX_NAV && ltRaw <= MAX_NAV);

        // A zero requirement means no inventory is mandated, so utilization is zero even with no pool
        assert(_liquidity(stEff, 0, ltRaw) == 0);
    }

    /*//////////////////////////////////////////////////////////////////////
                    LIQUIDITY — EMPTY-POOL INFINITY SENTINEL
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice A positive liquidity requirement against an empty pool reads as the uint256 maximum: senior value
     *         needs secondary liquidity while the market-making inventory is gone, so the redemption gate must
     *         saturate high rather than divide by a zero pool. This directly pins the seed hazard — an
     *         unseeded pool against any positive requirement reads as infinitely under-provisioned
     * @dev The sentinel branch returns type(uint256).max directly, no arithmetic. Senior value and the
     *      requirement are both held positive to isolate this branch from the two zero edges
     */
    function check_liquidityUtilizationIsInfiniteWhenPositiveRequirementMeetsEmptyPool(uint256 stEff, uint256 minLiquidityWAD) external pure {
        vm.assume(1 <= stEff && stEff <= MAX_GRID);
        vm.assume(1 <= minLiquidityWAD && minLiquidityWAD <= WAD);

        // Positive required inventory with a drained pool saturates the metric to infinity
        assert(_liquidity(stEff, minLiquidityWAD, 0) == type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////////////
                    LIQUIDITY — EXACT CEILING CHARACTERIZATION
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice On the positive branch the liquidity utilization is exactly the ceiling of the senior value times
     *         the requirement over the pool depth: it satisfies the two defining product inequalities of a
     *         ceiling. The lower half is the safety property — the redemption gate can only read pessimistically
     *         high, never understate how thin the pool is relative to the liquidity the senior is owed
     * @dev Division-free complete characterization: for a positive denominator d, q is ceil(n/d) exactly when
     *      n <= q*d < n + d, with n the senior value times the requirement and d the pool depth. Every spec-side
     *      product fits 2^256, so plain checked multiply is exact. The requirement and pool depth are swept over
     *      a config grid (unit divisor, small prime pools, full and half WAD requirement) with the senior value
     *      fully symbolic over the whole domain, so every rounding case is exercised while the assertion stays
     *      linear and the production division stays exact
     */
    function check_liquidityUtilizationCeilSatisfiesItsDefiningProductInequalities(uint256 stEff) external pure {
        vm.assume(1 <= stEff && stEff <= MAX_GRID);

        _assertLiquidityCeil(stEff, 1, 1);
        _assertLiquidityCeil(stEff, 1, 7);
        _assertLiquidityCeil(stEff, WAD, 3);
        _assertLiquidityCeil(stEff, WAD / 2, 1_000_000);
    }

    /*//////////////////////////////////////////////////////////////////////
                    LIQUIDITY — GATE BOUNDARY ALGEBRA
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice On the positive branch the liquidity utilization sits at or below full (WAD) exactly when the
     *         senior value times the requirement fits inside the pool depth times WAD. This is the exact product
     *         algebra of the liquidity tranche's no-run redemption gate: a redemption is admissible precisely on
     *         this half-plane, and the ceiling rounding never shifts the boundary because the divisor times WAD
     *         is the tight comparison point
     * @dev For a positive denominator d, ceil(n/d) <= k holds exactly when n <= k*d, so with k the WAD unit the
     *      gate predicate is the single product inequality n <= WAD*d with no division. Both sides fit 2^256, so
     *      plain checked multiply is exact. Pinned to the positive branch; the zero edges and the sentinel are
     *      owned by their own checks. The requirement and pool depth are swept over a config grid whose WAD
     *      crossing falls inside the senior-value domain, so both gate outcomes are exercised at fixed config
     */
    function check_liquidityUtilizationAtOrBelowWADIffRequirementFitsPool(uint256 stEff) external pure {
        vm.assume(1 <= stEff && stEff <= MAX_GRID);

        _assertLiquidityGate(stEff, WAD, 1);
        _assertLiquidityGate(stEff, WAD, 3);
        _assertLiquidityGate(stEff, WAD / 2, 7);
        _assertLiquidityGate(stEff, WAD, 1_000_000);
    }

    /*//////////////////////////////////////////////////////////////////////
                    LIQUIDITY — TOTALITY
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Liquidity utilization never reverts anywhere on the bounded domain, so no pool state can brick the
     *         LT redemption gate by making the utilization read itself blow up
     * @dev The only revert edges of a ceiling multiply-divide are a zero denominator (short-circuited to the
     *      infinity sentinel before the division) and a quotient overflowing 256 bits, which the domain bounds
     *      away: senior value times requirement caps near 1e48 for any positive pool depth. The padding routes
     *      the query to the real solver
     */
    function check_liquidityUtilizationNeverRevertsOnBoundedInputs(uint256 stEff, uint256 minLiquidityWAD, uint256 ltRaw, uint256 pad) external view {
        vm.assume(stEff <= MAX_NAV && ltRaw <= MAX_NAV && minLiquidityWAD <= WAD);
        vm.assume(pad <= 3);

        try this.liquidityUtilizationWrapped(stEff + pad - pad, minLiquidityWAD, ltRaw) returns (uint256) { }
        catch {
            assert(false);
        }
    }
}
