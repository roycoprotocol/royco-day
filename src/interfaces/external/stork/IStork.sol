// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/**
 * @title StorkStructs
 * @author Stork Labs
 * @notice Abridged Stork EVM SDK types (`@storknetwork/stork-evm-sdk/StorkStructs.sol`) a Royco collateral oracle reads
 */
library StorkStructs {
    /**
     * @notice A publisher-signed value at a point in time
     * @custom:field timestampNs - The publisher timestamp of the value, in NANOSECONDS since the unix epoch (not seconds)
     * @custom:field quantizedValue - The value, scaled to 18 decimals
     */
    struct TemporalNumericValue {
        uint64 timestampNs;
        int192 quantizedValue;
    }
}

/**
 * @title IStork
 * @author Stork Labs
 * @notice Abridged interface of the Stork core (pull oracle) contract a Royco collateral oracle reads
 * @dev Reads are free; publishers push signed updates through the (fee-bearing) update path, which is out of scope here
 */
interface IStork {
    /// @notice Thrown when no value has ever been published for the asset id
    error NotFound();

    /// @notice Thrown by the checked getter when the value is older than the contract-wide valid time period
    error StaleValue();

    /**
     * @notice Returns the latest value for an asset, reverting if it is older than `validTimePeriodSeconds`
     * @param id The Stork encoded asset id
     * @return value The latest value and its publisher timestamp
     */
    function getTemporalNumericValueV1(bytes32 id) external view returns (StorkStructs.TemporalNumericValue memory value);

    /**
     * @notice Returns the latest value for an asset with no freshness check
     * @param id The Stork encoded asset id
     * @return value The latest value and its publisher timestamp
     */
    function getTemporalNumericValueUnsafeV1(bytes32 id) external view returns (StorkStructs.TemporalNumericValue memory value);

    /// @notice The contract-wide maximum age the checked getter accepts, in seconds
    function validTimePeriodSeconds() external view returns (uint256);

    /// @notice The Stork contract version string
    function version() external view returns (string memory);
}
