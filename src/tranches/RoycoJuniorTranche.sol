// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { TrancheType } from "../interfaces/IRoycoVaultTranche.sol";
import { RoycoVaultTranche } from "./base/RoycoVaultTranche.sol";

/**
 * @title RoycoJuniorTranche
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Junior tranche implementation for Royco markets
 * @dev Inherits from RoycoVaultTranche and specifies JUNIOR as the tranche type
 */
contract RoycoJuniorTranche is RoycoVaultTranche {
    constructor(address _asset, address _kernel, bytes32 _marketId) RoycoVaultTranche(_asset, _kernel, _marketId) { }

    /**
     * @notice Initializes the Royco junior tranche
     * @param _jtParams Deployment parameters including name, symbol, kernel, and kernel initialization data for the junior tranche
     */
    function initialize(RoycoTrancheInitParams calldata _jtParams) external initializer {
        // Initialize the Royco Junior Tranche
        __RoycoTranche_init(_jtParams);
    }

    ///@inheritdoc RoycoVaultTranche
    function TRANCHE_TYPE() public pure virtual override(RoycoVaultTranche) returns (TrancheType) {
        return TrancheType.JUNIOR;
    }
}
