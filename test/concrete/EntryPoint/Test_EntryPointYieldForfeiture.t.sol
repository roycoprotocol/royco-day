// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { EntryPointTestBase, IERC20Like } from "../../utils/EntryPointTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_EntryPointYieldForfeiture
 * @notice The yield-neutrality property in BOTH queue directions: any positive NAV delta on escrowed deposit assets
 *         or redemption shares between request and execution is forfeited to the protocol as fee shares, and losses
 *         are never forfeited
 * @dev This is the free-option kill: a queued request can never gain value over its request-time NAV, so timing
 *      execution or cancellation against oracle updates confers nothing
 */
contract Test_EntryPointYieldForfeiture is EntryPointTestBase {
    uint256 internal stUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.collateralAsset.decimals);
        _seedMarket(100 * stUnit, 50 * stUnit);
        _deployEntryPoint();
    }

    // ---------------------------------------------------------------------
    // Deposit queue
    // ---------------------------------------------------------------------

    function test_depositForfeiture_yieldAccruedInQueue_accruesToProtocol() public {
        uint256 amount = 10 * stUnit;
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), amount, USER_A, 0);
        uint256 navAtRequest = toUint256(entryPoint.getDepositRequest(USER_A, nonce).baseRequest.navAtRequestTime);

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
        // An LPT loss leaves the market PERPETUAL (JT never covers LPT), so the deposit path stays open post-loss
        uint256 amount = 10e18;
        (uint256 nonce,) = _requestDeposit(USER_A, address(liquidityProviderTranche), amount, USER_A, 0);

        applyLPTPnL(-1000);
        _warpPastDepositDelay();

        uint256 userShares = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(userShares, 0, "the deposit must execute at the depreciated NAV");
        assertEq(entryPoint.getProtocolFeeSharesPendingCollection(address(liquidityProviderTranche)), 0, "losses must never be forfeited");
    }

    function test_depositForfeiture_lptDeposit_bptAppreciationForfeited() public {
        uint256 amount = 10e18;
        (uint256 nonce,) = _requestDeposit(USER_A, address(liquidityProviderTranche), amount, USER_A, 0);

        // The escrowed BPT appreciates 10% while queued
        applyLPTPnL(1000);
        _warpPastDepositDelay();

        _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(entryPoint.getProtocolFeeSharesPendingCollection(address(liquidityProviderTranche)), 0, "queued BPT appreciation must be forfeited");
    }

    // ---------------------------------------------------------------------
    // Redemption queue
    // ---------------------------------------------------------------------

    function test_redemptionForfeiture_yieldAccruedInQueue_accruesToProtocol() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_A, 0);
        uint256 navAtRequest = toUint256(entryPoint.getRedemptionRequest(USER_A, nonce).baseRequest.navAtRequestTime);

        applySTPnL(1000);
        _warpPastRedemptionDelay();

        AssetClaims memory claims = _executeRedemptionMax(USER_A, USER_A, nonce);
        uint256 forfeited = entryPoint.getProtocolFeeSharesPendingCollection(address(juniorTranche));

        assertGt(forfeited, 0, "the queued yield must be forfeited to the protocol");
        assertEq(juniorTranche.balanceOf(address(entryPoint)), forfeited, "the forfeited shares must be held by the entry point");
        assertApproxEqRel(toUint256(claims.nav), navAtRequest, 0.001e18, "the user's claims must be worth the request-time NAV");
    }

    function test_redemptionForfeiture_lossInQueue_forfeitsNothing() public {
        // An LPT loss leaves the market PERPETUAL (JT never covers LPT), so the redemption path stays open post-loss
        uint256 shares = _acquireTrancheShares(USER_A, address(liquidityProviderTranche), 10e18);
        (uint256 nonce,) = _requestRedemption(USER_A, address(liquidityProviderTranche), shares, USER_A, 0);

        applyLPTPnL(-1000);
        _warpPastRedemptionDelay();

        AssetClaims memory claims = _executeRedemptionMax(USER_A, USER_A, nonce);
        assertGt(toUint256(claims.nav), 0, "the redemption must execute at the depreciated NAV");
        assertEq(entryPoint.getProtocolFeeSharesPendingCollection(address(liquidityProviderTranche)), 0, "losses must never be forfeited");
    }

    function test_depositForfeiture_thirdPartyExecution_bonusScaledSnapshotStaysNeutral() public {
        // The gain x executor-bonus quadrant: the bonus is paid from the escrowed assets FIRST, so the neutrality pin
        // for the receiver is the snapshot scaled by the post-bonus remainder, the one line reconciling the two
        // mechanisms (the navAtRequestTime rescale on the third-party path) is only observable here
        uint256 amount = 10 * stUnit;
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), amount, USER_A, DEFAULT_EXECUTOR_BONUS);
        uint256 navAtRequest = toUint256(entryPoint.getDepositRequest(USER_A, nonce).baseRequest.navAtRequestTime);

        applySTPnL(1000);
        _warpPastDepositDelay();
        uint256 userShares = _executeDepositMax(EXECUTOR, USER_A, nonce);

        assertGt(entryPoint.getProtocolFeeSharesPendingCollection(address(juniorTranche)), 0, "the queued yield must still be forfeited under a bonus");
        // The receiver's pin is the request-time NAV scaled to the post-bonus deposit remainder
        uint256 bonusAssets = (amount * DEFAULT_EXECUTOR_BONUS) / 1e18;
        uint256 expectedNav = (navAtRequest * (amount - bonusAssets)) / amount;
        uint256 userNav = toUint256(juniorTranche.convertToAssets(userShares).nav);
        assertLe(
            userNav, expectedNav + toUint256(juniorTranche.convertToAssets(1).nav) + 1, "the receiver must never clear more than the bonus-scaled snapshot"
        );
        assertApproxEqRel(userNav, expectedNav, 0.001e18, "the receiver's shares must be pinned to the bonus-scaled request-time NAV");
    }

    function test_redemptionForfeiture_thirdPartyExecution_gainWithBonusStaysNeutral() public {
        // Redemption mirror of the gain x bonus quadrant: forfeiture settles on the full share amount first, then the
        // bonus split scales the resulting claims, so the receiver's pin is the snapshot scaled by (1 - bonus)
        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_B, DEFAULT_EXECUTOR_BONUS);
        uint256 navAtRequest = toUint256(entryPoint.getRedemptionRequest(USER_A, nonce).baseRequest.navAtRequestTime);

        applySTPnL(1000);
        _warpPastRedemptionDelay();
        AssetClaims memory userClaims = _executeRedemptionMax(EXECUTOR, USER_A, nonce);

        assertGt(entryPoint.getProtocolFeeSharesPendingCollection(address(juniorTranche)), 0, "the queued yield must still be forfeited under a bonus");
        uint256 expectedNav = (navAtRequest * (1e18 - DEFAULT_EXECUTOR_BONUS)) / 1e18;
        assertApproxEqRel(toUint256(userClaims.nav), expectedNav, 0.001e18, "the receiver's claims must be pinned to the bonus-scaled request-time NAV");
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

    function test_depositForfeiture_partialThirdPartyExecutions_composeBothRescalings() public {
        // The partial+bonus quadrant: each third-party slice composes the pro-rata storage rescale of the
        // nav snapshot with the per-slice bonus rescale, the receiver's total must still land on the
        // bonus-scaled request-time NAV
        uint256 amount = 10 * stUnit;
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), amount, USER_A, DEFAULT_EXECUTOR_BONUS);
        uint256 navAtRequest = toUint256(entryPoint.getDepositRequest(USER_A, nonce).baseRequest.navAtRequestTime);

        applySTPnL(1000);
        _warpPastDepositDelay();
        uint256 userShares = _executeDeposit(EXECUTOR, USER_A, nonce, amount / 2);
        userShares += _executeDepositMax(EXECUTOR, USER_A, nonce);

        assertGt(entryPoint.getProtocolFeeSharesPendingCollection(address(juniorTranche)), 0, "the queued yield must be forfeited across bonus slices");
        uint256 bonusAssets = (amount * DEFAULT_EXECUTOR_BONUS) / 1e18;
        uint256 expectedNav = (navAtRequest * (amount - bonusAssets)) / amount;
        uint256 userNav = toUint256(juniorTranche.convertToAssets(userShares).nav);
        assertLe(
            userNav,
            expectedNav + 2 * toUint256(juniorTranche.convertToAssets(1).nav) + 2,
            "split bonus execution must never clear more than the bonus-scaled snapshot plus per-slice dust"
        );
        assertApproxEqRel(userNav, expectedNav, 0.001e18, "split bonus execution must stay pinned to the bonus-scaled request-time NAV");
    }

    function test_redemptionForfeiture_partialExecutions_conserveTotalForfeiture() public {
        // Two identical redemptions under identical PnL, one executed in halves and one in full
        uint256 sharesA = _acquireTrancheShares(USER_A, address(juniorTranche), 10 * stUnit);
        uint256 sharesB = _acquireTrancheShares(USER_B, address(juniorTranche), 10 * stUnit);
        (uint256 noncePartial,) = _requestRedemption(USER_A, address(juniorTranche), sharesA, USER_A, 0);
        (uint256 nonceFull,) = _requestRedemption(USER_B, address(juniorTranche), sharesB, USER_B, 0);

        applySTPnL(1000);
        _warpPastRedemptionDelay();

        vm.prank(USER_A);
        entryPoint.executeRedemption(USER_A, noncePartial, sharesA / 2);
        _executeRedemptionMax(USER_A, USER_A, noncePartial);
        uint256 forfeitedAfterPartials = entryPoint.getProtocolFeeSharesPendingCollection(address(juniorTranche));

        _executeRedemptionMax(USER_B, USER_B, nonceFull);
        uint256 forfeitedByFull = entryPoint.getProtocolFeeSharesPendingCollection(address(juniorTranche)) - forfeitedAfterPartials;

        assertGt(forfeitedAfterPartials, 0, "the split redemption must forfeit the queued gain");
        // The partial path may only differ from the single-shot path by flooring dust
        assertApproxEqAbs(forfeitedAfterPartials, forfeitedByFull, 2, "split redemption must forfeit the same total as a single execution");
    }

    // ---------------------------------------------------------------------
    // collectProtocolFees
    // ---------------------------------------------------------------------

    // ---------------------------------------------------------------------
    // The zero-NAV-snapshot edge: full forfeiture settles, never bricks
    // ---------------------------------------------------------------------

    function test_redemptionForfeiture_zeroNavRemainder_fullyForfeitsThroughBonusSplitAndBatch() public {
        // A sub-par LP-token mark makes a one-share remainder's floor-scaled snapshot exactly zero
        // (staged on the LPT: senior-side losses would enter a fixed term and gate the queue; the position is
        // acquired at par FIRST, since acquisition itself cushions the pool's mark)
        // A small request slice keeps the near-total partial fill inside the market's liquidity gate
        uint256 shares = _acquireTrancheShares(USER_A, address(liquidityProviderTranche), 10e18) / 10;
        uint256 siblingShares = _acquireTrancheShares(USER_A, address(liquidityProviderTranche), 5e18);
        applyLPTPnL(-2000);
        (uint256 dustNonce,) = _requestRedemption(USER_A, address(liquidityProviderTranche), shares, USER_B, DEFAULT_EXECUTOR_BONUS);
        (uint256 siblingNonce,) = _requestRedemption(USER_A, address(liquidityProviderTranche), siblingShares, USER_B, DEFAULT_EXECUTOR_BONUS);
        _warpPastRedemptionDelay();

        // Execute all but one share, flooring the remainder's snapshot to zero
        _executeRedemption(EXECUTOR, USER_A, dustNonce, shares - 1);
        require(
            toUint256(entryPoint.getRedemptionRequest(USER_A, dustNonce).baseRequest.navAtRequestTime) == 0,
            "arrange: the remainder's snapshot must floor to zero"
        );

        // The mark recovers past par: the remainder reads as pure yield and forfeits whole
        applyLPTPnL(3000);

        // A third-party batch containing the fully forfeited remainder settles BOTH requests: the zero-claims
        // remainder pays the executor nothing, forfeits its share, and never poisons the sibling
        address[] memory users = new address[](2);
        users[0] = USER_A;
        users[1] = USER_A;
        uint256[] memory nonces = new uint256[](2);
        nonces[0] = dustNonce;
        nonces[1] = siblingNonce;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = type(uint256).max;
        amounts[1] = type(uint256).max;

        vm.prank(EXECUTOR);
        (AssetClaims[] memory claims,) = entryPoint.executeRedemptions(users, nonces, amounts);

        assertEq(toUint256(claims[0].nav), 0, "the fully forfeited remainder must settle no claims");
        assertGt(toUint256(claims[1].nav), 0, "the sibling request must settle normally in the same batch");
        assertEq(entryPoint.getRedemptionRequest(USER_A, dustNonce).shares, 0, "the remainder must be consumed, not bricked");
        assertGt(entryPoint.getProtocolFeeSharesPendingCollection(address(liquidityProviderTranche)), 0, "the remainder must forfeit to the protocol");
    }

    function test_depositForfeiture_zeroNavRemainder_fullyForfeitsWithoutReverting() public {
        // A near-wiped LP-token mark makes a 50-wei deposit remainder's floor-scaled snapshot exactly zero while
        // leaving the remainder large enough to mint shares at the recovered mark (staged on the LPT: senior-side
        // losses would enter a fixed term; the assets are funded at par FIRST, since funding cushions the mark)
        uint256 amount = 1e18;
        _fundTrancheAssets(USER_A, address(liquidityProviderTranche), amount);
        applyLPTPnL(-9900);
        vm.startPrank(USER_A);
        IERC20Like(address(bpt)).approve(address(entryPoint), amount);
        (uint256 nonce,) = entryPoint.requestDeposit(address(liquidityProviderTranche), toTrancheUnits(amount), USER_A, 0);
        vm.stopPrank();
        _warpPastDepositDelay();
        _executeDeposit(USER_A, USER_A, nonce, amount - 50);
        require(
            toUint256(entryPoint.getDepositRequest(USER_A, nonce).baseRequest.navAtRequestTime) == 0, "arrange: the remainder's snapshot must floor to zero"
        );

        // The mark recovers: the remainder reads as pure yield, forfeits whole, and settles without a user transfer
        applyLPTPnL(20_000);
        uint256 minted = _executeDepositMax(USER_A, USER_A, nonce);
        assertEq(minted, 0, "a fully forfeited deposit remainder must mint the user nothing");
        assertEq(toUint256(entryPoint.getDepositRequest(USER_A, nonce).assets), 0, "the remainder must be consumed, not bricked");
        assertGt(entryPoint.getProtocolFeeSharesPendingCollection(address(liquidityProviderTranche)), 0, "the remainder must forfeit to the protocol");
    }

    function test_redemptionForfeiture_thirdPartyExecution_lossPaysBonusAndForfeitsNothing() public {
        // Staged on the LPT: senior-side losses would enter a fixed term and gate the queue
        uint256 shares = _acquireTrancheShares(USER_A, address(liquidityProviderTranche), 10e18);
        (uint256 nonce,) = _requestRedemption(USER_A, address(liquidityProviderTranche), shares, USER_B, DEFAULT_EXECUTOR_BONUS);

        // The escrowed shares depreciate while queued: no yield to forfeit, and the receiver bears the loss
        applyLPTPnL(-500);
        _warpPastRedemptionDelay();

        uint256 executorAssetsBefore = bpt.balanceOf(EXECUTOR);
        _executeRedemptionMax(EXECUTOR, USER_A, nonce);

        assertEq(entryPoint.getProtocolFeeSharesPendingCollection(address(liquidityProviderTranche)), 0, "a loss must forfeit nothing");
        assertGt(bpt.balanceOf(EXECUTOR) - executorAssetsBefore, 0, "the executor bonus must still pay on a depreciated redemption");
        assertGt(bpt.balanceOf(USER_B), 0, "the receiver must get the post-bonus remainder");
    }

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

    function test_collectProtocolFees_maxSweep_neverDrawsEscrowedShares() public {
        // Accrue fee shares and a pending redemption escrow in the SAME tranche: the max sweep must draw only the
        // fee accrual, never the escrowed shares commingled in the entry point's balance
        (uint256 depositNonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        applySTPnL(1000);
        _warpPastDepositDelay();
        _executeDepositMax(USER_A, USER_A, depositNonce);
        uint256 accrued = entryPoint.getProtocolFeeSharesPendingCollection(address(juniorTranche));
        assertGt(accrued, 0, "the fixture must accrue fee shares");

        uint256 escrowed = _acquireTrancheShares(USER_B, address(juniorTranche), 10 * stUnit);
        (uint256 redemptionNonce,) = _requestRedemption(USER_B, address(juniorTranche), escrowed, USER_B, 0);

        address[] memory tranches = new address[](1);
        tranches[0] = address(juniorTranche);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = type(uint256).max;
        vm.prank(FEE_COLLECTOR);
        entryPoint.collectProtocolFees(tranches, amounts, FEE_COLLECTOR);

        assertEq(juniorTranche.balanceOf(FEE_COLLECTOR), accrued, "the sweep must draw exactly the fee accrual");
        assertEq(juniorTranche.balanceOf(address(entryPoint)), escrowed, "the escrowed redemption shares must be untouched");
        // The escrow remains fully recoverable after the sweep
        uint256 balanceBefore = juniorTranche.balanceOf(USER_B);
        _cancelRedemption(USER_B, redemptionNonce, USER_B);
        assertEq(juniorTranche.balanceOf(USER_B) - balanceBefore, escrowed, "cancellation must return the full escrow after the sweep");
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
