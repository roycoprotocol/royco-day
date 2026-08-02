// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { AssetClaims, DispatchMode, Operation, SyncedAccountingState, TrancheType } from "../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../libraries/Units.sol";

/**
 * @title IRoycoDayKernel
 * @notice Interface for the base Royco kernel contract
 * @dev The kernel contract is responsible for orchestrating all operations for every tranche (senior, junior, and liquidity) in a Royco market
 */
interface IRoycoDayKernel {
    /**
     * @notice Initialization parameters for the Royco Kernel
     * @custom:field initialAuthority - The access manager for this kernel
     * @custom:field seniorTranche - The address of the Royco senior tranche associated with this kernel
     * @custom:field juniorTranche - The address of the Royco junior tranche associated with this kernel
     * @custom:field liquidityProviderTranche - The address of the Royco liquidity provider tranche associated with this kernel
     * @custom:field collateralAsset - The address of the coinvested collateral asset both the senior and junior tranches deposit
     * @custom:field lptAsset - The base asset of the liquidity provider tranche (the liquidity venue's market-making position token)
     * @custom:field quoteAsset - The quote asset paired against the senior share in the liquidity venue, validated against the venue's registration
     * @custom:field accountant - The address of the accountant for the Royco market
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
        address seniorTranche;
        address juniorTranche;
        address liquidityProviderTranche;
        address collateralAsset;
        address lptAsset;
        address quoteAsset;
        address accountant;
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
     * @custom:field seniorTranche - The address of the Royco senior tranche associated with the kernel
     * @custom:field stSelfLiquidationBonusWAD - The market's configured ST self-liquidation bonus remitted to redeeming ST LPs when liquidation coverageUtilization threshold has been breached, scaled to WAD precision
     * @custom:field juniorTranche - The address of the Royco junior tranche associated with the kernel
     * @custom:field liquidityProviderTranche - The address of the Royco liquidity provider tranche associated with the kernel
     * @custom:field collateralAsset - The address of the coinvested collateral asset both the senior and junior tranches deposit
     * @custom:field lptAsset - The base asset of the liquidity provider tranche (the liquidity venue's market-making position token)
     * @custom:field lptAssetDecimals - The LPT asset's decimals, from which one whole LPT asset (10 ** decimals) is derived
     * @custom:field quoteAsset - The quote asset paired against the senior share in the liquidity venue
     * @custom:field accountant - The address of the accountant for the Royco market
     * @custom:field protocolFeeRecipient - The market's configured protocol fee recipient
     * @custom:field roycoBlacklist - The market's blacklist contract consulted on tranche balance updates (the null address disables blacklist screening)
     * @custom:field collateralAssetOracle - The collateral asset oracle pricing 1 whole collateral asset in NAV units, also the clock the kernel pokes on every price-cached operation
     * @custom:field stalenessThresholdSeconds - The maximum age in seconds an oracle price may have before it is considered stale
     * @custom:field collateralAssetDecimals - The collateral asset's decimals, from which one whole collateral asset (10 ** decimals) is derived
     * @custom:field sequencerUptimeFeed - The L2 sequencer uptime feed used to gate price queries (the null address when not applicable)
     * @custom:field gracePeriodSeconds - The grace period in seconds after the L2 sequencer is back up before oracle prices are trusted again
     * @custom:field totalCollateralAssets - The coinvested collateral assets held for the senior and junior tranches, in the collateral asset's units
     * @custom:field totalLPTAssets - The yield bearing assets held by the liquidity provider tranche, in LPT's asset units
     * @custom:field lptOwnedSeniorTrancheShares - The senior tranche shares held by the liquidity provider tranche (accumulated liquidity premium payments)
     */
    struct RoycoDayKernelState {
        // Slot 0
        address seniorTranche;
        uint64 stSelfLiquidationBonusWAD;
        // Slot 1
        address juniorTranche;
        // Slot 2
        address liquidityProviderTranche;
        // Slot 3
        address collateralAsset;
        uint64 oneWholeCollateralAsset;
        // Slot 4
        address lptAsset;
        uint64 oneWholeLPTAsset;
        // Slot 5
        address quoteAsset;
        // Slot 6
        address accountant;
        // Slot 7
        address protocolFeeRecipient;
        // Slot 8
        address roycoBlacklist;
        // Slot 9
        address collateralAssetOracle;
        uint48 stalenessThresholdSeconds;
        // Slot 10
        address sequencerUptimeFeed;
        uint48 gracePeriodSeconds;
        // Slot 11-13
        TRANCHE_UNIT totalCollateralAssets;
        TRANCHE_UNIT totalLPTAssets;
        uint256 lptOwnedSeniorTrancheShares;
    }

    /**
     * @notice Immutable state variables for the Royco Day Kernel
     * @custom:field seniorTranche - The address of the Royco senior tranche associated with the kernel
     * @custom:field juniorTranche - The address of the Royco junior tranche associated with the kernel
     * @custom:field collateralAsset - The address of the coinvested collateral asset both the senior and junior tranches deposit
     * @custom:field liquidityProviderTranche - The address of the Royco liquidity provider tranche associated with the kernel
     * @custom:field lptAsset - The base asset of the liquidity provider tranche (the liquidity venue's market-making position token)
     * @custom:field quoteAsset - The quote asset paired against the senior share in the liquidity venue
     * @custom:field accountant - The address of the accountant for the Royco market
     */
    struct RoycoDayKernelImmutableState {
        address seniorTranche;
        address juniorTranche;
        address collateralAsset;
        address liquidityProviderTranche;
        address lptAsset;
        address quoteAsset;
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

    /**
     * @notice Emitted when the collateral asset oracle is updated
     * @param collateralAssetOracle The new collateral asset oracle pricing 1 whole collateral asset in NAV units
     * @param stalenessThresholdSeconds The new staleness threshold seconds
     */
    event CollateralAssetOracleUpdated(address indexed collateralAssetOracle, uint48 stalenessThresholdSeconds);

    /**
     * @notice Emitted when the L2 sequencer uptime feed (and its grace period) used to gate price queries is updated
     * @param sequencerUptimeFeed The new L2 sequencer uptime feed (the null address if the check is disabled)
     * @param gracePeriodSeconds The new grace period seconds
     */
    event SequencerUptimeFeedUpdated(address indexed sequencerUptimeFeed, uint48 gracePeriodSeconds);

    /// @notice Emitted when a pre-operation tranche accounting synchronization settles
    /// @param resultingState The resulting market state after synchronizing the tranche accounting
    event PreOpTrancheAccountingSynced(SyncedAccountingState resultingState);

    /**
     * @notice Emitted when a post-operation tranche accounting synchronization settles
     * @param op The operation the synchronization settled
     * @param resultingState The resulting market state after synchronizing the tranche accounting
     */
    event PostOpTrancheAccountingSynced(Operation op, SyncedAccountingState resultingState);

    /**
     * @notice Emitted when the kernel deploys its held liquidity-premium senior shares into the liquidity provider tranche's venue
     * @param stSharesReinvested The senior tranche shares drained from the kernel's held balance and deployed into the liquidity venue
     * @param lptAssetsMinted The liquidity provider tranche assets minted to the liquidity provider tranche by the deployment
     */
    event LiquidityPremiumReinvested(uint256 stSharesReinvested, TRANCHE_UNIT lptAssetsMinted);

    /**
     * @notice Emitted when a liquidity-premium reinvestment attempt does not execute, leaving the senior shares idle in the kernel
     * @param stSharesToReinvest The senior tranche shares the kernel attempted to deploy into the liquidity venue
     * @param minLPTAssetsOut The slippage-bounded minimum liquidity provider tranche assets the deployment demanded
     * @param revertData The raw revert data returned by the venue, identifying a breached slippage gate versus any other add failure
     */
    event LiquidityPremiumReinvestmentFailed(uint256 stSharesToReinvest, TRANCHE_UNIT minLPTAssetsOut, bytes revertData);

    /// @notice Thrown when the tranche and the kernel's corresponding tranche assets don't match
    error TRANCHE_AND_KERNEL_ASSETS_MISMATCH();

    /// @notice Thrown when the caller of a permissioned function isn't the market's liquidity provider tranche
    error ONLY_LIQUIDITY_PROVIDER_TRANCHE();

    /// @notice Thrown when an LP is attempting to deposit into or redeem from the market while it is in a fixed term state
    error DISABLED_IN_FIXED_TERM_STATE();

    /// @notice Thrown when a deposit would mint zero tranche shares (a dust amount that prices to zero shares)
    error MUST_MINT_NON_ZERO_SHARES();

    /// @notice Thrown when a redemption is requested with zero shares
    error MUST_REDEMPTION_NON_ZERO_SHARES();

    /// @notice Thrown when the caller of a permissioned function isn't the market's senior, junior, or liquidity provider tranche
    error ONLY_TRANCHE();

    /// @notice Thrown when a venue driver restricted to kernel self-calls is invoked by any other caller
    error ONLY_SELF();

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

    /// @notice Thrown when the L2 sequencer is reported down by the configured sequencer uptime feed
    error SEQUENCER_DOWN();

    /// @notice Thrown when the L2 sequencer's grace period has not fully elapsed since it was last restored
    error GRACE_PERIOD_NOT_OVER();

    /// @notice Thrown when the market's coverage requirement is violated
    error COVERAGE_REQUIREMENT_VIOLATED();

    /// @notice Thrown when the market's liquidity requirement is violated
    error LIQUIDITY_REQUIREMENT_VIOLATED();

    /// @notice Thrown when the collateral asset's decimals are greater than 18
    error INVALID_COLLATERAL_ASSET_DECIMALS();

    /// @notice Thrown when the LPT asset's decimals are greater than 18
    error INVALID_LPT_ASSET_DECIMALS();

    /// @notice Retrieves the senior tranche address
    /// @return seniorTranche The address of the senior tranche for this Royco market
    function seniorTranche() external view returns (address seniorTranche);

    /// @notice Retrieves the junior tranche address
    /// @return juniorTranche The address of the junior tranche for this Royco market
    function juniorTranche() external view returns (address juniorTranche);

    /// @notice Retrieves the coinvested collateral asset address
    /// @return collateralAsset The address of the coinvested collateral asset both the senior and junior tranches deposit
    function collateralAsset() external view returns (address collateralAsset);

    /// @notice Retrieves the liquidity provider tranche address
    /// @return liquidityProviderTranche The address of the liquidity provider tranche for this Royco market
    function liquidityProviderTranche() external view returns (address liquidityProviderTranche);

    /// @notice Retrieves the liquidity provider tranche's base asset (the liquidity venue's market-making position token) address
    /// @return lptAsset The liquidity provider tranche's base asset address
    function lptAsset() external view returns (address lptAsset);

    /// @notice Retrieves the quote asset paired against the senior share in the liquidity venue
    /// @return quoteAsset The quote asset's address
    function quoteAsset() external view returns (address quoteAsset);

    /// @notice Retrieves the accountant address
    /// @return accountant The accountant responsible for maintaining this Royco market's accounting state and marking tranche NAVs to market
    function accountant() external view returns (address accountant);

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
     * @notice Converts the specified LPT assets denominated in its tranche units to their value in the kernel's NAV units
     * @param _lptAssets The LPT assets denominated in tranche units to convert to the kernel's NAV units
     * @return value The specified LPT assets denominated in its tranche units converted to the kernel's NAV units
     */
    function convertLPTAssetsToValue(TRANCHE_UNIT _lptAssets) external view returns (NAV_UNIT value);

    /**
     * @notice Converts the specified value denominated in the kernel's NAV units to assets denominated in LPT's tranche units
     * @param _value The value denominated in the kernel's NAV units to convert to assets denominated in LPT's tranche units
     * @return lptAssets The specified value denominated in the kernel's NAV units converted to assets denominated in LPT's tranche units
     */
    function convertValueToLPTAssets(NAV_UNIT _value) external view returns (TRANCHE_UNIT lptAssets);

    /**
     * @notice Queries the collateral asset oracle for the value of 1 whole collateral asset in NAV units
     * @dev Always prices the oracle live, never through the operation's cache
     * @dev The reported price is gated by the L2 sequencer, staleness, and non-zero price checks
     * @return collateralAssetPrice The value of 1 whole collateral asset in NAV units
     */
    function queryCollateralAssetOracle() external view returns (NAV_UNIT collateralAssetPrice);

    /**
     * @notice Queries the liquidity venue for the value of 1 whole LPT asset in NAV units
     * @dev Always prices the venue live, never through the operation's cache
     * @dev Implemented by the concrete liquidity venue against its manipulation-resistant venue oracle
     * @return lptAssetPrice The value of 1 whole LPT asset in NAV units
     */
    function queryLPTAssetOracle() external view returns (NAV_UNIT lptAssetPrice);

    /**
     * @notice Returns the maximum amount of assets that can be deposited in-kind into the specified tranche
     * @dev Only callable by one of the market's tranches: the queried tranche is the calling tranche
     * @param _receiver The address that will receive the tranche shares equating to the deposited assets
     * @return assets The maximum amount of assets that can be deposited into the calling tranche, denominated in its tranche units
     */
    function inkindMaxDeposit(address _receiver) external view returns (TRANCHE_UNIT assets);

    /**
     * @notice Returns the maximum number of shares that can be redeemed in-kind from the calling tranche, unbounded by any owner's balance
     * @dev Only callable by one of the market's tranches: the queried tranche is the calling tranche
     * @param _owner The address that is redeeming the shares
     * @return maxRedeemableShares The maximum number of shares that can be redeemed from the calling tranche
     */
    function inkindMaxRedeemable(address _owner) external view returns (uint256 maxRedeemableShares);

    /**
     * @notice Returns the maximum number of shares that can be redeemed from the liquidity provider tranche via a multi-asset redemption, unbounded by any owner's balance
     * @dev A multi-asset redemption redeems its senior tranche share legs (the proportional removal's ST leg and the idle liquidity
     *      premium pile) in-flow, shrinking the liquidity requirement alongside the withdrawal, so its bound is at least the
     *      in-kind bound, and strictly exceeds it whenever the liquidity requirement binds and the removal's senior-share
     *      legs carry value
     * @dev NON-VIEW: sizes the requirement reduction through the venue removal's execute-and-revert preview, which mutates no state net
     * @param _owner The address that is redeeming the shares
     * @return maxRedeemableShares The maximum number of shares that can be redeemed multi-asset from the liquidity provider tranche
     */
    function lptMaxRedeemableMultiAsset(address _owner) external returns (uint256 maxRedeemableShares);

    /**
     * @notice Synchronizes and persists the raw and effective NAVs of all tranches
     * @dev Only executes a pre-op sync because there is no operation being executed in the same call as this sync
     * @dev Never deploys the idle liquidity-premium senior shares: the pool hook routes this sync from inside the venue's
     *      own frame, where a deployment's venue add would re-enter it
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function syncTrancheAccounting() external returns (SyncedAccountingState memory state);

    /**
     * @notice Synchronizes and persists the raw and effective NAVs of all tranches, returning the specified tranche's post-sync claims and supply
     * @dev Only executes a pre-op sync because there is no operation being executed in the same call as this sync
     * @dev Syncs every tranche exactly as `syncTrancheAccounting` does, the tranche type only scopes the claims and supply returned alongside the state
     * @dev The executed counterpart of `previewSyncTrancheAccountingFor`: it returns the same figures against the same accounting state, but commits them
     * @param _trancheType An enumerator indicating which tranche to return claims and total tranche shares for
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     * @return claims The asset claims that the specified tranche has denominated in tranche-native units
     * @return totalTrancheShares The total number of shares that exist in the specified tranche after the post-sync mint of its accrued shares: the protocol fee shares for the senior and junior tranches, plus the liquidity premium shares for the senior tranche (the liquidity provider tranche mints none)
     */
    function syncTrancheAccountingFor(TrancheType _trancheType)
        external
        returns (SyncedAccountingState memory state, AssetClaims memory claims, uint256 totalTrancheShares);

    /**
     * @notice Syncs the tranche accounting and attempts to reinvest the liquidity provider tranche's idle liquidity-premium senior shares into its market-making inventory
     * @dev The on-demand deployment path: a sync never deploys the pile, so idle premium leaves the kernel only through an operation's reinvestment tail or this entrypoint
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
     * @return totalTrancheShares The total number of shares that exist in the specified tranche after the post-sync mint of its accrued shares: the protocol fee shares for the senior and junior tranches, plus the liquidity premium shares for the senior tranche (the liquidity provider tranche mints none)
     */
    function previewSyncTrancheAccountingFor(TrancheType _trancheType)
        external
        view
        returns (SyncedAccountingState memory state, AssetClaims memory claims, uint256 totalTrancheShares);

    /**
     * @notice Processes the in-kind deposit of a specified amount of the calling tranche's own assets into it
     * @dev Only callable by one of the market's tranches: the deposited tranche is the calling tranche
     * @dev Assumes that the funds are transferred to the kernel before the deposit call is made
     * @dev Prices the shares at the tranche's pre-deposit effective NAV against the post-sync supply and mints them to the receiver
     * @dev ST and JT deposits are enabled only in a PERPETUAL market state, the ST deposit granted that the market's coverage and liquidity requirements are satisfied post-deposit
     * @dev An in-kind LPT deposit mints no new senior shares and only deepens liquidity, so it is enabled in every market state (including fixed-term) and enforces no requirements
     * @dev A preview never returns: the flow unwinds every mutation by reverting with SIMULATION_RESULT carrying the ABI encoded return values
     * @param _mode The dispatch mode: SIMULATE computes the operation and unwinds every mutation by reverting with its result, EXECUTE settles it
     * @param _assets The amount of assets to deposit, denominated in the calling tranche's tranche units
     * @param _caller The address that initiated the deposit on the tranche, screened with the receiver against the market's blacklist, the null address for a simulation's synthetic caller
     * @param _receiver The address that receives the minted tranche shares
     * @return trancheSharesMinted The number of tranche shares minted to the receiver for the deposit
     */
    function inkindDeposit(DispatchMode _mode, TRANCHE_UNIT _assets, address _caller, address _receiver) external returns (uint256 trancheSharesMinted);

    /**
     * @notice Processes the in-kind redemption of a specified number of the calling tranche's shares
     * @dev Only callable by one of the market's tranches: the redeemed tranche is the calling tranche
     * @dev The function is expected to transfer the redeemed assets directly to the receiver, based on the redemption claims
     * @dev Burns the owner's shares after scaling their claims against the pre-burn supply (a preview skips only the burn)
     * @dev Redemptions are enabled only in a PERPETUAL market state, the JT redemption granted that the market's coverage requirement
     *      and the LPT redemption granted that the market's liquidity requirement are satisfied post-redemption
     * @dev A preview never returns: the flow unwinds every mutation by reverting with SIMULATION_RESULT carrying the ABI encoded return values
     * @param _mode The dispatch mode: SIMULATE computes the operation and unwinds every mutation by reverting with its result, EXECUTE settles it
     * @param _shares The number of shares to redeem
     * @param _caller The address that initiated the redemption on the tranche, screened with the owner and receiver against the market's blacklist, the null address for a simulation's synthetic caller that also skips the share burn
     * @param _owner The address whose tranche shares are burned for the redemption, the null address for a simulation's synthetic owner
     * @param _receiver The address that is receiving the assets
     * @return userAssetClaims The distribution of assets that were transferred to the receiver on redemption
     */
    function inkindRedeem(
        DispatchMode _mode,
        uint256 _shares,
        address _caller,
        address _owner,
        address _receiver
    )
        external
        returns (AssetClaims memory userAssetClaims);

    /**
     * @notice Atomically enters the liquidity provider tranche with the LPT assets' constituent assets: deposits collateral (minting senior
     *         shares), adds (senior shares + quote) into the liquidity venue to mint the LPT tranche assets, then deposits them into the LPT
     * @dev Assumes the collateral and quote have been transferred to the kernel before this call (by the LPT tranche)
     * @dev Enabled in a PERPETUAL market state, and in a fixed-term market only for a quote-only deposit (_collateralAssets == 0) that mints no senior shares, an ST-leg deposit reverts in a fixed-term market
     * @dev The senior leg is gated by the market's coverage requirement, its liquidity requirement is satisfied by the add deploying the minted shares as depth
     * @dev Prices the shares at the pre-deposit LPT effective NAV against the venue's settled post-add state and mints them to the receiver
     * @dev A preview never returns: the flow unwinds every mutation by reverting with SIMULATION_RESULT carrying the ABI encoded return values
     * @param _mode The dispatch mode: SIMULATE computes the operation and unwinds every mutation by reverting with its result, EXECUTE settles it
     * @param _collateralAssets The amount of collateral to deposit for the senior leg, denominated in tranche units
     * @param _quoteAssets The amount of quote asset to add as the second venue leg
     * @param _minLPTAssetsOut The minimum LPT tranche assets the liquidity add must mint (slippage bound against an unfavorable venue state)
     * @param _caller The address that initiated the deposit on the tranche, screened with the receiver against the market's blacklist, the null address for a simulation's synthetic caller
     * @param _receiver The address that receives the minted tranche shares
     * @return trancheSharesMinted The number of tranche shares minted to the receiver for the deposit
     * @return lptAssetsOut The amount of LPT tranche assets minted and credited to the liquidity provider tranche
     */
    function lptDepositMultiAsset(
        DispatchMode _mode,
        TRANCHE_UNIT _collateralAssets,
        uint256 _quoteAssets,
        TRANCHE_UNIT _minLPTAssetsOut,
        address _caller,
        address _receiver
    )
        external
        returns (uint256 trancheSharesMinted, TRANCHE_UNIT lptAssetsOut);

    /**
     * @notice Atomically exits the liquidity provider tranche to the LPT assets' constituent assets: proportionally removes the LPT-asset slice,
     *         redeems the venue-held senior shares to collateral, and returns (collateral + quote) to the receiver
     * @dev Burns the owner's LPT shares after scaling their claims against the pre-burn supply (a preview skips only the burn)
     * @dev A preview never returns: the flow unwinds every mutation by reverting with SIMULATION_RESULT carrying the ABI encoded return values
     * @param _mode The dispatch mode: SIMULATE computes the operation and unwinds every mutation by reverting with its result, EXECUTE settles it
     * @param _lptShares The number of LPT shares being redeemed (used to size the proportional LPT-asset slice)
     * @param _minSTSharesOut The minimum senior tranche shares the proportional removal must return (slippage bound)
     * @param _minQuoteAssetsOut The minimum quote to return (slippage bound)
     * @param _caller The address that initiated the redemption on the tranche, screened with the owner and receiver against the market's blacklist, the null address for a simulation's synthetic caller that also skips the share burn
     * @param _owner The address whose LPT shares are burned for the redemption, the null address for a simulation's synthetic owner
     * @param _receiver The address that receives the collateral and quote
     * @return stClaims The ST redemption asset claims transferred to the receiver (its collateral asset leg)
     * @return quoteAssets The quote assets returned to the receiver
     */
    function lptRedeemMultiAsset(
        DispatchMode _mode,
        uint256 _lptShares,
        uint256 _minSTSharesOut,
        uint256 _minQuoteAssetsOut,
        address _caller,
        address _owner,
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

    /**
     * @notice Reverts if the specified account is blacklisted on this market
     * @dev No-op when no blacklist is configured (the null address disables screening)
     * @param _account The address of the account to screen
     */
    function enforceNotBlacklisted(address _account) external view;

    /**
     * @notice Retrieves the market's wiring in one carrier for external consumers (the entry point and other periphery)
     * @dev The kernel's delegatecalled logic libraries read the wiring from the kernel's state directly, so this carrier never enters the operation hot paths
     * @return immutables The market's tranche set, assets, and accountant
     */
    function getImmutableState() external view returns (RoycoDayKernelImmutableState memory immutables);

    /// @notice Retrieves the state of the Royco kernel
    /// @return state The Royco kernel's state, including the protocol fee recipient and the kernel's controlled tranche and base assets
    function getState() external view returns (RoycoDayKernelState memory state);

    // =============================
    // Liquidity Provider Tranche Venue Drivers
    // =============================

    /**
     * @notice Adds a senior tranche share and quote asset position into the liquidity venue and returns the liquidity provider tranche assets minted
     * @dev Only invoked via a self-call from the kernel's delegatecall logic libraries
     * @param _mode The dispatch mode: SIMULATE computes the operation and unwinds every mutation by reverting with its result, EXECUTE settles it
     * @param _seniorShares The exact amount of senior tranche shares to add into the liquidity venue
     * @param _quoteAssets The exact amount of quote assets to add into the liquidity venue
     * @param _minLPTAssetsOut The minimum liquidity provider tranche assets that must be minted, bounding the add's slippage
     * @return lptAssets The liquidity provider tranche assets minted by the add
     * @return lptAssetPrice The value of 1 whole LPT asset against the post-add venue state, produced only for a preview to cache for the operation (zero when settling)
     */
    function addLiquidity(
        DispatchMode _mode,
        uint256 _seniorShares,
        uint256 _quoteAssets,
        TRANCHE_UNIT _minLPTAssetsOut
    )
        external
        returns (TRANCHE_UNIT lptAssets, NAV_UNIT lptAssetPrice);

    /**
     * @notice Proportionally removes a slice of liquidity provider tranche assets from the liquidity venue into its senior tranche share and quote asset constituents
     * @dev Only invoked via a self-call from the kernel's delegatecall logic libraries
     * @param _mode The dispatch mode: SIMULATE computes the operation and unwinds every mutation by reverting with its result, EXECUTE settles it
     * @param _lptAssets The exact liquidity provider tranche assets to burn
     * @param _minSTSharesOut The minimum senior tranche shares that must be withdrawn, bounding the removal's slippage
     * @param _minQuoteAssetsOut The minimum quote assets that must be withdrawn, bounding the removal's slippage
     * @param _quoteAssetsReceiver The recipient of the withdrawn quote assets, the withdrawn senior shares are returned to the kernel for the combined senior unwind
     * @return stShares The senior tranche shares withdrawn by the removal
     * @return quoteAssets The quote assets withdrawn by the removal
     * @return lptAssetPrice The value of 1 whole LPT asset against the post-remove venue state, produced only for a preview to cache for the operation (zero when settling)
     */
    function removeLiquidity(
        DispatchMode _mode,
        TRANCHE_UNIT _lptAssets,
        uint256 _minSTSharesOut,
        uint256 _minQuoteAssetsOut,
        address _quoteAssetsReceiver
    )
        external
        returns (uint256 stShares, uint256 quoteAssets, NAV_UNIT lptAssetPrice);

    /**
     * @notice Attempts to reinvest the liquidity provider tranche's idle liquidity-premium senior shares into its market-making inventory
     * @dev Tolerates reversions gracefully so it is non-blocking for the tranche operation that invokes it
     * @param _stSharesToReinvest The amount of idle liquidity-premium senior shares to reinvest, or type(uint256).max to reinvest the entire idle balance
     * @param _stShareRate The senior share rate the pile is valued at, the NAV backing one whole (WAD) senior share at the operation's settled state
     */
    function attemptLiquidityPremiumReinvestment(uint256 _stSharesToReinvest, NAV_UNIT _stShareRate) external;
}
