// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AssetClaims } from "../../src/libraries/Types.sol";
import { NAV_UNIT, toNAVUnits, toUint256 } from "../../src/libraries/Units.sol";
import { TrancheClaimsLogic } from "../../src/libraries/logic/TrancheClaimsLogic.sol";

/**
 * @title TrancheClaimsExposer
 * @notice Thin external exposer over the pure tranche claim math: the ST/JT claims decomposition on the raw
 *         NAVs and the proportional scaling of a tranche's asset claims by a share count
 * @dev External entrypoints let a test observe reverts anywhere in the claim math through try/catch
 */
contract TrancheClaimsExposer {
    /// @notice Decomposes the senior and junior effective NAVs into self-backed and cross-tranche claims on the raw NAVs
    function computeSTandJTClaimsOnRawNAVs(
        uint256 _stRawNAV,
        uint256 _jtRawNAV,
        uint256 _stEffectiveNAV,
        uint256 _jtEffectiveNAV
    )
        external
        pure
        returns (uint256 stClaimOnSTRawNAV, uint256 stClaimOnJTRawNAV, uint256 jtClaimOnSTRawNAV, uint256 jtClaimOnJTRawNAV)
    {
        (NAV_UNIT stOnST, NAV_UNIT stOnJT, NAV_UNIT jtOnST, NAV_UNIT jtOnJT) = TrancheClaimsLogic._computeSTandJTClaimsOnRawNAVs(
            toNAVUnits(_stRawNAV), toNAVUnits(_jtRawNAV), toNAVUnits(_stEffectiveNAV), toNAVUnits(_jtEffectiveNAV)
        );
        return (toUint256(stOnST), toUint256(stOnJT), toUint256(jtOnST), toUint256(jtOnJT));
    }

    /// @notice Scales a tranche's asset claims by the redeemed shares over the tranche's total shares
    function scaleAssetClaims(
        AssetClaims memory _claims,
        uint256 _shares,
        uint256 _totalTrancheShares
    )
        external
        pure
        returns (AssetClaims memory scaledClaims)
    {
        return TrancheClaimsLogic._scaleAssetClaims(_claims, _shares, _totalTrancheShares);
    }
}
