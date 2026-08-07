// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { stdError } from "../../../lib/forge-std/src/StdError.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { WAD, ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { MarketState, Operation, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { AccountantTestBase } from "../../utils/AccountantTestBase.sol";

/**
 * @title Test_PostOpSync_Accountant
 * @notice postOpSyncTrancheAccounting and commitLiquidityProviderTrancheRawNAV: the per-operation delta-shape
 *         requires on the single collateral delta, the effective NAV bookkeeping of each operation, the
 *         self-liquidation bonus split, the coverage and liquidity utilizations the post-op returns at their
 *         exact WAD boundaries, conservation over every valid shape, and the committed liquidity mark's
 *         downstream effects
 * @notice The LPT flows are single-delta ops: LPT_DEPOSIT and LPT_REDEMPTION move only the liquidity mark
 *         (and, for redeem, hand out idle premium shares). A multi-asset deposit or redeem is not its own op,
 *         it decomposes into two single-delta legs the kernel sequences: a deposit is the senior seed
 *         (ST_DEPOSIT) then the BPT join (LPT_DEPOSIT), a redeem is the BPT slice (LPT_REDEMPTION) then the
 *         senior unwind (ST_REDEMPTION), so each leg pins the exact delta its flow can produce and nothing more
 * @notice The accountant no longer enforces the coverage or liquidity requirement: it returns the computed
 *         coverageUtilizationWAD and liquidityUtilizationWAD and the kernel reverts past WAD, so these tests
 *         assert the returned utilization crosses WAD, never a revert from the accountant
 * @dev The old per-tranche raw-NAV shape requires (a moving jt mark during an st op and vice versa) are
 *      unrepresentable under the single collateral NAV: those vectors fold into the collateral-delta requires
 */
contract Test_PostOpSync_Accountant is AccountantTestBase {
    uint256 internal constant SEED_COLLATERAL = SEED_ST_EFF + SEED_JT_EFF;

    function setUp() public {
        stranger = makeAddr("stranger");
        _deploy(_defaultParams());
    }

    /// an ST deposit adds the collateral delta to the senior effective NAV and commits the checkpoint
    function test_PostOp_STDeposit_addsDeltaToSTEffective() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 123e18), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF + 123e18, "st effective NAV grows by the deposited value");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF, "jt effective NAV untouched");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastCollateralNAV), SEED_COLLATERAL + 123e18, "collateral NAV committed");
        assertEq(toUint256(s.lastSTEffectiveNAV), SEED_ST_EFF + 123e18, "st effective NAV committed");
    }

    /// an ST deposit with a zero collateral delta violates the shape require: a deposit that added no
    /// collateral value would let the kernel mint senior claims against nothing, so value must verifiably arrive
    function test_RevertIf_STDepositZeroCollateralDelta() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
    }

    /// an ST deposit with a negative collateral delta violates the shape require: value leaving during a
    /// deposit is an unsynced loss that must run the waterfall (so coverage applies), never a checkpoint commit
    function test_RevertIf_STDepositNegativeCollateralDelta() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_COLLATERAL - 1), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
    }

    /// an ST deposit with a nonzero liquidity raw NAV delta violates the shape require in both directions: a
    /// senior deposit never touches the pooled BPT, so any motion in the liquidity mark is an unsynced pool event
    function test_RevertIf_STDepositNonzeroLPTDelta() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 10e18), toNAVUnits(SEED_LPT_RAW + 1), ZERO_NAV_UNITS);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 10e18), toNAVUnits(SEED_LPT_RAW - 1), ZERO_NAV_UNITS);
    }

    /// an ST deposit with a nonzero self-liquidation bonus value violates the shape require: the bonus is a
    /// junior-funded sweetener that exists only on senior redemptions and would debit JT with nothing redeemed
    function test_RevertIf_STDepositNonzeroBonus() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 10e18), toNAVUnits(SEED_LPT_RAW), toNAVUnits(uint256(1)));
    }

    /// a JT deposit adds the collateral delta to the junior effective NAV and commits the checkpoint :
    /// fresh junior capital immediately deepens the first-loss buffer that covers senior
    function test_PostOp_JTDeposit_addsDeltaToJTEffective() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 45e18), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF + 45e18, "jt effective NAV grows by the deposited value");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF, "st effective NAV untouched");
        assertEq(toUint256(accountant.getState().lastJTEffectiveNAV), SEED_JT_EFF + 45e18, "jt effective NAV committed");
    }

    /// a JT deposit with a zero collateral delta violates the shape require: junior claims may only be
    /// minted against value that verifiably arrived, else the buffer is diluted for free
    function test_RevertIf_JTDepositZeroCollateralDelta() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
    }

    /// a JT deposit with a negative collateral delta violates the shape require: value leaving during a
    /// deposit is an unsynced loss that must run the waterfall before any checkpoint commit
    function test_RevertIf_JTDepositNegativeCollateralDelta() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_COLLATERAL - 1), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
    }

    /// a JT deposit with a nonzero liquidity raw NAV delta violates the shape require in both directions: a
    /// junior deposit never touches the pooled BPT, so a moving liquidity mark signals an unsynced pool event
    function test_RevertIf_JTDepositNonzeroLPTDelta() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 10e18), toNAVUnits(SEED_LPT_RAW + 1), ZERO_NAV_UNITS);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 10e18), toNAVUnits(SEED_LPT_RAW - 1), ZERO_NAV_UNITS);
    }

    /// a JT deposit with a nonzero self-liquidation bonus value violates the shape require: the bonus exists
    /// only on senior redemptions, where junior pays to retire senior exposure, never on junior entry
    function test_RevertIf_JTDepositNonzeroBonus() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 10e18), toNAVUnits(SEED_LPT_RAW), toNAVUnits(uint256(1)));
    }

    /// a BPT-only LPT deposit (zero collateral delta) books the liquidity raw NAV and leaves both effective NAVs
    /// untouched: pre-minted BPT adds pooled exit depth without creating any senior or junior claim to conserve
    function test_PostOp_LPTDepositBPTOnly_leavesEffectiveNAVsUntouched() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LPT_DEPOSIT, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LPT_RAW + 30e18), ZERO_NAV_UNITS);
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF, "st effective NAV untouched by the pure BPT leg");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF, "jt effective NAV untouched");
        assertEq(toUint256(state.lptRawNAV), SEED_LPT_RAW + 30e18, "lt raw NAV reflects the deposit");
        assertEq(toUint256(accountant.getState().lastLPTRawNAV), SEED_LPT_RAW + 30e18, "lt raw NAV committed");
    }

    /// a multi-asset LPT deposit decomposes into two single-delta post-ops: the senior seed leg (ST_DEPOSIT) mints
    /// new senior exposure coverage must track, then the BPT join leg (LPT_DEPOSIT) books the pooled depth
    function test_PostOp_LPTMultiAssetDeposit_addsCollateralDeltaToSTEffective() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        // Leg 1: the senior seed moves collateral only, growing the senior effective NAV by the minted senior value
        SyncedAccountingState memory afterSeed =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 50e18), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
        assertEq(toUint256(afterSeed.stEffectiveNAV), SEED_ST_EFF + 50e18, "st effective NAV grows by the minted senior value");
        // Leg 2: the BPT join moves the liquidity raw NAV only, against the collateral mark the seed leg committed
        SyncedAccountingState memory afterJoin =
            kernel.doPostOp(Operation.LPT_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 50e18), toNAVUnits(SEED_LPT_RAW + 20e18), ZERO_NAV_UNITS);
        assertEq(toUint256(afterJoin.lptRawNAV), SEED_LPT_RAW + 20e18, "lt raw NAV reflects the joined BPT value");
        assertEq(toUint256(accountant.getState().lastSTEffectiveNAV), SEED_ST_EFF + 50e18, "st effective NAV committed");
    }

    /// a quote-only multi-asset LPT deposit mints no senior shares, so it reduces to the single BPT-join leg
    /// (LPT_DEPOSIT): the quote joins the pool without creating any senior claim, leaving both effective NAVs untouched
    function test_PostOp_LPTMultiAssetDeposit_zeroCollateralDeltaPasses() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LPT_DEPOSIT, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LPT_RAW + 30e18), ZERO_NAV_UNITS);
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF, "st effective NAV untouched by the quote-only leg");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF, "jt effective NAV untouched");
        assertEq(toUint256(state.lptRawNAV), SEED_LPT_RAW + 30e18, "lt raw NAV reflects the deposit");
    }

    /// an in-kind LPT deposit with a nonzero collateral delta violates the shape require in both directions, the
    /// in-kind flow only moves pre-minted BPT so a moving collateral mark is unsynced PnL bypassing the waterfall
    function test_RevertIf_LPTDepositNonzeroCollateralDelta() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LPT_DEPOSIT));
        kernel.doPostOp(Operation.LPT_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 50e18), toNAVUnits(SEED_LPT_RAW + 20e18), ZERO_NAV_UNITS);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LPT_DEPOSIT));
        kernel.doPostOp(Operation.LPT_DEPOSIT, toNAVUnits(SEED_COLLATERAL - 1), toNAVUnits(SEED_LPT_RAW + 10e18), ZERO_NAV_UNITS);
    }

    /// an LPT deposit with a zero liquidity raw NAV delta violates the shape require: a liquidity deposit that
    /// added no pooled depth would mint LPT claims against nothing and dilute existing LPT holders
    function test_RevertIf_LPTDepositZeroLPTDelta() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LPT_DEPOSIT));
        kernel.doPostOp(Operation.LPT_DEPOSIT, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
    }

    /// an LPT deposit with a negative liquidity raw NAV delta violates the shape require: pooled depth leaving
    /// during a deposit means the mark embeds an unsynced pool loss that a fresh depositor would be priced into
    function test_RevertIf_LPTDepositNegativeLPTDelta() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LPT_DEPOSIT));
        kernel.doPostOp(Operation.LPT_DEPOSIT, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LPT_RAW - 1), ZERO_NAV_UNITS);
    }

    /// an LPT deposit with a nonzero self-liquidation bonus value violates the shape require: the junior-funded
    /// bonus exists only on senior redemptions and has no meaning when liquidity capital enters
    function test_RevertIf_LPTDepositNonzeroBonus() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LPT_DEPOSIT));
        kernel.doPostOp(Operation.LPT_DEPOSIT, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LPT_RAW + 10e18), toNAVUnits(uint256(1)));
    }

    /// the senior seed leg of a multi-asset deposit (ST_DEPOSIT) with a negative collateral delta violates the shape
    /// require, the seed can only MINT senior shares so a falling collateral mark is an unsynced loss bypassing the waterfall
    function test_RevertIf_LPTMultiAssetDepositNegativeCollateralDelta() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_COLLATERAL - 1), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
    }

    /// the BPT join leg of a multi-asset deposit (LPT_DEPOSIT) with a zero or negative liquidity raw NAV delta violates
    /// the shape require, a liquidity deposit that added no pooled depth would mint LPT claims against nothing
    function test_RevertIf_LPTMultiAssetDepositNonpositiveLPTDelta() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LPT_DEPOSIT));
        kernel.doPostOp(Operation.LPT_DEPOSIT, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LPT_DEPOSIT));
        kernel.doPostOp(Operation.LPT_DEPOSIT, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LPT_RAW - 1), ZERO_NAV_UNITS);
    }

    /// the BPT join leg of a multi-asset deposit (LPT_DEPOSIT) with a nonzero self-liquidation bonus value violates the
    /// shape require, the junior-funded bonus exists only on senior redemptions
    function test_RevertIf_LPTMultiAssetDepositNonzeroBonus() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LPT_DEPOSIT));
        kernel.doPostOp(Operation.LPT_DEPOSIT, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LPT_RAW + 10e18), toNAVUnits(uint256(1)));
    }

    /// an ST redemption without a bonus reduces the senior effective NAV by the full redeemed value
    function test_PostOp_STRedeem_reducesSTEffectiveWithoutBonus() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(SEED_COLLATERAL - 50e18), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF - 50e18, "st effective NAV bears the full redemption");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF, "jt effective NAV untouched without a bonus");
    }

    /**
     * an ST redemption with a self-liquidation bonus reduces the junior effective NAV by exactly the bonus
     * and the senior effective NAV by the total redeemed value minus the bonus
     * Derivation: total redeemed = 55e18 (collateral 1200e18 -> 1145e18), bonus 5e18:
     * jtEffectiveNAV = 200e18 - 5e18, stEffectiveNAV = 1000e18 - (55e18 - 5e18)
     */
    function test_PostOp_STRedeem_bonusSplitsAcrossJTAndST() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(SEED_COLLATERAL - 55e18), toNAVUnits(SEED_LPT_RAW), toNAVUnits(uint256(5e18)));
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF - 5e18, "jt effective NAV funds exactly the bonus");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF - 50e18, "st effective NAV bears the redemption net of the bonus");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(
            toUint256(s.lastCollateralNAV), toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV), "conservation holds through the bonus split"
        );
    }

    /// a bonus exactly equal to the total redeemed value draws everything from JT and leaves the senior effective NAV unchanged
    function test_PostOp_STRedeem_bonusEqualToTotalDrawsAllFromJT() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(SEED_COLLATERAL - 10e18), toNAVUnits(SEED_LPT_RAW), toNAVUnits(uint256(10e18)));
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF, "st effective NAV untouched when the bonus covers the total");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF - 10e18, "jt effective NAV funds the entire redemption");
    }

    /// an ST redemption with a nonzero liquidity raw NAV delta violates the shape require in both directions
    function test_RevertIf_STRedeemNonzeroLPTDelta() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_REDEMPTION));
        kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(SEED_COLLATERAL - 10e18), toNAVUnits(SEED_LPT_RAW + 1), ZERO_NAV_UNITS);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_REDEMPTION));
        kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(SEED_COLLATERAL - 10e18), toNAVUnits(SEED_LPT_RAW - 1), ZERO_NAV_UNITS);
    }

    /// an ST redemption with a zero total redeemed value violates the shape require
    function test_RevertIf_STRedeemZeroTotal() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_REDEMPTION));
        kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
    }

    /**
     * a positive collateral delta during an ST redemption violates the shape require: the delta-sign check runs
     * before the redeemed value is ever computed, so a redemption fed collateral inflow reverts INVALID_POST_OP_STATE
     */
    function test_RevertIf_STRedeemPositiveCollateralDelta() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_REDEMPTION));
        kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(SEED_COLLATERAL + 1), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
    }

    /**
     * a bonus exceeding the junior effective NAV underflows the raw NAV_UNIT subtraction with an
     * arithmetic panic (0x11), not a custom error: the junior buffer is debited before the senior leg
     */
    function test_RevertIf_STRedeemBonusExceedsJTEffective() public {
        _seedState(SEED_ST_EFF, 5e18, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        vm.expectRevert(stdError.arithmeticError);
        kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(SEED_ST_EFF + 5e18 - 10e18), toNAVUnits(SEED_LPT_RAW), toNAVUnits(uint256(6e18)));
    }

    /**
     * a bonus exceeding the total redeemed value (while within the junior buffer) underflows the
     * total-minus-bonus subtraction with an arithmetic panic (0x11)
     */
    function test_RevertIf_STRedeemBonusExceedsTotal() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        vm.expectRevert(stdError.arithmeticError);
        kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(SEED_COLLATERAL - 10e18), toNAVUnits(SEED_LPT_RAW), toNAVUnits(uint256(11e18)));
    }

    /// an in-kind LPT redemption (negative liquidity delta alone, zero total) passes and books only the liquidity mark
    function test_PostOp_LPTRedeem_negativeLPTDeltaAlonePasses() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LPT_RAW - 40e18), ZERO_NAV_UNITS);
        assertEq(toUint256(state.lptRawNAV), SEED_LPT_RAW - 40e18, "lt raw NAV reflects the burned BPT slice");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF, "st effective NAV untouched");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF, "jt effective NAV untouched");
        assertEq(toUint256(accountant.getState().lastLPTRawNAV), SEED_LPT_RAW - 40e18, "lt raw NAV committed");
    }

    /**
     * a multi-asset LPT redemption whose BPT slice floors to zero skips the LPT leg entirely and runs only the
     * senior unwind (ST_REDEMPTION): the LPT_REDEMPTION leg requires a strictly negative liquidity delta, so a
     * zero-slice leg would revert, the real flow omits it and the embedded senior redemption unwinds venue assets alone
     */
    function test_PostOp_LPTMultiAssetRedeem_zeroLPTDeltaWithPositiveTotalPasses() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        // Single senior-unwind leg: collateral falls, the liquidity mark is left untouched (no BPT slice burned)
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(SEED_COLLATERAL - 10e18), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF - 10e18, "st effective NAV bears the unwound senior leg");
        assertEq(toUint256(state.lptRawNAV), SEED_LPT_RAW, "lt raw NAV untouched by the zero-BPT-slice leg");
    }

    /// a multi-asset LPT redemption with a real BPT slice runs both legs: the BPT slice (LPT_REDEMPTION) burns depth,
    /// then the senior unwind (ST_REDEMPTION) reduces collateral
    function test_PostOp_LPTMultiAssetRedeem_bothLegsPass() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        // Leg 1: the BPT slice burns 40e18 of depth off the liquidity mark, the collateral cannot move
        SyncedAccountingState memory afterSlice =
            kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LPT_RAW - 40e18), ZERO_NAV_UNITS);
        assertEq(toUint256(afterSlice.lptRawNAV), SEED_LPT_RAW - 40e18, "lt raw NAV reflects the burned BPT slice");
        assertEq(toUint256(afterSlice.stEffectiveNAV), SEED_ST_EFF, "st effective NAV untouched by the slice leg");
        // Leg 2: the senior unwind reduces collateral by 10e18 against the mark the slice leg committed
        SyncedAccountingState memory afterUnwind =
            kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(SEED_COLLATERAL - 10e18), toNAVUnits(SEED_LPT_RAW - 40e18), ZERO_NAV_UNITS);
        assertEq(toUint256(afterUnwind.stEffectiveNAV), SEED_ST_EFF - 10e18, "st effective NAV bears the unwound senior leg");
        assertEq(toUint256(afterUnwind.lptRawNAV), SEED_LPT_RAW - 40e18, "lt raw NAV stays at the burned BPT slice");
    }

    /**
     * a multi-asset LPT redemption carries the self-liquidation bonus on its senior-unwind leg (ST_REDEMPTION):
     * the BPT-slice leg pays no bonus, the senior unwind reduces the junior effective NAV by exactly the bonus and
     * the senior effective NAV by the total redeemed value minus the bonus
     * Derivation: senior unwind total redeemed = 55e18, bonus 5e18: jtEffectiveNAV = 200e18 - 5e18, stEffectiveNAV = 1000e18 - 50e18
     */
    function test_PostOp_LPTMultiAssetRedeem_bonusSplitsAcrossJTAndST() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        // Leg 1: the BPT slice burns 40e18 of depth and pays no bonus
        kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LPT_RAW - 40e18), ZERO_NAV_UNITS);
        // Leg 2: the senior unwind redeems 55e18 with a 5e18 junior-funded bonus
        SyncedAccountingState memory state = kernel.doPostOp(
            Operation.ST_REDEMPTION, toNAVUnits(SEED_COLLATERAL - 55e18), toNAVUnits(SEED_LPT_RAW - 40e18), toNAVUnits(uint256(5e18)));
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF - 5e18, "jt effective NAV funds exactly the bonus");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF - 50e18, "st effective NAV bears the redemption net of the bonus");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(
            toUint256(s.lastCollateralNAV), toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV), "conservation holds through the bonus split"
        );
    }

    /// a positive liquidity delta on the BPT-slice leg (LPT_REDEMPTION) of a multi-asset redemption violates the
    /// shape require: the slice can only burn depth, so a rising liquidity mark is an unsynced pool event
    function test_RevertIf_LPTMultiAssetRedeemPositiveLPTDelta() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LPT_REDEMPTION));
        kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LPT_RAW + 1), ZERO_NAV_UNITS);
    }

    /**
     * a positive collateral delta on the senior-unwind leg (ST_REDEMPTION) of a multi-asset redemption violates
     * the shape require: the delta-sign check runs before the redeemed value is computed, so a senior unwind fed
     * collateral inflow reverts INVALID_POST_OP_STATE. The BPT-slice leg burns first, then the senior unwind reverts
     */
    function test_RevertIf_LPTMultiAssetRedeemPositiveCollateralDelta() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        // Leg 1: the BPT slice burns 10e18 of depth, the collateral cannot move
        kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LPT_RAW - 10e18), ZERO_NAV_UNITS);
        // Leg 2: the senior unwind fed a positive collateral delta violates the sign check
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_REDEMPTION));
        kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(SEED_COLLATERAL + 1), toNAVUnits(SEED_LPT_RAW - 10e18), ZERO_NAV_UNITS);
    }

    /// a bonus exceeding the junior effective NAV on the senior-unwind leg (ST_REDEMPTION) underflows the junior
    /// debit with an arithmetic panic (0x11): the junior buffer is debited before the senior leg
    function test_RevertIf_LPTMultiAssetRedeemBonusExceedsJTEffective() public {
        _seedState(SEED_ST_EFF, 5e18, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        // Leg 1: the BPT slice burns 1e18 of depth
        kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(SEED_ST_EFF + 5e18), toNAVUnits(SEED_LPT_RAW - 1e18), ZERO_NAV_UNITS);
        // Leg 2: the senior unwind's 6e18 bonus exceeds the 5e18 junior buffer and underflows
        vm.expectRevert(stdError.arithmeticError);
        kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(SEED_ST_EFF + 5e18 - 10e18), toNAVUnits(SEED_LPT_RAW - 1e18), toNAVUnits(uint256(6e18)));
    }

    /// a bonus exceeding the total redeemed value (while within the junior buffer) on the senior-unwind leg
    /// (ST_REDEMPTION) underflows the total-minus-bonus subtraction with an arithmetic panic (0x11)
    function test_RevertIf_LPTMultiAssetRedeemBonusExceedsTotal() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        // Leg 1: the BPT slice burns 1e18 of depth
        kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LPT_RAW - 1e18), ZERO_NAV_UNITS);
        // Leg 2: the senior unwind's 11e18 bonus exceeds the 10e18 redeemed total and underflows
        vm.expectRevert(stdError.arithmeticError);
        kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(SEED_COLLATERAL - 10e18), toNAVUnits(SEED_LPT_RAW - 1e18), toNAVUnits(uint256(11e18)));
    }

    /// an in-kind LPT redemption with a nonzero collateral delta violates the shape require in both directions,
    /// the in-kind flow only transfers BPT and idle premium shares so the collateral mark may not move
    function test_RevertIf_LPTRedeemNonzeroCollateralDelta() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LPT_REDEMPTION));
        kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(SEED_COLLATERAL - 10e18), toNAVUnits(SEED_LPT_RAW - 40e18), ZERO_NAV_UNITS);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LPT_REDEMPTION));
        kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(SEED_COLLATERAL + 1), toNAVUnits(SEED_LPT_RAW - 40e18), ZERO_NAV_UNITS);
    }

    /// an in-kind LPT redemption with a nonzero self-liquidation bonus value violates the shape require, the
    /// bonus exists only where a senior leg is unwound and the in-kind flow never unwinds one
    function test_RevertIf_LPTRedeemNonzeroBonus() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LPT_REDEMPTION));
        kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LPT_RAW - 40e18), toNAVUnits(uint256(1)));
    }

    /**
     * an LPT redemption with a zero liquidity delta and a zero total passes: the in-kind senior-shares-only leg,
     * where the redeemer takes idle premium senior shares in kind. The shares stay in the senior supply, so no
     * raw NAV moves on any tranche and every effective NAV is left untouched
     * NOTE: this pins the fix for the previously flagged edge where a pure senior-share in-kind LPT redemption
     * tripped INVALID_POST_OP_STATE despite moving no raw NAV
     */
    /// a zero-delta LPT redemption (no BPT slice burned, deltaLPTRawNAV == 0) fails the strict op-shape guard: the
    /// LPT_REDEMPTION guard requires deltaLPTRawNAV < 0, so an idle-premium-only redemption that moves no deployed
    /// raw NAV reverts INVALID_POST_OP_STATE before any liquidity check
    function test_RevertIf_LPTRedeemZeroLPTDelta() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LPT_REDEMPTION));
        kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
    }

    /// an LPT redemption with a positive liquidity delta violates the shape require
    function test_RevertIf_LPTRedeemPositiveLPTDelta() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LPT_REDEMPTION));
        kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LPT_RAW + 1), ZERO_NAV_UNITS);
    }

    /// a JT redemption reduces the junior effective NAV by the total redeemed value and leaves a zero IL untouched
    function test_PostOp_JTRedeem_reducesJTEffectiveWithZeroILUntouched() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.JT_REDEMPTION, toNAVUnits(SEED_COLLATERAL - 50e18), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF - 50e18, "jt effective NAV bears the redemption");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF, "st effective NAV untouched");
        assertEq(toUint256(state.jtImpermanentLoss), 0, "zero il stays zero through the redemption");
        assertEq(toUint256(accountant.getState().lastJTImpermanentLoss), 0, "committed il untouched");
    }

    /**
     * a JT redemption leaves a live impermanent loss ledger UNTOUCHED: the drawdown is a property of the
     * committed effective NAV path, not of the redeeming LP's share, so no scaling happens on redemption
     * (the old floor-scaling of the IL by the junior NAV ratio was deleted with the drawdown semantics)
     * Derivation from the (collateral 1200e18, stEff 1000e18, jtEff 200e18, il 100e18) fixed-term checkpoint:
     *   redeem 60e18: jtEffectiveNAV = 140e18, il stays exactly 100e18 returned and committed
     *   redeem 7 more wei: jtEffectiveNAV = 140e18 - 7, il still exactly 100e18
     */
    function test_PostOp_JTRedeem_leavesILLedgerUntouched() public {
        _seedState(1000e18, 200e18, 100e18, SEED_LPT_RAW, MarketState.FIXED_TERM);
        SyncedAccountingState memory state = kernel.doPostOp(Operation.JT_REDEMPTION, toNAVUnits(uint256(1140e18)), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
        assertEq(toUint256(state.jtEffectiveNAV), 140e18, "jt effective NAV bears the redemption");
        assertEq(toUint256(state.jtImpermanentLoss), 100e18, "il passthrough, never scaled by a redemption");
        assertEq(toUint256(accountant.getState().lastJTImpermanentLoss), 100e18, "committed il untouched");

        state = kernel.doPostOp(Operation.JT_REDEMPTION, toNAVUnits(uint256(1140e18 - 7)), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
        assertEq(toUint256(state.jtImpermanentLoss), 100e18, "il untouched by the second redemption");
        assertEq(toUint256(accountant.getState().lastJTImpermanentLoss), 100e18, "committed il still untouched");
        assertEq(uint8(accountant.getState().lastMarketState), uint8(MarketState.FIXED_TERM), "il > 0 keeps the market fixed term (biconditional)");
    }

    /// a JT redemption with a nonzero liquidity raw NAV delta violates the shape require in both directions
    function test_RevertIf_JTRedeemNonzeroLPTDelta() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_REDEMPTION));
        kernel.doPostOp(Operation.JT_REDEMPTION, toNAVUnits(SEED_COLLATERAL - 10e18), toNAVUnits(SEED_LPT_RAW + 1), ZERO_NAV_UNITS);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_REDEMPTION));
        kernel.doPostOp(Operation.JT_REDEMPTION, toNAVUnits(SEED_COLLATERAL - 10e18), toNAVUnits(SEED_LPT_RAW - 1), ZERO_NAV_UNITS);
    }

    /// a JT redemption with a zero total redeemed value violates the shape require
    function test_RevertIf_JTRedeemZeroTotal() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_REDEMPTION));
        kernel.doPostOp(Operation.JT_REDEMPTION, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
    }

    /// a positive collateral delta during a JT redemption violates the shape require: the delta-sign check runs
    /// before the redeemed value is ever computed, so a redemption fed collateral inflow reverts INVALID_POST_OP_STATE
    function test_RevertIf_JTRedeemPositiveCollateralDelta() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_REDEMPTION));
        kernel.doPostOp(Operation.JT_REDEMPTION, toNAVUnits(SEED_COLLATERAL + 1), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
    }

    /// a JT redemption with a nonzero self-liquidation bonus value violates the shape require
    function test_RevertIf_JTRedeemNonzeroBonus() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_REDEMPTION));
        kernel.doPostOp(Operation.JT_REDEMPTION, toNAVUnits(SEED_COLLATERAL - 10e18), toNAVUnits(SEED_LPT_RAW), toNAVUnits(uint256(1)));
    }

    /**
     * from any conserved flat checkpoint, every valid post-op shape commits without reverting and the
     * committed checkpoint conserves NAV exactly: the NAV_CONSERVATION_VIOLATION arm is unreachable
     * from conserved checkpoints (any revert or wei of drift here is a REAL divergence)
     */
    function testFuzz_PostOp_conservationHoldsForValidShapes(uint256 _stEff0, uint256 _jtEff0, uint256 _lpt0, uint256 _value, uint256 _opSeed) public {
        // Bounds: checkpoint effective NAVs uniform in [1e18, 1e30] (the strategy magnitude bound), the committed
        // liquidity value uniform in [2, 1e30] so an LPT redemption always has a withdrawable wei, the op value
        // uniform in [1, 1e18] so redemptions stay inside every tranche, and the op uniform across all six members
        _stEff0 = bound(_stEff0, 1e18, 1e30);
        _jtEff0 = bound(_jtEff0, 1e18, 1e30);
        _lpt0 = bound(_lpt0, 2, 1e30);
        _value = bound(_value, 1, 1e18);
        Operation op = Operation(bound(_opSeed, 0, 5));
        _seedState(_stEff0, _jtEff0, 0, _lpt0, MarketState.PERPETUAL);
        uint256 collateral0 = _stEff0 + _jtEff0;

        uint256 collateral1 = collateral0;
        uint256 lpt1 = _lpt0;
        NAV_UNIT bonus = ZERO_NAV_UNITS;
        if (op == Operation.ST_DEPOSIT) {
            collateral1 = collateral0 + _value;
        } else if (op == Operation.ST_REDEMPTION) {
            // Redeem the value from the collateral with half of it junior-funded as a bonus
            collateral1 = collateral0 - _value;
            bonus = toNAVUnits(_value / 2);
        } else if (op == Operation.JT_DEPOSIT) {
            collateral1 = collateral0 + _value;
        } else if (op == Operation.JT_REDEMPTION) {
            collateral1 = collateral0 - _value;
        } else if (op == Operation.LPT_DEPOSIT) {
            // The in-kind deposit only deepens the liquidity mark
            lpt1 = _lpt0 + _value;
        } else {
            // The in-kind LPT redemption only burns a BPT slice off the liquidity mark
            lpt1 = _lpt0 - (_value < _lpt0 ? _value : _lpt0 - 1);
        }
        kernel.doPostOp(op, toNAVUnits(collateral1), toNAVUnits(lpt1), bonus);

        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(
            toUint256(s.lastCollateralNAV), toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV), "committed checkpoint conserves NAV exactly"
        );
        assertEq(toUint256(s.lastCollateralNAV), collateral1, "collateral NAV committed");
        assertEq(toUint256(s.lastLPTRawNAV), lpt1, "lt raw NAV committed");
    }

    /**
     * the post-op writes all four NAV checkpoints including lastLPTRawNAV, never touches the market state,
     * the stored fixed-term end, or the IL ledger, performs no yield-share accrual, emits no sync event, and
     * returns zero fees and premium with fresh utilizations plus the fixed-term end passthrough
     */
    function test_PostOp_writesAllCheckpointsAndPreservesMarketState() public {
        _seedState(1000e18, 200e18, 100e18, SEED_LPT_RAW, MarketState.FIXED_TERM);
        uint32 end = accountant.getState().fixedTermEndTimestamp;
        assertGt(uint256(end), 0, "seed committed a live fixed-term end");
        uint256 jtCallsBefore = jtYDM.yieldShareCallCount();
        uint256 lptCallsBefore = lptYDM.yieldShareCallCount();
        vm.recordLogs();
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LPT_DEPOSIT, toNAVUnits(uint256(1200e18)), toNAVUnits(uint256(130e18)), ZERO_NAV_UNITS);

        // Returned state: passthroughs, zero fees and premium, fresh utilizations
        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "market state passthrough");
        assertEq(toUint256(state.collateralNAV), 1200e18, "collateral NAV passthrough");
        assertEq(toUint256(state.lptRawNAV), 130e18, "lt raw NAV passthrough");
        assertEq(toUint256(state.stEffectiveNAV), 1000e18, "st effective NAV unchanged by the BPT-only deposit");
        assertEq(toUint256(state.jtEffectiveNAV), 200e18, "jt effective NAV unchanged");
        assertEq(toUint256(state.jtImpermanentLoss), 100e18, "il passthrough");
        assertEq(toUint256(state.lptLiquidityPremium), 0, "no premium accrues on an operation");
        assertEq(toUint256(state.stProtocolFee), 0, "no st fee on an operation");
        assertEq(toUint256(state.jtProtocolFee), 0, "no jt fee on an operation");
        assertEq(toUint256(state.lptProtocolFee), 0, "no lt fee on an operation");
        assertEq(
            state.coverageUtilizationWAD, _specCoverageUtilization(1200e18, DEFAULT_MIN_COVERAGE_WAD, 200e18), "fresh coverage utilization, not a placeholder"
        );
        assertEq(
            state.liquidityUtilizationWAD, _specLiquidityUtilization(1000e18, DEFAULT_MIN_LIQUIDITY_WAD, 130e18), "fresh liquidity utilization on the new mark"
        );
        assertEq(state.fixedTermEndTimestamp, end, "fixed-term end passthrough");

        // Committed checkpoints: all four NAVs written, market state and end timestamp untouched
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastCollateralNAV), 1200e18, "collateral NAV committed");
        assertEq(toUint256(s.lastLPTRawNAV), 130e18, "lt raw NAV committed");
        assertEq(toUint256(s.lastSTEffectiveNAV), 1000e18, "st effective NAV committed");
        assertEq(toUint256(s.lastJTEffectiveNAV), 200e18, "jt effective NAV committed");
        assertEq(toUint256(s.lastJTImpermanentLoss), 100e18, "il ledger untouched");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.FIXED_TERM), "market state never changes in a post-op");
        assertEq(s.fixedTermEndTimestamp, end, "stored fixed-term end untouched");
        assertEq(jtYDM.yieldShareCallCount(), jtCallsBefore, "no jt accrual in a post-op");
        assertEq(lptYDM.yieldShareCallCount(), lptCallsBefore, "no lt accrual in a post-op");
        assertEq(_countAccountantLogs(vm.getRecordedLogs(), IRoycoDayKernel.PreOpTrancheAccountingSynced.selector), 0, "the sync events live on the kernel, the accountant emits none");
    }

    /**
     * the accountant never reverts on a breached requirement for any operation, it settles and returns the
     * breached utilization the kernel gate acts on, walked across every op from a doubly-breached market
     * Breach seed (stEff 1000e18, jtEff 50e18, lt 10e18): coverageUtilization = ceil(1050e18 * 0.1e18 / 50e18) = 2.1e18
     * and liquidityUtilization = ceil(1000e18 * 0.05e18 / 10e18) = 5e18
     */
    function test_PostOp_accountantNeverEnforcesGatesForAnyOp() public {
        _seedState(SEED_ST_EFF, 50e18, 0, 10e18, MarketState.PERPETUAL);
        // ST_DEPOSIT deepens the coverage breach and settles (collateral 1050e18 -> 1150e18, stEff 1100e18)
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(1150e18)), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage breached after the st deposit");
        assertGt(state.liquidityUtilizationWAD, WAD, "liquidity breached after the st deposit");
        // ST_REDEMPTION (collateral 1100e18, stEff 1050e18)
        state = kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(uint256(1100e18)), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage still breached after the st redemption");
        // JT_DEPOSIT (collateral 1110e18, jtEff 60e18)
        state = kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(uint256(1110e18)), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage still breached after the jt deposit");
        // JT_REDEMPTION deepens the coverage breach and settles (collateral 1100e18, jtEff 50e18)
        state = kernel.doPostOp(Operation.JT_REDEMPTION, toNAVUnits(uint256(1100e18)), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage still breached after the jt redemption");
        // LPT_DEPOSIT under a persisting liquidity breach settles (lt 15e18)
        state = kernel.doPostOp(Operation.LPT_DEPOSIT, toNAVUnits(uint256(1100e18)), toNAVUnits(uint256(15e18)), ZERO_NAV_UNITS);
        assertGt(state.liquidityUtilizationWAD, WAD, "liquidity still breached after the lt deposit");
        // LPT_REDEMPTION deepens the liquidity breach and settles (lt 5e18)
        state = kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(uint256(1100e18)), toNAVUnits(uint256(5e18)), ZERO_NAV_UNITS);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage still breached after the lt redemption");
        // A multi-asset deposit deepens the coverage breach: the senior seed leg (ST_DEPOSIT) mints senior to collateral 1150e18
        state = kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(1150e18)), toNAVUnits(uint256(5e18)), ZERO_NAV_UNITS);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage still breached after the multi-asset seed leg");
        // then the BPT join leg (LPT_DEPOSIT) books the pooled depth (lt 6e18)
        state = kernel.doPostOp(Operation.LPT_DEPOSIT, toNAVUnits(uint256(1150e18)), toNAVUnits(uint256(6e18)), ZERO_NAV_UNITS);
        assertGt(state.liquidityUtilizationWAD, WAD, "liquidity still breached after the multi-asset join leg");
        // A multi-asset redeem deepens the liquidity breach: the BPT-slice leg (LPT_REDEMPTION) burns depth (lt 5e18)
        state = kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(uint256(1150e18)), toNAVUnits(uint256(5e18)), ZERO_NAV_UNITS);
        assertGt(state.liquidityUtilizationWAD, WAD, "liquidity still breached after the multi-asset slice leg");
        // then the senior unwind leg (ST_REDEMPTION) reduces collateral to 1100e18
        state = kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(uint256(1100e18)), toNAVUnits(uint256(5e18)), ZERO_NAV_UNITS);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage still breached at the end");
        assertGt(state.liquidityUtilizationWAD, WAD, "liquidity still breached at the end");
    }

    /**
     * the ST_DEPOSIT coverage utilization the post-op returns lands exactly on WAD at the boundary and crosses to
     * WAD + 1 one wei past it, the value the kernel coverage gate lets through then rejects
     * Arithmetic: the WAD boundary is collateralNAV * minCov / jtEff == WAD, so at jtEffectiveNAV 200e18 and
     * minCoverage 0.1e18 the boundary collateral NAV is 2000e18: coverageUtilization = ceil(2000e18 * 0.1e18 / 200e18)
     * = 1e18 exactly (exact division), while one more wei gives ceil((2000e18 + 1) * 0.1e18 / 200e18) = 1e18 + 1
     * since the product gains a 1e17 remainder
     */
    function test_PostOp_coverageGate_stDepositExactBoundary() public {
        _seedFlatWithLPT(200e18);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(2000e18)), toNAVUnits(uint256(200e18)), ZERO_NAV_UNITS);
        assertEq(state.coverageUtilizationWAD, WAD, "coverage utilization lands exactly on WAD, the kernel gate lets it through");
        state = kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(2000e18 + 1)), toNAVUnits(uint256(200e18)), ZERO_NAV_UNITS);
        assertEq(state.coverageUtilizationWAD, WAD + 1, "one more senior wei crosses WAD, the would-breach value the kernel gate rejects");
    }

    /**
     * the coverage utilization a multi-asset deposit returns is set entirely by its senior seed leg (ST_DEPOSIT),
     * the BPT join leg (LPT_DEPOSIT) never moves coverage: the seed lands exactly on WAD then a further seed wei
     * crosses to WAD + 1, the value the kernel coverage gate lets through then rejects
     * Arithmetic: minting senior to collateral NAV 2000e18 against jtEffectiveNAV 200e18 gives coverageUtilization
     * exactly 1e18, one more wei of senior gives ceil((2000e18 + 1) * 0.1e18 / 200e18) = 1e18 + 1
     */
    function test_PostOp_coverageGate_lptMultiAssetDepositExactBoundary() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        // Seed leg mints senior to collateral 2000e18, landing coverage exactly on WAD
        SyncedAccountingState memory afterSeed =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(2000e18)), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
        assertEq(afterSeed.coverageUtilizationWAD, WAD, "the senior seed leg lands coverage exactly on WAD");
        // Join leg books the BPT depth without moving coverage
        SyncedAccountingState memory afterJoin =
            kernel.doPostOp(Operation.LPT_DEPOSIT, toNAVUnits(uint256(2000e18)), toNAVUnits(uint256(150e18)), ZERO_NAV_UNITS);
        assertEq(afterJoin.coverageUtilizationWAD, WAD, "the join leg does not move coverage");
        // A further senior seed wei crosses the coverage boundary, the value the kernel gate rejects
        SyncedAccountingState memory afterExtra =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(2000e18 + 1)), toNAVUnits(uint256(150e18)), ZERO_NAV_UNITS);
        assertEq(afterExtra.coverageUtilizationWAD, WAD + 1, "one more senior wei crosses WAD, the would-breach value the kernel gate rejects");
    }

    /// an in-kind LPT deposit never adds senior exposure, so its coverage utilization is passthrough even under a
    /// breach: pre-minted BPT can only move the liquidity mark, only a multi-asset deposit's senior seed leg moves coverage
    function test_PostOp_gateExemptions_lptDepositPassesCoverageBreach() public {
        _seedState(SEED_ST_EFF, 50e18, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LPT_DEPOSIT, toNAVUnits(uint256(1050e18)), toNAVUnits(uint256(150e18)), ZERO_NAV_UNITS);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage breached yet the in-kind lt deposit passed");
        assertLe(state.liquidityUtilizationWAD, WAD, "the liquidity requirement itself is satisfied");
    }

    /**
     * the JT_REDEMPTION coverage utilization the post-op returns lands exactly on WAD at the boundary and crosses
     * to WAD + 1 one wei past it, the value the kernel coverage gate lets through then rejects
     * Arithmetic: from the (collateral 1100e18, stEff 900e18, jtEff 200e18) checkpoint, redeeming junior down to
     * jtEffectiveNAV 100e18 lands collateral NAV 1000e18: coverageUtilization = ceil(1000e18 * 0.1e18 / 100e18) = 1e18
     * exactly, while one more redeemed wei gives ceil((1000e18 - 1) * 0.1e18 / (100e18 - 1)) = 1e18 + 1 since
     * (1e20 - 1) * 1e18 < 1e38 - 0.1e18 leaves a 0.9e18 remainder
     */
    function test_PostOp_coverageGate_jtRedeemExactBoundary() public {
        _seedState(900e18, SEED_JT_EFF, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPostOp(Operation.JT_REDEMPTION, toNAVUnits(uint256(1000e18)), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
        assertEq(state.coverageUtilizationWAD, WAD, "coverage utilization lands exactly on WAD, the kernel gate lets it through");
        state = kernel.doPostOp(Operation.JT_REDEMPTION, toNAVUnits(uint256(1000e18 - 1)), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
        assertEq(state.coverageUtilizationWAD, WAD + 1, "one more redeemed wei crosses WAD, the would-breach value the kernel gate rejects");
    }

    /**
     * the ST_DEPOSIT liquidity utilization the post-op returns lands exactly on WAD at the boundary and crosses to
     * WAD + 1 one wei past it, the value the kernel liquidity gate lets through then rejects
     * Arithmetic: with lptRawNAV 100e18 and minLiquidity 0.05e18, depositing to stEffectiveNAV 2000e18 gives
     * liquidityUtilization = ceil(2000e18 * 0.05e18 / 100e18) = 1e18 exactly, one more wei adds a 5e16 remainder so the
     * ceil lands on 1e18 + 1 (the 300e18 junior buffer keeps coverageUtilization at ceil(2300e18 * 0.1e18 / 300e18)
     * = 766666666666666667, clear of its gate)
     */
    function test_PostOp_liquidityGate_stDepositExactBoundary() public {
        _seedState(SEED_ST_EFF, 300e18, 0, 100e18, MarketState.PERPETUAL);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(2300e18)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS);
        assertEq(state.liquidityUtilizationWAD, WAD, "liquidity utilization lands exactly on WAD, the kernel gate lets it through");
        state = kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(2300e18 + 1)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS);
        assertEq(state.liquidityUtilizationWAD, WAD + 1, "one more senior wei crosses WAD, the would-breach value the kernel gate rejects");
    }

    /**
     * a multi-asset deposit raises the senior exposure ahead of the BPT depth: the senior seed leg (ST_DEPOSIT)
     * transiently pushes liquidity past WAD, then the BPT join leg (LPT_DEPOSIT) deepens the pool and heals it to
     * exactly WAD. A deeper seed whose extra senior outpaces the extra BPT wei settles at WAD + 1, the value the
     * kernel liquidity gate lets through then rejects at the flow's settled state
     * Arithmetic: senior to stEffectiveNAV 2020e18 against lptRawNAV 101e18 gives liquidityUtilization = ceil(2020e18 * 0.05e18
     * / 101e18) = 1e18 exactly. A deeper seed adds 21 wei of senior against one BPT wei, so the numerator grows by
     * 21 * 5e16 = 1.05e18 while the denominator threshold grows by only 1e18, landing the ceil on 1e18 + 1
     */
    function test_PostOp_liquidityGate_lptMultiAssetDepositExactBoundary() public {
        _seedState(SEED_ST_EFF, 300e18, 0, 100e18, MarketState.PERPETUAL);
        // Seed leg mints senior to stEffectiveNAV 2020e18 ahead of the join, transiently breaching liquidity
        SyncedAccountingState memory afterSeed =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(2320e18)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS);
        assertGt(afterSeed.liquidityUtilizationWAD, WAD, "the senior seed leg transiently breaches liquidity before the join deepens the pool");
        // Join leg deepens the pool to lptRawNAV 101e18, healing liquidity to exactly WAD
        SyncedAccountingState memory afterJoin =
            kernel.doPostOp(Operation.LPT_DEPOSIT, toNAVUnits(uint256(2320e18)), toNAVUnits(uint256(101e18)), ZERO_NAV_UNITS);
        assertEq(afterJoin.liquidityUtilizationWAD, WAD, "the join leg heals liquidity to exactly WAD");
        // A deeper seed then join whose extra senior outpaces the extra BPT wei settles one past WAD
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(2320e18 + 21)), toNAVUnits(uint256(101e18)), ZERO_NAV_UNITS);
        SyncedAccountingState memory afterExtraJoin =
            kernel.doPostOp(Operation.LPT_DEPOSIT, toNAVUnits(uint256(2320e18 + 21)), toNAVUnits(uint256(101e18 + 1)), ZERO_NAV_UNITS);
        assertEq(afterExtraJoin.liquidityUtilizationWAD, WAD + 1, "the extra senior outpaces the extra BPT wei, the settled utilization the kernel gate rejects");
    }

    /**
     * the LPT_REDEMPTION liquidity utilization the post-op returns lands exactly on WAD at the boundary and crosses
     * to WAD + 1 one wei past it, the value the kernel liquidity gate lets through then rejects
     * Arithmetic: redeeming BPT down to lptRawNAV 50e18 gives liquidityUtilization = ceil(1000e18 * 0.05e18 / 50e18) = 1e18
     * exactly, one more redeemed wei gives ceil(5e37 / (5e19 - 1)) = 1e18 + 1 since 5e37 = (5e19 - 1) * 1e18 + 1e18
     */
    function test_PostOp_liquidityGate_lptRedeemExactBoundary() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(SEED_COLLATERAL), toNAVUnits(uint256(50e18)), ZERO_NAV_UNITS);
        assertEq(state.liquidityUtilizationWAD, WAD, "liquidity utilization lands exactly on WAD, the kernel gate lets it through");
        state = kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(SEED_COLLATERAL), toNAVUnits(uint256(50e18 - 1)), ZERO_NAV_UNITS);
        assertEq(state.liquidityUtilizationWAD, WAD + 1, "one more burned BPT wei crosses WAD, the would-breach value the kernel gate rejects");
    }

    /**
     * a multi-asset redeem burns the BPT slice ahead of the senior unwind: the BPT-slice leg (LPT_REDEMPTION)
     * transiently pushes liquidity past WAD, then the senior unwind leg (ST_REDEMPTION) lowers the senior
     * requirement and heals it to exactly WAD. A further burned BPT wei past the healed mark settles at WAD + 1,
     * the value the kernel liquidity gate lets through then rejects
     * Arithmetic: the senior unwind drops senior to 900e18 alongside the slice, so the boundary sits at
     * lptRawNAV 45e18: liquidityUtilization = ceil(900e18 * 0.05e18 / 45e18) = 1e18 exactly, one more burned
     * BPT wei gives ceil(4.5e37 / (4.5e19 - 1)) = 1e18 + 1
     */
    function test_PostOp_liquidityGate_lptMultiAssetRedeemExactBoundary() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        // BPT-slice leg burns depth to 45e18 ahead of the unwind, transiently breaching liquidity against the 1000e18 senior mark
        SyncedAccountingState memory afterSlice =
            kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(SEED_COLLATERAL), toNAVUnits(uint256(45e18)), ZERO_NAV_UNITS);
        assertGt(afterSlice.liquidityUtilizationWAD, WAD, "the BPT-slice leg transiently breaches before the senior unwind lowers the requirement");
        // Senior unwind drops senior to 900e18, healing liquidity to exactly WAD
        SyncedAccountingState memory afterUnwind =
            kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(SEED_COLLATERAL - 100e18), toNAVUnits(uint256(45e18)), ZERO_NAV_UNITS);
        assertEq(afterUnwind.liquidityUtilizationWAD, WAD, "the senior unwind heals liquidity to exactly WAD");
        // One more burned BPT wei past the healed mark crosses WAD, the value the kernel gate rejects
        SyncedAccountingState memory afterExtraSlice =
            kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(SEED_COLLATERAL - 100e18), toNAVUnits(uint256(45e18 - 1)), ZERO_NAV_UNITS);
        assertEq(afterExtraSlice.liquidityUtilizationWAD, WAD + 1, "one more burned BPT wei crosses WAD, the would-breach value the kernel gate rejects");
    }

    /**
     * an in-kind BPT-only LPT deposit that IMPROVES a breached liquidity utilization returns a lowered utilization
     * even when the breach is not fully healed, the value the kernel gate exempts
     *
     * An in-kind LPT deposit can only add pooled depth: it raises lptRawNAV, never the senior exposure, so every
     * BPT-only deposit strictly lowers liquidity utilization and is a pure restoring force on a breach. The kernel
     * liquidity gate therefore exempts LPT_DEPOSIT, healing capital (external LPT deposits drawn in by a high
     * liquidity premium) is never blocked mid-breach
     * NOTE: this pins the fix for the previously documented wart where the gate blocked partially-healing
     * deposits and only a fully-healing deposit could enter
     */
    function test_PostOp_liquidityGate_lptDepositHealingPassesUnderBreach() public {
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, 10e18, MarketState.PERPETUAL);
        // A BPT-only deposit lifting lptRawNAV from 10e18 to 25e18 improves liquidityUtilization from 5e18 to 2e18 and passes
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LPT_DEPOSIT, toNAVUnits(SEED_COLLATERAL), toNAVUnits(uint256(25e18)), ZERO_NAV_UNITS);
        assertEq(state.liquidityUtilizationWAD, 2e18, "the partially healing deposit lands mid-breach and still passes");
        // A follow-up deposit healing the breach entirely (lptRawNAV 50e18) lands at exactly WAD
        state = kernel.doPostOp(Operation.LPT_DEPOSIT, toNAVUnits(SEED_COLLATERAL), toNAVUnits(uint256(50e18)), ZERO_NAV_UNITS);
        assertEq(state.liquidityUtilizationWAD, WAD, "a fully healing lt deposit lands at exactly WAD");
    }

    /**
     * ST_REDEMPTION and JT_DEPOSIT settle and return utilizations the kernel gate exempts from BOTH breaches
     * NOTE an ST redemption with a bonus consumes the junior buffer and can worsen coverage, but the kernel
     * exempts it by design, bounding the bonus to be utilization-neutral
     */
    function test_PostOp_gateExemptions_stRedeemAndJTDepositPassBothBreaches() public {
        _seedState(SEED_ST_EFF, 50e18, 0, 10e18, MarketState.PERPETUAL);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(uint256(1040e18)), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage breached yet the st redemption passed");
        assertGt(state.liquidityUtilizationWAD, WAD, "liquidity breached yet the st redemption passed");
        state = kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(uint256(1041e18)), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage breached yet the jt deposit passed");
        assertGt(state.liquidityUtilizationWAD, WAD, "liquidity breached yet the jt deposit passed");
    }

    /// JT_REDEMPTION settles under a liquidity breach the kernel gate exempts because a junior redemption cannot reduce pooled depth
    function test_PostOp_gateExemptions_jtRedeemPassesLiquidityBreach() public {
        _seedFlatWithLPT(10e18);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.JT_REDEMPTION, toNAVUnits(SEED_COLLATERAL - 50e18), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS);
        assertGt(state.liquidityUtilizationWAD, WAD, "liquidity breached yet the jt redemption passed");
        assertLe(state.coverageUtilizationWAD, WAD, "its own coverage gate was satisfied");
    }

    /// LPT_REDEMPTION settles under a coverage breach the kernel gate exempts because a liquidity redemption cannot add senior exposure
    function test_PostOp_gateExemptions_lptRedeemPassesCoverageBreach() public {
        _seedState(SEED_ST_EFF, 50e18, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(uint256(1050e18)), toNAVUnits(uint256(60e18)), ZERO_NAV_UNITS);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage breached yet the lt redemption passed");
        assertLe(state.liquidityUtilizationWAD, WAD, "its own liquidity gate was satisfied");
    }

    /**
     * a multi-asset redemption returns a coverage utilization the kernel gate exempts because unwinding senior
     * exposure can only improve coverage: the senior-unwind leg (ST_REDEMPTION) settles under a coverage breach
     * NOTE a redemption with a bonus consumes the junior buffer and can worsen coverage, but the kernel exempts
     * it by design, bounding the bonus to be utilization-neutral, mirroring ST_REDEMPTION
     */
    function test_PostOp_gateExemptions_lptMultiAssetRedeemPassesCoverageBreach() public {
        _seedState(SEED_ST_EFF, 50e18, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        // Leg 1: the BPT slice burns depth to 60e18, the collateral cannot move
        kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(uint256(1050e18)), toNAVUnits(uint256(60e18)), ZERO_NAV_UNITS);
        // Leg 2: the senior unwind reduces collateral to 1040e18 under a coverage breach
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(uint256(1040e18)), toNAVUnits(uint256(60e18)), ZERO_NAV_UNITS);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage breached yet the multi-asset lt redemption settled");
        assertLe(state.liquidityUtilizationWAD, WAD, "its own liquidity gate was satisfied");
    }

    /// commitLiquidityProviderTrancheRawNAV writes the committed liquidity raw NAV
    function test_Commit_writesLastLPTRawNAV() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        kernel.doCommit(toNAVUnits(uint256(77e18)));
        assertEq(toUint256(accountant.getState().lastLPTRawNAV), 77e18, "lt raw NAV committed");
    }

    /**
     * the committed liquidity raw NAV drives the next accrual's liquidity utilization and the
     * maxSTDeposit liquidity leg
     * Derivation: liquidityUtilization = ceil(1000e18 * 0.05e18 / 77e18) = 649350649350649351 (remainder forces the ceil up),
     * the coverage leg is floor(200e18 * 1e18 / 0.1e18) - 1200e18 = 800e18 and the liquidity leg is
     * floor(77e18 * 1e18 / 0.05e18) - 1000e18 = 540e18, so the min is the 540e18 liquidity leg
     */
    function test_Commit_affectsNextAccrualUtilizationAndMaxSTDeposit() public {
        _seedAndInitAccrual();
        kernel.doCommit(toNAVUnits(uint256(77e18)));
        vm.warp(block.timestamp + 100);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        assertEq(lptYDM.lastYieldShareUtilizationWAD(), 649_350_649_350_649_351, "lt ydm consulted with the committed-lt liquidity utilization");
        assertEq(toUint256(accountant.maxSTDeposit(_checkpointState())), 540e18, "liquidity leg reflects the committed lt raw NAV");
    }

    /**
     * Adversarial sequencing: commitLiquidityProviderTrancheRawNAV itself computes no gate, a kernel commit can park
     * the liquidity mark far below the senior liquidity floor, and every later operation then returns a breaching
     * liquidity utilization, the value the kernel gate rejects. Pins that any kernel path committing a mark it did
     * not freshly compute silently arms the liquidity gate against every later operation
     * Derivation: the 10e18 commit puts liquidityUtilization at ceil(1000e18 * 0.05e18 / 10e18) = 5e18, so a
     * 1 wei senior deposit returns ceil((1000e18 + 1) * 0.05e18 / 10e18) > WAD, and a further BPT redemption
     * against the deepened senior mark returns a still-larger liquidity utilization > WAD
     */
    function test_Commit_isUngatedAndArmsBothGatesForLaterOperations() public {
        _seedFlatWithLPT(SEED_LPT_RAW);
        // The breaching commit passes, no gate, no revert
        kernel.doCommit(toNAVUnits(uint256(10e18)));
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastLPTRawNAV), 10e18, "the breaching mark is committed verbatim");
        assertEq(toUint256(s.lastSTEffectiveNAV), SEED_ST_EFF, "no other checkpoint moves on a commit");
        assertEq(toUint256(s.lastJTEffectiveNAV), SEED_JT_EFF, "jt checkpoint untouched");

        // A later senior deposit returns a breaching liquidity utilization, the value the kernel gate rejects
        SyncedAccountingState memory afterDeposit =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 1), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS);
        assertGt(afterDeposit.liquidityUtilizationWAD, WAD, "the armed liquidity gate breaches on the later senior deposit");
        // A later BPT redemption burning the mark further returns a still-breaching liquidity utilization
        SyncedAccountingState memory afterRedeem =
            kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(SEED_COLLATERAL + 1), toNAVUnits(uint256(10e18 - 1)), ZERO_NAV_UNITS);
        assertGt(afterRedeem.liquidityUtilizationWAD, WAD, "the armed liquidity gate breaches on the later BPT redemption");
    }
}
