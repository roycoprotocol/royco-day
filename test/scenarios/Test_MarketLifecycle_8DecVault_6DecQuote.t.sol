// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { FixtureCell } from "../utils/FixtureTypes.sol";
import { cellD } from "../utils/TokenConfigs.sol";
import { Test_MarketLifecycleBase } from "./Test_MarketLifecycleBase.t.sol";

/// @title Test_MarketLifecycle_8DecVault_6DecQuote
/// @notice Market lifecycle on the 8-decimal shape: 4626(8,8) ST/JT shares against a 6-decimal quote stable
/// @dev This shape contributes the 8-decimal-shares axis only, ST/JT share one asset as the kernel requires
contract Test_MarketLifecycle_8DecVault_6DecQuote is Test_MarketLifecycleBase {
    function _tokenShape() internal pure override returns (FixtureCell memory) {
        return cellD();
    }

    /**
     * @dev Hand derivation for this shape: one whole ST asset = 1e8 share-wei, at initialRateWAD 1.0 that
     *      converts to 1e8 underlying-wei = 1.0 whole 8-decimal underlying, and the 1.0 oracle price maps one
     *      whole underlying to exactly 1e18 NAV wei
     */
    function _expectedSTUnitNAV() internal pure override returns (uint256) {
        return 1e18;
    }
}
