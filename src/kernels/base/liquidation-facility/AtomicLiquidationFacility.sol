// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoLiquidator } from "../../../interfaces/IRoycoLiquidator.sol";
import { MAX_TRANCHE_UNITS, MAX_TRANCHE_UNITS, WAD, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../../../libraries/Constants.sol";
import { BASE_UNIT, Math, NAV_UNIT, TRANCHE_UNIT, UnitsMathLib, toNAVUnits, toUint256 } from "../../../libraries/Units.sol";
import { AssetClaims, IRoycoAccountant, RoycoKernel, SyncedAccountingState, TrancheType } from "../RoycoKernel.sol";

/**
 * @title AtomicLiquidationFacility
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Abstract contract providing atomic (flash) liquidation functionality for Royco markets
 * @dev Implements a liquidation mechanism where liquidators can seize underwater senior tranche positions
 *      in a single atomic transaction. The liquidator receives the demanded assets plus a bonus from
 *      junior tranche claims, and pays back the fair value in the base asset as settlement.
 * @dev The liquidation incentive factor (LIF) scales with LLTV to encourage timely liquidations without incurring bad debt:
 *      LIF = min(MAX_LIF, 1 / (1 - SENSITIVITY * (1 - LLTV)))
 * @dev Supports flash-loan style liquidations via the IRoycoLiquidator callback interface
 */
abstract contract AtomicLiquidationFacility is RoycoKernel {
    using Math for uint256;

    /// @dev The maximum liquidation incentive factor, scaled to WAD precision (1.15 = 115% = 15% bonus)
    /// @dev Caps the bonus to prevent excessive JT losses in extreme scenarios
    uint256 internal constant MAX_LIF_WAD = 1.15e18;

    /// @dev The sensitivity parameter controlling how quickly LIF scales with LLTV, scaled to WAD precision
    /// @dev Higher sensitivity means LIF increases faster as LLTV decreases
    /// @dev Formula: LIF = min(MAX_LIF, 1 / (1 - LIF_SENSITIVITY * (1 - LLTV)))
    uint256 internal constant LIF_SENSITIVITY_WAD = 0.3e18;

    /// @dev Thrown when attempting to liquidate a position that is not underwater (LTV < LLTV)
    error LTV_IS_HEALTHY();

    /// @dev Thrown when the liquidator requests more assets than available in ST's liquidatable claims
    error INSUFFICIENT_ASSETS_TO_LIQUIDATE();

    /// @notice Validates that the kernel has a valid base asset configured for liquidation settlements
    /// @dev Reverts if BASE_ASSET is the zero address since liquidations require transferring base assets
    constructor() {
        require(BASE_ASSET != address(0), NULL_ADDRESS());
    }

    /**
     * @notice Emitted when a liquidation is executed
     * @param liquidator The address that executed the liquidation
     * @param stAssetsSeized Total ST assets transferred to liquidator (demanded + bonus)
     * @param jtAssetsSeized Total JT assets transferred to liquidator (demanded + bonus)
     * @param stAssetsBonus ST assets paid as bonus to liquidator from JT's claims on ST
     * @param jtAssetsBonus JT assets paid as bonus to liquidator from JT's claims on JT
     * @param baseAssetSettlement Base asset amount paid by liquidator as settlement
     */
    event Liquidation(
        address indexed liquidator,
        TRANCHE_UNIT stAssetsSeized,
        TRANCHE_UNIT jtAssetsSeized,
        TRANCHE_UNIT stAssetsBonus,
        TRANCHE_UNIT jtAssetsBonus,
        BASE_UNIT baseAssetSettlement
    );

    /**
     * @inheritdoc RoycoKernel
     * @dev Returns zero values if the market LTV is below the LLTV threshold
     * @dev JT assets are excluded from liquidation if beta is 0 (JT invested in risk-free rate)
     */
    function getLiquidatableAssets() public view virtual override(RoycoKernel) returns (TRANCHE_UNIT stAssets, TRANCHE_UNIT jtAssets) {
        // Get liquidation params from accountant
        (uint64 lltvWAD, uint96 betaWAD) = IRoycoAccountant(_accountant()).getLiquidationParams();
        // The liquidatable assets are the senior tranche's claims on ST and JT assets
        (SyncedAccountingState memory state, AssetClaims memory liquidatableClaims,) = previewSyncTrancheAccounting(TrancheType.SENIOR);
        // No liquidatable assets exist if the market is not in a liquidatable state
        if (state.ltvWAD < lltvWAD) return (ZERO_TRANCHE_UNITS, ZERO_TRANCHE_UNITS);
        // Claims on JT assets aren't liquidatable if beta is 0 since that implies that they are invested in the RFR
        return (liquidatableClaims.stAssets, betaWAD == 0 ? ZERO_TRANCHE_UNITS : liquidatableClaims.jtAssets);
    }

    /**
     * @inheritdoc RoycoKernel
     * @dev Liquidator receives the specified assets, executes callback, and must repay equivalent NAV in base asset
     * @dev Reverts if LTV is below LLTV or if requested assets exceed liquidatable claims
     */
    function liquidate(
        TRANCHE_UNIT _stAssetsToLiquidate,
        TRANCHE_UNIT _jtAssetsToLiquidate,
        bytes calldata _liquidationCallbackData
    )
        external
        virtual
        override(RoycoKernel)
        restricted
        nonReentrant
        withQuoterCache
    {
        // Synchronize the tranche accounting and get the liquidatable assets for ST
        (SyncedAccountingState memory state, AssetClaims memory stClaims, AssetClaims memory jtClaims) = _syncTrancheAccountingForLiquidation();

        // Get liquidation params from accountant
        (uint64 lltvWAD, uint96 betaWAD) = IRoycoAccountant(_accountant()).getLiquidationParams();
        // Claims on JT assets aren't liquidatable if beta is 0 since that implies that they are invested in the RFR
        stClaims.jtAssets = betaWAD == 0 ? ZERO_TRANCHE_UNITS : stClaims.jtAssets;

        // If max values are passed in, the liquidator wants to liquidate all liquidatable ST claims
        if (_stAssetsToLiquidate == MAX_TRANCHE_UNITS) _stAssetsToLiquidate = stClaims.stAssets;
        if (_jtAssetsToLiquidate == MAX_TRANCHE_UNITS) _jtAssetsToLiquidate = stClaims.jtAssets;

        // Ensure that the market is in a liquidatable state
        require(state.ltvWAD >= lltvWAD, LTV_IS_HEALTHY());
        // Ensure that the assets that the liquidator is attempting to seize belong to ST
        require(stClaims.stAssets >= _stAssetsToLiquidate && stClaims.jtAssets >= _jtAssetsToLiquidate, INSUFFICIENT_ASSETS_TO_LIQUIDATE());

        // Convert the assets to liquidate to NAV units and derive the base assets expected as settlement
        NAV_UNIT seizedSTClaimsOnST = stConvertTrancheUnitsToNAVUnits(_stAssetsToLiquidate);
        NAV_UNIT seizedSTClaimsOnJT = jtConvertTrancheUnitsToNAVUnits(_jtAssetsToLiquidate);
        // The settlement must be the exact mark to market value of the seized claims
        NAV_UNIT settlement = seizedSTClaimsOnST + seizedSTClaimsOnJT;

        // Compute the liquidation incentive factor for this liquidation
        uint256 liquidationIncentiveFactorWAD =
            Math.min(MAX_LIF_WAD, WAD.mulDiv(WAD, (WAD - LIF_SENSITIVITY_WAD.mulDiv(WAD - lltvWAD, WAD, Math.Rounding.Floor)), Math.Rounding.Floor));

        // Compute bonus NAV for the liquidator: (LIF - 1) * navToLiquidate
        NAV_UNIT bonusNAV = toNAVUnits(toUint256(settlement).mulDiv(liquidationIncentiveFactorWAD - WAD, WAD, Math.Rounding.Floor));

        // Source bonus from JT's claims, prioritizing JT assets first, then ST assets
        TRANCHE_UNIT bonusFromJTClaimsOnJT = UnitsMathLib.min(jtConvertNAVUnitsToTrancheUnits(bonusNAV), jtClaims.jtAssets);
        NAV_UNIT remainingBonusNAV = bonusNAV - jtConvertTrancheUnitsToNAVUnits(bonusFromJTClaimsOnJT);
        TRANCHE_UNIT bonusFromSTClaimsOnST = UnitsMathLib.min(stConvertNAVUnitsToTrancheUnits(remainingBonusNAV), jtClaims.stAssets);

        // Calculate total assets to free (demanded + bonus)
        TRANCHE_UNIT totalSTAssetsToFree = _stAssetsToLiquidate + bonusFromSTClaimsOnST;
        TRANCHE_UNIT totalJTAssetsToFree = _jtAssetsToLiquidate + bonusFromJTClaimsOnJT;

        // Free assets from underlying vaults and transfer to liquidator: no need to specify NAV in claims
        AssetClaims liquidatorClaimsWithBonus = AssetClaims(totalSTAssetsToFree, totalJTAssetsToFree, ZERO_NAV_UNITS, ZERO_NAV_UNITS);
        _withdrawAssets(liquidatorClaimsWithBonus, msg.sender);

        // Call liquidator callback if data is provided
        if (_liquidationCallbackData.length > 0) {
            IRoycoLiquidator(msg.sender).onRoycoLiquidate(totalSTAssetsToFree, totalJTAssetsToFree, _liquidationCallbackData);
        }

        // Pull base assets from liquidator as settlement for the liquidated NAV
        BASE_UNIT baseAssetSettlement = convertNAVUnitsToBaseUnits(settlement);
        _pullLiquidationProceeds(baseAssetSettlement, msg.sender);

        // Execute a post-liquidation sync using the dedicated liquidation function
        _postLiquidationSyncTrancheAccounting(
            seizedSTClaimsOnST,
            seizedSTClaimsOnJT,
            stConvertTrancheUnitsToNAVUnits(bonusFromSTClaimsOnST),
            jtConvertTrancheUnitsToNAVUnits(bonusFromJTClaimsOnJT),
            settlement
        );

        emit Liquidation(msg.sender, totalSTAssetsToFree, totalJTAssetsToFree, bonusFromSTClaimsOnST, bonusFromJTClaimsOnJT, baseAssetSettlement);
    }

    /**
     * @notice Invokes the accountant to do a pre-operation NAV sync and returns asset claims for both tranches
     * @dev Should be called before liquidation to get current claims for both ST and JT
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark to market accounting data
     * @return stClaims The claims on ST and JT assets that the senior tranche has, denominated in tranche-native units
     * @return jtClaims The claims on ST and JT assets that the junior tranche has, denominated in tranche-native units
     */
    function _syncTrancheAccountingForLiquidation()
        internal
        virtual
        returns (SyncedAccountingState memory state, AssetClaims memory stClaims, AssetClaims memory jtClaims)
    {
        // Execute the pre-op sync via the accountant
        state = _accountant().syncTrancheAccounting(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV());

        // Collect any protocol fees accrued
        _collectProtocolFees(state.stProtocolFeeAccrued, state.jtProtocolFeeAccrued, state.stEffectiveNAV, state.jtEffectiveNAV);

        // Decompose effective NAVs into self-backed NAV claims and cross-tranche NAV claims
        (NAV_UNIT stNAVClaimOnSelf, NAV_UNIT stNAVClaimOnJT, NAV_UNIT stNAVClaimOnLiquidationProceeds, NAV_UNIT jtNAVClaimOnSelf, NAV_UNIT jtNAVClaimOnST) =
            _decomposeNAVClaims(state);

        // Marshal the asset claims for the senior tranche
        stClaims = _marshalAssetClaims(TrancheType.SENIOR, stNAVClaimOnSelf, stNAVClaimOnJT, stNAVClaimOnLiquidationProceeds, jtNAVClaimOnSelf, jtNAVClaimOnST);

        // Marshal the asset claims for the junior tranche
        jtClaims = _marshalAssetClaims(TrancheType.JUNIOR, stNAVClaimOnSelf, stNAVClaimOnJT, stNAVClaimOnLiquidationProceeds, jtNAVClaimOnSelf, jtNAVClaimOnST);
    }
}
