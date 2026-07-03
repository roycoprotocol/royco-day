// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { GyroECLPPoolFactory } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoFactory } from "../../interfaces/factory/IRoycoFactory.sol";
import {
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_LT_Kernel
} from "../../kernels/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_LT_Kernel.sol";
import { BalancerV3DeploymentTemplate } from "./BalancerV3DeploymentTemplate.sol";
import { COMPONENT_ID_DAY_KERNEL_IDENTICAL_ERC4626_CHAINLINK } from "./base/Components.sol";

/**
 * @title DayIdenticalERC4626ChainlinkDeploymentTemplate
 * @notice Concrete Royco Day deployment template for a market whose ST/JT kernel is
 *         `Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_LT_Kernel` and whose LT holds a Gyro E-CLP pool position.
 * @dev The Balancer pool creation, three-tranche + accountant + kernel deployment, role bindings, and `verify`
 *      are all inherited from `BalancerV3DeploymentTemplate`. This subclass only plugs in the concrete kernel
 *      via `_kernelComponentId()` (its registered creation-code id) and `_kernelInitData()` (its `initialize` calldata).
 */
contract DayIdenticalERC4626ChainlinkDeploymentTemplate is BalancerV3DeploymentTemplate {
    constructor(IRoycoFactory _factory, GyroECLPPoolFactory _balancerV3PoolFactory) BalancerV3DeploymentTemplate(_factory, _balancerV3PoolFactory) { }

    /// @inheritdoc BalancerV3DeploymentTemplate
    function _kernelComponentId() internal pure override(BalancerV3DeploymentTemplate) returns (bytes32) {
        return COMPONENT_ID_DAY_KERNEL_IDENTICAL_ERC4626_CHAINLINK;
    }

    /// @inheritdoc BalancerV3DeploymentTemplate
    function _kernelInitData(
        IRoycoDayKernel.RoycoDayKernelInitParams memory _kip,
        bytes memory _kernelSpecificParams
    )
        internal
        pure
        override(BalancerV3DeploymentTemplate)
        returns (bytes memory)
    {
        Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_LT_Kernel.KernelSpecificInitParams memory qp =
            abi.decode(_kernelSpecificParams, (Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_LT_Kernel.KernelSpecificInitParams));
        return abi.encodeCall(Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_LT_Kernel.initialize, (_kip, qp));
    }
}
