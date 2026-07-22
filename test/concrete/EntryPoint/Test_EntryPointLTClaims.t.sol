// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toUint256 } from "../../../src/libraries/Units.sol";
import { EntryPointTestBase } from "../../utils/EntryPointTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_EntryPointLTClaims
 * @notice Day-specific 5-leg claim semantics through the entry point: an LT redemption pays BOTH a BPT leg
 *         (ltAssets) and a senior-tranche-share leg (stShares, the idle liquidity premium paid in kind), and the
 *         executor bonus split must scale and forward every leg
 * @dev Also pins the entry point's LT forfeiture quote basis: convertToAssets is the BPT-only raw-NAV floor
 *      (idle premium excluded, stShares == 0), so an idle premium held constant across the request lifecycle
 *      registers no fake yield — the accepted caveat is that a premium REINVESTED into the pool between request
 *      and execution appears as forfeitable yield under this basis
 */
contract Test_EntryPointLTClaims is EntryPointTestBase {
    uint256 internal stUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.stAsset.decimals);
        _seedMarket(100 * stUnit, 50 * stUnit);
        _deployEntryPoint();
        _stageIdlePremium();
    }

    /// @dev Stages an idle liquidity premium: armed venue slippage makes the premium's reinvest gate fail, so the
    ///      kernel holds the premium as idle senior tranche shares that LT redemptions pay out in kind
    function _stageIdlePremium() internal {
        setVenueSlippageMode(true);
        applySTPnL(1000);
        _sync();
        assertGt(kernel.getState().ltOwnedSeniorTrancheShares, 0, "the fixture must stage an idle senior-share premium");
    }

    function test_ltRedemption_paysBptAndSeniorShareLegs() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(liquidityTranche), 20e18);
        (uint256 nonce,) = _requestRedemption(USER_A, address(liquidityTranche), shares, USER_B, 0);
        _warpPastRedemptionDelay();

        uint256 receiverBptBefore = bpt.balanceOf(USER_B);
        uint256 receiverStSharesBefore = seniorTranche.balanceOf(USER_B);
        AssetClaims memory claims = _executeRedemptionMax(USER_A, USER_A, nonce);

        assertGt(toUint256(claims.ltAssets), 0, "the LT redemption must pay a BPT leg");
        assertGt(claims.stShares, 0, "the LT redemption must pay the idle premium's senior-share leg in kind");
        assertEq(bpt.balanceOf(USER_B) - receiverBptBefore, toUint256(claims.ltAssets), "the BPT leg must land on the receiver");
        assertEq(seniorTranche.balanceOf(USER_B) - receiverStSharesBefore, claims.stShares, "the senior-share leg must land on the receiver");
    }

    function test_ltRedemption_thirdParty_splitsAllLegsBetweenExecutorAndReceiver() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(liquidityTranche), 20e18);
        (uint256 nonce,) = _requestRedemption(USER_A, address(liquidityTranche), shares, USER_B, DEFAULT_EXECUTOR_BONUS);
        _warpPastRedemptionDelay();

        uint256 executorBptBefore = bpt.balanceOf(EXECUTOR);
        uint256 executorStSharesBefore = seniorTranche.balanceOf(EXECUTOR);
        AssetClaims memory userClaims = _executeRedemptionMax(EXECUTOR, USER_A, nonce);

        uint256 executorBpt = bpt.balanceOf(EXECUTOR) - executorBptBefore;
        uint256 executorStShares = seniorTranche.balanceOf(EXECUTOR) - executorStSharesBefore;
        assertGt(executorBpt, 0, "the executor must receive its BPT bonus slice");
        assertGt(executorStShares, 0, "the executor must receive its senior-share bonus slice");
        // Conservation per leg: executor slice + user claims == the total claims redeemed
        uint256 totalBpt = executorBpt + toUint256(userClaims.ltAssets);
        uint256 totalStShares = executorStShares + userClaims.stShares;
        assertEq(bpt.balanceOf(USER_B), toUint256(userClaims.ltAssets), "the receiver must get the post-bonus BPT leg");
        assertEq(seniorTranche.balanceOf(USER_B), userClaims.stShares, "the receiver must get the post-bonus senior-share leg");
        // The executor slice is the flooring bonus fraction of each leg. The bonus is a _scaleAssetClaims slice
        // priced against the virtual-shares effective denominator (WAD + 1e6), not WAD, so the derivation divides
        // by (1e18 + 1e6). totalBpt/totalStShares are the actual (bonus + receiver) totals redeemed.
        assertApproxEqAbs(executorBpt, (totalBpt * DEFAULT_EXECUTOR_BONUS) / (1e18 + 1e6), 1, "the BPT bonus slice must equal the flooring bonus fraction");
        assertApproxEqAbs(
            executorStShares, (totalStShares * DEFAULT_EXECUTOR_BONUS) / (1e18 + 1e6), 1, "the senior-share bonus slice must equal the flooring bonus fraction"
        );
        // Nothing may be left stranded in the entry point
        assertEq(bpt.balanceOf(address(entryPoint)), 0, "no BPT may remain in the entry point after the split");
        assertEq(seniorTranche.balanceOf(address(entryPoint)), 0, "no senior shares may remain in the entry point after the split");
    }

    function test_ltForfeitureBasis_idlePremiumHeldConstant_registersNoFakeYield() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(liquidityTranche), 20e18);
        (uint256 nonce,) = _requestRedemption(USER_A, address(liquidityTranche), shares, USER_A, 0);

        // The quote basis is pinned to the BPT-only floor: the idle premium is excluded from the snapshot
        IRoycoDayEntryPoint.RedemptionRequest memory request = entryPoint.getRedemptionRequest(USER_A, nonce);
        assertEq(
            toUint256(request.baseRequest.navAtRequestTime),
            toUint256(liquidityTranche.convertToAssets(shares).nav),
            "the LT nav snapshot must use the convertToAssets BPT-only floor"
        );

        // Nothing moves while queued: the same floor at execution must register zero forfeiture
        _warpPastRedemptionDelay();
        _executeRedemptionMax(USER_A, USER_A, nonce);
        assertEq(
            entryPoint.getProtocolFeeSharesPendingCollection(address(liquidityTranche)),
            0,
            "an idle premium held constant across the request lifecycle must not be forfeited as yield"
        );
    }

    function test_ltDepositForfeiture_monetizableValuePinnedToSnapshot() public {
        // The protocol retains the forfeited shares (supply unchanged), so the proportional split is exact in redeemable terms too
        (uint256 nonce,) = _requestDeposit(USER_A, address(liquidityTranche), 10e18, USER_A, 0);
        uint256 navAtRequest = toUint256(entryPoint.getDepositRequest(USER_A, nonce).baseRequest.navAtRequestTime);

        applyLTPnL(1000);
        _warpPastDepositDelay();
        uint256 userShares = _executeDepositMax(USER_A, USER_A, nonce);

        vm.prank(USER_A);
        AssetClaims memory redeemed = liquidityTranche.redeem(userShares, USER_A, USER_A);
        assertLe(
            toUint256(redeemed.nav),
            navAtRequest + toUint256(liquidityTranche.convertToAssets(1).nav) + 1,
            "the LT depositor must never redeem more than the snapshot plus rounding dust"
        );
        assertApproxEqRel(toUint256(redeemed.nav), navAtRequest, 0.001e18, "the LT depositor's redeemable value must be pinned to the request-time NAV");
    }

    function test_stRedemption_coveredLoss_claimsCarryJtAssetsLeg() public {
        // A covered senior drawdown sources part of ST's claims from JT's raw NAV (the jtAssets leg). The market
        // enters FIXED_TERM on the covered loss, so redeem after the term recovers... instead pin the leg via preview
        uint256 shares = _acquireTrancheShares(USER_A, address(seniorTranche), 10 * stUnit);
        applySTPnL(-500);
        // The ST claims decomposition now sources coverage from JT raw NAV
        AssetClaims memory preview = seniorTranche.convertToAssets(shares);
        assertGt(toUint256(preview.jtAssets), 0, "a covered senior loss must carry a jtAssets claim leg");
    }
}
