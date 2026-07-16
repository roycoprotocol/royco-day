// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { BalancerPoolToken } from "../../lib/balancer-v3-monorepo/pkg/vault/contracts/BalancerPoolToken.sol";
import { IRoycoDayKernel } from "../interfaces/IRoycoDayKernel.sol";
import { RoycoDayKernel } from "./base/RoycoDayKernel.sol";
import {
    IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter
} from "./base/quoter/identical-st-jt/IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter.sol";
import { IdenticalAssets_ST_JT_Oracle_Quoter } from "./base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_Oracle_Quoter.sol";
import { BalancerV3_LT_BPTOracle_Quoter } from "./base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_BPTOracle_Quoter.sol";

/**
 * @title Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel
 * @author Waymont
 * @notice The senior and junior tranches transfer in the same yield bearing ERC4626 shares (sUSDS, sUSDe, etc.), and the liquidity tranche provides secondary liquidity via a Balancer V3 pool pairing the senior tranche share against a quote asset (USDC, srRoyUSDC, etc.)
 * @dev ST/JT NAV computations convert tranche units (ERC4626 shares) to base assets using the vault's exchange rate and then convert base assets to NAV units using a Chainlink (compatible) oracle or an admin set exchange rate
 * @dev LT NAV computations value the pool position (BPT) using a manipulation-resistant Balancer V3 oracle, and the pool prices the senior share leg via this kernel's senior share rate provider
 */
contract Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel is
    IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter,
    BalancerV3_LT_BPTOracle_Quoter
{
    /**
     * @notice Kernel-specific initialization parameters
     * @custom:field stAndJTQuoterParams - The senior/junior tranche ERC4626-shares-to-Chainlink quoter's parameters
     * @custom:field ltQuoterParams - The liquidity tranche Balancer V3 quoter's parameters
     */
    struct KernelSpecificInitParams {
        IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter.ST_JT_QuoterSpecificParams stAndJTQuoterParams;
        BalancerV3_LT_BPTOracle_Quoter.LT_QuoterSpecificParams ltQuoterParams;
    }

    /// @notice Constructs the kernel state and resolves the quote asset from the liquidity tranche's Balancer V3 pool
    /// @param _params The standard construction parameters for the Royco Day kernel
    constructor(IRoycoDayKernel.RoycoDayKernelConstructionParams memory _params)
        RoycoDayKernel(_params)
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
        // Initialize the identical ERC4626 shares to Chainlink (compatible) oracle ST/JT quoter
        __IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter_init(_specificParams.stAndJTQuoterParams);
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
