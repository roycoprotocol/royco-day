// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoLiquidator } from "../../../interfaces/IRoycoLiquidator.sol";
import { MAX_TRANCHE_UNITS, MAX_TRANCHE_UNITS, WAD, ZERO_BASE_UNITS, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../../../libraries/Constants.sol";
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

    /// @dev Thrown when the computed settlement payment for the liquidation is zero base assets
    error LIQUIDATION_SETTLEMENT_MUST_BE_NON_ZERO();

    /// @notice Validates that the kernel has a valid base asset configured for liquidation settlements
    /// @dev Reverts if BASE_ASSET is the zero address since liquidations require transferring base assets
    constructor() {
        require(BASE_ASSET != address(0), NULL_ADDRESS());
    }

    /**
     * @notice Emitted when a liquidation is executed
     * @param liquidator The address that executed the liquidation
     * @param stAssetsLiquidated The ST assets, controlled by ST, liquidated by the liquidator
     * @param jtAssetsLiquidated The JT assets, controlled by ST, liquidated by the liquidator
     * @param lpAssetsBonus The liquidation proceeds assets, controlled by JT, paid as bonus to the liquidator
     * @param stAssetsBonus The ST assets, controlled by JT, paid as bonus to the liquidator
     * @param jtAssetsBonus The JT assets, controlled by JT, paid as bonus to the liquidator
     * @param baseAssetSettlement The base asset amount paid by the liquidator as a settlement for the seized assets
     */
    event Liquidation(
        address indexed liquidator,
        TRANCHE_UNIT stAssetsLiquidated,
        TRANCHE_UNIT jtAssetsLiquidated,
        BASE_UNIT lpAssetsBonus,
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
        (uint64 lltvWAD, uint96 betaWAD) = ACCOUNTANT.getLiquidationParams();
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
        (SyncedAccountingState memory state, AssetClaims memory stClaims, AssetClaims memory jtClaims) = _syncTrancheAccountingWithClaims();

        // Get liquidation params from accountant
        (uint64 lltvWAD, uint96 betaWAD) = ACCOUNTANT.getLiquidationParams();
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
        NAV_UNIT seizedSTClaimsOnSelf = stConvertTrancheUnitsToNAVUnits(_stAssetsToLiquidate);
        NAV_UNIT seizedSTClaimsOnJT = jtConvertTrancheUnitsToNAVUnits(_jtAssetsToLiquidate);
        // The settlement must be the exact mark-to-market value of the seized claims
        NAV_UNIT settlement = seizedSTClaimsOnSelf + seizedSTClaimsOnJT;

        // Get the bonus for the liquidation
        (NAV_UNIT bonusNAV, BASE_UNIT bonusFromJTClaimsOnLP, TRANCHE_UNIT bonusFromJTClaimsOnST, TRANCHE_UNIT bonusFromJTClaimsOnSelf) =
            _computeLiquidationBonus(settlement, lltvWAD, jtClaims);

        // Calculate total assets to free (demanded + bonus)
        TRANCHE_UNIT totalSTAssetsToFree = _stAssetsToLiquidate + bonusFromJTClaimsOnST;
        TRANCHE_UNIT totalJTAssetsToFree = _jtAssetsToLiquidate + bonusFromJTClaimsOnSelf;

        // Free assets (seized + bonus) to liquidator: no need to specify NAV in claims
        AssetClaims memory liquidatorClaimsWithBonus = AssetClaims(totalSTAssetsToFree, totalJTAssetsToFree, bonusFromJTClaimsOnLP, ZERO_NAV_UNITS);
        _withdrawAssets(liquidatorClaimsWithBonus, msg.sender);

        // Call liquidator callback if data is provided
        if (_liquidationCallbackData.length > 0) {
            IRoycoLiquidator(msg.sender).executeRoycoLiquidation(totalSTAssetsToFree, totalJTAssetsToFree, _liquidationCallbackData);
        }

        // Pull base assets from liquidator as settlement for the liquidated NAV
        BASE_UNIT baseAssetSettlement = convertNAVUnitsToBaseUnits(settlement);
        require(baseAssetSettlement != ZERO_BASE_UNITS, LIQUIDATION_SETTLEMENT_MUST_BE_NON_ZERO());
        _pullLiquidationProceeds(baseAssetSettlement, msg.sender);

        // Execute a post-liquidation sync on tranche accounting
        _postLiquidationSyncTrancheAccounting(bonusNAV);

        emit Liquidation(
            msg.sender, _stAssetsToLiquidate, _jtAssetsToLiquidate, bonusFromJTClaimsOnLP, bonusFromJTClaimsOnST, bonusFromJTClaimsOnSelf, baseAssetSettlement
        );
    }

    function _computeLiquidationBonus(
        NAV_UNIT stNAVToLiquidate,
        uint64 _lltvWAD,
        AssetClaims memory _jtClaims
    )
        internal
        view
        virtual
        override(RoycoKernel)
        returns (NAV_UNIT bonusNAV, BASE_UNIT bonusFromJTClaimsOnLP, TRANCHE_UNIT bonusFromJTClaimsOnST, TRANCHE_UNIT bonusFromJTClaimsOnSelf)
    {
        // Compute the liquidation incentive factor for this liquidation
        uint256 liquidationIncentiveFactorWAD =
            Math.min(MAX_LIF_WAD, WAD.mulDiv(WAD, (WAD - LIF_SENSITIVITY_WAD.mulDiv(WAD - _lltvWAD, WAD, Math.Rounding.Floor)), Math.Rounding.Floor));

        // Compute bonus NAV for the liquidator: (LIF - 1) * navToLiquidate
        NAV_UNIT expectedBonusNAV = toNAVUnits(toUint256(stNAVToLiquidate).mulDiv(liquidationIncentiveFactorWAD - WAD, WAD, Math.Rounding.Floor));

        // Source bonus from JT's claims, prioritizing LP assets first, then JT assets, and then ST assets
        bonusFromJTClaimsOnLP = UnitsMathLib.min(convertNAVUnitsToBaseUnits(expectedBonusNAV), _jtClaims.liquidationProceeds);
        NAV_UNIT remainingBonusNAV = UnitsMathLib.saturatingSub(expectedBonusNAV, convertBaseUnitsToNAVUnits(bonusFromJTClaimsOnLP));
        bonusFromJTClaimsOnSelf = UnitsMathLib.min(jtConvertNAVUnitsToTrancheUnits(remainingBonusNAV), _jtClaims.jtAssets);
        remainingBonusNAV = UnitsMathLib.saturatingSub(remainingBonusNAV, jtConvertTrancheUnitsToNAVUnits(bonusFromJTClaimsOnSelf));
        bonusFromJTClaimsOnST = UnitsMathLib.min(stConvertNAVUnitsToTrancheUnits(remainingBonusNAV), _jtClaims.stAssets);

        bonusNAV =
        (convertBaseUnitsToNAVUnits(bonusFromJTClaimsOnLP) + stConvertTrancheUnitsToNAVUnits(bonusFromJTClaimsOnST)
                + jtConvertTrancheUnitsToNAVUnits(bonusFromJTClaimsOnSelf));
    }
}
