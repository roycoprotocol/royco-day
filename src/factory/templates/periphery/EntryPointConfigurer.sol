// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayEntryPoint } from "../../../interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoFactory } from "../../../interfaces/factory/IRoycoFactory.sol";

/**
 * @title EntryPointConfigurer
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Template mixin pinning the pre-deployed Royco Day entry point singleton and exposing the helper that
 *         configures a freshly deployed market's tranches on it
 */
abstract contract EntryPointConfigurer {
    /// @notice Thrown when the entry point is the zero address
    error ENTRY_POINT_CANNOT_BE_ZERO_ADDRESS();

    /// @notice Thrown when the entry point's provenance registry is not the factory this template is bound to
    error ENTRY_POINT_BOUND_TO_DIFFERENT_FACTORY();

    /// @notice The pre-deployed Royco Day entry point singleton configured for every market deployed through this template
    address public immutable ROYCO_DAY_ENTRY_POINT;

    /**
     * @notice Validates and pins the entry point singleton, deployed before any market
     * @param _roycoDayEntryPoint The pre-deployed Royco Day entry point
     * @param _factory The Royco factory the inheriting template is bound to
     */
    constructor(address _roycoDayEntryPoint, IRoycoFactory _factory) {
        // Validate the entry point and factory
        require(_roycoDayEntryPoint != address(0), ENTRY_POINT_CANNOT_BE_ZERO_ADDRESS());
        // Validate the entry point is bound to the factory this template is bound to
        require(IRoycoDayEntryPoint(_roycoDayEntryPoint).ROYCO_FACTORY() == address(_factory), ENTRY_POINT_BOUND_TO_DIFFERENT_FACTORY());
        ROYCO_DAY_ENTRY_POINT = _roycoDayEntryPoint;
    }

    /**
     * @notice Applies the specified tranche configurations on the entry point through the factory
     * @dev A market always has a senior tranche but may lack a junior or liquidity tranche, so any zero-address
     *      tranche and its paired config are dropped before the call, the entry point rejects a zero tranche and a
     *      caller passes zero for an absent one
     * @param _factory The Royco factory driving the deployment, used to execute the admin-gated call
     * @param _tranches The freshly deployed tranches to configure on the entry point, an absent tranche is the zero address
     * @param _configs The entry point configuration for each tranche, index-aligned with `_tranches`
     */
    function _configureEntryPointTrancheConfigs(
        IRoycoFactory _factory,
        address[] memory _tranches,
        IRoycoDayEntryPoint.TrancheConfig[] memory _configs
    )
        internal
    {
        // Over-allocate to the input length, then pack the present tranches and their paired configs, dropping any null tranches
        address[] memory tranches = new address[](_tranches.length);
        IRoycoDayEntryPoint.TrancheConfig[] memory configs = new IRoycoDayEntryPoint.TrancheConfig[](_tranches.length);
        uint256 present;
        for (uint256 i = 0; i < _tranches.length; ++i) {
            if (_tranches[i] == address(0)) continue;
            (tranches[present], configs[present]) = (_tranches[i], _configs[i]);
            ++present;
        }
        // Set the size of the tranches and configs arrays to the final size after pruning the null tranches
        assembly ("memory-safe") {
            mstore(tranches, present)
            mstore(configs, present)
        }

        _factory.executeAsFactory(ROYCO_DAY_ENTRY_POINT, abi.encodeCall(IRoycoDayEntryPoint.modifyTrancheConfigs, (tranches, configs)));
    }
}
