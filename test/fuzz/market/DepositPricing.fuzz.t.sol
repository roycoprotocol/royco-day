// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { MarketFuzzBase } from "./MarketFuzzBase.sol";

/**
 * @title DepositPricingFuzz
 * @notice Fuzzes deposit share pricing through the full production stack for all three tranches: the minted
 *         shares must equal floor(value x supply / effectiveNAV) where the deposit's value is derived by hand
 *         through the quoter composition (vault rate x oracle price for ST/JT, pool TVL over BPT supply for LT),
 *         and a depositor can never come out ahead by immediately redeeming what it just minted
 * @dev The no-gain half is asserted two ways: the depositor's immediate redemption preview never exceeds the
 *      deposited value, and the pre-existing holders' NAV-per-share never decreases, checked in cross-multiplied
 *      integer form (effNAVAfter x supplyBefore >= effNAVBefore x supplyAfter) so no division rounding can hide
 *      a leak. Both follow from shares = floor(supply x value / effNAV): the floor means the depositor's claim
 *      on the enlarged pot is at most the value it brought
 */
contract DepositPricingFuzz is MarketFuzzBase {
    using Math for uint256;

    /**
     * Scenario: a seeded market accrues fuzzed vault-rate yield and a fuzzed quote-price move, syncs, and then a
     * senior LP deposits. The deposit's NAV value must be exactly the hand-composed quoter output (vault shares
     * -> underlying at the accrued rate, underlying -> NAV at the moved oracle price, each floored), the mint
     * must be exactly floor(value x supply / stEffectiveNAV), and the depositor cannot exit with more than it
     * put in.
     *
     * Quoter composition (cell A, 18/18 decimals, 8-decimal feed):
     *   vault rate after accrue(vb):  1e18 + vb x 1e14                                  (exact)
     *   feed answer after +qb bps:    1e8 + qb x 1e4                                    (exact)
     *   composed tranche->NAV rate:   floor((1e18 + vb x 1e14) x (1e8 + qb x 1e4) x 1e10 / 1e18)
     *   deposit value:                floor(assets x composedRate / 1e18)
     */
    function testFuzz_SeniorDeposit_mintsFloorPricedSharesAndDepositorNeverGains(
        uint256 _stSeed,
        uint256 _jtSeed,
        uint256 _vaultBps,
        uint256 _quoteBps,
        uint256 _elapsed,
        uint256 _amountSeed
    )
        public
    {
        uint256 st = bound(_stSeed, 1e18, 1e26); // uniform over 8 orders of magnitude of senior seed size
        uint256 jt = bound(_jtSeed, st / 2, 2 * st); // uniform coverage ratios from 2:1 to 1:2
        uint256 vb = bound(_vaultBps, 0, 10_000); // vault-rate yield 0% to +100%, up-only so the market stays PERPETUAL
        uint256 qb = bound(_quoteBps, 0, 2000); // quote-price move 0% to +20%, up-only so no coverage loss path triggers
        uint256 elapsed = bound(_elapsed, 1, 365 days); // premium accrual window from 1 second to a year
        // Extra quote-only depth worth 15% of the senior seed keeps the liquidity gate clear after the
        // appreciation: post-sync stEff <= 2.4 x st while depth >= 0.2 x st x quote price covers 5% of any
        // capacity-bounded deposit, so the reported max below is always positive
        _seedFlatMarket(st, jt, st.mulDiv(3, 20) / QUOTE_TO_NAV_SCALE + 1);

        applySTPnL(int256(vb));
        applyQuotePnL(int256(qb));
        _warpAndRefreshFeed(elapsed);
        syncVenuePrices();
        SyncedAccountingState memory state = _sync();

        // The hand-composed quoter rate must price one whole vault share exactly (the composition pin)
        uint256 composedRate = (1e18 + vb * 1e14).mulDiv((1e8 + qb * 1e4) * 1e10, 1e18);
        assertEq(toUint256(kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), composedRate, "quoter must price 1 share at the composed rate");

        // Bound the deposit by the live capacity so the gates cannot interfere with the pricing property
        uint256 assets = bound(_amountSeed, 1e12, toUint256(seniorTranche.maxDeposit(ST_PROVIDER))); // dust-to-max deposit sizes
        uint256 value = assets.mulDiv(composedRate, 1e18);
        uint256 supplyBefore = seniorTranche.totalSupply();
        uint256 stEffBefore = toUint256(state.stEffectiveNAV);
        uint256 expectedShares = supplyBefore.mulDiv(value, stEffBefore);

        uint256 minted = _depositSenior(assets);
        assertEq(minted, expectedShares, "senior deposit must mint exactly floor(value x supply / stEffectiveNAV)");

        // No-gain, redeemer side: immediately unwinding the fresh shares can never return more NAV than deposited
        assertLe(toUint256(seniorTranche.previewRedeem(minted).nav), value, "immediately redeeming the minted shares must never exceed the deposited value");
        // No-gain, incumbent side: NAV-per-share of pre-existing holders never decreases (cross-multiplied)
        uint256 stEffAfter = toUint256(accountant.getState().lastSTEffectiveNAV);
        assertGe(stEffAfter * supplyBefore, stEffBefore * (supplyBefore + minted), "pre-existing senior holders must never be diluted below their prior NAV-per-share");
    }

    /**
     * Scenario: identical setup to the senior case, but the deposit lands in the junior tranche, whose supply
     * includes the protocol-fee shares the sync minted against the junior gain. The junior quoter shares the
     * senior's composed rate (identical assets), so value = floor(assets x composedRate / 1e18) and the mint is
     * floor(value x jtSupply / jtEffectiveNAV).
     */
    function testFuzz_JuniorDeposit_mintsFloorPricedSharesAndDepositorNeverGains(
        uint256 _stSeed,
        uint256 _jtSeed,
        uint256 _vaultBps,
        uint256 _quoteBps,
        uint256 _elapsed,
        uint256 _amountSeed
    )
        public
    {
        uint256 st = bound(_stSeed, 1e18, 1e26); // uniform over 8 orders of magnitude of senior seed size
        uint256 jt = bound(_jtSeed, st / 2, 2 * st); // uniform coverage ratios from 2:1 to 1:2
        uint256 vb = bound(_vaultBps, 0, 10_000); // vault-rate yield 0% to +100%, up-only so the market stays PERPETUAL
        uint256 qb = bound(_quoteBps, 0, 2000); // quote-price move 0% to +20%, up-only
        uint256 elapsed = bound(_elapsed, 1, 365 days); // premium accrual window from 1 second to a year
        uint256 assets = bound(_amountSeed, 1e12, st); // dust-sized up to seed-sized junior deposits (never gated)
        _seedFlatMarket(st, jt, 0);

        applySTPnL(int256(vb));
        applyQuotePnL(int256(qb));
        _warpAndRefreshFeed(elapsed);
        syncVenuePrices();
        SyncedAccountingState memory state = _sync();

        uint256 composedRate = (1e18 + vb * 1e14).mulDiv((1e8 + qb * 1e4) * 1e10, 1e18);
        assertEq(toUint256(kernel.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), composedRate, "junior quoter must share the composed rate");

        uint256 value = assets.mulDiv(composedRate, 1e18);
        uint256 supplyBefore = juniorTranche.totalSupply();
        uint256 jtEffBefore = toUint256(state.jtEffectiveNAV);
        uint256 expectedShares = supplyBefore.mulDiv(value, jtEffBefore);

        uint256 minted = _depositJunior(assets);
        assertEq(minted, expectedShares, "junior deposit must mint exactly floor(value x supply / jtEffectiveNAV)");

        assertLe(toUint256(juniorTranche.previewRedeem(minted).nav), value, "immediately redeeming the minted shares must never exceed the deposited value");
        uint256 jtEffAfter = toUint256(accountant.getState().lastJTEffectiveNAV);
        assertGe(jtEffAfter * supplyBefore, jtEffBefore * (supplyBefore + minted), "pre-existing junior holders must never be diluted below their prior NAV-per-share");
    }

    /**
     * Scenario: the pool's quote leg re-prices by a fuzzed move (the LT's own PnL), a fresh LP mints quote-backed
     * BPT and deposits it in kind. The BPT's NAV value must be exactly the oracle composition
     * floor(poolTVL x bptIn / bptTotalSupply) with poolTVL = floor(poolQuoteBalance x quotePrice / 1e6) for this
     * quote-only pool, and the mint must be floor(value x ltSupply / ltEffectiveNAV) at the pre-deposit LT
     * effective NAV (no premium is staged in a flat market, so the effective NAV is the pool depth alone).
     */
    function testFuzz_LiquidityDeposit_mintsFloorPricedSharesAndDepositorNeverGains(
        uint256 _stSeed,
        uint256 _jtSeed,
        uint256 _extraQuoteSeed,
        int256 _ltBps,
        uint256 _amountSeed
    )
        public
    {
        uint256 st = bound(_stSeed, 1e18, 1e26); // uniform over 8 orders of magnitude of senior seed size
        uint256 jt = bound(_jtSeed, st / 2, 2 * st); // uniform coverage ratios from 2:1 to 1:2
        uint256 extraQuote = bound(_extraQuoteSeed, 1, st / QUOTE_TO_NAV_SCALE); // uniform surplus depth up to the senior NAV
        int256 ltBps = bound(_ltBps, -3000, 3000); // quote-leg re-pricing from -30% to +30%, both PnL signs
        uint256 quoteLeg = bound(_amountSeed, 1, st / QUOTE_TO_NAV_SCALE); // deposit sizes from 1 quote wei up to the senior NAV
        _seedFlatMarket(st, jt, extraQuote);

        // Re-price the pool's quote leg: the effective quote price becomes exactly 1e18 + ltBps x 1e14
        applyLTPnL(ltBps);
        uint256 quotePriceWAD = uint256(int256(1e18) + ltBps * 1e14);

        // Mint the deposit BPT 1:1 against its quote backing (the same convention every seed used), then derive
        // the oracle composition over the post-mint pool: TVL = floor(quoteBalance x price / 1e6) because the
        // senior leg is empty, and the BPT supply includes the pool's genesis and dead-reserve backing
        uint256 bptIn = quoteLeg * QUOTE_TO_NAV_SCALE;
        _mintQuoteBackedBPT(LT_PROVIDER, bptIn, quoteLeg);
        uint256 poolQuoteBalance = balancerVault.getPoolBalances(address(bpt))[1 - stPoolTokenIndex];
        uint256 poolTVL = poolQuoteBalance.mulDiv(quotePriceWAD, 1e6);
        uint256 bptSupply = bpt.totalSupply();
        uint256 value = poolTVL.mulDiv(bptIn, bptSupply);

        // The LT prices its shares at its pre-deposit effective NAV: the kernel-owned BPT at the same oracle
        // mark, with no staged premium leg in a flat market
        uint256 ltOwnedBPT = toUint256(kernel.getState().ltOwnedYieldBearingAssets);
        uint256 ltEffBefore = poolTVL.mulDiv(ltOwnedBPT, bptSupply);
        uint256 supplyBefore = liquidityTranche.totalSupply();
        uint256 expectedShares = supplyBefore.mulDiv(value, ltEffBefore);

        vm.startPrank(LT_PROVIDER);
        bpt.approve(address(liquidityTranche), bptIn);
        uint256 minted = liquidityTranche.deposit(toTrancheUnits(bptIn), LT_PROVIDER);
        vm.stopPrank();
        assertEq(minted, expectedShares, "liquidity deposit must mint exactly floor(value x supply / ltEffectiveNAV)");

        assertLe(toUint256(liquidityTranche.previewRedeem(minted).nav), value, "immediately redeeming the minted shares must never exceed the deposited value");
        // Incumbent side at the same oracle mark: the pot grew by at least the value the mint was priced on
        uint256 ltEffAfter = poolTVL.mulDiv(ltOwnedBPT + bptIn, bptSupply);
        assertGe(ltEffAfter * supplyBefore, ltEffBefore * (supplyBefore + minted), "pre-existing liquidity holders must never be diluted below their prior NAV-per-share");
    }
}
