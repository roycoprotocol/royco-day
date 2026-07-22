// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

/**
 * @title DispatchLogic
 * @author Waymont
 * @notice Dispatches operations for execution or simulation: an execution persists and returns its result, a simulation
 *         runs the same operation and unwinds every state change by reverting with SIMULATION_RESULT
 * @dev Either mode delivers the operation's result byte for byte, so callers decode without mode awareness:
 *      _dispatch serves operations that return bytes (the result keeps its offset and length words), _dispatchAndUnwrap serves
 *      operations that return value types (the result arrives bare)
 */
library DispatchLogic {
    /// @notice Thrown when a simulated operation returns instead of unwinding via its result-carrying revert
    error SIMULATION_CANNOT_MUTATE_STATE();

    /// @notice The result-carrying revert that unwinds a simulated operation
    /// @param result The simulated operation's ABI encoded result
    error SIMULATION_RESULT(bytes result);

    /// @notice The SIMULATION_RESULT selector a simulation's revert data is validated against
    bytes4 internal constant SIMULATION_RESULT_SELECTOR = 0x9d59ef49;

    /**
     * @notice Dispatches an operation that returns bytes for execution or simulation
     * @dev Should be used by any call site whose target function is declared to return bytes: their result is prefixed with its own offset and length words
     * @param _target The address the operation is dispatched into
     * @param _isPreview Whether this is a preview of the operation which must not mutate state
     * @param _callData The ABI encoded call to the operation
     * @return result The operation's ABI encoded return bytes
     */
    function _dispatch(address _target, bool _isPreview, bytes memory _callData) internal returns (bytes memory result) {
        return (_isPreview ? _simulate(_target, _callData, false) : _execute(_target, _callData));
    }

    /**
     * @notice Dispatches an operation that returns a value tuple for execution or simulation
     * @dev Should be used by any call site whose target function is declared to return value types: their result is the bare encoded values with no prefix
     * @param _target The address the operation is dispatched into
     * @param _isPreview Whether this is a preview of the operation which must not mutate state
     * @param _callData The ABI encoded call to the operation
     * @return result The operation's ABI encoded return values
     */
    function _dispatchAndUnwrap(address _target, bool _isPreview, bytes memory _callData) internal returns (bytes memory result) {
        return (_isPreview ? _simulate(_target, _callData, true) : _execute(_target, _callData));
    }

    /**
     * @notice Simulates an operation through the execute-and-revert pattern and returns its result
     * @dev Validates that a reversion occurred downstream with the expected error selector
     * @param _target The address the simulated operation is dispatched into
     * @param _callData The ABI encoded call to the operation's execute-and-revert function
     * @param _unwrap Whether to strip the error's offset and length words from the result: stripping matches an operation declared to return value types, keeping them matches one declared to return bytes
     * @return result The simulated operation's ABI encoded result
     */
    function _simulate(address _target, bytes memory _callData, bool _unwrap) internal returns (bytes memory result) {
        // Call the function and ensure it reverted
        (bool success, bytes memory revertData) = _target.call(_callData);
        // NOTE: Should be unreachable since the simulation is required to revert downstream
        require(!success, SIMULATION_CANNOT_MUTATE_STATE());

        // Ensure that the exception has the correct selector for the simulate operation (indicating a successful simulation) and propagate the result upstream
        assembly ("memory-safe") {
            // Revert with any genuine operation failure, mimicking the operation exactly
            let errorSelectorPtr := add(revertData, 0x20)
            if iszero(eq(shr(224, mload(errorSelectorPtr)), shr(224, SIMULATION_RESULT_SELECTOR))) {
                revert(errorSelectorPtr, mload(revertData))
            }

            // Handle the unwrap as specified
            switch _unwrap
            case 1 {
                // Seek past the container's length word, the validated selector, and the error's offset word
                // The caller only consumes the carried result
                result := add(revertData, 0x44)
            }
            default {
                // Seek the result pointer by 4 bytes (selector length)
                result := add(revertData, 0x04)
                // Write the new length of the result excluding the selector to the first word of result, effectively wiping the selector and seeking the entire result
                mstore(result, sub(mload(revertData), 4))
            }
        }
    }

    /**
     * @notice Executes an operation and returns its revertData, bubbling any failure verbatim
     * @param _target The address the operation is dispatched into
     * @param _callData The ABI encoded call to the operation
     * @return result The operation's revertData
     */
    function _execute(address _target, bytes memory _callData) private returns (bytes memory result) {
        bool success;
        (success, result) = _target.call(_callData);
        // Revert with any genuine operation failure, mimicking the operation exactly
        assembly ("memory-safe") {
            if iszero(success) {
                revert(add(result, 0x20), mload(result))
            }
        }
    }
}
