// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { AssetClaims, MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoTestMath } from "../../base/math/RoycoTestMath.sol";
import { MarketFuzzBase } from "./MarketFuzzBase.sol";

/**
 * @title SelfLiquidationBonusFuzz
 * @notice Fuzzes the senior self-liquidation bonus through the full production redemption stack: once coverage
 *         utilization breaches the liquidation threshold, a redeeming senior LP receives exactly the derived
 *         bonus on top of its pro-rata claims, and paying that bonus can never increase coverage utilization
 *         (the anti-bank-run property: one LP's exit sweetener must not eat into coverage for those who stay)
 * @dev The market is driven into liquidation with a fuzzed shared drawdown at a fixed 30% junior seed ratio.
 *      With jt = 0.3 x st, a drawdown r in [-23%, -20.8%] leaves the junior buffer positive but thin:
 *      jtEff = 0.3 x st x r - st x (1 - r) and covUtil = 1.3 x st x r x 0.2 / jtEff evaluates to at least
 *      (1.3 x 0.792 x 0.2) / (0.3 x 0.792 - 0.208) = 6.956 at the shallow end, above the 6.4667 liquidation
 *      threshold, and the buffer only thins (utilization only grows) as the drawdown deepens toward the
 *      junior-exhaustion point at -23.077%
 */
contract SelfLiquidationBonusFuzz is MarketFuzzBase {
    using Math for uint256;

    /**
     * Scenario: a covered drawdown breaches the liquidation threshold (which forces the market PERPETUAL so
     * withdrawals stay open), then a senior LP redeems a fuzzed slice. The payout must be the pro-rata claims
     * plus exactly the mirror-derived bonus - min(1% of the claim NAV, the junior buffer, the largest bonus
     * that keeps coverage utilization from rising) - sourced from the junior tranche's own assets (the junior
     * tranche holds no cross-claim on senior raw NAV after paying coverage). Afterwards the committed marks
     * must show coverage utilization at or below its pre-redemption value.
     */
    function testFuzz_SelfLiquidation_paysExactBonusAndNeverRaisesCoverageUtilization(uint256 _stSeed, uint256 _drawdownBps, uint256 _sharesSeed) public {
        uint256 st = bound(_stSeed, 1e18, 1e26); // uniform over 8 orders of magnitude of senior seed size
        // uniform drawdowns from -23% to -20.8%: always past the liquidation threshold, never exhausting the
        // junior buffer (exhaustion sits at -23.077% for the 30% junior ratio)
        uint256 drawdownBps = bound(_drawdownBps, 2080, 2300);
        uint256 jt = st * 3 / 10;
        _seedFlatMarket(st, jt, 0);

        applySTPnL(-int256(drawdownBps));
        SyncedAccountingState memory state = _sync();

        // Committed drawdown marks, pinned against the hand-derived quoter outputs: the loss is fully covered,
        // so the senior tranche keeps its full effective NAV and the junior buffer absorbs the entire hit
        uint256 rate = 1e18 - drawdownBps * 1e14;
        assertEq(toUint256(state.stRawNAV), st.mulDiv(rate, 1e18), "the senior raw mark must be the seed at the drawn-down rate");
        assertEq(toUint256(state.stEffectiveNAV), st, "a fully covered loss leaves the senior effective NAV whole");
        uint256 covPre = state.coverageUtilizationWAD;
        assertGe(covPre, 6.4667e18, "the drawdown must breach the liquidation coverage threshold by construction");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "a liquidation breach forces the market PERPETUAL so withdrawals stay open");

        // The senior tranche's total claims: its own raw NAV plus the coverage cross-claim on junior raw NAV
        // (stEff - stRaw), each floored through the quoter into vault shares. No mints happened on the loss
        // sync, so the senior supply is still the seed
        assertEq(seniorTranche.totalSupply(), st, "no premium or fee shares mint on a covered-loss sync");
        uint256 stClaimOnJTRaw = st - toUint256(state.stRawNAV);
        uint256 totalSTAssets = toUint256(state.stRawNAV).mulDiv(1e18, rate);
        uint256 totalJTAssets = stClaimOnJTRaw.mulDiv(1e18, rate);

        // The redeemer's base slice and the exact bonus the production stack must pay on top of it. The dust
        // floor of 1e6 share wei keeps the payout above the zero-asset threshold the accountant rejects
        uint256 shares = bound(_sharesSeed, 1e6, st); // dust-to-full-exit slices, small slices exercise the zero-bonus floor path
        uint256 baseNav = st.mulDiv(shares, st);
        uint256 baseSTAssets = totalSTAssets.mulDiv(shares, st);
        uint256 baseJTAssets = totalJTAssets.mulDiv(shares, st);
        uint256 expectedBonus = RoycoTestMath.selfLiqBonus(
            RoycoTestMath.SelfLiqBonusIn({
                stRaw: toUint256(state.stRawNAV),
                jtRaw: toUint256(state.jtRawNAV),
                jtEff: toUint256(state.jtEffectiveNAV),
                jtCoinvested: true,
                coverageUtilizationWAD: covPre,
                coverageLiquidationUtilizationWAD: 6.4667e18,
                bonusWAD: 0.01e18,
                userClaimNAV: baseNav,
                // The user's claim on real exposure re-values each floored asset leg at the drawn-down rate,
                // exactly as the production bonus sizing does
                stUserWeightedClaimNAV: baseSTAssets.mulDiv(rate, 1e18) + baseJTAssets.mulDiv(rate, 1e18)
            })
        );

        uint256 balBefore = stJtVault.balanceOf(ST_PROVIDER);
        vm.prank(ST_PROVIDER);
        AssetClaims memory claims = seniorTranche.redeem(shares, ST_PROVIDER, ST_PROVIDER);

        // Exact payout: the bonus lands on the junior-asset leg because the junior tranche's claims sit
        // entirely on its own raw NAV here (it holds no cross-claim on senior raw NAV to source from first)
        assertEq(toUint256(claims.nav), baseNav + expectedBonus, "the redeemed NAV must be the pro-rata slice plus exactly the derived bonus");
        assertEq(toUint256(claims.stAssets), baseSTAssets, "the senior-asset leg must be the unboosted pro-rata slice");
        assertEq(
            toUint256(claims.jtAssets), baseJTAssets + expectedBonus.mulDiv(1e18, rate), "the junior-asset leg must carry the bonus at the drawn-down rate"
        );
        assertEq(
            stJtVault.balanceOf(ST_PROVIDER) - balBefore,
            toUint256(claims.stAssets) + toUint256(claims.jtAssets),
            "the wallet delta must equal both claimed legs exactly"
        );

        // The anti-bank-run property: coverage utilization on the committed post-redemption marks never
        // exceeds its pre-redemption value, so the bonus can never worsen the remaining LPs' coverage
        uint256 covPost = RoycoTestMath.covUtil(
            toUint256(accountant.getState().lastSTRawNAV),
            toUint256(accountant.getState().lastJTRawNAV),
            true,
            0.2e18,
            toUint256(accountant.getState().lastJTEffectiveNAV)
        );
        assertLe(covPost, covPre, "paying the self-liquidation bonus must never increase coverage utilization");
    }
}
