// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { MAX_NAV_UNITS, WAD, ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { MarketState, Operation, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { AccountantTestBase } from "../../utils/AccountantTestBase.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";

/**
 * @title Test_MaxDepositAndWithdrawal_Accountant
 * @notice Hand-derived scenarios for the maxSTDeposit / maxJTWithdrawal / maxLTWithdrawal closed forms,
 *         cross-asserted against the independent RoycoTestMath mirrors, plus the exact gate-boundary probes the
 *         sync suite does not cover — the liquidity-binding deposit with an ST dust slack,
 *         the JT-withdrawal gate boundary on a non-exact ceil'd required value, and the LT-withdrawal
 *         ST dust slack boundary
 * @dev Existing coverage NOT duplicated here: the zero-dust coverage-binding and liquidity-binding
 *      maxSTDeposit gate boundaries, the coverage-side dust-slack boundary, the flat-market maxJTWithdrawal
 *      gate boundary on an exactly-divisible required value, the cross-claim probe, and the
 *      maxLTWithdrawal zero-dust exact boundary all live in the closed-form section below
 */
contract Test_MaxDepositAndWithdrawal_Accountant is AccountantTestBase {
    function setUp() public {
        _deploy(_defaultParams());
    }

    /*//////////////////////////////////////////////////////////////////////
                    maxSTDeposit RTM PARITY AND GATE BOUNDARIES
    //////////////////////////////////////////////////////////////////////*/

    /**
     * Mirror parity at zero dust across the closed form's whole branch set: both legs live, each leg
     * disabled, and saturation, so production and RoycoTestMath cannot drift apart on any branch.
     * Case 1 (coverage binds): coverage = floor(120e18 / 0.15) - (100e18 + 0 + 500e18 + 0) = 200e18,
     *   liquidity = floor(60e18 / 0.08) - 480e18 = 270e18 -> min = 200e18
     * Case 2 (minCoverage 0 disables the coverage leg): max = liquidity leg = 270e18
     * Case 3 (minLiquidity 0 disables the liquidity leg): max = coverage leg = 200e18
     * Case 4 (both 0): MAX_NAV_UNITS
     * Case 5 (saturation): coverage = floor(50e18 / 0.2) - (100e18 + 700e18) = 250e18 - 800e18 -> 0
     */
    function test_MaxSTDeposit_matchesRTM_bothLegsDisableEdgesAndSaturation() public view {
        // Case 1 — both legs live, coverage binds
        SyncedAccountingState memory st = _bareState(500e18, 100e18, 60e18, 480e18, 120e18, 0.15e18, 0.08e18);
        assertEq(toUint256(accountant.maxSTDeposit(st)), 200e18, "coverage leg binds at the hand literal");
        assertEq(RoycoTestMath.maxSTDeposit(500e18, 100e18, 480e18, 120e18, 60e18, 0.15e18, 0.08e18, 0, 0), 200e18, "RTM case 1");

        // Case 2 — coverage leg disabled
        st = _bareState(500e18, 100e18, 60e18, 480e18, 120e18, 0, 0.08e18);
        assertEq(toUint256(accountant.maxSTDeposit(st)), 270e18, "liquidity leg alone at the hand literal");
        assertEq(RoycoTestMath.maxSTDeposit(500e18, 100e18, 480e18, 120e18, 60e18, 0, 0.08e18, 0, 0), 270e18, "RTM case 2");

        // Case 3 — liquidity leg disabled
        st = _bareState(500e18, 100e18, 60e18, 480e18, 120e18, 0.15e18, 0);
        assertEq(toUint256(accountant.maxSTDeposit(st)), 200e18, "coverage leg alone at the hand literal");
        assertEq(RoycoTestMath.maxSTDeposit(500e18, 100e18, 480e18, 120e18, 60e18, 0.15e18, 0, 0, 0), 200e18, "RTM case 3");

        // Case 4 — both requirements zero leaves capacity unbounded
        st = _bareState(500e18, 100e18, 60e18, 480e18, 120e18, 0, 0);
        assertEq(toUint256(accountant.maxSTDeposit(st)), toUint256(MAX_NAV_UNITS), "no requirement leaves capacity unbounded");
        assertEq(RoycoTestMath.maxSTDeposit(500e18, 100e18, 480e18, 120e18, 60e18, 0, 0, 0, 0), type(uint256).max, "RTM case 4");

        // Case 5 — over-deployed coverage saturates to zero
        st = _bareState(700e18, 100e18, 40e18, 750e18, 50e18, 0.2e18, 0.04e18);
        assertEq(toUint256(accountant.maxSTDeposit(st)), 0, "over-deployed coverage saturates to zero");
        assertEq(RoycoTestMath.maxSTDeposit(700e18, 100e18, 750e18, 50e18, 40e18, 0.2e18, 0.04e18, 0, 0), 0, "RTM case 5");
    }

    /**
     * Mirror parity with live dust tolerances (st 3, jt 7).
     * Coverage leg = floor(200e18 / 0.1) - (500e18 + 7 + 1000e18 + 3) = 500e18 - 10,
     * liquidity leg = floor(100e18 / 0.05) - (900e18 + 3) = 1100e18 - 3 -> coverage binds at 500e18 - 10
     */
    function test_MaxSTDeposit_matchesRTM_withDustTolerances() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stNAVDustTolerance = toNAVUnits(uint256(3));
        p.jtNAVDustTolerance = toNAVUnits(uint256(7));
        _deploy(p);
        SyncedAccountingState memory st = _bareState(1000e18, 500e18, 100e18, 900e18, 200e18, 0.1e18, 0.05e18);
        assertEq(toUint256(accountant.maxSTDeposit(st)), 500e18 - 10, "coverage leg minus both dust terms binds");
        assertEq(RoycoTestMath.maxSTDeposit(1000e18, 500e18, 900e18, 200e18, 100e18, 0.1e18, 0.05e18, 3, 7), 500e18 - 10, "RTM dusted case");
    }

    /**
     * The liquidity-binding gate boundary with a live ST dust tolerance (RoycoDayAccountant.sol:365-372) — the slack
     * on the liquidity leg is stDust ONLY (no jt term), and the reported max is exact against the real gate.
     * Seed 1000e18/300e18 flat with 100e18 of LT depth, dust (st 3, jt 7):
     *   coverage leg = floor(300e18 / 0.1) - (300e18 + 7 + 1000e18 + 3) = 1700e18 - 10
     *   liquidity leg = floor(100e18 / 0.05) - (1000e18 + 3) = 1000e18 - 3 -> liquidity binds
     * Depositing max lands stEffectiveNAV = 2000e18 - 3: liquidityUtilization = ceil((2000e18 - 3) * 0.05 / 100e18) = WAD (the ceil
     * absorbs the 0.15 wei shortfall). Consuming the 3 wei slack lands stEffectiveNAV = 2000e18 exactly on WAD, and one
     * more wei violates the liquidity requirement
     */
    function test_MaxSTDeposit_LiquidityBindingWithSTDustSlackGateBoundary() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stNAVDustTolerance = toNAVUnits(uint256(3));
        p.jtNAVDustTolerance = toNAVUnits(uint256(7));
        _deploy(p);
        _seedSymmetric(1000e18, 300e18, 100e18);

        NAV_UNIT max = accountant.maxSTDeposit(_checkpointState());
        assertEq(toUint256(max), 1000e18 - 3, "liquidity leg binds at the independently derived value");
        assertEq(RoycoTestMath.maxSTDeposit(1000e18, 300e18, 1000e18, 300e18, 100e18, 0.1e18, 0.05e18, 3, 7), toUint256(max), "RTM parity");

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
                    maxJTWithdrawal RTM PARITY AND GATE BOUNDARIES
    //////////////////////////////////////////////////////////////////////*/

    /**
     * The cross-claim state (jtEffectiveNAV exceeds jtRawNAV because the junior holds a coverage claim on the
     * senior), cross-checked against the independent mirror.
     * State (1000e18, 200e18, jtEffectiveNAV 220e18, minCoverage 0.1): exposure = 1200e18,
     * required = ceil(1200e18 * 0.1) = 120e18, surplus = sat(220e18 - 120e18) = 100e18,
     * y = floor(100e18 * WAD / (WAD - 0.1e18))
     */
    function test_MaxJTWithdrawal_matchesRTM_crossClaim() public view {
        SyncedAccountingState memory st = _bareState(1000e18, 200e18, 100e18, 980e18, 220e18, 0.1e18, 0.05e18);
        NAV_UNIT jtW = accountant.maxJTWithdrawal(st);
        assertEq(toUint256(jtW), RoycoTestMath.maxJTWithdrawal(1000e18, 200e18, 220e18, 0.1e18, 0, 0), "RTM parity");
    }

    /**
     * The surplus saturation boundary of the closed form, plus the pure formula on a zero-senior-exposure
     * input, each cross-checked against the independent mirror across the settled branch set.
     * Saturation boundary: (stRawNAV 300e18, jtRawNAV 100e18) puts required = ceil(400e18 * 0.1) = 40e18, so
     * jtEffectiveNAV = 40e18 saturates the surplus to zero, and jtEffectiveNAV = 40e18 + 1 leaves surplus 1.
     * Zero senior exposure: (stRawNAV 0, jtRawNAV 8e18, jtEffectiveNAV 8e18) has exposure 8e18, required =
     * ceil(8e18 * 0.1) = 8e17, surplus = 8e18 - 8e17 = 7.2e18
     */
    function test_MaxJTWithdrawal_matchesRTM_earlyOutBoundaries() public view {
        // Exactly at the surplus saturation boundary
        SyncedAccountingState memory st = _bareState(300e18, 100e18, 0, 300e18, 40e18, 0.1e18, 0);
        assertEq(toUint256(accountant.maxJTWithdrawal(st)), RoycoTestMath.maxJTWithdrawal(300e18, 100e18, 40e18, 0.1e18, 0, 0), "RTM at the saturation boundary");

        // One wei above the boundary
        st = _bareState(300e18, 100e18, 0, 300e18, 40e18 + 1, 0.1e18, 0);
        assertEq(
            toUint256(accountant.maxJTWithdrawal(st)), RoycoTestMath.maxJTWithdrawal(300e18, 100e18, 40e18 + 1, 0.1e18, 0, 0), "RTM one wei above the boundary"
        );

        // Zero senior exposure: the pure formula off the junior raw NAV alone
        st = _bareState(0, 8e18, 0, 8e18, 8e18, 0.1e18, 0);
        assertEq(toUint256(accountant.maxJTWithdrawal(st)), RoycoTestMath.maxJTWithdrawal(0, 8e18, 8e18, 0.1e18, 0, 0), "RTM zero senior exposure");
    }

    /**
     * The coverage gate boundary on a NON-exact required value (RoycoDayAccountant.sol:392), where the inner
     * ceil of the coverage requirement rounds the fractional boundary up and the gross-up floor leaves a wei
     * of protocol-favoring slack on top.
     * Seed (1000e18 + 7, 200e18) flat, zero dust: required = ceil((1200e18 + 7) * 0.1) = 120e18 + 1 (the 0.7 wei
     * product remainder rounds up), surplus = 200e18 - (120e18 + 1) = 80e18 - 1, retention = 0.9e18,
     * y = floor((80e18 - 1) * 10 / 9).
     * The algebraic gate is 9 * jtEffectiveNAV' >= stRawNAV, so the minimum passing jtEffectiveNAV' is
     * ceil(stRawNAV / 9). Redeeming max lands one wei above it with coverageUtilization exactly WAD (ceil),
     * consuming the remaining slack down to the boundary stays at WAD, and one wei past it reads WAD + 1 and violates
     */
    function test_MaxJTWithdrawal_CeilRequiredGateBoundary() public {
        uint256 stRaw = 1000e18 + 7;
        _seedSymmetric(stRaw, 200e18, 100e18);

        NAV_UNIT jtW = accountant.maxJTWithdrawal(_checkpointState());
        assertEq(toUint256(jtW), RoycoTestMath.maxJTWithdrawal(stRaw, 200e18, 200e18, 0.1e18, 0, 0), "RTM parity");

        // Redeem exactly max: coverage utilization reads WAD by ceil
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(stRaw), toNAVUnits(200e18 - toUint256(jtW)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, true);
        assertEq(state.coverageUtilizationWAD, WAD, "the exact max lands coverage utilization on WAD");

        // Consume the remaining ceil slack down to the boundary ceil(stRawNAV / 9), retention 0.9 folds the 0.1
        // coverage into the /9
        uint256 minPassingJTEff = Math.ceilDiv(stRaw, 9);
        state = kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(stRaw), toNAVUnits(minPassingJTEff), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, true);
        assertEq(state.coverageUtilizationWAD, WAD, "the boundary jtEffectiveNAV still passes at WAD");

        // One wei past the boundary reads coverage utilization WAD + 1 and violates
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(stRaw), toNAVUnits(minPassingJTEff - 1), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, true);
    }

    /*//////////////////////////////////////////////////////////////////////
                    maxLTWithdrawal RTM PARITY AND GATE BOUNDARIES
    //////////////////////////////////////////////////////////////////////*/

    /**
     * Mirror parity across the closed form's branch set: the ceil'd required depth, the zero-requirement bypass,
     * coverage independence (the requirement holds even at and above the liquidation threshold), and saturation.
     * Required depth = ceil((600e18 + 11) * 0.03) = 18e18 + 1 (the 0.33 wei remainder rounds up):
     *   max = 40e18 - (18e18 + 1) = 22e18 - 1
     * minLiquidity 0 -> full 40e18. coverageUtilization at, above, and below the liquidation threshold all read 22e18 - 1.
     * ltRawNAV 10e18 < required -> saturates to 0
     */
    function test_MaxLTWithdrawal_matchesRTM_ceilCoverageIndependenceAndSaturation() public view {
        // Ceil'd required depth
        SyncedAccountingState memory st = _bareState(700e18, 100e18, 40e18, 600e18 + 11, 100e18, 0.1e18, 0.03e18);
        assertEq(toUint256(accountant.maxLTWithdrawal(st)), 22e18 - 1, "ceil'd required depth at the hand literal");
        assertEq(RoycoTestMath.maxLTWithdrawal(40e18, 600e18 + 11, 0.03e18, 0), 22e18 - 1, "RTM ceil case");

        // Zero-requirement bypass
        st.minLiquidityWAD = 0;
        assertEq(toUint256(accountant.maxLTWithdrawal(st)), 40e18, "no requirement leaves the full inventory withdrawable");
        assertEq(RoycoTestMath.maxLTWithdrawal(40e18, 600e18 + 11, 0, 0), 40e18, "RTM zero-requirement bypass");

        // Coverage independence: a breached liquidation threshold no longer unlocks the inventory, the requirement holds at all coverage levels
        st.minLiquidityWAD = 0.03e18;
        st.coverageLiquidationUtilizationWAD = 1.1e18;
        st.coverageUtilizationWAD = 1.1e18;
        assertEq(toUint256(accountant.maxLTWithdrawal(st)), 22e18 - 1, "the exact liquidation boundary stays requirement-restricted");
        st.coverageUtilizationWAD = type(uint256).max;
        assertEq(toUint256(accountant.maxLTWithdrawal(st)), 22e18 - 1, "a wipeout-grade utilization stays requirement-restricted");
        st.coverageUtilizationWAD = 1.1e18 - 1;
        assertEq(toUint256(accountant.maxLTWithdrawal(st)), 22e18 - 1, "one below the boundary reads identically");

        // Saturation
        st.coverageUtilizationWAD = 0;
        st.coverageLiquidationUtilizationWAD = type(uint256).max;
        st.ltRawNAV = toNAVUnits(uint256(10e18));
        assertEq(toUint256(accountant.maxLTWithdrawal(st)), 0, "under-provisioned inventory saturates to zero");
        assertEq(RoycoTestMath.maxLTWithdrawal(10e18, 600e18 + 11, 0.03e18, 0), 0, "RTM saturation");
    }

    /**
     * The LT-withdrawal gate boundary with a live ST dust tolerance (RoycoDayAccountant.sol:449-452) — the
     * dust folds into the senior NAV before the requirement scaling, and the reported max is exact against the
     * real post-op liquidity gate.
     * Seed 1000e18/200e18 flat with 100e18 of LT depth, stDust 3: required = ceil((1000e18 + 3) * 0.05) = 50e18 + 1,
     * max = 100e18 - (50e18 + 1) = 50e18 - 1.
     * Redeeming max leaves ltRawNAV = 50e18 + 1: liquidityUtilization = ceil(5e37 / (5e19 + 1)) = WAD (ceil absorbs the
     * shortfall). Consuming the 1 wei slack leaves ltRawNAV = 50e18 exactly on WAD, and one more wei computes
     * liquidityUtilization = WAD + 1 and violates
     */
    function test_MaxLTWithdrawal_STDustSlackGateBoundary() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stNAVDustTolerance = toNAVUnits(uint256(3));
        _deploy(p);
        _seedSymmetric(1000e18, 200e18, 100e18);

        NAV_UNIT max = accountant.maxLTWithdrawal(_checkpointState());
        assertEq(toUint256(max), 50e18 - 1, "closed form off the dust-padded required depth");
        // coverageUtilization at the flat seed = ceil((1000e18 + 200e18) * 0.1 / 200e18) = 0.6e18, below the 1.1e18 threshold: no bypass
        assertEq(RoycoTestMath.maxLTWithdrawal(100e18, 1000e18, 0.05e18, 3), toUint256(max), "RTM parity");

        // Redeem exactly the reported max
        SyncedAccountingState memory state = kernel.doPostOp(
            Operation.LT_REDEEM, toNAVUnits(uint256(1000e18)), toNAVUnits(uint256(200e18)), toNAVUnits(100e18 - toUint256(max)), ZERO_NAV_UNITS, true
        );
        assertEq(state.liquidityUtilizationWAD, WAD, "the exact max lands liquidity utilization on WAD via the ceil");
        // Consume the 1 wei of ceil slack, landing exactly on the algebraic boundary
        state =
            kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(uint256(1000e18)), toNAVUnits(uint256(200e18)), toNAVUnits(uint256(50e18)), ZERO_NAV_UNITS, true);
        assertEq(state.liquidityUtilizationWAD, WAD, "the slack consumed lands exactly on WAD");
        // One wei beyond max + slack violates the liquidity requirement
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(uint256(1000e18)), toNAVUnits(uint256(200e18)), toNAVUnits(uint256(50e18 - 1)), ZERO_NAV_UNITS, true);
    }

    /*//////////////////////////////////////////////////////////////////////
            CLOSED FORMS AND EXACT GATE BOUNDARIES (maxSTDeposit /
                    maxJTWithdrawal / maxLTWithdrawal)
    //////////////////////////////////////////////////////////////////////*/

    /**
     * with a zero minimum liquidity the result is the coverage leg alone:
     * floor(jtEffectiveNAV * WAD / minCoverage) - (jtRawNAV + jtDust + stRawNAV + stDust)
     * Derivation: floor(200e18 * 1e18 / 0.1e18) = 2000e18, minus (500e18 + 7 + 1000e18 + 3) = 500e18 - 10
     */
    function test_MaxSTDeposit_coverageLegExactWithDustTolerances() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stNAVDustTolerance = toNAVUnits(uint256(3));
        p.jtNAVDustTolerance = toNAVUnits(uint256(7));
        _deploy(p);
        SyncedAccountingState memory st = _bareState(1000e18, 500e18, 0, 1000e18, 200e18, 0.1e18, 0);
        assertEq(toUint256(accountant.maxSTDeposit(st)), 500e18 - 10, "coverage leg subtracts the junior raw NAV and both dust terms");
    }

    /**
     * with a zero minimum coverage the result is the liquidity leg alone:
     * floor(ltRawNAV * WAD / minLiquidity) - (stEffectiveNAV + stDust)
     * Derivation with zero dust: floor(123e18 * 1e18 / 0.05e18) = 2460e18, minus (1000e18 + 7) = 1460e18 - 7
     */
    function test_MaxSTDeposit_liquidityLegExactWhenMinCoverageZero() public view {
        SyncedAccountingState memory st = _bareState(900e18, 200e18, 123e18, 1000e18 + 7, 200e18, 0, 0.05e18);
        assertEq(toUint256(accountant.maxSTDeposit(st)), 1460e18 - 7, "liquidity leg exact against the senior effective NAV");
    }

    /// each leg saturates to zero instead of underflowing when the requirement already binds
    function test_MaxSTDeposit_legsSaturateToZero() public view {
        // Coverage leg: the junior buffer covers only 500e18 against a 1000e18 senior raw NAV
        SyncedAccountingState memory covBound = _bareState(1000e18, 0, 0, 1000e18, 50e18, 0.1e18, 0);
        assertEq(toUint256(accountant.maxSTDeposit(covBound)), 0, "over-deployed coverage saturates to zero");
        // Liquidity leg: the inventory supports only 100e18 of senior value against a live 1000e18
        SyncedAccountingState memory liqBound = _bareState(1000e18, 0, 10e18, 1000e18, 200e18, 0, 0.1e18);
        assertEq(toUint256(accountant.maxSTDeposit(liqBound)), 0, "over-deployed liquidity saturates to zero");
    }

    /**
     * the result is the minimum of the two legs, exercised in both directions
     * Derivation: the coverage leg is 2000e18 - 1000e18 = 1000e18 in both states, while the liquidity leg is
     * floor(80e18 / 0.05) - 1000e18 = 600e18 in the first and floor(200e18 / 0.05) - 1000e18 = 3000e18 in the second
     */
    function test_MaxSTDeposit_returnsMinOfBothLegs() public view {
        SyncedAccountingState memory liquidityBinds = _bareState(1000e18, 0, 80e18, 1000e18, 200e18, 0.1e18, 0.05e18);
        assertEq(toUint256(accountant.maxSTDeposit(liquidityBinds)), 600e18, "liquidity leg binds");
        SyncedAccountingState memory coverageBinds = _bareState(1000e18, 0, 200e18, 1000e18, 200e18, 0.1e18, 0.05e18);
        assertEq(toUint256(accountant.maxSTDeposit(coverageBinds)), 1000e18, "coverage leg binds");
    }

    /**
     * the coverage-binding gate boundary with zero dust — depositing exactly maxSTDeposit passes the enforced
     * gates landing coverage utilization exactly on WAD, and one more wei violates
     * Legs at the seed: coverage = floor(200e18 * 1e18 / 0.1e18) - (200e18 + 1000e18) = 800e18 and
     * liquidity = floor(1000e18 * 1e18 / 0.05e18) - 1000e18 = 19000e18, so coverage binds with zero slack
     */
    function test_MaxSTDeposit_CoverageBindingExactGateBoundary() public {
        _seedFlatWithLT(1000e18);
        NAV_UNIT max = accountant.maxSTDeposit(_checkpointState());
        assertEq(toUint256(max), 800e18, "coverage leg binds at the independently derived value");
        SyncedAccountingState memory state = kernel.doPostOp(
            Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + toUint256(max)), toNAVUnits(SEED_JT_RAW), toNAVUnits(uint256(1000e18)), ZERO_NAV_UNITS, true
        );
        assertEq(state.coverageUtilizationWAD, WAD, "the exact max lands coverage utilization on WAD");
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(
            Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + toUint256(max) + 1), toNAVUnits(SEED_JT_RAW), toNAVUnits(uint256(1000e18)), ZERO_NAV_UNITS, true
        );
    }

    /**
     * the liquidity-binding gate boundary with zero dust — the exact max lands liquidity utilization on WAD and
     * one more wei violates the liquidity requirement
     * Legs at the seed: coverage = floor(300e18 / 0.1) - (300e18 + 1000e18) = 1700e18 and liquidity =
     * floor(100e18 / 0.05) - 1000e18 = 1000e18, so liquidity binds with zero slack
     */
    function test_MaxSTDeposit_LiquidityBindingExactGateBoundary() public {
        _seedState(SEED_ST_RAW, 300e18, SEED_ST_RAW, 300e18, 0, 100e18, MarketState.PERPETUAL);
        NAV_UNIT max = accountant.maxSTDeposit(_checkpointState());
        assertEq(toUint256(max), 1000e18, "liquidity leg binds at the independently derived value");
        SyncedAccountingState memory state = kernel.doPostOp(
            Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + toUint256(max)), toNAVUnits(uint256(300e18)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, true
        );
        assertEq(state.liquidityUtilizationWAD, WAD, "the exact max lands liquidity utilization on WAD");
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(
            Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + toUint256(max) + 1), toNAVUnits(uint256(300e18)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, true
        );
    }

    /**
     * the dust slack boundary — with st dust 3 and jt dust 7 the reported max under-shoots the true
     * coverage boundary by exactly the 10 wei slack, so max passes, max + slack still passes (landing exactly
     * on WAD), and max + slack + 1 violates
     */
    function test_MaxSTDeposit_DustSlackExactGateBoundary() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stNAVDustTolerance = toNAVUnits(uint256(3));
        p.jtNAVDustTolerance = toNAVUnits(uint256(7));
        _deploy(p);
        _seedFlatWithLT(1000e18);
        NAV_UNIT max = accountant.maxSTDeposit(_checkpointState());
        assertEq(toUint256(max), 800e18 - 10, "coverage leg minus the combined dust slack");
        // Deposit exactly the reported max
        kernel.doPostOp(
            Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + toUint256(max)), toNAVUnits(SEED_JT_RAW), toNAVUnits(uint256(1000e18)), ZERO_NAV_UNITS, true
        );
        // Consume the 10 wei dust slack, landing coverage utilization exactly on WAD
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(1800e18)), toNAVUnits(SEED_JT_RAW), toNAVUnits(uint256(1000e18)), ZERO_NAV_UNITS, true);
        assertEq(state.coverageUtilizationWAD, WAD, "the slack consumed lands exactly on WAD");
        // One wei beyond max + slack violates
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(1800e18 + 1)), toNAVUnits(SEED_JT_RAW), toNAVUnits(uint256(1000e18)), ZERO_NAV_UNITS, true);
    }

    /**
     * the flat-market closed form with zero dust, surplus = jtEffectiveNAV - ceil((stRawNAV + jtRawNAV) * minCoverage / WAD),
     * grossed up by the coverage retention (WAD - minCoverage) to y = floor(surplus * WAD / (WAD - minCoverage))
     * Derivation: required = ceil(1200e18 * 0.1) = 120e18, surplus = 200e18 - 120e18 = 80e18, y = floor(80e18 * 10 / 9)
     */
    function test_MaxJTWithdrawal_flatMarketClosedForm() public view {
        SyncedAccountingState memory st = _bareState(1000e18, 200e18, 100e18, 1000e18, 200e18, 0.1e18, DEFAULT_MIN_LIQUIDITY_WAD);
        NAV_UNIT jtW = accountant.maxJTWithdrawal(st);
        assertEq(toUint256(jtW), RoycoTestMath.maxJTWithdrawal(1000e18, 200e18, 200e18, 0.1e18, 0, 0), "RTM parity");
    }

    /**
     * both dust tolerances fold into the requirement's ceil before the retention gross-up
     * Derivation: required = ceil((1200e18 + 3 + 7) * 0.1) = 120e18 + 1 (the 1 wei product remainder rounds up),
     * surplus = 200e18 - (120e18 + 1) = 80e18 - 1, retention = WAD - minCoverage = 0.9e18,
     * y = floor((80e18 - 1) * 1e18 / 0.9e18)
     */
    function test_MaxJTWithdrawal_dustTolerancesFoldIntoTheSurplus() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stNAVDustTolerance = toNAVUnits(uint256(3));
        p.jtNAVDustTolerance = toNAVUnits(uint256(7));
        _deploy(p);
        SyncedAccountingState memory st = _bareState(1000e18, 200e18, 0, 1000e18, 200e18, 0.1e18, 0);
        NAV_UNIT jtW = accountant.maxJTWithdrawal(st);
        assertEq(toUint256(jtW), RoycoTestMath.maxJTWithdrawal(1000e18, 200e18, 200e18, 0.1e18, 3, 7), "RTM parity with both dust tolerances folded into the requirement");
    }

    /**
     * the coverage gate boundary on an exactly-divisible required value, redeeming exactly maxJTWithdrawal lands
     * coverage utilization exactly on WAD (the minimum passing buffer, zero slack), and the next wei is the
     * first to violate.
     * Arithmetic: required = ceil(1200e18 * 0.1) = 120e18 divides exactly, surplus = 200e18 - 120e18 = 80e18,
     * y = floor(80e18 * 10 / 9).
     * The gate is 9 * jtEffectiveNAV' >= SEED_ST_RAW with minimum passing jtEffectiveNAV' = ceil(SEED_ST_RAW / 9),
     * and max leaves jtEffectiveNAV' exactly on it, so SEED_JT_RAW - jtW - 1 is the first violating buffer
     */
    function test_MaxJTWithdrawal_FlatMarketExactGateBoundary() public {
        _seedFlatWithLT(SEED_LT_RAW);
        NAV_UNIT jtW = accountant.maxJTWithdrawal(_checkpointState());
        assertEq(toUint256(jtW), RoycoTestMath.maxJTWithdrawal(SEED_ST_RAW, SEED_JT_RAW, SEED_JT_RAW, 0.1e18, 0, 0), "RTM parity");
        SyncedAccountingState memory state = kernel.doPostOp(
            Operation.JT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW - toUint256(jtW)), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, true
        );
        assertEq(state.coverageUtilizationWAD, WAD, "the exact max lands coverage utilization on WAD");
        // One wei beyond max crosses the boundary ceil(SEED_ST_RAW / 9) and violates
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(
            Operation.JT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW - toUint256(jtW) - 1), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, true
        );
    }

    /**
     * the cross-claim gate boundary. Redeeming exactly maxJTWithdrawal off a JT-cross-claim checkpoint clears
     * the enforced coverage gate, and a further 1000 wei violates.
     * Slack anatomy for this vector is a few wei of compounded mulDiv floors in the surplus gross-up, so the
     * probe uses a 1000 wei margin to land clear of the boundary
     */
    function test_MaxJTWithdrawal_CrossClaimGateBoundary() public {
        _seedState(1000e18, 200e18, 980e18, 220e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        NAV_UNIT jtW = accountant.maxJTWithdrawal(_checkpointState());
        assertEq(toUint256(jtW), RoycoTestMath.maxJTWithdrawal(1000e18, 200e18, 220e18, 0.1e18, 0, 0), "RTM parity");
        SyncedAccountingState memory state = kernel.doPostOp(
            Operation.JT_REDEEM, toNAVUnits(uint256(1000e18)), toNAVUnits(200e18 - toUint256(jtW)), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, true
        );
        assertLe(state.coverageUtilizationWAD, WAD, "the exact cross-claim max clears the enforced coverage gate");
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(
            Operation.JT_REDEEM, toNAVUnits(uint256(1000e18)), toNAVUnits(200e18 - toUint256(jtW) - 1000), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, true
        );
    }

    /**
     * the liquidity requirement holds at every coverage level: a coverage utilization at the liquidation
     * threshold, past it at the uint256 max wipeout reading, and just below it all report the same restricted
     * surplus, since the withdrawal bound no longer reads coverage
     * required = ceil(1000e18 * 0.05) = 50e18, so max = 100e18 - 50e18 = 50e18 regardless of coverage
     */
    function test_MaxLTWithdrawal_enforcedRegardlessOfLiquidationBoundary() public view {
        SyncedAccountingState memory st = _bareState(1000e18, 200e18, 100e18, 1000e18, 200e18, 0.1e18, 0.05e18);
        st.coverageLiquidationUtilizationWAD = DEFAULT_LIQUIDATION_UTILIZATION_WAD;
        st.coverageUtilizationWAD = DEFAULT_LIQUIDATION_UTILIZATION_WAD;
        assertEq(toUint256(accountant.maxLTWithdrawal(st)), 50e18, "the exact liquidation boundary stays requirement-restricted");
        st.coverageUtilizationWAD = type(uint256).max;
        assertEq(toUint256(accountant.maxLTWithdrawal(st)), 50e18, "a wipeout-grade utilization stays requirement-restricted");
        st.coverageUtilizationWAD = DEFAULT_LIQUIDATION_UTILIZATION_WAD - 1;
        assertEq(toUint256(accountant.maxLTWithdrawal(st)), 50e18, "one below the boundary reads identically");
    }

    /**
     * the closed form ceils the required depth and saturates to zero
     * Derivation: required = ceil((1000e18 + 7) * 0.05e18 / 1e18) = 50e18 + 1 (the 0.35 wei product remainder
     * rounds up), so 100e18 of inventory leaves 50e18 - 1 withdrawable, an inventory of 40e18 saturates to
     * zero, and an st dust of 100 folds into the senior NAV before scaling: required = ceil((1000e18 + 107) * 0.05)
     * = 50e18 + 6, shrinking the withdrawable to 50e18 - 6
     */
    function test_MaxLTWithdrawal_closedFormCeilAndSaturation() public {
        SyncedAccountingState memory st = _bareState(1000e18, 200e18, 100e18, 1000e18 + 7, 200e18, 0.1e18, 0.05e18);
        assertEq(toUint256(accountant.maxLTWithdrawal(st)), 50e18 - 1, "inner ceil rounds the required depth up");
        st.ltRawNAV = toNAVUnits(uint256(40e18));
        assertEq(toUint256(accountant.maxLTWithdrawal(st)), 0, "under-provisioned inventory saturates to zero");
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stNAVDustTolerance = toNAVUnits(uint256(100));
        _deploy(p);
        st.ltRawNAV = toNAVUnits(uint256(100e18));
        assertEq(toUint256(accountant.maxLTWithdrawal(st)), 50e18 - 6, "st dust tolerance shrinks the withdrawable depth");
    }

    /**
     * the exact boundary of the LT_REDEEM liquidity gate — redeeming exactly maxLTWithdrawal passes with
     * enforcement landing liquidity utilization exactly on WAD, and one more wei violates
     * Derivation: max = 100e18 - ceil(1000e18 * 0.05e18 / 1e18) = 50e18 with zero dust
     */
    function test_MaxLTWithdrawal_ExactGateBoundary() public {
        _seedFlatWithLT(SEED_LT_RAW);
        NAV_UNIT max = accountant.maxLTWithdrawal(_checkpointState());
        assertEq(toUint256(max), 50e18, "closed form at the flat seed");
        SyncedAccountingState memory state = kernel.doPostOp(
            Operation.LT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW - toUint256(max)), ZERO_NAV_UNITS, true
        );
        assertEq(state.liquidityUtilizationWAD, WAD, "the exact max lands liquidity utilization on WAD");
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(
            Operation.LT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW - toUint256(max) - 1), ZERO_NAV_UNITS, true
        );
    }
}
