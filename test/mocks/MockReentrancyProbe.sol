// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title MockReentrancyProbe
 * @notice A payout receiver wired as a MockERC20C transfer hook that fires a configurable list of reentrant calls
 *         when it observes a token transfer, recording each call's outcome instead of bubbling its revert
 * @dev The probe fires once per arm cycle (the fired latch stops recursion when a reentrant call itself moves
 *      tokens), so a test arms its calls, runs the outer flow, then asserts the recorded outcomes
 */
contract MockReentrancyProbe {
    /**
     * @notice One armed reentrant call
     * @custom:field target - The contract the probe calls mid-transfer
     * @custom:field data - The full calldata of the reentrant call
     */
    struct ProbeCall {
        address target;
        bytes data;
    }

    /**
     * @notice The recorded outcome of one fired reentrant call
     * @custom:field succeeded - Whether the reentrant call returned without reverting
     * @custom:field returnOrRevertData - The call's return data on success or its revert data on failure
     */
    struct ProbeOutcome {
        bool succeeded;
        bytes returnOrRevertData;
    }

    /// @dev The reentrant calls to fire, in order, on the next observed transfer
    ProbeCall[] private _armedCalls;

    /// @dev The recorded outcomes, index-aligned with the armed calls of the fired cycle
    ProbeOutcome[] private _outcomes;

    /// @notice Whether the probe has fired its armed calls this cycle
    bool public fired;

    /// @notice Arms one reentrant call to fire on the next observed transfer, appended in order
    /// @param _target The contract to call mid-transfer
    /// @param _data The full calldata of the reentrant call
    function armCall(address _target, bytes calldata _data) external {
        _armedCalls.push(ProbeCall({ target: _target, data: _data }));
    }

    /// @notice Clears the armed calls, the recorded outcomes, and the fired latch for a fresh cycle
    function reset() external {
        delete _armedCalls;
        delete _outcomes;
        fired = false;
    }

    /// @notice The number of recorded outcomes from the fired cycle
    function outcomeCount() external view returns (uint256) {
        return _outcomes.length;
    }

    /// @notice Returns the recorded outcome of the fired reentrant call at the specified index
    /// @param _index The armed-call index to read the outcome for
    function outcomeAt(uint256 _index) external view returns (ProbeOutcome memory) {
        return _outcomes[_index];
    }

    /**
     * @notice The MockERC20C transfer hook entrypoint: fires every armed call once and records each outcome
     * @dev Outcomes are recorded, never bubbled, so the outer flow proceeds and the test asserts what the
     *      reentrancy guard did. The fired latch stops recursion when a reentrant call itself transfers tokens
     */
    function onTokenTransfer(address, address, uint256) external {
        if (fired) return;
        fired = true;
        uint256 n = _armedCalls.length;
        for (uint256 i; i < n; ++i) {
            (bool succeeded, bytes memory returnOrRevertData) = _armedCalls[i].target.call(_armedCalls[i].data);
            _outcomes.push(ProbeOutcome({ succeeded: succeeded, returnOrRevertData: returnOrRevertData }));
        }
    }
}
