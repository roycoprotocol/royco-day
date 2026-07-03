// SPDX-License-Identifier: UNLICENSED
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
    constructor(
        address _asset,
        address _kernel,
        bool _enforceVaultSharesTransferWhitelist,
        address _lens,
        address _hook
    )
        RoycoVaultTranche(_asset, _kernel, _enforceVaultSharesTransferWhitelist, _lens, _hook)
    { }

    /// @notice Initializes the Royco senior tranche
    /// @param _stParams Deployment parameters including name, symbol, and initial authority for the senior tranche
    function initialize(RoycoTrancheInitParams calldata _stParams) external initializer {
        // Initialize the Royco Senior Tranche
        __RoycoTranche_init(_stParams);
    }

    /// @inheritdoc IRoycoSeniorTranche
    function mintLiquidityPremiumShares(
        address _to,
        uint256 _liquidityPremiumShares
    )
        external
        virtual
        override(IRoycoSeniorTranche)
        onlyKernel
        returns (uint256 totalTrancheShares)
    {
        // Mint the precomputed liquidity premium shares to the holder (the kernel custodies them for the liquidity tranche)
        if (_liquidityPremiumShares != 0) _mint(_to, _liquidityPremiumShares);

        totalTrancheShares = totalSupply();
        emit LiquidityPremiumSharesMinted(_to, _liquidityPremiumShares, totalTrancheShares);
    }

    /// @inheritdoc RoycoVaultTranche
    function TRANCHE_TYPE() public pure virtual override(RoycoVaultTranche, IRoycoVaultTranche) returns (TrancheType) {
        return TrancheType.SENIOR;
    }
}
