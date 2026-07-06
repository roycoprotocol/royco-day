// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { FeeAndLiquidityPremiumLogic } from "../../../src/libraries/logic/FeeAndLiquidityPremiumLogic.sol";
import { ValuationLogic } from "../../../src/libraries/logic/ValuationLogic.sol";
import { RoycoTestMath } from "../../base/math/RoycoTestMath.sol";

/**
 * @title CarveOutFuzz
 * @notice Phase C fuzz properties for the F11 premium/fee carve-out share mints (testing-strategy.md §4.2 row
 *         `_computeSTFeeAndLiquidityPremiumSharesToMint`): the I7 supply identity, exact share equality against
 *         the independent RoycoTestMath mirror, and the I8 two-sided derived mint-value bound on both legs
 * @dev Pure-library layer, no market deploy. The I8 tolerance derivation is the one already validated in
 *      test/unit/accountant/CarveOut.t.sol (_assertI8) and refuted-then-derived in test/scaffold/FuzzExemplar.t.sol
 */
contract CarveOutFuzz is Test {
    /// @notice Suite-wide NAV and share-supply ceiling (testing-strategy.md §4.2 global bounds)
    uint256 internal constant MAX_NAV = 1e30;

    /// @dev Builds the minimal synced state the pure carve-out computation reads (mirrors CarveOut.t.sol)
    function _carveState(uint256 _stEff, uint256 _premium, uint256 _fee) internal pure returns (SyncedAccountingState memory s) {
        s.stEffectiveNAV = toNAVUnits(_stEff);
        s.ltLiquidityPremium = toNAVUnits(_premium);
        s.stProtocolFee = toNAVUnits(_fee);
    }

    /**
     * Property (F11 + I7 fragment, FeeAndLiquidityPremiumLogic:88-104):
     *   supplyAfter == preSupply + premiumShares + feeShares                     [exact supply identity]
     *   (premiumShares, feeShares, supplyAfter) == RoycoTestMath.carveOut(...)   [exact, incl. both F9 edges]
     * The zero-supply first-mint edge is included and additionally pinned 1:1 with the carved NAV values, and
     * the retained == 0 degenerate (premium + fee == stEff) routes through the 1-wei denominator per VL:106
     */
    function testFuzz_CarveOut_sharesMatchMirrorAndSupplyIdentity(uint256 _stEff, uint256 _prem, uint256 _fee, uint256 _preSupply) public pure {
        _stEff = bound(_stEff, 1, MAX_NAV); // positive senior NAV: the carve-out is only reached on gain syncs
        _prem = bound(_prem, 0, _stEff); // waterfall guarantees premium <= stEff, incl. the 0 edge
        _fee = bound(_fee, 0, _stEff - _prem); // waterfall guarantees premium + fee <= stEff, incl. retained == 0
        _preSupply = bound(_preSupply, 0, MAX_NAV); // includes 0 => the first-mint 1:1 branch

        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) =
            FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(_carveState(_stEff, _prem, _fee), _preSupply);

        // I7 fragment: the supply grows by exactly the two carve-out mints
        assertEq(supplyAfter, _preSupply + premiumShares + feeShares, "I7: supply identity");

        // Exact equality with the independent mirror over the entire input space
        (uint256 rtmPrem, uint256 rtmFee, uint256 rtmSupply) = RoycoTestMath.carveOut(_stEff, _prem, _fee, _preSupply);
        assertEq(premiumShares, rtmPrem, "F11: premium shares == RoycoTestMath.carveOut");
        assertEq(feeShares, rtmFee, "F11: fee shares == RoycoTestMath.carveOut");
        assertEq(supplyAfter, rtmSupply, "F11: supply after == RoycoTestMath.carveOut");

        // First-mint edge re-pinned independently of the mirror: both carve-outs mint 1:1 with their NAV values
        if (_preSupply == 0) {
            assertEq(premiumShares, _prem, "F9 edge: zero pre-supply mints the premium 1:1");
            assertEq(feeShares, _fee, "F9 edge: zero pre-supply mints the fee 1:1");
        }
    }

    /**
     * Property (I8 two-sided, testing-strategy §3-I8): at the post-mint senior share rate,
     *   |valueFor(premiumShares, supplyAfter, stEff) - prem| <= 2*ceil(stEff/supplyAfter) + 2
     * and the identical bound for the fee leg.
     *
     * Bound derivation (validated in CarveOut.t.sol _assertI8 and derived-then-fuzz-confirmed in
     * test/scaffold/FuzzExemplar.t.sol after the one-sided `value <= prem` draft was refuted in 28 runs):
     * pShares = S*P/R - a and fShares = S*F/R - b with floor losses a, b in [0, 1) share units (F9), each share
     * worth about stEff/supplyAfter. The a-loss pushes the premium value DOWN (undersized mint), the b-loss
     * pushes it UP (the sibling carve-out's floor dust stays in the pot and accrues pro-rata to ALL post-mint
     * shares including the premium shares), and the final F10 valuation floor loses < 1, so
     * |value - P| < (a + b) * ceil(stEff/supplyAfter) + 1 < 2*ceil(stEff/supplyAfter) + 2.
     *
     * preSupply >= 1 because the derivation prices both legs against pre-existing shares retaining the retained
     * NAV. The zero-supply first-mint edge mints 1:1 and is pinned exactly in the shares property above and in
     * unit vector V2.3. Each leg is asserted whenever its mint is nonzero (a zero mint has p < ceil(R/S), which
     * the shares property already pins exactly via the mirror)
     */
    function testFuzz_CarveOut_I8_twoSidedMintValueBound(uint256 _stEff, uint256 _prem, uint256 _fee, uint256 _preSupply) public pure {
        _stEff = bound(_stEff, 1, MAX_NAV); // positive senior NAV: the carve-out is only reached on gain syncs
        _prem = bound(_prem, 0, _stEff); // waterfall guarantees premium <= stEff, incl. the 0 edge
        _fee = bound(_fee, 0, _stEff - _prem); // waterfall guarantees premium + fee <= stEff, incl. retained == 0
        _preSupply = bound(_preSupply, 1, MAX_NAV); // live market: the I8 derivation requires pre-existing shares (see natspec)

        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) =
            FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(_carveState(_stEff, _prem, _fee), _preSupply);

        // Derived per state, never a literal: 2*ceil(stEff/supplyAfter) + 2 (derivation in the property natspec)
        uint256 i8DerivedBound = 2 * Math.ceilDiv(_stEff, supplyAfter) + 2;

        if (premiumShares != 0) {
            uint256 premValue = toUint256(ValuationLogic._convertToValue(premiumShares, supplyAfter, toNAVUnits(_stEff), Math.Rounding.Floor));
            assertLe(premValue, _prem + i8DerivedBound, "I8: premium value uplift within the derived floor-dust bound");
            assertGe(premValue + i8DerivedBound, _prem, "I8: premium value shortfall within the derived floor-dust bound");
        }
        if (feeShares != 0) {
            uint256 feeValue = toUint256(ValuationLogic._convertToValue(feeShares, supplyAfter, toNAVUnits(_stEff), Math.Rounding.Floor));
            assertLe(feeValue, _fee + i8DerivedBound, "I8: fee value uplift within the derived floor-dust bound");
            assertGe(feeValue + i8DerivedBound, _fee, "I8: fee value shortfall within the derived floor-dust bound");
        }
    }
}
