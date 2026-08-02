// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { GyroECLPMath } from "../../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/lib/GyroECLPMath.sol";
import { PausableUpgradeable } from "../../../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { Math } from "../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IRoycoDayKernel } from "../../../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoLiquidityProviderTranche } from "../../../../src/interfaces/IRoycoLiquidityProviderTranche.sol";
import { IRoycoDayAccountant } from "../../../../src/interfaces/IRoycoDayAccountant.sol";
import { WAD } from "../../../../src/libraries/Constants.sol";
import { SyncedAccountingState, TrancheType } from "../../../../src/libraries/Types.sol";
import { NAV_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../../../src/libraries/Units.sol";
import { BalancerVenueForkBase } from "./BalancerVenueForkBase.sol";

/**
 * @title Test_BalancerSwapRateOracleBase
 * @notice Fork tests for real E-CLP swaps and hook coupling, the getRate rate provider, and computeTVL on the
 *         seeded pool — the real-Balancer-math surfaces the mock layers cannot reproduce. Runs on the market
 *         the concrete leaf configures.
 * @dev Cache regime notes per test follow the discipline documented on `BalancerVenueForkBase`.
 */
abstract contract Test_BalancerSwapRateOracleBase is BalancerVenueForkBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // SHARED ARRANGE HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Standard swap-test arrange: seeded ST/JT market plus a default-depth real pool.
    function _seedForSwaps() internal {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLPT();
    }

    /// @dev Probes capacity, sizes a swap at `_fractionWAD` of it, and returns a funded swapper with the sized input.
    function _armSwapper(address _tokenIn, uint256 _fractionWAD) internal returns (address swapper, uint256 amountIn) {
        uint256 capacity = _maxSwapInBeforeRangeRevert(_tokenIn);
        assertGt(capacity, 0, "arrange: the pool must have swap capacity in the requested direction");
        amountIn = Math.mulDiv(capacity, _fractionWAD, WAD);
        swapper = _makeExternalLP("ARMED_SWAPPER");
        if (_tokenIn == address(ST)) _fundExternalLP(swapper, amountIn, 0);
        else _fundExternalLP(swapper, 0, amountIn);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // A — REAL E-CLP SWAPS ON THE HOOKLESS POOL
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice the pool is HOOKLESS by design (the template validates hooksContract == address(0)): an external
     *         swap runs no kernel sync and leaves the committed checkpoint untouched, while the Vault still
     *         prices the senior leg at the kernel rate provider's LIVE previewed rate, so a pending feed move
     *         is priced by the swap without ever being committed.
     * @dev COVERAGE NOTE: the removed hook (optional since bc91b0c0, forbidden by the template since fdaa08ce)
     *      used to force a kernel sync and checkpoint commit on every external pool op. Pricing freshness is
     *      fully replaced by the rate provider's live preview (pinned here and by the LVR test), but the
     *      commit-on-external-flow behavior has NO replacement: the committed marks go stale until the next
     *      kernel operation or explicit sync.
     */
    function test_ExternalSwap_syncsBeforeSwap_commitsPreSwapMarks() public {
        _seedForSwaps();
        _sync();
        IRoycoDayAccountant.RoycoDayAccountantState memory committed0 = ACCOUNTANT.getState();
        simulateSTYield(0.01e18); // pending move, deliberately uncommitted

        (address swapper, uint256 amountIn) = _armSwapper(testConfig.quoteAsset, 0.5e18);
        uint256 committedRate = Math.mulDiv(WAD, toUint256(committed0.lastSTEffectiveNAV) + VIRTUAL_VALUE, ST.totalSupply() + VIRTUAL_SHARES);
        uint256 liveRate = _kernelRate();
        assertGt(liveRate, committedRate, "arrange: the live-previewed rate must carry the pending feed move");

        vm.recordLogs();
        _swapExactIn(swapper, testConfig.quoteAsset, address(ST), amountIn, 0);
        (uint256 syncCount,) = _lastLogData(vm.getRecordedLogs(), address(KERNEL), IRoycoDayKernel.PreOpTrancheAccountingSynced.selector);
        assertEq(syncCount, 0, "a hookless external swap must run no kernel sync");

        IRoycoDayAccountant.RoycoDayAccountantState memory committed = ACCOUNTANT.getState();
        assertEq(committed.lastCollateralNAV, committed0.lastCollateralNAV, "the committed collateral NAV must be untouched by the swap");
        assertEq(committed.lastSTEffectiveNAV, committed0.lastSTEffectiveNAV, "the committed ST effective NAV must be untouched by the swap");
        assertEq(committed.lastJTEffectiveNAV, committed0.lastJTEffectiveNAV, "the committed JT effective NAV must be untouched by the swap");
        assertEq(committed.lastLPTRawNAV, committed0.lastLPTRawNAV, "the committed LPT raw NAV must be untouched by the swap");
        // The swap priced the senior leg at the live rate: the pool's rate view still reads it after the swap
        (, uint256[] memory tokenRates) = VAULT.getPoolTokenRates(POOL);
        assertEq(tokenRates[_stPoolIndex()], liveRate, "the pool must price the senior leg at the live previewed rate");
        assertGt(toUint256(_liveLPTRawNAV()), toUint256(committed.lastLPTRawNAV), "the swap's fee lands in the pool above the stale committed mark");
    }

    /**
     * @notice swap fees accrue to the BPT: the oracle TVL rises by exactly the pool-retained fee, the BPT
     *         supply does not move, and NAV-per-BPT strictly rises.
     * @dev Bound source: `_swapFeeTVLBound` (fee kept = Vin * f * (1 - aggregate share), marked within the
     *      in-range price band). Flat market since the last sync, so the hook's re-sync leaves the senior rate
     *      untouched and the TVL delta isolates the fee.
     */
    function test_ExternalSwap_feeAccruesToBPT_tvlRiseWithinDerivedBound() public {
        _seedForSwaps();
        _sync();
        uint256 tvl0 = _poolTVL();
        uint256 supply0 = _bptSupply();
        uint256 navPerBPT0 = _navPerBPTWAD();

        (address swapper, uint256 amountIn) = _armSwapper(testConfig.quoteAsset, 0.25e18);
        _swapExactIn(swapper, testConfig.quoteAsset, address(ST), amountIn, 0);

        (uint256 lo, uint256 hi) = _swapFeeTVLBound(_quoteToNAV(amountIn));
        uint256 tvlDelta = _poolTVL() - tvl0;
        assertGe(tvlDelta, lo, "TVL must grow by at least the pool-retained swap fee (band floor)");
        assertLe(tvlDelta, hi, "TVL must grow by no more than the full retained swap fee");
        assertEq(_bptSupply(), supply0, "a swap must not move the BPT supply");
        assertGt(_navPerBPTWAD(), navPerBPT0, "NAV per BPT must strictly rise on the accrued fee");
    }

    /**
     * @notice the kernel's LPT raw NAV captures exactly its pro-rata share of the swap-fee TVL growth:
     *         the kernel valuation path (venue pricing -> oracle) moves with the venue, not with its own ledger.
     */
    function test_ExternalSwap_lptRawNAVGain_isPhiOfFee() public {
        _seedForSwaps();
        _sync();
        uint256 tvl0 = _poolTVL();
        uint256 lptRaw0 = toUint256(_liveLPTRawNAV());
        uint256 lptOwnedBPT = toUint256(KERNEL.getState().totalLPTAssets);
        uint256 supply0 = _bptSupply();

        (address swapper, uint256 amountIn) = _armSwapper(testConfig.quoteAsset, 0.25e18);
        _swapExactIn(swapper, testConfig.quoteAsset, address(ST), amountIn, 0);

        assertEq(toUint256(KERNEL.getState().totalLPTAssets), lptOwnedBPT, "a swap must not move the kernel's owned-BPT ledger");
        uint256 expectedGain = Math.mulDiv(_poolTVL() - tvl0, lptOwnedBPT, supply0);
        assertApproxEqAbs(toUint256(_liveLPTRawNAV()) - lptRaw0, expectedGain, _tol2(), "LPT raw NAV must gain its pool share of the accrued fee");
    }

    /**
     * @notice a paused kernel blocks external swaps: the pool's WITH_RATE leg reads the kernel rate provider,
     *         whose `whenNotPaused` revert bubbles through the Vault, so the pool never executes operations on
     *         a faulty kernel state. Unpausing restores swap liveness. This is the hookless replacement for the
     *         removed hook's pause coupling.
     */
    function test_RevertIf_ExternalSwapWhileHookPaused_thenRecovers() public {
        _seedForSwaps();
        (address swapper, uint256 amountIn) = _armSwapper(testConfig.quoteAsset, 0.25e18);

        _pauseKernel();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        _swapExactIn(swapper, testConfig.quoteAsset, address(ST), amountIn, 0);

        _unpauseKernel();
        uint256 amountOut = _swapExactIn(swapper, testConfig.quoteAsset, address(ST), amountIn, 0);
        assertGt(amountOut, 0, "the identical swap must succeed once the kernel is unpaused");
    }

    /**
     * @notice the kernel pause blast radius covers the WHOLE pool surface on the hookless topology: the
     *         kernel-routed multi-asset flows revert at the kernel's own gate and third-party swaps revert
     *         through the rate provider, and both resume after unpause. There is no narrower hook pause: the
     *         hook is removed, so the kernel's pause is the single liveness switch for the venue.
     */
    function test_ExternalSwap_hookPaused_kernelFlowsUnaffected() public {
        _seedForSwaps();
        (address swapper, uint256 amountIn) = _armSwapper(testConfig.quoteAsset, 0.25e18);
        uint256 stLeg = testConfig.initialFunding / 1000;
        uint256 quoteLeg = _quoteAssetsForValue(KERNEL.convertCollateralAssetsToValue(toTrancheUnits(stLeg)));
        _pauseKernel();

        vm.startPrank(LPT_ALICE_ADDRESS);
        IERC20(COLLATERAL_ASSET).approve(address(LPT), stLeg);
        IERC20(testConfig.quoteAsset).approve(address(LPT), quoteLeg);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        IRoycoLiquidityProviderTranche(address(LPT)).depositMultiAsset(stLeg, quoteLeg, 0, LPT_ALICE_ADDRESS);
        vm.stopPrank();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        _swapExactIn(swapper, testConfig.quoteAsset, address(ST), amountIn, 0);

        _unpauseKernel();
        uint256 shares = _doDepositLPTMulti(LPT_ALICE_ADDRESS, stLeg, quoteLeg, 0).shares;
        assertGt(shares, 0, "the kernel-routed multi-asset deposit must resume after unpause");
        assertGt(_swapExactIn(swapper, testConfig.quoteAsset, address(ST), amountIn, 0), 0, "external swaps must resume after unpause");
    }

    /**
     * @notice the E-CLP price range is a hard wall: the probed boundary capacity executes, ten percent
     *         beyond it reverts `AssetBoundsExceeded` from the Gyro math.
     */
    function test_RevertIf_ExternalSwapBeyondRangeBoundary_AssetBoundsExceeded() public {
        _seedForSwaps();
        uint256 capacity = _maxSwapInBeforeRangeRevert(testConfig.quoteAsset);
        assertGt(capacity, 0, "arrange: the pool must have swap capacity");

        uint256 snapshotId = vm.snapshotState();
        address swapper = _makeExternalLP("BOUNDARY_SWAPPER");
        _fundExternalLP(swapper, 0, capacity);
        uint256 amountOut = _swapExactIn(swapper, testConfig.quoteAsset, address(ST), capacity, 0);
        assertGt(amountOut, 0, "the probed boundary capacity itself must execute");
        vm.revertToState(snapshotId);

        uint256 beyond = Math.mulDiv(capacity, 11, 10);
        address swapper2 = _makeExternalLP("BEYOND_BOUNDARY_SWAPPER");
        _fundExternalLP(swapper2, 0, beyond);
        vm.expectRevert(GyroECLPMath.AssetBoundsExceeded.selector);
        _swapExactIn(swapper2, testConfig.quoteAsset, address(ST), beyond, 0);
    }

    /**
     * @notice swap capacity matches the band geometry: at a range boundary the pool holds a single asset,
     *         so each direction's value capacity approximates the OPPOSING leg's live balance. Documents the
     *         sizing rule every skew-driven test relies on.
     * @dev Cache regime: rates read frozen after the arrange sync. Bounds are deliberately loose ([50%, 110%])
     *      — the claim is the geometry, not a curve-exact figure.
     */
    function test_ExternalSwap_capacityAsymmetry_matchesBandGeometry() public {
        _seedForSwaps();
        _sync();
        uint256[] memory live = _liveBalances();
        uint256 stLegValue = live[_stPoolIndex()];
        uint256 quoteLegValue = live[_quotePoolIndex()];

        uint256 capQuoteIn = _maxSwapInBeforeRangeRevert(testConfig.quoteAsset);
        uint256 capQuoteValue = _quoteToNAV(capQuoteIn);
        assertGe(capQuoteValue, stLegValue / 2, "quote->ST capacity must approach the ST leg's depth (>= 50%)");
        assertLe(capQuoteValue, Math.mulDiv(stLegValue, 11, 10), "quote->ST capacity cannot exceed the ST leg's depth (+10% fee/rounding slack)");

        uint256 capSTIn = _maxSwapInBeforeRangeRevert(address(ST));
        uint256 capSTValue = _stSharesToNAVAtRate(capSTIn, _kernelRate());
        assertGe(capSTValue, quoteLegValue / 2, "ST->quote capacity must approach the quote leg's depth (>= 50%)");
        assertLe(capSTValue, Math.mulDiv(quoteLegValue, 11, 10), "ST->quote capacity cannot exceed the quote leg's depth (+10% fee/rounding slack)");
    }

    /**
     * @notice a swap in the same block as a P&L sync executes, and the same-block re-sync is a no-op. The hook
     *         syncs BEFORE the swap rather than blocking it, so a same-block sync-then-swap runs. Because the
     *         re-sync is idempotent, no double accrual occurs: the senior and junior marks are unchanged by the
     *         hook's own same-block sync.
     */
    function test_swapSameBlockAsSync_executesAndReSyncIsNoOp() public {
        _seedForSwaps();
        _sync();
        IRoycoDayAccountant.RoycoDayAccountantState memory committed0 = ACCOUNTANT.getState();

        (address swapper, uint256 amountIn) = _armSwapper(testConfig.quoteAsset, 0.25e18);
        uint256 amountOut = _swapExactIn(swapper, testConfig.quoteAsset, address(ST), amountIn, 0);
        assertGt(amountOut, 0, "a swap in the sync's own block executes rather than being blocked");

        IRoycoDayAccountant.RoycoDayAccountantState memory committed1 = ACCOUNTANT.getState();
        assertEq(committed1.lastSTEffectiveNAV, committed0.lastSTEffectiveNAV, "the same-block hook re-sync must be a no-op on the senior mark");
        assertEq(committed1.lastJTEffectiveNAV, committed0.lastJTEffectiveNAV, "the same-block hook re-sync must be a no-op on the junior mark");
    }

    /**
     * @notice the rate-staleness LVR arb is impossible through the pool: the swap always prices at the freshly
     *         synced rate. The before-swap hook syncs the kernel (rewriting the transient rate cache) and the
     *         Vault reloads token rates after `onBeforeSwap`, so a swap against the "stale" mark yields
     *         byte-identical output with and without an explicit front-run sync. (Stale-rate exposure remains
     *         for off-pool venues quoting the last mark, out of scope here.)
     */
    function test_rateStalenessLVR_noArbThroughPool_swapAlwaysPricesFreshRate() public {
        _seedForSwaps();
        _sync();
        uint256 staleRate = _kernelRate();

        simulateSTYield(0.01e18); // the stale-rate window under attack: the feed has moved, no sync has committed it
        (address swapper, uint256 amountIn) = _armSwapper(testConfig.quoteAsset, 0.25e18);

        // Path A: swap immediately against the "stale" market — no explicit sync.
        uint256 snapshotId = vm.snapshotState();
        uint256 outWithoutSync = _swapExactIn(swapper, testConfig.quoteAsset, address(ST), amountIn, 0);
        uint256 rateSeenBySwapA = _kernelRate();
        vm.revertToState(snapshotId);

        // Path B: explicitly sync first, then the identical swap.
        _sync();
        uint256 outWithSync = _swapExactIn(swapper, testConfig.quoteAsset, address(ST), amountIn, 0);

        assertEq(outWithoutSync, outWithSync, "the pool pays the identical amount with and without a front-run sync");
        assertEq(rateSeenBySwapA, _kernelRate(), "both paths price the senior leg at the same freshly-synced rate");
        assertGt(rateSeenBySwapA, staleRate, "the rate the swap priced at is the POST-move rate, not the stale committed one");
    }

    /**
     * @notice a round trip cannot profit and pays at least (approximately) two fee legs: no-free-lunch
     *         under the fresh-rate regime exercised by test_rateStalenessLVR_noArbThroughPool_swapAlwaysPricesFreshRate.
     * @dev Derivation: the reverse swap re-walks the same curve, so path effects cancel and the loss is the two
     *      fee legs, `f*Vin + f*Vout1 ~= 2*f*Vin`, floored conservatively at `2*f*Vin*alpha`.
     */
    function test_ExternalSwap_roundTrip_noProfit_lossAtLeastDoubleFee() public {
        _seedForSwaps();
        _sync();
        (address swapper, uint256 amountIn) = _armSwapper(testConfig.quoteAsset, 0.25e18);

        uint256 stOut = _swapExactIn(swapper, testConfig.quoteAsset, address(ST), amountIn, 0);
        uint256 quoteBack = _swapExactIn(swapper, address(ST), testConfig.quoteAsset, stOut, 0);

        assertLe(quoteBack, amountIn, "a round trip must never profit");
        uint256 lossValue = _quoteToNAV(amountIn - quoteBack);
        (uint256 alpha,) = _stPriceBandWAD();
        uint256 minLoss = Math.mulDiv(_quoteToNAV(amountIn), 2 * _staticSwapFeePctWAD(), WAD);
        minLoss = Math.mulDiv(minLoss, alpha, WAD);
        assertGe(lossValue + _tol2(), minLoss, "the round-trip loss must cover both fee legs (band-discounted floor)");
    }

    /**
     * @notice an executed swap's realized price stays inside the fee-adjusted E-CLP band, both directions.
     * @dev Derivation: the pool's internal ST-in-quote price q is confined to [alpha, beta]; an exact-in swap
     *      charges the static fee f on the input. Quote -> ST therefore pays out value in [Vin*(1-f)/beta,
     *      Vin*(1-f)/alpha]; ST -> quote pays out value in [Vin*(1-f)*alpha, Vin*(1-f)*beta]. Values are
     *      marked with the swap's own senior rate: the post-swap `getRate()` read observes the transient
     *      cache the hook's pre-swap sync wrote, which (the Vault reloads rates after `onBeforeSwap`) is
     *      exactly the rate the pool priced the ST leg at. Cache regime: frozen-cache reads after each swap.
     */
    function test_ExternalSwap_executionPriceWithinBand_bothDirections() public {
        _seedForSwaps();
        (uint256 bandLo, uint256 bandHi) = _stPriceBandWAD();
        uint256 f = _staticSwapFeePctWAD();

        // Direction 1: quote -> ST (buying the senior leg), sized at a quarter of the probed capacity.
        uint256 snapshotId = vm.snapshotState();
        {
            uint256 capacity = _maxSwapInBeforeRangeRevert(testConfig.quoteAsset);
            assertGt(capacity, 0, "quote->ST: the pool must have swap capacity");
            uint256 amountIn = capacity / 4;
            address swapper = _makeExternalLP("SWAPPER_QUOTE_TO_ST");
            _fundExternalLP(swapper, 0, amountIn);
            uint256 amountOut = _swapExactIn(swapper, testConfig.quoteAsset, address(ST), amountIn, 0);

            uint256 valueIn = _quoteToNAV(amountIn);
            uint256 valueOut = _stSharesToNAVAtRate(amountOut, _kernelRate());
            uint256 valueInAfterFee = Math.mulDiv(valueIn, WAD - f, WAD);
            assertGe(valueOut + _tol2(), Math.mulDiv(valueInAfterFee, WAD, bandHi), "quote->ST: swap paid out below the fee-adjusted band floor");
            assertLe(valueOut, Math.mulDiv(valueInAfterFee, WAD, bandLo) + _tol2(), "quote->ST: swap paid out above the fee-adjusted band ceiling");
        }
        vm.revertToState(snapshotId);

        // Direction 2: ST -> quote (selling the senior leg), same sizing rule from the same base state.
        {
            uint256 capacity = _maxSwapInBeforeRangeRevert(address(ST));
            assertGt(capacity, 0, "ST->quote: the pool must have swap capacity");
            uint256 amountIn = capacity / 4;
            address swapper = _makeExternalLP("SWAPPER_ST_TO_QUOTE");
            _fundExternalLP(swapper, amountIn, 0);
            uint256 amountOut = _swapExactIn(swapper, address(ST), testConfig.quoteAsset, amountIn, 0);

            uint256 valueIn = _stSharesToNAVAtRate(amountIn, _kernelRate());
            uint256 valueOut = _quoteToNAV(amountOut);
            uint256 valueInAfterFee = Math.mulDiv(valueIn, WAD - f, WAD);
            assertGe(valueOut + _tol2(), Math.mulDiv(valueInAfterFee, bandLo, WAD), "ST->quote: swap paid out below the fee-adjusted band floor");
            assertLe(valueOut, Math.mulDiv(valueInAfterFee, bandHi, WAD) + _tol2(), "ST->quote: swap paid out above the fee-adjusted band ceiling");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // B — getRate / RATE PROVIDER
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice `getRate` equals the committed senior NAV per share priced through the virtual-shares primitive:
     *         `floor(WAD * (lastSTEffectiveNAV + VIRTUAL_ASSETS) / (stTotalSupply + VIRTUAL_SHARES))` right after
     *         a sync. This is the number the pool's WITH_RATE leg prices at.
     * @dev Cache regime: frozen-cache read of the sync's written value — the exact value the Vault consumes.
     *      (Cache-miss vs live-path parity is pinned in the mock-based pricing suites;
     *      here the fork asserts the committed coherence of the value real pool ops execute against.)
     */
    function test_GetRate_matchesCommittedSeniorNAVPerShare() public {
        _seedForSwaps();
        _sync();
        uint256 rate = _kernelRate();
        uint256 supply = ST.totalSupply();
        uint256 stEff = toUint256(ACCOUNTANT.getState().lastSTEffectiveNAV);
        // _computeTrancheShareRate == _convertToValue(WAD, supply, stEff), which now carries the virtual
        // shares/value offset: floor((stEff + VIRTUAL_VALUE) * WAD / (supply + VIRTUAL_SHARES))
        assertEq(
            rate,
            Math.mulDiv(WAD, stEff + VIRTUAL_VALUE, supply + VIRTUAL_SHARES),
            "getRate must equal the committed senior effective NAV per effective share (floored)"
        );
        // Independent counterweight on plain checked integers (no shared math library): a floored NAV-per-share
        // must reconstruct the committed effective senior NAV to within one unit of effective-supply floor loss —
        // scaling the rate back up by the effective supply never overshoots WAD * effective NAV, and undershoots
        // it by less than one full effective supply.
        assertLe(rate * (supply + VIRTUAL_SHARES), WAD * (stEff + VIRTUAL_VALUE), "rate * effective supply must never overstate the committed senior NAV");
        assertGt(
            rate * (supply + VIRTUAL_SHARES) + (supply + VIRTUAL_SHARES),
            WAD * (stEff + VIRTUAL_VALUE),
            "rate * effective supply must undershoot the committed senior NAV by less than one effective-supply unit"
        );
    }

    /**
     * @notice the ST_SHARE_PRICE cache is OPERATION-scoped: the sync's `withPriceCache` frame clears it at the
     *         operation's exit, so a later `getRate` read reprices LIVE from committed state and immediately
     *         tracks a post-sync feed move through the preview path, exactly matching the previewed post-mint
     *         supply and effective NAV. In-frame freezing (an inline senior mint inside ONE operation) is
     *         pinned by the concrete harness test, since only a single call frame can observe it.
     */
    function test_GetRate_cacheHit_freezesSeniorMark() public {
        _seedForSwaps();
        _sync();
        uint256 rateAtSync = _kernelRate();
        simulateSTYield(0.01e18);

        // The frame cleared the cache at the sync's exit, so the read previews the moved feed live
        (SyncedAccountingState memory preview,, uint256 stSupplyAfterMints) = KERNEL.previewSyncTrancheAccountingFor(TrancheType.SENIOR);
        uint256 expectedLive = Math.mulDiv(WAD, toUint256(preview.stEffectiveNAV) + VIRTUAL_VALUE, stSupplyAfterMints + VIRTUAL_SHARES);
        assertGt(_kernelRate(), rateAtSync, "the post-frame read must reprice the moved feed live");
        assertEq(_kernelRate(), expectedLive, "the live read must match the previewed post-mint NAV per effective share");

        // The next sync commits the move and the fresh committed read agrees with the live preview
        _sync();
        assertGt(_kernelRate(), rateAtSync, "the committed rate must carry the moved feed");
        assertEq(
            _kernelRate(),
            Math.mulDiv(WAD, toUint256(ACCOUNTANT.getState().lastSTEffectiveNAV) + VIRTUAL_VALUE, ST.totalSupply() + VIRTUAL_SHARES),
            "the committed read must equal the committed NAV per effective share"
        );
    }

    /**
     * @notice the rate is monotone under senior yield and, after a premium-minting sync, still equals the
     *         committed NAV per POST-MINT share: the fee/premium share mints dilute the rate path exactly as
     *         committed.
     * @dev The LPT overlay is enabled so the sync mints liquidity-premium ST shares (a real supply change
     *      between the two reads); the mirror divides by the observed post-mint supply.
     */
    function test_GetRate_monotoneUnderYield_tracksCommittedMark() public {
        _seedForSwaps();
        _driveLiquidityUtilizationTo(0.8e18);
        _flushPremiumAccrual();
        uint256 rate0 = _kernelRate();
        uint256 supply0 = ST.totalSupply();

        _warpForward(1 days);
        _applySTYield(0.02e18);
        _sync();

        uint256 rate1 = _kernelRate();
        assertGt(rate1, rate0, "senior yield must raise the rate");
        assertGt(ST.totalSupply(), supply0, "arrange: the sync must have minted premium/fee shares");
        // getRate carries the offset: floor((stEff + VIRTUAL_VALUE) * WAD / (postMintSupply + VIRTUAL_SHARES))
        uint256 expected = Math.mulDiv(WAD, toUint256(ACCOUNTANT.getState().lastSTEffectiveNAV) + VIRTUAL_VALUE, ST.totalSupply() + VIRTUAL_SHARES);
        assertEq(rate1, expected, "the refreshed rate must equal committed NAV per post-mint effective share");
    }

    /**
     * @notice on the hookless pool an external swap neither syncs nor caches a rate: `getRate` previews the
     *         moved feed live before AND after the swap (the same rate the Vault priced the swap's senior leg
     *         at), while the committed checkpoint stays at the pre-move marks until the next kernel sync.
     */
    function test_GetRate_externalSwapRefreshesRateThroughHook() public {
        _seedForSwaps();
        _sync();
        uint256 rateBefore = _kernelRate();
        NAV_UNIT committedSTEff0 = ACCOUNTANT.getState().lastSTEffectiveNAV;
        simulateSTYield(0.01e18);
        uint256 liveRate = _kernelRate();
        assertGt(liveRate, rateBefore, "the live preview must carry the moved feed before any sync");

        (address swapper, uint256 amountIn) = _armSwapper(testConfig.quoteAsset, 0.1e18);
        _swapExactIn(swapper, testConfig.quoteAsset, address(ST), amountIn, 0);

        // The swap moved neither the senior supply nor the collateral marks, so the live preview is unchanged
        assertEq(_kernelRate(), liveRate, "the swap must not move the live-previewed senior rate");
        assertEq(ACCOUNTANT.getState().lastSTEffectiveNAV, committedSTEff0, "the committed senior mark must be untouched by the swap");

        // Only a kernel sync commits the move
        _sync();
        assertEq(
            _kernelRate(),
            Math.mulDiv(WAD, toUint256(ACCOUNTANT.getState().lastSTEffectiveNAV) + VIRTUAL_VALUE, ST.totalSupply() + VIRTUAL_SHARES),
            "the synced rate must equal the committed NAV per effective share"
        );
    }

    /// @notice the Vault's own view of the pool token rates reads the kernel rate provider live: the
    ///         WITH_RATE registration is empirically wired to `getRate`, and the STANDARD quote leg reads 1.0.
    function test_GetRate_vaultTokenRateView_matchesKernelPricing() public {
        _seedForSwaps();
        _sync();
        (, uint256[] memory tokenRates) = VAULT.getPoolTokenRates(POOL);
        assertEq(tokenRates[_stPoolIndex()], _kernelRate(), "the Vault's ST leg rate must be the kernel's getRate");
        assertEq(tokenRates[_quotePoolIndex()], WAD, "the STANDARD quote leg must read a 1.0 rate");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // C — computeTVL ON THE SEEDED POOL
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice on the seeded real pool the oracle TVL is a nonzero value inside the rate-scaled balance
     *         band: `TVL ∈ [MtM * alpha, MtM]` where MtM is the feed-price mark-to-market of actual balances
     *         (the sum of live scaled-18 balances: ST raw * getRate + quote raw * 1e12, both at feed price 1.0).
     * @dev The interior-branch TVL is the curve's minimum-composition value at the feed price, so it never
     *      exceeds the actual-balance MtM; re-marking each unit from an in-range internal price to 1.0 moves
     *      value by at most (1 - alpha). First fork assertion of a real nonzero E-CLP `computeTVL`.
     */
    function test_ComputeTVL_seededPool_withinRateScaledBalanceBand() public {
        _seedForSwaps();
        _sync();
        uint256 mtm = _markToMarketAtFeeds();
        uint256 tvl = _poolTVL();
        assertGt(tvl, 0, "the seeded pool's oracle TVL must be nonzero");
        (uint256 lo, uint256 hi) = _tvlMtMBand(mtm);
        assertGe(tvl, lo, "TVL must not undercut the band floor (MtM * alpha)");
        assertLe(tvl, hi, "TVL must never exceed the actual-balance mark-to-market");
    }

    /**
     * @notice manipulation resistance, quantified: a swap of half the pool's capacity moves the oracle TVL
     *         by no more than the retained fee, while the pool's real composition and spot price move heavily.
     * @dev The invariant-based TVL sees a swap only through fee-driven invariant growth (the oracle reads the
     *      invariant, not the balances directly), so spot/composition manipulation cannot move the LPT mark.
     */
    function test_ComputeTVL_underSwapManipulation_boundedByFee() public {
        _seedForSwaps();
        _sync();
        uint256 tvl0 = _poolTVL();
        uint256 stShare0 = _stValueShareWAD();
        uint256 spot0 = _spotSTinQuoteWAD();

        (uint256 amountIn,) = _skewPool(true, 0.5e18); // buy the ST leg with half the boundary capacity

        uint256 tvlDelta = _poolTVL() - tvl0;
        (, uint256 feeHi) = _swapFeeTVLBound(_quoteToNAV(amountIn));
        assertLe(tvlDelta, feeHi, "the oracle TVL may move by at most the retained swap fee");

        uint256 stShare1 = _stValueShareWAD();
        assertLt(stShare1, stShare0, "buying the ST leg must deplete its composition share");
        uint256 shiftValue = Math.mulDiv(stShare0 - stShare1, _markToMarketAtFeeds(), WAD);
        assertGe(shiftValue, 10 * tvlDelta, "the real composition shift must dwarf the TVL move (>= 10x)");
        assertGt(_spotSTinQuoteWAD(), spot0, "the spot price must have moved with the skew");
    }

    /// @notice the TVL/MtM band survives a near-boundary skew: even at maximal in-range composition
    ///         distortion the oracle never overstates the pool and never undercuts the band floor.
    function test_ComputeTVL_nearBoundarySkew_bandHolds() public {
        _seedForSwaps();
        _sync();
        _skewPool(true, 0.9e18);
        uint256 mtm = _markToMarketAtFeeds();
        uint256 tvl = _poolTVL();
        (uint256 lo, uint256 hi) = _tvlMtMBand(mtm);
        // The E-CLP curve-minimum floor mtm*alpha, relaxed by a ~2e-6 proportional basis tolerance: the
        // convert-to-assets rounding basis shifted computeTVL vs the feed MtM by ~5e-7 (the same shift behind
        // the reinvest/entry-cost conservation bounds), landing a hair below the exact alpha floor at a
        // near-boundary composition. Proportional, not the absolute maxNAVDelta which is ~1e-10 relative here.
        assertGe(tvl + Math.mulDiv(mtm, 2e12, WAD), lo, "TVL must hold the band floor at a near-boundary composition");
        assertLe(tvl, hi, "TVL must never overstate the pool, even maximally skewed");
    }

    /**
     * @notice the oracle's senior leg composes the kernel's `getRate`, not its constant-1.0 feed: a feed
     *         move followed by a sync moves TVL by the ST leg's live balance re-scaled through the refreshed
     *         rate, within the in-range marginal-price band.
     * @dev Expected delta: `d = liveST_before * (r2 - r1) / r1`, and `dTVL ∈ [d * alpha, d * beta]` — the
     *      marginal invariant-value of the extra rate-scaled balance is an in-range internal price. The quote
     *      leg is inert. Pins the composition mechanics: rates enter via live balances, feeds only via prices.
     */
    function test_ComputeTVL_rateLeg_composesKernelGetRate() public {
        _seedForSwaps();
        _sync();
        uint256 rate0 = _kernelRate();
        uint256 liveST0 = _liveBalances()[_stPoolIndex()];
        uint256 tvl0 = _poolTVL();

        simulateSTYield(0.01e18);
        _sync();

        uint256 delta = Math.mulDiv(liveST0, _kernelRate() - rate0, rate0);
        uint256 tvlDelta = _poolTVL() - tvl0;
        (uint256 alpha, uint256 beta) = _stPriceBandWAD();
        assertGe(tvlDelta + _tol2(), Math.mulDiv(delta, alpha, WAD), "the TVL move must capture the rate-scaled ST leg (band floor)");
        assertLe(tvlDelta, Math.mulDiv(delta, beta, WAD) + _tol2(), "the TVL move must not exceed the rate-scaled ST leg (band ceiling)");
    }

    /**
     * @notice `computeTVL` reads cleanly INSIDE `Vault.unlock`: every kernel venue op runs its callback inside
     *         its own unlock and reads the LPT oracle there (the add credits and re-commits the fresh mark
     *         mid-unlock). Validates the template's `shouldRevertIfVaultUnlocked = false` choice empirically:
     *         flipping it would brick every kernel-routed venue operation. The hookless external add runs no
     *         kernel code at all, so it can never trip the oracle's unlock guard.
     */
    function test_ComputeTVL_midVaultUnlock_doesNotRevert() public {
        _seedForSwaps();
        _sync();
        assertFalse(_oracleShouldRevertIfVaultUnlocked(), "the template must deploy the oracle readable mid-unlock");

        // The kernel-routed multi-asset deposit reads the oracle inside its own venue unlock and must succeed
        uint256 stLeg = testConfig.initialFunding / 1000;
        uint256 quoteLeg = _quoteAssetsForValue(KERNEL.convertCollateralAssetsToValue(toTrancheUnits(stLeg)));
        uint256 shares = _doDepositLPTMulti(LPT_ALICE_ADDRESS, stLeg, quoteLeg, 0).shares;
        assertGt(shares, 0, "the kernel deposit (with its mid-unlock oracle read) must succeed");

        // The hookless external add touches no kernel code and succeeds untouched by the unlock guard
        address actor = _makeExternalLP("MID_UNLOCK_ADDER");
        uint256 stShares = _rawBalances()[_stPoolIndex()] / 20;
        uint256 quoteAssets = _rawBalances()[_quotePoolIndex()] / 20;
        _fundExternalLP(actor, stShares, quoteAssets);
        vm.recordLogs();
        uint256 bptOut = _externalAddUnbalanced(actor, stShares, quoteAssets, 0);
        assertGt(bptOut, 0, "the external add must succeed");
        (uint256 syncCount,) = _lastLogData(vm.getRecordedLogs(), address(KERNEL), IRoycoDayKernel.PreOpTrancheAccountingSynced.selector);
        assertEq(syncCount, 0, "a hookless external add must run no kernel sync");
    }

    /// @notice the kernel's LPT conversions round-trip on the LIVE oracle TVL with bounded floor loss:
    ///         `back <= x` and the gap is at most one NAV-wei's worth of BPT plus the final floor.
    function test_LPTConversions_roundTripFloor_onLiveTVL() public {
        _seedForSwaps();
        _sync();
        uint256 x = toUint256(KERNEL.getState().totalLPTAssets) / 3;
        uint256 nav = toUint256(KERNEL.convertLPTAssetsToValue(toTrancheUnits(x)));
        uint256 back = toUint256(KERNEL.convertValueToLPTAssets(toNAVUnits(nav)));
        assertLe(back, x, "the round trip must never create BPT");
        uint256 maxGap = Math.mulDiv(_bptSupply(), 1, _poolTVL()) + 2; // one NAV-wei of BPT + the two floors
        assertLe(x - back, maxGap, "the round-trip floor loss must stay within one NAV-wei of BPT");
    }
}
