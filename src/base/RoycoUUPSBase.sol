// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { RoycoBase } from "./RoycoBase.sol";

/**
 * @title RoycoUUPSBase
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Abstract base for the Royco contracts that carry their own upgrade mechanism
 */
abstract contract RoycoUUPSBase is UUPSUpgradeable, RoycoBase {
    /// @dev Thrown when the new implementation for this contract is invalid
    error INVALID_IMPLEMENTATION();

    /// @dev Restricts the upgrade to only the authorized roles
    function _authorizeUpgrade(address _newImplementation) internal override(UUPSUpgradeable) restricted {
        require(_newImplementation.code.length > 0, INVALID_IMPLEMENTATION());
    }
}
