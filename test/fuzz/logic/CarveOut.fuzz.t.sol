// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { MINT_DILUTION_RESIDUAL_WAD, WAD } from "../../../src/libraries/Constants.sol";
import { SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { FeeAndLiquidityPremiumLogic } from "../../../src/libraries/logic/FeeAndLiquidityPremiumLogic.sol";
import { ValuationLogic } from "../../../src/libraries/logic/ValuationLogic.sol";
import { RoycoTestMath } from "../../base/math/RoycoTestMath.sol";

/**
 * @title CarveOutFuzz
 * @notice Fuzz properties for the post-sync carve-out that pays the LT liquidity premium and the ST
 *         protocol fee by minting new ST shares: the supply identity, exact share-count equality against
 *         the independent RoycoTestMath mirror, and a two-sided derived bound proving the minted shares
 *         are actually worth the NAV that was carved
 * @dev Pure-library layer, no market deploy. The two-sided tolerance derivation below was validated in
 *      test/unit/accountant/CarveOut.t.sol and refuted-then-rederived in test/scaffold/FuzzExemplar.t.sol
 */
contract CarveOutFuzz is Test {
    /// @notice Suite-wide NAV and share-supply ceiling
    uint256 internal constant MAX_NAV = 1e30;

    /// @dev Builds the minimal synced state the pure carve-out computation reads
    function _carveState(uint256 _stEff, uint256 _premium, uint256 _fee) internal pure returns (SyncedAccountingState memory s) {
        s.stEffectiveNAV = toNAVUnits(_stEff);
        s.ltLiquidityPremium = toNAVUnits(_premium);
        s.stProtocolFee = toNAVUnits(_fee);
    }

    /**
     * On a gain sync the accountant mints two batches of ST shares — the LT liquidity premium and the ST
     * protocol fee — sized at the pre-mint supply over the retained NAV (stEff - premium - fee), so plain
     * ST holders fund both carve-outs by dilution and no assets move. A miscount here either shorts the
     * LT/fee recipient or over-dilutes senior. Property (FeeAndLiquidityPremiumLogic.sol:88-104):
     *   supplyAfter == preSupply + premiumShares + feeShares                     [exact supply identity]
     *   (premiumShares, feeShares, supplyAfter) == RoycoTestMath.carveOut(...)   [exact, incl. both edges]
     * The zero-supply first-mint edge is included and additionally pinned 1:1 with the carved NAV values,
     * and the retained == 0 degenerate (premium + fee == stEff) routes through the 1-wei denominator per
     * ValuationLogic.sol:106
     */
    function testFuzz_CarveOut_sharesMatchMirrorAndSupplyIdentity(uint256 _stEff, uint256 _prem, uint256 _fee, uint256 _preSupply) public pure {
        _stEff = bound(_stEff, 1, MAX_NAV); // positive senior NAV: the carve-out is only reached on gain syncs
        _prem = bound(_prem, 0, _stEff); // waterfall guarantees premium <= stEff, incl. the 0 edge
        _fee = bound(_fee, 0, _stEff - _prem); // waterfall guarantees premium + fee <= stEff, incl. retained == 0
        _preSupply = bound(_preSupply, 0, MAX_NAV); // includes 0 => the first-mint 1:1 branch

        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) =
            FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(_carveState(_stEff, _prem, _fee), _preSupply);

        // The supply grows by exactly the two carve-out mints, nothing else
        assertEq(supplyAfter, _preSupply + premiumShares + feeShares, "supply grows by exactly the two mints");

        // Exact equality with the independent mirror over the entire input space (clamped branches included)
        (uint256 rtmPrem, uint256 rtmFee, uint256 rtmSupply) = RoycoTestMath.carveOut(_stEff, _prem, _fee, _preSupply);
        assertEq(premiumShares, rtmPrem, "premium shares == RoycoTestMath.carveOut");
        assertEq(feeShares, rtmFee, "fee shares == RoycoTestMath.carveOut");
        assertEq(supplyAfter, rtmSupply, "supply after == RoycoTestMath.carveOut");

        // First-mint edge re-pinned independently of the mirror: both carve-outs mint 1:1 with their NAV values
        // (the bootstrap mint is exempt from the dilution clamp)
        if (_preSupply == 0) {
            assertEq(premiumShares, _prem, "zero pre-supply mints the premium 1:1");
            assertEq(feeShares, _fee, "zero pre-supply mints the fee 1:1");
        }
    }

    /**
     * The carved share batches must be worth what was carved: valued at the post-mint senior share rate,
     * each batch redeems for its carved NAV to within floor dust, so the LT's premium is neither silently
     * taxed nor silently subsidized by rounding. Property (two-sided, per leg):
     *   |valueFor(premiumShares, supplyAfter, stEff) - prem| <= 2*ceil(stEff/supplyAfter) + 2
     * and the identical bound for the fee leg.
     *
     * Bound derivation (validated in CarveOut.t.sol and derived-then-fuzz-confirmed in
     * test/scaffold/FuzzExemplar.t.sol after a one-sided `value <= prem` draft was refuted in 28 runs):
     * pShares = S*P/R - a and fShares = S*F/R - b with floor losses a, b in [0, 1) share units, each share
     * worth about stEff/supplyAfter. The a-loss pushes the premium value DOWN (undersized mint), the b-loss
     * pushes it UP (the sibling carve-out's floor dust stays in the pot and accrues pro-rata to ALL
     * post-mint shares including the premium shares), and the final valuation floor loses < 1, so
     * |value - P| < (a + b) * ceil(stEff/supplyAfter) + 1 < 2*ceil(stEff/supplyAfter) + 2.
     *
     * preSupply >= 1 because the derivation prices both legs against pre-existing shares retaining the
     * retained NAV. The zero-supply first-mint edge mints 1:1 and is pinned exactly in the shares property
     * above. Each leg is asserted whenever its mint is nonzero (a zero mint has value below one share's
     * worth, which the shares property already pins exactly via the mirror).
     *
     * The I8 value bound is a FAIR-pricing property, so it is conditioned on the mint-dilution clamp
     * (never an early return: every arm carries its own exact assertion):
     *   - a binding leg deliberately mints less than its carved NAV is worth (the clamp's whole point),
     *     so it asserts shares == cap = floor(preSupply * (WAD - eps) / eps) exactly;
     *   - a fair leg whose SIBLING binds cannot use the value bound either — the sibling's under-mint
     *     shrinks supplyAfter, so every post-mint share (including this leg's) is worth more than the
     *     fair derivation assumed — so it asserts its exact floor formula shares == floor(S*leg/denom);
     *   - only when NEITHER leg binds does the two-sided value bound apply, with its original derivation.
     * The bind predicate is recomputed here from first principles at the protocol constant eps =
     * MINT_DILUTION_RESIDUAL_WAD: leg binds iff legNAV * eps > denom * (WAD - eps), with denom the
     * retained NAV pinned to 1 wei when zero (the integer-equivalent form of production's ordering)
     */
    function testFuzz_CarveOut_mintedValueMatchesCarvedNAVWithinDerivedDust(uint256 _stEff, uint256 _prem, uint256 _fee, uint256 _preSupply) public pure {
        _stEff = bound(_stEff, 1, MAX_NAV); // positive senior NAV: the carve-out is only reached on gain syncs
        _prem = bound(_prem, 0, _stEff); // waterfall guarantees premium <= stEff, incl. the 0 edge
        _fee = bound(_fee, 0, _stEff - _prem); // waterfall guarantees premium + fee <= stEff, incl. retained == 0
        _preSupply = bound(_preSupply, 1, MAX_NAV); // live market: the derivation requires pre-existing shares (see comment)

        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) =
            FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(_carveState(_stEff, _prem, _fee), _preSupply);

        // Derived per state, never a literal: 2*ceil(stEff/supplyAfter) + 2 (derivation in the property comment)
        uint256 mintValueDustDerivedBound = 2 * Math.ceilDiv(_stEff, supplyAfter) + 2;

        // The bind predicate per leg, recomputed from first principles (see the property comment)
        uint256 denom = (_stEff - _prem - _fee) == 0 ? 1 : (_stEff - _prem - _fee);
        // No overflow: legNAV, denom <= 1e30 and eps = 1e6, so both products stay below 1e48
        bool premBinds = _prem * MINT_DILUTION_RESIDUAL_WAD > denom * (WAD - MINT_DILUTION_RESIDUAL_WAD);
        bool feeBinds = _fee * MINT_DILUTION_RESIDUAL_WAD > denom * (WAD - MINT_DILUTION_RESIDUAL_WAD);
        // cap <= 1e30 * (1e12 - 1) < 1e43: the fuzz domain sits far below the residual cliff
        uint256 cap = Math.mulDiv(_preSupply, WAD - MINT_DILUTION_RESIDUAL_WAD, MINT_DILUTION_RESIDUAL_WAD);

        if (premiumShares != 0) {
            if (premBinds) {
                assertEq(premiumShares, cap, "a binding premium leg mints exactly the dilution cap");
            } else if (feeBinds) {
                // The sibling's under-mint invalidates the value derivation; the fair floor formula stays exact
                assertEq(
                    premiumShares, Math.mulDiv(_preSupply, _prem, denom, Math.Rounding.Floor), "a fair premium leg beside a binding sibling floors exactly"
                );
            } else {
                uint256 premValue = toUint256(ValuationLogic._convertToValue(premiumShares, supplyAfter, toNAVUnits(_stEff), Math.Rounding.Floor));
                assertLe(premValue, _prem + mintValueDustDerivedBound, "premium value uplift within the derived floor-dust bound");
                assertGe(premValue + mintValueDustDerivedBound, _prem, "premium value shortfall within the derived floor-dust bound");
            }
        }
        if (feeShares != 0) {
            if (feeBinds) {
                assertEq(feeShares, cap, "a binding fee leg mints exactly the dilution cap");
            } else if (premBinds) {
                // The sibling's under-mint invalidates the value derivation; the fair floor formula stays exact
                assertEq(feeShares, Math.mulDiv(_preSupply, _fee, denom, Math.Rounding.Floor), "a fair fee leg beside a binding sibling floors exactly");
            } else {
                uint256 feeValue = toUint256(ValuationLogic._convertToValue(feeShares, supplyAfter, toNAVUnits(_stEff), Math.Rounding.Floor));
                assertLe(feeValue, _fee + mintValueDustDerivedBound, "fee value uplift within the derived floor-dust bound");
                assertGe(feeValue + mintValueDustDerivedBound, _fee, "fee value shortfall within the derived floor-dust bound");
            }
        }
    }
}
