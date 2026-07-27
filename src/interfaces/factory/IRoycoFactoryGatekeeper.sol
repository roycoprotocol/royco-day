// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

/**
 * @title IRoycoFactoryGatekeeper
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Interface for the contract that holds `ADMIN_ROLE` on the Royco access manager on the factory's behalf and
 *         permits market deployments to configure only contracts that have never been configured before
 */
interface IRoycoFactoryGatekeeper {
    /// @notice Emitted when a target is configured through the gatekeeper
    event FreshTargetConfigured(address indexed target, uint256 selectorCount);
    /// @notice Emitted when a market deployment's role grants are applied
    event MarketRolesGranted(uint256 grantCount);

    /// @notice Thrown when any caller other than the factory invokes the gatekeeper
    error ONLY_FACTORY();
    /// @notice Thrown when the target already carries configuration and so may never be configured by a deployment
    error TARGET_ALREADY_CONFIGURED(address target);
    /// @notice Thrown when the target is the access manager, the factory, or the gatekeeper itself
    error TARGET_FORBIDDEN(address target);
    /// @notice Thrown when a market deployment tries to grant a role outside the two it legitimately mints
    error ROLE_FORBIDDEN(uint64 roleId);
    /// @notice Thrown when the selector and role arrays differ in length
    error LENGTH_MISMATCH();
    /// @notice Thrown when a constructor argument is the zero address
    error NULL_ADDRESS();

    /// @notice The access manager this gatekeeper holds `ADMIN_ROLE` on
    function ROYCO_ACCESS_MANAGER() external view returns (address accessManager);

    /// @notice The only address permitted to call this gatekeeper
    function ROYCO_FACTORY() external view returns (address factory);

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
     * @notice Grants the roles a market deployment mints, restricted to `SYNC_ROLE` and `BURNER_ROLE`
     * @param _roleIds The roles to grant, index-aligned with `_accounts` and `_executionDelays`
     * @param _accounts The accounts receiving them
     * @param _executionDelays The access manager execution delay applied to each grant
     */
    function grantMarketRoles(uint64[] calldata _roleIds, address[] calldata _accounts, uint32[] calldata _executionDelays) external;
}
