// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { AssetClaims, TrancheType } from "../../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../../libraries/Units.sol";
import { IRoycoAsyncCancellableVault } from "./IRoycoAsyncCancellableVault.sol";
import { IRoycoAsyncVault } from "./IRoycoAsyncVault.sol";

interface IRoycoVaultTranche is IERC20Metadata, IRoycoAsyncVault, IRoycoAsyncCancellableVault {
    /**
     * @notice Emitted when a deposit is made
     * @param sender The address that made the deposit
     * @param owner The address that owns the shares
     * @param assets The amount of assets deposited
     * @param shares The amount of shares minted
     * @param depositRequestId The deposit request identifier if the deposit is asynchronous. Ignore if the deposit is synchronous.
     * @param metadata The format prefixed metadata of the deposit or empty bytes if no metadata is shared
     */
    event Deposit(address indexed sender, address indexed owner, TRANCHE_UNIT assets, uint256 shares, uint256 depositRequestId, bytes metadata);

    /**
     * @notice Emitted when a redemption is made
     * @param sender The address that made the redemption
     * @param receiver The address of the receiver of the redeemed assets
     * @param claims A struct representing the assets received on redemption and their value at the time of redemption in NAV units
     * @param shares The total amount of shares redeemed
     * @param redemptionRequestId The redemption request identifier if the redemption is asynchronous. Ignore if the redemption is synchronous.
     * @param metadata The format prefixed metadata of the redemption or empty bytes if no metadata is shared
     */
    event Redeem(address indexed sender, address indexed receiver, AssetClaims claims, uint256 shares, uint256 redemptionRequestId, bytes metadata);

    /**
     * @notice Emitted when protocol fee shares are minted to the protocol fee recipient
     * @param protocolFeeRecipient The address that received the protocol fee shares
     * @param mintedProtocolFeeShares The number of protocol fee shares that were minted
     * @param totalTrancheShares The total number of shares that exist in the tranche after minting any protocol fee shares post-sync
     */
    event ProtocolFeeSharesMinted(address indexed protocolFeeRecipient, uint256 mintedProtocolFeeShares, uint256 totalTrancheShares);

    /// @notice Thrown when the address being checked is the null address
    error NULL_ADDRESS();

    /// @notice Thrown when the specified action is disabled
    error DISABLED();

    /// @notice Thrown when the caller is not the expected account or an approved operator
    error ONLY_CALLER_OR_OPERATOR();

    /// @notice Thrown when the redeem amount is zero
    error MUST_REQUEST_NON_ZERO_SHARES();

    /// @notice Thrown when the deposit amount is zero
    error MUST_DEPOSIT_NON_ZERO_ASSETS();

    /// @notice Thrown when the redeem amount is zero
    error MUST_CLAIM_NON_ZERO_SHARES();

    /// @notice Thrown when the caller isn't the kernel
    error ONLY_KERNEL();

    /// @notice Thrown when the value allocated is zero
    error INVALID_VALUE_ALLOCATED();

    /// @notice Thrown when trying to set an operator when neither flow is async
    error DEPOSIT_OR_REDEEM_MUST_BE_ASYNC();

    /**
     * @notice Returns the raw net asset value of the tranche's invested assets
     * @dev Excludes yield splits, coverage applications, etc.
     * @dev The NAV is expressed in the tranche's base asset
     * @return nav The raw net asset value of the tranche's invested assets
     */
    function getRawNAV() external view returns (NAV_UNIT nav);

    /**
     * @notice Returns the address of the kernel contract handling strategy logic
     */
    function kernel() external view returns (address);

    /**
     * @notice Returns the identifier of the Royco market this tranche is linked to
     */
    function marketId() external view returns (bytes32);

    /**
     * @notice Returns the total effective assets in the tranche's NAV units
     * @dev Includes yield splits, coverage applications, etc.
     * @dev The NAV is expressed in the tranche's base asset
     * @return claims The breakdown of assets that represent the value of the tranche's shares
     */
    function totalAssets() external view returns (AssetClaims memory claims);

    /**
     * @notice Returns the maximum amount of assets that can be deposited into the tranche
     * @dev The assets are expressed in the tranche's base asset
     * @param _receiver The address to receive the deposited assets
     * @return assets The maximum amount of assets that can be deposited into the tranche
     */
    function maxDeposit(address _receiver) external view returns (TRANCHE_UNIT assets);

    /**
     * @notice Returns the maximum amount of shares that can be redeemed from the tranche
     * @dev The shares are expressed in the tranche's base asset
     * @param _owner The address to redeem the shares from
     * @return shares The maximum amount of shares that can be redeemed from the tranche
     */
    function maxRedeem(address _owner) external view returns (uint256 shares);

    /**
     * @notice Returns the number of shares that would be minted for a given amount of assets
     * @dev The assets are expressed in the tranche's base asset
     * @dev Disabled if deposit execution is asynchronous
     * @param _assets The amount of assets to preview the deposit for
     * @return shares The number of shares that would be minted for a given amount of assets
     */
    function previewDeposit(TRANCHE_UNIT _assets) external view returns (uint256 shares);

    /**
     * @notice Returns the number of shares that would be minted for a given amount of assets
     * @dev The assets are expressed in the tranche's base asset
     * @param _assets The amount of assets to convert to shares
     * @return shares The number of shares that would be minted for a given amount of assets
     */
    function convertToShares(TRANCHE_UNIT _assets) external view returns (uint256 shares);

    /**
     * @notice Returns the breakdown of assets that the shares have a claim on
     * @dev The shares are expressed in the tranche's base asset
     * @dev Disabled if redemption execution is asynchronous
     * @param _shares The number of shares to convert to claims
     * @return claims The breakdown of assets that the shares have a claim on
     */
    function previewRedeem(uint256 _shares) external view returns (AssetClaims memory claims);

    /**
     * @notice Returns the breakdown of assets that the shares have a claim on
     * @dev The shares are expressed in the tranche's base asset
     * @param _shares The number of shares to convert to assets
     * @return claims The breakdown of assets that the shares have a claim on
     */
    function convertToAssets(uint256 _shares) external view returns (AssetClaims memory claims);

    /**
     * @notice Returns the type of the tranche
     * @return The type of the tranche
     */
    function TRANCHE_TYPE() external view returns (TrancheType);

    /**
     * @notice Mints tranche shares to the receiver
     * @dev The assets are expressed in the tranche's base asset
     * @param _assets The amount of assets to mint
     * @param _receiver The address to mint the shares to
     * @param _controller The controller of the request
     * @return shares The number of shares that were minted
     * @return metadata The format prefixed metadata of the deposit or empty bytes if no metadata is shared
     */
    function deposit(TRANCHE_UNIT _assets, address _receiver, address _controller) external returns (uint256 shares, bytes memory metadata);

    /**
     * @notice Redeems tranche shares from the owner
     * @dev The shares are expressed in the tranche's base asset
     * @param _shares The number of shares to redeem
     * @param _receiver The address to redeem the shares to
     * @param _controller The controller of the request
     * @return claims The breakdown of assets that the redeemed shares have a claim on
     * @return metadata The format prefixed metadata of the redemption or empty bytes if no metadata is shared
     */
    function redeem(uint256 _shares, address _receiver, address _controller) external returns (AssetClaims memory claims, bytes memory metadata);

    /**
     * @notice Previews the number of shares that would be minted to the protocol fee recipient to satisfy the ratio of total assets that the fee represents
     * @dev The fee assets are expressed in the tranche's base asset
     * @param _protocolFeeAssets The fee accrued for this tranche as a result of the pre-op sync
     * @param _trancheTotalAssets The total effective assets controlled by this tranche as a result of the pre-op sync
     * @return mintedProtocolFeeShares The number of protocol fee shares that would be minted to the protocol fee recipient
     * @return totalTrancheShares The total number of shares that exist in the tranche after minting any protocol fee shares post-sync
     */
    function previewMintProtocolFeeShares(
        NAV_UNIT _protocolFeeAssets,
        NAV_UNIT _trancheTotalAssets
    )
        external
        view
        returns (uint256 mintedProtocolFeeShares, uint256 totalTrancheShares);

    /**
     * @notice Mints tranche shares to the protocol fee recipient, representing ownership over the fee assets of the tranche
     * @dev Must be called by the tranche's kernel everytime protocol fees are accrued in its pre-op synchronization
     * @param _protocolFeeAssets The fee accrued for this tranche as a result of the pre-op sync
     * @param _protocolFeeRecipient The address to receive the freshly minted protocol fee shares
     * @param _trancheTotalAssets The total effective assets controlled by this tranche as a result of the pre-op sync
     * @return mintedProtocolFeeShares The number of protocol fee shares that were minted to the protocol fee recipient
     * @return totalTrancheShares The total number of shares that exist in the tranche after minting any protocol fee shares post-sync
     */
    function mintProtocolFeeShares(
        NAV_UNIT _protocolFeeAssets,
        NAV_UNIT _trancheTotalAssets,
        address _protocolFeeRecipient
    )
        external
        returns (uint256 mintedProtocolFeeShares, uint256 totalTrancheShares);

    /**
     * @notice Returns the address of the tranche's deposit asset
     * @return asset The address of the tranche's deposit asset
     */
    function asset() external view returns (address asset);
}
