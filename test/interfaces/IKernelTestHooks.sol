// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { NAV_UNIT, TRANCHE_UNIT } from "../../src/libraries/Units.sol";

/// @title IKernelTestHooks
/// @notice Interface for kernel-specific test hooks that allow NAV manipulation
/// @dev Each kernel test implementation must implement these hooks to enable yield/loss simulation
interface IKernelTestHooks {
    /// @notice Configuration for the test
    struct TestConfig {
        uint256 forkBlock; // Block to fork at
        string forkRpcUrlEnvVar; // RPC URL environment variable name
        address stAsset; // Senior tranche asset
        address jtAsset; // Junior tranche asset
        uint256 initialFunding; // Initial funding amount per user
    }

    /// @notice Returns the test configuration
    function getTestConfig() external view returns (TestConfig memory);

    /// @notice Simulates yield generation (positive NAV change) for ST
    /// @param _percentageWAD The percentage increase in WAD (e.g., 0.05e18 = 5%)
    function simulateSTYield(uint256 _percentageWAD) external;

    /// @notice Simulates yield generation (positive NAV change) for JT
    /// @param _percentageWAD The percentage increase in WAD (e.g., 0.05e18 = 5%)
    function simulateJTYield(uint256 _percentageWAD) external;

    /// @notice Simulates loss (negative NAV change) for ST
    /// @param _percentageWAD The percentage decrease in WAD (e.g., 0.05e18 = 5%)
    function simulateSTLoss(uint256 _percentageWAD) external;

    /// @notice Simulates loss (negative NAV change) for JT
    /// @param _percentageWAD The percentage decrease in WAD (e.g., 0.05e18 = 5%)
    function simulateJTLoss(uint256 _percentageWAD) external;

    /// @notice Deals the ST asset to an address
    /// @param _to The address to deal tokens to
    /// @param _amount The amount to deal
    function dealSTAsset(address _to, uint256 _amount) external;

    /// @notice Deals the JT asset to an address
    /// @param _to The address to deal tokens to
    /// @param _amount The amount to deal
    function dealJTAsset(address _to, uint256 _amount) external;

    /// @notice Returns the maximum delta tolerance for tranche unit comparisons
    function maxTrancheUnitDelta() external view returns (TRANCHE_UNIT);

    /// @notice Returns the maximum delta tolerance for NAV comparisons
    function maxNAVDelta() external view returns (NAV_UNIT);
}
