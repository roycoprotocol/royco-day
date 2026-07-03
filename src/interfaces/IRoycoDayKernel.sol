// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AssetClaims, SyncedAccountingState, TrancheType } from "../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../libraries/Units.sol";

/**
 * @title IRoycoDayKernel
 * @notice Interface for the base Royco kernel contract
 * @dev The kernel contract is responsible for orchestrating all operations for both tranches in a Royco market
 */
interface IRoycoDayKernel {
    /**
     * @notice Construction parameters for the Royco Kernel
     * @custom:field seniorTranche - The address of the Royco senior tranche associated with this kernel
     * @custom:field stAsset - The address of the base asset of the senior tranche
     * @custom:field juniorTranche - The address of the Royco junior tranche associated with this kernel
     * @custom:field jtAsset - The address of the base asset of the junior tranche
     * @custom:field accountant - The address of the accountant for the Royco market
     * @custom:field liquidityTranche - The address of the Royco liquidity tranche associated with this kernel
     * @custom:field ltAsset - The base asset of the liquidity tranche (the liquidity venue's market-making position token)
     * @custom:field quoter - The address of the quoter that prices this kernel's tranche assets and holds the market's preview surface
     */
    struct RoycoDayKernelConstructionParams {
        address seniorTranche;
        address stAsset;
        address juniorTranche;
        address jtAsset;
        address accountant;
        address liquidityTranche;
        address ltAsset;
        address quoter;
    }

    /**
     * @notice Initialization parameters for the Royco Kernel
     * @custom:field initialAuthority - The access manager for this kernel
     * @custom:field protocolFeeRecipient - The market's protocol fee recipient
     * @custom:field stSelfLiquidationBonusWAD - The market's configured ST self-liquidation bonus remitted to redeeming ST LPs when liquidation coverageUtilization threshold has been breached, scaled to WAD precision
     */
    struct RoycoDayKernelInitParams {
        address initialAuthority;
        address protocolFeeRecipient;
        uint64 stSelfLiquidationBonusWAD;
    }

    /**
     * @notice Storage state for the Royco Day Kernel
     * @custom:storage-location erc7201:Royco.storage.RoycoDayKernelState
     * @custom:field protocolFeeRecipient - The market's configured protocol fee recipient
     * @custom:field stSelfLiquidationBonusWAD - The market's configured ST self-liquidation bonus remitted to redeeming ST LPs when liquidation coverageUtilization threshold has been breached, scaled to WAD precision
     * @custom:field stOwnedYieldBearingAssets - The yield bearing assets held by the senior tranche, in ST's asset units
     * @custom:field jtOwnedYieldBearingAssets - The yield bearing assets held by the junior tranche, in JT's asset units
     * @custom:field ltOwnedYieldBearingAssets - The yield bearing assets held by the liquidity tranche, in LT's asset units
     * @custom:field ltOwnedSeniorTrancheShares - The senior tranche shares held by the liquidity tranche (accumulated liquidity premium payments)
     */
    struct RoycoDayKernelState {
        address protocolFeeRecipient;
        uint64 stSelfLiquidationBonusWAD;
        TRANCHE_UNIT stOwnedYieldBearingAssets;
        TRANCHE_UNIT jtOwnedYieldBearingAssets;
        TRANCHE_UNIT ltOwnedYieldBearingAssets;
        uint256 ltOwnedSeniorTrancheShares;
    }

    /// @notice Emitted when the protocol fee recipient is updated
    /// @param protocolFeeRecipient The new protocol fee recipient
    event ProtocolFeeRecipientUpdated(address protocolFeeRecipient);

    /// @notice Emitted when the ST self-liquidation bonus is updated
    /// @param stSelfLiquidationBonusWAD The new ST self-liquidation bonus remitted to redeeming ST LPs when liquidation coverageUtilization threshold has been breached
    event SeniorTrancheSelfLiquidationBonusUpdated(uint64 stSelfLiquidationBonusWAD);

    /**
     * @notice Emitted when the kernel deploys its held liquidity-premium senior shares into the liquidity tranche's venue
     * @param stSharesReinvested The senior tranche shares drained from the kernel's held balance and deployed into the liquidity venue
     * @param ltAssetsMinted The liquidity tranche assets minted to the liquidity tranche by the deployment
     */
    event LiquidityPremiumReinvested(uint256 stSharesReinvested, TRANCHE_UNIT ltAssetsMinted);

    /// @notice Thrown when the tranche and the kernel's corresponding tranche assets don't match
    error TRANCHE_AND_KERNEL_ASSETS_MISMATCH();

    /// @notice Thrown when the senior and junior tranches share the same asset (so are structurally correlated) but the accountant is not configured with the junior tranche co-invested
    error JT_MUST_BE_COINVESTED();

    /// @notice Thrown when the caller of a permissioned function isn't the market's senior tranche
    error ONLY_SENIOR_TRANCHE();

    /// @notice Thrown when the caller of a permissioned function isn't the market's junior tranche
    error ONLY_JUNIOR_TRANCHE();

    /// @notice Thrown when the caller of a permissioned function isn't the market's liquidity tranche
    error ONLY_LIQUIDITY_TRANCHE();

    /// @notice Thrown when an LP is attempting to deposit into or redeem from the market while it is in a fixed term state
    error DISABLED_IN_FIXED_TERM_STATE();

    /// @notice Thrown when the caller of a permissioned function isn't the market's senior, junior, or liquidity tranche
    error ONLY_TRANCHE();

    /// @notice Thrown when the specified account is the null address
    error NULL_DEPOSITOR();

    /// @notice Thrown when an LT multi-asset deposit/redeem is made with zero of both constituent assets (ST underlying and quote)
    error MUST_DEPOSIT_NON_ZERO_ASSETS();

    /// @notice Retrieves the senior tranche address
    /// @return seniorTranche The address of the senior tranche for this Royco market
    function SENIOR_TRANCHE() external view returns (address seniorTranche);

    /// @notice Retrieves the ST asset address
    /// @return stAsset The senior tranche's base asset address
    function ST_ASSET() external view returns (address stAsset);

    /// @notice Retrieves the junior tranche address
    /// @return juniorTranche The address of the junior tranche for this Royco market
    function JUNIOR_TRANCHE() external view returns (address juniorTranche);

    /// @notice Retrieves the JT asset address
    /// @return jtAsset The junior tranche's base asset address
    function JT_ASSET() external view returns (address jtAsset);

    /// @notice Retrieves the accountant address
    /// @return accountant The accountant responsible for maintaining this Royco market's accounting state and marking tranche NAVs to market
    function ACCOUNTANT() external view returns (address accountant);

    /// @notice Retrieves the liquidity tranche address.
    function LIQUIDITY_TRANCHE() external view returns (address liquidityTranche);

    /// @notice Retrieves the liquidity tranche's base asset (the liquidity venue's market-making position token) address.
    function LT_ASSET() external view returns (address ltAsset);

    /// @notice Retrieves the quote asset paired against the senior share in the liquidity venue.
    function QUOTE_ASSET() external view returns (address quoteAsset);

    /// @notice Retrieves the quoter that prices this kernel's tranche assets and holds the market's preview surface.
    function QUOTER() external view returns (address quoter);

    /**
     * @notice Sets the new protocol fee recipient
     * @dev Only callable by a designated admin
     * @param _protocolFeeRecipient The address of the new protocol fee recipient
     */
    function setProtocolFeeRecipient(address _protocolFeeRecipient) external;

    /**
     * @notice Sets the ST self-liquidation bonus remitted to redeeming ST LPs when liquidation coverageUtilization threshold has been breached
     * @dev Only callable by a designated admin
     * @param _stSelfLiquidationBonusWAD The ST self liquidation bonus, scaled to WAD precision
     */
    function setSeniorTrancheSelfLiquidationBonus(uint64 _stSelfLiquidationBonusWAD) external;

    /// @notice Retrieves the state of the Royco kernel
    /// @return state The Royco kernel's state, including the protocol fee recipient and the kernel's controlled tranche and base assets
    function getState() external view returns (RoycoDayKernelState memory state);

    // ─────────────────────────────────────────────────────────────────────────────
    // Quoter accessors — external views surfacing the kernel's internal, context-dependent computations
    // (storage + quoter conversions) to the quoter so previews reuse the kernel's execution bodies.
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Returns the raw net asset value of the senior tranche, valuing its holdings in the kernel's NAV units
    /// @return stRawNAV The senior tranche raw NAV
    function getSeniorTrancheRawNAV() external view returns (NAV_UNIT stRawNAV);

    /// @notice Returns the raw net asset value of the junior tranche, valuing its holdings in the kernel's NAV units
    /// @return jtRawNAV The junior tranche raw NAV
    function getJuniorTrancheRawNAV() external view returns (NAV_UNIT jtRawNAV);

    /// @notice Returns the raw NAVs of all three tranches (each tranche's holdings valued in the kernel's NAV units)
    /// @return stRawNAV The senior tranche raw NAV
    /// @return jtRawNAV The junior tranche raw NAV
    /// @return ltRawNAV The liquidity tranche raw NAV (its deployed market-making inventory)
    function getTrancheRawNAVs() external view returns (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, NAV_UNIT ltRawNAV);

    /// @notice Returns the liquidity tranche effective NAV (raw NAV plus the value of its held liquidity-premium senior shares)
    /// @param _stEffectiveNAV The senior tranche's post-sync effective NAV
    /// @param _totalSeniorTrancheShares The senior tranche supply after minting this sync's premium and protocol fee shares
    /// @param _ltOwnedSeniorTrancheShares The senior shares held by the liquidity tranche (post-mint count for previews)
    /// @return ltEffectiveNAV The liquidity tranche's effective NAV
    function getLiquidityTrancheEffectiveNAV(
        NAV_UNIT _stEffectiveNAV,
        uint256 _totalSeniorTrancheShares,
        uint256 _ltOwnedSeniorTrancheShares
    )
        external
        view
        returns (NAV_UNIT ltEffectiveNAV);

    /// @notice Derives the cumulative asset claims a tranche is entitled to for a synced accounting state
    /// @param _trancheType Which tranche to derive claims for
    /// @param _state The synced accounting state
    /// @return claims The tranche's cumulative asset claims
    function deriveTrancheAssetClaims(TrancheType _trancheType, SyncedAccountingState memory _state) external view returns (AssetClaims memory claims);

    /// @notice Applies the ST self-liquidation bonus to a redeeming senior user's claims (no-op unless liquidation coverage is breached)
    /// @param _state The synced accounting state
    /// @param _stUserClaims The redeeming ST user's base claims
    /// @return stUserClaimsWithBonus The claims after applying the bonus
    /// @return stSelfLiquidationBonusNAV The bonus NAV sourced from JT's claims
    function applySeniorTrancheSelfLiquidationBonus(
        SyncedAccountingState memory _state,
        AssetClaims memory _stUserClaims
    )
        external
        view
        returns (AssetClaims memory stUserClaimsWithBonus, NAV_UNIT stSelfLiquidationBonusNAV);

    /**
     * @notice Synchronizes and persists the raw and effective NAVs of both tranches
     * @dev Only executes a pre-op sync because there is no operation being executed in the same call as this sync
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function syncTrancheAccounting() external returns (SyncedAccountingState memory state);

    /**
     * @notice Syncs the tranche accounting and attempts to reinvest the liquidity tranche's idle liquidity-premium senior shares into its market-making inventory
     * @dev Values the reinvested shares against the freshly synced senior share rate, so a smaller amount can clear the venue's slippage gate when reinvesting the entire idle balance would not
     * @param _stShares The amount of idle liquidity-premium senior shares to reinvest, or type(uint256).max to reinvest the entire idle balance
     */
    function reinvestLiquidityPremium(uint256 _stShares) external;

    /**
     * @notice Processes the deposit of a specified amount of assets into the senior tranche
     * @dev Assumes that the funds are transferred to the kernel before the deposit call is made
     * @param _assets The amount of assets to deposit, denominated in the senior tranche's tranche units
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units
     * @return navToMintSharesAt The NAV at which the shares will be minted, exclusive of valueAllocated
     */
    function stDeposit(TRANCHE_UNIT _assets) external returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt);

    /**
     * @notice Processes the redemption of a specified number of shares from the senior tranche
     * @dev The function is expected to transfer the senior and junior assets directly to the receiver, based on the redemption claims
     * @param _shares The number of shares to redeem
     * @param _receiver The address that is receiving the assets
     * @return userAssetClaims The distribution of assets that were transferred to the receiver on redemption
     */
    function stRedeem(uint256 _shares, address _receiver) external returns (AssetClaims memory userAssetClaims);

    /**
     * @notice Processes the deposit of a specified amount of assets into the junior tranche
     * @dev Assumes that the funds are transferred to the kernel before the deposit call is made
     * @param _assets The amount of assets to deposit, denominated in the junior tranche's tranche units
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units
     * @return navToMintSharesAt The NAV at which the shares will be minted, exclusive of valueAllocated
     */
    function jtDeposit(TRANCHE_UNIT _assets) external returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt);

    /**
     * @notice Processes the redemption of a specified number of shares from the junior tranche
     * @dev The function is expected to transfer the senior and junior assets directly to the receiver, based on the redemption claims
     * @param _shares The number of shares to redeem
     * @param _receiver The address that is receiving the assets
     * @return userAssetClaims The distribution of assets that were transferred to the receiver on redemption
     */
    function jtRedeem(uint256 _shares, address _receiver) external returns (AssetClaims memory userAssetClaims);

    /**
     * @notice Processes the deposit of a specified amount of assets into the liquidity tranche.
     * @dev An in-kind LT deposit mints no new senior shares and only deepens liquidity, so it is enabled in every market state (including fixed-term).
     * @param _assets The amount of assets (the liquidity venue's position token) to deposit, denominated in the liquidity tranche's tranche units.
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units.
     * @return navToMintSharesAt The NAV at which the shares will be minted, exclusive of valueAllocated.
     */
    function ltDeposit(TRANCHE_UNIT _assets) external returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt);

    /**
     * @notice Processes the redemption of a specified number of shares from the liquidity tranche.
     * @param _shares The number of shares to redeem.
     * @param _receiver The address that is receiving the assets.
     * @return userAssetClaims The distribution of assets that were transferred to the receiver on redemption.
     */
    function ltRedeem(uint256 _shares, address _receiver) external returns (AssetClaims memory userAssetClaims);

    /**
     * @notice Atomically enters the liquidity tranche with the LT assets' constituent assets: deposits ST underlying (minting senior
     *         shares), adds (senior shares + quote) into the liquidity venue to mint the LT tranche assets, then deposits them into the LT
     * @dev Assumes the ST underlying and quote have been transferred to the kernel before this call (by the LT tranche)
     * @dev Enabled in a PERPETUAL market state, and in a fixed-term market only for a quote-only deposit (_stAssets == 0) that mints no senior shares; an ST-leg deposit reverts in a fixed-term market
     * @dev The combined new senior exposure is gated by the market's coverage and liquidity requirements; reverts if either is unsatisfied
     * @param _stAssets The amount of ST underlying (the senior tranche's base asset) to deposit, denominated in ST tranche units
     * @param _quoteAssets The amount of quote asset to add as the second venue leg
     * @param _minLTAssetsOut The minimum LT tranche assets the liquidity add must mint (slippage bound against an unfavorable venue state)
     * @return valueAllocated The value of the minted LT tranche assets, denominated in the kernel's NAV units
     * @return navToMintSharesAt The LT effective NAV at which the LT shares will be minted (pre-deposit)
     * @return ltAssetsOut The amount of LT tranche assets minted and credited to the liquidity tranche
     */
    function ltDepositMultiAsset(
        TRANCHE_UNIT _stAssets,
        uint256 _quoteAssets,
        TRANCHE_UNIT _minLTAssetsOut
    )
        external
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt, TRANCHE_UNIT ltAssetsOut);

    /**
     * @notice Atomically exits the liquidity tranche to the LT assets' constituent assets: proportionally removes the LT-asset slice,
     *         redeems the venue-held senior shares to ST underlying, and returns (ST underlying + quote) to the receiver
     * @param _ltShares The number of LT shares being redeemed (used to size the proportional LT-asset slice)
     * @param _minSTSharesOut The minimum senior tranche shares the proportional removal must return (slippage bound)
     * @param _minQuoteAssetsOut The minimum quote to return (slippage bound)
     * @param _receiver The address that receives the ST underlying and quote
     * @return stClaims The ST redemption asset claims transferred to the receiver (its ST/JT asset legs)
     * @return quoteAssets The quote assets returned to the receiver
     */
    function ltRedeemMultiAsset(
        uint256 _ltShares,
        uint256 _minSTSharesOut,
        uint256 _minQuoteAssetsOut,
        address _receiver
    )
        external
        returns (AssetClaims memory stClaims, uint256 quoteAssets);
}
