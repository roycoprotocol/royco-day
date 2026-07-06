// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayKernel } from "../../src/interfaces/IRoycoDayKernel.sol";
import { AssetClaims, SyncedAccountingState } from "../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../src/libraries/Units.sol";
import { SelfLiquidationLogic } from "../../src/libraries/logic/SelfLiquidationLogic.sol";

/**
 * @title SelfLiquidationHarness
 * @notice Thin external-call wrapper around the kernel-side SelfLiquidationLogic so unit tests can drive
 *         applySeniorTrancheSelfLiquidationBonus against a real RoycoDayKernelState storage struct
 * @dev The library calls IRoycoDayKernel(address(this)) back for the four tranche-unit conversions, so this
 *      harness implements them as identity conversions: 1 tranche unit equals 1 NAV unit, which keeps every
 *      test vector's tranche-unit and NAV-unit literals identical
 */
contract SelfLiquidationHarness {
    IRoycoDayKernel.RoycoDayKernelState internal kernelState;

    /// @notice Sets the configured self-liquidation bonus fraction of the redeemed NAV
    function setSelfLiquidationBonusWAD(uint64 _bonusWAD) external {
        kernelState.stSelfLiquidationBonusWAD = _bonusWAD;
    }

    /// @notice Drives the self-liquidation bonus computation and claim application against the harness state
    function applyBonus(
        SyncedAccountingState memory _state,
        AssetClaims memory _stUserClaims
    )
        external
        view
        returns (AssetClaims memory stUserClaimsWithBonus, NAV_UNIT stSelfLiquidationBonusNAV)
    {
        return SelfLiquidationLogic.applySeniorTrancheSelfLiquidationBonus(kernelState, _state, _stUserClaims);
    }

    /*//////////////////////////////////////////////////////////////////////
                    SELF-CALL SURFACE CONSUMED BY THE LIBRARY
    //////////////////////////////////////////////////////////////////////*/

    function stConvertNAVUnitsToTrancheUnits(NAV_UNIT _value) external pure returns (TRANCHE_UNIT stAssets) {
        return toTrancheUnits(toUint256(_value));
    }

    function jtConvertNAVUnitsToTrancheUnits(NAV_UNIT _value) external pure returns (TRANCHE_UNIT jtAssets) {
        return toTrancheUnits(toUint256(_value));
    }

    function stConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _stAssets) external pure returns (NAV_UNIT nav) {
        return toNAVUnits(toUint256(_stAssets));
    }

    function jtConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _jtAssets) external pure returns (NAV_UNIT nav) {
        return toNAVUnits(toUint256(_jtAssets));
    }
}
