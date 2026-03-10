// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoKernel } from "../interfaces/IRoycoKernel.sol";
import { RoycoKernel } from "./base/RoycoKernel.sol";
import { IdenticalMakinaSharesToAdminOracleQuoter } from "./base/quoter/IdenticalMakinaSharesToAdminOracleQuoter.sol";

/**
 * @title Identical_Makina_ST_Makina_JT_Kernel
 * @author Waymont
 * @notice The senior and junior tranches transfer in the same yield bearing Makina machine shares (DUSD, DBIT, etc.)
 */
contract Identical_Makina_ST_Makina_JT_Kernel is RoycoKernel, IdenticalMakinaSharesToAdminOracleQuoter {
    /**
     * @notice Constructs the kernel state
     * @param _params The standard construction parameters for the Royco kernel
     * @param _makinaMachine The Makina machine for the Royco market's tranche tokens
     */
    constructor(
        RoycoKernelConstructionParams memory _params,
        address _makinaMachine
    )
        RoycoKernel(_params)
        IdenticalMakinaSharesToAdminOracleQuoter(_makinaMachine)
    { }

    /**
     * @notice Initializes the Royco Kernel
     * @param _params The standard initialization parameters for the Royco Kernel
     * @param _initialConversionRateWAD The initial reference asset to NAV unit conversion rate, scaled to WAD precision
     */
    function initialize(IRoycoKernel.RoycoKernelInitParams calldata _params, uint256 _initialConversionRateWAD) external initializer {
        // Initialize the base kernel state
        __RoycoKernel_init(_params);
        // Initialize the identical Makina machine shares to admin oracle quoter
        __IdenticalMakinaSharesToAdminOracleQuoter_init(_initialConversionRateWAD);
    }
}
