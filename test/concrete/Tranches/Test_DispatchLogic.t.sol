// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toTrancheUnits } from "../../../src/libraries/Units.sol";
import { DispatchLogic } from "../../../src/libraries/logic/DispatchLogic.sol";
import { Assertions } from "../../utils/Assertions.sol";

/**
 * @title DispatchTarget
 * @notice Dispatch target with one function per specified outcome: illegal normal returns, genuine failures of every
 *         revert-data shape, result-carrying reverts over arbitrary payloads, and dual-mode operations of both return
 *         shapes plus a bytes-returning trampoline mirroring the venue's unlock geometry
 * @dev Every mutating path writes storage first so the suite can pin persistence on execution and the unwind on simulation
 */
contract DispatchTarget {
    /// @notice A genuine operation failure with no arguments
    error OPERATION_FAILED();

    /// @notice A genuine operation failure carrying arguments
    error OPERATION_FAILED_WITH_ARGS(uint256 code, address account);

    /// @notice A forged result error whose shape matches SIMULATION_RESULT but whose selector does not
    error FORGED_RESULT(bytes result);

    /// @notice Storage the dispatched frame mutates so the suite can assert persistence or the unwind
    uint256 public writes;

    /// @notice Mutates state and returns a value instead of unwinding, the outcome a simulation must reject
    function returnNormally() external returns (uint256) {
        writes = 1;
        return 42;
    }

    /// @notice Mutates state and returns nothing, the returndata-free flavor of the illegal outcome
    function returnNothing() external {
        writes = 1;
    }

    /// @notice Reverts with the argument-free operation failure
    function revertPlain() external pure {
        revert OPERATION_FAILED();
    }

    /// @notice Reverts with the argument-carrying operation failure
    function revertWithArgs(uint256 _code, address _account) external pure {
        revert OPERATION_FAILED_WITH_ARGS(_code, _account);
    }

    /// @notice Reverts with a string reason, the Error(string) builtin shape
    function revertWithReason(string memory _reason) external pure {
        revert(_reason);
    }

    /// @notice Reverts with a Panic via arithmetic overflow, the Panic(uint256) builtin shape
    function revertWithPanic(uint256 _value) external pure returns (uint256) {
        return _value + 1;
    }

    /// @notice Reverts with no data at all
    function revertEmpty() external pure {
        assembly ("memory-safe") {
            revert(0, 0)
        }
    }

    /// @notice Mutates state and unwinds with the given result payload, the well-formed simulation outcome
    function revertWithResult(bytes memory _payload) external {
        writes = 1;
        revert DispatchLogic.SIMULATION_RESULT(_payload);
    }

    /// @notice Reverts with a result-shaped payload under a forged selector, which must bubble instead of decode
    function revertWithForgedResult(bytes memory _payload) external pure {
        revert FORGED_RESULT(_payload);
    }

    /// @notice A dual-mode operation returning a value tuple, the shape _dispatchAndUnwrap serves
    function tupleOperation(bool _isPreview, uint256 _a, uint256 _b) external returns (uint256 sum, uint256 product) {
        writes = 1;
        (sum, product) = (_a + _b, _a * _b);
        if (_isPreview) revert DispatchLogic.SIMULATION_RESULT(abi.encode(sum, product));
    }

    /// @notice A dual-mode operation returning bytes, the shape _dispatch serves
    function bytesOperation(bool _isPreview, bytes memory _payload) external returns (bytes memory result) {
        writes = 1;
        if (_isPreview) revert DispatchLogic.SIMULATION_RESULT(_payload);
        return _payload;
    }

    /// @notice A bytes-returning trampoline mirroring the venue's unlock: it returns the inner call's raw returndata
    ///         as its bytes return, while an inner result-carrying revert pierces it untouched
    function trampoline(bytes memory _callData) external returns (bytes memory result) {
        bool success;
        (success, result) = address(this).call(_callData);
        // Revert with any genuine inner failure, mimicking the inner operation exactly
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }
}

/// @title DispatchLogicHarness
/// @notice Thin external wrapper around DispatchLogic so its reverts surface to the test frame with full revert data
contract DispatchLogicHarness {
    using DispatchLogic for address;

    /// @notice Runs _simulate with the unwrap depth, the delivery _dispatchAndUnwrap consumers receive
    function simulateUnwrapped(address _target, bytes memory _callData) external returns (bytes memory result) {
        result = _target._simulate(_callData, true);
    }

    /// @notice Runs _simulate keeping the error's offset and length prefix, the delivery _dispatch consumers receive
    function simulateWrapped(address _target, bytes memory _callData) external returns (bytes memory result) {
        result = _target._simulate(_callData, false);
    }

    /// @notice Runs _dispatch, the variant serving bytes-returning operations
    function dispatch(address _target, bool _isPreview, bytes memory _callData) external returns (bytes memory result) {
        result = _target._dispatch(_isPreview, _callData);
    }

    /// @notice Runs _dispatchAndUnwrap, the variant serving tuple-returning operations
    function dispatchAndUnwrap(address _target, bool _isPreview, bytes memory _callData) external returns (bytes memory result) {
        result = _target._dispatchAndUnwrap(_isPreview, _callData);
    }
}

/**
 * @title Test_DispatchLogic
 * @notice Direct unit coverage of DispatchLogic in isolation, pinned to the library's specified contract: a simulation
 *         that returns instead of unwinding is rejected, every non-SIMULATION_RESULT revert bubbles byte-exact through
 *         either depth and either variant, a SIMULATION_RESULT revert delivers its payload bare on the unwrap depth and
 *         inside the error's offset and length prefix on the wrapped depth, both dispatch variants deliver the operation's returndata
 *         byte for byte in either mode (a tuple return bare, a bytes return prefixed, a trampolined operation through
 *         its wrapper's offset and length prefix), an execution persists state, and a simulation leaves none
 * @dev Harness calls are external so the library's reverts surface to the test frame, where try/catch captures the FULL
 *      revert data for byte-exact assertions instead of selector-only matching
 */
contract Test_DispatchLogic is Assertions {
    DispatchLogicHarness internal harness;
    DispatchTarget internal target;

    /// @dev Payloads spanning every shape class: empty, one word, several words, a static struct, and unpadded bytes
    bytes[] internal payloads;

    function setUp() public {
        harness = new DispatchLogicHarness();
        target = new DispatchTarget();

        payloads.push("");
        payloads.push(abi.encode(uint256(42)));
        payloads.push(abi.encode(uint256(1), uint256(2), uint256(3)));
        payloads.push(abi.encode(AssetClaims(toTrancheUnits(1e18), toTrancheUnits(2e18), 3e18, toNAVUnits(uint256(4e18)))));
        payloads.push(hex"deadbeef");
    }

    // =============================
    // Selector constant (spec: the assembly-readable literal must equal the error's real selector)
    // =============================

    /// @notice The pinned literal selector constant equals SIMULATION_RESULT.selector, so the literal cannot drift
    function test_SimulationResultSelectorConstant_MatchesError() public pure {
        assertEq(
            DispatchLogic.SIMULATION_RESULT_SELECTOR, DispatchLogic.SIMULATION_RESULT.selector, "the pinned selector literal must equal the error's selector"
        );
    }

    // =============================
    // Illegal normal returns (spec: a simulation that does not unwind is rejected on both depths)
    // =============================

    /// @notice A target returning a value makes _simulate revert SIMULATION_CANNOT_MUTATE_STATE on both depths
    function test_RevertIf_SimulatedOperationReturnsValue() public {
        bytes memory callData = abi.encodeCall(DispatchTarget.returnNormally, ());
        try harness.simulateUnwrapped(address(target), callData) {
            fail("the unwrap depth must reject a returning simulation");
        } catch (bytes memory err) {
            assertEq(
                err, abi.encodeWithSelector(DispatchLogic.SIMULATION_CANNOT_MUTATE_STATE.selector), "the unwrap depth must reject with the exact guard error"
            );
        }
        try harness.simulateWrapped(address(target), callData) {
            fail("the wrapped depth must reject a returning simulation");
        } catch (bytes memory err) {
            assertEq(
                err, abi.encodeWithSelector(DispatchLogic.SIMULATION_CANNOT_MUTATE_STATE.selector), "the wrapped depth must reject with the exact guard error"
            );
        }
    }

    /// @notice A target returning nothing makes _simulate revert SIMULATION_CANNOT_MUTATE_STATE on both depths
    function test_RevertIf_SimulatedOperationReturnsNothing() public {
        bytes memory callData = abi.encodeCall(DispatchTarget.returnNothing, ());
        try harness.simulateUnwrapped(address(target), callData) {
            fail("the unwrap depth must reject a returndata-free returning simulation");
        } catch (bytes memory err) {
            assertEq(
                err, abi.encodeWithSelector(DispatchLogic.SIMULATION_CANNOT_MUTATE_STATE.selector), "the unwrap depth must reject with the exact guard error"
            );
        }
        try harness.simulateWrapped(address(target), callData) {
            fail("the wrapped depth must reject a returndata-free returning simulation");
        } catch (bytes memory err) {
            assertEq(
                err, abi.encodeWithSelector(DispatchLogic.SIMULATION_CANNOT_MUTATE_STATE.selector), "the wrapped depth must reject with the exact guard error"
            );
        }
    }

    /// @notice A codeless target succeeds emptily under call semantics, which a simulation must also reject
    function test_RevertIf_SimulatedTargetHasNoCode() public {
        try harness.simulateUnwrapped(address(0xBEEF), abi.encodeCall(DispatchTarget.returnNormally, ())) {
            fail("a codeless target must be rejected as a returning simulation");
        } catch (bytes memory err) {
            assertEq(
                err, abi.encodeWithSelector(DispatchLogic.SIMULATION_CANNOT_MUTATE_STATE.selector), "a codeless target must reject with the exact guard error"
            );
        }
    }

    // =============================
    // Genuine failure bubbling (spec: every non-SIMULATION_RESULT revert bubbles byte-exact)
    // =============================

    /// @notice An argument-free custom error bubbles byte-exact through both depths and both variants
    function test_RevertIf_OperationFails_PlainErrorBubblesByteExact() public {
        _assertBubblesByteExact(abi.encodeCall(DispatchTarget.revertPlain, ()), abi.encodeWithSelector(DispatchTarget.OPERATION_FAILED.selector));
    }

    /// @notice An argument-carrying custom error bubbles byte-exact including every argument word
    function test_RevertIf_OperationFails_ArgumentErrorBubblesByteExact() public {
        _assertBubblesByteExact(
            abi.encodeCall(DispatchTarget.revertWithArgs, (1337, address(0xCAFE))),
            abi.encodeWithSelector(DispatchTarget.OPERATION_FAILED_WITH_ARGS.selector, 1337, address(0xCAFE))
        );
    }

    /// @notice An Error(string) reason bubbles byte-exact through its dynamic encoding
    function test_RevertIf_OperationFails_StringReasonBubblesByteExact() public {
        _assertBubblesByteExact(
            abi.encodeCall(DispatchTarget.revertWithReason, ("the operation failed for a reason")),
            abi.encodeWithSignature("Error(string)", "the operation failed for a reason")
        );
    }

    /// @notice A Panic(uint256) bubbles byte-exact, pinned via the arithmetic overflow code
    function test_RevertIf_OperationFails_PanicBubblesByteExact() public {
        _assertBubblesByteExact(abi.encodeCall(DispatchTarget.revertWithPanic, (type(uint256).max)), abi.encodeWithSignature("Panic(uint256)", 0x11));
    }

    /// @notice A zero-data revert bubbles as a zero-data revert
    function test_RevertIf_OperationFails_EmptyRevertBubblesEmpty() public {
        _assertBubblesByteExact(abi.encodeCall(DispatchTarget.revertEmpty, ()), "");
    }

    /// @notice A result-shaped payload under a forged selector bubbles byte-exact instead of decoding as a result
    function test_RevertIf_ForgedResultSelector_BubblesByteExact() public {
        bytes memory payload = abi.encode(uint256(42));
        _assertBubblesByteExact(
            abi.encodeCall(DispatchTarget.revertWithForgedResult, (payload)), abi.encodeWithSelector(DispatchTarget.FORGED_RESULT.selector, payload)
        );
    }

    // =============================
    // Result delivery (spec: the unwrap depth yields the bare payload, the wrapped depth yields the payload behind its offset and length prefix)
    // =============================

    /// @notice The unwrap depth delivers exactly the carried payload for every payload shape
    function test_Simulate_UnwrapDepth_DeliversBarePayload() public {
        for (uint256 i = 0; i < payloads.length; i++) {
            bytes memory result = harness.simulateUnwrapped(address(target), abi.encodeCall(DispatchTarget.revertWithResult, (payloads[i])));
            assertEq(result, payloads[i], "the unwrap depth must deliver the carried payload byte for byte");
        }
    }

    /// @notice The wrapped depth delivers exactly the payload behind its offset and length prefix for every payload shape
    function test_Simulate_WrappedDepth_DeliversEnvelopedPayload() public {
        for (uint256 i = 0; i < payloads.length; i++) {
            bytes memory result = harness.simulateWrapped(address(target), abi.encodeCall(DispatchTarget.revertWithResult, (payloads[i])));
            assertEq(result, abi.encode(payloads[i]), "the wrapped depth must deliver the payload behind its offset and length prefix byte for byte");
        }
    }

    /// @notice Decoding the wrapped delivery as bytes recovers the unwrapped delivery, the two depths are one offset and length prefix apart
    function test_Simulate_WrappedDecodesToUnwrapped() public {
        for (uint256 i = 0; i < payloads.length; i++) {
            bytes memory callData = abi.encodeCall(DispatchTarget.revertWithResult, (payloads[i]));
            bytes memory wrapped = harness.simulateWrapped(address(target), callData);
            bytes memory unwrapped = harness.simulateUnwrapped(address(target), callData);
            assertEq(abi.decode(wrapped, (bytes)), unwrapped, "the wrapped delivery must decode to the unwrapped delivery");
        }
    }

    /// @notice A simulation leaves no state behind on either depth, the write inside the frame unwinds with the revert
    function test_Simulate_UnwindsEveryWrite() public {
        harness.simulateUnwrapped(address(target), abi.encodeCall(DispatchTarget.revertWithResult, (payloads[1])));
        assertEq(target.writes(), 0, "the unwrap depth must unwind the simulated frame's write");
        harness.simulateWrapped(address(target), abi.encodeCall(DispatchTarget.revertWithResult, (payloads[1])));
        assertEq(target.writes(), 0, "the wrapped depth must unwind the simulated frame's write");
    }

    // =============================
    // Dispatch invariants (spec: either mode delivers the operation's returndata byte for byte)
    // =============================

    /// @notice A tuple-returning operation dispatches to identical bytes in both modes, the bare tuple encoding
    function test_DispatchAndUnwrap_TupleOperation_ModesAreByteIdentical() public {
        bytes memory executed = harness.dispatchAndUnwrap(address(target), false, abi.encodeCall(DispatchTarget.tupleOperation, (false, 3, 7)));
        bytes memory simulated = harness.dispatchAndUnwrap(address(target), true, abi.encodeCall(DispatchTarget.tupleOperation, (true, 3, 7)));
        assertEq(executed, simulated, "both modes must deliver the tuple operation's returndata byte for byte");
        assertEq(executed, abi.encode(uint256(10), uint256(21)), "the delivery must be the bare tuple encoding");

        (uint256 sum, uint256 product) = abi.decode(simulated, (uint256, uint256));
        assertEq(sum, 10, "the simulated sum must decode exactly");
        assertEq(product, 21, "the simulated product must decode exactly");
    }

    /// @notice A bytes-returning operation dispatches to identical bytes in both modes, the prefixed bytes encoding
    function test_Dispatch_BytesOperation_ModesAreByteIdentical() public {
        for (uint256 i = 0; i < payloads.length; i++) {
            bytes memory executed = harness.dispatch(address(target), false, abi.encodeCall(DispatchTarget.bytesOperation, (false, payloads[i])));
            bytes memory simulated = harness.dispatch(address(target), true, abi.encodeCall(DispatchTarget.bytesOperation, (true, payloads[i])));
            assertEq(executed, simulated, "both modes must deliver the bytes operation's returndata byte for byte");
            assertEq(abi.decode(executed, (bytes)), payloads[i], "the delivery must decode to the operation's bytes return");
        }
    }

    /**
     * @notice A tuple operation dispatched through a bytes-returning trampoline is byte-identical in both modes, the
     *         venue's unlock geometry: the execution's return is wrapped by the trampoline while the simulation's
     *         revert pierces it, and the error's offset and length prefix stands in for the trampoline's
     */
    function test_Dispatch_TrampolinedOperation_ModesAreByteIdentical() public {
        bytes memory executed =
            harness.dispatch(address(target), false, abi.encodeCall(DispatchTarget.trampoline, (abi.encodeCall(DispatchTarget.tupleOperation, (false, 3, 7)))));
        bytes memory simulated =
            harness.dispatch(address(target), true, abi.encodeCall(DispatchTarget.trampoline, (abi.encodeCall(DispatchTarget.tupleOperation, (true, 3, 7)))));
        assertEq(executed, simulated, "both modes must deliver the trampolined operation's returndata byte for byte");

        (uint256 sum, uint256 product) = abi.decode(abi.decode(simulated, (bytes)), (uint256, uint256));
        assertEq(sum, 10, "the trampolined sum must decode exactly through the prefix");
        assertEq(product, 21, "the trampolined product must decode exactly through the prefix");
    }

    /// @notice A genuine failure inside a trampolined operation bubbles byte-exact through both modes
    function test_RevertIf_TrampolinedOperationFails_BubblesByteExact() public {
        bytes memory callData = abi.encodeCall(DispatchTarget.trampoline, (abi.encodeCall(DispatchTarget.revertWithArgs, (1337, address(0xCAFE)))));
        bytes memory expected = abi.encodeWithSelector(DispatchTarget.OPERATION_FAILED_WITH_ARGS.selector, 1337, address(0xCAFE));
        try harness.dispatch(address(target), false, callData) {
            fail("an executed trampolined failure must bubble");
        } catch (bytes memory err) {
            assertEq(err, expected, "the executed trampolined failure must bubble byte-exact");
        }
        try harness.dispatch(address(target), true, callData) {
            fail("a simulated trampolined failure must bubble");
        } catch (bytes memory err) {
            assertEq(err, expected, "the simulated trampolined failure must bubble byte-exact");
        }
    }

    /// @notice An execution persists the operation's write while a simulation leaves none, on both variants
    function test_Dispatch_ExecutionPersistsAndSimulationUnwinds() public {
        harness.dispatchAndUnwrap(address(target), true, abi.encodeCall(DispatchTarget.tupleOperation, (true, 3, 7)));
        assertEq(target.writes(), 0, "a simulated tuple operation must leave no state");
        harness.dispatch(address(target), true, abi.encodeCall(DispatchTarget.bytesOperation, (true, payloads[1])));
        assertEq(target.writes(), 0, "a simulated bytes operation must leave no state");

        harness.dispatchAndUnwrap(address(target), false, abi.encodeCall(DispatchTarget.tupleOperation, (false, 3, 7)));
        assertEq(target.writes(), 1, "an executed operation must persist its write");
    }

    // =============================
    // Internal assertion helpers
    // =============================

    /// @dev Asserts the call's revert data bubbles byte-exact through both simulation depths and both dispatch variants in both modes
    function _assertBubblesByteExact(bytes memory _callData, bytes memory _expected) internal {
        try harness.simulateUnwrapped(address(target), _callData) {
            fail("the unwrap depth must bubble the failure");
        } catch (bytes memory err) {
            assertEq(err, _expected, "the unwrap depth must bubble byte-exact");
        }
        try harness.simulateWrapped(address(target), _callData) {
            fail("the wrapped depth must bubble the failure");
        } catch (bytes memory err) {
            assertEq(err, _expected, "the wrapped depth must bubble byte-exact");
        }
        try harness.dispatch(address(target), true, _callData) {
            fail("a simulated dispatch must bubble the failure");
        } catch (bytes memory err) {
            assertEq(err, _expected, "a simulated dispatch must bubble byte-exact");
        }
        try harness.dispatchAndUnwrap(address(target), false, _callData) {
            fail("an executed dispatch must bubble the failure");
        } catch (bytes memory err) {
            assertEq(err, _expected, "an executed dispatch must bubble byte-exact");
        }
    }
}
