// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { MAX_MINT_DILUTION_WAD, WAD } from "../../../src/libraries/Constants.sol";
import { toNAVUnits } from "../../../src/libraries/Units.sol";
import { ValuationLogic } from "../../../src/libraries/logic/ValuationLogic.sol";

/**
 * @title TestFuzz_MintDilutionClamp_Logic
 * @notice Fuzz properties for the mint-dilution clamp inside the share-pricing primitive: any single mint may
 *         own at most MAX_MINT_DILUTION_WAD / WAD of the post-mint supply (WAD − 1e6, leaving incumbents a
 *         1e-12 residual EPS). Three properties pin the clamp end to end: the post-mint ownership bound holds
 *         unconditionally, a binding mint returns exactly the cap, and a clamped depositor's value loss is
 *         bounded by the residual times the deposit plus derived floor dust. The non-binding identity (the
 *         clamp leaves fair pricing untouched below the bind) is pinned branch-exactly over the full domain
 *         by testFuzz_ConvertToShares_MatchesMirrorIncludingZeroEdges in TestFuzz_Valuation.t.sol
 * @dev Pure-library layer, no market deploy. Every fuzz range is shaped with bound() and every tolerance is
 *      derived in its property comment, so no assertion hides behind a filtered domain or a magic literal
 */
contract TestFuzz_MintDilutionClamp_Logic is Test {
    /// @notice Suite-wide NAV and share-supply ceiling
    uint256 internal constant MAX_NAV = 1e30;

    /// @dev The incumbent residual (the complement of the protocol's max mint dilution), locally aliased for readability in the derivations below
    uint256 internal constant EPS = WAD - MAX_MINT_DILUTION_WAD;

    /**
     * The clamp's defining guarantee, asserted UNCONDITIONALLY (bind or not, every branch except the exempt
     * bootstrap): the minted shares own at most (1 − EPS/WAD) of the post-mint supply. In product form
     * (exactly equivalent to m <= cap and overflow-safe on this domain since m <= S * (WAD − EPS) / EPS
     * <= 1e30 * (1e12 − 1) < 1e43): m * EPS <= S * (WAD − EPS)
     */
    function testFuzz_Clamp_PostMintOwnershipBound(uint256 _value, uint256 _totalValue, uint256 _supply) public pure {
        _value = bound(_value, 0, MAX_NAV); // uniform over the full NAV range incl. the 0 edge
        _totalValue = bound(_totalValue, 0, MAX_NAV); // includes 0 => the 1-wei dilution branch, the clamp's raison d'etre
        _supply = bound(_supply, 1, MAX_NAV); // live supply: the bootstrap (supply == 0) is exempt by design

        uint256 minted = ValuationLogic._convertToShares(toNAVUnits(_value), toNAVUnits(_totalValue), _supply, Math.Rounding.Floor);
        assertLe(minted * EPS, _supply * (WAD - EPS), "a single mint may own at most (1 - residual) of the post-mint supply");
    }

    /**
     * Above the bind the clamp returns EXACTLY cap = floor(supply * (WAD − EPS) / EPS): the mint plateaus at
     * the residual guarantee. The bind predicate is recomputed here in its integer-equivalent product form
     * (value * EPS > d * (WAD − EPS), both products <= 1e30 * 1e18 so overflow-free), independent of the
     * production ordering
     */
    function testFuzz_Clamp_BindReturnsExactCap(uint256 _value, uint256 _totalValue, uint256 _supply) public pure {
        // Steer into the bind by construction: the bind requires the whole pre-existing tranche to be worth
        // under ~1e-12 of the deposit, so a binding value only exists on the domain when
        // threshold = floor(d * (WAD − EPS) / EPS) < MAX_NAV, i.e. d <= floor((MAX_NAV − 1) * EPS / (WAD − EPS)) ~ 1e18.
        // Bounding d there (instead of vm.assume) keeps every run on the binding region with zero rejections
        uint256 maxBindableTotal = Math.mulDiv(MAX_NAV - 1, EPS, WAD - EPS);
        _totalValue = bound(_totalValue, 0, maxBindableTotal); // includes 0 => the 1-wei dilution branch
        _supply = bound(_supply, 1, MAX_NAV); // live supply
        uint256 d = _totalValue == 0 ? 1 : _totalValue;
        uint256 threshold = Math.mulDiv(d, WAD - EPS, EPS); // < MAX_NAV by the d bound above
        _value = bound(_value, threshold + 1, MAX_NAV); // uniform over the binding region

        uint256 minted = ValuationLogic._convertToShares(toNAVUnits(_value), toNAVUnits(_totalValue), _supply, Math.Rounding.Floor);
        assertEq(minted, Math.mulDiv(_supply, WAD - EPS, EPS), "a binding mint returns exactly the cap");
    }

    /**
     * The economic safety argument for clamp-not-revert semantics: a clamped depositor's loss is bounded by
     * the residual share of its own deposit plus derived floor dust, because the clamp can only bind when the
     * whole pre-existing tranche is worth less than ~EPS * value / (WAD − EPS).
     * Derivation (bind case, cap* = S(WAD−EPS)/EPS exact):
     *   received = floor((T + v) * cap / (S + cap)) with cap = floor(cap*) >= cap* − 1, so
     *   received >= (T + v)(1 − EPS/WAD) − (T + v)/(S + cap) − 1, hence
     *   v − received <= v*EPS/WAD − T(1 − EPS/WAD) + (T + v)/(S + cap) + 1
     *               <= ceil(v*EPS/WAD) + ceil((T + v)/(S + cap)) + 1   =: EPS-share + LOSS_SLACK_DERIVED_BOUND.
     * The no-gain side is exact: bind implies T(WAD − EPS) < v*EPS, so (T + v) * cap/(S + cap)
     * <= (T + v)(1 − EPS/WAD) <= v, and the floors only lower it
     */
    function testFuzz_Clamp_DepositorLossBounded(uint256 _value, uint256 _totalValue, uint256 _supply) public pure {
        // Steer into the bind by construction (the fair-priced region's loss bound is the round-trip property
        // in TestFuzz_Valuation.t.sol): bounding d to the bindable region (see BindReturnsExactCap for the
        // derivation) keeps every run on the binding region with zero rejections
        uint256 maxBindableTotal = Math.mulDiv(MAX_NAV - 1, EPS, WAD - EPS);
        _totalValue = bound(_totalValue, 0, maxBindableTotal); // includes 0 => the 1-wei dilution branch
        _supply = bound(_supply, 1, MAX_NAV); // live supply
        uint256 d = _totalValue == 0 ? 1 : _totalValue;
        uint256 threshold = Math.mulDiv(d, WAD - EPS, EPS); // < MAX_NAV by the d bound above
        _value = bound(_value, threshold + 1, MAX_NAV); // uniform over the binding region

        uint256 minted = ValuationLogic._convertToShares(toNAVUnits(_value), toNAVUnits(_totalValue), _supply, Math.Rounding.Floor);
        // The depositor's claim right after the mint, at the post-mint supply over the post-deposit value
        uint256 received = Math.mulDiv(_totalValue + _value, minted, _supply + minted);

        assertLe(received, _value, "a clamped depositor can never come out ahead");
        uint256 lossSlackDerivedBound = Math.ceilDiv(_totalValue + _value, _supply + minted) + 1;
        assertLe(
            _value - received,
            Math.ceilDiv(_value * EPS, WAD) + lossSlackDerivedBound,
            "clamp loss bounded by the residual share of the deposit plus derived dust"
        );
    }
}
