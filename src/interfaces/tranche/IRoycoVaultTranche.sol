// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { AssetClaims, TrancheType } from "../../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../../libraries/Units.sol";

interface IRoycoVaultTranche is IERC20Metadata {
    /// @notice Emitted when a deposit is made
    /// @param sender The address that made the deposit
    /// @param receiver The address that received the shares
    /// @param assets The amount of assets deposited
    /// @param shares The amount of shares minted
    event Deposit(address indexed sender, address indexed receiver, TRANCHE_UNIT assets, uint256 shares);

    /// @notice Emitted when a redemption is made
    /// @param sender The address that made the redemption
    /// @param receiver The address that received the assets
    /// @param claims The assets received and their NAV value
    /// @param shares The amount of shares redeemed
    event Redeem(address indexed sender, address indexed receiver, AssetClaims claims, uint256 shares);

    /// @notice Emitted when protocol fee shares are minted
    /// @param protocolFeeRecipient The address that received the protocol fee shares
    /// @param mintedProtocolFeeShares The number of protocol fee shares minted
    /// @param totalTrancheShares The total shares after minting
    event ProtocolFeeSharesMinted(address indexed protocolFeeRecipient, uint256 mintedProtocolFeeShares, uint256 totalTrancheShares);

    error MUST_REQUEST_NON_ZERO_SHARES();
    error MUST_DEPOSIT_NON_ZERO_ASSETS();
    error ONLY_KERNEL();
    error INVALID_VALUE_ALLOCATED();

    /// @notice Returns the raw NAV of the tranche's invested assets
    function getRawNAV() external view returns (NAV_UNIT nav);

    /// @notice Returns the kernel address
    function kernel() external view returns (address);

    /// @notice Returns the market identifier
    function marketId() external view returns (bytes32);

    /// @notice Returns the total effective assets
    function totalAssets() external view returns (AssetClaims memory claims);

    /// @notice Returns the underlying asset address
    function asset() external view returns (address);

    /// @notice Returns the tranche type (SENIOR or JUNIOR)
    function TRANCHE_TYPE() external view returns (TrancheType);

    /// @notice Returns the maximum depositable assets
    function maxDeposit(address _receiver) external view returns (TRANCHE_UNIT assets);

    /// @notice Returns the maximum redeemable shares
    function maxRedeem(address _owner) external view returns (uint256 shares);

    /// @notice Previews shares minted for a deposit
    function previewDeposit(TRANCHE_UNIT _assets) external view returns (uint256 shares);

    /// @notice Previews assets received for a redemption
    function previewRedeem(uint256 _shares) external view returns (AssetClaims memory claims);

    /// @notice Converts assets to shares
    function convertToShares(TRANCHE_UNIT _assets) external view returns (uint256 shares);

    /// @notice Converts shares to asset claims
    function convertToAssets(uint256 _shares) external view returns (AssetClaims memory claims);

    /// @notice Deposits assets and mints shares to receiver
    function deposit(TRANCHE_UNIT _assets, address _receiver) external returns (uint256 shares);

    /// @notice Redeems shares for assets to receiver
    function redeem(uint256 _shares, address _receiver, address _owner) external returns (AssetClaims memory claims);

    /// @notice Previews protocol fee shares to be minted
    function previewMintProtocolFeeShares(
        NAV_UNIT _protocolFeeAssets,
        NAV_UNIT _trancheTotalAssets
    )
        external
        view
        returns (uint256 mintedProtocolFeeShares, uint256 totalTrancheShares);

    /// @notice Mints protocol fee shares
    function mintProtocolFeeShares(
        NAV_UNIT _protocolFeeAssets,
        NAV_UNIT _trancheTotalAssets,
        address _protocolFeeRecipient
    )
        external
        returns (uint256 mintedProtocolFeeShares, uint256 totalTrancheShares);
}
