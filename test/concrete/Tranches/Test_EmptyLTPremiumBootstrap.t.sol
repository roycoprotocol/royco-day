// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { LT_LP_ROLE } from "../../../src/factory/Roles.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { MarketParamsConfig } from "../../utils/FixtureTypes.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_EmptyLTPremiumBootstrap
 * @notice Investigates whether the liquidity premium (ST shares staged for the LT) can be minted while the LT
 *         tranche has ZERO shares, and what that causes.
 * @dev The premium mint (`mintLiquidityPremiumShares`) targets the kernel and does not read LT tranche supply,
 *      so it can accrue with no LT holders. To reach that state we deploy with minLiquidity == 0 (so ST deposits
 *      are NOT liquidity-gated and can land with no LT depth) but keep a non-zero LT yield-share curve (so the LDM
 *      still pays a premium at zero utilization). We also zero the LT protocol fee so the LT-fee mint does not
 *      itself create the first LT share.
 */
contract Test_EmptyLTPremiumBootstrap is DayMarketTestBase {
    uint256 internal stUnit;
    uint256 internal quoteUnit;

    function setUp() public {
        MarketParamsConfig memory p = defaultParams();
        p.minLiquidityWAD = 0; // ST deposits are not liquidity-gated, so no LT depth is required first
        p.ltYieldShareProtocolFeeWAD = 0; // no LT protocol fee, so the fee mint does not create the first LT share
        // ltCurve stays non-zero ([0.02, 0.1, 0.3]) so the LDM pays a premium even at zero liquidity utilization
        _deployMarket(cellA(), p);
        stUnit = 10 ** uint256(cell.collateralAsset.decimals);
        quoteUnit = 10 ** uint256(cell.quoteAsset.decimals);
    }

    function _idle() internal view returns (uint256) {
        return kernel.getState().ltOwnedSeniorTrancheShares;
    }

    function _mintBptTo(address _to, uint256 _bptAmount, uint256 _quoteLeg) internal {
        quoteToken.mint(address(this), _quoteLeg);
        quoteToken.approve(address(balancerVault), _quoteLeg);
        uint256[2] memory legs;
        legs[1 - stPoolTokenIndex] = _quoteLeg;
        balancerVault.mintPoolTokensTo(address(bpt), _to, _bptAmount, legs);
    }

    /// @notice Premium ST shares ARE minted for the LT while the LT tranche supply is zero, and the first LT
    ///         depositor then captures that staged premium 1:1 (bootstrap pricing), a windfall funded by the
    ///         dilution of plain ST holders.
    function test_PremiumMintedToEmptyLT_thenFirstDepositorCapturesIt() public {
        // Seed ST/JT only. No LT deposit, and minLiquidity == 0 means none is required for the ST deposit.
        _seedMarket(1000 * stUnit, 500 * stUnit);
        assertEq(liquidityTranche.totalSupply(), 0, "precondition: the LT tranche has zero shares");

        // Arm venue slippage so any premium stays staged as idle ST shares (rather than reinvesting into BPT),
        // making the "ST shares minted for an empty LT" observation direct.
        setVenueSlippageMode(true);

        // Accrue senior yield and sync a few times: the LDM pays a premium at zero utilization, staged as idle ST shares.
        for (uint256 i = 0; i < 5; ++i) {
            applySTPnL(2000); // +20% senior yield
            _warpAndRefreshFeed(7 days);
            syncVenuePrices();
            _sync();
        }

        uint256 stagedPremium = _idle();
        uint256 pooledBpt = toUint256(kernel.getState().totalLTAssets);
        emit log_named_uint("staged idle ST shares", stagedPremium);
        emit log_named_uint("pooled BPT held for LT", pooledBpt);
        // KEY OBSERVATION: value (ST shares and/or reinvested BPT) was accrued for the LT while the LT has zero shares.
        assertGt(stagedPremium + pooledBpt, 0, "premium value was accrued for an empty LT");
        assertGt(stagedPremium, 0, "premium ST shares were staged for the LT");
        assertEq(liquidityTranche.totalSupply(), 0, "the LT tranche still has zero shares (no fee mint, no deposit)");

        // The staged premium sits as senior shares custodied by the kernel for a non-existent LT.
        uint256 premiumNAV = toUint256(kernel.convertCollateralAssetsToValue(toTrancheUnits(stagedPremium)));
        assertGt(premiumNAV, 0, "the staged premium has positive NAV");

        // Now a first LT depositor arrives with a TINY BPT position and captures the whole staged premium.
        address dave = makeAddr("DAVE_FIRST_LP");
        accessManager.grantRole(LT_LP_ROLE, dave, 0);
        uint256 daveBpt = 1e18; // one BPT unit, tiny next to the accumulated premium
        _mintBptTo(dave, daveBpt, quoteUnit); // ~1 quote wei of backing, NAV ~ 1e18
        uint256 daveDepositNAV = toUint256(kernel.convertLTAssetsToValue(toTrancheUnits(daveBpt)));

        vm.startPrank(dave);
        bpt.approve(address(liquidityTranche), daveBpt);
        uint256 daveShares = liquidityTranche.deposit(toTrancheUnits(daveBpt), dave);
        vm.stopPrank();

        // Dave is now 100% of LT supply; his position's effective NAV is his BPT PLUS all the staged premium.
        assertEq(liquidityTranche.totalSupply(), daveShares, "Dave owns the entire LT supply");
        uint256 daveEffNAV = toUint256(liquidityTranche.totalAssets().nav);

        // The windfall: Dave deposited ~daveDepositNAV but owns ~daveDepositNAV + stagedPremiumNAV.
        assertGt(daveEffNAV, daveDepositNAV * 2, "Dave's position is worth far more than his deposit (captured premium)");
        emit log_named_uint("dave deposit NAV", daveDepositNAV);
        emit log_named_uint("staged premium NAV (captured)", premiumNAV);
        emit log_named_uint("dave effective NAV after deposit", daveEffNAV);
    }
}
