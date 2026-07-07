// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { FixtureCell } from "../utils/FixtureTypes.sol";
import { cellB } from "../utils/TokenConfigs.sol";
import { Test_MarketLifecycleBase } from "./Test_MarketLifecycleBase.t.sol";

/// @title Test_MarketLifecycle_6DecVault_18DecQuote
/// @notice Market lifecycle on the low-decimal shape: 4626(6,6) ST/JT shares against an 18-decimal quote stable
contract Test_MarketLifecycle_6DecVault_18DecQuote is Test_MarketLifecycleBase {
    function _tokenShape() internal pure override returns (FixtureCell memory) {
        return cellB();
    }

    /**
     * @dev Hand derivation for this shape: one whole ST asset = 1e6 share-wei, at initialRateWAD 1.0 that
     *      converts to 1e6 underlying-wei = 1.0 whole 6-decimal underlying, and the 1.0 oracle price maps one
     *      whole underlying to exactly 1e18 NAV wei (NAV_UNIT is always WAD-scaled regardless of tranche decimals)
     */
    function _expectedSTUnitNAV() internal pure override returns (uint256) {
        return 1e18;
    }
}
