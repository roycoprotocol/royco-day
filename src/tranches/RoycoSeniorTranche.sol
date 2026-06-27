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
 * @dev Inherits from RoycoVaultTranche and specifies SENIOR as the tranche type
 * @dev Carries the senior-specific liquidity premium share mint (IRoycoSeniorTranche): the premium is senior yield
 *      reassigned to the liquidity tranche, so it is paid as newly minted senior shares
 */
contract RoycoSeniorTranche is RoycoVaultTranche, IRoycoSeniorTranche {
    constructor(address _asset, address _kernel) RoycoVaultTranche(_asset, _kernel) { }

    /**
     * @notice Initializes the Royco senior tranche
     * @param _stParams Deployment parameters including name, symbol, and initial authority for the senior tranche
     */
    function initialize(RoycoTrancheInitParams calldata _stParams) external initializer {
        // Initialize the Royco Senior Tranche
        __RoycoTranche_init(_stParams);
    }

    /// @inheritdoc RoycoVaultTranche
    function TRANCHE_TYPE() public pure virtual override(RoycoVaultTranche, IRoycoVaultTranche) returns (TrancheType) {
        return TrancheType.SENIOR;
    }

    /// @inheritdoc IRoycoVaultTranche
    function burn(uint256 _shares) public override(RoycoVaultTranche, IRoycoVaultTranche) {
        super.burn(_shares);
    }

    /// @inheritdoc IRoycoVaultTranche
    function burnFrom(address _account, uint256 _shares) public override(RoycoVaultTranche, IRoycoVaultTranche) {
        super.burnFrom(_account, _shares);
    }

    /// @inheritdoc IRoycoSeniorTranche
    function mintLiquidityPremiumShares(
        address _to,
        uint256 _liquidityPremiumShares
    )
        external
        virtual
        override(IRoycoSeniorTranche)
        returns (uint256 totalTrancheShares)
    {
        // Only the kernel can mint liquidity premium shares based on a sync
        require(msg.sender == KERNEL, ONLY_KERNEL());

        // Mint the precomputed liquidity premium shares to the holder (the kernel custodies them for the liquidity tranche)
        if (_liquidityPremiumShares != 0) _mint(_to, _liquidityPremiumShares);

        totalTrancheShares = totalSupply();
        emit LiquidityPremiumSharesMinted(_to, _liquidityPremiumShares, totalTrancheShares);
    }
}
