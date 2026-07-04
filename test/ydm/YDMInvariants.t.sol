// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { StdInvariant } from "../../lib/forge-std/src/StdInvariant.sol";
import { StdUtils } from "../../lib/forge-std/src/StdUtils.sol";
import { Vm } from "../../lib/forge-std/src/Vm.sol";

import { StaticCurveYDM } from "../../src/ydm/StaticCurveYDM.sol";
import { AdaptiveCurveYDM_V1 } from "../../src/ydm/AdaptiveCurveYDM_V1.sol";
import { AdaptiveCurveYDM_V2 } from "../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { MarketState } from "../../src/libraries/Types.sol";
import { WAD } from "../../src/libraries/Constants.sol";

/**
 * @title YDMInvariants
 * @notice The single dedicated invariant suite for ALL THREE YDM models: StaticCurveYDM, AdaptiveCurveYDM_V1, AdaptiveCurveYDM_V2.
 * @dev One invariant test contract per model. Each contract deploys a spread of Handler instances that span the
 *      TARGET_UTILIZATION_WAD range (the constructor immutable kink), so the target dimension is exercised alongside
 *      utilization, market state, elapsed time, and reinitialization.
 *
 * Each Handler IS the accountant: it deploys and initializes its own model in its constructor (msg.sender == handler),
 * so the model keys all per-market storage off the handler address. The fuzzer drives the handler's four actions:
 *   - pokeYieldShare(util, stateSeed): the mutating IYDM.yieldShare path over RAW uint256 util + a MarketState from the seed
 *   - previewOnly(util, stateSeed):    the view IYDM.previewYieldShare path
 *   - warp(secs):                       advance time up to ~50 years so the adaptive engine actually adapts
 *   - reinit(...):                      re-initialize the market curve within bounded-VALID params
 * Every external model call is wrapped in try/catch: a revert flips everReverted rather than aborting the run.
 *
 * Canonical invariants (a genuine failure is a REAL bug — keep it failing, do not weaken):
 *   - yieldShare/previewYieldShare output is always <= WAD for any state/util (max observed <= WAD).
 *   - post-initialization calls NEVER revert (everReverted == false).
 *   - (adaptive only) the stored yieldShareAtTargetWAD stays within [MIN_YIELD_SHARE_AT_TARGET_WAD, MAX_YIELD_SHARE_AT_TARGET_WAD] == [1e14, WAD].
 */

// =====================================================================
// Shared handler base: cheatcodes + bounding, no external surface of its own
// =====================================================================

/// @dev Extends StdUtils for `bound` (internal pure) only. Declares vm directly so the handler exposes ZERO inherited
/// external functions and the invariant fuzzer sees only the concrete handler's declared actions.
abstract contract BaseYDMHandler is StdUtils {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice The largest yieldShare/previewYieldShare output observed across every action so far, scaled to WAD.
    uint256 public maxYieldShareObserved;

    /// @notice Set true the first time any post-init model call reverts. Must stay false.
    bool public everReverted;

    /// @dev ~50 years, the per-call warp ceiling.
    uint256 internal constant MAX_WARP_SECS = 50 * 365 days;

    /// @dev Maps a fuzzed seed to a MarketState so both PERPETUAL and FIXED_TERM are exercised.
    function _state(uint8 _seed) internal pure returns (MarketState) {
        return (_seed % 2 == 0) ? MarketState.PERPETUAL : MarketState.FIXED_TERM;
    }

    /// @dev Records an observed output, tracking the running maximum.
    function _record(uint256 _yieldShareWAD) internal {
        if (_yieldShareWAD > maxYieldShareObserved) maxYieldShareObserved = _yieldShareWAD;
    }

    /// @notice Advance time by a bounded amount so the adaptive engine has elapsed time to adapt over.
    function warp(uint256 _secs) external {
        _secs = bound(_secs, 0, MAX_WARP_SECS);
        vm.warp(block.timestamp + _secs);
    }
}

// =====================================================================
// StaticCurveYDM handler
// =====================================================================

contract StaticYDMHandler is BaseYDMHandler {
    StaticCurveYDM public model;

    /// @dev Deploys the model at the given target and seeds a flat, always-valid curve (slopes == 0 for any target).
    constructor(uint256 _targetWAD) {
        model = new StaticCurveYDM(_targetWAD);
        // Flat init: y0 == yT == yFull => both slopes are 0, so it initializes for ANY target in (0, WAD) with no SafeCast overflow.
        model.initializeYDMForMarket(1e17, 1e17, 1e17);
    }

    function pokeYieldShare(uint256 _util, uint8 _stateSeed) external {
        try model.yieldShare(_state(_stateSeed), _util) returns (uint256 ys) {
            _record(ys);
        } catch {
            everReverted = true;
        }
    }

    function previewOnly(uint256 _util, uint8 _stateSeed) external {
        try model.previewYieldShare(_state(_stateSeed), _util) returns (uint256 ys) {
            _record(ys);
        } catch {
            everReverted = true;
        }
    }

    /// @notice Re-initialize within bounded-VALID params, respecting the uint64 slope-fits constraint per target.
    function reinit(uint64 _y0Seed, uint64 _yTSeed, uint64 _yFullSeed) external {
        uint256 t = model.TARGET_UTILIZATION_WAD();
        // Max (yT - y0) so slopeLt = (yT-y0)*WAD/t fits uint64; max (yFull - yT) so slopeGte = (yFull-yT)*WAD/(WAD-t) fits uint64.
        uint256 belowCap = (t * uint256(type(uint64).max)) / WAD;
        uint256 aboveCap = ((WAD - t) * uint256(type(uint64).max)) / WAD;

        uint256 yT = bound(uint256(_yTSeed), 1, WAD); // yT > 0 required by Static init
        uint256 y0Lo = yT > belowCap ? yT - belowCap : 0;
        uint256 y0 = bound(uint256(_y0Seed), y0Lo, yT);
        uint256 yFullHi = yT + aboveCap > WAD ? WAD : yT + aboveCap;
        uint256 yFull = bound(uint256(_yFullSeed), yT, yFullHi);

        try model.initializeYDMForMarket(uint64(y0), uint64(yT), uint64(yFull)) { }
        catch {
            everReverted = true;
        }
    }
}

// =====================================================================
// AdaptiveCurveYDM_V1 handler
// =====================================================================

contract AdaptiveV1Handler is BaseYDMHandler {
    AdaptiveCurveYDM_V1 public model;

    /// @dev MIN_YIELD_SHARE_AT_TARGET_WAD baked into both adaptive models by their constructors.
    uint256 internal constant MIN_YT = 1e14;

    constructor(uint256 _targetWAD) {
        model = new AdaptiveCurveYDM_V1(_targetWAD);
        // Valid V1 init for any target: yT in [1e14, WAD], yT <= yFull <= WAD.
        model.initializeYDMForMarket(1e17, 8e17);
    }

    function pokeYieldShare(uint256 _util, uint8 _stateSeed) external {
        try model.yieldShare(_state(_stateSeed), _util) returns (uint256 ys) {
            _record(ys);
        } catch {
            everReverted = true;
        }
    }

    function previewOnly(uint256 _util, uint8 _stateSeed) external {
        try model.previewYieldShare(_state(_stateSeed), _util) returns (uint256 ys) {
            _record(ys);
        } catch {
            everReverted = true;
        }
    }

    /// @notice Re-initialize within bounded-VALID params: yT in [1e14, WAD], yFull in [yT, WAD].
    function reinit(uint64 _yTSeed, uint64 _yFullSeed) external {
        uint256 yT = bound(uint256(_yTSeed), MIN_YT, WAD);
        uint256 yFull = bound(uint256(_yFullSeed), yT, WAD);
        try model.initializeYDMForMarket(uint64(yT), uint64(yFull)) { }
        catch {
            everReverted = true;
        }
    }

    /// @dev Reads the stored yield share at target for this handler's market (element 0 of the curve struct).
    function storedYieldShareAtTargetWAD() external view returns (uint256 yTWAD) {
        (yTWAD,,) = model.accountantToCurve(address(this));
    }
}

// =====================================================================
// AdaptiveCurveYDM_V2 handler
// =====================================================================

contract AdaptiveV2Handler is BaseYDMHandler {
    AdaptiveCurveYDM_V2 public model;

    uint256 internal constant MIN_YT = 1e14;

    constructor(uint256 _targetWAD) {
        model = new AdaptiveCurveYDM_V2(_targetWAD);
        // Valid V2 init for any target: y0 <= yT, yT >= 1e14, yT <= yFull <= WAD.
        model.initializeYDMForMarket(0, 1e17, 8e17);
    }

    function pokeYieldShare(uint256 _util, uint8 _stateSeed) external {
        try model.yieldShare(_state(_stateSeed), _util) returns (uint256 ys) {
            _record(ys);
        } catch {
            everReverted = true;
        }
    }

    function previewOnly(uint256 _util, uint8 _stateSeed) external {
        try model.previewYieldShare(_state(_stateSeed), _util) returns (uint256 ys) {
            _record(ys);
        } catch {
            everReverted = true;
        }
    }

    /// @notice Re-initialize within bounded-VALID params: yT in [1e14, WAD], y0 in [0, yT], yFull in [yT, WAD].
    function reinit(uint64 _y0Seed, uint64 _yTSeed, uint64 _yFullSeed) external {
        uint256 yT = bound(uint256(_yTSeed), MIN_YT, WAD);
        uint256 y0 = bound(uint256(_y0Seed), 0, yT);
        uint256 yFull = bound(uint256(_yFullSeed), yT, WAD);
        try model.initializeYDMForMarket(uint64(y0), uint64(yT), uint64(yFull)) { }
        catch {
            everReverted = true;
        }
    }

    /// @dev Reads the stored yield share at target for this handler's market (element 0 of the curve struct).
    function storedYieldShareAtTargetWAD() external view returns (uint256 yTWAD) {
        (yTWAD,,,) = model.accountantToCurve(address(this));
    }
}

// =====================================================================
// Invariant test: StaticCurveYDM
// =====================================================================

contract StaticCurveYDMInvariants is StdInvariant, Test {
    StaticYDMHandler[] internal handlers;

    /// @dev Representative + boundary targets spanning (0, WAD). WAD itself is excluded: Static init divides by (WAD - target) and reverts at target == WAD.
    function _targets() internal pure returns (uint256[] memory t) {
        t = new uint256[](6);
        t[0] = 1; // 1 wei
        t[1] = 1e14;
        t[2] = 1e17; // 0.1
        t[3] = 5e17; // 0.5
        t[4] = 9e17; // 0.9
        t[5] = WAD - 1;
    }

    function setUp() public {
        uint256[] memory targets = _targets();
        bytes4[] memory sel = new bytes4[](4);
        sel[0] = StaticYDMHandler.pokeYieldShare.selector;
        sel[1] = StaticYDMHandler.previewOnly.selector;
        sel[2] = BaseYDMHandler.warp.selector;
        sel[3] = StaticYDMHandler.reinit.selector;

        for (uint256 i = 0; i < targets.length; i++) {
            StaticYDMHandler h = new StaticYDMHandler(targets[i]);
            handlers.push(h);
            targetContract(address(h));
            targetSelector(FuzzSelector({ addr: address(h), selectors: sel }));
        }
    }

    function invariant_yieldShareNeverExceedsWAD() public view {
        for (uint256 i = 0; i < handlers.length; i++) {
            assertLe(handlers[i].maxYieldShareObserved(), WAD, "static: yield share exceeded WAD");
        }
    }

    function invariant_callsNeverRevert() public view {
        for (uint256 i = 0; i < handlers.length; i++) {
            assertFalse(handlers[i].everReverted(), "static: a post-init call reverted");
        }
    }
}

// =====================================================================
// Invariant test: AdaptiveCurveYDM_V1
// =====================================================================

contract AdaptiveCurveYDMV1Invariants is StdInvariant, Test {
    AdaptiveV1Handler[] internal handlers;

    uint256 internal constant MIN_YT = 1e14;

    /// @dev Boundary + representative targets spanning (0, WAD], including WAD (adaptive init is well-defined at the kink == WAD).
    function _targets() internal pure returns (uint256[] memory t) {
        t = new uint256[](7);
        t[0] = 1;
        t[1] = 1e14;
        t[2] = 1e17;
        t[3] = 5e17;
        t[4] = 9e17;
        t[5] = WAD - 1;
        t[6] = WAD;
    }

    function setUp() public {
        uint256[] memory targets = _targets();
        bytes4[] memory sel = new bytes4[](4);
        sel[0] = AdaptiveV1Handler.pokeYieldShare.selector;
        sel[1] = AdaptiveV1Handler.previewOnly.selector;
        sel[2] = BaseYDMHandler.warp.selector;
        sel[3] = AdaptiveV1Handler.reinit.selector;

        for (uint256 i = 0; i < targets.length; i++) {
            AdaptiveV1Handler h = new AdaptiveV1Handler(targets[i]);
            handlers.push(h);
            targetContract(address(h));
            targetSelector(FuzzSelector({ addr: address(h), selectors: sel }));
        }
    }

    function invariant_yieldShareNeverExceedsWAD() public view {
        for (uint256 i = 0; i < handlers.length; i++) {
            assertLe(handlers[i].maxYieldShareObserved(), WAD, "V1: yield share exceeded WAD");
        }
    }

    function invariant_callsNeverRevert() public view {
        for (uint256 i = 0; i < handlers.length; i++) {
            assertFalse(handlers[i].everReverted(), "V1: a post-init call reverted");
        }
    }

    function invariant_yieldShareAtTargetWithinBounds() public view {
        for (uint256 i = 0; i < handlers.length; i++) {
            uint256 yT = handlers[i].storedYieldShareAtTargetWAD();
            assertGe(yT, MIN_YT, "V1: yieldShareAtTarget below MIN");
            assertLe(yT, WAD, "V1: yieldShareAtTarget above MAX");
        }
    }
}

// =====================================================================
// Invariant test: AdaptiveCurveYDM_V2
// =====================================================================

contract AdaptiveCurveYDMV2Invariants is StdInvariant, Test {
    AdaptiveV2Handler[] internal handlers;

    uint256 internal constant MIN_YT = 1e14;

    function _targets() internal pure returns (uint256[] memory t) {
        t = new uint256[](7);
        t[0] = 1;
        t[1] = 1e14;
        t[2] = 1e17;
        t[3] = 5e17;
        t[4] = 9e17;
        t[5] = WAD - 1;
        t[6] = WAD;
    }

    function setUp() public {
        uint256[] memory targets = _targets();
        bytes4[] memory sel = new bytes4[](4);
        sel[0] = AdaptiveV2Handler.pokeYieldShare.selector;
        sel[1] = AdaptiveV2Handler.previewOnly.selector;
        sel[2] = BaseYDMHandler.warp.selector;
        sel[3] = AdaptiveV2Handler.reinit.selector;

        for (uint256 i = 0; i < targets.length; i++) {
            AdaptiveV2Handler h = new AdaptiveV2Handler(targets[i]);
            handlers.push(h);
            targetContract(address(h));
            targetSelector(FuzzSelector({ addr: address(h), selectors: sel }));
        }
    }

    function invariant_yieldShareNeverExceedsWAD() public view {
        for (uint256 i = 0; i < handlers.length; i++) {
            assertLe(handlers[i].maxYieldShareObserved(), WAD, "V2: yield share exceeded WAD");
        }
    }

    function invariant_callsNeverRevert() public view {
        for (uint256 i = 0; i < handlers.length; i++) {
            assertFalse(handlers[i].everReverted(), "V2: a post-init call reverted");
        }
    }

    function invariant_yieldShareAtTargetWithinBounds() public view {
        for (uint256 i = 0; i < handlers.length; i++) {
            uint256 yT = handlers[i].storedYieldShareAtTargetWAD();
            assertGe(yT, MIN_YT, "V2: yieldShareAtTarget below MIN");
            assertLe(yT, WAD, "V2: yieldShareAtTarget above MAX");
        }
    }
}
