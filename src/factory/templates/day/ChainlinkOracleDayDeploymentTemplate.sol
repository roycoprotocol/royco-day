// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { GyroECLPPoolFactory } from "../../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { IRoycoDayKernel } from "../../../interfaces/IRoycoDayKernel.sol";
import { IRoycoFactory } from "../../../interfaces/factory/IRoycoFactory.sol";
import { RoycoDayKernel } from "../../../kernels/day/RoycoDayKernel.sol";
import { COMPONENT_ID_DAY_KERNEL_CHAINLINK_ST_CHAINLINK_QUOTE } from "../Components.sol";
import { DayDeploymentTemplate } from "./base/DayDeploymentTemplate.sol";

/**
 * @title ChainlinkOracleDayDeploymentTemplate
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Deployment template for a Royco Day market whose senior/junior assets are priced by a Chainlink-compatible
 *         oracle (to an admin-set NAV rate), with an LT holding the Gyro E-CLP BPT of `{ST_share, quote}`.
 * @dev Concrete subclass of {DayDeploymentTemplate}. STUB-stage: the Day kernel prices ST/JT exactly as the
 *      corresponding Dawn kernel; the LT/quote pricing + flows are added later.
 */
contract ChainlinkOracleDayDeploymentTemplate is DayDeploymentTemplate {
    /// @notice Kernel-specific params decoded from `DayParams.kernelSpecificParams`.
    struct KernelParams {
        uint256 initialConversionRateWAD;
        address trancheAssetToReferenceAssetOracle;
        uint48 stalenessThresholdSeconds;
    }

    constructor(IRoycoFactory _factory, GyroECLPPoolFactory _balancerV3PoolFactory) DayDeploymentTemplate(_factory, _balancerV3PoolFactory) { }

    function _kernelComponentId() internal pure override returns (bytes32) {
        return COMPONENT_ID_DAY_KERNEL_CHAINLINK_ST_CHAINLINK_QUOTE;
    }

    function _kernelInitData(
        IRoycoDayKernel.RoycoDayKernelInitParams memory _kip,
        bytes memory _kernelSpecificParams
    )
        internal
        pure
        override
        returns (bytes memory)
    {
        KernelParams memory k = abi.decode(_kernelSpecificParams, (KernelParams));
        return abi.encodeCall(RoycoDayKernel.initialize, (_kip, k.initialConversionRateWAD, k.trancheAssetToReferenceAssetOracle, k.stalenessThresholdSeconds));
    }
}
