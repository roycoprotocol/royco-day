// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AssetClaims, SyncedAccountingState, TrancheType } from "../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../libraries/Units.sol";

/**
 * @title IRoycoDayQuoter
 * @notice Interface for the Royco Day quoter, the view-only companion that prices a market's tranche assets and holds its preview surface
 * @dev The quoter owns the tranche-unit to NAV-unit conversions and the senior share rate, and reads the kernel's committed state to compose previews
 */
interface IRoycoDayQuoter {
    /// @notice Retrieves the kernel this quoter prices and reads its committed state from
    /// @return kernel The address of the kernel paired with this quoter
    function KERNEL() external view returns (address kernel);

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

    /// @notice Initializes the quoter's per-operation cache
    /// @dev Only callable by the kernel, at the start of a cached operation
    function initializeQuoterCache() external;

    /// @notice Clears the quoter's per-operation cache
    /// @dev Only callable by the kernel, at the end of a cached operation
    function clearQuoterCache() external;

    /**
     * @notice Caches the senior tranche share rate resolved by a pre-op synchronization for the duration of the operation
     * @dev Only callable by the kernel, so an inline senior share mint or burn (a multi-asset deposit or redemption) cannot transiently move the venue's senior-leg mark before the matching effective NAV is committed
     * @param _stEffectiveNAV The synced senior tranche effective NAV the cached rate is valued from
     * @param _stTotalSupplyAfterMints The senior tranche share supply after this sync's liquidity premium and ST protocol fee shares are minted, the per-share denominator
     */
    function cacheSTShareRate(NAV_UNIT _stEffectiveNAV, uint256 _stTotalSupplyAfterMints) external;

    /**
     * @notice Previews a synchronization of the raw and effective NAVs of both tranches
     * @dev Does not mutate any state
     * @param _trancheType An enumerator indicating which tranche to execute this preview for
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     * @return claims The claims on ST and JT assets that the specified tranche has denominated in tranche-native units
     * @return totalTrancheShares The total number of shares that exist in the specified tranche after the post-sync mint of its accrued shares: the protocol fee shares for every tranche, plus the liquidity premium shares for the senior tranche
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
     * @return claimOnSTNAV The notional claims on ST assets that the senior tranche has denominated in kernel's NAV units
     * @return claimOnJTNAV The notional claims on JT assets that the senior tranche has denominated in kernel's NAV units
     * @return stMaxWithdrawableNAV The maximum amount of assets that can be withdrawn from the senior tranche, denominated in the kernel's NAV units
     * @return jtMaxWithdrawableNAV The maximum amount of assets that can be withdrawn from the junior tranche, denominated in the kernel's NAV units
     * @return totalTrancheSharesAfterMintingFees The total number of shares that exist in the senior tranche after the post-sync mint of its protocol fee shares and liquidity premium shares
     */
    function stMaxWithdrawable(address _owner)
        external
        view
        returns (
            NAV_UNIT claimOnSTNAV,
            NAV_UNIT claimOnJTNAV,
            NAV_UNIT stMaxWithdrawableNAV,
            NAV_UNIT jtMaxWithdrawableNAV,
            uint256 totalTrancheSharesAfterMintingFees
        );

    /**
     * @notice Previews the deposit of a specified amount of assets into the senior tranche
     * @param _assets The amount of assets to deposit, denominated in the senior tranche's tranche units
     * @return stateBeforeDeposit The state of the senior tranche before the deposit, after applying the pre-op sync
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units
     * @return totalTrancheShares The senior tranche supply after the pre-op sync mints the premium and protocol fee shares
     */
    function stPreviewDeposit(TRANCHE_UNIT _assets)
        external
        view
        returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated, uint256 totalTrancheShares);

    /**
     * @notice Previews the deposit of a specified amount of assets into the liquidity tranche
     * @param _assets The amount of assets to deposit, denominated in the liquidity tranche's tranche units
     * @return stateBeforeDeposit The state of the liquidity tranche before the deposit, after applying the pre-op sync
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units
     * @return totalTrancheShares The liquidity tranche supply after the pre-op sync mints the protocol fee shares
     * @return navToMintSharesAt The pre-deposit LT effective NAV (value deployed into the AMM or another market-making venue plus the idle liquidity-premium senior shares) to mint LT shares at
     */
    function ltPreviewDeposit(TRANCHE_UNIT _assets)
        external
        view
        returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated, uint256 totalTrancheShares, NAV_UNIT navToMintSharesAt);

    /**
     * @notice Previews a multi-asset LT deposit of (ST underlying + quote) by simulating the venue add
     * @dev NON-VIEW: routes the venue add through its simulation/query mode, so callers must staticcall it
     * @param _stAssets The ST underlying leg, in the ST asset's native units
     * @param _quoteAssets The quote asset leg
     * @return valueAllocated The NAV value of the LT assets the add would mint
     * @return navToMintSharesAt The pre-deposit LT effective NAV that LT shares would be minted against
     * @return ltAssetsOut The LT tranche assets the add would mint
     */
    function ltPreviewDepositMultiAsset(
        TRANCHE_UNIT _stAssets,
        uint256 _quoteAssets
    )
        external
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt, TRANCHE_UNIT ltAssetsOut);

    /**
     * @notice Previews a multi-asset LT redemption of _ltShares by simulating the proportional venue removal and the senior unwind
     * @dev NON-VIEW: routes the venue removal through its simulation/query mode, so callers must staticcall it
     * @param _ltShares The number of LT shares to redeem
     * @return stClaims The ST redemption asset claims that would be transferred to the receiver, denominated in the respective tranches' tranche units
     * @return quoteAssets The quote assets the removal would withdraw to the receiver
     */
    function ltPreviewRedeemMultiAsset(uint256 _ltShares) external returns (AssetClaims memory stClaims, uint256 quoteAssets);

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
     * @notice Returns the maximum amount of assets that can be deposited into the junior tranche
     * @param _receiver The address that will receive the JT shares equating to the deposited assets
     * @return assets The maximum amount of assets that can be deposited into the junior tranche, denominated in the junior tranche's tranche units
     */
    function jtMaxDeposit(address _receiver) external view returns (TRANCHE_UNIT assets);

    /**
     * @notice Returns the maximum amount of assets that can be withdrawn from the junior tranche
     * @param _owner The address that is withdrawing the assets
     * @return claimOnSTNAV The notional claims on ST assets that the junior tranche has denominated in kernel's NAV units
     * @return claimOnJTNAV The notional claims on JT assets that the junior tranche has denominated in kernel's NAV units
     * @return stMaxWithdrawableNAV The maximum amount of assets that can be withdrawn from the senior tranche, denominated in the kernel's NAV units
     * @return jtMaxWithdrawableNAV The maximum amount of assets that can be withdrawn from the junior tranche, denominated in the kernel's NAV units
     * @return totalTrancheSharesAfterMintingFees The total number of shares that exist in the junior tranche after minting any protocol fee shares post-sync, including virtual shares
     */
    function jtMaxWithdrawable(address _owner)
        external
        view
        returns (
            NAV_UNIT claimOnSTNAV,
            NAV_UNIT claimOnJTNAV,
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
     * @return claimOnLTNAV The notional claims on LT assets that the liquidity tranche has denominated in kernel's NAV units
     * @return ltMaxWithdrawableNAV The maximum amount of assets that can be withdrawn from the liquidity tranche, denominated in the kernel's NAV units
     * @return totalTrancheSharesAfterMintingFees The total number of shares that exist in the liquidity tranche after minting any protocol fee shares post-sync
     */
    function ltMaxWithdrawable(address _owner)
        external
        view
        returns (NAV_UNIT claimOnLTNAV, NAV_UNIT ltMaxWithdrawableNAV, uint256 totalTrancheSharesAfterMintingFees);

    /**
     * @notice Previews the deposit of a specified amount of assets into the junior tranche
     * @dev The kernel may decide to simulate the deposit and revert internally with the result
     * @dev Should revert if deposits are asynchronous
     * @param _assets The amount of assets to deposit, denominated in the junior tranche's tranche units
     * @return stateBeforeDeposit The state of the junior tranche before the deposit, after applying the pre-op sync
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units
     * @return totalTrancheShares The junior tranche supply after the pre-op sync mints the protocol fee shares
     */
    function jtPreviewDeposit(TRANCHE_UNIT _assets)
        external
        view
        returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated, uint256 totalTrancheShares);

    /**
     * @notice Previews the redemption of a specified number of shares from the junior tranche
     * @dev The kernel may decide to simulate the redemption and revert internally with the result
     * @dev Should revert if redemptions are asynchronous
     * @param _shares The number of shares to redeem
     * @return userClaim The distribution of assets that would be transferred to the receiver on redemption, denominated in the respective tranches' tranche units
     */
    function jtPreviewRedeem(uint256 _shares) external view returns (AssetClaims memory userClaim);
}
