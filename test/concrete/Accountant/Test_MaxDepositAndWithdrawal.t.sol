// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { MAX_NAV_UNITS, WAD, ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { Operation, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { AccountantTestBase } from "../../utils/AccountantTestBase.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";

/**
 * @title Test_MaxDepositAndWithdrawal_Accountant
 * @notice Hand-derived scenarios for the maxSTDeposit / maxJTWithdrawal / maxLTWithdrawal closed forms over the
 *         single collateral NAV and the single dust tolerance, cross-asserted against the independent
 *         RoycoTestMath mirrors, plus the exact gate-boundary probes the sync suite does not cover — the
 *         liquidity-binding deposit with a dust slack, the JT-withdrawal gate boundary on a non-exact ceil'd
 *         required value, and the LT-withdrawal dust slack boundary
 * @dev Existing coverage NOT duplicated here: the zero-dust coverage-binding and liquidity-binding
 *      maxSTDeposit gate boundaries, the coverage-side dust-slack boundary, the flat-market maxJTWithdrawal
 *      gate boundary on an exactly-divisible required value, the non-flat-seed probe, and the
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
     * Case 1 (coverage binds): coverage = floor(120e18 / 0.15) - (600e18 + 0) = 200e18,
     *   liquidity = floor(60e18 / 0.08) - (480e18 + 0) = 270e18 -> min = 200e18
     * Case 2 (minCoverage 0 disables the coverage leg): max = liquidity leg = 270e18
     * Case 3 (minLiquidity 0 disables the liquidity leg): max = coverage leg = 200e18
     * Case 4 (both 0): MAX_NAV_UNITS
     * Case 5 (saturation): coverage = floor(50e18 / 0.2) - 800e18 = 250e18 - 800e18 -> 0
     */
    function test_MaxSTDeposit_matchesRTM_bothLegsDisableEdgesAndSaturation() public view {
        // Case 1 — both legs live, coverage binds
        SyncedAccountingState memory st = _bareState(600e18, 60e18, 480e18, 120e18, 0.15e18, 0.08e18);
        assertEq(toUint256(accountant.maxSTDeposit(st)), 200e18, "coverage leg binds at the hand literal");
        assertEq(RoycoTestMath.maxSTDeposit(600e18, 480e18, 120e18, 60e18, 0.15e18, 0.08e18, 0), 200e18, "RTM case 1");

        // Case 2 — coverage leg disabled
        st = _bareState(600e18, 60e18, 480e18, 120e18, 0, 0.08e18);
        assertEq(toUint256(accountant.maxSTDeposit(st)), 270e18, "liquidity leg alone at the hand literal");
        assertEq(RoycoTestMath.maxSTDeposit(600e18, 480e18, 120e18, 60e18, 0, 0.08e18, 0), 270e18, "RTM case 2");

        // Case 3 — liquidity leg disabled
        st = _bareState(600e18, 60e18, 480e18, 120e18, 0.15e18, 0);
        assertEq(toUint256(accountant.maxSTDeposit(st)), 200e18, "coverage leg alone at the hand literal");
        assertEq(RoycoTestMath.maxSTDeposit(600e18, 480e18, 120e18, 60e18, 0.15e18, 0, 0), 200e18, "RTM case 3");

        // Case 4 — both requirements zero leaves capacity unbounded
        st = _bareState(600e18, 60e18, 480e18, 120e18, 0, 0);
        assertEq(toUint256(accountant.maxSTDeposit(st)), toUint256(MAX_NAV_UNITS), "no requirement leaves capacity unbounded");
        assertEq(RoycoTestMath.maxSTDeposit(600e18, 480e18, 120e18, 60e18, 0, 0, 0), type(uint256).max, "RTM case 4");

        // Case 5 — over-deployed coverage saturates to zero
        st = _bareState(800e18, 40e18, 750e18, 50e18, 0.2e18, 0.04e18);
        assertEq(toUint256(accountant.maxSTDeposit(st)), 0, "over-deployed coverage saturates to zero");
        assertEq(RoycoTestMath.maxSTDeposit(800e18, 750e18, 50e18, 40e18, 0.2e18, 0.04e18, 0), 0, "RTM case 5");
    }

    /**
     * Mirror parity with a live dust tolerance of 10.
     * Coverage leg = floor(200e18 / 0.1) - (1100e18 + 10) = 900e18 - 10,
     * liquidity leg = floor(100e18 / 0.05) - (900e18 + 10) = 1100e18 - 10 -> coverage binds at 900e18 - 10
     */
    function test_MaxSTDeposit_matchesRTM_withDustTolerance() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.dustTolerance = toNAVUnits(uint256(10));
        _deploy(p);
        SyncedAccountingState memory st = _bareState(1100e18, 100e18, 900e18, 200e18, 0.1e18, 0.05e18);
        assertEq(toUint256(accountant.maxSTDeposit(st)), 900e18 - 10, "coverage leg minus the dust term binds");
        assertEq(RoycoTestMath.maxSTDeposit(1100e18, 900e18, 200e18, 100e18, 0.1e18, 0.05e18, 10), 900e18 - 10, "RTM dusted case");
    }

    /**
     * The liquidity-binding gate boundary with a live dust tolerance — the slack on the liquidity leg is the
     * single dustTolerance, and the reported max is exact against the real gate.
     * Seed 1000e18/300e18 flat (collateral 1300e18) with 100e18 of LT depth, dust 10:
     *   coverage leg = floor(300e18 / 0.1) - (1300e18 + 10) = 1700e18 - 10
     *   liquidity leg = floor(100e18 / 0.05) - (1000e18 + 10) = 1000e18 - 10 -> liquidity binds
     * Depositing max lands stEffectiveNAV = 2000e18 - 10: liquidityUtilization = ceil((2000e18 - 10) * 0.05 / 100e18) = WAD (the ceil
     * absorbs the 0.5 wei shortfall). Consuming the 10 wei slack lands stEffectiveNAV = 2000e18 exactly on WAD, and one
     * more wei violates the liquidity requirement
     */
    function test_MaxSTDeposit_LiquidityBindingWithDustSlackGateBoundary() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.dustTolerance = toNAVUnits(uint256(10));
        _deploy(p);
        _seedSymmetric(1000e18, 300e18, 100e18);

        NAV_UNIT max = accountant.maxSTDeposit(_checkpointState());
        assertEq(toUint256(max), 1000e18 - 10, "liquidity leg binds at the independently derived value");
        assertEq(RoycoTestMath.maxSTDeposit(1300e18, 1000e18, 300e18, 100e18, 0.1e18, 0.05e18, 10), toUint256(max), "RTM parity");

        // Deposit exactly the reported max: the post-op liquidity utilization already reads WAD by ceil
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(1300e18) + toUint256(max)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, true);
        assertEq(state.liquidityUtilizationWAD, WAD, "the exact max lands liquidity utilization on WAD via the ceil");
        // Consume the 10 wei dust slack, landing exactly on the algebraic boundary
        state = kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(2300e18)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, true);
        assertEq(state.liquidityUtilizationWAD, WAD, "the slack consumed lands exactly on WAD");
        // One wei beyond max + slack violates the liquidity requirement
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(2300e18 + 1)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, true);
    }

    /*//////////////////////////////////////////////////////////////////////
                    maxJTWithdrawal RTM PARITY AND GATE BOUNDARIES
    //////////////////////////////////////////////////////////////////////*/

    /**
     * A coverage-shifted claim state (jtEffectiveNAV above the flat split because coverage repayments moved
     * claim from senior to junior), cross-checked against the independent mirror.
     * State (collateralNAV 1200e18, stEffectiveNAV 980e18, jtEffectiveNAV 220e18, minCoverage 0.1):
     * required = ceil(1200e18 * 0.1) = 120e18, surplus = sat(220e18 - 120e18) = 100e18,
     * y = floor(100e18 * WAD / (WAD - 0.1e18)) = floor(1000e18 / 9) = 111111111111111111111
     */
    function test_MaxJTWithdrawal_matchesRTM_coverageShiftedClaim() public view {
        SyncedAccountingState memory st = _bareState(1200e18, 100e18, 980e18, 220e18, 0.1e18, 0.05e18);
        NAV_UNIT jtW = accountant.maxJTWithdrawal(st);
        assertEq(toUint256(jtW), 111_111_111_111_111_111_111, "hand literal off the retention gross-up");
        assertEq(toUint256(jtW), RoycoTestMath.maxJTWithdrawal(1200e18, 220e18, 0.1e18, 0), "RTM parity");
    }

    /**
     * The surplus saturation boundary of the closed form, plus the pure formula on a zero-senior-claim
     * input, each cross-checked against the independent mirror across the settled branch set.
     * Saturation boundary: collateralNAV 400e18 puts required = ceil(400e18 * 0.1) = 40e18, so
     * jtEffectiveNAV = 40e18 saturates the surplus to zero, and jtEffectiveNAV = 40e18 + 1 leaves surplus 1
     * grossing up to floor(1 * 10 / 9) = 1.
     * Zero senior claim: (collateralNAV 8e18, stEffectiveNAV 0, jtEffectiveNAV 8e18) has required =
     * ceil(8e18 * 0.1) = 8e17, surplus = 8e18 - 8e17 = 7.2e18, y = floor(7.2e18 * 10 / 9) = 8e18
     */
    function test_MaxJTWithdrawal_matchesRTM_earlyOutBoundaries() public view {
        // Exactly at the surplus saturation boundary
        SyncedAccountingState memory st = _bareState(400e18, 0, 360e18, 40e18, 0.1e18, 0);
        assertEq(toUint256(accountant.maxJTWithdrawal(st)), 0, "saturated surplus at the hand literal");
        assertEq(toUint256(accountant.maxJTWithdrawal(st)), RoycoTestMath.maxJTWithdrawal(400e18, 40e18, 0.1e18, 0), "RTM at the saturation boundary");

        // One wei above the boundary
        st = _bareState(400e18, 0, 360e18, 40e18 + 1, 0.1e18, 0);
        assertEq(toUint256(accountant.maxJTWithdrawal(st)), 1, "one wei of surplus at the hand literal");
        assertEq(toUint256(accountant.maxJTWithdrawal(st)), RoycoTestMath.maxJTWithdrawal(400e18, 40e18 + 1, 0.1e18, 0), "RTM one wei above the boundary");

        // Zero senior claim: the pure formula off the junior buffer alone
        st = _bareState(8e18, 0, 0, 8e18, 0.1e18, 0);
        assertEq(toUint256(accountant.maxJTWithdrawal(st)), 8e18, "zero senior claim at the hand literal");
        assertEq(toUint256(accountant.maxJTWithdrawal(st)), RoycoTestMath.maxJTWithdrawal(8e18, 8e18, 0.1e18, 0), "RTM zero senior claim");
    }

    /**
     * The coverage gate boundary on a NON-exact required value, where the inner ceil of the coverage
     * requirement rounds the fractional boundary up and the gross-up floor leaves a wei of
     * protocol-favoring slack on top.
     * Seed (1000e18 + 7, 200e18) flat (collateral 1200e18 + 7), zero dust: required = ceil((1200e18 + 7) * 0.1)
     * = 120e18 + 1 (the 0.7 wei product remainder rounds up), surplus = 200e18 - (120e18 + 1) = 80e18 - 1,
     * retention = 0.9e18, y = floor((80e18 - 1) * 10 / 9) = 88888888888888888887.
     * The algebraic gate is 9 * jtEffectiveNAV' >= stEffectiveNAV, so the minimum passing jtEffectiveNAV' is
     * ceil(stEffectiveNAV / 9). Redeeming max lands one wei above it with coverageUtilization exactly WAD (ceil),
     * consuming the remaining slack down to the boundary stays at WAD, and one wei past it reads WAD + 1 and violates
     */
    function test_MaxJTWithdrawal_CeilRequiredGateBoundary() public {
        uint256 stEff = 1000e18 + 7;
        _seedSymmetric(stEff, 200e18, 100e18);

        NAV_UNIT jtW = accountant.maxJTWithdrawal(_checkpointState());
        assertEq(toUint256(jtW), 88_888_888_888_888_888_887, "hand literal off the ceil'd requirement");
        assertEq(toUint256(jtW), RoycoTestMath.maxJTWithdrawal(stEff + 200e18, 200e18, 0.1e18, 0), "RTM parity");

        // Redeem exactly max: coverage utilization reads WAD by ceil
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(stEff + 200e18 - toUint256(jtW)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, true);
        assertEq(state.coverageUtilizationWAD, WAD, "the exact max lands coverage utilization on WAD");

        // Consume the remaining ceil slack down to the boundary ceil(stEffectiveNAV / 9), retention 0.9 folds the 0.1
        // coverage into the /9
        uint256 minPassingJTEff = Math.ceilDiv(stEff, 9);
        state = kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(stEff + minPassingJTEff), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, true);
        assertEq(state.coverageUtilizationWAD, WAD, "the boundary jtEffectiveNAV still passes at WAD");

        // One wei past the boundary reads coverage utilization WAD + 1 and violates
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(stEff + minPassingJTEff - 1), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, true);
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
        SyncedAccountingState memory st = _bareState(700e18 + 11, 40e18, 600e18 + 11, 100e18, 0.1e18, 0.03e18);
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
     * The LT-withdrawal gate boundary with a live dust tolerance — the dust folds into the senior NAV before
     * the requirement scaling, and the reported max is exact against the real post-op liquidity gate.
     * Seed 1000e18/200e18 flat with 100e18 of LT depth, dust 3: required = ceil((1000e18 + 3) * 0.05) = 50e18 + 1,
     * max = 100e18 - (50e18 + 1) = 50e18 - 1.
     * Redeeming max leaves ltRawNAV = 50e18 + 1: liquidityUtilization = ceil(5e37 / (5e19 + 1)) = WAD (ceil absorbs the
     * shortfall). Consuming the 1 wei slack leaves ltRawNAV = 50e18 exactly on WAD, and one more wei computes
     * liquidityUtilization = WAD + 1 and violates
     */
    function test_MaxLTWithdrawal_DustSlackGateBoundary() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.dustTolerance = toNAVUnits(uint256(3));
        _deploy(p);
        _seedSymmetric(1000e18, 200e18, 100e18);

        NAV_UNIT max = accountant.maxLTWithdrawal(_checkpointState());
        assertEq(toUint256(max), 50e18 - 1, "closed form off the dust-padded required depth");
        // coverageUtilization at the flat seed = ceil(1200e18 * 0.1 / 200e18) = 0.6e18, below the 1.1e18 threshold: no bypass
        assertEq(RoycoTestMath.maxLTWithdrawal(100e18, 1000e18, 0.05e18, 3), toUint256(max), "RTM parity");

        // Redeem exactly the reported max
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(uint256(1200e18)), toNAVUnits(100e18 - toUint256(max)), ZERO_NAV_UNITS, true);
        assertEq(state.liquidityUtilizationWAD, WAD, "the exact max lands liquidity utilization on WAD via the ceil");
        // Consume the 1 wei of ceil slack, landing exactly on the algebraic boundary
        state = kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(uint256(1200e18)), toNAVUnits(uint256(50e18)), ZERO_NAV_UNITS, true);
        assertEq(state.liquidityUtilizationWAD, WAD, "the slack consumed lands exactly on WAD");
        // One wei beyond max + slack violates the liquidity requirement
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(uint256(1200e18)), toNAVUnits(uint256(50e18 - 1)), ZERO_NAV_UNITS, true);
    }

    /*//////////////////////////////////////////////////////////////////////
            CLOSED FORMS AND EXACT GATE BOUNDARIES (maxSTDeposit /
                    maxJTWithdrawal / maxLTWithdrawal)
    //////////////////////////////////////////////////////////////////////*/

    /**
     * with a zero minimum liquidity the result is the coverage leg alone:
     * floor(jtEffectiveNAV * WAD / minCoverage) - (collateralNAV + dustTolerance)
     * Derivation: floor(200e18 * 1e18 / 0.1e18) = 2000e18, minus (1200e18 + 10) = 800e18 - 10
     */
    function test_MaxSTDeposit_coverageLegExactWithDustTolerance() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.dustTolerance = toNAVUnits(uint256(10));
        _deploy(p);
        SyncedAccountingState memory st = _bareState(1200e18, 0, 1000e18, 200e18, 0.1e18, 0);
        assertEq(toUint256(accountant.maxSTDeposit(st)), 800e18 - 10, "coverage leg subtracts the whole collateral NAV and the dust");
    }

    /**
     * with a zero minimum coverage the result is the liquidity leg alone:
     * floor(ltRawNAV * WAD / minLiquidity) - (stEffectiveNAV + dustTolerance)
     * Derivation with zero dust: floor(123e18 * 1e18 / 0.05e18) = 2460e18, minus (1000e18 + 7) = 1460e18 - 7
     */
    function test_MaxSTDeposit_liquidityLegExactWhenMinCoverageZero() public view {
        SyncedAccountingState memory st = _bareState(1200e18 + 7, 123e18, 1000e18 + 7, 200e18, 0, 0.05e18);
        assertEq(toUint256(accountant.maxSTDeposit(st)), 1460e18 - 7, "liquidity leg exact against the senior effective NAV");
    }

    /// each leg saturates to zero instead of underflowing when the requirement already binds
    function test_MaxSTDeposit_legsSaturateToZero() public view {
        // Coverage leg: the junior buffer covers only 500e18 against a 1050e18 collateral NAV
        SyncedAccountingState memory covBound = _bareState(1050e18, 0, 1000e18, 50e18, 0.1e18, 0);
        assertEq(toUint256(accountant.maxSTDeposit(covBound)), 0, "over-deployed coverage saturates to zero");
        // Liquidity leg: the inventory supports only 100e18 of senior value against a live 1000e18
        SyncedAccountingState memory liqBound = _bareState(1200e18, 10e18, 1000e18, 200e18, 0, 0.1e18);
        assertEq(toUint256(accountant.maxSTDeposit(liqBound)), 0, "over-deployed liquidity saturates to zero");
    }

    /**
     * the result is the minimum of the two legs, exercised in both directions
     * Derivation: the coverage leg is 2000e18 - 1200e18 = 800e18 in both states, while the liquidity leg is
     * floor(80e18 / 0.05) - 1000e18 = 600e18 in the first and floor(200e18 / 0.05) - 1000e18 = 3000e18 in the second
     */
    function test_MaxSTDeposit_returnsMinOfBothLegs() public view {
        SyncedAccountingState memory liquidityBinds = _bareState(1200e18, 80e18, 1000e18, 200e18, 0.1e18, 0.05e18);
        assertEq(toUint256(accountant.maxSTDeposit(liquidityBinds)), 600e18, "liquidity leg binds");
        SyncedAccountingState memory coverageBinds = _bareState(1200e18, 200e18, 1000e18, 200e18, 0.1e18, 0.05e18);
        assertEq(toUint256(accountant.maxSTDeposit(coverageBinds)), 800e18, "coverage leg binds");
    }

    /**
     * the coverage-binding gate boundary with zero dust — depositing exactly maxSTDeposit passes the enforced
     * gates landing coverage utilization exactly on WAD, and one more wei violates
     * Legs at the seed: coverage = floor(200e18 * 1e18 / 0.1e18) - 1200e18 = 800e18 and
     * liquidity = floor(1000e18 * 1e18 / 0.05e18) - 1000e18 = 19000e18, so coverage binds with zero slack
     */
    function test_MaxSTDeposit_CoverageBindingExactGateBoundary() public {
        _seedFlatWithLT(1000e18);
        NAV_UNIT max = accountant.maxSTDeposit(_checkpointState());
        assertEq(toUint256(max), 800e18, "coverage leg binds at the independently derived value");
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_EFF + SEED_JT_EFF + toUint256(max)), toNAVUnits(uint256(1000e18)), ZERO_NAV_UNITS, true);
        assertEq(state.coverageUtilizationWAD, WAD, "the exact max lands coverage utilization on WAD");
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_EFF + SEED_JT_EFF + toUint256(max) + 1), toNAVUnits(uint256(1000e18)), ZERO_NAV_UNITS, true);
    }

    /**
     * the liquidity-binding gate boundary with zero dust — the exact max lands liquidity utilization on WAD and
     * one more wei violates the liquidity requirement
     * Legs at the seed (collateral 1300e18): coverage = floor(300e18 / 0.1) - 1300e18 = 1700e18 and liquidity =
     * floor(100e18 / 0.05) - 1000e18 = 1000e18, so liquidity binds with zero slack
     */
    function test_MaxSTDeposit_LiquidityBindingExactGateBoundary() public {
        _seedSymmetric(1000e18, 300e18, 100e18);
        NAV_UNIT max = accountant.maxSTDeposit(_checkpointState());
        assertEq(toUint256(max), 1000e18, "liquidity leg binds at the independently derived value");
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(1300e18 + toUint256(max)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, true);
        assertEq(state.liquidityUtilizationWAD, WAD, "the exact max lands liquidity utilization on WAD");
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(1300e18 + toUint256(max) + 1), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, true);
    }

    /**
     * the dust slack boundary — with dust 10 the reported max under-shoots the true coverage boundary by
     * exactly the 10 wei slack, so max passes, max + slack still passes (landing exactly on WAD), and
     * max + slack + 1 violates
     */
    function test_MaxSTDeposit_DustSlackExactGateBoundary() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.dustTolerance = toNAVUnits(uint256(10));
        _deploy(p);
        _seedFlatWithLT(1000e18);
        NAV_UNIT max = accountant.maxSTDeposit(_checkpointState());
        assertEq(toUint256(max), 800e18 - 10, "coverage leg minus the dust slack");
        // Deposit exactly the reported max
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_EFF + SEED_JT_EFF + toUint256(max)), toNAVUnits(uint256(1000e18)), ZERO_NAV_UNITS, true);
        // Consume the 10 wei dust slack, landing coverage utilization exactly on WAD
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(2000e18)), toNAVUnits(uint256(1000e18)), ZERO_NAV_UNITS, true);
        assertEq(state.coverageUtilizationWAD, WAD, "the slack consumed lands exactly on WAD");
        // One wei beyond max + slack violates
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(2000e18 + 1)), toNAVUnits(uint256(1000e18)), ZERO_NAV_UNITS, true);
    }

    /**
     * the flat-market closed form with zero dust, surplus = jtEffectiveNAV - ceil(collateralNAV * minCoverage / WAD),
     * grossed up by the coverage retention (WAD - minCoverage) to y = floor(surplus * WAD / (WAD - minCoverage))
     * Derivation: required = ceil(1200e18 * 0.1) = 120e18, surplus = 200e18 - 120e18 = 80e18,
     * y = floor(80e18 * 10 / 9) = 88888888888888888888
     */
    function test_MaxJTWithdrawal_flatMarketClosedForm() public view {
        SyncedAccountingState memory st = _bareState(1200e18, 100e18, 1000e18, 200e18, 0.1e18, DEFAULT_MIN_LIQUIDITY_WAD);
        NAV_UNIT jtW = accountant.maxJTWithdrawal(st);
        assertEq(toUint256(jtW), 88_888_888_888_888_888_888, "hand literal off the retention gross-up");
        assertEq(toUint256(jtW), RoycoTestMath.maxJTWithdrawal(1200e18, 200e18, 0.1e18, 0), "RTM parity");
    }

    /**
     * the dust tolerance folds into the requirement's ceil before the retention gross-up
     * Derivation: required = ceil((1200e18 + 10) * 0.1) = 120e18 + 1 (the 1 wei product remainder rounds up),
     * surplus = 200e18 - (120e18 + 1) = 80e18 - 1, retention = WAD - minCoverage = 0.9e18,
     * y = floor((80e18 - 1) * 1e18 / 0.9e18) = 88888888888888888887
     */
    function test_MaxJTWithdrawal_dustToleranceFoldsIntoTheSurplus() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.dustTolerance = toNAVUnits(uint256(10));
        _deploy(p);
        SyncedAccountingState memory st = _bareState(1200e18, 0, 1000e18, 200e18, 0.1e18, 0);
        NAV_UNIT jtW = accountant.maxJTWithdrawal(st);
        assertEq(toUint256(jtW), 88_888_888_888_888_888_887, "hand literal with the dust folded into the requirement");
        assertEq(toUint256(jtW), RoycoTestMath.maxJTWithdrawal(1200e18, 200e18, 0.1e18, 10), "RTM parity with the dust folded into the requirement");
    }

    /**
     * the coverage gate boundary on an exactly-divisible required value, redeeming exactly maxJTWithdrawal lands
     * coverage utilization exactly on WAD (the minimum passing buffer, zero slack), and the next wei is the
     * first to violate.
     * Arithmetic: required = ceil(1200e18 * 0.1) = 120e18 divides exactly, surplus = 200e18 - 120e18 = 80e18,
     * y = floor(80e18 * 10 / 9).
     * The gate is 9 * jtEffectiveNAV' >= SEED_ST_EFF with minimum passing jtEffectiveNAV' = ceil(SEED_ST_EFF / 9),
     * and max leaves jtEffectiveNAV' exactly on it, so one more redeemed wei is the first violating buffer
     */
    function test_MaxJTWithdrawal_FlatMarketExactGateBoundary() public {
        _seedFlatWithLT(SEED_LT_RAW);
        NAV_UNIT jtW = accountant.maxJTWithdrawal(_checkpointState());
        assertEq(toUint256(jtW), RoycoTestMath.maxJTWithdrawal(SEED_ST_EFF + SEED_JT_EFF, SEED_JT_EFF, 0.1e18, 0), "RTM parity");
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_ST_EFF + SEED_JT_EFF - toUint256(jtW)), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, true);
        assertEq(state.coverageUtilizationWAD, WAD, "the exact max lands coverage utilization on WAD");
        // One wei beyond max crosses the boundary ceil(SEED_ST_EFF / 9) and violates
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_ST_EFF + SEED_JT_EFF - toUint256(jtW) - 1), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, true);
    }

    /**
     * the non-flat-seed gate boundary. Redeeming exactly maxJTWithdrawal off a 980e18/220e18 checkpoint lands
     * coverage utilization exactly on WAD, and one more wei violates — the single-conversion pipeline leaves
     * no compounded floor slack, so the bound is tight to the wei.
     * Arithmetic: required = ceil(1200e18 * 0.1) = 120e18, surplus = 100e18, y = floor(1000e18 / 9)
     * = 111111111111111111111. Redeeming max leaves jtEffectiveNAV' = 108888888888888888889 with
     * 9 * jtEffectiveNAV' = 980e18 + 1 >= 980e18, and one more wei leaves 9 * (jtEffectiveNAV' - 1) < 980e18
     */
    function test_MaxJTWithdrawal_NonFlatSeedExactGateBoundary() public {
        _seedSymmetric(980e18, 220e18, SEED_LT_RAW);
        NAV_UNIT jtW = accountant.maxJTWithdrawal(_checkpointState());
        assertEq(toUint256(jtW), 111_111_111_111_111_111_111, "hand literal at the non-flat seed");
        assertEq(toUint256(jtW), RoycoTestMath.maxJTWithdrawal(1200e18, 220e18, 0.1e18, 0), "RTM parity");
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(1200e18 - toUint256(jtW)), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, true);
        assertEq(state.coverageUtilizationWAD, WAD, "the exact max lands coverage utilization on WAD");
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(1200e18 - toUint256(jtW) - 1), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, true);
    }

    /**
     * the liquidity requirement holds at every coverage level: a coverage utilization at the liquidation
     * threshold, past it at the uint256 max wipeout reading, and just below it all report the same restricted
     * surplus, since the withdrawal bound no longer reads coverage
     * required = ceil(1000e18 * 0.05) = 50e18, so max = 100e18 - 50e18 = 50e18 regardless of coverage
     */
    function test_MaxLTWithdrawal_enforcedRegardlessOfLiquidationBoundary() public view {
        SyncedAccountingState memory st = _bareState(1200e18, 100e18, 1000e18, 200e18, 0.1e18, 0.05e18);
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
     * zero, and a dust of 100 folds into the senior NAV before scaling: required = ceil((1000e18 + 107) * 0.05)
     * = 50e18 + 6, shrinking the withdrawable to 50e18 - 6
     */
    function test_MaxLTWithdrawal_closedFormCeilAndSaturation() public {
        SyncedAccountingState memory st = _bareState(1200e18 + 7, 100e18, 1000e18 + 7, 200e18, 0.1e18, 0.05e18);
        assertEq(toUint256(accountant.maxLTWithdrawal(st)), 50e18 - 1, "inner ceil rounds the required depth up");
        st.ltRawNAV = toNAVUnits(uint256(40e18));
        assertEq(toUint256(accountant.maxLTWithdrawal(st)), 0, "under-provisioned inventory saturates to zero");
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.dustTolerance = toNAVUnits(uint256(100));
        _deploy(p);
        st.ltRawNAV = toNAVUnits(uint256(100e18));
        assertEq(toUint256(accountant.maxLTWithdrawal(st)), 50e18 - 6, "dust tolerance shrinks the withdrawable depth");
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
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(SEED_ST_EFF + SEED_JT_EFF), toNAVUnits(SEED_LT_RAW - toUint256(max)), ZERO_NAV_UNITS, true);
        assertEq(state.liquidityUtilizationWAD, WAD, "the exact max lands liquidity utilization on WAD");
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(SEED_ST_EFF + SEED_JT_EFF), toNAVUnits(SEED_LT_RAW - toUint256(max) - 1), ZERO_NAV_UNITS, true);
    }
}
