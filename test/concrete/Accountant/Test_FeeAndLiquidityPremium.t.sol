// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { Operation, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { FeeAndLiquidityPremiumLogic } from "../../../src/libraries/logic/FeeAndLiquidityPremiumLogic.sol";
import { ValuationLogic } from "../../../src/libraries/logic/ValuationLogic.sol";
import { FeeAndLiquidityPremiumHarness } from "../../mocks/FeeAndLiquidityPremiumHarness.sol";
import { AccountantTestBase } from "../../utils/AccountantTestBase.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";

/**
 * @title Test_FeeAndLiquidityPremium_Accountant
 * @notice Hand-derived scenarios for the sync-time share mint: the premium/fee share mints priced over the retained
 *         senior NAV, the coverage-neutral premium mint through the orchestrator, the two-sided mint-value
 *         bound, and the LPT effective NAV edges
 * @dev Every vector hand-derives its expected values in a comment and cross-asserts the matching independent
 *      RoycoTestMath function, so production, mirror, and hand literal must all three agree
 */
contract Test_FeeAndLiquidityPremium_Accountant is AccountantTestBase {
    uint256 internal constant WAD = 1e18;

    FeeAndLiquidityPremiumHarness internal flp;

    function setUp() public {
        _deploy(_defaultParams());
        flp = new FeeAndLiquidityPremiumHarness();
    }

    /// @dev Builds the minimal synced state the pure share mint computation reads
    function _mintState(uint256 _stEff, uint256 _premium, uint256 _fee) internal pure returns (SyncedAccountingState memory s) {
        s.stEffectiveNAV = toNAVUnits(_stEff);
        s.lptLiquidityPremium = toNAVUnits(_premium);
        s.stProtocolFee = toNAVUnits(_fee);
    }

    /*//////////////////////////////////////////////////////////////////////
                        PURE CARVE-OUT VECTORS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * Nominal share mint at realistic post-sync outputs (FeeAndLiquidityPremiumLogic.sol:79-99): the premium
     * and fee mints price jointly against the retained senior NAV, never against each other. At the default
     * residual eps = 1e6 the mint-dilution clamp is provably inert here (bind iff 2.5e18 * 1e6 > (1038.25e18+1) *
     * (1e18 - 1e6), i.e. 2.5e24 > ~1.038e39, false for both legs), so neither leg clamps.
     * Virtual-shares offset: each leg mints floor((preSupply+1e6) * legNAV / (retained+1)).
     * retained = 1045e18 - 2.5e18 - 4.25e18 = 1038.25e18 (shared denominator, joint pricing)
     * premShares = floor((1000e18+1e6) * 2.5e18 / (1038.25e18+1))  = 2_407_897_905_128_824_945
     * feeShares  = floor((1000e18+1e6) * 4.25e18 / (1038.25e18+1)) = 4_093_426_438_719_002_407
     * supplyAfter = 1000e18 + premShares + feeShares               = 1_006_501_324_343_847_827_352
     * Joint pricing: both mints divide by the SAME retained NAV at the SAME pre-sync supply, so the fee mint
     * does not dilute the premium mint — pinned by the counterfactual below where the fee is pre-already deducted from
     * the effective NAV instead (stEffectiveNAV' = stEffectiveNAV - fee, fee 0, identical retained denominator, identical shares)
     */
    function test_STFeeAndLiquidityPremiumShareMint_NominalJointPricing() public pure {
        (uint256 premShares, uint256 feeShares, uint256 supplyAfter) =
            FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(_mintState(1045e18, 2.5e18, 4.25e18), 1000e18);
        assertEq(premShares, 2_407_897_905_128_824_945, "premium shares floor over the retained denominator");
        assertEq(feeShares, 4_093_426_438_719_002_407, "fee shares floor over the same retained denominator");
        assertEq(supplyAfter, 1_006_501_324_343_847_827_352, "supply after both mints");

        // RoycoTestMath cross-assert (the computeSTFeeAndLiquidityPremiumSharesToMint mirror)
        (uint256 rtmPrem, uint256 rtmFee, uint256 rtmSupply) = RoycoTestMath.computeSTFeeAndLiquidityPremiumSharesToMint(1045e18, 2.5e18, 4.25e18, 1000e18);
        assertEq(premShares, rtmPrem, "RTM premium shares");
        assertEq(feeShares, rtmFee, "RTM fee shares");
        assertEq(supplyAfter, rtmSupply, "RTM supply after");

        // Counterfactual: minting the premium with the fee absent but already already deducted from stEffectiveNAV leaves the
        // premium mint byte-identical, so the fee share mint provably does not dilute the premium value retained senior
        (uint256 premSharesNoFee,,) = FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(_mintState(1040.75e18, 2.5e18, 0), 1000e18);
        assertEq(premSharesNoFee, premShares, "fee mint does not dilute the premium mint");
    }

    /**
     * Degenerate premium + fee == stEffectiveNAV (100% of the sync's senior effective NAV minted out as premium and fee, e.g. maximal
     * fees on a pure-gain sync from zero retained base) routes through the share-mint math's 1-wei
     * denominator branch (ValuationLogic.sol:114, FeeAndLiquidityPremiumLogic.sol:94-97), and at the default residual
     * eps = 1e6 both legs BIND the mint-dilution clamp instead of minting unbounded shares.
     * retained = 10e18 - 4e18 - 6e18 = 0 -> the 1-wei denominator branch, and both legs bind:
     *   bind: ceil(4e18 * 1e6 / (1e18 - 1e6)) = ceil(~4.000004e6) > 1 (and likewise for the fee leg)
     *   cap  = floor((1e18+1e6) * (1e18 - 1e6) / 1e6) = 999_999_999_999_999_999_999_999_000_000
     * premShares = feeShares = cap (each mint may own at most (1 - 1e-12) of the post-mint EFFECTIVE supply)
     * supplyAfter = 1e18 + 2 * cap = 2_000_000_000_000_999_999_999_998_000_000
     * The pre-existing 1e18 shares retain ~1e-12 of the tranche per mint — the intended near-total dilution
     * of unbacked holders, now bounded so repeated wipe cycles cannot race the supply to uint256
     */
    function test_STFeeAndLiquidityPremiumShareMint_DegenerateFullNAVMint_ClampsBothLegs() public pure {
        (uint256 premShares, uint256 feeShares, uint256 supplyAfter) =
            FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(_mintState(10e18, 4e18, 6e18), 1e18);
        assertEq(premShares, 999_999_999_999_999_999_999_999_000_000, "premium shares clamp to the dilution cap");
        assertEq(feeShares, 999_999_999_999_999_999_999_999_000_000, "fee shares clamp to the same dilution cap");
        assertEq(supplyAfter, 2_000_000_000_000_999_999_999_998_000_000, "supply after the two capped mints");

        (uint256 rtmPrem, uint256 rtmFee, uint256 rtmSupply) = RoycoTestMath.computeSTFeeAndLiquidityPremiumSharesToMint(10e18, 4e18, 6e18, 1e18);
        assertEq(premShares, rtmPrem, "RTM premium shares");
        assertEq(feeShares, rtmFee, "RTM fee shares");
        assertEq(supplyAfter, rtmSupply, "RTM supply after");
    }

    /**
     * Zero pre-sync supply with a NONZERO retained backing is the "empty but backed" state the virtual-shares
     * mitigation deliberately does NOT mint 1:1 (ValuationLogic.sol:109-122): the fresh-tranche exemption fires
     * only when supply == 0 AND totalValue == 0, but here retained = 1038.25e18 > 0 (a premium/fee staged against
     * an empty senior supply), so each leg falls through to the priced branch and captures the staged backing at
     * the virtual-share floor 1e6 over (retained+1) instead of handing it out one-for-one.
     * premShares = floor((0+1e6) * 2.5e18 / (1038.25e18+1))  = 2407
     * feeShares  = floor((0+1e6) * 4.25e18 / (1038.25e18+1)) = 4093
     * supplyAfter = 0 + premShares + feeShares               = 6500
     */
    function test_STFeeAndLiquidityPremiumShareMint_ZeroPreSupplyEmptyBackedDoesNotMintOneToOne() public pure {
        // Empty-but-backed (supply 0, retained > 0) is NOT the fresh exemption: the priced branch applies the offset
        (uint256 premShares, uint256 feeShares, uint256 supplyAfter) =
            FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(_mintState(1045e18, 2.5e18, 4.25e18), 0);
        assertEq(premShares, 2407, "empty-but-backed premium mint prices at the virtual-share floor, not 1:1");
        assertEq(feeShares, 4093, "empty-but-backed fee mint prices at the virtual-share floor, not 1:1");
        assertEq(supplyAfter, 6500, "supply after the two virtual-share-scaled mints");

        (uint256 rtmPrem, uint256 rtmFee, uint256 rtmSupply) = RoycoTestMath.computeSTFeeAndLiquidityPremiumSharesToMint(1045e18, 2.5e18, 4.25e18, 0);
        assertEq(premShares, rtmPrem, "RTM premium shares");
        assertEq(feeShares, rtmFee, "RTM fee shares");
        assertEq(supplyAfter, rtmSupply, "RTM supply after");
    }

    /*//////////////////////////////////////////////////////////////////////
                COVERAGE-NEUTRAL MINT THROUGH THE ORCHESTRATOR
    //////////////////////////////////////////////////////////////////////*/

    /**
     * A sync with zero premium and zero fees performs NO mint calls on any tranche
     * (FeeAndLiquidityPremiumLogic.sol:49-58), leaves the senior supply and the idle liquidity premium senior shares
     * untouched, and never attempts a reinvestment — the quiet path must be a true no-op
     */
    function test_ProcessFeesAndLiquidityPremium_ZeroPremiumAndFees_NoMintCalls() public {
        flp.ST_LEDGER().setTotalSupply(1000e18);
        flp.setLPTOwnedSeniorTrancheShares(5e18);
        SyncedAccountingState memory s = _mintState(1045e18, 0, 0);

        flp.processFeesAndLiquidityPremium(s);

        assertEq(flp.ST_LEDGER().premiumMintCallCount(), 0, "no premium mint");
        assertEq(flp.ST_LEDGER().feeMintCallCount(), 0, "no senior fee mint");
        assertEq(flp.JT_LEDGER().feeMintCallCount(), 0, "no junior fee mint");
        assertEq(flp.LPT_LEDGER().feeMintCallCount(), 0, "no liquidity fee mint");
        assertEq(flp.ST_LEDGER().totalSupply(), 1000e18, "senior supply unchanged");
        assertEq(flp.lptOwnedSeniorTrancheShares(), 5e18, "idle liquidity premium senior shares unchanged");
        assertEq(flp.reinvestCallCount(), 0, "no reinvestment attempt on a zero premium");
    }

    /**
     * The coverage-neutral premium mint invariant. Across _processFeesAndLiquidityPremium with the nominal
     * joint-pricing inputs above and a slippage-deferred reinvestment (drain 0):
     * - delta totalCollateralAssets == 0 (no collateral assets enter or leave, so the collateral NAV and coverageUtilization cannot move)
     * - delta ST supply == premShares + feeShares = 2_407_897_905_128_824_945 + 4_093_426_438_719_002_407
     * - delta idle premium share balance == premShares - reinvested = premShares - 0
     * - the reinvestment attempt is called once with (uint256 max, stEffectiveNAV, post-mint supply) so the idle premium senior shares
     *   are valued at the synced senior share rate
     * The premium mint lands on the kernel (played by the FeeAndLiquidityPremiumHarness mock) and the fee mint on the protocol fee recipient.
     * Run at the default residual 1e6: coverage neutrality holds under the clamp (the mint still moves no assets and the supply
     * delta is exactly the two share mints), and at these nominal inputs the clamp is inert (see the nominal joint-pricing scenario), so the
     * literals are the historical ones
     */
    function test_ProcessFeesAndLiquidityPremium_CoverageNeutralMint_IdlesWhenReinvestmentDefers() public {
        flp.ST_LEDGER().setTotalSupply(1000e18);
        flp.setTotalCollateralAssets(1000e18);
        flp.setLPTOwnedSeniorTrancheShares(5e18);
        flp.setReinvestSharesToDrain(0);
        SyncedAccountingState memory s = _mintState(1045e18, 2.5e18, 4.25e18);

        flp.processFeesAndLiquidityPremium(s);

        // Coverage neutrality: the mint reassigns share ownership only, so every coverageUtilization input is untouched
        assertEq(flp.totalCollateralAssets(), 1000e18, "collateral assets unchanged by the mint");
        // Supply delta is exactly the two share mints
        assertEq(flp.ST_LEDGER().totalSupply(), 1_006_501_324_343_847_827_352, "supply grows by premShares + feeShares");
        assertEq(flp.ST_LEDGER().premiumMintCallCount(), 1, "one premium mint");
        assertEq(flp.ST_LEDGER().lastPremiumSharesMinted(), 2_407_897_905_128_824_945, "premium share count");
        assertEq(flp.ST_LEDGER().lastPremiumMintTo(), address(flp), "premium shares mint to the kernel");
        assertEq(flp.ST_LEDGER().feeMintCallCount(), 1, "one senior fee mint");
        assertEq(flp.ST_LEDGER().lastFeeSharesMinted(), 4_093_426_438_719_002_407, "fee share count");
        assertEq(flp.ST_LEDGER().lastFeeMintTo(), flp.PROTOCOL_FEE_RECIPIENT(), "fee shares mint to the recipient");
        // Idle pile delta == premShares - reinvested (reinvested == 0 on the deferred path)
        assertEq(flp.lptOwnedSeniorTrancheShares(), 5e18 + 2_407_897_905_128_824_945, "idle premium share balance grows by exactly the premium shares");
        // Reinvestment attempt args pin the post-mint valuation basis
        assertEq(flp.reinvestCallCount(), 1, "one reinvestment attempt");
        assertEq(flp.lastReinvestSharesArg(), type(uint256).max, "attempts to deploy the entire idle premium share balance");
        assertEq(toUint256(flp.lastReinvestSTEffectiveNAVArg()), 1045e18, "valued at the synced senior effective NAV");
        assertEq(flp.lastReinvestTotalSTSharesArg(), 1_006_501_324_343_847_827_352, "valued at the post-mint supply");

        // RTM cross-assert of the two share counts driving the deltas
        (uint256 rtmPrem, uint256 rtmFee,) = RoycoTestMath.computeSTFeeAndLiquidityPremiumSharesToMint(1045e18, 2.5e18, 4.25e18, 1000e18);
        assertEq(flp.ST_LEDGER().lastPremiumSharesMinted(), rtmPrem, "RTM premium shares");
        assertEq(flp.ST_LEDGER().lastFeeSharesMinted(), rtmFee, "RTM fee shares");
    }

    /**
     * The partial-reinvestment arm of the coverage-neutral mint: with the stub draining 1e18 shares inside
     * the reinvestment attempt, the idle premium share balance lands at pre + premShares - drained
     * = 5e18 + 2_407_897_905_128_824_945 - 1e18, so a partial deploy never strands or double-counts shares
     */
    function test_ProcessFeesAndLiquidityPremium_PartialReinvestmentDrainsIdlePremiumShares() public {
        flp.ST_LEDGER().setTotalSupply(1000e18);
        flp.setLPTOwnedSeniorTrancheShares(5e18);
        flp.setReinvestSharesToDrain(1e18);
        SyncedAccountingState memory s = _mintState(1045e18, 2.5e18, 4.25e18);

        flp.processFeesAndLiquidityPremium(s);

        assertEq(flp.lptOwnedSeniorTrancheShares(), 5e18 + 2_407_897_905_128_824_945 - 1e18, "idle delta == premShares - reinvested");
    }

    /*//////////////////////////////////////////////////////////////////////
                        TWO-SIDED MINT-VALUE BOUND
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @dev The two-sided mint-value bound: |valueFor(premShares, S_post, stEffectiveNAV) - prem| <= 2*ceil(stEffectiveNAV/S_post) + 2,
     *      and the same bound for the fee leg. The tolerance is DERIVED per state (downward slack: the share-mint
     *      floor, upward slack: the sibling share mint's floor dust accruing pro-rata to post-mint shares, plus the
     *      valuation floor), never an arbitrary literal. The value bound is a FAIR-pricing property, so callers
     *      supply tuples where neither leg binds the mint-dilution clamp (MAX_MINT_DILUTION_WAD)
     *      — the helper re-derives the bind predicate and requires it false, so a tuple drifting onto the bind is
     *      a loud failure rather than a silently weakened assertion. Binding tuples are asserted separately
     *      (shares == cap exactly; a clamped mint's value diverges from its minted NAV by design)
     */
    function _assertMintValueBound(uint256 _stEff, uint256 _prem, uint256 _fee, uint256 _preSupply) internal pure {
        // Precondition, re-derived from first principles: neither leg may bind at the protocol residual. The
        // denominator carries the +1 VIRTUAL_ASSETS exactly as production's bind predicate does
        uint256 denom = (_stEff - _prem - _fee) + 1;
        assertTrue(_prem * 1e6 <= denom * (WAD - 1e6), "precondition: the premium leg must not bind");
        assertTrue(_fee * 1e6 <= denom * (WAD - 1e6), "precondition: the fee leg must not bind");

        (uint256 premShares, uint256 feeShares, uint256 supplyAfter) =
            FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(_mintState(_stEff, _prem, _fee), _preSupply);
        uint256 mintValueDerivedBound = 2 * Math.ceilDiv(_stEff, supplyAfter) + 2;
        uint256 premValue = toUint256(ValuationLogic._convertToValue(premShares, supplyAfter, toNAVUnits(_stEff), Math.Rounding.Floor));
        uint256 feeValue = toUint256(ValuationLogic._convertToValue(feeShares, supplyAfter, toNAVUnits(_stEff), Math.Rounding.Floor));
        uint256 premDiff = premValue > _prem ? premValue - _prem : _prem - premValue;
        uint256 feeDiff = feeValue > _fee ? feeValue - _fee : _fee - feeValue;
        assertLe(premDiff, mintValueDerivedBound, "premium mint value within the two-sided derived bound");
        assertLe(feeDiff, mintValueDerivedBound, "fee mint value within the two-sided derived bound");
        // Shares themselves must match the independent mirror exactly
        (uint256 rtmPrem, uint256 rtmFee,) = RoycoTestMath.computeSTFeeAndLiquidityPremiumSharesToMint(_stEff, _prem, _fee, _preSupply);
        assertEq(premShares, rtmPrem, "RTM premium shares");
        assertEq(feeShares, rtmFee, "RTM fee shares");
    }

    /**
     * The two-sided mint-value bound at adversarial non-binding (stEffectiveNAV, prem, fee, supply) tuples: what each
     * minted leg is WORTH after both mints must track the NAV it was minted for, within the derived rounding
     * bound. Hand-derived worked examples (all provably below the bind: legNAV * 1e6 <= denom * (1e18 - 1e6)):
     * - (7, 3, 3, 5): retained 1 -> premShares floor((5+1e6)*3/(1+1)) = 1500007, feeShares 1500007, S_post 3000019,
     *   value floor((7+1)*1500007/(3000019+1e6)) = 2, diff 1 <= 2*ceil(7/3000019)+2 = 4
     * - (1045e18, 2.5e18, 4.25e18, 1000e18): premValue = 2.5e18 - 1 (one wei of downward floor slack),
     *   diff 1 <= 2*ceil(1045e18/1006501324343847827352)+2 = 6
     * - (3, 1, 1, 1e24): retained 1 -> both mints floor((1e24+1e6)*1/(1+1)) = 500000000000000000500000 shares,
     *   S_post 2000000000000000001000000, value floor((3+1)*500000000000000000500000/(S_post+1e6)) = 1, diff 0
     */
    function test_STFeeAndLiquidityPremiumShareMint_TwoSidedMintValueBound() public pure {
        _assertMintValueBound(7, 3, 3, 5);
        _assertMintValueBound(1045e18, 2.5e18, 4.25e18, 1000e18);
        _assertMintValueBound(3, 1, 1, 1e24);
    }

    /**
     * The binding arm: on a bind the fair value bound is REPLACED by cap exactness — the clamp deliberately
     * mints less than the minted NAV is worth, and what it mints is exactly
     * cap = floor((preSupply + 1e6) * (WAD - eps) / eps) at eps = 1e6.
     * Tuple (10e18, 4e18, 6e18, 1e18) (the degenerate full-NAV state): both legs bind (retained 0 -> 1-wei denominator,
     * bind since ceil(4e18 * 1e6 / (1e18 - 1e6)) > 1), cap = floor((1e18+1e6) * (1e18 - 1e6) / 1e6) = 999_999_999_999_999_999_999_999_000_000.
     * Tuple (1e30, 1e30 - 2, 1, 3) (retained 1): the PREMIUM leg binds ((1e30 - 2) * 1e6 > (1+1) * (1e18 - 1e6))
     * and clamps to cap = floor((3+1e6) * (1e18 - 1e6) / 1e6) = 1_000_002_999_998_999_997, while the FEE leg stays fair
     * (1 * 1e6 <= (1+1) * (1e18 - 1e6)) and floors to floor((3+1e6) * 1 / (1+1)) = 500001 — the mixed case
     */
    function test_STFeeAndLiquidityPremiumShareMint_BindingLegsMintExactlyTheCap() public pure {
        (uint256 premShares, uint256 feeShares, uint256 supplyAfter) =
            FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(_mintState(10e18, 4e18, 6e18), 1e18);
        uint256 cap = Math.mulDiv(1e18 + 1e6, WAD - 1e6, 1e6);
        assertEq(cap, 999_999_999_999_999_999_999_999_000_000, "hand-derived cap literal (effective supply carries the virtual shares)");
        assertEq(premShares, cap, "binding premium leg mints exactly the cap");
        assertEq(feeShares, cap, "binding fee leg mints exactly the cap");
        assertEq(supplyAfter, 1e18 + 2 * cap, "supply identity across two capped mints");

        // The mixed case: one binding leg beside one fair leg
        (uint256 premMixed, uint256 feeMixed, uint256 supplyMixed) =
            FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(_mintState(1e30, 1e30 - 2, 1), 3);
        assertEq(premMixed, 1_000_002_999_998_999_997, "binding premium leg clamps to floor((3+1e6)*(1e18-1e6)/1e6)");
        assertEq(feeMixed, 500_001, "fair fee leg floors to floor((3+1e6)*1/(1+1)) beside the binding sibling");
        assertEq(supplyMixed, 3 + 1_000_002_999_998_999_997 + 500_001, "supply identity across the mixed mints");
    }

    /*//////////////////////////////////////////////////////////////////////
                        LPT EFFECTIVE NAV EDGES
    //////////////////////////////////////////////////////////////////////*/

    /**
     * The LPT effective NAV (ValuationLogic.sol:74-92) is the raw pool depth plus the idle premium shares
     * valued at the senior share price, flooring on the idle leg — the claimable leg a redeemer is owed.
     * lptEff = 100e18 + floor((1045e18+1) * 3e18 / (1004e18+1e6)) = 100e18 + 3_122_509_960_159_359_439
     * Edges: idleShares == 0 returns the raw NAV exactly, and stSupply == 0 returns the raw NAV exactly
     */
    function test_LPTEffectiveNAV_IdleLegAndEdges() public {
        flp.setTotalLPTAssets(100e18);
        flp.setLPTOwnedSeniorTrancheShares(3e18);
        assertEq(
            toUint256(flp.lptEffectiveNAV(toNAVUnits(uint256(1045e18)), 1004e18)), 100e18 + 3_122_509_960_159_359_439, "raw depth plus the floored idle leg"
        );
        assertEq(
            toUint256(flp.lptEffectiveNAV(toNAVUnits(uint256(1045e18)), 1004e18)),
            RoycoTestMath.getLiquidityProviderTrancheEffectiveNAV(100e18, 3e18, 1045e18, 1004e18),
            "RTM lptEffNav cross-assert"
        );

        // stSupply == 0 edge: the idle shares value to nothing against an empty senior supply
        assertEq(toUint256(flp.lptEffectiveNAV(toNAVUnits(uint256(1045e18)), 0)), 100e18, "zero senior supply values the idle leg at zero");
        assertEq(RoycoTestMath.getLiquidityProviderTrancheEffectiveNAV(100e18, 3e18, 1045e18, 0), 100e18, "RTM zero-supply edge");

        // idleShares == 0 edge: pure deployed inventory, the steady state
        flp.setLPTOwnedSeniorTrancheShares(0);
        assertEq(toUint256(flp.lptEffectiveNAV(toNAVUnits(uint256(1045e18)), 1004e18)), 100e18, "no idle leg leaves the raw NAV exactly");
        assertEq(RoycoTestMath.getLiquidityProviderTrancheEffectiveNAV(100e18, 0, 1045e18, 1004e18), 100e18, "RTM zero-idle edge");
    }

    /**
     * The LPT protocol fee is carved out of the liquidity premium and remitted as senior shares to the protocol
     * (FeeAndLiquidityPremiumLogic.sol:92-97): it mints NO liquidity provider tranche shares. The premium leg mints the
     * premium net of the LPT fee to the kernel's idle pile, and the senior fee leg mints the ST fee PLUS the carved
     * LPT fee to the protocol fee recipient, both priced over the same retained senior NAV.
     * stEff 1045e18, gross premium 2.5e18, ST fee 4.25e18, LPT fee 0.5e18, pre-sync supply 1000e18:
     *   retained = 1045e18 - 2.5e18 - 4.25e18 = 1038.25e18 (the LPT fee is inside the premium, so retained is unchanged)
     *   premShares = floor((1000e18+1e6) * (2.5e18 - 0.5e18) / (1038.25e18+1)) = 1_926_318_324_103_059_956
     *   feeShares  = floor((1000e18+1e6) * (4.25e18 + 0.5e18) / (1038.25e18+1)) = 4_575_006_019_744_767_397
     *   supplyAfter = 1000e18 + premShares + feeShares = 1_006_501_324_343_847_827_353
     */
    function test_LPTProtocolFeeMint_CarvedFromPremiumAsSeniorSharesNoLPTShares() public {
        flp.ST_LEDGER().setTotalSupply(1000e18);
        flp.setTotalCollateralAssets(1000e18);
        flp.setLPTOwnedSeniorTrancheShares(5e18);
        flp.setReinvestSharesToDrain(0);
        SyncedAccountingState memory s = _mintState(1045e18, 2.5e18, 4.25e18);
        s.lptProtocolFee = toNAVUnits(uint256(0.5e18));

        flp.processFeesAndLiquidityPremium(s);

        // The premium leg mints the premium NET of the LPT fee, to the kernel's idle pile
        assertEq(flp.ST_LEDGER().premiumMintCallCount(), 1, "one premium mint");
        assertEq(flp.ST_LEDGER().lastPremiumSharesMinted(), 1_926_318_324_103_059_956, "premium shares are net of the LPT fee");
        assertEq(flp.ST_LEDGER().lastPremiumMintTo(), address(flp), "premium shares mint to the kernel");
        assertEq(flp.lptOwnedSeniorTrancheShares(), 5e18 + 1_926_318_324_103_059_956, "idle pile grows by exactly the net premium shares");

        // The senior fee leg mints the ST fee PLUS the carved LPT fee, to the protocol fee recipient
        assertEq(flp.ST_LEDGER().feeMintCallCount(), 1, "one senior fee mint");
        assertEq(flp.ST_LEDGER().lastFeeSharesMinted(), 4_575_006_019_744_767_397, "fee shares pool the ST fee and the carved LPT fee");
        assertEq(flp.ST_LEDGER().lastFeeMintTo(), flp.PROTOCOL_FEE_RECIPIENT(), "fee shares mint to the recipient");

        // The liquidity provider tranche mints no shares for the LPT protocol fee
        assertEq(flp.LPT_LEDGER().feeMintCallCount(), 0, "the LPT protocol fee mints no liquidity shares");

        // RTM cross-assert of the carve-out split (the five-argument mirror models the LPT fee)
        (uint256 rtmPrem, uint256 rtmFee, uint256 rtmSupply) =
            RoycoTestMath.computeSTFeeAndLiquidityPremiumSharesToMint(1045e18, 2.5e18, 4.25e18, 0.5e18, 1000e18);
        assertEq(flp.ST_LEDGER().lastPremiumSharesMinted(), rtmPrem, "RTM premium shares net of the LPT fee");
        assertEq(flp.ST_LEDGER().lastFeeSharesMinted(), rtmFee, "RTM pooled fee shares");
        assertEq(flp.ST_LEDGER().totalSupply(), rtmSupply, "RTM supply after both mints");
    }

    /*//////////////////////////////////////////////////////////////////////
                ZERO-LPT-ASSET-SLICE LPT REDEMPTION
    //////////////////////////////////////////////////////////////////////*/

    /**
     * An in-kind LPT redemption whose proportional slice of the deployed inventory floors to zero NAV while the
     * idle premium ST-share slice is positive commits as a NAV-neutral redemption. Handing idle ST shares to the
     * redeemer moves no raw NAV, only share ownership shifts and no assets leave the vault, so the accountant sees
     * deltaLPTRawNAV == 0 AND totalSTAndJTRedemptionNAV == 0. The LPT_REDEEM op-shape require enforces only that a
     * redemption never grows the LPT's deployed raw NAV (deltaLPTRawNAV <= 0), which this satisfies, so the operation
     * commits with the collateral and every effective NAV untouched and conservation intact. The redeemer's
     * rightful idle-premium claim is delivered, not stranded on the shape check.
     */
    function test_LPTRedeem_ZeroLPTSliceWithIdleSharesOnly_CommitsNavNeutral() public {
        _seedSymmetric(1000e18, 200e18, 100e18);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LPT_REDEEM, toNAVUnits(uint256(1200e18)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, false);
        // No tranche NAV moved: the idle senior shares only changed hands, so every raw and effective NAV is untouched
        assertEq(toUint256(state.lptRawNAV), 100e18, "the LPT deployed raw NAV must be untouched (a redemption never grows it)");
        assertEq(toUint256(state.stEffectiveNAV), 1000e18, "senior effective NAV must be untouched (the shares stay in supply)");
        assertEq(toUint256(state.jtEffectiveNAV), 200e18, "junior effective NAV must be untouched");
        // Conservation holds across the commit
        assertEq(toUint256(state.collateralNAV), toUint256(state.stEffectiveNAV) + toUint256(state.jtEffectiveNAV), "NAV conservation must hold");
    }
}
