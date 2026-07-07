// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";

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
     *      ltOwnedSeniorTrancheShares nonzero. The preview's navToMintSharesAt must then equal
     *      ltRawNAV + floor(idleShares x stEff / stSupply), the exact effective-NAV pricing. A regression that
     *      priced LT deposits off pool depth alone would drop the idle term and undercharge depositors
     */
    function test_LTDeposit_PriceIncludesIdlePremiumLeg() public {
        uint256 idleShares = _accrueIdlePremiumSeniorShares();

        // Preview an in-kind LT deposit of one BPT: navToMintSharesAt is the pre-deposit LT effective NAV
        (SyncedAccountingState memory st,,, NAV_UNIT navToMintSharesAt) = kernel.ltPreviewDeposit(toTrancheUnits(1e18));

        // Independently value the idle leg at the senior share rate: floor(idleShares x stEff / stSupply)
        uint256 idleValue = Math.mulDiv(idleShares, toUint256(st.stEffectiveNAV), seniorTranche.totalSupply(), Math.Rounding.Floor);
        assertTrue(idleValue != 0, "the idle liquidity premium senior shares must carry a nonzero value");

        // The deposit price is pool depth plus the idle leg, so it strictly exceeds pool depth alone
        assertEq(toUint256(navToMintSharesAt), toUint256(st.ltRawNAV) + idleValue, "LT deposit price must be ltRawNAV plus the idle premium leg value");
        assertGt(toUint256(navToMintSharesAt), toUint256(st.ltRawNAV), "the idle premium leg must raise the deposit price above pool depth");
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
    function test_LTDepositMultiAsset_PreviewInFixedTerm_QuoteOnlyIsNonzero() public {
        _enterFixedTerm();

        // One whole quote adds 1e18 NAV at the fixture's 1.0 NAV-per-BPT, minting exactly 1e18 BPT
        (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt, TRANCHE_UNIT ltAssetsOut,) = kernel.ltPreviewDepositMultiAsset(toTrancheUnits(0), quoteUnit);

        assertEq(toUint256(ltAssetsOut), 1e18, "a quote-only deposit mints exactly 1e18 BPT in FIXED_TERM");
        assertEq(toUint256(valueAllocated), 1e18, "a quote-only deposit allocates exactly 1e18 NAV in FIXED_TERM");
        // No premium accrues on a covered loss, so the LT effective NAV equals the pool depth: the 6e18 auto-seed
        assertEq(toUint256(navToMintSharesAt), 6e18, "the quote-only LT share price equals the 6e18 pool depth (no idle premium leg)");
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
