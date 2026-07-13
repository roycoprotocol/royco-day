// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE, BURNER_ROLE } from "../../../src/factory/RolesConfiguration.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { EntryPointTestBase } from "../../utils/EntryPointTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_EntryPointYieldForfeiture
 * @notice The yield-neutrality property in BOTH queue directions: any positive NAV delta on escrowed deposit assets
 *         or redemption shares between request and execution is forfeited to the configured recipient (PROTOCOL
 *         accounting, REMAINING_LPS burn), and losses are never forfeited
 * @dev This is the free-option kill: a queued request can never gain value over its request-time NAV, so timing
 *      execution or cancellation against oracle updates confers nothing
 */
contract Test_EntryPointYieldForfeiture is EntryPointTestBase {
    uint256 internal stUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.stAsset.decimals);
        _seedMarket(100 * stUnit, 50 * stUnit);
        _deployEntryPoint();
    }

    /// @dev Rewrites all three tranche configs with the specified yield recipient (delays unchanged)
    function _setYieldRecipient(IRoycoDayEntryPoint.AccruedYieldRecipient _recipient) internal {
        (address[] memory tranches, IRoycoDayEntryPoint.TrancheConfig[] memory configs) = _defaultTrancheConfigs();
        for (uint256 i = 0; i < configs.length; ++i) {
            configs[i].yieldRecipient = _recipient;
        }
        vm.prank(ENTRY_POINT_ADMIN);
        entryPoint.modifyTrancheConfigs(tranches, configs);
    }

    // ---------------------------------------------------------------------
    // Deposit queue — PROTOCOL recipient (fixture default)
    // ---------------------------------------------------------------------

    function test_depositForfeiture_yieldAccruedInQueue_accruesToProtocol() public {
        uint256 amount = 10 * stUnit;
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), amount, USER_A, 0);
        uint256 navAtRequest = toUint256(entryPoint.getDepositRequest(USER_A, nonce).navAtRequestTime);

        // The escrowed vault shares appreciate 10% while queued
        applySTPnL(1000);
        _warpPastDepositDelay();

        uint256 userShares = _executeDepositMax(USER_A, USER_A, nonce);
        uint256 forfeited = entryPoint.getProtocolFeeSharesPendingCollection(address(juniorTranche));

        assertGt(forfeited, 0, "the queued yield must be forfeited to the protocol");
        assertEq(juniorTranche.balanceOf(address(entryPoint)), forfeited, "the forfeited shares must be held by the entry point");
        assertEq(juniorTranche.balanceOf(USER_A), userShares, "the user must receive only the post-forfeiture shares");
        // Yield neutrality: the user's shares are worth (approximately) the request-time NAV, not the appreciated NAV
        uint256 userNav = toUint256(juniorTranche.convertToAssets(userShares).nav);
        assertApproxEqRel(userNav, navAtRequest, 0.001e18, "the user's minted shares must be worth the request-time NAV");
    }

    function test_depositForfeiture_flatNav_mintsEverythingToReceiver() public {
        uint256 amount = 10 * stUnit;
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), amount, USER_A, 0);
        _warpPastDepositDelay();

        uint256 userShares = _executeDepositMax(USER_A, USER_A, nonce);
        assertEq(entryPoint.getProtocolFeeSharesPendingCollection(address(juniorTranche)), 0, "a flat queue must forfeit nothing");
        assertEq(juniorTranche.balanceOf(USER_A), userShares, "all shares must land on the receiver");
        assertEq(juniorTranche.balanceOf(address(entryPoint)), 0, "no shares may be routed through the entry point on the flat path");
    }

    function test_depositForfeiture_lossInQueue_forfeitsNothing() public {
        // An LT loss leaves the market PERPETUAL (JT never covers LT), so the deposit path stays open post-loss
        uint256 amount = 10e18;
        (uint256 nonce,) = _requestDeposit(USER_A, address(liquidityTranche), amount, USER_A, 0);

        applyLTPnL(-1000);
        _warpPastDepositDelay();

        uint256 userShares = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(userShares, 0, "the deposit must execute at the depreciated NAV");
        assertEq(entryPoint.getProtocolFeeSharesPendingCollection(address(liquidityTranche)), 0, "losses must never be forfeited");
    }

    function test_depositForfeiture_ltDeposit_bptAppreciationForfeited() public {
        uint256 amount = 10e18;
        (uint256 nonce,) = _requestDeposit(USER_A, address(liquidityTranche), amount, USER_A, 0);

        // The escrowed BPT appreciates 10% while queued
        applyLTPnL(1000);
        _warpPastDepositDelay();

        _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(entryPoint.getProtocolFeeSharesPendingCollection(address(liquidityTranche)), 0, "queued BPT appreciation must be forfeited");
    }

    // ---------------------------------------------------------------------
    // Deposit queue — REMAINING_LPS recipient
    // ---------------------------------------------------------------------

    function test_depositForfeiture_remainingLps_burnsForfeitedShares() public {
        _setYieldRecipient(IRoycoDayEntryPoint.AccruedYieldRecipient.REMAINING_LPS);
        uint256 amount = 10 * stUnit;
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), amount, USER_A, 0);

        applySTPnL(1000);
        _warpPastDepositDelay();
        // Flush the kernel's own yield attribution (protocol fee share mints) so the supply delta isolates the entry point
        _sync();

        uint256 supplyBefore = juniorTranche.totalSupply();
        uint256 userShares = _executeDepositMax(USER_A, USER_A, nonce);

        assertEq(entryPoint.getProtocolFeeSharesPendingCollection(address(juniorTranche)), 0, "REMAINING_LPS must not accrue protocol fees");
        assertEq(juniorTranche.balanceOf(address(entryPoint)), 0, "the forfeited shares must have been burned, not held");
        // The supply grew by only the user's shares: the forfeited portion was minted and immediately burned
        assertEq(juniorTranche.totalSupply(), supplyBefore + userShares, "the forfeited shares must be burned out of the supply");
    }

    function test_depositForfeiture_remainingLps_whaleDepositor_cannotRecaptureViaBurn() public {
        _setYieldRecipient(IRoycoDayEntryPoint.AccruedYieldRecipient.REMAINING_LPS);
        // A deposit ~10x the existing JT pool: under a naive proportional split the burn's supply reduction would
        // hand the depositor's fresh shares back ~90% of the forfeited yield
        uint256 amount = 500 * stUnit;
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), amount, USER_A, 0);
        uint256 navAtRequest = toUint256(entryPoint.getDepositRequest(USER_A, nonce).navAtRequestTime);

        applySTPnL(1000);
        _warpPastDepositDelay();
        uint256 userShares = _executeDepositMax(USER_A, USER_A, nonce);

        // The whale's post-burn share value must be pinned to the request-time NAV at ANY pool share
        uint256 userNav = toUint256(juniorTranche.convertToAssets(userShares).nav);
        assertLe(userNav, navAtRequest + toUint256(juniorTranche.convertToAssets(1).nav) + 1, "the whale must never clear more than the snapshot plus rounding dust");
        assertApproxEqRel(userNav, navAtRequest, 0.0001e18, "the whale's post-burn share value must be pinned to the request-time NAV (no burn recapture)");
    }

    function test_depositForfeiture_remainingLps_revertsWithoutBurnerRole() public {
        _setYieldRecipient(IRoycoDayEntryPoint.AccruedYieldRecipient.REMAINING_LPS);
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);

        applySTPnL(1000);
        _warpPastDepositDelay();

        accessManager.revokeRole(BURNER_ROLE, address(entryPoint));
        vm.expectRevert();
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));
    }

    // ---------------------------------------------------------------------
    // Redemption queue — the two recipients
    // ---------------------------------------------------------------------

    function test_redemptionForfeiture_yieldAccruedInQueue_accruesToProtocol() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_A, 0);
        uint256 navAtRequest = toUint256(entryPoint.getRedemptionRequest(USER_A, nonce).navAtRequestTime);

        applySTPnL(1000);
        _warpPastRedemptionDelay();

        AssetClaims memory claims = _executeRedemptionMax(USER_A, USER_A, nonce);
        uint256 forfeited = entryPoint.getProtocolFeeSharesPendingCollection(address(juniorTranche));

        assertGt(forfeited, 0, "the queued yield must be forfeited to the protocol");
        assertEq(juniorTranche.balanceOf(address(entryPoint)), forfeited, "the forfeited shares must be held by the entry point");
        assertApproxEqRel(toUint256(claims.nav), navAtRequest, 0.001e18, "the user's claims must be worth the request-time NAV");
    }

    function test_redemptionForfeiture_remainingLps_burnsForfeitedShares() public {
        _setYieldRecipient(IRoycoDayEntryPoint.AccruedYieldRecipient.REMAINING_LPS);
        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_A, 0);

        applySTPnL(1000);
        _warpPastRedemptionDelay();

        _executeRedemptionMax(USER_A, USER_A, nonce);
        assertEq(juniorTranche.balanceOf(address(entryPoint)), 0, "the forfeited shares must have been burned, not held");
        assertEq(entryPoint.getProtocolFeeSharesPendingCollection(address(juniorTranche)), 0, "REMAINING_LPS must not accrue protocol fees");
    }

    function test_redemptionForfeiture_lossInQueue_forfeitsNothing() public {
        // An LT loss leaves the market PERPETUAL (JT never covers LT), so the redemption path stays open post-loss
        uint256 shares = _acquireTrancheShares(USER_A, address(liquidityTranche), 10e18);
        (uint256 nonce,) = _requestRedemption(USER_A, address(liquidityTranche), shares, USER_A, 0);

        applyLTPnL(-1000);
        _warpPastRedemptionDelay();

        AssetClaims memory claims = _executeRedemptionMax(USER_A, USER_A, nonce);
        assertGt(toUint256(claims.nav), 0, "the redemption must execute at the depreciated NAV");
        assertEq(entryPoint.getProtocolFeeSharesPendingCollection(address(liquidityTranche)), 0, "losses must never be forfeited");
    }

    // ---------------------------------------------------------------------
    // Partial-execution conservation
    // ---------------------------------------------------------------------

    function test_depositForfeiture_partialExecutions_conserveTotalForfeiture() public {
        uint256 amount = 10 * stUnit;
        // Two identical requests, one executed in halves and one in full, under identical PnL
        (uint256 noncePartial,) = _requestDeposit(USER_A, address(juniorTranche), amount, USER_A, 0);
        (uint256 nonceFull,) = _requestDeposit(USER_B, address(juniorTranche), amount, USER_B, 0);

        applySTPnL(1000);
        _warpPastDepositDelay();

        _executeDeposit(USER_A, USER_A, noncePartial, amount / 2);
        _executeDepositMax(USER_A, USER_A, noncePartial);
        uint256 forfeitedAfterPartials = entryPoint.getProtocolFeeSharesPendingCollection(address(juniorTranche));

        _executeDepositMax(USER_B, USER_B, nonceFull);
        uint256 forfeitedByFull = entryPoint.getProtocolFeeSharesPendingCollection(address(juniorTranche)) - forfeitedAfterPartials;

        // The partial path may only differ from the single-shot path by flooring dust
        assertApproxEqAbs(forfeitedAfterPartials, forfeitedByFull, 2, "split execution must forfeit the same total as a single execution");
    }

    // ---------------------------------------------------------------------
    // collectProtocolFees
    // ---------------------------------------------------------------------

    function test_collectProtocolFees_specificAndMaxSweep() public {
        // Accrue protocol fee shares via a deposit-queue forfeiture
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        applySTPnL(1000);
        _warpPastDepositDelay();
        _executeDepositMax(USER_A, USER_A, nonce);
        uint256 accrued = entryPoint.getProtocolFeeSharesPendingCollection(address(juniorTranche));
        assertGt(accrued, 1, "the fixture must accrue more than one share-wei of fees");

        address[] memory tranches = new address[](1);
        tranches[0] = address(juniorTranche);
        uint256[] memory amounts = new uint256[](1);

        // Collect a specific amount
        amounts[0] = 1;
        vm.prank(FEE_COLLECTOR);
        entryPoint.collectProtocolFees(tranches, amounts, FEE_COLLECTOR);
        assertEq(entryPoint.getProtocolFeeSharesPendingCollection(address(juniorTranche)), accrued - 1, "the specific claim must decrement the accrual");

        // Sweep the remainder with the max sentinel
        amounts[0] = type(uint256).max;
        vm.prank(FEE_COLLECTOR);
        entryPoint.collectProtocolFees(tranches, amounts, FEE_COLLECTOR);
        assertEq(entryPoint.getProtocolFeeSharesPendingCollection(address(juniorTranche)), 0, "the max sweep must clear the accrual");
        assertEq(juniorTranche.balanceOf(FEE_COLLECTOR), accrued, "the collector must hold every accrued fee share");
    }

    function test_collectProtocolFees_overClaimReverts() public {
        // Accrue a known amount, then claiming more than accrued must underflow-revert rather than draw on escrow
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        applySTPnL(1000);
        _warpPastDepositDelay();
        _executeDepositMax(USER_A, USER_A, nonce);
        uint256 accrued = entryPoint.getProtocolFeeSharesPendingCollection(address(juniorTranche));

        address[] memory tranches = new address[](1);
        tranches[0] = address(juniorTranche);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = accrued + 1;
        vm.expectRevert();
        vm.prank(FEE_COLLECTOR);
        entryPoint.collectProtocolFees(tranches, amounts, FEE_COLLECTOR);
    }

    function test_collectProtocolFees_zeroAccrualIsSkipped() public {
        address[] memory tranches = new address[](1);
        tranches[0] = address(seniorTranche);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = type(uint256).max;
        vm.prank(FEE_COLLECTOR);
        entryPoint.collectProtocolFees(tranches, amounts, FEE_COLLECTOR);
        assertEq(seniorTranche.balanceOf(FEE_COLLECTOR), 0, "a zero accrual must be skipped without effect");
    }
}
