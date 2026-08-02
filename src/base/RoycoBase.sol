// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { RoycoAuth } from "../auth/RoycoAuth.sol";

/**
 * @title RoycoBase
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Abstract base contract for upgradeable Royco protocol contracts
 */
abstract contract RoycoBase is RoycoAuth {
    /// @dev Disable the initializers
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the Royco base contract
    /// @param _initialAuthority The initial authority for the contract
    function __RoycoBase_init(address _initialAuthority) internal onlyInitializing {
        __RoycoAuth_init(_initialAuthority);
    }
}
