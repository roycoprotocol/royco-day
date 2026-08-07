// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { MAX_MINT_DILUTION_WAD, WAD } from "../../../src/libraries/Constants.sol";
import { toNAVUnits } from "../../../src/libraries/Units.sol";
import { ValuationLogic } from "../../../src/libraries/logic/ValuationLogic.sol";

/**
 * @title TestFuzz_MintDilutionClamp_Logic
 * @notice Fuzz properties for the mint-dilution clamp inside the share-pricing primitive. The clamp arms ONLY
 *         in the collapsed-price regime — one effective share backed by under EPS/WAD = 1e-12 NAV, the state a
 *         supply-inflation attack needs — and there returns min(cap, fair), so an armed mint owns at most
 *         MAX_MINT_DILUTION_WAD / WAD of the post-mint effective supply while a mint into a healthily priced
 *         tranche always prices fairly, however large. Three properties pin the clamp end to end: the armed
 *         ownership bound (with the healthy regime pinned to exact fair pricing), a binding mint returns
 *         exactly the cap, and a clamped depositor's value loss is bounded by the residual times the deposit
 *         plus derived floor dust. The non-arming identity is also pinned branch-exactly over the full domain
 *         by testFuzz_ConvertToShares_MatchesMirrorIncludingZeroEdges in TestFuzz_Valuation.t.sol
 * @dev Pure-library layer, no market deploy. Every fuzz range is shaped with bound() and every tolerance is
 *      derived in its property comment, so no assertion hides behind a filtered domain or a magic literal
 */
contract TestFuzz_MintDilutionClamp_Logic is Test {
    /// @notice Suite-wide NAV and share-supply ceiling
    uint256 internal constant MAX_NAV = 1e30;

    /// @dev The incumbent residual (the complement of the protocol's max mint dilution), locally aliased for readability in the derivations below
    uint256 internal constant EPS = WAD - MAX_MINT_DILUTION_WAD;

    /// @dev Virtual shares / virtual value, restated inline (see Constants.sol VIRTUAL_SHARES / VIRTUAL_VALUE).
    ///      The clamp caps and prices against the EFFECTIVE supply (S + VS) over (T + VA)
    uint256 internal constant VS = 1;
    uint256 internal constant VA = 1;

    /**
     * The clamp's defining guarantee, branch-exact over the full live domain. The arm predicate is recomputed
     * inline in its integer-equivalent product form ((S + VS) * EPS > (T + VA) * (WAD − EPS), both sides
     * <= ~1e31 * 1e18 so overflow-free), matching production's ceil((S + VS) * EPS / (WAD − EPS)) > T + VA:
     *   armed (collapsed price, one effective share backed by < EPS/WAD NAV) => the minted shares own at most
     *     (1 − EPS/WAD) of the post-mint EFFECTIVE supply. In product form (exactly equivalent to m <= cap and
     *     overflow-safe since an armed m <= cap <= ~1e31 * (1e12 − 1) < 1e44): m * EPS <= (S + VS) * (WAD − EPS)
     *   healthy (not armed) => the clamp must not touch the price at all: m == floor((S + VS) * v / (T + VA))
     *     exactly, even when the depositor ends up owning nearly the whole post-mint supply — fair pricing means
     *     the ownership is paid for, so it is not dilution and is deliberately not capped
     */
    function testFuzz_Clamp_PostMintOwnershipBound(uint256 _value, uint256 _totalValue, uint256 _supply) public pure {
        _value = bound(_value, 0, MAX_NAV); // uniform over the full NAV range incl. the 0 edge
        _totalValue = bound(_totalValue, 0, MAX_NAV); // includes 0 => the 1-wei dilution branch, the clamp's raison d'etre
        _supply = bound(_supply, 1, MAX_NAV); // live supply: the bootstrap (supply == 0) is exempt by design

        uint256 minted = ValuationLogic._convertToShares(toNAVUnits(_value), toNAVUnits(_totalValue), _supply, Math.Rounding.Floor);
        if ((_supply + VS) * EPS > (_totalValue + VA) * (WAD - EPS)) {
            assertLe(minted * EPS, (_supply + VS) * (WAD - EPS), "an armed mint may own at most (1 - residual) of the post-mint supply");
        } else {
            assertEq(
                minted,
                Math.mulDiv(_supply + VS, _value, _totalValue + VA, Math.Rounding.Floor),
                "a healthily priced mint is never touched by the clamp"
            );
        }
    }

    /**
     * A binding mint returns EXACTLY cap = floor((supply + VS) * (WAD − EPS) / EPS): the mint plateaus at the
     * residual guarantee. Binding requires BOTH arm conditions, each recomputed here in its integer-equivalent
     * product form independent of the production ordering:
     *   armed:  (S + VS) * EPS > d * (WAD − EPS), the collapsed-price regime that computes the cap at all
     *   fair >= cap: value * EPS > d * (WAD − EPS), so min(cap, fair) resolves to the cap (integer lemma:
     *     v * EPS > d * (WAD − EPS) implies (S + VS) * v / d > cap exactly as integers)
     * Both are steered by construction below (all products <= ~1e31 * 1e18, overflow-free)
     */
    function testFuzz_Clamp_BindReturnsExactCap(uint256 _value, uint256 _totalValue, uint256 _supply) public pure {
        // Steer into the bind by construction: binding requires the whole pre-existing tranche backing to be
        // worth under ~1e-12 of BOTH the effective supply (the arm) and the deposit (the plateau), so a binding
        // pair only exists on the domain when threshold = floor(d * (WAD − EPS) / EPS) < MAX_NAV,
        // i.e. d <= floor((MAX_NAV − 1) * EPS / (WAD − EPS)) ~ 1e18.
        // Bounding d there (instead of vm.assume) keeps every run on the binding region with zero rejections
        uint256 maxBindableTotal = Math.mulDiv(MAX_NAV - 1, EPS, WAD - EPS) - VA;
        _totalValue = bound(_totalValue, 0, maxBindableTotal); // includes 0 => the 1-wei dilution branch
        uint256 d = _totalValue + VA;
        uint256 threshold = Math.mulDiv(d, WAD - EPS, EPS); // < MAX_NAV by the d bound above
        // The arm in supply form: (S + VS) * EPS > d * (WAD − EPS) iff S + VS > threshold iff S >= threshold + 1 - VS
        // (threshold is exact: (WAD − EPS) / EPS = 1e12 − 1 divides out with no remainder)
        _supply = bound(_supply, threshold + 1 - VS, MAX_NAV); // uniform over the armed (collapsed-price) region
        _value = bound(_value, threshold + 1, MAX_NAV); // uniform over the plateau region (fair >= cap)

        uint256 minted = ValuationLogic._convertToShares(toNAVUnits(_value), toNAVUnits(_totalValue), _supply, Math.Rounding.Floor);
        assertEq(minted, Math.mulDiv(_supply + VS, WAD - EPS, EPS), "a binding mint returns exactly the cap");
    }

    /**
     * The economic safety argument for clamp-not-revert semantics: a clamped depositor's loss is bounded by
     * the residual share of its own deposit plus derived floor dust, because the clamp can only bind when the
     * whole pre-existing tranche is worth less than ~EPS * value / (WAD − EPS).
     * Derivation (bind case, with effective amounts T' = T + VA, S' = S + VS and cap* = S'(WAD−EPS)/EPS exact):
     *   received = floor((T' + v) * cap / (S' + cap)) with cap = floor(cap*) >= cap* − 1, so
     *   received >= (T' + v)(1 − EPS/WAD) − (T' + v)/(S' + cap) − 1, hence
     *   v − received <= v*EPS/WAD − T'(1 − EPS/WAD) + (T' + v)/(S' + cap) + 1
     *               <= ceil(v*EPS/WAD) + ceil((T' + v)/(S' + cap)) + 1   =: EPS-share + LOSS_SLACK_DERIVED_BOUND.
     * The no-gain side is exact: bind implies T'(WAD − EPS) < v*EPS, so (T' + v) * cap/(S' + cap)
     * <= (T' + v)(1 − EPS/WAD) <= v, and the floors only lower it
     */
    function testFuzz_Clamp_DepositorLossBounded(uint256 _value, uint256 _totalValue, uint256 _supply) public pure {
        // Steer into the bind by construction (the fair-priced region's loss bound is the round-trip property
        // in TestFuzz_Valuation.t.sol): bounding d to the bindable region and the supply to the armed
        // (collapsed-price) region (see BindReturnsExactCap for both derivations) keeps every run on the
        // binding region with zero rejections
        uint256 maxBindableTotal = Math.mulDiv(MAX_NAV - 1, EPS, WAD - EPS) - VA;
        _totalValue = bound(_totalValue, 0, maxBindableTotal); // includes 0 => the 1-wei dilution branch
        uint256 d = _totalValue + VA;
        uint256 threshold = Math.mulDiv(d, WAD - EPS, EPS); // < MAX_NAV by the d bound above
        _supply = bound(_supply, threshold + 1 - VS, MAX_NAV); // uniform over the armed (collapsed-price) region
        _value = bound(_value, threshold + 1, MAX_NAV); // uniform over the plateau region (fair >= cap)

        uint256 minted = ValuationLogic._convertToShares(toNAVUnits(_value), toNAVUnits(_totalValue), _supply, Math.Rounding.Floor);
        // The depositor's claim right after the mint, at the post-mint supply over the post-deposit value
        uint256 received = Math.mulDiv(_totalValue + VA + _value, minted, _supply + VS + minted);

        assertLe(received, _value, "a clamped depositor can never come out ahead");
        uint256 lossSlackDerivedBound = Math.ceilDiv(_totalValue + VA + _value, _supply + VS + minted) + 1;
        assertLe(
            _value - received,
            Math.ceilDiv(_value * EPS, WAD) + lossSlackDerivedBound,
            "clamp loss bounded by the residual share of the deposit plus derived dust"
        );
    }
}
