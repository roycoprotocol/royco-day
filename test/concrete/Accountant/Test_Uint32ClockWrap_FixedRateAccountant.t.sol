// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayAccountant } from "../../../src/interfaces/accountant/IRoycoDayAccountant.sol";
import { IRoycoDayFixedRateAccountant } from "../../../src/interfaces/accountant/IRoycoDayFixedRateAccountant.sol";
import { MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { FixedRateAccountantTestBase } from "../../utils/FixedRateAccountantTestBase.sol";

/**
 * @title Test_Uint32ClockWrap_FixedRateAccountant
 * @notice The uint32 clock-width behavior of the fixed rate accountant. Every clock it persists is stamped as
 *         uint32(block.timestamp), so from the first second past 2^32 (February 2106) each stored stamp drops
 *         the 2^32 bit while block.timestamp keeps it. Every elapsed-time subtraction against such a stamp then
 *         reads 2^32 seconds (about 136 years) too long: the coupon window mints a phantom 136-year coupon that
 *         wipes the junior buffer in one settlement, and the LPT premium window over-weights the accumulator
 *         until every excess-bearing sync reverts
 * @dev The fixed flavor adds a clock the float does not have, lastCouponSettlementTimestamp, so the phantom
 *      coupon is a wrap surface unique to this flavor. Each test asserts the past-horizon behavior and documents
 *      the sub-horizon dated behavior in an adjacent comment with independently derived bounds
 */
contract Test_Uint32ClockWrap_FixedRateAccountant is FixedRateAccountantTestBase {
    /// @dev 2^32, the width of every persisted clock: the first second at which the truncated stamps disagree with block.timestamp
    uint256 internal constant TWO_POW_32 = 4_294_967_296;

    // =============================
    // The coupon settlement clock wraps at uint32 and mints a phantom 136-year coupon
    // =============================

    /**
     * @notice Coupon window: past the uint32 horizon, a 1000-second settlement window reads as 2^32 + 1000
     *         seconds, so the coupon demand explodes from the honest 1e15 to 4294.968296e18 — over four million
     *         times the real accrual — and one settlement wipes the entire 200e18 junior buffer into fronted
     *         impermanent loss that the wipeout clause immediately crystallizes
     * @dev The coupon clock is stamped at initialization as uint32(2^32 + 5000) = 5000, dropping the 2^32 bit.
     *      The settling sync then computes elapsed = block.timestamp - 5000 = 2^32 + 1000 = 4294968296 and
     *      stCouponDue = 1000e18 x 1e9 x 4294968296 / 1e18 = 4294968296000000000000. With a correctly sized
     *      clock the same window owes 1000e18 x 1e9 x 1000 / 1e18 = 1e15
     */
    function test_couponClock_wrapsAtUint32_phantomCouponWipesJuniorBuffer() public {
        // Deploy and seed past the uint32 horizon: initialize stamps the coupon clock as uint32(2^32 + 5000) = 5000
        vm.warp(TWO_POW_32 + 5000);
        _deploy(_defaultParams());
        _seedAndInitAccrual();
        assertEq(_couponWindowStart(), 5000, "the stored coupon stamp truncates 4294972296 to its low 32 bits");

        // A +1e18 gain settlement 1000 real seconds later. The wrapped window demands 4294.968296e18 of coupon:
        // the gain funds 1e18, the entire 200e18 junior buffer fronts the rest it can cover (booked as
        // impermanent loss), and the remaining 4093.968296e18 is forgiven. couponPaid = 201e18 with
        // stProtocolFee = 20.1e18, and the wiped buffer trips the perpetual wipeout clause, which crystallizes
        // the 200e18 fronted coupon on the spot
        vm.warp(vm.getBlockTimestamp() + 1000);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(toNAVUnits(uint256(200e18)));
        SyncedAccountingState memory executed = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 1e18));

        assertEq(toUint256(executed.stEffectiveNAV), 1201e18, "the senior collects the gain plus the whole fronted buffer");
        assertEq(toUint256(executed.jtEffectiveNAV), 0, "the phantom coupon wipes the junior buffer in one settlement");
        assertEq(toUint256(executed.jtImpermanentLoss), 0, "the wipeout clause erases the fronted coupon at the perpetual commit");
        assertEq(toUint256(executed.stProtocolFee), 20.1e18, "the senior fee prices the 201e18 phantom couponPaid");
        assertEq(uint8(executed.marketState), uint8(MarketState.PERPETUAL), "the wiped buffer forces the perpetual state");
        assertEq(toUint256(executed.collateralNAV), toUint256(executed.stEffectiveNAV) + toUint256(executed.jtEffectiveNAV), "conservation survives the wrap");
        // The re-stamp truncates back to the same low 32 bits, re-arming the wrap for the next window
        assertEq(_couponWindowStart(), 6000, "the settlement re-stamp truncates 4294973296 to its low 32 bits");
    }

    // =============================
    // The LPT premium window wraps at uint32 and bricks excess-bearing syncs
    // =============================

    /**
     * @notice Premium window: past the uint32 horizon, with the LPT yield share capped at 0.1e18 (so at most
     *         10% of any excess should ever leave as the liquidity premium), eleven flat syncs poison the
     *         accumulator so badly that every subsequent excess-bearing sync reverts with PREMIUMS_EXCEED_YIELD —
     *         and the accumulator only resets when a premium is actually paid, which now can never happen, so
     *         the market cannot heal itself
     * @dev The rate is zero here so the coupon leg stays silent and the wrap isolates to the premium window
     *      (a nonzero rate would wipe the buffer through the phantom coupon first, see the test above). Each
     *      1-second flat sync accrues cap x (2^32 + 1) instead of cap x 1, stacking an 11 x 2^32-scale numerator
     *      against a 1 x 2^32-scale payment window: the premium fraction reads about 11 x cap = 1.1 where the
     *      correct bound is the 0.1 cap
     */
    function test_premiumWindow_wrapsAtUint32_excessSyncRevertsPremiumsExceedYield() public {
        // Zero-rate market with the LPT share capped at 0.1e18: no coupon ever accrues, so the excess equals
        // the whole gain and the premium carve is the only wrapped consumer
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _defaultParams();
        p.stFixedRatePerSecondWAD = 0;
        _deploy(p);

        // Initialize both accrual clocks past the uint32 horizon: each stamps as uint32(2^32 + 5000) = 5000
        uint256 t0 = TWO_POW_32 + 5000;
        vm.warp(t0);
        _seedAndInitAccrual();
        lptYDM.setYieldShareReturn(0.1e18);

        // Eleven flat syncs spaced one real second apart. Each should accrue cap x 1s = 0.1e18 (1.1e18 total),
        // but every fresh stamp keeps losing its 2^32 bit, so each sync reads elapsed = 2^32 + 1 and accrues
        // 0.1e18 x 4294967297. After eleven: 11 x 0.1e18 x 4294967297 = 4724464026700000000000000000
        for (uint256 i = 1; i <= 11; ++i) {
            vm.warp(t0 + i);
            kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        }
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantState memory sFixed = accountant.getRoycoDayFixedRateAccountantState();
        assertEq(uint256(sFixed.twLPTYieldShareAccruedWAD), 4_724_464_026_700_000_000_000_000_000, "the accumulator holds eleven phantom 2^32-second accruals");
        assertEq(
            sFixed.lastPremiumPaymentTimestamp, 5000, "no premium was paid on the flat syncs so the payment window still opens at the truncated init stamp"
        );

        // Zero the forward rate: even if the YDM never awards another basis point of yield share from here on,
        // the poison already banked in the accumulator is enough to brick the market
        lptYDM.setYieldShareReturn(0);

        // A +12e18 gain one second later is pure excess (zero coupon). With a correctly sized clock the
        // accumulator would hold eleven 1-second accruals of 0.1e18 = 1.1e18 over a 12-second window, so the
        // premium would be floor(12e18 x 1.1e18 / (12 x 1e18)) = 1.1e18, well within the gain. Past the
        // horizon: the window reads block.timestamp - 5000 = 2^32 + 12 = 4294967308 seconds against the
        // 11 x 0.1e18 x (2^32 + 1) accumulator, so the premium computes
        // floor(12e18 x 4724464026700000000000000000 / (4294967308 x 1e18)) = 13199999966192990635 > the 12e18
        // excess, tripping the premiums-exceed-yield guard
        vm.warp(t0 + 12);
        vm.expectRevert(IRoycoDayAccountant.PREMIUMS_EXCEED_YIELD.selector);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 12e18));

        // The brick is persistent: the accumulator only resets when a premium is actually paid, and every
        // excess-bearing sync now reverts before paying. The window grows one second per block against an
        // 11 x 2^32-scale numerator, so diluting the premium back under the excess would take on the order of
        // 0.1 x 2^32 more seconds (about 13 more years). One block later the same gain still reverts
        vm.warp(t0 + 13);
        vm.expectRevert(IRoycoDayAccountant.PREMIUMS_EXCEED_YIELD.selector);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 12e18));
    }
}
