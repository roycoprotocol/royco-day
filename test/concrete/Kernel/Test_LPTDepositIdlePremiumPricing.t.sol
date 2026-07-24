// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { LPT_LP_ROLE } from "../../../src/factory/Roles.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { MarketState, SyncedAccountingState, TrancheType } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_LPTDepositIdlePremiumPricing_Kernel
 * @notice Binds the LPT-deposit pricing paths that depend on the idle liquidity premium senior shares
 *         (lptOwnedSeniorTrancheShares): the idle leg of the LPT deposit share price, exercised with a nonzero idle
 *         pile (every prior LPT deposit test ran at lptOwnedSeniorTrancheShares == 0), and the FIXED_TERM
 *         early-return of the multi-asset preview, whose non-shares legs were never asserted
 */
contract Test_LPTDepositIdlePremiumPricing_Kernel is DayMarketTestBase {
    /// @dev Whole ST/JT vault shares seeded. Coverage after seed: (100 + 30) x 0.2 / 30 = 0.8667 <= 1, gate clears
    uint256 internal constant ST_SEED_WHOLE = 100;
    uint256 internal constant JT_SEED_WHOLE = 30;

    uint256 internal stUnit;
    uint256 internal quoteUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.collateralAsset.decimals);
        quoteUnit = 10 ** uint256(cell.quoteAsset.decimals);
        _seedMarket(ST_SEED_WHOLE * stUnit, JT_SEED_WHOLE * stUnit);
    }

    /**
     * @notice With idle liquidity premium senior shares outstanding, the LPT deposit price is the pool depth PLUS
     *         the idle senior shares valued at the senior share rate, not the pool depth alone
     * @dev Arms venue slippage so a +10% senior gain's premium mints but cannot reinvest, leaving
     *      lptOwnedSeniorTrancheShares nonzero. The tranche's previewDeposit quote must then price the shares at
     *      lptRawNAV + floor(idleShares x (stEff + 1) / (stSupply + 1e6)), the exact effective-NAV pricing. A regression that
     *      priced LPT deposits off pool depth alone would drop the idle term and undercharge depositors
     */
    function test_LPTDeposit_PriceIncludesIdlePremiumLeg() public {
        uint256 idleShares = _accrueIdlePremiumSeniorShares();

        // The committed post-sync state the deposit prices against (the +10% gain is already synced)
        (SyncedAccountingState memory st,,) = kernel.previewSyncTrancheAccounting(TrancheType.LIQUIDITY_PROVIDER);

        // Independently value the idle leg at the senior share rate through the virtual-share/asset offset:
        // convertToValue = floor((stEff + 1) x idleShares / (stSupply + 1e6))
        uint256 idleValue = Math.mulDiv(idleShares, toUint256(st.stEffectiveNAV) + 1, seniorTranche.totalSupply() + 1e6, Math.Rounding.Floor);
        assertTrue(idleValue != 0, "the idle liquidity premium senior shares must carry a nonzero value");

        // Quote an in-kind LPT deposit of one BPT through the tranche preview. The one BPT's NAV at the oracle mark
        // is derived from the mock venue's ledger, never the kernel's own conversion chain
        uint256 depositValue = Math.mulDiv(bptOracle.computeTVL(), 1e18, balancerVault.totalSupply(address(bpt)), Math.Rounding.Floor);
        uint256 lptSupply = liquidityProviderTranche.totalSupply();
        uint256 quotedShares = liquidityProviderTranche.previewDeposit(toTrancheUnits(1e18));

        // The deposit price is pool depth plus the idle leg, priced through the offset: convertToShares mints
        // floor((lptSupply + 1e6) x value / (lptRawNAV + idleValue + 1)) shares, strictly fewer than pool-depth-only pricing would grant
        assertEq(
            quotedShares,
            Math.mulDiv(lptSupply + 1e6, depositValue, toUint256(st.lptRawNAV) + idleValue + 1, Math.Rounding.Floor),
            "the quoted shares must be priced on lptRawNAV plus the idle premium leg value"
        );
        assertLt(
            quotedShares,
            Math.mulDiv(lptSupply, depositValue, toUint256(st.lptRawNAV), Math.Rounding.Floor),
            "the idle premium leg must raise the deposit price above pool depth"
        );
    }

    /**
     * @notice Pins the idle-leg-inclusive LPT deposit price to hand-computed literals on the fixture's exact numbers,
     *         so the pricing cannot silently share an arithmetic bug with the kernel's own conversion primitives
     * @dev Every expected value below is worked out with plain integer arithmetic from the seed and the +10% senior
     *      gain, none is recomputed through the kernel's or the quoter's own math. A shared rounding or scaling bug
     *      in the conversion chain (premium share mint, idle-leg valuation, deposit price) would shift one of these
     *      literals and fail here even if a formula-mirroring assertion still agreed with itself
     */
    function test_LPTDeposit_PriceIncludesIdlePremiumLeg_LiteralAnchor() public {
        uint256 idleShares = _accrueIdlePremiumSeniorShares();

        // Hand derivation (all divisions floor):
        //   Seed: 100e18 senior NAV backing 100e18 senior shares (1:1 first mint), 30e18 junior NAV, and the
        //   6e18 quote-only auto-seeded pool depth. A +10% senior gain is 10e18. The fixture pins the yield
        //   shares at 20% (JT) and 10% (LPT), so the risk premium is 2e18 and the liquidity premium is 1e18,
        //   leaving a residual senior gain of 10e18 - 2e18 - 1e18 = 7e18, on which the 10% senior protocol fee
        //   takes 0.7e18. The premium stays a senior claim, so stEffectiveNAV = 100e18 + 7e18 + 1e18 = 108e18.
        //   The 10% LPT protocol fee carves 0.1e18 out of the 1e18 premium and is remitted as senior shares to the
        //   protocol, so the LPT's idle premium leg is the net 0.9e18 and no LPT shares are minted for the fee. The
        //   net premium and the pooled senior fee (0.7e18 ST + 0.1e18 LPT) share mints are both priced on the NAV
        //   the pre-existing shares retain, 108e18 - 1e18 - 0.7e18 = 106.3e18, over the pre-sync 100e18 supply,
        //   through the virtual-share/asset offset (effective supply 100e18 + 1e6, denominator 106.3e18 + 1):
        //     premium shares = floor((100e18 + 1e6) x 0.9e18 / (106.3e18 + 1)) = 846660395108192850
        //     fee shares     = floor((100e18 + 1e6) x 0.8e18 / (106.3e18 + 1)) = 752587017873949200
        //   post-mint senior supply = 100e18 + 846660395108192850 + 752587017873949200 = 101599247412982142050
        assertEq(idleShares, 846_660_395_108_192_850, "the staged premium must be the hand-derived senior share count net of the LPT protocol fee");
        assertEq(seniorTranche.totalSupply(), 101_599_247_412_982_142_050, "the senior supply must carry exactly the net premium and pooled fee mints");

        (SyncedAccountingState memory st,,) = kernel.previewSyncTrancheAccounting(TrancheType.LIQUIDITY_PROVIDER);
        assertEq(toUint256(st.stEffectiveNAV), 108e18, "the senior effective NAV must be exactly seed plus residual gain plus premium");
        assertEq(toUint256(st.lptRawNAV), 6e18, "the pool depth must be exactly the untouched auto-seed");
        assertEq(liquidityProviderTranche.totalSupply(), 6e18, "the LPT supply must be exactly the auto-seed's 1:1 bootstrap mint");
        // Idle leg value (convertToValue through the offset) =
        // floor((108e18 + 1) x 846660395108192850 / (101599247412982142050 + 1e6)) = 899999999999999999:
        // the net 0.9e18 premium minus one wei lost across the two floor roundings (share mint, then valuation), so
        // the deposit price is 6e18 + (0.9e18 - 1) = 6899999999999999999 and the rounding wei stays with the pool.
        // One BPT values to exactly 1e18 at the pool's 1.0 NAV per BPT, so the tranche's previewDeposit must quote
        // convertToShares = floor((6e18 + 1e6) x 1e18 / (6899999999999999999 + 1)) = 869565217391449275 shares
        assertEq(
            liquidityProviderTranche.previewDeposit(toTrancheUnits(1e18)),
            869_565_217_391_449_275,
            "the quoted shares must be priced at pool depth plus the net idle leg, one wei under 6.9e18"
        );
    }

    /**
     * @notice A depositor who tries to buy in while the idle liquidity premium is undeployed pays the idle-leg-inclusive
     *         price: the shares minted are priced on lptRawNAV plus the idle value, strictly fewer than pool-depth-only
     *         pricing would grant, so the entrant cannot dilute existing holders out of their undeployed premium claim
     * @dev Attacker intent: deposit between the premium mint and its reinvestment, when the pool depth understates the
     *      LPT's effective NAV, and capture a slice of the idle senior shares for free. Expected shares are derived
     *      independently: floor((lptSupply + 1e6) x depositValue / (lptRawNAV + idleValue + 1))
     */
    function test_LPTDeposit_WhileIdlePremiumOutstanding_CannotDiluteExistingHolders() public {
        uint256 idleShares = _accrueIdlePremiumSeniorShares();
        address entrant = makeAddr("DILUTION_ENTRANT");
        accessManager.grantRole(LPT_LP_ROLE, entrant, 0);

        // Fund the entrant with 1e18 fresh BPT against a matching quote leg, keeping NAV-per-BPT at exactly 1.0
        // (the mock vault pulls the quote leg from the caller, so it must be minted and approved first)
        uint256 depositBpt = 1e18;
        uint256[2] memory legs;
        legs[1 - stPoolTokenIndex] = quoteUnit;
        quoteToken.mint(address(this), quoteUnit);
        quoteToken.approve(address(balancerVault), quoteUnit);
        balancerVault.mintPoolTokensTo(address(bpt), entrant, depositBpt, legs);

        // Independent expected values from committed state and the mock venue's ledger (never the kernel's own preview):
        //   depositValue  = floor(TVL x depositBpt / bptSupply)                    the BPT's NAV at the oracle mark
        //   idleValue     = floor((stEff + 1) x idleShares / (stSupply + 1e6))     the idle premium leg (convertToValue, offset)
        //   ownedValue    = floor(TVL x lptOwnedBpt / bptSupply)                    the LPT's pool depth (lptRawNAV)
        //   fair shares   = floor((lptSupply + 1e6) x depositValue / (ownedValue + idleValue + 1))   convertToShares, offset
        uint256 tvl = bptOracle.computeTVL();
        uint256 bptSupply = balancerVault.totalSupply(address(bpt));
        uint256 depositValue = Math.mulDiv(tvl, depositBpt, bptSupply, Math.Rounding.Floor);
        uint256 idleValue =
            Math.mulDiv(idleShares, toUint256(accountant.getState().lastSTEffectiveNAV) + 1, seniorTranche.totalSupply() + 1e6, Math.Rounding.Floor);
        uint256 ownedBptBefore = toUint256(kernel.getState().totalLPTAssets);
        uint256 ownedValue = Math.mulDiv(tvl, ownedBptBefore, bptSupply, Math.Rounding.Floor);
        uint256 lptSupply = liquidityProviderTranche.totalSupply();
        uint256 expectedShares = Math.mulDiv(lptSupply + 1e6, depositValue, ownedValue + idleValue + 1, Math.Rounding.Floor);

        vm.startPrank(entrant);
        bpt.approve(address(liquidityProviderTranche), depositBpt);
        vm.expectEmit(address(liquidityProviderTranche));
        emit IRoycoVaultTranche.Deposit(entrant, entrant, toTrancheUnits(depositBpt), expectedShares);
        uint256 mintedShares = liquidityProviderTranche.deposit(toTrancheUnits(depositBpt), entrant);
        vm.stopPrank();

        assertEq(mintedShares, expectedShares, "the entrant's shares must be priced on the idle-leg-inclusive effective NAV");
        // The attack payoff check: pool-depth-only pricing would have minted strictly more shares
        uint256 poolDepthOnlyShares = Math.mulDiv(lptSupply, depositValue, ownedValue, Math.Rounding.Floor);
        assertLt(mintedShares, poolDepthOnlyShares, "idle-leg-inclusive pricing must grant strictly fewer shares than pool-depth-only pricing");
        // Full post-state: the idle pile is untouched, the BPT moved into kernel custody, and the entrant holds only shares
        assertEq(kernel.getState().lptOwnedSeniorTrancheShares, idleShares, "the idle liquidity premium senior shares must be untouched by the deposit");
        assertEq(toUint256(kernel.getState().totalLPTAssets), ownedBptBefore + depositBpt, "the deposited BPT must land in the kernel's LPT custody");
        assertEq(bpt.balanceOf(entrant), 0, "the entrant's BPT must be fully consumed");
        assertEq(liquidityProviderTranche.balanceOf(entrant), mintedShares, "the entrant must hold exactly the minted shares");
    }

    /**
     * @notice With idle liquidity premium senior shares outstanding, the multi-asset deposit preview matches its
     *         same-block execution exactly, for a two-leg (ST + quote) and a quote-only deposit
     * @dev Every other multi-asset deposit parity test runs at lptOwnedSeniorTrancheShares == 0, but the pile
     *      enters the pricing denominator (the LPT effective NAV) and the pre-op sync's reinvestment attempt runs
     *      inside the preview frame, so a frame-vs-exec divergence in pile handling would misprice quotes only in
     *      this state. Slippage stays armed so the pile survives both frames, its exec-side survival is asserted
     */
    function test_LPTDepositMultiAsset_PreviewParityWithIdlePremiumPile() public {
        uint256 idleShares = _accrueIdlePremiumSeniorShares();
        address entrant = makeAddr("MULTI_ASSET_PILE_ENTRANT");
        accessManager.grantRole(LPT_LP_ROLE, entrant, 0);

        // Two-leg deposit: one whole ST asset plus one whole quote, previewed immediately before execution
        stJtVault.mintShares(entrant, stUnit);
        quoteToken.mint(entrant, quoteUnit);
        vm.startPrank(entrant);
        stJtVault.approve(address(liquidityProviderTranche), stUnit);
        quoteToken.approve(address(liquidityProviderTranche), quoteUnit);
        (uint256 previewedTwoLeg,) = liquidityProviderTranche.previewDepositMultiAsset(stUnit, quoteUnit);
        (uint256 mintedTwoLeg,) = liquidityProviderTranche.depositMultiAsset(stUnit, quoteUnit, 0, entrant);
        vm.stopPrank();
        assertEq(mintedTwoLeg, previewedTwoLeg, "the two-leg multi-asset deposit must mint exactly the shares previewed over the idle pile");
        assertEq(kernel.getState().lptOwnedSeniorTrancheShares, idleShares, "the idle pile must survive the two-leg deposit with slippage armed");

        // Quote-only deposit against the same staged pile
        quoteToken.mint(entrant, quoteUnit);
        vm.startPrank(entrant);
        quoteToken.approve(address(liquidityProviderTranche), quoteUnit);
        (uint256 previewedQuoteOnly,) = liquidityProviderTranche.previewDepositMultiAsset(0, quoteUnit);
        (uint256 mintedQuoteOnly,) = liquidityProviderTranche.depositMultiAsset(0, quoteUnit, 0, entrant);
        vm.stopPrank();
        assertEq(mintedQuoteOnly, previewedQuoteOnly, "the quote-only multi-asset deposit must mint exactly the shares previewed over the idle pile");
        assertEq(kernel.getState().lptOwnedSeniorTrancheShares, idleShares, "the idle pile must survive the quote-only deposit with slippage armed");
    }

    /**
     * @notice In FIXED_TERM, the multi-asset LPT deposit preview for an ST-leg deposit reverts exactly like the
     *         forbidden execution path
     * @dev The preview routes through the actual kernel deposit flow, so the fixed-term ST-leg gate bubbles
     *      unchanged instead of returning a zeroed quote a caller could mistake for a real one
     */
    function test_RevertIf_LPTDepositMultiAsset_PreviewInFixedTermWithSTLeg() public {
        _enterFixedTerm();

        // An ST-leg multi-asset preview in FIXED_TERM bubbles the execution path's exact gate
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        liquidityProviderTranche.previewDepositMultiAsset(stUnit, 0);
    }

    /**
     * @notice In FIXED_TERM, a quote-only multi-asset LPT deposit preview is a real, nonzero quote, it mints no
     *         senior shares and only deepens liquidity, so it is the one multi-asset deposit FIXED_TERM allows
     */
    function test_LPTDepositMultiAsset_PreviewInFixedTerm_QuoteOnlyIsNonzero() public {
        _enterFixedTerm();

        // One whole quote adds 1e18 NAV at the fixture's 1.0 NAV-per-BPT, minting exactly 1e18 BPT priced at the
        // 6e18 pool depth (no premium accrues on a covered loss, so there is no idle premium leg): the quoted
        // shares are convertToShares(1e18, 6e18, lptSupply) = floor((lptSupply + 1e6) x 1e18 / (6e18 + 1)), exactly the execution path's mint
        (uint256 shares,) = liquidityProviderTranche.previewDepositMultiAsset(0, quoteUnit);
        assertEq(shares, Math.mulDiv(liquidityProviderTranche.totalSupply() + 1e6, 1e18, 6e18 + 1), "the quote-only preview must price at the 6e18 pool depth");
    }

    // =============================
    // Helpers
    // =============================

    /**
     * @dev Accrues a nonzero idle liquidity premium: arms venue slippage so the +10% senior gain's premium mints as
     *      senior shares to the LPT but the gated reinvestment defers, leaving lptOwnedSeniorTrancheShares nonzero.
     *      Slippage stays armed so a later operation's sync cannot deploy the pile mid-test
     */
    function _accrueIdlePremiumSeniorShares() internal returns (uint256 idleShares) {
        setVenueSlippageMode(true);
        applySTPnL(1000);
        _sync();
        idleShares = kernel.getState().lptOwnedSeniorTrancheShares;
        assertTrue(idleShares != 0, "the gain must have left a nonzero idle liquidity premium senior share pile");
    }

    /// @dev A covered -20% senior drawdown: coverage utilization = ceil(104e18 x 0.2 / 4e18) = 5.2e18, which enters FIXED_TERM
    function _enterFixedTerm() internal {
        applySTPnL(-2000);
        SyncedAccountingState memory s = _sync();
        assertEq(uint8(s.marketState), uint8(MarketState.FIXED_TERM), "the covered drawdown must enter FIXED_TERM");
    }
}
