// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { DispatchMode } from "../../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../../libraries/Units.sol";

/**
 * @title IBalancerV3LiquidityVenue
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Declares the Balancer V3 Vault callbacks the liquidity provider tranche venue logic library encodes and dispatches into
 */
interface IBalancerV3LiquidityVenue {
    /**
     * @notice The liquidity venue initialization parameters
     * @custom:field bptOracle - The manipulation-resistant Balancer V3 pool token (BPT) oracle used to value the liquidity provider tranche
     * @custom:field maxReinvestmentSlippageWAD - The maximum slippage tolerated when single-sided reinvesting the ST shares minted as a liquidity premium into the Balancer V3 Pool, scaled to WAD precision
     */
    struct BalancerV3LiquidityVenueInitParams {
        address bptOracle;
        uint64 maxReinvestmentSlippageWAD;
    }

    /**
     * @notice The namespaced storage for the BalancerV3LiquidityVenue
     * @custom:storage-location erc7201:Royco.storage.BalancerV3LiquidityVenueState
     * @custom:field bptOracle - The manipulation-resistant Balancer V3 pool token (BPT) oracle used to value the liquidity provider tranche assets
     * @custom:field maxReinvestmentSlippageWAD - The maximum slippage tolerated when single-sided reinvesting the liquidity premium ST shares into the BPT, scaled to WAD precision, a reinvestment breaching it is skipped and the premium shares remain idle
     */
    struct BalancerV3LiquidityVenueState {
        address bptOracle;
        uint64 maxReinvestmentSlippageWAD;
    }

    /**
     * @notice Callback that performs the unbalanced BPT mint inside the unlocked Balancer V3 Vault's context
     * @dev Only callable by the Balancer V3 Vault
     * @dev This callback must settle all credit and debt created in the vault's accounting by the end of its execution
     * @dev The kernel supplies the senior tranche shares and quote assets it already holds and receives the minted BPT for the liquidity provider tranche
     * @param _mode The dispatch mode: SIMULATE computes the amounts under the Vault's real semantics and unwinds by reverting with the result instead of settling, EXECUTE settles
     * @param _seniorShares The exact amount of senior tranche shares to add into the pool from this kernel's balance
     * @param _quoteAssets The exact amount of quote assets to add into the pool from this kernel's balance
     * @param _minLPTAssetsOut The minimum BPT (LPT assets) that must be minted, bounding the add's slippage at the Vault
     * @return lptAssets The BPT (LPT assets) minted to this kernel by the add
     * @return lptAssetPrice The value of 1 whole BPT against the post-add pool state, produced only for a preview to cache for the operation (zero when settling)
     */
    function addBalancerV3Liquidity(
        DispatchMode _mode,
        uint256 _seniorShares,
        uint256 _quoteAssets,
        TRANCHE_UNIT _minLPTAssetsOut
    )
        external
        returns (uint256 lptAssets, NAV_UNIT lptAssetPrice);

    /**
     * @notice Callback that performs the proportional BPT unwrap inside the unlocked Balancer V3 Vault's context
     * @dev Only callable by the Balancer V3 Vault
     * @dev This callback must settle all credit and debt created in the vault's accounting by the end of its execution
     * @dev The kernel receives any ST shares withdrawn and is responsible for converting them to the base assets before remitting them to the user
     * @param _mode The dispatch mode: SIMULATE computes the amounts under the Vault's real semantics and unwinds by reverting with the result instead of settling, EXECUTE settles
     * @param _lptAssets The exact BPT amount (LPT assets) to burn from this kernel's balance
     * @param _minSTSharesOut The minimum senior tranche shares that must be withdrawn, bounding the removal's slippage at the Vault
     * @param _minQuoteAssetsOut The minimum quote assets that must be withdrawn, bounding the removal's slippage at the Vault
     * @param _quoteAssetsReceiver The recipient of the quote assets withdrawn
     * @return stShares The senior tranche shares withdrawn back to this kernel by the unwrap
     * @return quoteAssets The quote assets withdrawn directly to the specified receiver
     * @return lptAssetPrice The value of 1 whole BPT against the post-remove pool state, produced only for a preview to cache for the operation (zero when settling)
     */
    function removeBalancerV3Liquidity(
        DispatchMode _mode,
        TRANCHE_UNIT _lptAssets,
        uint256 _minSTSharesOut,
        uint256 _minQuoteAssetsOut,
        address _quoteAssetsReceiver
    )
        external
        returns (uint256 stShares, uint256 quoteAssets, NAV_UNIT lptAssetPrice);
}
