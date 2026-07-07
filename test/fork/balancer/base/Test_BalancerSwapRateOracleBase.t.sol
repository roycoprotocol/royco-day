// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { GyroECLPMath } from "../../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/lib/GyroECLPMath.sol";
import { Math } from "../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

import { WAD } from "../../../../src/libraries/Constants.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../../src/libraries/Units.sol";
import { BalancerVenueForkBase } from "./BalancerVenueForkBase.sol";

/**
 * @title Test_BalancerSwapRateOracleBase
 * @notice Fork tests for real E-CLP swaps, the getRate rate provider, and computeTVL on the
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
        _seedDefaultLT();
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
    // A — REAL E-CLP SWAPS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Swap fees accrue to the BPT: the oracle TVL rises by exactly the pool-retained fee, the BPT
     *         supply does not move, and NAV-per-BPT strictly rises.
     * @dev Bound source: `_swapFeeTVLBound` (fee kept = Vin * f * (1 - aggregate share), marked within the
     *      in-range price band). Flat market since the last sync, so the senior rate is unchanged and the TVL
     *      delta isolates the fee.
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
     * @notice the kernel's LT raw NAV captures exactly its pro-rata share of the swap-fee TVL growth:
     *         the kernel valuation path (quoter -> oracle) moves with the venue, not with its own ledger.
     */
    function test_ExternalSwap_ltRawNAVGain_isPhiOfFee() public {
        _seedForSwaps();
        _sync();
        uint256 tvl0 = _poolTVL();
        uint256 ltRaw0 = toUint256(LT.getRawNAV());
        uint256 ltOwnedBPT = toUint256(KERNEL.getState().ltOwnedYieldBearingAssets);
        uint256 supply0 = _bptSupply();

        (address swapper, uint256 amountIn) = _armSwapper(testConfig.quoteAsset, 0.25e18);
        _swapExactIn(swapper, testConfig.quoteAsset, address(ST), amountIn, 0);

        assertEq(toUint256(KERNEL.getState().ltOwnedYieldBearingAssets), ltOwnedBPT, "a swap must not move the kernel's owned-BPT ledger");
        uint256 expectedGain = Math.mulDiv(_poolTVL() - tvl0, ltOwnedBPT, supply0);
        assertApproxEqAbs(toUint256(LT.getRawNAV()) - ltRaw0, expectedGain, _tol2(), "LT raw NAV must gain its pool share of the accrued fee");
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
     * @notice a round trip cannot profit and pays at least (approximately) two fee legs: no-free-lunch
     *         under the fresh-rate regime of FINDING 9.
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
     *      marked with the senior rate the pool priced the ST leg at: with no pool hook an external swap does not
     *      resync, so the frozen cached rate the Vault read for the swap is the same rate the post-swap
     *      `getRate()` read observes. Cache regime: frozen-cache reads after each swap.
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
     * @notice `getRate` equals the committed senior NAV per share: `floor(WAD * lastSTEffectiveNAV /
     *         stTotalSupply)` right after a sync. This is the number the pool's WITH_RATE leg prices at.
     * @dev Cache regime: frozen-cache read of the sync's written value — the exact value the Vault consumes.
     *      (Cache-miss vs live-path parity is pinned in the mock-based quoter suite (test/concrete/Quoters);
     *      here the fork asserts the committed coherence of the value real pool ops execute against.)
     */
    function test_GetRate_matchesCommittedSeniorNAVPerShare() public {
        _seedForSwaps();
        _sync();
        uint256 rate = _kernelRate();
        uint256 supply = ST.totalSupply();
        uint256 stEff = toUint256(ACCOUNTANT.getState().lastSTEffectiveNAV);
        assertEq(rate, Math.mulDiv(WAD, stEff, supply), "getRate must equal the committed senior effective NAV per share (floored)");
        // Independent counterweight on plain checked integers (no shared math library): a floored NAV-per-share
        // must reconstruct the committed senior NAV to within one unit of supply-scale floor loss — scaling the
        // rate back up by the supply never overshoots WAD * NAV, and undershoots it by less than one full supply.
        assertLe(rate * supply, WAD * stEff, "rate * supply must never overstate the committed senior NAV");
        assertGt(rate * supply + supply, WAD * stEff, "rate * supply must undershoot the committed senior NAV by less than one supply unit");
    }

    /// @notice within a synced transaction the rate is FROZEN: a feed move after the sync does not move
    ///         `getRate` until the next sync rewrites the cache. The senior mark inside an op is stable.
    function test_GetRate_cacheHit_freezesSeniorMark() public {
        _seedForSwaps();
        _sync();
        uint256 rateAtSync = _kernelRate();
        simulateSTYield(0.01e18);
        assertEq(_kernelRate(), rateAtSync, "the frozen cached rate must ignore a post-sync feed move");
        _sync();
        assertGt(_kernelRate(), rateAtSync, "the next sync must refresh the frozen mark to the moved feed");
    }

    /**
     * @notice the rate is monotone under senior yield and, after a premium-minting sync, still equals the
     *         committed NAV per POST-MINT share: the fee/premium share mints dilute the rate path exactly as
     *         committed.
     * @dev The LT overlay is enabled so the sync mints liquidity-premium ST shares (a real supply change
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
        uint256 expected = Math.mulDiv(WAD, toUint256(ACCOUNTANT.getState().lastSTEffectiveNAV), ST.totalSupply());
        assertEq(rate1, expected, "the refreshed rate must equal committed NAV per post-mint share");
    }

    /// @notice the Vault's own view of the pool token rates reads the kernel rate provider live: the
    ///         WITH_RATE registration is empirically wired to `getRate`, and the STANDARD quote leg reads 1.0.
    function test_GetRate_vaultTokenRateView_matchesQuoter() public {
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
     *      invariant, not the balances directly), so spot/composition manipulation cannot move the LT mark.
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
        assertGe(tvl, lo, "TVL must hold the band floor at a near-boundary composition");
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

    /// @notice the kernel's LT conversions round-trip on the LIVE oracle TVL with bounded floor loss:
    ///         `back <= x` and the gap is at most one NAV-wei's worth of BPT plus the final floor.
    function test_LTConversions_roundTripFloor_onLiveTVL() public {
        _seedForSwaps();
        _sync();
        uint256 x = toUint256(KERNEL.getState().ltOwnedYieldBearingAssets) / 3;
        uint256 nav = toUint256(KERNEL.ltConvertTrancheUnitsToNAVUnits(toTrancheUnits(x)));
        uint256 back = toUint256(KERNEL.ltConvertNAVUnitsToTrancheUnits(toNAVUnits(nav)));
        assertLe(back, x, "the round trip must never create BPT");
        uint256 maxGap = Math.mulDiv(_bptSupply(), 1, _poolTVL()) + 2; // one NAV-wei of BPT + the two floors
        assertLe(x - back, maxGap, "the round-trip floor loss must stay within one NAV-wei of BPT");
    }
}
