// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toUint256 } from "../../../src/libraries/Units.sol";
import { EntryPointTestBase } from "../../utils/EntryPointTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_EntryPointRedemptionForfeitureMatrix
 * @notice The hand-derived redemption value-forfeiture matrix across tranches, redemption modes, and executor
 *         bonuses. Every skim is pinned exactly against the value formula and every claim leg's bonus split is
 *         re-derived independently
 * @dev The value basis: a redemption request snapshots the escrowed shares' claim on the gate-free totalAssets NAV
 *      at the virtual-shares rate (vReq = ValuationLogic._convertToValue); at execution the same formula yields vExec, and the
 *      protocol skims exactly protocolFeeShares = floor(shares * (vExec - vReq) / vExec) when vExec > vReq (never on
 *      a loss). The skim is share-denominated and route-independent: INKIND and MULTIASSET executions of identical
 *      requests under identical PnL forfeit per the same formula
 * @dev Bonus splits: every leg (asset claims and quote) splits at the plain flooring bonus rate
 *      floor(total * bonus / 1e18) — the entry point's bonus scale carries no virtual-shares offset
 */
contract Test_EntryPointRedemptionForfeitureMatrix is EntryPointTestBase {
    uint256 internal stUnit;
    uint256 internal QUOTE_UNIT;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.collateralAsset.decimals);
        QUOTE_UNIT = 10 ** uint256(cell.quoteAsset.decimals);
        _seedMarket(100_000e18, 30_000e18);
        // A real two-leg pool seed so the multi-asset exit pays both a constituent and a quote leg
        _seedLPT(10_000e18, 8000e18, 2000 * QUOTE_UNIT);
        _deployEntryPoint();
    }

    // ---------------------------------------------------------------------
    // Independent derivations
    // ---------------------------------------------------------------------

    /// @dev The redemption value reference: the shares' claim on the tranche's totalAssets NAV at the virtual-shares
    ///      rate (mirrors ValuationLogic._convertToValue, the same basis the tranche's own redeem scales by)
    function _valueOf(address _tranche, uint256 _shares) internal view returns (uint256 value) {
        return RoycoTestMath.convertToValue(_shares, toUint256(IRoycoVaultTranche(_tranche).totalAssets().nav), IERC20(_tranche).totalSupply());
    }

    /// @dev The exact skim for a full-request execution: floor(shares * (vExec - vReq) / vExec), zero when value fell
    function _expectedSkim(uint256 _shares, uint256 _vReq, uint256 _vExec) internal pure returns (uint256 feeShares) {
        if (_vExec <= _vReq) return 0;
        return Math.mulDiv(_shares, _vExec - _vReq, _vExec, Math.Rounding.Floor);
    }

    // ---------------------------------------------------------------------
    // ST / JT INKIND cells: gain-in-queue skims exactly, bonus splits the collateral leg
    // ---------------------------------------------------------------------

    /// @dev Runs an ST/JT INKIND cell: acquire, request, +10% collateral gain, execute, exact skim + split asserts
    function _runStJtCell(address _tranche, uint64 _bonusWAD) internal {
        uint256 shares = _acquireTrancheShares(USER_A, _tranche, 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, _tranche, shares, USER_B, _bonusWAD, IRoycoDayEntryPoint.RedemptionMode.INKIND);

        // The stored snapshot must equal the independently derived pro-rata value
        uint256 vReq = toUint256(entryPoint.getRedemptionRequest(USER_A, nonce).valueAtRequestTime);
        assertEq(vReq, _valueOf(_tranche, shares), "the stored value snapshot must equal the derived pro-rata totalAssets claim");

        applySTPnL(1000);
        _warpPastRedemptionDelay();

        // The exact skim from the value formula, derived just before execution on identical state
        uint256 vExec = _valueOf(_tranche, shares);
        uint256 expectedFee = _expectedSkim(shares, vReq, vExec);
        assertGt(expectedFee, 0, "sanity: the queued gain must produce a nonzero skim");

        address executor = (_bonusWAD == 0) ? USER_A : EXECUTOR;
        uint256 feeBefore = entryPoint.getProtocolFeeSharesPendingCollection(_tranche);
        vm.prank(executor);
        (AssetClaims memory userClaims,) = entryPoint.executeRedemption(USER_A, nonce, shares);

        assertEq(entryPoint.getProtocolFeeSharesPendingCollection(_tranche) - feeBefore, expectedFee, "the skim must equal the exact value-formula fee shares");

        // The collateral leg splits at the _scaleAssetClaims rate; conservation is wei-exact on the single leg
        uint256 executorLeg = (_bonusWAD == 0) ? 0 : stJtVault.balanceOf(EXECUTOR);
        uint256 receiverLeg = stJtVault.balanceOf(USER_B);
        assertEq(receiverLeg, toUint256(userClaims.collateralAssets), "the receiver must get exactly the reported user claims");
        if (_bonusWAD != 0) {
            assertEq(executorLeg, Math.mulDiv(executorLeg + receiverLeg, _bonusWAD, 1e18), "the executor's collateral slice must equal the flooring scaled-claims fraction");
        }
        assertEq(stJtVault.balanceOf(address(entryPoint)), 0, "no claim assets may remain in the entry point");
        // The forfeited shares stay escrowed as protocol fee shares, nothing else
        assertEq(IERC20(_tranche).balanceOf(address(entryPoint)), entryPoint.getProtocolFeeSharesPendingCollection(_tranche), "the entry point must hold exactly the pending fee shares");
        // The receiver's claim value is the request-time pin scaled by the post-bonus fraction (approx: conversion dust only)
        uint256 expectedNav = (_bonusWAD == 0) ? vReq : Math.mulDiv(vReq, 1e18 - _bonusWAD, 1e18);
        assertApproxEqRel(toUint256(userClaims.nav), expectedNav, 0.001e18, "the receiver must be pinned to the (bonus-scaled) request-time value");
    }

    function test_redemptionMatrix_stGain_inKind_self_exactSkim() public {
        _runStJtCell(address(seniorTranche), 0);
    }

    function test_redemptionMatrix_stGain_inKind_bonus_exactSkimAndSplit() public {
        _runStJtCell(address(seniorTranche), DEFAULT_EXECUTOR_BONUS);
    }

    function test_redemptionMatrix_jtGain_inKind_self_exactSkim() public {
        _runStJtCell(address(juniorTranche), 0);
    }

    function test_redemptionMatrix_jtGain_inKind_bonus_exactSkimAndSplit() public {
        _runStJtCell(address(juniorTranche), DEFAULT_EXECUTOR_BONUS);
    }

    /// @dev Loss control: a value drop during the queue skims nothing on either tranche
    function test_redemptionMatrix_stJtLoss_skimsNothing() public {
        uint256 stShares = _acquireTrancheShares(USER_A, address(seniorTranche), 10 * stUnit);
        uint256 jtShares = _acquireTrancheShares(USER_B, address(juniorTranche), 10 * stUnit);
        (uint256 stNonce,) = _requestRedemption(USER_A, address(seniorTranche), stShares, USER_A, 0, IRoycoDayEntryPoint.RedemptionMode.INKIND);
        (uint256 jtNonce,) = _requestRedemption(USER_B, address(juniorTranche), jtShares, USER_B, 0, IRoycoDayEntryPoint.RedemptionMode.INKIND);

        applySTPnL(-300);
        _warpPastRedemptionDelay();

        _executeRedemptionMax(USER_A, USER_A, stNonce);
        assertEq(entryPoint.getProtocolFeeSharesPendingCollection(address(seniorTranche)), 0, "an ST value drop must skim nothing");
        // The JT redemption stays coverage-gated after the drawdown only if coverage breaks; a -3% covered move keeps it open
        _executeRedemptionMax(USER_B, USER_B, jtNonce);
        assertEq(entryPoint.getProtocolFeeSharesPendingCollection(address(juniorTranche)), 0, "a JT value drop must skim nothing");
    }

    // ---------------------------------------------------------------------
    // LPT INKIND explicit mode + bonus: the BPT and idle senior-share legs both split exactly
    // ---------------------------------------------------------------------

    function test_redemptionMatrix_lptInKindMode_bonus_splitsBptAndIdleStLegs() public {
        // Stage an idle premium so the in-kind exit pays BOTH legs (armed slippage fails the reinvest gate)
        setVenueSlippageMode(true);
        applySTPnL(1000);
        _sync();
        require(kernel.getState().lptOwnedSeniorTrancheShares > 0, "setup: an idle senior-share premium must be staged");

        uint256 shares = _acquireTrancheShares(USER_A, address(liquidityProviderTranche), 20e18);
        (uint256 nonce,) =
            _requestRedemption(USER_A, address(liquidityProviderTranche), shares, USER_B, DEFAULT_EXECUTOR_BONUS, IRoycoDayEntryPoint.RedemptionMode.INKIND);
        _warpPastRedemptionDelay();

        AssetClaims memory userClaims = _executeRedemptionMax(EXECUTOR, USER_A, nonce);

        // A flat queue skims nothing: the whole redemption output splits between receiver and executor
        assertEq(entryPoint.getProtocolFeeSharesPendingCollection(address(liquidityProviderTranche)), 0, "a flat queue must skim nothing");
        uint256 executorBpt = bpt.balanceOf(EXECUTOR);
        uint256 executorStShares = seniorTranche.balanceOf(EXECUTOR);
        assertGt(executorBpt, 0, "the executor must receive its BPT bonus slice");
        assertGt(executorStShares, 0, "the executor must receive its idle senior-share bonus slice");
        assertEq(bpt.balanceOf(USER_B), toUint256(userClaims.lptAssets), "the receiver must get the post-bonus BPT leg");
        assertEq(seniorTranche.balanceOf(USER_B), userClaims.stShares, "the receiver must get the post-bonus senior-share leg");
        assertEq(
            executorBpt,
            Math.mulDiv(executorBpt + toUint256(userClaims.lptAssets), DEFAULT_EXECUTOR_BONUS, 1e18),
            "the BPT bonus slice must equal the flooring scaled-claims fraction"
        );
        assertEq(
            executorStShares,
            Math.mulDiv(executorStShares + userClaims.stShares, DEFAULT_EXECUTOR_BONUS, 1e18),
            "the senior-share bonus slice must equal the flooring scaled-claims fraction"
        );
        assertEq(bpt.balanceOf(address(entryPoint)), 0, "no BPT may remain in the entry point");
        assertEq(seniorTranche.balanceOf(address(entryPoint)), 0, "no senior shares may remain in the entry point");
    }

    // ---------------------------------------------------------------------
    // LPT MULTIASSET mode + queued yield + bonus: the skim is exact, then every leg splits
    // ---------------------------------------------------------------------

    function test_redemptionMatrix_lptMultiAssetMode_gainWithBonus_skimsThenSplitsAllLanes() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(liquidityProviderTranche), 40e18);
        // Redeem half the position multi-asset so the amount sits comfortably inside the multi-asset bound
        uint256 redeemShares = shares / 2;
        (uint256 nonce,) = _requestRedemption(
            USER_A, address(liquidityProviderTranche), redeemShares, USER_B, DEFAULT_EXECUTOR_BONUS, IRoycoDayEntryPoint.RedemptionMode.MULTIASSET
        );
        uint256 vReq = toUint256(entryPoint.getRedemptionRequest(USER_A, nonce).valueAtRequestTime);
        assertEq(vReq, _valueOf(address(liquidityProviderTranche), redeemShares), "the stored snapshot must equal the derived pro-rata claim");

        // The LP-token mark appreciates while queued: the skim must equal the exact value-formula fee
        applyLPTPnL(1000);
        _warpPastRedemptionDelay();
        uint256 vExec = _valueOf(address(liquidityProviderTranche), redeemShares);
        uint256 expectedFee = _expectedSkim(redeemShares, vReq, vExec);
        assertGt(expectedFee, 0, "sanity: the queued BPT gain must produce a nonzero skim");

        vm.prank(EXECUTOR);
        (AssetClaims memory userClaims, uint256 userQuote) = entryPoint.executeRedemption(USER_A, nonce, redeemShares);

        assertEq(
            entryPoint.getProtocolFeeSharesPendingCollection(address(liquidityProviderTranche)),
            expectedFee,
            "the multi-asset skim must equal the exact value-formula fee shares"
        );
        // The route was forced multi-asset by the request's mode: a quote leg must have been paid
        assertGt(userQuote, 0, "MULTIASSET mode must exit multi-asset even within the in-kind bound");

        // The quote leg splits at the plain flooring bonus rate, receiver first
        uint256 executorQuote = quoteToken.balanceOf(EXECUTOR);
        assertEq(quoteToken.balanceOf(USER_B), userQuote, "the receiver must get the post-bonus quote remainder");
        assertEq(executorQuote, Math.mulDiv(executorQuote + userQuote, DEFAULT_EXECUTOR_BONUS, 1e18), "the quote bonus slice must equal the flooring bonus fraction");
        // The constituent leg splits at the scaled-claims rate
        uint256 executorConstituent = stJtVault.balanceOf(EXECUTOR);
        assertEq(stJtVault.balanceOf(USER_B), toUint256(userClaims.collateralAssets), "the receiver must get the post-bonus constituent leg");
        assertEq(
            executorConstituent,
            Math.mulDiv(executorConstituent + toUint256(userClaims.collateralAssets), DEFAULT_EXECUTOR_BONUS, 1e18),
            "the constituent bonus slice must equal the flooring scaled-claims fraction"
        );
        // Nothing stranded beyond the skimmed fee shares
        assertEq(quoteToken.balanceOf(address(entryPoint)), 0, "no quote may remain in the entry point");
        assertEq(stJtVault.balanceOf(address(entryPoint)), 0, "no constituent assets may remain in the entry point");
        assertEq(
            liquidityProviderTranche.balanceOf(address(entryPoint)),
            entryPoint.getProtocolFeeSharesPendingCollection(address(liquidityProviderTranche)),
            "the entry point must hold exactly the skimmed fee shares"
        );
    }

    // ---------------------------------------------------------------------
    // Route independence: identical requests under identical PnL skim per the same value formula on both routes
    // ---------------------------------------------------------------------

    function test_redemptionMatrix_skimIsRouteIndependent_inKindVsMultiAsset() public {
        uint256 sharesA = _acquireTrancheShares(USER_A, address(liquidityProviderTranche), 20e18);
        uint256 sharesB = _acquireTrancheShares(USER_B, address(liquidityProviderTranche), 20e18);
        uint256 redeemShares = Math.min(sharesA, sharesB) / 2;
        (uint256 nonceA,) =
            _requestRedemption(USER_A, address(liquidityProviderTranche), redeemShares, USER_A, 0, IRoycoDayEntryPoint.RedemptionMode.INKIND);
        (uint256 nonceB,) =
            _requestRedemption(USER_B, address(liquidityProviderTranche), redeemShares, USER_B, 0, IRoycoDayEntryPoint.RedemptionMode.MULTIASSET);
        uint256 vReqA = toUint256(entryPoint.getRedemptionRequest(USER_A, nonceA).valueAtRequestTime);
        uint256 vReqB = toUint256(entryPoint.getRedemptionRequest(USER_B, nonceB).valueAtRequestTime);
        assertEq(vReqA, vReqB, "identical requests in the same block must snapshot identical values");

        applyLPTPnL(1000);
        _warpPastRedemptionDelay();

        // Each execution's skim matches the value formula computed on its own pre-execution state: the route never
        // enters the formula (A's in-kind execution shifts state, so B's expectation is derived after A lands)
        uint256 expectedFeeA = _expectedSkim(redeemShares, vReqA, _valueOf(address(liquidityProviderTranche), redeemShares));
        _executeRedemption(USER_A, USER_A, nonceA, redeemShares);
        uint256 feeAfterA = entryPoint.getProtocolFeeSharesPendingCollection(address(liquidityProviderTranche));
        assertEq(feeAfterA, expectedFeeA, "the in-kind skim must equal the exact value-formula fee");

        uint256 expectedFeeB = _expectedSkim(redeemShares, vReqB, _valueOf(address(liquidityProviderTranche), redeemShares));
        vm.prank(USER_B);
        (, uint256 quoteAssets) = entryPoint.executeRedemption(USER_B, nonceB, redeemShares);
        assertGt(quoteAssets, 0, "sanity: B must exit multi-asset");
        assertEq(
            entryPoint.getProtocolFeeSharesPendingCollection(address(liquidityProviderTranche)) - feeAfterA,
            expectedFeeB,
            "the multi-asset skim must equal the exact value-formula fee"
        );
        // Route independence: both skims come from the same formula over near-identical states
        assertApproxEqAbs(expectedFeeA, expectedFeeB, expectedFeeA / 100, "the two routes must skim materially identical fees");
    }
}
