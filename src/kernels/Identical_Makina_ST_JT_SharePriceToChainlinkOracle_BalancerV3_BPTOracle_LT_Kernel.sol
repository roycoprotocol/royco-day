// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import { BalancerPoolToken } from "../../lib/balancer-v3-monorepo/pkg/vault/contracts/BalancerPoolToken.sol";
import { IRoycoDayKernel } from "../interfaces/IRoycoDayKernel.sol";
import { RoycoDayKernel } from "./base/RoycoDayKernel.sol";
import {
    IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_Quoter
} from "./base/quoter/identical-st-jt/IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_Quoter.sol";
import { IdenticalAssets_ST_JT_Oracle_Quoter } from "./base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_Oracle_Quoter.sol";
import { BalancerV3_LT_BPTOracle_Quoter } from "./base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_BPTOracle_Quoter.sol";

/**
 * @title Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel
 * @author Waymont
 * @notice The senior and junior tranches transfer in the same Makina machine shares (DUSD, etc.), and the liquidity tranche provides secondary liquidity via a Balancer V3 pool pairing the senior tranche share against a quote asset (USDC, srRoyUSDC, etc.)
 * @dev ST/JT NAV computations convert tranche units (Makina machine shares) to accounting assets using the machine's convertToAssets and then convert accounting assets to NAV units using a Chainlink (compatible) oracle or an admin set exchange rate
 * @dev LT NAV computations value the pool position (BPT) using a manipulation-resistant Balancer V3 oracle, and the pool prices the senior share leg via this kernel's senior share rate provider
 */
contract Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel is
    IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_Quoter,
    BalancerV3_LT_BPTOracle_Quoter
{
    /**
     * @notice Kernel-specific initialization parameters
     * @custom:field stAndJTQuoterParams - The senior/junior tranche Makina-machine-shares-to-Chainlink quoter's parameters
     * @custom:field ltQuoterParams - The liquidity tranche Balancer V3 quoter's parameters
     */
    struct KernelSpecificInitParams {
        IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_Quoter.ST_JT_QuoterSpecificParams stAndJTQuoterParams;
        BalancerV3_LT_BPTOracle_Quoter.LT_QuoterSpecificParams ltQuoterParams;
    }

    /// @notice Constructs the kernel state, pins the Makina machine, and resolves the quote asset from the liquidity tranche's Balancer V3 pool
    /// @param _params The standard construction parameters for the Royco Day kernel
    /// @param _makinaMachine The Makina machine whose share token is the ST/JT tranche asset
    constructor(
        IRoycoDayKernel.RoycoDayKernelConstructionParams memory _params,
        address _makinaMachine
    )
        RoycoDayKernel(_params)
        IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_Quoter(_makinaMachine)
        BalancerV3_LT_BPTOracle_Quoter(BalancerPoolToken(_params.ltAsset).getVault())
    { }

    /**
     * @notice Initializes the Royco Day kernel and its ST/JT and liquidity tranche quoters
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
        // Initialize the identical Makina machine shares to Chainlink (compatible) oracle ST/JT quoter
        __IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_Quoter_init(_specificParams.stAndJTQuoterParams);
        // Initialize the Balancer V3 liquidity tranche quoter
        __BalancerV3_LT_BPTOracle_Quoter_init_unchained(_specificParams.ltQuoterParams);
    }

    /// @inheritdoc RoycoDayKernel
    function _initializeQuoterCache() internal override(RoycoDayKernel, IdenticalAssets_ST_JT_Oracle_Quoter) {
        IdenticalAssets_ST_JT_Oracle_Quoter._initializeQuoterCache();
    }

    /// @inheritdoc RoycoDayKernel
    function _isTrancheShareCustodian(address _account) internal view override(RoycoDayKernel, BalancerV3_LT_BPTOracle_Quoter) returns (bool) {
        return BalancerV3_LT_BPTOracle_Quoter._isTrancheShareCustodian(_account);
    }
}
