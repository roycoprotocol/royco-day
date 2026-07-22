// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import { GyroECLPPoolFactory } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoFactory } from "../../interfaces/factory/IRoycoFactory.sol";
import {
    Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel
} from "../../kernels/Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel.sol";
import { IdenticalAssets_ST_JT_ChainlinkOracle_Quoter } from "../../kernels/base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.sol";
import { IdenticalAssets_ST_JT_Oracle_Quoter } from "../../kernels/base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_Oracle_Quoter.sol";
import { ADMIN_ORACLE_QUOTER_ROLE } from "../Roles.sol";
import { BalancerV3_GyroECLP_LT_DeploymentTemplate } from "./liquidity-tranche/BalancerV3_GyroECLP_LT_DeploymentTemplate.sol";

/**
 * @title Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3GyroECLP_LT_DeploymentTemplate
 * @notice Concrete Royco Day deployment template for a market whose ST/JT kernel is
 *         `Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel` and whose LT holds a Gyro E-CLP pool position
 */
contract Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3GyroECLP_LT_DeploymentTemplate is BalancerV3_GyroECLP_LT_DeploymentTemplate {
    /**
     * @notice Kernel-specific params blob market deployers ABI-encode into `DayParams.kernelSpecificParams`
     * @custom:field makinaMachine - The Makina machine whose share token is the ST/JT tranche asset, pinned as a kernel constructor arg
     * @custom:field initParams - The kernel initialization params, the template overwrites `ltQuoterParams.bptOracle` with its deployed oracle
     */
    struct KernelSpecificParams {
        address makinaMachine;
        Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel.KernelSpecificInitParams initParams;
    }

    constructor(
        IRoycoFactory _factory,
        GyroECLPPoolFactory _balancerV3PoolFactory,
        address _roycoDayEntryPoint,
        address _roycoMarketSyncer
    )
        BalancerV3_GyroECLP_LT_DeploymentTemplate(_factory, _balancerV3PoolFactory, _roycoDayEntryPoint, _roycoMarketSyncer)
    { }

    /// @inheritdoc BalancerV3_GyroECLP_LT_DeploymentTemplate
    /// @dev Verifies the Makina kernel's machine immutable matches the params (its extra constructor arg, deployed script-side)
    function _validateKernelSpecifics(address _kernel, bytes memory _kernelSpecificParams) internal view override(BalancerV3_GyroECLP_LT_DeploymentTemplate) {
        KernelSpecificParams memory p = abi.decode(_kernelSpecificParams, (KernelSpecificParams));
        require(
            Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel(_kernel).MAKINA_MACHINE() == p.makinaMachine,
            MARKET_WIRING_VERIFICATION_FAILED(_kernel)
        );
    }

    /// @inheritdoc BalancerV3_GyroECLP_LT_DeploymentTemplate
    function _kernelInitData(
        IRoycoDayKernel.RoycoDayKernelInitParams memory _kip,
        bytes memory _kernelSpecificParams,
        address _bptOracle
    )
        internal
        pure
        override(BalancerV3_GyroECLP_LT_DeploymentTemplate)
        returns (bytes memory)
    {
        KernelSpecificParams memory p = abi.decode(_kernelSpecificParams, (KernelSpecificParams));
        // Set the BPT oracle to the template-deployed oracle
        p.initParams.ltQuoterParams.bptOracle = _bptOracle;
        return abi.encodeCall(Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel.initialize, (_kip, p.initParams));
    }

    /// @inheritdoc BalancerV3_GyroECLP_LT_DeploymentTemplate
    /// @dev Extends the base's LT-quoter setters with this kernel family's ST/JT Chainlink quoter setters, all bound to ADMIN_ORACLE_QUOTER_ROLE.
    function _kernelQuoterBinding() internal view override(BalancerV3_GyroECLP_LT_DeploymentTemplate) returns (bytes4[] memory s, uint64[] memory r) {
        (bytes4[] memory bs, uint64[] memory br) = super._kernelQuoterBinding();

        s = new bytes4[](bs.length + 3);
        r = new uint64[](bs.length + 3);
        for (uint256 i; i < bs.length; ++i) {
            s[i] = bs[i];
            r[i] = br[i];
        }
        uint256 j = bs.length;
        s[j] = IdenticalAssets_ST_JT_Oracle_Quoter.setConversionRate.selector;
        r[j] = ADMIN_ORACLE_QUOTER_ROLE;
        s[j + 1] = IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.setChainlinkOracle.selector;
        r[j + 1] = ADMIN_ORACLE_QUOTER_ROLE;
        s[j + 2] = IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.setSequencerUptimeFeed.selector;
        r[j + 2] = ADMIN_ORACLE_QUOTER_ROLE;
    }
}
