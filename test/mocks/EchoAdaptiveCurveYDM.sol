// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { WAD_INT } from "../../src/libraries/Constants.sol";
import { BaseAdaptiveCurveYDM } from "../../src/ydm/base/BaseAdaptiveCurveYDM.sol";

/**
 * @title EchoAdaptiveCurveYDM
 * @notice Concrete adaptive model whose curve output echoes one of the two inputs the base engine hands the
 *         curve hook, selected by a mode flag: the time-averaged yield share at target, or the normalized
 *         delta from target shifted by WAD
 * @dev The shifted-delta echo maps the signed normalized delta in [-WAD, WAD] onto [0, 2 * WAD] so an observer
 *      recovers it as int256(output) - WAD_INT, making the base's region normalization directly observable
 * @dev Per-market curve state is keyed by the calling accountant and freely seedable, including the last
 *      adaptation timestamp, so elapsed-time adaptation paths are drivable without a prior mutating call
 */
contract EchoAdaptiveCurveYDM is BaseAdaptiveCurveYDM {
    /// @notice Selects which curve hook input the output echoes
    enum EchoMode {
        AVG_YIELD_SHARE_AT_TARGET,
        NORMALIZED_DELTA_SHIFTED
    }

    /// @notice The currently selected echo mode
    EchoMode public echoMode;

    /// @notice The stored yield share at target per market (keyed by the calling accountant)
    mapping(address market => uint256 yieldShareAtTargetWAD) public yieldShareAtTarget;

    /// @notice The stored last adaptation timestamp per market (keyed by the calling accountant)
    mapping(address market => uint256 timestamp) public lastAdaptationTimestamp;

    /// @notice The curve output most recently persisted through the write hook per market
    mapping(address market => uint256 yieldShareWAD) public lastWrittenYieldShare;

    constructor(
        uint256 _targetUtilizationWAD,
        uint256 _minYieldShareAtTargetWAD,
        uint256 _maxYieldShareAtTargetWAD,
        uint256 _adaptationSpeedAtBoundaryWAD
    )
        BaseAdaptiveCurveYDM(_targetUtilizationWAD, _minYieldShareAtTargetWAD, _maxYieldShareAtTargetWAD, _adaptationSpeedAtBoundaryWAD)
    { }

    /// @notice Selects which curve hook input the output echoes
    function setEchoMode(EchoMode _echoMode) external {
        echoMode = _echoMode;
    }

    /// @notice Seeds the caller's curve state so its market reads as initialized with a chosen adaptation clock
    function seedCurve(uint256 _yieldShareAtTargetWAD, uint256 _lastAdaptationTimestamp) external {
        yieldShareAtTarget[msg.sender] = _yieldShareAtTargetWAD;
        lastAdaptationTimestamp[msg.sender] = _lastAdaptationTimestamp;
    }

    /// @notice Seeds the curve state of an arbitrary market so a test can stage state on behalf of an accountant
    function seedCurveFor(address _market, uint256 _yieldShareAtTargetWAD, uint256 _lastAdaptationTimestamp) external {
        yieldShareAtTarget[_market] = _yieldShareAtTargetWAD;
        lastAdaptationTimestamp[_market] = _lastAdaptationTimestamp;
    }

    /// @dev Echoes the selected curve hook input, shifting the signed normalized delta into unsigned range
    function _computeYieldShare(int256 _normalizedDeltaFromTargetWAD, uint256 _avgYieldShareAtTargetWAD) internal view override returns (uint256) {
        if (echoMode == EchoMode.NORMALIZED_DELTA_SHIFTED) {
            // The normalized delta lies in [-WAD, WAD], so the shifted value lies in [0, 2 * WAD]
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint256(_normalizedDeltaFromTargetWAD + WAD_INT);
        }
        return _avgYieldShareAtTargetWAD;
    }

    function _readAdaptiveCurve() internal view override returns (uint256 yieldShareAtTargetWAD, uint256 lastAdaptationTs) {
        return (yieldShareAtTarget[msg.sender], lastAdaptationTimestamp[msg.sender]);
    }

    function _writeAdaptiveCurve(uint256 _newYieldShareAtTargetWAD, uint256 _yieldShareWAD) internal override {
        yieldShareAtTarget[msg.sender] = _newYieldShareAtTargetWAD;
        lastAdaptationTimestamp[msg.sender] = block.timestamp;
        lastWrittenYieldShare[msg.sender] = _yieldShareWAD;
    }
}
