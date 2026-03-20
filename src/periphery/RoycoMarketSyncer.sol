// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { EnumerableSet } from "../../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import { RoycoBase } from "../base/RoycoBase.sol";
import { IRoycoFactory } from "../interfaces/IRoycoFactory.sol";
import { IRoycoKernel } from "../interfaces/IRoycoKernel.sol";
import { IRoycoVaultTranche } from "../interfaces/IRoycoVaultTranche.sol";

/**
 * @title RoycoMarketSyncer
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Periphery contract enabling batch NAV accounting synchronization across multiple Royco markets
 * @dev Only kernels deployed by the canonical Royco Factory can be registered with this syncer
 */
contract RoycoMarketSyncer is RoycoBase {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev Storage slot for RoycoMarketSyncerState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoMarketSyncerState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROYCO_MARKET_SYNCER_STORAGE_SLOT = 0x65f8145c32d6f7d600ded0f23ff9c2c2e262c975a2f7552b5c41fcd203e2aa00;

    /// @dev The calldata for synchronizing NAV accounting for Royco markets
    bytes private constant ACCOUNTING_SYNC_CALLDATA = abi.encodeCall(IRoycoKernel.syncTrancheAccounting, ());

    /// @notice Storage state for the Royco market syncer
    /// @custom:field marketKernels An enumerable set of the configured market kernels
    struct RoycoMarketSyncerState {
        EnumerableSet.AddressSet marketKernels;
    }

    /// @notice Emitted when a market kernel is added to the syncer
    /// @param kernel The address of the market kernel that was added
    event MarketKernelAdded(address indexed kernel);

    /// @notice Emitted when a market kernel is removed from the syncer
    /// @param kernel The address of the market kernel that was removed
    event MarketKernelRemoved(address indexed kernel);

    /**
     * @notice Emitted when an accounting sync fails for a kernel
     * @param kernel The address of the market kernel that failed to sync
     * @param errorData The error data returned by the failed sync call
     */
    event AccountingSyncFailed(address indexed kernel, bytes errorData);

    /// @notice Thrown when attempting to add a kernel that was not deployed by the canonical RoycoFactory
    /// @param kernel The address of the invalid kernel
    error INVALID_KERNEL(address kernel);

    /// @notice Thrown when attempting to add a kernel that is already registered with this syncer
    /// @param kernel The address of the kernel that already exists
    error KERNEL_ALREADY_EXISTS(address kernel);

    /// @notice Thrown when attempting to remove a kernel that is not registered with this syncer
    /// @param kernel The address of the kernel that does not exist
    error KERNEL_DOES_NOT_EXISTS(address kernel);

    /**
     * @notice Initializes the market syncer state
     * @param _roycoFactory The canonical Royco factory responsible for deploying markets and acting as the singleton access manager
     * @param _marketKernels The initial kernels that this syncer will synchronize NAV accounting for
     */
    function initialize(address _roycoFactory, address[] calldata _marketKernels) external initializer {
        // Initialize the base syncer state
        __RoycoBase_init(_roycoFactory);
        // Initialize the syncer state with the market kernels
        _modifyMarketKernels(true, _marketKernels);
    }

    /**
     * @notice Executes a batch NAV accounting synchronization across all registered market kernels
     * @dev Iterates through all registered kernels and calls syncTrancheAccounting on each
     * @dev Uses low-level calls to gracefully handle reversions
     * @param _tolerateReversions A boolean indicating whether to tolerate downstream reversions or propograte them upstream
     */
    function executeBatchAccountingSync(bool _tolerateReversions) external whenNotPaused restricted {
        // Execute the NAV synchronization for each registered kernel
        RoycoMarketSyncerState storage $ = _getRoycoMarketSyncerStorage();
        uint256 numKernels = $.marketKernels.length();
        for (uint256 i = 0; i < numKernels; ++i) {
            address marketKernel = $.marketKernels.at(i);
            (bool syncSucceeded, bytes memory returnData) = marketKernel.call(ACCOUNTING_SYNC_CALLDATA);
            // If the sync reverted, handle it according to the tolerance specified
            if (!syncSucceeded) {
                emit AccountingSyncFailed(marketKernel, returnData);
                if (!_tolerateReversions) assembly ("memory-safe") { revert(add(returnData, 32), mload(returnData)) }
            }
        }
    }

    /**
     * @notice Adds new market kernels to the syncer
     * @dev Each kernel is validated to ensure it was deployed by the canonical Royco Factory before being added
     * @param _marketKernels The market kernels to add to the sync batch
     */
    function addMarketKernels(address[] calldata _marketKernels) external whenNotPaused restricted {
        _modifyMarketKernels(true, _marketKernels);
    }

    /**
     * @notice Removes market kernels from the syncer
     * @param _marketKernels The market kernels to remove from the sync batch
     */
    function removeMarketKernels(address[] calldata _marketKernels) external whenNotPaused restricted {
        _modifyMarketKernels(false, _marketKernels);
    }

    /// @notice Returns the kernels that are currently registered with this syncer
    function getMarketKernels() public view returns (address[] memory) {
        return _getRoycoMarketSyncerStorage().marketKernels.values();
    }

    /**
     * @notice Adds or removes market kernels from the syncer
     * @dev Validates each kernel before addition to ensure it was deployed by the canonical Royco Factory
     * @param _isAddition A boolean indicating whether to add or remove the specified kernels from the syncer
     * @param _marketKernels The market kernels to add or remove
     */
    function _modifyMarketKernels(bool _isAddition, address[] calldata _marketKernels) internal {
        // Execute the addition or removal of kernels
        RoycoMarketSyncerState storage $ = _getRoycoMarketSyncerStorage();
        uint256 numKernels = _marketKernels.length;
        for (uint256 i = 0; i < numKernels; ++i) {
            address marketKernel = _marketKernels[i];
            // If this is an addition, validate that the kernel was deployed by the Royco factory and add it if it doesn't exist
            if (_isAddition) {
                _validateMarketKernel(marketKernel);
                require($.marketKernels.add(marketKernel), KERNEL_ALREADY_EXISTS(marketKernel));
                emit MarketKernelAdded(marketKernel);
            }
            // If this is a removal, remove the kernel if it exists
            else {
                require($.marketKernels.remove(marketKernel), KERNEL_DOES_NOT_EXISTS(marketKernel));
                emit MarketKernelRemoved(marketKernel);
            }
        }
    }

    /**
     * @notice Validates that a market kernel was deployed by the canonical Royco Factory
     * @dev Queries the kernel's senior tranche and verifies the factory mapping to ensure authenticity
     * @param _ostensibleMarketKernel The address of the ostensible market kernel to validate
     */
    function _validateMarketKernel(address _ostensibleMarketKernel) internal view {
        // Ensure that the kernel isn't the null address
        require(_ostensibleMarketKernel != address(0), NULL_ADDRESS());

        // Get the senior tranche for this kernel from the kernel itself and the corresponding junior tranche from the canonical factory mapping
        address seniorTranche = IRoycoKernel(_ostensibleMarketKernel).SENIOR_TRANCHE();
        address juniorTranche = IRoycoFactory(authority()).seniorTrancheToJuniorTranche(seniorTranche);

        // Ensure that the kernel was deployed by the Royco factory
        require(juniorTranche != address(0) && _ostensibleMarketKernel == IRoycoVaultTranche(seniorTranche).KERNEL(), INVALID_KERNEL(_ostensibleMarketKernel));
    }

    /**
     * @notice Returns a storage pointer to the RoycoMarketSyncerState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer to the kernel's state
     */
    function _getRoycoMarketSyncerStorage() internal pure returns (RoycoMarketSyncerState storage $) {
        assembly ("memory-safe") {
            $.slot := ROYCO_MARKET_SYNCER_STORAGE_SLOT
        }
    }
}
