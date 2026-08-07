// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoDayEntryPoint } from "../../src/entrypoint/RoycoDayEntryPoint.sol";
import { AssetClaims } from "../../src/libraries/Types.sol";
import { IRoycoDayKernel } from "../../src/interfaces/IRoycoDayKernel.sol";

/**
 * @title EntryPointRemitClaimsHarness
 * @notice Exposes RoycoDayEntryPoint._remitRedemptionAndBonusClaims so the per-leg transfer gating (collateral,
 *         LPT asset, senior shares, and quote) is unit-testable against a mock kernel
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

/// @notice Mock kernel exposing the immutables carrier _remitRedemptionAndBonusClaims resolves the market's assets from
contract MockKernelAssets {
    address public immutable COLLATERAL_ASSET;
    address public immutable LPT_ASSET;
    address public immutable SENIOR_TRANCHE;
    address public immutable QUOTE_ASSET;

    constructor(address _collateralAsset, address _lptAsset, address _seniorTranche, address _quoteAsset) {
        COLLATERAL_ASSET = _collateralAsset;
        LPT_ASSET = _lptAsset;
        SENIOR_TRANCHE = _seniorTranche;
        QUOTE_ASSET = _quoteAsset;
    }

    /// @dev The remitter resolves the collateral, LPT, senior tranche, and quote legs off this struct
    function getImmutableState() external view returns (IRoycoDayKernel.RoycoDayKernelImmutableState memory immutables) {
        immutables.collateralAsset = COLLATERAL_ASSET;
        immutables.lptAsset = LPT_ASSET;
        immutables.seniorTranche = SENIOR_TRANCHE;
        immutables.quoteAsset = QUOTE_ASSET;
    }
}
