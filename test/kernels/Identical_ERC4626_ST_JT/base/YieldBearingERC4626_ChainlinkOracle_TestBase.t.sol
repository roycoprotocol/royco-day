// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel
} from "../../../../src/kernels/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.sol";

import { YieldBearingERC4626_TestBase } from "./YieldBearingERC4626_TestBase.t.sol";

/// @title YieldBearingERC4626_ChainlinkOracle_TestBase
/// @notice Base test contract for Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel
/// @dev Extends the AdminOracle test base, overriding only the kernel-specific casts.
///      Both kernel types inherit setConversionRate/getStoredConversionRateWAD from IdenticalAssetsOracleQuoter,
///      so yield/loss simulation via stored rate works identically.
abstract contract YieldBearingERC4626_ChainlinkOracle_TestBase is YieldBearingERC4626_TestBase {
    /// @notice Gets the current conversion rate using the kernel's getter (in WAD precision)
    function _getConversionRate() internal view virtual override returns (uint256) {
        return Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel(address(KERNEL)).getStoredConversionRateWAD();
    }

    /// @notice Sets the conversion rate using the kernel's setter (in WAD precision)
    /// @dev Requires ADMIN_ORACLE_QUOTER_ROLE, which is granted to ORACLE_QUOTER_ADMIN_ADDRESS
    function _setConversionRate(uint256 _newRateWAD) internal virtual override {
        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel(address(KERNEL)).setConversionRate(_newRateWAD);
    }
}
