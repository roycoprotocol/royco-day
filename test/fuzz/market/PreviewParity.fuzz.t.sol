// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { MarketFuzzBase } from "./MarketFuzzBase.sol";

/**
 * @title PreviewParityFuzz
 * @notice Fuzzes same-block preview/execute parity for all six deposit and redemption flows (senior, junior,
 *         and liquidity deposits, then senior, junior, and liquidity redemptions), chained through one evolving
 *         market so every later preview runs against state the earlier executions actually mutated
 * @dev Each preview is taken immediately before its execution in the same block, so any divergence between the
 *      view pricing path and the state-mutating pricing path (supply snapshots, fee-mint ordering, claim
 *      scaling) fails loudly. Amounts are bounded by the live max reads so no flow can revert on a gate and
 *      every one of the six parity assertions executes on every run
 */
contract PreviewParityFuzz is MarketFuzzBase {
    using Math for uint256;

    /**
     * Scenario: a seeded market accrues fuzzed up-only vault yield over a fuzzed window and syncs (committing
     * the premium deployment and every fee mint), then all six flows run back-to-back: deposit into each
     * tranche, redeem from each tranche, previewing immediately before each execution. Every preview must match
     * its execution byte-for-byte: minted shares for deposits, all five claim legs for redemptions.
     */
    function testFuzz_AllSixDepositAndRedeemFlows_previewMatchesExecutionInTheSameBlock(
        uint256 _stSeed,
        uint256 _jtSeed,
        uint256 _vaultBps,
        uint256 _elapsed,
        uint256 _amountSeedA,
        uint256 _amountSeedB,
        uint256 _amountSeedC,
        uint256 _sharesSeedA,
        uint256 _sharesSeedB,
        uint256 _sharesSeedC
    )
        public
    {
        uint256 st = bound(_stSeed, 1e18, 1e26); // uniform over 8 orders of magnitude of senior seed size
        uint256 jt = bound(_jtSeed, st / 2, 2 * st); // uniform coverage ratios from 2:1 to 1:2
        uint256 vb = bound(_vaultBps, 0, 10_000); // up-only yield 0% to +100% so the market stays PERPETUAL and all six flows stay enabled
        uint256 elapsed = bound(_elapsed, 1 hours, 365 days); // premium accrual window from an hour to a year
        // Extra quote-only depth worth 15% of the senior seed keeps the liquidity gate clear after up to +100%
        // senior appreciation, so the senior-deposit capacity and the LT-redemption capacity are both positive
        _seedFlatMarket(st, jt, st.mulDiv(3, 20) / QUOTE_TO_NAV_SCALE + 1);

        applySTPnL(int256(vb));
        _warpAndRefreshFeed(elapsed);
        syncVenuePrices();
        _sync();

        // Flow 1 — senior deposit, bounded by the live coverage-and-liquidity capacity (positive by the seeding)
        {
            uint256 assets = bound(_amountSeedA, 1e12, toUint256(seniorTranche.maxDeposit(ST_PROVIDER))); // dust-to-max sizes
            uint256 previewed = seniorTranche.previewDeposit(toTrancheUnits(assets));
            uint256 minted = _depositSenior(assets);
            assertEq(minted, previewed, "senior deposit must mint exactly the previewed shares");
        }

        // Flow 2 — junior deposit, never gated, seed-sized at most
        {
            uint256 assets = bound(_amountSeedB, 1e12, st); // dust-sized up to seed-sized junior deposits
            uint256 previewed = juniorTranche.previewDeposit(toTrancheUnits(assets));
            uint256 minted = _depositJunior(assets);
            assertEq(minted, previewed, "junior deposit must mint exactly the previewed shares");
        }

        // Flow 3 — in-kind liquidity deposit of freshly minted quote-backed BPT, never gated
        {
            uint256 quoteLeg = bound(_amountSeedC, 1, st / QUOTE_TO_NAV_SCALE); // 1 quote wei up to the senior NAV in depth
            uint256 bptIn = quoteLeg * QUOTE_TO_NAV_SCALE;
            _mintQuoteBackedBPT(LT_PROVIDER, bptIn, quoteLeg);
            uint256 previewed = liquidityTranche.previewDeposit(toTrancheUnits(bptIn));
            vm.startPrank(LT_PROVIDER);
            bpt.approve(address(liquidityTranche), bptIn);
            uint256 minted = liquidityTranche.deposit(toTrancheUnits(bptIn), LT_PROVIDER);
            vm.stopPrank();
            assertEq(minted, previewed, "liquidity deposit must mint exactly the previewed shares");
        }

        // Flow 4 — senior redemption, bounded by the live max so the raw-inventory constraints hold
        {
            // 1e6 share wei up to the reported max: a smaller redemption can floor to a zero-asset payout, which the
            // accountant rejects by design (INVALID_POST_OP_STATE), so the dust floor keeps every run on the parity path
            uint256 shares = bound(_sharesSeedA, 1e6, seniorTranche.maxRedeem(ST_PROVIDER));
            AssetClaims memory previewed = seniorTranche.previewRedeem(shares);
            vm.prank(ST_PROVIDER);
            AssetClaims memory claims = seniorTranche.redeem(shares, ST_PROVIDER, ST_PROVIDER);
            _assertClaimsParity(claims, previewed, "senior redemption");
        }

        // Flow 5 — junior redemption, bounded by the live coverage-respecting max
        {
            uint256 shares = bound(_sharesSeedB, 1e6, juniorTranche.maxRedeem(JT_PROVIDER)); // dust floor as in flow 4, up to the reported max
            AssetClaims memory previewed = juniorTranche.previewRedeem(shares);
            vm.prank(JT_PROVIDER);
            AssetClaims memory claims = juniorTranche.redeem(shares, JT_PROVIDER, JT_PROVIDER);
            _assertClaimsParity(claims, previewed, "junior redemption");
        }

        // Flow 6 — in-kind liquidity redemption, bounded by the live liquidity-respecting max
        {
            uint256 shares = bound(_sharesSeedC, 1e6, liquidityTranche.maxRedeem(LT_PROVIDER)); // dust floor as in flow 4, up to the reported max
            AssetClaims memory previewed = liquidityTranche.previewRedeem(shares);
            vm.prank(LT_PROVIDER);
            AssetClaims memory claims = liquidityTranche.redeem(shares, LT_PROVIDER, LT_PROVIDER);
            _assertClaimsParity(claims, previewed, "liquidity redemption");
        }
    }

    /// @notice Asserts all five claim legs of an executed redemption equal the same-block preview byte-for-byte
    function _assertClaimsParity(AssetClaims memory _executed, AssetClaims memory _previewed, string memory _flow) internal pure {
        assertEq(_executed.stAssets, _previewed.stAssets, string.concat(_flow, ": senior-asset leg must match the preview"));
        assertEq(_executed.jtAssets, _previewed.jtAssets, string.concat(_flow, ": junior-asset leg must match the preview"));
        assertEq(_executed.ltAssets, _previewed.ltAssets, string.concat(_flow, ": LT-asset leg must match the preview"));
        assertEq(_executed.stShares, _previewed.stShares, string.concat(_flow, ": senior-share leg must match the preview"));
        assertEq(_executed.nav, _previewed.nav, string.concat(_flow, ": claim NAV must match the preview"));
    }
}
