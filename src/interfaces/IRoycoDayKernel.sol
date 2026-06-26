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
     * @custom:field ltAsset - The base asset of the liquidity tranche (the market-making LP token)
     * @custom:field quoteAsset - The quote asset paired against the senior share in the LP token
     * @custom:field enforceVaultSharesTransferWhitelist Whether to enforce the vault shares transfer whitelist
     */
    struct RoycoDayKernelConstructionParams {
        address seniorTranche;
        address stAsset;
        address juniorTranche;
        address jtAsset;
        address accountant;
        address liquidityTranche;
        address ltAsset;
        address quoteAsset;
        bool enforceVaultSharesTransferWhitelist;
    }

    /**
     * @notice Initialization parameters for the Royco Kernel
     * @custom:field initialAuthority - The access manager for this kernel
     * @custom:field protocolFeeRecipient - The market's protocol fee recipient
     * @custom:field stSelfLiquidationBonusWAD - The market's configured ST self-liquidation bonus remitted to redeeming ST LPs when liquidation coverageUtilization threshold has been breached, scaled to WAD precision
     * @custom:field roycoBlacklist - The market's blacklist contract consulted on tranche balance updates (the null address disables blacklist screening)
     */
    struct RoycoDayKernelInitParams {
        address initialAuthority;
        address protocolFeeRecipient;
        uint64 stSelfLiquidationBonusWAD;
        address roycoBlacklist;
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
     * @custom:field roycoBlacklist - The market's blacklist contract consulted on tranche balance updates (the null address disables blacklist screening)
     */
    struct RoycoDayKernelState {
        address protocolFeeRecipient;
        uint64 stSelfLiquidationBonusWAD;
        TRANCHE_UNIT stOwnedYieldBearingAssets;
        TRANCHE_UNIT jtOwnedYieldBearingAssets;
        TRANCHE_UNIT ltOwnedYieldBearingAssets;
        uint256 ltOwnedSeniorTrancheShares;
        address roycoBlacklist;
    }

    /**
     * @notice Emitted when the protocol fee recipient is updated
     * @param protocolFeeRecipient The new protocol fee recipient
     */
    event ProtocolFeeRecipientUpdated(address protocolFeeRecipient);

    /**
     * @notice Emitted when the ST self-liquidation bonus is updated
     * @param stSelfLiquidationBonusWAD The new ST self-liquidation bonus remitted to redeeming ST LPs when liquidation coverageUtilization threshold has been breached
     */
    event SeniorTrancheSelfLiquidationBonusUpdated(uint64 stSelfLiquidationBonusWAD);

    /**
     * @notice Emitted when the market's blacklist contract is updated
     * @param roycoBlacklist The new blacklist contract address (the null address if screening is disabled)
     */
    event RoycoBlacklistUpdated(address roycoBlacklist);

    /// @notice Thrown when the tranche and the kernel's corresponding tranche assets don't match
    error TRANCHE_AND_KERNEL_ASSETS_MISMATCH();

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

    /// @notice Thrown when the to address is not whitelisted on the tranche
    error ACCOUNT_NOT_WHITELISTED_TRANCHE_LP(address to);

    /// @notice Thrown when an LT multi-asset deposit/redeem produces less than the caller's specified minimum output
    error INSUFFICIENT_OUTPUT_AMOUNT();

    /// @notice Thrown when an LT multi-asset deposit/redeem is made with zero of both constituent assets (ST underlying and quote)
    error MUST_DEPOSIT_NON_ZERO_ASSETS();

    /**
     * @notice Retrieves the senior tranche address
     * @return seniorTranche The address of the senior tranche for this Royco market
     */
    function SENIOR_TRANCHE() external view returns (address seniorTranche);

    /**
     * @notice Retrieves the ST asset address
     * @return stAsset The senior tranche's base asset address
     */
    function ST_ASSET() external view returns (address stAsset);

    /**
     * @notice Retrieves the junior tranche address
     * @return juniorTranche The address of the junior tranche for this Royco market
     */
    function JUNIOR_TRANCHE() external view returns (address juniorTranche);

    /**
     * @notice Retrieves the JT asset address
     * @return jtAsset The junior tranche's base asset address
     */
    function JT_ASSET() external view returns (address jtAsset);

    /**
     * @notice Retrieves the accountant address
     * @return accountant The accountant responsible for maintaining this Royco market's accounting state and marking tranche NAVs to market
     */
    function ACCOUNTANT() external view returns (address accountant);

    /// @notice Retrieves the liquidity tranche address.
    function LIQUIDITY_TRANCHE() external view returns (address liquidityTranche);

    /// @notice Retrieves the liquidity tranche's base asset (the market-making LP token) address.
    function LT_ASSET() external view returns (address ltAsset);

    /// @notice Retrieves the quote asset paired against the senior share in the LP token.
    function QUOTE_ASSET() external view returns (address quoteAsset);

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

    /**
     * @notice Sets the blacklist contract consulted on tranche balance updates for this market
     * @dev Only callable by a designated admin
     * @dev Setting the blacklist to the null address disables blacklist screening for this market
     * @param _roycoBlacklist The address of the market's blacklist contract (or the null address to disable screening)
     */
    function setRoycoBlacklist(address _roycoBlacklist) external;

    /**
     * @notice Retrieves the state of the Royco kernel
     * @return state The Royco kernel's state, including the protocol fee recipient and the kernel's controlled tranche and base assets
     */
    function getState() external view returns (RoycoDayKernelState memory state);

    /**
     * @notice Converts the specified ST assets denominated in its tranche units to the kernel's NAV units
     * @param _stAssets The ST assets denominated in tranche units to convert to the kernel's NAV units
     * @return nav The specified ST assets denominated in its tranche units converted to the kernel's NAV units
     */
    function stConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _stAssets) external view returns (NAV_UNIT nav);

    /**
     * @notice Converts the specified JT assets denominated in its tranche units to the kernel's NAV units
     * @param _jtAssets The JT assets denominated in tranche units to convert to the kernel's NAV units
     * @return nav The specified JT assets denominated in its tranche units converted to the kernel's NAV units
     */
    function jtConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _jtAssets) external view returns (NAV_UNIT nav);

    /**
     * @notice Converts the specified LT assets denominated in its tranche units to the kernel's NAV units
     * @param _ltAssets The LT assets denominated in tranche units to convert to the kernel's NAV units
     * @return nav The specified LT assets denominated in its tranche units converted to the kernel's NAV units
     */
    function ltConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _ltAssets) external view returns (NAV_UNIT nav);

    /**
     * @notice Converts the specified assets denominated in the kernel's NAV units to assets denominated in ST's tranche units
     * @param _navAssets The NAV of the assets denominated in the kernel's NAV units to convert to assets denominated in ST's tranche units
     * @return stAssets The specified NAV of the assets denominated in the kernel's NAV units converted to assets denominated in ST's tranche units
     */
    function stConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) external view returns (TRANCHE_UNIT stAssets);

    /**
     * @notice Converts the specified assets denominated in the kernel's NAV units to assets denominated in JT's tranche units
     * @param _navAssets The NAV of the assets denominated in the kernel's NAV units to convert to assets denominated in JT's tranche units
     * @return jtAssets The specified NAV of the assets denominated in the kernel's NAV units converted to assets denominated in JT's tranche units
     */
    function jtConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) external view returns (TRANCHE_UNIT jtAssets);

    /**
     * @notice Converts the specified assets denominated in the kernel's NAV units to assets denominated in LT's tranche units
     * @param _navAssets The NAV of the assets denominated in the kernel's NAV units to convert to assets denominated in LT's tranche units
     * @return ltAssets The specified NAV of the assets denominated in the kernel's NAV units converted to assets denominated in LT's tranche units
     */
    function ltConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) external view returns (TRANCHE_UNIT ltAssets);

    /**
     * @notice Synchronizes and persists the raw and effective NAVs of both tranches
     * @dev Only executes a pre-op sync because there is no operation being executed in the same call as this sync
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function syncTrancheAccounting() external returns (SyncedAccountingState memory state);

    /**
     * @notice Previews a synchronization of the raw and effective NAVs of both tranches
     * @dev Does not mutate any state
     * @param _trancheType An enumerator indicating which tranche to execute this preview for
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     * @return claims The claims on ST and JT assets that the specified tranche has denominated in tranche-native units
     * @return totalTrancheShares The total number of shares that exist in the specified tranche after minting any protocol fee shares post-sync
     */
    function previewSyncTrancheAccounting(TrancheType _trancheType)
        external
        view
        returns (SyncedAccountingState memory state, AssetClaims memory claims, uint256 totalTrancheShares);

    /**
     * @notice Returns the maximum amount of assets that can be deposited into the senior tranche
     * @param _receiver The address that will receive the ST shares equating to the deposited assets
     * @return assets The maximum amount of assets that can be deposited into the senior tranche, denominated in the senior tranche's tranche units
     */
    function stMaxDeposit(address _receiver) external view returns (TRANCHE_UNIT assets);

    /**
     * @notice Returns the maximum amount of assets that can be withdrawn from the senior tranche
     * @param _owner The address that is withdrawing the assets
     * @return claimOnStNAV The notional claims on ST assets that the senior tranche has denominated in kernel's NAV units
     * @return claimOnJtNAV The notional claims on JT assets that the senior tranche has denominated in kernel's NAV units
     * @return stMaxWithdrawableNAV The maximum amount of assets that can be withdrawn from the senior tranche, denominated in the kernel's NAV units
     * @return jtMaxWithdrawableNAV The maximum amount of assets that can be withdrawn from the junior tranche, denominated in the kernel's NAV units
     * @return totalTrancheSharesAfterMintingFees The total number of shares that exist in the senior tranche after minting any protocol fee shares post-sync
     */
    function stMaxWithdrawable(address _owner)
        external
        view
        returns (
            NAV_UNIT claimOnStNAV,
            NAV_UNIT claimOnJtNAV,
            NAV_UNIT stMaxWithdrawableNAV,
            NAV_UNIT jtMaxWithdrawableNAV,
            uint256 totalTrancheSharesAfterMintingFees
        );

    /**
     * @notice Previews the deposit of a specified amount of assets into the senior tranche
     * @param _assets The amount of assets to deposit, denominated in the senior tranche's tranche units
     * @return stateBeforeDeposit The state of the senior tranche before the deposit, after applying the pre-op sync
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units
     */
    function stPreviewDeposit(TRANCHE_UNIT _assets) external view returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated);

    /**
     * @notice Previews the deposit of a specified amount of assets into the liquidity tranche
     * @param _assets The amount of assets to deposit, denominated in the liquidity tranche's tranche units
     * @return stateBeforeDeposit The state of the liquidity tranche before the deposit, after applying the pre-op sync
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units
     */
    function ltPreviewDeposit(TRANCHE_UNIT _assets) external view returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated);

    /**
     * @notice Previews the redemption of a specified number of shares from the senior tranche
     * @param _shares The number of shares to redeem
     * @return userClaim The distribution of assets that would be transferred to the receiver on redemption, denominated in the respective tranches' tranche units
     */
    function stPreviewRedeem(uint256 _shares) external view returns (AssetClaims memory userClaim);

    /**
     * @notice Previews the redemption of a specified number of shares from the liquidity tranche
     * @param _shares The number of shares to redeem
     * @return userClaim The distribution of assets that would be transferred to the receiver on redemption, denominated in the respective tranches' tranche units
     */
    function ltPreviewRedeem(uint256 _shares) external view returns (AssetClaims memory userClaim);

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
     * @param _bypassRedemptionRestrictions Whether to bypass the redemption restrictions (eg. for Transfer Agent Obligations on RWA)
     * @return userAssetClaims The distribution of assets that were transferred to the receiver on redemption
     */
    function stRedeem(uint256 _shares, address _receiver, bool _bypassRedemptionRestrictions) external returns (AssetClaims memory userAssetClaims);

    /**
     * @notice Returns the maximum amount of assets that can be deposited into the junior tranche
     * @param _receiver The address that will receive the JT shares equating to the deposited assets
     * @return assets The maximum amount of assets that can be deposited into the junior tranche, denominated in the junior tranche's tranche units
     */
    function jtMaxDeposit(address _receiver) external view returns (TRANCHE_UNIT assets);

    /**
     * @notice Returns the maximum amount of assets that can be withdrawn from the junior tranche
     * @param _owner The address that is withdrawing the assets
     * @return claimOnStNAV The notional claims on ST assets that the junior tranche has denominated in kernel's NAV units
     * @return claimOnJtNAV The notional claims on JT assets that the junior tranche has denominated in kernel's NAV units
     * @return stMaxWithdrawableNAV The maximum amount of assets that can be withdrawn from the senior tranche, denominated in the kernel's NAV units
     * @return jtMaxWithdrawableNAV The maximum amount of assets that can be withdrawn from the junior tranche, denominated in the kernel's NAV units
     * @return totalTrancheSharesAfterMintingFees The total number of shares that exist in the junior tranche after minting any protocol fee shares post-sync, including virtual shares
     */
    function jtMaxWithdrawable(address _owner)
        external
        view
        returns (
            NAV_UNIT claimOnStNAV,
            NAV_UNIT claimOnJtNAV,
            NAV_UNIT stMaxWithdrawableNAV,
            NAV_UNIT jtMaxWithdrawableNAV,
            uint256 totalTrancheSharesAfterMintingFees
        );

    /**
     * @notice Returns the maximum amount of assets that can be deposited into the liquidity tranche
     * @param _receiver The address that will receive the LT shares equating to the deposited assets
     * @return assets The maximum amount of assets that can be deposited into the liquidity tranche, denominated in the liquidity tranche's tranche units
     */
    function ltMaxDeposit(address _receiver) external view returns (TRANCHE_UNIT assets);

    /**
     * @notice Returns the maximum amount of assets that can be withdrawn from the liquidity tranche
     * @param _owner The address that is withdrawing the assets
     * @return claimOnLtNAV The notional claims on LT assets that the liquidity tranche has denominated in kernel's NAV units
     * @return ltMaxWithdrawableNAV The maximum amount of assets that can be withdrawn from the liquidity tranche, denominated in the kernel's NAV units
     * @return totalTrancheSharesAfterMintingFees The total number of shares that exist in the liquidity tranche after minting any protocol fee shares post-sync
     */
    function ltMaxWithdrawable(address _owner)
        external
        view
        returns (NAV_UNIT claimOnLtNAV, NAV_UNIT ltMaxWithdrawableNAV, uint256 totalTrancheSharesAfterMintingFees);

    /**
     * @notice Previews the deposit of a specified amount of assets into the junior tranche
     * @dev The kernel may decide to simulate the deposit and revert internally with the result
     * @dev Should revert if deposits are asynchronous
     * @param _assets The amount of assets to deposit, denominated in the junior tranche's tranche units
     * @return stateBeforeDeposit The state of the junior tranche before the deposit, after applying the pre-op sync
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units
     */
    function jtPreviewDeposit(TRANCHE_UNIT _assets) external view returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated);

    /**
     * @notice Previews the redemption of a specified number of shares from the junior tranche
     * @dev The kernel may decide to simulate the redemption and revert internally with the result
     * @dev Should revert if redemptions are asynchronous
     * @param _shares The number of shares to redeem
     * @return userClaim The distribution of assets that would be transferred to the receiver on redemption, denominated in the respective tranches' tranche units
     */
    function jtPreviewRedeem(uint256 _shares) external view returns (AssetClaims memory userClaim);

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
     * @param _bypassRedemptionRestrictions Whether to bypass the redemption restrictions (eg. for Transfer Agent Obligations on RWA)
     * @return userAssetClaims The distribution of assets that were transferred to the receiver on redemption
     */
    function jtRedeem(uint256 _shares, address _receiver, bool _bypassRedemptionRestrictions) external returns (AssetClaims memory userAssetClaims);

    /**
     * @notice Processes the deposit of a specified amount of assets into the liquidity tranche.
     * @param _assets The amount of assets (the LP token) to deposit, denominated in the liquidity tranche's tranche units.
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units.
     * @return navToMintSharesAt The NAV at which the shares will be minted, exclusive of valueAllocated.
     */
    function ltDeposit(TRANCHE_UNIT _assets) external returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt);

    /**
     * @notice Processes the redemption of a specified number of shares from the liquidity tranche.
     * @param _shares The number of shares to redeem.
     * @param _receiver The address that is receiving the assets.
     * @param _bypassRedemptionRestrictions Whether to bypass the redemption restrictions.
     * @return userAssetClaims The distribution of assets that were transferred to the receiver on redemption.
     */
    function ltRedeem(uint256 _shares, address _receiver, bool _bypassRedemptionRestrictions) external returns (AssetClaims memory userAssetClaims);

    /**
     * @notice Atomically enters the liquidity tranche with the LP token's constituent assets: deposits ST underlying (minting senior
     *         shares), single-sided adds (senior shares + quote) into the liquidity venue to mint the LT tranche assets, then deposits them into the LT
     * @dev Assumes the ST underlying and quote have been transferred to the kernel before this call (by the LT tranche)
     * @dev The ST mint leg enforces the market's coverage requirement; reverts if coverage is unsatisfied
     * @param _stAssets The amount of ST underlying (the senior tranche's base asset) to deposit, denominated in ST tranche units
     * @param _quoteAssets The amount of quote asset to add as the second pool leg
     * @param _minStSharesMinted The minimum senior shares the deposited ST underlying must mint (slippage bound against an unfavorable ST share price)
     * @return valueAllocated The value of the minted LT tranche assets, denominated in the kernel's NAV units
     * @return navToMintSharesAt The LT raw NAV at which the LT shares will be minted (pre-deposit)
     * @return trancheAssetsOut The amount of LT tranche assets (LP token) minted and credited to the liquidity tranche
     */
    function ltDepositMultiAsset(
        TRANCHE_UNIT _stAssets,
        uint256 _quoteAssets,
        uint256 _minStSharesMinted
    )
        external
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt, uint256 trancheAssetsOut);

    /**
     * @notice Atomically exits the liquidity tranche to the LP token's constituent assets: proportionally removes the LP-token slice,
     *         redeems the pooled senior shares to ST underlying, and returns (ST underlying + quote) to the receiver
     * @param _ltShares The number of LT shares being redeemed (used to size the proportional LP-token slice)
     * @param _minQuoteOut The minimum quote to return (slippage bound)
     * @param _receiver The address that receives the ST underlying and quote
     * @return stClaims The ST redemption asset claims transferred to the receiver (its ST/JT asset legs)
     * @return quoteOut The quote returned to the receiver
     */
    function ltRedeemMultiAsset(uint256 _ltShares, uint256 _minQuoteOut, address _receiver) external returns (AssetClaims memory stClaims, uint256 quoteOut);

    /**
     * @notice Previews an LT multi-asset deposit
     * @dev NON-VIEW: it queries the liquidity venue, whose `query*` functions are not `view`. Intended for off-chain `eth_call`
     * @param _stUnderlying The amount of ST underlying to deposit, in ST tranche units
     * @param _quoteAmount The amount of quote asset to add as the second pool leg
     * @return valueAllocated The value of the LT tranche assets that would be minted, in the kernel's NAV units
     * @return navToMintSharesAt The LT raw NAV at which LT shares would be minted (pre-deposit)
     * @return trancheAssetsOut The LT tranche assets (LP token) that would be minted from the liquidity add
     */
    function previewLtDepositMultiAsset(
        uint256 _stUnderlying,
        uint256 _quoteAmount
    )
        external
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt, uint256 trancheAssetsOut);

    /**
     * @notice Previews an LT multi-asset redemption
     * @dev NON-VIEW: it queries the liquidity venue, whose `query*` functions are not `view`. Intended for off-chain `eth_call`
     * @param _ltShares The number of LT shares being redeemed
     * @return stClaims The ST redemption asset claims that would be transferred to the receiver (its ST/JT asset legs)
     * @return quoteOut The quote that would be returned
     */
    function previewLtRedeemMultiAsset(uint256 _ltShares) external returns (AssetClaims memory stClaims, uint256 quoteOut);

    /**
     * @notice Pre-balance update hook for the tranche
     * @dev This function should revert if the balance update is invalid.
     * @dev Should be called before every tranche share balance update
     * @param _caller The address that is calling the balance update
     * @param _from The address from which the balance is being updated
     * @param _to The address to which the balance is being updated
     * @param _value The amount of the balance being updated
     */
    function preTrancheBalanceUpdateHook(address _caller, address _from, address _to, uint256 _value) external;
}
