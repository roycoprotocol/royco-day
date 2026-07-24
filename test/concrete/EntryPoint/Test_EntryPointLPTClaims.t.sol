// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { EntryPointTestBase } from "../../utils/EntryPointTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_EntryPointLPTClaims
 * @notice Day-specific multi-leg claim semantics through the entry point: an LPT redemption pays BOTH a BPT leg
 *         (lptAssets) and a senior-tranche-share leg (stShares, the idle liquidity premium paid in kind), and the
 *         executor bonus split must scale and forward every leg
 * @dev Also pins the entry point's LT forfeiture quote basis: previewRedeem runs the real redemption path, so the
 *      snapshot INCLUDES the idle liquidity-premium senior-share leg (unlike convertToAssets, whose LT branch zeroes
 *      stShares and floors to ltRawNAV). Because the idle leg is in the reference at both request and execution, a
 *      premium held constant registers no fake yield AND a premium reinvested into the pool during the queue (a
 *      value-neutral rebalance) is no longer mis-read as forfeitable yield
 */
contract Test_EntryPointLPTClaims is EntryPointTestBase {
    uint256 internal stUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.collateralAsset.decimals);
        _seedMarket(100 * stUnit, 50 * stUnit);
        _deployEntryPoint();
        _stageIdlePremium();
    }

    /// @dev Stages an idle liquidity premium: armed venue slippage makes the premium's reinvest gate fail, so the
    ///      kernel holds the premium as idle senior tranche shares that LPT redemptions pay out in kind
    function _stageIdlePremium() internal {
        setVenueSlippageMode(true);
        applySTPnL(1000);
        _sync();
        assertGt(kernel.getState().lptOwnedSeniorTrancheShares, 0, "the fixture must stage an idle senior-share premium");
    }

    function test_lptRedemption_paysBptAndSeniorShareLegs() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(liquidityProviderTranche), 20e18);
        (uint256 nonce,) = _requestRedemption(USER_A, address(liquidityProviderTranche), shares, USER_B, 0);
        _warpPastRedemptionDelay();

        uint256 receiverBptBefore = bpt.balanceOf(USER_B);
        uint256 receiverStSharesBefore = seniorTranche.balanceOf(USER_B);
        AssetClaims memory claims = _executeRedemptionMax(USER_A, USER_A, nonce);

        assertGt(toUint256(claims.lptAssets), 0, "the LPT redemption must pay a BPT leg");
        assertGt(claims.stShares, 0, "the LPT redemption must pay the idle premium's senior-share leg in kind");
        assertEq(bpt.balanceOf(USER_B) - receiverBptBefore, toUint256(claims.lptAssets), "the BPT leg must land on the receiver");
        assertEq(seniorTranche.balanceOf(USER_B) - receiverStSharesBefore, claims.stShares, "the senior-share leg must land on the receiver");
    }

    function test_lptRedemption_thirdParty_splitsAllLegsBetweenExecutorAndReceiver() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(liquidityProviderTranche), 20e18);
        (uint256 nonce,) = _requestRedemption(USER_A, address(liquidityProviderTranche), shares, USER_B, DEFAULT_EXECUTOR_BONUS);
        _warpPastRedemptionDelay();

        uint256 executorBptBefore = bpt.balanceOf(EXECUTOR);
        uint256 executorStSharesBefore = seniorTranche.balanceOf(EXECUTOR);
        AssetClaims memory userClaims = _executeRedemptionMax(EXECUTOR, USER_A, nonce);

        uint256 executorBpt = bpt.balanceOf(EXECUTOR) - executorBptBefore;
        uint256 executorStShares = seniorTranche.balanceOf(EXECUTOR) - executorStSharesBefore;
        assertGt(executorBpt, 0, "the executor must receive its BPT bonus slice");
        assertGt(executorStShares, 0, "the executor must receive its senior-share bonus slice");
        // Conservation per leg: executor slice + user claims == the total claims redeemed
        uint256 totalBpt = executorBpt + toUint256(userClaims.lptAssets);
        uint256 totalStShares = executorStShares + userClaims.stShares;
        assertEq(bpt.balanceOf(USER_B), toUint256(userClaims.lptAssets), "the receiver must get the post-bonus BPT leg");
        assertEq(seniorTranche.balanceOf(USER_B), userClaims.stShares, "the receiver must get the post-bonus senior-share leg");
        // The executor slice is the flooring bonus fraction of each leg. The bonus is a _scaleAssetClaims slice
        // priced against the virtual-shares effective denominator (WAD + 1e6), not WAD, so the derivation divides
        // by (1e18 + 1e6). totalBpt/totalStShares are the actual (bonus + receiver) totals redeemed.
        assertEq(executorBpt, (totalBpt * DEFAULT_EXECUTOR_BONUS) / (1e18 + 1e6), "the BPT bonus slice must equal the flooring bonus fraction");
        assertEq(executorStShares, (totalStShares * DEFAULT_EXECUTOR_BONUS) / (1e18 + 1e6), "the senior-share bonus slice must equal the flooring bonus fraction");
        // Nothing may be left stranded in the entry point
        assertEq(bpt.balanceOf(address(entryPoint)), 0, "no BPT may remain in the entry point after the split");
        assertEq(seniorTranche.balanceOf(address(entryPoint)), 0, "no senior shares may remain in the entry point after the split");
    }

    function test_lptForfeitureBasis_idlePremiumHeldConstant_registersNoFakeYield() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(liquidityProviderTranche), 20e18);
        (uint256 nonce,) = _requestRedemption(USER_A, address(liquidityProviderTranche), shares, USER_A, 0);

        // The quote basis is the gate-free totalAssets view scaled by the share fraction: it INCLUDES the idle premium
        // leg (so it sits strictly above the BPT-only convertToAssets floor while a premium is staged)
        IRoycoDayEntryPoint.RedemptionRequest memory request = entryPoint.getRedemptionRequest(USER_A, nonce);
        assertEq(
            toUint256(request.valueAtRequestTime),
            (toUint256(liquidityProviderTranche.totalAssets().nav) * shares) / liquidityProviderTranche.totalSupply(),
            "the LT nav snapshot must use the totalAssets basis scaled by the share fraction"
        );
        assertGt(
            toUint256(request.valueAtRequestTime),
            toUint256(liquidityProviderTranche.convertToAssets(shares).nav),
            "the totalAssets basis must sit strictly above the BPT-only floor while an idle premium is staged"
        );

        // Nothing moves while queued: the same basis at execution must register zero forfeiture
        _warpPastRedemptionDelay();
        _executeRedemptionMax(USER_A, USER_A, nonce);
        assertEq(
            entryPoint.getProtocolFeeSharesPendingCollection(address(liquidityProviderTranche)),
            0,
            "an idle premium held constant across the request lifecycle must not be forfeited as yield"
        );
    }

    /// @notice The reason for the previewRedeem basis: a premium REINVESTED into the pool during the queue is a
    ///         value-neutral rebalance (idle senior shares become BPT depth at the manipulation-resistant mark), so
    ///         including the idle leg in the reference means it registers (near) zero forfeiture rather than the fake
    ///         yield the old BPT-only convertToAssets floor booked. The tiny reinvest slippage reads as negative
    ///         yield borne by the redeemer, so forfeiture stays zero
    function test_ltForfeitureBasis_premiumReinvestedDuringQueue_registersNoFakeYield() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(liquidityProviderTranche), 20e18);
        (uint256 nonce,) = _requestRedemption(USER_A, address(liquidityProviderTranche), shares, USER_A, 0);
        require(kernel.getState().lptOwnedSeniorTrancheShares > 0, "setup: an idle premium must be staged at request time");

        // Disarm the venue slippage and reinvest the staged idle premium into the pool during the queue (an explicit
        // reinvest of the whole idle balance, a plain sync does not re-attempt reinvestment of an already-idle pile)
        setVenueSlippageMode(false);
        vm.prank(MARKET_REINVEST_LIQUIDITY_PREMIUM_ADMIN);
        kernel.reinvestLiquidityPremium(type(uint256).max);
        _warpPastRedemptionDelay();
        require(kernel.getState().lptOwnedSeniorTrancheShares == 0, "setup: the idle premium must have reinvested into the pool during the queue");

        // The reinvestment moved value from the idle leg into the BPT leg with no net gain, so the previewRedeem
        // reference tracks it and no fake yield is forfeited (the old convertToAssets floor would have booked the
        // whole reinvested premium as forfeitable yield here)
        _executeRedemptionMax(USER_A, USER_A, nonce);
        assertEq(
            entryPoint.getProtocolFeeSharesPendingCollection(address(liquidityProviderTranche)),
            0,
            "a value-neutral premium reinvestment during the queue must not be forfeited as fake yield"
        );
    }

    function test_ltDepositForfeiture_cappedAtRequestTimeShareReference() public {
        // Share basis: the depositor keeps min(shares the deposit would have minted at request, shares it mints now),
        // and any excess minted now is forfeited to the protocol. The BPT appreciates during the queue while the LT
        // share price rises less (the staged idle premium dilutes the gain), so execution mints more than the
        // request-time reference and the excess is skimmed
        (uint256 nonce,) = _requestDeposit(USER_A, address(liquidityProviderTranche), 10e18, USER_A, 0);
        uint256 sharesRef = entryPoint.getDepositRequest(USER_A, nonce).equivalentSharesAtRequestTime;

        applyLPTPnL(1000);
        _warpPastDepositDelay();

        // The shares this deposit mints at execution, the execution-stage leg of the min (equals the amount the
        // execute below mints, by construction of previewDeposit)
        uint256 sharesExec = liquidityProviderTranche.previewDeposit(toTrancheUnits(10e18));
        uint256 feeBefore = entryPoint.getProtocolFeeSharesPendingCollection(address(liquidityProviderTranche));
        uint256 userShares = _executeDepositMax(USER_A, USER_A, nonce);
        uint256 forfeited = entryPoint.getProtocolFeeSharesPendingCollection(address(liquidityProviderTranche)) - feeBefore;

        assertLe(userShares, sharesRef, "the LT depositor is capped at the request-time share reference");
        assertEq(userShares, Math.min(sharesRef, sharesExec), "the user keeps the lower of the request-time and execution-time share counts");
        assertEq(userShares + forfeited, sharesExec, "the minted shares split exactly into the user's capped amount and the forfeited excess");
    }

    function test_stClaims_coveredLoss_navHeldWholeByJuniorCoverage() public {
        // A covered drawdown is absorbed entirely by the junior tranche: the attributed senior loss lands on JT as
        // impermanent loss, so the senior claim's NAV is byte-identical across the loss while its collateral leg
        // grows (the same value converts to more of the cheaper collateral). The market enters FIXED_TERM on the
        // covered loss, so the coverage is pinned via preview rather than an executed redemption
        uint256 shares = _acquireTrancheShares(USER_A, address(seniorTranche), 10 * stUnit);
        AssetClaims memory before = seniorTranche.convertToAssets(shares);
        applySTPnL(-500);
        AssetClaims memory previewed = seniorTranche.convertToAssets(shares);
        assertEq(toUint256(previewed.nav), toUint256(before.nav), "junior coverage must hold the senior claim NAV exactly whole across a covered loss");
        assertGt(
            toUint256(previewed.collateralAssets), toUint256(before.collateralAssets), "the whole NAV must convert to strictly more of the cheaper collateral"
        );
    }
}
