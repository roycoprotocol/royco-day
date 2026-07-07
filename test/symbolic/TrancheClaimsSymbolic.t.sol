// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { AssetClaims } from "../../src/libraries/Types.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../src/libraries/Units.sol";
import { TrancheClaimsExposer } from "../mocks/TrancheClaimsExposer.sol";

/**
 * @title TrancheClaimsSymbolicSpec
 * @notice Native symbolic specs for the kernel's pure tranche-claim math: the proportional scaling of a
 *         tranche's cumulative asset claims by redeemed shares over total shares (five floored pro-rata legs
 *         sharing one denominator), and the decomposition of the senior and junior effective NAVs into
 *         self-backed and cross-tranche claims on the raw NAVs. The load-bearing properties: every scaled leg
 *         is the exact floored pro-rata slice, scaling by shares within the supply never inflates a claim (the
 *         underflow shield for the checked ledger debits on withdrawal), splitting a redemption in two shorts
 *         the redeemers by at most one wei per leg and never over-pays, more shares never scale to less, the
 *         scaling reverts exactly when the tranche has zero total shares, and the claims decomposition
 *         partitions both raw and both effective NAVs with at most one nonzero cross-tranche claim, never
 *         reverting on any NAV-conserving state and reverting precisely when a cross-tranche claim exceeds
 *         the raw NAV that would have to back it
 * @dev Run with `forge test --symbolic --match-path test/symbolic/TrancheClaimsSymbolic.t.sol`. Functions
 *      prefixed check_ are discovered only under --symbolic. Domain: NAV legs and share counts up to 1e30
 *      (one trillion whole 18-decimal tokens, beyond any underwritable market) for the division-shaped scaling
 *      checks, and near-unbounded values for the fully linear decomposition checks. Every expected value is
 *      derived independently: floors as two-sided product brackets (q*T <= x*s < (q+1)*T) or bounds stated
 *      purely on outputs, never by re-running the production mulDiv as its own expectation. All products on
 *      the spec side cap near 1e60, far below 2^256, so plain checked arithmetic is exact
 */
contract TrancheClaimsSymbolicSpec is Test {
    /// @dev Suite-wide NAV domain bound: 1e30 NAV wei
    uint256 internal constant MAX_NAV = 1e30;

    /// @dev Suite-wide share supply domain bound
    uint256 internal constant MAX_SHARES = 1e30;

    TrancheClaimsExposer internal exposer;

    function setUp() public {
        exposer = new TrancheClaimsExposer();
    }

    /// @dev Builds a claims struct from raw values: the five legs a tranche redemption pays out
    function _claims(
        uint256 _nav,
        uint256 _stAssets,
        uint256 _jtAssets,
        uint256 _ltAssets,
        uint256 _stShares
    )
        internal
        pure
        returns (AssetClaims memory claims)
    {
        claims.nav = toNAVUnits(_nav);
        claims.stAssets = toTrancheUnits(_stAssets);
        claims.jtAssets = toTrancheUnits(_jtAssets);
        claims.ltAssets = toTrancheUnits(_ltAssets);
        claims.stShares = _stShares;
    }

    /// @dev Two-sided floor bracket, stated without any spec-side division: q == floor(x*s/T) iff
    ///      q*T <= x*s < (q+1)*T. Products cap at ~1e60 on this suite's domain so checked multiply is exact
    function _assertIsFlooredSlice(uint256 _q, uint256 _x, uint256 _s, uint256 _t) internal pure {
        assert(_q * _t <= _x * _s);
        assert(_x * _s < (_q + 1) * _t);
    }

    /*//////////////////////////////////////////////////////////////////////
                    SCALING IS AN EXACT FLOORED PRO-RATA SLICE
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Scaling a tranche's claims by shares over total shares pays each of the five legs (total NAV,
     *         ST assets, JT assets, LT assets, and ST shares) exactly floor(leg * shares / totalShares): the
     *         redeemer's slice of every asset is the floored pro-rata cut, so any rounding dust stays behind
     *         with the holders who remain in the tranche, never with the party leaving
     * @dev Expected form is the two-sided product bracket per leg, q*T <= x*s < (q+1)*T, with no division on
     *      the spec side at all. All five legs run the same floored multiply-divide against the one shared
     *      denominator, so proving each leg's bracket pins the whole function's arithmetic
     */
    function check_scaledClaimsAreExactFlooredProRataSlicesOnEveryLeg(
        uint256 nav,
        uint256 stAssets,
        uint256 jtAssets,
        uint256 ltAssets,
        uint256 stShares,
        uint256 shares,
        uint256 totalShares
    )
        external
        view
    {
        vm.assume(nav <= MAX_NAV && stAssets <= MAX_NAV && jtAssets <= MAX_NAV && ltAssets <= MAX_NAV && stShares <= MAX_SHARES);
        vm.assume(1 <= totalShares && totalShares <= MAX_SHARES);
        vm.assume(shares <= MAX_SHARES);

        AssetClaims memory scaled = exposer.scaleAssetClaims(_claims(nav, stAssets, jtAssets, ltAssets, stShares), shares, totalShares);

        // Why flooring on every leg: a redemption must never hand out more value than the shares burned
        // represent, so each leg rounds against the redeemer and the wei-level dust accretes to the tranche
        _assertIsFlooredSlice(toUint256(scaled.nav), nav, shares, totalShares);
        _assertIsFlooredSlice(toUint256(scaled.stAssets), stAssets, shares, totalShares);
        _assertIsFlooredSlice(toUint256(scaled.jtAssets), jtAssets, shares, totalShares);
        _assertIsFlooredSlice(toUint256(scaled.ltAssets), ltAssets, shares, totalShares);
        _assertIsFlooredSlice(scaled.stShares, stShares, shares, totalShares);
    }

    /*//////////////////////////////////////////////////////////////////////
                    SCALING WITHIN THE SUPPLY NEVER INFLATES
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice When the shares being redeemed do not exceed the tranche's total shares, no scaled leg exceeds
     *         the tranche's cumulative claim on that leg. This is the underflow shield for the withdrawal
     *         path: the kernel debits each scaled leg from its per-tranche asset ledger with a checked
     *         subtraction, and the ledger holds exactly the cumulative claims, so a scaled leg exceeding the
     *         cumulative leg would brick every redemption with an arithmetic panic
     * @dev Derivation, independent of the production path: the scaled leg is the floor of leg * s / T, and
     *      s <= T makes the true quotient at most leg * T / T == leg, so the floor is at most leg. Tight at
     *      s == T, where the last redeemer takes the entire ledger exactly to zero
     */
    function check_scalingBySharesWithinSupplyNeverInflatesAnyClaim(
        uint256 nav,
        uint256 stAssets,
        uint256 jtAssets,
        uint256 ltAssets,
        uint256 stShares,
        uint256 shares,
        uint256 totalShares
    )
        external
        view
    {
        vm.assume(nav <= MAX_NAV && stAssets <= MAX_NAV && jtAssets <= MAX_NAV && ltAssets <= MAX_NAV && stShares <= MAX_SHARES);
        vm.assume(1 <= totalShares && totalShares <= MAX_SHARES);
        // A real redemption can burn at most the whole supply
        vm.assume(shares <= totalShares);

        AssetClaims memory scaled = exposer.scaleAssetClaims(_claims(nav, stAssets, jtAssets, ltAssets, stShares), shares, totalShares);

        // No leg is ever inflated past the cumulative claim backing it, so every downstream checked ledger
        // debit lands at or above zero
        assert(toUint256(scaled.nav) <= nav);
        assert(toUint256(scaled.stAssets) <= stAssets);
        assert(toUint256(scaled.jtAssets) <= jtAssets);
        assert(toUint256(scaled.ltAssets) <= ltAssets);
        assert(scaled.stShares <= stShares);
    }

    /*//////////////////////////////////////////////////////////////////////
                    SPLIT REDEMPTION FLOORING DRIFT
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Redeeming the same total in two separate share batches never pays more than one combined
     *         redemption would, and at most one wei less per leg: the flooring drift always shorts the
     *         redeemers, so splitting a withdrawal can never extract extra value from the holders who stay,
     *         and the tranche silently keeps at most one wei of dust per leg per split
     * @dev Floor superadditivity stated purely on the production outputs, floor(a) + floor(b) <= floor(a+b)
     *      <= floor(a) + floor(b) + 1, with no spec-side division. All five legs run the identical floored
     *      multiply-divide on independent values against the one shared denominator, so the total-NAV leg is
     *      representative and the other four legs are held at zero to keep the query tractable. The padding
     *      input routes the query past the engine's built-in arithmetic heuristic (which cannot conclude on
     *      division-shaped queries) to the real SMT solver
     */
    function check_splittingARedemptionShortsTheRedeemersByAtMostOneWei(
        uint256 nav,
        uint256 sharesA,
        uint256 sharesB,
        uint256 totalShares,
        uint256 p1
    )
        external
        view
    {
        vm.assume(nav <= MAX_NAV);
        vm.assume(1 <= totalShares && totalShares <= MAX_SHARES);
        // Two disjoint share batches out of one live supply
        vm.assume(sharesA <= totalShares && sharesB <= totalShares - sharesA);
        vm.assume(p1 <= 3);

        AssetClaims memory claims = _claims(nav, 0, 0, 0, 0);
        uint256 sliceA = toUint256(exposer.scaleAssetClaims(claims, sharesA, totalShares).nav) + p1 - p1;
        uint256 sliceB = toUint256(exposer.scaleAssetClaims(claims, sharesB, totalShares).nav);
        uint256 whole = toUint256(exposer.scaleAssetClaims(claims, sharesA + sharesB, totalShares).nav);

        // Two floors can only under-pay against the combined floor, and by at most one wei together: the
        // split is never a way to over-draw the tranche, and the loss to splitting is bounded at dust
        assert(sliceA + sliceB <= whole);
        assert(whole - (sliceA + sliceB) <= 1);
    }

    /*//////////////////////////////////////////////////////////////////////
                    MONOTONICITY IN THE SHARES REDEEMED
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice For a fixed claims state and a fixed total supply, redeeming more shares never returns less of
     *         any leg: every scaled leg is non-decreasing in the shares redeemed. Without this ordering a
     *         redeemer could be paid strictly more by burning strictly fewer shares, which would invert the
     *         pro-rata economics of the tranche and make partial exits gameable
     * @dev Two floored multiply-divides per leg over the same denominator with ordered numerators: the true
     *      quotients are ordered, and flooring preserves a non-strict order. Stated purely on the two
     *      production outputs with no spec-side arithmetic beyond the comparison
     */
    function check_scaledClaimsAreMonotoneInSharesRedeemed(
        uint256 nav,
        uint256 stAssets,
        uint256 jtAssets,
        uint256 ltAssets,
        uint256 stShares,
        uint256 sharesA,
        uint256 sharesB,
        uint256 totalShares
    )
        external
        view
    {
        vm.assume(nav <= MAX_NAV && stAssets <= MAX_NAV && jtAssets <= MAX_NAV && ltAssets <= MAX_NAV && stShares <= MAX_SHARES);
        vm.assume(1 <= totalShares && totalShares <= MAX_SHARES);
        vm.assume(sharesA <= sharesB && sharesB <= MAX_SHARES);

        AssetClaims memory claims = _claims(nav, stAssets, jtAssets, ltAssets, stShares);
        AssetClaims memory scaledA = exposer.scaleAssetClaims(claims, sharesA, totalShares);
        AssetClaims memory scaledB = exposer.scaleAssetClaims(claims, sharesB, totalShares);

        // Burning at least as many shares always pays at least as much of every leg
        assert(toUint256(scaledA.nav) <= toUint256(scaledB.nav));
        assert(toUint256(scaledA.stAssets) <= toUint256(scaledB.stAssets));
        assert(toUint256(scaledA.jtAssets) <= toUint256(scaledB.jtAssets));
        assert(toUint256(scaledA.ltAssets) <= toUint256(scaledB.ltAssets));
        assert(scaledA.stShares <= scaledB.stShares);
    }

    /*//////////////////////////////////////////////////////////////////////
                    SCALING REVERTS EXACTLY ON A ZERO TOTAL SUPPLY
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Scaling against a zero total share supply always reverts, even when every claim leg and the
     *         share count are zero: the shared denominator makes the very first leg's multiply-divide panic
     *         on division by zero before any numerator is inspected. An empty tranche therefore cannot price
     *         a redemption at all — callers must guard the empty-tranche case themselves, because the math
     *         will panic rather than return zero claims for it
     * @dev This pins the panic surface of previewing a redemption against an empty tranche: the revert is an
     *      arithmetic panic from the shared division, not a custom error, and it fires on zero numerators too
     */
    function check_scalingAlwaysRevertsOnZeroTotalSharesEvenWithZeroClaims(
        uint256 nav,
        uint256 stAssets,
        uint256 jtAssets,
        uint256 ltAssets,
        uint256 stShares,
        uint256 shares
    )
        external
        view
    {
        vm.assume(nav <= MAX_NAV && stAssets <= MAX_NAV && jtAssets <= MAX_NAV && ltAssets <= MAX_NAV && stShares <= MAX_SHARES);
        vm.assume(shares <= MAX_SHARES);

        try exposer.scaleAssetClaims(_claims(nav, stAssets, jtAssets, ltAssets, stShares), shares, 0) returns (AssetClaims memory) {
            // A zero denominator must never produce a priced redemption
            assert(false);
        } catch {
            // Division by the zero total supply panics on the first leg, zero numerators included
        }
    }

    /**
     * @notice With at least one share outstanding the scaling is total on the physical domain: any claim legs
     *         and any share count up to the domain bound scale without reverting, so a live tranche can always
     *         price a redemption preview
     * @dev The only revert edges in a floored multiply-divide are a zero denominator (excluded here, owned by
     *      the zero-supply check above) and a quotient overflowing 256 bits, which the domain bounds away:
     *      every leg-times-shares product caps near 1e60, far below 2^256, for any positive denominator. The
     *      total supply is deliberately left unbounded above since a larger denominator only shrinks quotients
     */
    function check_scalingNeverRevertsWhileAnyShareIsOutstanding(
        uint256 nav,
        uint256 stAssets,
        uint256 jtAssets,
        uint256 ltAssets,
        uint256 stShares,
        uint256 shares,
        uint256 totalShares
    )
        external
        view
    {
        vm.assume(nav <= MAX_NAV && stAssets <= MAX_NAV && jtAssets <= MAX_NAV && ltAssets <= MAX_NAV && stShares <= MAX_SHARES);
        vm.assume(shares <= MAX_SHARES);
        vm.assume(totalShares >= 1);

        try exposer.scaleAssetClaims(_claims(nav, stAssets, jtAssets, ltAssets, stShares), shares, totalShares) returns (AssetClaims memory) {
            // Total on the whole live-tranche domain: every redemption preview can always be priced
        } catch {
            assert(false);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                    CLAIMS DECOMPOSITION PARTITIONS BOTH NAV PAIRS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice On any NAV-conserving state (the sum of the raw NAVs equals the sum of the effective NAVs,
     *         which every committed checkpoint enforces), the four claims exactly partition both sides of the
     *         books: the two claims on the senior raw NAV sum to the senior raw NAV, the two claims on the
     *         junior raw NAV sum to the junior raw NAV, the senior tranche's two claims sum to its effective
     *         NAV, and the junior tranche's two claims sum to its effective NAV. Every wei of held assets is
     *         owed to exactly one tranche, and every wei of entitlement is backed by exactly one pool
     * @dev Fully linear (two saturating subtractions and two checked subtractions), so the domain runs
     *      near-unbounded: each raw NAV below 2^254 keeps the conserved total below 2^255 with no spec-side
     *      overflow. The junior effective NAV is derived from conservation rather than assumed, which encodes
     *      the same constraint with one fewer free symbol
     */
    function check_claimsDecompositionPartitionsBothRawAndEffectiveNAVs(uint256 stRaw, uint256 jtRaw, uint256 stEff) external view {
        vm.assume(stRaw < 2 ** 254 && jtRaw < 2 ** 254);
        // Conservation: the effective NAVs re-slice the same conserved total the raw NAVs hold
        uint256 total = stRaw + jtRaw;
        vm.assume(stEff <= total);
        uint256 jtEff = total - stEff;

        (uint256 stClaimOnST, uint256 stClaimOnJT, uint256 jtClaimOnST, uint256 jtClaimOnJT) =
            exposer.computeSTandJTClaimsOnRawNAVs(stRaw, jtRaw, stEff, jtEff);

        // Why the double partition matters: a redemption sources each tranche's payout from these claims, so
        // an unpartitioned wei would be either unowned raw NAV (mintable for free) or unbacked entitlement
        assert(stClaimOnST + jtClaimOnST == stRaw);
        assert(stClaimOnJT + jtClaimOnJT == jtRaw);
        assert(stClaimOnST + stClaimOnJT == stEff);
        assert(jtClaimOnST + jtClaimOnJT == jtEff);
    }

    /*//////////////////////////////////////////////////////////////////////
                    AT MOST ONE CROSS-TRANCHE CLAIM
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice On any NAV-conserving state at most one cross-tranche claim is nonzero: the senior tranche
     *         holding a claim on junior assets and the junior tranche holding a claim on senior assets cannot
     *         coexist. Coverage moves entitlement in one direction at a time — if seniors are owed junior
     *         assets then juniors are fully backed by their own pool, and vice versa
     * @dev Derivation from conservation: the senior cross claim is positive only when the senior effective
     *      NAV exceeds the senior raw NAV, which under a conserved total forces the junior effective NAV
     *      below the junior raw NAV, zeroing the junior cross claim by saturation (and symmetrically). Fully
     *      linear, near-unbounded domain
     */
    function check_claimsDecompositionHasAtMostOneCrossTrancheClaim(uint256 stRaw, uint256 jtRaw, uint256 stEff) external view {
        vm.assume(stRaw < 2 ** 254 && jtRaw < 2 ** 254);
        uint256 total = stRaw + jtRaw;
        vm.assume(stEff <= total);
        uint256 jtEff = total - stEff;

        (, uint256 stClaimOnJT, uint256 jtClaimOnST,) = exposer.computeSTandJTClaimsOnRawNAVs(stRaw, jtRaw, stEff, jtEff);

        // Two simultaneous cross claims would mean both tranches are underbacked by their own pools at once,
        // which a conserved total makes impossible
        assert(stClaimOnJT == 0 || jtClaimOnST == 0);
    }

    /*//////////////////////////////////////////////////////////////////////
                    CONSERVATION MAKES THE DECOMPOSITION TOTAL
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The claims decomposition never reverts on any NAV-conserving state: the two checked
     *         subtractions that compute the self-backed portions cannot underflow when the raw and effective
     *         totals match. The decomposition runs inside every deposit, redemption, and claim derivation, so
     *         a revert here on a committed checkpoint would brick the entire market's asset flow
     * @dev Derivation: under conservation the junior cross claim equals the senior raw NAV minus the senior
     *      effective NAV whenever positive, so it never exceeds the senior raw NAV, and symmetrically for the
     *      senior cross claim against the junior raw NAV. Both checked subtractions are therefore safe on
     *      every state the accountant can ever commit
     */
    function check_claimsDecompositionNeverRevertsUnderConservation(uint256 stRaw, uint256 jtRaw, uint256 stEff) external view {
        vm.assume(stRaw < 2 ** 254 && jtRaw < 2 ** 254);
        uint256 total = stRaw + jtRaw;
        vm.assume(stEff <= total);
        uint256 jtEff = total - stEff;

        try exposer.computeSTandJTClaimsOnRawNAVs(stRaw, jtRaw, stEff, jtEff) returns (uint256, uint256, uint256, uint256) {
            // Total on every conserved state: the market's asset flow can always decompose its books
        } catch {
            assert(false);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                    EXACT REVERT CHARACTERIZATION WITHOUT CONSERVATION
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Without any conservation assumption, the decomposition succeeds whenever each cross-tranche
     *         claim fits inside the raw NAV that backs it, and on success the four outputs match their
     *         defining forms exactly: each cross claim is the saturated excess of a tranche's effective NAV
     *         over its own raw NAV, and each self-backed portion is the raw NAV net of the other tranche's
     *         cross claim
     * @dev The success half of the exact revert characterization. Expected cross claims are derived as plain
     *      guarded ternaries (the saturated difference written out), never by re-running the production
     *      saturating helper. Fully linear on the full uint256 domain
     */
    function check_claimsDecompositionSucceedsAndMatchesSaturatedFormsWhenCrossClaimsFit(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 stEff,
        uint256 jtEff
    )
        external
        view
    {
        // The saturated cross claims, derived independently: the entitlement each tranche holds beyond its own pool
        uint256 expectedSTCross = stEff > stRaw ? stEff - stRaw : 0;
        uint256 expectedJTCross = jtEff > jtRaw ? jtEff - jtRaw : 0;
        // The non-revert region: each cross claim fits the other tranche's raw NAV
        vm.assume(expectedJTCross <= stRaw && expectedSTCross <= jtRaw);

        try exposer.computeSTandJTClaimsOnRawNAVs(stRaw, jtRaw, stEff, jtEff) returns (
            uint256 stClaimOnST, uint256 stClaimOnJT, uint256 jtClaimOnST, uint256 jtClaimOnJT
        ) {
            // Each output is exactly its defining form: saturated excess for the cross claims, the raw NAV
            // net of the other side's cross claim for the self-backed portions
            assert(stClaimOnJT == expectedSTCross);
            assert(jtClaimOnST == expectedJTCross);
            assert(stClaimOnST == stRaw - expectedJTCross);
            assert(jtClaimOnJT == jtRaw - expectedSTCross);
        } catch {
            assert(false);
        }
    }

    /**
     * @notice Without any conservation assumption, the decomposition reverts whenever the junior tranche's
     *         cross claim exceeds the senior raw NAV that would have to back it: the checked subtraction
     *         computing the senior self-backed portion underflows. Such a state means more junior entitlement
     *         points at the senior pool than the pool holds, which conservation makes uncommittable — the
     *         panic is a defensive guard on unreachable books, not a user-facing error path
     * @dev The revert is an arithmetic underflow panic, not a custom error, which is deliberate for a state
     *      the accountant can never commit. Fully linear on the full uint256 domain
     */
    function check_claimsDecompositionRevertsWhenJuniorCrossClaimExceedsSeniorRawNAV(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 stEff,
        uint256 jtEff
    )
        external
        view
    {
        // Pin the first underflow site: junior entitlement beyond its own pool exceeds the whole senior pool
        vm.assume(jtEff > jtRaw);
        vm.assume(jtEff - jtRaw > stRaw);

        try exposer.computeSTandJTClaimsOnRawNAVs(stRaw, jtRaw, stEff, jtEff) returns (uint256, uint256, uint256, uint256) {
            // Unbacked junior entitlement must never decompose into claims a redemption could pay out
            assert(false);
        } catch {
            // The senior self-backed subtraction underflows: the defensive panic on non-conserving books
        }
    }

    /**
     * @notice Without any conservation assumption, the decomposition reverts whenever the senior tranche's
     *         cross claim exceeds the junior raw NAV that would have to back it (and the junior cross claim
     *         still fits, isolating this revert site): the checked subtraction computing the junior
     *         self-backed portion underflows. More senior entitlement points at the junior pool than the pool
     *         holds — again a state conservation makes uncommittable, guarded by a defensive panic
     * @dev The junior-cross-claim revert cause is excluded so this check pins the second underflow site
     *      specifically, keeping one pinned branch per check. Fully linear on the full uint256 domain
     */
    function check_claimsDecompositionRevertsWhenSeniorCrossClaimExceedsJuniorRawNAV(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 stEff,
        uint256 jtEff
    )
        external
        view
    {
        // Pin the second underflow site: senior entitlement beyond its own pool exceeds the whole junior pool
        vm.assume(stEff > stRaw);
        vm.assume(stEff - stRaw > jtRaw);
        // ... with the junior cross claim still fitting, so the earlier subtraction passes and this site fires
        vm.assume(jtEff <= jtRaw || jtEff - jtRaw <= stRaw);

        try exposer.computeSTandJTClaimsOnRawNAVs(stRaw, jtRaw, stEff, jtEff) returns (uint256, uint256, uint256, uint256) {
            // Unbacked senior entitlement must never decompose into claims a redemption could pay out
            assert(false);
        } catch {
            // The junior self-backed subtraction underflows: the defensive panic on non-conserving books
        }
    }
}
