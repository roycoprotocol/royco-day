// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { toTrancheUnits, toUint256 } from "../../src/libraries/Units.sol";
import { DayMarketTestBase } from "./DayMarketTestBase.sol";
import { defaultParams } from "./MarketParams.sol";
import { cellA } from "./TokenConfigs.sol";

/**
 * @title MarketFuzzTestBase
 * @notice Shared base for the market-level fuzz suites: the baseline token shape (18-decimal ST/JT vault shares
 *         over an 18-decimal underlying, 6-decimal quote stable) at the default market parameterization
 * @dev setUp only deploys (it re-runs per fuzz run), all seeding happens inside each test with fuzzed sizes.
 *      In this token shape at a 1.0 vault rate and a 1.0 oracle price one vault-share wei is worth exactly one
 *      NAV wei, so seed sizes written in NAV wei are also exact tranche-unit amounts and initial share mints are 1:1
 */
abstract contract MarketFuzzTestBase is DayMarketTestBase {
    /// @dev NAV wei per quote wei at a 1.0 quote price (18 NAV decimals over the baseline shape's 6-decimal quote)
    uint256 internal constant QUOTE_TO_NAV_SCALE = 1e12;

    function setUp() public virtual {
        _deployMarket(cellA(), defaultParams());
    }

    /**
     * @notice Seeds a flat market (vault rate 1.0, every price 1.0): _jt into JT, _st into ST, plus _extraQuote
     *         quote wei of additional quote-only pool depth, returning the derived total LT raw NAV
     * @dev The fixture auto-seeds the minimal quote-only depth the liquidity-gated ST seed deposit needs:
     *      autoQuote = ceil(ceil(_st / 20) / 1e12) + 1e6 quote wei, which is the required depth
     *      ceil(_st x 5% liquidity requirement) rounded up to quote precision plus one whole quote unit of
     *      cushion, minted as BPT 1:1 with its NAV so the pool's NAV-per-BPT stays exactly 1.0. The explicit
     *      extra leg is minted the same way, so ltRawNAV = (autoQuote + _extraQuote) x 1e12 exactly, and the
     *      helper pins the live read against that derivation
     */
    function _seedFlatMarket(uint256 _st, uint256 _jt, uint256 _extraQuote) internal returns (uint256 ltRawNAV) {
        _seedMarket(_st, _jt);
        if (_extraQuote != 0) _seedLT(_extraQuote * QUOTE_TO_NAV_SCALE, 0, _extraQuote);
        // Independent plain-integer re-derivation of the auto-seeded depth (deliberately no shared ceil helper
        // with the fixture, so a rounding bug in its math-library calls fails this pin): the liquidity gate
        // requires ltRawNAV >= ceil(5% of the post-deposit senior effective NAV), and at a 1.0 vault rate and 1.0
        // prices that NAV is exactly _st, so the required depth is ceil(_st / 20) = (_st + 19) / 20 NAV wei. The
        // fixture funds it quote-only, rounded up to whole quote wei (1 quote wei == 1e12 NAV wei) plus one whole
        // quote unit (1e6 quote wei) of cushion, minting BPT 1:1 with the NAV added.
        // Worked example, _st = 1e18 + 1: required = (1e18 + 20) / 20 = 5e16 + 1 NAV wei, auto quote leg
        // = (5e16 + 1 + (1e12 - 1)) / 1e12 + 1e6 = 50_001 + 1_000_000 = 1_050_001 quote wei, so with
        // _extraQuote = 0 the seeded depth is exactly 1_050_001e12 NAV wei
        uint256 autoQuote = ((_st + 19) / 20 + (QUOTE_TO_NAV_SCALE - 1)) / QUOTE_TO_NAV_SCALE + 1e6;
        ltRawNAV = (autoQuote + _extraQuote) * QUOTE_TO_NAV_SCALE;
        assertEq(toUint256(liquidityTranche.getRawNAV()), ltRawNAV, "seeded LT depth must match the derived quote-backed BPT value");
    }

    /// @notice Mints vault shares to ST_PROVIDER and deposits them into the senior tranche
    function _depositSenior(uint256 _assets) internal returns (uint256 shares) {
        stJtVault.mintShares(ST_PROVIDER, _assets);
        vm.startPrank(ST_PROVIDER);
        stJtVault.approve(address(seniorTranche), _assets);
        shares = seniorTranche.deposit(toTrancheUnits(_assets), ST_PROVIDER);
        vm.stopPrank();
    }

    /// @notice Mints vault shares to JT_PROVIDER and deposits them into the junior tranche
    function _depositJunior(uint256 _assets) internal returns (uint256 shares) {
        stJtVault.mintShares(JT_PROVIDER, _assets);
        vm.startPrank(JT_PROVIDER);
        stJtVault.approve(address(juniorTranche), _assets);
        shares = juniorTranche.deposit(toTrancheUnits(_assets), JT_PROVIDER);
        vm.stopPrank();
    }

    /**
     * @notice Mints quote-backed BPT to the receiver through the mock vault's external-LP helper
     * @dev The quote leg is funded by this fixture and mapped through the pool's sorted registration order,
     *      mirroring DayMarketTestBase._seedLT's quote-only leg placement
     */
    function _mintQuoteBackedBPT(address _to, uint256 _bptAmount, uint256 _quoteLeg) internal {
        quoteToken.mint(address(this), _quoteLeg);
        quoteToken.approve(address(balancerVault), _quoteLeg);
        uint256[2] memory legs;
        legs[1 - stPoolTokenIndex] = _quoteLeg;
        balancerVault.mintPoolTokensTo(address(bpt), _to, _bptAmount, legs);
    }
}
