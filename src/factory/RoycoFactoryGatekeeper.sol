// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { AccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { IRoycoDayEntryPoint } from "../interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoMarketSyncer } from "../interfaces/external/royco-periphery/IRoycoMarketSyncer.sol";
import { IRoycoAccessManager } from "../interfaces/factory/IRoycoAccessManager.sol";
import { IRoycoFactoryGatekeeper } from "../interfaces/factory/IRoycoFactoryGatekeeper.sol";
import { ADMIN_ROLE, PUBLIC_ROLE } from "./Roles.sol";

/**
 * @title RoycoFactoryGatekeeper
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Holds `ADMIN_ROLE` on the Royco access manager so the factory does not have to, and lets a market deployment
 *         configure only contracts that have never been configured before
 */
contract RoycoFactoryGatekeeper is IRoycoFactoryGatekeeper {
    /// @inheritdoc IRoycoFactoryGatekeeper
    address public immutable override(IRoycoFactoryGatekeeper) ROYCO_ACCESS_MANAGER;

    /// @inheritdoc IRoycoFactoryGatekeeper
    address public immutable override(IRoycoFactoryGatekeeper) ROYCO_FACTORY;

    /// @inheritdoc IRoycoFactoryGatekeeper
    address public immutable override(IRoycoFactoryGatekeeper) ROYCO_DAY_ENTRY_POINT;

    /// @inheritdoc IRoycoFactoryGatekeeper
    address public immutable override(IRoycoFactoryGatekeeper) ROYCO_MARKET_SYNCER;

    /// @dev Restricts a call to the one factory this gatekeeper serves
    modifier onlyFactory() {
        require(msg.sender == ROYCO_FACTORY, ONLY_FACTORY());
        _;
    }

    /**
     * @param _roycoAccessManager The access manager this gatekeeper holds `ADMIN_ROLE` on
     * @param _roycoFactory The only address permitted to call this gatekeeper, supplied as the CREATE3 address the
     *        factory proxy will occupy: that address is fixed by its salt, so it is knowable before the proxy exists
     * @param _roycoDayEntryPoint The chain's entry point singleton, deployed before this gatekeeper
     * @param _roycoMarketSyncer The chain's market syncer singleton, deployed before this gatekeeper
     */
    constructor(address _roycoAccessManager, address _roycoFactory, address _roycoDayEntryPoint, address _roycoMarketSyncer) {
        require(
            _roycoAccessManager != address(0) && _roycoFactory != address(0) && _roycoDayEntryPoint != address(0) && _roycoMarketSyncer != address(0),
            NULL_ADDRESS()
        );

        ROYCO_ACCESS_MANAGER = _roycoAccessManager;
        ROYCO_FACTORY = _roycoFactory;
        ROYCO_DAY_ENTRY_POINT = _roycoDayEntryPoint;
        ROYCO_MARKET_SYNCER = _roycoMarketSyncer;
    }

    /// @inheritdoc IRoycoFactoryGatekeeper
    function configureFreshTarget(
        address _target,
        bytes4[] calldata _selectors,
        uint64[] calldata _roleIds
    )
        external
        override(IRoycoFactoryGatekeeper)
        onlyFactory
    {
        uint256 numSelectorsToBind = _selectors.length;
        require(numSelectorsToBind == _roleIds.length, LENGTH_MISMATCH());

        // The protocol's own contracts are never legitimate deployment targets, and a target may be configured exactly once, by the deployment that created it
        _requireNotConfigured(_target);

        // Bind the selectors to the target
        AccessManager accessManager = AccessManager(ROYCO_ACCESS_MANAGER);
        bytes4[] memory selector = new bytes4[](1);
        for (uint256 i; i < numSelectorsToBind; ++i) {
            require(_roleIds[i] != PUBLIC_ROLE && _roleIds[i] != ADMIN_ROLE, ROLE_FORBIDDEN(_roleIds[i]));
            selector[0] = _selectors[i];
            accessManager.setTargetFunctionRole(_target, selector, _roleIds[i]);
        }

        emit FreshTargetConfigured(_target, numSelectorsToBind);
    }

    /// @inheritdoc IRoycoFactoryGatekeeper
    function configureMarketPeriphery(
        address[] calldata _tranches,
        IRoycoDayEntryPoint.TrancheConfig[] calldata _configs,
        address _kernel
    )
        external
        override(IRoycoFactoryGatekeeper)
        onlyFactory
    {
        uint256 numTranches = _tranches.length;
        require(numTranches == _configs.length, LENGTH_MISMATCH());

        for (uint256 i; i < numTranches; ++i) {
            address tranche = _tranches[i];
            require(tranche != address(0), NULL_ADDRESS());
            // A configured tranche carries its market's kernel, so a non-null kernel means this tranche is already live
            require(IRoycoDayEntryPoint(ROYCO_DAY_ENTRY_POINT).getTrancheConfig(tranche).kernel == address(0), TRANCHE_ALREADY_CONFIGURED(tranche));
        }

        IRoycoDayEntryPoint(ROYCO_DAY_ENTRY_POINT).modifyTrancheConfigs(_tranches, _configs);

        // Register the market's kernel on the syncer's batch accounting sync set
        require(!IRoycoMarketSyncer(ROYCO_MARKET_SYNCER).isMarketKernelRegistered(_kernel), KERNEL_ALREADY_REGISTERED(_kernel));
        address[] memory kernels = new address[](1);
        kernels[0] = _kernel;
        IRoycoMarketSyncer(ROYCO_MARKET_SYNCER).addMarketKernels(kernels);

        emit MarketPeripheryConfigured(_kernel, numTranches);
    }

    /// @dev A market deployment may only act on a contract that has never been configured before
    /// @param _subject The address a deployment is asking to configure or to grant a role to
    function _requireNotConfigured(address _subject) private view {
        require(_subject != ROYCO_ACCESS_MANAGER && _subject != ROYCO_FACTORY && _subject != address(this), TARGET_FORBIDDEN(_subject));
        require(!IRoycoAccessManager(ROYCO_ACCESS_MANAGER).wasEverConfigured(_subject), TARGET_ALREADY_CONFIGURED(_subject));
    }
}
