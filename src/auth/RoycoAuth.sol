// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { AccessManagedUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";
import { PausableUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { IRoycoAuth } from "../interfaces/IRoycoAuth.sol";

/**
 * @title RoycoAuth
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Abstract contract that provides access control and pausability functionality for Royco contracts
 * @dev Combines OpenZeppelin's AccessManager-based access control (`restricted` gating) with pausability
 */
abstract contract RoycoAuth is AccessManagedUpgradeable, PausableUpgradeable, IRoycoAuth {
    /// @notice Initializes the access control and pausability state
    /// @param _initialAuthority The initial authority (AccessManager) that governs the restricted functions
    function __RoycoAuth_init(address _initialAuthority) internal onlyInitializing {
        require(_initialAuthority != address(0), NULL_ADDRESS());
        __AccessManaged_init(_initialAuthority);
        __Pausable_init();
    }

    /// @inheritdoc IRoycoAuth
    function pause() external virtual restricted {
        _pause();
    }

    /// @inheritdoc IRoycoAuth
    function unpause() external virtual restricted {
        _unpause();
    }
}
