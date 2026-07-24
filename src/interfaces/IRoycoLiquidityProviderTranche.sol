// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { AssetClaims } from "../libraries/Types.sol";
import { IRoycoVaultTranche } from "./IRoycoVaultTranche.sol";

/**
 * @title IRoycoLiquidityProviderTranche
 * @notice Interface for the liquidity provider tranche (LPT): the standard share-token surface (inherited from IRoycoVaultTranche)
 *         plus the LPT-specific multi-asset entrypoints that let an LP enter/exit with the LP token's constituent assets
 *         (collateral + quote) directly
 * @dev The LPT's base asset is a market-making LP token, the kernel keeps the specific venue (e.g. the AMM) behind its
 *      own hooks, so this surface stays venue-agnostic
 */
interface IRoycoLiquidityProviderTranche is IRoycoVaultTranche {
    /**
     * @notice Emitted on a multi-asset LPT deposit (collateral + quote -> LP token -> LPT shares)
     * @param caller The address that initiated the deposit
     * @param receiver The address that received the minted LPT shares
     * @param collateralAssets The collateral deposited for the senior leg, denominated in the collateral asset's native units
     * @param quoteAssets The quote asset paired against the minted senior shares
     * @param lptAssetsMinted The LPT tranche assets (the LP token) minted from the liquidity add and deposited into the LPT
     * @param shares The number of LPT shares minted to the receiver
     */
    event MultiAssetDeposit(
        address indexed caller, address indexed receiver, uint256 collateralAssets, uint256 quoteAssets, uint256 lptAssetsMinted, uint256 shares
    );

    /**
     * @notice Emitted on a multi-asset LPT redemption (LPT shares -> LP token -> collateral + quote)
     * @param caller The address that initiated the redemption
     * @param receiver The address that received the collateral and quote
     * @param owner The address whose LPT shares were burned
     * @param shares The number of LPT shares redeemed
     * @param stClaims The ST redemption asset claims transferred to the receiver
     * @param quoteAssets The quote transferred to the receiver
     */
    event MultiAssetRedeem(address indexed caller, address indexed receiver, address indexed owner, uint256 shares, AssetClaims stClaims, uint256 quoteAssets);

    /**
     * @notice Enters the LPT with the LP token's constituent assets: collateral + quote
     * @dev Pulls the collateral and quote from the caller to the kernel, which mints senior shares, adds them
     *      together with the quote into the liquidity venue to mint the LPT tranche assets (LP token), and deposits them into the LPT
     * @param _collateralAssets The amount of collateral to deposit for the senior leg, denominated in the collateral asset's native units
     * @param _quoteAssets The amount of quote asset to pair against the minted senior shares
     * @param _minLPTAssetsOut The minimum LP token the liquidity add must mint (slippage bound against an unfavorable pool state), denominated in the LPT asset's native units
     * @param _receiver The address that receives the minted LPT shares
     * @return shares The number of LPT shares minted to the receiver
     * @return lptAssetsOut The LPT tranche assets (the LP token) minted by the liquidity add and deposited into the LPT, denominated in the LPT asset's native units
     */
    function depositMultiAsset(
        uint256 _collateralAssets,
        uint256 _quoteAssets,
        uint256 _minLPTAssetsOut,
        address _receiver
    )
        external
        returns (uint256 shares, uint256 lptAssetsOut);

    /**
     * @notice Exits the LPT to the LP token's constituent assets: collateral + quote
     * @dev The kernel proportionally removes the LP-token slice, redeems the pooled senior shares to collateral, and
     *      transfers the collateral and quote directly to the receiver, the LPT shares are burned afterwards
     * @param _shares The number of LPT shares to redeem
     * @param _minSTSharesOut The minimum senior tranche shares the proportional removal must yield (slippage bound)
     * @param _minQuoteAssetsOut The minimum quote to receive (slippage bound)
     * @param _receiver The address that receives the collateral and quote
     * @param _owner The address that owns the LPT shares being redeemed
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
     * @notice Previews a multi-asset LPT deposit of (collateral + quote): the LPT shares it would mint and the LPT tranche assets the add would produce
     * @dev NON-VIEW: routes the deposit through its execute-and-revert simulation, which mutates no state net
     * @dev The quote is produced by the actual kernel multi-asset deposit path, so any revert the deposit would raise bubbles unchanged
     * @param _collateralAssets The collateral leg, denominated in the collateral asset's native units
     * @param _quoteAssets The quote asset leg
     * @return shares The LPT shares that would be minted to a receiver
     * @return lptAssetsOut The LPT tranche assets the liquidity add would mint, denominated in the LPT asset's native units
     */
    function previewDepositMultiAsset(uint256 _collateralAssets, uint256 _quoteAssets) external returns (uint256 shares, uint256 lptAssetsOut);

    /**
     * @notice Previews a multi-asset LPT redemption of _shares: the collateral claims and quote it would yield
     * @dev NON-VIEW: routes the redemption through its execute-and-revert simulation, which mutates no state net
     * @dev The quote is produced by the actual kernel multi-asset redemption path, so any revert the redemption would raise bubbles unchanged
     * @param _shares The number of LPT shares to redeem
     * @return stClaims The ST redemption asset claims that would be transferred to the receiver
     * @return quoteAssets The quote assets that would be transferred to the receiver
     */
    function previewRedeemMultiAsset(uint256 _shares) external returns (AssetClaims memory stClaims, uint256 quoteAssets);

    /**
     * @notice Returns the maximum number of LPT shares that can be redeemed from the specified owner's balance via a multi-asset redemption
     * @dev A multi-asset redemption redeems its senior tranche share legs in-flow, shrinking the market's liquidity requirement
     *      alongside the withdrawal, so this bound is at least maxRedeem, and strictly exceeds it whenever the liquidity
     *      requirement binds and the removal's senior-share legs carry value
     * @dev NON-VIEW: sizes the requirement reduction through the venue removal's execute-and-revert preview, which mutates no state net
     * @param _owner The address that owns the LPT shares being redeemed
     * @return shares The maximum number of LPT shares that can be redeemed multi-asset
     */
    function maxRedeemMultiAsset(address _owner) external returns (uint256 shares);
}
