// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { BalancerPoolToken } from "../../lib/balancer-v3-monorepo/pkg/vault/contracts/BalancerPoolToken.sol";
import { IRoycoDayKernel } from "../../src/interfaces/IRoycoDayKernel.sol";
import { RoycoDayKernel } from "../../src/kernels/base/RoycoDayKernel.sol";
import {
    IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter
} from "../../src/kernels/base/quoter/identical-st-jt/IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter.sol";
import { IdenticalAssets_ST_JT_Oracle_Quoter } from "../../src/kernels/base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_Oracle_Quoter.sol";
import { BalancerV3_LT_BPTOracle_Quoter } from "../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_BPTOracle_Quoter.sol";

/**
 * @title Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3_BPTOracle_LT_Kernel
 * @notice Test-only concrete kernel composing the Chainlink-to-admin-oracle ST/JT quoter with the Balancer V3
 *         BPT-oracle liquidity tranche quoter, mirroring the shipped ERC4626-to-Chainlink kernel's shape
 * @dev The Chainlink-to-admin quoter ships abstract with no concrete kernel wiring it, so tests exercise it through
 *      this composition. The exposed oracle-query shim lets tests pin the admin backstop's unreachable-revert design
 */
contract Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3_BPTOracle_LT_Kernel is
    IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter,
    BalancerV3_LT_BPTOracle_Quoter
{
    /**
     * @notice Kernel-specific initialization parameters
     * @custom:field stAndJTQuoterParams - The senior/junior tranche Chainlink-to-admin-oracle quoter's parameters
     * @custom:field ltQuoterParams - The liquidity tranche Balancer V3 quoter's parameters
     */
    struct KernelSpecificInitParams {
        IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter.ST_JT_QuoterSpecificParams stAndJTQuoterParams;
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
        __RoycoDayKernel_init(_standardParams);
        __IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter_init(_specificParams.stAndJTQuoterParams);
        __BalancerV3_LT_BPTOracle_Quoter_init_unchained(_specificParams.ltQuoterParams);
    }

    /// @notice Exposes the internal oracle-query helper so tests can pin its unreachable-backstop revert directly
    /// @return conversionRateWAD Never returns, the admin-oracle composition's helper always reverts
    function exposed_getConversionRateFromOracleWAD() external pure returns (uint256 conversionRateWAD) {
        return _getConversionRateFromOracleWAD();
    }

    /// @inheritdoc RoycoDayKernel
    function _initializeQuoterCache() internal override(RoycoDayKernel, IdenticalAssets_ST_JT_Oracle_Quoter) {
        IdenticalAssets_ST_JT_Oracle_Quoter._initializeQuoterCache();
    }
}
