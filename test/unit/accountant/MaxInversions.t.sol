// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoDayAccountant } from "../../../src/accountant/RoycoDayAccountant.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { MAX_NAV_UNITS, WAD, ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { Operation, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoTestMath } from "../../base/math/RoycoTestMath.sol";
import { AccountantUnitHarness } from "./AccountantUnitHarness.sol";

/**
 * @title MaxInversionsTest
 * @notice Phase B block 3 golden vectors (testing-strategy.md §4.1 block 3, spec 12 §6 V3.1-V3.8): the F15-F17
 *         max* closed forms cross-asserted against the independent RoycoTestMath mirrors, plus the inversion
 *         probes the existing accountant suite does not cover — the liquidity-binding deposit with an ST dust
 *         slack, the JT-withdrawal fudge boundary on a non-exact ceil'd required value, and the LT-withdrawal
 *         ST dust slack boundary
 * @dev Existing coverage NOT duplicated here (spec 12 §6 V3.x EXISTS notes): the zero-dust coverage-binding and
 *      liquidity-binding maxSTDeposit inversions, the coverage-side dust-slack boundary, the flat-market
 *      maxJTWithdrawal fudge boundary on an exactly-divisible required value, the cross-claim probe, and the
 *      maxLTWithdrawal zero-dust exact boundary all live in test/accountant/RoycoDayAccountant.t.sol H1-H5
 */
contract MaxInversionsTest is AccountantUnitHarness {
    function setUp() public {
        _deploy(false, _defaultParams());
    }

    /*//////////////////////////////////////////////////////////////////////
                    F15 — maxSTDeposit RTM PARITY AND INVERSION
    //////////////////////////////////////////////////////////////////////*/

    /**
     * V3.3 + F15 mirror parity at zero dust, both legs live, each leg disabled, and saturation.
     * Cell 1 (coverage binds, coinvested): coverage = floor(120e18 / 0.15) - (100e18 + 0 + 500e18 + 0) = 200e18,
     *   liquidity = floor(60e18 / 0.08) - 480e18 = 270e18 -> min = 200e18
     * Cell 2 (minCoverage 0 disables the coverage leg): max = liquidity leg = 270e18
     * Cell 3 (minLiquidity 0 disables the liquidity leg): max = coverage leg = 200e18
     * Cell 4 (both 0): MAX_NAV_UNITS
     * Cell 5 (saturation, coinvested): coverage = floor(50e18 / 0.2) - (100e18 + 700e18) = 250e18 - 800e18 -> 0
     */
    function test_MaxSTDeposit_matchesRTM_bothLegsDisableEdgesAndSaturation() public view {
        // Cell 1 — both legs live, coverage binds
        SyncedAccountingState memory st = _bareState(500e18, 100e18, 60e18, 480e18, 120e18, true, 0.15e18, 0.08e18);
        assertEq(toUint256(accountant.maxSTDeposit(st)), 200e18, "coverage leg binds at the hand literal");
        assertEq(RoycoTestMath.maxSTDeposit(500e18, 100e18, 480e18, 120e18, 60e18, true, 0.15e18, 0.08e18, 0, 0), 200e18, "RTM cell 1");

        // Cell 2 — coverage leg disabled
        st = _bareState(500e18, 100e18, 60e18, 480e18, 120e18, true, 0, 0.08e18);
        assertEq(toUint256(accountant.maxSTDeposit(st)), 270e18, "liquidity leg alone at the hand literal");
        assertEq(RoycoTestMath.maxSTDeposit(500e18, 100e18, 480e18, 120e18, 60e18, true, 0, 0.08e18, 0, 0), 270e18, "RTM cell 2");

        // Cell 3 — liquidity leg disabled
        st = _bareState(500e18, 100e18, 60e18, 480e18, 120e18, true, 0.15e18, 0);
        assertEq(toUint256(accountant.maxSTDeposit(st)), 200e18, "coverage leg alone at the hand literal");
        assertEq(RoycoTestMath.maxSTDeposit(500e18, 100e18, 480e18, 120e18, 60e18, true, 0.15e18, 0, 0, 0), 200e18, "RTM cell 3");

        // Cell 4 — both requirements zero leaves capacity unbounded
        st = _bareState(500e18, 100e18, 60e18, 480e18, 120e18, true, 0, 0);
        assertEq(toUint256(accountant.maxSTDeposit(st)), toUint256(MAX_NAV_UNITS), "no requirement leaves capacity unbounded");
        assertEq(RoycoTestMath.maxSTDeposit(500e18, 100e18, 480e18, 120e18, 60e18, true, 0, 0, 0, 0), type(uint256).max, "RTM cell 4");

        // Cell 5 — over-deployed coverage saturates to zero
        st = _bareState(700e18, 100e18, 40e18, 750e18, 50e18, true, 0.2e18, 0.04e18);
        assertEq(toUint256(accountant.maxSTDeposit(st)), 0, "over-deployed coverage saturates to zero");
        assertEq(RoycoTestMath.maxSTDeposit(700e18, 100e18, 750e18, 50e18, 40e18, true, 0.2e18, 0.04e18, 0, 0), 0, "RTM cell 5");
    }

    /**
     * F15 mirror parity with live dust tolerances (st 3, jt 7), not coinvested.
     * Coverage leg = floor(200e18 / 0.1) - (0 + 7 + 1000e18 + 3) = 1000e18 - 10 (jtDust applies REGARDLESS of
     * co-investment per RDA:368, the pinned H1 quirk), liquidity leg = floor(100e18 / 0.05) - (900e18 + 3)
     * = 1100e18 - 3 -> coverage binds at 1000e18 - 10
     */
    function test_MaxSTDeposit_matchesRTM_withDustTolerances() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stNAVDustTolerance = toNAVUnits(uint256(3));
        p.jtNAVDustTolerance = toNAVUnits(uint256(7));
        _deploy(false, p);
        SyncedAccountingState memory st = _bareState(1000e18, 500e18, 100e18, 900e18, 200e18, false, 0.1e18, 0.05e18);
        assertEq(toUint256(accountant.maxSTDeposit(st)), 1000e18 - 10, "coverage leg minus both dust terms binds");
        assertEq(RoycoTestMath.maxSTDeposit(1000e18, 500e18, 900e18, 200e18, 100e18, false, 0.1e18, 0.05e18, 3, 7), 1000e18 - 10, "RTM dusted cell");
    }

    /**
     * V3.2 (F15, RDA:376-384): liquidity-binding inversion with a live ST dust tolerance — the slack on the
     * liquidity leg is stDust ONLY (no jt term).
     * Seed 1000e18/300e18 flat with 100e18 of LT depth, dust (st 3, jt 7):
     *   coverage leg = floor(300e18 / 0.1) - (0 + 7 + 1000e18 + 3) = 2000e18 - 10
     *   liquidity leg = floor(100e18 / 0.05) - (1000e18 + 3) = 1000e18 - 3 -> liquidity binds
     * Depositing max lands stEff = 2000e18 - 3: liqUtil = ceil((2000e18 - 3) * 0.05 / 100e18) = WAD (the ceil
     * absorbs the 0.15 wei shortfall). Consuming the 3 wei slack lands stEff = 2000e18 exactly on WAD, and one
     * more wei violates the liquidity requirement
     */
    function test_MaxSTDeposit_inversionLiquidityBindingWithSTDustSlack() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stNAVDustTolerance = toNAVUnits(uint256(3));
        p.jtNAVDustTolerance = toNAVUnits(uint256(7));
        _deploy(false, p);
        _seedSymmetric(1000e18, 300e18, 100e18);

        NAV_UNIT max = accountant.maxSTDeposit(_checkpointState());
        assertEq(toUint256(max), 1000e18 - 3, "liquidity leg binds at the independently derived value");
        assertEq(RoycoTestMath.maxSTDeposit(1000e18, 300e18, 1000e18, 300e18, 100e18, false, 0.1e18, 0.05e18, 3, 7), toUint256(max), "RTM parity");

        // Deposit exactly the reported max: the post-op liquidity utilization already reads WAD by ceil
        SyncedAccountingState memory state = kernel.doPostOp(
            Operation.ST_DEPOSIT, toNAVUnits(uint256(1000e18) + toUint256(max)), toNAVUnits(uint256(300e18)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, true
        );
        assertEq(state.liquidityUtilizationWAD, WAD, "the exact max lands liquidity utilization on WAD via the ceil");
        // Consume the 3 wei stDust slack, landing exactly on the algebraic boundary
        state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(2000e18)), toNAVUnits(uint256(300e18)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, true);
        assertEq(state.liquidityUtilizationWAD, WAD, "the slack consumed lands exactly on WAD");
        // One wei beyond max + slack violates the liquidity requirement (slack = stDust only on this leg)
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(2000e18 + 1)), toNAVUnits(uint256(300e18)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, true);
    }

    /*//////////////////////////////////////////////////////////////////////
                    F16 — maxJTWithdrawal RTM PARITY AND INVERSION
    //////////////////////////////////////////////////////////////////////*/

    /**
     * V3.6 (F16, RDA:429-444): the cross-claim split at both co-investment values, RTM parity plus hand literals.
     * State (1000e18, 200e18, stEff 980e18, jtEff 220e18): jtClaimOnST = 20e18, jtClaimOnJT = 200e18,
     * fracST = floor(20e18 * WAD / 220e18) = 90_909_090_909_090_909 and fracJT = 909_090_909_090_909_090.
     * Not coinvested: required = ceil(1000e18 * 0.1) = 100e18, surplus = 120e18 - 2,
     *   retention = WAD - floor(0.1e18 * fracST / WAD) = 990_909_090_909_090_910,
     *   claimable = floor((120e18 - 2) * WAD / retention) = 121_100_917_431_192_660_437,
     *   stW = floor(claimable * fracST / WAD) = 11_009_174_311_926_605_483,
     *   jtW = floor(claimable * fracJT / WAD) = 110_091_743_119_266_054_832
     * Coinvested: required = ceil(1200e18 * 0.1) = 120e18, surplus = 100e18 - 2,
     *   retention = WAD - floor(0.1e18 * (fracST + fracJT) / WAD) = 900_000_000_000_000_001,
     *   claimable = 111_111_111_111_111_110_985,
     *   stW = 10_101_010_101_010_100_988, jtW = 101_010_101_010_101_009_885
     */
    function test_MaxJTWithdrawal_matchesRTM_crossClaimBothCoinvestments() public view {
        // Not coinvested
        SyncedAccountingState memory st = _bareState(1000e18, 200e18, 100e18, 980e18, 220e18, false, 0.1e18, 0.05e18);
        (NAV_UNIT stW, NAV_UNIT jtW) = accountant.maxJTWithdrawal(st);
        assertEq(toUint256(stW), 11_009_174_311_926_605_483, "senior-side withdrawable, not coinvested");
        assertEq(toUint256(jtW), 110_091_743_119_266_054_832, "junior-side withdrawable, not coinvested");
        (uint256 rtmST, uint256 rtmJT) = RoycoTestMath.maxJTWithdrawal(1000e18, 200e18, 980e18, 220e18, false, 0.1e18, 0, 0);
        assertEq(toUint256(stW), rtmST, "RTM senior side, not coinvested");
        assertEq(toUint256(jtW), rtmJT, "RTM junior side, not coinvested");

        // Coinvested (the view honors state.jtCoinvested, the pinned H1 note)
        st = _bareState(1000e18, 200e18, 100e18, 980e18, 220e18, true, 0.1e18, 0.05e18);
        (stW, jtW) = accountant.maxJTWithdrawal(st);
        assertEq(toUint256(stW), 10_101_010_101_010_100_988, "senior-side withdrawable, coinvested");
        assertEq(toUint256(jtW), 101_010_101_010_101_009_885, "junior-side withdrawable, coinvested");
        (rtmST, rtmJT) = RoycoTestMath.maxJTWithdrawal(1000e18, 200e18, 980e18, 220e18, true, 0.1e18, 0, 0);
        assertEq(toUint256(stW), rtmST, "RTM senior side, coinvested");
        assertEq(toUint256(jtW), rtmJT, "RTM junior side, coinvested");
    }

    /**
     * V3.5 (F16, RDA:426-440): the early-outs, RTM parity on both sides of the surplus boundary and on the
     * defensive zero-claims arm.
     * Surplus boundary: required = ceil(400e18 * 0.1) = 40e18, so jtEff = 40e18 + 2 zeroes the surplus through
     * the +2 fudge -> (0, 0), and jtEff = 40e18 + 3 leaves surplus 1 -> claimable 1 -> split (0, 1).
     * Zero-claims arm: (stRaw 0, jtRaw 8e18, stEff 8e18, jtEff 8e18) is non-conserved (defensive input): both
     * jtClaimOnST = sat(8e18 - 8e18) = 0 and jtClaimOnJT = 8e18 - sat(8e18 - 0) = 0 -> (0, 0)
     */
    function test_MaxJTWithdrawal_matchesRTM_earlyOutBoundaries() public view {
        // Exactly at the fudge-consumed surplus boundary
        SyncedAccountingState memory st = _bareState(400e18, 40e18 + 2, 0, 400e18, 40e18 + 2, false, 0.1e18, 0);
        (NAV_UNIT stW, NAV_UNIT jtW) = accountant.maxJTWithdrawal(st);
        (uint256 rtmST, uint256 rtmJT) = RoycoTestMath.maxJTWithdrawal(400e18, 40e18 + 2, 400e18, 40e18 + 2, false, 0.1e18, 0, 0);
        assertEq(toUint256(stW) + toUint256(jtW), 0, "surplus exactly zero at the fudge boundary");
        assertEq(rtmST + rtmJT, 0, "RTM surplus boundary");

        // One wei above the boundary
        st = _bareState(400e18, 40e18 + 3, 0, 400e18, 40e18 + 3, false, 0.1e18, 0);
        (stW, jtW) = accountant.maxJTWithdrawal(st);
        (rtmST, rtmJT) = RoycoTestMath.maxJTWithdrawal(400e18, 40e18 + 3, 400e18, 40e18 + 3, false, 0.1e18, 0, 0);
        assertEq(toUint256(stW), 0, "nothing from the senior raw NAV");
        assertEq(toUint256(jtW), 1, "one wei withdrawable above the boundary");
        assertEq(rtmST, 0, "RTM senior side above the boundary");
        assertEq(rtmJT, 1, "RTM junior side above the boundary");

        // Defensive zero-claims arm (non-conserved input)
        st = _bareState(0, 8e18, 0, 8e18, 8e18, false, 0.1e18, 0);
        (stW, jtW) = accountant.maxJTWithdrawal(st);
        (rtmST, rtmJT) = RoycoTestMath.maxJTWithdrawal(0, 8e18, 8e18, 8e18, false, 0.1e18, 0, 0);
        assertEq(toUint256(stW) + toUint256(jtW), 0, "zero total claims early-out");
        assertEq(rtmST + rtmJT, 0, "RTM zero total claims early-out");
    }

    /**
     * V3.4 (F16, RDA:424-425): the +2 wei fudge boundary on a NON-exact required value, where the inner ceil of
     * the coverage requirement absorbs the fractional boundary and the fudge is pure protocol-favoring slack.
     * Seed (1000e18 + 7, 200e18) flat, zero dust: required = ceil((1000e18 + 7) * 0.1) = 100e18 + 1 (the 0.7 wei
     * product remainder rounds up), surplus = 200e18 - (100e18 + 1) - 2 = 100e18 - 3, split (0, 100e18 - 3).
     * The algebraic gate is jtEff' * WAD >= (1000e18 + 7) * 0.1e18 = 1e38 + 7e17, so the minimum passing
     * jtEff' is 100e18 + 1: redeeming max lands jtEff' = 100e18 + 3 with covUtil exactly WAD (ceil), the two
     * fudge wei redeem one at a time still at WAD, and the wei that would land jtEff' = 100e18 computes
     * covUtil = WAD + 1 and violates
     */
    function test_MaxJTWithdrawal_inversionCeilRequiredFudgeBoundary() public {
        _seedSymmetric(1000e18 + 7, 200e18, 100e18);

        (NAV_UNIT stW, NAV_UNIT jtW) = accountant.maxJTWithdrawal(_checkpointState());
        assertEq(toUint256(stW), 0, "flat market withdraws from the junior raw NAV only");
        assertEq(toUint256(jtW), 100e18 - 3, "max with the ceil'd required value and the 2 wei fudge");
        (uint256 rtmST, uint256 rtmJT) = RoycoTestMath.maxJTWithdrawal(1000e18 + 7, 200e18, 1000e18 + 7, 200e18, false, 0.1e18, 0, 0);
        assertEq(toUint256(stW), rtmST, "RTM senior side");
        assertEq(toUint256(jtW), rtmJT, "RTM junior side");

        // Redeem exactly max: jtEff' = 100e18 + 3, covUtil = ceil((1e38 + 7e17) / (100e18 + 3)) = WAD exactly
        SyncedAccountingState memory state = kernel.doPostOp(
            Operation.JT_REDEEM, toNAVUnits(uint256(1000e18 + 7)), toNAVUnits(200e18 - toUint256(jtW)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, true
        );
        assertEq(state.coverageUtilizationWAD, WAD, "the exact max lands coverage utilization on WAD");
        // First fudge wei: jtEff' = 100e18 + 2, still WAD
        state = kernel.doPostOp(
            Operation.JT_REDEEM, toNAVUnits(uint256(1000e18 + 7)), toNAVUnits(uint256(100e18 + 2)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, true
        );
        assertEq(state.coverageUtilizationWAD, WAD, "max + 1 still passes inside the fudge");
        // Second fudge wei: jtEff' = 100e18 + 1, the minimum passing buffer, still WAD
        state = kernel.doPostOp(
            Operation.JT_REDEEM, toNAVUnits(uint256(1000e18 + 7)), toNAVUnits(uint256(100e18 + 1)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, true
        );
        assertEq(state.coverageUtilizationWAD, WAD, "max + 2 exhausts the fudge exactly at WAD");
        // One more wei crosses the algebraic boundary: covUtil = WAD + 1
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(uint256(1000e18 + 7)), toNAVUnits(uint256(100e18)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, true);
    }

    /*//////////////////////////////////////////////////////////////////////
                    F17 — maxLTWithdrawal RTM PARITY AND INVERSION
    //////////////////////////////////////////////////////////////////////*/

    /**
     * V3.8 + F17 mirror parity: the ceil'd required depth, both bypasses (zero requirement, liquidation breach
     * at the EXACT threshold per the >= comparison), and saturation.
     * Required depth = ceil((600e18 + 11) * 0.03) = 18e18 + 1 (the 0.33 wei remainder rounds up):
     *   max = 40e18 - (18e18 + 1) = 22e18 - 1
     * minLiquidity 0 -> full 40e18. covUtil == liqThreshold (1.1e18) exactly -> full 40e18, one below -> restricted.
     * ltRaw 10e18 < required -> saturates to 0
     */
    function test_MaxLTWithdrawal_matchesRTM_ceilBypassesAndSaturation() public view {
        // Ceil'd required depth
        SyncedAccountingState memory st = _bareState(700e18, 100e18, 40e18, 600e18 + 11, 100e18, false, 0.1e18, 0.03e18);
        assertEq(toUint256(accountant.maxLTWithdrawal(st)), 22e18 - 1, "ceil'd required depth at the hand literal");
        assertEq(RoycoTestMath.maxLTWithdrawal(40e18, 600e18 + 11, 0.03e18, 0, 0, type(uint256).max), 22e18 - 1, "RTM ceil cell");

        // Zero-requirement bypass
        st.minLiquidityWAD = 0;
        assertEq(toUint256(accountant.maxLTWithdrawal(st)), 40e18, "no requirement leaves the full inventory withdrawable");
        assertEq(RoycoTestMath.maxLTWithdrawal(40e18, 600e18 + 11, 0, 0, 0, type(uint256).max), 40e18, "RTM zero-requirement bypass");

        // Liquidation-breach bypass at the exact threshold (>= comparison)
        st.minLiquidityWAD = 0.03e18;
        st.coverageLiquidationUtilizationWAD = 1.1e18;
        st.coverageUtilizationWAD = 1.1e18;
        assertEq(toUint256(accountant.maxLTWithdrawal(st)), 40e18, "the exact liquidation boundary unlocks the full inventory");
        assertEq(RoycoTestMath.maxLTWithdrawal(40e18, 600e18 + 11, 0.03e18, 0, 1.1e18, 1.1e18), 40e18, "RTM exact-threshold bypass");
        st.coverageUtilizationWAD = 1.1e18 - 1;
        assertEq(toUint256(accountant.maxLTWithdrawal(st)), 22e18 - 1, "one below the boundary stays restricted");
        assertEq(RoycoTestMath.maxLTWithdrawal(40e18, 600e18 + 11, 0.03e18, 0, 1.1e18 - 1, 1.1e18), 22e18 - 1, "RTM below-threshold restriction");

        // Saturation
        st.coverageUtilizationWAD = 0;
        st.coverageLiquidationUtilizationWAD = type(uint256).max;
        st.ltRawNAV = toNAVUnits(uint256(10e18));
        assertEq(toUint256(accountant.maxLTWithdrawal(st)), 0, "under-provisioned inventory saturates to zero");
        assertEq(RoycoTestMath.maxLTWithdrawal(10e18, 600e18 + 11, 0.03e18, 0, 0, type(uint256).max), 0, "RTM saturation");
    }

    /**
     * V3.7 (F17, RDA:459-462): the LT-withdrawal inversion with a live ST dust tolerance — slack = stDust.
     * Seed 1000e18/200e18 flat with 100e18 of LT depth, stDust 3: required = ceil(1000e18 * 0.05) = 50e18 exact,
     * max = 100e18 - (50e18 + 3) = 50e18 - 3.
     * Redeeming max leaves ltRaw = 50e18 + 3: liqUtil = ceil(5e37 / (5e19 + 3)) = WAD (ceil absorbs the
     * shortfall). Consuming the 3 wei slack leaves ltRaw = 50e18 exactly on WAD, and one more wei computes
     * liqUtil = WAD + 1 and violates
     */
    function test_MaxLTWithdrawal_inversionSTDustSlackBoundary() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stNAVDustTolerance = toNAVUnits(uint256(3));
        _deploy(false, p);
        _seedSymmetric(1000e18, 200e18, 100e18);

        NAV_UNIT max = accountant.maxLTWithdrawal(_checkpointState());
        assertEq(toUint256(max), 50e18 - 3, "closed form minus the stDust slack");
        // covUtil at the flat seed = ceil(1000e18 * 0.1 / 200e18) = 0.5e18, below the 1.1e18 threshold: no bypass
        assertEq(RoycoTestMath.maxLTWithdrawal(100e18, 1000e18, 0.05e18, 3, 0.5e18, 1.1e18), toUint256(max), "RTM parity");

        // Redeem exactly the reported max
        SyncedAccountingState memory state = kernel.doPostOp(
            Operation.LT_REDEEM, toNAVUnits(uint256(1000e18)), toNAVUnits(uint256(200e18)), toNAVUnits(100e18 - toUint256(max)), ZERO_NAV_UNITS, true
        );
        assertEq(state.liquidityUtilizationWAD, WAD, "the exact max lands liquidity utilization on WAD via the ceil");
        // Consume the 3 wei stDust slack, landing exactly on the algebraic boundary
        state =
            kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(uint256(1000e18)), toNAVUnits(uint256(200e18)), toNAVUnits(uint256(50e18)), ZERO_NAV_UNITS, true);
        assertEq(state.liquidityUtilizationWAD, WAD, "the slack consumed lands exactly on WAD");
        // One wei beyond max + slack violates the liquidity requirement
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(uint256(1000e18)), toNAVUnits(uint256(200e18)), toNAVUnits(uint256(50e18 - 1)), ZERO_NAV_UNITS, true);
    }
}
