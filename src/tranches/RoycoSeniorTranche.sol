// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { TrancheType } from "../libraries/Types.sol";
import { RoycoVaultTranche } from "./base/RoycoVaultTranche.sol";

/**
 * @title RoycoSeniorTranche
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Senior tranche implementation for Royco markets
 * @dev Inherits from RoycoVaultTranche and specifies SENIOR as the tranche type
 */
contract RoycoSeniorTranche is RoycoVaultTranche {
    constructor(address _asset, address _kernel, bytes32 _marketId) RoycoVaultTranche(_asset, _kernel, _marketId) { }

    /**
     * @notice Initializes the Royco senior tranche
     * @param _stParams Deployment parameters including name, symbol, kernel, and kernel initialization data for the senior tranche
     */
    function initialize(RoycoTrancheInitParams calldata _stParams) external initializer {
        // Initialize the Royco Senior Tranche
        __RoycoTranche_init(_stParams);
    }

    /// @inheritdoc RoycoVaultTranche
    function TRANCHE_TYPE() public pure virtual override(RoycoVaultTranche) returns (TrancheType) {
        return TrancheType.SENIOR;
    }
}
