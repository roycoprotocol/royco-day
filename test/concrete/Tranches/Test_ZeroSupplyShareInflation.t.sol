// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { LPT_LP_ROLE } from "../../../src/factory/Roles.sol";
import { MAX_MINT_DILUTION_WAD, VIRTUAL_SHARES, WAD } from "../../../src/libraries/Constants.sol";
import { NAV_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { ValuationLogic } from "../../../src/libraries/logic/ValuationLogic.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { MarketParamsConfig } from "../../utils/FixtureTypes.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_ZeroSupplyShareInflation
 * @notice REGRESSION pins for the share-price inflation class rooted in `ValuationLogic._convertToShares`, closed by
 *         the virtual shares/assets hardening: the 1:1 bootstrap is now exempt only for a genuinely fresh tranche
 *         (supply == 0 AND backing == 0), and an empty-with-backing state prices against the (supply + VIRTUAL_SHARES)
 *         over (backing + VIRTUAL_ASSETS) basis, stranding the pre-existing backing to the virtual shares instead of
 *         handing it to the bootstrap depositor. Every tranche deposit prices through this primitive, so these pins
 *         cover ST/JT/LPT at once.
 *
 *         The amplifier that made this reachable WITHOUT an external donation is protocol-credited value that is
 *         independent of a tranche's own share supply:
 *           - LPT: the liquidity premium (senior shares the kernel stages for the LPT) accrues even with zero LPT holders
 *           - JT: the risk premium is booked into jtEffectiveNAV independent of JT tranche supply
 *         The senior tranche has no such amplifier: its NAV basis is its own underlying (which scales with its shares)
 *         plus loss cross-claims, and the kernel accounts assets internally (`totalCollateralAssets`, not
 *         `balanceOf`), so a raw ERC20 donation cannot inflate it. ST is documented non-vulnerable in ROOT_A_note.
 *
 * @dev Each test asserts the safe invariant the hardening guarantees, none design-specific: (a) no windfall, a
 *      depositor's position NAV must not exceed its deposit NAV, (b) no DoS/robbery, after a bootstrap mint, a
 *      normal depositor must still enter and keep ~its deposit value.
 * @dev The sibling `totalValue == 0, supply > 0` branch (priced against the 1-wei VIRTUAL_ASSETS denominator) is
 *      bounded by the mint-dilution clamp (MAX_MINT_DILUTION_WAD), pinned to its exact cap in
 *      `test_ZeroBacking_ClampAlreadyBoundsIt` below.
 */
contract Test_ZeroSupplyShareInflation is DayMarketTestBase {
    uint256 internal stUnit;
    uint256 internal quoteUnit;

    function setUp() public {
        MarketParamsConfig memory p = defaultParams();
        p.minLiquidityWAD = 0; // decouple deposits from a liquidity gate so a bare bootstrap deposit lands
        p.lptYieldShareProtocolFeeWAD = 0; // no LPT protocol fee, so the fee mint does not create a phantom first LPT share
        _deployMarket(cellA(), p);
        stUnit = 10 ** uint256(cell.collateralAsset.decimals);
        quoteUnit = 10 ** uint256(cell.quoteAsset.decimals);
    }

    /*//////////////////////////////////////////////////////////////////////
                ROOT PRIMITIVE (shared by every tranche deposit)
    //////////////////////////////////////////////////////////////////////*/

    /**
     * ROOT: zero supply against a nonzero backing NAV, the first mint must not hand the depositor a claim on the
     * pre-existing backing. Under the virtual offset the empty-with-backing state falls through to the priced branch
     * (floor((0 + 1e6) x deposit / (backing + 1))), so the backing stays stranded to the virtual shares and the
     * depositor's round-trip claim is strictly below its deposit (both conversions floor). This is the single
     * primitive every tranche deposit prices through, so this pin covers ST/JT/LPT at once.
     */
    function test_Root_ZeroSupply_FirstMintMustNotCaptureBackingNAV() public pure {
        uint256 backingNAV = 1000e18;
        uint256 depositNAV = 1e18;
        // A first deposit into a tranche that already has `backingNAV` of unowned backing
        uint256 shares = ValuationLogic._convertToShares(toNAVUnits(depositNAV), toNAVUnits(backingNAV), 0, Math.Rounding.Floor);
        // The minted shares, valued back against the post-deposit tranche, must claim no more than the deposit, the
        // pre-existing backing must NOT be captured (pre-hardening the 1:1 bootstrap made these shares own backing + deposit)
        NAV_UNIT roundTrip = ValuationLogic._convertToValue(shares, shares, toNAVUnits(backingNAV + depositNAV), Math.Rounding.Floor);
        assertLe(toUint256(roundTrip), depositNAV, "ROOT: a bootstrap mint must claim no more than its deposit");
    }

    /**
     * PRODUCTION PIN: the bootstrap 1:1 branch and the clamp's bind boundary, asserted directly against
     * `ValuationLogic._convertToShares` (the mirror-level pins live in Test_RoycoTestMath): a genuinely fresh
     * tranche mints 1:1, the largest non-binding value prices fair to EXACTLY the cap (branch continuity, since
     * (WAD - MAX_MINT_DILUTION_WAD) / 1e6 = 1e12 - 1 divides the boundary value), and one more wei flips into
     * the clamp branch returning the same cap.
     */
    function test_Primitive_BootstrapAndClampBindBoundary_ProductionPins() public pure {
        // Bootstrap: supply == 0 AND backing == 0 mints exactly 1:1
        assertEq(
            ValuationLogic._convertToShares(toNAVUnits(uint256(123e18)), toNAVUnits(uint256(0)), 0, Math.Rounding.Floor),
            123e18,
            "a genuinely fresh tranche must mint 1:1"
        );

        // Clamp bind boundary at a live (supply, backing): the largest non-binding value is
        // floor((backing + 1) * MAX_MINT_DILUTION_WAD / (WAD - MAX_MINT_DILUTION_WAD)), the integer complement of
        // production's ceil-form bind predicate
        uint256 supply = 1e18;
        uint256 backing = 1e18;
        uint256 boundaryValue = Math.mulDiv(backing + 1, MAX_MINT_DILUTION_WAD, WAD - MAX_MINT_DILUTION_WAD);
        uint256 cap = Math.mulDiv(supply + VIRTUAL_SHARES, MAX_MINT_DILUTION_WAD, WAD - MAX_MINT_DILUTION_WAD);
        // The largest non-binding value prices FAIR to exactly the cap: the two branches meet with no discontinuity
        assertEq(
            ValuationLogic._convertToShares(toNAVUnits(boundaryValue), toNAVUnits(backing), supply, Math.Rounding.Floor),
            cap,
            "the largest non-binding value must price fair to exactly the cap"
        );
        // One more wei crosses into the clamp branch and returns the same cap
        assertEq(
            ValuationLogic._convertToShares(toNAVUnits(boundaryValue + 1), toNAVUnits(backing), supply, Math.Rounding.Floor),
            cap,
            "one wei past the boundary must clamp to the same cap"
        );
    }

    /**
     * CONTROL: the sibling zero-backing branch is bounded by the mint-dilution clamp, the 1-wei VIRTUAL_ASSETS
     * denominator makes the fair price bind the clamp, which mints exactly the cap on the effective supply,
     * floor((supply + VIRTUAL_SHARES) x MAX_MINT_DILUTION_WAD / (WAD - MAX_MINT_DILUTION_WAD)).
     */
    function test_ZeroBacking_ClampAlreadyBoundsIt() public pure {
        uint256 supply = 1e18;
        uint256 value = 1000e18;
        uint256 shares = ValuationLogic._convertToShares(toNAVUnits(value), toNAVUnits(uint256(0)), supply, Math.Rounding.Floor);
        assertEq(
            shares,
            Math.mulDiv(supply + VIRTUAL_SHARES, MAX_MINT_DILUTION_WAD, WAD - MAX_MINT_DILUTION_WAD),
            "the zero-backing mint clamps to the exact dilution cap on the effective supply"
        );
    }

    /*//////////////////////////////////////////////////////////////////////
                LPT PREMIUM STAGED FOR AN EMPTY TRANCHE (windfall)
    //////////////////////////////////////////////////////////////////////*/

    /**
     * INSTANCE LPT-WINDFALL: the liquidity premium (ST shares staged for the LPT) accrues while the LPT tranche has
     * ZERO shares (minLiquidity 0, LPT yield-share curve nonzero), so `_getLiquidityProviderTrancheEffectiveNAV` is positive
     * with LPT supply 0. Pre-hardening the first LPT depositor minted 1:1 and captured the entire staged premium,
     * under the virtual offset the premium stays stranded to the virtual shares and the first LPT depositor's
     * position is worth ~its deposit (1% slack absorbs the integration path's multiple floors)
     */
    function test_LPT_PremiumToEmptyTranche_FirstDepositorMustNotCaptureIt() public {
        _seedMarket(1000 * stUnit, 500 * stUnit);
        assertEq(liquidityProviderTranche.totalSupply(), 0, "precondition: LPT has zero shares");

        // Keep the premium staged as idle senior shares (venue reinvestment fails), then accrue senior yield
        setVenueSlippageMode(true);
        for (uint256 i = 0; i < 5; ++i) {
            applySTPnL(2000); // +20% senior yield
            _warpAndRefreshFeed(7 days);
            syncVenuePrices();
            _sync();
        }
        assertGt(kernel.getState().lptOwnedSeniorTrancheShares, 0, "precondition: premium staged for an empty LPT");
        assertEq(liquidityProviderTranche.totalSupply(), 0, "precondition: LPT still empty");

        // First LPT depositor arrives with a tiny position
        address dave = makeAddr("DAVE_FIRST_LP");
        accessManager.grantRole(LPT_LP_ROLE, dave, 0);
        uint256 daveBpt = 1e18;
        _mintBptTo(dave, daveBpt, quoteUnit);
        uint256 daveDepositNAV = toUint256(kernel.convertLPTAssetsToValue(toTrancheUnits(daveBpt)));

        vm.startPrank(dave);
        bpt.approve(address(liquidityProviderTranche), daveBpt);
        uint256 daveShares = liquidityProviderTranche.deposit(toTrancheUnits(daveBpt), dave);
        vm.stopPrank();

        // Dave's own redeemable claim (not the tranche total): the staged premium must stay stranded to the phantom
        // shares, so Dave can only redeem ~his deposit
        uint256 daveClaimNAV = toUint256(liquidityProviderTranche.previewRedeem(daveShares).nav);
        assertLe(daveClaimNAV, daveDepositNAV + daveDepositNAV / 100, "LPT-WINDFALL: first LPT depositor must not capture the staged premium");
    }
    // NOTE: the "wiped JT + fresh deposit captures the recovery" scenario is intentionally NOT a test here. Once
    // jtEffectiveNAV hits zero the existing JT shares back zero NAV and are correctly diluted, a fresh depositor
    // providing the only real backing SHOULD own the tranche and capture yield from then on (standard vault
    // semantics, unchanged by virtual shares, at zero backing there is nothing to strand). The only questionable
    // part, a ~zero-buffer JT earning the MAXIMUM risk premium (jtEff == 0 -> coverageUtilization == max -> yield
    // share cap), is a YDM/accountant policy question tracked by the coverage cross-claim findings, not a
    // share-pricing bug.

    /*//////////////////////////////////////////////////////////////////////
                            SHARED HELPERS
    //////////////////////////////////////////////////////////////////////*/

    function _mintBptTo(address _to, uint256 _bptAmount, uint256 _quoteLeg) internal {
        quoteToken.mint(address(this), _quoteLeg);
        quoteToken.approve(address(balancerVault), _quoteLeg);
        uint256[2] memory legs;
        legs[1 - stPoolTokenIndex] = _quoteLeg;
        balancerVault.mintPoolTokensTo(address(bpt), _to, _bptAmount, legs);
    }
}
