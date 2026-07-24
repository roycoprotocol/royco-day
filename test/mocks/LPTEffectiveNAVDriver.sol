// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayKernel } from "../../src/interfaces/IRoycoDayKernel.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../src/libraries/Units.sol";
import { ValuationLogic } from "../../src/libraries/logic/ValuationLogic.sol";

/**
 * @title LPTEffectiveNAVDriver
 * @notice External exposer over both liquidity provider tranche effective NAV overloads in ValuationLogic, driven
 *         against a real RoycoDayKernelState storage struct without a full kernel deployment
 * @dev The library reads the LPT raw NAV through IRoycoDayKernel(address(this)).convertLPTAssetsToValue,
 *      so this driver implements that entrypoint as an identity conversion: 1 tranche unit equals 1 NAV unit,
 *      which lets setLPTRawNAV pin the LPT raw NAV directly in NAV units
 */
contract LPTEffectiveNAVDriver {
    IRoycoDayKernel.RoycoDayKernelState internal kernelState;

    /// @notice Pins the LPT raw NAV read by the effective NAV computation (identity conversion, so NAV units)
    function setLPTRawNAV(uint256 _lptRawNAV) external {
        kernelState.totalLPTAssets = toTrancheUnits(_lptRawNAV);
    }

    /// @notice Sets the idle liquidity premium senior shares held on behalf of the liquidity provider tranche
    function setLPTOwnedSeniorTrancheShares(uint256 _shares) external {
        kernelState.lptOwnedSeniorTrancheShares = _shares;
    }

    /// @notice Returns the stored idle liquidity premium senior share count
    function lptOwnedSeniorTrancheShares() external view returns (uint256) {
        return kernelState.lptOwnedSeniorTrancheShares;
    }

    /// @notice The storage-count overload: values the held senior shares committed to storage
    function lptEffectiveNAV(uint256 _stEffectiveNAV, uint256 _totalSeniorTrancheShares) external view returns (uint256 lptEffectiveNAVUnits) {
        return toUint256(ValuationLogic._getLiquidityProviderTrancheEffectiveNAV(kernelState, toNAVUnits(_stEffectiveNAV), _totalSeniorTrancheShares));
    }

    /// @notice The explicit-count overload: values an injected held senior share count the storage does not yet reflect
    function lptEffectiveNAV(
        uint256 _stEffectiveNAV,
        uint256 _totalSeniorTrancheShares,
        uint256 _lptOwnedSeniorTrancheShares
    )
        external
        view
        returns (uint256 lptEffectiveNAVUnits)
    {
        return toUint256(
            ValuationLogic._getLiquidityProviderTrancheEffectiveNAV(kernelState, toNAVUnits(_stEffectiveNAV), _totalSeniorTrancheShares, _lptOwnedSeniorTrancheShares)
        );
    }

    /// @dev Identity conversion consumed by the library's self-call for the LPT raw NAV read
    function convertLPTAssetsToValue(TRANCHE_UNIT _lptAssets) external pure returns (NAV_UNIT value) {
        return toNAVUnits(toUint256(_lptAssets));
    }
}
