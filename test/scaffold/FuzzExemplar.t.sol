// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { MarketState, SyncedAccountingState } from "../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../src/libraries/Units.sol";
import { FeeAndLiquidityPremiumLogic } from "../../src/libraries/logic/FeeAndLiquidityPremiumLogic.sol";
import { UtilizationLogic } from "../../src/libraries/logic/UtilizationLogic.sol";

/**
 * @title FuzzExemplar (SCAFFOLD) — demonstrates the fuzz-property standard.
 *
 * Standard demonstrated:
 *  1. The property is an EQUATION (or a derived-bound inequality), stated in the natspec, not "should work".
 *  2. Inputs are shaped with bound() only, each bound carrying a comment stating the induced
 *     distribution. No `if (...) return;`, no vm.assume input-space collapse.
 *  3. The expected side is computed independently (inline mulDiv here; RoycoTestMath in the real suite)
 *     — never by re-calling the function under test.
 */
contract FuzzExemplar is Test {
    uint256 private constant WAD = 1e18;
    uint256 private constant MAX_NAV = 1e30; // suite-wide NAV ceiling (docs/testing-strategy.md §4.2)

    /// Property (F8 + ceil bias, docs/testing-strategy.md §1.3):
    ///   liqU == ceil(stEff * minLiq / ltRaw)                          [exact equation vs independent math]
    ///   and the ceil bias direction:  liqU * ltRaw >= stEff * minLiq  [senior-favoring rounding]
    /// Zero-edges pinned exactly: stEff==0 or minLiq==0 => 0; ltRaw==0 => type(uint256).max.
    function testFuzz_LiquidityUtilization_exactCeil(uint256 _stEff, uint256 _minLiq, uint256 _ltRaw) public pure {
        _stEff = bound(_stEff, 0, MAX_NAV); // uniform over the full supported NAV range incl. 0 edge
        _minLiq = bound(_minLiq, 0, WAD - 1); // config invariant: minLiquidityWAD < WAD (RoycoDayAccountant.sol:87)
        _ltRaw = bound(_ltRaw, 0, MAX_NAV); // includes 0 edge => infinite-utilization branch

        uint256 got = UtilizationLogic._computeLiquidityUtilization(toNAVUnits(_stEff), _minLiq, toNAVUnits(_ltRaw));

        if (_stEff == 0 || _minLiq == 0) {
            assertEq(got, 0, "zero edge: no senior value or no requirement");
        } else if (_ltRaw == 0) {
            assertEq(got, type(uint256).max, "zero depth vs positive requirement is infinite");
        } else {
            // Independent expected value: OZ mulDiv Ceil, same formula, different code path than the lib's
            // NAV_UNIT-typed wrapper chain.
            assertEq(got, Math.mulDiv(_stEff, _minLiq, _ltRaw, Math.Rounding.Ceil), "liqU == ceil(stEff*minLiq/ltRaw)");
            // Rounding-direction bias (mulDiv cannot overflow the check: got <= MAX_NAV * WAD / 1 fits 256 bits
            // because stEff, minLiq <= 1e30, 1e18 => product <= 1e48).
            assertGe(got * _ltRaw, _stEff * _minLiq, "ceil bias favors senior");
        }
    }

    /// Property (F11 / invariants I7+I8, docs/testing-strategy.md §3):
    ///   supplyAfter == supply + premiumShares + feeShares                        [exact]
    ///   |value(premiumShares @ post-mint rate) - premium| <= eps,
    ///     eps = 2 * ceil(stEff / supplyAfter) + 2                                [derived, TWO-SIDED]
    ///
    ///   Bound derivation: pShares = S*P/R - a, fShares = S*F/R - b with floor losses a,b in [0,1)
    ///   share-units (F9), each share worth ~stEff/supplyAfter. The a-loss pushes value DOWN (premium
    ///   shares undersized); the b-loss pushes value UP (fee dust stays in the pot and accrues pro-rata
    ///   to ALL post-mint shares, including the premium shares). Final valuation floor (F10) loses < 1.
    ///   So |value - P| < (a + b) * ceil(stEff/supplyAfter) + 1 < 2*ceil(stEff/supplyAfter) + 2.
    ///
    ///   NOTE: the first draft of this property asserted the one-sided `value <= premium` — the fuzzer
    ///   refuted it in 28 runs (fee-dust uplift). Kept here as a worked example of why tolerance bounds
    ///   must be DERIVED and fuzz-validated, never assumed.
    function testFuzz_CarveOut_valueBoundsAndJointPricing(uint256 _stEff, uint256 _prem, uint256 _fee, uint256 _supply) public pure {
        _stEff = bound(_stEff, 1, MAX_NAV); // positive senior NAV: the carve-out is only reached on gain syncs
        _prem = bound(_prem, 0, _stEff); // waterfall guarantees premium <= stEff (RoycoDayAccountant.sol:624,646)
        _fee = bound(_fee, 0, _stEff - _prem); // and premium + fee <= stEff (FeeAndLiquidityPremiumLogic.sol:97)
        _supply = bound(_supply, 1, MAX_NAV); // live market: supply > 0 (first-mint path is a separate unit vector)

        SyncedAccountingState memory s;
        s.marketState = MarketState.PERPETUAL;
        s.stEffectiveNAV = toNAVUnits(_stEff);
        s.ltLiquidityPremium = toNAVUnits(_prem);
        s.stProtocolFee = toNAVUnits(_fee);

        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) = FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(s, _supply);

        // I7 fragment: supply identity, exact.
        assertEq(supplyAfter, _supply + premiumShares + feeShares, "supply identity");

        // Independent expected shares: floor over the retained denominator (zero-NAV denominator branch pins
        // to 1 wei) clamped per mint by the dilution cap (MINT_DILUTION_RESIDUAL_WAD = 1e6, a 1e-12 residual;
        // ValuationLogic._convertToShares) — both reproduced independently here. The bind predicate is the
        // integer-equivalent product form legNAV * eps > denom * (WAD - eps); products fit (<= 1e30 * 1e18).
        uint256 retained = _stEff - _prem - _fee;
        uint256 denom = retained == 0 ? 1 : retained;
        bool premBinds = _prem * 1e6 > denom * (WAD - 1e6);
        bool feeBinds = _fee * 1e6 > denom * (WAD - 1e6);
        uint256 cap = Math.mulDiv(_supply, WAD - 1e6, 1e6);
        assertEq(
            premiumShares,
            premBinds ? cap : Math.mulDiv(_supply, _prem, denom, Math.Rounding.Floor),
            "premium shares floored over retained NAV, capped at the dilution clamp"
        );
        assertEq(
            feeShares,
            feeBinds ? cap : Math.mulDiv(_supply, _fee, denom, Math.Rounding.Floor),
            "fee shares floored over retained NAV, capped at the dilution clamp"
        );

        // I8: realized premium value within the derived two-sided floor-dust bound. A FAIR-pricing property:
        // it only holds when NEITHER leg binds the clamp (a binding leg deliberately mints less than its
        // carved NAV, and a binding sibling shrinks supplyAfter so this leg's value inflates) — the binding
        // arms are pinned exactly by the share equalities above, so nothing is silently skipped.
        if (premiumShares != 0 && !premBinds && !feeBinds) {
            uint256 value = Math.mulDiv(_stEff, premiumShares, supplyAfter, Math.Rounding.Floor);
            uint256 epsDerived = 2 * ((_stEff + supplyAfter - 1) / supplyAfter) + 2; // 2*ceil(stEff/supplyAfter) + 2
            assertLe(value, _prem + epsDerived, "fee-dust uplift bounded by derived floor dust");
            assertGe(value + epsDerived, _prem, "sizing loss bounded by derived floor dust");
        }
    }
}
