// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { WaterfallSyncDriver } from "../../mocks/WaterfallSyncDriver.sol";

/**
 * @title Test_SeniorLeverageViaImpermanentLossRecovery_PoC
 * @notice REGRESSION GUARD (was a PoC of a since-remediated bug). A collateral round trip DOWN then UP must leave the
 *         senior tranche with the SAME split as a direct move to the same final price. This originally failed: the
 *         round trip overpaid the senior, because the JT impermanent-loss ledger was a single pooled number drained by
 *         whichever gain leg touched it first, and the JT gain leg ran before the ST gain leg.
 *
 *         The IL booked on a drawdown has two economic components: JT's OWN attributed loss, and the coverage JT
 *         extended to protect ST. Under the old waterfall both landed in one `jtImpermanentLoss` accumulator; on
 *         recovery JT's own attributed gain recovered the FULL pooled IL first, so by the time the ST gain leg ran the
 *         ledger was empty and ST repaid NONE of the coverage it received — keeping the full appreciation on the
 *         enlarged collateral claim that coverage handed it during the dip (extra leverage a senior tranche should not
 *         get; the round trip left ST at 250 versus the fair 200).
 *
 * @dev The pricing-system simplification remediated this: the recovery now repays the coverage debt to ST before JT
 *      keeps its residual gain, so the round trip conserves the fair 200/100 split (ST repays the coverage it drew).
 *      This test isolates the pure waterfall: every fee and premium rate is zero, so the only forces are attribution,
 *      coverage, and IL recovery. It now asserts the FAIR outcome and stands as a regression guard against the leverage
 *      reappearing.
 */
contract Test_SeniorLeverageViaImpermanentLossRecovery_PoC is Test {
    WaterfallSyncDriver internal driver;

    // Price 1.0 marks: collateral 150 units, ST claims 100, JT claims 50 (NAV == units at price 1.0)
    NAV_UNIT internal constant COLLATERAL_AT_1 = NAV_UNIT.wrap(150e18);
    NAV_UNIT internal constant ST_EFF_AT_1 = NAV_UNIT.wrap(100e18);
    NAV_UNIT internal constant JT_EFF_AT_1 = NAV_UNIT.wrap(50e18);

    // The collateral is a fixed 150 units, so its NAV is just 150 * price
    uint256 internal constant COLLATERAL_AT_0_8 = 120e18; // price 0.8
    uint256 internal constant COLLATERAL_AT_2 = 300e18; // price 2.0

    function setUp() public {
        // The driver acts as its own kernel for the seedCheckpoint / runSync shims (both are unrestricted)
        driver = new WaterfallSyncDriver(address(this));
        // A nonzero premium clock so the ST gain premium block takes the time-weighted branch (never touches the YDMs)
        vm.warp(1_000_000);
    }

    /// @dev The base checkpoint at price 1.0: PERPETUAL, no IL, every fee/premium rate zeroed so only the waterfall acts
    function _baseSeed() internal view returns (IRoycoDayAccountant.RoycoDayAccountantState memory seed) {
        seed.minCoverageWAD = 0.1e18; // 10%, keeps coverage utilization well under the liquidation threshold
        seed.fixedTermDurationSeconds = 30 days; // nonzero, so a genuine IL locks the market FIXED_TERM instead of erasing
        seed.lastMarketState = MarketState.PERPETUAL;
        seed.lastYieldShareAccrualTimestamp = 1;
        seed.lastPremiumPaymentTimestamp = 1; // elapsed = block.timestamp - 1 > 0
        seed.jtYDM = address(0x1111); // never called: tw shares are passed in as zero and elapsed is nonzero
        seed.lptYDM = address(0x2222);
        seed.maxJTYieldShareWAD = 1e18;
        seed.maxLPTYieldShareWAD = 1e18;
        seed.coverageLiquidationUtilizationWAD = 2e18; // > WAD per the accountant's config invariant
        seed.lastCollateralNAV = COLLATERAL_AT_1;
        seed.lastSTEffectiveNAV = ST_EFF_AT_1;
        seed.lastJTEffectiveNAV = JT_EFF_AT_1;
        seed.lastJTImpermanentLoss = toNAVUnits(uint256(0));
        seed.dustTolerance = toNAVUnits(uint256(0));
    }

    /// @dev Runs one non-committing sync with zero time-weighted premium shares
    function _sync(uint256 _collateralNAV) internal view returns (SyncedAccountingState memory state) {
        (state,,,) = driver.runSync(_collateralNAV, 0, 0);
    }

    function test_regression_roundTripDoesNotOverpaySeniorVersusDirectMove() public {
        // ============================================================
        // Path A: the direct move 1.0 -> 2.0 (the fair benchmark)
        // ============================================================
        driver.seedCheckpoint(_baseSeed());
        SyncedAccountingState memory direct = _sync(COLLATERAL_AT_2);

        // Fair split: gain 150 attributed floor(150 * 100/150)=100 to ST, 50 residual to JT
        assertEq(toUint256(direct.stEffectiveNAV), 200e18, "direct: ST ends at 200");
        assertEq(toUint256(direct.jtEffectiveNAV), 100e18, "direct: JT ends at 100");

        // ============================================================
        // Path B: the round trip 1.0 -> 0.8 -> 2.0
        // ============================================================

        // ---- Sync 1: price 1.0 -> 0.8 (collateral 150 -> 120, delta -30) ----
        driver.seedCheckpoint(_baseSeed());
        SyncedAccountingState memory dip = _sync(COLLATERAL_AT_0_8);

        // Attribution floor(30 * 100/150)=20 to ST, 10 residual to JT.
        // JT-loss leg books its own 10 as IL; ST-loss leg is fully covered by JT (20), booking another 20 as IL.
        assertEq(toUint256(dip.stEffectiveNAV), 100e18, "dip: ST fully protected at 100");
        assertEq(toUint256(dip.jtEffectiveNAV), 20e18, "dip: JT absorbs its own loss and ST's, down to 20");
        assertEq(toUint256(dip.jtImpermanentLoss), 30e18, "dip: pooled IL is JT's own 10 plus the 20 coverage it gave ST");
        assertEq(uint8(dip.marketState), uint8(MarketState.FIXED_TERM), "dip: a real IL locks the market FIXED_TERM");

        // ---- Sync 2: price 0.8 -> 2.0 (collateral 120 -> 300, delta +180) ----
        // Re-seed the driver with sync 1's committed output, exactly as preOpSyncTrancheAccounting would persist it
        IRoycoDayAccountant.RoycoDayAccountantState memory seed2 = _baseSeed();
        seed2.lastMarketState = dip.marketState;
        seed2.fixedTermEndTimestamp = dip.fixedTermEndTimestamp;
        seed2.lastCollateralNAV = toNAVUnits(COLLATERAL_AT_0_8);
        seed2.lastSTEffectiveNAV = dip.stEffectiveNAV;
        seed2.lastJTEffectiveNAV = dip.jtEffectiveNAV;
        seed2.lastJTImpermanentLoss = dip.jtImpermanentLoss;
        driver.seedCheckpoint(seed2);

        SyncedAccountingState memory roundTrip = _sync(COLLATERAL_AT_2);

        // Attribution floor(180 * 100/120)=150 to ST, 30 residual to JT. The remediated recovery repays the coverage
        // debt to ST before JT keeps its residual gain, so the pooled IL still clears to zero but ST lands at the fair
        // 200 (it gives back the coverage it drew during the dip) rather than the old leveraged 250.
        assertEq(toUint256(roundTrip.jtImpermanentLoss), 0, "round trip: pooled IL fully recovered");
        assertEq(toUint256(roundTrip.stEffectiveNAV), 200e18, "round trip: ST ends at the fair 200 (coverage repaid), NOT the old leveraged 250");
        assertEq(toUint256(roundTrip.jtEffectiveNAV), 100e18, "round trip: JT ends at the fair 100, NOT the old shortchanged 50");

        // ============================================================
        // No overpayment: identical final price, identical conserved total, identical split
        // ============================================================
        assertEq(
            toUint256(roundTrip.stEffectiveNAV) + toUint256(roundTrip.jtEffectiveNAV),
            toUint256(direct.stEffectiveNAV) + toUint256(direct.jtEffectiveNAV),
            "both paths conserve the same 300 collateral NAV"
        );
        assertEq(toUint256(roundTrip.stEffectiveNAV), toUint256(direct.stEffectiveNAV), "the round trip pays ST exactly the direct-move amount (no leverage)");
        assertEq(toUint256(roundTrip.jtEffectiveNAV), toUint256(direct.jtEffectiveNAV), "the round trip pays JT exactly the direct-move amount (not shortchanged)");

        // The leverage framing: at price 2.0 the senior's NAV is a claim on collateral units (units = NAV / price).
        // The remediated round trip leaves ST claiming the fair 100 units of the fixed 150-unit pool — no extra claim
        // on base-asset units it never funded.
        uint256 stUnitsRoundTrip = (toUint256(roundTrip.stEffectiveNAV) * 1e18) / 2e18;
        uint256 stUnitsDirect = (toUint256(direct.stEffectiveNAV) * 1e18) / 2e18;
        assertEq(stUnitsRoundTrip, 100e18, "round trip: ST claims its fair 100 of the 150 collateral units");
        assertEq(stUnitsDirect, 100e18, "direct: ST claims its fair 100 units");
        assertEq(stUnitsRoundTrip, stUnitsDirect, "ST gains no permanent leverage on base-asset units via the coverage round trip");
    }
}
