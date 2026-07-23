// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { AssetClaims, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { MarketFuzzTestBase } from "../../utils/MarketFuzzTestBase.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";

/**
 * @title TestFuzz_RedemptionClaims_Kernel
 * @notice Fuzzes redemption payouts through the full production stack for all three tranches: a redeemer's
 *         claims must equal the floor-scaled pro-rata slice of its tranche's total claims (the claim NAV is
 *         the tranche's effective NAV and the collateral leg is that NAV converted ONCE at the quoter rate),
 *         the tokens received must equal the claims to the wei, and no redemption can extract value beyond
 *         its pro-rata share of the tranche
 * @dev Every scenario first accrues fuzzed up-only yield and syncs, so the redemptions run against a state
 *      where the risk premium has shifted value from the senior to the junior claim and freshly minted
 *      premium and protocol-fee shares sit in the supplies. The no-extraction half is asserted in
 *      cross-multiplied integer form so no division rounding can hide a leak
 */
contract TestFuzz_RedemptionClaims_Kernel is MarketFuzzTestBase {
    using Math for uint256;

    /**
     * Scenario: after fuzzed vault yield and a sync, a senior LP redeems a fuzzed slice. The senior claim IS
     * its effective NAV: total senior claims are collateralAssets = floor(stEffectiveNAV x 1e18 / rate) vault
     * shares from the one coinvested pool (a single conversion, no per-leg decomposition). The redeemer
     * receives the floor-scaled slice of each leg and its wallet delta must match the claims exactly.
     */
    function testFuzz_SeniorRedemption_PaysExactProRataClaims(
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
        uint256 vb = bound(_vaultBps, 1, 10_000); // strictly positive yield so the risk premium moves value toward the junior claim
        uint256 elapsed = bound(_elapsed, 1 hours, 365 days); // premium accrual window from an hour to a year
        _seedFlatMarket(st, jt, 0);

        applySTPnL(int256(vb));
        _warpAndRefreshFeed(elapsed);
        syncVenuePrices();
        SyncedAccountingState memory state = _sync();

        // With the quote at 1.0 the composed quoter rate is just the accrued vault rate, exact: the collateral
        // mark is ONE conversion of the whole coinvested seed at that rate
        uint256 rate = 1e18 + vb * 1e14;
        assertEq(toUint256(state.collateralNAV), (st + jt).mulDiv(rate, 1e18), "the collateral mark must be the whole seed at the accrued rate");
        // Conservation at wei precision on the committed marks: the pool is exactly the sum of the tranche claims
        uint256 stEffectiveNAV = toUint256(state.stEffectiveNAV);
        assertEq(
            stEffectiveNAV + toUint256(state.jtEffectiveNAV), toUint256(state.collateralNAV), "the effective NAVs must conserve the collateral mark exactly"
        );
        // The senior claim is its effective NAV converted once into the coinvested collateral asset
        uint256 totalClaimAssets = stEffectiveNAV.mulDiv(1e18, rate);

        // The redeemer's slice: every claim leg floors independently over the EFFECTIVE supply (supply + VIRTUAL_SHARES),
        // mirroring src _scaleAssetClaims, which prices each field against totalTrancheShares + 1e6 so the virtual-share
        // sliver stays behind (the redemption-side inflation-attack mitigation)
        uint256 supply = seniorTranche.totalSupply();
        // 1e6 share wei up to the full seeded balance: a smaller redemption can floor to a zero-asset payout,
        // which the accountant rejects by design (INVALID_POST_OP_STATE), so the dust floor keeps every run valid
        uint256 shares = bound(_sharesSeed, 1e6, st);
        uint256 balBefore = stJtVault.balanceOf(ST_PROVIDER);
        // The Redeem event must carry exactly the derived claims (each leg floor-scaled independently over supply + 1e6)
        AssetClaims memory expectedClaims;
        expectedClaims.collateralAssets = toTrancheUnits(totalClaimAssets.mulDiv(shares, supply + 1e6));
        expectedClaims.nav = toNAVUnits(stEffectiveNAV.mulDiv(shares, supply + 1e6));
        vm.expectEmit(true, true, true, true, address(seniorTranche));
        emit IRoycoVaultTranche.Redeem(ST_PROVIDER, ST_PROVIDER, expectedClaims, shares);
        vm.prank(ST_PROVIDER);
        AssetClaims memory claims = seniorTranche.redeem(shares, ST_PROVIDER, ST_PROVIDER);

        assertEq(toUint256(claims.nav), stEffectiveNAV.mulDiv(shares, supply + 1e6), "redeemed NAV must be the floor-scaled slice of the senior effective NAV");
        assertEq(
            toUint256(claims.collateralAssets),
            totalClaimAssets.mulDiv(shares, supply + 1e6),
            "the collateral leg must be the floor-scaled slice of the once-converted senior claim"
        );
        assertEq(
            stJtVault.balanceOf(ST_PROVIDER) - balBefore, toUint256(claims.collateralAssets), "the wallet delta must equal the claimed vault shares exactly"
        );

        // No extraction beyond pro-rata: the payout NAV never exceeds the exact fractional slice, so the
        // remaining holders keep at least their prior NAV-per-share (cross-multiplied, no division rounding)
        assertLe(toUint256(claims.nav) * supply, stEffectiveNAV * shares, "the floor-scaled payout can never exceed the exact pro-rata slice");
        assertGe(
            (stEffectiveNAV - toUint256(claims.nav)) * supply,
            stEffectiveNAV * (supply - shares),
            "remaining senior holders must keep at least their prior NAV-per-share"
        );
    }

    /**
     * Scenario: after fuzzed vault yield and a sync, a junior LP redeems a fuzzed slice bounded by the coverage
     * gate. The junior claim IS its effective NAV (its attributed share of the collateral gain plus the risk
     * premium the senior ceded), converted ONCE into the coinvested collateral asset and floor-scaled.
     */
    function testFuzz_JuniorRedemption_PaysExactProRataClaims(
        uint256 _stSeed,
        uint256 _jtSeed,
        uint256 _vaultBps,
        uint256 _elapsed,
        uint256 _sharesSeed
    )
        public
    {
        uint256 st = bound(_stSeed, 1e18, 1e26); // uniform over 8 orders of magnitude of senior seed size
        uint256 jt = bound(_jtSeed, st / 2, 2 * st); // uniform coverage ratios from 2:1 to 1:2, ample surplus for redemption
        uint256 vb = bound(_vaultBps, 1, 10_000); // strictly positive yield so the risk-premium shift is live
        uint256 elapsed = bound(_elapsed, 1 hours, 365 days); // premium accrual window from an hour to a year
        _seedFlatMarket(st, jt, 0);

        applySTPnL(int256(vb));
        _warpAndRefreshFeed(elapsed);
        syncVenuePrices();
        SyncedAccountingState memory state = _sync();

        uint256 rate = 1e18 + vb * 1e14;
        uint256 jtEffectiveNAV = toUint256(state.jtEffectiveNAV);
        // Conservation at wei precision on the committed marks, then the junior claim converted once
        assertEq(
            toUint256(state.stEffectiveNAV) + jtEffectiveNAV, toUint256(state.collateralNAV), "the effective NAVs must conserve the collateral mark exactly"
        );
        uint256 totalClaimAssets = jtEffectiveNAV.mulDiv(1e18, rate);

        // Every claim leg floors over the EFFECTIVE supply (supply + VIRTUAL_SHARES), mirroring src _scaleAssetClaims
        uint256 supply = juniorTranche.totalSupply();
        uint256 shares = bound(_sharesSeed, 1e6, juniorTranche.maxRedeem(JT_PROVIDER)); // coverage-respecting slices above the zero-payout dust floor
        uint256 balBefore = stJtVault.balanceOf(JT_PROVIDER);
        // The Redeem event must carry exactly the derived claims (the single collateral leg floor-scaled over supply + 1e6)
        AssetClaims memory expectedClaims;
        expectedClaims.collateralAssets = toTrancheUnits(totalClaimAssets.mulDiv(shares, supply + 1e6));
        expectedClaims.nav = toNAVUnits(jtEffectiveNAV.mulDiv(shares, supply + 1e6));
        vm.expectEmit(true, true, true, true, address(juniorTranche));
        emit IRoycoVaultTranche.Redeem(JT_PROVIDER, JT_PROVIDER, expectedClaims, shares);
        vm.prank(JT_PROVIDER);
        AssetClaims memory claims = juniorTranche.redeem(shares, JT_PROVIDER, JT_PROVIDER);

        assertEq(toUint256(claims.nav), jtEffectiveNAV.mulDiv(shares, supply + 1e6), "redeemed NAV must be the floor-scaled slice of the junior effective NAV");
        assertEq(
            toUint256(claims.collateralAssets),
            totalClaimAssets.mulDiv(shares, supply + 1e6),
            "the collateral leg must be the floor-scaled slice of the once-converted junior claim"
        );
        assertEq(
            stJtVault.balanceOf(JT_PROVIDER) - balBefore, toUint256(claims.collateralAssets), "the wallet delta must equal the claimed vault shares exactly"
        );

        assertLe(toUint256(claims.nav) * supply, jtEffectiveNAV * shares, "the floor-scaled payout can never exceed the exact pro-rata slice");
        assertGe(
            (jtEffectiveNAV - toUint256(claims.nav)) * supply,
            jtEffectiveNAV * (supply - shares),
            "remaining junior holders must keep at least their prior NAV-per-share"
        );
    }

    /**
     * Scenario: the venue is armed to reject the premium reinvestment (persistent 50% slippage), so the sync
     * leaves the liquidity premium as idle liquidity premium senior shares held by the kernel
     * (ltOwnedSeniorTrancheShares) instead of deploying it into the pool. A liquidity LP then redeems a
     * fuzzed slice and must receive BOTH legs of the LT's effective NAV: the floor-scaled BPT slice and the
     * floor-scaled slice of the idle liquidity premium senior shares, sent directly.
     *
     * Idle-share derivation: the premium mint to the LT is net of the LT protocol fee and the senior-fee mint to
     * the recipient is the ST fee plus the LT fee carved out of the premium, both priced against the retained
     * senior NAV (stEffectiveNAV - premium - fee) at the pre-sync supply, so
     *   idleShares = floor(st x (premium - ltFee) / (stEffectiveNAV - premium - fee))
     * and the LT effective NAV adds the idle shares valued at the post-mint senior share price through the
     * offset-aware _convertToValue (numerator gains VIRTUAL_VALUE = 1, denominator gains VIRTUAL_SHARES = 1e6):
     *   ltEff = depth + floor((stEffectiveNAV + 1) x idleShares / (stSupplyAfterMints + 1e6))
     */
    function testFuzz_LiquidityRedemption_PaysBPTSliceAndIdleLiquidityPremiumSharesSliceExactly(
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

        // The kernel must hold exactly the derived idle liquidity premium senior shares, outside the raw LT mark.
        // The premium mint to the LT is net of the LT protocol fee, the fee mint to the recipient is the ST fee
        // plus the LT fee, both priced against the retained senior NAV (stEffectiveNAV - premium - fee) at the
        // pre-sync supply. No liquidity-tranche shares are minted on a sync.
        uint256 retainedSeniorNAV = toUint256(state.stEffectiveNAV) - toUint256(state.ltLiquidityPremium) - toUint256(state.stProtocolFee);
        uint256 idleShares = RoycoTestMath.convertToShares(toUint256(state.ltLiquidityPremium) - toUint256(state.ltProtocolFee), retainedSeniorNAV, st);
        uint256 stProtocolFeeShares = RoycoTestMath.convertToShares(toUint256(state.stProtocolFee) + toUint256(state.ltProtocolFee), retainedSeniorNAV, st);
        uint256 stSupplyAfterMints = st + idleShares + stProtocolFeeShares;
        IRoycoDayKernel.RoycoDayKernelState memory ks = kernel.getState();
        assertEq(ks.ltOwnedSeniorTrancheShares, idleShares, "ltOwnedSeniorTrancheShares must hold exactly the net premium mint");
        assertEq(seniorTranche.totalSupply(), stSupplyAfterMints, "the senior supply must include the net premium and fee-plus-ltfee mints exactly");
        assertEq(toUint256(state.ltRawNAV), depth, "the committed LT raw mark must exclude the idle liquidity premium senior shares");

        // The LT's two-leg effective NAV: pool depth plus the idle shares valued through the offset-aware
        // _convertToValue (numerator + VIRTUAL_VALUE, denominator + VIRTUAL_SHARES), mirroring src exactly
        uint256 idleValue = idleShares.mulDiv(toUint256(state.stEffectiveNAV) + 1, stSupplyAfterMints + 1e6);
        uint256 ltEff = depth + idleValue;

        // Every claim leg floors over the EFFECTIVE supply (supply + VIRTUAL_SHARES), mirroring src _scaleAssetClaims
        uint256 supply = liquidityTranche.totalSupply();
        uint256 shares = bound(_sharesSeed, 1e6, liquidityTranche.maxRedeem(LT_PROVIDER)); // liquidity-respecting slices above the zero-payout dust floor
        uint256 bptBefore = bpt.balanceOf(LT_PROVIDER);
        uint256 stSharesBefore = seniorTranche.balanceOf(LT_PROVIDER);
        // The Redeem event must carry exactly the derived two-leg claims (BPT slice plus idle-share slice), each over supply + 1e6
        AssetClaims memory expectedClaims;
        expectedClaims.ltAssets = toTrancheUnits(depth.mulDiv(shares, supply + 1e6));
        expectedClaims.stShares = idleShares.mulDiv(shares, supply + 1e6);
        expectedClaims.nav = toNAVUnits(ltEff.mulDiv(shares, supply + 1e6));
        vm.expectEmit(true, true, true, true, address(liquidityTranche));
        emit IRoycoVaultTranche.Redeem(LT_PROVIDER, LT_PROVIDER, expectedClaims, shares);
        vm.prank(LT_PROVIDER);
        AssetClaims memory claims = liquidityTranche.redeem(shares, LT_PROVIDER, LT_PROVIDER);

        assertEq(toUint256(claims.nav), ltEff.mulDiv(shares, supply + 1e6), "redeemed NAV must be the floor-scaled slice of the two-leg LT effective NAV");
        assertEq(toUint256(claims.ltAssets), depth.mulDiv(shares, supply + 1e6), "the BPT leg must be the floor-scaled slice of the pool depth");
        assertEq(
            claims.stShares,
            idleShares.mulDiv(shares, supply + 1e6),
            "the senior-share leg must be the floor-scaled slice of the idle liquidity premium senior shares"
        );
        assertEq(bpt.balanceOf(LT_PROVIDER) - bptBefore, toUint256(claims.ltAssets), "the BPT wallet delta must equal the claim exactly");
        assertEq(
            seniorTranche.balanceOf(LT_PROVIDER) - stSharesBefore,
            claims.stShares,
            "the idle liquidity premium senior shares must be sent directly to the redeemer"
        );

        assertLe(toUint256(claims.nav) * supply, ltEff * shares, "the floor-scaled payout can never exceed the exact pro-rata slice");
        assertGe(
            (ltEff - toUint256(claims.nav)) * supply, ltEff * (supply - shares), "remaining liquidity holders must keep at least their prior NAV-per-share"
        );
    }
}
