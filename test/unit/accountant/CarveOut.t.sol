// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { Operation, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { FeeAndLiquidityPremiumLogic } from "../../../src/libraries/logic/FeeAndLiquidityPremiumLogic.sol";
import { ValuationLogic } from "../../../src/libraries/logic/ValuationLogic.sol";
import { RoycoTestMath } from "../../base/math/RoycoTestMath.sol";
import { FeeAndLiquidityPremiumHarness } from "../../mocks/FeeAndLiquidityPremiumHarness.sol";
import { AccountantUnitHarness } from "./AccountantUnitHarness.sol";

/**
 * @title CarveOutTest
 * @notice Phase B block 2 golden vectors (testing-strategy.md §4.1 block 2, spec 12 §6 V2.1-V2.8): the F11
 *         premium/fee carve-out share mints, the I7 coverage-neutral mint invariant, the I8 two-sided
 *         mint-value bound, and the F12 LT effective NAV edges
 * @dev Every vector hand-derives its expected values in a comment and cross-asserts the matching independent
 *      RoycoTestMath function, so production, mirror, and hand literal must all three agree
 */
contract CarveOutTest is AccountantUnitHarness {
    uint256 internal constant WAD = 1e18;

    FeeAndLiquidityPremiumHarness internal flp;

    function setUp() public {
        _deploy(false, _defaultParams());
        flp = new FeeAndLiquidityPremiumHarness();
    }

    /// @dev Builds the minimal synced state the pure carve-out computation reads
    function _carveState(uint256 _stEff, uint256 _premium, uint256 _fee) internal pure returns (SyncedAccountingState memory s) {
        s.stEffectiveNAV = toNAVUnits(_stEff);
        s.ltLiquidityPremium = toNAVUnits(_premium);
        s.stProtocolFee = toNAVUnits(_fee);
    }

    /*//////////////////////////////////////////////////////////////////////
                        F11 — PURE CARVE-OUT VECTORS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * V2.1 (F11, FLP:88-104): nominal carve-out at the W7-shaped sync outputs.
     * retained = 1045e18 - 2.5e18 - 4.25e18 = 1038.25e18 (shared denominator, joint pricing)
     * premShares = floor(1000e18 * 2.5e18 / 1038.25e18)  = 2_407_897_905_128_822_537
     * feeShares  = floor(1000e18 * 4.25e18 / 1038.25e18) = 4_093_426_438_718_998_314
     * supplyAfter = 1000e18 + premShares + feeShares     = 1_006_501_324_343_847_820_851
     * Joint pricing: both mints divide by the SAME retained NAV at the SAME pre-sync supply, so the fee mint
     * does not dilute the premium mint — pinned by the counterfactual below where the fee is pre-carved out of
     * the effective NAV instead (stEff' = stEff - fee, fee 0, identical retained denominator, identical shares)
     */
    function test_CarveOut_V21_nominalJointPricing() public pure {
        (uint256 premShares, uint256 feeShares, uint256 supplyAfter) =
            FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(_carveState(1045e18, 2.5e18, 4.25e18), 1000e18);
        assertEq(premShares, 2_407_897_905_128_822_537, "premium shares floor over the retained denominator");
        assertEq(feeShares, 4_093_426_438_718_998_314, "fee shares floor over the same retained denominator");
        assertEq(supplyAfter, 1_006_501_324_343_847_820_851, "supply after both mints");

        // RoycoTestMath cross-assert (F11 mirror)
        (uint256 rtmPrem, uint256 rtmFee, uint256 rtmSupply) = RoycoTestMath.carveOut(1045e18, 2.5e18, 4.25e18, 1000e18);
        assertEq(premShares, rtmPrem, "RTM premium shares");
        assertEq(feeShares, rtmFee, "RTM fee shares");
        assertEq(supplyAfter, rtmSupply, "RTM supply after");

        // Counterfactual: minting the premium with the fee absent but already carved out of stEff leaves the
        // premium mint byte-identical, so the fee carve-out provably does not dilute the premium carve-out
        (uint256 premSharesNoFee,,) = FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(_carveState(1040.75e18, 2.5e18, 0), 1000e18);
        assertEq(premSharesNoFee, premShares, "fee mint does not dilute the premium mint");
    }

    /**
     * V2.2 (F9 edge, VL:106, FLP:98): degenerate premium + fee == stEff (100% of the sync's senior effective
     * NAV carved out, e.g. maximal fees on a pure-gain sync from zero retained base).
     * retained = 10e18 - 4e18 - 6e18 = 0 -> the 1-wei denominator branch
     * premShares = floor(1e18 * 4e18 / 1) = 4e36 and feeShares = floor(1e18 * 6e18 / 1) = 6e36 (huge, no revert)
     * supplyAfter = 1e18 + 4e36 + 6e36 = 1e37 + 1e18 — the pre-existing 1e18 shares retain nothing, which is
     * exactly the intended dilution of unbacked holders, and conservation (I1/I2) is untouched because share
     * mints move no NAV
     */
    function test_CarveOut_V22_degeneratePremiumPlusFeeEqualsSTEff() public pure {
        (uint256 premShares, uint256 feeShares, uint256 supplyAfter) =
            FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(_carveState(10e18, 4e18, 6e18), 1e18);
        assertEq(premShares, 4e36, "premium shares against the 1-wei pinned denominator");
        assertEq(feeShares, 6e36, "fee shares against the 1-wei pinned denominator");
        assertEq(supplyAfter, 1e37 + 1e18, "supply after the degenerate mints");

        (uint256 rtmPrem, uint256 rtmFee, uint256 rtmSupply) = RoycoTestMath.carveOut(10e18, 4e18, 6e18, 1e18);
        assertEq(premShares, rtmPrem, "RTM premium shares");
        assertEq(feeShares, rtmFee, "RTM fee shares");
        assertEq(supplyAfter, rtmSupply, "RTM supply after");
    }

    /**
     * V2.3 (VL:104): zero pre-sync supply mints both carve-outs 1:1 with their NAV values.
     * premShares = 2.5e18 and feeShares = 4.25e18 exactly (first-mint semantics), supplyAfter = 6.75e18
     */
    function test_CarveOut_V23_zeroPreSupplyMintsOneToOne() public pure {
        (uint256 premShares, uint256 feeShares, uint256 supplyAfter) =
            FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(_carveState(1045e18, 2.5e18, 4.25e18), 0);
        assertEq(premShares, 2.5e18, "premium shares 1:1 with NAV at zero supply");
        assertEq(feeShares, 4.25e18, "fee shares 1:1 with NAV at zero supply");
        assertEq(supplyAfter, 6.75e18, "supply after the first mints");

        (uint256 rtmPrem, uint256 rtmFee, uint256 rtmSupply) = RoycoTestMath.carveOut(1045e18, 2.5e18, 4.25e18, 0);
        assertEq(premShares, rtmPrem, "RTM premium shares");
        assertEq(feeShares, rtmFee, "RTM fee shares");
        assertEq(supplyAfter, rtmSupply, "RTM supply after");
    }

    /*//////////////////////////////////////////////////////////////////////
                I7 — COVERAGE-NEUTRAL MINT THROUGH THE ORCHESTRATOR
    //////////////////////////////////////////////////////////////////////*/

    /**
     * V2.4 (FLP:49-58): a sync with zero premium and zero fees performs NO mint calls on any tranche, leaves
     * the senior supply and the staged premium pile untouched, and never attempts a reinvestment
     */
    function test_CarveOut_V24_zeroPremiumAndFees_noMintCalls() public {
        flp.ST_LEDGER().setTotalSupply(1000e18);
        flp.setLTOwnedSeniorTrancheShares(5e18);
        SyncedAccountingState memory s = _carveState(1045e18, 0, 0);

        flp.processFeesAndLiquidityPremium(s);

        assertEq(flp.ST_LEDGER().premiumMintCallCount(), 0, "no premium mint");
        assertEq(flp.ST_LEDGER().feeMintCallCount(), 0, "no senior fee mint");
        assertEq(flp.JT_LEDGER().feeMintCallCount(), 0, "no junior fee mint");
        assertEq(flp.LT_LEDGER().feeMintCallCount(), 0, "no liquidity fee mint");
        assertEq(flp.ST_LEDGER().totalSupply(), 1000e18, "senior supply unchanged");
        assertEq(flp.ltOwnedSeniorTrancheShares(), 5e18, "staged premium pile unchanged");
        assertEq(flp.reinvestCallCount(), 0, "no reinvestment attempt on a zero premium");
    }

    /**
     * I7 (testing-strategy §3): the coverage-neutral premium mint. Across _processFeesAndLiquidityPremium with
     * the V2.1 inputs and a slippage-deferred reinvestment (drain 0):
     * - delta stOwnedYieldBearingAssets == 0 (no senior assets enter or leave, so stRaw and covUtil cannot move)
     * - delta ST supply == premShares + feeShares = 2_407_897_905_128_822_537 + 4_093_426_438_718_998_314
     * - delta staged idle pile == premShares - reinvested = premShares - 0
     * - the reinvestment attempt is called once with (uint256 max, stEff, post-mint supply) so the staged shares
     *   are valued at the synced senior share rate
     * The premium mint lands on the kernel (the harness) and the fee mint on the protocol fee recipient
     */
    function test_CarveOut_I7_coverageNeutralMint_stagedWhenReinvestmentDefers() public {
        flp.ST_LEDGER().setTotalSupply(1000e18);
        flp.setSTOwnedYieldBearingAssets(1000e18);
        flp.setLTOwnedSeniorTrancheShares(5e18);
        flp.setReinvestSharesToDrain(0);
        SyncedAccountingState memory s = _carveState(1045e18, 2.5e18, 4.25e18);

        flp.processFeesAndLiquidityPremium(s);

        // Coverage neutrality: the mint reassigns share ownership only, so every covUtil input is untouched
        assertEq(flp.stOwnedYieldBearingAssets(), 1000e18, "senior raw assets unchanged by the mint");
        // Supply delta is exactly the two carve-outs
        assertEq(flp.ST_LEDGER().totalSupply(), 1_006_501_324_343_847_820_851, "supply grows by premShares + feeShares");
        assertEq(flp.ST_LEDGER().premiumMintCallCount(), 1, "one premium mint");
        assertEq(flp.ST_LEDGER().lastPremiumSharesMinted(), 2_407_897_905_128_822_537, "premium share count");
        assertEq(flp.ST_LEDGER().lastPremiumMintTo(), address(flp), "premium shares mint to the kernel");
        assertEq(flp.ST_LEDGER().feeMintCallCount(), 1, "one senior fee mint");
        assertEq(flp.ST_LEDGER().lastFeeSharesMinted(), 4_093_426_438_718_998_314, "fee share count");
        assertEq(flp.ST_LEDGER().lastFeeMintTo(), flp.PROTOCOL_FEE_RECIPIENT(), "fee shares mint to the recipient");
        // Idle pile delta == premShares - reinvested (reinvested == 0 on the deferred path)
        assertEq(flp.ltOwnedSeniorTrancheShares(), 5e18 + 2_407_897_905_128_822_537, "staged pile grows by exactly the premium shares");
        // Reinvestment attempt args pin the post-mint valuation basis
        assertEq(flp.reinvestCallCount(), 1, "one reinvestment attempt");
        assertEq(flp.lastReinvestSharesArg(), type(uint256).max, "attempts to deploy the entire staged pile");
        assertEq(toUint256(flp.lastReinvestSTEffectiveNAVArg()), 1045e18, "valued at the synced senior effective NAV");
        assertEq(flp.lastReinvestTotalSTSharesArg(), 1_006_501_324_343_847_820_851, "valued at the post-mint supply");

        // RTM cross-assert of the two share counts driving the deltas
        (uint256 rtmPrem, uint256 rtmFee,) = RoycoTestMath.carveOut(1045e18, 2.5e18, 4.25e18, 1000e18);
        assertEq(flp.ST_LEDGER().lastPremiumSharesMinted(), rtmPrem, "RTM premium shares");
        assertEq(flp.ST_LEDGER().lastFeeSharesMinted(), rtmFee, "RTM fee shares");
    }

    /**
     * I7 (partial-reinvestment arm): with the stub draining 1e18 shares inside the reinvestment attempt, the
     * staged pile lands at pre + premShares - drained = 5e18 + 2_407_897_905_128_822_537 - 1e18
     */
    function test_CarveOut_I7_partialReinvestmentDrainsStagedPile() public {
        flp.ST_LEDGER().setTotalSupply(1000e18);
        flp.setLTOwnedSeniorTrancheShares(5e18);
        flp.setReinvestSharesToDrain(1e18);
        SyncedAccountingState memory s = _carveState(1045e18, 2.5e18, 4.25e18);

        flp.processFeesAndLiquidityPremium(s);

        assertEq(flp.ltOwnedSeniorTrancheShares(), 5e18 + 2_407_897_905_128_822_537 - 1e18, "idle delta == premShares - reinvested");
    }

    /*//////////////////////////////////////////////////////////////////////
                        I8 — TWO-SIDED MINT-VALUE BOUND
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @dev I8 (testing-strategy §3-I8): |valueFor(premShares, S_post, stEff) - prem| <= 2*ceil(stEff/S_post) + 2,
     *      and the same bound for the fee leg. The tolerance is DERIVED per state (downward slack: the F9 floor,
     *      upward slack: the sibling carve-out's floor dust accruing pro-rata to post-mint shares, plus the F10
     *      valuation floor), never an arbitrary literal
     */
    function _assertI8(uint256 _stEff, uint256 _prem, uint256 _fee, uint256 _preSupply) internal pure {
        (uint256 premShares, uint256 feeShares, uint256 supplyAfter) =
            FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(_carveState(_stEff, _prem, _fee), _preSupply);
        uint256 i8DerivedBound = 2 * Math.ceilDiv(_stEff, supplyAfter) + 2;
        uint256 premValue = toUint256(ValuationLogic._convertToValue(premShares, supplyAfter, toNAVUnits(_stEff), Math.Rounding.Floor));
        uint256 feeValue = toUint256(ValuationLogic._convertToValue(feeShares, supplyAfter, toNAVUnits(_stEff), Math.Rounding.Floor));
        uint256 premDiff = premValue > _prem ? premValue - _prem : _prem - premValue;
        uint256 feeDiff = feeValue > _fee ? feeValue - _fee : _fee - feeValue;
        assertLe(premDiff, i8DerivedBound, "premium mint value within the two-sided derived bound");
        assertLe(feeDiff, i8DerivedBound, "fee mint value within the two-sided derived bound");
        // Shares themselves must match the independent mirror exactly
        (uint256 rtmPrem, uint256 rtmFee,) = RoycoTestMath.carveOut(_stEff, _prem, _fee, _preSupply);
        assertEq(premShares, rtmPrem, "RTM premium shares");
        assertEq(feeShares, rtmFee, "RTM fee shares");
    }

    /**
     * V2.6 (I8): the two-sided mint-value bound at adversarial (stEff, prem, fee, supply) tuples.
     * Hand-derived worked exemplars:
     * - (7, 3, 3, 5): retained 1 -> premShares 15, feeShares 15, S_post 35, value floor(7*15/35) = 3,
     *   diff 0 <= 2*ceil(7/35)+2 = 4
     * - (1e30, 1e30-2, 1, 3): retained 1 -> premShares 3*(1e30-2), feeShares 3, S_post 3e30 exactly,
     *   premValue = floor(1e30*(3e30-6)/3e30) = 1e30-2, diff 0 <= 4
     * - (1045e18, 2.5e18, 4.25e18, 1000e18): premValue = 2.5e18 - 1 (one wei of downward floor slack),
     *   diff 1 <= 2*ceil(1045e18/1006501324343847820851)+2 = 6
     * - (3, 1, 1, 1e24): retained 1 -> both mints 1e24 shares, S_post 3e24, value floor(3*1e24/3e24) = 1, diff 0
     */
    function test_CarveOut_I8_twoSidedMintValueBound() public pure {
        _assertI8(7, 3, 3, 5);
        _assertI8(1e30, 1e30 - 2, 1, 3);
        _assertI8(1045e18, 2.5e18, 4.25e18, 1000e18);
        _assertI8(3, 1, 1, 1e24);
    }

    /*//////////////////////////////////////////////////////////////////////
                        F12 — LT EFFECTIVE NAV EDGES
    //////////////////////////////////////////////////////////////////////*/

    /**
     * V2.5 (F12, VL:73-91): the LT effective NAV is the raw pool depth plus the staged premium shares valued at
     * the senior share price, flooring on the idle leg.
     * ltEff = 100e18 + floor(3e18 * 1045e18 / 1004e18) = 100e18 + 3_122_509_960_159_362_549
     * Edges: idleShares == 0 returns the raw NAV exactly, and stSupply == 0 returns the raw NAV exactly
     */
    function test_CarveOut_V25_ltEffectiveNAV_idleLegAndEdges() public {
        flp.setLTOwnedYieldBearingAssets(100e18);
        flp.setLTOwnedSeniorTrancheShares(3e18);
        assertEq(toUint256(flp.ltEffectiveNAV(toNAVUnits(uint256(1045e18)), 1004e18)), 100e18 + 3_122_509_960_159_362_549, "raw depth plus the floored idle leg");
        assertEq(
            toUint256(flp.ltEffectiveNAV(toNAVUnits(uint256(1045e18)), 1004e18)),
            RoycoTestMath.ltEffNav(100e18, 3e18, 1045e18, 1004e18),
            "RTM ltEffNav cross-assert"
        );

        // stSupply == 0 edge: the idle shares value to nothing against an empty senior supply
        assertEq(toUint256(flp.ltEffectiveNAV(toNAVUnits(uint256(1045e18)), 0)), 100e18, "zero senior supply values the idle leg at zero");
        assertEq(RoycoTestMath.ltEffNav(100e18, 3e18, 1045e18, 0), 100e18, "RTM zero-supply edge");

        // idleShares == 0 edge: pure BPT, the steady state
        flp.setLTOwnedSeniorTrancheShares(0);
        assertEq(toUint256(flp.ltEffectiveNAV(toNAVUnits(uint256(1045e18)), 1004e18)), 100e18, "no idle leg leaves the raw NAV exactly");
        assertEq(RoycoTestMath.ltEffNav(100e18, 0, 1045e18, 1004e18), 100e18, "RTM zero-idle edge");
    }

    /**
     * V2.8 (FLP:66-72, VL:106, strategy §4.1-9): an LT protocol fee equal to the entire LT effective NAV (the
     * 100% fee ceiling) drives the fee-share denominator ltEff - fee to zero, which routes through the F9
     * 1-wei branch instead of reverting.
     * ltEff = ltRaw 10e18 + idle 0 = 10e18, fee = 10e18 -> denominator 0 -> 1 wei
     * feeShares = floor(50e18 * 10e18 / 1) = 5e38, minted to the protocol fee recipient
     */
    function test_CarveOut_V28_ltFeeMintAtFullFee_routesThroughOneWeiDenominator() public {
        flp.ST_LEDGER().setTotalSupply(1000e18);
        flp.LT_LEDGER().setTotalSupply(50e18);
        flp.setLTOwnedYieldBearingAssets(10e18);
        SyncedAccountingState memory s = _carveState(1045e18, 0, 0);
        s.ltProtocolFee = toNAVUnits(uint256(10e18));

        flp.processFeesAndLiquidityPremium(s);

        assertEq(flp.LT_LEDGER().feeMintCallCount(), 1, "one liquidity fee mint");
        assertEq(flp.LT_LEDGER().lastFeeSharesMinted(), 5e38, "fee shares against the 1-wei pinned denominator");
        assertEq(flp.LT_LEDGER().lastFeeMintTo(), flp.PROTOCOL_FEE_RECIPIENT(), "fee shares mint to the recipient");
        // The 1-wei branch matches the RTM F9 mirror: sharesFor(10e18, 0, 50e18) = floor(50e18 * 10e18 / 1)
        assertEq(flp.LT_LEDGER().lastFeeSharesMinted(), RoycoTestMath.sharesFor(10e18, 0, 50e18), "RTM sharesFor cross-assert");
    }

    /*//////////////////////////////////////////////////////////////////////
            V2.7 — ZERO-BPT-SLICE LT REDEMPTION (SPEC DIVERGENCE PIN)
    //////////////////////////////////////////////////////////////////////*/

    /**
     * FINDING 3 (docs/testing/agent-notes/13-spec-divergence-findings.md, testing-strategy Appendix B.2): an
     * in-kind LT redemption whose BPT slice floors to zero NAV while the idle-share slice is positive presents
     * the accountant with deltaLT == 0 and totalSTAndJTRedemptionNAV == 0 (transferring idle ST shares moves no
     * raw NAV), which fails the LT_REDEEM op-shape require at RoycoDayAccountant.sol:263 regardless of the
     * enforcement flag.
     * Spec-expected value: the redemption SUCCEEDS and the redeemer receives its pro-rata idle ST shares
     * (CLAUDE.md: "If a user redeems LT shares while idle ST shares still sit in the LT, those ST shares are
     * sent directly to them"). Pinned here as the current (diverging) revert
     */
    function test_FINDING_3_ltRedeemZeroBPTSliceWithIdleShares_revertsInvalidPostOpState() public {
        _seedSymmetric(1000e18, 200e18, 100e18);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_REDEEM));
        kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(uint256(1000e18)), toNAVUnits(uint256(200e18)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, false);
    }
}
