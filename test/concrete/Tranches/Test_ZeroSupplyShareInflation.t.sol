// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { LT_LP_ROLE } from "../../../src/factory/Roles.sol";
import { NAV_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { ValuationLogic } from "../../../src/libraries/logic/ValuationLogic.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { MarketParamsConfig } from "../../utils/FixtureTypes.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_ZeroSupplyShareInflation
 * @notice ACCEPTANCE (fail-first) tests for the share-price inflation class rooted in
 *         `ValuationLogic._convertToShares`: when `totalSupply == 0` it mints 1:1 with the deposit value and IGNORES
 *         the tranche's existing NAV basis. Every tranche deposit prices through this primitive, so any state where a
 *         tranche's backing NAV is nonzero while its share supply is 0 (or a bootstrap 1-share) lets that mint capture
 *         the backing, or brick/rob the next depositor.
 *
 *         The amplifier that makes this reachable WITHOUT an external donation is protocol-credited value that is
 *         independent of a tranche's own share supply:
 *           - LT: the liquidity premium (senior shares the kernel stages for the LT) accrues even with zero LT holders
 *           - JT: the risk premium is booked into jtEffectiveNAV independent of JT tranche supply
 *         The senior tranche has no such amplifier: its NAV basis is its own underlying (which scales with its shares)
 *         plus loss cross-claims, and the kernel accounts assets internally (`stOwnedYieldBearingAssets`, not
 *         `balanceOf`), so a raw ERC20 donation cannot inflate it — ST is documented non-vulnerable in ROOT_A_note.
 *
 * @dev Every finding test asserts the DESIRED (safe) invariant and FAILS against current code by design; they go
 *      green when the primitive is hardened (virtual shares/offset, seeding the first mint against the live NAV
 *      basis, or routing pre-existing backing away from the bootstrap depositor). The safe invariants, none
 *      design-specific: (a) no windfall — a depositor's position NAV must not exceed its deposit NAV beyond dust;
 *      (b) no DoS/robbery — after a bootstrap mint, a normal depositor must still enter and keep ~its deposit value.
 * @dev The sibling `totalValue == 0, supply > 0` branch (`shares = supply * value`) is NOT reproduced here: the
 *      mint-dilution clamp (MAX_MINT_DILUTION_WAD) already bounds it, verified by the passing assertion in
 *      `test_ZeroBacking_ClampAlreadyBoundsIt` below.
 */
contract Test_ZeroSupplyShareInflation is DayMarketTestBase {
    uint256 internal stUnit;
    uint256 internal quoteUnit;

    function setUp() public {
        MarketParamsConfig memory p = defaultParams();
        p.minLiquidityWAD = 0; // decouple deposits from a liquidity gate so a bare bootstrap deposit lands
        p.ltYieldShareProtocolFeeWAD = 0; // no LT protocol fee, so the fee mint does not create a phantom first LT share
        _deployMarket(cellA(), p);
        stUnit = 10 ** uint256(cell.stAsset.decimals);
        quoteUnit = 10 ** uint256(cell.quoteAsset.decimals);
    }

    /*//////////////////////////////////////////////////////////////////////
                ROOT PRIMITIVE (shared by every tranche deposit)
    //////////////////////////////////////////////////////////////////////*/

    /**
     * ROOT (fails today) — zero supply against a nonzero backing NAV: the first mint must not hand the depositor a
     * claim on the pre-existing backing. `_convertToShares(1 wei, 1000e18 backing, supply 0)` returns 1 share today,
     * so that 1 share owns the whole 1000e18 backing the depositor never funded. This is the single primitive every
     * tranche deposit prices through, so hardening it fixes ST/JT/LT at once.
     */
    function test_Root_ZeroSupply_FirstMintMustNotCaptureBackingNAV() public pure {
        uint256 backingNAV = 1000e18;
        uint256 depositNAV = 1e18;
        // A first deposit into a tranche that already has `backingNAV` of unowned backing
        uint256 shares = ValuationLogic._convertToShares(toNAVUnits(depositNAV), toNAVUnits(backingNAV), 0, Math.Rounding.Floor);
        // The minted shares, valued back against the post-deposit tranche, must claim no more than the deposit — the
        // pre-existing backing must NOT be captured (pre-fix the 1:1 bootstrap made these shares own backing + deposit)
        NAV_UNIT roundTrip = ValuationLogic._convertToValue(shares, shares, toNAVUnits(backingNAV + depositNAV), Math.Rounding.Floor);
        assertLe(toUint256(roundTrip), depositNAV + depositNAV / 100, "ROOT: a bootstrap mint must claim no more than its deposit");
    }

    /**
     * CONTROL (passes today, documents the boundary) — the sibling zero-backing branch is already bounded by the
     * mint-dilution clamp, so `shares < supply * value`. This is why only the zero-supply branch above is a live bug.
     */
    function test_ZeroBacking_ClampAlreadyBoundsIt() public pure {
        uint256 supply = 1e18;
        uint256 value = 1000e18;
        uint256 shares = ValuationLogic._convertToShares(toNAVUnits(value), toNAVUnits(uint256(0)), supply, Math.Rounding.Floor);
        assertLt(shares, supply * value, "the dilution clamp bounds the zero-backing mint");
    }

    /*//////////////////////////////////////////////////////////////////////
                LT — PREMIUM STAGED FOR AN EMPTY TRANCHE (windfall)
    //////////////////////////////////////////////////////////////////////*/

    /**
     * INSTANCE LT-WINDFALL (fails today) — the liquidity premium (ST shares staged for the LT) accrues while the LT
     * tranche has ZERO shares (minLiquidity 0, LT yield-share curve nonzero), so `_getLiquidityTrancheEffectiveNAV`
     * is positive with LT supply 0. The first LT depositor mints 1:1 and captures the entire staged premium.
     * DESIRED: the first LT depositor's position is worth ~its deposit, not deposit + staged premium
     */
    function test_LT_PremiumToEmptyTranche_FirstDepositorMustNotCaptureIt() public {
        _seedMarket(1000 * stUnit, 500 * stUnit);
        assertEq(liquidityTranche.totalSupply(), 0, "precondition: LT has zero shares");

        // Keep the premium staged as idle senior shares (venue reinvestment fails), then accrue senior yield
        setVenueSlippageMode(true);
        for (uint256 i = 0; i < 5; ++i) {
            applySTPnL(2000); // +20% senior yield
            _warpAndRefreshFeed(7 days);
            syncVenuePrices();
            _sync();
        }
        assertGt(kernel.getState().ltOwnedSeniorTrancheShares, 0, "precondition: premium staged for an empty LT");
        assertEq(liquidityTranche.totalSupply(), 0, "precondition: LT still empty");

        // First LT depositor arrives with a tiny position
        address dave = makeAddr("DAVE_FIRST_LP");
        accessManager.grantRole(LT_LP_ROLE, dave, 0);
        uint256 daveBpt = 1e18;
        _mintBptTo(dave, daveBpt, quoteUnit);
        uint256 daveDepositNAV = toUint256(kernel.ltConvertTrancheUnitsToNAVUnits(toTrancheUnits(daveBpt)));

        vm.startPrank(dave);
        bpt.approve(address(liquidityTranche), daveBpt);
        uint256 daveShares = liquidityTranche.deposit(toTrancheUnits(daveBpt), dave);
        vm.stopPrank();

        // Dave's own redeemable claim (not the tranche total): the staged premium must stay stranded to the phantom
        // shares, so Dave can only redeem ~his deposit
        uint256 daveClaimNAV = toUint256(liquidityTranche.previewRedeem(daveShares).nav);
        assertLe(daveClaimNAV, daveDepositNAV + daveDepositNAV / 100, "LT-WINDFALL: first LT depositor must not capture the staged premium");
    }
    // NOTE: the "wiped JT + fresh deposit captures the recovery" scenario is intentionally NOT a test here. Once
    // jtEffectiveNAV hits zero the existing JT shares back zero NAV and are correctly diluted; a fresh depositor
    // providing the only real backing SHOULD own the tranche and capture yield from then on (standard vault
    // semantics, unchanged by virtual shares — at zero backing there is nothing to strand). The only questionable
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
