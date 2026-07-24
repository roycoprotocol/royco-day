// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { AssetClaims, SyncedAccountingState, TrancheType } from "../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../libraries/Units.sol";

/**
 * @title IRoycoDayKernel
 * @notice Interface for the base Royco kernel contract
 * @dev The kernel contract is responsible for orchestrating all operations for every tranche (senior, junior, and liquidity) in a Royco market
 */
interface IRoycoDayKernel {
    /**
     * @notice Construction parameters for the Royco Kernel
     * @custom:field seniorTranche - The address of the Royco senior tranche associated with this kernel
     * @custom:field juniorTranche - The address of the Royco junior tranche associated with this kernel
     * @custom:field collateralAsset - The address of the coinvested collateral asset both the senior and junior tranches deposit
     * @custom:field accountant - The address of the accountant for the Royco market
     * @custom:field liquidityTranche - The address of the Royco liquidity tranche associated with this kernel
     * @custom:field ltAsset - The base asset of the liquidity tranche (the liquidity venue's market-making position token)
     * @custom:field enforceVaultSharesTransferWhitelist Whether to enforce the vault shares transfer whitelist
     */
    struct RoycoDayKernelConstructionParams {
        address seniorTranche;
        address juniorTranche;
        address collateralAsset;
        address accountant;
        address liquidityTranche;
        address ltAsset;
        bool enforceVaultSharesTransferWhitelist;
    }

    /**
     * @notice Initialization parameters for the Royco Kernel
     * @custom:field initialAuthority - The access manager for this kernel
     * @custom:field protocolFeeRecipient - The market's protocol fee recipient
     * @custom:field stSelfLiquidationBonusWAD - The market's configured ST self-liquidation bonus remitted to redeeming ST LPs when liquidation coverageUtilization threshold has been breached, scaled to WAD precision
     * @custom:field roycoBlacklist - The market's blacklist contract consulted on tranche balance updates (the null address disables blacklist screening)
     * @custom:field collateralAssetOracle - The collateral asset oracle pricing 1 whole collateral asset in NAV units
     * @custom:field stalenessThresholdSeconds - The maximum age in seconds an oracle price may have before it is considered stale
     * @custom:field sequencerUptimeFeed - The L2 sequencer uptime feed used to gate price queries (the null address when not applicable)
     * @custom:field gracePeriodSeconds - The grace period in seconds after the L2 sequencer is back up before oracle prices are trusted again
     */
    struct RoycoDayKernelInitParams {
        address initialAuthority;
        address protocolFeeRecipient;
        uint64 stSelfLiquidationBonusWAD;
        address roycoBlacklist;
        address collateralAssetOracle;
        uint48 stalenessThresholdSeconds;
        address sequencerUptimeFeed;
        uint48 gracePeriodSeconds;
    }

    /**
     * @notice Storage state for the Royco Day Kernel
     * @custom:storage-location erc7201:Royco.storage.RoycoDayKernelState
     * @custom:field protocolFeeRecipient - The market's configured protocol fee recipient
     * @custom:field stSelfLiquidationBonusWAD - The market's configured ST self-liquidation bonus remitted to redeeming ST LPs when liquidation coverageUtilization threshold has been breached, scaled to WAD precision
     * @custom:field totalCollateralAssets - The coinvested collateral assets held for the senior and junior tranches, in the collateral asset's units
     * @custom:field totalLTAssets - The yield bearing assets held by the liquidity tranche, in LT's asset units
     * @custom:field ltOwnedSeniorTrancheShares - The senior tranche shares held by the liquidity tranche (accumulated liquidity premium payments)
     * @custom:field roycoBlacklist - The market's blacklist contract consulted on tranche balance updates (the null address disables blacklist screening)
     * @custom:field collateralAssetOracle - The collateral asset oracle pricing 1 whole collateral asset in NAV units, also the clock the kernel pokes on every quoter-cached operation
     * @custom:field stalenessThresholdSeconds - The maximum age in seconds an oracle price may have before it is considered stale
     * @custom:field sequencerUptimeFeed - The L2 sequencer uptime feed used to gate price queries (the null address when not applicable)
     * @custom:field gracePeriodSeconds - The grace period in seconds after the L2 sequencer is back up before oracle prices are trusted again
     */
    struct RoycoDayKernelState {
        address protocolFeeRecipient;
        uint64 stSelfLiquidationBonusWAD;
        TRANCHE_UNIT totalCollateralAssets;
        TRANCHE_UNIT totalLTAssets;
        uint256 ltOwnedSeniorTrancheShares;
        address roycoBlacklist;
        address collateralAssetOracle;
        uint48 stalenessThresholdSeconds;
        address sequencerUptimeFeed;
        uint48 gracePeriodSeconds;
    }

    /**
     * @notice Immutables carrier passed to the kernel's delegatecall logic libraries so a moved body can reach the six
     *         kernel-level addresses it would otherwise read from an immutable (which a delegatecalled library cannot see)
     * @custom:field seniorTranche - The address of the Royco senior tranche associated with the kernel
     * @custom:field juniorTranche - The address of the Royco junior tranche associated with the kernel
     * @custom:field collateralAsset - The address of the coinvested collateral asset both the senior and junior tranches deposit
     * @custom:field liquidityTranche - The address of the Royco liquidity tranche associated with the kernel
     * @custom:field ltAsset - The base asset of the liquidity tranche (the liquidity venue's market-making position token)
     * @custom:field accountant - The address of the accountant for the Royco market
     */
    struct RoycoDayKernelImmutableState {
        address seniorTranche;
        address juniorTranche;
        address collateralAsset;
        address liquidityTranche;
        address ltAsset;
        address accountant;
    }

    /// @notice Emitted when the protocol fee recipient is updated
    /// @param protocolFeeRecipient The new protocol fee recipient
    event ProtocolFeeRecipientUpdated(address protocolFeeRecipient);

    /// @notice Emitted when the ST self-liquidation bonus is updated
    /// @param stSelfLiquidationBonusWAD The new ST self-liquidation bonus remitted to redeeming ST LPs when liquidation coverageUtilization threshold has been breached
    event SeniorTrancheSelfLiquidationBonusUpdated(uint64 stSelfLiquidationBonusWAD);

    /// @notice Emitted when the market's blacklist contract is updated
    /// @param roycoBlacklist The new blacklist contract address (the null address if screening is disabled)
    event RoycoBlacklistUpdated(address roycoBlacklist);

    /// @notice Emitted when the collateral asset oracle is updated
    /// @param collateralAssetOracle The new collateral asset oracle pricing 1 whole collateral asset in NAV units
    /// @param stalenessThresholdSeconds The new staleness threshold seconds
    event CollateralAssetOracleUpdated(address indexed collateralAssetOracle, uint48 stalenessThresholdSeconds);

    /// @notice Emitted when the L2 sequencer uptime feed (and its grace period) used to gate price queries is updated
    /// @param sequencerUptimeFeed The new L2 sequencer uptime feed (the null address if the check is disabled)
    /// @param gracePeriodSeconds The new grace period seconds
    event SequencerUptimeFeedUpdated(address indexed sequencerUptimeFeed, uint48 gracePeriodSeconds);

    /**
     * @notice Emitted when the kernel deploys its held liquidity-premium senior shares into the liquidity tranche's venue
     * @param stSharesReinvested The senior tranche shares drained from the kernel's held balance and deployed into the liquidity venue
     * @param ltAssetsMinted The liquidity tranche assets minted to the liquidity tranche by the deployment
     */
    event LiquidityPremiumReinvested(uint256 stSharesReinvested, TRANCHE_UNIT ltAssetsMinted);

    /**
     * @notice Emitted when a liquidity-premium reinvestment attempt does not execute, leaving the senior shares idle in the kernel
     * @param stSharesToReinvest The senior tranche shares the kernel attempted to deploy into the liquidity venue
     * @param minLTAssetsOut The slippage-bounded minimum liquidity tranche assets the deployment demanded
     * @param revertData The raw revert data returned by the venue, identifying a breached slippage gate versus any other add failure
     */
    event LiquidityPremiumReinvestmentFailed(uint256 stSharesToReinvest, TRANCHE_UNIT minLTAssetsOut, bytes revertData);

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

    /// @notice Thrown when a venue driver restricted to kernel self-calls is invoked by any other caller
    error ONLY_SELF();

    /// @notice Thrown when the to address is not whitelisted on the tranche
    error ACCOUNT_NOT_WHITELISTED_TRANCHE_LP(address to);

    /// @notice Thrown when the senior tranche self-liquidation bonus is set above 100% (WAD)
    error INVALID_SELF_LIQUIDATION_BONUS();

    /// @notice Thrown when the collateral asset oracle does not price this market's collateral asset
    error COLLATERAL_ASSET_ORACLE_MISMATCH();

    /// @notice Thrown when the staleness threshold seconds is zero
    error INVALID_STALENESS_THRESHOLD_SECONDS();

    /// @notice Thrown when a sequencer uptime feed is configured with a non-positive grace period
    error INVALID_GRACE_PERIOD_SECONDS();

    /// @notice Thrown when the collateral asset oracle's price is stale
    error STALE_PRICE();

    /// @notice Thrown when the collateral asset oracle's price is invalid
    error INVALID_PRICE();

    /// @notice Thrown when the price is incomplete
    error INCOMPLETE_PRICE();

    /// @notice Thrown when the L2 sequencer is reported down by the configured sequencer uptime feed
    error SEQUENCER_DOWN();

    /// @notice Thrown when the L2 sequencer's grace period has not fully elapsed since it was last restored
    error GRACE_PERIOD_NOT_OVER();

    /// @notice Thrown when an LT multi-asset deposit is made with zero of both constituent assets (collateral and quote)
    error MUST_DEPOSIT_NON_ZERO_ASSETS();

    /// @notice Retrieves the senior tranche address
    /// @return seniorTranche The address of the senior tranche for this Royco market
    function SENIOR_TRANCHE() external view returns (address seniorTranche);

    /// @notice Retrieves the junior tranche address
    /// @return juniorTranche The address of the junior tranche for this Royco market
    function JUNIOR_TRANCHE() external view returns (address juniorTranche);

    /// @notice Retrieves the coinvested collateral asset address
    /// @return collateralAsset The address of the coinvested collateral asset both the senior and junior tranches deposit
    function COLLATERAL_ASSET() external view returns (address collateralAsset);

    /// @notice Retrieves the liquidity tranche address
    /// @return liquidityTranche The address of the liquidity tranche for this Royco market
    function LIQUIDITY_TRANCHE() external view returns (address liquidityTranche);

    /// @notice Retrieves the liquidity tranche's base asset (the liquidity venue's market-making position token) address
    /// @return ltAsset The liquidity tranche's base asset address
    function LT_ASSET() external view returns (address ltAsset);

    /// @notice Retrieves the quote asset paired against the senior share in the liquidity venue
    /// @return quoteAsset The quote asset's address
    function QUOTE_ASSET() external view returns (address quoteAsset);

    /// @notice Retrieves the accountant address
    /// @return accountant The accountant responsible for maintaining this Royco market's accounting state and marking tranche NAVs to market
    function ACCOUNTANT() external view returns (address accountant);

    /// @notice Whether the market enforces the vault-shares transfer whitelist on tranche balance updates
    /// @return enforced True if transfer-whitelist screening is enforced for this market
    function ENFORCE_TRANCHE_WHITELIST_ON_TRANSFER() external view returns (bool enforced);

    /**
     * @notice Converts the specified collateral assets denominated in tranche units to their value in the kernel's NAV units
     * @param _collateralAssets The collateral assets denominated in tranche units to convert to the kernel's NAV units
     * @return value The specified collateral assets denominated in tranche units converted to the kernel's NAV units
     */
    function convertCollateralAssetsToValue(TRANCHE_UNIT _collateralAssets) external view returns (NAV_UNIT value);

    /**
     * @notice Converts the specified value denominated in the kernel's NAV units to collateral assets denominated in tranche units
     * @param _value The value denominated in the kernel's NAV units to convert to collateral assets denominated in tranche units
     * @return collateralAssets The specified value denominated in the kernel's NAV units converted to collateral assets denominated in tranche units
     */
    function convertValueToCollateralAssets(NAV_UNIT _value) external view returns (TRANCHE_UNIT collateralAssets);

    /**
     * @notice Converts the specified LT assets denominated in its tranche units to their value in the kernel's NAV units
     * @param _ltAssets The LT assets denominated in tranche units to convert to the kernel's NAV units
     * @return value The specified LT assets denominated in its tranche units converted to the kernel's NAV units
     */
    function convertLTAssetsToValue(TRANCHE_UNIT _ltAssets) external view returns (NAV_UNIT value);

    /**
     * @notice Converts the specified value denominated in the kernel's NAV units to assets denominated in LT's tranche units
     * @param _value The value denominated in the kernel's NAV units to convert to assets denominated in LT's tranche units
     * @return ltAssets The specified value denominated in the kernel's NAV units converted to assets denominated in LT's tranche units
     */
    function convertValueToLTAssets(NAV_UNIT _value) external view returns (TRANCHE_UNIT ltAssets);

    /**
     * @notice Returns the maximum amount of assets that can be deposited into the senior tranche
     * @param _receiver The address that will receive the ST shares equating to the deposited assets
     * @return assets The maximum amount of assets that can be deposited into the senior tranche, denominated in the senior tranche's tranche units
     */
    function stMaxDeposit(address _receiver) external view returns (TRANCHE_UNIT assets);

    /**
     * @notice Returns the maximum amount of assets that can be withdrawn from the senior tranche
     * @param _owner The address that is withdrawing the assets
     * @return stClaimNAV The senior tranche's total notional claim on the collateral NAV, denominated in kernel's NAV units
     * @return stMaxWithdrawableNAV The maximum amount of assets that can be withdrawn from the senior tranche, denominated in the kernel's NAV units
     * @return totalTrancheSharesAfterMintingFees The total number of shares that exist in the senior tranche after the post-sync mint of its protocol fee shares and liquidity premium shares
     */
    function stMaxWithdrawable(address _owner)
        external
        view
        returns (NAV_UNIT stClaimNAV, NAV_UNIT stMaxWithdrawableNAV, uint256 totalTrancheSharesAfterMintingFees);

    /**
     * @notice Returns the maximum amount of assets that can be deposited into the junior tranche
     * @param _receiver The address that will receive the JT shares equating to the deposited assets
     * @return assets The maximum amount of assets that can be deposited into the junior tranche, denominated in the junior tranche's tranche units
     */
    function jtMaxDeposit(address _receiver) external view returns (TRANCHE_UNIT assets);

    /**
     * @notice Returns the maximum amount of assets that can be withdrawn from the junior tranche
     * @param _owner The address that is withdrawing the assets
     * @return jtClaimNAV The junior tranche's total notional claim on the collateral NAV, denominated in kernel's NAV units
     * @return jtMaxWithdrawableNAV The maximum amount of assets that can be withdrawn from the junior tranche, denominated in the kernel's NAV units
     * @return totalTrancheSharesAfterMintingFees The total number of shares that exist in the junior tranche after minting any protocol fee shares post-sync
     */
    function jtMaxWithdrawable(address _owner)
        external
        view
        returns (NAV_UNIT jtClaimNAV, NAV_UNIT jtMaxWithdrawableNAV, uint256 totalTrancheSharesAfterMintingFees);

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
     * @return totalTrancheSharesAfterMintingFees The total number of shares that exist in the liquidity tranche post-sync (the liquidity tranche mints no protocol fee shares on a sync)
     */
    function ltMaxWithdrawable(address _owner)
        external
        view
        returns (NAV_UNIT claimOnLTNAV, NAV_UNIT ltMaxWithdrawableNAV, uint256 totalTrancheSharesAfterMintingFees);

    /**
     * @notice Returns the maximum amount of assets that can be withdrawn from the liquidity tranche via a multi-asset redemption
     * @dev A multi-asset redemption redeems its senior tranche share legs (the proportional removal's ST leg and the idle liquidity
     *      premium pile) in-flow, shrinking the liquidity requirement alongside the withdrawal, so its bound is at least the
     *      in-kind bound, and strictly exceeds it whenever the liquidity requirement binds and the removal's senior-share
     *      legs carry value
     * @dev NON-VIEW: sizes the requirement reduction through the venue removal's execute-and-revert preview, which mutates no state net
     * @param _owner The address that is withdrawing the assets
     * @return claimOnLTNAV The notional claims on LT assets that the liquidity tranche has denominated in kernel's NAV units
     * @return ltMaxWithdrawableNAV The maximum amount of assets that can be withdrawn multi-asset, denominated in the kernel's NAV units
     * @return totalTrancheSharesAfterMintingFees The total number of shares that exist in the liquidity tranche post-sync (the liquidity tranche mints no protocol fee shares on a sync)
     */
    function ltMaxWithdrawableMultiAsset(address _owner)
        external
        returns (NAV_UNIT claimOnLTNAV, NAV_UNIT ltMaxWithdrawableNAV, uint256 totalTrancheSharesAfterMintingFees);

    /**
     * @notice Synchronizes and persists the raw and effective NAVs of all tranches
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
     * @notice Previews a synchronization of the raw and effective NAVs of all tranches
     * @dev Does not mutate any state
     * @param _trancheType An enumerator indicating which tranche to execute this preview for
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     * @return claims The asset claims that the specified tranche has denominated in tranche-native units
     * @return totalTrancheShares The total number of shares that exist in the specified tranche after the post-sync mint of its accrued shares: the protocol fee shares for the senior and junior tranches, plus the liquidity premium shares for the senior tranche (the liquidity tranche mints none)
     */
    function previewSyncTrancheAccounting(TrancheType _trancheType)
        external
        view
        returns (SyncedAccountingState memory state, AssetClaims memory claims, uint256 totalTrancheShares);

    /**
     * @notice Processes the deposit of a specified amount of assets into the senior tranche
     * @dev Assumes that the funds are transferred to the kernel before the deposit call is made
     * @dev A preview never returns: the flow unwinds every mutation by reverting with SIMULATION_RESULT carrying the ABI encoded return values
     * @param _isPreview Whether this is a preview of the operation which must not mutate state
     * @param _assets The amount of assets to deposit, denominated in the senior tranche's tranche units
     * @return depositNAV The value of the assets deposited, denominated in the kernel's NAV units
     * @return effectiveNAV The NAV at which the shares will be minted, exclusive of depositNAV
     * @return totalTrancheShares The tranche's total share supply after the sync's premium and protocol fee mints, the supply the shares price against
     */
    function stDeposit(bool _isPreview, TRANCHE_UNIT _assets) external returns (NAV_UNIT depositNAV, NAV_UNIT effectiveNAV, uint256 totalTrancheShares);

    /**
     * @notice Processes the redemption of a specified number of shares from the senior tranche
     * @dev The function is expected to transfer the collateral assets directly to the receiver, based on the redemption claims
     * @dev A preview never returns: the flow unwinds every mutation by reverting with SIMULATION_RESULT carrying the ABI encoded return values
     * @param _isPreview Whether this is a preview of the operation which must not mutate state
     * @param _shares The number of shares to redeem
     * @param _receiver The address that is receiving the assets
     * @return userAssetClaims The distribution of assets that were transferred to the receiver on redemption
     */
    function stRedeem(bool _isPreview, uint256 _shares, address _receiver) external returns (AssetClaims memory userAssetClaims);

    /**
     * @notice Processes the deposit of a specified amount of assets into the junior tranche
     * @dev Assumes that the funds are transferred to the kernel before the deposit call is made
     * @dev A preview never returns: the flow unwinds every mutation by reverting with SIMULATION_RESULT carrying the ABI encoded return values
     * @param _isPreview Whether this is a preview of the operation which must not mutate state
     * @param _assets The amount of assets to deposit, denominated in the junior tranche's tranche units
     * @return depositNAV The value of the assets deposited, denominated in the kernel's NAV units
     * @return effectiveNAV The NAV at which the shares will be minted, exclusive of depositNAV
     * @return totalTrancheShares The tranche's total share supply after the sync's premium and protocol fee mints, the supply the shares price against
     */
    function jtDeposit(bool _isPreview, TRANCHE_UNIT _assets) external returns (NAV_UNIT depositNAV, NAV_UNIT effectiveNAV, uint256 totalTrancheShares);

    /**
     * @notice Processes the redemption of a specified number of shares from the junior tranche
     * @dev The function is expected to transfer the collateral assets directly to the receiver, based on the redemption claims
     * @dev A preview never returns: the flow unwinds every mutation by reverting with SIMULATION_RESULT carrying the ABI encoded return values
     * @param _isPreview Whether this is a preview of the operation which must not mutate state
     * @param _shares The number of shares to redeem
     * @param _receiver The address that is receiving the assets
     * @return userAssetClaims The distribution of assets that were transferred to the receiver on redemption
     */
    function jtRedeem(bool _isPreview, uint256 _shares, address _receiver) external returns (AssetClaims memory userAssetClaims);

    /**
     * @notice Processes the deposit of a specified amount of assets into the liquidity tranche
     * @dev An in-kind LT deposit mints no new senior shares and only deepens liquidity, so it is enabled in every market state (including fixed-term)
     * @dev A preview never returns: the flow unwinds every mutation by reverting with SIMULATION_RESULT carrying the ABI encoded return values
     * @param _isPreview Whether this is a preview of the operation which must not mutate state
     * @param _assets The amount of assets (the liquidity venue's position token) to deposit, denominated in the liquidity tranche's tranche units
     * @return depositNAV The value of the assets deposited, denominated in the kernel's NAV units
     * @return effectiveNAV The NAV at which the shares will be minted, exclusive of depositNAV
     * @return totalTrancheShares The tranche's total share supply after the sync's premium and protocol fee mints, the supply the shares price against
     */
    function ltDeposit(bool _isPreview, TRANCHE_UNIT _assets) external returns (NAV_UNIT depositNAV, NAV_UNIT effectiveNAV, uint256 totalTrancheShares);

    /**
     * @notice Processes the redemption of a specified number of shares from the liquidity tranche
     * @dev A preview never returns: the flow unwinds every mutation by reverting with SIMULATION_RESULT carrying the ABI encoded return values
     * @param _isPreview Whether this is a preview of the operation which must not mutate state
     * @param _shares The number of shares to redeem
     * @param _receiver The address that is receiving the assets
     * @return userAssetClaims The distribution of assets that were transferred to the receiver on redemption
     */
    function ltRedeem(bool _isPreview, uint256 _shares, address _receiver) external returns (AssetClaims memory userAssetClaims);

    /**
     * @notice Atomically enters the liquidity tranche with the LT assets' constituent assets: deposits collateral (minting senior
     *         shares), adds (senior shares + quote) into the liquidity venue to mint the LT tranche assets, then deposits them into the LT
     * @dev Assumes the collateral and quote have been transferred to the kernel before this call (by the LT tranche)
     * @dev Enabled in a PERPETUAL market state, and in a fixed-term market only for a quote-only deposit (_collateralAssets == 0) that mints no senior shares, an ST-leg deposit reverts in a fixed-term market
     * @dev The combined new senior exposure is gated by the market's coverage and liquidity requirements, reverts if either is unsatisfied
     * @dev A preview never returns: the flow unwinds every mutation by reverting with SIMULATION_RESULT carrying the ABI encoded return values
     * @param _isPreview Whether this is a preview of the operation which must not mutate state
     * @param _collateralAssets The amount of collateral to deposit for the senior leg, denominated in tranche units
     * @param _quoteAssets The amount of quote asset to add as the second venue leg
     * @param _minLTAssetsOut The minimum LT tranche assets the liquidity add must mint (slippage bound against an unfavorable venue state)
     * @return depositNAV The value of the minted LT tranche assets, denominated in the kernel's NAV units
     * @return effectiveNAV The LT effective NAV at which the LT shares will be minted (pre-deposit)
     * @return ltAssetsOut The amount of LT tranche assets minted and credited to the liquidity tranche
     */
    function ltDepositMultiAsset(
        bool _isPreview,
        TRANCHE_UNIT _collateralAssets,
        uint256 _quoteAssets,
        TRANCHE_UNIT _minLTAssetsOut
    )
        external
        returns (NAV_UNIT depositNAV, NAV_UNIT effectiveNAV, TRANCHE_UNIT ltAssetsOut);

    /**
     * @notice Atomically exits the liquidity tranche to the LT assets' constituent assets: proportionally removes the LT-asset slice,
     *         redeems the venue-held senior shares to collateral, and returns (collateral + quote) to the receiver
     * @dev A preview never returns: the flow unwinds every mutation by reverting with SIMULATION_RESULT carrying the ABI encoded return values
     * @param _isPreview Whether this is a preview of the operation which must not mutate state
     * @param _ltShares The number of LT shares being redeemed (used to size the proportional LT-asset slice)
     * @param _minSTSharesOut The minimum senior tranche shares the proportional removal must return (slippage bound)
     * @param _minQuoteAssetsOut The minimum quote to return (slippage bound)
     * @param _receiver The address that receives the collateral and quote
     * @return stClaims The ST redemption asset claims transferred to the receiver (its collateral asset leg)
     * @return quoteAssets The quote assets returned to the receiver
     */
    function ltRedeemMultiAsset(
        bool _isPreview,
        uint256 _ltShares,
        uint256 _minSTSharesOut,
        uint256 _minQuoteAssetsOut,
        address _receiver
    )
        external
        returns (AssetClaims memory stClaims, uint256 quoteAssets);

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
     * @notice Sets the collateral asset oracle pricing 1 whole collateral asset in NAV units
     * @param _collateralAssetOracle The new collateral asset oracle
     * @param _stalenessThresholdSeconds The new staleness threshold seconds
     * @param _syncBeforeUpdate Whether to sync the tranche accounting before updating the collateral asset oracle
     */
    function setCollateralAssetOracle(address _collateralAssetOracle, uint48 _stalenessThresholdSeconds, bool _syncBeforeUpdate) external;

    /**
     * @notice Sets the L2 sequencer uptime feed and grace period used to gate price queries
     * @param _sequencerUptimeFeed The new L2 sequencer uptime feed (set to the null address to disable the check)
     * @param _gracePeriodSeconds The new grace period in seconds that must elapse after the L2 sequencer is restored before trusting the price
     */
    function setSequencerUptimeFeed(address _sequencerUptimeFeed, uint48 _gracePeriodSeconds) external;

    /// @notice Returns the collateral asset oracle pricing 1 whole collateral asset in NAV units
    /// @return collateralAssetOracle The collateral asset oracle
    function getCollateralAssetOracle() external view returns (address collateralAssetOracle);

    /**
     * @notice Pre-balance update hook for the tranche
     * @dev This function should revert if the balance update is invalid
     * @dev Should be called before every tranche share balance update
     * @param _caller The address that is calling the balance update
     * @param _from The address from which the balance is being updated
     * @param _to The address to which the balance is being updated
     * @param _value The amount of the balance being updated
     */
    function preTrancheBalanceUpdateHook(address _caller, address _from, address _to, uint256 _value) external;

    /**
     * @notice Reverts if any of the specified accounts is blacklisted by the market's configured blacklist
     * @dev No-op when no blacklist is configured (the null address disables screening)
     * @dev Exposes the market's blacklist screening to periphery contracts whose value flows settle outside the tranche balance update hooks
     * @param _accounts The addresses of the accounts to screen
     */
    function enforceNotBlacklisted(address[] memory _accounts) external view;

    /// @notice Retrieves the state of the Royco kernel
    /// @return state The Royco kernel's state, including the protocol fee recipient and the kernel's controlled tranche and base assets
    function getState() external view returns (RoycoDayKernelState memory state);

    // =============================
    // Liquidity Tranche Venue Drivers
    // =============================

    /**
     * @notice Adds a senior tranche share and quote asset position into the liquidity venue and returns the liquidity tranche assets minted
     * @param _isPreview Whether this is a preview of the operation which must not mutate state
     * @param _seniorShares The exact amount of senior tranche shares to add into the liquidity venue
     * @param _quoteAssets The exact amount of quote assets to add into the liquidity venue
     * @param _minLTAssetsOut The minimum liquidity tranche assets that must be minted, bounding the add's slippage
     * @return ltAssets The liquidity tranche assets minted by the add
     * @return depositNAV The value of the minted liquidity tranche assets against the post-add venue state
     * @return postOpLTRawNAV The post-op liquidity tranche raw NAV marked against the post-add venue state, the mark the post-op sync enforces at
     */
    function addLiquidity(
        bool _isPreview,
        uint256 _seniorShares,
        uint256 _quoteAssets,
        TRANCHE_UNIT _minLTAssetsOut
    )
        external
        returns (TRANCHE_UNIT ltAssets, NAV_UNIT depositNAV, NAV_UNIT postOpLTRawNAV);

    /**
     * @notice Proportionally removes a slice of liquidity tranche assets from the liquidity venue into its senior tranche share and quote asset constituents
     * @param _isPreview Whether this is a preview of the operation which must not mutate state
     * @param _ltAssets The exact liquidity tranche assets to burn
     * @param _minSTSharesOut The minimum senior tranche shares that must be withdrawn, bounding the removal's slippage
     * @param _minQuoteAssetsOut The minimum quote assets that must be withdrawn, bounding the removal's slippage
     * @param _quoteAssetsReceiver The recipient of the withdrawn quote assets, the withdrawn senior shares are returned to the kernel for the combined senior unwind
     * @return stShares The senior tranche shares withdrawn by the removal
     * @return quoteAssets The quote assets withdrawn by the removal
     * @return postOpLTRawNAV The post-op liquidity tranche raw NAV marked against the post-remove venue state, the mark the post-op sync enforces at
     */
    function removeLiquidity(
        bool _isPreview,
        TRANCHE_UNIT _ltAssets,
        uint256 _minSTSharesOut,
        uint256 _minQuoteAssetsOut,
        address _quoteAssetsReceiver
    )
        external
        returns (uint256 stShares, uint256 quoteAssets, NAV_UNIT postOpLTRawNAV);

    /**
     * @notice Attempts to reinvest the liquidity tranche's idle liquidity-premium senior shares into its market-making inventory
     * @dev Tolerates reversions gracefully so it is non-blocking for the tranche operation that invokes it
     * @param _stSharesToReinvest The amount of idle liquidity-premium senior shares to reinvest, or type(uint256).max to reinvest the entire idle balance
     * @param _stEffectiveNAV The synced senior tranche effective NAV used to value the liquidity tranche's idle premium senior shares
     * @param _totalSTShares The senior tranche share supply after the liquidity premium and senior tranche protocol fee shares are minted, the denominator of the senior share rate
     */
    function attemptLiquidityPremiumReinvestment(uint256 _stSharesToReinvest, NAV_UNIT _stEffectiveNAV, uint256 _totalSTShares) external;
}
