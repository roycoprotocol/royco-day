// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { BalancerPoolToken } from "../../lib/balancer-v3-monorepo/pkg/vault/contracts/BalancerPoolToken.sol";
import { IRoycoDayKernel } from "../../src/interfaces/IRoycoDayKernel.sol";
import { RoycoDayKernel } from "../../src/kernels/base/RoycoDayKernel.sol";
import {
    IdenticalMakinaShares_ST_JT_SharePriceToAdminOracle_Quoter
} from "../../src/kernels/base/quoter/identical-st-jt/IdenticalMakinaShares_ST_JT_SharePriceToAdminOracle_Quoter.sol";
import { IdenticalAssets_ST_JT_Oracle_Quoter } from "../../src/kernels/base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_Oracle_Quoter.sol";
import { BalancerV3_LT_BPTOracle_Quoter } from "../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_BPTOracle_Quoter.sol";

/**
 * @title Identical_Makina_ST_JT_SharePriceToAdminOracle_BalancerV3_BPTOracle_LT_Kernel
 * @notice Test-only concrete kernel composing the Makina machine-share-price-to-admin-oracle ST/JT quoter with the
 *         Balancer V3 BPT-oracle liquidity tranche quoter, mirroring the shipped ERC4626-to-Chainlink kernel's shape
 * @dev The Makina quoter ships abstract with no concrete kernel wiring it, so tests exercise it through this composition
 */
contract Identical_Makina_ST_JT_SharePriceToAdminOracle_BalancerV3_BPTOracle_LT_Kernel is
    IdenticalMakinaShares_ST_JT_SharePriceToAdminOracle_Quoter,
    BalancerV3_LT_BPTOracle_Quoter
{
    /**
     * @notice Kernel-specific initialization parameters
     * @custom:field stAndJTQuoterParams - The senior/junior tranche Makina-shares-to-admin-oracle quoter's parameters
     * @custom:field ltQuoterParams - The liquidity tranche Balancer V3 quoter's parameters
     */
    struct KernelSpecificInitParams {
        IdenticalMakinaShares_ST_JT_SharePriceToAdminOracle_Quoter.ST_JT_QuoterSpecificParams stAndJTQuoterParams;
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
        IdenticalMakinaShares_ST_JT_SharePriceToAdminOracle_Quoter(_makinaMachine)
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
        __RoycoDayKernel_init(_standardParams);
        __IdenticalMakinaShares_ST_JT_SharePriceToAdminOracle_Quoter_init(_specificParams.stAndJTQuoterParams);
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
