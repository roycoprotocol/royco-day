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
 *      one NAV wei on the seed. Default parameters throughout: 20% minimum coverage, 5% minimum liquidity, 1 wei
 *      ST and JT NAV dust tolerances. The senior-deposit max is a NAV amount and stays exact integer algebra, but
 *      the two redemption maxes are SHARE counts: maxRedeem converts its NAV bound to shares through the virtual-shares
 *      offset primitive (supply + VIRTUAL_SHARES over claimNAV + VIRTUAL_VALUE), so shares and NAV no longer coincide.
 *      Each redemption gate binds on the WITHDRAWN NAV (floor(claimNAV x shares / (supply + 1e6))), so the tests invert
 *      that floor to the largest gate-respecting share count and check one share past it reverts:
 *      - senior deposit, coverage leg: stDust + jtDust = 2 wei of NAV slack
 *      - senior deposit, liquidity leg: stDust = 1 wei of NAV slack
 *      - junior redemption: the reported share max sits at or below the inverted coverage boundary sStar
 *      - liquidity redemption: the reported share max sits at or below the inverted liquidity boundary sStar
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
        vm.expectRevert(expectedError);
        seniorTranche.previewDeposit(toTrancheUnits(uint256(1)));
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
     * Algebraic boundary (flat marks, JT holds no cross-claim, so the junior supply == jt effNAV, but redeeming s
     * shares withdraws floor(jt * s / (jt + VIRTUAL_SHARES)) NAV under the redemption-side offset):
     *   post-redemption coverage gate for a total withdrawal w: ceil((st + jt - w) * 0.2e18 / (jt - w)) <= WAD
     *   <=> 4w <= 4*jt - st <=> w <= floor((4jt - st)/4). Inverting the withdrawn-NAV floor at that boundary gives the
     *   largest gate-respecting share count sStar; the dust-held-back reported max sits at or below it, and one share
     *   past sStar withdraws boundary + 1 NAV and reverts on coverage. The independent mirror pins the reported max.
     */
    function testFuzz_MaxJuniorRedemption_DrainsCoverageSurplusAndOneMoreShareReverts(uint256 _stSeed, uint256 _jtSeed) public {
        uint256 st = bound(_stSeed, 1e18, 1e27); // uniform over 9 orders of magnitude of senior seed size
        uint256 jt = bound(_jtSeed, st / 2, 2 * st); // uniform coverage ratios from 2:1 to 1:2, surplus always positive
        _seedFlatMarket(st, jt, 0);

        // The independent mirror pins the exact reported max. maxRedeem now converts the NAV bound to shares through
        // the offset-aware primitive (supply + VIRTUAL_SHARES over effNAV + VIRTUAL_VALUE), capped by the balance, so
        // the reported max is a SHARE count that no longer equals the withdrawable NAV 1:1 (flat seed: jt supply == jt effNAV)
        uint256 maxWithdrawNAV = RoycoTestMath.maxJTWithdrawal(st, jt, jt, 0.2e18, 1, 1);
        uint256 reportedMax = juniorTranche.maxRedeem(JT_PROVIDER);
        assertEq(
            reportedMax,
            Math.min(juniorTranche.balanceOf(JT_PROVIDER), RoycoTestMath.convertToShares(maxWithdrawNAV, jt, jt)),
            "independent mirror must agree with the reported max junior redemption"
        );

        // The coverage gate binds on the WITHDRAWN NAV, not the share count: redeeming s shares withdraws
        // floor(jt x s / (jt + VIRTUAL_SHARES)) NAV (flat marks, junior holds no cross-claim), and the post-redemption
        // coverage requirement caps that at w <= floor((4jt - st)/4). Inverting the floor at that boundary gives the
        // largest redeemable share count sStar; one share past it withdraws boundary + 1 NAV and breaches coverage
        uint256 boundaryNAV = (4 * jt - st) / 4;
        uint256 sStar = ((boundaryNAV + 1) * (jt + 1e6) - 1) / jt;
        // The dust-held-back advisory max must never exceed the true coverage-bounded share max
        assertLe(reportedMax, sStar, "the reported max must not advertise past the true coverage-bounded share max");

        // One share past the true max makes the withdrawn NAV exceed floor((4jt - st)/4) and violates the coverage
        // requirement, from the preview and the execution alike (both from the untouched pre-redemption state, the
        // reverting calls mutate nothing)
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        juniorTranche.previewRedeem(sStar + 1);
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        vm.prank(JT_PROVIDER);
        juniorTranche.redeem(sStar + 1, JT_PROVIDER, JT_PROVIDER);

        // Redeeming exactly the true max succeeds and leaves the coverage gate at or below 100%, with the withdrawn NAV
        // landing on or just under the algebraic boundary (the offset granularity may leave it a wei short of exact)
        vm.prank(JT_PROVIDER);
        juniorTranche.redeem(sStar, JT_PROVIDER, JT_PROVIDER);
        uint256 jtRawAfter = toUint256(accountant.getState().lastJTRawNAV);
        assertLe(jt - jtRawAfter, boundaryNAV, "the max redemption's withdrawn NAV must respect the algebraic coverage boundary");
        assertLe(
            RoycoTestMath.computeCoverageUtilization(st, jtRawAfter, 0.2e18, jtRawAfter),
            WAD,
            "coverage utilization must hold at or below 100% after the max redemption"
        );
    }

    /**
     * Scenario: the liquidity LP redeems exactly its reported max, then the single wei of dust slack, and one
     * more share reverts on the liquidity gate. This is the no-run guarantee: pooled depth can be pulled down
     * to the senior tranche's required liquidity floor but never below it.
     *
     * Derivation (flat marks, NAV-per-BPT exactly 1.0, and the LT supply == depth ltRawNAV on the seed, but redeeming s
     * shares withdraws floor(depth * s / (depth + VIRTUAL_SHARES)) NAV under the redemption-side offset):
     *   post-redemption liquidity gate for a total withdrawal w:
     *     ceil(st * 0.05e18 / (depth - w)) <= WAD  <=>  ceil(st/20) <= depth - w  <=>  w <= depth - ceil(st/20)
     *   Inverting the withdrawn-NAV floor at that boundary gives the largest gate-respecting share count sStar; the
     *   view's advisory max (its NAV bound depth - floor(st/20) - 1 converted to shares) sits at or below sStar, and one
     *   share past sStar drops the pool below the required floor ceil(st/20) and reverts on liquidity.
     */
    function testFuzz_MaxLiquidityRedemption_DrainsToLiquidityFloorAndOneMoreShareReverts(uint256 _stSeed, uint256 _jtSeed, uint256 _extraQuoteSeed) public {
        uint256 st = bound(_stSeed, 1e18, 1e27); // uniform over 9 orders of magnitude of senior seed size
        uint256 jt = bound(_jtSeed, st / 2, 2 * st); // uniform coverage ratios from 2:1 to 1:2 (coverage is not under test here)
        // uniform surplus depth from 1 quote wei to ~4x the senior NAV, so the withdrawable surplus varies widely
        uint256 extraQuote = bound(_extraQuoteSeed, 1, 4 * st / QUOTE_TO_NAV_SCALE);
        uint256 depth = _seedFlatMarket(st, jt, extraQuote);

        // The algebraic 5% liquidity floor the pool must retain, rounded up against the redeemer (no dust pad here)
        uint256 requiredFloor = (st + 19) / 20;

        // The independent mirror pins the exact reported max. maxRedeem converts the NAV bound to shares through the
        // offset-aware primitive (supply + VIRTUAL_SHARES over ltRawNAV + VIRTUAL_VALUE), capped by the balance, so the
        // reported max is a SHARE count that no longer equals the withdrawable NAV 1:1. The claim NAV is the pool depth
        // (depth == ltRawNAV), but the LT SUPPLY no longer equals depth: the fresh auto-seed mints 1:1 while the
        // extraQuote seed mints through the offset, so the conversion must use the actual live LT supply, not depth.
        uint256 supply = liquidityTranche.totalSupply();
        uint256 maxWithdrawNAV = RoycoTestMath.maxLTWithdrawal(depth, st, 0.05e18, 1); // == depth - floor(st/20) - 1
        uint256 reportedMax = liquidityTranche.maxRedeem(LT_PROVIDER);
        assertEq(
            reportedMax,
            Math.min(liquidityTranche.balanceOf(LT_PROVIDER), RoycoTestMath.convertToShares(maxWithdrawNAV, depth, supply)),
            "independent mirror must agree with the reported max"
        );

        // The liquidity gate binds on the WITHDRAWN BPT/NAV, not the share count: redeeming s shares withdraws
        // floor(depth x s / (supply + VIRTUAL_SHARES)) NAV (NAV-per-BPT is exactly 1.0, and the redeemer's slice scales
        // against supply + VIRTUAL_SHARES), and the pool must retain the 5% floor requiredFloor = ceil(st/20), so
        // withdrawn <= depth - requiredFloor. Inverting the floor at that boundary gives the largest redeemable share
        // count sStar; one share past it drops the pool below the floor
        uint256 boundaryNAV = depth - requiredFloor;
        uint256 sStar = ((boundaryNAV + 1) * (supply + 1e6) - 1) / depth;
        // The dust-held-back advisory max must never exceed the true liquidity-bounded share max
        assertLe(reportedMax, sStar, "the reported max must not advertise past the true liquidity-bounded share max");

        // One share past the true max drops the retained depth below the required floor and violates the liquidity
        // requirement, from the preview and the execution alike (both from the untouched pre-redemption state)
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        liquidityTranche.previewRedeem(sStar + 1);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        vm.prank(LT_PROVIDER);
        liquidityTranche.redeem(sStar + 1, LT_PROVIDER, LT_PROVIDER);

        // Redeeming exactly the true max succeeds and leaves the pool at or above the required liquidity floor
        vm.prank(LT_PROVIDER);
        liquidityTranche.redeem(sStar, LT_PROVIDER, LT_PROVIDER);
        uint256 ltRawAfter = toUint256(accountant.getState().lastLTRawNAV);
        assertGe(ltRawAfter, requiredFloor, "the max redemption must leave the required liquidity floor in the pool");
        assertLe(RoycoTestMath.computeLiquidityUtilization(st, 0.05e18, ltRawAfter), WAD, "liquidity utilization must hold at or below 100% after the max redemption");
    }
}
