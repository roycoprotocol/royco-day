// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayKernel } from "../../src/interfaces/IRoycoDayKernel.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../src/libraries/Units.sol";
import { ValuationLogic } from "../../src/libraries/logic/ValuationLogic.sol";

/**
 * @title LTEffectiveNAVDriver
 * @notice External exposer over both liquidity tranche effective NAV overloads in ValuationLogic, driven
 *         against a real RoycoDayKernelState storage struct without a full kernel deployment
 * @dev The library reads the LT raw NAV through IRoycoDayKernel(address(this)).ltConvertTrancheUnitsToNAVUnits,
 *      so this driver implements that entrypoint as an identity conversion: 1 tranche unit equals 1 NAV unit,
 *      which lets setLTRawNAV pin the LT raw NAV directly in NAV units
 */
contract LTEffectiveNAVDriver {
    IRoycoDayKernel.RoycoDayKernelState internal kernelState;

    /// @notice Pins the LT raw NAV read by the effective NAV computation (identity conversion, so NAV units)
    function setLTRawNAV(uint256 _ltRawNAV) external {
        kernelState.ltOwnedYieldBearingAssets = toTrancheUnits(_ltRawNAV);
    }

    /// @notice Sets the idle liquidity premium senior shares held on behalf of the liquidity tranche
    function setLTOwnedSeniorTrancheShares(uint256 _shares) external {
        kernelState.ltOwnedSeniorTrancheShares = _shares;
    }

    /// @notice Returns the stored idle liquidity premium senior share count
    function ltOwnedSeniorTrancheShares() external view returns (uint256) {
        return kernelState.ltOwnedSeniorTrancheShares;
    }

    /// @notice The storage-count overload: values the held senior shares committed to storage
    function ltEffectiveNAV(uint256 _stEffectiveNAV, uint256 _totalSeniorTrancheShares) external view returns (uint256 ltEffectiveNAVUnits) {
        return toUint256(ValuationLogic._getLiquidityTrancheEffectiveNAV(kernelState, toNAVUnits(_stEffectiveNAV), _totalSeniorTrancheShares));
    }

    /// @notice The explicit-count overload: values an injected held senior share count the storage does not yet reflect
    function ltEffectiveNAV(
        uint256 _stEffectiveNAV,
        uint256 _totalSeniorTrancheShares,
        uint256 _ltOwnedSeniorTrancheShares
    )
        external
        view
        returns (uint256 ltEffectiveNAVUnits)
    {
        return toUint256(
            ValuationLogic._getLiquidityTrancheEffectiveNAV(kernelState, toNAVUnits(_stEffectiveNAV), _totalSeniorTrancheShares, _ltOwnedSeniorTrancheShares)
        );
    }

    /// @dev Identity conversion consumed by the library's self-call for the LT raw NAV read
    function ltConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _ltAssets) external pure returns (NAV_UNIT nav) {
        return toNAVUnits(toUint256(_ltAssets));
    }
}
