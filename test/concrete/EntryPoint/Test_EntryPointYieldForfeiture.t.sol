// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
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
        // Uses the SENIOR tranche: under the share basis a deposit only forfeits when the tranche share price rises
        // LESS than the collateral over the delay, so the same assets mint more shares now than at request. The senior
        // tranche is capped (its yield is shared to JT/LT as premium), so a collateral gain makes it underperform the
        // collateral and mint the forfeitable excess. A junior deposit is levered and outperforms, so it would not forfeit
        uint256 amount = 10 * stUnit;
        (uint256 nonce,) = _requestDeposit(USER_A, address(seniorTranche), amount, USER_A, 0);
        // Deposit forfeiture is share-based: the request snapshots the shares the deposit would mint at request-time pricing
        uint256 sharesRef = entryPoint.getDepositRequest(USER_A, nonce).equivalentSharesAtRequestTime;

        // The collateral appreciates 10% while queued, the capped senior share rises less
        applySTPnL(1000);
        _warpPastDepositDelay();

        // The execution-stage mint: previewDeposit is the mechanism's own reference for the shares minted now (the
        // deposit below mints exactly this, by construction of previewDeposit). Captured before the execute at the
        // full request amount, which _executeDepositMax deposits in one shot
        uint256 sharesExec = seniorTranche.previewDeposit(toTrancheUnits(amount));
        uint256 userShares = _executeDepositMax(USER_A, USER_A, nonce);
        uint256 forfeited = entryPoint.getProtocolFeeSharesPendingCollection(address(seniorTranche));

        assertGt(forfeited, 0, "the queued yield must be forfeited to the protocol");
        assertEq(seniorTranche.balanceOf(address(entryPoint)), forfeited, "the forfeited shares must be held by the entry point");
        assertEq(seniorTranche.balanceOf(USER_A), userShares, "the user must receive only the post-forfeiture shares");
        // Yield neutrality: the user keeps the lesser of the request-time reference and the shares minted now, and the
        // excess minted now (the queued appreciation) is forfeited whole, so the two partition the execution mint
        assertEq(userShares, Math.min(sharesRef, sharesExec), "the user must keep the lower of the request-time and execution-time share counts");
        assertEq(userShares + forfeited, sharesExec, "the user shares and the forfeited excess must partition the execution mint");
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

    function test_depositForfeiture_ltDeposit_pureBptAppreciationNotForfeited() public {
        // Share basis: a deposit forfeits only when the tranche share price rises LESS than the deposited asset. A pure
        // BPT mark gain (no idle liquidity premium staged in this fixture) lifts the LT effective NAV per share in exact
        // proportion to the deposited BPT's value, so the same BPT mints the same shares at execution as at request. The
        // depositor keeps their BPT's own beta and nothing is forfeited. (The forfeiting case, where a staged idle
        // premium makes the LT share underperform the BPT gain, is pinned in Test_EntryPointLPTClaims.)
        uint256 amount = 10e18;
        (uint256 nonce,) = _requestDeposit(USER_A, address(liquidityProviderTranche), amount, USER_A, 0);

        // The escrowed BPT appreciates 10% while queued, and the LT share price tracks it proportionally
        applyLPTPnL(1000);
        _warpPastDepositDelay();

        uint256 userShares = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(userShares, 0, "the deposit must execute at the appreciated mark");
        assertEq(
            entryPoint.getProtocolFeeSharesPendingCollection(address(liquidityProviderTranche)),
            0,
            "a pure BPT mark gain the LT share tracks must not be forfeited"
        );
    }

    // ---------------------------------------------------------------------
    // Redemption queue
    // ---------------------------------------------------------------------

    function test_redemptionForfeiture_yieldAccruedInQueue_accruesToProtocol() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_A, 0);
        uint256 navAtRequest = toUint256(entryPoint.getRedemptionRequest(USER_A, nonce).valueAtRequestTime);

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

    function test_depositForfeiture_thirdPartyExecution_bonusPaidInSharesFromPostForfeitureMint() public {
        // The gain x executor-bonus quadrant: the FULL escrow is deposited (the bonus never touches the assets or the
        // share reference), forfeiture pins the user's combined mint to min(request-time reference, execution mint),
        // and the executor's bonus is a share slice of that post-forfeiture mint, the receiver keeping the remainder
        uint256 amount = 10 * stUnit;
        // Senior tranche: the capped senior underperforms the collateral on a gain, so a deposit forfeits (see the yieldAccruedInQueue test)
        (uint256 nonce,) = _requestDeposit(USER_A, address(seniorTranche), amount, USER_A, DEFAULT_EXECUTOR_BONUS);
        uint256 sharesRef = entryPoint.getDepositRequest(USER_A, nonce).equivalentSharesAtRequestTime;

        applySTPnL(1000);
        _warpPastDepositDelay();

        // The tranche mints against the full escrow, so the forfeiture min is taken against the unscaled reference
        uint256 sharesExec = seniorTranche.previewDeposit(toTrancheUnits(amount));

        uint256 userShares = _executeDepositMax(EXECUTOR, USER_A, nonce);

        assertGt(entryPoint.getProtocolFeeSharesPendingCollection(address(seniorTranche)), 0, "the queued yield must still be forfeited under a bonus");
        // The user's combined mint (receiver + executor) is pinned to the unscaled request-time share reference
        assertEq(userShares, Math.min(sharesRef, sharesExec), "the combined mint must be pinned to the unscaled request-time share reference");
        // The executor's bonus is a flooring share slice of the post-forfeiture mint, the receiver keeps the remainder
        uint256 expectedBonusShares = (userShares * DEFAULT_EXECUTOR_BONUS) / 1e18;
        assertEq(seniorTranche.balanceOf(EXECUTOR), expectedBonusShares, "the executor must receive the bonus in freshly minted shares");
        assertEq(seniorTranche.balanceOf(USER_A), userShares - expectedBonusShares, "the receiver must keep the remainder of the minted shares");
    }

    function test_redemptionForfeiture_thirdPartyExecution_gainWithBonusStaysNeutral() public {
        // Redemption mirror of the gain x bonus quadrant: forfeiture settles on the full share amount first, then the
        // bonus split scales the resulting claims, so the receiver's pin is the snapshot scaled by (1 - bonus)
        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_B, DEFAULT_EXECUTOR_BONUS);
        uint256 navAtRequest = toUint256(entryPoint.getRedemptionRequest(USER_A, nonce).valueAtRequestTime);

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
        // Senior tranche: only the capped tranche forfeits a deposit on a collateral gain (see the yieldAccruedInQueue test)
        // Two identical requests, one executed in halves and one in full, under identical PnL
        (uint256 noncePartial,) = _requestDeposit(USER_A, address(seniorTranche), amount, USER_A, 0);
        (uint256 nonceFull,) = _requestDeposit(USER_B, address(seniorTranche), amount, USER_B, 0);

        applySTPnL(1000);
        _warpPastDepositDelay();

        _executeDeposit(USER_A, USER_A, noncePartial, amount / 2);
        _executeDepositMax(USER_A, USER_A, noncePartial);
        uint256 forfeitedAfterPartials = entryPoint.getProtocolFeeSharesPendingCollection(address(seniorTranche));

        _executeDepositMax(USER_B, USER_B, nonceFull);
        uint256 forfeitedByFull = entryPoint.getProtocolFeeSharesPendingCollection(address(seniorTranche)) - forfeitedAfterPartials;

        assertGt(forfeitedAfterPartials, 0, "the split deposit must forfeit the queued gain");
        // The partial path may only differ from the single-shot path by flooring dust
        assertApproxEqAbs(forfeitedAfterPartials, forfeitedByFull, 2, "split execution must forfeit the same total as a single execution");
    }

    function test_depositForfeiture_partialThirdPartyExecutions_proRataRescaleWithShareBonus() public {
        // The partial+bonus quadrant: each third-party slice deposits its FULL asset slice (the bonus never rescales
        // the reference), so each slice's combined mint is min(its pro-rata reference slice, its execution mint), and
        // the executor's bonus is a per-slice share slice of that post-forfeiture mint
        uint256 amount = 10 * stUnit;
        // Senior tranche: the capped senior underperforms the collateral on a gain, so a deposit forfeits (see the yieldAccruedInQueue test)
        (uint256 nonce,) = _requestDeposit(USER_A, address(seniorTranche), amount, USER_A, DEFAULT_EXECUTOR_BONUS);
        uint256 sharesRef = entryPoint.getDepositRequest(USER_A, nonce).equivalentSharesAtRequestTime;

        applySTPnL(1000);
        _warpPastDepositDelay();

        // Each slice deposits half the escrow in full
        uint256 sliceAssets = amount / 2;

        // Slice 1: the pro-rata storage rescale floors the unfilled half's reference to storage
        // (mulDiv(sharesRef, sliceAssets, amount) = floor(sharesRef / 2)), leaving the remainder as the filled
        // portion's reference (ceil(sharesRef / 2)). Slice 2 then consumes the whole stored remainder
        uint256 sharesLeftAfterSlice1 = Math.mulDiv(sharesRef, sliceAssets, amount, Math.Rounding.Floor);
        uint256 sharesRefFilled1 = sharesRef - sharesLeftAfterSlice1;
        uint256 sharesRefFilled2 = sharesLeftAfterSlice1;

        // Each slice's execution mint is previewDeposit of its full asset slice, captured at that slice's state
        // (slice 1's deposit shifts pricing, so slice 2's mint is previewed after slice 1 lands)
        uint256 sharesExec1 = seniorTranche.previewDeposit(toTrancheUnits(sliceAssets));
        uint256 userShares1 = _executeDeposit(EXECUTOR, USER_A, nonce, sliceAssets);
        uint256 sharesExec2 = seniorTranche.previewDeposit(toTrancheUnits(sliceAssets));
        uint256 userShares2 = _executeDepositMax(EXECUTOR, USER_A, nonce);

        assertGt(entryPoint.getProtocolFeeSharesPendingCollection(address(seniorTranche)), 0, "the queued yield must be forfeited across bonus slices");
        // Each slice's combined mint is min(its pro-rata reference, its execution mint)
        assertEq(
            userShares1 + userShares2,
            Math.min(sharesRefFilled1, sharesExec1) + Math.min(sharesRefFilled2, sharesExec2),
            "split bonus execution must land on the pro-rata share reference, unscaled by the bonus"
        );
        // The executor's bonus floors per slice off each slice's post-forfeiture mint, the receiver keeps the rest
        uint256 expectedBonusShares = (userShares1 * DEFAULT_EXECUTOR_BONUS) / 1e18 + (userShares2 * DEFAULT_EXECUTOR_BONUS) / 1e18;
        assertEq(seniorTranche.balanceOf(EXECUTOR), expectedBonusShares, "the executor must receive each slice's bonus in freshly minted shares");
        assertEq(seniorTranche.balanceOf(USER_A), userShares1 + userShares2 - expectedBonusShares, "the receiver must keep the remainder of both slices' mints");
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
        // The totalAssets forfeiture basis scales each slice's NAV by the tranche's live total NAV and supply, which
        // shift as the first partial redeems, so the split path differs from the single shot by more than flooring
        // dust (path dependence), but only negligibly (well under 1e-9 relative)
        assertApproxEqRel(
            forfeitedAfterPartials, forfeitedByFull, 1e9, "split redemption must forfeit the same total as a single execution up to totalAssets path dependence"
        );
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
        require(toUint256(entryPoint.getRedemptionRequest(USER_A, dustNonce).valueAtRequestTime) == 0, "arrange: the remainder's snapshot must floor to zero");

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

    // NOTE: the NAV-basis "zero-snapshot deposit remainder fully forfeits" edge does NOT port to the share basis and
    // has no share-basis analog to pin. Under the NAV basis a sub-par mark crashed the remainder's NAV reference to
    // zero while the deposit still minted positive shares, so the remainder forfeited its whole mint. Under the share
    // basis the remainder's reference and its execution mint are the SAME near-identical share quantity (both are
    // previewDeposit of the remainder assets, at request vs execution pricing), so they floor to zero together: a
    // remainder small enough to floor the reference to zero also mints zero shares at execution, which reverts
    // MUST_MINT_NON_ZERO_SHARES rather than settling a fully-forfeited deposit. The "graceful full forfeiture of a
    // zero-reference remainder" invariant is therefore only reachable, and is pinned, on the redemption side
    // (test_redemptionForfeiture_zeroNavRemainder_fullyForfeitsThroughBonusSplitAndBatch), where the reference is a
    // NAV that a sub-par mark still crashes to zero independently of the redeemed share count.

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
        // Accrue protocol fee shares via a deposit-queue forfeiture. Senior tranche: only the capped tranche forfeits
        // a deposit on a collateral gain (see the yieldAccruedInQueue test)
        (uint256 nonce,) = _requestDeposit(USER_A, address(seniorTranche), 10 * stUnit, USER_A, 0);
        applySTPnL(1000);
        _warpPastDepositDelay();
        _executeDepositMax(USER_A, USER_A, nonce);
        uint256 accrued = entryPoint.getProtocolFeeSharesPendingCollection(address(seniorTranche));
        assertGt(accrued, 1, "the fixture must accrue more than one share-wei of fees");

        address[] memory tranches = new address[](1);
        tranches[0] = address(seniorTranche);
        uint256[] memory amounts = new uint256[](1);

        // Collect a specific amount
        amounts[0] = 1;
        vm.prank(FEE_COLLECTOR);
        entryPoint.collectProtocolFees(tranches, amounts, FEE_COLLECTOR);
        assertEq(entryPoint.getProtocolFeeSharesPendingCollection(address(seniorTranche)), accrued - 1, "the specific claim must decrement the accrual");

        // Sweep the remainder with the max sentinel
        amounts[0] = type(uint256).max;
        vm.prank(FEE_COLLECTOR);
        entryPoint.collectProtocolFees(tranches, amounts, FEE_COLLECTOR);
        assertEq(entryPoint.getProtocolFeeSharesPendingCollection(address(seniorTranche)), 0, "the max sweep must clear the accrual");
        assertEq(seniorTranche.balanceOf(FEE_COLLECTOR), accrued, "the collector must hold every accrued fee share");
    }

    function test_collectProtocolFees_maxSweep_neverDrawsEscrowedShares() public {
        // Accrue fee shares and a pending redemption escrow in the SAME tranche: the max sweep must draw only the
        // fee accrual, never the escrowed shares commingled in the entry point's balance. Senior tranche: only the
        // capped tranche forfeits a deposit on a collateral gain (see the yieldAccruedInQueue test)
        (uint256 depositNonce,) = _requestDeposit(USER_A, address(seniorTranche), 10 * stUnit, USER_A, 0);
        applySTPnL(1000);
        _warpPastDepositDelay();
        _executeDepositMax(USER_A, USER_A, depositNonce);
        uint256 accrued = entryPoint.getProtocolFeeSharesPendingCollection(address(seniorTranche));
        assertGt(accrued, 0, "the fixture must accrue fee shares");

        uint256 escrowed = _acquireTrancheShares(USER_B, address(seniorTranche), 10 * stUnit);
        (uint256 redemptionNonce,) = _requestRedemption(USER_B, address(seniorTranche), escrowed, USER_B, 0);

        address[] memory tranches = new address[](1);
        tranches[0] = address(seniorTranche);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = type(uint256).max;
        vm.prank(FEE_COLLECTOR);
        entryPoint.collectProtocolFees(tranches, amounts, FEE_COLLECTOR);

        assertEq(seniorTranche.balanceOf(FEE_COLLECTOR), accrued, "the sweep must draw exactly the fee accrual");
        assertEq(seniorTranche.balanceOf(address(entryPoint)), escrowed, "the escrowed redemption shares must be untouched");
        // The escrow remains fully recoverable after the sweep
        uint256 balanceBefore = seniorTranche.balanceOf(USER_B);
        _cancelRedemption(USER_B, redemptionNonce, USER_B);
        assertEq(seniorTranche.balanceOf(USER_B) - balanceBefore, escrowed, "cancellation must return the full escrow after the sweep");
    }

    function test_collectProtocolFees_overClaimReverts() public {
        // Accrue a known amount, then claiming more than accrued must underflow-revert rather than draw on escrow.
        // Senior tranche: only the capped tranche forfeits a deposit on a collateral gain (see the yieldAccruedInQueue test)
        (uint256 nonce,) = _requestDeposit(USER_A, address(seniorTranche), 10 * stUnit, USER_A, 0);
        applySTPnL(1000);
        _warpPastDepositDelay();
        _executeDepositMax(USER_A, USER_A, nonce);
        uint256 accrued = entryPoint.getProtocolFeeSharesPendingCollection(address(seniorTranche));
        assertGt(accrued, 0, "the fixture must accrue fee shares to over-claim against");

        address[] memory tranches = new address[](1);
        tranches[0] = address(seniorTranche);
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
