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
 *      coverage, 5% minimum liquidity, 1 wei ST and JT NAV dust tolerances, JT co-invested (forced by the kernel
 *      family). The dust slacks between the reported max and the algebraic gate boundary are therefore:
 *      - senior deposit, coverage leg: stDust + jtDust = 2 wei of slack
 *      - senior deposit, liquidity leg: stDust = 1 wei of slack
 *      - junior redemption: stDust + jtDust + the 2 wei rounding fudge, all amplified by the 1/0.8 coverage
 *        retention, so the slack is computed as (algebraic bound - reported max) and consumed explicitly
 *      - liquidity redemption: stDust = 1 wei of slack
 */
contract TestFuzz_MaxDepositAndWithdrawal_Kernel is MarketFuzzTestBase {
    using Math for uint256;

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
            RoycoTestMath.maxSTDeposit(st, jt, st, jt, depth, true, 0.2e18, 0.05e18, 1, 1), expectedMax, "independent mirror must agree with the reported max"
        );

        // Filling exactly the reported max must succeed and leave both gates at or below 100%
        _depositSenior(reportedMax);
        IRoycoDayAccountant.RoycoDayAccountantState memory acct = accountant.getState();
        assertEq(toUint256(acct.lastSTRawNAV), st + reportedMax, "the max deposit must land wei-exactly on the senior raw mark");
        assertLe(RoycoTestMath.computeCoverageUtilization(st + reportedMax, jt, true, 0.2e18, jt), WAD, "coverage utilization must hold at or below 100% after filling the max");
        assertLe(RoycoTestMath.computeLiquidityUtilization(st + reportedMax, 0.05e18, depth), WAD, "liquidity utilization must hold at or below 100% after filling the max");

        // Consuming the dust slack lands exactly on the algebraic boundary and still passes
        uint256 boundary = Math.min(covBound, liqBound);
        uint256 slack = boundary - reportedMax;
        _depositSenior(slack);
        assertEq(toUint256(accountant.getState().lastSTRawNAV), st + boundary, "the slack deposit must land exactly on the algebraic gate boundary");
        assertLe(RoycoTestMath.computeCoverageUtilization(st + boundary, jt, true, 0.2e18, jt), WAD, "coverage utilization must sit at or below 100% exactly at the boundary");
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
     *   production max: surplus = jt - ceil((st + jt)/5) - stDust - jtDust - 2 (the 2 wei rounding fudge),
     *     scaled by the 1/(1 - 0.2) coverage retention: max = floor(surplus * 1e18 / 0.8e18), which sits at
     *     least 4 wei under the boundary, so the slack is computed and consumed explicitly
     */
    function testFuzz_MaxJuniorRedemption_DrainsCoverageSurplusAndOneMoreShareReverts(uint256 _stSeed, uint256 _jtSeed) public {
        uint256 st = bound(_stSeed, 1e18, 1e27); // uniform over 9 orders of magnitude of senior seed size
        uint256 jt = bound(_jtSeed, st / 2, 2 * st); // uniform coverage ratios from 2:1 to 1:2, surplus always positive
        _seedFlatMarket(st, jt, 0);

        // The production closed form restated: required coverage, the fudged surplus, and the retention scale-up
        uint256 required = (st + jt).ceilDiv(5);
        uint256 surplus = jt - required - 4;
        uint256 expectedMax = surplus.mulDiv(1e18, 0.8e18);
        uint256 reportedMax = juniorTranche.maxRedeem(JT_PROVIDER);
        assertEq(reportedMax, expectedMax, "reported max junior redemption must equal floor((jt - ceil((st + jt)/5) - 4) / 0.8)");
        (uint256 rtmST, uint256 rtmJT) = RoycoTestMath.maxJTWithdrawal(st, jt, st, jt, true, 0.2e18, 1, 1);
        assertEq(rtmST, 0, "a flat market withdraws nothing from the senior raw NAV");
        assertEq(rtmJT, expectedMax, "independent mirror must agree with the reported max");

        // Redeeming exactly the reported max must succeed and leave the coverage gate at or below 100%
        vm.prank(JT_PROVIDER);
        juniorTranche.redeem(reportedMax, JT_PROVIDER, JT_PROVIDER);
        assertEq(toUint256(accountant.getState().lastJTRawNAV), jt - reportedMax, "the max redemption must land wei-exactly on the junior raw mark");
        assertLe(
            RoycoTestMath.computeCoverageUtilization(st, jt - reportedMax, true, 0.2e18, jt - reportedMax),
            WAD,
            "coverage utilization must hold at or below 100% after the max redemption"
        );

        // Consume the slack to the algebraic boundary w <= floor((4jt - st)/4), still passing
        uint256 boundary = (4 * jt - st) / 4;
        uint256 slack = boundary - reportedMax;
        vm.prank(JT_PROVIDER);
        juniorTranche.redeem(slack, JT_PROVIDER, JT_PROVIDER);
        assertEq(toUint256(accountant.getState().lastJTRawNAV), jt - boundary, "the slack redemption must land exactly on the algebraic boundary");
        assertLe(
            RoycoTestMath.computeCoverageUtilization(st, jt - boundary, true, 0.2e18, jt - boundary), WAD, "coverage utilization must sit at or below 100% exactly at the boundary"
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
     *   production max = depth - ceil(st/20) - stDust = boundary - 1, so the slack is exactly 1 share
     */
    function testFuzz_MaxLiquidityRedemption_DrainsToLiquidityFloorAndOneMoreShareReverts(uint256 _stSeed, uint256 _jtSeed, uint256 _extraQuoteSeed) public {
        uint256 st = bound(_stSeed, 1e18, 1e27); // uniform over 9 orders of magnitude of senior seed size
        uint256 jt = bound(_jtSeed, st / 2, 2 * st); // uniform coverage ratios from 2:1 to 1:2 (coverage is not under test here)
        // uniform surplus depth from 1 quote wei to ~4x the senior NAV, so the withdrawable surplus varies widely
        uint256 extraQuote = bound(_extraQuoteSeed, 1, 4 * st / QUOTE_TO_NAV_SCALE);
        uint256 depth = _seedFlatMarket(st, jt, extraQuote);

        // The production closed form restated: withdrawable = depth - ceil'd required floor - 1 wei of ST dust
        uint256 requiredFloor = st.ceilDiv(20);
        uint256 expectedMax = depth - requiredFloor - 1;
        uint256 reportedMax = liquidityTranche.maxRedeem(LT_PROVIDER);
        assertEq(reportedMax, expectedMax, "reported max liquidity redemption must equal depth - ceil(st/20) - 1");
        // Flat coverage utilization ceil((st + jt) * 0.2e18 / jt) is far below the 6.4667e18 liquidation
        // threshold at these seed ratios, so no liquidation bypass is active
        assertEq(
            RoycoTestMath.maxLTWithdrawal(depth, st, 0.05e18, 1, RoycoTestMath.computeCoverageUtilization(st, jt, true, 0.2e18, jt), 6.4667e18),
            expectedMax,
            "independent mirror must agree with the reported max"
        );

        // Redeeming exactly the reported max must succeed and leave the liquidity gate at or below 100%
        vm.prank(LT_PROVIDER);
        liquidityTranche.redeem(reportedMax, LT_PROVIDER, LT_PROVIDER);
        assertEq(toUint256(accountant.getState().lastLTRawNAV), depth - reportedMax, "the max redemption must land wei-exactly on the LT raw mark");
        assertLe(RoycoTestMath.computeLiquidityUtilization(st, 0.05e18, depth - reportedMax), WAD, "liquidity utilization must hold at or below 100% after the max redemption");

        // Consume the single wei of ST dust slack, landing exactly on the algebraic floor depth == ceil(st/20)
        vm.prank(LT_PROVIDER);
        liquidityTranche.redeem(1, LT_PROVIDER, LT_PROVIDER);
        assertEq(toUint256(accountant.getState().lastLTRawNAV), requiredFloor, "the slack redemption must land exactly on the required liquidity floor");
        assertLe(RoycoTestMath.computeLiquidityUtilization(st, 0.05e18, requiredFloor), WAD, "liquidity utilization must sit at or below 100% exactly at the floor");

        // One share below the floor makes the remaining depth insufficient and violates the liquidity requirement
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        vm.prank(LT_PROVIDER);
        liquidityTranche.redeem(1, LT_PROVIDER, LT_PROVIDER);
    }
}
