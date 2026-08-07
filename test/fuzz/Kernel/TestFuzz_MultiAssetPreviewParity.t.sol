// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { LPT_LP_ROLE } from "../../../src/factory/Roles.sol";
import { WAD } from "../../../src/libraries/Constants.sol";
import { AssetClaims, MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toUint256 } from "../../../src/libraries/Units.sol";
import { MarketFuzzTestBase } from "../../utils/MarketFuzzTestBase.sol";

/**
 * @title TestFuzz_MultiAssetPreviewParity_Kernel
 * @notice Fuzzes same-block preview/execute parity for the two MULTI-ASSET liquidity flows that
 *         TestFuzz_PreviewParity excludes: `depositMultiAsset` and `redeemMultiAsset`. Previously multi-asset
 *         deposit parity was only a ±30bps inequality on the real venue (Test_BalancerHooksAndReinvest) and
 *         redeem parity was a single fixture, on the deterministic mock venue exact parity must hold.
 * @dev Each preview is taken immediately before its execution in the same block, so any divergence in the
 *      multi-asset pricing path (senior-share mint sizing, venue add/remove, claim scaling) fails loudly.
 */
contract TestFuzz_MultiAssetPreviewParity_Kernel is MarketFuzzTestBase {
    using Math for uint256;

    function testFuzz_QuoteOnlyMultiAssetDeposit_PreviewMatchesExecution(
        uint256 _stSeed,
        uint256 _jtSeed,
        uint256 _vaultBps,
        uint256 _elapsed,
        uint256 _quoteSeed
    )
        public
    {
        _setupEvolvedMarket(_stSeed, _jtSeed, _vaultBps, _elapsed);
        uint256 quoteLeg = bound(_quoteSeed, 1, 1e12); // 1 quote wei up to 1e12 quote wei
        address a = makeAddr("MA_QUOTE");
        accessManager.grantRole(LPT_LP_ROLE, a, 0);
        quoteToken.mint(a, quoteLeg);
        vm.startPrank(a);
        quoteToken.approve(address(liquidityProviderTranche), quoteLeg);
        uint256 previewed;
        try liquidityProviderTranche.previewDepositMultiAsset(0, quoteLeg) returns (uint256 p, uint256) {
            previewed = p;
        } catch {
            vm.stopPrank();
            return; // dust input floors to zero shares (MUST_MINT_NON_ZERO_SHARES), not a parity case
        }
        if (previewed == 0) {
            vm.stopPrank();
            return;
        }
        (uint256 minted,) = liquidityProviderTranche.depositMultiAsset(0, quoteLeg, 0, a);
        vm.stopPrank();
        assertEq(minted, previewed, "quote-only multi-asset deposit must mint exactly the previewed shares");
    }

    function testFuzz_BalancedMultiAssetDeposit_PreviewMatchesExecution(
        uint256 _stSeed,
        uint256 _jtSeed,
        uint256 _vaultBps,
        uint256 _elapsed,
        uint256 _stSeed2,
        uint256 _quoteSeed
    )
        public
    {
        uint256 st = _setupEvolvedMarket(_stSeed, _jtSeed, _vaultBps, _elapsed);
        // Bound the senior leg by the live plain-ST max (conservative: the multi-asset op also adds quote depth,
        // so it can never breach the liquidity gate harder than a bare ST deposit of the same size). Use a
        // substantial fraction of capacity (per the repo's dust-floor convention in TestFuzz_PreviewParity) so the
        // ST leg is always well above the zero-share mint boundary that a 1-wei leg hits in a large pool.
        uint256 maxStLeg = toUint256(seniorTranche.maxDeposit(ST_PROVIDER));
        if (maxStLeg < 1e6) return; // negligible senior capacity this run, the quote-only test covers the venue add
        uint256 stLeg = bound(_stSeed2, maxStLeg / 2, maxStLeg);
        uint256 quoteLeg = bound(_quoteSeed, 1, Math.max(1, st / QUOTE_TO_NAV_SCALE / 10));
        address a = makeAddr("MA_BALANCED");
        accessManager.grantRole(LPT_LP_ROLE, a, 0);
        stJtVault.mintShares(a, stLeg);
        quoteToken.mint(a, quoteLeg);
        vm.startPrank(a);
        stJtVault.approve(address(liquidityProviderTranche), stLeg);
        quoteToken.approve(address(liquidityProviderTranche), quoteLeg);
        uint256 previewed;
        // A dust combined value floors to zero LPT shares (a non-mintable input), skip it. Capturing the preview via
        // try/catch means a preview that reverts OR returns zero is skipped, while a preview that returns >0 shares
        // still proceeds to execution, so a genuine preview-over-promises divergence would fail the assertion.
        try liquidityProviderTranche.previewDepositMultiAsset(stLeg, quoteLeg) returns (uint256 p, uint256) {
            previewed = p;
        } catch {
            vm.stopPrank();
            return;
        }
        if (previewed == 0) {
            vm.stopPrank();
            return;
        }
        (uint256 minted,) = liquidityProviderTranche.depositMultiAsset(stLeg, quoteLeg, 0, a);
        vm.stopPrank();
        assertEq(minted, previewed, "balanced multi-asset deposit must mint exactly the previewed shares");
    }

    function testFuzz_MultiAssetRedeem_PreviewMatchesExecution(
        uint256 _stSeed,
        uint256 _jtSeed,
        uint256 _vaultBps,
        uint256 _elapsed,
        uint256 _sharesSeed
    )
        public
    {
        _setupEvolvedMarket(_stSeed, _jtSeed, _vaultBps, _elapsed);
        // Size by the multi-asset bound so the sweep also exercises the wedge past the in-kind maximum,
        // and pin the bounds' dominance across every evolved market the fuzzer constructs
        uint256 maxShares = liquidityProviderTranche.maxRedeemMultiAsset(LPT_PROVIDER);
        // Exact dominance: both bounds price through the same virtual-shares primitive (floor((S+1e6)*W/(claimNAV+1)))
        // over identical (claimNAV, supply) inputs, and the multi-asset withdrawable NAV weakly exceeds the in-kind
        // NAV (zero relief leaves them equal, senior-share relief only lifts the multi bound), so the dominance holds
        // share for share with no offset slack
        assertGe(maxShares, liquidityProviderTranche.maxRedeem(LPT_PROVIDER), "the multi-asset bound must weakly dominate the in-kind bound");
        if (maxShares < 1e6) return; // no liquidity-respecting redemption capacity this run
        uint256 shares = bound(_sharesSeed, 1e6, maxShares); // dust floor avoids a zero-asset payout the accountant rejects

        (AssetClaims memory previewClaims, uint256 previewQuote) = liquidityProviderTranche.previewRedeemMultiAsset(shares);
        vm.prank(LPT_PROVIDER);
        (AssetClaims memory claims, uint256 quoteOut) = liquidityProviderTranche.redeemMultiAsset(shares, 0, 0, LPT_PROVIDER, LPT_PROVIDER);

        assertEq(quoteOut, previewQuote, "multi-asset redeem: quote leg must match the preview");
        assertEq(claims.collateralAssets, previewClaims.collateralAssets, "multi-asset redeem: collateral leg must match the preview");
        assertEq(claims.lptAssets, previewClaims.lptAssets, "multi-asset redeem: LPT-asset leg must match the preview");
        assertEq(claims.stShares, previewClaims.stShares, "multi-asset redeem: senior-share leg must match the preview");
        assertEq(claims.nav, previewClaims.nav, "multi-asset redeem: claim NAV must match the preview");
    }

    /**
     * Scenario: a fuzzed covered drawdown breaches the liquidation threshold (which forces the market PERPETUAL),
     * arming the ST self-liquidation bonus. The multi-asset redemption preview must then match the bonus-boosted
     * execution exactly on all five claim legs plus the quote leg. In lptRedeemMultiAsset the bonus lands on the
     * claims immediately before the preview's early return, so a regression reordering those two lines would
     * silently under-quote every bonus-regime preview while exec stays correct, this arm is the multi-asset
     * analog of the dedicated senior in-kind bonus-parity fuzz. A small pre-drawdown collateral-leg deposit puts
     * senior shares in the pool so the removal's venue leg withdraws shares the bonus rides on. The drawdown band
     * [-20.8%, -22.5%] at the 30% junior ratio (plus the 0.5% ST leg) always breaches the liquidation threshold
     * without exhausting the junior buffer (exhaustion sits at -22.99%), mirroring the senior arm's band.
     */
    function testFuzz_RedeemMultiAssetPreviewParity_LiquidationBonusRegime(uint256 _stSeed, uint256 _drawdownBps, uint256 _sharesSeed) public {
        uint256 st = bound(_stSeed, 1e18, 1e26); // uniform over 8 orders of magnitude of senior seed size
        uint256 drawdownBps = bound(_drawdownBps, 2080, 2250); // always past the liquidation threshold, buffer never exhausted
        _seedFlatMarket(st, st * 3 / 10, 0);

        // A collateral-leg deposit worth 0.5% of the senior seed puts senior shares in the quote-only pool, so
        // the later removal's venue leg withdraws senior shares for the bonus to boost
        uint256 stLeg = st / 200;
        stJtVault.mintShares(LPT_PROVIDER, stLeg);
        vm.startPrank(LPT_PROVIDER);
        stJtVault.approve(address(liquidityProviderTranche), stLeg);
        liquidityProviderTranche.depositMultiAsset(stLeg, 0, 0, LPT_PROVIDER);
        vm.stopPrank();

        applySTPnL(-int256(drawdownBps));
        syncVenuePrices();
        SyncedAccountingState memory state = _sync();
        assertGe(state.coverageUtilizationWAD, state.coverageLiquidationUtilizationWAD, "the drawdown must breach the liquidation coverage threshold");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "a liquidation breach forces the market PERPETUAL so redemptions stay open");

        uint256 maxShares = liquidityProviderTranche.maxRedeemMultiAsset(LPT_PROVIDER);
        if (maxShares < 1e6) return; // no liquidity-respecting redemption capacity this run
        // A substantial slice keeps the proportional removal's senior-share leg above the floor-to-zero boundary,
        // so the bonus always rides on nonzero claims and the parity is never vacuous
        uint256 shares = bound(_sharesSeed, Math.max(1e6, maxShares / 2), maxShares);

        (AssetClaims memory previewClaims, uint256 previewQuote) = liquidityProviderTranche.previewRedeemMultiAsset(shares);
        assertTrue(toUint256(previewClaims.nav) != 0, "the bonus-regime quote must carry a nonzero senior-share redemption claim");
        vm.prank(LPT_PROVIDER);
        (AssetClaims memory claims, uint256 quoteOut) = liquidityProviderTranche.redeemMultiAsset(shares, 0, 0, LPT_PROVIDER, LPT_PROVIDER);

        assertEq(quoteOut, previewQuote, "bonus-regime multi-asset redeem: quote leg must match the preview");
        assertEq(claims.collateralAssets, previewClaims.collateralAssets, "bonus-regime multi-asset redeem: collateral leg must match the preview");
        assertEq(claims.lptAssets, previewClaims.lptAssets, "bonus-regime multi-asset redeem: LPT-asset leg must match the preview");
        assertEq(claims.stShares, previewClaims.stShares, "bonus-regime multi-asset redeem: senior-share leg must match the preview");
        assertEq(claims.nav, previewClaims.nav, "bonus-regime multi-asset redeem: claim NAV must match the preview");
    }

    // =============================
    // The harsh-state sweep: the advertised multi-asset maximum must execute, quote exactly at the
    // boundary, and conserve every venue token flow, across drawdown, liquidation, wipeout, idle
    // premium, venue slippage, and pool-skew states the evolved up-only sweep never constructs
    // =============================

    /**
     * Scenario: the advertised maxRedeemMultiAsset must NEVER revert when executed at exactly that value.
     * The bound linearizes the senior-unwind relief (z = (D - S*m) * D / (D - r*m)) while the execution
     * settles the real venue removal, senior redemption, and end-of-flow liquidity gate, so any modeling
     * error in the bound (a stale pile assumption, a rounding wedge the heal machinery misses, a relief
     * overstatement in the wiped regime) surfaces here as a revert at the advertised size. Also pins the
     * weak dominance maxRedeemMultiAsset >= maxRedeem on every harsh state, extending the evolved-market
     * dominance pin into the drawdown and liquidation regimes, and that the settled exit leaves the
     * committed liquidity utilization within WAD (the end-of-flow gate's own promise).
     */
    function testFuzz_MaxRedeemMultiAsset_AdvertisedMaxAlwaysExecutes(
        uint256 _stSeed,
        uint256 _jtSeed,
        uint256 _regimeSeed,
        uint256 _pnlSeed,
        uint256 _elapsed,
        uint256 _lptBpsSeed,
        uint256 _premiumSeed
    )
        public
    {
        _buildHarshState(_stSeed, _jtSeed, _regimeSeed, _pnlSeed, _elapsed, _lptBpsSeed, _premiumSeed);

        uint256 maxShares = liquidityProviderTranche.maxRedeemMultiAsset(LPT_PROVIDER);
        // The multi-asset bound weakly dominates the in-kind bound on every harsh state: both price through the
        // same virtual-shares primitive and the senior-unwind relief only ever lifts the multi-asset bound
        assertGe(maxShares, liquidityProviderTranche.maxRedeem(LPT_PROVIDER), "the multi-asset bound must weakly dominate the in-kind bound");
        // Dust floor per the repo convention: a sub-1e6-share max scales its claims to a zero-NAV payout the
        // accountant's no-op guard rejects, a dust boundary the concrete boundary suite owns, not this property
        if (maxShares < 1e6) return;

        // The advertised maximum must settle with no slippage floors and no tolerance for any revert
        vm.prank(LPT_PROVIDER);
        liquidityProviderTranche.redeemMultiAsset(maxShares, 0, 0, LPT_PROVIDER, LPT_PROVIDER);

        // The settled exit honored the liquidity requirement it was sized against
        SyncedAccountingState memory state = _sync();
        assertLe(state.liquidityUtilizationWAD, WAD, "the settled max redemption must leave the liquidity utilization within WAD");
    }

    /**
     * Scenario: previewRedeemMultiAsset at exactly maxRedeemMultiAsset must quote (not revert) and match the
     * execution byte for byte on the quote leg and every claim leg. The existing parity fuzz samples uniformly
     * below the max, but the max point is where the wedge and heal machinery is maximally stressed: the
     * preview's null caller skips every burn and its LPT_ASSET_PRICE cache replaces the settled post-remove
     * pool, so a divergence between the simulated and settled boundary paths lands exactly here.
     */
    function testFuzz_PreviewRedeemMultiAsset_ParityAtExactMax(
        uint256 _stSeed,
        uint256 _jtSeed,
        uint256 _regimeSeed,
        uint256 _pnlSeed,
        uint256 _elapsed,
        uint256 _lptBpsSeed,
        uint256 _premiumSeed
    )
        public
    {
        _buildHarshState(_stSeed, _jtSeed, _regimeSeed, _pnlSeed, _elapsed, _lptBpsSeed, _premiumSeed);

        uint256 maxShares = liquidityProviderTranche.maxRedeemMultiAsset(LPT_PROVIDER);
        if (maxShares < 1e6) return; // dust floor, see the always-executes arm

        // The preview at the exact boundary must quote, so no try/catch tolerance
        (AssetClaims memory previewClaims, uint256 previewQuote) = liquidityProviderTranche.previewRedeemMultiAsset(maxShares);
        vm.prank(LPT_PROVIDER);
        (AssetClaims memory claims, uint256 quoteOut) = liquidityProviderTranche.redeemMultiAsset(maxShares, 0, 0, LPT_PROVIDER, LPT_PROVIDER);

        assertEq(quoteOut, previewQuote, "max-boundary multi-asset redeem: quote leg must match the preview");
        assertEq(claims.collateralAssets, previewClaims.collateralAssets, "max-boundary multi-asset redeem: collateral leg must match the preview");
        assertEq(claims.lptAssets, previewClaims.lptAssets, "max-boundary multi-asset redeem: LPT-asset leg must match the preview");
        assertEq(claims.stShares, previewClaims.stShares, "max-boundary multi-asset redeem: senior-share leg must match the preview");
        assertEq(claims.nav, previewClaims.nav, "max-boundary multi-asset redeem: claim NAV must match the preview");
    }

    /**
     * Scenario: after a fuzzed multi-asset deposit the venue's ACTUAL token movements must conserve exactly,
     * independently of any pricing mirror: the quote leg lands in the pool in full, every senior share the
     * deposit minted plus the tail's measured idle-premium deployment lands in the pool (none stranded with
     * the kernel or the depositor), and every pool token the add minted sits in kernel custody. Mirrors the
     * invariant handler's token-flow reconciliation as direct fuzz assertions over the harsh state sweep.
     */
    function testFuzz_DepositMultiAsset_VenueTokenFlowsConserved(
        uint256 _stSeed,
        uint256 _jtSeed,
        uint256 _regimeSeed,
        uint256 _pnlSeed,
        uint256 _elapsed,
        uint256 _lptBpsSeed,
        uint256 _premiumSeed,
        uint256 _stLegSeed,
        uint256 _quoteSeed
    )
        public
    {
        uint256 st = _buildHarshState(_stSeed, _jtSeed, _regimeSeed, _pnlSeed, _elapsed, _lptBpsSeed, _premiumSeed);

        // Bound the senior leg by the live plain-ST max (conservative, per the balanced parity arm), degrading to
        // a quote-only deposit when senior capacity is negligible or the harsh state landed FIXED_TERM
        uint256 maxStLeg = toUint256(seniorTranche.maxDeposit(ST_PROVIDER));
        uint256 stLeg = maxStLeg < 1e6 ? 0 : bound(_stLegSeed, maxStLeg / 2, maxStLeg);
        uint256 quoteLeg = bound(_quoteSeed, 1, Math.max(1e12, st / QUOTE_TO_NAV_SCALE / 10));

        address a = makeAddr("MA_FLOWS_IN");
        accessManager.grantRole(LPT_LP_ROLE, a, 0);
        if (stLeg != 0) stJtVault.mintShares(a, stLeg);
        quoteToken.mint(a, quoteLeg);
        vm.startPrank(a);
        if (stLeg != 0) stJtVault.approve(address(liquidityProviderTranche), stLeg);
        quoteToken.approve(address(liquidityProviderTranche), quoteLeg);
        // A dust combined value floors to zero shares (a non-mintable input), skip it via the preview
        try liquidityProviderTranche.previewDepositMultiAsset(stLeg, quoteLeg) returns (uint256 p, uint256) {
            if (p == 0) {
                vm.stopPrank();
                return;
            }
        } catch {
            vm.stopPrank();
            return;
        }

        FlowSnap memory f = _snapFlows();
        liquidityProviderTranche.depositMultiAsset(stLeg, quoteLeg, 0, a);
        vm.stopPrank();

        // The settled op's tail deploys the idle premium pile into the pool, so the ledger may only fall
        uint256 idleAfter = kernel.getState().lptOwnedSeniorTrancheShares;
        assertLe(idleAfter, f.idle0, "a multi-asset deposit must never grow the idle liquidity premium ledger");
        uint256 idleDeployed = f.idle0 - idleAfter;

        // Venue conservation, written additively so a flow moving the wrong way fails instead of underflowing
        assertEq(quoteToken.balanceOf(address(balancerVault)), f.venueQuote0 + quoteLeg, "the deposited quote leg must land in the pool in full");
        assertEq(
            seniorTranche.totalSupply() + f.venueSenior0 + idleDeployed,
            f.stSupply0 + seniorTranche.balanceOf(address(balancerVault)),
            "minted senior shares plus the deployed idle pile must reconcile with the pool's senior inflow"
        );
        assertEq(
            bpt.balanceOf(address(kernel)) + f.bptSupply0,
            f.kernelBpt0 + bpt.totalSupply(),
            "pool tokens minted by the add must reconcile with the kernel's custody"
        );
    }

    /**
     * Scenario: after a fuzzed multi-asset redemption the venue's ACTUAL token movements must conserve exactly:
     * the pool's quote outflow all lands with the receiver, every senior share pulled from the pool or the idle
     * pile is burned (none parked with the kernel), and the burned pool tokens come exclusively from the
     * kernel's custody. The idle ledger's total move is measured and split into the redeemer's floor-mirrored
     * slice and the tail's deployment of the remaining pile.
     */
    function testFuzz_RedeemMultiAsset_VenueTokenFlowsConserved(
        uint256 _stSeed,
        uint256 _jtSeed,
        uint256 _regimeSeed,
        uint256 _pnlSeed,
        uint256 _elapsed,
        uint256 _lptBpsSeed,
        uint256 _premiumSeed,
        uint256 _sharesSeed
    )
        public
    {
        _buildHarshState(_stSeed, _jtSeed, _regimeSeed, _pnlSeed, _elapsed, _lptBpsSeed, _premiumSeed);

        uint256 maxShares = liquidityProviderTranche.maxRedeemMultiAsset(LPT_PROVIDER);
        if (maxShares < 1e6) return; // dust floor, see the always-executes arm
        uint256 shares = bound(_sharesSeed, 1e6, maxShares);

        // A fresh receiver isolates the quote outflow reconciliation from the provider's own balances
        address receiver = makeAddr("MA_FLOWS_OUT");
        FlowSnap memory f = _snapFlows();
        vm.prank(LPT_PROVIDER);
        liquidityProviderTranche.redeemMultiAsset(shares, 0, 0, receiver, LPT_PROVIDER);

        // The idle ledger moves twice in a settled exit: the redeemer's slice is unwound in the ST leg, then the
        // tail deploys the remaining pile, so the total move is at least the floor-mirrored slice and never grows
        uint256 idleAfter = kernel.getState().lptOwnedSeniorTrancheShares;
        assertLe(idleAfter, f.idle0, "a multi-asset redemption must never grow the idle liquidity premium ledger");
        uint256 idleUnwound = f.idle0 - idleAfter;
        // The slice mirror divides by the effective supply exactly as production's _scaleAssetClaims does
        assertGe(idleUnwound, f.idle0.mulDiv(shares, f.lptSupply0 + 1), "the idle ledger must move by at least the redeemer's mirrored slice");

        // Venue conservation, written additively so a flow moving the wrong way fails instead of underflowing
        assertEq(
            quoteToken.balanceOf(address(balancerVault)) + quoteToken.balanceOf(receiver),
            f.venueQuote0,
            "the pool's quote outflow must reconcile with the receiver's quote gain"
        );
        assertEq(
            seniorTranche.totalSupply() + f.venueSenior0 + idleUnwound,
            f.stSupply0 + seniorTranche.balanceOf(address(balancerVault)),
            "burned senior shares must reconcile with the pool withdrawal plus the idle ledger outflow"
        );
        assertEq(
            bpt.totalSupply() + f.kernelBpt0,
            f.bptSupply0 + bpt.balanceOf(address(kernel)),
            "burned pool tokens must reconcile with the kernel's custody outflow"
        );
    }

    // =============================
    // Harsh-state fixtures
    // =============================

    /// @dev Token balances captured around a multi-asset op so its actual transfers can be reconciled
    struct FlowSnap {
        uint256 venueQuote0;
        uint256 venueSenior0;
        uint256 stSupply0;
        uint256 kernelBpt0;
        uint256 bptSupply0;
        uint256 idle0;
        uint256 lptSupply0;
    }

    /// @dev Captures the balances the venue-flow reconciliation compares against after a multi-asset op
    function _snapFlows() internal view returns (FlowSnap memory f) {
        f.venueQuote0 = quoteToken.balanceOf(address(balancerVault));
        f.venueSenior0 = seniorTranche.balanceOf(address(balancerVault));
        f.stSupply0 = seniorTranche.totalSupply();
        f.kernelBpt0 = bpt.balanceOf(address(kernel));
        f.bptSupply0 = bpt.totalSupply();
        f.idle0 = kernel.getState().lptOwnedSeniorTrancheShares;
        f.lptSupply0 = liquidityProviderTranche.totalSupply();
    }

    /**
     * @dev Builds the harshest state the fixture can construct, then commits it with a final sync:
     *      1. Flat market over 8 orders of magnitude of senior size with real two-leg pool depth (a 0.5%
     *         collateral-leg deposit puts senior shares in the pool so removals carry a senior leg)
     *      2. Staged idle premium: mode 1 and 2 arm the venue's punitive slippage so the staging sync's
     *         reinvest gate fails and the minted premium senior shares sit idle, mode 1 then disarms so the
     *         next op's tail can deploy the pile, mode 2 leaves it armed so the pile stays idle through the op
     *      3. Regime PnL: the even regime sweeps up-only vault yield [0%, +100%], the odd regime holds the
     *         bonus suite's 30% junior ratio and sweeps the drawdown band [-20.8%, -26%] on the staged price.
     *         At that ratio the flat-market liquidation entry sits at -20.8% and junior exhaustion at -22.99%
     *         (0.3 / 1.305), both shifted slightly by the staged +2% gain and its junior yield share, so the
     *         band sweeps liquidation-regime PERPETUAL through wiped-buffer PERPETUAL with only a thin
     *         FIXED_TERM sliver at the low edge (those runs advertise zero and skip)
     *      4. LPT-side PnL skews the pool's quote leg [-20%, +20%] in both price stores coherently
     * @return st The senior seed size in NAV wei
     */
    function _buildHarshState(
        uint256 _stSeed,
        uint256 _jtSeed,
        uint256 _regimeSeed,
        uint256 _pnlSeed,
        uint256 _elapsed,
        uint256 _lptBpsSeed,
        uint256 _premiumSeed
    )
        internal
        returns (uint256 st)
    {
        st = bound(_stSeed, 1e18, 1e26);
        bool liquidationRegime = _regimeSeed % 2 == 1;
        uint256 jt = liquidationRegime ? st * 3 / 10 : bound(_jtSeed, st / 2, 2 * st);
        _seedFlatMarket(st, jt, st.mulDiv(3, 20) / QUOTE_TO_NAV_SCALE + 1);

        // A collateral-leg deposit worth 0.5% of the senior seed puts senior shares in the quote-only pool
        uint256 stLeg = st / 200;
        stJtVault.mintShares(LPT_PROVIDER, stLeg);
        vm.startPrank(LPT_PROVIDER);
        stJtVault.approve(address(liquidityProviderTranche), stLeg);
        liquidityProviderTranche.depositMultiAsset(stLeg, 0, 0, LPT_PROVIDER);
        vm.stopPrank();

        // Stage the idle premium pile over an elapsed window with a fixed +2% gain
        uint256 premiumMode = _premiumSeed % 3;
        if (premiumMode != 0) setVenueSlippageMode(true);
        _warpAndRefreshFeed(bound(_elapsed, 1 hours, 30 days));
        applySTPnL(200);
        _sync();
        if (premiumMode == 1) setVenueSlippageMode(false);

        // Regime PnL on the shared collateral oracle
        if (liquidationRegime) applySTPnL(-int256(bound(_pnlSeed, 2080, 2600)));
        else applySTPnL(int256(bound(_pnlSeed, 0, 10_000)));

        // Skew the pool's quote leg last so no venue price re-sync erases it
        applyLPTPnL(int256(bound(_lptBpsSeed, 0, 4000)) - 2000);

        _sync();
    }

    /// @dev Seeds a flat market, applies up-only vault yield over a window, and syncs, leaving PERPETUAL state
    ///      with the premium deployed and every fee minted. Returns the senior seed size.
    function _setupEvolvedMarket(uint256 _stSeed, uint256 _jtSeed, uint256 _vaultBps, uint256 _elapsed) internal returns (uint256 st) {
        st = bound(_stSeed, 1e18, 1e26);
        uint256 jt = bound(_jtSeed, st / 2, 2 * st);
        uint256 vb = bound(_vaultBps, 0, 10_000);
        uint256 elapsed = bound(_elapsed, 1 hours, 365 days);
        _seedFlatMarket(st, jt, st.mulDiv(3, 20) / QUOTE_TO_NAV_SCALE + 1);
        applySTPnL(int256(vb));
        _warpAndRefreshFeed(elapsed);
        syncVenuePrices();
        _sync();
    }
}
