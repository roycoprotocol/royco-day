// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AssetClaims } from "../libraries/Types.sol";
import { IRoycoVaultTranche } from "./IRoycoVaultTranche.sol";

/**
 * @title IRoycoLiquidityTranche
 * @notice Interface for the liquidity tranche (LT): the standard share-token surface (inherited from IRoycoVaultTranche)
 *         plus the LT-specific multi-asset entrypoints that let an LP enter/exit with the LP token's constituent assets
 *         (ST underlying + quote) directly, plus their previews.
 * @dev The LT's base asset is a market-making LP token; the kernel keeps the specific venue (e.g. the AMM) behind its
 *      own hooks, so this surface stays venue-agnostic.
 */
interface IRoycoLiquidityTranche is IRoycoVaultTranche {
    /// @notice Thrown when a multi-asset deposit is made with zero of both constituent assets (ST underlying and quote)
    error MUST_DEPOSIT_NON_ZERO_ASSETS();

    /// @notice Emitted on a multi-asset LT deposit (ST underlying + quote -> LP token -> LT shares)
    /// @param caller The address that initiated the deposit
    /// @param receiver The address that received the minted LT shares
    /// @param stUnderlying The ST underlying deposited, in ST tranche units
    /// @param quoteAmount The quote asset paired against the minted senior shares
    /// @param trancheAssetsMinted The LT tranche assets (the LP token) minted from the liquidity add and deposited into the LT
    /// @param shares The LT shares minted to the receiver
    event MultiAssetDeposit(
        address indexed caller, address indexed receiver, uint256 stUnderlying, uint256 quoteAmount, uint256 trancheAssetsMinted, uint256 shares
    );

    /// @notice Emitted on a multi-asset LT redemption (LT shares -> LP token -> ST underlying + quote)
    /// @param caller The address that initiated the redemption
    /// @param receiver The address that received the ST underlying and quote
    /// @param owner The address whose LT shares were burned
    /// @param shares The LT shares redeemed
    /// @param stClaims The ST redemption asset claims transferred to the receiver
    /// @param quoteOut The quote transferred to the receiver
    event MultiAssetRedeem(address indexed caller, address indexed receiver, address indexed owner, uint256 shares, AssetClaims stClaims, uint256 quoteOut);

    /**
     * @notice Enters the LT with the LP token's constituent assets: ST underlying + quote
     * @dev Pulls the ST underlying and quote from the caller to the kernel, which mints senior shares, single-sided
     *      adds them with the quote into the liquidity venue to mint the LT tranche assets (LP token), and deposits them into the LT
     * @param _stUnderlying The amount of ST underlying (the senior tranche's base asset) to deposit, in ST tranche units
     * @param _quoteAmount The amount of quote asset to pair against the minted senior shares
     * @param _minStSharesMinted The minimum senior shares the deposited ST underlying must mint (slippage bound against an unfavorable ST share price)
     * @param _minLpTokenOut The minimum LP token the liquidity add must mint (slippage bound against an unfavorable pool state)
     * @param _receiver The address that receives the minted LT shares
     * @return shares The number of LT shares minted to the receiver
     */
    function depositMultiAsset(
        uint256 _stUnderlying,
        uint256 _quoteAmount,
        uint256 _minStSharesMinted,
        uint256 _minLpTokenOut,
        address _receiver
    )
        external
        returns (uint256 shares);

    /**
     * @notice Exits the LT to the LP token's constituent assets: ST underlying + quote
     * @dev The kernel proportionally removes the LP-token slice, redeems the pooled senior shares to ST underlying, and
     *      transfers the ST underlying and quote directly to the receiver. The LT shares are burned afterwards
     * @param _shares The number of LT shares to redeem
     * @param _minQuoteOut The minimum quote to receive (slippage bound)
     * @param _receiver The address that receives the ST underlying and quote
     * @param _owner The address that owns the LT shares being redeemed
     * @return stClaims The ST redemption asset claims transferred to the receiver
     * @return quoteOut The quote transferred to the receiver
     */
    function redeemMultiAsset(
        uint256 _shares,
        uint256 _minQuoteOut,
        address _receiver,
        address _owner
    )
        external
        returns (AssetClaims memory stClaims, uint256 quoteOut);

    /**
     * @notice Previews a multi-asset LT deposit
     * @dev NON-VIEW: the kernel queries the liquidity venue, whose `query*` functions are not `view`. Intended for off-chain `eth_call`
     * @param _stUnderlying The amount of ST underlying to deposit, in ST tranche units
     * @param _quoteAmount The amount of quote asset to pair against the minted senior shares
     * @return shares The LT shares that would be minted
     * @return trancheAssetsMinted The LT tranche assets (LP token) that would be minted from the liquidity add
     */
    function previewDepositMultiAsset(uint256 _stUnderlying, uint256 _quoteAmount) external returns (uint256 shares, uint256 trancheAssetsMinted);

    /**
     * @notice Previews a multi-asset LT redemption
     * @dev NON-VIEW: the kernel queries the liquidity venue, whose `query*` functions are not `view`. Intended for off-chain `eth_call`
     * @param _shares The number of LT shares to redeem
     * @return stClaims The ST redemption asset claims that would be transferred to the receiver
     * @return quoteOut The quote that would be received
     */
    function previewRedeemMultiAsset(uint256 _shares) external returns (AssetClaims memory stClaims, uint256 quoteOut);
}
