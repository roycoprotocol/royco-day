// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { AccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { IRoycoAccessManager } from "../interfaces/factory/IRoycoAccessManager.sol";
import { IRoycoFactoryGatekeeper } from "../interfaces/factory/IRoycoFactoryGatekeeper.sol";
import { ADMIN_ROLE, BURNER_ROLE, PUBLIC_ROLE, SYNC_ROLE } from "./Roles.sol";

/**
 * @title RoycoFactoryGatekeeper
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Holds `ADMIN_ROLE` on the Royco access manager so the factory does not have to, and lets a market deployment
 *         configure only contracts that have never been configured before
 */
contract RoycoFactoryGatekeeper is IRoycoFactoryGatekeeper {
    /// @inheritdoc IRoycoFactoryGatekeeper
    address public immutable override(IRoycoFactoryGatekeeper) ROYCO_ACCESS_MANAGER;

    /// @inheritdoc IRoycoFactoryGatekeeper
    address public immutable override(IRoycoFactoryGatekeeper) ROYCO_FACTORY;

    /// @dev Restricts a call to the one factory this gatekeeper serves
    modifier onlyFactory() {
        require(msg.sender == ROYCO_FACTORY, ONLY_FACTORY());
        _;
    }

    /**
     * @param _roycoAccessManager The access manager this gatekeeper holds `ADMIN_ROLE` on
     * @param _roycoFactory The only address permitted to call this gatekeeper, supplied as the CREATE3 address the
     *        factory proxy will occupy: that address is fixed by its salt, so it is knowable before the proxy exists
     */
    constructor(address _roycoAccessManager, address _roycoFactory) {
        require(_roycoAccessManager != address(0) && _roycoFactory != address(0), NULL_ADDRESS());
        ROYCO_ACCESS_MANAGER = _roycoAccessManager;
        ROYCO_FACTORY = _roycoFactory;
    }

    /// @inheritdoc IRoycoFactoryGatekeeper
    function configureFreshTarget(
        address _target,
        bytes4[] calldata _selectors,
        uint64[] calldata _roleIds
    )
        external
        override(IRoycoFactoryGatekeeper)
        onlyFactory
    {
        uint256 numSelectorsToBind = _selectors.length;
        require(numSelectorsToBind == _roleIds.length, LENGTH_MISMATCH());

        // The protocol's own contracts are never legitimate deployment targets, and a target may be configured exactly once, by the deployment that created it
        _requireNotConfigured(_target);

        // Bind the selectors to the target
        AccessManager accessManager = AccessManager(ROYCO_ACCESS_MANAGER);
        bytes4[] memory selector = new bytes4[](1);
        for (uint256 i; i < numSelectorsToBind; ++i) {
            require(_roleIds[i] != PUBLIC_ROLE && _roleIds[i] != ADMIN_ROLE, ROLE_FORBIDDEN(_roleIds[i]));
            selector[0] = _selectors[i];
            accessManager.setTargetFunctionRole(_target, selector, _roleIds[i]);
        }

        emit FreshTargetConfigured(_target, numSelectorsToBind);
    }

    /// @inheritdoc IRoycoFactoryGatekeeper
    function grantMarketRoles(
        uint64[] calldata _roleIds,
        address[] calldata _accounts,
        uint32[] calldata _executionDelays
    )
        external
        override(IRoycoFactoryGatekeeper)
        onlyFactory
    {
        uint256 numRolesToGrant = _roleIds.length;
        require(numRolesToGrant == _accounts.length && numRolesToGrant == _executionDelays.length, LENGTH_MISMATCH());

        AccessManager accessManager = AccessManager(ROYCO_ACCESS_MANAGER);
        for (uint256 i; i < numRolesToGrant; ++i) {
            require(_roleIds[i] == SYNC_ROLE || _roleIds[i] == BURNER_ROLE, ROLE_FORBIDDEN(_roleIds[i]));
            // Verify the contract has never been configured
            _requireNotConfigured(_accounts[i]);
            accessManager.grantRole(_roleIds[i], _accounts[i], _executionDelays[i]);
        }
        emit MarketRolesGranted(numRolesToGrant);
    }

    /// @dev A market deployment may only act on a contract that has never been configured before
    /// @param _subject The address a deployment is asking to configure or to grant a role to
    function _requireNotConfigured(address _subject) private view {
        require(_subject != ROYCO_ACCESS_MANAGER && _subject != ROYCO_FACTORY && _subject != address(this), TARGET_FORBIDDEN(_subject));
        require(!IRoycoAccessManager(ROYCO_ACCESS_MANAGER).wasEverConfigured(_subject), TARGET_ALREADY_CONFIGURED(_subject));
    }
}
