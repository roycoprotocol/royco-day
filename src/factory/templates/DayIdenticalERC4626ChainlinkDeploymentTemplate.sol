// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ILPOracleFactoryBase } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/oracles/ILPOracleFactoryBase.sol";
import { GyroECLPPoolFactory } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoFactory } from "../../interfaces/factory/IRoycoFactory.sol";
import {
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel
} from "../../kernels/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel.sol";
import { IdenticalAssets_ST_JT_ChainlinkOracle_Quoter } from "../../kernels/base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.sol";
import { IdenticalAssets_ST_JT_Oracle_Quoter } from "../../kernels/base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_Oracle_Quoter.sol";
import { ADMIN_ORACLE_QUOTER_ROLE } from "../RolesConfiguration.sol";
import { BalancerV3DeploymentTemplate } from "./BalancerV3DeploymentTemplate.sol";
import { COMPONENT_ID_DAY_KERNEL_IDENTICAL_ERC4626_CHAINLINK } from "./base/Components.sol";

/**
 * @title DayIdenticalERC4626ChainlinkDeploymentTemplate
 * @notice Concrete Royco Day deployment template for a market whose ST/JT kernel is
 *         `Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel` and whose LT holds a Gyro E-CLP pool position
 */
contract DayIdenticalERC4626ChainlinkDeploymentTemplate is BalancerV3DeploymentTemplate {
    constructor(
        IRoycoFactory _factory,
        GyroECLPPoolFactory _balancerV3PoolFactory,
        ILPOracleFactoryBase _eclpLPOracleFactory
    )
        BalancerV3DeploymentTemplate(_factory, _balancerV3PoolFactory, _eclpLPOracleFactory)
    { }

    /// @inheritdoc BalancerV3DeploymentTemplate
    function _kernelComponentId() internal pure override(BalancerV3DeploymentTemplate) returns (bytes32) {
        return COMPONENT_ID_DAY_KERNEL_IDENTICAL_ERC4626_CHAINLINK;
    }

    /// @inheritdoc BalancerV3DeploymentTemplate
    function _kernelInitData(
        IRoycoDayKernel.RoycoDayKernelInitParams memory _kip,
        bytes memory _kernelSpecificParams,
        address _bptOracle
    )
        internal
        pure
        override(BalancerV3DeploymentTemplate)
        returns (bytes memory)
    {
        Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel.KernelSpecificInitParams memory qp =
            abi.decode(_kernelSpecificParams, (Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel.KernelSpecificInitParams));
        // Set the BPT oracle to the template-deployed oracle
        qp.ltQuoterParams.bptOracle = _bptOracle;
        return abi.encodeCall(Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel.initialize, (_kip, qp));
    }

    /**
     * @inheritdoc BalancerV3DeploymentTemplate
     * @dev Extends the base's LT-quoter setters with this kernel family's ST/JT Chainlink quoter setters, all bound
     *      to ADMIN_ORACLE_QUOTER_ROLE. (Every restricted selector must be explicitly bound: an unbound selector
     *      silently defaults to ADMIN_ROLE under OZ AccessManager.)
     */
    function _kernelQuoterBinding(address _kernel) internal view override(BalancerV3DeploymentTemplate) returns (TargetBinding memory) {
        TargetBinding memory base = super._kernelQuoterBinding(_kernel);

        bytes4[] memory s = new bytes4[](base.selectors.length + 3);
        uint64[] memory r = new uint64[](base.selectors.length + 3);
        for (uint256 i; i < base.selectors.length; ++i) {
            s[i] = base.selectors[i];
            r[i] = base.roleIds[i];
        }
        uint256 j = base.selectors.length;
        s[j] = IdenticalAssets_ST_JT_Oracle_Quoter.setConversionRate.selector;
        r[j] = ADMIN_ORACLE_QUOTER_ROLE;
        s[j + 1] = IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.setChainlinkOracle.selector;
        r[j + 1] = ADMIN_ORACLE_QUOTER_ROLE;
        s[j + 2] = IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.setSequencerUptimeFeed.selector;
        r[j + 2] = ADMIN_ORACLE_QUOTER_ROLE;
        return TargetBinding({ target: _kernel, selectors: s, roleIds: r });
    }
}
