// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { AssetClaims } from "../libraries/Types.sol";
import { IRoycoVaultTranche } from "./IRoycoVaultTranche.sol";

/**
 * @title IRoycoLiquidityTranche
 * @notice Interface for the liquidity tranche (LT): the standard share-token surface (inherited from IRoycoVaultTranche)
 *         plus the LT-specific multi-asset entrypoints that let an LP enter/exit with the LP token's constituent assets
 *         (ST underlying + quote) directly
 * @dev The LT's base asset is a market-making LP token, the kernel keeps the specific venue (e.g. the AMM) behind its
 *      own hooks, so this surface stays venue-agnostic
 */
interface IRoycoLiquidityTranche is IRoycoVaultTranche {
    /// @notice Thrown when a multi-asset deposit is made with zero of both constituent assets (ST underlying and quote)
    error MUST_DEPOSIT_NON_ZERO_ASSETS();

    /**
     * @notice Emitted on a multi-asset LT deposit (ST underlying + quote -> LP token -> LT shares)
     * @param caller The address that initiated the deposit
     * @param receiver The address that received the minted LT shares
     * @param stAssets The ST underlying deposited, denominated in the ST asset's native units
     * @param quoteAssets The quote asset paired against the minted senior shares
     * @param ltAssetsMinted The LT tranche assets (the LP token) minted from the liquidity add and deposited into the LT
     * @param shares The number of LT shares minted to the receiver
     */
    event MultiAssetDeposit(address indexed caller, address indexed receiver, uint256 stAssets, uint256 quoteAssets, uint256 ltAssetsMinted, uint256 shares);

    /**
     * @notice Emitted on a multi-asset LT redemption (LT shares -> LP token -> ST underlying + quote)
     * @param caller The address that initiated the redemption
     * @param receiver The address that received the ST underlying and quote
     * @param owner The address whose LT shares were burned
     * @param shares The number of LT shares redeemed
     * @param stClaims The ST redemption asset claims transferred to the receiver
     * @param quoteAssets The quote transferred to the receiver
     */
    event MultiAssetRedeem(address indexed caller, address indexed receiver, address indexed owner, uint256 shares, AssetClaims stClaims, uint256 quoteAssets);

    /**
     * @notice Enters the LT with the LP token's constituent assets: ST underlying + quote
     * @dev Pulls the ST underlying and quote from the caller to the kernel, which mints senior shares, adds them
     *      together with the quote into the liquidity venue to mint the LT tranche assets (LP token), and deposits them into the LT
     * @param _stAssets The amount of ST underlying (the senior tranche's base asset) to deposit, denominated in the ST asset's native units
     * @param _quoteAssets The amount of quote asset to pair against the minted senior shares
     * @param _minLTAssetsOut The minimum LP token the liquidity add must mint (slippage bound against an unfavorable pool state), denominated in the LT asset's native units
     * @param _receiver The address that receives the minted LT shares
     * @return shares The number of LT shares minted to the receiver
     */
    function depositMultiAsset(uint256 _stAssets, uint256 _quoteAssets, uint256 _minLTAssetsOut, address _receiver) external returns (uint256 shares);

    /**
     * @notice Previews a multi-asset LT deposit of (ST underlying + quote): the LT shares it would mint
     * @dev NON-VIEW: simulates the venue add by executing it and unwinding via a result-carrying revert, mutating no state net
     * @param _stAssets The ST underlying leg, denominated in the ST asset's native units
     * @param _quoteAssets The quote asset leg
     * @return shares The LT shares that would be minted to a receiver
     */
    function previewDepositMultiAsset(uint256 _stAssets, uint256 _quoteAssets) external returns (uint256 shares);

    /**
     * @notice Returns the maximum number of LT shares that can be redeemed from the specified owner's balance via a multi-asset redemption
     * @dev A multi-asset redemption redeems its senior tranche share legs in-flow, shrinking the market's liquidity requirement
     *      alongside the withdrawal, so this bound is at least maxRedeem, and strictly exceeds it whenever the liquidity
     *      requirement binds and the removal's senior-share legs carry value
     * @dev NON-VIEW: sizes the requirement reduction through the venue removal's execute-and-revert preview, which mutates no state net
     * @param _owner The address that owns the LT shares being redeemed
     * @return shares The maximum number of LT shares that can be redeemed multi-asset
     */
    function maxRedeemMultiAsset(address _owner) external returns (uint256 shares);

    /**
     * @notice Exits the LT to the LP token's constituent assets: ST underlying + quote
     * @dev The kernel proportionally removes the LP-token slice, redeems the pooled senior shares to ST underlying, and
     *      transfers the ST underlying and quote directly to the receiver, the LT shares are burned afterwards
     * @param _shares The number of LT shares to redeem
     * @param _minSTSharesOut The minimum senior tranche shares the proportional removal must yield (slippage bound)
     * @param _minQuoteAssetsOut The minimum quote to receive (slippage bound)
     * @param _receiver The address that receives the ST underlying and quote
     * @param _owner The address that owns the LT shares being redeemed
     * @return stClaims The ST redemption asset claims transferred to the receiver
     * @return quoteAssets The quote transferred to the receiver
     */
    function redeemMultiAsset(
        uint256 _shares,
        uint256 _minSTSharesOut,
        uint256 _minQuoteAssetsOut,
        address _receiver,
        address _owner
    )
        external
        returns (AssetClaims memory stClaims, uint256 quoteAssets);

    /**
     * @notice Previews a multi-asset LT redemption of _shares: the ST underlying claims and quote it would yield
     * @dev NON-VIEW: simulates the venue removal by executing it and unwinding via a result-carrying revert, mutating no state net
     * @param _shares The number of LT shares to redeem
     * @return stClaims The ST redemption asset claims that would be transferred to the receiver
     * @return quoteAssets The quote assets that would be transferred to the receiver
     */
    function previewRedeemMultiAsset(uint256 _shares) external returns (AssetClaims memory stClaims, uint256 quoteAssets);
}
