// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import { IVault } from "../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../../../../../libraries/Units.sol";

/**
 * @title IBalancerV3VenueCallbacks
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Declares the Balancer V3 Vault callbacks the liquidity provider tranche venue logic library encodes and dispatches into
 */
interface IBalancerV3VenueCallbacks {
    /**
     * @notice The immutable liquidity venue configuration a delegatecalled venue logic function needs, carried in from the kernel mixin
     * @custom:field vault - The Balancer V3 Vault the kernel's pool is registered with
     * @custom:field lptAsset - The liquidity provider tranche asset (the Balancer Pool Token) the kernel custodies
     * @custom:field seniorTranche - The senior tranche share token, one of the pool's two constituents
     * @custom:field quoteAsset - The quote asset, the pool's other constituent
     * @custom:field stSharePoolIndex - The senior tranche share token's index in the pool's token registration order
     * @custom:field quoteAssetPoolIndex - The quote asset's index in the pool's token registration order
     */
    struct BalancerV3VenueImmutableState {
        IVault vault;
        address lptAsset;
        address seniorTranche;
        address quoteAsset;
        uint256 stSharePoolIndex;
        uint256 quoteAssetPoolIndex;
    }

    /**
     * @notice Callback that performs the unbalanced BPT mint inside the unlocked Balancer V3 Vault's context
     * @dev Only callable by the Balancer V3 Vault
     * @dev This callback must settle all credit and debt created in the vault's accounting by the end of its execution
     * @dev The kernel supplies the senior tranche shares and quote assets it already holds and receives the minted BPT for the liquidity provider tranche
     * @param _isPreview Whether this is a preview, which computes the amounts under the Vault's real semantics and unwinds by reverting with the result instead of settling
     * @param _seniorShares The exact amount of senior tranche shares to add into the pool from this kernel's balance
     * @param _quoteAssets The exact amount of quote assets to add into the pool from this kernel's balance
     * @param _minLPTAssetsOut The minimum BPT (LPT assets) that must be minted, bounding the add's slippage at the Vault
     * @return lptAssets The BPT (LPT assets) minted to this kernel by the add
     * @return depositNAV The value of the minted BPT against the post-add pool state, denominated in the kernel's NAV units
     * @return postOpLPTRawNAV The post-op LPT raw NAV marked against the post-add pool state, the mark the post-op sync enforces at
     */
    function addBalancerV3Liquidity(
        bool _isPreview,
        uint256 _seniorShares,
        uint256 _quoteAssets,
        TRANCHE_UNIT _minLPTAssetsOut
    )
        external
        returns (uint256 lptAssets, NAV_UNIT depositNAV, NAV_UNIT postOpLPTRawNAV);

    /**
     * @notice Callback that performs the proportional BPT unwrap inside the unlocked Balancer V3 Vault's context
     * @dev Only callable by the Balancer V3 Vault
     * @dev This callback must settle all credit and debt created in the vault's accounting by the end of its execution
     * @dev The kernel receives any ST shares withdrawn and is responsible for converting them to the base assets before remitting them to the user
     * @param _isPreview Whether this is a preview, which computes the amounts under the Vault's real semantics and unwinds by reverting with the result instead of settling
     * @param _lptAssets The exact BPT amount (LPT assets) to burn from this kernel's balance
     * @param _minSTSharesOut The minimum senior tranche shares that must be withdrawn, bounding the removal's slippage at the Vault
     * @param _minQuoteAssetsOut The minimum quote assets that must be withdrawn, bounding the removal's slippage at the Vault
     * @param _quoteAssetsReceiver The recipient of the quote assets withdrawn
     * @return stShares The senior tranche shares withdrawn back to this kernel by the unwrap
     * @return quoteAssets The quote assets withdrawn directly to the specified receiver
     * @return postOpLPTRawNAV The post-op LPT raw NAV marked against the post-remove pool state, the mark the post-op sync enforces at
     */
    function removeBalancerV3Liquidity(
        bool _isPreview,
        TRANCHE_UNIT _lptAssets,
        uint256 _minSTSharesOut,
        uint256 _minQuoteAssetsOut,
        address _quoteAssetsReceiver
    )
        external
        returns (uint256 stShares, uint256 quoteAssets, NAV_UNIT postOpLPTRawNAV);
}
