// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { MAX_MINT_DILUTION_WAD, WAD } from "../../../src/libraries/Constants.sol";
import { SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { FeeAndLiquidityPremiumLogic } from "../../../src/libraries/logic/FeeAndLiquidityPremiumLogic.sol";
import { ValuationLogic } from "../../../src/libraries/logic/ValuationLogic.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";

/**
 * @title TestFuzz_FeeAndLiquidityPremium_Logic
 * @notice Fuzz properties for the post-sync fee and liquidity premium share mint
 *         (_computeSTFeeAndLiquidityPremiumSharesToMint), which pays the LT liquidity premium and the ST
 *         protocol fee by minting new ST shares: the supply identity, exact share-count equality against
 *         the independent RoycoTestMath mirror, and a two-sided derived bound proving the minted shares
 *         are actually worth the premium and fee NAV they were minted for
 * @dev Pure-library layer, no market deploy. Every tolerance below is derived in its property comment
 */
contract TestFuzz_FeeAndLiquidityPremium_Logic is Test {
    /// @notice Suite-wide NAV and share-supply ceiling
    uint256 internal constant MAX_NAV = 1e30;

    /// @notice The virtual-shares offset each ST share mint prices against (mirrors src Constants.VIRTUAL_SHARES)
    uint256 internal constant VIRTUAL_SHARES = 1e6;

    /// @dev Builds the minimal synced state the pure share-mint computation reads
    function _syncedState(uint256 _stEff, uint256 _premium, uint256 _fee) internal pure returns (SyncedAccountingState memory s) {
        s.stEffectiveNAV = toNAVUnits(_stEff);
        s.ltLiquidityPremium = toNAVUnits(_premium);
        s.stProtocolFee = toNAVUnits(_fee);
    }

    /**
     * On a gain sync the accountant mints two batches of ST shares — the LT liquidity premium and the ST
     * protocol fee — sized at the pre-mint supply over the retained NAV (stEffectiveNAV - premium - fee), so plain
     * ST holders fund both mints by dilution and no assets move. A miscount here either shorts the
     * LT/fee recipient or over-dilutes senior. Property (FeeAndLiquidityPremiumLogic.sol:88-104):
     *   supplyAfter == preSupply + premiumShares + feeShares                     [exact supply identity]
     *   (premiumShares, feeShares, supplyAfter) == RoycoTestMath.computeSTFeeAndLiquidityPremiumSharesToMint(...)   [exact, incl. both edges]
     * The genuinely-fresh first-mint edge (preSupply == 0 AND retained == 0) is included and additionally pinned
     * 1:1 with the premium and fee NAV values; under the virtual-shares offset preSupply == 0 with positive retained
     * is empty-with-backing and is priced, not 1:1 (ValuationLogic.sol:106)
     */
    function testFuzz_FeeAndLiquidityPremiumShareMint_SharesMatchMirrorAndSupplyIdentity(
        uint256 _stEff,
        uint256 _prem,
        uint256 _fee,
        uint256 _preSupply
    )
        public
        pure
    {
        _stEff = bound(_stEff, 1, MAX_NAV); // positive senior NAV: the mint is only reached on gain syncs
        _prem = bound(_prem, 0, _stEff); // the sync guarantees premium <= stEffectiveNAV, incl. the 0 edge
        _fee = bound(_fee, 0, _stEff - _prem); // the sync guarantees premium + fee <= stEffectiveNAV, incl. retained == 0
        _preSupply = bound(_preSupply, 0, MAX_NAV); // includes 0 => the first-mint 1:1 branch

        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) =
            FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(_syncedState(_stEff, _prem, _fee), _preSupply);

        // The supply grows by exactly the two mints, nothing else
        assertEq(supplyAfter, _preSupply + premiumShares + feeShares, "supply grows by exactly the two mints");

        // Exact equality with the independent mirror over the entire input space (clamped branches included)
        (uint256 rtmPrem, uint256 rtmFee, uint256 rtmSupply) = RoycoTestMath.computeSTFeeAndLiquidityPremiumSharesToMint(_stEff, _prem, _fee, _preSupply);
        assertEq(premiumShares, rtmPrem, "premium shares == RoycoTestMath.computeSTFeeAndLiquidityPremiumSharesToMint");
        assertEq(feeShares, rtmFee, "fee shares == RoycoTestMath.computeSTFeeAndLiquidityPremiumSharesToMint");
        assertEq(supplyAfter, rtmSupply, "supply after == RoycoTestMath.computeSTFeeAndLiquidityPremiumSharesToMint");

        // First-mint edge re-pinned independently of the mirror: a GENUINELY fresh mint (preSupply == 0 AND
        // retained == 0, so both legs hit the supply == 0 && totalValue == 0 branch) mints 1:1 with its NAV. Under
        // the virtual-shares offset a preSupply == 0 with positive retained is empty-with-backing and is priced.
        if (_preSupply == 0 && (_stEff - _prem - _fee) == 0) {
            assertEq(premiumShares, _prem, "genuinely fresh mint mints the premium 1:1");
            assertEq(feeShares, _fee, "genuinely fresh mint mints the fee 1:1");
        }
    }

    /**
     * The minted share batches must be worth what they were minted for: valued at the post-mint senior share
     * rate, each batch redeems for its premium/fee NAV to within floor dust, so the LT's premium is neither
     * silently taxed nor silently subsidized by rounding. Property (two-sided, per leg):
     *   |valueFor(premiumShares, supplyAfter, stEffectiveNAV) - prem| <= 2*ceil(stEffectiveNAV/supplyAfter) + 2
     * and the identical bound for the fee leg.
     *
     * Bound derivation (a one-sided `value <= prem` draft is refutable, the uplift side is real):
     * pShares = floor(S'*P/R') and fShares = floor(S'*F/R') with effective supply S' = preSupply + VIRTUAL_SHARES and
     * denominator R' = retained + VIRTUAL_VALUE, floor losses a, b in [0, 1) share units, each share worth about
     * stEffectiveNAV/supplyAfter. The a-loss pushes the premium value DOWN (undersized mint), the b-loss
     * pushes it UP (the sibling mint's floor dust stays in the pot and accrues pro-rata to ALL
     * post-mint shares including the premium shares), and the final valuation floor loses < 1, so
     * |value - P| < (a + b) * ceil(stEffectiveNAV/supplyAfter) + 1 < 2*ceil(stEffectiveNAV/supplyAfter) + 2.
     *
     * preSupply >= 1 because the derivation prices both legs against pre-existing shares retaining the
     * retained NAV. The zero-supply first-mint edge mints 1:1 and is pinned exactly in the shares property
     * above. Each leg is asserted whenever its mint is nonzero (a zero mint has value below one share's
     * worth, which the shares property already pins exactly via the mirror).
     *
     * The value bound is a FAIR-pricing property, so it is conditioned on the mint-dilution clamp
     * (never an early return: every arm carries its own exact assertion):
     *   - a binding leg deliberately mints less than its NAV is worth (the clamp's whole point), so it asserts
     *     shares == cap = floor((preSupply + VIRTUAL_SHARES) * MAX_MINT_DILUTION_WAD / (WAD - MAX_MINT_DILUTION_WAD)) exactly;
     *   - a fair leg whose SIBLING binds cannot use the value bound either — the sibling's under-mint
     *     shrinks supplyAfter, so every post-mint share (including this leg's) is worth more than the
     *     fair derivation assumed — so it asserts its exact floor formula shares == floor((preSupply + VIRTUAL_SHARES)*leg/denom);
     *   - only when NEITHER leg binds does the two-sided value bound apply, with its original derivation.
     * The bind predicate is recomputed here from first principles at the protocol constant:
     * leg binds iff legNAV * (WAD - MAX_MINT_DILUTION_WAD) > denom * MAX_MINT_DILUTION_WAD, with denom the
     * retained NAV plus VIRTUAL_VALUE (= retained + 1, which also pins it to 1 wei when retained is zero;
     * the integer-equivalent form of production's ordering)
     */
    function testFuzz_FeeAndLiquidityPremiumShareMint_MintedValueMatchesMintedNAVWithinDerivedDust(
        uint256 _stEff,
        uint256 _prem,
        uint256 _fee,
        uint256 _preSupply
    )
        public
        pure
    {
        _stEff = bound(_stEff, 1, MAX_NAV); // positive senior NAV: the mint is only reached on gain syncs
        _prem = bound(_prem, 0, _stEff); // the sync guarantees premium <= stEffectiveNAV, incl. the 0 edge
        _fee = bound(_fee, 0, _stEff - _prem); // the sync guarantees premium + fee <= stEffectiveNAV, incl. retained == 0
        _preSupply = bound(_preSupply, 1, MAX_NAV); // live market: the derivation requires pre-existing shares (see comment)

        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) =
            FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(_syncedState(_stEff, _prem, _fee), _preSupply);

        // Derived per state, never a literal: 2*ceil(stEffectiveNAV/supplyAfter) + 2 (derivation in the property comment)
        uint256 mintValueDustDerivedBound = 2 * Math.ceilDiv(_stEff, supplyAfter) + 2;

        // The bind predicate per leg, recomputed from first principles (see the property comment). Under the
        // virtual-value offset the denominator is retained + VIRTUAL_VALUE (= retained + 1), which also pins it
        // to 1 wei when retained is zero.
        uint256 denom = (_stEff - _prem - _fee) + 1;
        // No overflow: legNAV <= 1e30, denom <= 1e30 + 1 and WAD - MAX_MINT_DILUTION_WAD = 1e6, so both products stay below 1e48
        bool premBinds = _prem * (WAD - MAX_MINT_DILUTION_WAD) > denom * MAX_MINT_DILUTION_WAD;
        bool feeBinds = _fee * (WAD - MAX_MINT_DILUTION_WAD) > denom * MAX_MINT_DILUTION_WAD;
        // Offset-aware cap floor((preSupply + VIRTUAL_SHARES) * MAX / (WAD - MAX)); still < 1e43, far below the overflow cliff
        uint256 cap = Math.mulDiv(_preSupply + VIRTUAL_SHARES, MAX_MINT_DILUTION_WAD, WAD - MAX_MINT_DILUTION_WAD);

        if (premiumShares != 0) {
            if (premBinds) {
                assertEq(premiumShares, cap, "a binding premium leg mints exactly the dilution cap");
            } else if (feeBinds) {
                // The sibling's under-mint invalidates the value derivation; the fair floor formula stays exact
                assertEq(
                    premiumShares,
                    Math.mulDiv(_preSupply + VIRTUAL_SHARES, _prem, denom, Math.Rounding.Floor),
                    "a fair premium leg beside a binding sibling floors exactly"
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
                assertEq(
                    feeShares,
                    Math.mulDiv(_preSupply + VIRTUAL_SHARES, _fee, denom, Math.Rounding.Floor),
                    "a fair fee leg beside a binding sibling floors exactly"
                );
            } else {
                uint256 feeValue = toUint256(ValuationLogic._convertToValue(feeShares, supplyAfter, toNAVUnits(_stEff), Math.Rounding.Floor));
                assertLe(feeValue, _fee + mintValueDustDerivedBound, "fee value uplift within the derived floor-dust bound");
                assertGe(feeValue + mintValueDustDerivedBound, _fee, "fee value shortfall within the derived floor-dust bound");
            }
        }
    }
}
