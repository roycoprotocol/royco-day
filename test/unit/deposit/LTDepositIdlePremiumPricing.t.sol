// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { defaultParams } from "../../base/fixtures/MarketParams.sol";
import { cellA } from "../../base/fixtures/TokenConfigs.sol";
import { TrancheFixture } from "../../base/fixtures/TrancheFixture.sol";

/**
 * @title LTDepositIdlePremiumPricingTest
 * @notice Binds the two LT-deposit preview paths the fork suite left partially covered: the idle liquidity-premium
 *         leg of the LT deposit share price, exercised with a nonzero staged premium (every prior LT deposit test
 *         ran at idleSTShares == 0), and the FIXED_TERM early-return of the multi-asset preview, whose non-shares
 *         legs were never asserted
 */
contract LTDepositIdlePremiumPricingTest is TrancheFixture {
    /// @dev Whole ST/JT vault shares seeded. Coverage after seed: (100 + 30) x 0.2 / 30 = 0.8667 <= 1, gate clears
    uint256 internal constant ST_SEED_WHOLE = 100;
    uint256 internal constant JT_SEED_WHOLE = 30;

    uint256 internal stUnit;
    uint256 internal quoteUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.stAsset.decimals);
        quoteUnit = 10 ** uint256(cell.quoteAsset.decimals);
        _seedMarket(ST_SEED_WHOLE * stUnit, JT_SEED_WHOLE * stUnit);
    }

    /**
     * @notice With a staged idle liquidity premium, the LT deposit price is the pool depth PLUS the idle senior
     *         shares valued at the senior share rate — not the pool depth alone
     * @dev Arms venue slippage so a +10% senior gain's premium mints but cannot reinvest, leaving idle senior
     *      shares staged. The preview's navToMintSharesAt must then equal ltRawNAV + floor(idleShares x stEff /
     *      stSupply), the exact effective-NAV pricing. A regression that priced LT deposits off pool depth alone
     *      would drop the idle term and undercharge depositors
     */
    function test_LTDeposit_priceIncludesStagedIdlePremiumLeg() public {
        // Stage an idle premium: slippage blocks the reinvestment, so the minted premium stays as idle senior shares
        setVenueSlippageMode(true);
        applySTPnL(1000);
        _sync();

        uint256 idleShares = kernel.getState().ltOwnedSeniorTrancheShares;
        assertTrue(idleShares != 0, "the gain must have staged a nonzero idle premium");

        // Preview an in-kind LT deposit of one BPT: navToMintSharesAt is the pre-deposit LT effective NAV
        (SyncedAccountingState memory st,,, NAV_UNIT navToMintSharesAt) = kernel.ltPreviewDeposit(toTrancheUnits(1e18));

        // Independently value the idle leg at the senior share rate: floor(idleShares x stEff / stSupply)
        uint256 idleValue = Math.mulDiv(idleShares, toUint256(st.stEffectiveNAV), seniorTranche.totalSupply(), Math.Rounding.Floor);
        assertTrue(idleValue != 0, "the staged idle premium must carry a nonzero value");

        // The deposit price is pool depth plus the idle leg, so it strictly exceeds pool depth alone
        assertEq(toUint256(navToMintSharesAt), toUint256(st.ltRawNAV) + idleValue, "LT deposit price must be ltRawNAV plus the idle premium leg value");
        assertGt(toUint256(navToMintSharesAt), toUint256(st.ltRawNAV), "the idle premium leg must raise the deposit price above pool depth");
    }

    /**
     * @notice In FIXED_TERM, the multi-asset LT deposit preview zeroes ALL of value/navToMint/ltAssetsOut for an
     *         ST-leg deposit (which the reverting execution path forbids), while still returning the live LT supply
     * @dev The reverting ST-leg path returns a fully-zero quote so a caller cannot mistake it for a real quote;
     *      the supply leg stays live because it is read before the branch
     */
    function test_LTDepositMultiAsset_previewInFixedTerm_zeroesAllQuoteLegsForSTLeg() public {
        _enterFixedTerm();

        // An ST-leg multi-asset preview in FIXED_TERM returns the fully-zeroed quote
        (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt, TRANCHE_UNIT ltAssetsOut, uint256 ltTotalSupplyAfterMints) =
            kernel.ltPreviewDepositMultiAsset(toTrancheUnits(stUnit), 0);

        assertEq(toUint256(valueAllocated), 0, "valueAllocated must be zero for a forbidden ST-leg deposit in FIXED_TERM");
        assertEq(toUint256(navToMintSharesAt), 0, "navToMintSharesAt must be zero for a forbidden ST-leg deposit in FIXED_TERM");
        assertEq(toUint256(ltAssetsOut), 0, "ltAssetsOut must be zero for a forbidden ST-leg deposit in FIXED_TERM");
        // The LT supply leg is read before the FIXED_TERM branch, so it stays live (no fee shares mint in FIXED_TERM)
        assertEq(ltTotalSupplyAfterMints, liquidityTranche.totalSupply(), "the LT supply leg stays live and equals the live LT supply");
    }

    /**
     * @notice In FIXED_TERM, a quote-only multi-asset LT deposit preview is a real, nonzero quote — it mints no
     *         senior shares and only deepens liquidity, so it is the one multi-asset deposit FIXED_TERM allows
     */
    function test_LTDepositMultiAsset_previewInFixedTerm_quoteOnlyIsNonzero() public {
        _enterFixedTerm();

        // One whole quote adds 1e18 NAV at the fixture's 1.0 NAV-per-BPT, minting exactly 1e18 BPT
        (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt, TRANCHE_UNIT ltAssetsOut,) = kernel.ltPreviewDepositMultiAsset(toTrancheUnits(0), quoteUnit);

        assertEq(toUint256(ltAssetsOut), 1e18, "a quote-only deposit mints exactly 1e18 BPT in FIXED_TERM");
        assertEq(toUint256(valueAllocated), 1e18, "a quote-only deposit allocates exactly 1e18 NAV in FIXED_TERM");
        // No premium is staged after a covered loss, so the LT effective NAV equals the pool depth: the 6e18 auto-seed
        assertEq(toUint256(navToMintSharesAt), 6e18, "the quote-only LT share price equals the 6e18 pool depth (no idle premium)");
    }

    /// @dev A covered -20% senior drawdown: covUtil = ceil(104e18 x 0.2 / 4e18) = 5.2e18, which enters FIXED_TERM
    function _enterFixedTerm() internal {
        applySTPnL(-2000);
        SyncedAccountingState memory s = _sync();
        assertEq(uint8(s.marketState), uint8(MarketState.FIXED_TERM), "the covered drawdown must enter FIXED_TERM");
    }
}
