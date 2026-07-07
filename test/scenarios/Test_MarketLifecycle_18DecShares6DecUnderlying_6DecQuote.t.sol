// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { FixtureCell } from "../utils/FixtureTypes.sol";
import { cellC } from "../utils/TokenConfigs.sol";
import { Test_MarketLifecycleBase } from "./Test_MarketLifecycleBase.t.sol";

/// @title Test_MarketLifecycle_18DecShares6DecUnderlying_6DecQuote
/// @notice Market lifecycle on the decimal-skewed shape: 4626(18,6) shares against a 6-decimal quote stable
contract Test_MarketLifecycle_18DecShares6DecUnderlying_6DecQuote is Test_MarketLifecycleBase {
    function _tokenShape() internal pure override returns (FixtureCell memory) {
        return cellC();
    }

    /**
     * @dev Hand derivation for this shape: one whole ST asset = 1e18 share-wei over a 6-decimal underlying, at
     *      initialRateWAD 1.0 that converts to 1e6 underlying-wei = 1.0 whole underlying, and the 1.0 oracle price
     *      maps one whole underlying to exactly 1e18 NAV wei (the 18-to-6 share/underlying skew must cancel)
     */
    function _expectedSTUnitNAV() internal pure override returns (uint256) {
        return 1e18;
    }
}
