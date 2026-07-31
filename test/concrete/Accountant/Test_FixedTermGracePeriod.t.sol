// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { AccountantTestBase } from "../../utils/AccountantTestBase.sol";

/**
 * @title Test_FixedTermGracePeriod
 * @notice The post-deployment fixed-term grace period: a market whose accountant was deployed with a nonzero
 *         grace can never enter a fixed term until FIXED_TERM_COMMENCEABLE_AT_TIMESTAMP (deploy time plus the
 *         grace) has elapsed, no matter what junior impermanent loss a covered loss would otherwise book
 * @dev The grace gate is the seventh perpetual-forcing disjunct in the shared tranche-accounting determination
 *      (block.timestamp < FIXED_TERM_COMMENCEABLE_AT_TIMESTAMP), so it is exercised through the same executed
 *      pre-op sync path (MockAccountantKernel.doPreOp) as every other lock decision. All the loss scenarios reuse
 *      the covered-loss recipe from Test_PremiumDustAndFixedTermEdges: a flat 100e18/30e18 PERPETUAL checkpoint
 *      then a -10e18 collateral loss, which absent the grace enters FIXED_TERM with il 10e18 and a 0.6e18 coverage
 *      utilization well under the 1.1e18 liquidation threshold
 */
contract Test_FixedTermGracePeriod is AccountantTestBase {
    // A thirty day grace, comfortably inside the uint24 seconds ceiling
    uint24 internal constant GRACE_SECONDS = uint24(30 days);

    // Flat PERPETUAL seed shared by every loss scenario (stEffectiveNAV, jtEffectiveNAV, lptRawNAV)
    uint256 internal constant SEED_ST = 100e18;
    uint256 internal constant SEED_JT = 30e18;
    uint256 internal constant SEED_LPT = 10e18;
    // The covered loss target: collateralNAV drops from 130e18 to 120e18
    uint256 internal constant LOSS_COLLATERAL_NAV = 120e18;

    /// @dev Deploys with the given grace, seeds the flat PERPETUAL checkpoint at the current block, then drives the covered -10e18 loss sync and returns its result
    function _deploySeedAndLose(uint24 _graceSeconds) internal returns (SyncedAccountingState memory s) {
        _deployWithGrace(_defaultParams(), _graceSeconds);
        _seedSymmetric(SEED_ST, SEED_JT, SEED_LPT);
        s = kernel.doPreOp(toNAVUnits(LOSS_COLLATERAL_NAV));
    }

    /// @dev Asserts both the returned sync result and the persisted checkpoint report PERPETUAL with the impermanent loss erased
    function _assertPerpetualNoIL(SyncedAccountingState memory _s, string memory _ctx) internal view {
        assertEq(uint8(_s.marketState), uint8(MarketState.PERPETUAL), string.concat(_ctx, ": sync result must stay PERPETUAL"));
        assertEq(toUint256(_s.jtImpermanentLoss), 0, string.concat(_ctx, ": sync result must carry no impermanent loss"));
        IRoycoDayAccountant.RoycoDayAccountantState memory st = accountant.getState();
        assertEq(uint8(st.lastMarketState), uint8(MarketState.PERPETUAL), string.concat(_ctx, ": persisted checkpoint must stay PERPETUAL"));
        assertEq(toUint256(st.lastJTImpermanentLoss), 0, string.concat(_ctx, ": persisted checkpoint must carry no impermanent loss"));
    }

    /// @dev Asserts both the returned sync result and the persisted checkpoint locked into FIXED_TERM with a real impermanent loss
    function _assertFixedTermWithIL(SyncedAccountingState memory _s, string memory _ctx) internal view {
        assertEq(uint8(_s.marketState), uint8(MarketState.FIXED_TERM), string.concat(_ctx, ": sync result must enter FIXED_TERM"));
        assertGt(toUint256(_s.jtImpermanentLoss), 0, string.concat(_ctx, ": sync result must book impermanent loss"));
        IRoycoDayAccountant.RoycoDayAccountantState memory st = accountant.getState();
        assertEq(uint8(st.lastMarketState), uint8(MarketState.FIXED_TERM), string.concat(_ctx, ": persisted checkpoint must be FIXED_TERM"));
        assertGt(toUint256(st.lastJTImpermanentLoss), 0, string.concat(_ctx, ": persisted checkpoint must carry impermanent loss"));
    }

    // =============================
    // The immutable anchors on deploy time plus the grace
    // =============================

    /// @notice FIXED_TERM_COMMENCEABLE_AT_TIMESTAMP is the implementation deploy timestamp plus the grace, so the anchor tracks when the market was created rather than any fixed zero
    function test_commenceableTimestamp_isDeployTimePlusGrace() public {
        vm.warp(5000);
        _deployWithGrace(_defaultParams(), GRACE_SECONDS);
        assertEq(accountant.getState().fixedTermCommenceableAtTimestamp, 5000 + uint256(GRACE_SECONDS), "commenceable = deploy time + grace");
    }

    /// @notice A zero grace makes the commenceable timestamp exactly the deploy time, so a fixed term can commence from the very first block
    function test_commenceableTimestamp_zeroGraceIsDeployTime() public {
        vm.warp(5000);
        _deployWithGrace(_defaultParams(), 0);
        assertEq(accountant.getState().fixedTermCommenceableAtTimestamp, 5000, "zero grace: commenceable = deploy time");
    }

    // =============================
    // Within the grace the market cannot lock no matter what
    // =============================

    /// @notice A covered loss that would otherwise enter FIXED_TERM instead stays PERPETUAL and has its impermanent loss erased while the market is still inside its grace period
    function test_withinGrace_coveredLoss_staysPerpetualAndErasesIL() public {
        SyncedAccountingState memory s = _deploySeedAndLose(GRACE_SECONDS);
        _assertPerpetualNoIL(s, "within grace");
    }

    /// @notice One second before the commenceable timestamp the grace is still active, so the same covered loss cannot lock
    function test_oneSecondBeforeCommenceable_staysPerpetual() public {
        _deployWithGrace(_defaultParams(), GRACE_SECONDS);
        vm.warp(accountant.getState().fixedTermCommenceableAtTimestamp - 1);
        _seedSymmetric(SEED_ST, SEED_JT, SEED_LPT);
        SyncedAccountingState memory s = kernel.doPreOp(toNAVUnits(LOSS_COLLATERAL_NAV));
        _assertPerpetualNoIL(s, "one second before commenceable");
    }

    /// @notice The grace only gates entry, it never forces a lock: after the grace elapses a market with no fresh loss stays PERPETUAL
    function test_afterGrace_healthyMarket_staysPerpetual() public {
        _deployWithGrace(_defaultParams(), GRACE_SECONDS);
        _seedSymmetric(SEED_ST, SEED_JT, SEED_LPT);
        vm.warp(accountant.getState().fixedTermCommenceableAtTimestamp + 1000);
        // A flat resync at the unchanged 130e18 collateral NAV books no loss
        SyncedAccountingState memory s = kernel.doPreOp(toNAVUnits(SEED_ST + SEED_JT));
        assertEq(uint8(s.marketState), uint8(MarketState.PERPETUAL), "no fresh loss after grace: stays PERPETUAL");
        assertEq(toUint256(s.jtImpermanentLoss), 0, "no fresh loss after grace: no impermanent loss");
    }

    // =============================
    // At and after the commenceable timestamp the market locks normally
    // =============================

    /// @notice Exactly at the commenceable timestamp the grace is over (the gate is a strict block.timestamp < FIXED_TERM_COMMENCEABLE_AT_TIMESTAMP), so the covered loss enters FIXED_TERM
    function test_atExactCommenceableTimestamp_locks() public {
        _deployWithGrace(_defaultParams(), GRACE_SECONDS);
        vm.warp(accountant.getState().fixedTermCommenceableAtTimestamp);
        _seedSymmetric(SEED_ST, SEED_JT, SEED_LPT);
        SyncedAccountingState memory s = kernel.doPreOp(toNAVUnits(LOSS_COLLATERAL_NAV));
        _assertFixedTermWithIL(s, "at commenceable timestamp");
    }

    /// @notice Well past the grace the covered loss locks normally, the direct contrast to the identical loss staying PERPETUAL inside the grace
    function test_wellAfterGrace_coveredLoss_locks() public {
        _deployWithGrace(_defaultParams(), GRACE_SECONDS);
        vm.warp(accountant.getState().fixedTermCommenceableAtTimestamp + 365 days);
        _seedSymmetric(SEED_ST, SEED_JT, SEED_LPT);
        SyncedAccountingState memory s = kernel.doPreOp(toNAVUnits(LOSS_COLLATERAL_NAV));
        _assertFixedTermWithIL(s, "well after grace");
    }

    // =============================
    // A zero grace preserves the pre-feature behavior
    // =============================

    /// @notice With a zero grace the commenceable timestamp is the deploy time, so a young market locks on the very first covered loss exactly as it did before the feature
    function test_zeroGrace_locksImmediately() public {
        SyncedAccountingState memory s = _deploySeedAndLose(0);
        _assertFixedTermWithIL(s, "zero grace");
    }

    // =============================
    // Adversarial extremes
    // =============================

    /// @notice A maximum uint24 grace does not overflow the timestamp addition and still forces PERPETUAL on a covered loss inside the window
    function test_maxUint24Grace_noOverflowAndStaysPerpetual() public {
        vm.warp(1000);
        _deployWithGrace(_defaultParams(), type(uint24).max);
        assertEq(
            accountant.getState().fixedTermCommenceableAtTimestamp, 1000 + uint256(type(uint24).max), "max grace: commenceable = deploy time + max uint24"
        );
        _seedSymmetric(SEED_ST, SEED_JT, SEED_LPT);
        SyncedAccountingState memory s = kernel.doPreOp(toNAVUnits(LOSS_COLLATERAL_NAV));
        _assertPerpetualNoIL(s, "max uint24 grace");
    }

    /// @notice The grace holds across repeated covered losses inside the window: the market never latches a fixed term that would survive to the next sync
    function test_withinGrace_repeatedLosses_neverLatchFixedTerm() public {
        _deployWithGrace(_defaultParams(), GRACE_SECONDS);
        _seedSymmetric(SEED_ST, SEED_JT, SEED_LPT);

        // First covered loss inside the grace is forced PERPETUAL and its impermanent loss erased
        SyncedAccountingState memory s1 = kernel.doPreOp(toNAVUnits(LOSS_COLLATERAL_NAV));
        _assertPerpetualNoIL(s1, "within grace loss 1");

        // A deeper covered loss later in the same window is still forced PERPETUAL, so no fixed term ever latches
        vm.warp(accountant.getState().fixedTermCommenceableAtTimestamp - 1);
        SyncedAccountingState memory s2 = kernel.doPreOp(toNAVUnits(LOSS_COLLATERAL_NAV - 5e18));
        _assertPerpetualNoIL(s2, "within grace loss 2");
    }
}
