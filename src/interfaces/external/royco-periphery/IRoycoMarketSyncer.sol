// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

/**
 * @title IRoycoMarketSyncer
 * @notice Minimal surface of royco-periphery's RoycoMarketSyncer consumed by royco-day
 * @dev The syncer is deployed and governed from the royco-periphery repository; this interface only mirrors
 *      the selectors market deployments drive, keeping the production code decoupled from the periphery codebase
 */
interface IRoycoMarketSyncer {
    /// @notice Registers new market kernels on the syncer's batch accounting sync set
    /// @param _marketKernels The market kernels to register
    function addMarketKernels(address[] calldata _marketKernels) external;

    /**
     * @notice Returns whether the specified market kernel is registered on the syncer
     * @param _marketKernel The market kernel to check
     * @return registered Whether the market kernel is registered
     */
    function isMarketKernelRegistered(address _marketKernel) external view returns (bool registered);
}
