// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { FixtureCell } from "../../base/fixtures/FixtureTypes.sol";
import { cellA } from "../../base/fixtures/TokenConfigs.sol";
import { TrancheFixtureSmoke } from "./TrancheFixtureSmoke.sol";

/// @title CellASmokeTest
/// @notice Smoke battery on cell A: 4626(18,18) ST/JT shares against a 6-decimal quote stable
contract CellASmokeTest is TrancheFixtureSmoke {
    function _smokeCell() internal pure override returns (FixtureCell memory) {
        return cellA();
    }

    /**
     * @dev Hand derivation for cell A: one whole ST asset = 1e18 share-wei, at initialRateWAD 1.0 that converts to
     *      1e18 underlying-wei = 1.0 whole 18-decimal underlying, and the 1.0 oracle price maps one whole
     *      underlying to exactly 1e18 NAV wei
     */
    function _expectedSTUnitNAV() internal pure override returns (uint256) {
        return 1e18;
    }
}
