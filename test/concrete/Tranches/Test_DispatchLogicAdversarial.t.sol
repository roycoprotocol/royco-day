// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { AssetClaims, DispatchMode } from "../../../src/libraries/Types.sol";
import { TRANCHE_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { DispatchLogic } from "../../../src/libraries/logic/DispatchLogic.sol";

/// @title AdversarialTarget
/// @notice A dispatch target that FORGES the SIMULATION_RESULT selector with hand-crafted, malformed bodies, plus targets
///         that mirror the exact return shapes production dispatches (single value, AssetClaims struct, struct+value,
///         value+UDVT, and the venue's double-encoded bytes). The forgery functions build revert data in assembly so a
///         lying offset word, a lying inner length word, or a sub-selector-length body can be delivered to _simulate.
contract AdversarialTarget {
    /// @dev SIMULATION_RESULT(bytes) selector, left-aligned in a word for assembly mstore
    bytes32 internal constant SIM_SELECTOR_WORD = 0x9d59ef4900000000000000000000000000000000000000000000000000000000;

    uint256 public writes;

    error NEAR_COLLISION(); // selector engineered below to share the top 3 bytes of SIMULATION_RESULT

    // ---- Honest dual-mode ops mirroring the real _dispatchAndUnwrap consumers ----

    /// @notice inkindDeposit shape: returns a single uint256
    function singleValueOp(DispatchMode _mode, uint256 _v) external returns (uint256) {
        writes = 1;
        if (_mode == DispatchMode.SIMULATE) revert DispatchLogic.SIMULATION_RESULT(abi.encode(_v));
        return _v;
    }

    /// @notice inkindRedeem shape: returns an AssetClaims struct (four static words)
    function assetClaimsOp(DispatchMode _mode, AssetClaims memory _c) external returns (AssetClaims memory) {
        writes = 1;
        if (_mode == DispatchMode.SIMULATE) revert DispatchLogic.SIMULATION_RESULT(abi.encode(_c));
        return _c;
    }

    /// @notice lptRedeemMultiAsset shape: returns (AssetClaims, uint256)
    function claimsAndValueOp(DispatchMode _mode, AssetClaims memory _c, uint256 _q) external returns (AssetClaims memory, uint256) {
        writes = 1;
        if (_mode == DispatchMode.SIMULATE) revert DispatchLogic.SIMULATION_RESULT(abi.encode(_c, _q));
        return (_c, _q);
    }

    /// @notice lptDepositMultiAsset shape: returns (uint256, TRANCHE_UNIT)
    function uintAndUdvtOp(DispatchMode _mode, uint256 _shares, TRANCHE_UNIT _assets) external returns (uint256, TRANCHE_UNIT) {
        writes = 1;
        if (_mode == DispatchMode.SIMULATE) revert DispatchLogic.SIMULATION_RESULT(abi.encode(_shares, _assets));
        return (_shares, _assets);
    }

    /// @notice Venue unlock shape: a bytes-returning op whose payload is itself abi.encode(bytes), for the double-decode path
    function bytesDoubleEncodeOp(DispatchMode _mode, bytes memory _inner) external returns (bytes memory) {
        writes = 1;
        bytes memory wrapped = abi.encode(_inner);
        if (_mode == DispatchMode.SIMULATE) revert DispatchLogic.SIMULATION_RESULT(wrapped);
        return wrapped;
    }

    /// @notice A large SIMULATION_RESULT payload to exercise the returndatacopy path (return-bomb)
    function resultBombOp(DispatchMode _mode, uint256 _bytesLen) external returns (bytes memory) {
        writes = 1;
        bytes memory big = new bytes(_bytesLen);
        for (uint256 i = 0; i < _bytesLen; i += 97) {
            big[i] = bytes1(uint8(i));
        }
        if (_mode == DispatchMode.SIMULATE) revert DispatchLogic.SIMULATION_RESULT(big);
        return big;
    }

    // ---- Forgery: hand-crafted malformed SIMULATION_RESULT bodies ----

    /// @notice Reverts with a genuine SIMULATION_RESULT selector, a canonical 0x20 offset, but an inner length word LARGER
    ///         than the real payload. The unwrap depth reads this length verbatim from revertData+0x44.
    function revertForgedInnerLength(uint256 _forgedLen, bytes memory _payload) external pure {
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, SIM_SELECTOR_WORD)
            mstore(add(p, 0x04), 0x20) // canonical offset
            mstore(add(p, 0x24), _forgedLen) // forged inner length
            let plen := mload(_payload)
            let src := add(_payload, 0x20)
            let dst := add(p, 0x44)
            for { let i := 0 } lt(i, plen) { i := add(i, 0x20) } { mstore(add(dst, i), mload(add(src, i))) }
            revert(p, add(0x44, plen))
        }
    }

    /// @notice Reverts with EXACTLY the 4-byte SIMULATION_RESULT selector and no body. The unwrap depth's +0x44 seek points
    ///         past the buffer.
    function revertBareSelector() external pure {
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, SIM_SELECTOR_WORD)
            revert(p, 0x04)
        }
    }

    /// @notice Reverts with a genuine selector but a NON-canonical offset word (0x40), which the unwrap assembly never reads.
    function revertLyingOffset(bytes32 _wordAtInner) external pure {
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, SIM_SELECTOR_WORD)
            mstore(add(p, 0x04), 0x40) // lying offset (canonical is 0x20)
            mstore(add(p, 0x24), _wordAtInner) // whatever sits where the unwrap path reads the length
            mstore(add(p, 0x44), 0x00)
            revert(p, 0x64)
        }
    }

    /// @notice Reverts with arbitrary raw bytes, for sub-selector-length reverts and engineered near-collision selectors.
    function revertRaw(bytes memory _raw) external pure {
        assembly ("memory-safe") {
            revert(add(_raw, 0x20), mload(_raw))
        }
    }

    // ---- Honest genuine failure + non-reverting sim, for control comparisons ----

    function returnNormally(DispatchMode) external returns (uint256) {
        writes = 1;
        return 42;
    }

    function nestedDispatch(DispatchMode _mode, address _inner, bytes memory _innerCall) external returns (bytes memory) {
        writes = 1;
        // A target that itself dispatches: an inner SIMULATION_RESULT must pierce this frame untouched under SIMULATE
        bytes memory out = DispatchLogic._dispatch(_inner, _mode, _innerCall);
        if (_mode == DispatchMode.SIMULATE) revert DispatchLogic.SIMULATION_RESULT(out);
        return out;
    }
}

/// @title DispatchHarness
/// @notice External wrapper so DispatchLogic's internal/private reverts and returns surface to the test frame intact.
contract DispatchHarness {
    using DispatchLogic for address;

    function dispatch(address _t, DispatchMode _m, bytes memory _c) external returns (bytes memory) {
        return _t._dispatch(_m, _c);
    }

    function dispatchAndUnwrap(address _t, DispatchMode _m, bytes memory _c) external returns (bytes memory) {
        return _t._dispatchAndUnwrap(_m, _c);
    }

    function tryExecute(address _t, bytes memory _c) external returns (bool ok, bytes memory ret) {
        return _t._tryExecute(_c);
    }

    /// @notice Returns the raw length word the unwrap delivery would expose, WITHOUT triggering an ABI-encode of the
    ///         (possibly enormous) bytes body, so a forged length can be observed without OOG in the observing frame.
    function unwrapDeliveredLength(address _t, bytes memory _c) external returns (uint256 len) {
        bytes memory r = _t._dispatchAndUnwrap(DispatchMode.SIMULATE, _c);
        assembly {
            len := mload(r)
        }
    }
}

/// @title Test_DispatchLogicAdversarial
/// @notice Adversarial and use-case-faithful coverage of DispatchLogic, targeting the assembly in _simulate/_execute:
///         forged SIMULATION_RESULT bodies (lying inner length, bare selector, lying offset), sub-selector reverts,
///         near-collision selectors, EXECUTE-mode revert bubbling, _tryExecute, return-bombs, and the exact return
///         shapes production dispatches (uint, AssetClaims struct, struct+value, value+UDVT, double-encoded bytes).
contract Test_DispatchLogicAdversarial is Test {
    AdversarialTarget internal target;
    DispatchHarness internal harness;

    bytes4 internal constant SIM_SELECTOR = 0x9d59ef49;

    function setUp() public {
        target = new AdversarialTarget();
        harness = new DispatchHarness();
    }

    // =============================
    // Use-case fidelity: SIMULATE and EXECUTE deliver byte-identical results for every real dispatch shape
    // =============================

    function test_UseCase_SingleValue_ModesByteIdentical() public {
        bytes memory e =
            harness.dispatchAndUnwrap(address(target), DispatchMode.EXECUTE, abi.encodeCall(AdversarialTarget.singleValueOp, (DispatchMode.EXECUTE, 12_345)));
        bytes memory s =
            harness.dispatchAndUnwrap(address(target), DispatchMode.SIMULATE, abi.encodeCall(AdversarialTarget.singleValueOp, (DispatchMode.SIMULATE, 12_345)));
        assertEq(s, e, "single-value unwrap must be byte-identical across modes");
        assertEq(abi.decode(s, (uint256)), 12_345, "decoded single value must round-trip");
    }

    function test_UseCase_AssetClaimsStruct_ModesByteIdentical() public {
        AssetClaims memory c =
            AssetClaims({ collateralAssets: toTrancheUnits(11e18), lptAssets: toTrancheUnits(7e18), stShares: 3e18, nav: toNAVUnits(uint256(21e18)) });
        bytes memory e =
            harness.dispatchAndUnwrap(address(target), DispatchMode.EXECUTE, abi.encodeCall(AdversarialTarget.assetClaimsOp, (DispatchMode.EXECUTE, c)));
        bytes memory s =
            harness.dispatchAndUnwrap(address(target), DispatchMode.SIMULATE, abi.encodeCall(AdversarialTarget.assetClaimsOp, (DispatchMode.SIMULATE, c)));
        assertEq(s, e, "AssetClaims struct unwrap must be byte-identical across modes");
        AssetClaims memory d = abi.decode(s, (AssetClaims));
        assertEq(toUint256(d.collateralAssets), 11e18, "collateral round-trips");
        assertEq(toUint256(d.nav), 21e18, "nav round-trips");
    }

    function test_UseCase_ClaimsAndValue_ModesByteIdentical() public {
        AssetClaims memory c =
            AssetClaims({ collateralAssets: toTrancheUnits(5e18), lptAssets: toTrancheUnits(0), stShares: 1e18, nav: toNAVUnits(uint256(6e18)) });
        bytes memory e = harness.dispatchAndUnwrap(
            address(target), DispatchMode.EXECUTE, abi.encodeCall(AdversarialTarget.claimsAndValueOp, (DispatchMode.EXECUTE, c, 999))
        );
        bytes memory s = harness.dispatchAndUnwrap(
            address(target), DispatchMode.SIMULATE, abi.encodeCall(AdversarialTarget.claimsAndValueOp, (DispatchMode.SIMULATE, c, 999))
        );
        assertEq(s, e, "(AssetClaims,uint256) unwrap must be byte-identical across modes");
        (, uint256 q) = abi.decode(s, (AssetClaims, uint256));
        assertEq(q, 999, "trailing value round-trips");
    }

    function test_UseCase_UintAndUdvt_ModesByteIdentical() public {
        bytes memory e = harness.dispatchAndUnwrap(
            address(target), DispatchMode.EXECUTE, abi.encodeCall(AdversarialTarget.uintAndUdvtOp, (DispatchMode.EXECUTE, 4, toTrancheUnits(88)))
        );
        bytes memory s = harness.dispatchAndUnwrap(
            address(target), DispatchMode.SIMULATE, abi.encodeCall(AdversarialTarget.uintAndUdvtOp, (DispatchMode.SIMULATE, 4, toTrancheUnits(88)))
        );
        assertEq(s, e, "(uint256,TRANCHE_UNIT) unwrap must be byte-identical across modes");
    }

    function test_UseCase_VenueDoubleDecodedBytes_ModesByteIdentical() public {
        bytes memory inner = hex"deadbeefcafe";
        bytes memory e =
            harness.dispatch(address(target), DispatchMode.EXECUTE, abi.encodeCall(AdversarialTarget.bytesDoubleEncodeOp, (DispatchMode.EXECUTE, inner)));
        bytes memory s =
            harness.dispatch(address(target), DispatchMode.SIMULATE, abi.encodeCall(AdversarialTarget.bytesDoubleEncodeOp, (DispatchMode.SIMULATE, inner)));
        assertEq(s, e, "double-encoded bytes wrap must be byte-identical across modes");
        // Mirror the venue's abi.decode(abi.decode(dispatch, (bytes)), ...) double-decode: the op returns abi.encode(inner),
        // so one decode yields that wrapper and the second yields the inner payload
        assertEq(abi.decode(abi.decode(s, (bytes)), (bytes)), inner, "inner bytes must survive the venue-style double-decode");
    }

    // =============================
    // _tryExecute (best-effort primitive) — success and failure
    // =============================

    function test_TryExecute_SuccessReturnsData() public {
        (bool ok, bytes memory ret) = harness.tryExecute(address(target), abi.encodeCall(AdversarialTarget.returnNormally, (DispatchMode.EXECUTE)));
        assertTrue(ok, "a successful call must report success");
        assertEq(abi.decode(ret, (uint256)), 42, "return data must be delivered");
    }

    function test_TryExecute_FailureReportsWithoutBubbling() public {
        (bool ok, bytes memory ret) = harness.tryExecute(address(target), abi.encodeCall(AdversarialTarget.revertBareSelector, ()));
        assertFalse(ok, "a reverting call must report failure without bubbling");
        assertEq(ret.length, 4, "revert data (the bare selector) must be returned verbatim");
    }

    // =============================
    // Mode isolation: EXECUTE must bubble a SIMULATION_RESULT as a genuine revert, never swallow it
    // =============================

    function test_RevertIf_ExecuteModeOnSimulationResult_Bubbles() public {
        bytes memory forged = abi.encode(uint256(7));
        // A target reverting SIMULATION_RESULT under EXECUTE is a genuine failure and must bubble byte-exact
        try harness.dispatch(address(target), DispatchMode.EXECUTE, abi.encodeCall(AdversarialTarget.singleValueOp, (DispatchMode.SIMULATE, 7))) {
            fail("EXECUTE must not swallow a SIMULATION_RESULT revert");
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(SIM_SELECTOR, forged), "the SIMULATION_RESULT must bubble verbatim under EXECUTE");
        }
    }

    // =============================
    // Forged-selector attacks on the unwrap assembly (revertData+0x44 read is attacker-controlled)
    // =============================

    /// @notice A forged SIMULATION_RESULT whose inner length word is enormous: the wrap depth stays bounded to the real
    ///         returndata, the unwrap depth exposes the attacker's length verbatim. Documents the asymmetry.
    function test_ForgedInnerLength_WrapBoundedUnwrapAttackerControlled() public {
        uint256 forgedLen = type(uint256).max;
        bytes memory smallPayload = hex"aabbccdd";
        bytes memory call = abi.encodeCall(AdversarialTarget.revertForgedInnerLength, (forgedLen, smallPayload));

        // Wrap depth: length is derived from the real returndatasize, never from the forged word -> bounded and safe
        bytes memory wrapped = harness.dispatch(address(target), DispatchMode.SIMULATE, call);
        assertLt(wrapped.length, 1024, "wrap-depth length must stay bounded to real returndata, ignoring the forged word");

        // Unwrap depth: the delivered length is read verbatim from revertData+0x44 -> equals the attacker's forged value
        uint256 delivered = harness.unwrapDeliveredLength(address(target), call);
        assertEq(delivered, forgedLen, "unwrap depth exposes the attacker-controlled inner length verbatim (latent OOB primitive)");
    }

    /// @notice Returning the forged-length bytes to an ABI-encoding frame triggers an out-of-gas from the enormous
    ///         returndatacopy: proof the unwrap primitive is unsafe against an adversarial target.
    function test_RevertIf_ForgedInnerLength_UnwrapDeliveryOOG() public {
        bytes memory call = abi.encodeCall(AdversarialTarget.revertForgedInnerLength, (type(uint256).max, hex"aabbccdd"));
        (bool ok,) = address(harness).call(abi.encodeCall(DispatchHarness.dispatchAndUnwrap, (address(target), DispatchMode.SIMULATE, call)));
        assertFalse(ok, "delivering an attacker-forged huge bytes length must fail (OOG) rather than return corrupt data");
    }

    /// @notice A bare 4-byte SIMULATION_RESULT selector: wrap depth yields empty bytes (sub(4,4)=0), unwrap depth seeks
    ///         past the buffer at +0x44.
    function test_ForgedBareSelector_WrapEmptyUnwrapOOB() public {
        bytes memory call = abi.encodeCall(AdversarialTarget.revertBareSelector, ());
        bytes memory wrapped = harness.dispatch(address(target), DispatchMode.SIMULATE, call);
        assertEq(wrapped.length, 0, "a bare selector must wrap-decode to empty bytes");
        // The unwrap delivery reads a length from past the buffer; its exact value is heap-dependent, so only assert the
        // wrap path's safety here and let the OOG test above cover the unwrap danger class.
    }

    // =============================
    // Genuine (non-forged) revert bubbling: sub-selector and near-collision must never decode
    // =============================

    function test_SubSelectorReverts_BubbleByteExact() public {
        for (uint256 n = 1; n <= 3; n++) {
            bytes memory raw = new bytes(n);
            // even sharing the top byte, a sub-selector-length revert must not match the full 4-byte selector
            for (uint256 i = 0; i < n; i++) {
                raw[i] = 0x9d;
            }
            try harness.dispatch(address(target), DispatchMode.SIMULATE, abi.encodeCall(AdversarialTarget.revertRaw, (raw))) {
                fail("a sub-selector revert must bubble, never decode");
            } catch (bytes memory err) {
                assertEq(err, raw, "a sub-selector revert must bubble byte-exact");
            }
        }
    }

    function test_NearCollisionSelector_BubblesByteExact() public {
        // Top three bytes equal 9d 59 ef, last byte differs (0x48 not 0x49): must NOT be treated as SIMULATION_RESULT
        bytes memory raw = hex"9d59ef48";
        try harness.dispatch(address(target), DispatchMode.SIMULATE, abi.encodeCall(AdversarialTarget.revertRaw, (raw))) {
            fail("a 3-of-4-byte near-collision must not decode as SIMULATION_RESULT");
        } catch (bytes memory err) {
            assertEq(err, raw, "a near-collision selector must bubble byte-exact");
        }
    }

    // =============================
    // Return-bomb: a large SIMULATION_RESULT payload round-trips byte-exact across modes
    // =============================

    function test_ResultBomb_LargePayloadRoundTrips() public {
        uint256 len = 200_000;
        bytes memory e = harness.dispatch(address(target), DispatchMode.EXECUTE, abi.encodeCall(AdversarialTarget.resultBombOp, (DispatchMode.EXECUTE, len)));
        bytes memory s = harness.dispatch(address(target), DispatchMode.SIMULATE, abi.encodeCall(AdversarialTarget.resultBombOp, (DispatchMode.SIMULATE, len)));
        assertEq(keccak256(s), keccak256(e), "a large payload must be byte-identical across modes");
    }

    // =============================
    // Nested dispatch: an inner SIMULATION_RESULT pierces an intermediate dispatching frame
    // =============================

    function test_NestedDispatch_ModeInvariantThroughFrame() public {
        AdversarialTarget inner = new AdversarialTarget();
        // The inner op returns bytes so the outer nestedDispatch's _dispatch (wrap depth) delivers the same shape in both
        // modes; a SIMULATE run must unwind both frames and deliver byte-identical bytes to a matching EXECUTE run
        bytes memory sim = harness.dispatch(
            address(target),
            DispatchMode.SIMULATE,
            abi.encodeCall(
                AdversarialTarget.nestedDispatch,
                (DispatchMode.SIMULATE, address(inner), abi.encodeCall(AdversarialTarget.bytesDoubleEncodeOp, (DispatchMode.SIMULATE, hex"1234")))
            )
        );
        assertEq(inner.writes(), 0, "the inner simulation must leave no state in the nested frame");
        assertEq(target.writes(), 0, "the outer simulation must leave no state");
        bytes memory exec = harness.dispatch(
            address(target),
            DispatchMode.EXECUTE,
            abi.encodeCall(
                AdversarialTarget.nestedDispatch,
                (DispatchMode.EXECUTE, address(inner), abi.encodeCall(AdversarialTarget.bytesDoubleEncodeOp, (DispatchMode.EXECUTE, hex"1234")))
            )
        );
        assertEq(sim, exec, "a nested dispatch delivers byte-identical results across modes, an inner simulation result pierces the outer frame");
    }

    // =============================
    // Fuzz: bytes payloads of every length round-trip byte-exact through both wrap and unwrap deliveries
    // =============================

    function testFuzz_BytesPayloadRoundTrips(bytes memory _payload) public {
        vm.assume(_payload.length <= 4096);
        bytes memory e =
            harness.dispatch(address(target), DispatchMode.EXECUTE, abi.encodeCall(AdversarialTarget.bytesDoubleEncodeOp, (DispatchMode.EXECUTE, _payload)));
        bytes memory s =
            harness.dispatch(address(target), DispatchMode.SIMULATE, abi.encodeCall(AdversarialTarget.bytesDoubleEncodeOp, (DispatchMode.SIMULATE, _payload)));
        assertEq(s, e, "wrap delivery must be byte-identical across modes for any payload");
        assertEq(abi.decode(abi.decode(s, (bytes)), (bytes)), _payload, "any payload must survive the venue-style double-decode");
    }
}
