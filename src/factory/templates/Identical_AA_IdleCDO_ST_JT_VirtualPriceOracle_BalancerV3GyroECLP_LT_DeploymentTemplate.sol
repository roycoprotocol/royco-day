// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import { ILPOracleFactoryBase } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/oracles/ILPOracleFactoryBase.sol";
import { GyroECLPPoolFactory } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoFactory } from "../../interfaces/factory/IRoycoFactory.sol";
import {
    Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_BalancerV3_BPTOracle_LT_Kernel
} from "../../kernels/Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_BalancerV3_BPTOracle_LT_Kernel.sol";
import { IdenticalAssets_ST_JT_Oracle_Quoter } from "../../kernels/base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_Oracle_Quoter.sol";
import { ADMIN_ORACLE_QUOTER_ROLE } from "../RolesConfiguration.sol";
import { COMPONENT_ID_DAY_KERNEL_IDENTICAL_AA_IDLE_CDO_VIRTUAL_PRICE } from "./base/Components.sol";
import { BalancerV3_GyroECLP_LT_DeploymentTemplate } from "./liquidity-tranche/BalancerV3_GyroECLP_LT_DeploymentTemplate.sol";

/**
 * @title Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_BalancerV3GyroECLP_LT_DeploymentTemplate
 * @notice Concrete Royco Day deployment template for a market whose ST/JT kernel is
 *         `Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_BalancerV3_BPTOracle_LT_Kernel` and whose LT holds a Gyro E-CLP pool position
 */
contract Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_BalancerV3GyroECLP_LT_DeploymentTemplate is BalancerV3_GyroECLP_LT_DeploymentTemplate {
    /**
     * @notice Kernel-specific params blob market deployers ABI-encode into `DayParams.kernelSpecificParams`
     * @custom:field idleCDO - The Idle CDO whose AA tranche token is the ST/JT tranche asset, pinned as a kernel constructor arg
     * @custom:field initParams - The kernel initialization params, the template overwrites `ltQuoterParams.bptOracle` with its deployed oracle
     */
    struct KernelSpecificParams {
        address idleCDO;
        Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_BalancerV3_BPTOracle_LT_Kernel.KernelSpecificInitParams initParams;
    }

    constructor(
        IRoycoFactory _factory,
        GyroECLPPoolFactory _balancerV3PoolFactory,
        ILPOracleFactoryBase _eclpLPOracleFactory,
        address _roycoDayEntryPoint,
        address _roycoMarketSyncer
    )
        BalancerV3_GyroECLP_LT_DeploymentTemplate(_factory, _balancerV3PoolFactory, _eclpLPOracleFactory, _roycoDayEntryPoint, _roycoMarketSyncer)
    { }

    /// @inheritdoc BalancerV3_GyroECLP_LT_DeploymentTemplate
    function _kernelComponentId() internal pure override(BalancerV3_GyroECLP_LT_DeploymentTemplate) returns (bytes32) {
        return COMPONENT_ID_DAY_KERNEL_IDENTICAL_AA_IDLE_CDO_VIRTUAL_PRICE;
    }

    /// @inheritdoc BalancerV3_GyroECLP_LT_DeploymentTemplate
    /// @dev The Idle CDO kernel constructor takes the CDO address after the standard params
    function _kernelConstructionArgs(
        IRoycoDayKernel.RoycoDayKernelConstructionParams memory _cp,
        bytes memory _kernelSpecificParams
    )
        internal
        pure
        override(BalancerV3_GyroECLP_LT_DeploymentTemplate)
        returns (bytes memory)
    {
        KernelSpecificParams memory p = abi.decode(_kernelSpecificParams, (KernelSpecificParams));
        return abi.encode(_cp, p.idleCDO);
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
        return abi.encodeCall(Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_BalancerV3_BPTOracle_LT_Kernel.initialize, (_kip, p.initParams));
    }

    /**
     * @inheritdoc BalancerV3_GyroECLP_LT_DeploymentTemplate
     * @dev Extends the base's LT-quoter setters with this kernel family's sole ST/JT quoter setter, the root
     *      conversion rate setter, bound to ADMIN_ORACLE_QUOTER_ROLE. The virtual price quoter has no Chainlink
     *      layer so no other restricted ST/JT selectors exist. (Every restricted selector must be explicitly
     *      bound: an unbound selector silently defaults to ADMIN_ROLE under OZ AccessManager.)
     */
    function _kernelQuoterBinding(address _kernel) internal view override(BalancerV3_GyroECLP_LT_DeploymentTemplate) returns (TargetBinding memory) {
        TargetBinding memory base = super._kernelQuoterBinding(_kernel);

        bytes4[] memory s = new bytes4[](base.selectors.length + 1);
        uint64[] memory r = new uint64[](base.selectors.length + 1);
        for (uint256 i; i < base.selectors.length; ++i) {
            s[i] = base.selectors[i];
            r[i] = base.roleIds[i];
        }
        uint256 j = base.selectors.length;
        s[j] = IdenticalAssets_ST_JT_Oracle_Quoter.setConversionRate.selector;
        r[j] = ADMIN_ORACLE_QUOTER_ROLE;
        return TargetBinding({ target: _kernel, selectors: s, roleIds: r });
    }
}
