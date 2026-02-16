// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoKernelInitParams } from "../libraries/RoycoKernelStorageLib.sol";
import { RoycoKernel } from "./base/RoycoKernel.sol";
import { AaveV3_JT_Kernel } from "./base/junior/AaveV3_JT_Kernel.sol";
import { AtomicLiquidationFacility } from "./base/liquidation-facility/AtomicLiquidationFacility.sol";
import { InKindAssetsQuoter } from "./base/quoter/InKindAssetsQuoter.sol";
import { ERC4626_ST_Kernel } from "./base/senior/ERC4626_ST_Kernel.sol";

/**
 * @title ERC4626_ST_AaveV3_JT_InKindAssets_Kernel
 * @author Waymont
 * @notice The senior tranche is deployed into a ERC4626 compliant vault and the junior tranche is deployed into Aave V3
 * @notice The tranche assets are identical in value and can have differing precisions (eg. USDC and USDS, USDT and USDe, etc.)
 * @notice Tranche units are always expressed in the tranche's assets precision
 * @notice NAV units are always expressed in tranche units scaled to WAD (18 decimals) precision
 */
contract ERC4626_ST_AaveV3_JT_InKindAssets_Kernel is ERC4626_ST_Kernel, AaveV3_JT_Kernel, InKindAssetsQuoter, AtomicLiquidationFacility {
    /**
     * @notice Constructs the Royco kernel
     * @param _params The standard construction parameters for the Royco kernel
     * @param _stVault The address of the ERC4626 compliant vault that the senior tranche will deploy into
     * @param _aaveV3Pool The address of the Aave V3 Pool
     */
    constructor(
        RoycoKernelConstructionParams memory _params,
        address _stVault,
        address _aaveV3Pool
    )
        RoycoKernel(_params)
        ERC4626_ST_Kernel(_stVault)
        AaveV3_JT_Kernel(_aaveV3Pool)
    { }

    /**
     * @notice Initializes the Royco Kernel
     * @param _params The standard initialization parameters for the Royco Kernel
     */
    function initialize(RoycoKernelInitParams calldata _params) external initializer {
        // Initialize the base kernel state
        __RoycoKernel_init(_params);
        // Initialize the ERC4626 senior tranche state
        __ERC4626_ST_Kernel_init_unchained();
        // Initialize the Aave V3 junior tranche state
        __AaveV3_JT_Kernel_init_unchained();
    }
}
