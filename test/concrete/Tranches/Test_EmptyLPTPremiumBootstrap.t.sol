// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { LPT_LP_ROLE } from "../../../src/factory/Roles.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { MarketParamsConfig } from "../../utils/FixtureTypes.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_EmptyLPTPremiumBootstrap
 * @notice Investigates whether the liquidity premium (ST shares staged for the LPT) can be minted while the LPT
 *         tranche has ZERO shares, and what that causes.
 * @dev The premium mint (`mintLiquidityPremiumShares`) targets the kernel and does not read LPT tranche supply,
 *      so it can accrue with no LPT holders. To reach that state we deploy with minLiquidity == 0 (so ST deposits
 *      are NOT liquidity-gated and can land with no LPT depth) but keep a non-zero LPT yield-share curve (so the LDM
 *      still pays a premium at zero utilization). We also zero the LPT protocol fee so the LPT-fee mint does not
 *      itself create the first LPT share.
 */
contract Test_EmptyLPTPremiumBootstrap is DayMarketTestBase {
    uint256 internal stUnit;
    uint256 internal quoteUnit;

    function setUp() public {
        MarketParamsConfig memory p = defaultParams();
        p.minLiquidityWAD = 0; // ST deposits are not liquidity-gated, so no LPT depth is required first
        p.lptYieldShareProtocolFeeWAD = 0; // no LPT protocol fee, so the fee mint does not create the first LPT share
        // lptCurve stays non-zero ([0.02, 0.1, 0.3]) so the LDM pays a premium even at zero liquidity utilization
        _deployMarket(cellA(), p);
        stUnit = 10 ** uint256(cell.collateralAsset.decimals);
        quoteUnit = 10 ** uint256(cell.quoteAsset.decimals);
    }

    function _idle() internal view returns (uint256) {
        return kernel.getState().lptOwnedSeniorTrancheShares;
    }

    function _mintBptTo(address _to, uint256 _bptAmount, uint256 _quoteLeg) internal {
        quoteToken.mint(address(this), _quoteLeg);
        quoteToken.approve(address(balancerVault), _quoteLeg);
        uint256[2] memory legs;
        legs[1 - stPoolTokenIndex] = _quoteLeg;
        balancerVault.mintPoolTokensTo(address(bpt), _to, _bptAmount, legs);
    }

    /// @notice Premium ST shares ARE minted for the LPT while the LPT tranche supply is zero, but the first LPT
    ///         depositor does NOT capture that staged premium: the bootstrap mint prices their deposit against the
    ///         idle-inclusive LPT effective NAV (so they pay for the premium up front) and the redemption scaler
    ///         carries the virtual-shares offset, so their actual redeemable claim never exceeds their deposit.
    ///         The idle-inclusive totalAssets().nav is the whole-tranche effective NAV, not the depositor's claim,
    ///         so this anchors on previewRedeem of the depositor's own shares instead.
    function test_PremiumMintedToEmptyLPT_thenFirstDepositorCannotCaptureIt() public {
        // Seed ST/JT only. No LPT deposit, and minLiquidity == 0 means none is required for the ST deposit.
        _seedMarket(1000 * stUnit, 500 * stUnit);
        assertEq(liquidityProviderTranche.totalSupply(), 0, "precondition: the LPT tranche has zero shares");

        // Arm venue slippage so any premium stays staged as idle ST shares (rather than reinvesting into BPT),
        // making the "ST shares minted for an empty LPT" observation direct.
        setVenueSlippageMode(true);

        // Accrue senior yield and sync a few times: the LDM pays a premium at zero utilization, staged as idle ST shares.
        for (uint256 i = 0; i < 5; ++i) {
            applySTPnL(2000); // +20% senior yield
            _warpAndRefreshFeed(7 days);
            syncVenuePrices();
            _sync();
        }

        uint256 stagedPremium = _idle();
        uint256 pooledBpt = toUint256(kernel.getState().totalLPTAssets);
        emit log_named_uint("staged idle ST shares", stagedPremium);
        emit log_named_uint("pooled BPT held for LPT", pooledBpt);
        // KEY OBSERVATION: value (ST shares and/or reinvested BPT) was accrued for the LPT while the LPT has zero shares.
        assertGt(stagedPremium + pooledBpt, 0, "premium value was accrued for an empty LPT");
        assertGt(stagedPremium, 0, "premium ST shares were staged for the LPT");
        assertEq(liquidityProviderTranche.totalSupply(), 0, "the LPT tranche still has zero shares (no fee mint, no deposit)");

        // The staged premium sits as senior shares custodied by the kernel for a non-existent LPT.
        uint256 premiumNAV = toUint256(kernel.convertCollateralAssetsToValue(toTrancheUnits(stagedPremium)));
        assertGt(premiumNAV, 0, "the staged premium has positive NAV");

        // Now a first LPT depositor arrives. Their BPT position is comparable to the accrued premium, so a naive
        // bootstrap-1:1 reading of totalAssets().nav would suggest they double their money on the staged premium.
        address dave = makeAddr("DAVE_FIRST_LP");
        accessManager.grantRole(LPT_LP_ROLE, dave, 0);
        uint256 daveBpt = 400e18; // quote-backed 1:1 so its NAV is 400e18, on the order of the staged premium
        _mintBptTo(dave, daveBpt, 400 * quoteUnit);
        uint256 daveDepositNAV = toUint256(kernel.convertLPTAssetsToValue(toTrancheUnits(daveBpt)));

        vm.startPrank(dave);
        bpt.approve(address(liquidityProviderTranche), daveBpt);
        uint256 daveShares = liquidityProviderTranche.deposit(toTrancheUnits(daveBpt), dave);
        vm.stopPrank();

        // Dave is now 100% of LPT supply, so the whole-tranche totalAssets().nav (his BPT PLUS all the staged
        // premium) reads far above his deposit, the misleading idle-inclusive figure the old test anchored on.
        assertEq(liquidityProviderTranche.totalSupply(), daveShares, "Dave owns the entire LPT supply");
        uint256 daveEffNAV = toUint256(liquidityProviderTranche.totalAssets().nav);
        assertGt(daveEffNAV, daveDepositNAV, "the idle-inclusive whole-tranche NAV reads above the deposit, but it is not Dave's claim");

        // RE-ANCHOR: Dave's actual redeemable claim is his own shares' previewRedeem, which prices in the bootstrap
        // mint (deposit valued against the idle-inclusive effective NAV) and the redemption virtual-shares offset.
        AssetClaims memory daveClaim = liquidityProviderTranche.previewRedeem(daveShares);
        uint256 daveClaimNAV = toUint256(daveClaim.nav);
        emit log_named_uint("dave shares", daveShares);
        emit log_named_uint("dave deposit NAV", daveDepositNAV);
        emit log_named_uint("dave whole-tranche totalAssets NAV (NOT his claim)", daveEffNAV);
        emit log_named_uint("dave redeemable claim NAV (previewRedeem)", daveClaimNAV);

        // The staged premium is NOT a windfall: the depositor's redeemable claim never exceeds their deposit. The
        // bootstrap mint against P + D over the virtual single share mints s = floor(D/P) shares, and the redeem
        // scaler pays (P + D) x s / (s + 1) <= D since P x floor(D/P) <= D always, so the premium cannot be extracted.
        assertLe(daveClaimNAV, daveDepositNAV, "the first LP's redeemable claim never exceeds their deposit (no premium windfall)");

        // Dave captures only a strict fraction of the staged idle senior shares, the rest stays custodied for the
        // LPT tranche as a whole, the direct signature of the mint pricing and redemption offset neutralizing the premium.
        assertLt(daveClaim.stShares, stagedPremium, "the depositor claims only part of the staged idle senior shares, not the whole premium");
        assertGt(daveClaim.stShares, 0, "the depositor does claim a scaled slice of the idle senior shares");
    }
}
