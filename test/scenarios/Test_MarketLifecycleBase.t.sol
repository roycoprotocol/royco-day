// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { LT_LP_ROLE, ST_LP_ROLE } from "../../src/factory/Roles.sol";
import { IRoycoDayAccountant } from "../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoSeniorTranche } from "../../src/interfaces/IRoycoSeniorTranche.sol";
import { IRoycoVaultTranche } from "../../src/interfaces/IRoycoVaultTranche.sol";
import { AssetClaims, MarketState, SyncedAccountingState } from "../../src/libraries/Types.sol";
import { Math, toNAVUnits, toTrancheUnits, toUint256 } from "../../src/libraries/Units.sol";
import { DayMarketTestBase } from "../utils/DayMarketTestBase.sol";
import { FixtureCell } from "../utils/FixtureTypes.sol";
import { defaultParams } from "../utils/MarketParams.sol";

/**
 * @title Test_MarketLifecycleBase
 * @notice The full market lifecycle (deploy, seed, PnL, tranche accounting sync, deposit, redeem) run against
 *         every token/decimals shape the market supports
 * @dev One concrete per token shape supplies the shape config and the hand-derived quoter expectation. Every
 *      expected number is derived by hand BEFORE execution, never read back from the code: the collateral mark is
 *      one conversion `coinvestedShares x rateWAD x oraclePrice` scaled to WAD, conservation is the exact identity
 *      collateralNAV == stEff + jtEff, and the premium, fee, and redemption expectations are the floor-arithmetic
 *      derivations shown at the constants below
 * @dev This file carries only lifecycle assertions. Deposit-gating behavior is the subject of dedicated tests
 *      (see the two positive conformance tests at the bottom), and the edge-case behaviors that were once
 *      collected separately now live in their respective feature suites
 */
abstract contract Test_MarketLifecycleBase is DayMarketTestBase {
    // =============================
    // Seed Constants (whole tokens, scaled per token shape in setUp)
    // =============================

    /// @dev Whole ST/JT vault shares seeded. Coverage after seed: (100 + 30) x 0.2 / 30 = 0.8667 <= 1, gate clears
    uint256 internal constant ST_SEED_WHOLE = 100;
    uint256 internal constant JT_SEED_WHOLE = 30;

    /**
     * @dev Explicitly seeded LT depth: 20 BPT against a 20-whole-quote leg (NAV-per-BPT stays 1.0)
     * @dev The fixture's ST-deposit auto-seed already added ceil(100 x 0.05) + 1 = 6 whole quote = 6e18 NAV of
     *      depth (DayMarketTestBase._ensureLiquidityCapacityForSTDeposit), so total seeded ltRawNAV = 26e18
     */
    uint256 internal constant LT_SEED_BPT = 20e18;

    /// @dev Hand-derived total seeded LT raw NAV: 6e18 (auto-seed) + 20e18 (explicit) at 1.0 quote price
    uint256 internal constant SEEDED_LT_RAW_NAV = 26e18;

    /// @dev The virtual-shares/value offset (Constants.sol VIRTUAL_SHARES / VIRTUAL_VALUE, the OZ ERC4626
    ///      inflation-attack mitigation): every non-fresh share conversion prices against the effective supply
    ///      (supply + 1e6) over the effective value (totalValue + 1)
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_VALUE = 1;

    /**
     * @dev Total seeded LT shares. The 6e18 auto-seed is the FIRST LT deposit (fresh tranche, supply == NAV == 0)
     *      so it mints 1:1 -> 6e18 shares. The explicit 20e18 BPT then deposits into a live tranche (supply 6e18,
     *      raw NAV 6e18), so the offset applies: floor((6e18 + 1e6) x 20e18 / (6e18 + 1)) = 20000000000003333329
     *      shares. Total seeded = 6e18 + 20000000000003333329 = 26000000000003333329 (26e18 + 3333329 of
     *      virtual-offset dust the fresh-1:1 pin used to hide). The seeded LT RAW NAV is still exactly 26e18 (BPT
     *      is minted 1:1 with NAV); only the SHARE count drifts
     */
    uint256 internal constant SEEDED_LT_SHARES = 26_000_000_000_003_333_329;

    // =============================
    // Canonical +100bps Sync Expectations (hand-derived BEFORE execution)
    // =============================

    /**
     * @dev Full derivation of the canonical sync used by the lifecycle and redemption tests: _seedDefault, then
     *      applySTPnL(100), a 1-day warp, syncVenuePrices, and one sync. Every value below is floor arithmetic
     *      from defaultParams, and is shape-independent because tranche shares, NAV units, and BPT all carry
     *      18 decimals in every token shape.
     *
     *      Checkpoint after _seedDefault (all seed ops share the deploy block, so no time-weighted yield share
     *      has accrued): collateralNAV = 130e18 (130 whole coinvested shares at rate 1.0 and price 1.0),
     *      stEff = 100e18, jtEff = 30e18, ltRaw = 26e18, il = 0, PERPETUAL.
     *
     *      applySTPnL(100) moves the shared vault rate 1.0 -> 1.01, so the fresh collateral mark is one
     *      conversion of the 130 whole coinvested shares: 130 x 1.01 x 1.0 = 131.3e18 exactly.
     *      deltaCollateralNAV = +1.3e18, attributed pro rata off the checkpoint:
     *      deltaST = floor(1.3e18 x 100e18 / 130e18) = 1e18 exactly and deltaJT = 1.3e18 - 1e18 = 0.3e18
     *      (JT is the residual; the floor drops zero wei here). The waterfall with defaultParams:
     *      1. JT gain leg: jtGain = 0.3e18 > dustTolerance (1 wei), so jtFee books
     *         floor(0.3e18 x 0.1) = 0.03e18 and jtEff rises to 30.3e18
     *      2. Premiums over the 1-day window (MockYDM pins the shares at the defaultParams curve targets,
     *         JT 0.2e18 and LT 0.1e18, both under their 0.5e18 / 0.3e18 caps). The time-weighted accrual is
     *         share x 86400 over an 86400-second premium window, so the day cancels exactly:
     *         jtRiskPremium = floor(1e18 x (0.2e18 x 86400) / (86400 x 1e18)) = 0.2e18
     *         ltLiquidityPremium = floor(1e18 x (0.1e18 x 86400) / (86400 x 1e18)) = 0.1e18
     *      3. Yield-share fees (premiumsPaid, stGain 1e18 > dust): jtFee += floor(0.2e18 x 0.1) = 0.02e18 for a
     *         0.05e18 total, and ltFee = floor(0.1e18 x 0.1) = 0.01e18
     *      4. Residual: stGain = 1e18 - 0.2e18 - 0.1e18 = 0.7e18, so stFee = floor(0.7e18 x 0.1) = 0.07e18
     *      5. stEff = 100e18 + 0.7e18 + 0.1e18 = 100.8e18 (the LT premium stays a senior claim inside stEff)
     *         and jtEff = 30.3e18 + 0.2e18 = 30.5e18. Conservation: 131.3 == 100.8 + 30.5 exactly
     */
    uint256 internal constant POST_PNL_RATE_WAD = 1.01e18;
    uint256 internal constant POST_PNL_COLLATERAL_NAV = 131.3e18;
    uint256 internal constant POST_SYNC_ST_EFF_NAV = 100.8e18;
    uint256 internal constant POST_SYNC_JT_EFF_NAV = 30.5e18;
    uint256 internal constant LT_LIQUIDITY_PREMIUM_NAV = 0.1e18;
    uint256 internal constant ST_PROTOCOL_FEE_NAV = 0.07e18;
    uint256 internal constant JT_PROTOCOL_FEE_NAV = 0.05e18;
    uint256 internal constant LT_PROTOCOL_FEE_NAV = 0.01e18;

    /**
     * @dev The fee and liquidity premium share mint (_computeSTFeeAndLiquidityPremiumSharesToMint, jointly
     *      priced): both price against the pre-sync 100e18 supply over the retained NAV
     *      100.8e18 - 0.1e18 - 0.07e18 = 100.63e18, each floored. The LT protocol fee is carved out of the
     *      liquidity premium and remitted as SENIOR shares, so the LT receives the premium NET of its own fee
     *      and the fee recipient receives senior shares worth the ST fee PLUS the LT fee:
     *      Both legs are convertToShares against the pre-sync 100e18 supply, so the virtual-shares offset prices
     *      each against effective supply (100e18 + 1e6) over effective retained value (100.63e18 + 1):
     *      LT_PREMIUM_SHARES = floor((100e18 + 1e6) x (0.1e18 - 0.01e18) / (100.63e18 + 1)) = 89436549736659942
     *      ST_FEE_SHARES = floor((100e18 + 1e6) x (0.07e18 + 0.01e18) / (100.63e18 + 1)) = 79499155321475504
     *      Total senior shares minted this sync stays (premium - ltFee) + (stFee + ltFee) == premium + stFee in
     *      NAV terms, but each floored share count ticks up by the offset numerator's +1e6
     */
    uint256 internal constant LT_PREMIUM_SHARES = 89_436_549_736_659_942;
    uint256 internal constant ST_FEE_SHARES = 79_499_155_321_475_504;
    uint256 internal constant POST_SYNC_ST_SUPPLY = 100e18 + LT_PREMIUM_SHARES + ST_FEE_SHARES;

    /**
     * @dev The sync's inline single-sided add DEPLOYS the premium, and the reason is derivable: the venue prices
     *      the pool's senior leg live through the production IRateProvider.getRate, which inside the sync reads
     *      the just-cached effective share rate floor(1e18 x 100.8e18 / POST_SYNC_ST_SUPPLY) = 1.0063e18, and the
     *      seeded pool's NAV-per-BPT is exactly 1.0 (the genesis seed backs the dead minimum supply at 1.0), so
     *      the add mints fair value:
     *      the offset share rate floor((100.8e18 + 1) x 1e18 / (POST_SYNC_ST_SUPPLY + 1e6)) = 1006299999999989937,
     *      REINVESTED_BPT = floor(LT_PREMIUM_SHARES x 1006299999999989937 / 1e18) = 89999999999999999
     *      against the gate's minimum of
     *      ceil(floor(LT_PREMIUM_SHARES x 100.8e18 / POST_SYNC_ST_SUPPLY) x 0.999) = 89910000000000000,
     *      leaving only wei-level flooring as slippage, far inside the 10bps defaultParams gate. The deployed
     *      senior leg marks the oracle TVL up by the identical amount (same price, same floor), so the committed
     *      post-sync ltRawNAV is exactly SEEDED_LT_RAW_NAV + REINVESTED_BPT and no idle liquidity premium senior
     *      shares remain with the kernel. Only the NET premium (premium - ltFee) deploys, so the depth grows by
     *      less than the old full-premium split
     */
    uint256 internal constant REINVESTED_BPT = 89_999_999_999_999_999;
    uint256 internal constant POST_DEPLOY_LT_RAW_NAV = SEEDED_LT_RAW_NAV + REINVESTED_BPT;

    /**
     * @dev JT protocol fee share mint, priced against the post-fee NAV over the pre-mint supply:
     *      Priced through the offset over the pre-mint 30e18 supply:
     *      JT_FEE_SHARES = floor((30e18 + 1e6) x 0.05e18 / ((30.5e18 - 0.05e18) + 1)) = 49261083743844006
     *      The LT protocol fee no longer mints liquidity-tranche shares: it is remitted as senior shares folded
     *      into ST_FEE_SHARES, so a sync leaves the LT total supply unchanged at the seeded SEEDED_LT_SHARES
     */
    uint256 internal constant JT_FEE_SHARES = 49_261_083_743_844_006;
    uint256 internal constant POST_SYNC_JT_SUPPLY = 30e18 + JT_FEE_SHARES;
    uint256 internal constant POST_SYNC_LT_SUPPLY = SEEDED_LT_SHARES;

    /**
     * @dev Exact redemption NAV expectations (shape-independent, all inputs above):
     *      A tranche's claim IS its effective NAV, and the redeemer's nav slice scales through _scaleAssetClaims,
     *      which divides by the effective supply (totalShares + 1e6), leaving a virtual-share sliver behind:
     *      ST nav, 10e18 of POST_SYNC_ST_SUPPLY: floor(100.8e18 x 10e18 / (100168935705058135446 + 1e6)) = 10062999999999899370
     *      JT nav, 3e18 of POST_SYNC_JT_SUPPLY: floor(30.5e18 x 3e18 / (30049261083743844006 + 1e6)) = 3044999999999898500
     *      The LT redemption expectations re-mark the pool's senior leg at the live post-redemption share rate,
     *      which carries the shape's ST-withdrawal truncation, so they are derived inline in the test
     */
    uint256 internal constant ST_REDEEM_EXPECTED_NAV = 10_062_999_999_999_899_370;
    uint256 internal constant JT_REDEEM_EXPECTED_NAV = 3_044_999_999_999_898_500;

    // =============================
    // Per-Shape State
    // =============================

    /// @dev One whole coinvested ST/JT collateral asset (the shared vault share) in tranche units (10^collateralDecimals)
    uint256 internal collateralUnit;

    /// @dev One whole quote token (10^quoteDecimals)
    uint256 internal quoteUnit;

    // =============================
    // Token Shape Parameterization
    // =============================

    /// @notice The token/decimals shape this concrete runs the lifecycle against
    function _tokenShape() internal pure virtual returns (FixtureCell memory);

    /**
     * @notice The hand-derived NAV (WAD) of one whole collateral asset for this token shape
     * @dev Derived per shape in the concrete: 10^collateralDecimals share-wei at the shape's initialRateWAD
     *      converts to whole underlying, and the 1.0 price feed maps one whole underlying to exactly 1e18 NAV units
     */
    function _expectedSTUnitNAV() internal pure virtual returns (uint256);

    // =============================
    // Setup
    // =============================

    function setUp() public virtual {
        _deployMarket(_tokenShape(), defaultParams());
        collateralUnit = 10 ** uint256(cell.collateralAsset.decimals);
        quoteUnit = 10 ** uint256(cell.quoteAsset.decimals);
    }

    /// @dev Seeds the canonical lifecycle market: 30 whole JT, 100 whole ST (plus the 6e18 auto-seed), 20e18 quote-only BPT
    function _seedDefault() internal {
        _seedMarket(ST_SEED_WHOLE * collateralUnit, JT_SEED_WHOLE * collateralUnit);
        _seedLT(LT_SEED_BPT, 0, 20 * quoteUnit);
    }

    // =============================
    // Deployment Wiring
    // =============================

    /// @notice The kernel proxy must land at the CREATE address predicted for the impl constructors' immutables
    function test_Deploy_kernelProxyLandsAtPredictedAddress() public {
        // The fixture deployed exactly one contract from the dedicated deployer, so the prediction was nonce - 1
        address predicted = vm.computeCreateAddress(kernelProxyDeployer, vm.getNonce(kernelProxyDeployer) - 1);
        assertEq(address(kernel), predicted, "kernel proxy not at the CREATE-predicted address");

        // The five-contract wiring must be closed under the kernel's immutables
        assertEq(kernel.SENIOR_TRANCHE(), address(seniorTranche), "kernel ST wiring");
        assertEq(kernel.JUNIOR_TRANCHE(), address(juniorTranche), "kernel JT wiring");
        assertEq(kernel.LIQUIDITY_TRANCHE(), address(liquidityTranche), "kernel LT wiring");
        assertEq(kernel.ACCOUNTANT(), address(accountant), "kernel accountant wiring");
        assertEq(kernel.COLLATERAL_ASSET(), address(stJtVault), "kernel collateral asset wiring");
        assertEq(kernel.LT_ASSET(), address(bpt), "kernel LT asset wiring");
        assertEq(kernel.QUOTE_ASSET(), address(quoteToken), "kernel quote asset wiring");
    }

    // =============================
    // Quoter Unit Identity
    // =============================

    /**
     * @notice One whole collateral asset must quote to the shape's hand-derived NAV at the initial rate and a 1.0 oracle price
     * @dev Derivation: NAV_UNIT is always WAD-scaled, so 10^collateralDecimals share-wei x initialRateWAD (1.0)
     *      x oracle price (1.0) == exactly 1e18 NAV wei, independent of share or underlying decimals. ST and JT
     *      coinvest the one collateral asset, so a single converter pair carries both tranches by construction
     */
    function test_Quoter_oneWholeCollateralAssetQuotesToHandDerivedNAV() public view {
        assertEq(toUint256(kernel.convertCollateralAssetsToValue(toTrancheUnits(collateralUnit))), _expectedSTUnitNAV(), "collateral unit -> NAV identity");
        // And the inverse conversion must return exactly one whole collateral asset
        assertEq(toUint256(kernel.convertValueToCollateralAssets(toNAVUnits(_expectedSTUnitNAV()))), collateralUnit, "NAV -> collateral unit inverse identity");
    }

    // =============================
    // Lifecycle: Seed, PnL, Sync
    // =============================

    /**
     * @notice The canonical lifecycle: seed, +100bps senior PnL, sync, wei-exact conservation, exact premium flow
     * @dev Hand-derived mark: 130 whole coinvested shares at rate 1.01 and price 1.0 -> collateralNAV = 131.3e18
     *      exactly in one conversion. Conservation collateralNAV == stEff + jtEff holds at wei precision on both
     *      the returned state and the persisted checkpoint. The LT premium pipeline is asserted end to end
     *      against the derivation at the constants, with every value-moving mint pinned by its event: with the
     *      venue's senior leg priced live through the production rate provider and slippage mode off, the inline
     *      add MUST take the DEPLOYED branch (fair value clears the 10bps gate with only wei-level flooring), so
     *      the premium can never silently mint nothing
     */
    function test_Lifecycle_pnlSyncConservesNAVAndKernelStaysSolvent() public {
        _seedDefault();
        assertEq(_liveLTRawNAV(), SEEDED_LT_RAW_NAV, "seeded ltRawNAV must be 6e18 auto-seed + 20e18 explicit");

        applySTPnL(100);
        _warpAndRefreshFeed(1 days);
        syncVenuePrices();

        // Every value-moving mint in the sync is pinned with exact args, in emission order: the NET premium share
        // mint to the LT (supply is 100e18 + net premium at that instant), the inline reinvestment, the ST and JT
        // protocol fee share mints (the LT fee is folded into the senior fee mint as senior shares, and no
        // liquidity-tranche shares are minted on a sync), and the final committed LT raw NAV
        vm.expectEmit(address(seniorTranche));
        emit IRoycoSeniorTranche.LiquidityPremiumSharesMinted(address(kernel), LT_PREMIUM_SHARES, 100e18 + LT_PREMIUM_SHARES);
        vm.expectEmit(address(kernel));
        emit IRoycoDayKernel.LiquidityPremiumReinvested(LT_PREMIUM_SHARES, toTrancheUnits(REINVESTED_BPT));
        vm.expectEmit(address(seniorTranche));
        emit IRoycoVaultTranche.ProtocolFeeSharesMinted(PROTOCOL_FEE_RECIPIENT, ST_FEE_SHARES, POST_SYNC_ST_SUPPLY);
        vm.expectEmit(address(juniorTranche));
        emit IRoycoVaultTranche.ProtocolFeeSharesMinted(PROTOCOL_FEE_RECIPIENT, JT_FEE_SHARES, POST_SYNC_JT_SUPPLY);
        vm.expectEmit(address(accountant));
        emit IRoycoDayAccountant.LiquidityTrancheRawNAVCommitted(toNAVUnits(POST_DEPLOY_LT_RAW_NAV));
        SyncedAccountingState memory state = _sync();

        // The collateral mark is hand-derived exactly from the rate and oracle price in one conversion
        assertEq(toUint256(state.collateralNAV), POST_PNL_COLLATERAL_NAV, "collateralNAV must be 130 whole coinvested shares x 1.01 x 1.0 = 131.3e18");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "an up-only sync must stay PERPETUAL");
        // A PERPETUAL commit never carries a drawdown (marketState == PERPETUAL iff jtImpermanentLoss == 0)
        assertEq(toUint256(state.jtImpermanentLoss), 0, "a PERPETUAL commit must carry zero JT impermanent loss");

        // The full yield split lands exactly per the derivation at the constants
        assertEq(toUint256(state.stEffectiveNAV), POST_SYNC_ST_EFF_NAV, "stEff must be 100e18 + 0.7e18 residual + 0.1e18 LT premium");
        assertEq(toUint256(state.jtEffectiveNAV), POST_SYNC_JT_EFF_NAV, "jtEff must be 30e18 + 0.3e18 gain + 0.2e18 risk premium");
        assertEq(toUint256(state.ltLiquidityPremium), LT_LIQUIDITY_PREMIUM_NAV, "liqShare must be floor(1e18 x 0.1e18 x 1d / (1d x WAD)) = 0.1e18");
        assertEq(toUint256(state.stProtocolFee), ST_PROTOCOL_FEE_NAV, "stFee must be floor(0.7e18 x 0.1) = 0.07e18");
        assertEq(toUint256(state.jtProtocolFee), JT_PROTOCOL_FEE_NAV, "jtFee must be floor(0.3e18 x 0.1) + floor(0.2e18 x 0.1) = 0.05e18");
        assertEq(toUint256(state.ltProtocolFee), LT_PROTOCOL_FEE_NAV, "ltFee must be floor(0.1e18 x 0.1) = 0.01e18");

        // Wei-exact conservation on the returned state and the persisted checkpoint
        assertNAVConservation(state.collateralNAV, state.stEffectiveNAV, state.jtEffectiveNAV, "sync return");
        IRoycoDayAccountant.RoycoDayAccountantState memory acct = accountant.getState();
        assertNAVConservation(acct.lastCollateralNAV, acct.lastSTEffectiveNAV, acct.lastJTEffectiveNAV, "persisted checkpoint");

        // The premium and ST fee mints land exactly per the fee and liquidity premium share mint derivation at the constants
        assertEq(seniorTranche.totalSupply(), POST_SYNC_ST_SUPPLY, "ST supply must be 100e18 + premium shares + fee shares exactly");

        // Branch pin: the sync's inline add must DEPLOY (live fair-value pricing, see REINVESTED_BPT): the idle
        // premium senior shares drain to zero, the pool's senior leg holds exactly the minted premium shares, and
        // the BPT depth and committed ltRawNAV both grow by exactly the fair-value mint
        IRoycoDayKernel.RoycoDayKernelState memory ks = kernel.getState();
        assertEq(ks.ltOwnedSeniorTrancheShares, 0, "deployed branch: no idle premium senior shares may remain with live venue pricing");
        assertEq(seniorTranche.balanceOf(address(kernel)), 0, "deployed branch: the premium shares must sit in the pool, not the kernel");
        assertEq(toUint256(ks.totalLTAssets), POST_DEPLOY_LT_RAW_NAV, "deployed branch: the BPT ledger must grow by exactly REINVESTED_BPT");
        assertEq(bpt.balanceOf(address(kernel)), POST_DEPLOY_LT_RAW_NAV, "deployed branch: the kernel BPT balance must equal the owned ledger");
        assertEq(
            balancerVault.getPoolBalances(address(bpt))[stPoolTokenIndex], LT_PREMIUM_SHARES, "deployed branch: the pool's senior leg must hold the premium"
        );
        assertEq(toUint256(state.ltRawNAV), POST_DEPLOY_LT_RAW_NAV, "deployed branch: committed ltRawNAV must include the deployed depth");
        assertEq(_liveLTRawNAV(), POST_DEPLOY_LT_RAW_NAV, "deployed branch: the live ltRawNAV read must match the committed mark");

        // Solvency: the kernel's custodied balance must exactly equal the single coinvested collateral ledger
        assertEq(toUint256(ks.totalCollateralAssets), (ST_SEED_WHOLE + JT_SEED_WHOLE) * collateralUnit, "collateral ledger must equal the seeded shares");
        assertEq(
            stJtVault.balanceOf(address(kernel)),
            (ST_SEED_WHOLE + JT_SEED_WHOLE) * collateralUnit,
            "kernel vault-share balance must equal the collateral ledger exactly"
        );
    }

    // =============================
    // Redemptions (gate-respecting, preview parity, exact payout deltas)
    // =============================

    /**
     * @notice One gate-respecting redemption per tranche pays exactly the previewed and hand-derived claims
     * @dev Preview parity is the property (claims == preview byte-for-byte), every previewed leg is pinned to
     *      its floor-arithmetic expectation from the constants' derivation, and every Redeem event carries the
     *      exact derived claims. The NAV expectations are exact and shape-independent, the collateral legs go
     *      through the quoter identity (floor(nav x collateralUnit / 1.01e18)) and so carry the shape's decimals,
     *      computed inline. Gate sanity at the chosen sizes: ST 10e18 shares is ungated, JT 3e18 shares leaves
     *      coverageUtilization ~= 118.2 x 0.2 / 27.5 = 0.86 <= 1, and LT 5.2e18 shares leaves
     *      liquidityUtilization ~= 90.7 x 0.05 / 20.9 = 0.22 <= 1, so every redemption must clear
     */
    function test_Redemptions_eachTranchePaysExactPreviewedClaims() public {
        _seedDefault();
        // Setup observation (an input, not an expectation): the seeded BPT supply is the 26e18 deposited depth
        // plus the fixture's genesis backing for the pool's dead minimum supply, all at exactly 1.0 NAV-per-BPT
        uint256 bptSupplySeeded = bpt.totalSupply();
        applySTPnL(100);
        _warpAndRefreshFeed(1 days);
        syncVenuePrices();
        _sync();

        // The providers hold exactly their seeded share counts (the premium and fee mints landed elsewhere)
        assertEq(seniorTranche.balanceOf(ST_PROVIDER), 100e18, "ST provider must hold the seeded 100e18 shares");
        assertEq(juniorTranche.balanceOf(JT_PROVIDER), 30e18, "JT provider must hold the seeded 30e18 shares");
        assertEq(liquidityTranche.balanceOf(LT_PROVIDER), SEEDED_LT_SHARES, "LT provider must hold the seeded SEEDED_LT_SHARES");

        // Senior: redeem a tenth (10e18 shares). Claim derivation: ST's claim IS its effective NAV 100.8e18
        // converted ONCE to the collateral asset, then sliced proportionally and floored:
        // nav = floor(100.8e18 x 10e18 / (POST_SYNC_ST_SUPPLY + 1e6)) = ST_REDEEM_EXPECTED_NAV, and
        // collateralAssets = floor(floor(100.8e18 x collateralUnit / 1.01e18) x 10e18 / (POST_SYNC_ST_SUPPLY + 1e6)),
        // the slice divides by the effective supply (the virtual-share offset in _scaleAssetClaims)
        uint256 stShares = seniorTranche.balanceOf(ST_PROVIDER) / 10;
        uint256 expectedStAssetsWithdrawn =
            Math.mulDiv(Math.mulDiv(POST_SYNC_ST_EFF_NAV, collateralUnit, POST_PNL_RATE_WAD), stShares, POST_SYNC_ST_SUPPLY + VIRTUAL_SHARES);
        AssetClaims memory stPreviewed = seniorTranche.previewRedeem(stShares);
        uint256 stBalBefore = stJtVault.balanceOf(ST_PROVIDER);
        vm.expectEmit(address(seniorTranche));
        emit IRoycoVaultTranche.Redeem(
            ST_PROVIDER,
            ST_PROVIDER,
            AssetClaims({
                collateralAssets: toTrancheUnits(expectedStAssetsWithdrawn), ltAssets: toTrancheUnits(0), stShares: 0, nav: toNAVUnits(ST_REDEEM_EXPECTED_NAV)
            }),
            stShares
        );
        vm.prank(ST_PROVIDER);
        AssetClaims memory stClaims = seniorTranche.redeem(stShares, ST_PROVIDER, ST_PROVIDER);
        assertEq(stClaims.collateralAssets, stPreviewed.collateralAssets, "ST redeem: collateralAssets preview parity");
        assertEq(stClaims.ltAssets, stPreviewed.ltAssets, "ST redeem: ltAssets preview parity");
        assertEq(stClaims.nav, stPreviewed.nav, "ST redeem: nav preview parity");
        assertEq(toUint256(stClaims.nav), ST_REDEEM_EXPECTED_NAV, "ST redeem: nav must equal the hand-derived expectation exactly");
        assertEq(toUint256(stClaims.collateralAssets), expectedStAssetsWithdrawn, "ST redeem: collateralAssets must equal the derived effective-NAV slice");
        assertEq(stJtVault.balanceOf(ST_PROVIDER) - stBalBefore, toUint256(stClaims.collateralAssets), "ST redeem: payout must equal the claimed vault shares");

        // Junior: redeem a tenth (3e18 shares). The ST redemption reduced the collateral mark and stEff by the
        // same ceil(wSt x 1.01e18 / collateralUnit) and left jtEff 30.5e18 untouched, so this pre-op sync sees a
        // zero delta and JT's claim is its effective NAV converted ONCE (the old two-legged cross-claim on a
        // separate senior raw NAV no longer exists):
        // nav = floor(30.5e18 x 3e18 / (POST_SYNC_JT_SUPPLY + 1e6)) = JT_REDEEM_EXPECTED_NAV exactly, and
        // collateralAssets = floor(floor(30.5e18 x collateralUnit / 1.01e18) x 3e18 / (POST_SYNC_JT_SUPPLY + 1e6))
        uint256 jtShares = juniorTranche.balanceOf(JT_PROVIDER) / 10;
        uint256 expectedJtAssetsWithdrawn =
            Math.mulDiv(Math.mulDiv(POST_SYNC_JT_EFF_NAV, collateralUnit, POST_PNL_RATE_WAD), jtShares, POST_SYNC_JT_SUPPLY + VIRTUAL_SHARES);
        AssetClaims memory jtPreviewed = juniorTranche.previewRedeem(jtShares);
        uint256 jtBalBefore = stJtVault.balanceOf(JT_PROVIDER);
        vm.expectEmit(address(juniorTranche));
        emit IRoycoVaultTranche.Redeem(
            JT_PROVIDER,
            JT_PROVIDER,
            AssetClaims({
                collateralAssets: toTrancheUnits(expectedJtAssetsWithdrawn), ltAssets: toTrancheUnits(0), stShares: 0, nav: toNAVUnits(JT_REDEEM_EXPECTED_NAV)
            }),
            jtShares
        );
        vm.prank(JT_PROVIDER);
        AssetClaims memory jtClaims = juniorTranche.redeem(jtShares, JT_PROVIDER, JT_PROVIDER);
        assertEq(jtClaims.collateralAssets, jtPreviewed.collateralAssets, "JT redeem: collateralAssets preview parity");
        assertEq(jtClaims.ltAssets, jtPreviewed.ltAssets, "JT redeem: ltAssets preview parity");
        assertEq(jtClaims.nav, jtPreviewed.nav, "JT redeem: nav preview parity");
        assertEq(toUint256(jtClaims.nav), JT_REDEEM_EXPECTED_NAV, "JT redeem: nav must equal the hand-derived expectation exactly");
        assertEq(toUint256(jtClaims.collateralAssets), expectedJtAssetsWithdrawn, "JT redeem: collateralAssets must equal the derived effective-NAV slice");
        assertEq(stJtVault.balanceOf(JT_PROVIDER) - jtBalBefore, toUint256(jtClaims.collateralAssets), "JT redeem: payout must equal the claimed vault shares");

        // Liquidity: redeem a fifth (5.2e18 shares) in-kind. The premium DEPLOYED at the sync (see
        // REINVESTED_BPT), so there is no idle leg and the redemption pays a pure BPT slice. The pool's senior
        // leg re-marks at the live post-redemption share rate, which carries the shape's ST-withdrawal
        // truncation, so the expectation chains it inline:
        // collateralAfterStRedeem = floor((130 x collateralUnit - wSt) x 1.01e18 / collateralUnit) for the wSt
        // collateral wei the ST redemption withdrew, and its post-op reduced stEff by the identical mark delta:
        // stEffAfter = 100.8e18 - (131.3e18 - collateralAfterStRedeem) (the JT redemption reduces only jtEff),
        // the senior supply is 10e18 lower after the burn, so the live share rate is
        // rateAfter = floor(1e18 x stEffAfter / (POST_SYNC_ST_SUPPLY - 10e18)), the oracle TVL is the seeded
        // quote depth plus floor(LT_PREMIUM_SHARES x rateAfter / 1e18), and the kernel's 26e18 + REINVESTED_BPT
        // of the BPT supply marks to nav = floor(floor(TVL x ltOwned / bptSupply) x 5.2e18 / POST_SYNC_LT_SUPPLY)
        uint256 ltShares = liquidityTranche.balanceOf(LT_PROVIDER) / 5;
        uint256 expectedLtNav;
        uint256 expectedLtAssets;
        {
            uint256 collateralAfterStRedeem =
                Math.mulDiv((ST_SEED_WHOLE + JT_SEED_WHOLE) * collateralUnit - expectedStAssetsWithdrawn, POST_PNL_RATE_WAD, collateralUnit);
            uint256 stEffAfter = POST_SYNC_ST_EFF_NAV - (POST_PNL_COLLATERAL_NAV - collateralAfterStRedeem);
            // The live senior share rate is _computeTrancheShareRate == _convertToValue(WAD, supply, effNAV), which
            // carries the offset: (effNAV + 1) x WAD / (supply + 1e6)
            uint256 rateAfter = Math.mulDiv(stEffAfter + VIRTUAL_VALUE, 1e18, (POST_SYNC_ST_SUPPLY - 10e18) + VIRTUAL_SHARES);
            // bptSupplySeeded is the whole seeded supply including the genesis backing, captured above at 1.0 NAV-per-BPT
            uint256 poolTVL = bptSupplySeeded + Math.mulDiv(LT_PREMIUM_SHARES, rateAfter, 1e18);
            uint256 ltRawAtRedeem = Math.mulDiv(poolTVL, POST_DEPLOY_LT_RAW_NAV, bptSupplySeeded + REINVESTED_BPT);
            // The redeemer's slice scales through _scaleAssetClaims, dividing by the effective supply (+ 1e6)
            expectedLtNav = Math.mulDiv(ltRawAtRedeem, ltShares, POST_SYNC_LT_SUPPLY + VIRTUAL_SHARES);
            expectedLtAssets =
                Math.mulDiv(Math.mulDiv(bptSupplySeeded + REINVESTED_BPT, ltRawAtRedeem, poolTVL), ltShares, POST_SYNC_LT_SUPPLY + VIRTUAL_SHARES);
        }
        AssetClaims memory ltPreviewed = liquidityTranche.previewRedeem(ltShares);
        uint256 ltBptBefore = bpt.balanceOf(LT_PROVIDER);
        uint256 ltStSharesBefore = seniorTranche.balanceOf(LT_PROVIDER);
        vm.expectEmit(address(liquidityTranche));
        emit IRoycoVaultTranche.Redeem(
            LT_PROVIDER,
            LT_PROVIDER,
            AssetClaims({ collateralAssets: toTrancheUnits(0), ltAssets: toTrancheUnits(expectedLtAssets), stShares: 0, nav: toNAVUnits(expectedLtNav) }),
            ltShares
        );
        vm.prank(LT_PROVIDER);
        AssetClaims memory ltClaims = liquidityTranche.redeem(ltShares, LT_PROVIDER, LT_PROVIDER);
        assertEq(ltClaims.ltAssets, ltPreviewed.ltAssets, "LT redeem: ltAssets preview parity");
        assertEq(ltClaims.stShares, ltPreviewed.stShares, "LT redeem: stShares preview parity");
        assertEq(ltClaims.nav, ltPreviewed.nav, "LT redeem: nav preview parity");
        assertEq(toUint256(ltClaims.nav), expectedLtNav, "LT redeem: nav must equal the derived re-marked BPT slice exactly");
        assertEq(toUint256(ltClaims.ltAssets), expectedLtAssets, "LT redeem: the BPT slice must equal the derived expectation exactly");
        assertEq(ltClaims.stShares, 0, "LT redeem: no idle premium senior shares exist after the deployed reinvestment");
        assertEq(bpt.balanceOf(LT_PROVIDER) - ltBptBefore, toUint256(ltClaims.ltAssets), "LT redeem: BPT payout must equal the claim");
        assertEq(seniorTranche.balanceOf(LT_PROVIDER) - ltStSharesBefore, ltClaims.stShares, "LT redeem: idle premium ST share payout must equal the claim");
    }

    // =============================
    // ST Deposit Preview Parity
    // =============================

    /**
     * @notice An ST deposit mints exactly the previewed shares
     * @dev Derivation: at rate 1.0 the freshly seeded market has supply == stEff == 100e18 (initial mint is
     *      one share-wei per NAV-wei with no accrued yield or fees). The tranche is no longer fresh (supply > 0),
     *      so 5 whole collateral assets == 5e18 NAV mint through the offset:
     *      floor((100e18 + 1e6) x 5e18 / (100e18 + 1)) = 5000000000000049999 (5e18 + 49999 of virtual-offset
     *      dust, the incumbent 100e18 supply's price ticks up by the +1e6 numerator), and preview must match
     *      execution byte-for-byte
     */
    function test_STDeposit_previewMatchesExecutionExactly() public {
        _seedDefault();
        uint256 assets = 5 * collateralUnit;
        stJtVault.mintShares(ST_PROVIDER, assets);

        // Offset mint against the live 100e18 supply / 100e18 stEff: floor((100e18 + 1e6) x 5e18 / (100e18 + 1))
        uint256 expectedMinted = Math.mulDiv(100e18 + VIRTUAL_SHARES, 5e18, 100e18 + VIRTUAL_VALUE);
        uint256 previewedShares = seniorTranche.previewDeposit(toTrancheUnits(assets));
        uint256 sharesBefore = seniorTranche.balanceOf(ST_PROVIDER);
        vm.startPrank(ST_PROVIDER);
        stJtVault.approve(address(seniorTranche), assets);
        vm.expectEmit(address(seniorTranche));
        emit IRoycoVaultTranche.Deposit(ST_PROVIDER, ST_PROVIDER, toTrancheUnits(assets), expectedMinted);
        uint256 mintedShares = seniorTranche.deposit(toTrancheUnits(assets), ST_PROVIDER);
        vm.stopPrank();

        assertEq(mintedShares, previewedShares, "ST deposit: preview/execute share parity");
        assertEq(seniorTranche.balanceOf(ST_PROVIDER) - sharesBefore, mintedShares, "ST deposit: minted shares must land on the receiver");
        assertEq(mintedShares, expectedMinted, "ST deposit: 5 whole assets must mint the offset-priced share count against the 100e18 supply");
    }

    // =============================
    // Adversarial: Sync Sandwich
    // =============================

    /**
     * @notice Depositing into the senior tranche right before a gain sync captures none of the pending gain or premium
     * @dev Attacker intent: +100bps of senior gain has accrued but no sync has booked it, so the attacker
     *      deposits 5 whole vault shares hoping to be priced at the stale 1.0 share rate and skim the gain plus
     *      the LT liquidity premium. The deposit's own pre-op tranche accounting sync books the entire gain to
     *      the pre-existing holders first (the premium shares mint against the pre-deposit supply), so the
     *      attacker's shares price at the fresh rate: minted = floor(5.05e18 x POST_SYNC_ST_SUPPLY / 100.8e18).
     *      The immediate same-block round-trip redemption then returns at most the deposited value (two floors),
     *      proving the sandwich nets zero and the NET premium (premium - ltFee) still lands with the LT
     */
    function test_STDeposit_frontRunningGainSync_capturesNoYieldOrPremium() public {
        _seedDefault();
        applySTPnL(100);
        _warpAndRefreshFeed(1 days);
        syncVenuePrices();

        // The attacker's 5 whole vault shares are worth exactly 5 x 1.01 x 1.0 = 5.05e18 NAV at deposit time
        address attacker = _generateActor("ST_SANDWICHER", ST_LP_ROLE);
        uint256 depositAssets = 5 * collateralUnit;
        uint256 depositNAV = 5.05e18;
        // The deposit's inline pre-op sync produces the canonical post-sync state, so the attacker mints at the
        // diluted share rate through the offset convertToShares: floor((POST_SYNC_ST_SUPPLY + 1e6) x 5.05e18 /
        // (100.8e18 + 1)) shares, strictly less than 5.05e18
        uint256 expectedMintedShares = Math.mulDiv(POST_SYNC_ST_SUPPLY + VIRTUAL_SHARES, depositNAV, POST_SYNC_ST_EFF_NAV + VIRTUAL_VALUE);
        stJtVault.mintShares(attacker, depositAssets);

        vm.startPrank(attacker);
        stJtVault.approve(address(seniorTranche), depositAssets);
        // The premium mint must precede the attacker's share pricing inside the very same deposit call
        vm.expectEmit(address(seniorTranche));
        emit IRoycoSeniorTranche.LiquidityPremiumSharesMinted(address(kernel), LT_PREMIUM_SHARES, 100e18 + LT_PREMIUM_SHARES);
        vm.expectEmit(address(seniorTranche));
        emit IRoycoVaultTranche.Deposit(attacker, attacker, toTrancheUnits(depositAssets), expectedMintedShares);
        uint256 mintedShares = seniorTranche.deposit(toTrancheUnits(depositAssets), attacker);
        vm.stopPrank();

        assertEq(mintedShares, expectedMintedShares, "sandwich deposit: shares must price at the freshly synced rate, not the stale 1.0");
        assertLt(mintedShares, depositNAV, "sandwich deposit: the attacker must mint strictly fewer shares than deposited NAV wei");
        assertEq(seniorTranche.totalSupply(), POST_SYNC_ST_SUPPLY + expectedMintedShares, "sandwich deposit: supply must be post-sync supply + attacker mint");

        // The premium and fee flows are untouched by the sandwich: the net premium deployed to the pool in full
        // and the fee recipient holds exactly the derived senior fee shares (ST fee plus the LT fee)
        IRoycoDayKernel.RoycoDayKernelState memory ks = kernel.getState();
        assertEq(ks.ltOwnedSeniorTrancheShares, 0, "sandwich deposit: the premium must still deploy, leaving no idle senior shares");
        assertEq(balancerVault.getPoolBalances(address(bpt))[stPoolTokenIndex], LT_PREMIUM_SHARES, "sandwich deposit: the pool must hold the net premium");
        assertEq(seniorTranche.balanceOf(PROTOCOL_FEE_RECIPIENT), ST_FEE_SHARES, "sandwich deposit: the senior fee mint must be undiluted by the attacker");

        // Round-trip: redeem every minted share in the same block. Post-deposit state is exact: stEff rose by
        // the 5.05e18 deposit to 105.85e18 and the supply by the attacker's mint, so the exit pays
        // nav = floor(105.85e18 x minted / supplyAfter) <= 5.05e18 and
        // assets = floor(floor(105.85e18 x collateralUnit / 1.01e18) x minted / supplyAfter) <= 5 x collateralUnit
        // The exit slice scales through _scaleAssetClaims, dividing by the effective supply (supplyAfter + 1e6)
        uint256 supplyAfterDeposit = POST_SYNC_ST_SUPPLY + expectedMintedShares;
        uint256 stEffAfterDeposit = POST_SYNC_ST_EFF_NAV + depositNAV;
        uint256 expectedNavOut = Math.mulDiv(stEffAfterDeposit, expectedMintedShares, supplyAfterDeposit + VIRTUAL_SHARES);
        uint256 expectedAssetsOut =
            Math.mulDiv(Math.mulDiv(stEffAfterDeposit, collateralUnit, POST_PNL_RATE_WAD), expectedMintedShares, supplyAfterDeposit + VIRTUAL_SHARES);

        vm.expectEmit(address(seniorTranche));
        emit IRoycoVaultTranche.Redeem(
            attacker,
            attacker,
            AssetClaims({ collateralAssets: toTrancheUnits(expectedAssetsOut), ltAssets: toTrancheUnits(0), stShares: 0, nav: toNAVUnits(expectedNavOut) }),
            mintedShares
        );
        vm.prank(attacker);
        AssetClaims memory exitClaims = seniorTranche.redeem(mintedShares, attacker, attacker);

        // The attacker's full observable post-state: exact exit claims, zero profit, no residual shares
        assertEq(toUint256(exitClaims.nav), expectedNavOut, "sandwich exit: nav must equal the derived proportional slice");
        assertEq(toUint256(exitClaims.collateralAssets), expectedAssetsOut, "sandwich exit: collateralAssets must equal the derived effective-NAV slice");
        assertLe(expectedNavOut, depositNAV, "sandwich exit: the round trip must never pay out more NAV than deposited");
        assertLe(expectedAssetsOut, depositAssets, "sandwich exit: the round trip must never pay out more assets than deposited");
        assertEq(seniorTranche.balanceOf(attacker), 0, "sandwich exit: every attacker share must be burned");
        assertEq(stJtVault.balanceOf(attacker), expectedAssetsOut, "sandwich exit: the attacker holds exactly the floored exit assets");
        assertEq(seniorTranche.totalSupply(), POST_SYNC_ST_SUPPLY, "sandwich exit: supply must return to the post-sync supply");
        assertEq(
            toUint256(kernel.getState().totalCollateralAssets),
            (ST_SEED_WHOLE + JT_SEED_WHOLE + 5) * collateralUnit - expectedAssetsOut,
            "sandwich exit: the collateral ledger must shrink by exactly the paid assets"
        );
    }

    // =============================
    // Adversarial: Liquidity Requirement Boundary Parking
    // =============================

    /**
     * @notice An LT redemption that parks liquidityUtilization at exactly 100% succeeds, and one more BPT wei of
     *         depth removed reverts
     * @dev Attacker intent: drain the market-making depth to the last wei the liquidity requirement allows,
     *      then probe whether rounding lets one more redemption slip under the senior liquidity floor.
     *      Derivation at rate 1.0: stEff = 100e18 and minLiquidity = 0.05e18, so the floor depth is exactly 5e18.
     *      The gate is purely on ltRawNAV (depth), independent of the offset: liquidityUtilization =
     *      ceil(100e18 x 0.05e18 / depth), so depth == 5e18 reads exactly 100% and depth == 5e18 - 1 reads
     *      1e18 + 1 > WAD. Under the virtual-shares offset a BPT slice is floor(26e18 x shares /
     *      (SEEDED_LT_SHARES + 1e6)), so parking depth at exactly 5e18 needs PARK_SHARES =
     *      ceil(21e18 x (SEEDED_LT_SHARES + 1e6) / 26e18) = 21000000000003499997 (the smallest share count whose
     *      slice floors to a full 21e18 BPT). The offset also means a single-wei-share redemption now claims
     *      floor(5e18 x 1 / (residual + 1e6)) == 0 BPT, the virtual-share sliver, so it removes no depth and can
     *      never breach the floor. The minimal depth-reducing probe is therefore 2 shares, which claims exactly
     *      1 BPT wei, leaves ltRawNAV = 5e18 - 1, and must revert with LIQUIDITY_REQUIREMENT_VIOLATED
     */
    function test_LTRedeem_parkedAtExactlyFullLiquidityUtilization_succeedsAndNextWeiReverts() public {
        _seedDefault();

        // Park depth at exactly the 5e18 floor: PARK_SHARES claims a full 21e18 BPT slice (see the derivation
        // above) and leaves the residual SEEDED_LT_SHARES - PARK_SHARES shares against the 5e18 depth
        uint256 parkShares = 21_000_000_000_003_499_997;
        uint256 residualShares = SEEDED_LT_SHARES - parkShares;
        vm.expectEmit(address(liquidityTranche));
        emit IRoycoVaultTranche.Redeem(
            LT_PROVIDER,
            LT_PROVIDER,
            AssetClaims({ collateralAssets: toTrancheUnits(0), ltAssets: toTrancheUnits(21e18), stShares: 0, nav: toNAVUnits(uint256(21e18)) }),
            parkShares
        );
        vm.prank(LT_PROVIDER);
        AssetClaims memory parkClaims = liquidityTranche.redeem(parkShares, LT_PROVIDER, LT_PROVIDER);

        // Full observable post-state at the boundary: exact claims, exact depth, exact committed mark
        assertEq(toUint256(parkClaims.ltAssets), 21e18, "boundary redeem: the BPT slice must be exactly 21e18");
        assertEq(toUint256(parkClaims.nav), 21e18, "boundary redeem: the NAV slice must be exactly 21e18 at 1.0 NAV-per-BPT");
        assertEq(parkClaims.stShares, 0, "boundary redeem: no idle premium senior shares exist before any gain sync");
        assertEq(bpt.balanceOf(LT_PROVIDER), 21e18, "boundary redeem: the redeemer must hold the full BPT slice");
        assertEq(liquidityTranche.balanceOf(LT_PROVIDER), residualShares, "boundary redeem: the redeemer keeps the residual LT shares");
        assertEq(liquidityTranche.totalSupply(), residualShares, "boundary redeem: the LT supply must burn down to the residual shares");
        assertEq(toUint256(kernel.getState().totalLTAssets), 5e18, "boundary redeem: the owned BPT ledger must be exactly the 5e18 floor");
        assertEq(bpt.balanceOf(address(kernel)), 5e18, "boundary redeem: the kernel BPT balance must equal the owned ledger");
        assertEq(toUint256(accountant.getState().lastLTRawNAV), 5e18, "boundary redeem: the committed ltRawNAV must be exactly the floor depth");

        // The market reads exactly 100% utilized and stays PERPETUAL: ceil(100e18 x 0.05e18 / 5e18) = 1e18
        SyncedAccountingState memory state = _sync();
        assertEq(state.liquidityUtilizationWAD, 1e18, "boundary redeem: liquidityUtilization must read exactly 100%");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "boundary redeem: parking the boundary must not change the market state");
        // A PERPETUAL commit never carries a drawdown (marketState == PERPETUAL iff jtImpermanentLoss == 0)
        assertEq(toUint256(state.jtImpermanentLoss), 0, "boundary redeem: a PERPETUAL commit must carry zero JT impermanent loss");
        assertNAVConservation(state.collateralNAV, state.stEffectiveNAV, state.jtEffectiveNAV, "boundary sync");

        // The minimal depth-reducing probe (2 shares claims exactly 1 BPT wei under the offset) would leave
        // ltRawNAV = 5e18 - 1, and ceil(5e36 / (5e18 - 1)) = 1e18 + 1 > 100% (a single share claims 0 BPT and is
        // inert). ceil rounding favors the senior floor, so it must revert
        vm.prank(LT_PROVIDER);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        liquidityTranche.redeem(2, LT_PROVIDER, LT_PROVIDER);

        // The failed probe must have moved nothing
        assertEq(bpt.balanceOf(LT_PROVIDER), 21e18, "failed probe: the redeemer BPT balance must be unchanged");
        assertEq(liquidityTranche.balanceOf(LT_PROVIDER), residualShares, "failed probe: the redeemer LT shares must be unchanged");
        assertEq(toUint256(kernel.getState().totalLTAssets), 5e18, "failed probe: the owned BPT ledger must be unchanged");
    }

    // =============================
    // Deposit-Gating Conformance (positive tests pinning the deposit-gating behavior directly)
    // =============================

    /**
     * @notice An in-kind LT deposit is never liquidity-gated, even into an under-provisioned market
     *         (deposits are enabled at all times by design: an LT deposit only raises ltRawNAV)
     * @dev Production conforms: DepositLogic.sol:148 passes enforce=false for the in-kind path, so the accountant's
     *      Operation.LT_DEPOSIT gate never runs for it.
     *      Breach derivation: +100% shared PnL doubles the collateral mark 130e18 -> 260e18, so
     *      deltaST = floor(130e18 x 100e18 / 130e18) = 100e18 and deltaJT = 30e18. The senior gain splits per the
     *      canonical waterfall scaled x100: risk premium 20e18, liquidity premium 10e18, residual 70e18, so
     *      stEff = 100e18 + 70e18 + 10e18 = 180e18 exactly, while depth stays at the 6e18 auto-seed (the idle
     *      premium senior shares are excluded from ltRawNAV and slippage mode blocks their reinvestment):
     *      liquidityUtilization = ceil(180e18 x 0.05e18 / 6e18) = 1.5e18 > WAD. The 1e18-BPT deposit does not
     *      heal the breach and must still succeed
     */
    function test_LTDeposit_neverLiquidityGated_evenWhileUnderProvisioned() public {
        _seedMarket(ST_SEED_WHOLE * collateralUnit, JT_SEED_WHOLE * collateralUnit);
        setVenueSlippageMode(true);
        applySTPnL(10_000);
        _warpAndRefreshFeed(1 days);

        // Commit the breach so the pre-deposit market state is unambiguous (the sync return is authoritative
        // and the assertion must not depend on any read in the same test transaction picking up the previous
        // operation's transient rate cache)
        SyncedAccountingState memory pre = _sync();
        assertEq(pre.liquidityUtilizationWAD, 1.5e18, "liquidityUtilization must read the derived breach exactly (180e18 x 0.05 / 6e18)");
        // A pure-gain sync books no drawdown, so the market resolves PERPETUAL (PERPETUAL iff il == 0)
        assertEq(uint8(pre.marketState), uint8(MarketState.PERPETUAL), "a liquidity breach alone must not leave PERPETUAL");
        assertEq(toUint256(pre.jtImpermanentLoss), 0, "a PERPETUAL commit must carry zero JT impermanent loss");

        address depositor = makeAddr("UNDER_PROVISIONED_LT_DEPOSITOR");
        accessManager.grantRole(LT_LP_ROLE, depositor, 0);
        quoteToken.mint(address(this), quoteUnit);
        quoteToken.approve(address(balancerVault), quoteUnit);
        // The pool's token amounts follow the sorted registration order, so map the quote leg through the index
        uint256[2] memory quoteOnlyLegs;
        quoteOnlyLegs[1 - stPoolTokenIndex] = quoteUnit;
        balancerVault.mintPoolTokensTo(address(bpt), depositor, 1e18, quoteOnlyLegs);

        uint256 previewedShares = liquidityTranche.previewDeposit(toTrancheUnits(1e18));
        vm.startPrank(depositor);
        bpt.approve(address(liquidityTranche), 1e18);
        vm.expectEmit(address(liquidityTranche));
        emit IRoycoVaultTranche.Deposit(depositor, depositor, toTrancheUnits(1e18), previewedShares);
        uint256 mintedShares = liquidityTranche.deposit(toTrancheUnits(1e18), depositor);
        vm.stopPrank();

        assertEq(mintedShares, previewedShares, "under-provisioned LT deposit: preview/execute share parity");
        assertEq(liquidityTranche.balanceOf(depositor), mintedShares, "under-provisioned LT deposit: shares must land on the receiver");
        // The LT owned ledger is the 6e18 auto-seed plus this deposit (slippage mode precludes reinvested BPT)
        assertEq(toUint256(kernel.getState().totalLTAssets), 6e18 + 1e18, "under-provisioned LT deposit: totalLTAssets must be credited exactly");
    }

    /**
     * @notice An in-kind LT deposit is never coverage-gated, even into a coverage-breached FIXED_TERM market
     *         (it adds no senior exposure, so it cannot consume coverage capacity)
     * @dev Production conforms: DepositLogic.sol:148 passes enforce=false for the in-kind path, and only the
     *      multi-asset LT deposit with a collateral leg enforces the gates (DepositLogic.sol:214), which is
     *      consistent because that path mints senior shares.
     *      Breach derivation: -20% shared PnL drops the collateral mark 130e18 -> 104e18, so
     *      deltaST = -floor(26e18 x 100e18 / 130e18) = -20e18 and deltaJT = -6e18 as the residual. JT absorbs its
     *      own 6e18 loss and covers ST's 20e18 in full -> jtEff = 4e18, stEff = 100e18, and the IL ledger books
     *      6e18 + 20e18 = 26e18. coverageUtilization = 104e18 x 0.2 / 4e18 = 5.2e18 exactly (> WAD, below the
     *      6.4667e18 liquidation threshold, so no PERPETUAL arm of the resolution predicate fires: il = 26e18 is
     *      neither zero nor dust, the term has not elapsed, and JT is not wiped, so the covered drawdown enters
     *      FIXED_TERM carrying the full 26e18 IL, and in-kind LT deposits stay enabled). A FIXED_TERM commit
     *      structurally carries zero fee and premium fields (any nonzero fee needs the IL fully recovered, which
     *      resolves PERPETUAL instead)
     */
    function test_LTDeposit_inKind_neverCoverageGated_evenWhileCoverageBreached() public {
        _seedMarket(ST_SEED_WHOLE * collateralUnit, JT_SEED_WHOLE * collateralUnit);
        applySTPnL(-2000);

        // Commit the breach so the pre-deposit market state is unambiguous (the sync return is authoritative
        // and the assertion must not depend on any read in the same test transaction picking up the previous
        // operation's transient rate cache)
        SyncedAccountingState memory pre = _sync();
        assertEq(pre.coverageUtilizationWAD, 5.2e18, "coverageUtilization must be 104e18 x 0.2 / 4e18 = 5.2e18 exactly");
        assertEq(uint8(pre.marketState), uint8(MarketState.FIXED_TERM), "covered drawdown must enter FIXED_TERM");
        // FIXED_TERM always carries the drawdown (marketState == PERPETUAL iff jtImpermanentLoss == 0): the
        // ledger books the 6e18 JT loss plus the 20e18 coverage applied to the senior loss
        assertEq(toUint256(pre.jtImpermanentLoss), 26e18, "the FIXED_TERM commit must carry the full 6e18 + 20e18 = 26e18 IL");
        // A FIXED_TERM commit structurally takes no fees and pays no premium (a loss sync has no gain to split)
        assertEq(toUint256(pre.ltLiquidityPremium), 0, "a FIXED_TERM commit must pay zero liquidity premium");
        assertEq(toUint256(pre.stProtocolFee), 0, "a FIXED_TERM commit must take zero ST fee");
        assertEq(toUint256(pre.jtProtocolFee), 0, "a FIXED_TERM commit must take zero JT fee");
        assertEq(toUint256(pre.ltProtocolFee), 0, "a FIXED_TERM commit must take zero LT fee");

        address depositor = makeAddr("COVERAGE_BREACHED_LT_DEPOSITOR");
        accessManager.grantRole(LT_LP_ROLE, depositor, 0);
        quoteToken.mint(address(this), quoteUnit);
        quoteToken.approve(address(balancerVault), quoteUnit);
        // The pool's token amounts follow the sorted registration order, so map the quote leg through the index
        uint256[2] memory quoteOnlyLegs;
        quoteOnlyLegs[1 - stPoolTokenIndex] = quoteUnit;
        balancerVault.mintPoolTokensTo(address(bpt), depositor, 1e18, quoteOnlyLegs);

        uint256 previewedShares = liquidityTranche.previewDeposit(toTrancheUnits(1e18));
        vm.startPrank(depositor);
        bpt.approve(address(liquidityTranche), 1e18);
        vm.expectEmit(address(liquidityTranche));
        emit IRoycoVaultTranche.Deposit(depositor, depositor, toTrancheUnits(1e18), previewedShares);
        uint256 mintedShares = liquidityTranche.deposit(toTrancheUnits(1e18), depositor);
        vm.stopPrank();

        assertEq(mintedShares, previewedShares, "coverage-breached LT deposit: preview/execute share parity");
        assertEq(liquidityTranche.balanceOf(depositor), mintedShares, "coverage-breached LT deposit: shares must land on the receiver");
        assertEq(toUint256(kernel.getState().totalLTAssets), 6e18 + 1e18, "coverage-breached LT deposit: totalLTAssets must be credited exactly");
        // The FIXED_TERM transition must still be committed after the deposit settles
        assertEq(uint8(accountant.getState().lastMarketState), uint8(MarketState.FIXED_TERM), "market must remain FIXED_TERM after the deposit");
    }
}
