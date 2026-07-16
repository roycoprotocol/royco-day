// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { TrancheType } from "../libraries/Types.sol";
import { RoycoVaultTranche } from "./base/RoycoVaultTranche.sol";

/**
 * @title RoycoJuniorTranche
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Junior tranche implementation for Royco markets
 */
contract RoycoJuniorTranche is RoycoVaultTranche {
    constructor(address _asset, address _kernel) RoycoVaultTranche(_asset, _kernel) { }

    /// @notice Initializes the Royco junior tranche
    /// @param _jtParams Deployment parameters including name, symbol, and initial authority for the junior tranche
    function initialize(RoycoTrancheInitParams calldata _jtParams) external initializer {
        // Initialize the Royco Junior Tranche
        __RoycoTranche_init(_jtParams);
    }

    /// @inheritdoc RoycoVaultTranche
    function TRANCHE_TYPE() public pure virtual override(RoycoVaultTranche) returns (TrancheType) {
        return TrancheType.JUNIOR;
    }
}
