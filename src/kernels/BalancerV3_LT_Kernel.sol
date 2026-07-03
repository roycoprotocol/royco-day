// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { BalancerPoolToken } from "../../lib/balancer-v3-monorepo/pkg/vault/contracts/BalancerPoolToken.sol";
import { IRoycoDayKernel } from "../interfaces/IRoycoDayKernel.sol";
import { RoycoDayKernel } from "./base/RoycoDayKernel.sol";
import { BalancerV3_LT_Venue_Kernel } from "./lt-venue/balancer-v3/BalancerV3_LT_Venue_Kernel.sol";

/**
 * @title BalancerV3_LT_Kernel
 * @author Waymont
 * @notice A Royco Day kernel whose liquidity tranche provides secondary liquidity via a Balancer V3 pool pairing the senior tranche share against a quote asset (USDC, srRoyUSDC, etc.)
 * @dev Venue-only and ST/JT-pricing-agnostic: the senior/junior tranche asset pricing and the entire preview surface live on the market's quoter, so a single kernel works with any ST/JT pricing quoter
 * @dev LT execution values and settles the pool position (BPT) through the Balancer V3 Vault, while the pool prices the senior share leg via the market quoter's senior share rate provider
 */
contract BalancerV3_LT_Kernel is BalancerV3_LT_Venue_Kernel {
    /**
     * @notice Kernel-specific initialization parameters
     * @custom:field maxReinvestmentSlippageWAD - The maximum slippage tolerated when single-sided reinvesting the liquidity premium ST shares into the Balancer V3 Pool, scaled to WAD precision
     */
    struct KernelSpecificInitParams {
        uint64 maxReinvestmentSlippageWAD;
    }

    /// @notice Constructs the kernel state and resolves the Balancer V3 Vault from the liquidity tranche's pool
    /// @dev The Balancer V3 Vault is resolved here from `_params.ltAsset` (the BPT) and passed to the LT kernel venue's constructor.
    ///      It cannot be read from the `LT_ASSET` immutable inside that base constructor's arguments (it is not yet assigned
    ///      during construction), so it is threaded explicitly from the construction params, which are always readable.
    /// @param _params The standard construction parameters for the Royco Day kernel
    constructor(IRoycoDayKernel.RoycoDayKernelConstructionParams memory _params)
        RoycoDayKernel(_params)
        BalancerV3_LT_Venue_Kernel(BalancerPoolToken(_params.ltAsset).getVault())
    { }

    /**
     * @notice Initializes the Royco Day kernel and its Balancer V3 liquidity tranche venue
     * @param _standardParams The standard initialization parameters for the Royco Day kernel
     * @param _specificParams The kernel-specific initialization parameters
     */
    function initialize(
        IRoycoDayKernel.RoycoDayKernelInitParams calldata _standardParams,
        KernelSpecificInitParams calldata _specificParams
    )
        external
        initializer
    {
        // Initialize the base kernel state
        __RoycoDayKernel_init(_standardParams);
        // Initialize the Balancer V3 liquidity tranche kernel venue
        __BalancerV3_LT_Venue_Kernel_init_unchained(_specificParams.maxReinvestmentSlippageWAD);
    }
}
