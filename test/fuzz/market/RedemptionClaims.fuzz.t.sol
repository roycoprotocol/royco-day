// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { AssetClaims, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoTestMath } from "../../base/math/RoycoTestMath.sol";
import { MarketFuzzBase } from "./MarketFuzzBase.sol";

/**
 * @title RedemptionClaimsFuzz
 * @notice Fuzzes redemption payouts through the full production stack for all three tranches: a redeemer's
 *         claims must equal the floor-scaled pro-rata slice of its tranche's total claims (each leg derived by
 *         hand from the committed marks and the quoter rate), the tokens received must equal the claims to the
 *         wei, and no redemption can extract value beyond its pro-rata share of the tranche
 * @dev Every scenario first accrues fuzzed up-only yield and syncs, so the redemptions run against a state with
 *      a live cross-claim (the junior risk premium makes jtEffectiveNAV exceed jtRawNAV) and freshly minted
 *      premium and protocol-fee shares in the supplies. The no-extraction half is asserted in cross-multiplied
 *      integer form so no division rounding can hide a leak
 */
contract RedemptionClaimsFuzz is MarketFuzzBase {
    using Math for uint256;

    /**
     * Scenario: after fuzzed vault yield and a sync, a senior LP redeems a fuzzed slice. On the gain path the
     * senior tranche cedes the risk premium to the junior tranche, so its effective NAV is backed entirely by
     * its own raw NAV: total senior claims are stAssets = floor((stRaw - (jtEff - jtRaw)) x 1e18 / rate) vault
     * shares (the junior cross-claim carved out) and no junior-asset leg. The redeemer receives the floor-scaled
     * slice of each leg and its wallet delta must match the claims exactly.
     */
    function testFuzz_SeniorRedemption_paysExactProRataClaims(uint256 _stSeed, uint256 _jtSeed, uint256 _vaultBps, uint256 _elapsed, uint256 _sharesSeed) public {
        uint256 st = bound(_stSeed, 1e18, 1e26); // uniform over 8 orders of magnitude of senior seed size
        uint256 jt = bound(_jtSeed, st / 2, 2 * st); // uniform coverage ratios from 2:1 to 1:2
        uint256 vb = bound(_vaultBps, 1, 10_000); // strictly positive yield so the risk-premium cross-claim is live
        uint256 elapsed = bound(_elapsed, 1 hours, 365 days); // premium accrual window from an hour to a year
        _seedFlatMarket(st, jt, 0);

        applySTPnL(int256(vb));
        _warpAndRefreshFeed(elapsed);
        syncVenuePrices();
        SyncedAccountingState memory state = _sync();

        // With the quote at 1.0 the composed quoter rate is just the accrued vault rate, exact
        uint256 rate = 1e18 + vb * 1e14;
        assertEq(toUint256(state.stRawNAV), st.mulDiv(rate, 1e18), "the senior raw mark must be the seed at the accrued rate");

        // Decompose the committed marks: the junior cross-claim on senior raw NAV is the ceded risk premium
        uint256 jtClaimOnSTRaw = toUint256(state.jtEffectiveNAV) - toUint256(state.jtRawNAV);
        uint256 stEff = toUint256(state.stEffectiveNAV);
        assertEq(stEff, toUint256(state.stRawNAV) - jtClaimOnSTRaw, "on the gain path the senior effective NAV is its raw NAV minus the ceded premium");
        uint256 totalSTAssets = (toUint256(state.stRawNAV) - jtClaimOnSTRaw).mulDiv(1e18, rate);

        // The redeemer's slice: every claim leg floors independently over the post-sync supply
        uint256 supply = seniorTranche.totalSupply();
        // 1e6 share wei up to the full seeded balance: a smaller redemption can floor to a zero-asset payout,
        // which the accountant rejects by design (INVALID_POST_OP_STATE), so the dust floor keeps every run valid
        uint256 shares = bound(_sharesSeed, 1e6, st);
        uint256 balBefore = stJtVault.balanceOf(ST_PROVIDER);
        vm.prank(ST_PROVIDER);
        AssetClaims memory claims = seniorTranche.redeem(shares, ST_PROVIDER, ST_PROVIDER);

        assertEq(toUint256(claims.nav), stEff.mulDiv(shares, supply), "redeemed NAV must be the floor-scaled slice of the senior effective NAV");
        assertEq(toUint256(claims.stAssets), totalSTAssets.mulDiv(shares, supply), "the senior-asset leg must be the floor-scaled slice of the own-raw claim");
        assertEq(toUint256(claims.jtAssets), 0, "no junior-asset leg exists on the gain path");
        assertEq(stJtVault.balanceOf(ST_PROVIDER) - balBefore, toUint256(claims.stAssets), "the wallet delta must equal the claimed vault shares exactly");

        // No extraction beyond pro-rata: the payout NAV never exceeds the exact fractional slice, so the
        // remaining holders keep at least their prior NAV-per-share (cross-multiplied, no division rounding)
        assertLe(toUint256(claims.nav) * supply, stEff * shares, "the floor-scaled payout can never exceed the exact pro-rata slice");
        assertGe((stEff - toUint256(claims.nav)) * supply, stEff * (supply - shares), "remaining senior holders must keep at least their prior NAV-per-share");
    }

    /**
     * Scenario: after fuzzed vault yield and a sync, a junior LP redeems a fuzzed slice bounded by the coverage
     * gate. The junior tranche's claims span both raw pools: its own full raw NAV plus the risk-premium
     * cross-claim on senior raw NAV, each converted to vault shares at the accrued rate and floor-scaled.
     */
    function testFuzz_JuniorRedemption_paysExactProRataClaims(uint256 _stSeed, uint256 _jtSeed, uint256 _vaultBps, uint256 _elapsed, uint256 _sharesSeed) public {
        uint256 st = bound(_stSeed, 1e18, 1e26); // uniform over 8 orders of magnitude of senior seed size
        uint256 jt = bound(_jtSeed, st / 2, 2 * st); // uniform coverage ratios from 2:1 to 1:2, ample surplus for redemption
        uint256 vb = bound(_vaultBps, 1, 10_000); // strictly positive yield so the cross-claim leg is live
        uint256 elapsed = bound(_elapsed, 1 hours, 365 days); // premium accrual window from an hour to a year
        _seedFlatMarket(st, jt, 0);

        applySTPnL(int256(vb));
        _warpAndRefreshFeed(elapsed);
        syncVenuePrices();
        SyncedAccountingState memory state = _sync();

        uint256 rate = 1e18 + vb * 1e14;
        uint256 jtClaimOnSTRaw = toUint256(state.jtEffectiveNAV) - toUint256(state.jtRawNAV);
        uint256 jtEff = toUint256(state.jtEffectiveNAV);
        // The junior tranche's total claims: the ceded premium sits on senior raw NAV, its full own raw backs the rest
        uint256 totalSTAssets = jtClaimOnSTRaw.mulDiv(1e18, rate);
        uint256 totalJTAssets = toUint256(state.jtRawNAV).mulDiv(1e18, rate);

        uint256 supply = juniorTranche.totalSupply();
        uint256 shares = bound(_sharesSeed, 1e6, juniorTranche.maxRedeem(JT_PROVIDER)); // coverage-respecting slices above the zero-payout dust floor
        uint256 balBefore = stJtVault.balanceOf(JT_PROVIDER);
        vm.prank(JT_PROVIDER);
        AssetClaims memory claims = juniorTranche.redeem(shares, JT_PROVIDER, JT_PROVIDER);

        assertEq(toUint256(claims.nav), jtEff.mulDiv(shares, supply), "redeemed NAV must be the floor-scaled slice of the junior effective NAV");
        assertEq(toUint256(claims.stAssets), totalSTAssets.mulDiv(shares, supply), "the senior-asset leg must be the floor-scaled premium cross-claim slice");
        assertEq(toUint256(claims.jtAssets), totalJTAssets.mulDiv(shares, supply), "the junior-asset leg must be the floor-scaled own-raw claim slice");
        assertEq(
            stJtVault.balanceOf(JT_PROVIDER) - balBefore,
            toUint256(claims.stAssets) + toUint256(claims.jtAssets),
            "the wallet delta must equal both claimed legs exactly"
        );

        assertLe(toUint256(claims.nav) * supply, jtEff * shares, "the floor-scaled payout can never exceed the exact pro-rata slice");
        assertGe((jtEff - toUint256(claims.nav)) * supply, jtEff * (supply - shares), "remaining junior holders must keep at least their prior NAV-per-share");
    }

    /**
     * Scenario: the venue is armed to reject the premium reinvestment (persistent 50% slippage), so the sync
     * stages the liquidity premium as idle senior shares held by the kernel instead of deploying it into the
     * pool. A liquidity LP then redeems a fuzzed slice and must receive BOTH legs of the LT's effective NAV: the
     * floor-scaled BPT slice and the floor-scaled slice of the staged premium senior shares, sent directly.
     *
     * Staged-premium derivation: the premium and senior-fee share mints price against the retained senior NAV
     * (stEff - premium - fee) at the pre-sync supply, so
     *   idleShares = floor(st x premium / (stEff - premium - fee))
     * and the LT effective NAV adds the idle shares valued at the post-mint senior share price:
     *   ltEff = depth + floor(idleShares x stEff / stSupplyAfterMints)
     */
    function testFuzz_LiquidityRedemption_paysBPTSliceAndStagedPremiumSliceExactly(
        uint256 _stSeed,
        uint256 _jtSeed,
        uint256 _vaultBps,
        uint256 _elapsed,
        uint256 _sharesSeed
    )
        public
    {
        uint256 st = bound(_stSeed, 1e18, 1e26); // uniform over 8 orders of magnitude of senior seed size
        uint256 jt = bound(_jtSeed, st / 2, 2 * st); // uniform coverage ratios from 2:1 to 1:2
        uint256 vb = bound(_vaultBps, 1, 10_000); // strictly positive yield so a liquidity premium accrues and stages
        uint256 elapsed = bound(_elapsed, 1 hours, 365 days); // premium accrual window from an hour to a year
        // Extra depth worth 15% of the senior seed keeps the post-redemption liquidity gate satisfiable after
        // up to +100% senior appreciation (required floor <= 0.1 x st < seeded depth)
        uint256 depth = _seedFlatMarket(st, jt, st.mulDiv(3, 20) / QUOTE_TO_NAV_SCALE + 1);

        setVenueSlippageMode(true);
        applySTPnL(int256(vb));
        _warpAndRefreshFeed(elapsed);
        syncVenuePrices();
        SyncedAccountingState memory state = _sync();

        // The staged buffer must hold exactly the carve-out premium shares, and the raw LT mark must exclude them
        (uint256 idleShares,, uint256 stSupplyAfterMints) =
            RoycoTestMath.carveOut(toUint256(state.stEffectiveNAV), toUint256(state.ltLiquidityPremium), toUint256(state.stProtocolFee), st);
        IRoycoDayKernel.RoycoDayKernelState memory ks = kernel.getState();
        assertEq(ks.ltOwnedSeniorTrancheShares, idleShares, "the staged premium buffer must hold exactly the derived carve-out shares");
        assertEq(seniorTranche.totalSupply(), stSupplyAfterMints, "the senior supply must include the premium and fee mints exactly");
        assertEq(toUint256(state.ltRawNAV), depth, "the committed LT raw mark must exclude the staged premium");

        // The LT's two-leg effective NAV: pool depth plus the idle shares at the post-mint senior share price
        uint256 idleValue = idleShares.mulDiv(toUint256(state.stEffectiveNAV), stSupplyAfterMints);
        uint256 ltEff = depth + idleValue;

        uint256 supply = liquidityTranche.totalSupply();
        uint256 shares = bound(_sharesSeed, 1e6, liquidityTranche.maxRedeem(LT_PROVIDER)); // liquidity-respecting slices above the zero-payout dust floor
        uint256 bptBefore = bpt.balanceOf(LT_PROVIDER);
        uint256 stSharesBefore = seniorTranche.balanceOf(LT_PROVIDER);
        vm.prank(LT_PROVIDER);
        AssetClaims memory claims = liquidityTranche.redeem(shares, LT_PROVIDER, LT_PROVIDER);

        assertEq(toUint256(claims.nav), ltEff.mulDiv(shares, supply), "redeemed NAV must be the floor-scaled slice of the two-leg LT effective NAV");
        assertEq(toUint256(claims.ltAssets), depth.mulDiv(shares, supply), "the BPT leg must be the floor-scaled slice of the pool depth");
        assertEq(claims.stShares, idleShares.mulDiv(shares, supply), "the staged-premium leg must be the floor-scaled slice of the idle senior shares");
        assertEq(bpt.balanceOf(LT_PROVIDER) - bptBefore, toUint256(claims.ltAssets), "the BPT wallet delta must equal the claim exactly");
        assertEq(seniorTranche.balanceOf(LT_PROVIDER) - stSharesBefore, claims.stShares, "the staged premium shares must be sent directly to the redeemer");

        assertLe(toUint256(claims.nav) * supply, ltEff * shares, "the floor-scaled payout can never exceed the exact pro-rata slice");
        assertGe((ltEff - toUint256(claims.nav)) * supply, ltEff * (supply - shares), "remaining liquidity holders must keep at least their prior NAV-per-share");
    }
}
