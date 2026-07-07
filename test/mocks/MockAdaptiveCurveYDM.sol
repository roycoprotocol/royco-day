// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { BaseAdaptiveCurveYDM } from "../../src/ydm/base/BaseAdaptiveCurveYDM.sol";

/**
 * @title MockAdaptiveCurveYDM
 * @notice Minimal concrete model that forwards ARBITRARY constructor parameters straight to the
 *         BaseAdaptiveCurveYDM constructor. V1 and V2 hardcode their (min, max, speed) triple, so
 *         this mock is the only way to exercise the base constructor's parameter gate across the
 *         full space (min == 0, min > max, max > WAD, speed == 0, speed > limit, speed == limit).
 * @dev The curve shape is deliberately trivial: `_computeYieldShare` returns the (already-bounded)
 *      time-averaged yield share at target, ignoring the delta. That keeps the mock's output a pure
 *      function of base machinery so the base behavior (capping, uninitialized gate, immutable
 *      getters) is what is under test, not a concrete curve.
 */
contract MockAdaptiveCurveYDM is BaseAdaptiveCurveYDM {
    /// @notice The stored yield share at target per market (keyed by caller)
    mapping(address => uint256) public yAtTarget;

    /// @notice The stored last-adaptation timestamp per market (keyed by caller)
    mapping(address => uint256) public lastTs;

    constructor(uint256 _target, uint256 _minY, uint256 _maxY, uint256 _speed) BaseAdaptiveCurveYDM(_target, _minY, _maxY, _speed) { }

    /// @notice Seed a nonzero yield-share-at-target for msg.sender so the market reads as initialized.
    function initFor(uint256 _y) external {
        yAtTarget[msg.sender] = _y;
        lastTs[msg.sender] = 0;
    }

    function _computeYieldShare(int256, uint256 _avgYieldShareAtTargetWAD) internal pure override returns (uint256) {
        return _avgYieldShareAtTargetWAD;
    }

    function _readAdaptiveCurve() internal view override returns (uint256, uint256) {
        return (yAtTarget[msg.sender], lastTs[msg.sender]);
    }

    function _writeAdaptiveCurve(uint256 _newYieldShareAtTargetWAD, uint256) internal override {
        yAtTarget[msg.sender] = _newYieldShareAtTargetWAD;
        lastTs[msg.sender] = block.timestamp;
    }
}
