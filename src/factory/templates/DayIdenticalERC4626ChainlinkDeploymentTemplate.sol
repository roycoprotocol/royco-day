// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { GyroECLPPoolFactory } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoFactory } from "../../interfaces/factory/IRoycoFactory.sol";
import { BalancerV3_LT_Kernel } from "../../kernels/BalancerV3_LT_Kernel.sol";
import {
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_LT_Quoter
} from "../../quoters/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_LT_Quoter.sol";
import { BalancerV3DeploymentTemplate } from "./BalancerV3DeploymentTemplate.sol";
import { COMPONENT_ID_DAY_KERNEL_IDENTICAL_ERC4626_CHAINLINK, COMPONENT_ID_DAY_QUOTER_IDENTICAL_ERC4626_CHAINLINK } from "./base/Components.sol";

/**
 * @title DayIdenticalERC4626ChainlinkDeploymentTemplate
 * @notice Concrete Royco Day deployment template for a market whose kernel is `BalancerV3_LT_Kernel` and whose
 *         quoter is `Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_LT_Quoter` (ST/JT share an ERC4626
 *         vault share priced share->base via `convertToAssets`, base->NAV via Chainlink; the LT holds a Gyro E-CLP BPT).
 * @dev The Balancer pool creation, three-tranche + accountant + kernel + quoter deployment, role bindings, and `verify`
 *      are all inherited from `BalancerV3DeploymentTemplate`. This subclass only plugs in the concrete kernel and quoter
 *      via their registered creation-code ids (`_kernelComponentId()`/`_quoterComponentId()`) and their `initialize`
 *      calldata builders (`_kernelInitData()`/`_quoterInitData()`).
 */
contract DayIdenticalERC4626ChainlinkDeploymentTemplate is BalancerV3DeploymentTemplate {
    constructor(IRoycoFactory _factory, GyroECLPPoolFactory _balancerV3PoolFactory) BalancerV3DeploymentTemplate(_factory, _balancerV3PoolFactory) { }

    /// @inheritdoc BalancerV3DeploymentTemplate
    function _kernelComponentId() internal pure override(BalancerV3DeploymentTemplate) returns (bytes32) {
        return COMPONENT_ID_DAY_KERNEL_IDENTICAL_ERC4626_CHAINLINK;
    }

    /// @inheritdoc BalancerV3DeploymentTemplate
    function _quoterComponentId() internal pure override(BalancerV3DeploymentTemplate) returns (bytes32) {
        return COMPONENT_ID_DAY_QUOTER_IDENTICAL_ERC4626_CHAINLINK;
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
        BalancerV3_LT_Kernel.KernelSpecificInitParams memory kp =
            abi.decode(_kernelSpecificParams, (BalancerV3_LT_Kernel.KernelSpecificInitParams));
        return abi.encodeCall(BalancerV3_LT_Kernel.initialize, (_kip, kp));
    }

    /// @inheritdoc BalancerV3DeploymentTemplate
    function _quoterInitData(address _authority, bytes memory _quoterSpecificParams) internal view override(BalancerV3DeploymentTemplate) returns (bytes memory) {
        Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_LT_Quoter.QuoterSpecificInitParams memory qp = abi.decode(
            _quoterSpecificParams, (Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_LT_Quoter.QuoterSpecificInitParams)
        );
        return abi.encodeCall(Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_LT_Quoter.initialize, (_authority, qp));
    }
}
