// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toUint256 } from "../../../src/libraries/Units.sol";
import { MockBPTOracle } from "../../mocks/MockBPTOracle.sol";
import { MockBalancerVault } from "../../mocks/MockBalancerVault.sol";
import { EntryPointTestBase } from "../../utils/EntryPointTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_EntryPointLPTMultiAssetRouting
 * @notice The entry point's internal LPT exit maximizer: liquidity provider tranche redemptions exit in-kind by default, a
 *         maximal redemption is sized by the dominant multi-asset bound, and any amount the in-kind gate cannot
 *         admit falls back to the multi-asset exit. Nothing is exposed to the user, the route is decided from
 *         the two bounds alone, and equal bounds always resolve in-kind
 * @dev The fixture binds the liquidity requirement against the escrowed position: a senior-share-heavy pool leg
 *      keeps the multi-asset bound strictly wider than the in-kind bound, and the seeded LPT position is handed to
 *      the requester so a maximal redemption genuinely crosses the wedge
 */
contract Test_EntryPointLPTMultiAssetRouting is EntryPointTestBase {
    /// @dev One whole quote token in its native decimals (this market's quote asset uses 6 decimals, so 1e6)
    uint256 internal QUOTE_UNIT;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        QUOTE_UNIT = 10 ** uint256(cell.quoteAsset.decimals);
        _seedMarket(100_000e18, 30_000e18);
        _seedLPT(10_000e18, 8000e18, 2000 * QUOTE_UNIT);
        _deployEntryPoint();
        // Hand the seeded LPT position to USER_A so an escrowed redemption can exceed the in-kind bound
        // (the balance read is hoisted: an inline call in the argument list would consume the prank)
        uint256 seededShares = liquidityProviderTranche.balanceOf(LPT_PROVIDER);
        vm.prank(LPT_PROVIDER);
        liquidityProviderTranche.transfer(USER_A, seededShares);
    }

    /// @dev Queues USER_A's whole LPT position (OPTIMIZED mode) for redemption to USER_B, returning the nonce and both post-escrow bounds
    function _requestWholePosition(uint64 _executorBonusWAD) internal returns (uint256 nonce, uint256 maxInKindShares, uint256 maxMultiAssetShares) {
        return _requestWholePosition(_executorBonusWAD, IRoycoDayEntryPoint.RedemptionMode.OPTIMIZED);
    }

    /// @dev Queues USER_A's whole LPT position under an explicit redemption mode, returning the nonce and both post-escrow bounds
    function _requestWholePosition(
        uint64 _executorBonusWAD,
        IRoycoDayEntryPoint.RedemptionMode _mode
    )
        internal
        returns (uint256 nonce, uint256 maxInKindShares, uint256 maxMultiAssetShares)
    {
        (nonce,) = _requestRedemption(USER_A, address(liquidityProviderTranche), liquidityProviderTranche.balanceOf(USER_A), USER_B, _executorBonusWAD, _mode);
        _warpPastRedemptionDelay();
        maxInKindShares = liquidityProviderTranche.maxRedeem(address(entryPoint));
        maxMultiAssetShares = liquidityProviderTranche.maxRedeemMultiAsset(address(entryPoint));
        require(maxMultiAssetShares > maxInKindShares, "setup: the wedge between the two bounds must be live");
        require(entryPoint.getRedemptionRequest(USER_A, nonce).shares > maxInKindShares, "setup: the escrow must exceed the in-kind bound");
    }

    // =============================
    // The maximizer's routing: sentinel sizing, the in-kind default, and the tie
    // =============================

    /// @notice A maximal redemption the in-kind gate cannot serve is sized by the multi-asset bound and exits to
    ///         the LP token's constituents, paying exactly what the tranche's own preview quotes
    function test_lptRedemption_maxSentinel_fallsBackToMultiAssetBeyondInKindBound() public {
        (uint256 nonce, uint256 maxInKindShares, uint256 maxMultiAssetShares) = _requestWholePosition(0);
        uint256 escrowedShares = entryPoint.getRedemptionRequest(USER_A, nonce).shares;

        // The maximizer must execute the multi-asset bound: forecast the constituents it pays
        (AssetClaims memory previewClaims, uint256 previewQuote) = liquidityProviderTranche.previewRedeemMultiAsset(maxMultiAssetShares);
        uint256 receiverVaultSharesBefore = stJtVault.balanceOf(USER_B);
        (AssetClaims memory claims, uint256 quoteAssets) = _executeRedemptionMaxWithQuote(USER_A, USER_A, nonce);

        // The executed size must be the multi-asset bound, strictly past everything in-kind could admit
        uint256 sharesExecuted = escrowedShares - entryPoint.getRedemptionRequest(USER_A, nonce).shares;
        assertEq(sharesExecuted, maxMultiAssetShares, "the maximal execution must be sized by the multi-asset bound");
        assertGt(sharesExecuted, maxInKindShares, "the execution must cross strictly past the in-kind bound");
        assertGt(entryPoint.getRedemptionRequest(USER_A, nonce).shares, 0, "the gate, not the balance, must bind the maximal execution");

        // The exit must be multi-asset: constituents and quote land on the receiver, and no LP tokens move
        assertEq(toUint256(claims.lptAssets), 0, "a multi-asset exit must carry no LP-token leg");
        assertGt(quoteAssets, 0, "a multi-asset exit must carry a quote leg");
        assertEq(bpt.balanceOf(USER_B), 0, "no LP tokens may land on the receiver");
        assertEq(quoteToken.balanceOf(USER_B), previewQuote, "the quote leg must land exactly as the tranche previews");
        assertEq(
            stJtVault.balanceOf(USER_B) - receiverVaultSharesBefore,
            toUint256(previewClaims.collateralAssets),
            "the constituent leg must land exactly as the tranche previews"
        );
    }

    /// @notice An amount the in-kind gate can admit exits in-kind even while the wider multi-asset bound is live:
    ///         the fallback is a last resort, never a preference
    function test_lptRedemption_withinInKindBound_staysInKind() public {
        uint256 shares = 1000e18;
        (uint256 nonce,) = _requestRedemption(USER_A, address(liquidityProviderTranche), shares, USER_B, 0);
        _warpPastRedemptionDelay();
        require(shares <= liquidityProviderTranche.maxRedeem(address(entryPoint)), "setup: the amount must fit the in-kind bound");

        (AssetClaims memory claims, uint256 quoteAssets) = _executeRedemptionMaxWithQuote(USER_A, USER_A, nonce);

        assertGt(toUint256(claims.lptAssets), 0, "an in-kind exit must pay the LP-token leg");
        assertEq(quoteAssets, 0, "an in-kind exit must carry no quote leg");
        assertEq(bpt.balanceOf(USER_B), toUint256(claims.lptAssets), "the LP-token leg must land on the receiver");
        assertEq(quoteToken.balanceOf(USER_B), 0, "no quote may land on an in-kind exit");
    }

    /// @notice Equal-NAV bounds resolve in-kind: with no senior-share value in the removal the two withdrawal bounds
    ///         share identical NAV inputs (same maxLPTWithdrawal, same lptRawNAV, same supply), and a maximal redemption
    ///         executes the in-kind bound as a partial in-kind fill.
    /// @dev Both bounds price the withdrawable NAV through the same virtual-shares primitive
    ///      (floor((S+1e6)*W/(claimNAV+1))), so identical NAV inputs make them equal share for share. The routing
    ///      test is strict (multiAsset > inKind), so the exact tie defaults the maximal redemption to the in-kind exit.
    function test_lptRedemption_equalBounds_defaultsInKind() public {
        // Redeploy with quote-only pool legs so a proportional removal returns no senior shares
        _deployMarket(cellA(), defaultParams());
        _seedMarket(100_000e18, 30_000e18);
        _seedLPT(10_000e18, 0, 10_000 * QUOTE_UNIT);
        _deployEntryPoint();
        uint256 seededShares = liquidityProviderTranche.balanceOf(LPT_PROVIDER);
        vm.prank(LPT_PROVIDER);
        liquidityProviderTranche.transfer(USER_A, seededShares);

        (uint256 nonce,) = _requestRedemption(USER_A, address(liquidityProviderTranche), liquidityProviderTranche.balanceOf(USER_A), USER_B, 0);
        _warpPastRedemptionDelay();
        uint256 maxInKindShares = liquidityProviderTranche.maxRedeem(address(entryPoint));
        // Exact tie: with no senior-share relief the two bounds coincide share for share, so the strict-greater
        // routing test defaults to the in-kind exit.
        require(liquidityProviderTranche.maxRedeemMultiAsset(address(entryPoint)) == maxInKindShares, "setup: the two bounds must tie exactly");
        require(entryPoint.getRedemptionRequest(USER_A, nonce).shares > maxInKindShares, "setup: the escrow must exceed the shared bound");

        (AssetClaims memory claims, uint256 quoteAssets) = _executeRedemptionMaxWithQuote(USER_A, USER_A, nonce);

        assertEq(quoteAssets, 0, "equal bounds must resolve to the in-kind exit");
        assertGt(toUint256(claims.lptAssets), 0, "the in-kind exit must pay the LP-token leg");
        assertEq(bpt.balanceOf(USER_B), toUint256(claims.lptAssets), "the partial in-kind fill must land on the receiver");
    }

    // =============================
    // Explicit amounts: the same route rule, and true excess still reverts
    // =============================

    /// @notice INKIND mode holds every explicit amount to the in-kind gate: an amount inside the wedge (beyond the
    ///         in-kind bound but within the multi-asset bound) reverts, while an amount within the in-kind bound exits in-kind
    function test_lptRedemption_inKindMode_explicitHoldsToInKindGate() public {
        (uint256 nonce, uint256 maxInKindShares, uint256 maxMultiAssetShares) = _requestWholePosition(0, IRoycoDayEntryPoint.RedemptionMode.INKIND);

        // An explicit amount inside the wedge window holds to the in-kind gate and reverts
        vm.prank(USER_A);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        entryPoint.executeRedemption(USER_A, nonce, maxMultiAssetShares);

        // An explicit amount within the in-kind bound exits in-kind
        (AssetClaims memory inKindClaims, uint256 inKindQuote) = _executeRedemptionWithQuote(USER_A, USER_A, nonce, maxInKindShares / 2);
        assertEq(inKindQuote, 0, "an explicit amount must exit in-kind under INKIND mode");
        assertGt(toUint256(inKindClaims.lptAssets), 0, "the in-kind exit must pay the LP-token leg");
    }

    /// @notice A maximal redemption whose remaining request sits inside the wedge window fills the WHOLE request
    ///         multi-asset: the dominant bound is clamped to what remains, never past it
    function test_lptRedemption_maxSentinel_clampsDominantBoundToTheRequest() public {
        // Queue a slice that the in-kind bound cannot serve but the multi-asset bound over-serves
        uint256 maxInKindShares = liquidityProviderTranche.maxRedeem(USER_A);
        uint256 maxMultiAssetShares = liquidityProviderTranche.maxRedeemMultiAsset(USER_A);
        require(maxMultiAssetShares > maxInKindShares + 2, "setup: the wedge between the two bounds must be live");
        uint256 requestedShares = maxInKindShares + (maxMultiAssetShares - maxInKindShares) / 2;
        (uint256 nonce,) = _requestRedemption(USER_A, address(liquidityProviderTranche), requestedShares, USER_B, 0);
        _warpPastRedemptionDelay();

        (, uint256 quoteAssets) = _executeRedemptionMaxWithQuote(USER_A, USER_A, nonce);

        assertGt(quoteAssets, 0, "the wedge-window fill must exit multi-asset");
        assertEq(entryPoint.getRedemptionRequest(USER_A, nonce).shares, 0, "the whole remaining request must fill: clamped, never exceeded");
    }

    /// @notice MULTIASSET mode routes an explicit amount through the multi-asset exit, but an amount past even the
    ///         multi-asset bound still reverts at the market's liquidity gate: the mode widens what can execute, it never overrides the requirement
    function test_lptRedemption_multiAssetMode_explicitBeyondBoundReverts() public {
        (uint256 nonce,, uint256 maxMultiAssetShares) = _requestWholePosition(0, IRoycoDayEntryPoint.RedemptionMode.MULTIASSET);

        // The slack covers the accountant's one-NAV-wei dust tolerance plus the flow's quote and share quantization floors
        uint256 breachShares =
            maxMultiAssetShares + Math.mulDiv(2e12 + 1, liquidityProviderTranche.totalSupply(), toUint256(accountant.getState().lastLPTRawNAV), Math.Rounding.Ceil) + 2;
        vm.prank(USER_A);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        entryPoint.executeRedemption(USER_A, nonce, breachShares);
    }

    /// @notice MULTIASSET mode forces the multi-asset exit even for an amount the in-kind bound could serve: an
    ///         explicit slice within the in-kind bound still pays a quote leg (INKIND would pay none)
    function test_lptRedemption_multiAssetMode_forcesMultiAssetWithinInKindBound() public {
        (uint256 nonce, uint256 maxInKindShares,) = _requestWholePosition(0, IRoycoDayEntryPoint.RedemptionMode.MULTIASSET);
        (, uint256 quoteAssets) = _executeRedemptionWithQuote(USER_A, USER_A, nonce, maxInKindShares / 2);
        assertGt(quoteAssets, 0, "MULTIASSET mode must exit multi-asset even within the in-kind bound");
    }

    /// @notice MULTIASSET mode with the MAX sentinel caps the fill at the multi-asset bound and exits multi-asset
    function test_lptRedemption_multiAssetMode_maxSentinelCapsAtMultiAssetBound() public {
        (uint256 nonce,, uint256 maxMultiAssetShares) = _requestWholePosition(0, IRoycoDayEntryPoint.RedemptionMode.MULTIASSET);
        uint256 escrow = entryPoint.getRedemptionRequest(USER_A, nonce).shares;
        (, uint256 quoteAssets) = _executeRedemptionMaxWithQuote(USER_A, USER_A, nonce);
        assertGt(quoteAssets, 0, "the MAX multi-asset fill must exit multi-asset");
        assertEq(
            entryPoint.getRedemptionRequest(USER_A, nonce).shares,
            escrow - Math.min(maxMultiAssetShares, escrow),
            "the MAX multi-asset fill must cap at the multi-asset bound"
        );
    }

    /// @notice OPTIMIZED mode with an explicit amount past every bound fills to whichever bound is wider (multi-asset)
    ///         instead of reverting: the max-withdrawal semantics extend to explicit targets
    function test_lptRedemption_optimizedMode_explicitBeyondAllBoundsFillsToWiderBoundNoRevert() public {
        (uint256 nonce,, uint256 maxMultiAssetShares) = _requestWholePosition(0, IRoycoDayEntryPoint.RedemptionMode.OPTIMIZED);
        uint256 escrow = entryPoint.getRedemptionRequest(USER_A, nonce).shares;

        // A target past both bounds resolves to the wider (multi-asset) bound, never exceeding the escrow, and never reverts
        (, uint256 quoteAssets) = _executeRedemptionWithQuote(USER_A, USER_A, nonce, maxMultiAssetShares + 1e24);
        assertGt(quoteAssets, 0, "OPTIMIZED must take the wider multi-asset route past the in-kind bound");
        assertEq(entryPoint.getRedemptionRequest(USER_A, nonce).shares, escrow - maxMultiAssetShares, "the fill caps at the wider (multi-asset) bound, leaving the rest open");
    }

    /// @notice The senior and junior tranches reject every non-in-kind redemption mode at request time
    function test_stJtRedemption_nonInKindModeReverts() public {
        vm.startPrank(USER_A);
        vm.expectRevert(IRoycoDayEntryPoint.UNSUPPORTED_REDEMPTION_MODE.selector);
        entryPoint.requestRedemption(address(seniorTranche), 1, USER_A, 0, IRoycoDayEntryPoint.RedemptionMode.MULTIASSET);
        vm.expectRevert(IRoycoDayEntryPoint.UNSUPPORTED_REDEMPTION_MODE.selector);
        entryPoint.requestRedemption(address(juniorTranche), 1, USER_A, 0, IRoycoDayEntryPoint.RedemptionMode.OPTIMIZED);
        vm.stopPrank();
    }

    // =============================
    // The bonus split, forfeiture, and the empty-capacity corner on the multi-asset route
    // =============================

    /// @notice A third-party execution across the wedge splits every leg including the quote: the executor's quote
    ///         slice floors, the receiver takes the remainder, and nothing is stranded in the entry point
    function test_lptRedemption_thirdParty_multiAsset_splitsQuoteAndConstituentLegs() public {
        (uint256 nonce,,) = _requestWholePosition(DEFAULT_EXECUTOR_BONUS);

        (AssetClaims memory userClaims, uint256 userQuote) = _executeRedemptionMaxWithQuote(EXECUTOR, USER_A, nonce);

        // The quote leg splits with the flooring bonus fraction, receiver first
        uint256 executorQuote = quoteToken.balanceOf(EXECUTOR);
        uint256 totalQuote = executorQuote + userQuote;
        assertGt(executorQuote, 0, "the executor must receive its quote bonus slice");
        assertEq(quoteToken.balanceOf(USER_B), userQuote, "the receiver must get the post-bonus quote remainder");
        assertEq(executorQuote, Math.mulDiv(totalQuote, DEFAULT_EXECUTOR_BONUS, 1e18), "the quote bonus slice must equal the flooring bonus fraction");

        // The constituent legs split like every claims leg
        assertGt(stJtVault.balanceOf(EXECUTOR), 0, "the executor must receive its constituent bonus slice");
        assertEq(stJtVault.balanceOf(USER_B), toUint256(userClaims.collateralAssets), "the receiver must get the post-bonus constituent leg");

        // Nothing may be left stranded in the entry point
        assertEq(quoteToken.balanceOf(address(entryPoint)), 0, "no quote may remain in the entry point after the split");
        assertEq(stJtVault.balanceOf(address(entryPoint)), 0, "no vault shares may remain in the entry point after the split");
    }

    /// @notice Yield accrued while queued is forfeited on the multi-asset route exactly as in-kind: the forfeiture
    ///         basis is share-denominated and route-independent
    function test_lptRedemption_multiAsset_forfeitsQueuedYieldAsLPTShares() public {
        (uint256 nonce,,) = _requestWholePosition(0);

        // The LP-token mark appreciates while the request is queued
        applyLPTPnL(1000);
        _sync();

        (, uint256 quoteAssets) = _executeRedemptionMaxWithQuote(USER_A, USER_A, nonce);
        assertGt(quoteAssets, 0, "the fixture must exercise the multi-asset route");
        assertGt(
            entryPoint.getProtocolFeeSharesPendingCollection(address(liquidityProviderTranche)),
            0,
            "queued yield must be forfeited as LPT protocol fee shares on the multi-asset route"
        );
    }

    /// @notice A wiped LP-token mark zeroes both bounds: a maximal execution settles nothing, keeps the escrow
    ///         queued, and never reverts
    function test_lptRedemption_maxSentinel_zeroCapacityExecutesNothing() public {
        (uint256 nonce,,) = _requestWholePosition(0);
        uint256 escrowedShares = entryPoint.getRedemptionRequest(USER_A, nonce).shares;

        // Wipe the LP-token mark: both bounds read zero
        bptOracle.setTVL(0);
        bptOracle.setMode(MockBPTOracle.Mode.MANUAL);
        _sync();
        require(liquidityProviderTranche.maxRedeemMultiAsset(address(entryPoint)) == 0, "setup: the wiped mark must zero the multi-asset bound");

        (AssetClaims memory claims, uint256 quoteAssets) = _executeRedemptionMaxWithQuote(USER_A, USER_A, nonce);

        assertEq(toUint256(claims.nav), 0, "a zero-capacity maximal execution must settle nothing");
        assertEq(quoteAssets, 0, "a zero-capacity maximal execution must carry no quote");
        assertEq(entryPoint.getRedemptionRequest(USER_A, nonce).shares, escrowedShares, "the escrow must stay queued untouched");
    }

    /// @notice ST and JT redemptions never carry a quote leg: the maximizer and the quote lane are liquidity-provider-tranche-only
    function test_stRedemption_neverCarriesQuote() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(seniorTranche), 10e18);
        (uint256 nonce,) = _requestRedemption(USER_A, address(seniorTranche), shares, USER_B, 0);
        _warpPastRedemptionDelay();

        (AssetClaims memory claims, uint256 quoteAssets) = _executeRedemptionMaxWithQuote(USER_A, USER_A, nonce);
        assertGt(toUint256(claims.nav), 0, "the senior redemption must settle");
        assertEq(quoteAssets, 0, "a senior redemption must never carry a quote leg");
    }

    /// @notice The RedemptionExecuted event carries every lane exactly: shares, zero forfeiture, the previewed
    ///         claims and quote, and zeroed bonus lanes on a self-execution
    function test_lptRedemption_multiAsset_redemptionExecutedEventCarriesAllLanes() public {
        (uint256 nonce,, uint256 maxMultiAssetShares) = _requestWholePosition(0);
        (AssetClaims memory previewClaims, uint256 previewQuote) = liquidityProviderTranche.previewRedeemMultiAsset(maxMultiAssetShares);

        AssetClaims memory zeroClaims;
        vm.prank(USER_A);
        vm.expectEmit(address(entryPoint));
        emit IRoycoDayEntryPoint.RedemptionExecuted(USER_A, nonce, USER_A, maxMultiAssetShares, 0, previewClaims, previewQuote, zeroClaims, 0);
        entryPoint.executeRedemption(USER_A, nonce, type(uint256).max);
    }

    /// @notice A batch execution across tranches carries a per-request quote lane: the LPT request's multi-asset
    ///         exit fills its slot and the senior request's slot stays zero
    function test_executeRedemptions_mixedTranches_carryPerRequestQuoteLanes() public {
        (uint256 lptNonce,,) = _requestWholePosition(0);
        uint256 stShares = _acquireTrancheShares(USER_A, address(seniorTranche), 10e18);
        (uint256 stNonce,) = _requestRedemption(USER_A, address(seniorTranche), stShares, USER_B, 0);
        _warpPastRedemptionDelay();

        address[] memory users = new address[](2);
        users[0] = USER_A;
        users[1] = USER_A;
        uint256[] memory nonces = new uint256[](2);
        nonces[0] = lptNonce;
        nonces[1] = stNonce;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = type(uint256).max;
        amounts[1] = type(uint256).max;

        vm.prank(USER_A);
        (AssetClaims[] memory claims, uint256[] memory quoteAssets) = entryPoint.executeRedemptions(users, nonces, amounts);

        assertGt(quoteAssets[0], 0, "the LPT request's multi-asset exit must fill its quote slot");
        assertEq(quoteAssets[1], 0, "the senior request's quote slot must stay zero");
        assertGt(toUint256(claims[0].nav), 0, "the LPT request must settle claims");
        assertGt(toUint256(claims[1].nav), 0, "the senior request must settle claims");
    }

    /// @notice Yield-neutrality holds by magnitude on the multi-asset route: the receiver's settled value (claims
    ///         plus quote) never exceeds the executed slice of the request-time NAV snapshot, up to quantization dust
    function test_lptRedemption_multiAsset_yieldNeutralByMagnitude() public {
        (uint256 nonce,,) = _requestWholePosition(0);
        uint256 navAtRequest = toUint256(entryPoint.getRedemptionRequest(USER_A, nonce).valueAtRequestTime);

        // The LP-token mark appreciates while the request is queued
        applyLPTPnL(1000);
        _sync();

        (AssetClaims memory claims, uint256 quoteAssets) = _executeRedemptionMaxWithQuote(USER_A, USER_A, nonce);
        uint256 navLeft = toUint256(entryPoint.getRedemptionRequest(USER_A, nonce).valueAtRequestTime);

        // The receiver's value: the claims NAV plus the quote leg lifted to NAV precision (6 -> 18 decimals at par)
        uint256 settledNAV = toUint256(claims.nav) + quoteAssets * 1e12;
        // navAtRequest and navLeft are the previewRedeem-basis snapshot, so the reference now includes the idle
        // liquidity-premium senior-share leg convertToAssets excludes. Request and execution price on the same
        // previewRedeem basis, so the magnitude bound holds. One quote quantum plus one share's NAV of slack
        // covers the flow's floor roundings
        uint256 dust = 1e12 + toUint256(liquidityProviderTranche.convertToAssets(1).nav) + 1;
        assertLe(settledNAV, (navAtRequest - navLeft) + dust, "the settled value must never exceed the executed slice of the snapshot");
        assertGt(entryPoint.getProtocolFeeSharesPendingCollection(address(liquidityProviderTranche)), 0, "the queued yield must land as protocol fee shares");
    }

    /// @notice Mixed-route partials conserve the snapshot: an explicit in-kind fill floor-scales the remaining
    ///         snapshot, and cancelling the remainder returns exactly the unfilled escrow
    function test_lptRedemption_mixedRoutePartial_conservesSnapshotAndCancellation() public {
        (uint256 nonce, uint256 maxInKindShares,) = _requestWholePosition(0);
        IRoycoDayEntryPoint.RedemptionRequest memory before = entryPoint.getRedemptionRequest(USER_A, nonce);

        // An explicit in-kind partial fill floor-scales the remaining snapshot
        uint256 fillShares = maxInKindShares / 2;
        _executeRedemptionWithQuote(USER_A, USER_A, nonce, fillShares);
        uint256 sharesLeft = before.shares - fillShares;
        assertEq(
            toUint256(entryPoint.getRedemptionRequest(USER_A, nonce).valueAtRequestTime),
            Math.mulDiv(toUint256(before.valueAtRequestTime), sharesLeft, before.shares),
            "the remaining snapshot must floor-scale by the unfilled shares"
        );

        // Cancelling the remainder returns exactly the unfilled escrow
        uint256 balanceBefore = liquidityProviderTranche.balanceOf(USER_A);
        vm.prank(USER_A);
        entryPoint.cancelRedemptionRequest(nonce, USER_A);
        assertEq(liquidityProviderTranche.balanceOf(USER_A) - balanceBefore, sharesLeft, "cancellation must return exactly the unfilled escrow");
    }

    /// @notice A paused kernel zeroes both bounds through the entry point: a maximal execution settles nothing
    ///         and never reverts, and the escrow stays queued
    function test_lptRedemption_maxSentinel_pausedKernelExecutesNothing() public {
        (uint256 nonce,,) = _requestWholePosition(0);
        uint256 escrowedShares = entryPoint.getRedemptionRequest(USER_A, nonce).shares;

        vm.prank(PAUSER);
        kernel.pause();

        (AssetClaims memory claims, uint256 quoteAssets) = _executeRedemptionMaxWithQuote(USER_A, USER_A, nonce);
        assertEq(toUint256(claims.nav), 0, "a paused kernel must settle nothing");
        assertEq(quoteAssets, 0, "a paused kernel must carry no quote");
        assertEq(entryPoint.getRedemptionRequest(USER_A, nonce).shares, escrowedShares, "the escrow must stay queued untouched");
    }

    /// @notice A venue that cannot even be previewed fails the maximal redemption shut: a market whose venue is
    ///         broken is not one to move funds through, and the failure bubbles verbatim, while an explicit
    ///         in-kind amount, which never touches the venue, remains the deliberate escape hatch
    /// @notice A venue that reverts the multi-asset probe never bricks the maximal redemption, the probe is a
    ///         low-level call whose failure demotes the multi-asset bound to zero, so the maximizer falls back to
    ///         the in-kind bound and partially fills the request in-kind rather than leaving the servable portion behind
    function test_lptRedemption_maxSentinel_venueFailureFallsBackToInKind() public {
        (uint256 nonce, uint256 maxInKindShares,) = _requestWholePosition(0);
        uint256 escrowedShares = entryPoint.getRedemptionRequest(USER_A, nonce).shares;

        // The venue's removal path reverts outright: the probe swallows the failure and the maximizer stays in-kind
        balancerVault.setRevertMode(MockBalancerVault.RevertMode.REMOVE);
        (AssetClaims memory claims, uint256 quoteAssets) = _executeRedemptionMaxWithQuote(USER_A, USER_A, nonce);

        // The execution must fill exactly the in-kind bound in-kind, never touching the reverting venue
        uint256 sharesExecuted = escrowedShares - entryPoint.getRedemptionRequest(USER_A, nonce).shares;
        assertEq(sharesExecuted, maxInKindShares, "the fallback must fill exactly the in-kind bound");
        assertEq(quoteAssets, 0, "the fallback must exit in-kind");
        assertGt(toUint256(claims.lptAssets), 0, "the fallback must pay the LP-token leg");
        assertEq(bpt.balanceOf(USER_B), toUint256(claims.lptAssets), "the in-kind fill must land on the receiver");
        assertGt(entryPoint.getRedemptionRequest(USER_A, nonce).shares, 0, "the unservable remainder must stay queued, not bricked");
    }

    /// @notice A remainder whose floor-scaled snapshot hits zero is fully forfeited and settles without a redeem
    ///         call instead of bricking: the zero-NAV edge mirrors the deposit path's graceful degradation
    function test_ltRedemption_zeroNavSnapshotRemainder_fullyForfeitsWithoutReverting() public {
        // The snapshot basis is previewRedeem, whose LT reference adds the idle liquidity-premium senior-share leg
        // convertToAssets excludes. That premium is senior yield routed to the LT, and this fixture accrues no
        // senior yield (only the LT mark loss below), so no idle premium is staged and the previewRedeem reference
        // equals the convertToAssets one. A 1% sub-par mark then keeps the whole-request previewRedeem NAV strictly
        // below the requested share count (navAtRequest < requestedShares, i.e. per-share price < 1.0), so the
        // one-share remainder floor-scales navAtRequest * 1 / requestedShares to exactly zero
        applyLPTPnL(-100);
        _sync();
        uint256 requestedShares = 1000e18;
        (uint256 nonce,) = _requestRedemption(USER_A, address(liquidityProviderTranche), requestedShares, USER_B, 0);
        _warpPastRedemptionDelay();
        _executeRedemptionWithQuote(USER_A, USER_A, nonce, requestedShares - 1);
        require(
            toUint256(entryPoint.getRedemptionRequest(USER_A, nonce).valueAtRequestTime) == 0, "setup: the remainder's snapshot must floor to zero"
        );

        // The mark appreciates: the whole remainder reads as yield and is forfeited, settling without a redeem
        applyLPTPnL(1000);
        _sync();
        uint256 feeSharesBefore = entryPoint.getProtocolFeeSharesPendingCollection(address(liquidityProviderTranche));
        (AssetClaims memory claims,) = _executeRedemptionWithQuote(USER_A, USER_A, nonce, 1);
        assertEq(toUint256(claims.nav), 0, "a fully forfeited remainder must settle no claims");
        assertEq(entryPoint.getProtocolFeeSharesPendingCollection(address(liquidityProviderTranche)) - feeSharesBefore, 1, "the remainder must forfeit whole");
        assertEq(entryPoint.getRedemptionRequest(USER_A, nonce).shares, 0, "the request must be consumed, not bricked");
    }

    /// @dev Executes a redemption request as _executor for the specified shares, returning the quote leg alongside the claims
    function _executeRedemptionWithQuote(
        address _executor,
        address _user,
        uint256 _nonce,
        uint256 _shares
    )
        internal
        returns (AssetClaims memory claims, uint256 quoteAssets)
    {
        vm.prank(_executor);
        (claims, quoteAssets) = entryPoint.executeRedemption(_user, _nonce, _shares);
    }
}
