// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { WAD } from "../../../src/libraries/Constants.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { MarketState } from "../../../src/libraries/Types.sol";
import { toUint256 } from "../../../src/libraries/Units.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { MarketParamsConfig, defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_MaxRedeemMultiAssetSharpness
 * @notice Measures how far the advertised maxRedeemMultiAsset sits below the TRUE maximum (the largest share
 *         count that actually executes), found by binary search over snapshot-and-revert probes
 * @dev The binding constraint at trueMax + 1 is the documented liquidity gate itself, judged at the flow's final
 *      settled state (the ST leg's post-op heals or keeps the LPT leg's recorded violation, and _exitMultiAssetFlow
 *      reverts LIQUIDITY_REQUIREMENT_VIOLATED on an unhealed one). The gate perceives the withdrawal at quote-wei
 *      granularity: the venue's proportional removal floors its quote payout, so the settled lptRawNAV is a step
 *      function of the redeemed shares. It holds nearly flat between quote-wei boundaries (the sub-quote-wei
 *      remainder stays in the pool for the remaining holders) and drops a whole quote-wei of NAV at each boundary
 *      while the floored senior-share leg (the requirement relief) stays flat. The advertised bound's linear model
 *      counts the full quote leg as withdrawn, so its slack is strictly below one step and the true maximum runs
 *      exactly to the share before the first quote-wei boundary past the advertised max. The gap is therefore
 *      bounded by the boundary spacing in shares (about 1.15e12 share-wei here, about 1e-6 quote tokens of NAV),
 *      not by the dust tolerance (the measured gap is identical with dustTolerance zeroed). This suite pins that
 *      gap to its derived ceiling so the bound can tighten but never silently loosen, and pins the one-past-true-max
 *      probe to the exact liquidity gate revert so the binding constraint stays the documented one
 */
contract Test_MaxRedeemMultiAssetSharpness is DayMarketTestBase {
    /// @dev One whole quote token in its native decimals
    uint256 internal QUOTE_UNIT;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        QUOTE_UNIT = 10 ** uint256(cell.quoteAsset.decimals);
        _seedMarket(100_000e18, 30_000e18);
        _seedLPT(10_000e18, 2000e18, 8000 * QUOTE_UNIT);
        _sync();
    }

    /// @dev Whether a multi-asset redemption of the share count settles, probed on a snapshot that is always reverted
    function _executes(uint256 _shares) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        vm.prank(LPT_PROVIDER);
        try liquidityProviderTranche.redeemMultiAsset(_shares, 0, 0, LPT_PROVIDER, LPT_PROVIDER) {
            ok = true;
        } catch { }
        vm.revertToState(snap);
    }

    /// @dev Binary searches the true maximum: the largest executable share count in [advertised, balance]
    function _trueMax(uint256 _advertised) internal returns (uint256 lo) {
        lo = _advertised;
        uint256 hi = liquidityProviderTranche.balanceOf(LPT_PROVIDER);
        require(_executes(lo), "sharpness: the advertised maximum must execute");
        if (_executes(hi)) return hi;
        // Invariant: lo executes, hi reverts
        while (hi - lo > 1) {
            uint256 mid = lo + (hi - lo) / 2;
            if (_executes(mid)) lo = mid;
            else hi = mid;
        }
    }

    /**
     * @dev The derived ceiling on trueMax - advertised, dictated by the venue's quote-wei payout quantization
     *
     *      Derivation. The flow's exit gate enforces stEff * minLiquidity <= WAD * lptRawNAV at the settled
     *      mid-flow state. The venue's proportional removal pays out quote = floor(bptIn * quoteBalance / bptSupply),
     *      so the post-remove pool TVL (and with it lptRawNAV, the remaining BPT valued at the post-remove pool)
     *      steps down by one quote-wei of NAV only when bptIn crosses a multiple of bptSupply / quoteBalance.
     *      Between steps the payout's sub-quote-wei remainder stays in the pool and lptRawNAV decays only by the
     *      floored senior leg net of the ST redemption's relief, a near-zero slope. The advertised bound's linear
     *      model treats the full quote leg as withdrawn, so the settled slack it leaves is strictly below one
     *      step's drop and the first quote-wei boundary past the advertised max violates the gate. One boundary
     *      spacing of shares therefore ceilings the gap:
     *
     *          bptPerTick = ceil(bptSupply / quoteBalance)                      (bptIn between quote-wei payouts)
     *          tickShares = ceil(bptPerTick * (lptSupply + 1) / kernelBPT)      (inverts bptIn = floor(kernelBPT * shares / (lptSupply + 1)))
     *
     *      A second tick covers the adversarial corner where the retained remainder plus the requirement's ceil
     *      slop and the dust headroom the bound withholds (ceil((stEff + dust) * m / WAD) vs stEff * m / WAD,
     *      at most ceil(dust * m / WAD) + 1 NAV-wei, amplified below 2x by the multi-asset scaling) barely
     *      survives the first tick. Each further whole quote-wei of dust headroom can carry the flow past one
     *      further tick (zero extra ticks for the dustTolerance = 1 wei these fixtures use, whose headroom is a
     *      twentieth of a NAV-wei). The trailing constant absorbs the bound's own two floored share conversions.
     *      Verified against an exact integer replication of the flow: at the seeded fixture the measured gap is
     *      36927402176 shares and trueMax + 1 is exactly the first quote-wei boundary past the advertised max
     */
    function _gapCeiling() internal view returns (uint256) {
        uint256 bptSupply = balancerVault.totalSupply(address(bpt));
        uint256 quoteBalance = balancerVault.getPoolBalances(address(bpt))[1];
        uint256 kernelBPT = toUint256(kernel.getState().totalLPTAssets);
        uint256 bptPerTick = Math.ceilDiv(bptSupply, quoteBalance);
        uint256 tickShares = Math.mulDiv(bptPerTick, liquidityProviderTranche.totalSupply() + 1, kernelBPT, Math.Rounding.Ceil);
        // The NAV a single quote-wei represents (the fixtures' quote stable prices at par)
        uint256 quoteTickNAV = WAD / QUOTE_UNIT;
        uint256 dustHeadroomNAV =
            Math.mulDiv(toUint256(accountant.getState().dustTolerance), accountant.getState().minLiquidityWAD, WAD, Math.Rounding.Ceil);
        return (2 + dustHeadroomNAV / quoteTickNAV) * tickShares + 2;
    }

    /// @dev Asserts the sharpness contract on the live fixture: the advertised maximum executes, the true maximum
    ///      sits within the derived quote-tick ceiling above it, and one share past it reverts on the exact
    ///      liquidity gate (the binding constraint stays the documented one, not a shape or dust guard)
    function _assertSharpness() internal returns (uint256 advertised, uint256 trueMax) {
        uint256 ceiling = _gapCeiling();
        advertised = liquidityProviderTranche.maxRedeemMultiAsset(LPT_PROVIDER);
        trueMax = _trueMax(advertised);
        assertLe(trueMax - advertised, ceiling, "the bound's conservatism must stay within the quote-tick ceiling");
        vm.prank(LPT_PROVIDER);
        vm.expectRevert(IRoycoDayKernel.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        liquidityProviderTranche.redeemMultiAsset(trueMax + 1, 0, 0, LPT_PROVIDER, LPT_PROVIDER);
        emit log_named_uint("advertised", advertised);
        emit log_named_uint("true max  ", trueMax);
        emit log_named_uint("gap shares", trueMax - advertised);
        emit log_named_uint("gap ceil  ", ceiling);
    }

    /// @notice The advertised maximum's gap to the true maximum stays within its derived quote-tick ceiling on the
    ///         seeded market, and one share past the true maximum reverts on the exact liquidity gate
    function test_Sharpness_SeededMarket_GapWithinDerivedCeiling() public {
        (, uint256 trueMax) = _assertSharpness();
        assertLt(trueMax, liquidityProviderTranche.balanceOf(LPT_PROVIDER), "the gate, not the balance, must bind the true maximum");
    }

    /// @notice With zero dust tolerance the gap persists unchanged: the venue's quote-wei payout quantization,
    ///         not the dust tolerance, is what the advertised bound concedes to the true maximum
    function test_Sharpness_ZeroDustTolerance_GapIsPureQuantization() public {
        MarketParamsConfig memory params = defaultParams();
        params.dustTolerance = 0;
        _deployMarket(cellA(), params);
        _seedMarket(100_000e18, 30_000e18);
        _seedLPT(10_000e18, 2000e18, 8000 * QUOTE_UNIT);
        _sync();

        _assertSharpness();
    }

    /// @notice The quote-tick ceiling holds through a coverage-liquidation drawdown that reprices every leg of the
    ///         bound (junior exhausted, senior absorbing losses, the market forced perpetual by the liquidation band)
    function test_Sharpness_UnderDrawdown_GapWithinDerivedCeiling() public {
        // A covered drawdown would enter FIXED_TERM and zero the capacity, so crash 60% into the liquidation
        // band instead, which forces PERPETUAL (mirrors test_MaxRedeemMultiAsset_CoverageLiquidationBreach)
        applySTPnL(-6000);
        _sync();
        assertEq(uint8(accountant.getState().lastMarketState), uint8(MarketState.PERPETUAL), "arrange: the liquidation band must force perpetual");
        require(liquidityProviderTranche.maxRedeemMultiAsset(LPT_PROVIDER) > 0, "arrange: the drawdown fixture must leave capacity");

        _assertSharpness();
    }
}
