// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRateProvider } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { IVaultErrors } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultErrors.sol";
import {
    RemoveLiquidityKind,
    RemoveLiquidityParams,
    SwapKind,
    VaultSwapParams
} from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { LPT_LP_ROLE, ST_LP_ROLE } from "../../../src/factory/Roles.sol";
import { BalancerV3LiquidityVenue } from "../../../src/kernels/base/liquidity-venue/balancer-v3/BalancerV3LiquidityVenue.sol";
import { WAD } from "../../../src/libraries/Constants.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoLiquidityProviderTranche } from "../../../src/tranches/RoycoLiquidityProviderTranche.sol";
import { MockBalancerVault } from "../../mocks/MockBalancerVault.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_ExogenousPoolInteractions_LiquidityVenue
 * @notice Spec-first pins for every composition an exogenous pool actor can force against the Royco flows:
 *         exact-in swaps in both directions at the mock's pinned rates, stale-preview floors after adverse
 *         drift, gated ops judged at the post-drift mark, donation and swap inertness against the
 *         ledger-priced redemption claim, and the vault-session mutual exclusion between external actors
 *         and Royco venue operations
 * @dev SPEC DECISIONS pinned here: (1) preview/exec parity is a same-block same-state claim, an exogenous
 *      op between a preview and its execution legitimately changes the answer, and safety means the stale
 *      preview's floors reject (AmountOutBelowMin / BptAmountOutBelowMin) instead of settling mispriced.
 *      (2) At the mock's pinned prices every exogenous flow weakly RAISES the ledger-priced mark (swap
 *      flooring and fees stay in the pool, donations add value, removals strand floor dust), so the
 *      mark-lowering composition attack requires curve math and is fork-suite territory by construction.
 *      (3) getRate is reachable mid-session (the venue's whenVaultLocked does not guard it) and prices off
 *      committed state, exactly how the production E-CLP reads its rate provider inside a swap.
 *      (4) An external LP cannot interleave a removal into a Royco flow: mid-Royco-flow the only executing
 *      code is the kernel's own onlyVault callback (the mock has no hook layer, matching the guard shape),
 *      and the inverse direction is enforced by whenVaultLocked, every Royco venue op refuses to run inside
 *      a session it did not open
 * @dev Fixture derivations (python, exact integers): quote 6 decimals so 1 quote wei = 1e12 NAV wei at the
 *      1.0 quote price. After setUp: stSupply == stEffectiveNAV == 101_000e18 + 1 (senior rate exactly
 *      WAD), jtEffectiveNAV == 60_000e18, pool = [1_000e18 senior, 9_001_000_001 quote wei], BPT supply
 *      == 10_001_000_001e12, kernel LPT ledger == LPT supply == 10_001e18, TVL == BPT supply so NAV per
 *      BPT is exactly 1.0 and the committed mark is exactly 10_001e18
 */
contract Test_ExogenousPoolInteractions_LiquidityVenue is DayMarketTestBase {
    /// @dev The committed two-step mark of the seeded fixture, NAV per BPT exactly 1.0 over the 10_001e18 ledger
    uint256 internal constant SEEDED_MARK = 10_001e18;

    /// @dev The seeded BPT total supply: three 1:1 seeds plus the 1e12 genesis backing the 1e6 dead shares
    uint256 internal constant SEEDED_BPT_SUPPLY = 10_001_000_001e12;

    address internal exogenousActor;

    function setUp() public virtual {
        _deployMarket(cellA(), defaultParams());
        // 60k junior makes the senior deposit maximum LIQUIDITY-bound (liquidity cap on collateral
        // mark/5% + jt = 2.6002e23 sits under the coverage cap jt/20% = 3e23), so a mark moved by an
        // exogenous swap provably moves the advertised senior capacity in the gate test below
        _seedMarket(100_000e18, 60_000e18);
        // Quote-only depth so the multi-legged seed's ST acquisition needs no auto-seed, keeping every leg derivable
        _seedLPT(2_000e6 * 1e12, 0, 2_000e6);
        // A real senior leg in the pool (acquired through the production ST deposit path) so swaps run both ways
        _seedLPT(3_000e18, 1_000e18, 2_000e6);

        exogenousActor = makeAddr("EXOGENOUS_ACTOR");
        // ST_LP_ROLE only sources senior shares through the real deposit path, LPT_LP_ROLE drives the
        // stale-preview deposit probes, the pool interactions themselves are permissionless
        accessManager.grantRole(ST_LP_ROLE, exogenousActor, 0);
        accessManager.grantRole(LPT_LP_ROLE, exogenousActor, 0);

        // Documenting assertions: the derived fixture state the pinned expectations below are computed from
        assertEq(seniorTranche.totalSupply(), 101_000e18 + 1, "fixture: senior supply");
        assertEq(toUint256(seniorTranche.totalAssets().nav), 101_000e18 + 1, "fixture: senior effective NAV (rate exactly 1.0)");
        assertEq(bpt.totalSupply(), SEEDED_BPT_SUPPLY, "fixture: BPT supply");
        assertEq(toUint256(kernel.getState().totalLPTAssets), SEEDED_MARK, "fixture: kernel LPT ledger");
        assertEq(seniorTranche.balanceOf(address(balancerVault)), 1_000e18, "fixture: pool senior leg");
        assertEq(quoteToken.balanceOf(address(balancerVault)), 9_001_000_001, "fixture: pool quote leg");
        assertEq(_liveLPTRawNAV(), SEEDED_MARK, "fixture: two-step mark at NAV-per-BPT exactly 1.0");
    }

    // =============================
    // Swap primitive pins
    // =============================

    /**
     * @notice A fee-less exact-in swap quote -> senior at the pinned rates is pure composition drift: the
     *         swapper pays 500e6 quote (5e20 NAV) and receives exactly 500e18 senior shares (rate exactly
     *         WAD), pool TVL and the committed two-step mark are unchanged to the wei, and the kernel's
     *         ledgers and custody are inert
     * @dev Derivation: valueIn = 500e6 x 1e18 / 1e6 = 5e20, out = floor(5e20 x 1e18 / 1e18) = 5e20 = 500e18.
     *      TVL' = (9_001_000_001 + 500_000_000)e12 + 500e18 = 10_001_000_001e12 = TVL, so unit price stays
     *      exactly 1e18 and the mark stays 10_001e18: an exogenous swap changes the POOL COMPOSITION, never
     *      the ledger-priced claim, at the constant-price model
     */
    function test_ExternalSwapQuoteToSenior_FeelessSwapIsPureCompositionDrift() public {
        uint256 amountIn = 500e6;
        quoteToken.mint(exogenousActor, amountIn);
        uint256 kernelLpt0 = toUint256(kernel.getState().totalLPTAssets);
        uint256 kernelCollateral0 = toUint256(kernel.getState().totalCollateralAssets);

        vm.startPrank(exogenousActor);
        quoteToken.approve(address(balancerRouter), amountIn);
        uint256 amountOut = balancerRouter.swapSingleTokenExactIn(address(bpt), IERC20(address(quoteToken)), IERC20(address(seniorTranche)), amountIn, 500e18);
        vm.stopPrank();

        assertEq(amountOut, 500e18, "the swap must pay exactly the fair-value senior shares at the WAD rate");
        assertEq(seniorTranche.balanceOf(exogenousActor), 500e18, "the senior output must land with the swapper in full");
        assertEq(quoteToken.balanceOf(exogenousActor), 0, "the exact input must leave the swapper");
        assertEq(seniorTranche.balanceOf(address(balancerVault)), 500e18, "pool senior leg must shrink by exactly the output");
        assertEq(quoteToken.balanceOf(address(balancerVault)), 9_501_000_001, "pool quote leg must grow by exactly the input");
        assertFalse(balancerVault.isUnlocked(), "the router must close the session before returning");
        assertEq(bptOracle.computeTVL(), SEEDED_BPT_SUPPLY, "a fee-less fair-value swap conserves pool TVL to the wei");
        assertEq(toUint256(kernel.getState().totalLPTAssets), kernelLpt0, "the kernel's LPT ledger must be inert");
        assertEq(toUint256(kernel.getState().totalCollateralAssets), kernelCollateral0, "the kernel's collateral ledger must be inert");

        _sync();
        assertEq(toUint256(accountant.getState().lastLPTRawNAV), SEEDED_MARK, "the committed two-step mark must be unmoved by pure composition drift");
    }

    /**
     * @notice A 100 bps swap fee is retained by the pool: the swapper receives 495e18 senior for 500e6
     *         quote, the pool gains exactly 5e18 of TVL, and the committed mark rises to exactly
     *         10_005_999_999_999_500_049_510e0 NAV wei, the fee accruing pro-rata to every BPT holder
     * @dev Derivation: gross = 500e18, out = 500e18 x 9900 / 10000 = 495e18. TVL' = 10_001_000_001e12 + 5e18.
     *      unit' = floor(1e18 x TVL' / 10_001_000_001e12) = 1_000_499_950_004_949_510, and the mark
     *      floor(10_001e18 x unit' / 1e18) = 10_005_999_999_999_500_049_510
     */
    function test_ExternalSwapWithFee_PoolRetainsFeeAndMarkRisesExactly() public {
        balancerVault.setSwapFeeBps(100);
        uint256 amountIn = 500e6;
        quoteToken.mint(exogenousActor, amountIn);

        vm.startPrank(exogenousActor);
        quoteToken.approve(address(balancerRouter), amountIn);
        uint256 amountOut = balancerRouter.swapSingleTokenExactIn(address(bpt), IERC20(address(quoteToken)), IERC20(address(seniorTranche)), amountIn, 495e18);
        vm.stopPrank();

        assertEq(amountOut, 495e18, "the fee must be charged on the output leg exactly");
        assertEq(bptOracle.computeTVL(), SEEDED_BPT_SUPPLY + 5e18, "the pool must retain exactly the fee's value");

        _sync();
        assertEq(
            toUint256(accountant.getState().lastLPTRawNAV),
            10_005_999_999_999_500_049_510,
            "the committed mark must capture the ledger's floor-quantized share of the retained fee"
        );
    }

    /**
     * @notice The vault's SwapLimit floor rejects an output one wei short of the minimum, exact boundary
     *         from both sides: minAmountOut = out + 1 reverts SwapLimit(out, out + 1), minAmountOut = out settles
     */
    function test_ExternalSwap_MinAmountOutBoundary_BothSides() public {
        uint256 amountIn = 500e6;
        quoteToken.mint(exogenousActor, amountIn);
        vm.startPrank(exogenousActor);
        quoteToken.approve(address(balancerRouter), amountIn);
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SwapLimit.selector, 500e18, 500e18 + 1));
        balancerRouter.swapSingleTokenExactIn(address(bpt), IERC20(address(quoteToken)), IERC20(address(seniorTranche)), amountIn, 500e18 + 1);
        uint256 amountOut = balancerRouter.swapSingleTokenExactIn(address(bpt), IERC20(address(quoteToken)), IERC20(address(seniorTranche)), amountIn, 500e18);
        vm.stopPrank();
        assertEq(amountOut, 500e18, "the swap must settle at exactly the advertised floor");
    }

    // =============================
    // Stale previews against drift (spec decision 1)
    // =============================

    /**
     * @notice A multi-asset redemption preview's quote leg becomes stale when an exogenous senior -> quote
     *         swap drains the pool's quote side: executing at the stale floor reverts AmountOutBelowMin
     *         (never settles mispriced), and re-previewing against the drifted state executes exactly
     * @dev Derivation: preview of 1_000e18 shares at the fixture pays qOut0 = 900_009_999 quote wei
     *      (userLt = 10_001e18 x 1_000e18 / (10_001e18 + 1) = 999_999_999_999_999_999_999 BPT, quote slice
     *      floor(9_001_000_001 x userLt / 10_001_000_001e12)). The actor's 200e18-share swap removes
     *      200e6 quote, so the fresh slice is 880_011_998 < the stale floor. Parity is a same-block
     *      same-state claim, the drift legitimately changed the answer, safety is the revert
     */
    function test_StaleRedeemMultiAssetQuoteFloor_RevertsAfterAdverseSwap_FreshPreviewExecutes() public {
        uint256 shares = 1_000e18;
        (, uint256 staleQuoteOut) = liquidityProviderTranche.previewRedeemMultiAsset(shares);
        assertEq(staleQuoteOut, 900_009_999, "the fixture preview's quote leg must match the derivation");

        // Adverse drift: the actor sources 200e18 senior through the real deposit path and swaps it for quote
        _actorDepositsSenior(200e18);
        vm.startPrank(exogenousActor);
        seniorTranche.approve(address(balancerRouter), 200e18);
        balancerRouter.swapSingleTokenExactIn(address(bpt), IERC20(address(seniorTranche)), IERC20(address(quoteToken)), 200e18, 200e6);
        vm.stopPrank();

        // Executing at the stale floor must reject: the drifted pool can no longer pay it
        vm.prank(LPT_PROVIDER);
        vm.expectRevert(
            abi.encodeWithSelector(IVaultErrors.AmountOutBelowMin.selector, IERC20(address(quoteToken)), 880_011_998, staleQuoteOut)
        );
        liquidityProviderTranche.redeemMultiAsset(shares, 0, staleQuoteOut, LPT_PROVIDER, LPT_PROVIDER);

        // The fresh preview against the drifted state executes exactly, parity holds per block
        (AssetClaims memory freshClaims, uint256 freshQuoteOut) = liquidityProviderTranche.previewRedeemMultiAsset(shares);
        assertEq(freshQuoteOut, 880_011_998, "the fresh preview must price the drifted composition");
        uint256 vaultShares0 = stJtVault.balanceOf(LPT_PROVIDER);
        uint256 quote0 = quoteToken.balanceOf(LPT_PROVIDER);
        vm.prank(LPT_PROVIDER);
        liquidityProviderTranche.redeemMultiAsset(shares, 0, freshQuoteOut, LPT_PROVIDER, LPT_PROVIDER);
        assertEq(quoteToken.balanceOf(LPT_PROVIDER) - quote0, freshQuoteOut, "execution must pay exactly the fresh preview's quote leg");
        assertEq(
            stJtVault.balanceOf(LPT_PROVIDER) - vaultShares0,
            toUint256(freshClaims.collateralAssets),
            "execution must pay exactly the fresh preview's collateral leg"
        );
    }

    /**
     * @notice A multi-asset deposit preview's BPT out becomes stale when a donation raises NAV per BPT:
     *         executing at the stale minimum reverts BptAmountOutBelowMin, the fresh preview executes exactly
     * @dev Derivation: a 1_000e6 quote-only add at NAV-per-BPT 1.0 mints exactly 1_000e18 BPT. A 500e6
     *      donation lifts TVL to 10_001_500_001e12 at unchanged supply, so the same legs mint only
     *      floor(1e21 x 10_001_000_001e12 / 10_001_500_001e12) = 952_385_487_101_001_286_820 BPT
     */
    function test_StaleDepositMultiAssetMinLptOut_RevertsAfterDonation_FreshPreviewExecutes() public {
        (, uint256 staleLptOut) = liquidityProviderTranche.previewDepositMultiAsset(0, 1_000e6);
        assertEq(staleLptOut, 1_000e18, "the fixture preview must mint 1:1 at NAV-per-BPT exactly 1.0");

        // The donation: composition drift raising NAV per BPT, so the same legs now mint fewer BPT
        quoteToken.mint(exogenousActor, 500e6);
        vm.startPrank(exogenousActor);
        quoteToken.approve(address(balancerVault), 500e6);
        balancerVault.injectPoolBalance(address(bpt), IERC20(address(quoteToken)), 500e6);
        vm.stopPrank();

        quoteToken.mint(exogenousActor, 1_000e6);
        vm.startPrank(exogenousActor);
        quoteToken.approve(address(liquidityProviderTranche), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.BptAmountOutBelowMin.selector, 952_385_487_101_001_286_820, staleLptOut));
        liquidityProviderTranche.depositMultiAsset(0, 1_000e6, staleLptOut, exogenousActor);

        (uint256 freshShares, uint256 freshLptOut) = liquidityProviderTranche.previewDepositMultiAsset(0, 1_000e6);
        assertEq(freshLptOut, 952_385_487_101_001_286_820, "the fresh preview must price the donated depth");
        (uint256 mintedShares, uint256 mintedLptOut) = liquidityProviderTranche.depositMultiAsset(0, 1_000e6, freshLptOut, exogenousActor);
        vm.stopPrank();
        assertEq(mintedLptOut, freshLptOut, "execution must mint exactly the fresh preview's BPT");
        assertEq(mintedShares, freshShares, "execution must mint exactly the fresh preview's shares");
    }

    // =============================
    // Gated ops judge the moved mark (spec decision 2)
    // =============================

    /**
     * @notice The gates judge the post-drift mark: a fee-bearing exogenous swap raises the pool's TVL, the
     *         advertised senior deposit maximum recomputed after the swap strictly exceeds the pre-swap
     *         figure (the fixture is liquidity-bound by construction), depositing exactly the recomputed
     *         maximum executes, and the enforced floor still holds at the moved mark
     * @dev At the constant-price mock every exogenous flow weakly raises the mark, so the moved-mark
     *      direction reachable here is the relaxing one, the advertised maxima only grow. The tightening
     *      direction (a swap crushing the mark below a stale maximum) requires curve-implied price impact
     *      and belongs to the fork suites by construction
     */
    function test_GatedOps_JudgeThePostSwapMark_RecomputedMaximaExecute() public {
        balancerVault.setSwapFeeBps(1_000);
        // The actor's senior shares come first so the deposit's own state change is out of the measurement
        _actorDepositsSenior(2_000e18);
        uint256 maxStBefore = toUint256(seniorTranche.maxDeposit(ST_PROVIDER));
        uint256 markBefore = _liveLPTRawNAV();

        // The 10% fee on the 2_000e18-share swap strands 2e20 NAV of value in the pool, lifting the mark
        vm.startPrank(exogenousActor);
        seniorTranche.approve(address(balancerRouter), 2_000e18);
        balancerRouter.swapSingleTokenExactIn(address(bpt), IERC20(address(seniorTranche)), IERC20(address(quoteToken)), 2_000e18, 0);
        vm.stopPrank();

        uint256 markAfter = _liveLPTRawNAV();
        assertGt(markAfter, markBefore, "the fee-bearing swap must raise the ledger-priced mark");

        uint256 maxStAfter = toUint256(seniorTranche.maxDeposit(ST_PROVIDER));
        assertGt(maxStAfter, maxStBefore, "the liquidity-bound senior capacity must be recomputed off the moved mark");

        // The recomputed maximum executes, and the enforced floor holds at the moved mark
        stJtVault.mintShares(ST_PROVIDER, maxStAfter);
        vm.startPrank(ST_PROVIDER);
        stJtVault.approve(address(seniorTranche), maxStAfter);
        seniorTranche.deposit(toTrancheUnits(maxStAfter), ST_PROVIDER);
        vm.stopPrank();
        assertLe(
            RoycoTestMath.computeLiquidityUtilization(
                toUint256(seniorTranche.totalAssets().nav), accountant.getState().minLiquidityWAD, _liveLPTRawNAV()
            ),
            WAD,
            "the advertised maximum executed at the moved mark must leave the liquidity floor intact"
        );
    }

    /**
     * @notice The redemption side of the moved mark: the fee-bearing swap lifts the mark while the senior
     *         floor requirement is unmoved, so the advertised in-kind redemption maximum recomputed after
     *         the swap strictly exceeds the pre-swap figure, and redeeming exactly it executes with the
     *         liquidity floor intact
     */
    function test_GatedOps_JudgeThePostSwapMark_RecomputedRedeemMaximumExecutes() public {
        balancerVault.setSwapFeeBps(1_000);
        _actorDepositsSenior(2_000e18);
        uint256 maxRedeemBefore = liquidityProviderTranche.maxRedeem(LPT_PROVIDER);

        vm.startPrank(exogenousActor);
        seniorTranche.approve(address(balancerRouter), 2_000e18);
        balancerRouter.swapSingleTokenExactIn(address(bpt), IERC20(address(seniorTranche)), IERC20(address(quoteToken)), 2_000e18, 0);
        vm.stopPrank();

        uint256 maxRedeemAfter = liquidityProviderTranche.maxRedeem(LPT_PROVIDER);
        assertGt(maxRedeemAfter, maxRedeemBefore, "the redeemable maximum must be recomputed off the fee-lifted mark");

        vm.prank(LPT_PROVIDER);
        liquidityProviderTranche.redeem(maxRedeemAfter, LPT_PROVIDER, LPT_PROVIDER);
        assertLe(
            RoycoTestMath.computeLiquidityUtilization(
                toUint256(seniorTranche.totalAssets().nav), accountant.getState().minLiquidityWAD, _liveLPTRawNAV()
            ),
            WAD,
            "the advertised maximum redemption at the moved mark must leave the liquidity floor intact"
        );
    }

    // =============================
    // Drift inertness against the ledger-priced claim (spec decision 2)
    // =============================

    /**
     * @notice Donation-then-redeem: a 777e6 quote donation moves the committed mark to exactly
     *         10_777_999_999_922_307_763_861 NAV wei with the kernel's ledger untouched, and a 1_000e18-share
     *         in-kind redemption then pays exactly 999_999_999_999_999_999_999 BPT, whose value at the
     *         drifted unit price never exceeds the redeemer's pro-rata slice of the drifted mark
     * @dev Derivation: TVL' = 10_778_000_001e12, unit' = floor(1e18 x TVL' / 10_001_000_001e12) =
     *      1_077_692_230_769_153_861, mark' = floor(10_001e18 x unit' / 1e18). The claim converts the mark
     *      back at unit' (10_001e18 exactly, the quantization round-trips) and scales by
     *      1_000e18 / (10_001e18 + 1). Value bound: floor(userLt x unit' / 1e18) = 1_077_692_230_769_153_860_998
     *      <= floor(mark' x shares / (supply + 1)) = 1_077_692_230_769_153_860_999, the donation accrues to
     *      the redeemer only through the price, never past its ledger share
     */
    function test_DonationThenRedeem_PaysExactlyTheLedgerShareOfTheDriftedMark() public {
        quoteToken.mint(exogenousActor, 777e6);
        uint256 kernelLpt0 = toUint256(kernel.getState().totalLPTAssets);
        vm.startPrank(exogenousActor);
        quoteToken.approve(address(balancerVault), 777e6);
        balancerVault.injectPoolBalance(address(bpt), IERC20(address(quoteToken)), 777e6);
        vm.stopPrank();
        assertEq(toUint256(kernel.getState().totalLPTAssets), kernelLpt0, "a donation must never touch the kernel's ledger");

        _sync();
        uint256 markAfter = toUint256(accountant.getState().lastLPTRawNAV);
        assertEq(markAfter, 10_777_999_999_922_307_763_861, "the committed mark must capture the ledger's quantized share of the donation");

        uint256 shares = 1_000e18;
        uint256 supply = liquidityProviderTranche.totalSupply();
        uint256 bpt0 = bpt.balanceOf(LPT_PROVIDER);
        vm.prank(LPT_PROVIDER);
        liquidityProviderTranche.redeem(shares, LPT_PROVIDER, LPT_PROVIDER);
        uint256 bptPaid = bpt.balanceOf(LPT_PROVIDER) - bpt0;
        assertEq(bptPaid, 999_999_999_999_999_999_999, "the in-kind redemption must pay exactly the derived BPT slice");

        // The conservation bound: the BPT paid, valued at the drifted unit price, never exceeds the
        // redeemer's pro-rata slice of the drifted ledger mark
        uint256 unitPrice = 1_077_692_230_769_153_861;
        assertEq((bptPaid * unitPrice) / 1e18, 1_077_692_230_769_153_860_998, "paid value at the drifted unit price");
        assertLe((bptPaid * unitPrice) / 1e18, (markAfter * shares) / (supply + 1), "the redeemer must never receive more than its ledger share");
    }

    /**
     * @notice Swap-then-redeem: a fee-less exogenous swap is invisible to the in-kind redemption claim (the
     *         mark is unchanged, so the BPT slice is bit-identical), while the multi-asset redemption's LEG
     *         SPLIT tracks the drifted composition with the total claim NAV preserved up to one quote wei
     *         of flooring
     * @dev Derivation: for 1_000e18 shares the BPT slice is 999_999_999_999_999_999_999 before and after the
     *      500e6 quote -> senior swap (mark unmoved at 10_001e18). The multi-asset legs move from
     *      [99_990_000_989_902_009_699 senior-share-equivalent collateral, 900_009_999 quote] to
     *      [49_995_000_494_951_004_849, 950_004_999]: NAV totals 999_999_999_989_902_009_699 vs
     *      999_999_999_494_951_004_849, a 494_951_004_850 NAV-wei difference bounded by the 1e12 NAV
     *      granularity of one quote wei, value the flooring strands in the pool, never pays out
     */
    function test_SwapThenRedeem_InKindClaimUnchanged_MultiAssetSplitTracksComposition() public {
        uint256 shares = 1_000e18;
        (AssetClaims memory claimsBefore, uint256 quoteBefore) = liquidityProviderTranche.previewRedeemMultiAsset(shares);
        AssetClaims memory inKindBefore = liquidityProviderTranche.previewRedeem(shares);
        assertEq(quoteBefore, 900_009_999, "pre-swap multi-asset quote leg");
        assertEq(toUint256(inKindBefore.lptAssets), 999_999_999_999_999_999_999, "pre-swap in-kind BPT slice");

        // The fee-less swap: pure composition drift, TVL and the mark provably unmoved (see the swap pin above)
        quoteToken.mint(exogenousActor, 500e6);
        vm.startPrank(exogenousActor);
        quoteToken.approve(address(balancerRouter), 500e6);
        balancerRouter.swapSingleTokenExactIn(address(bpt), IERC20(address(quoteToken)), IERC20(address(seniorTranche)), 500e6, 500e18);
        vm.stopPrank();

        AssetClaims memory inKindAfter = liquidityProviderTranche.previewRedeem(shares);
        assertEq(toUint256(inKindAfter.lptAssets), toUint256(inKindBefore.lptAssets), "the in-kind BPT claim must be immune to pure composition drift");

        (AssetClaims memory claimsAfter, uint256 quoteAfter) = liquidityProviderTranche.previewRedeemMultiAsset(shares);
        assertEq(quoteAfter, 950_004_999, "the multi-asset quote leg must track the drifted composition");
        // stClaims.nav covers the ST-leg claims only, the quote leg is reported beside it, so the total
        // claim NAV adds the quote at its exact 1.0 fixture price (1 quote wei = 1e12 NAV wei)
        uint256 navBefore = toUint256(claimsBefore.nav) + quoteBefore * 1e12;
        uint256 navAfter = toUint256(claimsAfter.nav) + quoteAfter * 1e12;
        assertLe(navAfter, navBefore, "flooring strands value in the pool, the drifted split can only pay weakly less");
        assertLt(navBefore - navAfter, 1e12, "the split's total claim NAV must be preserved up to one quote wei of flooring");

        // Execute and pin: the redeemer receives exactly the drifted split, never the stale one
        uint256 quote0 = quoteToken.balanceOf(LPT_PROVIDER);
        vm.prank(LPT_PROVIDER);
        liquidityProviderTranche.redeemMultiAsset(shares, 0, quoteAfter, LPT_PROVIDER, LPT_PROVIDER);
        assertEq(quoteToken.balanceOf(LPT_PROVIDER) - quote0, 950_004_999, "execution must pay the drifted quote leg exactly");
    }

    /**
     * @notice An external LP's partial removal pays the floor-rounded proportional slices of its OWN BPT and
     *         leaves the kernel's ledger, custody, and the per-BPT price weakly-risen: exogenous exits can
     *         never dilute the ledger-priced claim
     */
    function test_ExternalPartialRemove_BurnsOwnBptOnly_LedgerInertAndMarkWeaklyRises() public {
        // The external LP joins at fair value first: 1_000e6 quote mints exactly 1_000e18 BPT at NAV-per-BPT 1.0
        quoteToken.mint(exogenousActor, 1_000e6);
        vm.startPrank(exogenousActor);
        quoteToken.approve(address(balancerVault), 1_000e6);
        uint256[2] memory legs;
        legs[1 - stPoolTokenIndex] = 1_000e6;
        balancerVault.mintPoolTokensTo(address(bpt), exogenousActor, 1_000e18, legs);
        vm.stopPrank();

        uint256 kernelLpt0 = toUint256(kernel.getState().totalLPTAssets);
        uint256 kernelBpt0 = bpt.balanceOf(address(kernel));
        uint256 mark0 = _liveLPTRawNAV();
        uint256 supply0 = bpt.totalSupply();
        uint256[2] memory pool0 = balancerVault.getPoolBalances(address(bpt));
        uint256 burn = 600e18;
        uint256[2] memory expectedOuts = [(pool0[0] * burn) / supply0, (pool0[1] * burn) / supply0];

        vm.prank(exogenousActor);
        uint256[2] memory outs = balancerRouter.removeLiquidityProportional(address(bpt), burn, expectedOuts);

        assertEq(outs[0], expectedOuts[0], "token0 out must be the floor-rounded proportional slice");
        assertEq(outs[1], expectedOuts[1], "token1 out must be the floor-rounded proportional slice");
        assertEq(bpt.balanceOf(exogenousActor), 1_000e18 - burn, "the burn must draw exclusively on the external LP's balance");
        assertEq(bpt.totalSupply(), supply0 - burn, "the supply must fall by exactly the burn");
        assertEq(toUint256(kernel.getState().totalLPTAssets), kernelLpt0, "the kernel's LPT ledger must be inert");
        assertEq(bpt.balanceOf(address(kernel)), kernelBpt0, "the kernel's BPT custody must be inert");
        assertGe(_liveLPTRawNAV(), mark0, "the floor residue stays in the pool, the ledger-priced mark can only weakly rise");
    }

    // =============================
    // Vault-session mutual exclusion (spec decision 4)
    // =============================

    /**
     * @notice Royco venue operations refuse to run inside a vault session they did not open: a multi-asset
     *         redemption and a multi-asset deposit attempted from inside an externally held unlock both
     *         revert VAULT_ALREADY_UNLOCKED, and an external removal outside any session reverts
     *         VaultIsNotUnlocked, so an external remove can never interleave into a Royco flow's settlement
     * @dev The converse direction needs no runtime pin: mid-Royco-flow the only executing code is the
     *      kernel's own onlyVault callback (the mock registers no hook layer), so no external LP instruction
     *      can run before the kernel's unlock settles and returns
     */
    function test_RoycoVenueOps_RefuseAForeignVaultSession_ExternalRemoveNeedsItsOwnSession() public {
        MidSessionProbe probe = new MidSessionProbe(balancerVault, liquidityProviderTranche);
        accessManager.grantRole(LPT_LP_ROLE, address(probe), 0);
        vm.prank(LPT_PROVIDER);
        liquidityProviderTranche.transfer(address(probe), 100e18);
        quoteToken.mint(address(probe), 100e6);

        vm.expectRevert(BalancerV3LiquidityVenue.VAULT_ALREADY_UNLOCKED.selector);
        probe.attemptRedeemMidSession(100e18);

        vm.expectRevert(BalancerV3LiquidityVenue.VAULT_ALREADY_UNLOCKED.selector);
        probe.attemptDepositMidSession(100e6);

        // Outside a session the raw vault surface is sealed: the settlement discipline is unlock-only
        uint256[] memory minAmountsOut = new uint256[](2);
        vm.prank(exogenousActor);
        vm.expectRevert(IVaultErrors.VaultIsNotUnlocked.selector);
        balancerVault.removeLiquidity(
            RemoveLiquidityParams({
                pool: address(bpt),
                from: exogenousActor,
                maxBptAmountIn: 1,
                minAmountsOut: minAmountsOut,
                kind: RemoveLiquidityKind.PROPORTIONAL,
                userData: ""
            })
        );
        vm.prank(exogenousActor);
        vm.expectRevert(IVaultErrors.VaultIsNotUnlocked.selector);
        balancerVault.swap(VaultSwapParams(SwapKind.EXACT_IN, address(bpt), IERC20(address(quoteToken)), IERC20(address(seniorTranche)), 1, 0, ""));
    }

    // =============================
    // getRate mid-session (spec decision 3)
    // =============================

    /**
     * @notice getRate is reachable from inside an open vault session with a live unsettled swap delta and
     *         returns exactly the locked-vault reading: the rate prices committed accounting state, never
     *         session state, exactly how the production E-CLP reads its rate provider mid-swap
     * @dev The fixture's rate is exactly WAD (stEffectiveNAV == stSupply), and the mid-session swap's own
     *      output (500e18 senior for 500e6 quote) is priced at that same rate, pinning that the swap and the
     *      reader consume one rate source
     */
    function test_GetRate_MidExternalSwapSession_MatchesLockedRead() public {
        uint256 lockedRate = IRateProvider(address(kernel)).getRate();
        assertEq(lockedRate, WAD, "fixture: the senior rate is exactly WAD");

        MidSessionProbe probe = new MidSessionProbe(balancerVault, liquidityProviderTranche);
        quoteToken.mint(address(probe), 500e6);
        (uint256 midSessionRate, uint256 amountOut) =
            probe.swapAndReadRate(address(bpt), IERC20(address(quoteToken)), IERC20(address(seniorTranche)), 500e6, IRateProvider(address(kernel)));

        assertEq(midSessionRate, lockedRate, "getRate mid-session must equal the locked-vault reading");
        assertEq(amountOut, 500e18, "the mid-session swap must price its senior leg at that same rate");
    }

    // =============================
    // Helpers
    // =============================

    /// @dev The exogenous actor sources senior shares through the real gated deposit path, never a mint
    function _actorDepositsSenior(uint256 _assets) internal {
        stJtVault.mintShares(exogenousActor, _assets);
        vm.startPrank(exogenousActor);
        stJtVault.approve(address(seniorTranche), _assets);
        seniorTranche.deposit(toTrancheUnits(_assets), exogenousActor);
        vm.stopPrank();
    }
}

/**
 * @title MidSessionProbe
 * @notice An external contract holding a vault session open while probing what can and cannot run inside it
 */
contract MidSessionProbe {
    MockBalancerVault internal immutable VAULT;
    RoycoLiquidityProviderTranche internal immutable LPT;

    error ONLY_VAULT();

    constructor(MockBalancerVault _vault, RoycoLiquidityProviderTranche _lpt) {
        VAULT = _vault;
        LPT = _lpt;
    }

    /// @notice Opens a session and attempts a Royco multi-asset redemption from inside it
    function attemptRedeemMidSession(uint256 _shares) external {
        VAULT.unlock(abi.encodeCall(this.redeemHook, (_shares)));
    }

    function redeemHook(uint256 _shares) external {
        require(msg.sender == address(VAULT), ONLY_VAULT());
        LPT.redeemMultiAsset(_shares, 0, 0, address(this), address(this));
    }

    /// @notice Opens a session and attempts a Royco multi-asset deposit from inside it
    function attemptDepositMidSession(uint256 _quoteAssets) external {
        VAULT.unlock(abi.encodeCall(this.depositHook, (_quoteAssets)));
    }

    function depositHook(uint256 _quoteAssets) external {
        require(msg.sender == address(VAULT), ONLY_VAULT());
        IERC20 quote = VAULT.getPoolTokens(address(LPT.asset()))[1];
        quote.approve(address(LPT), _quoteAssets);
        LPT.depositMultiAsset(0, _quoteAssets, 0, address(this));
    }

    /// @notice Opens a session, swaps with the delta still unsettled, reads the rate provider, then settles
    function swapAndReadRate(
        address _pool,
        IERC20 _tokenIn,
        IERC20 _tokenOut,
        uint256 _amountIn,
        IRateProvider _rateProvider
    )
        external
        returns (uint256 rate, uint256 amountOut)
    {
        bytes memory result = VAULT.unlock(abi.encodeCall(this.swapAndReadRateHook, (_pool, _tokenIn, _tokenOut, _amountIn, _rateProvider)));
        (rate, amountOut) = abi.decode(result, (uint256, uint256));
    }

    function swapAndReadRateHook(
        address _pool,
        IERC20 _tokenIn,
        IERC20 _tokenOut,
        uint256 _amountIn,
        IRateProvider _rateProvider
    )
        external
        returns (uint256 rate, uint256 amountOut)
    {
        require(msg.sender == address(VAULT), ONLY_VAULT());
        (,, amountOut) = VAULT.swap(VaultSwapParams(SwapKind.EXACT_IN, _pool, _tokenIn, _tokenOut, _amountIn, 0, ""));
        // The read happens with the swap's debt and credit still open, the deepest mid-session point
        rate = _rateProvider.getRate();
        _tokenIn.transfer(address(VAULT), _amountIn);
        VAULT.settle(_tokenIn, _amountIn);
        VAULT.sendTo(_tokenOut, address(this), amountOut);
    }
}
