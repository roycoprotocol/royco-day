// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { ZERO_NAV_UNITS } from "../../src/libraries/Constants.sol";
import { MarketState, SyncedAccountingState } from "../../src/libraries/Types.sol";
import { toNAVUnits } from "../../src/libraries/Units.sol";
import { FeeAndLiquidityPremiumLogic } from "../../src/libraries/logic/FeeAndLiquidityPremiumLogic.sol";

/**
 * @title UnitExemplar (SCAFFOLD) — demonstrates the golden-vector assertion standard.
 *
 * Standard demonstrated:
 *  1. Expected values are hand-derived in a comment, with the rounding direction stated at each step.
 *  2. Assertions are exact (assertEq). Where a tolerance is unavoidable it must be a *derived* bound
 *     with the derivation in a comment — never a literal like 1e12.
 *  3. No call to the contract under test appears on the expected side of any assertion.
 *
 * Target: F11 — the ST fee / liquidity-premium carve-out
 *         (FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint,
 *          src/libraries/logic/FeeAndLiquidityPremiumLogic.sol:88-104).
 */
contract UnitExemplar is Test {
    /// Vector 1 — clean division (no rounding anywhere).
    ///
    /// Inputs:  stEffectiveNAV = 1_050e18, ltLiquidityPremium = 30e18, stProtocolFee = 20e18,
    ///          pre-sync ST supply = 1_000e18.
    /// Derivation (all divisions exact here):
    ///   retained            = 1_050e18 - 30e18 - 20e18 = 1_000e18        (exact subtraction; the
    ///                         waterfall guarantees premium + fee <= stEff, :97-98)
    ///   premiumShares       = floor(1_000e18 * 30e18 / 1_000e18) = 30e18 (Floor, favors existing ST)
    ///   feeShares           = floor(1_000e18 * 20e18 / 1_000e18) = 20e18 (Floor)
    ///   supplyAfter         = 1_000e18 + 30e18 + 20e18 = 1_050e18
    /// Post-check: value of premium shares at the post-mint rate
    ///   = floor(1_050e18 * 30e18 / 1_050e18) = 30e18 == ltLiquidityPremium exactly.
    function test_CarveOut_cleanDivision() public pure {
        SyncedAccountingState memory s = _state(1050e18, 30e18, 20e18);

        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) = FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(s, 1000e18);

        assertEq(premiumShares, 30e18, "premium shares: hand-derived 30e18");
        assertEq(feeShares, 20e18, "fee shares: hand-derived 20e18");
        assertEq(supplyAfter, 1050e18, "supply after both mints");
    }

    /// Vector 2 — floor rounding engaged; asserts exact floored values AND the derived value-loss bound.
    ///
    /// Inputs:  stEffectiveNAV = 10, premium = 3, fee = 2, pre-sync supply = 3 (wei-scale on purpose:
    ///          rounding effects are maximal and hand-checkable).
    /// Derivation:
    ///   retained      = 10 - 3 - 2 = 5
    ///   premiumShares = floor(3 * 3 / 5) = floor(9/5)  = 1   (Floor: dust stays with existing ST)
    ///   feeShares     = floor(3 * 2 / 5) = floor(6/5)  = 1   (Floor)
    ///   supplyAfter   = 3 + 1 + 1 = 5
    /// Derived bound for the premium's realized value (invariant I8, docs/testing-strategy.md §3; two-sided,
    /// see FuzzExemplar for the derivation and the fuzz refutation of the one-sided version):
    ///   value(premiumShares) = floor(stEff * shares / supplyAfter) = floor(10 * 1 / 5) = 2
    ///   epsilon = 2 * ceil(stEff / supplyAfter) + 2 = 2 * ceil(10/5) + 2 = 6
    ///   Require: |value - premium| = |2 - 3| = 1 <= 6. Exact asserts below.
    function test_CarveOut_floorRounding_boundDerived() public pure {
        SyncedAccountingState memory s = _state(10, 3, 2);

        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) = FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(s, 3);

        assertEq(premiumShares, 1, "floor(9/5)");
        assertEq(feeShares, 1, "floor(6/5)");
        assertEq(supplyAfter, 5, "3 + 1 + 1");

        // Realized value of the carve-out at the post-mint rate: exact, hand-derived.
        uint256 premiumValue = (10 * premiumShares) / supplyAfter;
        assertEq(premiumValue, 2, "floor(10*1/5)");
        // And the derived two-sided bound holds (this is what the fuzz layer generalizes; the literal 6
        // is 2*ceil(stEff/supplyAfter) + 2 derived above — not an arbitrary tolerance).
        uint256 EPSILON_DERIVED_BOUND = 6;
        assertLe(3 - premiumValue, EPSILON_DERIVED_BOUND, "sizing loss within derived floor-dust bound");
        assertLe(premiumValue, 3 + EPSILON_DERIVED_BOUND, "fee-dust uplift within derived floor-dust bound");
    }

    function _state(uint256 _stEff, uint256 _prem, uint256 _fee) private pure returns (SyncedAccountingState memory s) {
        s.marketState = MarketState.PERPETUAL;
        s.stEffectiveNAV = toNAVUnits(_stEff);
        s.ltLiquidityPremium = toNAVUnits(_prem);
        s.stProtocolFee = toNAVUnits(_fee);
        // remaining fields irrelevant to F11; left at zero deliberately
        s.jtProtocolFee = ZERO_NAV_UNITS;
    }
}
