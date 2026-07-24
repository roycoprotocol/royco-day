// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import { BalancerPoolToken } from "../../lib/balancer-v3-monorepo/pkg/vault/contracts/BalancerPoolToken.sol";
import { IRoycoDayKernel } from "../interfaces/IRoycoDayKernel.sol";
import { RoycoDayKernel } from "./base/RoycoDayKernel.sol";
import { BalancerV3LiquidityVenue } from "./base/liquidity-venue/balancer-v3/BalancerV3LiquidityVenue.sol";

/**
 * @title RoycoDayBalancerV3Kernel
 * @author Waymont
 * @notice The senior and junior tranches coinvest the same collateral asset, and the liquidity provider tranche provides secondary liquidity via a Balancer V3 pool pairing the senior tranche share against a quote asset
 * @dev ST/JT NAV computations price the collateral asset in NAV units through the market's collateral asset oracle, so one kernel serves every collateral integration
 * @dev LPT NAV computations value the pool position (BPT) using a manipulation-resistant Balancer V3 oracle, and the pool prices the senior share leg via this kernel's senior share rate provider
 */
contract RoycoDayBalancerV3Kernel is BalancerV3LiquidityVenue {
    /// @notice Constructs the kernel state and resolves the quote asset from the liquidity provider tranche's Balancer V3 pool
    /// @param _params The standard construction parameters for the Royco Day kernel
    constructor(IRoycoDayKernel.RoycoDayKernelConstructionParams memory _params)
        RoycoDayKernel(_params)
        BalancerV3LiquidityVenue(BalancerPoolToken(_params.lptAsset).getVault())
    { }

    /**
     * @notice Initializes the Royco Day kernel and its liquidity venue
     * @param _standardParams The standard initialization parameters for the Royco Day kernel
     * @param _liquidityVenueParams The Balancer V3 liquidity venue's parameters
     */
    function initialize(
        IRoycoDayKernel.RoycoDayKernelInitParams calldata _standardParams,
        BalancerV3LiquidityVenue.LiquidityVenueInitParams calldata _liquidityVenueParams
    )
        external
        initializer
    {
        // Initialize the base kernel state
        __RoycoDayKernel_init(_standardParams);
        // Initialize the Balancer V3 liquidity venue
        __BalancerV3LiquidityVenue_init_unchained(_liquidityVenueParams);
    }
}
