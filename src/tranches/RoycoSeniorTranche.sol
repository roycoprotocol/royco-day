// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IRoycoSeniorTranche } from "../interfaces/IRoycoSeniorTranche.sol";
import { IRoycoVaultTranche } from "../interfaces/IRoycoVaultTranche.sol";
import { TrancheType } from "../libraries/Types.sol";
import { RoycoVaultTranche } from "./base/RoycoVaultTranche.sol";

/**
 * @title RoycoSeniorTranche
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Senior tranche implementation for Royco markets
 */
contract RoycoSeniorTranche is RoycoVaultTranche, IRoycoSeniorTranche {
    /// @notice Initializes the Royco senior tranche
    /// @param _stParams Deployment parameters including name, symbol, initial authority, kernel, and asset for the senior tranche
    function initialize(RoycoTrancheInitParams calldata _stParams) external initializer {
        // Initialize the Royco Senior Tranche
        __RoycoTranche_init(_stParams);
    }

    /// @inheritdoc RoycoVaultTranche
    function TRANCHE_TYPE() public pure virtual override(RoycoVaultTranche, IRoycoVaultTranche) returns (TrancheType) {
        return TrancheType.SENIOR;
    }

    /// @inheritdoc IRoycoSeniorTranche
    function mintLiquidityPremiumShares(uint256 _liquidityPremiumShares)
        external
        virtual
        override(IRoycoSeniorTranche)
        onlyKernel
        returns (uint256 totalTrancheShares)
    {
        address kernel = kernel();

        // Mint the precomputed liquidity premium shares to the kernel, which custodies them for the liquidity provider tranche
        if (_liquidityPremiumShares != 0) _mint(kernel, _liquidityPremiumShares);

        totalTrancheShares = totalSupply();
        emit LiquidityPremiumSharesMinted(kernel, _liquidityPremiumShares, totalTrancheShares);
    }
}
