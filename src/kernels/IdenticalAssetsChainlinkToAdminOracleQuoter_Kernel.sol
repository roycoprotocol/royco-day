// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoKernel } from "../interfaces/kernel/IRoycoKernel.sol";
import { RoycoKernel } from "./base/RoycoKernel.sol";
import { IdenticalAssetsChainlinkToAdminOracleQuoter } from "./base/quoter/IdenticalAssetsChainlinkToAdminOracleQuoter.sol";

/**
 * @title IdenticalAssetsChainlinkToAdminOracleQuoter_Kernel
 * @author Waymont
 * @notice The senior and junior tranches transfer in the same yield bearing asset
 * @notice The kernel uses a Chainlink oracle to convert tranche token units to NAV units, allowing NAVs to sync based on underlying PNL
 */
contract IdenticalAssetsChainlinkToAdminOracleQuoter_Kernel is RoycoKernel, IdenticalAssetsChainlinkToAdminOracleQuoter {
    /// @notice Constructs the kernel state
    /// @param _params The standard construction parameters for the Royco kernel
    constructor(RoycoKernelConstructionParams memory _params) RoycoKernel(_params) { }

    /**
     * @notice Initializes the Royco Kernel
     * @param _params The standard initialization parameters for the Royco Kernel
     * @param _trancheAssetToReferenceAssetOracle The tranche asset to reference asset oracle
     * @param _stalenessThresholdSeconds The staleness threshold seconds
     * @param _initialConversionRateWAD The initial reference asset to NAV unit conversion rate, scaled to WAD precision
     */
    function initialize(
        IRoycoKernel.RoycoKernelInitParams calldata _params,
        address _trancheAssetToReferenceAssetOracle,
        uint48 _stalenessThresholdSeconds,
        uint256 _initialConversionRateWAD
    )
        external
        initializer
    {
        // Initialize the base kernel state
        __RoycoKernel_init(_params);
        // Initialize the identical assets chainlink to admin oracle quoter
        __IdenticalAssetsChainlinkToAdminOracleQuoter_init(_initialConversionRateWAD, _trancheAssetToReferenceAssetOracle, _stalenessThresholdSeconds);
    }
}
