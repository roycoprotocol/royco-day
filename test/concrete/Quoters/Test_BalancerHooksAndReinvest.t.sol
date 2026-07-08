// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { stdError } from "../../../lib/forge-std/src/StdError.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { WAD } from "../../../src/libraries/Constants.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { MockBPTOracle } from "../../mocks/MockBPTOracle.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";

/**
 * @title Test_ReinvestLiquidityPremiumGate_Kernel
 * @notice The liquidity premium reinvestment's slippage gate: the minimum-BPT-out floor pinned from both sides of the
 *         exact boundary, the partial-amount path that deploys only part of the idle pile, and two edges where the
 *         gate's fair-value floor degrades — rounding to zero (the add runs unprotected) and dividing by a zero
 *         oracle TVL (every tranche operation reverts)
 * @dev The gate is the manipulation defense on the single-sided add: a venue fill one wei under it must be a
 *      tolerated no-op (the idle liquidity premium senior shares stay claimable), a fill exactly at it must deploy
 */
contract Test_ReinvestLiquidityPremiumGate_Kernel is DayMarketTestBase {
    function setUp() public virtual {
        _deployMarket(cellA(), defaultParams());
    }

    /**
     * @notice The gate floors the add at exactly 0.999e18 BPT for the seeded pile (hand-derived below), pinned from
     *         BOTH sides: a venue minting exactly one wei less defers (tolerated failure, idle pile and committed
     *         state untouched), a venue minting exactly the floor deploys the entire pile with its event
     * @dev Attacker intent: park the venue's fill exactly at the threshold to check the comparison direction, an
     *      off-by-one here either strands healthy reinvestments or accepts a sandwiched fill one wei too poor
     */
    function test_ReinvestLiquidityPremium_MinBptOutBoundary_BothSides() public {
        uint256 idleShares = _accrueIdlePremiumSeniorShares();
        _assertSeededGateFixture(idleShares);

        // The gate's floor, hand-derived from the pinned fixture state rather than by re-running the production
        // conversion chain: the whole idle pile values to floor(108e18 x 940733772342427093 / 101599247412982126058)
        // = 999999999999999999 at the committed senior rate — the 1e18 premium it was minted for, less a single
        // floor-rounding wei. The pool's NAV per BPT is exactly 1.0 (6.000001e18 BPT backing 6.000001e18 of value),
        // so the fair BPT is that same figure, and the 0.1% max reinvestment slippage discount floors the add at
        // ceil(999999999999999999 x 999 / 1000) = ceil(999e15 - 0.999) = 999000000000000000
        uint256 minOut = 0.999e18;

        uint256 ltOwnedBefore = toUint256(kernel.getState().ltOwnedYieldBearingAssets);
        uint256 committedLtRawNAVBefore = toUint256(accountant.getState().lastLTRawNAV);

        // Side 1: one wei under the gate, the inner add reverts, the failure is tolerated, and NOTHING moves
        balancerVault.setNextBptOutOverride(minOut - 1);
        vm.prank(MARKET_OPS_ADMIN);
        kernel.reinvestLiquidityPremium(type(uint256).max);
        assertEq(kernel.getState().ltOwnedSeniorTrancheShares, idleShares, "under the gate: the idle pile must be untouched");
        assertEq(toUint256(kernel.getState().ltOwnedYieldBearingAssets), ltOwnedBefore, "under the gate: no BPT may be credited");
        assertEq(toUint256(accountant.getState().lastLTRawNAV), committedLtRawNAVBefore, "under the gate: the committed LT raw NAV must be unmoved");

        // Side 2: exactly the gate, the entire pile deploys, exactly minOut BPT is credited, and the event fires
        balancerVault.setNextBptOutOverride(minOut);
        vm.expectEmit(address(kernel));
        emit IRoycoDayKernel.LiquidityPremiumReinvested(idleShares, toTrancheUnits(minOut));
        vm.prank(MARKET_OPS_ADMIN);
        kernel.reinvestLiquidityPremium(type(uint256).max);
        assertEq(kernel.getState().ltOwnedSeniorTrancheShares, 0, "at the gate: the entire idle pile must deploy");
        assertEq(toUint256(kernel.getState().ltOwnedYieldBearingAssets), ltOwnedBefore + minOut, "at the gate: exactly minOut BPT must be credited");
    }

    /**
     * @notice A partial reinvestment deploys only the requested senior shares and leaves the remainder idle and
     *         claimable, with the event carrying the exact partial amounts
     * @dev The remainder staying in ltOwnedSeniorTrancheShares is what keeps a redeeming LT holder whole on the
     *      undeployed slice, so a partial deploy that silently zeroed the pile would burn the premium
     */
    function test_ReinvestLiquidityPremium_PartialAmount_LeavesRemainderIdle() public {
        uint256 idleShares = _accrueIdlePremiumSeniorShares();
        _assertSeededGateFixture(idleShares);

        // Deploy the floor-rounded half of the pinned pile: 940733772342427093 / 2 = 470366886171213546
        uint256 half = 470366886171213546;

        // The gate's floor for the half, hand-derived from the pinned fixture state: the half values to
        // floor(108e18 x 470366886171213546 / 101599247412982126058) = 499999999999999999 at the committed senior
        // rate (half the premium less a floor-rounding wei), the pool's NAV per BPT is exactly 1.0 so the fair BPT
        // is the same figure, and the 0.1% discount floors the add at ceil(499999999999999999 x 999 / 1000)
        // = ceil(4995e14 - 0.999) = 499500000000000000
        uint256 minOut = 0.4995e18;

        uint256 ltOwnedBefore = toUint256(kernel.getState().ltOwnedYieldBearingAssets);

        balancerVault.setNextBptOutOverride(minOut);
        vm.expectEmit(address(kernel));
        emit IRoycoDayKernel.LiquidityPremiumReinvested(half, toTrancheUnits(minOut));
        vm.prank(MARKET_OPS_ADMIN);
        kernel.reinvestLiquidityPremium(half);

        assertEq(kernel.getState().ltOwnedSeniorTrancheShares, idleShares - half, "the undeployed remainder must stay idle and claimable");
        assertEq(toUint256(kernel.getState().ltOwnedYieldBearingAssets), ltOwnedBefore + minOut, "exactly the partial add's BPT must be credited");
    }

    /**
     * @notice When the oracle's fair-value floor rounds to zero, the reinvestment defers: the add is skipped and the
     *         premium shares stay idle and claimable, exactly as a breached gate leaves them
     * @dev The gate marks the staged premium to its fair BPT as floor(bptSupply x premiumValue / TVL) discounted by
     *      the slippage tolerance. Once the pool's TVL dwarfs the premium's value that floor rounds to 0, and
     *      ceil(0 x 999 / 1000) is still 0. A zero floor would send minBptAmountOut = 0 to the venue — no slippage
     *      protection at all — so rather than let a ~1e18-value pile clear for as little as 1 wei, the reinvestment
     *      returns early and leaves the shares idle. This is the exact regime where a sandwich costs the LT the most
     *      relative to what it receives, so deferring is the safe outcome.
     */
    function test_ReinvestLiquidityPremium_ZeroMinOutFloor_DefersAddAndLeavesSharesIdle() public {
        uint256 idleShares = _accrueIdlePremiumSeniorShares();
        _assertSeededGateFixture(idleShares);

        // Sync once more: the +10% gain is already committed, so this sync accrues no new premium and the reinvest
        // call's own internal pre-op sync below also mints nothing, leaving the idle pile intact for the explicit reinvestment
        vm.prank(SYNC_OPERATOR);
        kernel.syncTrancheAccounting();
        assertEq(kernel.getState().ltOwnedSeniorTrancheShares, idleShares, "arrange: the no-gain sync must not touch the idle pile");

        // Pin the oracle to a TVL that rounds the fair-value floor to zero. The pile values to under 1e18 NAV
        // (999999999999999999, pinned above) and the BPT supply is 6.000001e18, so the fair-BPT numerator
        // bptSupply x premiumValue is under 6.1e36 — any TVL above that rounds floor(numerator / TVL) to 0, and
        // 1e40 clears the boundary by more than a thousandfold
        bptOracle.setMode(MockBPTOracle.Mode.MANUAL);
        bptOracle.setTVL(1e40);

        uint256 ltOwnedBefore = toUint256(kernel.getState().ltOwnedYieldBearingAssets);

        // With a zero fair-value floor the reinvestment returns early before any venue add: it never reaches the
        // Vault, so no fill can occur and the idle pile is left untouched
        vm.prank(MARKET_OPS_ADMIN);
        kernel.reinvestLiquidityPremium(idleShares);

        assertEq(kernel.getState().ltOwnedSeniorTrancheShares, idleShares, "the idle pile stays idle and claimable when the fair-value floor rounds to zero");
        assertEq(toUint256(kernel.getState().ltOwnedYieldBearingAssets), ltOwnedBefore, "no BPT is credited: the zero-floor add is deferred, not executed");
    }

    /**
     * @notice With the BPT oracle marking a zero TVL while BPT supply is positive, the sync that would mint a
     *         pending liquidity premium reverts with a division-by-zero — and because every tranche operation runs
     *         that same pre-op sync, every operation reverts until the oracle heals
     * @dev The reinvestment attempt is designed to be non-blocking: the venue add runs behind a tolerated low-level
     *      call so a failed deploy leaves the premium idle instead of reverting the operation. But the gate's floor
     *      is computed BEFORE that tolerated frame, and converting the premium's NAV to BPT divides by the oracle
     *      TVL — zero TVL with a nonzero BPT supply skips the empty-pool early-return and reverts in the conversion
     *      itself. The pending senior gain never commits (every sync reverts before committing), so no sync, no
     *      deposit, and no redemption can run until the oracle reports a sane TVL.
     */
    function test_SyncTrancheAccounting_RevertsWhenOracleTVLZeroWithBPTSupply() public {
        _seedMarket(100e18, 50e18);

        // The first sync initializes the premium accrual clock
        vm.prank(SYNC_OPERATOR);
        kernel.syncTrancheAccounting();

        // Arm venue slippage so that even if the deploy attempt were reached it would defer and keep the premium
        // idle — proving the revert below comes from the floor computation, not from the tolerated venue add
        setVenueSlippageMode(true);

        // Accrue senior gain across a real time window so the NEXT sync mints a nonzero premium (the fee path only
        // attempts a reinvestment when premium shares actually minted, so a nonzero pending premium is what arms it)
        _warpAndRefreshFeed(1 days);
        applySTPnL(1000); // +10%

        // Poison the oracle: zero TVL against a live pool. The seeded pool carries 6.000001e18 BPT, so the
        // fair-value conversion's zero-supply early-return does not fire and the division by TVL == 0 is reached
        bptOracle.setMode(MockBPTOracle.Mode.MANUAL);
        bptOracle.setTVL(0);
        assertGt(balancerVault.totalSupply(address(bpt)), 0, "arrange: the poisoned state requires live BPT supply against the zero TVL");

        // The sync itself reverts: the premium mint's deploy attempt divides by the zero TVL while computing the gate floor
        vm.prank(SYNC_OPERATOR);
        vm.expectRevert(stdError.divisionError);
        kernel.syncTrancheAccounting();

        // An ordinary senior deposit reverts identically: its pre-op sync mints the same pending premium and hits
        // the same division, so the oracle outage locks out depositors with no exposure to the liquidity tranche
        stJtVault.mintShares(ST_PROVIDER, 1e18);
        vm.startPrank(ST_PROVIDER);
        stJtVault.approve(address(seniorTranche), 1e18);
        vm.expectRevert(stdError.divisionError);
        seniorTranche.deposit(toTrancheUnits(1e18), ST_PROVIDER);
        vm.stopPrank();

        // Nothing committed and nothing staged: the premium was never minted, so the gain is still pending and every
        // future operation will retry the same reverting path until the oracle reports a nonzero TVL again
        assertEq(kernel.getState().ltOwnedSeniorTrancheShares, 0, "no premium may stage while every sync reverts");
    }

    // =============================
    // Helpers
    // =============================

    /**
     * @dev Accrues an idle liquidity premium senior share pile: arm venue slippage so the sync's reinvestment
     *      attempt defers, accrue senior gain across a real time window, sync, then disarm so the boundary tests
     *      control the venue's mint exactly via the one-shot override. Returns the idle ltOwnedSeniorTrancheShares
     */
    function _accrueIdlePremiumSeniorShares() internal returns (uint256 idleShares) {
        _seedMarket(100e18, 50e18);

        // The first sync initializes the premium accrual clock
        vm.prank(SYNC_OPERATOR);
        kernel.syncTrancheAccounting();

        // Arm the 50% unbalanced haircut so the gated reinvestment deterministically fails and the premium stays idle
        setVenueSlippageMode(true);

        // Accrue senior gain across a real time window, then sync: the LT premium mints as idle senior shares
        _warpAndRefreshFeed(1 days);
        applySTPnL(1000); // +10%
        vm.prank(SYNC_OPERATOR);
        kernel.syncTrancheAccounting();

        idleShares = kernel.getState().ltOwnedSeniorTrancheShares;
        assertGt(idleShares, 0, "arrange: the premium must be idle (venue slippage armed)");

        setVenueSlippageMode(false);
    }

    /**
     * @dev Pins the exact post-accrual fixture state every hand-computed gate literal in this contract is derived
     *      from, so a fixture drift fails loudly here instead of silently invalidating a pinned floor.
     *      Derivation from the seeded market (100e18 senior, 50e18 junior, +10% vault rate over one day):
     *      - the senior raw NAV moves 100e18 to 110e18, a 10e18 senior gain, and the junior's pinned 20% risk
     *        premium routes 2e18 of it to the junior side, so the committed senior effective NAV is 108e18
     *      - the liquidity tranche's pinned 10% premium carves 1e18 out of the gain, and the 10% senior protocol
     *        fee takes 0.7e18 (10% of the 7e18 senior residual after the 2e18 and 1e18 carve-outs), so the
     *        pre-existing 100e18 senior shares retain 108e18 - 1e18 - 0.7e18 = 106.3e18
     *      - premium shares minted: floor(1e18 x 100e18 / 106.3e18) = 940733772342427093 idle senior shares
     *      - fee shares minted: floor(0.7e18 x 100e18 / 106.3e18) = 658513640639698965, so the senior supply lands
     *        at 100e18 + 940733772342427093 + 658513640639698965 = 101599247412982126058
     *      - the pool holds 6.000001e18 BPT backing 6.000001e18 of quote-leg value (the 6e6-quote-wei auto-seed
     *        plus the genesis backing of the dead minimum supply), so its NAV per BPT is exactly 1.0
     */
    function _assertSeededGateFixture(uint256 _idleShares) internal view {
        assertEq(_idleShares, 940733772342427093, "fixture pin: the idle premium pile");
        assertEq(toUint256(accountant.getState().lastSTEffectiveNAV), 108e18, "fixture pin: the committed senior effective NAV");
        assertEq(seniorTranche.totalSupply(), 101599247412982126058, "fixture pin: the post-mint senior supply");
        assertEq(balancerVault.totalSupply(address(bpt)), 6000001000000000000, "fixture pin: the pool's BPT supply");
        assertEq(bptOracle.computeTVL(), 6000001000000000000, "fixture pin: the pool's oracle TVL (NAV per BPT exactly 1.0)");
    }
}

/**
 * @title Test_MultiAssetPreviewParity_LiquidityTranche
 * @notice Multi-asset LT deposit and redeem preview parity: exact at zero venue fee, a compliant lower bound under
 *         a nonzero venue fee, and exact for the multi-asset redemption
 * @dev Preview-vs-execution parity is the one property a preview cannot prove about itself, so each test runs both
 *      paths in the same block and compares
 */
contract Test_MultiAssetPreviewParity_LiquidityTranche is DayMarketTestBase {
    function setUp() public virtual {
        _deployMarket(cellA(), defaultParams());
    }

    /**
     * @notice Zero venue fee gives EXACT preview parity: a fair (fee-less) add leaves TVL-per-BPT unchanged, so the
     *         executed path's post-add mark equals the preview's discarded-quote pre-add mark and the share math
     *         coincides to the wei
     */
    function test_LTDepositMultiAsset_PreviewParityExact_ZeroVenueFee() public {
        (uint256 previewShares, uint256 mintedShares) = _previewThenExecuteMultiAssetDeposit(5e18, 5e6);
        assertEq(mintedShares, previewShares, "zero venue fee: the multi-asset deposit preview must equal execution in the same block");
        assertGt(mintedShares, 0, "arrange: the deposit must be non-degenerate");
    }

    /**
     * @notice With a venue fee the preview is a compliant LOWER bound (a preview must never overestimate):
     *         execution marks the fresh BPT AFTER the add, when the depositor's own fee has already accrued to the
     *         pool's TVL-per-BPT, while the preview's quote discards that post-add uplift
     * @dev The gap is bounded by the fee itself: the depositor recaptures at most their own 30 bps, so
     *      preview <= minted <= ceil(preview x (1 + fee))
     */
    function test_LTDepositMultiAsset_PreviewLowerBoundsExecution_WithVenueFee() public {
        balancerVault.setUnbalancedFeeBps(30);
        (uint256 previewShares, uint256 mintedShares) = _previewThenExecuteMultiAssetDeposit(5e18, 5e6);

        assertGe(mintedShares, previewShares, "the preview must never overestimate the minted shares");
        assertLe(
            mintedShares,
            Math.mulDiv(previewShares, WAD + 0.003e18, WAD, Math.Rounding.Ceil),
            "the preview gap must be bounded by the 30 bps venue fee the depositor recaptures"
        );
    }

    /// @notice previewRedeemMultiAsset equals the executed redeemMultiAsset (senior tranche claims plus quote out), same block
    function test_LTRedeemMultiAsset_PreviewMatchesExecution() public {
        _seedMarket(100e18, 50e18);
        _seedLT(10e18, 0, 10e6); // quote-only LT depth on top of the auto-seed

        uint256 ltShares = liquidityTranche.balanceOf(LT_PROVIDER) / 2;
        assertGt(ltShares, 0, "arrange: LT_PROVIDER must hold shares to redeem");

        vm.startPrank(LT_PROVIDER);
        (AssetClaims memory previewClaims, uint256 previewQuote) = liquidityTranche.previewRedeemMultiAsset(ltShares);
        (AssetClaims memory claims, uint256 quoteOut) = liquidityTranche.redeemMultiAsset(ltShares, 0, 0, LT_PROVIDER, LT_PROVIDER);
        vm.stopPrank();

        assertEq(quoteOut, previewQuote, "the quote leg preview must equal execution");
        assertEq(keccak256(abi.encode(claims)), keccak256(abi.encode(previewClaims)), "the senior tranche claims preview must equal execution");
    }

    // =============================
    // Helpers
    // =============================

    /**
     * @dev Seeds the market, refreshes the transient senior share rate cache (the seeding syncs above ran inside
     *      THIS test transaction and the last pre-op cache write predates the senior supply, so the venue would
     *      price the ST leg at the 1-wei floor, a state production never sees since every user interaction is its
     *      own transaction and syncs pre-op), then previews and executes the same multi-asset deposit in one block
     */
    function _previewThenExecuteMultiAssetDeposit(uint256 _stLeg, uint256 _quoteLeg) internal returns (uint256 previewShares, uint256 mintedShares) {
        _seedMarket(100e18, 50e18);
        vm.prank(SYNC_OPERATOR);
        kernel.syncTrancheAccounting();

        stJtVault.mintShares(LT_PROVIDER, _stLeg);
        quoteToken.mint(LT_PROVIDER, _quoteLeg);

        vm.startPrank(LT_PROVIDER);
        stJtVault.approve(address(liquidityTranche), _stLeg);
        quoteToken.approve(address(liquidityTranche), _quoteLeg);
        previewShares = liquidityTranche.previewDepositMultiAsset(_stLeg, _quoteLeg);
        mintedShares = liquidityTranche.depositMultiAsset(_stLeg, _quoteLeg, 0, LT_PROVIDER);
        vm.stopPrank();
    }
}
