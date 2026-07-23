// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { toUint256 } from "../../src/libraries/Units.sol";
import { FixtureCell } from "../utils/FixtureTypes.sol";
import { cellI } from "../utils/TokenConfigs.sol";
import { Test_MarketLifecycleBase } from "./Test_MarketLifecycleBase.t.sol";

/**
 * @title Test_MarketLifecycle_8DecQuote_NonStandardTokens
 * @notice Market lifecycle on an 8-decimal quote stable against the baseline 4626(18,18) ST/JT shares
 * @dev The inherited lifecycle's exact constants hold unchanged because every constant is denominated in WAD NAV,
 *      tranche shares, or BPT (all 18-decimal in every token shape). The quote's 8 decimals surface only in the
 *      pool's raw token balances, pinned by the arithmetic below
 * @dev Nightly-only concrete, matched by the shared NonStandardTokens contract-name suffix
 *      (forge test --match-contract NonStandardTokens)
 */
contract Test_MarketLifecycle_8DecQuote_NonStandardTokens is Test_MarketLifecycleBase {
    function _tokenShape() internal pure override returns (FixtureCell memory) {
        return cellI();
    }

    /**
     * @dev Hand derivation for this shape: one whole ST asset = 1e18 share-wei, at initialRateWAD 1.0 that
     *      converts to 1e18 underlying-wei = 1.0 whole 18-decimal underlying, and the 1.0 oracle price maps one
     *      whole underlying to exactly 1e18 NAV wei. The quote decimals do not enter the ST quoter at all
     */
    function _expectedSTUnitNAV() internal pure override returns (uint256) {
        return 1e18;
    }

    /**
     * @notice The canonical seed's quote leg lands in 8-decimal wei while every mark stays exact WAD
     * @dev Seeds the canonical market and pins the pool's raw quote balance to its 8-decimal derivation. Why it
     *      matters: this is the axis the shape exists for — the fixture's seed helpers convert WAD NAV to quote
     *      wei with ceil rounding, and an off-by-one-decimal bug would land a 100x-wrong leg while the WAD marks
     *      could still be forced to agree. Derivation at 1.0 quote price:
     *      genesis backing for the 1e6 dead BPT = max(1, ceil(1e6 x 1e8 / 1e18)) = 1 quote-wei
     *      ST auto-seed leg = ceil(5e18 x 1e8 / 1e18) + 1e8 = 5e8 + 1e8 = 6e8 quote-wei (6e18 NAV)
     *      explicit seed leg = 20 x 1e8 = 20e8 quote-wei (20e18 NAV)
     *      pool quote balance = 1 + 6e8 + 20e8 = 2600000001 quote-wei
     */
    function test_EightDecimalQuote_poolLegLandsInQuoteWeiWhileMarksStayWAD() public {
        _seedDefault();
        assertEq(
            balancerVault.getPoolBalances(address(bpt))[1 - stPoolTokenIndex],
            2_600_000_001,
            "the pool's quote leg must be 1 + 6e8 + 20e8 = 2600000001 eight-decimal wei"
        );
        // The kernel-owned depth those wei back is the same shape-independent WAD mark every shape seeds:
        // 6e8 wei x 1e18 / 1e8 = 6e18 plus the 20e18 explicit BPT = 26e18
        assertEq(_liveLTRawNAV(), SEEDED_LT_RAW_NAV, "the 8-decimal quote leg must still mark 26e18 WAD of seeded depth");
    }
}
