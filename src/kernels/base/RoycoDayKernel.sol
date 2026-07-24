// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IAccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { IERC20Metadata } from "../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { ReentrancyGuardTransient } from "../../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import { RoycoBase } from "../../base/RoycoBase.sol";
import { IRoycoDayAccountant } from "../../interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoPriceOracle } from "../../interfaces/IRoycoPriceOracle.sol";
import { IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { AggregatorV3Interface } from "../../interfaces/external/chainlink/AggregatorV3Interface.sol";
import { Cache, CacheKey } from "../../libraries/Cache.sol";
import { WAD, ZERO_NAV_UNITS } from "../../libraries/Constants.sol";
import { AssetClaims, SyncedAccountingState, TrancheType } from "../../libraries/Types.sol";
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

    /// @dev Value representing the scale factor of one whole collateral asset: 10^(COLLATERAL_ASSET_DECIMALS)
    /// @dev A single collateral asset price values the coinvested collateral both the senior and junior tranches deposit
    uint256 internal immutable COLLATERAL_ASSET_SCALE_FACTOR;

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
    /// @dev Venue-agnostic getter: the concrete liquidity venue overrides this with its quote asset
    function QUOTE_ASSET() external view virtual override(IRoycoDayKernel) returns (address quoteAsset);

    /// @inheritdoc IRoycoDayKernel
    address public immutable override(IRoycoDayKernel) ACCOUNTANT;

    /// @inheritdoc IRoycoDayKernel
    bool public immutable override(IRoycoDayKernel) ENFORCE_TRANCHE_WHITELIST_ON_TRANSFER;

    /// @dev Permissions the function to only be callable by this contract via a self-call, the seam through which the delegatecall logic libraries reach callback into the kernel
    modifier onlySelf() {
        require(msg.sender == address(this), ONLY_SELF());
        _;
    }

    /// @dev Permissions the function to only be callable by the market's senior tranche
    /// @dev Should be placed on ST deposit and redeem functions
    modifier onlySeniorTranche() {
        require(msg.sender == SENIOR_TRANCHE, ONLY_SENIOR_TRANCHE());
        _;
    }

    /// @dev Permissions the function to only be callable by the market's junior tranche
    /// @dev Should be placed on JT deposit and redeem functions
    modifier onlyJuniorTranche() {
        require(msg.sender == JUNIOR_TRANCHE, ONLY_JUNIOR_TRANCHE());
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

    /// @dev Initializes the collateral price cache at the start of the call and clears it at the end
    /// @dev Should be placed on all state mutating functions that use the collateral price
    modifier withCollateralPriceCached() {
        // Poke the collateral asset oracle as the operation's first action: can revert as a circuit-breaker
        IRoycoPriceOracle(_getRoycoDayKernelStorage().collateralAssetOracle).poke();
        // Cache the collateral asset price for the operation
        Cache._write(CacheKey.COLLATERAL_ASSET_PRICE, toUint256(_queryCollateralAssetOracle()));
        _;
        // Clear the cached price
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
                && _params.collateralAsset != address(0) && _params.lptAsset != address(0) && _params.accountant != address(0),
            NULL_ADDRESS()
        );

        // Set the immutable addresses
        SENIOR_TRANCHE = _params.seniorTranche;
        JUNIOR_TRANCHE = _params.juniorTranche;
        COLLATERAL_ASSET = _params.collateralAsset;
        ACCOUNTANT = _params.accountant;
        LIQUIDITY_PROVIDER_TRANCHE = _params.liquidityProviderTranche;
        LPT_ASSET = _params.lptAsset;
        ENFORCE_TRANCHE_WHITELIST_ON_TRANSFER = _params.enforceVaultSharesTransferWhitelist;
        COLLATERAL_ASSET_SCALE_FACTOR = 10 ** IERC20Metadata(_params.collateralAsset).decimals();
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
        return toNAVUnits(toUint256(_collateralAssets.mulDiv(toUint256(_getCollateralAssetPrice()), COLLATERAL_ASSET_SCALE_FACTOR, Math.Rounding.Floor)));
    }

    /// @inheritdoc IRoycoDayKernel
    function convertValueToCollateralAssets(NAV_UNIT _value) public view virtual override(IRoycoDayKernel) returns (TRANCHE_UNIT collateralAssets) {
        return toTrancheUnits(toUint256(_value.mulDiv(COLLATERAL_ASSET_SCALE_FACTOR, toUint256(_getCollateralAssetPrice()), Math.Rounding.Floor)));
    }

    /// @inheritdoc IRoycoDayKernel
    function convertLPTAssetsToValue(TRANCHE_UNIT _lptAssets) public view virtual override(IRoycoDayKernel) returns (NAV_UNIT);

    /// @inheritdoc IRoycoDayKernel
    function convertValueToLPTAssets(NAV_UNIT _value) public view virtual override(IRoycoDayKernel) returns (TRANCHE_UNIT);

    // =============================
    // Tranche Max Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoDayKernel
    /// @dev ST deposits are allowed only in a PERPETUAL market state, granted that the market's coverage and liquidity requirements are satisfied post-deposit
    function stMaxDeposit(address _receiver) public view virtual override(IRoycoDayKernel) returns (TRANCHE_UNIT) {
        return DepositLogic.stMaxDeposit(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _receiver);
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev ST redemptions are allowed in PERPETUAL market states
    function stMaxWithdrawable(address _owner)
        public
        view
        virtual
        override(IRoycoDayKernel)
        returns (NAV_UNIT stClaimNAV, NAV_UNIT stMaxWithdrawableNAV, uint256 totalTrancheShares)
    {
        return RedemptionLogic.stMaxWithdrawable(_getRoycoDayKernelStorage(), _owner);
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev JT deposits are allowed if the market is in a PERPETUAL state
    function jtMaxDeposit(address _receiver) public view virtual override(IRoycoDayKernel) returns (TRANCHE_UNIT) {
        return DepositLogic.jtMaxDeposit(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _receiver);
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev JT redemptions are allowed only in a PERPETUAL market state, granted that the market's coverage requirement is satisfied post-redemption
    function jtMaxWithdrawable(address _owner)
        public
        view
        virtual
        override(IRoycoDayKernel)
        returns (NAV_UNIT jtClaimNAV, NAV_UNIT jtMaxWithdrawableNAV, uint256 totalTrancheShares)
    {
        return RedemptionLogic.jtMaxWithdrawable(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _owner);
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev An in-kind LPT deposit mints no new senior shares and only deepens liquidity, so it is enabled in every market state and unbounded
    function lptMaxDeposit(address _receiver) public view virtual override(IRoycoDayKernel) returns (TRANCHE_UNIT) {
        return DepositLogic.lptMaxDeposit(_getRoycoDayKernelStorage(), _receiver);
    }

    /// @inheritdoc IRoycoDayKernel
    function lptMaxWithdrawable(address _owner)
        public
        view
        virtual
        override(IRoycoDayKernel)
        returns (NAV_UNIT claimOnLPTNAV, NAV_UNIT lptMaxWithdrawableNAV, uint256 totalTrancheShares)
    {
        return RedemptionLogic.lptMaxWithdrawable(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _owner);
    }

    /// @inheritdoc IRoycoDayKernel
    function lptMaxWithdrawableMultiAsset(address _owner)
        public
        virtual
        override(IRoycoDayKernel)
        returns (NAV_UNIT claimOnLPTNAV, NAV_UNIT lptMaxWithdrawableNAV, uint256 totalTrancheShares)
    {
        return RedemptionLogic.lptMaxWithdrawableMultiAsset(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _owner);
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
        return AccountingSyncLogic.syncTrancheAccounting(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState());
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
        return AccountingSyncLogic.syncTrancheAccountingFor(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _trancheType);
    }

    /// @inheritdoc IRoycoDayKernel
    function previewSyncTrancheAccountingFor(TrancheType _trancheType)
        public
        view
        virtual
        override(IRoycoDayKernel)
        whenNotPaused
        returns (SyncedAccountingState memory state, AssetClaims memory claims, uint256 totalTrancheShares)
    {
        RoycoDayKernelState storage $ = _getRoycoDayKernelStorage();
        // Simulate the poke first so a circuit-breaking oracle reverts identically to a real operation
        IRoycoPriceOracle($.collateralAssetOracle).previewPoke();
        return AccountingSyncLogic.previewSyncTrancheAccountingFor($, _getRoycoDayKernelImmutableState(), _trancheType);
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
        AccountingSyncLogic.reinvestLiquidityPremium(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _stShares);
    }

    // =============================
    // Senior Tranche Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoDayKernel
    /// @dev ST deposits are enabled only in a PERPETUAL market state, granted that the market's coverage and liquidity requirements are satisfied post-deposit
    function stDeposit(
        bool _isPreview,
        TRANCHE_UNIT _assets
    )
        external
        virtual
        override(IRoycoDayKernel)
        whenNotPaused
        onlySeniorTranche
        nonReentrant
        withCollateralPriceCached
        returns (NAV_UNIT depositNAV, NAV_UNIT effectiveNAV, uint256 totalTrancheShares)
    {
        return DepositLogic.stDeposit(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _isPreview, _assets);
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev ST redemptions are enabled if the market is in a PERPETUAL state
    function stRedeem(
        bool _isPreview,
        uint256 _shares,
        address _receiver
    )
        external
        virtual
        override(IRoycoDayKernel)
        whenNotPaused
        onlySeniorTranche
        nonReentrant
        withCollateralPriceCached
        returns (AssetClaims memory userAssetClaims)
    {
        return RedemptionLogic.stRedeem(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _isPreview, _shares, _receiver);
    }

    // =============================
    // Junior Tranche Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoDayKernel
    /// @dev JT deposits are enabled if the market is in a PERPETUAL state
    function jtDeposit(
        bool _isPreview,
        TRANCHE_UNIT _assets
    )
        external
        virtual
        override(IRoycoDayKernel)
        whenNotPaused
        onlyJuniorTranche
        nonReentrant
        withCollateralPriceCached
        returns (NAV_UNIT depositNAV, NAV_UNIT effectiveNAV, uint256 totalTrancheShares)
    {
        return DepositLogic.jtDeposit(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _isPreview, _assets);
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev JT redemptions are enabled only in a PERPETUAL market state, granted that the market's coverage requirement is satisfied post-redemption
    function jtRedeem(
        bool _isPreview,
        uint256 _shares,
        address _receiver
    )
        external
        virtual
        override(IRoycoDayKernel)
        whenNotPaused
        onlyJuniorTranche
        nonReentrant
        withCollateralPriceCached
        returns (AssetClaims memory userAssetClaims)
    {
        return RedemptionLogic.jtRedeem(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _isPreview, _shares, _receiver);
    }

    // =============================
    // Liquidity Provider Tranche Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoDayKernel
    /// @dev An in-kind LPT deposit mints no new senior shares and only deepens liquidity, so it is enabled in every market state and enforces no requirements
    function lptDeposit(
        bool _isPreview,
        TRANCHE_UNIT _assets
    )
        external
        virtual
        override(IRoycoDayKernel)
        whenNotPaused
        onlyLiquidityProviderTranche
        nonReentrant
        withCollateralPriceCached
        returns (NAV_UNIT depositNAV, NAV_UNIT effectiveNAV, uint256 totalTrancheShares)
    {
        return DepositLogic.lptDeposit(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _isPreview, _assets);
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev LPT redemptions are enabled only in a PERPETUAL market state, granted that the market's liquidity requirement is satisfied post-redemption
    function lptRedeem(
        bool _isPreview,
        uint256 _shares,
        address _receiver
    )
        external
        virtual
        override(IRoycoDayKernel)
        whenNotPaused
        onlyLiquidityProviderTranche
        nonReentrant
        withCollateralPriceCached
        returns (AssetClaims memory userAssetClaims)
    {
        return RedemptionLogic.lptRedeem(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _isPreview, _shares, _receiver);
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev LPT multi-asset deposits are enabled in a PERPETUAL market state (granted the market's coverage and liquidity requirements are satisfied against the new senior exposure), and in a fixed-term market only for a quote-only deposit that mints no senior shares
    function lptDepositMultiAsset(
        bool _isPreview,
        TRANCHE_UNIT _collateralAssets,
        uint256 _quoteAssets,
        TRANCHE_UNIT _minLPTAssetsOut
    )
        external
        virtual
        override(IRoycoDayKernel)
        whenNotPaused
        onlyLiquidityProviderTranche
        nonReentrant
        withCollateralPriceCached
        returns (NAV_UNIT depositNAV, NAV_UNIT effectiveNAV, TRANCHE_UNIT lptAssetsOut)
    {
        return DepositLogic.lptDepositMultiAsset(
            _getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _isPreview, _collateralAssets, _quoteAssets, _minLPTAssetsOut
        );
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev LPT multi-asset redemptions are enabled only in a PERPETUAL market state, granted the market's liquidity requirement is satisfied post-redemption
    function lptRedeemMultiAsset(
        bool _isPreview,
        uint256 _lptShares,
        uint256 _minSTSharesOut,
        uint256 _minQuoteAssetsOut,
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
            _getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _isPreview, _lptShares, _minSTSharesOut, _minQuoteAssetsOut, _receiver
        );
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
        if (_syncBeforeUpdate) _preOpSyncTrancheAccountingWithFreshCache();
        // Update the collateral asset oracle
        _setCollateralAssetOracle(_collateralAssetOracle, _stalenessThresholdSeconds);
        // Sync the tranche accounting to reflect the PNL from the updated oracle's price (the sync re-initializes the price cache to the new price)
        _preOpSyncTrancheAccountingWithFreshCache();
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev The sequencer uptime feed and grace period do not affect the collateral asset price, so no accounting sync is performed
    function setSequencerUptimeFeed(address _sequencerUptimeFeed, uint48 _gracePeriodSeconds) external virtual override(IRoycoDayKernel) restricted {
        _setSequencerUptimeFeed(_sequencerUptimeFeed, _gracePeriodSeconds);
    }

    // =============================
    // Internal Utility Functions
    // =============================

    /**
     * @notice Invokes the accountant to do a pre-operation (deposit and withdrawal) NAV sync and mints any protocol fee shares accrued
     * @dev A sync must be executed before every NAV mutating operation (deposit and withdrawal)
     * @dev Uses the price cache since it is called by admin setters outside a cached operation, so it re-initializes the price cache to the live price before syncing
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function _preOpSyncTrancheAccountingWithFreshCache() internal virtual withCollateralPriceCached returns (SyncedAccountingState memory state) {
        return AccountingSyncLogic._preOpSyncTrancheAccounting(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState());
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

    /// @inheritdoc IRoycoDayKernel
    function enforceNotBlacklisted(address[] memory _accounts) external view override(IRoycoDayKernel) {
        BlacklistLogic._enforceNotBlacklisted(_getRoycoDayKernelStorage(), _accounts);
    }

    /// @inheritdoc IRoycoDayKernel
    function enforceNotBlacklisted(address _account) external view override(IRoycoDayKernel) {
        BlacklistLogic._enforceNotBlacklisted(_getRoycoDayKernelStorage(), _account);
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
    // Collateral Oracle Functions
    // =============================

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
        return _queryCollateralAssetOracle();
    }

    /**
     * @notice Queries the collateral asset oracle for the value of 1 whole collateral asset in NAV units
     * @dev The reported price is gated by the L2 sequencer, staleness, and non-zero price checks
     * @return collateralAssetPrice The value of 1 whole collateral asset in NAV units
     */
    function _queryCollateralAssetOracle() internal view returns (NAV_UNIT collateralAssetPrice) {
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
    // State Accessor Functions
    // =============================

    /**
     * @notice Builds the immutables carrier threaded into the kernel's delegatecall logic libraries
     * @dev A delegatecalled library cannot read the kernel's immutables directly, so they are passed in via this struct
     * @return immutables The kernel's senior, junior, and liquidity provider tranche addresses, the collateral and LPT assets, and the accountant
     */
    function _getRoycoDayKernelImmutableState() internal view returns (RoycoDayKernelImmutableState memory immutables) {
        return RoycoDayKernelImmutableState({
            seniorTranche: SENIOR_TRANCHE,
            juniorTranche: JUNIOR_TRANCHE,
            collateralAsset: COLLATERAL_ASSET,
            liquidityProviderTranche: LIQUIDITY_PROVIDER_TRANCHE,
            lptAsset: LPT_ASSET,
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
