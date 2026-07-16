// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { TRANCHE_UNIT } from "../../../../../../libraries/Units.sol";

/**
 * @title IBalancerV3VenueCallbacks
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Declares the Balancer V3 Vault callbacks the liquidity tranche venue logic library encodes and dispatches into
 */
interface IBalancerV3VenueCallbacks {
    /**
     * @notice Callback that performs the unbalanced BPT mint inside the unlocked Balancer V3 Vault's context
     * @dev Only callable by the Balancer V3 Vault
     * @dev This callback must settle all credit and debt created in the vault's accounting by the end of its execution
     * @dev The kernel supplies the senior tranche shares and quote assets it already holds and receives the minted BPT for the liquidity tranche
     * @param _isPreview Whether this is a preview, which computes the amounts under the Vault's real semantics and unwinds by reverting with the result instead of settling
     * @param _seniorShares The exact amount of senior tranche shares to add into the pool from this kernel's balance
     * @param _quoteAssets The exact amount of quote assets to add into the pool from this kernel's balance
     * @param _minLTAssetsOut The minimum BPT (LT assets) that must be minted, bounding the add's slippage at the Vault
     * @return ltAssets The BPT (LT assets) minted to this kernel by the add
     */
    function addBalancerV3Liquidity(
        bool _isPreview,
        uint256 _seniorShares,
        uint256 _quoteAssets,
        TRANCHE_UNIT _minLTAssetsOut
    )
        external
        returns (uint256 ltAssets);

    /**
     * @notice Callback that performs the proportional BPT unwrap inside the unlocked Balancer V3 Vault's context
     * @dev Only callable by the Balancer V3 Vault
     * @dev This callback must settle all credit and debt created in the vault's accounting by the end of its execution
     * @dev The kernel receives any ST shares withdrawn and is responsible for converting them to the base assets before remitting them to the user
     * @param _isPreview Whether this is a preview, which computes the amounts under the Vault's real semantics and unwinds by reverting with the result instead of settling
     * @param _ltAssets The exact BPT amount (LT assets) to burn from this kernel's balance
     * @param _minSTSharesOut The minimum senior tranche shares that must be withdrawn, bounding the removal's slippage at the Vault
     * @param _minQuoteAssetsOut The minimum quote assets that must be withdrawn, bounding the removal's slippage at the Vault
     * @param _quoteAssetsReceiver The recipient of the quote assets withdrawn
     * @return stShares The senior tranche shares withdrawn back to this kernel by the unwrap
     * @return quoteAssets The quote assets withdrawn directly to the specified receiver
     */
    function removeBalancerV3Liquidity(
        bool _isPreview,
        TRANCHE_UNIT _ltAssets,
        uint256 _minSTSharesOut,
        uint256 _minQuoteAssetsOut,
        address _quoteAssetsReceiver
    )
        external
        returns (uint256 stShares, uint256 quoteAssets);
}
