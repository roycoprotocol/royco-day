// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { WAD } from "../../../src/libraries/Constants.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";
import { MarketFuzzTestBase } from "../../utils/MarketFuzzTestBase.sol";

/**
 * @title TestFuzz_MaxDepositAndWithdrawal_Kernel
 * @notice Fuzzes the three gated max deposit/withdrawal reads through the full production stack (tranche -> kernel -> accountant):
 *         executing exactly the reported max succeeds and leaves both the coverage and liquidity gates at or below
 *         100%, and one wei (or share) beyond the max plus its derived dust slack reverts on the derived gate
 * @dev Every market is seeded flat at a 1.0 vault rate and 1.0 prices, so one vault-share wei == one BPT wei ==
 *      one NAV wei and every boundary is exact integer algebra. Default parameters throughout: 20% minimum
 *      coverage, 5% minimum liquidity, 1 wei ST and JT NAV dust tolerances. The dust slacks between the
 *      reported max and the algebraic gate boundary are therefore:
 *      - senior deposit, coverage leg: stDust + jtDust = 2 wei of slack
 *      - senior deposit, liquidity leg: stDust = 1 wei of slack
 *      - junior redemption: the two dust tolerances plus a 2 wei guard for the gate's internal ceil, all
 *        amplified by the 1/0.8 coverage retention into a slack of exactly 5 or 6 shares (derived and
 *        bracketed in the test), consumed explicitly down to the algebraic boundary
 *      - liquidity redemption: stDust = 1 wei of slack
 */
contract TestFuzz_MaxDepositAndWithdrawal_Kernel is MarketFuzzTestBase {
    /**
     * Scenario: a flat seeded market reports its max senior deposit, the depositor fills exactly that capacity,
     * then consumes the dust slack up to the algebraic gate boundary, and the very next wei reverts on the gate
     * that binds. This is the no-overfill guarantee: the advertised max is achievable and nothing beyond the
     * boundary can enter.
     *
     * Derivation (flat marks stRawNAV = stEffectiveNAV = st, jtRawNAV = jtEffectiveNAV = jt, ltRawNAV = depth, exact because 0.2e18 and
     * 0.05e18 divide WAD):
     *   coverage gate:  ceil((st + d + jt) * 0.2e18 / jt) <= WAD  <=>  d <= 4*jt - st            (covBound)
     *   liquidity gate: ceil((st + d) * 0.05e18 / depth) <= WAD   <=>  d <= 20*depth - st        (liqBound)
     *   reported max = min(covBound - stDust - jtDust, liqBound - stDust) = min(covBound - 2, liqBound - 1)
     * so the slack to the true boundary B = min(covBound, liqBound) is 1 or 2 wei, and B + 1 wei must revert:
     * on the coverage error when covBound <= liqBound (coverage is checked first), else on the liquidity error.
     */
    function testFuzz_MaxSeniorDeposit_FillsCapacityExactlyAndOneMoreWeiReverts(uint256 _stSeed, uint256 _jtSeed, uint256 _extraQuoteSeed) public {
        uint256 st = bound(_stSeed, 1e18, 1e27); // uniform over 9 orders of magnitude of senior seed size
        uint256 jt = bound(_jtSeed, st / 2, 2 * st); // uniform coverage ratios from 2:1 to 1:2, always seedable (needs jt >= st/4)
        // uniform extra pool depth from 1 quote wei to ~4x the senior NAV, sweeping which leg (coverage or liquidity) binds
        uint256 extraQuote = bound(_extraQuoteSeed, 1, 4 * st / QUOTE_TO_NAV_SCALE);
        uint256 depth = _seedFlatMarket(st, jt, extraQuote);

        // The algebraic gate boundaries and the production max with its per-leg dust slack (derivation above)
        uint256 covBound = 4 * jt - st;
        uint256 liqBound = 20 * depth - st;
        uint256 expectedMax = Math.min(covBound - 2, liqBound - 1);
        uint256 reportedMax = toUint256(seniorTranche.maxDeposit(ST_PROVIDER));
        assertEq(reportedMax, expectedMax, "reported max senior deposit must equal min(4jt - st - 2, 20depth - st - 1)");
        assertEq(
            RoycoTestMath.maxSTDeposit(st, jt, st, jt, depth, 0.2e18, 0.05e18, 1, 1), expectedMax, "independent mirror must agree with the reported max"
        );

        // Filling exactly the reported max must succeed and leave both gates at or below 100%
        _depositSenior(reportedMax);
        IRoycoDayAccountant.RoycoDayAccountantState memory acct = accountant.getState();
        assertEq(toUint256(acct.lastSTRawNAV), st + reportedMax, "the max deposit must land wei-exactly on the senior raw mark");
        assertLe(RoycoTestMath.computeCoverageUtilization(st + reportedMax, jt, 0.2e18, jt), WAD, "coverage utilization must hold at or below 100% after filling the max");
        assertLe(RoycoTestMath.computeLiquidityUtilization(st + reportedMax, 0.05e18, depth), WAD, "liquidity utilization must hold at or below 100% after filling the max");

        // Consuming the dust slack lands exactly on the algebraic boundary and still passes
        uint256 boundary = Math.min(covBound, liqBound);
        uint256 slack = boundary - reportedMax;
        _depositSenior(slack);
        assertEq(toUint256(accountant.getState().lastSTRawNAV), st + boundary, "the slack deposit must land exactly on the algebraic gate boundary");
        assertLe(RoycoTestMath.computeCoverageUtilization(st + boundary, jt, 0.2e18, jt), WAD, "coverage utilization must sit at or below 100% exactly at the boundary");
        assertLe(RoycoTestMath.computeLiquidityUtilization(st + boundary, 0.05e18, depth), WAD, "liquidity utilization must sit at or below 100% exactly at the boundary");

        // One wei past the boundary trips whichever gate binds: coverage is checked before liquidity, so the
        // coverage error surfaces whenever covBound <= liqBound, otherwise only liquidity is violated
        bytes4 expectedError =
            covBound <= liqBound ? IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector : IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector;
        stJtVault.mintShares(ST_PROVIDER, 1);
        vm.prank(ST_PROVIDER);
        stJtVault.approve(address(seniorTranche), 1);
        vm.expectRevert(expectedError);
        vm.prank(ST_PROVIDER);
        seniorTranche.deposit(toTrancheUnits(uint256(1)), ST_PROVIDER);
    }

    /**
     * Scenario: the junior LP redeems exactly its reported max, then consumes the remaining dust-and-fudge slack
     * up to the algebraic coverage boundary, and one more share reverts on the coverage gate. This guarantees the
     * junior tranche can always exit down to the senior tranche's required coverage floor but never through it.
     *
     * Derivation (flat marks, JT holds no cross-claim so shares, NAV, and withdrawn value are all 1:1):
     *   post-redemption coverage gate for a total withdrawal w:
     *     ceil((st + jt - w) * 0.2e18 / (jt - w)) <= WAD  <=>  4w <= 4*jt - st  <=>  w <= floor((4jt - st)/4)
     *   the view holds back a safety margin before inverting that gate. Rounding the required 20% coverage
     *   up against the redeemer costs k/5 wei of coverage surplus, where k = (5 - (st + jt) % 5) % 5 pads
     *   st + jt to the next multiple of 5; the market's two 1-wei NAV dust tolerances plus a 2-wei guard for
     *   the gate's internal ceil cost 4 more wei. A withdrawn wei frees only 0.8 wei of surplus (it shrinks
     *   the required coverage by 0.2 as it leaves), so the 4 + k/5 wei holdback prices at
     *   (4 + k/5) / 0.8 = 5 + k/4 shares of headroom, i.e. always 5 or 6 whole shares:
     *     reportedMax = floor((4*jt - st - k - 20) / 4)
     */
    function testFuzz_MaxJuniorRedemption_DrainsCoverageSurplusAndOneMoreShareReverts(uint256 _stSeed, uint256 _jtSeed) public {
        uint256 st = bound(_stSeed, 1e18, 1e27); // uniform over 9 orders of magnitude of senior seed size
        uint256 jt = bound(_jtSeed, st / 2, 2 * st); // uniform coverage ratios from 2:1 to 1:2, surplus always positive
        _seedFlatMarket(st, jt, 0);

        // The hand-derived closed form (derivation above) in plain checked integer arithmetic: k pads the
        // flat exposure st + jt up to the next multiple of 5 (the ceil in the required 20% coverage)
        uint256 k = (5 - (st + jt) % 5) % 5;
        uint256 expectedMax = (4 * jt - st - k - 20) / 4;
        uint256 reportedMax = juniorTranche.maxRedeem(JT_PROVIDER);
        assertEq(reportedMax, expectedMax, "reported max junior redemption must equal floor((4jt - st - k - 20) / 4)");
        (uint256 rtmST, uint256 rtmJT) = RoycoTestMath.maxJTWithdrawal(st, jt, st, jt, 0.2e18, 1, 1);
        assertEq(rtmST, 0, "a flat market withdraws nothing from the senior raw NAV");
        assertEq(rtmJT, expectedMax, "independent mirror must agree with the reported max");

        // Independent bracket that needs no closed form at all: the view must never advertise a redemption
        // past the algebraic coverage boundary (or executing the advertised max could revert on the gate),
        // and its safety holdback is at most 6 shares (or the view would sandbag the junior LP's exit)
        uint256 boundary = (4 * jt - st) / 4;
        assertLe(reportedMax + 5, boundary, "the reported max must hold back at least 5 shares of gate headroom");
        assertGe(reportedMax + 6, boundary, "the reported max may hold back at most 6 shares of gate headroom");

        // Redeeming exactly the reported max must succeed and leave the coverage gate at or below 100%
        vm.prank(JT_PROVIDER);
        juniorTranche.redeem(reportedMax, JT_PROVIDER, JT_PROVIDER);
        assertEq(toUint256(accountant.getState().lastJTRawNAV), jt - reportedMax, "the max redemption must land wei-exactly on the junior raw mark");
        assertLe(
            RoycoTestMath.computeCoverageUtilization(st, jt - reportedMax, 0.2e18, jt - reportedMax),
            WAD,
            "coverage utilization must hold at or below 100% after the max redemption"
        );

        // Consume the slack to the algebraic boundary w <= floor((4jt - st)/4), still passing
        uint256 slack = boundary - reportedMax;
        vm.prank(JT_PROVIDER);
        juniorTranche.redeem(slack, JT_PROVIDER, JT_PROVIDER);
        assertEq(toUint256(accountant.getState().lastJTRawNAV), jt - boundary, "the slack redemption must land exactly on the algebraic boundary");
        assertLe(
            RoycoTestMath.computeCoverageUtilization(st, jt - boundary, 0.2e18, jt - boundary), WAD, "coverage utilization must sit at or below 100% exactly at the boundary"
        );

        // One share past the boundary makes 4w > 4jt - st and violates the coverage requirement
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        vm.prank(JT_PROVIDER);
        juniorTranche.redeem(1, JT_PROVIDER, JT_PROVIDER);
    }

    /**
     * Scenario: the liquidity LP redeems exactly its reported max, then the single wei of dust slack, and one
     * more share reverts on the liquidity gate. This is the no-run guarantee: pooled depth can be pulled down
     * to the senior tranche's required liquidity floor but never below it.
     *
     * Derivation (flat marks, NAV-per-BPT exactly 1.0 so shares == BPT == NAV):
     *   post-redemption liquidity gate for a total withdrawal w:
     *     ceil(st * 0.05e18 / (depth - w)) <= WAD  <=>  ceil(st/20) <= depth - w  <=>  w <= depth - ceil(st/20)
     *   the view pads the senior NAV by the market's 1-wei ST NAV dust tolerance before scaling:
     *     reportedMax = depth - ceil((st + 1)/20) = depth - floor(st/20) - 1, so the slack to the algebraic
     *     floor is exactly 1 share when 20 divides st (the ceil absorbs the pad otherwise)
     */
    function testFuzz_MaxLiquidityRedemption_DrainsToLiquidityFloorAndOneMoreShareReverts(uint256 _stSeed, uint256 _jtSeed, uint256 _extraQuoteSeed) public {
        uint256 st = bound(_stSeed, 1e18, 1e27); // uniform over 9 orders of magnitude of senior seed size
        uint256 jt = bound(_jtSeed, st / 2, 2 * st); // uniform coverage ratios from 2:1 to 1:2 (coverage is not under test here)
        // uniform surplus depth from 1 quote wei to ~4x the senior NAV, so the withdrawable surplus varies widely
        uint256 extraQuote = bound(_extraQuoteSeed, 1, 4 * st / QUOTE_TO_NAV_SCALE);
        uint256 depth = _seedFlatMarket(st, jt, extraQuote);

        // The hand-derived closed form (derivation above) in plain checked integer arithmetic: the pool must
        // keep at least 5% of the dust-padded senior effective NAV, rounded up against the redeemer
        uint256 requiredFloor = (st + 19) / 20;
        uint256 expectedMax = depth - (st / 20) - 1;
        uint256 reportedMax = liquidityTranche.maxRedeem(LT_PROVIDER);
        assertEq(reportedMax, expectedMax, "reported max liquidity redemption must equal depth - ceil(st/20) - 1");

        // Independent conjunct that needs no closed form: the view must never advertise depth past the
        // required liquidity floor, or executing the advertised max would breach the no-run guarantee
        assertLe(reportedMax + requiredFloor, depth, "the reported max must leave the required liquidity floor in the pool");

        // A breached liquidation threshold would bypass the liquidity gate and unlock the full depth, so
        // prove the bypass is inactive rather than assume it: with the market's 20% minimum coverage and
        // jt >= floor(st/2), the flat coverage utilization ceil((st + jt) * 0.2e18 / jt) is at most
        // 0.6e18 + 1 wei (since (st + jt) / jt <= 3 up to the flooring in jt's lower bound), while the
        // deployed liquidation threshold must exceed WAD -- a market cannot be declared in liquidation
        // before its coverage is even fully utilized
        uint256 flatCoverageUtilizationWAD = RoycoTestMath.computeCoverageUtilization(st, jt, 0.2e18, jt);
        uint256 liquidationThresholdWAD = accountant.getState().coverageLiquidationUtilizationWAD;
        assertLe(flatCoverageUtilizationWAD, 0.6e18 + 1, "flat 2:1-to-1:2 seeds mark at most 60% coverage utilization");
        assertGt(liquidationThresholdWAD, WAD, "the deployed liquidation threshold must sit above full coverage utilization");
        assertEq(
            RoycoTestMath.maxLTWithdrawal(depth, st, 0.05e18, 1, flatCoverageUtilizationWAD, liquidationThresholdWAD),
            expectedMax,
            "independent mirror must agree with the reported max"
        );

        // Redeeming exactly the reported max must succeed and leave the liquidity gate at or below 100%
        vm.prank(LT_PROVIDER);
        liquidityTranche.redeem(reportedMax, LT_PROVIDER, LT_PROVIDER);
        assertEq(toUint256(accountant.getState().lastLTRawNAV), depth - reportedMax, "the max redemption must land wei-exactly on the LT raw mark");
        assertLe(RoycoTestMath.computeLiquidityUtilization(st, 0.05e18, depth - reportedMax), WAD, "liquidity utilization must hold at or below 100% after the max redemption");

        // The dust pad leaves slack to the algebraic floor only when the ceil cannot absorb it: exactly 1 share
        // when 20 divides st, zero otherwise
        uint256 slack = (depth - reportedMax) - requiredFloor;
        assertEq(slack, st % 20 == 0 ? 1 : 0, "the dust pad's slack to the algebraic floor must match the ceil absorption");
        if (slack != 0) {
            // Consume the slack, landing exactly on the algebraic floor depth == ceil(st/20)
            vm.prank(LT_PROVIDER);
            liquidityTranche.redeem(slack, LT_PROVIDER, LT_PROVIDER);
            assertEq(toUint256(accountant.getState().lastLTRawNAV), requiredFloor, "the slack redemption must land exactly on the required liquidity floor");
            assertLe(RoycoTestMath.computeLiquidityUtilization(st, 0.05e18, requiredFloor), WAD, "liquidity utilization must sit at or below 100% exactly at the floor");
        }

        // One share below the floor makes the remaining depth insufficient and violates the liquidity requirement
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        vm.prank(LT_PROVIDER);
        liquidityTranche.redeem(1, LT_PROVIDER, LT_PROVIDER);
    }
}
