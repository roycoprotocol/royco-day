// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { NAV_UNIT } from "../libraries/Units.sol";

/**
 * @title IRoycoPriceOracle
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Oracle exposing the price of 1 whole collateral asset in NAV units (USD, BTC, ETH, etc.)
 * @dev Also serves as the update clock for the entry point's execution gate, so the kernel prices with and the entry point gates on the same source
 * @dev getPrice gates pricing (is the report current) and poke gates queue execution (has new pricing information arrived), so a pull-based source may report a current updatedAt from getPrice while poke only advances on an observed value change
 */
interface IRoycoPriceOracle {
    /// @notice The collateral asset this oracle prices in NAV units
    /// @return collateralAsset The collateral asset
    function COLLATERAL_ASSET() external view returns (address collateralAsset);

    /**
     * @notice Returns the price of 1 whole collateral asset in NAV units
     * @dev updatedAt must be the oldest update timestamp among the oracle's timestamped price hops (a hop read live from its source counts as current)
     * @return price The price of 1 whole collateral asset in NAV units
     * @return updatedAt The timestamp of the report's oldest price hop update
     */
    function getPrice() external view returns (NAV_UNIT price, uint256 updatedAt);

    /**
     * @notice Observes the underlying source, checkpointing a new update timestamp if its value has been updated
     * @dev Permissionless: the entry point pokes on every request and execution and the kernel pokes as the first operation of every pre-op accounting sync, so market traffic organically drives the clock
     * @dev May revert to act as a protocol circuit breaker (eg. on an implausible price change), halting every sync-gated operation until the condition clears or the admin replaces the oracle
     * @dev Must report only honest update times: the wall-clock timestamp of a genuine source update, and zero when none has been observed yet
     *      It must never report a manufactured (initialization-time) or future timestamp
     *      The entry point's execution gate compares this directly against request placement times, so a manufactured timestamp would open the gate without new pricing information, and a zero conservatively holds it shut
     * @return updatedAt The timestamp of the last observed update of the underlying source (zero if none observed yet)
     */
    function poke() external returns (uint256 updatedAt);

    /**
     * @notice Simulates a poke, returning the update timestamp it would report without committing it
     * @dev Used by the kernel's preview sync, so a circuit-breaking oracle reverts previews identically to the real operations
     * @return updatedAt The timestamp a poke would report (zero if none observed yet)
     */
    function previewPoke() external view returns (uint256 updatedAt);

    /// @notice Gets the price precision of the oracle
    /// @return 18 decimals of precision (NAV units always employ this)
    function decimals() external view returns (uint8);

    /// @notice Gets the description of the oracle
    /// @return The description of the oracle
    function description() external view returns (string memory);

    /// @notice Gets the version of the oracle
    /// @return The version of the oracle
    function version() external view returns (uint256);
}
