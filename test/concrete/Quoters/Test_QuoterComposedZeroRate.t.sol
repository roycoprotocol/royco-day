// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { stdError } from "../../../lib/forge-std/src/StdError.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_QuoterComposedZeroRate
 * @notice The composed ST/JT conversion rate (the vault-share hop times the price-feed hop) can floor to exactly
 *         zero, and the quoter accepts that composed rate with no typed error: forward conversions value both
 *         tranche NAVs at zero while backward conversions revert division-by-zero
 * @dev The kernel family prices a tranche unit as floor(vaultHop x feedHop / 1e18), where the vault hop is the
 *      ERC4626 share price scaled to WAD and the feed hop is the Chainlink-shaped answer scaled to WAD. The feed
 *      hop is gated (a non-positive answer reverts INVALID_PRICE), but the composed product has no zero gate, so
 *      a 1-wei vault rate against a sub-1.0 feed answer floors the composed rate to exactly zero one hop past the
 *      gate. Every test below constructs that reachable zero on the 18-decimal ERC4626 ST/JT vault, 6-decimal
 *      quote market and asserts the resulting behavior
 */
contract Test_QuoterComposedZeroRate is DayMarketTestBase {
    // =============================
    // Seed Constants (whole tokens, 18-decimal ERC4626 ST/JT shares, 6-decimal quote)
    // =============================

    /// @dev Whole ST/JT vault shares seeded. Coverage after seed: (100 + 30) x 0.2 / 30 = 0.8667 <= 1, gate clears
    uint256 internal constant ST_SEED_WHOLE = 100;
    uint256 internal constant JT_SEED_WHOLE = 30;

    /**
     * @dev Auto-seeded LT depth (DayMarketTestBase._ensureLiquidityCapacityForSTDeposit): required ltRawNAV =
     *      ceil(100e18 x 0.05) = 5e18, quote leg = 5 whole + 1 cushion = 6 whole quote, BPT minted 1:1 with the
     *      18-decimal NAV added, so the kernel-owned mark is exactly 6e18. The pool never holds a senior leg
     *      (the auto-seed is quote-only), so collapsing the senior share price cannot move this mark
     */
    uint256 internal constant SEEDED_LT_RAW_NAV = 6e18;

    /// @dev A feed answer just below the 1.0 peg at the fixture's 8 feed decimals: 0.99 x 1e8. Strictly positive,
    ///      so it passes the feed's own answer > 0 gate while still flooring the composed product to zero
    int256 internal constant SUB_PEG_FEED_ANSWER = 99_000_000;

    /// @dev One whole collateral vault share in tranche units (this market's shares are 18-decimal)
    uint256 internal collateralUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        collateralUnit = 10 ** uint256(cell.collateralAsset.decimals);
    }

    /**
     * @notice Drives the live composed tranche-unit-to-NAV-unit rate to exactly zero through reachable knobs
     * @dev Hand derivation of the zero, hop by hop (18-decimal shares over an 18-decimal underlying, so the
     *      quoter's WAD-scaling share amount is 10^(18 + 18 - 18) = 1e18):
     *      vault hop:  convertToAssets(1e18) = floor(1e18 x 1 / 1e18) = 1 wei. The mock vault rejects a zero
     *                  rate outright, so a 1-wei share price is the smallest reachable vault hop — this is the
     *                  boundary just above the trivially-broken zero, not an artificial state
     *      feed hop:   floor(99000000 x 1e18 / 1e8) = 0.99e18, and 99000000 > 0 clears the feed's zero-answer gate
     *      composed:   floor(1 x 0.99e18 / 1e18) = 0
     *      A zero feed answer would have reverted INVALID_PRICE, but the composed product is never checked, so
     *      the exact same broken price (zero) is accepted when it emerges one hop later
     */
    function _collapseToComposedZeroRate() internal {
        stJtVault.setRate(1);
        priceFeed.setAnswer(SUB_PEG_FEED_ANSWER);
    }

    // =============================
    // Forward conversion accepts the zero composed rate
    // =============================

    /**
     * @notice With the composed rate floored to zero, the quoter reports the rate as a plain zero and forward
     *         conversion values a whole collateral share, the deposit unit of both tranches, at 0 NAV with no revert
     * @dev The composed product is not gated on zero the way the feed hop is, so the zero flows through as an
     *      ordinary number and every downstream NAV mark becomes zero
     */
    function test_ComposedZeroRate_forwardConversionYieldsZeroNAV() public {
        _collapseToComposedZeroRate();

        // The composed rate is exactly zero: floor(1 x 0.99e18 / 1e18) = 0 — accepted where the feed's own
        // zero-answer gate would have reverted, because only the feed hop is checked, never the product
        assertEq(kernel.getTrancheUnitToNAVUnitConversionRateWAD(), 0, "the 1-wei vault hop times the 0.99 feed hop must floor the composed rate to zero");

        // One whole 18-decimal share forward-converts as floor(1e18 x 0 / 1e18) = 0 NAV through the one converter
        // both tranches deposit against: real deposited capital is priced at nothing and no error surfaces to the
        // caller or to a syncing keeper
        assertEq(
            toUint256(kernel.convertCollateralAssetsToValue(toTrancheUnits(collateralUnit))),
            0,
            "a whole collateral share must silently value to 0 NAV at the zero composed rate"
        );
    }

    // =============================
    // Backward conversion reverts on the same zero composed rate
    // =============================

    /**
     * @notice The same zero composed rate that forward conversion accepts makes backward conversion revert with
     *         division-by-zero
     * @dev Backward conversion computes floor(nav x 1e18 / composedRate), so a zero rate is a zero denominator:
     *      floor(1e18 x 1e18 / 0) hits Solidity's division-by-zero check, Panic(0x12). Every caller that
     *      backward-converts (previews, max views, redemption sizing) reverts with that panic
     */
    function test_ComposedZeroRate_backwardConversionRevertsDivisionByZero() public {
        _collapseToComposedZeroRate();

        // floor(1e18 NAV x 1e18 / 0) divides by the zero composed rate, Panic(0x12), for every backward consumer
        // of the one collateral converter both tranches share
        vm.expectRevert(stdError.divisionError);
        kernel.convertValueToCollateralAssets(toNAVUnits(uint256(1e18)));
    }

    // =============================
    // A sync commits zeroed NAVs at the zero composed rate, then the max-deposit view reverts
    // =============================

    /**
     * @notice A sync at the zero composed rate marks the collateral NAV to zero and the waterfall commits a
     *         checkpoint that zeroes both effective NAVs, while both risk metrics read zero. The booked
     *         impermanent loss enters the fixed term, whose gate zeroes the senior max-deposit view
     * @dev Hand derivation from the seeded amounts: 100e18 senior and 30e18 junior shares deposited at a 1.0
     *      share price and a 1.0 feed mark the collateral NAV at 130e18. At the collapsed rate the mark becomes
     *      floor(130e18 x 0 / 1e18) = 0, a 130e18 loss. The attribution gives ST floor(130e18 x 100e18 / 130e18)
     *      = 100e18 of it and JT the 30e18 residual, and the waterfall's conservation identity
     *      (collateralNAV == stEff + jtEff) forces stEff = jtEff = 0. The zeroed state reads healthy: coverage
     *      utilization returns 0 because no collateral NAV survives the wipe (nothing is left to protect), and
     *      liquidity utilization returns 0 because there is no senior value left to market-make, but the junior
     *      wipe extinguishes the junior buffer, so the wipeout disjunct forces perpetual and erases the 30e18
     *      drawdown (the dead restoration claim). The sync commits the zeroed checkpoint
     * @dev Max-deposit derivation: the view previews the sync at the live zero rate, the coverage leg reads a
     *      zero capacity off the wiped junior buffer, and the zero-capacity short-circuit returns zero tranche
     *      units before the backward conversion ever divides by the zero composed rate
     */
    function test_ComposedZeroRate_syncCommitsZeroedNAVsAndMaxDepositReturnsZero() public {
        _seedMarket(ST_SEED_WHOLE * collateralUnit, JT_SEED_WHOLE * collateralUnit);
        _collapseToComposedZeroRate();

        // The sync succeeds and commits the zeroed checkpoint (no revert to catch)
        SyncedAccountingState memory state = _sync();

        // The collateral mark: all 130e18 deposited shares times the zero composed rate floor to zero, and both
        // tranche raw-NAV surfaces report the one zeroed pool
        assertEq(toUint256(state.collateralNAV), 0, "130e18 collateral shares x the zero composed rate must mark collateralNAV to 0");
        assertEq(_liveCollateralNAV(), 0, "the live collateral NAV must read zero after the wipe");

        // Conservation (collateralNAV == stEff + jtEff) with a zero collateral mark wipes both effective NAVs: the
        // junior buffer absorbs a phantom 30e18 loss and the senior claim on 100e18 evaporates alongside it
        assertEq(toUint256(state.stEffectiveNAV), 0, "the waterfall must wipe stEffectiveNAV to 0 off the pricing artifact");
        assertEq(toUint256(state.jtEffectiveNAV), 0, "the waterfall must wipe jtEffectiveNAV to 0 off the pricing artifact");

        // The zeroing is committed, not just previewed: the checkpoint now anchors all future waterfalls at zero,
        // so even a rate recovery next block would book the rebound as fresh senior gain, not a correction
        IRoycoDayAccountant.RoycoDayAccountantState memory committed = accountant.getState();
        assertEq(toUint256(committed.lastCollateralNAV), 0, "the committed checkpoint must carry the zeroed collateral NAV");
        assertEq(toUint256(committed.lastSTEffectiveNAV), 0, "the committed checkpoint must carry the wiped senior effective NAV");
        assertEq(toUint256(committed.lastJTEffectiveNAV), 0, "the committed checkpoint must carry the wiped junior effective NAV");

        // Both risk metrics read healthy (zero exposure needs no coverage and zero senior value needs no
        // liquidity), and the junior wipe forces perpetual with the 30e18 drawdown erased at the commit
        assertEq(state.coverageUtilizationWAD, 0, "coverage utilization must read a healthy 0 (no collateral NAV survives the wipe)");
        assertEq(state.liquidityUtilizationWAD, 0, "liquidity utilization must read a healthy 0 (no senior value survives the wipe)");
        assertEq(toUint256(state.jtImpermanentLoss), 0, "the wipeout must erase the junior drawdown at the perpetual commit");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "the extinguished junior buffer must force perpetual");

        // The quote-only LT pool is untouched by the senior share price, its 6e18 mark survives the collapse
        assertEq(toUint256(state.ltRawNAV), SEEDED_LT_RAW_NAV, "the quote-only LT depth must be unaffected by the senior pricing collapse");

        // The max-deposit view returns zero: the wiped junior buffer zeroes the coverage capacity and the
        // zero-capacity short-circuit returns before the backward conversion can divide by the live zero composed rate
        assertEq(toUint256(kernel.stMaxDeposit(ST_PROVIDER)), 0, "the zero-capacity short-circuit must zero the senior deposit capacity without a panic");
    }
}
