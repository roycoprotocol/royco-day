// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { EntryPointRemitClaimsHarness, MockKernelAssets } from "../../mocks/EntryPointRemitClaimsHarness.sol";
import { MockERC20C } from "../../mocks/MockERC20C.sol";

/**
 * @title Test_EntryPointRemitClaims
 * @notice Unit-pins the claim-remittance matrix of _remitRedemptionAndBonusClaims: the bonus split and the per-leg
 *         transfer gating (every nonzero leg is paid, gated on the receiver's post-bonus portion alone) across the
 *         four transferable legs: collateral, LPT asset, senior shares, and quote
 */
contract Test_EntryPointRemitClaims is Test {
    uint64 internal constant TEN_PERCENT_WAD = 0.1e18;

    EntryPointRemitClaimsHarness internal harness;
    MockERC20C internal collateralAsset;
    MockERC20C internal lptAsset;
    MockERC20C internal seniorShare;
    MockERC20C internal quoteAsset;

    address internal EXECUTOR = makeAddr("EXECUTOR");
    address internal RECEIVER = makeAddr("RECEIVER");

    function setUp() public {
        harness = new EntryPointRemitClaimsHarness(makeAddr("FACTORY"));
        collateralAsset = new MockERC20C("Collateral Asset", "COLL", 18);
        lptAsset = new MockERC20C("LPT Asset", "LPTA", 18);
        seniorShare = new MockERC20C("Senior Share", "RST", 18);
        quoteAsset = new MockERC20C("Quote Asset", "QTA", 6);
    }

    function _mockKernel() internal returns (MockKernelAssets kernel) {
        kernel = new MockKernelAssets(address(collateralAsset), address(lptAsset), address(seniorShare), address(quoteAsset));
    }

    /// @dev Builds a claims struct over the three transferable claim legs (nav does not affect transfers)
    function _claims(uint256 _collateral, uint256 _lt, uint256 _stShares) internal pure returns (AssetClaims memory claims) {
        claims.collateralAssets = toTrancheUnits(_collateral);
        claims.lptAssets = toTrancheUnits(_lt);
        claims.stShares = _stShares;
        claims.nav = toNAVUnits(uint256(0));
    }

    function _fundHarness(uint256 _collateral, uint256 _lt, uint256 _stShares) internal {
        if (_collateral != 0) collateralAsset.mint(address(harness), _collateral);
        if (_lt != 0) lptAsset.mint(address(harness), _lt);
        if (_stShares != 0) seniorShare.mint(address(harness), _stShares);
    }

    function test_remit_collateralLeg_singleTransferWithFlooredBonus() public {
        MockKernelAssets kernel = _mockKernel();
        _fundHarness(330, 0, 0);

        // A 10% bonus on a 330-wei collateral leg. The bonus is a _scaleAssetClaims slice priced against the
        // virtual-shares effective denominator (WAD + 1e6): bonus = floor(330*0.1e18/(1e18+1e6)) = 32. The
        // receiver keeps total-minus-bonus, 298. Conservation holds exactly (executor + receiver == total): the
        // offset only shifts the floor of the bonus slice.
        vm.prank(EXECUTOR);
        (AssetClaims memory bonusClaims,, AssetClaims memory userClaims) =
            harness.remitRedemptionAndBonusClaims(address(kernel), _claims(330, 0, 0), 0, TEN_PERCENT_WAD, RECEIVER);

        assertEq(collateralAsset.balanceOf(RECEIVER), 298, "receiver collateral leg");
        assertEq(collateralAsset.balanceOf(EXECUTOR), 32, "executor collateral leg");
        // The returned splits must mirror the transfers: the total claims are reduced in place to the receiver's portion
        assertEq(toUint256(bonusClaims.collateralAssets), 32, "returned bonus collateral leg");
        assertEq(toUint256(userClaims.collateralAssets), 298, "returned user collateral leg");
    }

    function test_remit_transfersLptAndSeniorShareLegs() public {
        MockKernelAssets kernel = _mockKernel();
        _fundHarness(0, 300, 400);

        vm.prank(EXECUTOR);
        harness.remitRedemptionAndBonusClaims(address(kernel), _claims(0, 300, 400), 0, TEN_PERCENT_WAD, RECEIVER);

        // Bonus over (WAD + 1e6): bonusLPT = floor(300*0.1e18/(1e18+1e6)) = 29, bonusShares =
        // floor(400*0.1e18/(1e18+1e6)) = 39, receiver keeps (271, 361).
        assertEq(lptAsset.balanceOf(RECEIVER), 271, "receiver LPT asset leg");
        assertEq(seniorShare.balanceOf(RECEIVER), 361, "receiver senior share leg");
        assertEq(lptAsset.balanceOf(EXECUTOR), 29, "executor LPT asset leg");
        assertEq(seniorShare.balanceOf(EXECUTOR), 39, "executor senior share leg");
    }

    function test_remit_zeroBonus_sendsEverythingToReceiver() public {
        MockKernelAssets kernel = _mockKernel();
        _fundHarness(300, 0, 0);

        vm.prank(EXECUTOR);
        harness.remitRedemptionAndBonusClaims(address(kernel), _claims(300, 0, 0), 0, 0, RECEIVER);

        assertEq(collateralAsset.balanceOf(RECEIVER), 300, "receiver must get the full collateral leg under a zero bonus");
        assertEq(collateralAsset.balanceOf(EXECUTOR), 0, "executor must get nothing under a zero bonus");
    }

    function test_remit_zeroLegsAreSkippedWithoutReverting() public {
        // The harness holds NO tokens: any attempted transfer would revert, so success proves every leg was skipped
        MockKernelAssets kernel = _mockKernel();
        vm.prank(EXECUTOR);
        harness.remitRedemptionAndBonusClaims(address(kernel), _claims(0, 0, 0), 0, TEN_PERCENT_WAD, RECEIVER);
    }

    function test_remit_quoteLeg_splitsWithFloorAndPaysReceiverFirst() public {
        // The quote leg's bonus floors over the plain WAD denominator (mulDiv(quote, bonus, WAD)), UNLIKE the three
        // claims legs, which are a _scaleAssetClaims slice over the virtual-shares effective denominator (WAD + 1e6).
        // The leg is sized at 10_000_005 so the two denominators produce DIFFERENT slices at a 10% bonus
        // (1_000_000 vs 999_999), pinning the WAD path against a regression that switched the denominator
        MockKernelAssets kernel = _mockKernel();
        quoteAsset.mint(address(harness), 10_000_005);

        vm.prank(EXECUTOR);
        (, uint256 bonusQuoteAssets,) = harness.remitRedemptionAndBonusClaims(address(kernel), _claims(0, 0, 0), 10_000_005, TEN_PERCENT_WAD, RECEIVER);

        assertEq(bonusQuoteAssets, 1_000_000, "the executor's quote slice must be the flooring WAD-denominator bonus fraction");
        assertEq(quoteAsset.balanceOf(EXECUTOR), 1_000_000, "the executor must receive its quote slice");
        assertEq(quoteAsset.balanceOf(RECEIVER), 9_000_005, "the receiver must get the post-bonus quote remainder");
        assertEq(quoteAsset.balanceOf(address(harness)), 0, "no quote may remain in the entry point after the split");
    }

    function test_remit_maximalBonusOverOneWeiLegs_receiverKeepsEveryLeg() public {
        // The load-bearing extreme of the gating argument: at the maximal legal bonus (WAD - 1) over 1-wei legs,
        // every bonus slice floors to zero and the receiver provably keeps at least the wei on every leg
        MockKernelAssets kernel = _mockKernel();
        _fundHarness(1, 1, 1);
        quoteAsset.mint(address(harness), 1);

        vm.prank(EXECUTOR);
        (AssetClaims memory bonusClaims, uint256 bonusQuoteAssets,) =
            harness.remitRedemptionAndBonusClaims(address(kernel), _claims(1, 1, 1), 1, uint64(1e18 - 1), RECEIVER);

        assertEq(toUint256(bonusClaims.collateralAssets) + toUint256(bonusClaims.lptAssets) + bonusClaims.stShares, 0, "every bonus slice must floor to zero");
        assertEq(bonusQuoteAssets, 0, "the quote bonus slice must floor to zero");
        assertEq(
            collateralAsset.balanceOf(RECEIVER) + lptAsset.balanceOf(RECEIVER) + seniorShare.balanceOf(RECEIVER) + quoteAsset.balanceOf(RECEIVER),
            4,
            "the receiver must keep every 1-wei leg"
        );
    }

    function test_remit_zeroQuoteLeg_isSkippedWithoutReverting() public {
        // The harness holds NO quote: success proves a zero quote leg never reaches the transfer
        MockKernelAssets kernel = _mockKernel();
        _fundHarness(330, 0, 0);
        vm.prank(EXECUTOR);
        (, uint256 bonusQuoteAssets,) = harness.remitRedemptionAndBonusClaims(address(kernel), _claims(330, 0, 0), 0, TEN_PERCENT_WAD, RECEIVER);
        assertEq(bonusQuoteAssets, 0, "a zero quote leg must carry no bonus");
    }

    function test_remit_everyNonZeroLegIsPaid_legDrivenNotTypeDriven() public {
        // The remitter is leg-driven: every nonzero leg is split and paid regardless of which tranche type produced
        // the claims (the kernel's categorical derivation makes cross-type legs structurally zero in production, so
        // relying on the type bought nothing, and a hypothetical cross-type leg is paid out rather than stranded)
        MockKernelAssets kernel = _mockKernel();
        _fundHarness(330, 300, 400);
        vm.prank(EXECUTOR);
        harness.remitRedemptionAndBonusClaims(address(kernel), _claims(330, 300, 400), 0, TEN_PERCENT_WAD, RECEIVER);

        // Bonus per leg over (WAD + 1e6): (bonusCollateral, bonusLPT, bonusShares) = (32, 29, 39); receiver keeps
        // total-minus-bonus on every leg. Conservation holds per leg (executor + receiver == total).
        assertEq(collateralAsset.balanceOf(RECEIVER), 298, "receiver collateral leg");
        assertEq(lptAsset.balanceOf(RECEIVER), 271, "receiver LPT asset leg");
        assertEq(seniorShare.balanceOf(RECEIVER), 361, "receiver senior share leg");
        assertEq(collateralAsset.balanceOf(EXECUTOR), 32, "executor collateral leg");
        assertEq(lptAsset.balanceOf(EXECUTOR), 29, "executor LPT asset leg");
        assertEq(seniorShare.balanceOf(EXECUTOR), 39, "executor senior share leg");
    }
}
