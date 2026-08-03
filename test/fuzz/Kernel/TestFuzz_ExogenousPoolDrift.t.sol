// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVaultErrors } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultErrors.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { LPT_LP_ROLE, ST_LP_ROLE } from "../../../src/factory/Roles.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { MarketFuzzTestBase } from "../../utils/MarketFuzzTestBase.sol";

/**
 * @title TestFuzz_ExogenousPoolDrift_Kernel
 * @notice Fuzzes exogenous pool interactions (exact-in swaps in both directions with a fuzzed fee, quote and
 *         senior donations) composed against Royco preview/execute pairs, asserting the conservation and
 *         parity spec pinned in Test_ExogenousPoolInteractions: exogenous flows never destroy pool value
 *         beyond the TVL floors' single wei, never touch the kernel's ledgers, preview/exec parity holds
 *         per block against the CURRENT (post-drift) state, a stale quote floor rejects instead of settling
 *         mispriced, and a redeemer is never paid past its ledger share of the drifted mark
 * @dev The senior legs an exogenous actor swaps or donates are sourced through the real gated ST deposit
 *      path, never a mint, so every drifted state is production-reachable
 */
contract TestFuzz_ExogenousPoolDrift_Kernel is MarketFuzzTestBase {
    using Math for uint256;

    address internal EXT;

    function setUp() public virtual override {
        super.setUp();
        EXT = makeAddr("EXO_DRIFT_ACTOR");
        accessManager.grantRole(ST_LP_ROLE, EXT, 0);
        accessManager.grantRole(LPT_LP_ROLE, EXT, 0);
    }

    // =============================
    // Seeding and drift machinery
    // =============================

    /**
     * @dev Seeds a flat market with quote depth plus a real senior pool leg: EXT deposits st/10 through the
     *      production ST path and donates half of it into the pool, so swaps run in both directions. The
     *      extra quote floor (1_000 whole quote) covers the senior deposit's liquidity requirement
     *      (st/200 NAV = st/200e12 quote wei <= 1e8 < 1e9) for every seeded size
     */
    function _seedDriftedMarket(uint256 _stSeed, uint256 _jtSeed, uint256 _extraQuoteSeed) internal returns (uint256 st) {
        st = bound(_stSeed, 1e20, 2e22);
        uint256 jt = bound(_jtSeed, st / 2, st);
        uint256 extraQuote = bound(_extraQuoteSeed, 1e9, 1e12);
        _seedFlatMarket(st, jt, extraQuote);

        uint256 stLeg = st / 10;
        stJtVault.mintShares(EXT, stLeg);
        vm.startPrank(EXT);
        stJtVault.approve(address(seniorTranche), stLeg);
        seniorTranche.deposit(toTrancheUnits(stLeg), EXT);
        seniorTranche.approve(address(balancerVault), stLeg / 2);
        balancerVault.injectPoolBalance(address(bpt), IERC20(address(seniorTranche)), stLeg / 2);
        vm.stopPrank();
    }

    /// @dev The mock swap's exact-in output recomputed with plain integer ops (independent of the vault's code path)
    function _swapOutMirror(address _tokenIn, address _tokenOut, uint256 _amountIn) internal view returns (uint256) {
        uint256 unitIn = _tokenIn == address(quoteToken) ? 1e6 : 1e18;
        uint256 unitOut = _tokenOut == address(quoteToken) ? 1e6 : 1e18;
        uint256 valueIn = (_amountIn * balancerVault.getTokenPriceWAD(_tokenIn)) / unitIn;
        uint256 grossOut = (valueIn * unitOut) / balancerVault.getTokenPriceWAD(_tokenOut);
        return (grossOut * (10_000 - balancerVault.swapFeeBps())) / 10_000;
    }

    /// @dev Halves the input until the priced output fits the pool's out leg, returning zero when nothing fits
    function _clampSwapInput(address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 _outLeg) internal view returns (uint256) {
        uint256 predOut = _swapOutMirror(_tokenIn, _tokenOut, _amountIn);
        while (predOut > _outLeg && _amountIn > 1) {
            _amountIn /= 2;
            predOut = _swapOutMirror(_tokenIn, _tokenOut, _amountIn);
        }
        return predOut > _outLeg ? 0 : _amountIn;
    }

    /// @dev Applies one fuzzed exogenous drift: quote donation, senior donation, or an exact-in swap either way
    function _applyDrift(uint256 _kindSeed, uint256 _amountSeed) internal {
        uint256 kind = bound(_kindSeed, 0, 3);
        if (kind == 0) {
            uint256 amount = bound(_amountSeed, 1, 1e10);
            quoteToken.mint(EXT, amount);
            vm.startPrank(EXT);
            quoteToken.approve(address(balancerVault), amount);
            balancerVault.injectPoolBalance(address(bpt), IERC20(address(quoteToken)), amount);
            vm.stopPrank();
        } else if (kind == 1) {
            uint256 bal = seniorTranche.balanceOf(EXT);
            if (bal == 0) return;
            uint256 amount = bound(_amountSeed, 1, bal);
            vm.startPrank(EXT);
            seniorTranche.approve(address(balancerVault), amount);
            balancerVault.injectPoolBalance(address(bpt), IERC20(address(seniorTranche)), amount);
            vm.stopPrank();
        } else {
            bool seniorIn = kind == 3;
            (address tokenIn, address tokenOut) = seniorIn ? (address(seniorTranche), address(quoteToken)) : (address(quoteToken), address(seniorTranche));
            uint256 amountIn;
            if (seniorIn) {
                uint256 bal = seniorTranche.balanceOf(EXT);
                if (bal == 0) return;
                amountIn = bound(_amountSeed, 1, bal);
            } else {
                amountIn = bound(_amountSeed, 1, 1e10);
                quoteToken.mint(EXT, amountIn);
            }
            uint256 outIdx = seniorIn ? 1 - stPoolTokenIndex : stPoolTokenIndex;
            amountIn = _clampSwapInput(tokenIn, tokenOut, amountIn, balancerVault.getPoolBalances(address(bpt))[outIdx]);
            if (amountIn == 0) return;
            vm.startPrank(EXT);
            IERC20(tokenIn).approve(address(balancerRouter), amountIn);
            balancerRouter.swapSingleTokenExactIn(address(bpt), IERC20(tokenIn), IERC20(tokenOut), amountIn, 0);
            vm.stopPrank();
        }
    }

    // =============================
    // Conservation under exogenous swaps
    // =============================

    /**
     * @notice Any exact-in swap at any fee conserves pool value and kernel state: the output equals the
     *         constant-price mirror, the swapper's received value never exceeds its paid value at the
     *         oracle's prices, the pool's TVL falls by at most the TVL floors' single wei, the composition
     *         moves by exactly the swapped amounts, and every kernel ledger is inert
     */
    /// forge-config: default.fuzz.runs = 1000
    /// forge-config: ci.fuzz.runs = 1000
    function testFuzz_ExternalSwap_ConservesPoolValueAndKernelLedgers(
        uint256 _stSeed,
        uint256 _jtSeed,
        uint256 _extraQuoteSeed,
        uint256 _feeSeed,
        uint256 _dirSeed,
        uint256 _amountSeed
    )
        public
    {
        _seedDriftedMarket(_stSeed, _jtSeed, _extraQuoteSeed);
        balancerVault.setSwapFeeBps(uint16(bound(_feeSeed, 0, 1_000)));
        bool seniorIn = _dirSeed % 2 == 1;
        (address tokenIn, address tokenOut) = seniorIn ? (address(seniorTranche), address(quoteToken)) : (address(quoteToken), address(seniorTranche));
        uint256 amountIn;
        if (seniorIn) {
            amountIn = bound(_amountSeed, 1, seniorTranche.balanceOf(EXT));
        } else {
            amountIn = bound(_amountSeed, 1, 1e10);
            quoteToken.mint(EXT, amountIn);
        }
        uint256 outIdx = seniorIn ? 1 - stPoolTokenIndex : stPoolTokenIndex;
        uint256[2] memory pool0 = balancerVault.getPoolBalances(address(bpt));
        amountIn = _clampSwapInput(tokenIn, tokenOut, amountIn, pool0[outIdx]);
        if (amountIn == 0) return;
        uint256 predOut = _swapOutMirror(tokenIn, tokenOut, amountIn);

        uint256 tvl0 = bptOracle.computeTVL();
        uint256 kernelLpt0 = toUint256(kernel.getState().totalLPTAssets);
        uint256 kernelCollateral0 = toUint256(kernel.getState().totalCollateralAssets);
        uint256 kernelIdle0 = kernel.getState().lptOwnedSeniorTrancheShares;

        vm.startPrank(EXT);
        IERC20(tokenIn).approve(address(balancerRouter), amountIn);
        uint256 amountOut = balancerRouter.swapSingleTokenExactIn(address(bpt), IERC20(tokenIn), IERC20(tokenOut), amountIn, predOut);
        vm.stopPrank();

        assertEq(amountOut, predOut, "the swap output must equal the constant-price mirror");
        // Value conservation at the oracle's prices: received <= paid, the flooring and fee stay in the pool
        uint256 unitIn = tokenIn == address(quoteToken) ? 1e6 : 1e18;
        uint256 unitOut = tokenOut == address(quoteToken) ? 1e6 : 1e18;
        assertLe(
            amountOut.mulDiv(bptOracle.getPriceWAD(tokenOut), unitOut),
            amountIn.mulDiv(bptOracle.getPriceWAD(tokenIn), unitIn),
            "the swapper's received value must never exceed its paid value"
        );
        assertGe(bptOracle.computeTVL() + 1, tvl0, "the pool's TVL must fall by at most the TVL floors' single wei");
        uint256[2] memory pool1 = balancerVault.getPoolBalances(address(bpt));
        assertEq(pool1[1 - outIdx], pool0[1 - outIdx] + amountIn, "the in leg must grow by exactly the input");
        assertEq(pool1[outIdx], pool0[outIdx] - amountOut, "the out leg must shrink by exactly the output");
        assertEq(toUint256(kernel.getState().totalLPTAssets), kernelLpt0, "the kernel's LPT ledger must be inert");
        assertEq(toUint256(kernel.getState().totalCollateralAssets), kernelCollateral0, "the kernel's collateral ledger must be inert");
        assertEq(kernel.getState().lptOwnedSeniorTrancheShares, kernelIdle0, "the kernel's idle premium ledger must be inert");

        // The keeper sync prices the drifted composition without complaint
        _sync();
    }

    // =============================
    // Preview/exec parity against the post-drift state
    // =============================

    /**
     * @notice Same-block preview/execute parity holds against the CURRENT state after any exogenous drift:
     *         a multi-asset deposit mints exactly its post-drift preview and a multi-asset redemption pays
     *         exactly its post-drift preview under the preview's own floors
     */
    /// forge-config: default.fuzz.runs = 1000
    /// forge-config: ci.fuzz.runs = 1000
    function testFuzz_PreviewExecParity_HoldsAgainstPostDriftState(
        uint256 _stSeed,
        uint256 _jtSeed,
        uint256 _extraQuoteSeed,
        uint256 _driftKindSeed,
        uint256 _driftAmountSeed,
        uint256 _opSeed
    )
        public
    {
        _seedDriftedMarket(_stSeed, _jtSeed, _extraQuoteSeed);
        balancerVault.setSwapFeeBps(uint16(bound(_driftAmountSeed, 0, 500)));
        _applyDrift(_driftKindSeed, _driftAmountSeed);

        // Deposit parity: quote-only multi-asset deposit against the drifted pool
        uint256 quoteLeg = bound(_opSeed, 1, 1e10);
        quoteToken.mint(EXT, quoteLeg);
        vm.startPrank(EXT);
        quoteToken.approve(address(liquidityProviderTranche), quoteLeg);
        uint256 previewedShares;
        uint256 previewedLptOut;
        bool previewOk;
        try liquidityProviderTranche.previewDepositMultiAsset(0, quoteLeg) returns (uint256 p, uint256 l) {
            (previewedShares, previewedLptOut, previewOk) = (p, l, p > 0);
        } catch {
            previewOk = false;
        }
        if (previewOk) {
            (uint256 minted, uint256 lptOut) = liquidityProviderTranche.depositMultiAsset(0, quoteLeg, previewedLptOut, EXT);
            assertEq(minted, previewedShares, "post-drift deposit must mint exactly the post-drift preview's shares");
            assertEq(lptOut, previewedLptOut, "post-drift deposit must add exactly the post-drift preview's BPT");
        }
        vm.stopPrank();

        // Redemption parity: multi-asset exit under the post-drift preview's own floors
        uint256 maxShares = liquidityProviderTranche.maxRedeemMultiAsset(LPT_PROVIDER);
        if (maxShares < 1e6) return;
        uint256 shares = bound(_opSeed, 1e6, maxShares);
        (AssetClaims memory claims, uint256 quoteOut) = liquidityProviderTranche.previewRedeemMultiAsset(shares);
        if (toUint256(claims.nav) == 0) return;
        uint256 vaultShares0 = stJtVault.balanceOf(LPT_PROVIDER);
        uint256 quote0 = quoteToken.balanceOf(LPT_PROVIDER);
        vm.prank(LPT_PROVIDER);
        liquidityProviderTranche.redeemMultiAsset(shares, 0, quoteOut, LPT_PROVIDER, LPT_PROVIDER);
        assertEq(quoteToken.balanceOf(LPT_PROVIDER) - quote0, quoteOut, "post-drift redemption must pay exactly the post-drift preview's quote leg");
        assertEq(
            stJtVault.balanceOf(LPT_PROVIDER) - vaultShares0,
            toUint256(claims.collateralAssets),
            "post-drift redemption must pay exactly the post-drift preview's collateral leg"
        );
    }

    // =============================
    // Stale floors against adverse drift
    // =============================

    /**
     * @notice A redemption floor taken from a pre-drift preview is SAFE, never mispriced: when an adverse
     *         senior -> quote swap shrinks the pool's quote leg below the stale floor the execution reverts
     *         (AmountOutBelowMin, or the no-op guard on a dust slice), and when the drift is too small to
     *         cross a quote wei the stale floor still clears with at least the promised amount. The fresh
     *         floor always settles at exactly the fresh preview
     */
    /// forge-config: default.fuzz.runs = 1000
    /// forge-config: ci.fuzz.runs = 1000
    function testFuzz_StaleQuoteFloor_RejectsOrClearsButNeverMisprices(
        uint256 _stSeed,
        uint256 _jtSeed,
        uint256 _extraQuoteSeed,
        uint256 _swapSeed,
        uint256 _sharesSeed
    )
        public
    {
        _seedDriftedMarket(_stSeed, _jtSeed, _extraQuoteSeed);
        uint256 maxShares = liquidityProviderTranche.maxRedeemMultiAsset(LPT_PROVIDER);
        if (maxShares < 1e6) return;
        uint256 shares = bound(_sharesSeed, 1e6, maxShares);
        (, uint256 staleQuoteOut) = liquidityProviderTranche.previewRedeemMultiAsset(shares);

        // The adverse drift: EXT swaps senior in, quote out
        uint256 amountIn = _clampSwapInput(
            address(seniorTranche),
            address(quoteToken),
            bound(_swapSeed, 1, seniorTranche.balanceOf(EXT)),
            balancerVault.getPoolBalances(address(bpt))[1 - stPoolTokenIndex]
        );
        if (amountIn == 0) return;
        vm.startPrank(EXT);
        seniorTranche.approve(address(balancerRouter), amountIn);
        balancerRouter.swapSingleTokenExactIn(address(bpt), IERC20(address(seniorTranche)), IERC20(address(quoteToken)), amountIn, 0);
        vm.stopPrank();

        (, uint256 freshQuoteOut) = liquidityProviderTranche.previewRedeemMultiAsset(shares);
        uint256 quote0 = quoteToken.balanceOf(LPT_PROVIDER);
        if (freshQuoteOut < staleQuoteOut) {
            // The stale floor exceeds what the drifted pool pays: executing it must revert, never settle short
            vm.prank(LPT_PROVIDER);
            bool settled;
            try liquidityProviderTranche.redeemMultiAsset(shares, 0, staleQuoteOut, LPT_PROVIDER, LPT_PROVIDER) {
                settled = true;
            } catch (bytes memory err) {
                bytes4 sel = bytes4(err);
                assertTrue(
                    sel == IVaultErrors.AmountOutBelowMin.selector || sel == IRoycoDayAccountant.INVALID_POST_OP_STATE.selector,
                    "the stale floor must reject with the vault's floor error or the no-op guard"
                );
            }
            assertFalse(settled, "an exit that cannot pay its stale floor must not settle");
            // The fresh floor settles at exactly the fresh preview
            vm.prank(LPT_PROVIDER);
            liquidityProviderTranche.redeemMultiAsset(shares, 0, freshQuoteOut, LPT_PROVIDER, LPT_PROVIDER);
            assertEq(quoteToken.balanceOf(LPT_PROVIDER) - quote0, freshQuoteOut, "the fresh floor must settle at exactly the fresh preview");
        } else {
            // The drift never crossed a quote wei: the stale floor still clears with at least its promise
            vm.prank(LPT_PROVIDER);
            liquidityProviderTranche.redeemMultiAsset(shares, 0, staleQuoteOut, LPT_PROVIDER, LPT_PROVIDER);
            assertGe(quoteToken.balanceOf(LPT_PROVIDER) - quote0, staleQuoteOut, "a clearing stale floor must still pay its promise");
        }
    }

    // =============================
    // Ledger-share bound under drift
    // =============================

    /**
     * @notice After any exogenous drift, an in-kind redemption pays exactly the floor-scaled BPT slice of
     *         the committed mark, and the slice's value at the drifted unit price never exceeds the
     *         redeemer's pro-rata share of that mark: drift accrues to redeemers only through the price
     * @dev The committed mark and the expected slice are recomputed here with plain integer ops from raw
     *      reads (pool TVL, BPT supply, kernel ledger), independently of the kernel's converters
     */
    /// forge-config: default.fuzz.runs = 1000
    /// forge-config: ci.fuzz.runs = 1000
    function testFuzz_DriftThenRedeem_PayoutNeverExceedsLedgerShare(
        uint256 _stSeed,
        uint256 _jtSeed,
        uint256 _extraQuoteSeed,
        uint256 _driftKindSeed,
        uint256 _driftAmountSeed,
        uint256 _sharesSeed
    )
        public
    {
        _seedDriftedMarket(_stSeed, _jtSeed, _extraQuoteSeed);
        balancerVault.setSwapFeeBps(uint16(bound(_sharesSeed, 0, 500)));
        _applyDrift(_driftKindSeed, _driftAmountSeed);
        _sync();

        // The independent two-step recomputation of the committed mark from raw reads
        uint256 supply = bpt.totalSupply();
        uint256 ledger = toUint256(kernel.getState().totalLPTAssets);
        uint256 unitPrice = (1e18 * bptOracle.computeTVL()) / supply;
        uint256 mark = (ledger * unitPrice) / 1e18;
        assertEq(toUint256(accountant.getState().lastLPTRawNAV), mark, "the committed mark must equal the independent two-step recomputation");

        uint256 maxShares = liquidityProviderTranche.maxRedeem(LPT_PROVIDER);
        if (maxShares < 1e6) return;
        uint256 shares = bound(_sharesSeed, 1e6, maxShares);
        uint256 lptSupply = liquidityProviderTranche.totalSupply();
        // The claim chain, floor for floor: the mark converted back at the unit price, scaled by the shares
        uint256 expectedBpt = (((mark * 1e18) / unitPrice) * shares) / (lptSupply + 1);
        if (expectedBpt == 0) return;

        uint256 bpt0 = bpt.balanceOf(LPT_PROVIDER);
        vm.prank(LPT_PROVIDER);
        liquidityProviderTranche.redeem(shares, LPT_PROVIDER, LPT_PROVIDER);
        uint256 bptPaid = bpt.balanceOf(LPT_PROVIDER) - bpt0;

        assertEq(bptPaid, expectedBpt, "the in-kind redemption must pay exactly the floor-scaled slice of the committed mark");
        assertLe(
            bptPaid.mulDiv(unitPrice, 1e18),
            mark.mulDiv(shares, lptSupply + 1),
            "the slice's value must never exceed the redeemer's pro-rata share of the drifted mark"
        );
    }
}
