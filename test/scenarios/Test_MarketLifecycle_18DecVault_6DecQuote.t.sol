// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { FixtureCell } from "../utils/FixtureTypes.sol";
import { cellA } from "../utils/TokenConfigs.sol";
import { Test_MarketLifecycleBase } from "./Test_MarketLifecycleBase.t.sol";

/// @title Test_MarketLifecycle_18DecVault_6DecQuote
/// @notice Market lifecycle on the baseline token shape: 4626(18,18) ST/JT shares against a 6-decimal quote stable
contract Test_MarketLifecycle_18DecVault_6DecQuote is Test_MarketLifecycleBase {
    function _tokenShape() internal pure override returns (FixtureCell memory) {
        return cellA();
    }

    /**
     * @dev Hand derivation for this shape: one whole ST asset = 1e18 share-wei, at initialRateWAD 1.0 that
     *      converts to 1e18 underlying-wei = 1.0 whole 18-decimal underlying, and the 1.0 oracle price maps one
     *      whole underlying to exactly 1e18 NAV wei
     */
    function _expectedSTUnitNAV() internal pure override returns (uint256) {
        return 1e18;
    }
}
