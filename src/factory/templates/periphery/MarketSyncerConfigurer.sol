// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IRoycoMarketSyncer } from "../../../interfaces/external/royco-periphery/IRoycoMarketSyncer.sol";
import { IRoycoFactory } from "../../../interfaces/factory/IRoycoFactory.sol";

/**
 * @title MarketSyncerConfigurer
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Template mixin pinning the pre-deployed Royco market syncer singleton and exposing the helper that
 *         registers a freshly deployed market's kernel on it
 */
abstract contract MarketSyncerConfigurer {
    /// @notice Thrown when the market syncer is the zero address
    error SYNCER_CANNOT_BE_ZERO_ADDRESS();

    /// @notice The pre-deployed Royco market syncer singleton every deployed market's kernel is registered on
    address public immutable ROYCO_MARKET_SYNCER;

    /// @notice Validates and pins the market syncer singleton, deployed before any market
    /// @param _roycoMarketSyncer The pre-deployed Royco market syncer
    constructor(address _roycoMarketSyncer) {
        // Validate the market syncer
        require(_roycoMarketSyncer != address(0), SYNCER_CANNOT_BE_ZERO_ADDRESS());
        ROYCO_MARKET_SYNCER = _roycoMarketSyncer;
    }

    /**
     * @notice Registers the specified market kernel on the syncer through the factory
     * @param _factory The Royco factory driving the deployment, used to execute the gated call
     * @param _kernel The freshly deployed market kernel to register
     */
    function _registerMarketKernelOnSyncer(IRoycoFactory _factory, address _kernel) internal {
        address[] memory kernels = new address[](1);
        kernels[0] = _kernel;
        _factory.executeAsFactory(ROYCO_MARKET_SYNCER, abi.encodeCall(IRoycoMarketSyncer.addMarketKernels, (kernels)));
    }
}
