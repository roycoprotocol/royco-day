// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;


/**
 * @notice Storage state for Royco Tranche contracts
 * @custom:storage-location erc7201:Royco.storage.RoycoTrancheState
 * @custom:field kernel - The address of the kernel contract handling strategy logic
 * @custom:field asset - The address of the tranche's deposit asset
 * @custom:field marketId - The identifier of the Royco market this tranche is linked to
 */
struct RoycoTrancheState {
    address kernel;
    address asset;
    bytes32 marketId;
}

/**
 * @title RoycoTrancheStorageLib
 * @notice Library for managing Royco Tranche storage using ERC-7201 pattern
 * @dev Provides functions to safely access and modify tranche state
 */
library RoycoTrancheStorageLib {
    /// @dev Storage slot for RoycoTrancheState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoTrancheState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROYCO_TRANCHE_STORAGE_SLOT = 0x25265df6fdb5acadb02f38e62cea4bba666d308120ed42c208a4ef005c50ec00;

    /**
     * @notice Initializes the tranche storage state
     * @dev Sets up all initial parameters and validates fee constraints
     * @param _kernel The address of the kernel contract handling strategy logic
     * @param _asset The address of the tranche's deposit asset
     * @param _marketId The identifier of the Royco market this tranche is linked to
     */
    function __RoycoTranche_init(address _kernel, address _asset, bytes32 _marketId) internal {
        // Set the initial state of the tranche
        RoycoTrancheState storage $ = _getRoycoTrancheStorage();
        $.kernel = _kernel;
        $.asset = _asset;
        $.marketId = _marketId;
    }

    /**
     * @notice Returns a reference to the RoycoTrancheState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage reference to the tranche state
     */
    function _getRoycoTrancheStorage() internal pure returns (RoycoTrancheState storage $) {
        assembly ("memory-safe") {
            $.slot := ROYCO_TRANCHE_STORAGE_SLOT
        }
    }
}
