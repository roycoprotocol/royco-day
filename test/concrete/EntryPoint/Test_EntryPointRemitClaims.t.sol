// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { EntryPointRemitClaimsHarness, MockKernelAssets } from "../../mocks/EntryPointRemitClaimsHarness.sol";
import { MockERC20C } from "../../mocks/MockERC20C.sol";

/**
 * @title Test_EntryPointRemitClaims
 * @notice Unit-pins the claim-remittance matrix of _remitRedemptionAndBonusClaims: the bonus split, the per-leg
 *         transfer gating (every nonzero leg is paid, gated on the receiver's post-bonus portion alone), and the
 *         DIFFERENT-asset ST/JT branch that the shipped identical-ST/JT-asset kernel family can never produce
 *         through a real market
 */
contract Test_EntryPointRemitClaims is Test {
    uint64 internal constant TEN_PERCENT_WAD = 0.1e18;

    EntryPointRemitClaimsHarness internal harness;
    MockERC20C internal stAsset;
    MockERC20C internal jtAsset;
    MockERC20C internal ltAsset;
    MockERC20C internal seniorShare;
    MockERC20C internal quoteAsset;

    address internal EXECUTOR = makeAddr("EXECUTOR");
    address internal RECEIVER = makeAddr("RECEIVER");

    function setUp() public {
        harness = new EntryPointRemitClaimsHarness(makeAddr("FACTORY"));
        stAsset = new MockERC20C("ST Asset", "STA", 18);
        jtAsset = new MockERC20C("JT Asset", "JTA", 18);
        ltAsset = new MockERC20C("LT Asset", "LTA", 18);
        seniorShare = new MockERC20C("Senior Share", "RST", 18);
        quoteAsset = new MockERC20C("Quote Asset", "QTA", 6);
    }

    /// @dev Builds a claims struct over the four transferable legs (nav does not affect transfers)
    function _claims(uint256 _st, uint256 _jt, uint256 _lt, uint256 _stShares) internal pure returns (AssetClaims memory claims) {
        claims.stAssets = toTrancheUnits(_st);
        claims.jtAssets = toTrancheUnits(_jt);
        claims.ltAssets = toTrancheUnits(_lt);
        claims.stShares = _stShares;
        claims.nav = toNAVUnits(uint256(0));
    }

    function _fundHarness(uint256 _st, uint256 _jt, uint256 _lt, uint256 _stShares) internal {
        if (_st != 0) stAsset.mint(address(harness), _st);
        if (_jt != 0) jtAsset.mint(address(harness), _jt);
        if (_lt != 0) ltAsset.mint(address(harness), _lt);
        if (_stShares != 0) seniorShare.mint(address(harness), _stShares);
    }

    function test_remit_differentAssets_transfersEachLegSeparately() public {
        MockKernelAssets kernel = new MockKernelAssets(address(stAsset), address(jtAsset), address(ltAsset), address(seniorShare), address(quoteAsset));
        _fundHarness(110, 220, 0, 0);

        // A 10% bonus on totals (110, 220): the executor gets (11, 22) and the receiver gets the (99, 198) remainder
        vm.prank(EXECUTOR);
        (AssetClaims memory bonusClaims,, AssetClaims memory userClaims) =
            harness.remitRedemptionAndBonusClaims(address(kernel), _claims(110, 220, 0, 0), 0, TEN_PERCENT_WAD, RECEIVER);

        assertEq(stAsset.balanceOf(RECEIVER), 99, "receiver ST asset leg");
        assertEq(jtAsset.balanceOf(RECEIVER), 198, "receiver JT asset leg");
        assertEq(stAsset.balanceOf(EXECUTOR), 11, "executor ST asset leg");
        assertEq(jtAsset.balanceOf(EXECUTOR), 22, "executor JT asset leg");
        // The returned splits must mirror the transfers: the total claims are reduced in place to the receiver's portion
        assertEq(toUint256(bonusClaims.stAssets), 11, "returned bonus ST leg");
        assertEq(toUint256(userClaims.stAssets), 99, "returned user ST leg");
        assertEq(toUint256(userClaims.jtAssets), 198, "returned user JT leg");
    }

    function test_remit_sameAsset_batchesStAndJtLegs() public {
        MockKernelAssets kernel = new MockKernelAssets(address(stAsset), address(stAsset), address(ltAsset), address(seniorShare), address(quoteAsset));
        _fundHarness(330, 0, 0, 0);

        vm.prank(EXECUTOR);
        harness.remitRedemptionAndBonusClaims(address(kernel), _claims(110, 220, 0, 0), 0, TEN_PERCENT_WAD, RECEIVER);

        assertEq(stAsset.balanceOf(RECEIVER), 297, "receiver must get one batched ST+JT transfer");
        assertEq(stAsset.balanceOf(EXECUTOR), 33, "executor must get one batched ST+JT transfer");
    }

    function test_remit_transfersLtAndSeniorShareLegs() public {
        MockKernelAssets kernel = new MockKernelAssets(address(stAsset), address(jtAsset), address(ltAsset), address(seniorShare), address(quoteAsset));
        _fundHarness(0, 0, 300, 400);

        vm.prank(EXECUTOR);
        harness.remitRedemptionAndBonusClaims(address(kernel), _claims(0, 0, 300, 400), 0, TEN_PERCENT_WAD, RECEIVER);

        assertEq(ltAsset.balanceOf(RECEIVER), 270, "receiver LT asset leg");
        assertEq(seniorShare.balanceOf(RECEIVER), 360, "receiver senior share leg");
        assertEq(ltAsset.balanceOf(EXECUTOR), 30, "executor LT asset leg");
        assertEq(seniorShare.balanceOf(EXECUTOR), 40, "executor senior share leg");
    }

    function test_remit_zeroBonus_sendsEverythingToReceiver() public {
        MockKernelAssets kernel = new MockKernelAssets(address(stAsset), address(jtAsset), address(ltAsset), address(seniorShare), address(quoteAsset));
        _fundHarness(100, 200, 0, 0);

        vm.prank(EXECUTOR);
        harness.remitRedemptionAndBonusClaims(address(kernel), _claims(100, 200, 0, 0), 0, 0, RECEIVER);

        assertEq(stAsset.balanceOf(RECEIVER), 100, "receiver must get the full ST leg under a zero bonus");
        assertEq(jtAsset.balanceOf(RECEIVER), 200, "receiver must get the full JT leg under a zero bonus");
        assertEq(stAsset.balanceOf(EXECUTOR), 0, "executor must get nothing under a zero bonus");
    }

    function test_remit_zeroLegsAreSkippedWithoutReverting() public {
        // The harness holds NO tokens: any attempted transfer would revert, so success proves every leg was skipped
        MockKernelAssets kernel = new MockKernelAssets(address(stAsset), address(jtAsset), address(ltAsset), address(seniorShare), address(quoteAsset));
        vm.prank(EXECUTOR);
        harness.remitRedemptionAndBonusClaims(address(kernel), _claims(0, 0, 0, 0), 0, TEN_PERCENT_WAD, RECEIVER);
    }

    function test_remit_quoteLeg_splitsWithFloorAndPaysReceiverFirst() public {
        // The quote leg splits like every claims leg: the executor's slice floors, the receiver takes the remainder,
        // and the receiver's portion is provably nonzero whenever the leg is (bonus strictly under WAD)
        MockKernelAssets kernel = new MockKernelAssets(address(stAsset), address(jtAsset), address(ltAsset), address(seniorShare), address(quoteAsset));
        quoteAsset.mint(address(harness), 105);

        vm.prank(EXECUTOR);
        (, uint256 bonusQuoteAssets,) = harness.remitRedemptionAndBonusClaims(address(kernel), _claims(0, 0, 0, 0), 105, TEN_PERCENT_WAD, RECEIVER);

        assertEq(bonusQuoteAssets, 10, "the executor's quote slice must be the flooring bonus fraction");
        assertEq(quoteAsset.balanceOf(EXECUTOR), 10, "the executor must receive its quote slice");
        assertEq(quoteAsset.balanceOf(RECEIVER), 95, "the receiver must get the post-bonus quote remainder");
        assertEq(quoteAsset.balanceOf(address(harness)), 0, "no quote may remain in the entry point after the split");
    }

    function test_remit_maximalBonusOverOneWeiLegs_receiverKeepsEveryLeg() public {
        // The load-bearing extreme of the gating argument: at the maximal legal bonus (WAD - 1) over 1-wei legs,
        // every bonus slice floors to zero and the receiver provably keeps at least the wei on every leg
        MockKernelAssets kernel = new MockKernelAssets(address(stAsset), address(jtAsset), address(ltAsset), address(seniorShare), address(quoteAsset));
        _fundHarness(1, 1, 1, 1);
        quoteAsset.mint(address(harness), 1);

        vm.prank(EXECUTOR);
        (AssetClaims memory bonusClaims, uint256 bonusQuoteAssets,) =
            harness.remitRedemptionAndBonusClaims(address(kernel), _claims(1, 1, 1, 1), 1, uint64(1e18 - 1), RECEIVER);

        assertEq(toUint256(bonusClaims.stAssets) + toUint256(bonusClaims.jtAssets) + toUint256(bonusClaims.ltAssets) + bonusClaims.stShares, 0, "every bonus slice must floor to zero");
        assertEq(bonusQuoteAssets, 0, "the quote bonus slice must floor to zero");
        assertEq(stAsset.balanceOf(RECEIVER) + jtAsset.balanceOf(RECEIVER) + ltAsset.balanceOf(RECEIVER) + seniorShare.balanceOf(RECEIVER) + quoteAsset.balanceOf(RECEIVER), 5, "the receiver must keep every 1-wei leg");
    }

    function test_remit_zeroQuoteLeg_isSkippedWithoutReverting() public {
        // The harness holds NO quote: success proves a zero quote leg never reaches the transfer
        MockKernelAssets kernel = new MockKernelAssets(address(stAsset), address(jtAsset), address(ltAsset), address(seniorShare), address(quoteAsset));
        _fundHarness(110, 220, 0, 0);
        vm.prank(EXECUTOR);
        (, uint256 bonusQuoteAssets,) = harness.remitRedemptionAndBonusClaims(address(kernel), _claims(110, 220, 0, 0), 0, TEN_PERCENT_WAD, RECEIVER);
        assertEq(bonusQuoteAssets, 0, "a zero quote leg must carry no bonus");
    }

    function test_remit_everyNonZeroLegIsPaid_legDrivenNotTypeDriven() public {
        // The remitter is leg-driven: every nonzero leg is split and paid regardless of which tranche type produced
        // the claims (the kernel's categorical derivation makes cross-type legs structurally zero in production, so
        // relying on the type bought nothing — and a hypothetical cross-type leg is paid out rather than stranded)
        MockKernelAssets kernel = new MockKernelAssets(address(stAsset), address(jtAsset), address(ltAsset), address(seniorShare), address(quoteAsset));
        _fundHarness(110, 220, 300, 400);
        vm.prank(EXECUTOR);
        harness.remitRedemptionAndBonusClaims(address(kernel), _claims(110, 220, 300, 400), 0, TEN_PERCENT_WAD, RECEIVER);

        assertEq(stAsset.balanceOf(RECEIVER), 99, "receiver ST asset leg");
        assertEq(jtAsset.balanceOf(RECEIVER), 198, "receiver JT asset leg");
        assertEq(ltAsset.balanceOf(RECEIVER), 270, "receiver LT asset leg");
        assertEq(seniorShare.balanceOf(RECEIVER), 360, "receiver senior share leg");
        assertEq(stAsset.balanceOf(EXECUTOR), 11, "executor ST asset leg");
        assertEq(jtAsset.balanceOf(EXECUTOR), 22, "executor JT asset leg");
        assertEq(ltAsset.balanceOf(EXECUTOR), 30, "executor LT asset leg");
        assertEq(seniorShare.balanceOf(EXECUTOR), 40, "executor senior share leg");
    }
}
