// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { stdError } from "../../../lib/forge-std/src/StdError.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { AssetClaims, Operation } from "../../../src/libraries/Types.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { MockBPTOracle } from "../../mocks/MockBPTOracle.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { MarketParamsConfig } from "../../utils/FixtureTypes.sol";
import { defaultParams, zeroLiquidityParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_TrancheViewEdges_Tranches
 * @notice Exercises the tranche conversion and max-redeem views on the degraded states integrators actually probe:
 *         a tranche with zero share supply, and an LT whose pool-depth mark is zero while claimable idle
 *         liquidity-premium senior shares are outstanding. Each market is deployed inside its test because the
 *         three tests need different parameterizations and seed shapes
 */
contract Test_TrancheViewEdges_Tranches is DayMarketTestBase {
    /// @dev Whole ST/JT vault shares seeded for the idle-premium tests. Coverage after seed: (100 + 30) x 0.2 / 30 = 0.8667 <= 1
    uint256 internal constant ST_SEED = 100e18;
    uint256 internal constant JT_SEED = 30e18;

    /// @dev The quote-only LT seed: 5 whole 6-decimal quote (5e6 wei) backs 5e18 BPT, keeping NAV-per-BPT at exactly 1.0
    uint256 internal constant LT_SEED_BPT = 5e18;
    uint256 internal constant LT_SEED_QUOTE = 5e6;

    // =============================
    // Empty-tranche conversion views
    // =============================

    /**
     * @notice On a tranche with zero share supply, convertToAssets panics with a division-by-zero instead of
     *         reporting zero claims, while convertToShares on the identical state returns cleanly
     * @dev A share of an empty tranche is worth nothing, so a total conversion view should report zero claims for
     *      any input (the ERC-4626 convention integrators like lending oracles and yield wrappers rely on).
     *      Instead, scaling the tranche's claims by shares over a zero total supply divides by zero, so the view
     *      bricks on exactly the pre-bootstrap and fully-exited states where an integrator probes it. Expected
     *      behavior: return zero claims without reverting
     */
    function test_DIVERGENCE_24_ConvertToAssets_EmptyTrancheReturnsZeroClaims() public {
        // A freshly deployed, never-seeded market: every tranche has zero share supply
        _deployMarket(cellA(), defaultParams());
        assertEq(juniorTranche.totalSupply(), 0, "the fresh junior tranche must start with zero share supply");
        assertEq(liquidityTranche.totalSupply(), 0, "the fresh liquidity tranche must start with zero share supply");

        // FIXED: an empty tranche's claim scale short-circuits on zero total supply and returns zero claims instead
        // of dividing by zero, so both the zero-share and the whole-share probes return zero-valued claims.
        assertEq(toUint256(juniorTranche.convertToAssets(0).nav), 0, "empty JT convertToAssets(0) returns zero NAV");
        assertEq(toUint256(juniorTranche.convertToAssets(1e18).nav), 0, "empty JT convertToAssets(1e18) returns zero NAV");
        assertEq(toUint256(liquidityTranche.convertToAssets(0).nav), 0, "empty LT convertToAssets(0) returns zero NAV");
        assertEq(toUint256(liquidityTranche.convertToAssets(1e18).nav), 0, "empty LT convertToAssets(1e18) returns zero NAV");

        // The asymmetry pin: convertToShares on the IDENTICAL empty state does not revert, because the
        // shares-from-value conversion special-cases zero supply as a 1:1 bootstrap mint. Independent derivation:
        // 1e18 vault shares at the 1.0 vault rate and the 1.0 feed answer are worth exactly 1e18 NAV, and an empty
        // tranche's first mint is 1:1 with value, so the quote is exactly 1e18 shares
        assertEq(juniorTranche.convertToShares(toTrancheUnits(1e18)), 1e18, "the empty junior tranche must quote the 1:1 bootstrap mint without reverting");
        // The pool's genesis seed pins NAV-per-BPT at exactly 1.0, so 1e18 BPT is worth 1e18 NAV and mints 1:1
        assertEq(liquidityTranche.convertToShares(toTrancheUnits(1e18)), 1e18, "the empty liquidity tranche must quote the 1:1 bootstrap mint without reverting");
    }

    // =============================
    // LT maxRedeem against idle premium senior shares
    // =============================

    /**
     * @notice When the LT's pool-depth mark is zero but claimable idle liquidity-premium senior shares are
     *         outstanding, maxRedeem reports zero while the same holder can redeem its FULL balance through the
     *         multi-asset exit and is paid its pro-rata slice of the idle senior shares
     * @dev The idle premium is a claimable leg of the LT's effective NAV: a redeemer must receive its slice even
     *      when the pooled depth marks worthless, otherwise the premium would be stranded. The multi-asset
     *      redemption honors that, but maxRedeem keys the LT's claims on the pool-depth mark alone, so it returns
     *      0 whenever the BPT marks zero and underreports the true maximum. Expected behavior: maxRedeem reports
     *      the largest amount a redemption accepts, here the full balance
     */
    function test_DIVERGENCE_25_LTMaxRedeem_ReportsZeroOnIdleOnlyNAVWhileFullBalanceRedeems() public {
        _deployZeroMinLiquidityMarketWithPremium();
        uint256 idleShares = _accrueIdlePremiumSeniorShares();

        // Mark the entire pool worthless through the oracle: the LT's raw NAV (its pool-depth mark) reads zero
        // while the idle senior shares remain a live, claimable leg of the LT's effective NAV
        bptOracle.setTVL(0);
        bptOracle.setMode(MockBPTOracle.Mode.MANUAL);

        // The view underreport: with the pool depth marking zero, maxRedeem claims nothing is redeemable
        assertEq(liquidityTranche.maxRedeem(LT_PROVIDER), 0, "maxRedeem must currently report zero when the pool-depth mark is zero");

        // Hand-compute the redeemer's idle slice from the pre-redeem ledgers: a full-balance redemption pays
        // floor(balance x idleShares / totalSupply) senior shares (the LT protocol fee shares minted at the accrual
        // sync keep totalSupply strictly above the holder's balance, so the slice floors below the whole pile)
        uint256 balance = liquidityTranche.balanceOf(LT_PROVIDER);
        uint256 totalSupply = liquidityTranche.totalSupply();
        uint256 expectedIdleSlice = Math.mulDiv(balance, idleShares, totalSupply, Math.Rounding.Floor);
        assertGt(expectedIdleSlice, 0, "the redeemer's idle senior share slice must be nonzero for the underreport to matter");
        assertLt(balance, totalSupply, "fee shares must hold the redeemer's balance strictly below the total supply");

        // The in-kind path cannot disprove maxRedeem here: handing the idle senior shares over in kind moves no
        // raw NAV anywhere (share ownership only changes hands and the BPT leg marks zero), so the accountant's
        // redemption shape check sees a redemption that withdrew nothing and rejects it with INVALID_POST_OP_STATE.
        // The revert is captured with a low-level call rather than vm.expectRevert because the in-kind redeem's
        // pre-op sync retries the still-slipping premium reinvestment, whose internally-caught BptAmountOutBelowMin
        // revert would otherwise be mistaken by the cheatcode for the expected top-level revert
        vm.prank(LT_PROVIDER);
        (bool inKindSucceeded, bytes memory inKindReturn) =
            address(liquidityTranche).call(abi.encodeWithSelector(liquidityTranche.redeem.selector, balance, LT_PROVIDER, LT_PROVIDER));
        assertFalse(inKindSucceeded, "the in-kind redemption must revert when only the idle senior-share leg is claimable");
        assertEq(
            inKindReturn,
            abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_REDEEM),
            "the in-kind redemption must revert with the LT_REDEEM post-op shape violation"
        );

        // Pre-redeem senior ledgers for the multi-asset exit: the idle slice is redeemed against the senior
        // tranche's pool of yield-bearing vault shares
        uint256 stSupplyBefore = seniorTranche.totalSupply();
        uint256 stOwnedBefore = toUint256(kernel.getState().stOwnedYieldBearingAssets);
        uint256 vaultSharesBefore = stJtVault.balanceOf(LT_PROVIDER);

        // The SAME holder maxRedeem just zeroed redeems its FULL balance through the multi-asset exit: the idle
        // senior-share slice is redeemed (burned) for the senior tranche's yield-bearing asset, which moves senior
        // raw NAV and satisfies the shape check the in-kind path failed
        vm.prank(LT_PROVIDER);
        (AssetClaims memory stClaims, uint256 quoteAssets) = liquidityTranche.redeemMultiAsset(balance, 0, 0, LT_PROVIDER, LT_PROVIDER);

        // Exactly the hand-computed idle senior-share slice was redeemed: the senior supply and the kernel's idle
        // pile both drop by floor(balance x idleShares / totalSupply), so no premium is stranded on the exit
        assertEq(stSupplyBefore - seniorTranche.totalSupply(), expectedIdleSlice, "the redemption must burn exactly the pro-rata idle senior share slice");
        assertEq(kernel.getState().ltOwnedSeniorTrancheShares, idleShares - expectedIdleSlice, "the kernel's idle pile must drop by exactly the redeemed slice");
        assertEq(liquidityTranche.balanceOf(LT_PROVIDER), 0, "the full balance must have been burned");

        // Nothing but the idle leg moved: the pool marks zero so no venue removal ran, no quote came back, and the
        // kernel's pooled BPT inventory is untouched
        assertEq(quoteAssets, 0, "no quote assets can come back while the pool-depth mark is zero");
        assertEq(bpt.balanceOf(LT_PROVIDER), 0, "the redeemer must receive no BPT against a zero pool-depth mark");
        assertEq(toUint256(kernel.getState().ltOwnedYieldBearingAssets), LT_SEED_BPT, "the kernel's pooled BPT inventory must be untouched");

        // The slice paid out as the ST yield-bearing asset, bounded from first principles rather than re-quoted:
        // a senior share can claim at most its raw pro-rata slice of the senior pool (part of the +10% gain was
        // paid away as risk and liquidity premiums, never more), so the payout is at most
        // floor(slice x stOwned / stSupply) vault shares. And at worst the ENTIRE gain was paid away, leaving each
        // share its pre-gain value: with the vault rate at 1.1 that floor is 10/11 of the raw slice, minus 2 wei
        // for the two floor conversions between vault shares and NAV
        uint256 received = stJtVault.balanceOf(LT_PROVIDER) - vaultSharesBefore;
        uint256 rawProRataSlice = Math.mulDiv(expectedIdleSlice, stOwnedBefore, stSupplyBefore, Math.Rounding.Floor);
        assertEq(received, toUint256(stClaims.stAssets), "the reported ST asset claim must equal the vault shares actually delivered");
        assertGt(received, 0, "the redeemed slice must pay out a nonzero amount of the senior yield-bearing asset");
        assertLe(received, rawProRataSlice, "no senior share can claim more than its raw pro-rata slice of the senior pool");
        assertGe(received + 2, Math.mulDiv(expectedIdleSlice * 10, stOwnedBefore, stSupplyBefore * 11, Math.Rounding.Floor), "even with the whole gain paid away as premiums, each share keeps its pre-gain value");
    }

    /**
     * @notice With both LT legs nonzero (pooled BPT depth plus idle premium senior shares) in a market with no
     *         minimum liquidity requirement, maxRedeem reports the full balance and redeeming exactly that
     *         balance pays a pro-rata slice of each leg
     * @dev This is the healthy-state contract maxRedeem must honor: with no liquidity floor to protect, nothing
     *      constrains an LT exit, so the largest redeemable amount is the holder's whole balance and the payout
     *      is proportional on both legs. Each slice is derived from the pre-redeem ledgers as
     *      floor(balance x leg / totalSupply), never from the redemption's own quote
     */
    function test_LTMaxRedeem_FullBalanceRedeemableWithIdlePremiumAndPoolDepth() public {
        _deployZeroMinLiquidityMarketWithPremium();
        uint256 idleShares = _accrueIdlePremiumSeniorShares();

        // Pre-redeem ledgers. The pool is quote-only (the senior gain lives in the vault rate, not the pool), so
        // its value never moved and NAV-per-BPT is still exactly 1.0: the pooled inventory is the seeded 5e18 BPT
        // and the BPT-to-NAV round trip is wei-exact, making the ledger slice below exact rather than approximate
        uint256 ownedBpt = toUint256(kernel.getState().ltOwnedYieldBearingAssets);
        assertEq(ownedBpt, LT_SEED_BPT, "the pooled inventory must be exactly the seeded BPT (the failed reinvestment deployed nothing)");
        uint256 balance = liquidityTranche.balanceOf(LT_PROVIDER);
        uint256 totalSupply = liquidityTranche.totalSupply();

        // With no minimum liquidity requirement there is no depth floor to protect, so the whole balance is redeemable
        assertEq(liquidityTranche.maxRedeem(LT_PROVIDER), balance, "maxRedeem must report the full balance when no liquidity floor constrains the exit");

        // Each payout leg is an independent pro-rata slice of the pre-redeem ledgers
        uint256 expectedBptSlice = Math.mulDiv(balance, ownedBpt, totalSupply, Math.Rounding.Floor);
        uint256 expectedIdleSlice = Math.mulDiv(balance, idleShares, totalSupply, Math.Rounding.Floor);
        assertGt(expectedBptSlice, 0, "the pooled BPT slice must be nonzero");
        assertGt(expectedIdleSlice, 0, "the idle senior share slice must be nonzero");

        // Redeeming exactly the reported maximum succeeds and pays both legs
        vm.prank(LT_PROVIDER);
        AssetClaims memory claims = liquidityTranche.redeem(balance, LT_PROVIDER, LT_PROVIDER);

        assertEq(toUint256(claims.ltAssets), expectedBptSlice, "the redemption must pay exactly the pro-rata pooled BPT slice");
        assertEq(claims.stShares, expectedIdleSlice, "the redemption must pay exactly the pro-rata idle senior share slice");
        assertEq(bpt.balanceOf(LT_PROVIDER), expectedBptSlice, "the redeemer must hold exactly its BPT slice");
        assertEq(seniorTranche.balanceOf(LT_PROVIDER), expectedIdleSlice, "the redeemer must hold exactly its idle senior share slice");
        assertEq(liquidityTranche.balanceOf(LT_PROVIDER), 0, "the full balance must have been burned");
        // The kernel's ledgers drop by exactly the paid slices, so the fee-share holders retain the remainders
        assertEq(toUint256(kernel.getState().ltOwnedYieldBearingAssets), ownedBpt - expectedBptSlice, "the pooled inventory must drop by exactly the BPT slice");
        assertEq(kernel.getState().ltOwnedSeniorTrancheShares, idleShares - expectedIdleSlice, "the idle pile must drop by exactly the senior share slice");
    }

    // =============================
    // Helpers
    // =============================

    /**
     * @dev Deploys a market with no minimum liquidity requirement but with the LT liquidity premium enabled, then
     *      seeds ST/JT and a quote-only LT depth. The zero minimum removes every liquidity gate on redemptions
     *      (utilization is defined as zero at a zero minimum), while the re-enabled premium lets a senior gain
     *      stage idle premium senior shares, the combination the maxRedeem edge cases need
     */
    function _deployZeroMinLiquidityMarketWithPremium() internal {
        MarketParamsConfig memory p = zeroLiquidityParams();
        p.maxLTYieldShareWAD = 0.3e18;
        p.ltCurve = [uint64(0.02e18), uint64(0.1e18), uint64(0.3e18)];
        _deployMarket(cellA(), p);
        _seedMarket(ST_SEED, JT_SEED);
        // With no minimum liquidity the fixture never auto-seeds LT depth, so seed it explicitly: 5e18 BPT against
        // 5 whole quote (5e6 wei is worth 5e18 NAV at the 1.0 quote price), keeping NAV-per-BPT at exactly 1.0
        _seedLT(LT_SEED_BPT, 0, LT_SEED_QUOTE);
    }

    /**
     * @dev Accrues a nonzero idle liquidity premium: arms venue slippage so the +10% senior gain's premium mints as
     *      senior shares to the LT but the gated reinvestment defers, leaving ltOwnedSeniorTrancheShares nonzero.
     *      Slippage stays armed so a later operation's sync cannot deploy the pile mid-test. No further senior gain
     *      accrues after this sync, so subsequent pre-op syncs mint no new premium and attempt no reinvestment
     */
    function _accrueIdlePremiumSeniorShares() internal returns (uint256 idleShares) {
        setVenueSlippageMode(true);
        applySTPnL(1000);
        _sync();
        idleShares = kernel.getState().ltOwnedSeniorTrancheShares;
        assertTrue(idleShares != 0, "the gain must have left a nonzero idle liquidity premium senior share pile");
    }
}
