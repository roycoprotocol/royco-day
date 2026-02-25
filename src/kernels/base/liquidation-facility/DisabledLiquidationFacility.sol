// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ZERO_TRANCHE_UNITS } from "../../../libraries/Constants.sol";
import { TRANCHE_UNIT } from "../../../libraries/Units.sol";
import { RoycoKernel } from "../RoycoKernel.sol";

/**
 * @title DisabledLiquidationFacility
 * @author Shivaansh Kapoor, Ankur Dubey
 * @dev Inherit from this contract for markets that do not support liquidations
 */
abstract contract DisabledLiquidationFacility is RoycoKernel {
    /// @dev Thrown when attempting to call the liquidate function or when a base asset is configured for a non-liquidatable market
    error LIQUIDATIONS_DISABLED();

    /// @notice Validates that the kernel has no base asset configured since liquidations are disabled
    /// @dev Reverts if BASE_ASSET is non-zero to prevent misconfiguration of markets with liquidations disabled
    constructor() {
        require(BASE_ASSET == address(0), LIQUIDATIONS_DISABLED());
    }

    /// @inheritdoc RoycoKernel
    function getLiquidatableAssets() public pure override(RoycoKernel) returns (TRANCHE_UNIT, TRANCHE_UNIT) {
        return (ZERO_TRANCHE_UNITS, ZERO_TRANCHE_UNITS);
    }

    /// @inheritdoc RoycoKernel
    function liquidate(TRANCHE_UNIT, TRANCHE_UNIT, bytes calldata) external pure override(RoycoKernel) {
        revert LIQUIDATIONS_DISABLED();
    }
}
