// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AssetClaims } from "../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../libraries/Units.sol";
import { IRoycoDawnKernel } from "./IRoycoDawnKernel.sol";

/**
 * @title IRoycoDayKernel
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Interface for the Royco Day kernel: the Dawn kernel (ST/JT) plus a third Liquidity Tranche (LT) that
 *         custodies a Balancer BPT of the senior share paired against a quote stablecoin.
 * @dev STUB: the LT operational surface (`ltDeposit`/`ltRedeem`) is declared here but not yet implemented by the
 *      kernel. Only the getters + wiring are functional, which is sufficient to deploy and verify a Day market.
 */
interface IRoycoDayKernel is IRoycoDawnKernel {
    /**
     * @notice Construction parameters for the Royco Day kernel.
     * @custom:field dawnKernelParams - The standard Dawn (ST/JT) construction parameters.
     * @custom:field liquidityTranche - The address of the liquidity tranche associated with this kernel.
     * @custom:field ltAsset - The base asset of the liquidity tranche (the Balancer BPT).
     * @custom:field quoteAsset - The quote asset paired against the senior share in the BPT.
     */
    struct RoycoDayKernelConstructionParams {
        RoycoDawnKernelConstructionParams dawnKernelParams;
        address liquidityTranche;
        address ltAsset;
        address quoteAsset;
    }

    /**
     * @notice Initialization parameters for the Royco Day kernel.
     * @custom:field dawnKernelInitParams - The standard Dawn (ST/JT) initialization parameters.
     */
    struct RoycoDayKernelInitParams {
        RoycoDawnKernelInitParams dawnKernelInitParams;
    }

    /// @notice Thrown when an LT operation that is not yet implemented is invoked.
    error LT_NOT_IMPLEMENTED();

    /// @notice Retrieves the liquidity tranche address.
    function LIQUIDITY_TRANCHE() external view returns (address liquidityTranche);

    /// @notice Retrieves the liquidity tranche's base asset (the Balancer BPT) address.
    function LT_ASSET() external view returns (address ltAsset);

    /// @notice Retrieves the quote asset paired against the senior share in the BPT.
    function QUOTE_ASSET() external view returns (address quoteAsset);

    /**
     * @notice Processes the deposit of a specified amount of assets into the liquidity tranche.
     * @dev STUB: reverts with `LT_NOT_IMPLEMENTED` until the LT flow is implemented.
     * @param _assets The amount of assets (BPT) to deposit, denominated in the liquidity tranche's tranche units.
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units.
     * @return navToMintSharesAt The NAV at which the shares will be minted, exclusive of valueAllocated.
     */
    function ltDeposit(TRANCHE_UNIT _assets) external returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt);

    /**
     * @notice Processes the redemption of a specified number of shares from the liquidity tranche.
     * @dev STUB: reverts with `LT_NOT_IMPLEMENTED` until the LT flow is implemented.
     * @param _shares The number of shares to redeem.
     * @param _receiver The address that is receiving the assets.
     * @param _bypassRedemptionRestrictions Whether to bypass the redemption restrictions.
     * @return userAssetClaims The distribution of assets that were transferred to the receiver on redemption.
     */
    function ltRedeem(uint256 _shares, address _receiver, bool _bypassRedemptionRestrictions) external returns (AssetClaims memory userAssetClaims);
}
