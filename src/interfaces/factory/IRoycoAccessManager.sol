// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

/**
 * @title IRoycoAccessManager
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice The Royco access manager's one addition over the OpenZeppelin `AccessManager`: a monotonic record of every
 *         target that has ever received configuration
 */
interface IRoycoAccessManager {
    /// @notice Emitted when a target receives configuration for the first time
    event TargetConfiguredAtGenesis(address indexed target);

    /**
     * @notice Whether a target has ever received configuration through this access manager
     * @dev Set by every target-scoped write (`setTargetFunctionRole`, `setTargetAdminDelay`, `setTargetClosed`),
     *      whoever the caller is: governance, the deployment script, and the factory's gatekeeper alike
     * @dev Monotonic with no clearing path: a reset would reintroduce exactly the capability the flag exists to remove
     * @param _target The contract to query
     * @return configured Whether the target has ever been configured
     */
    function wasEverConfigured(address _target) external view returns (bool configured);
}
