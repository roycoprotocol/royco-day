// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ISanctionsList } from "../../src/interfaces/external/chainalysis/ISanctionsList.sol";

/// @title MockSanctionsList
/// @notice Minimal Chainalysis-shaped sanctions list with a settable designation per address
contract MockSanctionsList is ISanctionsList {
    /// @dev The sanctions designations this mock reports
    mapping(address account => bool sanctioned) private _sanctioned;

    /// @notice Flags or clears an address's sanctions designation
    function setSanctioned(address _account, bool _isSanctioned) external {
        _sanctioned[_account] = _isSanctioned;
    }

    /// @inheritdoc ISanctionsList
    function isSanctioned(address _account) external view override(ISanctionsList) returns (bool) {
        return _sanctioned[_account];
    }
}
