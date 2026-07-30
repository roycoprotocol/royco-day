// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IAccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { IERC20Metadata } from "../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { ReentrancyGuardTransient } from "../../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import { RoycoBase } from "../../base/RoycoBase.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoPriceOracle } from "../../interfaces/IRoycoPriceOracle.sol";
import { IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { AggregatorV3Interface } from "../../interfaces/external/chainlink/AggregatorV3Interface.sol";
import { Cache, CacheKey } from "../../libraries/Cache.sol";
import { WAD, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../../libraries/Constants.sol";
import { AssetClaims, DispatchMode, SyncedAccountingState, TrancheType } from "../../libraries/Types.sol";
import { Math, NAV_UNIT, RoycoUnitsMath, TRANCHE_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../libraries/Units.sol";
import { AccountingSyncLogic } from "../../libraries/logic/AccountingSyncLogic.sol";
import { BlacklistLogic } from "../../libraries/logic/BlacklistLogic.sol";
import { DepositLogic } from "../../libraries/logic/DepositLogic.sol";
import { RedemptionLogic } from "../../libraries/logic/RedemptionLogic.sol";

/**
 * @title RoycoDayKernel
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Abstract contract serving as the base for all Royco Day Kernel implementations
 * @dev Provides the foundational logic for kernel contracts including pre and post operation NAV reconciliation, coverage enforcement logic, and base wiring for tranche synchronization
 * @dev All concrete kernel implementations inherit this base kernel
 */
abstract contract RoycoDayKernel is IRoycoDayKernel, RoycoBase, ReentrancyGuardTransient {
    using RoycoUnitsMath for NAV_UNIT;
    using RoycoUnitsMath for TRANCHE_UNIT;

    /// @dev Storage slot for RoycoDayKernelState using ERC-7201 pattern
    /// @dev keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoDayKernelState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROYCO_DAY_KERNEL_STORAGE_SLOT = 0xc366ce7b07de4bd3f36c874874355fb088fd2057e716d8a9786c17b22e6fec00;

    /// @dev One whole collateral asset: 10^(COLLATERAL_ASSET_DECIMALS)
    /// @dev A single collateral asset price values the coinvested collateral both the senior and junior tranches deposit
    TRANCHE_UNIT internal immutable ONE_WHOLE_COLLATERAL_ASSET;

    /// @dev One whole LPT asset: 10^(LPT_ASSET_DECIMALS)
    /// @dev A single LPT asset price values the liquidity provider tranche's market-making position token
    TRANCHE_UNIT internal immutable ONE_WHOLE_LPT_ASSET;

    /// @inheritdoc IRoycoDayKernel
    address public immutable override(IRoycoDayKernel) SENIOR_TRANCHE;

    /// @inheritdoc IRoycoDayKernel
    address public immutable override(IRoycoDayKernel) JUNIOR_TRANCHE;

    /// @inheritdoc IRoycoDayKernel
    address public immutable override(IRoycoDayKernel) COLLATERAL_ASSET;

    /// @inheritdoc IRoycoDayKernel
    address public immutable override(IRoycoDayKernel) LIQUIDITY_PROVIDER_TRANCHE;

    /// @inheritdoc IRoycoDayKernel
    address public immutable override(IRoycoDayKernel) LPT_ASSET;

    /// @inheritdoc IRoycoDayKernel
    /// @dev The concrete liquidity venue validates this against its pool registration at construction
    address public immutable override(IRoycoDayKernel) QUOTE_ASSET;

    /// @inheritdoc IRoycoDayKernel
    address public immutable override(IRoycoDayKernel) ACCOUNTANT;

    /// @inheritdoc IRoycoDayKernel
    bool public immutable override(IRoycoDayKernel) ENFORCE_TRANCHE_WHITELIST_ON_TRANSFER;

    /// @dev Permissions the function to only be callable by this contract via a self-call, the seam through which the delegatecall logic libraries reach callback into the kernel
    modifier onlySelf() {
        require(msg.sender == address(this), ONLY_SELF());
        _;
    }

    /// @dev Permissions the function to only be callable by the market's liquidity provider tranche
    /// @dev Should be placed on LPT deposit and redeem functions
    modifier onlyLiquidityProviderTranche() {
        require(msg.sender == LIQUIDITY_PROVIDER_TRANCHE, ONLY_LIQUIDITY_PROVIDER_TRANCHE());
        _;
    }

    /// @dev Permissions the function to only be callable by the market's senior, junior, or liquidity provider tranche
    modifier onlyTranche() {
        require(msg.sender == SENIOR_TRANCHE || msg.sender == JUNIOR_TRANCHE || msg.sender == LIQUIDITY_PROVIDER_TRANCHE, ONLY_TRANCHE());
        _;
    }

    /// @dev Initializes the operation's collateral price cache at the start of the call and clears it at the end
    /// @dev Should be placed on all state mutating functions that use the collateral asset price
    modifier withCollateralPriceCached() {
        // Poke the collateral asset oracle as the operation's first action: can revert as a circuit-breaker
        IRoycoPriceOracle(_getRoycoDayKernelStorage().collateralAssetOracle).poke();
        // Cache the collateral asset price for the operation
        Cache._write(CacheKey.COLLATERAL_ASSET_PRICE, toUint256(queryCollateralAssetOracle()));
        _;
        Cache._delete(CacheKey.COLLATERAL_ASSET_PRICE);
    }

    // =============================
    // Construction and Initialization Functions
    // =============================

    /// @notice Constructs the base Royco kernel state
    /// @param _params The standard construction parameters for the Royco kernel
    constructor(RoycoDayKernelConstructionParams memory _params) {
        // Ensure that the tranche and accountant addresses are not null
        // The senior and junior tranches are coinvested structurally: both deposit the same collateral asset
        require(
            _params.seniorTranche != address(0) && _params.juniorTranche != address(0) && _params.liquidityProviderTranche != address(0)
                && _params.collateralAsset != address(0) && _params.lptAsset != address(0) && _params.quoteAsset != address(0)
                && _params.accountant != address(0),
            NULL_ADDRESS()
        );

        // Set the immutable addresses
        SENIOR_TRANCHE = _params.seniorTranche;
        JUNIOR_TRANCHE = _params.juniorTranche;
        COLLATERAL_ASSET = _params.collateralAsset;
        LIQUIDITY_PROVIDER_TRANCHE = _params.liquidityProviderTranche;
        LPT_ASSET = _params.lptAsset;
        QUOTE_ASSET = _params.quoteAsset;
        ACCOUNTANT = _params.accountant;
        ENFORCE_TRANCHE_WHITELIST_ON_TRANSFER = _params.enforceVaultSharesTransferWhitelist;
        ONE_WHOLE_COLLATERAL_ASSET = toTrancheUnits(10 ** IERC20Metadata(_params.collateralAsset).decimals());
        ONE_WHOLE_LPT_ASSET = toTrancheUnits(10 ** IERC20Metadata(_params.lptAsset).decimals());
    }

    /**
     * @notice Initializes the base Royco kernel state
     * @dev Initializes any parent contracts and the base kernel state
     * @param _params The standard initialization parameters for the Royco kernel
     */
    function __RoycoDayKernel_init(RoycoDayKernelInitParams memory _params) internal onlyInitializing {
        // Ensure that the tranches and their corresponding assets in the kernel match: coinvestment is structural, both the senior and junior tranches deposit the one collateral asset
        require(
            IRoycoVaultTranche(SENIOR_TRANCHE).asset() == COLLATERAL_ASSET && IRoycoVaultTranche(JUNIOR_TRANCHE).asset() == COLLATERAL_ASSET
                && IRoycoVaultTranche(LIQUIDITY_PROVIDER_TRANCHE).asset() == LPT_ASSET,
            TRANCHE_AND_KERNEL_ASSETS_MISMATCH()
        );
        // Ensure that the initial authority and protocol fee recipient are not null
        require(_params.initialAuthority != address(0) && _params.protocolFeeRecipient != address(0), NULL_ADDRESS());
        // Ensure that the ST self-liquidiation bonus is less than 100% of its value
        require(_params.stSelfLiquidationBonusWAD < WAD, INVALID_SELF_LIQUIDATION_BONUS());

        // Initialize the base state
        __RoycoBase_init(_params.initialAuthority);

        // Initialize the kernel state
        RoycoDayKernelState storage $ = _getRoycoDayKernelStorage();
        $.protocolFeeRecipient = _params.protocolFeeRecipient;
        $.stSelfLiquidationBonusWAD = _params.stSelfLiquidationBonusWAD;
        $.roycoBlacklist = _params.roycoBlacklist;
        emit ProtocolFeeRecipientUpdated(_params.protocolFeeRecipient);
        emit SeniorTrancheSelfLiquidationBonusUpdated(_params.stSelfLiquidationBonusWAD);
        emit RoycoBlacklistUpdated(_params.roycoBlacklist);

        // Initialize the collateral asset oracle configuration (the setters validate and emit)
        _setCollateralAssetOracle(_params.collateralAssetOracle, _params.stalenessThresholdSeconds);
        _setSequencerUptimeFeed(_params.sequencerUptimeFeed, _params.gracePeriodSeconds);
    }

    // =============================
    // Tranche Asset Pricing Functions
    // =============================

    /// @inheritdoc IRoycoDayKernel
    function convertCollateralAssetsToValue(TRANCHE_UNIT _collateralAssets) public view virtual override(IRoycoDayKernel) returns (NAV_UNIT value) {
        return _collateralAssets.mulDiv(_getCollateralAssetPrice(), ONE_WHOLE_COLLATERAL_ASSET, Math.Rounding.Floor);
    }

    /// @inheritdoc IRoycoDayKernel
    function convertValueToCollateralAssets(NAV_UNIT _value) public view virtual override(IRoycoDayKernel) returns (TRANCHE_UNIT collateralAssets) {
        return _value.mulDiv(ONE_WHOLE_COLLATERAL_ASSET, _getCollateralAssetPrice(), Math.Rounding.Floor);
    }

    /// @inheritdoc IRoycoDayKernel
    function convertLPTAssetsToValue(TRANCHE_UNIT _lptAssets) public view virtual override(IRoycoDayKernel) returns (NAV_UNIT value) {
        return _lptAssets.mulDiv(_getLPTAssetPrice(), ONE_WHOLE_LPT_ASSET, Math.Rounding.Floor);
    }

    /// @inheritdoc IRoycoDayKernel
    function convertValueToLPTAssets(NAV_UNIT _value) public view virtual override(IRoycoDayKernel) returns (TRANCHE_UNIT lptAssets) {
        return _value.mulDiv(ONE_WHOLE_LPT_ASSET, _getLPTAssetPrice(), Math.Rounding.Floor);
    }

    // =============================
    // Tranche Accounting and Synchronization Functions
    // =============================

    /// @inheritdoc IRoycoDayKernel
    function syncTrancheAccounting()
        public
        virtual
        override(IRoycoDayKernel)
        whenNotPaused
        restricted
        nonReentrant
        withCollateralPriceCached
        returns (SyncedAccountingState memory state)
    {
        return AccountingSyncLogic.syncTrancheAccounting(_getRoycoDayKernelStorage(), getImmutableState());
    }

    /// @inheritdoc IRoycoDayKernel
    function syncTrancheAccountingFor(TrancheType _trancheType)
        public
        virtual
        override(IRoycoDayKernel)
        whenNotPaused
        restricted
        nonReentrant
        withCollateralPriceCached
        returns (SyncedAccountingState memory state, AssetClaims memory claims, uint256 totalTrancheShares)
    {
        return AccountingSyncLogic.syncTrancheAccountingFor(_getRoycoDayKernelStorage(), getImmutableState(), _trancheType);
    }

    /// @inheritdoc IRoycoDayKernel
    function previewSyncTrancheAccountingFor(TrancheType _trancheType)
        public
        view
        virtual
        override(IRoycoDayKernel)
        whenNotPaused
        nonReentrantView
        returns (SyncedAccountingState memory state, AssetClaims memory claims, uint256 totalTrancheShares)
    {
        RoycoDayKernelState storage $ = _getRoycoDayKernelStorage();
        // Simulate the poke first so a circuit-breaking oracle reverts identically to a real operation
        IRoycoPriceOracle($.collateralAssetOracle).previewPoke();
        return AccountingSyncLogic.previewSyncTrancheAccountingFor($, getImmutableState(), _trancheType);
    }

    /// @inheritdoc IRoycoDayKernel
    function reinvestLiquidityPremium(uint256 _stShares)
        external
        virtual
        override(IRoycoDayKernel)
        whenNotPaused
        restricted
        nonReentrant
        withCollateralPriceCached
    {
        AccountingSyncLogic.reinvestLiquidityPremium(_getRoycoDayKernelStorage(), getImmutableState(), _stShares);
    }

    // =============================
    // Tranche Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoDayKernel
    /// @dev ST and JT deposits are enabled only in a PERPETUAL market state, the ST deposit granted that the market's coverage and liquidity requirements are satisfied post-deposit
    /// @dev An in-kind LPT deposit mints no new senior shares and only deepens liquidity, so it is enabled in every market state and enforces no requirements
    function inkindDeposit(
        DispatchMode _mode,
        TRANCHE_UNIT _assets,
        address _caller,
        address _receiver
    )
        external
        virtual
        override(IRoycoDayKernel)
        whenNotPaused
        onlyTranche
        nonReentrant
        withCollateralPriceCached
        returns (uint256 trancheSharesMinted)
    {
        return DepositLogic.inkindDeposit(_getRoycoDayKernelStorage(), getImmutableState(), _mode, _getInvokingTranche(), _assets, _caller, _receiver);
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev Redemptions are enabled only in a PERPETUAL market state, the JT redemption granted that the market's coverage requirement and the LPT redemption granted that the market's liquidity requirement are satisfied post-redemption
    function inkindRedeem(
        DispatchMode _mode,
        uint256 _shares,
        address _caller,
        address _owner,
        address _receiver
    )
        external
        virtual
        override(IRoycoDayKernel)
        whenNotPaused
        onlyTranche
        nonReentrant
        withCollateralPriceCached
        returns (AssetClaims memory userAssetClaims)
    {
        return RedemptionLogic.inkindRedeem(_getRoycoDayKernelStorage(), getImmutableState(), _mode, _getInvokingTranche(), _shares, _caller, _owner, _receiver);
    }

    // =============================
    // Liquidity Provider Tranche Multi-Asset Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoDayKernel
    /// @dev LPT multi-asset deposits are enabled in a PERPETUAL market state (granted the market's coverage and liquidity requirements are satisfied against the new senior exposure), and in a fixed-term market only for a quote-only deposit that mints no senior shares
    /// @dev Composed from the shared deposit primitives: an ST deposit seeding the add's senior shares, the venue add, then an LPT deposit of the minted assets
    function lptDepositMultiAsset(
        DispatchMode _mode,
        TRANCHE_UNIT _collateralAssets,
        uint256 _quoteAssets,
        TRANCHE_UNIT _minLPTAssetsOut,
        address _caller,
        address _receiver
    )
        external
        virtual
        override(IRoycoDayKernel)
        whenNotPaused
        onlyLiquidityProviderTranche
        nonReentrant
        withCollateralPriceCached
        returns (uint256 trancheSharesMinted, TRANCHE_UNIT lptAssetsOut)
    {
        return DepositLogic.lptDepositMultiAsset(
            _getRoycoDayKernelStorage(), getImmutableState(), _mode, _collateralAssets, _quoteAssets, _minLPTAssetsOut, _caller, _receiver
        );
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev LPT multi-asset redemptions are enabled only in a PERPETUAL market state, granted the market's liquidity requirement is satisfied post-redemption
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
        virtual
        override(IRoycoDayKernel)
        whenNotPaused
        onlyLiquidityProviderTranche
        nonReentrant
        withCollateralPriceCached
        returns (AssetClaims memory stClaims, uint256 quoteAssets)
    {
        return RedemptionLogic.lptRedeemMultiAsset(
            _getRoycoDayKernelStorage(), getImmutableState(), _mode, _lptShares, _minSTSharesOut, _minQuoteAssetsOut, _caller, _owner, _receiver
        );
    }

    // =============================
    // Tranche Max Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoDayKernel
    /// @dev ST and JT deposits are allowed only in a PERPETUAL market state, the ST deposit granted that the market's coverage and liquidity requirements are satisfied post-deposit
    /// @dev An in-kind LPT deposit mints no new senior shares and only deepens liquidity, so it is enabled in every market state and unbounded
    function inkindMaxDeposit(address _receiver) public view virtual override(IRoycoDayKernel) onlyTranche returns (TRANCHE_UNIT) {
        return DepositLogic.inkindMaxDeposit(_getRoycoDayKernelStorage(), getImmutableState(), _getInvokingTranche(), _receiver);
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev Redemptions are allowed only in a PERPETUAL market state, the JT withdrawal bounded by the market's coverage requirement and the LPT withdrawal by its liquidity requirement
    function inkindMaxRedeemable(address _owner) public view virtual override(IRoycoDayKernel) onlyTranche returns (uint256 maxRedeemableShares) {
        return RedemptionLogic.inkindMaxRedeemable(_getRoycoDayKernelStorage(), getImmutableState(), _getInvokingTranche(), _owner);
    }

    /// @inheritdoc IRoycoDayKernel
    function lptMaxRedeemableMultiAsset(address _owner)
        public
        virtual
        override(IRoycoDayKernel)
        onlyLiquidityProviderTranche
        returns (uint256 maxRedeemableShares)
    {
        return RedemptionLogic.lptMaxRedeemableMultiAsset(_getRoycoDayKernelStorage(), getImmutableState(), _owner);
    }

    // =============================
    // Admin Functions
    // =============================

    /// @inheritdoc IRoycoDayKernel
    function setProtocolFeeRecipient(address _protocolFeeRecipient) external override(IRoycoDayKernel) restricted {
        require(_protocolFeeRecipient != address(0), NULL_ADDRESS());
        _getRoycoDayKernelStorage().protocolFeeRecipient = _protocolFeeRecipient;
        emit ProtocolFeeRecipientUpdated(_protocolFeeRecipient);
    }

    /// @inheritdoc IRoycoDayKernel
    function setSeniorTrancheSelfLiquidationBonus(uint64 _stSelfLiquidationBonusWAD) external override(IRoycoDayKernel) restricted {
        require(_stSelfLiquidationBonusWAD < WAD, INVALID_SELF_LIQUIDATION_BONUS());
        _getRoycoDayKernelStorage().stSelfLiquidationBonusWAD = _stSelfLiquidationBonusWAD;
        emit SeniorTrancheSelfLiquidationBonusUpdated(_stSelfLiquidationBonusWAD);
    }

    /// @inheritdoc IRoycoDayKernel
    function setRoycoBlacklist(address _roycoBlacklist) external override(IRoycoDayKernel) restricted {
        _getRoycoDayKernelStorage().roycoBlacklist = _roycoBlacklist;
        emit RoycoBlacklistUpdated(_roycoBlacklist);
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev Executes an accounting sync after (and optionally before) the update so the fresh oracle's price is committed immediately
    function setCollateralAssetOracle(
        address _collateralAssetOracle,
        uint48 _stalenessThresholdSeconds,
        bool _syncBeforeUpdate
    )
        external
        override(IRoycoDayKernel)
        restricted
    {
        // If specified, sync the tranche accounting to reflect the PNL up to this point in time at the outgoing oracle's price
        if (_syncBeforeUpdate) _preOpSyncTrancheAccountingWithPriceCached();
        // Update the collateral asset oracle
        _setCollateralAssetOracle(_collateralAssetOracle, _stalenessThresholdSeconds);
        // Sync the tranche accounting to reflect the PNL from the updated oracle's price (the sync re-initializes the price cache to the new price)
        _preOpSyncTrancheAccountingWithPriceCached();
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev The sequencer uptime feed and grace period do not affect the collateral asset price, so no accounting sync is performed
    function setSequencerUptimeFeed(address _sequencerUptimeFeed, uint48 _gracePeriodSeconds) external virtual override(IRoycoDayKernel) restricted {
        _setSequencerUptimeFeed(_sequencerUptimeFeed, _gracePeriodSeconds);
    }

    // =============================
    // Asset Pricing Oracle Functions
    // =============================

    /// @inheritdoc IRoycoDayKernel
    function queryCollateralAssetOracle() public view override(IRoycoDayKernel) returns (NAV_UNIT collateralAssetPrice) {
        RoycoDayKernelState storage $ = _getRoycoDayKernelStorage();

        // If a sequencer uptime feed is set, ensure the L2 sequencer is up and its grace period has elapsed before trusting the price
        address sequencerUptimeFeed = $.sequencerUptimeFeed;
        if (sequencerUptimeFeed != address(0)) {
            (, int256 sequencerStatus, uint256 sequencerStartedAt,,) = AggregatorV3Interface(sequencerUptimeFeed).latestRoundData();
            // A sequencer status of 0 indicates that the sequencer is up, and 1 indicates that it is down
            require(sequencerStatus == 0, SEQUENCER_DOWN());
            // Ensure the round is initialized (startedAt is 0 only for an uninitialized uptime feed) and that the grace period has fully elapsed since the sequencer was last restored
            require(sequencerStartedAt != 0 && (block.timestamp - sequencerStartedAt) > $.gracePeriodSeconds, GRACE_PERIOD_NOT_OVER());
        }

        // Fetch the collateral asset price in NAV units
        uint256 updatedAt;
        (collateralAssetPrice, updatedAt) = IRoycoPriceOracle($.collateralAssetOracle).getPrice();

        // Conduct sanity checks
        require((updatedAt + $.stalenessThresholdSeconds) >= block.timestamp, STALE_PRICE());
        require(collateralAssetPrice != ZERO_NAV_UNITS, INVALID_PRICE());
    }

    /// @inheritdoc IRoycoDayKernel
    function queryLPTAssetOracle() public view virtual override(IRoycoDayKernel) returns (NAV_UNIT lptAssetPrice);

    /**
     * @notice Sets the new collateral asset oracle
     * @dev The oracle must price this market's collateral asset
     * @param _collateralAssetOracle The new collateral asset oracle
     * @param _stalenessThresholdSeconds The new staleness threshold seconds
     */
    function _setCollateralAssetOracle(address _collateralAssetOracle, uint48 _stalenessThresholdSeconds) internal {
        // The kernel has no fallback price source, so the oracle can never be set to the null address
        require(_collateralAssetOracle != address(0), NULL_ADDRESS());
        require(_stalenessThresholdSeconds > 0, INVALID_STALENESS_THRESHOLD_SECONDS());
        require(IRoycoPriceOracle(_collateralAssetOracle).COLLATERAL_ASSET() == COLLATERAL_ASSET, COLLATERAL_ASSET_ORACLE_MISMATCH());

        RoycoDayKernelState storage $ = _getRoycoDayKernelStorage();
        $.collateralAssetOracle = _collateralAssetOracle;
        $.stalenessThresholdSeconds = _stalenessThresholdSeconds;

        emit CollateralAssetOracleUpdated(_collateralAssetOracle, _stalenessThresholdSeconds);
    }

    /**
     * @notice Returns the collateral asset's price in NAV units
     * @dev If the operation's cache slot is populated returns the cached price, otherwise falls back to querying the price live for view function compatibility
     * @return The value of 1 whole collateral asset in NAV units
     */
    function _getCollateralAssetPrice() internal view returns (NAV_UNIT) {
        // If the cache slot is populated use the cached value
        (bool cacheHit, uint256 collateralAssetPrice) = Cache._read(CacheKey.COLLATERAL_ASSET_PRICE);
        if (cacheHit) return toNAVUnits(collateralAssetPrice);
        // Otherwise fall back to querying the price directly (for view functions)
        return queryCollateralAssetOracle();
    }

    /**
     * @notice Returns the LPT asset's price in NAV units
     * @dev If the operation's cache slot is populated returns the cached price, otherwise falls back to querying the price live for view function compatibility
     * @return The value of 1 whole LPT asset in NAV units
     */
    function _getLPTAssetPrice() internal view returns (NAV_UNIT) {
        // If the cache slot is populated use the cached value
        (bool cacheHit, uint256 lptAssetPrice) = Cache._read(CacheKey.LPT_ASSET_PRICE);
        if (cacheHit) return toNAVUnits(lptAssetPrice);
        // Otherwise fall back to querying the price directly (for view functions)
        return queryLPTAssetOracle();
    }

    /**
     * @notice Sets the new L2 sequencer uptime feed and grace period
     * @dev A null sequencer uptime feed disables the L2 sequencer check
     *      When a feed is set, the grace period must be a positive
     *      duration (mirroring the treatment of the staleness threshold for the price feed)
     * @param _sequencerUptimeFeed The new L2 sequencer uptime feed (set to the null address to disable the check)
     * @param _gracePeriodSeconds The new grace period seconds
     */
    function _setSequencerUptimeFeed(address _sequencerUptimeFeed, uint48 _gracePeriodSeconds) internal virtual {
        require(_sequencerUptimeFeed == address(0) || _gracePeriodSeconds > 0, INVALID_GRACE_PERIOD_SECONDS());

        RoycoDayKernelState storage $ = _getRoycoDayKernelStorage();
        $.sequencerUptimeFeed = _sequencerUptimeFeed;
        $.gracePeriodSeconds = _gracePeriodSeconds;

        emit SequencerUptimeFeedUpdated(_sequencerUptimeFeed, _gracePeriodSeconds);
    }

    // =============================
    //  Utility Functions
    // =============================

    /**
     * @notice Invokes the accountant to do a pre-operation (deposit and withdrawal) NAV sync and mints any protocol fee shares accrued
     * @dev A sync must be executed before every NAV mutating operation (deposit and withdrawal)
     * @dev Uses the price cache since it is called by admin setters outside a cached operation, so it re-initializes the price cache to the live price before syncing
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function _preOpSyncTrancheAccountingWithPriceCached() internal virtual withCollateralPriceCached returns (SyncedAccountingState memory state) {
        return AccountingSyncLogic._preOpSyncTrancheAccounting(_getRoycoDayKernelStorage(), getImmutableState());
    }

    /// @inheritdoc IRoycoDayKernel
    function preTrancheBalanceUpdateHook(
        address _caller,
        address _from,
        address _to,
        uint256 _value
    )
        external
        override(IRoycoDayKernel)
        onlyTranche
        whenNotPaused
    {
        // Get the Royco kernel state
        RoycoDayKernelState storage $ = _getRoycoDayKernelStorage();

        // Batch screen the involved accounts against the market's blacklist
        BlacklistLogic._enforceNotBlacklisted($, _caller, _from, _to);

        // If transferring shares, ensure that the recipient is a whitelisted LP for the tranche
        // The kernel, the protocol fee recipient, and any market-specific tranche share custodian are exempt from this check
        if (
            ENFORCE_TRANCHE_WHITELIST_ON_TRANSFER && _to != address(0) && _to != address(this) && _to != $.protocolFeeRecipient
                && !_isTrancheShareCustodian(_to)
        ) {
            // It is assumed that the sender is already a whitelisted LP
            address authority = authority();
            // Check if the to address can call the deposit function on the tranche
            /// @dev msg.sender is the tranche address
            (bool isWhitelistedTrancheLP,) = IAccessManager(authority).canCall(_to, msg.sender, IRoycoVaultTranche.deposit.selector);
            require(_to != authority && isWhitelistedTrancheLP, ACCOUNT_NOT_WHITELISTED_TRANCHE_LP(_to));
        }

        // Call the market specific pre-balance update hook
        _preTrancheBalanceUpdate(_caller, _from, _to, _value);
    }

    /// @dev Resolves the calling tranche's type from msg.sender, reverting for any caller that is not one of the market's tranches
    /// @return The calling tranche's type
    function _getInvokingTranche() private view returns (TrancheType) {
        if (msg.sender == SENIOR_TRANCHE) return TrancheType.SENIOR;
        else if (msg.sender == JUNIOR_TRANCHE) return TrancheType.JUNIOR;
        else if (msg.sender == LIQUIDITY_PROVIDER_TRANCHE) return TrancheType.LIQUIDITY_PROVIDER;
        else revert ONLY_TRANCHE();
    }

    /**
     * @notice Pre-balance update hook for the kernel
     * @dev Intentionally implemented with an empty body since inheriting contracts are not required to override this function
     * @dev Should be overridden by concrete kernel implementations to perform any additional checks or actions
     * @dev The caller is the account that initiated the balance update
     * @param _caller The account that initiated the balance update
     * @param _from The account from which the balance is being updated
     * @param _to The account to which the balance is being updated
     * @param _value The amount of the balance being updated
     */
    function _preTrancheBalanceUpdate(address _caller, address _from, address _to, uint256 _value) internal virtual { }

    /**
     * @notice Returns whether an account is a market-specific custodian of tranche shares such as the LPT venue
     * @dev Intentionally implemented with an empty body since inheriting contracts are not required to override this function
     * @param _account The account to check
     * @return True if the account is a market-specific tranche share custodian
     */
    function _isTrancheShareCustodian(address _account) internal view virtual returns (bool) { }

    // =============================
    // State Accessor Functions
    // =============================

    /// @inheritdoc IRoycoDayKernel
    function enforceNotBlacklisted(address[] memory _accounts) external view override(IRoycoDayKernel) {
        BlacklistLogic._enforceNotBlacklisted(_getRoycoDayKernelStorage(), _accounts);
    }

    /// @inheritdoc IRoycoDayKernel
    function enforceNotBlacklisted(address _account) external view override(IRoycoDayKernel) {
        BlacklistLogic._enforceNotBlacklisted(_getRoycoDayKernelStorage(), _account);
    }

    /// @inheritdoc IRoycoDayKernel
    function getImmutableState() public view override(IRoycoDayKernel) returns (RoycoDayKernelImmutableState memory) {
        return RoycoDayKernelImmutableState({
            seniorTranche: SENIOR_TRANCHE,
            juniorTranche: JUNIOR_TRANCHE,
            collateralAsset: COLLATERAL_ASSET,
            liquidityProviderTranche: LIQUIDITY_PROVIDER_TRANCHE,
            lptAsset: LPT_ASSET,
            quoteAsset: QUOTE_ASSET,
            accountant: ACCOUNTANT
        });
    }

    /// @inheritdoc IRoycoDayKernel
    function getCollateralAssetOracle() external view override(IRoycoDayKernel) returns (address collateralAssetOracle) {
        return _getRoycoDayKernelStorage().collateralAssetOracle;
    }

    /// @inheritdoc IRoycoDayKernel
    function getState() external view override(IRoycoDayKernel) returns (RoycoDayKernelState memory) {
        return _getRoycoDayKernelStorage();
    }

    /**
     * @notice Returns a storage pointer to the RoycoDayKernelState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer to the kernel's state
     */
    function _getRoycoDayKernelStorage() internal pure returns (RoycoDayKernelState storage $) {
        assembly ("memory-safe") {
            $.slot := ROYCO_DAY_KERNEL_STORAGE_SLOT
        }
    }
}
