// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";
import { MarketFuzzTestBase } from "../../utils/MarketFuzzTestBase.sol";

/**
 * @title TestFuzz_DepositPricing_Kernel
 * @notice Fuzzes deposit share pricing through the full production stack for all three tranches: the minted
 *         shares must equal the offset-aware floor((supply + VIRTUAL_SHARES) x value / (effectiveNAV + VIRTUAL_VALUE))
 *         (VIRTUAL_SHARES = 1e6, VIRTUAL_VALUE = 1) where the deposit's value is derived by hand through the quoter
 *         composition (vault rate x oracle price for ST/JT, pool TVL over BPT supply for LT), and a depositor can
 *         never come out ahead by immediately redeeming what it just minted
 * @dev The no-gain half is asserted two ways: the depositor's immediate redemption preview never exceeds the
 *      deposited value, and the pre-existing holders' NAV-per-share never decreases. Because the redemption side also
 *      prices against the effective supply, the incumbent invariant is checked in cross-multiplied, offset-aware form
 *      (effNAVAfter x (supplyBefore + 1e6) >= effNAVBefore x (supplyAfter + 1e6)) so no division rounding can hide a
 *      leak. Both follow from shares = floor((supply + 1e6) x value / (effNAV + 1)): the floor means the depositor's
 *      claim on the enlarged pot is at most the value it brought
 */
contract TestFuzz_DepositPricing_Kernel is MarketFuzzTestBase {
    using Math for uint256;

    /**
     * Scenario: a seeded market accrues fuzzed vault-rate yield and a fuzzed quote-price move, syncs, and then a
     * senior LP deposits. The deposit's NAV value must be exactly the hand-composed quoter output (vault shares
     * -> underlying at the accrued rate, underlying -> NAV at the moved oracle price, each floored), the mint
     * must be exactly floor(value x supply / stEffectiveNAV), and the depositor cannot exit with more than it
     * put in.
     *
     * Quoter composition (18-decimal vault shares over an 18-decimal underlying, 8-decimal feed):
     *   vault rate after accrue(vb):  1e18 + vb x 1e14                                  (exact)
     *   feed answer after +qb bps:    1e8 + qb x 1e4                                    (exact)
     *   composed tranche->NAV rate:   floor((1e18 + vb x 1e14) x (1e8 + qb x 1e4) x 1e10 / 1e18)
     *   deposit value:                floor(assets x composedRate / 1e18)
     */
    function testFuzz_SeniorDeposit_MintsFloorPricedSharesAndDepositorNeverGains(
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
        // appreciation: post-sync stEffectiveNAV <= 2.4 x st while depth >= 0.2 x st x quote price covers 5% of any
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
        // The clamp-aware mirror: in these live bounded states the clamp never binds, so the fair branch resolves to
        // the offset-aware floor floor((supply + VIRTUAL_SHARES) x value / (effNAV + VIRTUAL_VALUE)); the mirror proves
        // the clamp is inert rather than the test assuming it (a bind would diverge from this inline formula)
        uint256 expectedShares = RoycoTestMath.convertToShares(value, stEffBefore, supplyBefore);
        assertEq(expectedShares, (supplyBefore + 1e6).mulDiv(value, stEffBefore + 1), "clamp must be inert at live-market deposit sizes");

        // Execute inline (not via the helper) so the Deposit event lands directly after expectEmit
        stJtVault.mintShares(ST_PROVIDER, assets);
        vm.startPrank(ST_PROVIDER);
        stJtVault.approve(address(seniorTranche), assets);
        vm.expectEmit(true, true, true, true, address(seniorTranche));
        emit IRoycoVaultTranche.Deposit(ST_PROVIDER, ST_PROVIDER, toTrancheUnits(assets), expectedShares);
        uint256 minted = seniorTranche.deposit(toTrancheUnits(assets), ST_PROVIDER);
        vm.stopPrank();
        assertEq(minted, expectedShares, "senior deposit must mint exactly floor((supply + 1e6) x value / (stEffectiveNAV + 1))");

        // No-gain, redeemer side: immediately unwinding the fresh shares can never return more NAV than deposited
        assertLe(toUint256(seniorTranche.previewRedeem(minted).nav), value, "immediately redeeming the minted shares must never exceed the deposited value");
        // No-gain, incumbent side: NAV-per-share of pre-existing holders never decreases. The redemption side prices a
        // share against the EFFECTIVE supply (supply + VIRTUAL_SHARES), so the offset-aware invariant is
        // effNAVAfter x (supplyBefore + 1e6) >= effNAVBefore x (supplyAfter + 1e6) (cross-multiplied, no division rounding)
        uint256 stEffAfter = toUint256(accountant.getState().lastSTEffectiveNAV);
        assertGe(
            stEffAfter * (supplyBefore + 1e6),
            stEffBefore * (supplyBefore + minted + 1e6),
            "pre-existing senior holders must never be diluted below their prior NAV-per-share"
        );
    }

    /**
     * Scenario: identical setup to the senior case, but the deposit lands in the junior tranche, whose supply
     * includes the protocol-fee shares the sync minted against the junior gain. The junior quoter shares the
     * senior's composed rate (identical assets), so value = floor(assets x composedRate / 1e18) and the mint is
     * floor(value x jtSupply / jtEffectiveNAV).
     */
    function testFuzz_JuniorDeposit_MintsFloorPricedSharesAndDepositorNeverGains(
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
        // The clamp-aware mirror proves the clamp is inert at live-market deposit sizes; the fair branch is the
        // offset-aware floor floor((supply + VIRTUAL_SHARES) x value / (effNAV + VIRTUAL_VALUE)) (see the senior variant)
        uint256 expectedShares = RoycoTestMath.convertToShares(value, jtEffBefore, supplyBefore);
        assertEq(expectedShares, (supplyBefore + 1e6).mulDiv(value, jtEffBefore + 1), "clamp must be inert at live-market deposit sizes");

        // Execute inline (not via the helper) so the Deposit event lands directly after expectEmit
        stJtVault.mintShares(JT_PROVIDER, assets);
        vm.startPrank(JT_PROVIDER);
        stJtVault.approve(address(juniorTranche), assets);
        vm.expectEmit(true, true, true, true, address(juniorTranche));
        emit IRoycoVaultTranche.Deposit(JT_PROVIDER, JT_PROVIDER, toTrancheUnits(assets), expectedShares);
        uint256 minted = juniorTranche.deposit(toTrancheUnits(assets), JT_PROVIDER);
        vm.stopPrank();
        assertEq(minted, expectedShares, "junior deposit must mint exactly floor((supply + 1e6) x value / (jtEffectiveNAV + 1))");

        assertLe(toUint256(juniorTranche.previewRedeem(minted).nav), value, "immediately redeeming the minted shares must never exceed the deposited value");
        // Incumbent side, offset-aware (redemption prices against supply + VIRTUAL_SHARES; see the senior variant)
        uint256 jtEffAfter = toUint256(accountant.getState().lastJTEffectiveNAV);
        assertGe(
            jtEffAfter * (supplyBefore + 1e6),
            jtEffBefore * (supplyBefore + minted + 1e6),
            "pre-existing junior holders must never be diluted below their prior NAV-per-share"
        );
    }

    /**
     * Scenario: the pool's quote leg re-prices by a fuzzed move (the LT's own PnL), a fresh LP mints quote-backed
     * BPT and deposits it in kind. The BPT's NAV value must be exactly the oracle composition
     * floor(poolTVL x bptIn / bptTotalSupply) with poolTVL = floor(poolQuoteBalance x quotePrice / 1e6) for this
     * quote-only pool, and the mint must be floor(value x ltSupply / ltEffectiveNAV) at the pre-deposit LT
     * effective NAV (a flat market holds no idle liquidity premium senior shares, so the effective NAV is the pool depth alone).
     */
    function testFuzz_LiquidityDeposit_MintsFloorPricedSharesAndDepositorNeverGains(
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
        // mark, with no idle liquidity premium senior shares in a flat market
        uint256 ltOwnedBPT = toUint256(kernel.getState().ltOwnedYieldBearingAssets);
        uint256 ltEffBefore = poolTVL.mulDiv(ltOwnedBPT, bptSupply);
        uint256 supplyBefore = liquidityTranche.totalSupply();
        // The clamp-aware mirror proves the clamp is inert at live-market deposit sizes; the fair branch is the
        // offset-aware floor floor((supply + VIRTUAL_SHARES) x value / (effNAV + VIRTUAL_VALUE)) (see the senior variant)
        uint256 expectedShares = RoycoTestMath.convertToShares(value, ltEffBefore, supplyBefore);
        assertEq(expectedShares, (supplyBefore + 1e6).mulDiv(value, ltEffBefore + 1), "clamp must be inert at live-market deposit sizes");

        vm.startPrank(LT_PROVIDER);
        bpt.approve(address(liquidityTranche), bptIn);
        vm.expectEmit(true, true, true, true, address(liquidityTranche));
        emit IRoycoVaultTranche.Deposit(LT_PROVIDER, LT_PROVIDER, toTrancheUnits(bptIn), expectedShares);
        uint256 minted = liquidityTranche.deposit(toTrancheUnits(bptIn), LT_PROVIDER);
        vm.stopPrank();
        assertEq(minted, expectedShares, "liquidity deposit must mint exactly floor((supply + 1e6) x value / (ltEffectiveNAV + 1))");

        // No-gain, redeemer side: previewRedeem simulates the real redemption and bubbles every execution gate,
        // so a down-repriced quote leg can leave the fresh position beyond the liquidity-respecting max. The
        // unwind is asserted whenever it is executable, and an unexecutable unwind returns the depositor nothing
        if (minted <= liquidityTranche.maxRedeem(LT_PROVIDER)) {
            assertLe(toUint256(liquidityTranche.previewRedeem(minted).nav), value, "immediately redeeming the minted shares must never exceed the deposited value");
        }
        // Incumbent side at the same oracle mark, offset-aware (redemption prices against supply + VIRTUAL_SHARES):
        // the pot grew by at least the value the mint was priced on
        uint256 ltEffAfter = poolTVL.mulDiv(ltOwnedBPT + bptIn, bptSupply);
        assertGe(
            ltEffAfter * (supplyBefore + 1e6),
            ltEffBefore * (supplyBefore + minted + 1e6),
            "pre-existing liquidity holders must never be diluted below their prior NAV-per-share"
        );
    }

    /**
     * Scenario: vault yield has accrued but no keeper has committed a sync yet, so the last committed
     * checkpoint under-marks the senior tranche. An attacker deposits directly, hoping to be priced at the
     * stale checkpoint NAV and capture the unsynced gain from incumbent holders when the next sync lands.
     * The deposit's own pre-op tranche accounting sync must re-mark the tranche first, so depositing before
     * the keeper's sync is byte-identical to depositing after it and the sandwich captures nothing.
     */
    function testFuzz_SeniorDeposit_SandwichingTheSyncCapturesNoUnsyncedYield(
        uint256 _stSeed,
        uint256 _jtSeed,
        uint256 _vaultBps,
        uint256 _elapsed,
        uint256 _amountSeed
    )
        public
    {
        uint256 st = bound(_stSeed, 1e18, 1e26); // uniform over 8 orders of magnitude of senior seed size
        // Coverage ratios from 1:1 to 1:2 keep the coverage gate clear for a deposit of up to st after a
        // +100% shared move: st <= jtRaw, so exposure = stRaw + d + jtRaw <= 3 x st + jtRaw <= 4 x jtRaw and the
        // required coverage 0.2 x exposure <= 0.8 x jtRaw <= jtEffectiveNAV keeps utilization at or below 100%
        uint256 jt = bound(_jtSeed, st, 2 * st);
        uint256 vb = bound(_vaultBps, 1, 10_000); // strictly positive unsynced yield: the value the attacker is after
        uint256 elapsed = bound(_elapsed, 1, 365 days); // staleness window from 1 second to a year
        // Extra quote-only depth worth 20% of the senior seed keeps the liquidity gate clear after up to
        // +100% appreciation plus a deposit of up to st: (2st + st) x 5% = 0.15 x st < 0.2 x st of depth
        _seedFlatMarket(st, jt, st / 5 / QUOTE_TO_NAV_SCALE + 1);

        applySTPnL(int256(vb));
        _warpAndRefreshFeed(elapsed);
        syncVenuePrices();
        // The gain is live in the vault mark but NOT in the committed checkpoint: no _sync() runs here

        uint256 assets = bound(_amountSeed, 1e12, st); // dust-to-seed-sized deposits, within capacity by the seeding above

        // Path A: the keeper syncs first, then an honest LP deposits at the freshly committed NAV
        uint256 snapshotId = vm.snapshotState();
        _sync();
        uint256 mintedAfterSync = _depositSenior(assets);
        uint256 exitAfterSync = toUint256(seniorTranche.previewRedeem(mintedAfterSync).nav);
        uint256 stEffAfterSyncPath = toUint256(accountant.getState().lastSTEffectiveNAV);

        // Path B: the attacker front-runs the keeper and deposits against the stale checkpoint
        vm.revertToState(snapshotId);
        uint256 mintedSandwich = _depositSenior(assets);

        assertEq(mintedSandwich, mintedAfterSync, "front-running the keeper's sync must mint exactly the honest post-sync share count");
        assertEq(
            toUint256(seniorTranche.previewRedeem(mintedSandwich).nav), exitAfterSync, "the sandwich exit value must equal the honest-path exit value"
        );
        assertEq(
            toUint256(accountant.getState().lastSTEffectiveNAV),
            stEffAfterSyncPath,
            "both paths must commit the identical senior effective NAV, so no unsynced gain moved between holders"
        );
    }
}
