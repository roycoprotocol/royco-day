// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { stdError } from "../../../lib/forge-std/src/StdError.sol";
import { PausableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { MINT_DILUTION_RESIDUAL_WAD, WAD } from "../../../src/libraries/Constants.sol";
import { AssetClaims, MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { ValuationLogic } from "../../../src/libraries/logic/ValuationLogic.sol";
import { defaultParams } from "../../base/fixtures/MarketParams.sol";
import { cellA } from "../../base/fixtures/TokenConfigs.sol";
import { TrancheFixture } from "../../base/fixtures/TrancheFixture.sol";

/**
 * @title SpecDivergencesTest
 * @notice Loud, first-class pins of every known kernel-layer divergence between production and the CLAUDE.md
 *         product spec (docs/testing/agent-notes/13-spec-divergence-findings.md findings 4-7)
 * @dev Each test states the exact CLAUDE.md sentence it contradicts, constructs the divergent state on cell A
 *      with defaultParams, and asserts CURRENT production behavior with the spec-expected behavior documented in
 *      an adjacent comment. If a future src change makes production match the spec, the corresponding test here
 *      MUST fail — that is the alarm these pins exist to raise. CI stays green while the divergences stay loud
 */
contract SpecDivergencesTest is TrancheFixture {
    // =============================
    // Seed Constants (whole tokens, cell A: 4626(18,18) ST/JT shares, 6-decimal quote)
    // =============================

    /// @dev Whole ST/JT vault shares seeded. Coverage after seed: (100 + 30) x 0.2 / 30 = 0.8667 <= 1, gate clears
    uint256 internal constant ST_SEED_WHOLE = 100;
    uint256 internal constant JT_SEED_WHOLE = 30;

    /**
     * @dev Spec-derived auto-seeded LT depth (TrancheFixture._ensureLiquidityCapacityForSTDeposit):
     *      required ltRawNAV = ceil(100e18 x 0.05) = 5e18, quote leg = 5 whole + 1 cushion = 6 whole quote,
     *      BPT minted 1:1 with the 18-decimal NAV added, so the kernel-owned mark is exactly 6e18 at the 1.0
     *      default venue prices (the fixture's genesis initializer backs the pool's dead minimum supply, so
     *      NAV-per-BPT is exactly 1.0 and every derivation below is wei-exact)
     */
    uint256 internal constant SEEDED_LT_RAW_NAV = 6e18;

    /// @dev One whole ST/JT vault share in tranche units (cell A shares are 18-decimal)
    uint256 internal stUnit;

    /// @dev One whole quote token (cell A quote is 6-decimal)
    uint256 internal quoteUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.stAsset.decimals);
        quoteUnit = 10 ** uint256(cell.quoteAsset.decimals);
    }

    // =============================
    // FINDING 4 — ST deposits ARE liquidity-gated
    // =============================

    /**
     * @notice FINDING 4: an ST deposit into an under-provisioned market reverts LIQUIDITY_REQUIREMENT_VIOLATED,
     *         contradicting CLAUDE.md's "Deposits are enabled at all times" / "a senior deposit keeps its own
     *         coverage gate, so no deposit is ever blocked on liquidity" (the two-metrics section)
     * @dev CLAUDE.md contradicts itself: the canonical product-spec section (which CLAUDE.md says governs) states
     *      "Each market sets a minimum percentage of liquidity required for senior tranche deposits", and
     *      production follows that line — Operation.ST_DEPOSIT is in the post-op liquidity requirement check
     *      (RoycoDayAccountant.sol:332-334). SPEC-EXPECTED (two-metrics narrative): the deposit succeeds because
     *      liquidity never blocks a deposit. ACTUAL: it reverts until LT depth is restored
     * @dev Breach derivation: seeded stEff = 100e18 and auto-seeded ltRawNAV = 6e18, then a -20% LT venue mark
     *      (applyLTPnL scales both pool-token oracle prices by 0.8) gives ltRawNAV = 4.8e18 exactly, so
     *      liquidityUtilization = ceil(100e18 x 0.05e18 / 4.8e18) = 1041666666666666667 > WAD while the market
     *      stays PERPETUAL (liquidity breaches never move the state machine). The 1-share deposit would leave
     *      ceil(101e18 x 0.05e18 / 4.8e18) = 1052083333333333334 > WAD, and its coverage gate passes at
     *      ceil(131e18 x 0.2e18 / 30e18) = 873333333333333334 <= WAD, so the liquidity gate is what fires
     */
    function test_FINDING_4_stDeposit_isLiquidityGated_underProvisionedMarketBlocksSeniorEntry() public {
        _seedMarket(ST_SEED_WHOLE * stUnit, JT_SEED_WHOLE * stUnit);
        applyLTPnL(-2000);

        // Commit the breached pre-deposit state so it is unambiguous (the sync return is authoritative)
        SyncedAccountingState memory pre = _sync();
        assertEq(toUint256(pre.ltRawNAV), 4.8e18, "ltRawNAV must be the 6e18 auto-seed marked down 20%");
        assertEq(pre.liquidityUtilizationWAD, 1_041_666_666_666_666_667, "liqUtil must be ceil(100e18 x 0.05e18 / 4.8e18)");
        assertGt(pre.liquidityUtilizationWAD, WAD, "the liquidity requirement must read breached before the deposit");
        assertEq(uint8(pre.marketState), uint8(MarketState.PERPETUAL), "a liquidity breach must not move the state machine");

        // ACTUAL production behavior: the senior deposit is blocked on liquidity
        // SPEC-EXPECTED (CLAUDE.md two-metrics section): the deposit succeeds and mints ~1e18 ST shares
        stJtVault.mintShares(ST_PROVIDER, stUnit);
        vm.startPrank(ST_PROVIDER);
        stJtVault.approve(address(seniorTranche), stUnit);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        seniorTranche.deposit(toTrancheUnits(stUnit), ST_PROVIDER);
        vm.stopPrank();
    }

    // =============================
    // FINDING 5 — JT redemption stays coverage-gated after the liquidation threshold is breached
    // =============================

    /**
     * @notice FINDING 5: once the liquidation coverage utilization is breached (forced PERPETUAL), a JT
     *         redemption still reverts COVERAGE_REQUIREMENT_VIOLATED, contradicting CLAUDE.md's "unless the
     *         liquidation utilization has been breached, in which case all withdrawals are allowed"
     * @dev Production gives the liquidation bypass ONLY to LT redemptions (RedemptionLogic.sol:145,216 pass
     *      enforce = covUtil < liquidationThreshold) while jtRedeem passes enforce = true unconditionally
     *      (RedemptionLogic.sol:105), so the accountant's JT_REDEEM coverage gate
     *      (RoycoDayAccountant.sol:327-329) fires in exactly the wind-down state the spec exempts.
     *      SPEC-EXPECTED: the JT redemption succeeds (all withdrawals allowed during liquidation).
     *      ACTUAL: JT reverts while the LT redemption in the same state succeeds through its bypass
     * @dev Breach derivation (shared -21% rate on the seeded 100/30 market): stRaw = 79e18, jtRaw = 23.7e18,
     *      the 21e18 ST loss is fully covered so stEff = 100e18 and jtEff = 30e18 - 6.3e18 - 21e18 = 2.7e18,
     *      covUtil = ceil((79e18 + 23.7e18) x 0.2e18 / 2.7e18) = 7607407407407407408 >= 6.4667e18, which takes
     *      the forced-PERPETUAL liquidation branch (RoycoDayAccountant.sol:666-678) and erases the coverage IL
     * @dev LT contrast derivation: redeeming 3e18 of the 6e18 LT shares pays exactly the 3e18 BPT slice and
     *      leaves ltRawNAV = 3e18, and post-op liqUtil would be ceil(100e18 x 0.05e18 / 3e18) =
     *      1666666666666666667 > WAD — the liquidity gate WOULD have fired, so its success proves the
     *      liquidation bypass exists for LT and is withheld from JT
     */
    function test_FINDING_5_jtRedeem_staysCoverageGated_afterLiquidationBreach() public {
        _seedMarket(ST_SEED_WHOLE * stUnit, JT_SEED_WHOLE * stUnit);
        applySTPnL(-2100);

        // Commit the liquidation breach: forced PERPETUAL with the coverage IL erased
        SyncedAccountingState memory pre = _sync();
        assertEq(toUint256(pre.stRawNAV), 79e18, "stRawNAV must be 100 whole shares x 0.79 x 1.0");
        assertEq(toUint256(pre.jtRawNAV), 23.7e18, "jtRawNAV must be 30 whole shares x 0.79 x 1.0");
        assertEq(toUint256(pre.jtEffectiveNAV), 2.7e18, "jtEff must be 30e18 - 6.3e18 own loss - 21e18 coverage");
        assertEq(pre.coverageUtilizationWAD, 7_607_407_407_407_407_408, "covUtil must be ceil(102.7e18 x 0.2e18 / 2.7e18)");
        assertGe(pre.coverageUtilizationWAD, pre.coverageLiquidationUtilizationWAD, "the liquidation threshold must be breached");
        assertEq(uint8(pre.marketState), uint8(MarketState.PERPETUAL), "a liquidation breach must force PERPETUAL");
        assertEq(toUint256(pre.jtCoverageImpermanentLoss), 0, "the liquidation branch must erase the coverage IL");

        // ACTUAL production behavior: the JT redemption is still coverage-gated during liquidation
        // SPEC-EXPECTED (CLAUDE.md canonical spec): the redemption succeeds, all withdrawals are allowed
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
    // FINDING 6 — every accountant parameter setter reverts while the kernel is paused
    // =============================

    /**
     * @notice FINDING 6: pausing the kernel bricks every accountant parameter setter, because each setter's
     *         withSyncedAccounting modifier (RoycoDayAccountant.sol:42-45) calls the kernel's whenNotPaused
     *         syncTrancheAccounting (RoycoDayKernel.sol:309-320), which reverts EnforcedPause
     * @dev Divergence from the operational expectation that governance can remediate parameters during an
     *      emergency pause (testing-strategy.md Appendix B.8) — during a pause governance cannot adjust fees,
     *      coverage, liquidity, the liquidation threshold, term duration, or dust tolerances (only the two YDM
     *      swap setters survive, via a tolerated raw call). SPEC-EXPECTED (operational): the setters succeed,
     *      or at minimum a remediation path exists while paused. ACTUAL: EnforcedPause across all three admin
     *      roles' setter surfaces until the kernel is unpaused
     */
    function test_FINDING_6_accountantSetters_revertWhileKernelPaused() public {
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
    // FINDING 7 — intra-spec contradiction on FIXED_TERM deposits: production's actual matrix
    // =============================

    /**
     * @notice FINDING 7: CLAUDE.md contradicts itself on FIXED_TERM deposits — the capital-realism section says
     *         "In FIXED_TERM, deposits and redeems are disabled for every tranche" while the canonical spec
     *         section says "Deposits are enabled at all times". Production implements neither sentence:
     *         ST and JT deposits revert DISABLED_IN_FIXED_TERM_STATE, the in-kind LT deposit succeeds, the
     *         multi-asset LT deposit reverts with an ST leg and succeeds quote-only
     * @dev Production matrix pinned here (all five deposit entrypoints in FIXED_TERM):
     *      stDeposit           REVERTS DISABLED_IN_FIXED_TERM_STATE (DepositLogic.sol:226)
     *      jtDeposit           REVERTS DISABLED_IN_FIXED_TERM_STATE (DepositLogic.sol:262)
     *      ltDeposit (in-kind) SUCCEEDS, never gated                (DepositLogic.sol:281-307)
     *      ltDepositMultiAsset with an ST leg REVERTS DISABLED_IN_FIXED_TERM_STATE (DepositLogic.sol:343)
     *      ltDepositMultiAsset quote-only     SUCCEEDS              (DepositLogic.sol:343, _stAssets == 0 arm)
     * @dev FIXED_TERM entry derivation (shared -20% rate): stRaw = 80e18, jtRaw = 24e18, fully covered 20e18
     *      ST loss gives jtEff = 4e18, covUtil = ceil((80e18 + 24e18) x 0.2e18 / 4e18) = 5.2e18 exactly — above
     *      WAD, below the 6.4667e18 liquidation threshold, so the covered drawdown enters FIXED_TERM
     * @dev Success-leg derivations (NAV-per-BPT is exactly 1.0, the fixture's genesis initializer backs the
     *      dead minimum supply): the pool holds a 6-whole-quote leg and no senior leg at 1.0 venue prices.
     *      In-kind leg mints 1e18 BPT against 1 whole quote, so valueAllocated = 1e18 against
     *      navToMintSharesAt = 6e18 over the 6e18 LT supply mints exactly 1e18 LT shares. Quote-only
     *      multi-asset leg adds 1 whole quote = 1e18 NAV into the pool, minting exactly 1e18 BPT and again
     *      exactly 1e18 LT shares (7e18 eff NAV over 7e18 supply)
     */
    function test_FINDING_7_fixedTermDeposits_productionMatrix_intraSpecContradiction() public {
        _seedMarket(ST_SEED_WHOLE * stUnit, JT_SEED_WHOLE * stUnit);
        applySTPnL(-2000);

        // Commit the FIXED_TERM entry so the pre-deposit market state is unambiguous
        SyncedAccountingState memory pre = _sync();
        assertEq(pre.coverageUtilizationWAD, 5.2e18, "covUtil must be ceil(104e18 x 0.2e18 / 4e18) = 5.2e18 exactly");
        assertEq(uint8(pre.marketState), uint8(MarketState.FIXED_TERM), "the covered drawdown must enter FIXED_TERM");

        // 1. ST deposit: REVERTS (canonical spec sentence "Deposits are enabled at all times" contradicted)
        stJtVault.mintShares(ST_PROVIDER, stUnit);
        vm.startPrank(ST_PROVIDER);
        stJtVault.approve(address(seniorTranche), stUnit);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        seniorTranche.deposit(toTrancheUnits(stUnit), ST_PROVIDER);
        vm.stopPrank();

        // 2. JT deposit: REVERTS
        stJtVault.mintShares(JT_PROVIDER, stUnit);
        vm.startPrank(JT_PROVIDER);
        stJtVault.approve(address(juniorTranche), stUnit);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        juniorTranche.deposit(toTrancheUnits(stUnit), JT_PROVIDER);
        vm.stopPrank();

        // 3. Multi-asset LT deposit with an ST leg: REVERTS (it would mint senior shares mid-term)
        address depositor = makeAddr("FINDING_LT_DEPOSITOR");
        stJtVault.mintShares(depositor, stUnit);
        vm.startPrank(depositor);
        stJtVault.approve(address(liquidityTranche), stUnit);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        liquidityTranche.depositMultiAsset(stUnit, 0, 0, depositor);
        vm.stopPrank();

        // 4. In-kind LT deposit: SUCCEEDS (capital-realism sentence "deposits disabled for every tranche" contradicted)
        quoteToken.mint(address(this), quoteUnit);
        quoteToken.approve(address(balancerVault), quoteUnit);
        // The pool's token amounts follow the sorted registration order, so map the quote leg through the recorded index
        uint256[2] memory legs;
        legs[1 - stPoolTokenIndex] = quoteUnit;
        balancerVault.mintPoolTokensTo(address(bpt), depositor, 1e18, legs);
        vm.startPrank(depositor);
        bpt.approve(address(liquidityTranche), 1e18);
        uint256 inKindShares = liquidityTranche.deposit(toTrancheUnits(1e18), depositor);
        vm.stopPrank();
        assertEq(inKindShares, 1e18, "in-kind FIXED_TERM LT deposit must mint exactly 1e18 shares (1e18 NAV at a 1.0 share price)");

        // 5. Quote-only multi-asset LT deposit: SUCCEEDS (mints no senior shares, only deepens liquidity)
        quoteToken.mint(depositor, quoteUnit);
        vm.startPrank(depositor);
        quoteToken.approve(address(liquidityTranche), quoteUnit);
        uint256 quoteOnlyShares = liquidityTranche.depositMultiAsset(0, quoteUnit, 0, depositor);
        vm.stopPrank();
        assertEq(quoteOnlyShares, 1e18, "quote-only FIXED_TERM multi-asset deposit must mint exactly 1e18 shares");

        // The matrix's two success legs must leave the committed state in FIXED_TERM with the depth credited
        assertEq(uint8(accountant.getState().lastMarketState), uint8(MarketState.FIXED_TERM), "market must remain FIXED_TERM");
        assertEq(toUint256(kernel.getState().ltOwnedYieldBearingAssets), SEEDED_LT_RAW_NAV + 2e18, "ltOwned must be the 6e18 seed plus both 1e18 legs");
    }

    // =============================
    // FINDING 11 — the mint-dilution clamp's residual overflow cliff
    // =============================

    /// @dev External probe so the cliff's Panic(0x11) is observable through expectRevert (findings 8-10b live in the fork suite)
    function convertToSharesCliffProbe(uint256 _value, uint256 _totalValue, uint256 _supply) external pure returns (uint256) {
        return ValuationLogic._convertToShares(toNAVUnits(_value), toNAVUnits(_totalValue), _supply, Math.Rounding.Floor);
    }

    /**
     * @notice FINDING 11: the mint-dilution clamp (MINT_DILUTION_RESIDUAL_WAD = 1e6) bounds the zero-NAV
     *         dilution mint per cycle but, with an absolute supply ceiling explicitly declined (user
     *         decision), the cap computation floor(supply x (WAD - eps) / eps) itself overflows uint256 once
     *         supply > floor((2^256 - 1) x eps / (WAD - eps)) — so repeated total-wipe dilution cycles (each
     *         growing the supply by up to x(WAD - eps)/eps ~ 1e12) still terminate in a Panic(0x11) after ~4
     *         cycles, including inside the sync's fee mint where it bricks the market.
     *         SPEC-EXPECTED (Appendix B.4 resolution): a bounded, legible failure; ACTUAL: an arithmetic panic
     *         at the cliff. Pinned exactly: the boundary supply floor((2^256 - 1)/((WAD - eps)/eps)) succeeds
     *         and one share-wei past it panics ((WAD - eps)/eps = 1e12 - 1 exactly at eps = 1e6, so the cap
     *         multiply is exact and the floor identity max - S_ok x k < k gives the crisp +1 boundary)
     */
    function test_FINDING_11_mintDilutionClamp_residualOverflowCliff() public {
        uint256 k = (WAD - MINT_DILUTION_RESIDUAL_WAD) / MINT_DILUTION_RESIDUAL_WAD; // 1e12 - 1, exact division
        uint256 supplyAtCliff = type(uint256).max / k; // the largest supply whose cap still fits in uint256
        uint256 bindingValue = 1e18; // over a 1-wei denominator this always binds: ceil(1e18 x 1e6 / (1e18 - 1e6)) > 1

        // Just below the cliff the clamped mint succeeds and returns the exact cap
        uint256 minted = this.convertToSharesCliffProbe(bindingValue, 0, supplyAtCliff);
        assertEq(minted, Math.mulDiv(supplyAtCliff, WAD - MINT_DILUTION_RESIDUAL_WAD, MINT_DILUTION_RESIDUAL_WAD), "at the boundary the cap still fits");

        // One share-wei past the cliff the cap computation overflows uint256 and the mint panics
        vm.expectRevert(stdError.arithmeticError);
        this.convertToSharesCliffProbe(bindingValue, 0, supplyAtCliff + 1);
    }
}
