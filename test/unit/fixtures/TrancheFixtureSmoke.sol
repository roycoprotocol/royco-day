// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { AssetClaims, MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { Math, toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { FixtureCell } from "../../base/fixtures/FixtureTypes.sol";
import { defaultParams } from "../../base/fixtures/MarketParams.sol";
import { TrancheFixture } from "../../base/fixtures/TrancheFixture.sol";

/**
 * @title TrancheFixtureSmoke
 * @notice Phase A smoke battery run against every token-matrix cell (09-phase-a-spec.md §5)
 * @dev One concrete per cell A-D supplies the cell and the hand-derived quoter expectation. Every expected number
 *      is derived from the spec (CLAUDE.md, testing-strategy.md §1.3) BEFORE execution, never read back from the
 *      code: raw NAVs are `shares x rateWAD x oraclePrice` scaled to WAD, conservation is the exact two-term
 *      identity, and the premium, fee, and redemption expectations are the floor-arithmetic derivations shown at
 *      the constants below
 * @dev This file carries NO test_FINDING_* pins. Findings 1-2 were retracted (production conforms to the spec,
 *      see docs/testing/agent-notes/13-spec-divergence-findings.md) and are covered by the two positive
 *      deposit-gating conformance tests below, and finding 3's pin lives in test/unit/accountant/CarveOut.t.sol
 */
abstract contract TrancheFixtureSmoke is TrancheFixture {
    // =============================
    // Seed Constants (whole tokens, scaled per cell in setUp)
    // =============================

    /// @dev Whole ST/JT vault shares seeded. Coverage after seed: (100 + 30) x 0.2 / 30 = 0.8667 <= 1, gate clears
    uint256 internal constant ST_SEED_WHOLE = 100;
    uint256 internal constant JT_SEED_WHOLE = 30;

    /**
     * @dev Explicitly seeded LT depth: 20 BPT against a 20-whole-quote leg (NAV-per-BPT stays 1.0)
     * @dev The fixture's ST-deposit auto-seed already added ceil(100 x 0.05) + 1 = 6 whole quote = 6e18 NAV of
     *      depth (TrancheFixture._ensureLiquidityCapacityForSTDeposit), so total seeded ltRawNAV = 26e18
     */
    uint256 internal constant LT_SEED_BPT = 20e18;

    /// @dev Spec-derived total seeded LT raw NAV: 6e18 (auto-seed) + 20e18 (explicit) at 1.0 quote price
    uint256 internal constant SEEDED_LT_RAW_NAV = 26e18;

    // =============================
    // Canonical +100bps Sync Expectations (hand-derived BEFORE execution)
    // =============================

    /**
     * @dev Full derivation of the canonical sync used by the lifecycle and redemption tests: _seedDefault, then
     *      applySTPnL(100), a 1-day warp, syncVenuePrices, and one sync. Every value below is floor arithmetic
     *      from the spec and defaultParams, and is cell-independent because tranche shares, NAV units, and BPT
     *      all carry 18 decimals in every cell.
     *
     *      Checkpoint after _seedDefault (all seed ops share the deploy block, so no time-weighted yield share
     *      has accrued): stRaw = stEff = 100e18, jtRaw = jtEff = 30e18, ltRaw = 26e18, il = 0, PERPETUAL.
     *
     *      applySTPnL(100) moves the shared vault rate 1.0 -> 1.01, so the fresh marks are stRaw = 101e18 and
     *      jtRaw = 30.3e18 (dST = +1e18, dJT = +0.3e18). The up-path waterfall with defaultParams:
     *      1. JT gain leg: jtNetGain = 0.3e18 > effectiveDust (1 + 1 wei), so jtFee books
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
     *         and jtEff = 30.3e18 + 0.2e18 = 30.5e18. Conservation: 101 + 30.3 == 100.8 + 30.5 exactly
     */
    uint256 internal constant POST_PNL_RATE_WAD = 1.01e18;
    uint256 internal constant POST_SYNC_ST_EFF_NAV = 100.8e18;
    uint256 internal constant POST_SYNC_JT_EFF_NAV = 30.5e18;
    uint256 internal constant LT_LIQUIDITY_PREMIUM_NAV = 0.1e18;
    uint256 internal constant ST_PROTOCOL_FEE_NAV = 0.07e18;
    uint256 internal constant JT_PROTOCOL_FEE_NAV = 0.05e18;
    uint256 internal constant LT_PROTOCOL_FEE_NAV = 0.01e18;

    /// @dev JT's cross-claim on ST raw NAV after the sync: jtEff 30.5e18 - jtRaw 30.3e18 (the premium is a senior-asset claim)
    uint256 internal constant JT_CLAIM_ON_ST_RAW_NAV = 0.2e18;

    /**
     * @dev Senior carve-out share mints (the F11 joint price): the premium and the ST fee both price against the
     *      pre-sync 100e18 supply over the retained NAV 100.8e18 - 0.1e18 - 0.07e18 = 100.63e18, each floored:
     *      LT_PREMIUM_SHARES = floor(100e18 x 0.1e18 / 100.63e18) = 99373944151843386
     *      ST_FEE_SHARES = floor(100e18 x 0.07e18 / 100.63e18) = 69561760906290370
     */
    uint256 internal constant LT_PREMIUM_SHARES = 99_373_944_151_843_386;
    uint256 internal constant ST_FEE_SHARES = 69_561_760_906_290_370;
    uint256 internal constant POST_SYNC_ST_SUPPLY = 100e18 + LT_PREMIUM_SHARES + ST_FEE_SHARES;

    /**
     * @dev The sync's inline single-sided add DEPLOYS the premium, and the reason is derivable: the venue prices
     *      the pool's senior leg live through the production IRateProvider.getRate, which inside the sync reads
     *      the just-cached effective share rate floor(1e18 x 100.8e18 / POST_SYNC_ST_SUPPLY) = 1.0063e18, and the
     *      seeded pool's NAV-per-BPT is exactly 1.0 (the genesis seed backs the dead minimum supply at 1.0), so
     *      the add mints fair value:
     *      REINVESTED_BPT = floor(LT_PREMIUM_SHARES x 1.0063e18 / 1e18) = 99999999999999999
     *      against the gate's minimum of
     *      ceil(floor(LT_PREMIUM_SHARES x 100.8e18 / POST_SYNC_ST_SUPPLY) x 0.999) = 99900000000000000,
     *      leaving only wei-level flooring as slippage, far inside the 10bps defaultParams gate. The deployed
     *      senior leg marks the oracle TVL up by the identical amount (same price, same floor), so the committed
     *      post-sync ltRawNAV is exactly SEEDED_LT_RAW_NAV + REINVESTED_BPT and no idle premium remains staged
     */
    uint256 internal constant REINVESTED_BPT = 99_999_999_999_999_999;
    uint256 internal constant POST_DEPLOY_LT_RAW_NAV = SEEDED_LT_RAW_NAV + REINVESTED_BPT;

    /**
     * @dev JT and LT protocol fee share mints, each priced against the post-fee NAV over the pre-mint supply:
     *      JT_FEE_SHARES = floor(30e18 x 0.05e18 / (30.5e18 - 0.05e18)) = 49261083743842364
     *      LT_FEE_SHARES = floor(26e18 x 0.01e18 / (POST_DEPLOY_LT_RAW_NAV - 0.01e18)) = 9965504024530471
     *      (the LT fee prices against the post-sync LT effective NAV, which is the post-deploy ltRawNAV because
     *      the premium deployed inline and left nothing staged)
     */
    uint256 internal constant JT_FEE_SHARES = 49_261_083_743_842_364;
    uint256 internal constant POST_SYNC_JT_SUPPLY = 30e18 + JT_FEE_SHARES;
    uint256 internal constant LT_FEE_SHARES = 9_965_504_024_530_471;
    uint256 internal constant POST_SYNC_LT_SUPPLY = 26e18 + LT_FEE_SHARES;

    /**
     * @dev Exact redemption NAV expectations (cell-independent, all inputs above):
     *      ST nav, 10e18 of POST_SYNC_ST_SUPPLY: floor(100.8e18 x 10e18 / 100168935705058133756) = 10.063e18
     *      JT nav, 3e18 of POST_SYNC_JT_SUPPLY: floor(30.5e18 x 3e18 / 30049261083743842364) = 3.045e18
     *      The LT redemption expectations re-mark the pool's senior leg at the live post-redemption share rate,
     *      which carries the cell's ST-withdrawal truncation, so they are derived inline in the test
     */
    uint256 internal constant ST_REDEEM_EXPECTED_NAV = 10.063e18;
    uint256 internal constant JT_REDEEM_EXPECTED_NAV = 3.045e18;

    // =============================
    // Per-Cell State
    // =============================

    /// @dev One whole ST/JT vault share in tranche units (10^stDecimals)
    uint256 internal stUnit;

    /// @dev One whole quote token (10^quoteDecimals)
    uint256 internal quoteUnit;

    // =============================
    // Cell Parameterization
    // =============================

    /// @notice The token-matrix cell this concrete runs against
    function _smokeCell() internal pure virtual returns (FixtureCell memory);

    /**
     * @notice The spec-derived NAV (WAD) of one whole ST asset for this cell
     * @dev Hand-derived per cell in the concrete: 10^stDecimals share-wei at the cell's initialRateWAD converts to
     *      whole underlying, and the 1.0 price feed maps one whole underlying to exactly 1e18 NAV units
     */
    function _expectedSTUnitNAV() internal pure virtual returns (uint256);

    // =============================
    // Setup
    // =============================

    function setUp() public virtual {
        _deployMarket(_smokeCell(), defaultParams());
        stUnit = 10 ** uint256(cell.stAsset.decimals);
        quoteUnit = 10 ** uint256(cell.quoteAsset.decimals);
    }

    /// @dev Seeds the canonical smoke market: 30 whole JT, 100 whole ST (plus the 6e18 auto-seed), 20e18 quote-only BPT
    function _seedDefault() internal {
        _seedMarket(ST_SEED_WHOLE * stUnit, JT_SEED_WHOLE * stUnit);
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
        assertEq(kernel.ST_ASSET(), address(stJtVault), "kernel ST asset wiring");
        assertEq(kernel.JT_ASSET(), address(stJtVault), "kernel JT asset wiring");
        assertEq(kernel.LT_ASSET(), address(bpt), "kernel LT asset wiring");
        assertEq(kernel.QUOTE_ASSET(), address(quoteToken), "kernel quote asset wiring");
    }

    // =============================
    // Quoter Unit Identity
    // =============================

    /**
     * @notice One whole ST asset must quote to the cell's hand-derived NAV at the initial rate and a 1.0 oracle price
     * @dev Spec derivation: NAV_UNIT is always WAD-scaled, so 10^stDecimals share-wei x initialRateWAD (1.0)
     *      x oracle price (1.0) == exactly 1e18 NAV wei, independent of share or underlying decimals
     */
    function test_Quoter_oneWholeSTAssetQuotesToSpecDerivedNAV() public view {
        assertEq(toUint256(kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(stUnit))), _expectedSTUnitNAV(), "ST unit -> NAV identity");
        // The JT quoter shares the identical asset, so the identity must be byte-identical
        assertEq(toUint256(kernel.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(stUnit))), _expectedSTUnitNAV(), "JT unit -> NAV identity");
        // And the inverse conversion must return exactly one whole ST asset
        assertEq(toUint256(kernel.stConvertNAVUnitsToTrancheUnits(toNAVUnits(_expectedSTUnitNAV()))), stUnit, "NAV -> ST unit inverse identity");
    }

    // =============================
    // Lifecycle: Seed, PnL, Sync
    // =============================

    /**
     * @notice The canonical lifecycle: seed, +100bps senior PnL, sync, wei-exact conservation, exact premium flow
     * @dev Spec-derived marks: 100 whole ST shares at rate 1.01 and price 1.0 -> stRawNAV = 101e18 exactly, and
     *      30 whole JT shares -> jtRawNAV = 30.3e18 exactly. Conservation stRaw + jtRaw == stEff + jtEff holds at
     *      wei precision (CLAUDE.md invariant) on both the returned state and the persisted checkpoint. The LT
     *      premium pipeline is asserted end to end against the derivation at the constants, pinning WHICH branch
     *      the gated single-sided add takes: with the venue's senior leg priced live through the production rate
     *      provider and slippage mode off, the inline add MUST take the DEPLOYED branch (fair value clears the
     *      10bps gate with only wei-level flooring), so the premium can never silently mint nothing
     */
    function test_Lifecycle_pnlSyncConservesNAVAndKernelStaysSolvent() public {
        _seedDefault();
        assertEq(toUint256(liquidityTranche.getRawNAV()), SEEDED_LT_RAW_NAV, "seeded ltRawNAV must be 6e18 auto-seed + 20e18 explicit");

        applySTPnL(100);
        _warpAndRefreshFeed(1 days);
        syncVenuePrices();
        SyncedAccountingState memory state = _sync();

        // Raw marks are spec-derived exactly from the rate and oracle price
        assertEq(toUint256(state.stRawNAV), 101e18, "stRawNAV must be 100 whole shares x 1.01 x 1.0 = 101e18");
        assertEq(toUint256(state.jtRawNAV), 30.3e18, "jtRawNAV must be 30 whole shares x 1.01 x 1.0 = 30.3e18");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "an up-only sync must stay PERPETUAL");

        // The full yield split lands exactly per the derivation at the constants (F4 premium math)
        assertEq(toUint256(state.stEffectiveNAV), POST_SYNC_ST_EFF_NAV, "stEff must be 100e18 + 0.7e18 residual + 0.1e18 LT premium");
        assertEq(toUint256(state.jtEffectiveNAV), POST_SYNC_JT_EFF_NAV, "jtEff must be 30e18 + 0.3e18 gain + 0.2e18 risk premium");
        assertEq(toUint256(state.ltLiquidityPremium), LT_LIQUIDITY_PREMIUM_NAV, "liqShare must be floor(1e18 x 0.1e18 x 1d / (1d x WAD)) = 0.1e18");
        assertEq(toUint256(state.stProtocolFee), ST_PROTOCOL_FEE_NAV, "stFee must be floor(0.7e18 x 0.1) = 0.07e18");
        assertEq(toUint256(state.jtProtocolFee), JT_PROTOCOL_FEE_NAV, "jtFee must be floor(0.3e18 x 0.1) + floor(0.2e18 x 0.1) = 0.05e18");
        assertEq(toUint256(state.ltProtocolFee), LT_PROTOCOL_FEE_NAV, "ltFee must be floor(0.1e18 x 0.1) = 0.01e18");

        // Wei-exact two-term conservation on the returned state and the persisted checkpoint
        assertNAVConservation(state.stRawNAV, state.jtRawNAV, state.stEffectiveNAV, state.jtEffectiveNAV, "sync return");
        IRoycoDayAccountant.RoycoDayAccountantState memory acct = accountant.getState();
        assertNAVConservation(acct.lastSTRawNAV, acct.lastJTRawNAV, acct.lastSTEffectiveNAV, acct.lastJTEffectiveNAV, "persisted checkpoint");

        // The premium and ST fee mints land exactly per the F11 carve-out
        assertEq(seniorTranche.totalSupply(), POST_SYNC_ST_SUPPLY, "ST supply must be 100e18 + premium shares + fee shares exactly");

        // Branch pin: the sync's inline add must DEPLOY (live fair-value pricing, see REINVESTED_BPT): the idle
        // buffer drains to zero, the pool's senior leg holds exactly the minted premium shares, and the BPT
        // depth and committed ltRawNAV both grow by exactly the fair-value mint
        IRoycoDayKernel.RoycoDayKernelState memory ks = kernel.getState();
        assertEq(ks.ltOwnedSeniorTrancheShares, 0, "deployed branch: no staged premium may remain with live venue pricing");
        assertEq(seniorTranche.balanceOf(address(kernel)), 0, "deployed branch: the premium shares must sit in the pool, not the kernel");
        assertEq(toUint256(ks.ltOwnedYieldBearingAssets), POST_DEPLOY_LT_RAW_NAV, "deployed branch: the BPT ledger must grow by exactly REINVESTED_BPT");
        assertEq(bpt.balanceOf(address(kernel)), POST_DEPLOY_LT_RAW_NAV, "deployed branch: the kernel BPT balance must equal the owned ledger");
        assertEq(balancerVault.getPoolBalances(address(bpt))[stPoolTokenIndex], LT_PREMIUM_SHARES, "deployed branch: the pool's senior leg must hold the premium");
        assertEq(toUint256(state.ltRawNAV), POST_DEPLOY_LT_RAW_NAV, "deployed branch: committed ltRawNAV must include the deployed depth");
        assertEq(toUint256(liquidityTranche.getRawNAV()), POST_DEPLOY_LT_RAW_NAV, "deployed branch: the live ltRawNAV read must match the committed mark");

        // Solvency: the kernel's custodied balances must exactly equal every owned-asset ledger entry
        assertEq(toUint256(ks.stOwnedYieldBearingAssets), ST_SEED_WHOLE * stUnit, "ST owned ledger must equal the seeded shares");
        assertEq(toUint256(ks.jtOwnedYieldBearingAssets), JT_SEED_WHOLE * stUnit, "JT owned ledger must equal the seeded shares");
        assertEq(
            stJtVault.balanceOf(address(kernel)),
            (ST_SEED_WHOLE + JT_SEED_WHOLE) * stUnit,
            "kernel vault-share balance must equal stOwned + jtOwned exactly"
        );
    }

    // =============================
    // Redemptions (gate-respecting, preview parity, exact payout deltas)
    // =============================

    /**
     * @notice One gate-respecting redemption per tranche pays exactly the previewed and hand-derived claims
     * @dev Preview parity is the property (claims == preview byte-for-byte) and every previewed leg is pinned to
     *      its floor-arithmetic expectation from the constants' derivation. The NAV expectations are exact and
     *      cell-independent, the asset legs go through the quoter identity (floor(nav x stUnit / 1.01e18)) and so
     *      carry the cell's decimals, computed inline. Gate sanity at the chosen sizes: ST 10e18 shares is
     *      ungated, JT 3e18 shares leaves covUtil ~= (90.7 + 27.3) x 0.2 / 27.5 = 0.86 <= 1, and LT 5.2e18 shares
     *      leaves liqUtil ~= 90.7 x 0.05 / 20.9 = 0.22 <= 1, so every redemption must clear
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
        assertEq(liquidityTranche.balanceOf(LT_PROVIDER), 26e18, "LT provider must hold the seeded 26e18 shares");

        // Senior: redeem a tenth (10e18 shares). Claim derivation: jtEff 30.5e18 exceeds jtRaw 30.3e18 by the
        // 0.2e18 risk premium, so JT holds a 0.2e18 claim on ST raw and ST's own-raw claim is
        // 101e18 - 0.2e18 = 100.8e18 with no JT leg. The redeemer's slice is proportional and floored:
        // nav = floor(100.8e18 x 10e18 / POST_SYNC_ST_SUPPLY) = 10.063e18 exactly, and
        // stAssets = floor(floor(100.8e18 x stUnit / 1.01e18) x 10e18 / POST_SYNC_ST_SUPPLY)
        uint256 stShares = seniorTranche.balanceOf(ST_PROVIDER) / 10;
        AssetClaims memory stPreviewed = seniorTranche.previewRedeem(stShares);
        uint256 stBalBefore = stJtVault.balanceOf(ST_PROVIDER);
        vm.prank(ST_PROVIDER);
        AssetClaims memory stClaims = seniorTranche.redeem(stShares, ST_PROVIDER, ST_PROVIDER);
        assertEq(stClaims.stAssets, stPreviewed.stAssets, "ST redeem: stAssets preview parity");
        assertEq(stClaims.jtAssets, stPreviewed.jtAssets, "ST redeem: jtAssets preview parity");
        assertEq(stClaims.nav, stPreviewed.nav, "ST redeem: nav preview parity");
        assertEq(toUint256(stClaims.nav), ST_REDEEM_EXPECTED_NAV, "ST redeem: nav must equal the hand-derived expectation exactly");
        uint256 expectedStAssetsWithdrawn = Math.mulDiv(Math.mulDiv(POST_SYNC_ST_EFF_NAV, stUnit, POST_PNL_RATE_WAD), stShares, POST_SYNC_ST_SUPPLY);
        assertEq(toUint256(stClaims.stAssets), expectedStAssetsWithdrawn, "ST redeem: stAssets must equal the derived own-raw claim slice");
        assertEq(toUint256(stClaims.jtAssets), 0, "ST redeem: no JT-raw claim exists on the up path");
        assertEq(
            stJtVault.balanceOf(ST_PROVIDER) - stBalBefore,
            toUint256(stClaims.stAssets) + toUint256(stClaims.jtAssets),
            "ST redeem: payout must equal the claimed vault shares"
        );

        // Junior: redeem a tenth (3e18 shares). The ST redemption reduced stRaw and stEff by the same withdrawn
        // NAV and left jtRaw 30.3e18 / jtEff 30.5e18 untouched, so JT's claims are unchanged: the 0.2e18
        // cross-claim on ST raw plus its full 30.3e18 own raw, each floored through the quoter and the
        // proportional scale. nav = floor(30.5e18 x 3e18 / POST_SYNC_JT_SUPPLY) = 3.045e18 exactly
        uint256 jtShares = juniorTranche.balanceOf(JT_PROVIDER) / 10;
        AssetClaims memory jtPreviewed = juniorTranche.previewRedeem(jtShares);
        uint256 jtBalBefore = stJtVault.balanceOf(JT_PROVIDER);
        vm.prank(JT_PROVIDER);
        AssetClaims memory jtClaims = juniorTranche.redeem(jtShares, JT_PROVIDER, JT_PROVIDER);
        assertEq(jtClaims.stAssets, jtPreviewed.stAssets, "JT redeem: stAssets preview parity");
        assertEq(jtClaims.jtAssets, jtPreviewed.jtAssets, "JT redeem: jtAssets preview parity");
        assertEq(jtClaims.nav, jtPreviewed.nav, "JT redeem: nav preview parity");
        assertEq(toUint256(jtClaims.nav), JT_REDEEM_EXPECTED_NAV, "JT redeem: nav must equal the hand-derived expectation exactly");
        assertEq(
            toUint256(jtClaims.stAssets),
            Math.mulDiv(Math.mulDiv(JT_CLAIM_ON_ST_RAW_NAV, stUnit, POST_PNL_RATE_WAD), jtShares, POST_SYNC_JT_SUPPLY),
            "JT redeem: stAssets must equal the derived cross-claim slice"
        );
        assertEq(
            toUint256(jtClaims.jtAssets),
            Math.mulDiv(Math.mulDiv(30.3e18, stUnit, POST_PNL_RATE_WAD), jtShares, POST_SYNC_JT_SUPPLY),
            "JT redeem: jtAssets must equal the derived own-raw claim slice"
        );
        assertEq(
            stJtVault.balanceOf(JT_PROVIDER) - jtBalBefore,
            toUint256(jtClaims.stAssets) + toUint256(jtClaims.jtAssets),
            "JT redeem: payout must equal the claimed vault shares"
        );

        // Liquidity: redeem a fifth (5.2e18 shares) in-kind. The premium DEPLOYED at the sync (see
        // REINVESTED_BPT), so there is no idle leg and the redemption pays a pure BPT slice. The pool's senior
        // leg re-marks at the live post-redemption share rate, which carries the cell's ST-withdrawal
        // truncation, so the expectation chains it inline:
        // stRawAfter = floor((100 x stUnit - wSt) x 1.01e18 / stUnit) for the wSt vault-share wei the ST
        // redemption withdrew, stEffAfter = 100.8e18 - (101e18 - stRawAfter) (the JT redemption reduces only
        // jtEff), the senior supply is 10e18 lower after the burn, so the live share rate is
        // rateAfter = floor(1e18 x stEffAfter / (POST_SYNC_ST_SUPPLY - 10e18)), the oracle TVL is the seeded
        // quote depth plus floor(LT_PREMIUM_SHARES x rateAfter / 1e18), and the kernel's 26e18 + REINVESTED_BPT
        // of the BPT supply marks to nav = floor(floor(TVL x ltOwned / bptSupply) x 5.2e18 / POST_SYNC_LT_SUPPLY)
        uint256 ltShares = liquidityTranche.balanceOf(LT_PROVIDER) / 5;
        uint256 expectedLtNav;
        uint256 expectedLtAssets;
        {
            uint256 stRawAfter = Math.mulDiv(100 * stUnit - expectedStAssetsWithdrawn, POST_PNL_RATE_WAD, stUnit);
            uint256 rateAfter = Math.mulDiv(1e18, POST_SYNC_ST_EFF_NAV - (101e18 - stRawAfter), POST_SYNC_ST_SUPPLY - 10e18);
            // bptSupplySeeded is the whole seeded supply including the genesis backing, captured above at 1.0 NAV-per-BPT
            uint256 poolTVL = bptSupplySeeded + Math.mulDiv(LT_PREMIUM_SHARES, rateAfter, 1e18);
            uint256 ltRawAtRedeem = Math.mulDiv(poolTVL, POST_DEPLOY_LT_RAW_NAV, bptSupplySeeded + REINVESTED_BPT);
            expectedLtNav = Math.mulDiv(ltRawAtRedeem, ltShares, POST_SYNC_LT_SUPPLY);
            expectedLtAssets = Math.mulDiv(Math.mulDiv(bptSupplySeeded + REINVESTED_BPT, ltRawAtRedeem, poolTVL), ltShares, POST_SYNC_LT_SUPPLY);
        }
        AssetClaims memory ltPreviewed = liquidityTranche.previewRedeem(ltShares);
        uint256 ltBptBefore = bpt.balanceOf(LT_PROVIDER);
        uint256 ltStSharesBefore = seniorTranche.balanceOf(LT_PROVIDER);
        vm.prank(LT_PROVIDER);
        AssetClaims memory ltClaims = liquidityTranche.redeem(ltShares, LT_PROVIDER, LT_PROVIDER);
        assertEq(ltClaims.ltAssets, ltPreviewed.ltAssets, "LT redeem: ltAssets preview parity");
        assertEq(ltClaims.stShares, ltPreviewed.stShares, "LT redeem: stShares preview parity");
        assertEq(ltClaims.nav, ltPreviewed.nav, "LT redeem: nav preview parity");
        assertEq(toUint256(ltClaims.nav), expectedLtNav, "LT redeem: nav must equal the derived re-marked BPT slice exactly");
        assertEq(toUint256(ltClaims.ltAssets), expectedLtAssets, "LT redeem: the BPT slice must equal the derived expectation exactly");
        assertEq(ltClaims.stShares, 0, "LT redeem: no idle premium shares exist after the deployed reinvestment");
        assertEq(bpt.balanceOf(LT_PROVIDER) - ltBptBefore, toUint256(ltClaims.ltAssets), "LT redeem: BPT payout must equal the claim");
        assertEq(seniorTranche.balanceOf(LT_PROVIDER) - ltStSharesBefore, ltClaims.stShares, "LT redeem: staged-premium ST shares must equal the claim");
    }

    // =============================
    // ST Deposit Preview Parity
    // =============================

    /**
     * @notice An ST deposit mints exactly the previewed shares
     * @dev Spec derivation: at rate 1.0 the freshly seeded market has supply == stEff == 100e18 (initial mint is
     *      one share-wei per NAV-wei with no accrued yield or fees), so 5 whole ST assets == 5e18 NAV must mint
     *      exactly 5e18 shares, and preview must match execution byte-for-byte
     */
    function test_STDeposit_previewMatchesExecutionExactly() public {
        _seedDefault();
        uint256 assets = 5 * stUnit;
        stJtVault.mintShares(ST_PROVIDER, assets);

        uint256 previewedShares = seniorTranche.previewDeposit(toTrancheUnits(assets));
        uint256 sharesBefore = seniorTranche.balanceOf(ST_PROVIDER);
        vm.startPrank(ST_PROVIDER);
        stJtVault.approve(address(seniorTranche), assets);
        uint256 mintedShares = seniorTranche.deposit(toTrancheUnits(assets), ST_PROVIDER);
        vm.stopPrank();

        assertEq(mintedShares, previewedShares, "ST deposit: preview/execute share parity");
        assertEq(seniorTranche.balanceOf(ST_PROVIDER) - sharesBefore, mintedShares, "ST deposit: minted shares must land on the receiver");
        assertEq(mintedShares, 5e18, "ST deposit: 5 whole assets at a 1.0 share price must mint exactly 5e18 shares");
    }

    // =============================
    // Deposit-Gating Spec Conformance (findings 1 and 2 investigated and RETRACTED, see
    // docs/testing/agent-notes/13-spec-divergence-findings.md — production matches the spec)
    // =============================

    /**
     * @notice An in-kind LT deposit is never liquidity-gated, even into an under-provisioned market (CLAUDE.md,
     *         "Deposits are enabled at all times")
     * @dev Production conforms: DepositLogic.sol:306 passes enforce=false for the in-kind path, so the accountant's
     *      Operation.LT_DEPOSIT gate never runs for it (finding 1 retracted on this evidence).
     *      Breach derivation: +100% senior PnL takes stEff to [180e18, 200e18] (residual after a <= 20e18 risk
     *      share), so liquidityUtilization = stEff x 0.05 / 6e18 >= 1.5e18 > WAD, while depth stays at the 6e18
     *      auto-seed (the staged premium is excluded from ltRawNAV and slippage mode blocks its reinvestment).
     *      The 1e18-BPT deposit does not heal the breach and must still succeed
     */
    function test_LTDeposit_neverLiquidityGated_evenWhileUnderProvisioned() public {
        _seedMarket(ST_SEED_WHOLE * stUnit, JT_SEED_WHOLE * stUnit);
        setVenueSlippageMode(true);
        applySTPnL(10_000);
        _warpAndRefreshFeed(1 days);

        // Commit the breach so the pre-deposit market state is unambiguous (the sync return is authoritative,
        // a view preview in the same test transaction would read the previous operation's transient rate cache)
        SyncedAccountingState memory pre = _sync();
        assertGe(pre.liquidityUtilizationWAD, 1.5e18, "liquidityUtilization must read breached (>= 180e18 x 0.05 / 6e18)");

        address depositor = makeAddr("SMOKE_LT_DEPOSITOR");
        quoteToken.mint(address(this), quoteUnit);
        quoteToken.approve(address(balancerVault), quoteUnit);
        // The pool's token amounts follow the sorted registration order, so map the quote leg through the index
        uint256[2] memory quoteOnlyLegs;
        quoteOnlyLegs[1 - stPoolTokenIndex] = quoteUnit;
        balancerVault.mintPoolTokensTo(address(bpt), depositor, 1e18, quoteOnlyLegs);

        uint256 previewedShares = liquidityTranche.previewDeposit(toTrancheUnits(1e18));
        vm.startPrank(depositor);
        bpt.approve(address(liquidityTranche), 1e18);
        uint256 mintedShares = liquidityTranche.deposit(toTrancheUnits(1e18), depositor);
        vm.stopPrank();

        assertEq(mintedShares, previewedShares, "under-provisioned LT deposit: preview/execute share parity");
        assertEq(liquidityTranche.balanceOf(depositor), mintedShares, "under-provisioned LT deposit: shares must land on the receiver");
        // The LT owned ledger is the 6e18 auto-seed plus this deposit (slippage mode precludes reinvested BPT)
        assertEq(toUint256(kernel.getState().ltOwnedYieldBearingAssets), 6e18 + 1e18, "under-provisioned LT deposit: ltOwned must be credited exactly");
    }

    /**
     * @notice An in-kind LT deposit is never coverage-gated, even into a coverage-breached FIXED_TERM market
     *         (it adds no senior exposure, CLAUDE.md invariants)
     * @dev Production conforms: DepositLogic.sol:306 passes enforce=false for the in-kind path, and only the
     *      multi-asset LT deposit with an ST leg enforces the gates (DepositLogic.sol:370), which is
     *      spec-consistent because that path mints senior shares (finding 2 retracted on this evidence).
     *      Breach derivation: -20% shared PnL gives stRaw 80e18, jtRaw 24e18, fully covered ST loss 20e18 ->
     *      jtEff = 4e18, covUtil = (80 + 24) x 0.2 / 4 = 5.2e18 exactly (> WAD, below the 6.4667e18 liquidation
     *      threshold, so the covered drawdown enters FIXED_TERM where in-kind LT deposits stay enabled)
     */
    function test_LTDeposit_inKind_neverCoverageGated_evenWhileCoverageBreached() public {
        _seedMarket(ST_SEED_WHOLE * stUnit, JT_SEED_WHOLE * stUnit);
        applySTPnL(-2000);

        // Commit the breach so the pre-deposit market state is unambiguous (the sync return is authoritative,
        // a view preview in the same test transaction would read the previous operation's transient rate cache)
        SyncedAccountingState memory pre = _sync();
        assertEq(pre.coverageUtilizationWAD, 5.2e18, "coverageUtilization must be (80 + 24) x 0.2 / 4 = 5.2e18 exactly");
        assertEq(uint8(pre.marketState), uint8(MarketState.FIXED_TERM), "covered drawdown must enter FIXED_TERM");

        address depositor = makeAddr("SMOKE_LT_DEPOSITOR");
        quoteToken.mint(address(this), quoteUnit);
        quoteToken.approve(address(balancerVault), quoteUnit);
        // The pool's token amounts follow the sorted registration order, so map the quote leg through the index
        uint256[2] memory quoteOnlyLegs;
        quoteOnlyLegs[1 - stPoolTokenIndex] = quoteUnit;
        balancerVault.mintPoolTokensTo(address(bpt), depositor, 1e18, quoteOnlyLegs);

        uint256 previewedShares = liquidityTranche.previewDeposit(toTrancheUnits(1e18));
        vm.startPrank(depositor);
        bpt.approve(address(liquidityTranche), 1e18);
        uint256 mintedShares = liquidityTranche.deposit(toTrancheUnits(1e18), depositor);
        vm.stopPrank();

        assertEq(mintedShares, previewedShares, "coverage-breached LT deposit: preview/execute share parity");
        assertEq(liquidityTranche.balanceOf(depositor), mintedShares, "coverage-breached LT deposit: shares must land on the receiver");
        assertEq(toUint256(kernel.getState().ltOwnedYieldBearingAssets), 6e18 + 1e18, "coverage-breached LT deposit: ltOwned must be credited exactly");
        // The FIXED_TERM transition must still be committed after the deposit settles
        assertEq(uint8(accountant.getState().lastMarketState), uint8(MarketState.FIXED_TERM), "market must remain FIXED_TERM after the deposit");
    }
}
