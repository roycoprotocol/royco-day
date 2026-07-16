// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoDayEntryPoint } from "../../src/entrypoint/RoycoDayEntryPoint.sol";
import { AssetClaims } from "../../src/libraries/Types.sol";

/**
 * @title EntryPointRemitClaimsHarness
 * @notice Exposes RoycoDayEntryPoint._remitRedemptionAndBonusClaims so the different-asset transfer branch — unreachable
 *         under the shipped identical-ST/JT-asset kernel family — and the per-leg transfer gating are unit-testable
 *         against a mock kernel
 */
contract EntryPointRemitClaimsHarness is RoycoDayEntryPoint {
    constructor(address _roycoFactory) RoycoDayEntryPoint(_roycoFactory) { }

    function remitRedemptionAndBonusClaims(
        address _kernel,
        AssetClaims memory _totalClaims,
        uint256 _quoteAssets,
        uint64 _executorBonusWAD,
        address _receiver
    )
        external
        returns (AssetClaims memory bonusClaims, uint256 bonusQuoteAssets, AssetClaims memory userClaims)
    {
        (bonusClaims, bonusQuoteAssets) = _remitRedemptionAndBonusClaims(_kernel, _totalClaims, _quoteAssets, _executorBonusWAD, _receiver);
        // The claims struct is reduced in place to the receiver's post-bonus portion
        userClaims = _totalClaims;
    }
}

/// @notice Mock kernel exposing only the asset getters _remitRedemptionAndBonusClaims resolves
contract MockKernelAssets {
    address public immutable ST_ASSET;
    address public immutable JT_ASSET;
    address public immutable LT_ASSET;
    address public immutable SENIOR_TRANCHE;
    address public immutable QUOTE_ASSET;

    constructor(address _stAsset, address _jtAsset, address _ltAsset, address _seniorTranche, address _quoteAsset) {
        ST_ASSET = _stAsset;
        JT_ASSET = _jtAsset;
        LT_ASSET = _ltAsset;
        SENIOR_TRANCHE = _seniorTranche;
        QUOTE_ASSET = _quoteAsset;
    }
}
