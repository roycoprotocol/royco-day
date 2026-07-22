// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { stdError } from "../../../lib/forge-std/src/StdError.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";

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

    /// @dev One whole ST/JT vault share in tranche units (this market's shares are 18-decimal)
    uint256 internal stUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.stAsset.decimals);
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
     *         conversion values whole shares of both tranches at 0 NAV, with no revert
     * @dev The composed product is not gated on zero the way the feed hop is, so the zero flows through as an
     *      ordinary number and every downstream NAV mark becomes zero
     */
    function test_ComposedZeroRate_forwardConversionYieldsZeroNAVForBothTranches() public {
        _collapseToComposedZeroRate();

        // The composed rate is exactly zero: floor(1 x 0.99e18 / 1e18) = 0 — accepted where the feed's own
        // zero-answer gate would have reverted, because only the feed hop is checked, never the product
        assertEq(kernel.getTrancheUnitToNAVUnitConversionRateWAD(), 0, "the 1-wei vault hop times the 0.99 feed hop must floor the composed rate to zero");

        // One whole 18-decimal share forward-converts as floor(1e18 x 0 / 1e18) = 0 NAV for BOTH tranches: real
        // deposited capital is priced at nothing and no error surfaces to the caller or to a syncing keeper
        assertEq(toUint256(kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(stUnit))), 0, "a whole senior share must silently value to 0 NAV at the zero composed rate");
        assertEq(toUint256(kernel.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(stUnit))), 0, "a whole junior share must silently value to 0 NAV at the zero composed rate");
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

        // Senior direction: floor(1e18 NAV x 1e18 / 0) divides by the zero composed rate, Panic(0x12)
        vm.expectRevert(stdError.divisionError);
        kernel.stConvertNAVUnitsToTrancheUnits(toNAVUnits(uint256(1e18)));

        // Junior direction: identical assets share the identical zero rate, so the same panic fires
        vm.expectRevert(stdError.divisionError);
        kernel.jtConvertNAVUnitsToTrancheUnits(toNAVUnits(uint256(1e18)));
    }

    // =============================
    // A sync commits zeroed NAVs at the zero composed rate, then the max-deposit view reverts
    // =============================

    /**
     * @notice A sync at the zero composed rate marks stRaw and jtRaw to zero and the waterfall commits a
     *         checkpoint that zeroes both effective NAVs, while both risk metrics read zero. The booked
     *         impermanent loss enters the fixed term, whose gate zeroes the senior max-deposit view
     * @dev Hand derivation from the seeded amounts: 100e18 senior shares and 30e18 junior shares deposited at a
     *      1.0 share price and a 1.0 feed mark stRaw = 100e18 and jtRaw = 30e18. At the collapsed rate the raw
     *      marks become floor(100e18 x 0 / 1e18) = 0 and floor(30e18 x 0 / 1e18) = 0, and the waterfall's
     *      conservation identity (stRaw + jtRaw == stEff + jtEff) forces stEff = jtEff = 0. The zeroed state
     *      reads healthy: coverage utilization returns 0 because there is no covered exposure left (0 raw NAV
     *      needs no protection), and liquidity utilization returns 0 because there is no senior value left to
     *      market-make, but the junior wipe books its 30e18 drawdown as impermanent loss and the market enters
     *      FIXED_TERM. The sync commits the zeroed checkpoint
     * @dev Max-deposit derivation: the view previews the sync at the live zero rate, and the previewed state
     *      carries the booked impermanent loss so it reads FIXED_TERM: the senior-deposit gate short-circuits
     *      to zero tranche units before the backward conversion ever divides by the zero composed rate
     */
    function test_ComposedZeroRate_syncCommitsZeroedNAVsAndMaxDepositReturnsZero() public {
        _seedMarket(ST_SEED_WHOLE * stUnit, JT_SEED_WHOLE * stUnit);
        _collapseToComposedZeroRate();

        // The sync succeeds and commits the zeroed checkpoint (no revert to catch)
        SyncedAccountingState memory state = _sync();

        // Raw marks: every deposited share times the zero composed rate floors to zero
        assertEq(toUint256(state.stRawNAV), 0, "100e18 senior shares x the zero composed rate must mark stRawNAV to 0");
        assertEq(toUint256(state.jtRawNAV), 0, "30e18 junior shares x the zero composed rate must mark jtRawNAV to 0");

        // Conservation (stRaw + jtRaw == stEff + jtEff) with a zero raw total wipes both effective NAVs: the
        // junior buffer absorbs a phantom 30e18 loss and the senior claim on 100e18 evaporates alongside it
        assertEq(toUint256(state.stEffectiveNAV), 0, "the waterfall must wipe stEffectiveNAV to 0 off the pricing artifact");
        assertEq(toUint256(state.jtEffectiveNAV), 0, "the waterfall must wipe jtEffectiveNAV to 0 off the pricing artifact");

        // The zeroing is committed, not just previewed: the checkpoint now anchors all future waterfalls at zero,
        // so even a rate recovery next block would book the rebound as fresh senior gain, not a correction
        IRoycoDayAccountant.RoycoDayAccountantState memory committed = accountant.getState();
        assertEq(toUint256(committed.lastSTRawNAV), 0, "the committed checkpoint must carry the zeroed senior raw NAV");
        assertEq(toUint256(committed.lastJTRawNAV), 0, "the committed checkpoint must carry the zeroed junior raw NAV");
        assertEq(toUint256(committed.lastSTEffectiveNAV), 0, "the committed checkpoint must carry the wiped senior effective NAV");
        assertEq(toUint256(committed.lastJTEffectiveNAV), 0, "the committed checkpoint must carry the wiped junior effective NAV");

        // Both risk metrics read healthy (zero exposure needs no coverage and zero senior value needs no
        // liquidity), but the junior wipe books its full 30e18 drawdown as impermanent loss so the market enters FIXED_TERM
        assertEq(state.coverageUtilizationWAD, 0, "coverage utilization must read a healthy 0 (no covered exposure survives the wipe)");
        assertEq(state.liquidityUtilizationWAD, 0, "liquidity utilization must read a healthy 0 (no senior value survives the wipe)");
        assertEq(toUint256(state.jtImpermanentLoss), 30e18, "the junior wipe must book its full drawdown as impermanent loss");
        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "the booked impermanent loss must enter the fixed term");

        // The quote-only LT pool is untouched by the senior share price, its 6e18 mark survives the collapse
        assertEq(toUint256(state.ltRawNAV), SEEDED_LT_RAW_NAV, "the quote-only LT depth must be unaffected by the senior pricing collapse");

        // The max-deposit view returns zero: the previewed FIXED_TERM state gates senior deposits before the
        // backward conversion can divide by the live zero composed rate
        assertEq(toUint256(kernel.stMaxDeposit(ST_PROVIDER)), 0, "the fixed-term gate must zero the senior deposit capacity without a panic");
    }
}
