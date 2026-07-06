// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { MINT_DILUTION_RESIDUAL_WAD, WAD } from "../../../src/libraries/Constants.sol";
import { toNAVUnits } from "../../../src/libraries/Units.sol";
import { ValuationLogic } from "../../../src/libraries/logic/ValuationLogic.sol";

/**
 * @title MintDilutionClampFuzz
 * @notice Fuzz properties for the mint-dilution clamp inside the share-pricing primitive: any single mint may
 *         own at most (1 − ε/WAD) of the post-mint supply, ε = MINT_DILUTION_RESIDUAL_WAD (1e6, a 1e-12
 *         residual). Four properties pin the clamp end to end: the post-mint ownership bound holds
 *         unconditionally, a binding mint returns exactly the cap, a non-binding mint is byte-identical to
 *         the unclamped floor formula, and a clamped depositor's value loss is bounded by the residual times
 *         the deposit plus derived floor dust
 * @dev Pure-library layer, no market deploy. Every bound is derived in its property comment per the
 *      testing-strategy rules (documented bound()s, *_DERIVED_BOUND tolerances, no early returns)
 */
contract MintDilutionClampFuzz is Test {
    /// @notice Suite-wide NAV and share-supply ceiling
    uint256 internal constant MAX_NAV = 1e30;

    /// @dev The protocol residual, locally aliased for readability in the derivations below
    uint256 internal constant EPS = MINT_DILUTION_RESIDUAL_WAD;

    /**
     * The clamp's defining guarantee, asserted UNCONDITIONALLY (bind or not, every branch except the exempt
     * bootstrap): the minted shares own at most (1 − ε/WAD) of the post-mint supply. In product form
     * (exactly equivalent to m <= cap and overflow-safe on this domain since m <= S * (WAD − ε) / ε
     * <= 1e30 * (1e12 − 1) < 1e43): m * ε <= S * (WAD − ε)
     */
    function testFuzz_Clamp_postMintOwnershipBound(uint256 _value, uint256 _totalValue, uint256 _supply) public pure {
        _value = bound(_value, 0, MAX_NAV); // uniform over the full NAV range incl. the 0 edge
        _totalValue = bound(_totalValue, 0, MAX_NAV); // includes 0 => the 1-wei dilution branch, the clamp's raison d'etre
        _supply = bound(_supply, 1, MAX_NAV); // live supply: the bootstrap (supply == 0) is exempt by design

        uint256 minted = ValuationLogic._convertToShares(toNAVUnits(_value), toNAVUnits(_totalValue), _supply, Math.Rounding.Floor);
        assertLe(minted * EPS, _supply * (WAD - EPS), "a single mint may own at most (1 - residual) of the post-mint supply");
    }

    /**
     * Above the bind the clamp returns EXACTLY cap = floor(supply * (WAD − ε) / ε): the mint plateaus at
     * the residual guarantee. The bind predicate is recomputed here in its integer-equivalent product form
     * (value * ε > d * (WAD − ε), both products <= 1e30 * 1e18 so overflow-free), independent of the
     * production ordering
     */
    function testFuzz_Clamp_bindReturnsExactCap(uint256 _value, uint256 _totalValue, uint256 _supply) public pure {
        _totalValue = bound(_totalValue, 0, MAX_NAV); // includes 0 => the 1-wei dilution branch
        _supply = bound(_supply, 1, MAX_NAV); // live supply
        uint256 d = _totalValue == 0 ? 1 : _totalValue;
        // Steer into the bind instead of assuming it away: a representable binding value must exist on the
        // domain, so the pre-existing NAV is bounded to keep threshold + 1 <= MAX_NAV (the bind requires the
        // whole tranche to be worth under ~1e-12 of the deposit, so d < MAX_NAV / (1e12 - 1) ~ 1e18)
        uint256 threshold = Math.mulDiv(d, WAD - EPS, EPS);
        vm.assume(threshold < MAX_NAV); // documented: keeps a binding value representable; excludes only d >~ 1e18
        _value = bound(_value, threshold + 1, MAX_NAV); // uniform over the binding region

        uint256 minted = ValuationLogic._convertToShares(toNAVUnits(_value), toNAVUnits(_totalValue), _supply, Math.Rounding.Floor);
        assertEq(minted, Math.mulDiv(_supply, WAD - EPS, EPS), "a binding mint returns exactly the cap");
    }

    /**
     * At or below the bind the clamp is the identity: the mint equals the unclamped floor formula exactly,
     * so fair pricing is untouched everywhere the residual guarantee is not at stake
     */
    function testFuzz_Clamp_noBindEqualsUnclamped(uint256 _value, uint256 _totalValue, uint256 _supply) public pure {
        _totalValue = bound(_totalValue, 0, MAX_NAV); // includes 0 => the 1-wei dilution branch
        _supply = bound(_supply, 1, MAX_NAV); // live supply
        uint256 d = _totalValue == 0 ? 1 : _totalValue;
        // Bound the value to the no-bind region [0, threshold] (threshold capped to the domain), uniform within it
        uint256 threshold = Math.mulDiv(d, WAD - EPS, EPS);
        _value = bound(_value, 0, threshold < MAX_NAV ? threshold : MAX_NAV);

        uint256 minted = ValuationLogic._convertToShares(toNAVUnits(_value), toNAVUnits(_totalValue), _supply, Math.Rounding.Floor);
        assertEq(minted, Math.mulDiv(_supply, _value, d), "below the bind the clamp is the identity");
    }

    /**
     * The economic safety argument for clamp-not-revert semantics: a clamped depositor's loss is bounded by
     * the residual share of its own deposit plus derived floor dust, because the clamp can only bind when the
     * whole pre-existing tranche is worth less than ~ε * value / (WAD − ε).
     * Derivation (bind case, cap* = S(WAD−ε)/ε exact):
     *   received = floor((T + v) * cap / (S + cap)) with cap = floor(cap*) >= cap* − 1, so
     *   received >= (T + v)(1 − ε/WAD) − (T + v)/(S + cap) − 1, hence
     *   v − received <= v*ε/WAD − T(1 − ε/WAD) + (T + v)/(S + cap) + 1
     *               <= ceil(v*ε/WAD) + ceil((T + v)/(S + cap)) + 1   =: ε-share + LOSS_SLACK_DERIVED_BOUND.
     * The no-gain side is exact: bind implies T(WAD − ε) < v*ε, so (T + v) * cap/(S + cap)
     * <= (T + v)(1 − ε/WAD) <= v, and the floors only lower it
     */
    function testFuzz_Clamp_depositorLossBounded(uint256 _value, uint256 _totalValue, uint256 _supply) public pure {
        _totalValue = bound(_totalValue, 0, MAX_NAV); // includes 0 => the 1-wei dilution branch
        _supply = bound(_supply, 1, MAX_NAV); // live supply
        uint256 d = _totalValue == 0 ? 1 : _totalValue;
        // Steer into the bind (the fair-priced region's loss bound is the round-trip property in Valuation.fuzz)
        uint256 threshold = Math.mulDiv(d, WAD - EPS, EPS);
        vm.assume(threshold < MAX_NAV); // documented: keeps a binding value representable; excludes only d >~ 1e18
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
