// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IRoycoDayEntryPoint } from "../IRoycoDayEntryPoint.sol";

/**
 * @title IRoycoFactoryGatekeeper
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Interface for the contract that holds `ADMIN_ROLE` on the Royco access manager on the factory's behalf and
 *         permits market deployments to configure only contracts that have never been configured before
 */
interface IRoycoFactoryGatekeeper {
    /// @notice Emitted when a target is configured through the gatekeeper
    event FreshTargetConfigured(address indexed target, uint256 selectorCount);

    /// @notice Emitted when a market's periphery is configured: its tranches on the entry point and its kernel on the syncer
    event MarketPeripheryConfigured(address indexed kernel, uint256 trancheCount);

    /// @notice Thrown when any caller other than the factory invokes the gatekeeper
    error ONLY_FACTORY();

    /// @notice Thrown when the target already carries configuration and so may never be configured by a deployment
    error TARGET_ALREADY_CONFIGURED(address target);

    /// @notice Thrown when the target is the access manager, the factory, or the gatekeeper itself
    error TARGET_FORBIDDEN(address target);

    /// @notice Thrown when a deployment binds a selector to a role that would leave it ungated or super-admin-only
    error ROLE_FORBIDDEN(uint64 roleId);

    /// @notice Thrown when a tranche already carries an entry point configuration, so a deployment may not set one
    error TRANCHE_ALREADY_CONFIGURED(address tranche);

    /// @notice Thrown when a kernel is already registered on the market syncer
    error KERNEL_ALREADY_REGISTERED(address kernel);

    /// @notice Thrown when the pinned entry point's provenance registry is not the factory this gatekeeper serves
    error ENTRY_POINT_BOUND_TO_DIFFERENT_FACTORY();

    /// @notice Thrown when a constructor argument that must name a live contract holds no code
    error CONSTRUCTION_PARAMETER_HAS_NO_CODE(address subject);

    /// @notice Thrown when the selector and role arrays differ in length
    error LENGTH_MISMATCH();

    /// @notice Thrown when a constructor argument is the zero address
    error NULL_ADDRESS();

    /// @notice The access manager this gatekeeper holds `ADMIN_ROLE` on
    function ROYCO_ACCESS_MANAGER() external view returns (address accessManager);

    /// @notice The only address permitted to call this gatekeeper
    function ROYCO_FACTORY() external view returns (address factory);

    /// @notice The chain's Royco Day entry point singleton, on which every deployed market's tranches are configured
    function ROYCO_DAY_ENTRY_POINT() external view returns (address entryPoint);

    /// @notice The chain's Royco market syncer singleton, on which every deployed market's kernel is registered
    function ROYCO_MARKET_SYNCER() external view returns (address marketSyncer);

    /**
     * @notice Binds a set of selectors on a never-before-configured target to their roles
     * @dev Reverts unless the target is genuinely fresh, so a market deployment can configure only contracts it just
     *      created and can never re-point an existing market, a periphery singleton, or the protocol's own contracts
     * @dev The whole target is configured in ONE call by design. The freshness check runs once, before the first write
     *      marks the target configured; a call-per-selector API would reject every target's second selector
     * @param _target The contract to configure
     * @param _selectors The selectors to bind, index-aligned with `_roleIds`
     * @param _roleIds The role each selector is bound to
     */
    function configureFreshTarget(address _target, bytes4[] calldata _selectors, uint64[] calldata _roleIds) external;

    /**
     * @notice Configures a freshly deployed market's periphery: its tranches on the entry point and its kernel on the syncer
     * @dev The gatekeeper, not the factory, holds the periphery's admin roles, so a market deployment reaches the
     *      entry point and the syncer only through this one narrow, freshness-checked call
     * @dev Every tranche must be unconfigured and the kernel unregistered. Both are freshly CREATE3-deployed per
     *      market, so a collision here means a `marketId` reuse that would otherwise silently re-point live config
     * @param _tranches The market's tranches to configure, index-aligned with `_configs`; every market carries all three, so none may be null
     * @param _configs The entry point configuration for each tranche, index-aligned with `_tranches`
     * @param _kernel The market's kernel, registered on the syncer's batch accounting sync set
     */
    function configureMarketPeriphery(address[] calldata _tranches, IRoycoDayEntryPoint.TrancheConfig[] calldata _configs, address _kernel) external;
}
