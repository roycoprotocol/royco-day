// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoDayEntryPoint } from "../../src/entrypoint/RoycoDayEntryPoint.sol";
import { AssetClaims } from "../../src/libraries/Types.sol";

/**
 * @title EntryPointRemitClaimsHarness
 * @notice Exposes RoycoDayEntryPoint._remitClaims so the different-asset transfer branch — unreachable under the
 *         shipped identical-ST/JT-asset kernel family — is unit-testable against a mock kernel
 */
contract EntryPointRemitClaimsHarness is RoycoDayEntryPoint {
    constructor(address _roycoFactory) RoycoDayEntryPoint(_roycoFactory) { }

    function remitClaims(address _kernel, AssetClaims memory _userClaims, AssetClaims memory _bonusClaims, address _receiver) external {
        _remitClaims(_kernel, _userClaims, _bonusClaims, _receiver);
    }
}

/// @notice Mock kernel exposing only the asset getters _remitClaims resolves
contract MockKernelAssets {
    address public immutable ST_ASSET;
    address public immutable JT_ASSET;
    address public immutable LT_ASSET;
    address public immutable SENIOR_TRANCHE;

    constructor(address _stAsset, address _jtAsset, address _ltAsset, address _seniorTranche) {
        ST_ASSET = _stAsset;
        JT_ASSET = _jtAsset;
        LT_ASSET = _ltAsset;
        SENIOR_TRANCHE = _seniorTranche;
    }
}
