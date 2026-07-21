// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { LT_LP_ROLE } from "../../../src/factory/Roles.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { MarketState, SyncedAccountingState, TrancheType } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_LTDepositIdlePremiumPricing_Kernel
 * @notice Binds the LT-deposit pricing paths that depend on the idle liquidity premium senior shares
 *         (ltOwnedSeniorTrancheShares): the idle leg of the LT deposit share price, exercised with a nonzero idle
 *         pile (every prior LT deposit test ran at ltOwnedSeniorTrancheShares == 0), and the FIXED_TERM
 *         early-return of the multi-asset preview, whose non-shares legs were never asserted
 */
contract Test_LTDepositIdlePremiumPricing_Kernel is DayMarketTestBase {
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
     * @notice With idle liquidity premium senior shares outstanding, the LT deposit price is the pool depth PLUS
     *         the idle senior shares valued at the senior share rate, not the pool depth alone
     * @dev Arms venue slippage so a +10% senior gain's premium mints but cannot reinvest, leaving
     *      ltOwnedSeniorTrancheShares nonzero. The tranche's previewDeposit quote must then price the shares at
     *      ltRawNAV + floor(idleShares x stEff / stSupply), the exact effective-NAV pricing. A regression that
     *      priced LT deposits off pool depth alone would drop the idle term and undercharge depositors
     */
    function test_LTDeposit_PriceIncludesIdlePremiumLeg() public {
        uint256 idleShares = _accrueIdlePremiumSeniorShares();

        // The committed post-sync state the deposit prices against (the +10% gain is already synced)
        (SyncedAccountingState memory st,,) = kernel.previewSyncTrancheAccounting(TrancheType.LIQUIDITY);

        // Independently value the idle leg at the senior share rate: floor(idleShares x stEff / stSupply)
        uint256 idleValue = Math.mulDiv(idleShares, toUint256(st.stEffectiveNAV), seniorTranche.totalSupply(), Math.Rounding.Floor);
        assertTrue(idleValue != 0, "the idle liquidity premium senior shares must carry a nonzero value");

        // Quote an in-kind LT deposit of one BPT through the tranche preview. The one BPT's NAV at the oracle mark
        // is derived from the mock venue's ledger, never the kernel's own conversion chain
        uint256 depositValue = Math.mulDiv(bptOracle.computeTVL(), 1e18, balancerVault.totalSupply(address(bpt)), Math.Rounding.Floor);
        uint256 ltSupply = liquidityTranche.totalSupply();
        uint256 quotedShares = liquidityTranche.previewDeposit(toTrancheUnits(1e18));

        // The deposit price is pool depth plus the idle leg: the quote mints floor(ltSupply x value / (ltRawNAV + idleValue))
        // shares, strictly fewer than pool-depth-only pricing would grant
        assertEq(
            quotedShares,
            Math.mulDiv(ltSupply, depositValue, toUint256(st.ltRawNAV) + idleValue, Math.Rounding.Floor),
            "the quoted shares must be priced on ltRawNAV plus the idle premium leg value"
        );
        assertLt(
            quotedShares,
            Math.mulDiv(ltSupply, depositValue, toUint256(st.ltRawNAV), Math.Rounding.Floor),
            "the idle premium leg must raise the deposit price above pool depth"
        );
    }

    /**
     * @notice Pins the idle-leg-inclusive LT deposit price to hand-computed literals on the fixture's exact numbers,
     *         so the pricing cannot silently share an arithmetic bug with the kernel's own conversion primitives
     * @dev Every expected value below is worked out with plain integer arithmetic from the seed and the +10% senior
     *      gain, none is recomputed through the kernel's or the quoter's own math. A shared rounding or scaling bug
     *      in the conversion chain (premium share mint, idle-leg valuation, deposit price) would shift one of these
     *      literals and fail here even if a formula-mirroring assertion still agreed with itself
     */
    function test_LTDeposit_PriceIncludesIdlePremiumLeg_LiteralAnchor() public {
        uint256 idleShares = _accrueIdlePremiumSeniorShares();

        // Hand derivation (all divisions floor):
        //   Seed: 100e18 senior NAV backing 100e18 senior shares (1:1 first mint), 30e18 junior NAV, and the
        //   6e18 quote-only auto-seeded pool depth. A +10% senior gain is 10e18. The fixture pins the yield
        //   shares at 20% (JT) and 10% (LT), so the risk premium is 2e18 and the liquidity premium is 1e18,
        //   leaving a residual senior gain of 10e18 - 2e18 - 1e18 = 7e18, on which the 10% senior protocol fee
        //   takes 0.7e18. The premium stays a senior claim, so stEffectiveNAV = 100e18 + 7e18 + 1e18 = 108e18.
        //   The 10% LT protocol fee carves 0.1e18 out of the 1e18 premium and is remitted as senior shares to the
        //   protocol, so the LT's idle premium leg is the net 0.9e18 and no LT shares are minted for the fee. The
        //   net premium and the pooled senior fee (0.7e18 ST + 0.1e18 LT) share mints are both priced on the NAV
        //   the pre-existing shares retain, 108e18 - 1e18 - 0.7e18 = 106.3e18, over the pre-sync 100e18 supply:
        //     premium shares = floor(0.9e18 x 100e18 / 106.3e18) = floor(9x10^20 / 1063) = 846660395108184383
        //     fee shares     = floor(0.8e18 x 100e18 / 106.3e18) = floor(8x10^20 / 1063) = 752587017873941674
        //   post-mint senior supply = 100e18 + 846660395108184383 + 752587017873941674 = 101599247412982126057
        assertEq(idleShares, 846_660_395_108_184_383, "the staged premium must be the hand-derived senior share count net of the LT protocol fee");
        assertEq(seniorTranche.totalSupply(), 101_599_247_412_982_126_057, "the senior supply must carry exactly the net premium and pooled fee mints");

        (SyncedAccountingState memory st,,) = kernel.previewSyncTrancheAccounting(TrancheType.LIQUIDITY);
        assertEq(toUint256(st.stEffectiveNAV), 108e18, "the senior effective NAV must be exactly seed plus residual gain plus premium");
        assertEq(toUint256(st.ltRawNAV), 6e18, "the pool depth must be exactly the untouched auto-seed");
        assertEq(liquidityTranche.totalSupply(), 6e18, "the LT supply must be exactly the auto-seed's 1:1 bootstrap mint");
        // Idle leg value = floor(846660395108184383 x 108e18 / 101599247412982126057) = 899999999999999999:
        // the net 0.9e18 premium minus one wei lost across the two floor roundings (share mint, then valuation), so
        // the deposit price is 6e18 + (0.9e18 - 1) and the rounding wei stays with the pool, never the entrant.
        // One BPT values to exactly 1e18 at the pool's 1.0 NAV per BPT, so the tranche's previewDeposit must quote
        // floor(6e18 x 1e18 / 6899999999999999999) = 869565217391304347 shares at that idle-leg-inclusive price
        assertEq(
            liquidityTranche.previewDeposit(toTrancheUnits(1e18)),
            869_565_217_391_304_347,
            "the quoted shares must be priced at pool depth plus the net idle leg, one wei under 6.9e18"
        );
    }

    /**
     * @notice A depositor who tries to buy in while the idle liquidity premium is undeployed pays the idle-leg-inclusive
     *         price: the shares minted are priced on ltRawNAV plus the idle value, strictly fewer than pool-depth-only
     *         pricing would grant, so the entrant cannot dilute existing holders out of their undeployed premium claim
     * @dev Attacker intent: deposit between the premium mint and its reinvestment, when the pool depth understates the
     *      LT's effective NAV, and capture a slice of the idle senior shares for free. Expected shares are derived
     *      independently: floor(ltSupply x depositValue / (ltRawNAV + idleValue))
     */
    function test_LTDeposit_WhileIdlePremiumOutstanding_CannotDiluteExistingHolders() public {
        uint256 idleShares = _accrueIdlePremiumSeniorShares();
        address entrant = makeAddr("DILUTION_ENTRANT");
        accessManager.grantRole(LT_LP_ROLE, entrant, 0);

        // Fund the entrant with 1e18 fresh BPT against a matching quote leg, keeping NAV-per-BPT at exactly 1.0
        // (the mock vault pulls the quote leg from the caller, so it must be minted and approved first)
        uint256 depositBpt = 1e18;
        uint256[2] memory legs;
        legs[1 - stPoolTokenIndex] = quoteUnit;
        quoteToken.mint(address(this), quoteUnit);
        quoteToken.approve(address(balancerVault), quoteUnit);
        balancerVault.mintPoolTokensTo(address(bpt), entrant, depositBpt, legs);

        // Independent expected values from committed state and the mock venue's ledger (never the kernel's own preview):
        //   depositValue  = floor(TVL x depositBpt / bptSupply)         the BPT's NAV at the oracle mark
        //   idleValue     = floor(idleShares x stEff / stSupply)        the idle premium leg at the senior share rate
        //   ownedValue    = floor(TVL x ltOwnedBpt / bptSupply)         the LT's pool depth (ltRawNAV)
        //   fair shares   = floor(ltSupply x depositValue / (ownedValue + idleValue))
        uint256 tvl = bptOracle.computeTVL();
        uint256 bptSupply = balancerVault.totalSupply(address(bpt));
        uint256 depositValue = Math.mulDiv(tvl, depositBpt, bptSupply, Math.Rounding.Floor);
        uint256 idleValue = Math.mulDiv(idleShares, toUint256(accountant.getState().lastSTEffectiveNAV), seniorTranche.totalSupply(), Math.Rounding.Floor);
        uint256 ownedBptBefore = toUint256(kernel.getState().ltOwnedYieldBearingAssets);
        uint256 ownedValue = Math.mulDiv(tvl, ownedBptBefore, bptSupply, Math.Rounding.Floor);
        uint256 ltSupply = liquidityTranche.totalSupply();
        uint256 expectedShares = Math.mulDiv(ltSupply, depositValue, ownedValue + idleValue, Math.Rounding.Floor);

        vm.startPrank(entrant);
        bpt.approve(address(liquidityTranche), depositBpt);
        vm.expectEmit(address(liquidityTranche));
        emit IRoycoVaultTranche.Deposit(entrant, entrant, toTrancheUnits(depositBpt), expectedShares);
        uint256 mintedShares = liquidityTranche.deposit(toTrancheUnits(depositBpt), entrant);
        vm.stopPrank();

        assertEq(mintedShares, expectedShares, "the entrant's shares must be priced on the idle-leg-inclusive effective NAV");
        // The attack payoff check: pool-depth-only pricing would have minted strictly more shares
        uint256 poolDepthOnlyShares = Math.mulDiv(ltSupply, depositValue, ownedValue, Math.Rounding.Floor);
        assertLt(mintedShares, poolDepthOnlyShares, "idle-leg-inclusive pricing must grant strictly fewer shares than pool-depth-only pricing");
        // Full post-state: the idle pile is untouched, the BPT moved into kernel custody, and the entrant holds only shares
        assertEq(kernel.getState().ltOwnedSeniorTrancheShares, idleShares, "the idle liquidity premium senior shares must be untouched by the deposit");
        assertEq(toUint256(kernel.getState().ltOwnedYieldBearingAssets), ownedBptBefore + depositBpt, "the deposited BPT must land in the kernel's LT custody");
        assertEq(bpt.balanceOf(entrant), 0, "the entrant's BPT must be fully consumed");
        assertEq(liquidityTranche.balanceOf(entrant), mintedShares, "the entrant must hold exactly the minted shares");
    }

    /**
     * @notice In FIXED_TERM, the multi-asset LT deposit preview zeroes ALL of value/navToMint/ltAssetsOut for an
     *         ST-leg deposit (which the reverting execution path forbids), while still returning the live LT supply
     * @dev The reverting ST-leg path returns a fully-zero quote so a caller cannot mistake it for a real quote;
     *      the supply leg stays live because it is read before the branch
     */
    function test_LTDepositMultiAsset_PreviewInFixedTerm_ZeroesAllQuoteLegsForSTLeg() public {
        _enterFixedTerm();

        // An ST-leg multi-asset preview in FIXED_TERM returns the fully-zeroed quote
        (NAV_UNIT depositNAV, NAV_UNIT effectiveNAV, TRANCHE_UNIT ltAssetsOut, uint256 ltTotalSupplyAfterMints) =
            kernel.ltPreviewDepositMultiAsset(toTrancheUnits(stUnit), 0);

        assertEq(toUint256(depositNAV), 0, "depositNAV must be zero for a forbidden ST-leg deposit in FIXED_TERM");
        assertEq(toUint256(effectiveNAV), 0, "effectiveNAV must be zero for a forbidden ST-leg deposit in FIXED_TERM");
        assertEq(toUint256(ltAssetsOut), 0, "ltAssetsOut must be zero for a forbidden ST-leg deposit in FIXED_TERM");
        // The LT supply leg is read before the FIXED_TERM branch, so it stays live (no fee shares mint in FIXED_TERM)
        assertEq(ltTotalSupplyAfterMints, liquidityTranche.totalSupply(), "the LT supply leg stays live and equals the live LT supply");
    }

    /**
     * @notice In FIXED_TERM, a quote-only multi-asset LT deposit preview is a real, nonzero quote — it mints no
     *         senior shares and only deepens liquidity, so it is the one multi-asset deposit FIXED_TERM allows
     */
    function test_LTDepositMultiAsset_PreviewInFixedTerm_QuoteOnlyIsNonzero() public {
        _enterFixedTerm();

        // One whole quote adds 1e18 NAV at the fixture's 1.0 NAV-per-BPT, minting exactly 1e18 BPT
        (NAV_UNIT depositNAV, NAV_UNIT effectiveNAV, TRANCHE_UNIT ltAssetsOut,) = kernel.ltPreviewDepositMultiAsset(toTrancheUnits(0), quoteUnit);

        assertEq(toUint256(ltAssetsOut), 1e18, "a quote-only deposit mints exactly 1e18 BPT in FIXED_TERM");
        assertEq(toUint256(depositNAV), 1e18, "a quote-only deposit allocates exactly 1e18 NAV in FIXED_TERM");
        // No premium accrues on a covered loss, so the LT effective NAV equals the pool depth: the 6e18 auto-seed
        assertEq(toUint256(effectiveNAV), 6e18, "the quote-only LT share price equals the 6e18 pool depth (no idle premium leg)");
    }

    // =============================
    // Helpers
    // =============================

    /**
     * @dev Accrues a nonzero idle liquidity premium: arms venue slippage so the +10% senior gain's premium mints as
     *      senior shares to the LT but the gated reinvestment defers, leaving ltOwnedSeniorTrancheShares nonzero.
     *      Slippage stays armed so a later operation's sync cannot deploy the pile mid-test
     */
    function _accrueIdlePremiumSeniorShares() internal returns (uint256 idleShares) {
        setVenueSlippageMode(true);
        applySTPnL(1000);
        _sync();
        idleShares = kernel.getState().ltOwnedSeniorTrancheShares;
        assertTrue(idleShares != 0, "the gain must have left a nonzero idle liquidity premium senior share pile");
    }

    /// @dev A covered -20% senior drawdown: coverage utilization = ceil(104e18 x 0.2 / 4e18) = 5.2e18, which enters FIXED_TERM
    function _enterFixedTerm() internal {
        applySTPnL(-2000);
        SyncedAccountingState memory s = _sync();
        assertEq(uint8(s.marketState), uint8(MarketState.FIXED_TERM), "the covered drawdown must enter FIXED_TERM");
    }
}
