// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { MockBPTOracle } from "../../mocks/MockBPTOracle.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { MarketParamsConfig } from "../../utils/FixtureTypes.sol";
import { defaultParams, zeroLiquidityParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_TrancheViewEdges_Tranches
 * @notice Exercises the tranche conversion and max-redeem views on the degraded states integrators actually probe:
 *         a tranche with zero share supply, and an LPT whose pool-depth mark is zero while claimable idle
 *         liquidity-premium senior shares are outstanding. Each market is deployed inside its test because the
 *         three tests need different parameterizations and seed shapes
 */
contract Test_TrancheViewEdges_Tranches is DayMarketTestBase {
    /// @dev Whole ST/JT vault shares seeded for the idle-premium tests. Coverage after seed: (100 + 30) x 0.2 / 30 = 0.8667 <= 1
    uint256 internal constant ST_SEED = 100e18;
    uint256 internal constant JT_SEED = 30e18;

    /// @dev The quote-only LPT seed: 5 whole 6-decimal quote (5e6 wei) backs 5e18 BPT, keeping NAV-per-BPT at exactly 1.0
    uint256 internal constant LPT_SEED_BPT = 5e18;
    uint256 internal constant LPT_SEED_QUOTE = 5e6;

    // =============================
    // Empty-tranche conversion views
    // =============================

    /**
     * @notice On a tranche with zero share supply, convertToAssets reports zero claims for any input, while
     *         convertToShares on the identical state returns the 1:1 bootstrap quote
     * @dev A share of an empty tranche is worth nothing, so the total conversion view reports zero claims for any
     *      input (the ERC-4626 convention integrators like lending oracles and yield wrappers rely on): the claim
     *      scale short-circuits on zero total supply instead of dividing by zero. convertToShares special-cases
     *      the same empty state as a 1:1 bootstrap mint, so it returns value-for-value without reverting.
     */
    function test_ConvertToAssets_EmptyTrancheReturnsZeroClaims_ConvertToSharesBootstraps() public {
        // A freshly deployed, never-seeded market: every tranche has zero share supply
        _deployMarket(cellA(), defaultParams());
        assertEq(juniorTranche.totalSupply(), 0, "the fresh junior tranche must start with zero share supply");
        assertEq(liquidityProviderTranche.totalSupply(), 0, "the fresh liquidity provider tranche must start with zero share supply");

        // FIXED: an empty tranche's claim scale short-circuits on zero total supply and returns zero claims instead
        // of dividing by zero, so both the zero-share and the whole-share probes return zero-valued claims.
        assertEq(toUint256(juniorTranche.convertToAssets(0).nav), 0, "empty JT convertToAssets(0) returns zero NAV");
        assertEq(toUint256(juniorTranche.convertToAssets(1e18).nav), 0, "empty JT convertToAssets(1e18) returns zero NAV");
        assertEq(toUint256(liquidityProviderTranche.convertToAssets(0).nav), 0, "empty LPT convertToAssets(0) returns zero NAV");
        assertEq(toUint256(liquidityProviderTranche.convertToAssets(1e18).nav), 0, "empty LPT convertToAssets(1e18) returns zero NAV");

        // The asymmetry pin: convertToShares on the IDENTICAL empty state does not revert, because the
        // shares-from-value conversion special-cases zero supply as a 1:1 bootstrap mint. Independent derivation:
        // 1e18 vault shares at the 1.0 vault rate and the 1.0 feed answer are worth exactly 1e18 NAV, and an empty
        // tranche's first mint is 1:1 with value, so the quote is exactly 1e18 shares
        assertEq(juniorTranche.convertToShares(toTrancheUnits(1e18)), 1e18, "the empty junior tranche must quote the 1:1 bootstrap mint without reverting");
        // The pool's genesis seed pins NAV-per-BPT at exactly 1.0, so 1e18 BPT is worth 1e18 NAV and mints 1:1
        assertEq(
            liquidityProviderTranche.convertToShares(toTrancheUnits(1e18)), 1e18, "the empty liquidity provider tranche must quote the 1:1 bootstrap mint without reverting"
        );
    }

    // =============================
    // LPT maxRedeem against idle premium senior shares
    // =============================

    /**
     * @notice When the LPT's pool-depth mark is zero but claimable idle liquidity-premium senior shares are
     *         outstanding, maxRedeem reports zero while the holder is still paid its pro-rata slice of the idle
     *         senior shares on BOTH exit paths: in-kind hands the shares over directly, multi-asset burns them
     *         against the senior pool
     * @dev The idle premium is a claimable leg of the LPT's effective NAV, so it is never stranded. maxRedeem keys the
     *      LPT's claims on the pool-depth mark alone, so it returns 0 whenever the BPT marks zero and underreports the
     *      true maximum both redemption paths accept. The in-kind path moves no raw NAV (the shares stay in the senior
     *      supply), which the LPT_REDEEM shape check commits as a NAV-neutral redemption
     */
    function test_LPTMaxRedeem_UnderreportsZeroOnIdleOnlyNAV_WhileEitherPathDeliversIdlePremium() public {
        _deployZeroMinLiquidityMarketWithPremium();
        uint256 idleShares = _accrueIdlePremiumSeniorShares();

        // Mark the entire pool worthless through the oracle: the LPT's raw NAV (its pool-depth mark) reads zero
        // while the idle senior shares remain a live, claimable leg of the LPT's effective NAV
        bptOracle.setTVL(0);
        bptOracle.setMode(MockBPTOracle.Mode.MANUAL);

        // The view underreport: with the pool depth marking zero, maxRedeem claims nothing is redeemable
        assertEq(liquidityProviderTranche.maxRedeem(LPT_PROVIDER), 0, "maxRedeem must currently report zero when the pool-depth mark is zero");
        require(idleShares != 0, "setup: the idle premium pile must be nonzero");

        // The in-kind path delivers the idle premium: redeem half the balance and the pro-rata idle senior shares are
        // handed over directly. This moves no raw NAV anywhere (share ownership only changes hands and the BPT leg
        // marks zero), which the LPT_REDEEM shape check commits as a NAV-neutral redemption
        uint256 inKindShares = liquidityProviderTranche.balanceOf(LPT_PROVIDER) / 2;
        require(inKindShares != 0, "setup: the holder must have a splittable balance");
        uint256 idleBeforeInKind = kernel.getState().lptOwnedSeniorTrancheShares;
        uint256 supplyBeforeInKind = liquidityProviderTranche.totalSupply();
        // The claim scaler divides by the effective supply (totalSupply + 1e6 virtual shares), leaving a virtual-dust sliver behind
        uint256 expectedInKindSlice = Math.mulDiv(inKindShares, idleBeforeInKind, supplyBeforeInKind + 1e6, Math.Rounding.Floor);
        assertGt(expectedInKindSlice, 0, "the in-kind idle slice must be nonzero for the delivery to matter");

        vm.prank(LPT_PROVIDER);
        AssetClaims memory inKindClaims = liquidityProviderTranche.redeem(inKindShares, LPT_PROVIDER, LPT_PROVIDER);

        // Exactly the pro-rata idle senior shares are handed over in kind and nothing else: the wiped BPT leg pays
        // nothing, the redeemer receives the shares directly, and the kernel's idle pile drops by exactly that slice
        assertEq(inKindClaims.stShares, expectedInKindSlice, "the in-kind redeem must pay exactly the pro-rata idle senior share slice");
        assertEq(toUint256(inKindClaims.lptAssets), 0, "the wiped BPT leg must pay nothing in kind");
        assertEq(seniorTranche.balanceOf(LPT_PROVIDER), expectedInKindSlice, "the redeemer must receive exactly its idle senior share slice in kind");
        assertEq(
            kernel.getState().lptOwnedSeniorTrancheShares,
            idleBeforeInKind - expectedInKindSlice,
            "the kernel's idle pile must drop by exactly the in-kind slice"
        );
        assertEq(bpt.balanceOf(LPT_PROVIDER), 0, "no BPT can be delivered against a zero pool-depth mark");

        // The multi-asset path delivers the remaining premium by burning it against the senior pool: the idle slice
        // is redeemed for the senior tranche's yield-bearing asset, which moves senior raw NAV
        uint256 remaining = liquidityProviderTranche.balanceOf(LPT_PROVIDER);
        uint256 idleBeforeMulti = kernel.getState().lptOwnedSeniorTrancheShares;
        uint256 supplyBeforeMulti = liquidityProviderTranche.totalSupply();
        uint256 expectedMultiSlice = Math.mulDiv(remaining, idleBeforeMulti, supplyBeforeMulti + 1e6, Math.Rounding.Floor);
        assertGt(expectedMultiSlice, 0, "the multi-asset idle slice must be nonzero");
        uint256 stSupplyBefore = seniorTranche.totalSupply();
        uint256 stEffBefore = toUint256(accountant.getState().lastSTEffectiveNAV);
        uint256 vaultSharesBefore = stJtVault.balanceOf(LPT_PROVIDER);

        vm.prank(LPT_PROVIDER);
        (AssetClaims memory stClaims, uint256 quoteAssets) = liquidityProviderTranche.redeemMultiAsset(remaining, 0, 0, LPT_PROVIDER, LPT_PROVIDER);

        // Exactly the pro-rata idle senior-share slice was burned: the senior supply and the kernel's idle pile both
        // drop by it, so no premium is stranded on the exit
        assertEq(
            stSupplyBefore - seniorTranche.totalSupply(), expectedMultiSlice, "the multi-asset redeem must burn exactly the pro-rata idle senior share slice"
        );
        assertEq(
            kernel.getState().lptOwnedSeniorTrancheShares, idleBeforeMulti - expectedMultiSlice, "the kernel's idle pile must drop by exactly the burned slice"
        );
        assertEq(liquidityProviderTranche.balanceOf(LPT_PROVIDER), 0, "the remaining balance must have been burned");

        // Nothing but the idle leg moved: the pool marks zero so no venue removal ran, no quote came back, and the
        // kernel's pooled BPT inventory is untouched across both redemptions
        assertEq(quoteAssets, 0, "no quote assets can come back while the pool-depth mark is zero");
        assertEq(bpt.balanceOf(LPT_PROVIDER), 0, "the redeemer must receive no BPT against a zero pool-depth mark");
        assertEq(toUint256(kernel.getState().totalLPTAssets), LPT_SEED_BPT, "the kernel's pooled BPT inventory must be untouched");

        // The multi-asset slice paid out as the collateral vault share, bounded from the committed checkpoint rather
        // than re-quoted: a senior share can claim at most its pro-rata slice of the senior effective NAV converted
        // once to collateral. The bound is un-offset (denominator stSupply, not stSupply + 1e6) so the actual
        // offset-diluted payout sits at or below it
        uint256 received = stJtVault.balanceOf(LPT_PROVIDER) - vaultSharesBefore;
        uint256 effProRataSlice =
            toUint256(kernel.convertValueToCollateralAssets(toNAVUnits(Math.mulDiv(expectedMultiSlice, stEffBefore + 1, stSupplyBefore, Math.Rounding.Floor))));
        assertEq(received, toUint256(stClaims.collateralAssets), "the reported collateral claim must equal the vault shares actually delivered");
        assertGt(received, 0, "the redeemed slice must pay out a nonzero amount of the collateral vault share");
        assertLe(received, effProRataSlice, "no senior share can claim more than its pro-rata slice of the senior effective NAV");
    }

    /**
     * @notice With both LPT legs nonzero (pooled BPT depth plus idle premium senior shares) in a market with no
     *         minimum liquidity requirement, maxRedeem reports the full balance and redeeming exactly that
     *         balance pays a pro-rata slice of each leg
     * @dev This is the healthy-state contract maxRedeem must honor: with no liquidity floor to protect, nothing
     *      constrains an LPT exit, so the largest redeemable amount is the holder's whole balance and the payout
     *      is proportional on both legs. Each slice is derived from the pre-redeem ledgers as
     *      floor(balance x leg / (totalSupply + 1e6)), never from the redemption's own quote
     */
    function test_LPTMaxRedeem_FullBalanceRedeemableWithIdlePremiumAndPoolDepth() public {
        _deployZeroMinLiquidityMarketWithPremium();
        uint256 idleShares = _accrueIdlePremiumSeniorShares();

        // Pre-redeem ledgers. The pool is quote-only (the senior gain lives in the vault rate, not the pool), so
        // its value never moved and NAV-per-BPT is still exactly 1.0: the pooled inventory is the seeded 5e18 BPT
        // and the BPT-to-NAV round trip is wei-exact, making the ledger slice below exact rather than approximate
        uint256 ownedBpt = toUint256(kernel.getState().totalLPTAssets);
        assertEq(ownedBpt, LPT_SEED_BPT, "the pooled inventory must be exactly the seeded BPT (the failed reinvestment deployed nothing)");
        uint256 balance = liquidityProviderTranche.balanceOf(LPT_PROVIDER);
        uint256 totalSupply = liquidityProviderTranche.totalSupply();

        // With no minimum liquidity requirement there is no depth floor to protect, so the whole balance is redeemable
        assertEq(liquidityProviderTranche.maxRedeem(LPT_PROVIDER), balance, "maxRedeem must report the full balance when no liquidity floor constrains the exit");

        // Each payout leg is an independent pro-rata slice of the pre-redeem ledgers, scaled by the effective
        // supply (totalSupply + 1e6 virtual shares) the claim scaler now carries
        uint256 expectedBptSlice = Math.mulDiv(balance, ownedBpt, totalSupply + 1e6, Math.Rounding.Floor);
        uint256 expectedIdleSlice = Math.mulDiv(balance, idleShares, totalSupply + 1e6, Math.Rounding.Floor);
        assertGt(expectedBptSlice, 0, "the pooled BPT slice must be nonzero");
        assertGt(expectedIdleSlice, 0, "the idle senior share slice must be nonzero");

        // Redeeming exactly the reported maximum succeeds and pays both legs
        vm.prank(LPT_PROVIDER);
        AssetClaims memory claims = liquidityProviderTranche.redeem(balance, LPT_PROVIDER, LPT_PROVIDER);

        assertEq(toUint256(claims.lptAssets), expectedBptSlice, "the redemption must pay exactly the pro-rata pooled BPT slice");
        assertEq(claims.stShares, expectedIdleSlice, "the redemption must pay exactly the pro-rata idle senior share slice");
        assertEq(bpt.balanceOf(LPT_PROVIDER), expectedBptSlice, "the redeemer must hold exactly its BPT slice");
        assertEq(seniorTranche.balanceOf(LPT_PROVIDER), expectedIdleSlice, "the redeemer must hold exactly its idle senior share slice");
        assertEq(liquidityProviderTranche.balanceOf(LPT_PROVIDER), 0, "the full balance must have been burned");
        // The kernel's ledgers drop by exactly the paid slices, so the fee-share holders retain the remainders
        assertEq(toUint256(kernel.getState().totalLPTAssets), ownedBpt - expectedBptSlice, "the pooled inventory must drop by exactly the BPT slice");
        assertEq(kernel.getState().lptOwnedSeniorTrancheShares, idleShares - expectedIdleSlice, "the idle pile must drop by exactly the senior share slice");
    }

    // =============================
    // Helpers
    // =============================

    /**
     * @dev Deploys a market with no minimum liquidity requirement but with the LPT liquidity premium enabled, then
     *      seeds ST/JT and a quote-only LPT depth. The zero minimum removes every liquidity gate on redemptions
     *      (utilization is defined as zero at a zero minimum), while the re-enabled premium lets a senior gain
     *      stage idle premium senior shares, the combination the maxRedeem edge cases need
     */
    function _deployZeroMinLiquidityMarketWithPremium() internal {
        MarketParamsConfig memory p = zeroLiquidityParams();
        p.maxLPTYieldShareWAD = 0.3e18;
        p.lptCurve = [uint64(0.02e18), uint64(0.1e18), uint64(0.3e18)];
        _deployMarket(cellA(), p);
        _seedMarket(ST_SEED, JT_SEED);
        // With no minimum liquidity the fixture never auto-seeds LPT depth, so seed it explicitly: 5e18 BPT against
        // 5 whole quote (5e6 wei is worth 5e18 NAV at the 1.0 quote price), keeping NAV-per-BPT at exactly 1.0
        _seedLPT(LPT_SEED_BPT, 0, LPT_SEED_QUOTE);
    }

    /**
     * @dev Accrues a nonzero idle liquidity premium: arms venue slippage so the +10% senior gain's premium mints as
     *      senior shares to the LPT but the gated reinvestment defers, leaving lptOwnedSeniorTrancheShares nonzero.
     *      Slippage stays armed so a later operation's sync cannot deploy the pile mid-test. No further senior gain
     *      accrues after this sync, so subsequent pre-op syncs mint no new premium and attempt no reinvestment
     */
    function _accrueIdlePremiumSeniorShares() internal returns (uint256 idleShares) {
        setVenueSlippageMode(true);
        applySTPnL(1000);
        _sync();
        idleShares = kernel.getState().lptOwnedSeniorTrancheShares;
        assertTrue(idleShares != 0, "the gain must have left a nonzero idle liquidity premium senior share pile");
    }
}
