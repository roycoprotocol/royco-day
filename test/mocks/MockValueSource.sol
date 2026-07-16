// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @notice Settable pull-based value source for checkpoint clock tests, with an optional revert mode
contract MockValueSource {
    uint256 public value;
    bool public revertMode;

    constructor(uint256 _value) {
        value = _value;
    }

    function setValue(uint256 _value) external {
        value = _value;
    }

    function setRevertMode(bool _revertMode) external {
        revertMode = _revertMode;
    }

    function getValue() external view returns (uint256) {
        require(!revertMode, "MockValueSource: revert mode");
        return value;
    }
}
