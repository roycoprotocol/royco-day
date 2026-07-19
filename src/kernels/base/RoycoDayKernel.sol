// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IAccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { ReentrancyGuardTransient } from "../../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import { RoycoBase } from "../../base/RoycoBase.sol";
import { IRoycoDayAccountant } from "../../interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { WAD } from "../../libraries/Constants.sol";
import { AssetClaims, SyncedAccountingState, TrancheType } from "../../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../../libraries/Units.sol";
import { AccountingSyncLogic } from "../../libraries/logic/AccountingSyncLogic.sol";
import { BlacklistLogic } from "../../libraries/logic/BlacklistLogic.sol";
import { DepositLogic } from "../../libraries/logic/DepositLogic.sol";
import { RedemptionLogic } from "../../libraries/logic/RedemptionLogic.sol";

/**
 * @title RoycoDayKernel
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Abstract contract serving as the base for all Royco kernel implementations
 * @dev Provides the foundational logic for kernel contracts including pre and post operation NAV reconciliation, coverage enforcement logic,
 *      and base wiring for tranche synchronization
 *      All concrete kernel implementations should inherit from the Royco Kernel
 */
abstract contract RoycoDayKernel is IRoycoDayKernel, RoycoBase, ReentrancyGuardTransient {
    /// @dev Storage slot for RoycoDayKernelState using ERC-7201 pattern
    /// @dev keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoDayKernelState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROYCO_DAY_KERNEL_STORAGE_SLOT = 0xc366ce7b07de4bd3f36c874874355fb088fd2057e716d8a9786c17b22e6fec00;

    /// @inheritdoc IRoycoDayKernel
    address public immutable override(IRoycoDayKernel) SENIOR_TRANCHE;

    /// @inheritdoc IRoycoDayKernel
    address public immutable override(IRoycoDayKernel) ST_ASSET;

    /// @inheritdoc IRoycoDayKernel
    address public immutable override(IRoycoDayKernel) JUNIOR_TRANCHE;

    /// @inheritdoc IRoycoDayKernel
    address public immutable override(IRoycoDayKernel) JT_ASSET;

    /// @inheritdoc IRoycoDayKernel
    address public immutable override(IRoycoDayKernel) LIQUIDITY_TRANCHE;

    /// @inheritdoc IRoycoDayKernel
    address public immutable override(IRoycoDayKernel) LT_ASSET;

    /// @inheritdoc IRoycoDayKernel
    /// @dev Venue-agnostic getter: a concrete liquidity-tranche quoter overrides this with its quote asset
    function QUOTE_ASSET() external view virtual override(IRoycoDayKernel) returns (address quoteAsset);

    /// @inheritdoc IRoycoDayKernel
    address public immutable override(IRoycoDayKernel) ACCOUNTANT;

    /// @notice Whether to enforce the tranche whitelist on share transfers
    bool public immutable ENFORCE_TRANCHE_WHITELIST_ON_TRANSFER;

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

    /// @dev Permissions the function to only be callable by the market's liquidity tranche
    /// @dev Should be placed on LT deposit and redeem functions
    modifier onlyLiquidityTranche() {
        require(msg.sender == LIQUIDITY_TRANCHE, ONLY_LIQUIDITY_TRANCHE());
        _;
    }

    /// @dev Permissions the function to only be callable by the market's senior, junior, or liquidity tranche
    modifier onlyTranche() {
        require(msg.sender == SENIOR_TRANCHE || msg.sender == JUNIOR_TRANCHE || msg.sender == LIQUIDITY_TRANCHE, ONLY_TRANCHE());
        _;
    }

    /// @dev Initializes the quoter cache at the start of the call, no teardown is needed since the transient cache auto-clears at transaction end
    /// @dev Should be placed on all functions that use the quoter cache
    modifier withQuoterCache() {
        _initializeQuoterCache();
        _;
    }

    // =============================
    // Construction and Initialization Functions
    // =============================

    /// @notice Constructs the base Royco kernel state
    /// @param _params The standard construction parameters for the Royco kernel
    constructor(RoycoDayKernelConstructionParams memory _params) {
        // Ensure that the tranche and accountant addresses are not null
        require(
            _params.seniorTranche != address(0) && _params.stAsset != address(0) && _params.juniorTranche != address(0) && _params.jtAsset != address(0)
                && _params.accountant != address(0) && _params.liquidityTranche != address(0) && _params.ltAsset != address(0),
            NULL_ADDRESS()
        );

        // Set the immutable addresses
        SENIOR_TRANCHE = _params.seniorTranche;
        ST_ASSET = _params.stAsset;
        JUNIOR_TRANCHE = _params.juniorTranche;
        JT_ASSET = _params.jtAsset;
        ACCOUNTANT = _params.accountant;
        LIQUIDITY_TRANCHE = _params.liquidityTranche;
        LT_ASSET = _params.ltAsset;
        ENFORCE_TRANCHE_WHITELIST_ON_TRANSFER = _params.enforceVaultSharesTransferWhitelist;

        // The senior and junior tranches must hold the same yield-bearing asset (coinvestment) so the junior tranche's capital always shares the senior tranche's exposure
        require(_params.stAsset == _params.jtAsset, TRANCHE_ASSETS_MUST_BE_IDENTICAL());
    }

    /**
     * @notice Initializes the base Royco kernel state
     * @dev Initializes any parent contracts and the base kernel state
     * @param _params The standard initialization parameters for the Royco kernel
     */
    function __RoycoDayKernel_init(RoycoDayKernelInitParams memory _params) internal onlyInitializing {
        // Ensure that the tranches and their corresponding assets in the kernel match
        require(
            IRoycoVaultTranche(SENIOR_TRANCHE).asset() == ST_ASSET && IRoycoVaultTranche(JUNIOR_TRANCHE).asset() == JT_ASSET
                && IRoycoVaultTranche(LIQUIDITY_TRANCHE).asset() == LT_ASSET,
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
    }

    // =============================
    // Tranche Asset Quoter Functions
    // =============================

    /// @inheritdoc IRoycoDayKernel
    function stConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _stAssets) public view virtual override(IRoycoDayKernel) returns (NAV_UNIT);

    /// @inheritdoc IRoycoDayKernel
    function jtConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _jtAssets) public view virtual override(IRoycoDayKernel) returns (NAV_UNIT);

    /// @inheritdoc IRoycoDayKernel
    function ltConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _ltAssets) public view virtual override(IRoycoDayKernel) returns (NAV_UNIT);

    /// @inheritdoc IRoycoDayKernel
    function stConvertNAVUnitsToTrancheUnits(NAV_UNIT _value) public view virtual override(IRoycoDayKernel) returns (TRANCHE_UNIT);

    /// @inheritdoc IRoycoDayKernel
    function jtConvertNAVUnitsToTrancheUnits(NAV_UNIT _value) public view virtual override(IRoycoDayKernel) returns (TRANCHE_UNIT);

    /// @inheritdoc IRoycoDayKernel
    function ltConvertNAVUnitsToTrancheUnits(NAV_UNIT _value) public view virtual override(IRoycoDayKernel) returns (TRANCHE_UNIT);

    // =============================
    // Tranche Preview Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoDayKernel
    function stPreviewDeposit(TRANCHE_UNIT _assets)
        public
        view
        override(IRoycoDayKernel)
        returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated, uint256 totalTrancheShares)
    {
        return DepositLogic.stPreviewDeposit(_assets);
    }

    /// @inheritdoc IRoycoDayKernel
    function jtPreviewDeposit(TRANCHE_UNIT _assets)
        public
        view
        override(IRoycoDayKernel)
        returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated, uint256 totalTrancheShares)
    {
        return DepositLogic.jtPreviewDeposit(_assets);
    }

    /// @inheritdoc IRoycoDayKernel
    function ltPreviewDeposit(TRANCHE_UNIT _assets)
        external
        view
        override(IRoycoDayKernel)
        returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated, uint256 totalTrancheShares, NAV_UNIT navToMintSharesAt)
    {
        return DepositLogic.ltPreviewDeposit(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _assets);
    }

    /// @inheritdoc IRoycoDayKernel
    function ltPreviewDepositMultiAsset(
        TRANCHE_UNIT _stAssets,
        uint256 _quoteAssets
    )
        external
        virtual
        override(IRoycoDayKernel)
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt, TRANCHE_UNIT ltAssetsOut, uint256 ltTotalSupplyAfterMints)
    {
        return DepositLogic.ltPreviewDepositMultiAsset(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _stAssets, _quoteAssets);
    }

    /// @inheritdoc IRoycoDayKernel
    function ltPreviewRedeemMultiAsset(uint256 _ltShares)
        external
        virtual
        override(IRoycoDayKernel)
        returns (AssetClaims memory stClaims, uint256 quoteAssets)
    {
        return RedemptionLogic.ltPreviewRedeemMultiAsset(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _ltShares);
    }

    /// @inheritdoc IRoycoDayKernel
    function stPreviewRedeem(uint256 _shares) public view override(IRoycoDayKernel) returns (AssetClaims memory userClaim) {
        return RedemptionLogic.stPreviewRedeem(_getRoycoDayKernelStorage(), _shares);
    }

    /// @inheritdoc IRoycoDayKernel
    function jtPreviewRedeem(uint256 _shares) public view override(IRoycoDayKernel) returns (AssetClaims memory userClaim) {
        return RedemptionLogic.jtPreviewRedeem(_shares);
    }

    /// @inheritdoc IRoycoDayKernel
    function ltPreviewRedeem(uint256 _shares) public view override(IRoycoDayKernel) returns (AssetClaims memory userClaim) {
        return RedemptionLogic.ltPreviewRedeem(_shares);
    }

    // =============================
    // Tranche Max Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoDayKernel
    /// @dev ST deposits are allowed only in a PERPETUAL market state, granted that the market's coverage requirement is satisfied post-deposit
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
    /// @dev An in-kind LT deposit mints no new senior shares and only deepens liquidity, so it is enabled in every market state and unbounded
    function ltMaxDeposit(address _receiver) public view virtual override(IRoycoDayKernel) returns (TRANCHE_UNIT) {
        return DepositLogic.ltMaxDeposit(_getRoycoDayKernelStorage(), _receiver);
    }

    /// @inheritdoc IRoycoDayKernel
    function ltMaxWithdrawable(address _owner)
        public
        view
        virtual
        override(IRoycoDayKernel)
        returns (NAV_UNIT claimOnLTNAV, NAV_UNIT ltMaxWithdrawableNAV, uint256 totalTrancheShares)
    {
        return RedemptionLogic.ltMaxWithdrawable(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _owner);
    }

    /// @inheritdoc IRoycoDayKernel
    function ltMaxWithdrawableMultiAsset(address _owner)
        public
        virtual
        override(IRoycoDayKernel)
        returns (NAV_UNIT claimOnLTNAV, NAV_UNIT ltMaxWithdrawableNAV, uint256 totalTrancheShares)
    {
        return RedemptionLogic.ltMaxWithdrawableMultiAsset(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _owner);
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
        withQuoterCache
        returns (SyncedAccountingState memory state)
    {
        return AccountingSyncLogic.syncTrancheAccounting(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState());
    }

    /// @inheritdoc IRoycoDayKernel
    function reinvestLiquidityPremium(uint256 _stShares) external virtual override(IRoycoDayKernel) whenNotPaused restricted nonReentrant withQuoterCache {
        AccountingSyncLogic.reinvestLiquidityPremium(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _stShares);
    }

    /// @inheritdoc IRoycoDayKernel
    function previewSyncTrancheAccounting(TrancheType _trancheType)
        public
        view
        virtual
        override(IRoycoDayKernel)
        whenNotPaused
        returns (SyncedAccountingState memory state, AssetClaims memory claims, uint256 totalTrancheShares)
    {
        return AccountingSyncLogic.previewSyncTrancheAccounting(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _trancheType);
    }

    // =============================
    // Senior Tranche Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoDayKernel
    /// @dev ST deposits are enabled only in a PERPETUAL market state, granted that the market's coverage requirement is satisfied post-deposit
    function stDeposit(TRANCHE_UNIT _assets)
        external
        virtual
        override(IRoycoDayKernel)
        whenNotPaused
        onlySeniorTranche
        nonReentrant
        withQuoterCache
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt)
    {
        return DepositLogic.stDeposit(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _assets);
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev ST redemptions are enabled if the market is in a PERPETUAL state
    function stRedeem(
        uint256 _shares,
        address _receiver
    )
        external
        virtual
        override(IRoycoDayKernel)
        whenNotPaused
        onlySeniorTranche
        nonReentrant
        withQuoterCache
        returns (AssetClaims memory userAssetClaims)
    {
        return RedemptionLogic.stRedeem(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _shares, _receiver);
    }

    // =============================
    // Junior Tranche Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoDayKernel
    /// @dev JT deposits are enabled if the market is in a PERPETUAL state
    function jtDeposit(TRANCHE_UNIT _assets)
        external
        virtual
        override(IRoycoDayKernel)
        whenNotPaused
        onlyJuniorTranche
        nonReentrant
        withQuoterCache
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt)
    {
        return DepositLogic.jtDeposit(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _assets);
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev JT redemptions are enabled only in a PERPETUAL market state, granted that the market's coverage requirement is satisfied post-redemption
    function jtRedeem(
        uint256 _shares,
        address _receiver
    )
        external
        virtual
        override(IRoycoDayKernel)
        whenNotPaused
        onlyJuniorTranche
        nonReentrant
        withQuoterCache
        returns (AssetClaims memory userAssetClaims)
    {
        return RedemptionLogic.jtRedeem(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _shares, _receiver);
    }

    // =============================
    // Liquidity Tranche Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoDayKernel
    /// @dev An in-kind LT deposit mints no new senior shares and only deepens liquidity, so it is enabled in every market state and enforces no requirements
    function ltDeposit(TRANCHE_UNIT _assets)
        external
        virtual
        override(IRoycoDayKernel)
        whenNotPaused
        onlyLiquidityTranche
        nonReentrant
        withQuoterCache
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt)
    {
        return DepositLogic.ltDeposit(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _assets);
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev LT redemptions are enabled only in a PERPETUAL market state, granted that the market's liquidity requirement is satisfied post-redemption
    function ltRedeem(
        uint256 _shares,
        address _receiver
    )
        external
        virtual
        override(IRoycoDayKernel)
        whenNotPaused
        onlyLiquidityTranche
        nonReentrant
        withQuoterCache
        returns (AssetClaims memory userAssetClaims)
    {
        return RedemptionLogic.ltRedeem(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _shares, _receiver);
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev LT multi-asset deposits are enabled in a PERPETUAL market state (granted the market's coverage and liquidity requirements are satisfied against the new senior exposure), and in a fixed-term market only for a quote-only deposit that mints no senior shares
    function ltDepositMultiAsset(
        TRANCHE_UNIT _stAssets,
        uint256 _quoteAssets,
        TRANCHE_UNIT _minLTAssetsOut
    )
        external
        virtual
        override(IRoycoDayKernel)
        whenNotPaused
        onlyLiquidityTranche
        nonReentrant
        withQuoterCache
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt, TRANCHE_UNIT ltAssetsOut)
    {
        return DepositLogic.ltDepositMultiAsset(_getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _stAssets, _quoteAssets, _minLTAssetsOut);
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev LT multi-asset redemptions are enabled only in a PERPETUAL market state, granted the market's liquidity requirement is satisfied post-redemption
    function ltRedeemMultiAsset(
        uint256 _ltShares,
        uint256 _minSTSharesOut,
        uint256 _minQuoteAssetsOut,
        address _receiver
    )
        external
        virtual
        override(IRoycoDayKernel)
        whenNotPaused
        onlyLiquidityTranche
        nonReentrant
        withQuoterCache
        returns (AssetClaims memory stClaims, uint256 quoteAssets)
    {
        return RedemptionLogic.ltRedeemMultiAsset(
            _getRoycoDayKernelStorage(), _getRoycoDayKernelImmutableState(), _ltShares, _minSTSharesOut, _minQuoteAssetsOut, _receiver
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

    // =============================
    // Internal Utility Functions
    // =============================

    /**
     * @notice Invokes the accountant to do a pre-operation (deposit and withdrawal) NAV sync and mints any protocol fee shares accrued
     * @dev A sync must be executed before every NAV mutating operation (deposit and withdrawal)
     * @dev Uses the quoter cache since it is called by admin setters outside a cached operation, so it re-initializes the quoter cache to the live rate before syncing
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function _preOpSyncTrancheAccounting() internal virtual withQuoterCache returns (SyncedAccountingState memory state) {
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
     * @notice Returns whether an account is a market-specific custodian of tranche shares such as the LT venue
     * @dev Intentionally implemented with an empty body since inheriting contracts are not required to override this function
     * @param _account The account to check
     * @return True if the account is a market-specific tranche share custodian
     */
    function _isTrancheShareCustodian(address _account) internal view virtual returns (bool) { }

    /**
     * @notice Initializes the quoter
     * @dev Should be called at the start of a call
     * @dev Typically used to initialize the cached tranche unit to NAV unit conversion rate
     * @dev Intentionally implemented with an empty body since inheriting contracts are not required to override this function: the cache is a pure optimization and quoters that do not cache read live
     */
    function _initializeQuoterCache() internal virtual { }

    // =============================
    // State Accessor Functions
    // =============================

    /**
     * @notice Builds the immutables carrier threaded into the kernel's delegatecall logic libraries
     * @dev A delegatecalled library cannot read the kernel's immutables directly, so they are passed in via this struct
     * @return immutables The kernel's senior, junior, and liquidity tranche addresses, their respective assets, and the accountant
     */
    function _getRoycoDayKernelImmutableState() internal view returns (RoycoDayKernelImmutableState memory immutables) {
        return RoycoDayKernelImmutableState({
            seniorTranche: SENIOR_TRANCHE,
            stAsset: ST_ASSET,
            juniorTranche: JUNIOR_TRANCHE,
            jtAsset: JT_ASSET,
            liquidityTranche: LIQUIDITY_TRANCHE,
            ltAsset: LT_ASSET,
            accountant: ACCOUNTANT
        });
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
