// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { stdError } from "../../../lib/forge-std/src/StdError.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { WAD, ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { MarketState, Operation, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { ASSETS_MUST_BE_NON_NEGATIVE, NAV_UNIT, toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { AccountantTestBase } from "../../utils/AccountantTestBase.sol";

/**
 * @title Test_PostOpSync_Accountant
 * @notice postOpSyncTrancheAccounting and commitLiquidityTrancheRawNAV: the per-operation delta-shape
 *         requires on the single collateral delta, the effective NAV bookkeeping of each operation, the
 *         self-liquidation bonus split, the coverage and liquidity gates at their exact WAD boundaries with
 *         per-operation exemptions, conservation over every valid shape, and the committed liquidity mark's
 *         downstream effects
 * @notice The LT flows are split per variant: LT_DEPOSIT and LT_REDEEM are the in-kind ops that can only
 *         move the liquidity mark (and, for redeem, hand out idle premium shares), LT_MULTI_ASSET_DEPOSIT
 *         and LT_MULTI_ASSET_REDEEM are the underlying-asset ops that can also mint or unwind senior
 *         exposure, so each branch pins the exact deltas its flow can produce and nothing more
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
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 123e18), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF + 123e18, "st effective NAV grows by the deposited value");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF, "jt effective NAV untouched");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastCollateralNAV), SEED_COLLATERAL + 123e18, "collateral NAV committed");
        assertEq(toUint256(s.lastSTEffectiveNAV), SEED_ST_EFF + 123e18, "st effective NAV committed");
    }

    /// an ST deposit with a zero collateral delta violates the shape require: a deposit that added no
    /// collateral value would let the kernel mint senior claims against nothing, so value must verifiably arrive
    function test_RevertIf_STDepositZeroCollateralDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// an ST deposit with a negative collateral delta violates the shape require: value leaving during a
    /// deposit is an unsynced loss that must run the waterfall (so coverage applies), never a checkpoint commit
    function test_RevertIf_STDepositNegativeCollateralDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_COLLATERAL - 1), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// an ST deposit with a nonzero liquidity raw NAV delta violates the shape require in both directions: a
    /// senior deposit never touches the pooled BPT, so any motion in the liquidity mark is an unsynced pool event
    function test_RevertIf_STDepositNonzeroLTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 10e18), toNAVUnits(SEED_LT_RAW + 1), ZERO_NAV_UNITS, false);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 10e18), toNAVUnits(SEED_LT_RAW - 1), ZERO_NAV_UNITS, false);
    }

    /// an ST deposit with a nonzero self-liquidation bonus value violates the shape require: the bonus is a
    /// junior-funded sweetener that exists only on senior redemptions and would debit JT with nothing redeemed
    function test_RevertIf_STDepositNonzeroBonus() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 10e18), toNAVUnits(SEED_LT_RAW), toNAVUnits(uint256(1)), false);
    }

    /// a JT deposit adds the collateral delta to the junior effective NAV and commits the checkpoint :
    /// fresh junior capital immediately deepens the first-loss buffer that covers senior
    function test_PostOp_JTDeposit_addsDeltaToJTEffective() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 45e18), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF + 45e18, "jt effective NAV grows by the deposited value");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF, "st effective NAV untouched");
        assertEq(toUint256(accountant.getState().lastJTEffectiveNAV), SEED_JT_EFF + 45e18, "jt effective NAV committed");
    }

    /// a JT deposit with a zero collateral delta violates the shape require: junior claims may only be
    /// minted against value that verifiably arrived, else the buffer is diluted for free
    function test_RevertIf_JTDepositZeroCollateralDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// a JT deposit with a negative collateral delta violates the shape require: value leaving during a
    /// deposit is an unsynced loss that must run the waterfall before any checkpoint commit
    function test_RevertIf_JTDepositNegativeCollateralDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_COLLATERAL - 1), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// a JT deposit with a nonzero liquidity raw NAV delta violates the shape require in both directions: a
    /// junior deposit never touches the pooled BPT, so a moving liquidity mark signals an unsynced pool event
    function test_RevertIf_JTDepositNonzeroLTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 10e18), toNAVUnits(SEED_LT_RAW + 1), ZERO_NAV_UNITS, false);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 10e18), toNAVUnits(SEED_LT_RAW - 1), ZERO_NAV_UNITS, false);
    }

    /// a JT deposit with a nonzero self-liquidation bonus value violates the shape require: the bonus exists
    /// only on senior redemptions, where junior pays to retire senior exposure, never on junior entry
    function test_RevertIf_JTDepositNonzeroBonus() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 10e18), toNAVUnits(SEED_LT_RAW), toNAVUnits(uint256(1)), false);
    }

    /// a BPT-only LT deposit (zero collateral delta) books the liquidity raw NAV and leaves both effective NAVs
    /// untouched: pre-minted BPT adds pooled exit depth without creating any senior or junior claim to conserve
    function test_PostOp_LTDepositBPTOnly_leavesEffectiveNAVsUntouched() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LT_RAW + 30e18), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF, "st effective NAV untouched by the pure BPT leg");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF, "jt effective NAV untouched");
        assertEq(toUint256(state.ltRawNAV), SEED_LT_RAW + 30e18, "lt raw NAV reflects the deposit");
        assertEq(toUint256(accountant.getState().lastLTRawNAV), SEED_LT_RAW + 30e18, "lt raw NAV committed");
    }

    /// a multi-asset LT deposit (positive collateral delta) adds the freshly minted senior value to the senior
    /// effective NAV, the ST shares joined into the pool are real new senior exposure that coverage must track
    function test_PostOp_LTMultiAssetDeposit_addsCollateralDeltaToSTEffective() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_MULTI_ASSET_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 50e18), toNAVUnits(SEED_LT_RAW + 20e18), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF + 50e18, "st effective NAV grows by the minted senior value");
        assertEq(toUint256(state.ltRawNAV), SEED_LT_RAW + 20e18, "lt raw NAV reflects the joined BPT value");
        assertEq(toUint256(accountant.getState().lastSTEffectiveNAV), SEED_ST_EFF + 50e18, "st effective NAV committed");
    }

    /// a quote-only multi-asset LT deposit (zero collateral delta) passes and leaves both effective NAVs untouched,
    /// the quote leg joins the pool without minting senior shares so no senior claim is created
    function test_PostOp_LTMultiAssetDeposit_zeroCollateralDeltaPasses() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_MULTI_ASSET_DEPOSIT, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LT_RAW + 30e18), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF, "st effective NAV untouched by the quote-only leg");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF, "jt effective NAV untouched");
        assertEq(toUint256(state.ltRawNAV), SEED_LT_RAW + 30e18, "lt raw NAV reflects the deposit");
    }

    /// an in-kind LT deposit with a nonzero collateral delta violates the shape require in both directions, the
    /// in-kind flow only moves pre-minted BPT so a moving collateral mark is unsynced PnL bypassing the waterfall
    function test_RevertIf_LTDepositNonzeroCollateralDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_DEPOSIT));
        kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 50e18), toNAVUnits(SEED_LT_RAW + 20e18), ZERO_NAV_UNITS, false);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_DEPOSIT));
        kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(SEED_COLLATERAL - 1), toNAVUnits(SEED_LT_RAW + 10e18), ZERO_NAV_UNITS, false);
    }

    /// an LT deposit with a zero liquidity raw NAV delta violates the shape require: a liquidity deposit that
    /// added no pooled depth would mint LT claims against nothing and dilute existing LT holders
    function test_RevertIf_LTDepositZeroLTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_DEPOSIT));
        kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// an LT deposit with a negative liquidity raw NAV delta violates the shape require: pooled depth leaving
    /// during a deposit means the mark embeds an unsynced pool loss that a fresh depositor would be priced into
    function test_RevertIf_LTDepositNegativeLTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_DEPOSIT));
        kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LT_RAW - 1), ZERO_NAV_UNITS, false);
    }

    /// an LT deposit with a nonzero self-liquidation bonus value violates the shape require: the junior-funded
    /// bonus exists only on senior redemptions and has no meaning when liquidity capital enters
    function test_RevertIf_LTDepositNonzeroBonus() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_DEPOSIT));
        kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LT_RAW + 10e18), toNAVUnits(uint256(1)), false);
    }

    /// a multi-asset LT deposit with a negative collateral delta violates the shape require, the flow can
    /// only MINT senior shares so a falling collateral mark is an unsynced loss bypassing the waterfall
    function test_RevertIf_LTMultiAssetDepositNegativeCollateralDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_MULTI_ASSET_DEPOSIT));
        kernel.doPostOp(Operation.LT_MULTI_ASSET_DEPOSIT, toNAVUnits(SEED_COLLATERAL - 1), toNAVUnits(SEED_LT_RAW + 10e18), ZERO_NAV_UNITS, false);
    }

    /// a multi-asset LT deposit with a zero or negative liquidity raw NAV delta violates the shape require, a
    /// liquidity deposit that added no pooled depth would mint LT claims against nothing
    function test_RevertIf_LTMultiAssetDepositNonpositiveLTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_MULTI_ASSET_DEPOSIT));
        kernel.doPostOp(Operation.LT_MULTI_ASSET_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 10e18), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_MULTI_ASSET_DEPOSIT));
        kernel.doPostOp(Operation.LT_MULTI_ASSET_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 10e18), toNAVUnits(SEED_LT_RAW - 1), ZERO_NAV_UNITS, false);
    }

    /// a multi-asset LT deposit with a nonzero self-liquidation bonus value violates the shape require, the
    /// junior-funded bonus exists only on senior redemptions
    function test_RevertIf_LTMultiAssetDepositNonzeroBonus() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_MULTI_ASSET_DEPOSIT));
        kernel.doPostOp(Operation.LT_MULTI_ASSET_DEPOSIT, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LT_RAW + 10e18), toNAVUnits(uint256(1)), false);
    }

    /// an ST redemption without a bonus reduces the senior effective NAV by the full redeemed value
    function test_PostOp_STRedeem_reducesSTEffectiveWithoutBonus() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_REDEEM, toNAVUnits(SEED_COLLATERAL - 50e18), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
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
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_REDEEM, toNAVUnits(SEED_COLLATERAL - 55e18), toNAVUnits(SEED_LT_RAW), toNAVUnits(uint256(5e18)), false);
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF - 5e18, "jt effective NAV funds exactly the bonus");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF - 50e18, "st effective NAV bears the redemption net of the bonus");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(
            toUint256(s.lastCollateralNAV), toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV), "conservation holds through the bonus split"
        );
    }

    /// a bonus exactly equal to the total redeemed value draws everything from JT and leaves the senior effective NAV unchanged
    function test_PostOp_STRedeem_bonusEqualToTotalDrawsAllFromJT() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_REDEEM, toNAVUnits(SEED_COLLATERAL - 10e18), toNAVUnits(SEED_LT_RAW), toNAVUnits(uint256(10e18)), false);
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF, "st effective NAV untouched when the bonus covers the total");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF - 10e18, "jt effective NAV funds the entire redemption");
    }

    /// an ST redemption with a nonzero liquidity raw NAV delta violates the shape require in both directions
    function test_RevertIf_STRedeemNonzeroLTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_REDEEM));
        kernel.doPostOp(Operation.ST_REDEEM, toNAVUnits(SEED_COLLATERAL - 10e18), toNAVUnits(SEED_LT_RAW + 1), ZERO_NAV_UNITS, false);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_REDEEM));
        kernel.doPostOp(Operation.ST_REDEEM, toNAVUnits(SEED_COLLATERAL - 10e18), toNAVUnits(SEED_LT_RAW - 1), ZERO_NAV_UNITS, false);
    }

    /// an ST redemption with a zero total redeemed value violates the shape require
    function test_RevertIf_STRedeemZeroTotal() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_REDEEM));
        kernel.doPostOp(Operation.ST_REDEEM, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /**
     * a positive collateral delta during an ST redemption reverts inside toNAVUnits(int256) with
     * ASSETS_MUST_BE_NON_NEGATIVE, NOT with INVALID_POST_OP_STATE: the total redeemed
     * value is computed before the shape require can run
     */
    function test_RevertIf_STRedeemPositiveCollateralDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(ASSETS_MUST_BE_NON_NEGATIVE.selector);
        kernel.doPostOp(Operation.ST_REDEEM, toNAVUnits(SEED_COLLATERAL + 1), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /**
     * a bonus exceeding the junior effective NAV underflows the raw NAV_UNIT subtraction with an
     * arithmetic panic (0x11), not a custom error: the junior buffer is debited before the senior leg
     */
    function test_RevertIf_STRedeemBonusExceedsJTEffective() public {
        _seedState(SEED_ST_EFF, 5e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        vm.expectRevert(stdError.arithmeticError);
        kernel.doPostOp(Operation.ST_REDEEM, toNAVUnits(SEED_ST_EFF + 5e18 - 10e18), toNAVUnits(SEED_LT_RAW), toNAVUnits(uint256(6e18)), false);
    }

    /**
     * a bonus exceeding the total redeemed value (while within the junior buffer) underflows the
     * total-minus-bonus subtraction with an arithmetic panic (0x11)
     */
    function test_RevertIf_STRedeemBonusExceedsTotal() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(stdError.arithmeticError);
        kernel.doPostOp(Operation.ST_REDEEM, toNAVUnits(SEED_COLLATERAL - 10e18), toNAVUnits(SEED_LT_RAW), toNAVUnits(uint256(11e18)), false);
    }

    /// an in-kind LT redemption (negative liquidity delta alone, zero total) passes and books only the liquidity mark
    function test_PostOp_LTRedeem_negativeLTDeltaAlonePasses() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LT_RAW - 40e18), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.ltRawNAV), SEED_LT_RAW - 40e18, "lt raw NAV reflects the burned BPT slice");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF, "st effective NAV untouched");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF, "jt effective NAV untouched");
        assertEq(toUint256(accountant.getState().lastLTRawNAV), SEED_LT_RAW - 40e18, "lt raw NAV committed");
    }

    /**
     * a multi-asset LT redemption with a zero liquidity delta but a positive total passes: the zero-BPT-slice
     * leg, where the redeemer's BPT slice floors to zero while the embedded senior redemption still unwinds
     * senior venue assets
     */
    function test_PostOp_LTMultiAssetRedeem_zeroLTDeltaWithPositiveTotalPasses() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_MULTI_ASSET_REDEEM, toNAVUnits(SEED_COLLATERAL - 10e18), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF - 10e18, "st effective NAV bears the unwound senior leg");
        assertEq(toUint256(state.ltRawNAV), SEED_LT_RAW, "lt raw NAV untouched by the zero-BPT-slice leg");
    }

    /// a multi-asset LT redemption with both a negative liquidity delta and a positive total passes
    function test_PostOp_LTMultiAssetRedeem_bothLegsPass() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_MULTI_ASSET_REDEEM, toNAVUnits(SEED_COLLATERAL - 10e18), toNAVUnits(SEED_LT_RAW - 40e18), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF - 10e18, "st effective NAV bears the unwound senior leg");
        assertEq(toUint256(state.ltRawNAV), SEED_LT_RAW - 40e18, "lt raw NAV reflects the burned BPT slice");
    }

    /**
     * a multi-asset LT redemption with a self-liquidation bonus reduces the junior effective NAV by exactly
     * the bonus and the senior effective NAV by the total redeemed value minus the bonus, mirroring ST_REDEEM
     * Derivation: total redeemed = 55e18, bonus 5e18: jtEffectiveNAV = 200e18 - 5e18, stEffectiveNAV = 1000e18 - 50e18
     */
    function test_PostOp_LTMultiAssetRedeem_bonusSplitsAcrossJTAndST() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state = kernel.doPostOp(
            Operation.LT_MULTI_ASSET_REDEEM, toNAVUnits(SEED_COLLATERAL - 55e18), toNAVUnits(SEED_LT_RAW - 40e18), toNAVUnits(uint256(5e18)), false
        );
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF - 5e18, "jt effective NAV funds exactly the bonus");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF - 50e18, "st effective NAV bears the redemption net of the bonus");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(
            toUint256(s.lastCollateralNAV), toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV), "conservation holds through the bonus split"
        );
    }

    /// a multi-asset LT redemption with a positive liquidity delta violates the shape require
    function test_RevertIf_LTMultiAssetRedeemPositiveLTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_MULTI_ASSET_REDEEM));
        kernel.doPostOp(Operation.LT_MULTI_ASSET_REDEEM, toNAVUnits(SEED_COLLATERAL - 10e18), toNAVUnits(SEED_LT_RAW + 1), ZERO_NAV_UNITS, false);
    }

    /**
     * a positive collateral delta during a multi-asset LT redemption reverts inside toNAVUnits(int256) with
     * ASSETS_MUST_BE_NON_NEGATIVE, the total redeemed value is computed before the shape require can run,
     * mirroring ST_REDEEM
     */
    function test_RevertIf_LTMultiAssetRedeemPositiveCollateralDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(ASSETS_MUST_BE_NON_NEGATIVE.selector);
        kernel.doPostOp(Operation.LT_MULTI_ASSET_REDEEM, toNAVUnits(SEED_COLLATERAL + 1), toNAVUnits(SEED_LT_RAW - 10e18), ZERO_NAV_UNITS, false);
    }

    /// a bonus exceeding the junior effective NAV underflows the junior debit with an arithmetic panic (0x11),
    /// the junior buffer is debited before the senior leg, mirroring ST_REDEEM
    function test_RevertIf_LTMultiAssetRedeemBonusExceedsJTEffective() public {
        _seedState(SEED_ST_EFF, 5e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        vm.expectRevert(stdError.arithmeticError);
        kernel.doPostOp(
            Operation.LT_MULTI_ASSET_REDEEM, toNAVUnits(SEED_ST_EFF + 5e18 - 10e18), toNAVUnits(SEED_LT_RAW - 1e18), toNAVUnits(uint256(6e18)), false
        );
    }

    /// a bonus exceeding the total redeemed value (while within the junior buffer) underflows the
    /// total-minus-bonus subtraction with an arithmetic panic (0x11), mirroring ST_REDEEM
    function test_RevertIf_LTMultiAssetRedeemBonusExceedsTotal() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(stdError.arithmeticError);
        kernel.doPostOp(Operation.LT_MULTI_ASSET_REDEEM, toNAVUnits(SEED_COLLATERAL - 10e18), toNAVUnits(SEED_LT_RAW - 1e18), toNAVUnits(uint256(11e18)), false);
    }

    /// an in-kind LT redemption with a nonzero collateral delta violates the shape require in both directions,
    /// the in-kind flow only transfers BPT and idle premium shares so the collateral mark may not move
    function test_RevertIf_LTRedeemNonzeroCollateralDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_REDEEM));
        kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(SEED_COLLATERAL - 10e18), toNAVUnits(SEED_LT_RAW - 40e18), ZERO_NAV_UNITS, false);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_REDEEM));
        kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(SEED_COLLATERAL + 1), toNAVUnits(SEED_LT_RAW - 40e18), ZERO_NAV_UNITS, false);
    }

    /// an in-kind LT redemption with a nonzero self-liquidation bonus value violates the shape require, the
    /// bonus exists only where a senior leg is unwound and the in-kind flow never unwinds one
    function test_RevertIf_LTRedeemNonzeroBonus() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_REDEEM));
        kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LT_RAW - 40e18), toNAVUnits(uint256(1)), false);
    }

    /**
     * an LT redemption with a zero liquidity delta and a zero total passes: the in-kind senior-shares-only leg,
     * where the redeemer takes idle premium senior shares in kind. The shares stay in the senior supply, so no
     * raw NAV moves on any tranche and every effective NAV is left untouched
     * NOTE: this pins the fix for the previously flagged edge where a pure senior-share in-kind LT redemption
     * tripped INVALID_POST_OP_STATE despite moving no raw NAV
     */
    function test_PostOp_LTRedeem_zeroLTDeltaZeroTotalPasses() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state = kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.ltRawNAV), SEED_LT_RAW, "lt raw NAV untouched (no BPT slice burned)");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF, "st effective NAV untouched (senior shares stay in supply)");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF, "jt effective NAV untouched");
        assertEq(toUint256(accountant.getState().lastLTRawNAV), SEED_LT_RAW, "committed lt raw NAV untouched");
    }

    /// an LT redemption with a positive liquidity delta violates the shape require
    function test_RevertIf_LTRedeemPositiveLTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_REDEEM));
        kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LT_RAW + 1), ZERO_NAV_UNITS, false);
    }

    /// a JT redemption reduces the junior effective NAV by the total redeemed value and leaves a zero IL untouched
    function test_PostOp_JTRedeem_reducesJTEffectiveWithZeroILUntouched() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_COLLATERAL - 50e18), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
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
        _seedState(1000e18, 200e18, 100e18, SEED_LT_RAW, MarketState.FIXED_TERM);
        SyncedAccountingState memory state = kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(uint256(1140e18)), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.jtEffectiveNAV), 140e18, "jt effective NAV bears the redemption");
        assertEq(toUint256(state.jtImpermanentLoss), 100e18, "il passthrough, never scaled by a redemption");
        assertEq(toUint256(accountant.getState().lastJTImpermanentLoss), 100e18, "committed il untouched");

        state = kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(uint256(1140e18 - 7)), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.jtImpermanentLoss), 100e18, "il untouched by the second redemption");
        assertEq(toUint256(accountant.getState().lastJTImpermanentLoss), 100e18, "committed il still untouched");
        assertEq(uint8(accountant.getState().lastMarketState), uint8(MarketState.FIXED_TERM), "il > 0 keeps the market fixed term (biconditional)");
    }

    /// a JT redemption with a nonzero liquidity raw NAV delta violates the shape require in both directions
    function test_RevertIf_JTRedeemNonzeroLTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_REDEEM));
        kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_COLLATERAL - 10e18), toNAVUnits(SEED_LT_RAW + 1), ZERO_NAV_UNITS, false);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_REDEEM));
        kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_COLLATERAL - 10e18), toNAVUnits(SEED_LT_RAW - 1), ZERO_NAV_UNITS, false);
    }

    /// a JT redemption with a zero total redeemed value violates the shape require
    function test_RevertIf_JTRedeemZeroTotal() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_REDEEM));
        kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_COLLATERAL), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// a positive collateral delta during a JT redemption reverts inside toNAVUnits(int256) with
    /// ASSETS_MUST_BE_NON_NEGATIVE: the total redeemed value is computed before the shape require can run
    function test_RevertIf_JTRedeemPositiveCollateralDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(ASSETS_MUST_BE_NON_NEGATIVE.selector);
        kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_COLLATERAL + 1), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// a JT redemption with a nonzero self-liquidation bonus value violates the shape require
    function test_RevertIf_JTRedeemNonzeroBonus() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_REDEEM));
        kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_COLLATERAL - 10e18), toNAVUnits(SEED_LT_RAW), toNAVUnits(uint256(1)), false);
    }

    /**
     * from any conserved flat checkpoint, every valid post-op shape commits without reverting and the
     * committed checkpoint conserves NAV exactly: the NAV_CONSERVATION_VIOLATION arm is unreachable
     * from conserved checkpoints (any revert or wei of drift here is a REAL divergence)
     */
    function testFuzz_PostOp_conservationHoldsForValidShapes(uint256 _stEff0, uint256 _jtEff0, uint256 _lt0, uint256 _value, uint256 _opSeed) public {
        // Bounds: checkpoint effective NAVs uniform in [1e18, 1e30] (the strategy magnitude bound), the committed
        // liquidity value uniform in [2, 1e30] so an LT redemption always has a withdrawable wei, the op value
        // uniform in [1, 1e18] so redemptions stay inside every tranche, and the op uniform across all eight members
        _stEff0 = bound(_stEff0, 1e18, 1e30);
        _jtEff0 = bound(_jtEff0, 1e18, 1e30);
        _lt0 = bound(_lt0, 2, 1e30);
        _value = bound(_value, 1, 1e18);
        Operation op = Operation(bound(_opSeed, 0, 7));
        _seedState(_stEff0, _jtEff0, 0, _lt0, MarketState.PERPETUAL);
        uint256 collateral0 = _stEff0 + _jtEff0;

        uint256 collateral1 = collateral0;
        uint256 lt1 = _lt0;
        NAV_UNIT bonus = ZERO_NAV_UNITS;
        if (op == Operation.ST_DEPOSIT) {
            collateral1 = collateral0 + _value;
        } else if (op == Operation.ST_REDEEM) {
            // Redeem the value from the collateral with half of it junior-funded as a bonus
            collateral1 = collateral0 - _value;
            bonus = toNAVUnits(_value / 2);
        } else if (op == Operation.JT_DEPOSIT) {
            collateral1 = collateral0 + _value;
        } else if (op == Operation.JT_REDEEM) {
            collateral1 = collateral0 - _value;
        } else if (op == Operation.LT_DEPOSIT) {
            // The in-kind deposit only deepens the liquidity mark
            lt1 = _lt0 + _value;
        } else if (op == Operation.LT_MULTI_ASSET_DEPOSIT) {
            // The multi-asset deposit deepens the liquidity mark and can mint a senior leg
            lt1 = _lt0 + _value;
            collateral1 = collateral0 + (_value / 2);
        } else if (op == Operation.LT_MULTI_ASSET_REDEEM) {
            // The multi-asset redemption burns a BPT slice and unwinds a senior leg with a junior bonus slice
            lt1 = _lt0 - (_value < _lt0 ? _value : _lt0 - 1);
            collateral1 = collateral0 - _value;
            bonus = toNAVUnits(_value / 2);
        } else {
            lt1 = _lt0 - (_value < _lt0 ? _value : _lt0 - 1);
        }
        kernel.doPostOp(op, toNAVUnits(collateral1), toNAVUnits(lt1), bonus, false);

        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(
            toUint256(s.lastCollateralNAV), toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV), "committed checkpoint conserves NAV exactly"
        );
        assertEq(toUint256(s.lastCollateralNAV), collateral1, "collateral NAV committed");
        assertEq(toUint256(s.lastLTRawNAV), lt1, "lt raw NAV committed");
    }

    /**
     * the post-op writes all four NAV checkpoints including lastLTRawNAV, never touches the market state,
     * the stored fixed-term end, or the IL ledger, performs no yield-share accrual, emits no sync event, and
     * returns zero fees and premium with fresh utilizations plus the fixed-term end passthrough
     */
    function test_PostOp_writesAllCheckpointsAndPreservesMarketState() public {
        _seedState(1000e18, 200e18, 100e18, SEED_LT_RAW, MarketState.FIXED_TERM);
        uint32 end = accountant.getState().fixedTermEndTimestamp;
        assertGt(uint256(end), 0, "seed committed a live fixed-term end");
        uint256 jtCallsBefore = jtYDM.yieldShareCallCount();
        uint256 ltCallsBefore = ltYDM.yieldShareCallCount();
        vm.recordLogs();
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(uint256(1200e18)), toNAVUnits(uint256(130e18)), ZERO_NAV_UNITS, false);

        // Returned state: passthroughs, zero fees and premium, fresh utilizations
        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "market state passthrough");
        assertEq(toUint256(state.collateralNAV), 1200e18, "collateral NAV passthrough");
        assertEq(toUint256(state.ltRawNAV), 130e18, "lt raw NAV passthrough");
        assertEq(toUint256(state.stEffectiveNAV), 1000e18, "st effective NAV unchanged by the BPT-only deposit");
        assertEq(toUint256(state.jtEffectiveNAV), 200e18, "jt effective NAV unchanged");
        assertEq(toUint256(state.jtImpermanentLoss), 100e18, "il passthrough");
        assertEq(toUint256(state.ltLiquidityPremium), 0, "no premium accrues on an operation");
        assertEq(toUint256(state.stProtocolFee), 0, "no st fee on an operation");
        assertEq(toUint256(state.jtProtocolFee), 0, "no jt fee on an operation");
        assertEq(toUint256(state.ltProtocolFee), 0, "no lt fee on an operation");
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
        assertEq(toUint256(s.lastLTRawNAV), 130e18, "lt raw NAV committed");
        assertEq(toUint256(s.lastSTEffectiveNAV), 1000e18, "st effective NAV committed");
        assertEq(toUint256(s.lastJTEffectiveNAV), 200e18, "jt effective NAV committed");
        assertEq(toUint256(s.lastJTImpermanentLoss), 100e18, "il ledger untouched");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.FIXED_TERM), "market state never changes in a post-op");
        assertEq(s.fixedTermEndTimestamp, end, "stored fixed-term end untouched");
        assertEq(jtYDM.yieldShareCallCount(), jtCallsBefore, "no jt accrual in a post-op");
        assertEq(ltYDM.yieldShareCallCount(), ltCallsBefore, "no lt accrual in a post-op");
        assertEq(_countAccountantLogs(vm.getRecordedLogs(), IRoycoDayAccountant.TrancheAccountingSynced.selector), 0, "post-op emits no sync event");
    }

    /**
     * enforce = false skips both gates for every operation from a doubly-breached market
     * Breach seed (stEff 1000e18, jtEff 50e18, lt 10e18): coverageUtilization = ceil(1050e18 * 0.1e18 / 50e18) = 2.1e18
     * and liquidityUtilization = ceil(1000e18 * 0.05e18 / 10e18) = 5e18
     */
    function test_PostOp_enforceFalseSkipsBothGatesForEveryOp() public {
        _seedState(SEED_ST_EFF, 50e18, 0, 10e18, MarketState.PERPETUAL);
        // ST_DEPOSIT deepens the coverage breach and still passes (collateral 1050e18 -> 1150e18, stEff 1100e18)
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(1150e18)), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS, false);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage breached after the st deposit");
        assertGt(state.liquidityUtilizationWAD, WAD, "liquidity breached after the st deposit");
        // ST_REDEEM (collateral 1100e18, stEff 1050e18)
        state = kernel.doPostOp(Operation.ST_REDEEM, toNAVUnits(uint256(1100e18)), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS, false);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage still breached after the st redemption");
        // JT_DEPOSIT (collateral 1110e18, jtEff 60e18)
        state = kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(uint256(1110e18)), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS, false);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage still breached after the jt deposit");
        // JT_REDEEM deepens the coverage breach and still passes (collateral 1100e18, jtEff 50e18)
        state = kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(uint256(1100e18)), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS, false);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage still breached after the jt redemption");
        // LT_DEPOSIT under a persisting liquidity breach still passes (lt 15e18)
        state = kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(uint256(1100e18)), toNAVUnits(uint256(15e18)), ZERO_NAV_UNITS, false);
        assertGt(state.liquidityUtilizationWAD, WAD, "liquidity still breached after the lt deposit");
        // LT_REDEEM deepens the liquidity breach and still passes (lt 5e18)
        state = kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(uint256(1100e18)), toNAVUnits(uint256(5e18)), ZERO_NAV_UNITS, false);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage still breached after the lt redemption");
        // LT_MULTI_ASSET_DEPOSIT deepens the coverage breach with a senior leg and still passes (collateral 1150e18, lt 6e18)
        state = kernel.doPostOp(Operation.LT_MULTI_ASSET_DEPOSIT, toNAVUnits(uint256(1150e18)), toNAVUnits(uint256(6e18)), ZERO_NAV_UNITS, false);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage still breached after the multi-asset lt deposit");
        // LT_MULTI_ASSET_REDEEM deepens the liquidity breach with an unwound senior leg and still passes
        state = kernel.doPostOp(Operation.LT_MULTI_ASSET_REDEEM, toNAVUnits(uint256(1100e18)), toNAVUnits(uint256(5e18)), ZERO_NAV_UNITS, false);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage still breached at the end");
        assertGt(state.liquidityUtilizationWAD, WAD, "liquidity still breached at the end");
    }

    /**
     * the coverage gate for ST_DEPOSIT passes at coverage utilization exactly WAD and fires at WAD + 1
     * Arithmetic: the WAD boundary is collateralNAV * minCov / jtEff == WAD, so at jtEffectiveNAV 200e18 and
     * minCoverage 0.1e18 the boundary collateral NAV is 2000e18: coverageUtilization = ceil(2000e18 * 0.1e18 / 200e18)
     * = 1e18 exactly (exact division), while one more wei gives ceil((2000e18 + 1) * 0.1e18 / 200e18) = 1e18 + 1
     * since the product gains a 1e17 remainder
     */
    function test_PostOp_coverageGate_stDepositExactBoundary() public {
        _seedFlatWithLT(200e18);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(2000e18)), toNAVUnits(uint256(200e18)), ZERO_NAV_UNITS, true);
        assertEq(state.coverageUtilizationWAD, WAD, "coverage utilization lands exactly on WAD and passes");
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(2000e18 + 1)), toNAVUnits(uint256(200e18)), ZERO_NAV_UNITS, true);
    }

    /**
     * the coverage gate for LT_MULTI_ASSET_DEPOSIT (senior-minting) passes at exactly WAD and fires at WAD + 1
     * Arithmetic: minting senior to collateral NAV 2000e18 against jtEffectiveNAV 200e18 gives coverageUtilization
     * exactly 1e18, the follow-up wei of senior against a fresh BPT wei gives ceil((2000e18 + 1) * 0.1e18 / 200e18) = 1e18 + 1
     */
    function test_PostOp_coverageGate_ltMultiAssetDepositExactBoundary() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_MULTI_ASSET_DEPOSIT, toNAVUnits(uint256(2000e18)), toNAVUnits(uint256(150e18)), ZERO_NAV_UNITS, true);
        assertEq(state.coverageUtilizationWAD, WAD, "coverage utilization lands exactly on WAD and passes");
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.LT_MULTI_ASSET_DEPOSIT, toNAVUnits(uint256(2000e18 + 1)), toNAVUnits(uint256(150e18 + 1)), ZERO_NAV_UNITS, true);
    }

    /// an in-kind LT deposit passes an enforced coverage breach because pre-minted BPT can never add senior
    /// exposure, only the multi-asset variant sits inside the coverage gate
    function test_PostOp_gateExemptions_ltDepositPassesCoverageBreach() public {
        _seedState(SEED_ST_EFF, 50e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(uint256(1050e18)), toNAVUnits(uint256(150e18)), ZERO_NAV_UNITS, true);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage breached yet the in-kind lt deposit passed");
        assertLe(state.liquidityUtilizationWAD, WAD, "the liquidity requirement itself is satisfied");
    }

    /**
     * the coverage gate for JT_REDEEM passes at exactly WAD and fires at WAD + 1
     * Arithmetic: from the (collateral 1100e18, stEff 900e18, jtEff 200e18) checkpoint, redeeming junior down to
     * jtEffectiveNAV 100e18 lands collateral NAV 1000e18: coverageUtilization = ceil(1000e18 * 0.1e18 / 100e18) = 1e18
     * exactly, while one more redeemed wei gives ceil((1000e18 - 1) * 0.1e18 / (100e18 - 1)) = 1e18 + 1 since
     * (1e20 - 1) * 1e18 < 1e38 - 0.1e18 leaves a 0.9e18 remainder
     */
    function test_PostOp_coverageGate_jtRedeemExactBoundary() public {
        _seedState(900e18, SEED_JT_EFF, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(uint256(1000e18)), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, true);
        assertEq(state.coverageUtilizationWAD, WAD, "coverage utilization lands exactly on WAD and passes");
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(uint256(1000e18 - 1)), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, true);
    }

    /**
     * the liquidity gate for ST_DEPOSIT passes at liquidity utilization exactly WAD and fires at WAD + 1
     * Arithmetic: with ltRawNAV 100e18 and minLiquidity 0.05e18, depositing to stEffectiveNAV 2000e18 gives
     * liquidityUtilization = ceil(2000e18 * 0.05e18 / 100e18) = 1e18 exactly, one more wei adds a 5e16 remainder so the
     * ceil lands on 1e18 + 1 (the 300e18 junior buffer keeps coverageUtilization at ceil(2300e18 * 0.1e18 / 300e18)
     * = 766666666666666667, clear of its gate)
     */
    function test_PostOp_liquidityGate_stDepositExactBoundary() public {
        _seedState(SEED_ST_EFF, 300e18, 0, 100e18, MarketState.PERPETUAL);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(2300e18)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, true);
        assertEq(state.liquidityUtilizationWAD, WAD, "liquidity utilization lands exactly on WAD and passes");
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(2300e18 + 1)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, true);
    }

    /**
     * the liquidity gate for LT_MULTI_ASSET_DEPOSIT passes at exactly WAD and fires at WAD + 1
     * Arithmetic: minting senior to stEffectiveNAV 2020e18 against ltRawNAV 101e18 gives liquidityUtilization = ceil(2020e18 * 0.05e18
     * / 101e18) = 1e18 exactly. The follow-up deposit adds 21 wei of senior against one BPT wei, so the
     * numerator grows by 21 * 5e16 = 1.05e18 while the denominator threshold grows by only 1e18, landing the
     * ceil exactly on 1e18 + 1 (coverageUtilization stays near 0.7733e18 against the 300e18 junior buffer)
     */
    function test_PostOp_liquidityGate_ltMultiAssetDepositExactBoundary() public {
        _seedState(SEED_ST_EFF, 300e18, 0, 100e18, MarketState.PERPETUAL);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_MULTI_ASSET_DEPOSIT, toNAVUnits(uint256(2320e18)), toNAVUnits(uint256(101e18)), ZERO_NAV_UNITS, true);
        assertEq(state.liquidityUtilizationWAD, WAD, "liquidity utilization lands exactly on WAD and passes");
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.LT_MULTI_ASSET_DEPOSIT, toNAVUnits(uint256(2320e18 + 21)), toNAVUnits(uint256(101e18 + 1)), ZERO_NAV_UNITS, true);
    }

    /**
     * the liquidity gate for LT_REDEEM passes at exactly WAD and fires at WAD + 1
     * Arithmetic: redeeming BPT down to ltRawNAV 50e18 gives liquidityUtilization = ceil(1000e18 * 0.05e18 / 50e18) = 1e18
     * exactly, one more redeemed wei gives ceil(5e37 / (5e19 - 1)) = 1e18 + 1 since 5e37 = (5e19 - 1) * 1e18 + 1e18
     */
    function test_PostOp_liquidityGate_ltRedeemExactBoundary() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state = kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(SEED_COLLATERAL), toNAVUnits(uint256(50e18)), ZERO_NAV_UNITS, true);
        assertEq(state.liquidityUtilizationWAD, WAD, "liquidity utilization lands exactly on WAD and passes");
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(SEED_COLLATERAL), toNAVUnits(uint256(50e18 - 1)), ZERO_NAV_UNITS, true);
    }

    /**
     * the liquidity gate for LT_MULTI_ASSET_REDEEM passes at exactly WAD and fires at WAD + 1
     * Arithmetic: the redemption unwinds 100e18 of senior alongside the BPT slice, so the boundary sits at
     * ltRawNAV 45e18: liquidityUtilization = ceil(900e18 * 0.05e18 / 45e18) = 1e18 exactly, one more redeemed
     * BPT wei gives ceil(4.5e37 / (4.5e19 - 1)) = 1e18 + 1
     */
    function test_PostOp_liquidityGate_ltMultiAssetRedeemExactBoundary() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_MULTI_ASSET_REDEEM, toNAVUnits(SEED_COLLATERAL - 100e18), toNAVUnits(uint256(45e18)), ZERO_NAV_UNITS, true);
        assertEq(state.liquidityUtilizationWAD, WAD, "liquidity utilization lands exactly on WAD and passes");
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.LT_MULTI_ASSET_REDEEM, toNAVUnits(SEED_COLLATERAL - 100e18), toNAVUnits(uint256(45e18 - 1)), ZERO_NAV_UNITS, true);
    }

    /**
     * an in-kind BPT-only LT deposit that IMPROVES a breached liquidity utilization passes under enforcement
     * even when the breach is not fully healed
     *
     * An in-kind LT deposit can only add pooled depth: it raises ltRawNAV, never the senior exposure, so every
     * BPT-only deposit strictly lowers liquidity utilization and is a pure restoring force on a breach. The
     * liquidity gate therefore exempts LT_DEPOSIT, healing capital (external LT deposits drawn in by a high
     * liquidity premium) is never blocked mid-breach
     * NOTE: this pins the fix for the previously documented wart where the gate blocked partially-healing
     * deposits and only a fully-healing deposit could enter under enforcement
     */
    function test_PostOp_liquidityGate_ltDepositHealingPassesUnderBreach() public {
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, 10e18, MarketState.PERPETUAL);
        // A BPT-only deposit lifting ltRawNAV from 10e18 to 25e18 improves liquidityUtilization from 5e18 to 2e18 and passes
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(SEED_COLLATERAL), toNAVUnits(uint256(25e18)), ZERO_NAV_UNITS, true);
        assertEq(state.liquidityUtilizationWAD, 2e18, "the partially healing deposit lands mid-breach and still passes");
        // A follow-up deposit healing the breach entirely (ltRawNAV 50e18) lands at exactly WAD
        state = kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(SEED_COLLATERAL), toNAVUnits(uint256(50e18)), ZERO_NAV_UNITS, true);
        assertEq(state.liquidityUtilizationWAD, WAD, "a fully healing lt deposit lands at exactly WAD");
    }

    /**
     * ST_REDEEM and JT_DEPOSIT pass BOTH breached gates with enforcement on
     * NOTE an ST redemption with a bonus consumes the junior buffer and can worsen coverage, but the
     * accountant exempts it by design: the kernel bounds the bonus to be utilization-neutral
     */
    function test_PostOp_gateExemptions_stRedeemAndJTDepositPassBothBreaches() public {
        _seedState(SEED_ST_EFF, 50e18, 0, 10e18, MarketState.PERPETUAL);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_REDEEM, toNAVUnits(uint256(1040e18)), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS, true);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage breached yet the st redemption passed");
        assertGt(state.liquidityUtilizationWAD, WAD, "liquidity breached yet the st redemption passed");
        state = kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(uint256(1041e18)), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS, true);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage breached yet the jt deposit passed");
        assertGt(state.liquidityUtilizationWAD, WAD, "liquidity breached yet the jt deposit passed");
    }

    /// JT_REDEEM passes an enforced liquidity breach because a junior redemption cannot reduce pooled depth
    function test_PostOp_gateExemptions_jtRedeemPassesLiquidityBreach() public {
        _seedFlatWithLT(10e18);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_COLLATERAL - 50e18), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS, true);
        assertGt(state.liquidityUtilizationWAD, WAD, "liquidity breached yet the jt redemption passed");
        assertLe(state.coverageUtilizationWAD, WAD, "its own coverage gate was satisfied");
    }

    /// LT_REDEEM passes an enforced coverage breach because a liquidity redemption cannot add senior exposure
    function test_PostOp_gateExemptions_ltRedeemPassesCoverageBreach() public {
        _seedState(SEED_ST_EFF, 50e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(uint256(1050e18)), toNAVUnits(uint256(60e18)), ZERO_NAV_UNITS, true);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage breached yet the lt redemption passed");
        assertLe(state.liquidityUtilizationWAD, WAD, "its own liquidity gate was satisfied");
    }

    /**
     * LT_MULTI_ASSET_REDEEM passes an enforced coverage breach because unwinding senior exposure can only
     * improve coverage
     * NOTE a redemption with a bonus consumes the junior buffer and can worsen coverage, but the accountant
     * exempts it by design, the kernel bounds the bonus to be utilization-neutral, mirroring ST_REDEEM
     */
    function test_PostOp_gateExemptions_ltMultiAssetRedeemPassesCoverageBreach() public {
        _seedState(SEED_ST_EFF, 50e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_MULTI_ASSET_REDEEM, toNAVUnits(uint256(1040e18)), toNAVUnits(uint256(60e18)), ZERO_NAV_UNITS, true);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage breached yet the multi-asset lt redemption passed");
        assertLe(state.liquidityUtilizationWAD, WAD, "its own liquidity gate was satisfied");
    }

    /// commitLiquidityTrancheRawNAV writes the committed liquidity raw NAV with its exact event
    function test_Commit_writesLastLTRawNAVWithEvent() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.LiquidityTrancheRawNAVCommitted(toNAVUnits(uint256(77e18)));
        kernel.doCommit(toNAVUnits(uint256(77e18)));
        assertEq(toUint256(accountant.getState().lastLTRawNAV), 77e18, "lt raw NAV committed");
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
        assertEq(ltYDM.lastYieldShareUtilizationWAD(), 649_350_649_350_649_351, "lt ydm consulted with the committed-lt liquidity utilization");
        assertEq(toUint256(accountant.maxSTDeposit(_checkpointState())), 540e18, "liquidity leg reflects the committed lt raw NAV");
    }

    /**
     * Adversarial sequencing: commitLiquidityTrancheRawNAV itself enforces NO gate: a kernel commit can park
     * the liquidity mark far below the senior liquidity floor without reverting, and only the NEXT enforced
     * operation observes the breach. Pins that gate enforcement is deferred to operations, so any kernel path
     * that commits a mark it did not freshly compute silently arms both gates against every later operation
     * Derivation: the 10e18 commit puts liquidityUtilization at ceil(1000e18 * 0.05e18 / 10e18) = 5e18, so a
     * 1 wei enforced senior deposit computes ceil((1000e18 + 1) * 0.05e18 / 10e18) > WAD and reverts,
     * and a 1 wei enforced BPT redemption computes ceil(1000e18 * 0.05e18 / (10e18 - 1)) > WAD and reverts
     */
    function test_Commit_isUngatedAndArmsBothGatesForLaterOperations() public {
        _seedFlatWithLT(SEED_LT_RAW);
        // The breaching commit passes with only its event, no gate, no revert
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.LiquidityTrancheRawNAVCommitted(toNAVUnits(uint256(10e18)));
        kernel.doCommit(toNAVUnits(uint256(10e18)));
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastLTRawNAV), 10e18, "the breaching mark is committed verbatim");
        assertEq(toUint256(s.lastSTEffectiveNAV), SEED_ST_EFF, "no other checkpoint moves on a commit");
        assertEq(toUint256(s.lastJTEffectiveNAV), SEED_JT_EFF, "jt checkpoint untouched");

        // Every later enforced operation that the liquidity gate covers now reverts
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 1), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS, true);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(SEED_COLLATERAL), toNAVUnits(uint256(10e18 - 1)), ZERO_NAV_UNITS, true);
    }
}
