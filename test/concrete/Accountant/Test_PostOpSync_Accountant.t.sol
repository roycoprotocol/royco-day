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
 *         requires, the effective NAV bookkeeping of each operation, the self-liquidation bonus split,
 *         the coverage and liquidity gates at their exact WAD boundaries with per-operation exemptions,
 *         conservation over every valid shape, and the committed liquidity mark's downstream effects
 */
contract Test_PostOpSync_Accountant is AccountantTestBase {
    function setUp() public {
        stranger = makeAddr("stranger");
        _deploy(false, _defaultParams());
    }

    /// an ST deposit adds its senior raw NAV delta to the senior effective NAV and commits the checkpoint
    function test_PostOp_STDeposit_addsDeltaToSTEffective() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + 123e18), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_RAW + 123e18, "st effective NAV grows by the deposited value");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW, "jt effective NAV untouched");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTRawNAV), SEED_ST_RAW + 123e18, "st raw NAV committed");
        assertEq(toUint256(s.lastSTEffectiveNAV), SEED_ST_RAW + 123e18, "st effective NAV committed");
    }

    /// an ST deposit with a zero senior raw NAV delta violates the shape require — a deposit that added no
    /// senior value would let the kernel mint senior claims against nothing, so value must verifiably arrive
    function test_RevertIf_STDepositZeroSTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// an ST deposit with a negative senior raw NAV delta violates the shape require — value leaving during a
    /// deposit is an unsynced loss that must run the waterfall (so coverage applies), never a checkpoint commit
    function test_RevertIf_STDepositNegativeSTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW - 1), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// an ST deposit with a positive junior raw NAV delta violates the shape require — a senior deposit never
    /// touches junior assets, so a moving junior mark is unsynced P&L smuggled past yield attribution
    function test_RevertIf_STDepositPositiveJTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + 10e18), toNAVUnits(SEED_JT_RAW + 1), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// an ST deposit with a negative junior raw NAV delta violates the shape require — a junior loss may only
    /// be recognized by a sync, where the waterfall and coverage accounting run, not inside a deposit commit
    function test_RevertIf_STDepositNegativeJTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + 10e18), toNAVUnits(SEED_JT_RAW - 1), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// an ST deposit with a nonzero liquidity raw NAV delta violates the shape require in both directions — a
    /// senior deposit never touches the pooled BPT, so any motion in the liquidity mark is an unsynced pool event
    function test_RevertIf_STDepositNonzeroLTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + 10e18), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW + 1), ZERO_NAV_UNITS, false);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + 10e18), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW - 1), ZERO_NAV_UNITS, false);
    }

    /// an ST deposit with a nonzero self-liquidation bonus value violates the shape require — the bonus is a
    /// junior-funded sweetener that exists only on senior redemptions and would debit JT with nothing redeemed
    function test_RevertIf_STDepositNonzeroBonus() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + 10e18), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW), toNAVUnits(uint256(1)), false);
    }

    /// a JT deposit adds its junior raw NAV delta to the junior effective NAV and commits the checkpoint —
    /// fresh junior capital immediately deepens the first-loss buffer that covers senior
    function test_PostOp_JTDeposit_addsDeltaToJTEffective() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW + 45e18), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + 45e18, "jt effective NAV grows by the deposited value");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_RAW, "st effective NAV untouched");
        assertEq(toUint256(accountant.getState().lastJTEffectiveNAV), SEED_JT_RAW + 45e18, "jt effective NAV committed");
    }

    /// a JT deposit with a zero junior raw NAV delta violates the shape require — junior claims may only be
    /// minted against value that verifiably arrived in the junior mark, else the buffer is diluted for free
    function test_RevertIf_JTDepositZeroJTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// a JT deposit with a negative junior raw NAV delta violates the shape require — value leaving during a
    /// deposit is an unsynced junior loss that must run the waterfall before any checkpoint commit
    function test_RevertIf_JTDepositNegativeJTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW - 1), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// a JT deposit with a positive senior raw NAV delta violates the shape require — a junior deposit never
    /// adds senior exposure, so a rising senior mark is unsynced senior gain bypassing the premium and fee split
    function test_RevertIf_JTDepositPositiveSTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_ST_RAW + 1), toNAVUnits(SEED_JT_RAW + 10e18), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// a JT deposit with a negative senior raw NAV delta violates the shape require — a senior loss surfacing
    /// mid-deposit must be recognized by a sync so junior coverage can absorb it, not committed silently
    function test_RevertIf_JTDepositNegativeSTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_ST_RAW - 1), toNAVUnits(SEED_JT_RAW + 10e18), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// a JT deposit with a nonzero liquidity raw NAV delta violates the shape require in both directions — a
    /// junior deposit never touches the pooled BPT, so a moving liquidity mark signals an unsynced pool event
    function test_RevertIf_JTDepositNonzeroLTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW + 10e18), toNAVUnits(SEED_LT_RAW + 1), ZERO_NAV_UNITS, false);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW + 10e18), toNAVUnits(SEED_LT_RAW - 1), ZERO_NAV_UNITS, false);
    }

    /// a JT deposit with a nonzero self-liquidation bonus value violates the shape require — the bonus exists
    /// only on senior redemptions, where junior pays to retire senior exposure, never on junior entry
    function test_RevertIf_JTDepositNonzeroBonus() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW + 10e18), toNAVUnits(SEED_LT_RAW), toNAVUnits(uint256(1)), false);
    }

    /// a BPT-only LT deposit (zero senior delta) books the liquidity raw NAV and leaves both effective NAVs
    /// untouched — pre-minted BPT adds pooled exit depth without creating any senior or junior claim to conserve
    function test_PostOp_LTDepositBPTOnly_leavesEffectiveNAVsUntouched() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW + 30e18), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_RAW, "st effective NAV untouched by the pure BPT leg");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW, "jt effective NAV untouched");
        assertEq(toUint256(state.ltRawNAV), SEED_LT_RAW + 30e18, "lt raw NAV reflects the deposit");
        assertEq(toUint256(accountant.getState().lastLTRawNAV), SEED_LT_RAW + 30e18, "lt raw NAV committed");
    }

    /// a multi-asset LT deposit (positive senior delta) adds the freshly minted senior value to the senior
    /// effective NAV — the ST shares joined into the pool are real new senior exposure that coverage must track
    function test_PostOp_LTDepositMultiAsset_addsSTDeltaToSTEffective() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state = kernel.doPostOp(
            Operation.LT_DEPOSIT, toNAVUnits(SEED_ST_RAW + 50e18), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW + 20e18), ZERO_NAV_UNITS, false
        );
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_RAW + 50e18, "st effective NAV grows by the minted senior value");
        assertEq(toUint256(state.ltRawNAV), SEED_LT_RAW + 20e18, "lt raw NAV reflects the joined BPT value");
        assertEq(toUint256(accountant.getState().lastSTEffectiveNAV), SEED_ST_RAW + 50e18, "st effective NAV committed");
    }

    /// an LT deposit with a zero liquidity raw NAV delta violates the shape require — a liquidity deposit that
    /// added no pooled depth would mint LT claims against nothing and dilute existing LT holders
    function test_RevertIf_LTDepositZeroLTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_DEPOSIT));
        kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(SEED_ST_RAW + 10e18), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// an LT deposit with a negative liquidity raw NAV delta violates the shape require — pooled depth leaving
    /// during a deposit means the mark embeds an unsynced pool loss that a fresh depositor would be priced into
    function test_RevertIf_LTDepositNegativeLTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_DEPOSIT));
        kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(SEED_ST_RAW + 10e18), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW - 1), ZERO_NAV_UNITS, false);
    }

    /// an LT deposit with a negative senior raw NAV delta violates the shape require — the multi-asset flow can
    /// only MINT senior shares, so a falling senior mark is an unsynced senior loss bypassing the waterfall
    function test_RevertIf_LTDepositNegativeSTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_DEPOSIT));
        kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(SEED_ST_RAW - 1), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW + 10e18), ZERO_NAV_UNITS, false);
    }

    /// an LT deposit with a nonzero junior raw NAV delta violates the shape require in both directions — no LT
    /// flow touches junior assets, so a moving junior mark is unsynced junior P&L outside the coverage accounting
    function test_RevertIf_LTDepositNonzeroJTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_DEPOSIT));
        kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW + 1), toNAVUnits(SEED_LT_RAW + 10e18), ZERO_NAV_UNITS, false);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_DEPOSIT));
        kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW - 1), toNAVUnits(SEED_LT_RAW + 10e18), ZERO_NAV_UNITS, false);
    }

    /// an LT deposit with a nonzero self-liquidation bonus value violates the shape require — the junior-funded
    /// bonus exists only on senior redemptions and has no meaning when liquidity capital enters
    function test_RevertIf_LTDepositNonzeroBonus() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_DEPOSIT));
        kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW + 10e18), toNAVUnits(uint256(1)), false);
    }

    /// an ST redemption without a bonus reduces the senior effective NAV by the full redeemed value
    function test_PostOp_STRedeem_reducesSTEffectiveWithoutBonus() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_REDEEM, toNAVUnits(SEED_ST_RAW - 50e18), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_RAW - 50e18, "st effective NAV bears the full redemption");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW, "jt effective NAV untouched without a bonus");
    }

    /**
     * an ST redemption with a self-liquidation bonus reduces the junior effective NAV by exactly the bonus
     * and the senior effective NAV by the total redeemed value minus the bonus
     * Derivation: total = 50e18 + 5e18 = 55e18, jtEffectiveNAV = 200e18 - 5e18, stEffectiveNAV = 1000e18 - (55e18 - 5e18)
     */
    function test_PostOp_STRedeem_bonusSplitsAcrossJTAndST() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state = kernel.doPostOp(
            Operation.ST_REDEEM, toNAVUnits(SEED_ST_RAW - 50e18), toNAVUnits(SEED_JT_RAW - 5e18), toNAVUnits(SEED_LT_RAW), toNAVUnits(uint256(5e18)), false
        );
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW - 5e18, "jt effective NAV funds exactly the bonus");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_RAW - 50e18, "st effective NAV bears the redemption net of the bonus");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(
            toUint256(s.lastSTRawNAV) + toUint256(s.lastJTRawNAV),
            toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV),
            "conservation holds through the bonus split"
        );
    }

    /// a bonus exactly equal to the total redeemed value draws everything from JT and leaves the senior effective NAV unchanged
    function test_PostOp_STRedeem_bonusEqualToTotalDrawsAllFromJT() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state = kernel.doPostOp(
            Operation.ST_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW - 10e18), toNAVUnits(SEED_LT_RAW), toNAVUnits(uint256(10e18)), false
        );
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_RAW, "st effective NAV untouched when the bonus covers the total");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW - 10e18, "jt effective NAV funds the entire redemption");
    }

    /// an ST redemption with a nonzero liquidity raw NAV delta violates the shape require in both directions
    function test_RevertIf_STRedeemNonzeroLTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_REDEEM));
        kernel.doPostOp(Operation.ST_REDEEM, toNAVUnits(SEED_ST_RAW - 10e18), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW + 1), ZERO_NAV_UNITS, false);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_REDEEM));
        kernel.doPostOp(Operation.ST_REDEEM, toNAVUnits(SEED_ST_RAW - 10e18), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW - 1), ZERO_NAV_UNITS, false);
    }

    /// an ST redemption with a zero total redeemed value violates the shape require
    function test_RevertIf_STRedeemZeroTotal() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_REDEEM));
        kernel.doPostOp(Operation.ST_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /**
     * a positive junior raw NAV delta during an ST redemption reverts inside toNAVUnits(int256) with
     * ASSETS_MUST_BE_NON_NEGATIVE (Units.sol:94-98), NOT with INVALID_POST_OP_STATE — the total redeemed
     * value is computed before the shape require can run
     */
    function test_RevertIf_STRedeemPositiveJTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(ASSETS_MUST_BE_NON_NEGATIVE.selector);
        kernel.doPostOp(Operation.ST_REDEEM, toNAVUnits(SEED_ST_RAW - 10e18), toNAVUnits(SEED_JT_RAW + 1), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// a positive senior raw NAV delta during an ST redemption reverts identically in toNAVUnits(int256)
    function test_RevertIf_STRedeemPositiveSTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(ASSETS_MUST_BE_NON_NEGATIVE.selector);
        kernel.doPostOp(Operation.ST_REDEEM, toNAVUnits(SEED_ST_RAW + 1), toNAVUnits(SEED_JT_RAW - 10e18), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /**
     * a bonus exceeding the junior effective NAV underflows the raw NAV_UNIT subtraction at :267 with an
     * arithmetic panic (0x11), not a custom error — the junior buffer is debited before the senior leg
     */
    function test_RevertIf_STRedeemBonusExceedsJTEffective() public {
        _seedState(SEED_ST_RAW, 5e18, SEED_ST_RAW, 5e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        vm.expectRevert(stdError.arithmeticError);
        kernel.doPostOp(
            Operation.ST_REDEEM, toNAVUnits(SEED_ST_RAW - 10e18), toNAVUnits(uint256(5e18)), toNAVUnits(SEED_LT_RAW), toNAVUnits(uint256(6e18)), false
        );
    }

    /**
     * a bonus exceeding the total redeemed value (while within the junior buffer) underflows the
     * total-minus-bonus subtraction at :269 with an arithmetic panic (0x11)
     */
    function test_RevertIf_STRedeemBonusExceedsTotal() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(stdError.arithmeticError);
        kernel.doPostOp(
            Operation.ST_REDEEM, toNAVUnits(SEED_ST_RAW - 10e18), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW), toNAVUnits(uint256(11e18)), false
        );
    }

    /// an in-kind LT redemption (negative liquidity delta alone, zero total) passes and books only the liquidity mark
    function test_PostOp_LTRedeem_negativeLTDeltaAlonePasses() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW - 40e18), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.ltRawNAV), SEED_LT_RAW - 40e18, "lt raw NAV reflects the burned BPT slice");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_RAW, "st effective NAV untouched");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW, "jt effective NAV untouched");
        assertEq(toUint256(accountant.getState().lastLTRawNAV), SEED_LT_RAW - 40e18, "lt raw NAV committed");
    }

    /**
     * an LT redemption with a zero liquidity delta but a positive total passes — the idle-premium-share-only
     * leg, where the redeemer takes idle premium senior shares without touching the BPT
     * NOTE: this pins the fix for a previously flagged edge (a zero-BPT-slice in-kind LT
     * redemption formerly tripped INVALID_POST_OP_STATE)
     */
    function test_PostOp_LTRedeem_zeroLTDeltaWithPositiveTotalPasses() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(SEED_ST_RAW - 10e18), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_RAW - 10e18, "st effective NAV bears the idle-share redemption");
        assertEq(toUint256(state.ltRawNAV), SEED_LT_RAW, "lt raw NAV untouched by the idle-share-only leg");
    }

    /// a multi-asset LT redemption with both a negative liquidity delta and a positive total passes
    function test_PostOp_LTRedeem_bothLegsPass() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state = kernel.doPostOp(
            Operation.LT_REDEEM, toNAVUnits(SEED_ST_RAW - 10e18), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW - 40e18), ZERO_NAV_UNITS, false
        );
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_RAW - 10e18, "st effective NAV bears the unwound senior leg");
        assertEq(toUint256(state.ltRawNAV), SEED_LT_RAW - 40e18, "lt raw NAV reflects the burned BPT slice");
    }

    /// an LT redemption with a zero liquidity delta and a zero total violates the shape require
    function test_RevertIf_LTRedeemZeroLTDeltaZeroTotal() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_REDEEM));
        kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// an LT redemption with a positive liquidity delta violates the shape require
    function test_RevertIf_LTRedeemPositiveLTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_REDEEM));
        kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW + 1), ZERO_NAV_UNITS, false);
    }

    /// a JT redemption reduces the junior effective NAV by the total redeemed value and leaves a zero IL untouched
    function test_PostOp_JTRedeem_reducesJTEffectiveWithZeroILUntouched() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW - 50e18), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW - 50e18, "jt effective NAV bears the redemption");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_RAW, "st effective NAV untouched");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 0, "zero il stays zero through the redemption");
        assertEq(toUint256(accountant.getState().lastJTCoverageImpermanentLoss), 0, "committed il untouched");
    }

    /**
     * a JT redemption floor-scales a live coverage impermanent loss by the junior effective NAV ratio and
     * persists it immediately, compounding across successive redemptions
     * Derivation from the (900e18, 300e18, 1000e18, 200e18, il 100e18) fixed-term checkpoint:
     *   redeem 60e18: jtEffectiveNAV = 140e18, il = floor(100e18 * 140e18 / 200e18) = 70e18
     *   then redeem 7 wei: jtEffectiveNAV = 140e18 - 7, il = floor(70e18 * (140e18 - 7) / 140e18) = floor(70e18 - 3.5) = 70e18 - 4
     */
    function test_PostOp_JTRedeem_scalesILImmediatelyWithFloor() public {
        _seedState(900e18, 300e18, 1000e18, 200e18, 100e18, SEED_LT_RAW, MarketState.FIXED_TERM);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(uint256(900e18)), toNAVUnits(uint256(240e18)), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.jtEffectiveNAV), 140e18, "jt effective NAV bears the redemption");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 70e18, "il floor-scaled by the effective NAV ratio");
        assertEq(toUint256(accountant.getState().lastJTCoverageImpermanentLoss), 70e18, "scaled il persisted immediately");

        state =
            kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(uint256(900e18)), toNAVUnits(uint256(240e18 - 7)), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 70e18 - 4, "second scaling floors the awkward wei ratio");
        assertEq(toUint256(accountant.getState().lastJTCoverageImpermanentLoss), 70e18 - 4, "compounded il persisted immediately");
    }

    /// a JT redemption with a nonzero liquidity raw NAV delta violates the shape require in both directions
    function test_RevertIf_JTRedeemNonzeroLTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_REDEEM));
        kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW - 10e18), toNAVUnits(SEED_LT_RAW + 1), ZERO_NAV_UNITS, false);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_REDEEM));
        kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW - 10e18), toNAVUnits(SEED_LT_RAW - 1), ZERO_NAV_UNITS, false);
    }

    /// a JT redemption with a zero total redeemed value violates the shape require
    function test_RevertIf_JTRedeemZeroTotal() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_REDEEM));
        kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// a JT redemption with a nonzero self-liquidation bonus value violates the shape require
    function test_RevertIf_JTRedeemNonzeroBonus() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_REDEEM));
        kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW - 10e18), toNAVUnits(SEED_LT_RAW), toNAVUnits(uint256(1)), false);
    }

    /**
     * from any conserved flat checkpoint, every valid post-op shape commits without reverting and the
     * committed checkpoint conserves NAV exactly — the NAV_CONSERVATION_VIOLATION arm at :286 is unreachable
     * from conserved checkpoints (any revert or wei of drift here is a REAL divergence)
     */
    function testFuzz_PostOp_conservationHoldsForValidShapes(uint256 _stRaw0, uint256 _jtRaw0, uint256 _lt0, uint256 _value, uint256 _opSeed) public {
        // Bounds: checkpoint raw NAVs uniform in [1e18, 1e30] (the strategy magnitude bound), the committed
        // liquidity value uniform in [2, 1e30] so an LT redemption always has a withdrawable wei, the op value
        // uniform in [1, 1e18] so redemptions stay inside every tranche, and the op uniform across all six members
        _stRaw0 = bound(_stRaw0, 1e18, 1e30);
        _jtRaw0 = bound(_jtRaw0, 1e18, 1e30);
        _lt0 = bound(_lt0, 2, 1e30);
        _value = bound(_value, 1, 1e18);
        Operation op = Operation(bound(_opSeed, 0, 5));
        _seedState(_stRaw0, _jtRaw0, _stRaw0, _jtRaw0, 0, _lt0, MarketState.PERPETUAL);

        uint256 stRaw1 = _stRaw0;
        uint256 jtRaw1 = _jtRaw0;
        uint256 lt1 = _lt0;
        NAV_UNIT bonus = ZERO_NAV_UNITS;
        if (op == Operation.ST_DEPOSIT) {
            stRaw1 = _stRaw0 + _value;
        } else if (op == Operation.ST_REDEEM) {
            // Redeem the value from senior and half the value from junior, the junior slice provided as a bonus
            stRaw1 = _stRaw0 - _value;
            jtRaw1 = _jtRaw0 - (_value / 2);
            bonus = toNAVUnits(_value / 2);
        } else if (op == Operation.JT_DEPOSIT) {
            jtRaw1 = _jtRaw0 + _value;
        } else if (op == Operation.JT_REDEEM) {
            jtRaw1 = _jtRaw0 - _value;
        } else if (op == Operation.LT_DEPOSIT) {
            lt1 = _lt0 + _value;
            stRaw1 = _stRaw0 + (_value / 2);
        } else {
            lt1 = _lt0 - (_value < _lt0 ? _value : _lt0 - 1);
        }
        kernel.doPostOp(op, toNAVUnits(stRaw1), toNAVUnits(jtRaw1), toNAVUnits(lt1), bonus, false);

        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(
            toUint256(s.lastSTRawNAV) + toUint256(s.lastJTRawNAV),
            toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV),
            "committed checkpoint conserves NAV exactly"
        );
        assertEq(toUint256(s.lastSTRawNAV), stRaw1, "st raw NAV committed");
        assertEq(toUint256(s.lastJTRawNAV), jtRaw1, "jt raw NAV committed");
        assertEq(toUint256(s.lastLTRawNAV), lt1, "lt raw NAV committed");
    }

    /**
     * the post-op writes all five NAV checkpoints including lastLTRawNAV, never touches the market state
     * or the stored fixed-term end, performs no yield-share accrual, emits no sync event, and returns zero
     * fees and premium with fresh utilizations plus the fixed-term end passthrough
     */
    function test_PostOp_writesAllCheckpointsAndPreservesMarketState() public {
        _seedState(900e18, 300e18, 1000e18, 200e18, 100e18, SEED_LT_RAW, MarketState.FIXED_TERM);
        uint32 end = accountant.getState().fixedTermEndTimestamp;
        assertGt(uint256(end), 0, "seed committed a live fixed-term end");
        uint256 jtCallsBefore = jtYDM.yieldShareCallCount();
        uint256 ltCallsBefore = ltYDM.yieldShareCallCount();
        vm.recordLogs();
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(uint256(900e18)), toNAVUnits(uint256(300e18)), toNAVUnits(uint256(130e18)), ZERO_NAV_UNITS, false);

        // Returned state: passthroughs, zero fees and premium, fresh utilizations
        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "market state passthrough");
        assertEq(toUint256(state.stRawNAV), 900e18, "st raw NAV passthrough");
        assertEq(toUint256(state.jtRawNAV), 300e18, "jt raw NAV passthrough");
        assertEq(toUint256(state.ltRawNAV), 130e18, "lt raw NAV passthrough");
        assertEq(toUint256(state.stEffectiveNAV), 1000e18, "st effective NAV unchanged by the BPT-only deposit");
        assertEq(toUint256(state.jtEffectiveNAV), 200e18, "jt effective NAV unchanged");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 100e18, "il passthrough");
        assertEq(toUint256(state.ltLiquidityPremium), 0, "no premium accrues on an operation");
        assertEq(toUint256(state.stProtocolFee), 0, "no st fee on an operation");
        assertEq(toUint256(state.jtProtocolFee), 0, "no jt fee on an operation");
        assertEq(toUint256(state.ltProtocolFee), 0, "no lt fee on an operation");
        assertEq(
            state.coverageUtilizationWAD,
            _specCoverageUtilization(900e18, 300e18, false, DEFAULT_MIN_COVERAGE_WAD, 200e18),
            "fresh coverage utilization, not a placeholder"
        );
        assertEq(
            state.liquidityUtilizationWAD, _specLiquidityUtilization(1000e18, DEFAULT_MIN_LIQUIDITY_WAD, 130e18), "fresh liquidity utilization on the new mark"
        );
        assertEq(state.fixedTermEndTimestamp, end, "fixed-term end passthrough");

        // Committed checkpoints: all five NAVs written, market state and end timestamp untouched
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTRawNAV), 900e18, "st raw NAV committed");
        assertEq(toUint256(s.lastJTRawNAV), 300e18, "jt raw NAV committed");
        assertEq(toUint256(s.lastLTRawNAV), 130e18, "lt raw NAV committed");
        assertEq(toUint256(s.lastSTEffectiveNAV), 1000e18, "st effective NAV committed");
        assertEq(toUint256(s.lastJTEffectiveNAV), 200e18, "jt effective NAV committed");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.FIXED_TERM), "market state never changes in a post-op");
        assertEq(s.fixedTermEndTimestamp, end, "stored fixed-term end untouched");
        assertEq(jtYDM.yieldShareCallCount(), jtCallsBefore, "no jt accrual in a post-op");
        assertEq(ltYDM.yieldShareCallCount(), ltCallsBefore, "no lt accrual in a post-op");
        assertEq(_countAccountantLogs(vm.getRecordedLogs(), IRoycoDayAccountant.TrancheAccountingSynced.selector), 0, "post-op emits no sync event");
    }

    /**
     * enforce = false skips both gates for every operation from a doubly-breached market
     * Breach seed: coverageUtilization = ceil(1000e18 * 0.1e18 / 50e18) = 2e18 and liquidityUtilization = ceil(1000e18 * 0.05e18 / 10e18) = 5e18
     */
    function test_PostOp_enforceFalseSkipsBothGatesForEveryOp() public {
        _seedState(SEED_ST_RAW, 50e18, SEED_ST_RAW, 50e18, 0, 10e18, MarketState.PERPETUAL);
        // ST_DEPOSIT deepens the coverage breach and still passes
        SyncedAccountingState memory state = kernel.doPostOp(
            Operation.ST_DEPOSIT, toNAVUnits(uint256(1100e18)), toNAVUnits(uint256(50e18)), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS, false
        );
        assertGt(state.coverageUtilizationWAD, WAD, "coverage breached after the st deposit");
        assertGt(state.liquidityUtilizationWAD, WAD, "liquidity breached after the st deposit");
        // ST_REDEEM
        state =
            kernel.doPostOp(Operation.ST_REDEEM, toNAVUnits(uint256(1050e18)), toNAVUnits(uint256(50e18)), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS, false);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage still breached after the st redemption");
        // JT_DEPOSIT
        state =
            kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(uint256(1050e18)), toNAVUnits(uint256(60e18)), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS, false);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage still breached after the jt deposit");
        // JT_REDEEM deepens the coverage breach and still passes
        state =
            kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(uint256(1050e18)), toNAVUnits(uint256(50e18)), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS, false);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage still breached after the jt redemption");
        // LT_DEPOSIT under a persisting liquidity breach still passes
        state =
            kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(uint256(1050e18)), toNAVUnits(uint256(50e18)), toNAVUnits(uint256(15e18)), ZERO_NAV_UNITS, false);
        assertGt(state.liquidityUtilizationWAD, WAD, "liquidity still breached after the lt deposit");
        // LT_REDEEM deepens the liquidity breach and still passes
        state = kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(uint256(1050e18)), toNAVUnits(uint256(50e18)), toNAVUnits(uint256(5e18)), ZERO_NAV_UNITS, false);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage still breached at the end");
        assertGt(state.liquidityUtilizationWAD, WAD, "liquidity still breached at the end");
    }

    /**
     * the coverage gate for ST_DEPOSIT passes at coverage utilization exactly WAD and fires at WAD + 1
     * Arithmetic: with jtEffectiveNAV 200e18 and minCoverage 0.1e18, depositing to stRawNAV 2000e18 gives
     * coverageUtilization = ceil(2000e18 * 0.1e18 / 200e18) = 1e18 exactly (exact division), while one more wei gives
     * ceil((2000e18 + 1) * 0.1e18 / 200e18) = 1e18 + 1 since the product gains a 1e17 remainder
     */
    function test_PostOp_coverageGate_stDepositExactBoundary() public {
        _seedFlatWithLT(200e18);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(2000e18)), toNAVUnits(SEED_JT_RAW), toNAVUnits(uint256(200e18)), ZERO_NAV_UNITS, true);
        assertEq(state.coverageUtilizationWAD, WAD, "coverage utilization lands exactly on WAD and passes");
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(2000e18 + 1)), toNAVUnits(SEED_JT_RAW), toNAVUnits(uint256(200e18)), ZERO_NAV_UNITS, true);
    }

    /**
     * the coverage gate for LT_DEPOSIT (multi-asset, senior-minting) passes at exactly WAD and fires at WAD + 1
     * Arithmetic: minting senior to stRawNAV 2000e18 against jtEffectiveNAV 200e18 gives coverageUtilization exactly 1e18, the follow-up
     * wei of senior against a fresh BPT wei gives ceil((2000e18 + 1) * 0.1e18 / 200e18) = 1e18 + 1
     */
    function test_PostOp_coverageGate_ltDepositExactBoundary() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(uint256(2000e18)), toNAVUnits(SEED_JT_RAW), toNAVUnits(uint256(150e18)), ZERO_NAV_UNITS, true);
        assertEq(state.coverageUtilizationWAD, WAD, "coverage utilization lands exactly on WAD and passes");
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(uint256(2000e18 + 1)), toNAVUnits(SEED_JT_RAW), toNAVUnits(uint256(150e18 + 1)), ZERO_NAV_UNITS, true);
    }

    /**
     * the coverage gate for JT_REDEEM passes at exactly WAD and fires at WAD + 1
     * Arithmetic: redeeming junior to jtEffectiveNAV 100e18 gives coverageUtilization = 1e38 / 1e20 = 1e18 exactly, while one more
     * wei gives ceil(1e38 / (1e20 - 1)) = 1e18 + 1 since 1e38 = (1e20 - 1) * 1e18 + 1e18
     */
    function test_PostOp_coverageGate_jtRedeemExactBoundary() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(uint256(100e18)), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, true);
        assertEq(state.coverageUtilizationWAD, WAD, "coverage utilization lands exactly on WAD and passes");
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(uint256(100e18 - 1)), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, true);
    }

    /**
     * the liquidity gate for ST_DEPOSIT passes at liquidity utilization exactly WAD and fires at WAD + 1
     * Arithmetic: with ltRawNAV 100e18 and minLiquidity 0.05e18, depositing to stEffectiveNAV 2000e18 gives
     * liquidityUtilization = ceil(2000e18 * 0.05e18 / 100e18) = 1e18 exactly, one more wei adds a 5e16 remainder so the
     * ceil lands on 1e18 + 1 (the 300e18 junior buffer keeps coverageUtilization at 666666666666666667, clear of its gate)
     */
    function test_PostOp_liquidityGate_stDepositExactBoundary() public {
        _seedState(SEED_ST_RAW, 300e18, SEED_ST_RAW, 300e18, 0, 100e18, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPostOp(
            Operation.ST_DEPOSIT, toNAVUnits(uint256(2000e18)), toNAVUnits(uint256(300e18)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, true
        );
        assertEq(state.liquidityUtilizationWAD, WAD, "liquidity utilization lands exactly on WAD and passes");
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(2000e18 + 1)), toNAVUnits(uint256(300e18)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, true);
    }

    /**
     * the liquidity gate for LT_DEPOSIT (multi-asset) passes at exactly WAD and fires at WAD + 1
     * Arithmetic: minting senior to stEffectiveNAV 2020e18 against ltRawNAV 101e18 gives liquidityUtilization = ceil(2020e18 * 0.05e18
     * / 101e18) = 1e18 exactly. The follow-up deposit adds 21 wei of senior against one BPT wei, so the
     * numerator grows by 21 * 5e16 = 1.05e18 while the denominator threshold grows by only 1e18, landing the
     * ceil exactly on 1e18 + 1 (coverageUtilization stays near 0.6733e18 against the 300e18 junior buffer)
     */
    function test_PostOp_liquidityGate_ltDepositExactBoundary() public {
        _seedState(SEED_ST_RAW, 300e18, SEED_ST_RAW, 300e18, 0, 100e18, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPostOp(
            Operation.LT_DEPOSIT, toNAVUnits(uint256(2020e18)), toNAVUnits(uint256(300e18)), toNAVUnits(uint256(101e18)), ZERO_NAV_UNITS, true
        );
        assertEq(state.liquidityUtilizationWAD, WAD, "liquidity utilization lands exactly on WAD and passes");
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(
            Operation.LT_DEPOSIT, toNAVUnits(uint256(2020e18 + 21)), toNAVUnits(uint256(300e18)), toNAVUnits(uint256(101e18 + 1)), ZERO_NAV_UNITS, true
        );
    }

    /**
     * the liquidity gate for LT_REDEEM passes at exactly WAD and fires at WAD + 1
     * Arithmetic: redeeming BPT down to ltRawNAV 50e18 gives liquidityUtilization = ceil(1000e18 * 0.05e18 / 50e18) = 1e18
     * exactly, one more redeemed wei gives ceil(5e37 / (5e19 - 1)) = 1e18 + 1 since 5e37 = (5e19 - 1) * 1e18 + 1e18
     */
    function test_PostOp_liquidityGate_ltRedeemExactBoundary() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(uint256(50e18)), ZERO_NAV_UNITS, true);
        assertEq(state.liquidityUtilizationWAD, WAD, "liquidity utilization lands exactly on WAD and passes");
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(uint256(50e18 - 1)), ZERO_NAV_UNITS, true);
    }

    /**
     * REAL DIVERGENCE (behavior pinned, adjudication needed): an in-kind BPT-only LT deposit that IMPROVES a
     * breached liquidity utilization but does not fully heal it reverts under enforcement
     *
     * An LT deposit can only add pooled depth: it raises ltRawNAV, never the senior exposure, so every BPT-only
     * deposit strictly lowers liquidity utilization and is a pure restoring force on a breach. One design
     * reading therefore says no deposit should ever be blocked on liquidity, while the competing reading says
     * the minimum-liquidity requirement must hold after EVERY enforced operation, deposits included (the
     * reading maxSTDeposit's liquidity leg encodes). The accountant implements the second: LT_DEPOSIT (and
     * ST_DEPOSIT) sit inside the liquidity gate. The sharp consequence pinned here is that enforcement blocks
     * the exact healing capital (external LT deposits drawn in by a high liquidity premium) that is supposed
     * to close the breach, unless the kernel passes enforce = false for LT deposits. Severity rests on the
     * kernel's flag choice — flagged for adjudication
     */
    function test_PostOp_liquidityGate_blocksHealingLTDepositUnderBreach() public {
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, 10e18, MarketState.PERPETUAL);
        // A BPT-only deposit lifting ltRawNAV from 10e18 to 25e18 improves liquidityUtilization from 5e18 to 2e18 yet reverts
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(uint256(25e18)), ZERO_NAV_UNITS, true);
        // Healing the breach entirely (ltRawNAV 50e18 puts liquidityUtilization at exactly WAD) is the only enforced way in
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(uint256(50e18)), ZERO_NAV_UNITS, true);
        assertEq(state.liquidityUtilizationWAD, WAD, "a fully healing lt deposit passes at exactly WAD");
    }

    /**
     * ST_REDEEM and JT_DEPOSIT pass BOTH breached gates with enforcement on
     * NOTE an ST redemption with a bonus consumes the junior buffer and can worsen coverage, but the
     * accountant exempts it by design — the kernel bounds the bonus to be utilization-neutral
     */
    function test_PostOp_gateExemptions_stRedeemAndJTDepositPassBothBreaches() public {
        _seedState(SEED_ST_RAW, 50e18, SEED_ST_RAW, 50e18, 0, 10e18, MarketState.PERPETUAL);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_REDEEM, toNAVUnits(uint256(990e18)), toNAVUnits(uint256(50e18)), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS, true);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage breached yet the st redemption passed");
        assertGt(state.liquidityUtilizationWAD, WAD, "liquidity breached yet the st redemption passed");
        state = kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(uint256(990e18)), toNAVUnits(uint256(51e18)), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS, true);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage breached yet the jt deposit passed");
        assertGt(state.liquidityUtilizationWAD, WAD, "liquidity breached yet the jt deposit passed");
    }

    /// JT_REDEEM passes an enforced liquidity breach because a junior redemption cannot reduce pooled depth
    function test_PostOp_gateExemptions_jtRedeemPassesLiquidityBreach() public {
        _seedFlatWithLT(10e18);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(uint256(150e18)), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS, true);
        assertGt(state.liquidityUtilizationWAD, WAD, "liquidity breached yet the jt redemption passed");
        assertLe(state.coverageUtilizationWAD, WAD, "its own coverage gate was satisfied");
    }

    /// LT_REDEEM passes an enforced coverage breach because a liquidity redemption cannot add senior exposure
    function test_PostOp_gateExemptions_ltRedeemPassesCoverageBreach() public {
        _seedState(SEED_ST_RAW, 50e18, SEED_ST_RAW, 50e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(uint256(50e18)), toNAVUnits(uint256(60e18)), ZERO_NAV_UNITS, true);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage breached yet the lt redemption passed");
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
     * Derivation: liquidityUtilization = ceil(1000e18 * 0.05e18 / 77e18) = 649350649350649351 (remainder forces the ceil up)
     * and the liquidity leg is floor(77e18 * 1e18 / 0.05e18) - 1000e18 = 540e18 against a 1000e18 coverage leg
     */
    function test_Commit_affectsNextAccrualUtilizationAndMaxSTDeposit() public {
        _seedAndInitAccrual();
        kernel.doCommit(toNAVUnits(uint256(77e18)));
        vm.warp(block.timestamp + 100);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        assertEq(ltYDM.lastYieldShareUtilizationWAD(), 649_350_649_350_649_351, "lt ydm consulted with the committed-lt liquidity utilization");
        assertEq(toUint256(accountant.maxSTDeposit(_checkpointState())), 540e18, "liquidity leg reflects the committed lt raw NAV");
    }

    /**
     * Adversarial sequencing: commitLiquidityTrancheRawNAV itself enforces NO gate — a kernel commit can park
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
        assertEq(toUint256(s.lastSTEffectiveNAV), SEED_ST_RAW, "no other checkpoint moves on a commit");
        assertEq(toUint256(s.lastJTEffectiveNAV), SEED_JT_RAW, "jt checkpoint untouched");

        // Every later enforced operation that the liquidity gate covers now reverts
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + 1), toNAVUnits(SEED_JT_RAW), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS, true);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(uint256(10e18 - 1)), ZERO_NAV_UNITS, true);
    }
}
