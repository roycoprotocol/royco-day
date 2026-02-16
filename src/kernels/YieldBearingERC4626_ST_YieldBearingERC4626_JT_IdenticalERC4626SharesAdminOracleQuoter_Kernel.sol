// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoKernelInitParams } from "../libraries/RoycoKernelStorageLib.sol";
import { RoycoKernel } from "./base/RoycoKernel.sol";
import { YieldBearingERC20_JT_Kernel } from "./base/junior/YieldBearingERC20_JT_Kernel.sol";
import { AtomicLiquidationFacility } from "./base/liquidation-facility/AtomicLiquidationFacility.sol";
import { IdenticalERC4626SharesAdminOracleQuoter } from "./base/quoter/IdenticalERC4626SharesAdminOracleQuoter.sol";
import { YieldBearingERC20_ST_Kernel } from "./base/senior/YieldBearingERC20_ST_Kernel.sol";

/**
 * @title YieldBearingERC20_ST_YieldBearingERC20_JT_IdenticalAssetsOracleQuoter_Kernel
 * @author Waymont
 * @notice The senior and junior tranches transfer in the same yield bearing ERC4626 shares (sNUSD, sUSDe, etc.)
 * @notice The kernel uses an overridable oracle to convert tranche token units (ERC4626 shares) to NAV units, allowing NAVs to sync based on underlying PNL
 */
contract YieldBearingERC4626_ST_YieldBearingERC4626_JT_IdenticalERC4626SharesAdminOracleQuoter_Kernel is
    YieldBearingERC20_ST_Kernel,
    YieldBearingERC20_JT_Kernel,
    IdenticalERC4626SharesAdminOracleQuoter,
    AtomicLiquidationFacility
{
    /// @notice Constructs the kernel state
    /// @param _params The standard construction parameters for the Royco kernel
    constructor(RoycoKernelConstructionParams memory _params) RoycoKernel(_params) { }

    /**
     * @notice Initializes the Royco Kernel
     * @param _params The standard initialization parameters for the Royco Kernel
     * @param _initialConversionRateWAD The initial reference asset to NAV unit conversion rate, scaled to WAD precision
     */
    function initialize(RoycoKernelInitParams calldata _params, uint256 _initialConversionRateWAD) external initializer {
        // Initialize the base kernel state
        __RoycoKernel_init(_params);
        // Initialize the identical ERC4626 shares to admin oracle quoter
        __IdenticalERC4626SharesAdminOracleQuoter_init(_initialConversionRateWAD);
    }
}
