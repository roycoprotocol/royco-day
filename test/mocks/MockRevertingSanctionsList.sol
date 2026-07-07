// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ISanctionsList } from "../../src/interfaces/external/chainalysis/ISanctionsList.sol";

/// @title MockRevertingSanctionsList
/// @notice A Chainalysis-shaped sanctions list whose every query reverts, modeling a broken or unreachable oracle
contract MockRevertingSanctionsList is ISanctionsList {
    /// @notice Thrown on every isSanctioned query, a distinctive error so tests can pin the bubbled failure
    error SANCTIONS_LIST_UNAVAILABLE();

    /// @inheritdoc ISanctionsList
    function isSanctioned(address) external pure override(ISanctionsList) returns (bool) {
        revert SANCTIONS_LIST_UNAVAILABLE();
    }
}
