// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { WAD } from "../../../src/libraries/Constants.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";

/**
 * @title Test_ReinvestLiquidityPremiumGate_Kernel
 * @notice The liquidity premium reinvestment's slippage gate: the minimum-BPT-out floor is
 *         ceil(fairBPT x (WAD - maxReinvestmentSlippage) / WAD), pinned from both sides of the exact boundary,
 *         plus the partial-amount path that deploys only part of the idle pile
 * @dev The gate is the manipulation defense on the single-sided add: a venue fill one wei under it must be a
 *      tolerated no-op (the idle liquidity premium senior shares stay claimable), a fill exactly at it must deploy
 */
contract Test_ReinvestLiquidityPremiumGate_Kernel is DayMarketTestBase {
    function setUp() public virtual {
        _deployMarket(cellA(), defaultParams());
    }

    /**
     * @notice The gate floors the add at minOut = ceil(fairBPT x (WAD - maxSlippage) / WAD), pinned from BOTH sides
     *         on the same idle pile: a venue minting exactly minOut - 1 defers (tolerated failure, idle pile and
     *         committed state untouched), a venue minting exactly minOut deploys the entire pile with its event
     * @dev Attacker intent: park the venue's fill exactly at the threshold to check the comparison direction, an
     *      off-by-one here either strands healthy reinvestments or accepts a sandwiched fill one wei too poor
     */
    function test_ReinvestLiquidityPremium_MinBptOutBoundary_BothSides() public {
        uint256 idleShares = _accrueIdlePremiumSeniorShares();

        // Derive the gate's exact floor from committed state, mirroring the production formula:
        //   fairNAV  = floor(stEff x idleShares / stSupply)                (ValuationLogic._convertToValue)
        //   fairBPT  = floor(bptSupply x fairNAV / TVL)                    (ltConvertNAVUnitsToTrancheUnits)
        //   minOut   = ceil(fairBPT x (WAD - maxSlippage) / WAD)
        uint256 stEff = toUint256(accountant.getState().lastSTEffectiveNAV);
        uint256 stSupply = seniorTranche.totalSupply();
        uint256 fairNAV = Math.mulDiv(stEff, idleShares, stSupply, Math.Rounding.Floor);
        uint256 fairBPT = Math.mulDiv(balancerVault.totalSupply(address(bpt)), fairNAV, bptOracle.computeTVL(), Math.Rounding.Floor);
        uint256 minOut = Math.mulDiv(fairBPT, WAD - params.maxReinvestmentSlippageWAD, WAD, Math.Rounding.Ceil);
        assertGt(minOut, 1, "arrange: the boundary must be expressible from both sides");

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
        uint256 half = idleShares / 2;
        assertGt(half, 0, "arrange: the pile must split into two nonzero parts");

        // The same gate formula, applied to only the deployed half
        uint256 stEff = toUint256(accountant.getState().lastSTEffectiveNAV);
        uint256 fairNAV = Math.mulDiv(stEff, half, seniorTranche.totalSupply(), Math.Rounding.Floor);
        uint256 fairBPT = Math.mulDiv(balancerVault.totalSupply(address(bpt)), fairNAV, bptOracle.computeTVL(), Math.Rounding.Floor);
        uint256 minOut = Math.mulDiv(fairBPT, WAD - params.maxReinvestmentSlippageWAD, WAD, Math.Rounding.Ceil);

        uint256 ltOwnedBefore = toUint256(kernel.getState().ltOwnedYieldBearingAssets);

        balancerVault.setNextBptOutOverride(minOut);
        vm.expectEmit(address(kernel));
        emit IRoycoDayKernel.LiquidityPremiumReinvested(half, toTrancheUnits(minOut));
        vm.prank(MARKET_OPS_ADMIN);
        kernel.reinvestLiquidityPremium(half);

        assertEq(kernel.getState().ltOwnedSeniorTrancheShares, idleShares - half, "the undeployed remainder must stay idle and claimable");
        assertEq(toUint256(kernel.getState().ltOwnedYieldBearingAssets), ltOwnedBefore + minOut, "exactly the partial add's BPT must be credited");
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
