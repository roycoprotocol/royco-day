// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { AssetClaims } from "../../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../../libraries/Units.sol";
import { RoycoDawnKernel } from "../base/RoycoDawnKernel.sol";
import { IdenticalAssetsChainlinkToAdminOracleQuoter } from "../base/quoter/IdenticalAssetsChainlinkToAdminOracleQuoter.sol";

/**
 * @title RoycoDayKernel
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Royco Day kernel: the Dawn (ST/JT) kernel plus a third Liquidity Tranche (LT) holding a Balancer BPT of
 *         the senior share paired against a quote stablecoin. ST/JT are priced exactly as Dawn (chainlink → admin oracle).
 * @dev STUB: LT custody + the `lt*` operational surface are not yet implemented (they revert). The LT/quote wiring
 *      (immutables + getters) is functional, which is enough to deploy, wire, and verify a Day market. ST/JT behave
 *      identically to the corresponding Dawn kernel.
 */
// NOTE: `IRoycoDayKernel` is intentionally NOT in the inheritance list to avoid a diamond-override conflict on the
// Dawn quoter functions (declared via the interface chain, implemented by the quoter mixin). The contract still
// exposes the full `IRoycoDayKernel` surface and is castable to it at every call site.
contract RoycoDayKernel is RoycoDawnKernel, IdenticalAssetsChainlinkToAdminOracleQuoter {
    /// @notice The liquidity tranche address.
    address public immutable LIQUIDITY_TRANCHE;
    /// @notice The liquidity tranche's base asset (the Balancer BPT).
    address public immutable LT_ASSET;
    /// @notice The quote asset paired against the senior share in the BPT.
    address public immutable QUOTE_ASSET;

    /// @param _params The Day kernel construction parameters (Dawn params + LT/quote wiring).
    constructor(IRoycoDayKernel.RoycoDayKernelConstructionParams memory _params) RoycoDawnKernel(_params.dawnKernelParams) {
        LIQUIDITY_TRANCHE = _params.liquidityTranche;
        LT_ASSET = _params.ltAsset;
        QUOTE_ASSET = _params.quoteAsset;
    }

    /**
     * @notice Initializes the Royco Day kernel.
     * @param _params The Day kernel initialization parameters (wrapping the Dawn init params).
     * @param _initialConversionRateWAD The initial reference asset to NAV unit conversion rate, scaled to WAD precision.
     * @param _trancheAssetToReferenceAssetOracle The senior/junior tranche asset to reference asset oracle.
     * @param _stalenessThresholdSeconds The oracle staleness threshold in seconds.
     */
    function initialize(
        IRoycoDayKernel.RoycoDayKernelInitParams calldata _params,
        uint256 _initialConversionRateWAD,
        address _trancheAssetToReferenceAssetOracle,
        uint48 _stalenessThresholdSeconds
    )
        external
        initializer
    {
        __RoycoDawnKernel_init(_params.dawnKernelInitParams);
        __IdenticalAssetsChainlinkToAdminOracleQuoter_init(_initialConversionRateWAD, _trancheAssetToReferenceAssetOracle, _stalenessThresholdSeconds);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LIQUIDITY TRANCHE (stub — not yet implemented)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice STUB: deposit into the liquidity tranche. Reverts until the LT flow is implemented.
    function ltDeposit(TRANCHE_UNIT) external pure returns (NAV_UNIT, NAV_UNIT) {
        revert IRoycoDayKernel.LT_NOT_IMPLEMENTED();
    }

    /// @notice STUB: redeem from the liquidity tranche. Reverts until the LT flow is implemented.
    function ltRedeem(uint256, address, bool) external pure returns (AssetClaims memory) {
        revert IRoycoDayKernel.LT_NOT_IMPLEMENTED();
    }
}
