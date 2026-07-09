// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { stdError } from "../../../lib/forge-std/src/StdError.sol";
import { PausableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { MAX_MINT_DILUTION_WAD, WAD } from "../../../src/libraries/Constants.sol";
import { AssetClaims, MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { ValuationLogic } from "../../../src/libraries/logic/ValuationLogic.sol";
import { MockBPTOracle } from "../../mocks/MockBPTOracle.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_EntrypointGateAndConversionEdges
 * @notice Kernel-layer entrypoint gating and conversion edge behaviors on the 18-decimal ERC4626 ST/JT vault,
 *         6-decimal quote market with defaultParams
 * @dev Each test constructs the relevant market state and asserts the resulting behavior of the deposit,
 *      redemption, admin-setter, and conversion entrypoints
 */
contract Test_EntrypointGateAndConversionEdges is DayMarketTestBase {
    // =============================
    // Seed Constants (whole tokens, 18-decimal ERC4626 ST/JT shares, 6-decimal quote)
    // =============================

    /// @dev Whole ST/JT vault shares seeded. Coverage after seed: (100 + 30) x 0.2 / 30 = 0.8667 <= 1, gate clears
    uint256 internal constant ST_SEED_WHOLE = 100;
    uint256 internal constant JT_SEED_WHOLE = 30;

    /**
     * @dev Spec-derived auto-seeded LT depth (DayMarketTestBase._ensureLiquidityCapacityForSTDeposit):
     *      required ltRawNAV = ceil(100e18 x 0.05) = 5e18, quote leg = 5 whole + 1 cushion = 6 whole quote,
     *      BPT minted 1:1 with the 18-decimal NAV added, so the kernel-owned mark is exactly 6e18 at the 1.0
     *      default venue prices (the market base's genesis initializer backs the pool's dead minimum supply, so
     *      NAV-per-BPT is exactly 1.0 and every derivation below is wei-exact)
     */
    uint256 internal constant SEEDED_LT_RAW_NAV = 6e18;

    /// @dev One whole ST/JT vault share in tranche units (this market's shares are 18-decimal)
    uint256 internal stUnit;

    /// @dev One whole quote token (this market's quote is 6-decimal)
    uint256 internal quoteUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.stAsset.decimals);
        quoteUnit = 10 ** uint256(cell.quoteAsset.decimals);
    }

    // =============================
    // ST deposits are liquidity-gated
    // =============================

    /**
     * @notice An ST deposit into an under-provisioned market reverts LIQUIDITY_REQUIREMENT_VIOLATED: each market
     *         sets a minimum percentage of liquidity required for senior tranche deposits, and Operation.ST_DEPOSIT
     *         is in the post-op liquidity requirement check (RoycoDayAccountant.sol:332-334), so the deposit is
     *         blocked until LT depth is restored
     * @dev Breach derivation: seeded stEffectiveNAV = 100e18 and auto-seeded ltRawNAV = 6e18, then a -20% LT
     *      venue mark (applyLTPnL scales both pool-token oracle prices by 0.8) gives ltRawNAV = 4.8e18 exactly, so
     *      liquidityUtilizationWAD = ceil(100e18 x 0.05e18 / 4.8e18) = 1041666666666666667 > WAD while the market
     *      stays PERPETUAL (liquidity breaches never move the state machine). The 1-share deposit would leave
     *      ceil(101e18 x 0.05e18 / 4.8e18) = 1052083333333333334 > WAD, and its coverage gate passes at
     *      ceil(131e18 x 0.2e18 / 30e18) = 873333333333333334 <= WAD, so the liquidity gate is what fires
     */
    function test_stDeposit_revertsLiquidityRequirementViolated_whenLTUnderProvisioned() public {
        _seedMarket(ST_SEED_WHOLE * stUnit, JT_SEED_WHOLE * stUnit);
        applyLTPnL(-2000);

        // Commit the breached pre-deposit state so it is unambiguous (the sync return is authoritative)
        SyncedAccountingState memory pre = _sync();
        assertEq(toUint256(pre.ltRawNAV), 4.8e18, "ltRawNAV must be the 6e18 auto-seed marked down 20%");
        assertEq(pre.liquidityUtilizationWAD, 1_041_666_666_666_666_667, "liquidityUtilizationWAD must be ceil(100e18 x 0.05e18 / 4.8e18)");
        assertGt(pre.liquidityUtilizationWAD, WAD, "the liquidity requirement must read breached before the deposit");
        assertEq(uint8(pre.marketState), uint8(MarketState.PERPETUAL), "a liquidity breach must not move the state machine");

        // The senior deposit is blocked on liquidity
        stJtVault.mintShares(ST_PROVIDER, stUnit);
        vm.startPrank(ST_PROVIDER);
        stJtVault.approve(address(seniorTranche), stUnit);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        seniorTranche.deposit(toTrancheUnits(stUnit), ST_PROVIDER);
        vm.stopPrank();
    }

    // =============================
    // JT redemption stays coverage-gated after the liquidation threshold is breached, while LT redemption bypasses it
    // =============================

    /**
     * @notice Once the liquidation coverage utilization is breached (forced PERPETUAL), a JT redemption reverts
     *         COVERAGE_REQUIREMENT_VIOLATED while an LT redemption in the same state succeeds through the
     *         liquidation bypass
     * @dev The liquidation bypass is given only to LT redemptions (RedemptionLogic.sol:145,216 pass
     *      enforce = coverage utilization < liquidation threshold) while jtRedeem passes enforce = true
     *      unconditionally (RedemptionLogic.sol:105), so the accountant's JT_REDEEM coverage gate
     *      (RoycoDayAccountant.sol:327-329) fires in the wind-down state while the LT gate is released
     * @dev Breach derivation (shared -21% rate on the seeded 100/30 market): stRawNAV = 79e18, jtRawNAV = 23.7e18,
     *      the 21e18 ST loss is fully covered so stEffectiveNAV = 100e18 and jtEffectiveNAV = 30e18 - 6.3e18 -
     *      21e18 = 2.7e18, coverageUtilizationWAD = ceil((79e18 + 23.7e18) x 0.2e18 / 2.7e18) =
     *      7607407407407407408 >= 6.4667e18, which takes the forced-PERPETUAL liquidation branch
     *      (RoycoDayAccountant.sol:666-678) and erases the coverage IL
     * @dev LT contrast derivation: redeeming 3e18 of the 6e18 LT shares pays exactly the 3e18 BPT slice and
     *      leaves ltRawNAV = 3e18, and the post-op liquidityUtilizationWAD would be ceil(100e18 x 0.05e18 / 3e18)
     *      = 1666666666666666667 > WAD — the liquidity gate WOULD have fired, so its success proves the
     *      liquidation bypass exists for LT and is withheld from JT
     */
    function test_jtRedeem_coverageGated_whileLtRedeem_bypasses_duringLiquidation() public {
        _seedMarket(ST_SEED_WHOLE * stUnit, JT_SEED_WHOLE * stUnit);
        applySTPnL(-2100);

        // Commit the liquidation breach: forced PERPETUAL with the coverage IL erased
        SyncedAccountingState memory pre = _sync();
        assertEq(toUint256(pre.stRawNAV), 79e18, "stRawNAV must be 100 whole shares x 0.79 x 1.0");
        assertEq(toUint256(pre.jtRawNAV), 23.7e18, "jtRawNAV must be 30 whole shares x 0.79 x 1.0");
        assertEq(toUint256(pre.jtEffectiveNAV), 2.7e18, "jtEffectiveNAV must be 30e18 - 6.3e18 own loss - 21e18 coverage");
        assertEq(pre.coverageUtilizationWAD, 7_607_407_407_407_407_408, "coverageUtilizationWAD must be ceil(102.7e18 x 0.2e18 / 2.7e18)");
        assertGe(pre.coverageUtilizationWAD, pre.coverageLiquidationUtilizationWAD, "the liquidation threshold must be breached");
        assertEq(uint8(pre.marketState), uint8(MarketState.PERPETUAL), "a liquidation breach must force PERPETUAL");
        assertEq(toUint256(pre.jtCoverageImpermanentLoss), 0, "the liquidation branch must erase the coverage IL");

        // The JT redemption is coverage-gated during liquidation
        uint256 jtShares = juniorTranche.balanceOf(JT_PROVIDER) / 10;
        vm.prank(JT_PROVIDER);
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        juniorTranche.redeem(jtShares, JT_PROVIDER, JT_PROVIDER);

        // The LT redemption in the identical state succeeds through its liquidation bypass (the asymmetry pin):
        // 3e18 of 6e18 LT shares pays 3e18 BPT even though the post-op liquidity gate would read breached
        uint256 ltShares = 3e18;
        vm.prank(LT_PROVIDER);
        AssetClaims memory ltClaims = liquidityTranche.redeem(ltShares, LT_PROVIDER, LT_PROVIDER);
        assertEq(toUint256(ltClaims.ltAssets), 3e18, "LT redeem must pay the proportional 3e18 BPT slice");
        assertEq(bpt.balanceOf(LT_PROVIDER), 3e18, "the BPT payout must land on the LT redeemer");
        assertEq(toUint256(accountant.getState().lastLTRawNAV), 3e18, "ltRawNAV must drop below the 5e18 liquidity floor");
    }

    // =============================
    // Every accountant parameter setter reverts while the kernel is paused
    // =============================

    /**
     * @notice Pausing the kernel makes every accountant parameter setter revert EnforcedPause, because each
     *         setter's withSyncedAccounting modifier (RoycoDayAccountant.sol:42-45) calls the kernel's
     *         whenNotPaused syncTrancheAccounting (RoycoDayKernel.sol:309-320), which reverts while paused
     * @dev During a pause the three admin roles cannot adjust fees, coverage, liquidity, the liquidation
     *      threshold, term duration, or dust tolerances (only the two YDM swap setters survive, via a tolerated
     *      raw call). Unpausing the kernel is the remediation, after which the same call lands
     */
    function test_accountantSetters_revertEnforcedPause_whileKernelPaused() public {
        _seedMarket(ST_SEED_WHOLE * stUnit, JT_SEED_WHOLE * stUnit);

        vm.prank(PAUSER);
        kernel.pause();

        // ACCOUNTANT_ADMIN surface (setMinCoverage stands in for the seven ADMIN_ACCOUNTANT_ROLE setters)
        vm.prank(ACCOUNTANT_ADMIN);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        accountant.setMinCoverage(0.1e18);

        // PROTOCOL_FEE_SETTER surface (the four protocol fee setters)
        vm.prank(PROTOCOL_FEE_SETTER);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        accountant.setSeniorTrancheProtocolFee(0);

        // MARKET_OPS_ADMIN surface (the two dust tolerance setters)
        vm.prank(MARKET_OPS_ADMIN);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        accountant.setSeniorTrancheDustTolerance(toNAVUnits(uint256(1)));

        // Control: unpausing the kernel is the only remediation, after which the same call lands
        vm.prank(UNPAUSER);
        kernel.unpause();
        vm.prank(ACCOUNTANT_ADMIN);
        accountant.setMinCoverage(0.1e18);
        assertEq(uint256(accountant.getState().minCoverageWAD), 0.1e18, "the setter must succeed once the kernel is unpaused");
    }

    // =============================
    // The mint-dilution clamp's cap computation overflow boundary
    // =============================

    /// @dev External probe so the cliff's Panic(0x11) is observable through expectRevert
    function convertToSharesCliffProbe(uint256 _value, uint256 _totalValue, uint256 _supply) external pure returns (uint256) {
        return ValuationLogic._convertToShares(toNAVUnits(_value), toNAVUnits(_totalValue), _supply, Math.Rounding.Floor);
    }

    /**
     * @notice The mint-dilution clamp (MAX_MINT_DILUTION_WAD = WAD - 1e6) bounds the zero-NAV dilution mint per
     *         cycle, but with no absolute supply ceiling the cap computation
     *         floor(supply x MAX_MINT_DILUTION_WAD / (WAD - MAX_MINT_DILUTION_WAD)) itself overflows uint256 once
     *         supply > floor((2^256 - 1) x (WAD - MAX_MINT_DILUTION_WAD) / MAX_MINT_DILUTION_WAD), so repeated
     *         total-wipe dilution cycles (each growing the supply by up to
     *         xMAX_MINT_DILUTION_WAD/(WAD - MAX_MINT_DILUTION_WAD) ~ 1e12) terminate in a Panic(0x11) after
     *         ~4 cycles, including inside the sync's fee mint
     * @dev The boundary supply floor((2^256 - 1)/k) succeeds and one share-wei past it panics
     *      (k = MAX_MINT_DILUTION_WAD/(WAD - MAX_MINT_DILUTION_WAD) = 1e12 - 1 exactly, so the cap multiply is
     *      exact and the floor identity max - S_ok x k < k gives the crisp +1 boundary)
     */
    function test_mintDilutionClamp_capComputationOverflowBoundary() public {
        uint256 k = MAX_MINT_DILUTION_WAD / (WAD - MAX_MINT_DILUTION_WAD); // 1e12 - 1, exact division
        uint256 supplyAtCliff = type(uint256).max / k; // the largest supply whose cap still fits in uint256
        uint256 bindingValue = 1e18; // over a 1-wei denominator this always binds: ceil(1e18 x 1e6 / (1e18 - 1e6)) > 1

        // Just below the cliff the clamped mint succeeds and returns the exact cap
        uint256 minted = this.convertToSharesCliffProbe(bindingValue, 0, supplyAtCliff);
        assertEq(minted, Math.mulDiv(supplyAtCliff, MAX_MINT_DILUTION_WAD, WAD - MAX_MINT_DILUTION_WAD), "at the boundary the cap still fits");

        // One share-wei past the cliff the cap computation overflows uint256 and the mint panics
        vm.expectRevert(stdError.arithmeticError);
        this.convertToSharesCliffProbe(bindingValue, 0, supplyAtCliff + 1);
    }

    // =============================
    // The multi-asset LT redemption skips the caller's slippage floors when the venue slice is zero
    // =============================

    /**
     * @notice `redeemMultiAsset(shares, _minSTSharesOut, _minQuoteAssetsOut, ...)` enforces the caller's minimums
     *         only through the proportional venue removal, which is skipped whenever the redeemer's venue-asset
     *         slice is zero (RedemptionLogic.sol:181-185 guards removeLiquidity behind
     *         `userAssetClaims.ltAssets != 0`). In the idle-only LT state the call therefore succeeds while
     *         returning 0 quote assets against a positive `_minQuoteAssetsOut`, and no funds are lost because the
     *         fair idle premium slice is still paid
     * @dev Idle-only construction: venue slippage is armed so a +10% senior gain's liquidity premium mints as
     *      senior shares to the LT but the gated reinvestment defers, staging the premium idle in the kernel.
     *      Then the BPT oracle is pinned to a zero mark (a worthless pool), so ltRawNAV = 0 and every redeemer's
     *      venue-asset slice is exactly zero: the LT share's only remaining value is the idle premium leg.
     *      Governance retires the liquidity requirement first (setMinLiquidity(0)) so the post-redemption
     *      liquidity gate cannot mask the missing slippage check — with a positive minimum and zero pool depth
     *      every LT redemption would revert LIQUIDITY_REQUIREMENT_VIOLATED instead
     * @dev Idle pile derivation (+10% on the seeded 100/30 market, same block so the instantaneous yield shares
     *      apply): stRaw 100e18 -> 110e18 gives stGain = 10e18; JT risk premium = 10e18 x 0.2 = 2e18 and LT
     *      liquidity premium = 10e18 x 0.1 = 1e18 (the fixture's pinned yield shares); ST protocol fee =
     *      (10 - 2 - 1)e18 x 0.1 = 0.7e18; stEffectiveNAV = 100e18 + 7e18 + 1e18 = 108e18. The premium mints
     *      against the retained senior NAV 108e18 - 1e18 - 0.7e18 = 106.3e18 over the 100e18 pre-sync supply:
     *      idleShares = floor(100e18 x 1e18 / 106.3e18) = 940733772342427093. The ST fee mint is
     *      floor(100e18 x 0.7e18 / 106.3e18) = 658513640639698965, so the senior supply lands at
     *      101599247412982126058
     * @dev Redemption slice derivation: the gain sync also mints LT protocol fee shares — the 0.1e18 LT fee is
     *      priced on the LT effective NAV 6e18 + floor(940733772342427093 x 108e18 / 101599247412982126058) =
     *      6e18 + 999999999999999999, so ltFeeShares = floor(6e18 x 0.1e18 / 6899999999999999999) =
     *      86956521739130434 and the LT supply is 6086956521739130434. Redeeming the provider's full 6e18 shares
     *      takes the pro-rata idle slice floor(940733772342427093 x 6e18 / 6086956521739130434) =
     *      927294718451820991 senior shares, unwound to the yield-bearing asset: the total senior claim is
     *      floor(108e18 / 1.1) = 98181818181818181818 vault shares, so the redeemer receives
     *      floor(98181818181818181818 x 927294718451820991 / 101599247412982126058) = 896103896103896103
     */
    function test_ltRedeemMultiAsset_zeroVenueSlice_skipsSlippageFloorsAndPaysIdlePremium() public {
        _seedMarket(ST_SEED_WHOLE * stUnit, JT_SEED_WHOLE * stUnit);

        // Stage the idle premium: armed venue slippage defers the gated reinvestment, so the +10% gain's premium
        // stays as kernel-held senior shares instead of deploying into the pool
        setVenueSlippageMode(true);
        applySTPnL(1000);
        _sync();
        uint256 idleShares = kernel.getState().ltOwnedSeniorTrancheShares;
        assertEq(idleShares, 940_733_772_342_427_093, "the staged premium must be floor(100e18 x 1e18 / 106.3e18) senior shares");

        // Retire the liquidity requirement so the redemption reaches the missing slippage check instead of the
        // post-op liquidity gate (with zero pool depth and a positive minimum, every LT redemption would revert
        // LIQUIDITY_REQUIREMENT_VIOLATED and the ignored minimum would be unobservable)
        vm.prank(ACCOUNTANT_ADMIN);
        accountant.setMinLiquidity(0);

        // Collapse the pool mark to zero (a worthless BPT): the LT's deployed depth is now worth nothing and the
        // idle premium senior shares are the LT share's only remaining value
        bptOracle.setMode(MockBPTOracle.Mode.MANUAL);
        bptOracle.setTVL(0);
        SyncedAccountingState memory pre = _sync();
        assertEq(toUint256(pre.ltRawNAV), 0, "the committed LT mark must read the pinned zero pool value");
        assertEq(uint8(pre.marketState), uint8(MarketState.PERPETUAL), "a collapsed pool mark must not move the state machine");

        // The provider still holds its full 6e18 seed shares; the gain sync's LT protocol fee shares went to the
        // fee recipient, growing the supply to 6e18 + 86956521739130434
        assertEq(liquidityTranche.balanceOf(LT_PROVIDER), 6e18, "the provider must still hold its full LT seed shares");
        assertEq(liquidityTranche.totalSupply(), 6_086_956_521_739_130_434, "the LT supply must be the 6e18 seed plus the gain sync's fee shares");

        // The redemption succeeds with quoteAssets = 0 against _minQuoteAssetsOut = 1 (and zero venue senior
        // shares against _minSTSharesOut = 1). Both floors sit inside the proportional venue removal, and a zero
        // venue-asset slice skips that removal entirely.
        vm.prank(LT_PROVIDER);
        (AssetClaims memory stClaims, uint256 quoteAssets) = liquidityTranche.redeemMultiAsset(6e18, 1, 1, LT_PROVIDER, LT_PROVIDER);

        // The caller's quote floor was violated by a successful call: 0 returned against a minimum of 1
        assertEq(quoteAssets, 0, "the redemption must return zero quote assets below the caller's 1-wei minimum");
        assertEq(quoteToken.balanceOf(LT_PROVIDER), 0, "no quote assets may reach the redeemer, its floor notwithstanding");
        assertEq(bpt.balanceOf(LT_PROVIDER), 0, "the worthless pool position pays out no BPT either");

        // The fair idle premium slice is still paid (no funds are lost, only the slippage floor is skipped):
        // the idle senior shares are unwound to the yield-bearing asset at the 1.1 rate
        assertEq(toUint256(stClaims.stAssets), 896_103_896_103_896_103, "the idle slice must unwind to its pro-rata vault shares");
        assertEq(toUint256(stClaims.jtAssets), 0, "a healthy market's senior claim has no junior-asset leg");
        assertEq(stJtVault.balanceOf(LT_PROVIDER), 896_103_896_103_896_103, "the unwound vault shares must land on the redeemer");

        // The shares are burned and the kernel state reflects a completed redemption: the idle pile drops by the
        // redeemed slice while the (worthless) pooled BPT never left kernel custody
        assertEq(liquidityTranche.balanceOf(LT_PROVIDER), 0, "the redeemed LT shares must be burned");
        assertEq(liquidityTranche.totalSupply(), 86_956_521_739_130_434, "only the fee recipient's LT shares may remain outstanding");
        assertEq(
            kernel.getState().ltOwnedSeniorTrancheShares,
            940_733_772_342_427_093 - 927_294_718_451_820_991,
            "the idle pile must drop by exactly the redeemed pro-rata slice"
        );
        assertEq(
            toUint256(kernel.getState().ltOwnedYieldBearingAssets),
            SEEDED_LT_RAW_NAV,
            "the pooled BPT must remain in kernel custody, untouched by the skipped removal"
        );
    }
}
