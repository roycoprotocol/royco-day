// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayAccountant } from "../../../src/interfaces/accountant/IRoycoDayAccountant.sol";
import { ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { MarketState, Operation, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { FixedRateAccountantTestBase } from "../../utils/FixedRateAccountantTestBase.sol";

/**
 * @title Test_FixedAPY_FixedRateAccountant
 * @notice The headline fixed APY suite: the senior tranche's NAV path is EXACTLY the compounded fixed rate at
 *         the settlement cadence, regardless of what the collateral earned. Twelve monthly settlements are swept
 *         under generous gains, exact-coupon gains, near-zero gains (coupon fronted from the junior buffer), and
 *         a covered loss month, plus the cadence properties: flat-NAV syncs never move the coupon, one long
 *         window pays linearly (less than two compounded short windows), and a senior deposit scales the next
 *         coupon exactly linearly
 * @dev Every scenario runs the default rate 1e9 WAD per second over 30 day windows of 2_592_000 seconds, so the
 *      per-window growth factor is exactly 1 + 1e9 * 2_592_000 / 1e18 = 1.002592 and every vector is hand-derivable
 * @dev The mock LPT YDM's rates stay at their zero defaults in this suite, so the liquidity premium is zero and
 *      the senior path carries only the coupon (fees are share mints and never dent the accountant-level NAVs)
 */
contract Test_FixedAPY_FixedRateAccountant is FixedRateAccountantTestBase {
    /// @dev The settlement window: 30 days, so one window's coupon on stEff 1000e18 is 1000e18 * 1e9 * 2_592_000 / 1e18 = 2.592e18
    uint256 internal constant WINDOW = 2_592_000;
    /// @dev The generous per-window collateral gain, always far above the ~2.6e18 coupon
    uint256 internal constant GAIN = 50e18;
    /// @dev The covered loss applied in the loss-month scenario, well inside the ~480e18 junior buffer it hits
    uint256 internal constant LOSS = 30e18;
    /**
     * @dev stEffectiveNAV after 12 compounded windows from 1000e18, hand-derived by iterating
     * stEff += floor(stEff * 1e9 * 2_592_000 / 1e18):
     *   w1  coupon 2592000000000000000 -> 1002592000000000000000
     *   w2  coupon 2598718464000000000 -> 1005190718464000000000
     *   w3  coupon 2605454342258688000 -> 1007796172806258688000
     *   ...
     *   w12 coupon 2666868374707497094 -> 1031551272197044339026
     * Total coupons paid: 31551272197044339026
     */
    uint256 internal constant COMPOUNDED_ST_EFF_AFTER_12_WINDOWS = 1_031_551_272_197_044_339_026;

    function setUp() public {
        _deploy(_defaultParams());
        // Seed the flat 1000e18/200e18 market and initialize the accrual clocks inside the deploy block, so the
        // first coupon window opens at the deploy timestamp with a committed senior checkpoint of exactly 1000e18
        _seedAndInitAccrual();
    }

    /*//////////////////////////////////////////////////////////////////////
                            SETTLEMENT RUNNERS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @dev Settlement runner: previews then executes the identical settling sync, asserts preview == execution
     * byte-for-byte, then re-reads the committed checkpoint and asserts returned-vs-persisted equality, exact NAV
     * conservation, the il > 0 iff FIXED_TERM biconditional, and the coupon clock restamp (every caller passes a
     * moved collateral NAV, so the sync always settles)
     */
    function _settle(uint256 _collateralNew) internal returns (SyncedAccountingState memory executed) {
        return _settleExpectingReset(_collateralNew, 0);
    }

    /// @dev As _settle, but arms an exact JuniorTrancheImpermanentLossReset expectation for a perpetual commit
    /// that crystallizes fronted coupon (the expectEmit must bind to the mutating call, not the preview staticcall)
    function _settleExpectingReset(uint256 _collateralNew, uint256 _erased) internal returns (SyncedAccountingState memory executed) {
        SyncedAccountingState memory previewed = accountant.previewSyncTrancheAccounting(toNAVUnits(_collateralNew));
        if (_erased != 0) {
            vm.expectEmit(true, true, true, true, address(accountant));
            emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(toNAVUnits(_erased));
        }
        executed = kernel.doPreOp(toNAVUnits(_collateralNew));
        assertEq(keccak256(abi.encode(previewed)), keccak256(abi.encode(executed)), "settle: preview must match execution exactly");

        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastCollateralNAV), toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV), "settle: committed NAV conservation");
        assertEq(toUint256(s.lastSTEffectiveNAV), toUint256(executed.stEffectiveNAV), "settle: committed st effective NAV");
        assertEq(toUint256(s.lastJTEffectiveNAV), toUint256(executed.jtEffectiveNAV), "settle: committed jt effective NAV");
        assertEq(toUint256(s.lastJTImpermanentLoss), toUint256(executed.jtImpermanentLoss), "settle: committed il");
        assertEq(s.lastMarketState == MarketState.PERPETUAL, toUint256(s.lastJTImpermanentLoss) == 0, "settle: il > 0 iff FIXED_TERM");
        assertEq(_couponWindowStart(), vm.getBlockTimestamp(), "settle: a settling sync restamps the coupon clock");
    }

    /// @dev The independent compounded fixed rate product: the spec coupon folded into the base once per window,
    /// floors included, so the twelve-window scenarios are pinned against a loop production never runs
    function _compoundedSeniorPath(uint256 _base, uint256 _windows) internal pure returns (uint256 stEff) {
        stEff = _base;
        for (uint256 i; i < _windows; ++i) {
            stEff += _specCoupon(stEff, DEFAULT_ST_FIXED_RATE_PER_SECOND_WAD, WINDOW);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                    TWELVE MONTHLY SETTLEMENTS: THE FIXED APY PROPERTY
    //////////////////////////////////////////////////////////////////////*/

    /**
     * Fixed APY scenario (generous gains): 12 monthly settlements with a +50e18 collateral gain each window
     * Derivation per window k (committed stEff_{k-1}, coupon c_k = floor(stEff_{k-1} * 1e9 * 2_592_000 / 1e18)):
     * the gain covers the coupon in full, so stEff_k = stEff_{k-1} + c_k and JT keeps the excess 50e18 - c_k.
     * w1: c1 = 1000e18 * 2592 / 1e6 = 2.592e18, stEff = 1002.592e18, excess 47.408e18
     * w2: c2 = 1002.592e18 * 2592 / 1e6 = 2598718464000000000 exact, stEff = 1005190718464000000000
     * Fees: stFee = floor(c_k * 0.1e18 / 1e18) = c_k / 10, jtFee = (50e18 - c_k) / 10, both share mints.
     * The senior path is EXACTLY the compounded fixed rate no matter how large the gains were: after 12 windows
     * stEff = 1031551272197044339026 (the independently compounded product)
     */
    function test_FixedAPY_TwelveWindows_GenerousGains_SeniorPathIsExactCompoundedRate() public {
        uint256 nav = SEED_COLLATERAL;
        for (uint256 k = 1; k <= 12; ++k) {
            uint256 stPrev = toUint256(accountant.getState().lastSTEffectiveNAV);
            uint256 jtPrev = toUint256(accountant.getState().lastJTEffectiveNAV);
            uint256 coupon = _specCoupon(stPrev, DEFAULT_ST_FIXED_RATE_PER_SECOND_WAD, WINDOW);
            vm.warp(vm.getBlockTimestamp() + WINDOW);
            nav += GAIN;
            SyncedAccountingState memory executed = _settle(nav);
            assertEq(toUint256(executed.stEffectiveNAV), stPrev + coupon, "window: senior path is the checkpoint times the exact growth factor");
            assertEq(toUint256(executed.jtEffectiveNAV), jtPrev + GAIN - coupon, "window: jt keeps the entire excess above the coupon");
            assertEq(toUint256(executed.jtImpermanentLoss), 0, "window: a gain covering the coupon books no il");
            assertEq(toUint256(executed.stProtocolFee), coupon / 10, "window: st fee is a tenth of the coupon");
            assertEq(toUint256(executed.jtProtocolFee), (GAIN - coupon) / 10, "window: jt fee is a tenth of the excess");
            assertEq(toUint256(executed.lptLiquidityPremium), 0, "window: zero lpt rate pays no liquidity premium");
            assertEq(toUint256(executed.lptProtocolFee), 0, "window: no premium means no lpt fee");
            assertEq(uint8(executed.marketState), uint8(MarketState.PERPETUAL), "window: coupon-covering gains never lock the market");
        }
        uint256 finalSTEff = toUint256(accountant.getState().lastSTEffectiveNAV);
        assertEq(finalSTEff, _compoundedSeniorPath(SEED_ST_EFF, 12), "final: senior path equals the independently compounded product");
        assertEq(finalSTEff, COMPOUNDED_ST_EFF_AFTER_12_WINDOWS, "final: hand-derived compounded literal");
    }

    /**
     * Fixed APY scenario (asset earns exactly the coupon): 12 monthly settlements with NAV_new = NAV_old + c_k
     * Derivation per window k: the gain equals the coupon exactly, so couponFromGain = c_k consumes the whole
     * gain, no JT fronting, no il, no excess (premiums never paid), the JT sits flat at 200e18 forever.
     * The senior path is identical to the generous-gains path: stEff_k = stEff_{k-1} + c_k with
     * stFee = c_k / 10 each window, ending at 1031551272197044339026 after 12 windows
     */
    function test_FixedAPY_TwelveWindows_ExactCouponEarned_IdenticalSeniorPathFlatJT() public {
        uint256 nav = SEED_COLLATERAL;
        for (uint256 k = 1; k <= 12; ++k) {
            uint256 stPrev = toUint256(accountant.getState().lastSTEffectiveNAV);
            uint256 coupon = _specCoupon(stPrev, DEFAULT_ST_FIXED_RATE_PER_SECOND_WAD, WINDOW);
            vm.warp(vm.getBlockTimestamp() + WINDOW);
            nav += coupon;
            SyncedAccountingState memory executed = _settle(nav);
            assertEq(toUint256(executed.stEffectiveNAV), stPrev + coupon, "window: senior path is the checkpoint plus the exact coupon");
            assertEq(toUint256(executed.jtEffectiveNAV), SEED_JT_EFF, "window: jt stays flat when the asset earns exactly the coupon");
            assertEq(toUint256(executed.jtImpermanentLoss), 0, "window: no fronting when the gain funds the coupon exactly");
            assertEq(toUint256(executed.stProtocolFee), coupon / 10, "window: st fee is a tenth of the coupon");
            assertEq(toUint256(executed.jtProtocolFee), 0, "window: no excess means no jt fee");
            assertEq(toUint256(executed.lptLiquidityPremium), 0, "window: no excess means no liquidity premium");
            assertEq(uint8(executed.marketState), uint8(MarketState.PERPETUAL), "window: an exactly-funded coupon never locks the market");
        }
        uint256 finalSTEff = toUint256(accountant.getState().lastSTEffectiveNAV);
        assertEq(finalSTEff, _compoundedSeniorPath(SEED_ST_EFF, 12), "final: senior path equals the independently compounded product");
        assertEq(finalSTEff, COMPOUNDED_ST_EFF_AFTER_12_WINDOWS, "final: identical to the generous-gains literal");
    }

    /**
     * Fixed APY scenario (asset earns nothing): 12 monthly settlements with NAV_new = NAV_old + 1 wei (a flat
     * NAV never settles, so the minimal movement that does). The coupon is fronted from the junior buffer
     * Derivation per window k: couponFromGain = 1, couponFromJT = c_k - 1, so stEff_k = stEff_{k-1} + c_k
     * (identical senior path), jt_k = jt_{k-1} - (c_k - 1), and c_k - 1 books as il.
     * State machine (default duration 604_800 < WINDOW, so each term expires before the next settlement):
     * odd windows commit FIXED_TERM with il = c_k - 1 and end = now + 604_800, even windows find the term
     * elapsed so the perpetual commit crystallizes the accumulated fronted coupon
     * (w2 erases (c1 - 1) + (c2 - 1) = 5190718463999999998).
     * After 12 windows jt = 200e18 - sum(c_k - 1) = 168448727802955660986 while the senior path still ends at
     * exactly 1031551272197044339026: the fixed rate is honored from the buffer
     */
    function test_FixedAPY_TwelveWindows_CouponFrontedFromJT_SeniorPathHonoredFromBuffer() public {
        uint256 nav = SEED_COLLATERAL;
        uint256 jtExpected = SEED_JT_EFF;
        uint256 couponPrev;
        for (uint256 k = 1; k <= 12; ++k) {
            uint256 stPrev = toUint256(accountant.getState().lastSTEffectiveNAV);
            uint256 coupon = _specCoupon(stPrev, DEFAULT_ST_FIXED_RATE_PER_SECOND_WAD, WINDOW);
            vm.warp(vm.getBlockTimestamp() + WINDOW);
            nav += 1;
            jtExpected -= coupon - 1;

            SyncedAccountingState memory executed;
            if (k % 2 == 0) {
                // Term expired mid-window: the perpetual commit erases the fronted coupon accumulated across the
                // odd window's checkpoint plus this window's fronting
                executed = _settleExpectingReset(nav, (couponPrev - 1) + (coupon - 1));
                assertEq(uint8(executed.marketState), uint8(MarketState.PERPETUAL), "even window: term expiry commits perpetual");
                assertEq(toUint256(executed.jtImpermanentLoss), 0, "even window: crystallized fronted coupon is erased");
                assertEq(executed.fixedTermEndTimestamp, 0, "even window: the term end resets");
            } else {
                executed = _settle(nav);
                assertEq(uint8(executed.marketState), uint8(MarketState.FIXED_TERM), "odd window: coupon drag alone locks the term");
                assertEq(toUint256(executed.jtImpermanentLoss), coupon - 1, "odd window: the fronted coupon books as il");
                assertEq(
                    executed.fixedTermEndTimestamp,
                    uint32(vm.getBlockTimestamp() + DEFAULT_FIXED_TERM_DURATION_SECONDS),
                    "odd window: fresh term end stamped on entry"
                );
            }
            assertEq(toUint256(executed.stEffectiveNAV), stPrev + coupon, "window: senior path unchanged when jt fronts the coupon");
            assertEq(toUint256(executed.jtEffectiveNAV), jtExpected, "window: jt bleeds exactly the fronted coupon");
            assertEq(toUint256(executed.stProtocolFee), coupon / 10, "window: st fee is a tenth of the coupon even when fronted");
            assertEq(toUint256(executed.jtProtocolFee), 0, "window: no excess means no jt fee");
            assertEq(toUint256(executed.lptLiquidityPremium), 0, "window: no excess means no liquidity premium");
            couponPrev = coupon;
        }
        uint256 finalSTEff = toUint256(accountant.getState().lastSTEffectiveNAV);
        assertEq(finalSTEff, _compoundedSeniorPath(SEED_ST_EFF, 12), "final: senior path equals the independently compounded product");
        assertEq(finalSTEff, COMPOUNDED_ST_EFF_AFTER_12_WINDOWS, "final: identical to the generous-gains literal");
        assertEq(toUint256(accountant.getState().lastJTEffectiveNAV), 168_448_727_802_955_660_986, "final: jt bled the sum of fronted coupons");
    }

    /**
     * Fixed APY scenario (a covered loss month inside the sequence): windows 1-6 and 9-12 gain +50e18, window 7
     * loses 30e18, window 8 gains +50e18 again
     * Derivation window 7 (stEff_6 = 1015653125922942423465, c7 = 2632572902392266761): the loss is absorbed
     * junior-first (jt -= 30e18, il = 30e18), then the coupon is fronted from the remaining buffer
     * (jt -= c7, il = 30e18 + c7 = 32632572902392266761, stEff += c7), FIXED_TERM entry.
     * Derivation window 8 (c8 = 2639396531355267517): coupon off the top of the gain, remaining
     * 50e18 - c8 = 47360603468644732483 repays the whole il (restoration, never fee'd), the excess
     * 14728030566252465722 goes to JT with jtFee = 1472803056625246572, and the term (expired 604_800 < WINDOW
     * ago, il repaid to zero) commits perpetual with nothing left to erase.
     * The senior path is unbroken through the loss: stEff_k = stEff_{k-1} + c_k every window, ending at
     * exactly 1031551272197044339026
     */
    function test_FixedAPY_CoveredLossMonth_SeniorPathUnbroken() public {
        uint256 nav = SEED_COLLATERAL;
        uint256 jtExpected = SEED_JT_EFF;
        uint256 ilExpected;
        for (uint256 k = 1; k <= 12; ++k) {
            uint256 stPrev = toUint256(accountant.getState().lastSTEffectiveNAV);
            uint256 coupon = _specCoupon(stPrev, DEFAULT_ST_FIXED_RATE_PER_SECOND_WAD, WINDOW);
            vm.warp(vm.getBlockTimestamp() + WINDOW);

            uint256 jtFeeExpected;
            MarketState stateExpected;
            if (k == 7) {
                // Covered loss month: the loss and the fronted coupon both land on JT and book as il
                nav -= LOSS;
                jtExpected -= LOSS + coupon;
                ilExpected = LOSS + coupon;
                stateExpected = MarketState.FIXED_TERM;
            } else if (k == 8) {
                // Recovery month: coupon first, full il repayment second, the excess to JT third
                nav += GAIN;
                uint256 excess = GAIN - coupon - ilExpected;
                jtExpected += GAIN - coupon;
                jtFeeExpected = excess / 10;
                ilExpected = 0;
                stateExpected = MarketState.PERPETUAL;
            } else {
                nav += GAIN;
                jtExpected += GAIN - coupon;
                jtFeeExpected = (GAIN - coupon) / 10;
                stateExpected = MarketState.PERPETUAL;
            }

            SyncedAccountingState memory executed = _settle(nav);
            assertEq(toUint256(executed.stEffectiveNAV), stPrev + coupon, "window: senior path unbroken through the covered loss");
            assertEq(toUint256(executed.jtEffectiveNAV), jtExpected, "window: jt absorbs the loss and collects the recovery");
            assertEq(toUint256(executed.jtImpermanentLoss), ilExpected, "window: il tracks the loss plus the fronted coupon");
            assertEq(toUint256(executed.stProtocolFee), coupon / 10, "window: st fee is a tenth of the coupon every window");
            assertEq(toUint256(executed.jtProtocolFee), jtFeeExpected, "window: jt fee only on the post-restoration excess");
            assertEq(toUint256(executed.lptLiquidityPremium), 0, "window: zero lpt rate pays no liquidity premium");
            assertEq(uint8(executed.marketState), uint8(stateExpected), "window: the loss locks the term, the recovery releases it");
        }
        uint256 finalSTEff = toUint256(accountant.getState().lastSTEffectiveNAV);
        assertEq(finalSTEff, _compoundedSeniorPath(SEED_ST_EFF, 12), "final: senior path equals the independently compounded product");
        assertEq(finalSTEff, COMPOUNDED_ST_EFF_AFTER_12_WINDOWS, "final: identical to the loss-free literal");
    }

    /*//////////////////////////////////////////////////////////////////////
                            CADENCE PROPERTIES
    //////////////////////////////////////////////////////////////////////*/

    /**
     * Cadence scenario (sync-cadence invariance): a window peppered with flat-NAV pre-op syncs pays the identical
     * settlement coupon as an untouched window
     * Derivation: a flat-NAV pre-op sync observes no collateral movement, so it settles nothing and never
     * restamps the coupon clock. The peppered window's settlement at +30 days therefore pays the full-window
     * coupon floor(1000e18 * 1e9 * 2_592_000 / 1e18) = 2592000000000000000, byte-identical to a fresh market's
     * untouched window over the same base and elapsed time
     */
    function test_FixedAPY_FlatSyncPeppering_SettlementCouponInvariant() public {
        uint256 windowStart = _couponWindowStart();
        // Relative gaps landing at +432000, +1036800, +1728000, and +2505600 into the window
        uint256[4] memory gaps = [uint256(432_000), 604_800, 691_200, 777_600];
        for (uint256 i; i < gaps.length; ++i) {
            vm.warp(vm.getBlockTimestamp() + gaps[i]);
            kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
            IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
            assertEq(toUint256(s.lastSTEffectiveNAV), SEED_ST_EFF, "pepper: flat sync leaves the senior checkpoint untouched");
            assertEq(toUint256(s.lastJTEffectiveNAV), SEED_JT_EFF, "pepper: flat sync leaves the junior checkpoint untouched");
            assertEq(toUint256(s.lastJTImpermanentLoss), 0, "pepper: flat sync books no il");
            assertEq(_couponWindowStart(), windowStart, "pepper: flat sync never restamps the coupon clock");
        }
        // The final warp completes the exact 30 day window from its opening
        vm.warp(vm.getBlockTimestamp() + 86_400);
        SyncedAccountingState memory peppered = _settle(SEED_COLLATERAL + 10e18);
        uint256 couponPeppered = toUint256(peppered.stEffectiveNAV) - SEED_ST_EFF;
        assertEq(couponPeppered, 2_592_000_000_000_000_000, "pepper: the peppered window pays the full-window coupon");

        // Untouched control: a fresh market over the same base and window length pays the identical coupon
        _deploy(_defaultParams());
        _seedAndInitAccrual();
        vm.warp(vm.getBlockTimestamp() + WINDOW);
        SyncedAccountingState memory untouched = _settle(SEED_COLLATERAL + 10e18);
        uint256 couponUntouched = toUint256(untouched.stEffectiveNAV) - SEED_ST_EFF;
        assertEq(couponPeppered, couponUntouched, "pepper: identical coupon to the untouched window");
    }

    /**
     * Cadence scenario (settlement-cadence compounding): one 60 day window pays linearly, two 30 day windows
     * compound, and the compounded path is strictly larger
     * Derivation (base 1000e18):
     *   one 60 day window: coupon = floor(1000e18 * 1e9 * 5_184_000 / 1e18) = 5184000000000000000,
     *     stEff = 1005184000000000000000 (linear within the window)
     *   two 30 day windows: c1 = 2592000000000000000 then c2 = floor(1002.592e18 * 2592 / 1e6)
     *     = 2598718464000000000, total 5190718464000000000, stEff = 1005190718464000000000
     * The strict ordering 5184000000000000000 < 5190718464000000000 pins linear-within-window plus
     * compound-at-settlement: only a settlement folds the coupon into the accruing base
     */
    function test_FixedAPY_SettlementCadence_LinearWithinWindowCompoundsAcrossSettlements() public {
        // One 60 day window on the setUp market
        vm.warp(vm.getBlockTimestamp() + 2 * WINDOW);
        SyncedAccountingState memory singleWindow = _settle(SEED_COLLATERAL + 10e18);
        uint256 couponSingle = toUint256(singleWindow.stEffectiveNAV) - SEED_ST_EFF;
        assertEq(couponSingle, 5_184_000_000_000_000_000, "cadence: one 60 day window pays exactly stEff * r * 60d");
        assertEq(toUint256(singleWindow.stEffectiveNAV), 1_005_184_000_000_000_000_000, "cadence: linear single-window senior NAV");

        // Two 30 day windows on a fresh market over the same base
        _deploy(_defaultParams());
        _seedAndInitAccrual();
        vm.warp(vm.getBlockTimestamp() + WINDOW);
        _settle(SEED_COLLATERAL + 10e18);
        vm.warp(vm.getBlockTimestamp() + WINDOW);
        SyncedAccountingState memory twoWindows = _settle(SEED_COLLATERAL + 20e18);
        uint256 couponCompounded = toUint256(twoWindows.stEffectiveNAV) - SEED_ST_EFF;
        assertEq(couponCompounded, 5_190_718_464_000_000_000, "cadence: two 30 day windows compound the second coupon");
        assertEq(toUint256(twoWindows.stEffectiveNAV), 1_005_190_718_464_000_000_000, "cadence: compounded two-window senior NAV");

        // The compounded path strictly dominates: settlements are the compounding events
        assertLt(couponSingle, couponCompounded, "cadence: linear 60d pays strictly less than two compounded 30d windows");
    }

    /**
     * Cadence scenario (boundary senior flow): an ST_DEPOSIT doubling the committed senior base right after a
     * settlement makes the NEXT window's coupon exactly double, so the per-capital rate is unchanged
     * Derivation: after window 1 stEff = 1002592000000000000000 (nav 1210e18, jt 207.408e18). An ST_DEPOSIT of
     * exactly stEff doubles the base to 2005184000000000000000 (nav 2212.592e18). Window 2's coupon is then
     * floor(2005184000000000000000 * 2592 / 1e6) = 5197436928000000000, exactly twice the single-base coupon
     * 2598718464000000000 (the doubled base divides 1e6 exactly so no floor skew), with
     * stFee = 519743692800000000 and stEff = 2010381436928000000000
     */
    function test_FixedAPY_STDepositDoublesBase_NextCouponExactlyDoubles() public {
        vm.warp(vm.getBlockTimestamp() + WINDOW);
        SyncedAccountingState memory first = _settle(SEED_COLLATERAL + 10e18);
        uint256 stEffAfterFirst = toUint256(first.stEffectiveNAV);
        assertEq(stEffAfterFirst, 1_002_592_000_000_000_000_000, "deposit: first window senior NAV");

        // Double the committed senior base in the settlement block, so the whole next window accrues on it
        uint256 navAfterDeposit = SEED_COLLATERAL + 10e18 + stEffAfterFirst;
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(navAfterDeposit), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
        assertEq(toUint256(accountant.getState().lastSTEffectiveNAV), 2 * stEffAfterFirst, "deposit: senior base doubled");

        uint256 singleBaseCoupon = _specCoupon(stEffAfterFirst, DEFAULT_ST_FIXED_RATE_PER_SECOND_WAD, WINDOW);
        vm.warp(vm.getBlockTimestamp() + WINDOW);
        SyncedAccountingState memory second = _settle(navAfterDeposit + 10e18);
        uint256 doubledBaseCoupon = toUint256(second.stEffectiveNAV) - 2 * stEffAfterFirst;
        assertEq(doubledBaseCoupon, 2 * singleBaseCoupon, "deposit: doubling the base exactly doubles the coupon");
        assertEq(doubledBaseCoupon, 5_197_436_928_000_000_000, "deposit: hand-derived doubled coupon literal");
        assertEq(toUint256(second.stProtocolFee), doubledBaseCoupon / 10, "deposit: st fee stays a tenth of the coupon");
        assertEq(toUint256(second.stEffectiveNAV), 2_010_381_436_928_000_000_000, "deposit: second window senior NAV on the doubled base");
    }
}
