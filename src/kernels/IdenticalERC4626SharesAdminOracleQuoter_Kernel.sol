// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoKernel } from "../interfaces/IRoycoKernel.sol";
import { RoycoKernel } from "./base/RoycoKernel.sol";
import { IdenticalERC4626SharesAdminOracleQuoter } from "./base/quoter/IdenticalERC4626SharesAdminOracleQuoter.sol";

/**
 * @title IdenticalERC4626SharesAdminOracleQuoter_Kernel
 * @author Waymont
 * @notice The senior and junior tranches transfer in the same yield bearing ERC4626 shares (sNUSD, sUSDe, etc.)
 * @notice The kernel uses an overridable oracle to convert tranche token units (ERC4626 shares) to NAV units, allowing NAVs to sync based on underlying PNL
 */
contract IdenticalERC4626SharesAdminOracleQuoter_Kernel is RoycoKernel, IdenticalERC4626SharesAdminOracleQuoter {
    /// @notice Constructs the kernel state
    /// @param _params The standard construction parameters for the Royco kernel
    constructor(RoycoKernelConstructionParams memory _params) RoycoKernel(_params) { }

    /**
     * @notice Initializes the Royco Kernel
     * @param _params The standard initialization parameters for the Royco Kernel
     * @param _initialConversionRateWAD The initial reference asset to NAV unit conversion rate, scaled to WAD precision
     */
    function initialize(IRoycoKernel.RoycoKernelInitParams calldata _params, uint256 _initialConversionRateWAD) external initializer {
        // Initialize the base kernel state
        __RoycoKernel_init(_params);
        // Initialize the identical ERC4626 shares to admin oracle quoter
        __IdenticalERC4626SharesAdminOracleQuoter_init(_initialConversionRateWAD);
    }
}
