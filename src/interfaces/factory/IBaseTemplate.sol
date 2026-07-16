// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IRoycoFactory } from "./IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "./IRoycoProtocolTemplate.sol";

/**
 * @title IBaseTemplate
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Common surface shared by every concrete Royco deployment template, on top of `IRoycoProtocolTemplate`
 */
interface IBaseTemplate is IRoycoProtocolTemplate {
    /// @notice Thrown when a factory-only function is called by another address
    error ONLY_ROYCO_FACTORY();
    /// @notice Thrown when the template is constructed with the zero address as its factory
    error ROYCO_FACTORY_CANNOT_BE_ZERO_ADDRESS();
    /// @notice Thrown when two index-aligned arrays have mismatched lengths
    error LENGTH_MISMATCH();
    /// @notice Thrown when a component's creation code is set more than once
    error CREATION_CODE_ALREADY_SET(bytes32 componentId);
    /// @notice Thrown when a component's creation code is empty
    error CREATION_CODE_CANNOT_BE_EMPTY(bytes32 componentId);
    /// @notice Thrown when reading a component whose creation code was never set
    error CREATION_CODE_NOT_SET(bytes32 componentId);

    /// @notice The factory this template is bound to
    function ROYCO_FACTORY() external view returns (IRoycoFactory);

    /// @notice Returns the SSTORE2 pointer holding a component's creation code (zero if unset)
    function bytecodePointer(bytes32 _componentId) external view returns (address);

    /// @notice Whether the template's component bytecode store has been initialized
    function isInitialized() external view returns (bool);
}
