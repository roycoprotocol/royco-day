// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IYDM } from "../../src/interfaces/IYDM.sol";
import { MarketState } from "../../src/libraries/Types.sol";

/**
 * @title MockYDM
 * @notice Yield distribution model test mock pinning premium shares to chosen constants instead of curve outputs
 * @dev State is keyed by msg.sender (the accountant), matching production YDMs, so distinct markets on one instance never collide
 * @dev Resolution precedence per call, armed revert mode, then the global script (peeked by previews, consumed by mutating calls),
 *      then the per-accountant pinned share, then the global default share
 * @dev previewYieldShare is a STATICCALL from the accountant, so preview invocations cannot be recorded on-chain, only mutating
 *      calls are counted, use vm.expectCall to observe previews
 * @dev Fidelity gaps vs the production YDMs: initializeYDMForMarket accepts any curve without the monotonicity and
 *      nonzero-target validation StaticCurveYDM enforces (INVALID_YDM_INITIALIZATION), is freely re-callable, and the
 *      output is a pinned constant with no utilization dependence or adaptation
 */
contract MockYDM is IYDM {
    /// @dev A per-accountant pinned yield share and whether it is set, so a pinned zero is distinguishable from unset
    struct PinnedShare {
        bool isPinned;
        uint256 yieldShareWAD;
    }

    /// @notice Thrown by both entrypoints when revert mode is armed (the sync-bricking YDM)
    error YDM_REVERT_MODE();

    /// @dev Per-accountant pinned yield shares, set by initializeYDMForMarket and the keyed setYieldShare
    mapping(address accountant => PinnedShare pinned) private _pinned;

    /// @notice The global default yield share used when no script is active and the accountant has no pinned share
    uint256 public defaultYieldShareWAD;

    /// @notice Whether initializeYDMForMarket was invoked for the accountant, recording the raw-call init path
    mapping(address accountant => bool initialized) public initializedFor;

    /// @notice The initialization parameters recorded per accountant, (yAtZero, yAtTarget, yAtFull)
    mapping(address accountant => uint64[3] curve) private _initParams;

    /// @dev The scripted output sequence, consumed one entry per mutating call
    uint256[] private _script;

    /// @notice The index of the next unconsumed script entry
    uint256 public scriptIndex;

    /// @dev Whether both entrypoints revert
    bool private _revertMode;

    /// @notice The market state passed to the last mutating call
    MarketState public lastMarketState;

    /// @notice The utilization passed to the last mutating call, scaled to WAD precision
    uint256 public lastUtilizationWAD;

    /// @notice The accountant that made the last mutating call
    address public lastCaller;

    /// @notice The number of mutating yieldShare calls served
    uint256 public mutatingCallCount;

    // =============================
    // Accountant-Facing Surface
    // =============================

    /**
     * @notice Initializes this mock for the calling accountant, satisfying the accountant's raw-call init path
     * @dev Accepts any curve without validation and pins the target-utilization value as the accountant's share
     * @param _yieldShareAtZeroUtilWAD The yield share at 0% utilization, recorded only
     * @param _yieldShareAtTargetWAD The yield share at target utilization, pinned as the accountant's share
     * @param _yieldShareAtFullUtilWAD The yield share at 100% utilization, recorded only
     */
    function initializeYDMForMarket(uint64 _yieldShareAtZeroUtilWAD, uint64 _yieldShareAtTargetWAD, uint64 _yieldShareAtFullUtilWAD) external {
        initializedFor[msg.sender] = true;
        _initParams[msg.sender] = [_yieldShareAtZeroUtilWAD, _yieldShareAtTargetWAD, _yieldShareAtFullUtilWAD];
        _pinned[msg.sender] = PinnedShare({ isPinned: true, yieldShareWAD: _yieldShareAtTargetWAD });
    }

    /// @inheritdoc IYDM
    /// @dev Peeks the next script entry without consuming it, so a preview predicts what the next mutating call returns
    function previewYieldShare(MarketState, uint256) external view override(IYDM) returns (uint256 yieldShareWAD) {
        require(!_revertMode, YDM_REVERT_MODE());
        return _resolve(msg.sender);
    }

    /// @inheritdoc IYDM
    function yieldShare(MarketState _marketState, uint256 _utilizationWAD) external override(IYDM) returns (uint256 yieldShareWAD) {
        require(!_revertMode, YDM_REVERT_MODE());

        // Record the mutating call
        lastMarketState = _marketState;
        lastUtilizationWAD = _utilizationWAD;
        lastCaller = msg.sender;
        mutatingCallCount++;

        // Resolve the output and consume the script entry if one was active
        yieldShareWAD = _resolve(msg.sender);
        if (scriptIndex < _script.length) scriptIndex++;
    }

    // =============================
    // Test Knobs
    // =============================

    /// @notice Pins the yield share for a specific accountant
    function setYieldShare(address _accountant, uint256 _yieldShareWAD) external {
        _pinned[_accountant] = PinnedShare({ isPinned: true, yieldShareWAD: _yieldShareWAD });
    }

    /// @notice Convenience setter for the global default yield share, used when the calling accountant has no pinned share
    function setYieldShare(uint256 _yieldShareWAD) external {
        defaultYieldShareWAD = _yieldShareWAD;
    }

    /// @notice Clears an accountant's pinned share so it falls back to the global default
    function clearYieldShare(address _accountant) external {
        delete _pinned[_accountant];
    }

    /// @notice Arms a scripted output sequence consumed one entry per mutating call, overriding pinned and default shares while active
    function setScript(uint256[] calldata _outputs) external {
        _script = _outputs;
        scriptIndex = 0;
    }

    /// @notice Arms or disarms the revert mode on both entrypoints (the sync-bricking YDM)
    function setRevertMode(bool _shouldRevert) external {
        _revertMode = _shouldRevert;
    }

    // =============================
    // Views
    // =============================

    /// @notice Returns the accountant's pinned share and whether one is set
    function getPinnedShare(address _accountant) external view returns (bool isPinned, uint256 yieldShareWAD) {
        PinnedShare storage pinned = _pinned[_accountant];
        return (pinned.isPinned, pinned.yieldShareWAD);
    }

    /// @notice Returns the initialization parameters recorded for the accountant, (yAtZero, yAtTarget, yAtFull)
    function getInitParams(address _accountant) external view returns (uint64[3] memory) {
        return _initParams[_accountant];
    }

    /// @notice Returns the full scripted output sequence
    function getScript() external view returns (uint256[] memory) {
        return _script;
    }

    // =============================
    // Internal Logic
    // =============================

    /// @notice Resolves the yield share for the accountant, script head first, then its pinned share, then the global default
    function _resolve(address _accountant) internal view returns (uint256) {
        if (scriptIndex < _script.length) return _script[scriptIndex];
        PinnedShare storage pinned = _pinned[_accountant];
        if (pinned.isPinned) return pinned.yieldShareWAD;
        return defaultYieldShareWAD;
    }
}
