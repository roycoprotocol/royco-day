// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { FixtureCell } from "../../base/fixtures/FixtureTypes.sol";
import { cellD } from "../../base/fixtures/TokenConfigs.sol";
import { TrancheFixtureSmoke } from "./TrancheFixtureSmoke.sol";

/// @title CellDSmokeTest
/// @notice Smoke battery on cell D: 8-decimal 4626(8,8) ST/JT shares against a 6-decimal quote stable
/// @dev Cell D contributes the 8-decimal-shares axis only, jtCoinvested stays true at the kernel layer (identical ST/JT assets force co-investment)
contract CellDSmokeTest is TrancheFixtureSmoke {
    function _smokeCell() internal pure override returns (FixtureCell memory) {
        return cellD();
    }

    /**
     * @dev Hand derivation for cell D: one whole ST asset = 1e8 share-wei, at initialRateWAD 1.0 that converts to
     *      1e8 underlying-wei = 1.0 whole 8-decimal underlying, and the 1.0 oracle price maps one whole underlying
     *      to exactly 1e18 NAV wei
     */
    function _expectedSTUnitNAV() internal pure override returns (uint256) {
        return 1e18;
    }
}
