// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { TrancheType } from "../libraries/Types.sol";
import { RoycoVaultTranche } from "./base/RoycoVaultTranche.sol";

/**
 * @title RoycoLiquidityTranche
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Liquidity tranche (LT) share token for Royco Day markets. The LT holds the Balancer BPT of the senior
 *         share paired against a quote stablecoin and earns a liquidity premium out of ST yield.
 * @dev Inherits from RoycoVaultTranche and specifies LIQUIDITY as the tranche type.
 */
contract RoycoLiquidityTranche is RoycoVaultTranche {
    constructor(address _asset, address _kernel) RoycoVaultTranche(_asset, _kernel) { }

    /**
     * @notice Initializes the Royco liquidity tranche.
     * @param _ltParams Deployment parameters including name, symbol, and initial authority for the liquidity tranche.
     */
    function initialize(RoycoTrancheInitParams calldata _ltParams) external initializer {
        __RoycoTranche_init(_ltParams);
    }

    /// @inheritdoc RoycoVaultTranche
    function TRANCHE_TYPE() public pure virtual override(RoycoVaultTranche) returns (TrancheType) {
        return TrancheType.LIQUIDITY;
    }
}
