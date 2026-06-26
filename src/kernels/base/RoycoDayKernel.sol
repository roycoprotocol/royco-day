// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IAccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from "../../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import { RoycoBase } from "../../base/RoycoBase.sol";
import { IRoycoBlacklist } from "../../interfaces/IRoycoBlacklist.sol";
import { IRoycoDayAccountant } from "../../interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { MAX_NAV_UNITS, MAX_TRANCHE_UNITS, WAD, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../../libraries/Constants.sol";
import { AssetClaims, MarketState, Operation, SyncedAccountingState, TrancheType } from "../../libraries/Types.sol";
import { Math, NAV_UNIT, TRANCHE_UNIT, UnitsMathLib, toTrancheUnits, toUint256 } from "../../libraries/Units.sol";
import { UtilsLib } from "../../libraries/UtilsLib.sol";

/**
 * @title RoycoDayKernel
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Abstract contract serving as the base for all Royco kernel implementations
 * @dev Provides the foundational logic for kernel contracts including pre and post operation NAV reconciliation, coverage enforcement logic,
 *      and base wiring for tranche synchronization. All concrete kernel implementations should inherit from the Royco Kernel.
 */
abstract contract RoycoDayKernel is IRoycoDayKernel, RoycoBase, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using UnitsMathLib for NAV_UNIT;
    using UnitsMathLib for TRANCHE_UNIT;

    /// @dev Storage slot for RoycoDayKernelState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoDayKernelState")) - 1)) & ~bytes32(uint256(0xff))
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
    address public immutable override(IRoycoDayKernel) QUOTE_ASSET;

    /// @inheritdoc IRoycoDayKernel
    address public immutable override(IRoycoDayKernel) ACCOUNTANT;

    /// @notice Whether to enforce the tranche shares transfer whitelist
    bool public immutable ENFORCE_TRANCHE_SHARES_TRANSFER_WHITELIST;

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

    /// @dev Permissions the function to only be callable by the market's junior tranche
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

    /// @dev Initializes and clears the quoter cache at the start and end of the call respectively
    /// @dev Should be placed on all functions that use the quoter cache
    modifier withQuoterCache() {
        _initializeQuoterCache();
        _;
        _clearQuoterCache();
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
                && _params.accountant != address(0) && _params.liquidityTranche != address(0) && _params.ltAsset != address(0)
                && _params.quoteAsset != address(0),
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
        QUOTE_ASSET = _params.quoteAsset;
        ENFORCE_TRANCHE_SHARES_TRANSFER_WHITELIST = _params.enforceVaultSharesTransferWhitelist;
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
    function stConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) public view virtual override(IRoycoDayKernel) returns (TRANCHE_UNIT);

    /// @inheritdoc IRoycoDayKernel
    function jtConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) public view virtual override(IRoycoDayKernel) returns (TRANCHE_UNIT);

    /// @inheritdoc IRoycoDayKernel
    function ltConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) public view virtual override(IRoycoDayKernel) returns (TRANCHE_UNIT);

    // =============================
    // Tranche Preview Functions
    // =============================

    /// @inheritdoc IRoycoDayKernel
    function stPreviewDeposit(TRANCHE_UNIT _assets)
        public
        view
        override(IRoycoDayKernel)
        returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated)
    {
        // Preview the state of the senior tranche before the deposit
        stateBeforeDeposit = _previewSyncTrancheAccounting();
        // Convert the assets to NAV units
        valueAllocated = stConvertTrancheUnitsToNAVUnits(_assets);
    }

    /// @inheritdoc IRoycoDayKernel
    function jtPreviewDeposit(TRANCHE_UNIT _assets)
        public
        view
        override(IRoycoDayKernel)
        returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated)
    {
        // Preview the state of the junior tranche before the deposit
        stateBeforeDeposit = _previewSyncTrancheAccounting();
        // Convert the assets to NAV units
        valueAllocated = jtConvertTrancheUnitsToNAVUnits(_assets);
    }

    /// @inheritdoc IRoycoDayKernel
    function ltPreviewDeposit(TRANCHE_UNIT _assets)
        public
        view
        override(IRoycoDayKernel)
        returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated)
    {
        // Preview the state of the liquidity tranche before the deposit
        stateBeforeDeposit = _previewSyncTrancheAccounting();
        // Convert the assets to NAV units
        valueAllocated = ltConvertTrancheUnitsToNAVUnits(_assets);
    }

    /// @inheritdoc IRoycoDayKernel
    function stPreviewRedeem(uint256 _shares) public view override(IRoycoDayKernel) returns (AssetClaims memory userClaim) {
        // Preview the total claims the senior tranche has on each tranche's assets and the total shares after minting any protocol fee shares post-sync
        (SyncedAccountingState memory state, AssetClaims memory stNotionalClaims, uint256 totalShares) = previewSyncTrancheAccounting(TrancheType.SENIOR);

        // Calculate the user's claims based on the shares redeemed
        userClaim = UtilsLib.scaleAssetClaims(stNotionalClaims, _shares, totalShares);
        (userClaim,) = _applySeniorTrancheSelfLiquidationBonus(state, userClaim);
    }

    /// @inheritdoc IRoycoDayKernel
    function jtPreviewRedeem(uint256 _shares) public view override(IRoycoDayKernel) returns (AssetClaims memory userClaim) {
        // Preview the total claims the junior tranche has on each tranche's assets and the total shares after minting any protocol fee shares post-sync
        (, AssetClaims memory jtNotionalClaims, uint256 totalShares) = previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Calculate the user's claims based on the shares redeemed
        userClaim = UtilsLib.scaleAssetClaims(jtNotionalClaims, _shares, totalShares);
    }

    /// @inheritdoc IRoycoDayKernel
    function ltPreviewRedeem(uint256 _shares) public view override(IRoycoDayKernel) returns (AssetClaims memory userClaim) {
        // Preview the total claims the liquidity tranche has on each tranche's assets and the total shares after minting any protocol fee shares post-sync
        (, AssetClaims memory ltNotionalClaims, uint256 totalShares) = previewSyncTrancheAccounting(TrancheType.LIQUIDITY);

        // Calculate the user's claims based on the shares redeemed
        userClaim = UtilsLib.scaleAssetClaims(ltNotionalClaims, _shares, totalShares);
    }

    // =============================
    // Tranche Max Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoDayKernel
    /// @dev ST deposits are allowed only in a PERPETUAL market state, granted that the market's coverage requirement is satisfied post-deposit
    function stMaxDeposit(address _receiver) public view virtual override(IRoycoDayKernel) returns (TRANCHE_UNIT) {
        // If the receiver is blacklisted or the kernel is currently paused, return zero tranche units
        if (_isBlacklisted(_receiver) || paused()) return ZERO_TRANCHE_UNITS;
        SyncedAccountingState memory state = _previewSyncTrancheAccounting();
        // ST deposits are disabled during a fixed-term market state
        if (state.marketState == MarketState.FIXED_TERM) return ZERO_TRANCHE_UNITS;
        // ST deposits are enabled as long as the market's coverage requirement is satisfied
        // No need to include ST liquidation proceeds in the raw NAV because those assets are not exposed to any volatility
        NAV_UNIT stMaxDepositableNAV = IRoycoDayAccountant(ACCOUNTANT).maxSTDeposit(state);
        return ((stMaxDepositableNAV == MAX_NAV_UNITS) ? MAX_TRANCHE_UNITS : stConvertNAVUnitsToTrancheUnits(stMaxDepositableNAV));
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev ST redemptions are allowed in PERPETUAL market states
    function stMaxWithdrawable(address _owner)
        public
        view
        virtual
        override(IRoycoDayKernel)
        returns (
            NAV_UNIT claimOnStNAV,
            NAV_UNIT claimOnJtNAV,
            NAV_UNIT stMaxWithdrawableNAV,
            NAV_UNIT jtMaxWithdrawableNAV,
            uint256 totalTrancheSharesAfterMintingFees
        )
    {
        // If the owner is blacklisted or the kernel is currently paused, return zero claims
        if (_isBlacklisted(_owner) || paused()) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);

        SyncedAccountingState memory state;
        AssetClaims memory stNotionalClaims;
        (state, stNotionalClaims, totalTrancheSharesAfterMintingFees) = previewSyncTrancheAccounting(TrancheType.SENIOR);

        // ST redemptions are disabled during a fixed-term market state
        if (state.marketState == MarketState.FIXED_TERM) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);

        // Get the total claims the senior tranche has on each tranche's assets
        claimOnStNAV = stConvertTrancheUnitsToNAVUnits(stNotionalClaims.stAssets);
        claimOnJtNAV = jtConvertTrancheUnitsToNAVUnits(stNotionalClaims.jtAssets);

        // Bound the claims by the max withdrawable assets globally for each tranche and compute the cumulative NAV
        stMaxWithdrawableNAV = _getSeniorTrancheRawNAV();
        jtMaxWithdrawableNAV = _getJuniorTrancheRawNAV();
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev JT deposits are allowed if the market is in a PERPETUAL state
    function jtMaxDeposit(address _receiver) public view virtual override(IRoycoDayKernel) returns (TRANCHE_UNIT) {
        // If the receiver is blacklisted or the kernel is currently paused, return zero tranche units
        if (_isBlacklisted(_receiver) || paused()) return ZERO_TRANCHE_UNITS;
        // JT deposits are disabled during a fixed-term market state
        if ((_previewSyncTrancheAccounting()).marketState == MarketState.FIXED_TERM) return ZERO_TRANCHE_UNITS;
        return MAX_TRANCHE_UNITS;
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev JT redemptions are allowed only in a PERPETUAL market state, granted that the market's coverage requirement is satisfied post-redemption
    function jtMaxWithdrawable(address _owner)
        public
        view
        virtual
        override(IRoycoDayKernel)
        returns (
            NAV_UNIT claimOnStNAV,
            NAV_UNIT claimOnJtNAV,
            NAV_UNIT stMaxWithdrawableNAV,
            NAV_UNIT jtMaxWithdrawableNAV,
            uint256 totalTrancheSharesAfterMintingFees
        )
    {
        // If the owner is blacklisted or the kernel is currently paused, return zero claims
        if (_isBlacklisted(_owner) || paused()) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);

        // Get the total claims the junior tranche has on each tranche's assets
        SyncedAccountingState memory state;
        (state,, totalTrancheSharesAfterMintingFees) = previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // JT redemptions are disabled during a fixed-term market state
        if (state.marketState == MarketState.FIXED_TERM) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);

        // Use the precise NAV claims directly from the decomposition instead of round-tripping them through tranche units (NAV -> tranche -> NAV).
        (,, claimOnStNAV, claimOnJtNAV) = UtilsLib.computeTrancheClaimsOnNAVs(state);

        // Get the max withdrawable ST and JT assets in NAV units from the accountant considering the coverage requirement
        (, NAV_UNIT stClaimableGivenCoverage, NAV_UNIT jtClaimableGivenCoverage) = IRoycoDayAccountant(ACCOUNTANT).maxJTWithdrawal(state);

        // Bound the claims by the max withdrawable assets globally for each tranche and compute the cumulative NAV
        stMaxWithdrawableNAV = stClaimableGivenCoverage;
        jtMaxWithdrawableNAV = jtClaimableGivenCoverage;
    }

    /// @inheritdoc IRoycoDayKernel
    function ltMaxDeposit(address _receiver) public view virtual override(IRoycoDayKernel) returns (TRANCHE_UNIT) {
        // If the receiver is blacklisted or the kernel is currently paused, return zero tranche units
        if (_isBlacklisted(_receiver) || paused()) return ZERO_TRANCHE_UNITS;
        // LT deposits are disabled during a fixed-term market state
        if ((_previewSyncTrancheAccounting()).marketState == MarketState.FIXED_TERM) return ZERO_TRANCHE_UNITS;
        return MAX_TRANCHE_UNITS;
    }

    /// @inheritdoc IRoycoDayKernel
    function ltMaxWithdrawable(address _owner)
        public
        view
        virtual
        override(IRoycoDayKernel)
        returns (NAV_UNIT claimOnLtNAV, NAV_UNIT ltMaxWithdrawableNAV, uint256 totalTrancheSharesAfterMintingFees)
    {
        // // If the owner is blacklisted or the kernel is currently paused, return zero claims
        // if (_isBlacklisted(_owner) || paused()) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);

        // // Get the total claims the liquidity tranche has on its own assets
        // SyncedAccountingState memory state;
        // (state,, totalTrancheSharesAfterMintingFees) = previewSyncTrancheAccounting(TrancheType.LIQUIDITY);

        // // LT redemptions are disabled during a fixed-term market state
        // if (state.marketState == MarketState.FIXED_TERM) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);

        // // Use the precise NAV claims directly from the decomposition instead of round-tripping them through tranche units (NAV -> tranche -> NAV).
        // (,,,, claimOnLtNAV) = UtilsLib.computeTrancheClaimsOnNAVs(state);

        // // TODO: Implement (LT max withdrawable); reverts until the LT withdrawal path lands .
        // // Depends on maxLtWithdrawable implementation in the accountant
        // revert("not implemented");
    }

    // =============================
    // External Tranche Accounting and Synchronization Functions
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
        // Execute a NAV accounting sync via the accountant to reconcile PNL
        return _preOpSyncTrancheAccounting();
    }

    /// @inheritdoc IRoycoDayKernel
    function previewSyncTrancheAccounting(TrancheType _trancheType)
        public
        view
        virtual
        override(IRoycoDayKernel)
        returns (SyncedAccountingState memory state, AssetClaims memory claims, uint256 totalTrancheShares)
    {
        // Preview an accounting sync via the accountant
        state = _previewSyncTrancheAccounting();

        // Derive the asset claims for this tranche
        claims = _deriveTrancheAssetClaims(_trancheType, state);

        // Return the requested tranche claims and total shares
        if (_trancheType == TrancheType.SENIOR) {
            (, totalTrancheShares) = IRoycoVaultTranche(SENIOR_TRANCHE).previewMintProtocolFeeShares(state.stProtocolFee, state.stEffectiveNAV);
        } else if (_trancheType == TrancheType.JUNIOR) {
            (, totalTrancheShares) = IRoycoVaultTranche(JUNIOR_TRANCHE).previewMintProtocolFeeShares(state.jtProtocolFee, state.jtEffectiveNAV);
        } else {
            (, totalTrancheShares) = IRoycoVaultTranche(LIQUIDITY_TRANCHE).previewMintProtocolFeeShares(state.ltProtocolFee, state.ltRawNAV);
        }
    }

    // =============================
    // Senior Tranche Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoDayKernel
    /// @dev ST deposits are enabled only in a PERPETUAL market state, granted that the market's coverage requirement is satisfied post-deposit
    /// @dev ST deposits are disabled if the senior tranche has incurred any impermanent loss to prevent dilution
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
        // Execute an accounting sync to reconcile underlying PNL
        SyncedAccountingState memory state = _preOpSyncTrancheAccounting();
        // ST deposits are disabled during a fixed-term market state
        require(state.marketState == MarketState.PERPETUAL, DISABLED_IN_FIXED_TERM_STATE());
        // The NAV to mint tranche shares at is the pre-deposit senior tranche controlled NAV
        navToMintSharesAt = state.stEffectiveNAV;
        // The precise value allocated is the value of the deposited assets
        valueAllocated = stConvertTrancheUnitsToNAVUnits(_assets);

        // Process the deposit for the senior tranche
        _stDepositAssets(_assets);

        // Execute a post-deposit sync on accounting and enforce the market's coverage requirement
        _postOpSyncTrancheAccountingAndEnforceCoverage(Operation.ST_DEPOSIT);
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev ST redemptions are enabled if the market is in a PERPETUAL state
    function stRedeem(
        uint256 _shares,
        address _receiver,
        bool _bypassRedemptionRestrictions
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
        SyncedAccountingState memory state;
        uint256 totalTrancheShares;
        // Execute an accounting sync to reconcile underlying PNL
        (state, userAssetClaims, totalTrancheShares) = _preOpSyncTrancheAccounting(TrancheType.SENIOR);
        // ST redemptions are disabled during a fixed-term market state
        require(_bypassRedemptionRestrictions || state.marketState == MarketState.PERPETUAL, DISABLED_IN_FIXED_TERM_STATE());

        // Scale the cumulative tranche asset claims by the ratio of shares this user owns of the entire tranche
        // Protocol fee shares were minted in the pre-op sync, so the total tranche shares are up to date
        userAssetClaims = UtilsLib.scaleAssetClaims(userAssetClaims, _shares, totalTrancheShares);

        // Apply any ST self-liquidation bonus to the redeeming user's asset claims and retrieve the bonus NAV applied
        NAV_UNIT stSelfLiquidationBonusNAV;
        (userAssetClaims, stSelfLiquidationBonusNAV) = _applySeniorTrancheSelfLiquidationBonus(state, userAssetClaims);

        // Withdraw the asset claims from each tranche with the self-liquidation bonus applied and transfer them to the receiver
        _withdrawAssets(userAssetClaims, _receiver);

        // Execute a post-redeem sync on accounting and include any self-liquidation bonus
        _postOpSyncTrancheAccounting(Operation.ST_REDEEM, stSelfLiquidationBonusNAV);
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
        // Execute an accounting sync to reconcile underlying PNL
        SyncedAccountingState memory state = _preOpSyncTrancheAccounting();
        // JT deposits are disabled during a fixed-term market state
        require(state.marketState == MarketState.PERPETUAL, DISABLED_IN_FIXED_TERM_STATE());
        // The NAV to mint tranche shares at is the pre-deposit junior tranche controlled NAV
        navToMintSharesAt = state.jtEffectiveNAV;
        // The precise value allocated is the value of the deposited assets
        valueAllocated = jtConvertTrancheUnitsToNAVUnits(_assets);

        // Process the deposit for the junior tranche
        _jtDepositAssets(_assets);

        // Execute a post-deposit sync on accounting
        _postOpSyncTrancheAccounting(Operation.JT_DEPOSIT, ZERO_NAV_UNITS);
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev JT redemptions are enabled only in a PERPETUAL market state (unless restrictions are bypassed for a seizure), granted that the market's coverage requirement is satisfied post-redemption
    function jtRedeem(
        uint256 _shares,
        address _receiver,
        bool _bypassRedemptionRestrictions
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
        // Execute a pre-op sync on accounting
        SyncedAccountingState memory state;
        uint256 totalTrancheShares;
        (state, userAssetClaims, totalTrancheShares) = _preOpSyncTrancheAccounting(TrancheType.JUNIOR);
        // JT redemptions are disabled during a fixed-term market state
        require(_bypassRedemptionRestrictions || state.marketState == MarketState.PERPETUAL, DISABLED_IN_FIXED_TERM_STATE());

        // Scale the cumulative tranche asset claims by the ratio of shares this user owns of the entire tranche
        // Protocol fee shares were minted in the pre-op sync, so the total tranche shares are up to date
        userAssetClaims = UtilsLib.scaleAssetClaims(userAssetClaims, _shares, totalTrancheShares);

        // Withdraw the asset claims from each tranche and transfer them to the receiver
        _withdrawAssets(userAssetClaims, _receiver);

        if (_bypassRedemptionRestrictions) {
            // Execute a post-redeem sync on accounting without enforcing the market's coverage requirement
            _postOpSyncTrancheAccounting(Operation.JT_REDEEM, ZERO_NAV_UNITS);
        } else {
            // Execute a post-redeem sync on accounting and enforce the market's coverage requirement
            _postOpSyncTrancheAccountingAndEnforceCoverage(Operation.JT_REDEEM);
        }
    }

    // =============================
    // Liquidity Tranche Deposit and Redeem Functions (stub — not yet implemented)
    // =============================

    /// @inheritdoc IRoycoDayKernel
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
        // Execute an accounting sync to reconcile underlying PNL
        SyncedAccountingState memory state = _preOpSyncTrancheAccounting();
        // JT deposits are disabled during a fixed-term market state
        require(state.marketState == MarketState.PERPETUAL, DISABLED_IN_FIXED_TERM_STATE());
        // The NAV to mint tranche shares at is the pre-deposit junior tranche controlled NAV
        navToMintSharesAt = state.ltRawNAV;
        // The precise value allocated is the value of the deposited assets
        valueAllocated = ltConvertTrancheUnitsToNAVUnits(_assets);

        // Process the deposit for the liquidity tranche
        _ltDepositAssets(_assets);

        // Execute a post-deposit sync on accounting
        _postOpSyncTrancheAccounting(Operation.LT_DEPOSIT, ZERO_NAV_UNITS);
    }

    /// @inheritdoc IRoycoDayKernel
    function ltRedeem(
        uint256 _shares,
        address _receiver,
        bool _bypassRedemptionRestrictions
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
        // Execute a pre-op sync on accounting
        SyncedAccountingState memory state;
        uint256 totalTrancheShares;
        (state, userAssetClaims, totalTrancheShares) = _preOpSyncTrancheAccounting(TrancheType.LIQUIDITY);
        // LT redemptions are disabled during a fixed-term market state
        require(_bypassRedemptionRestrictions || state.marketState == MarketState.PERPETUAL, DISABLED_IN_FIXED_TERM_STATE());

        // Scale the cumulative tranche asset claims by the ratio of shares this user owns of the entire tranche
        // Protocol fee shares were minted in the pre-op sync, so the total tranche shares are up to date
        userAssetClaims = UtilsLib.scaleAssetClaims(userAssetClaims, _shares, totalTrancheShares);

        // Withdraw the asset claims from each tranche and transfer them to the receiver
        _withdrawAssets(userAssetClaims, _receiver);

        if (_bypassRedemptionRestrictions) {
            // Execute a post-redeem sync on accounting without enforcing the market's coverage requirement
            _postOpSyncTrancheAccounting(Operation.LT_REDEEM, ZERO_NAV_UNITS);
        } else {
            // Execute a post-redeem sync on accounting and enforce the market's coverage requirement
            _postOpSyncTrancheAccountingAndEnforceCoverage(Operation.LT_REDEEM);
        }
    }

    // =============================
    // Liquidity Tranche Multi-Asset Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoDayKernel
    function ltDepositMultiAsset(
        TRANCHE_UNIT _stAssets,
        uint256 _quoteAssets,
        uint256 _minStSharesMinted
    )
        external
        virtual
        override(IRoycoDayKernel)
        whenNotPaused
        onlyLiquidityTranche
        nonReentrant
        withQuoterCache
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt, uint256 trancheAssetsOut)
    {
        require((_stAssets != ZERO_TRANCHE_UNITS && _minStSharesMinted != 0) || _quoteAssets != 0, MUST_DEPOSIT_NON_ZERO_ASSETS());

        // Sync and reconcile PnL
        SyncedAccountingState memory state = _preOpSyncTrancheAccounting();
        // Multi-asset deposits are disabled during a fixed-term market state
        require(state.marketState == MarketState.PERPETUAL, DISABLED_IN_FIXED_TERM_STATE());

        // If the ST underlying is deposited, deposit it and mint the senior shares
        uint256 seniorSharesMinted;
        if (_stAssets != ZERO_TRANCHE_UNITS) {
            // Value the deposited ST underlying and compute the non-diluting senior share count to mint
            NAV_UNIT stValueAllocated = stConvertTrancheUnitsToNAVUnits(_stAssets);
            seniorSharesMinted = _navToShares(stValueAllocated, state.stEffectiveNAV, IERC20(SENIOR_TRANCHE).totalSupply());
            // Enforce the caller's slippage bound on the senior shares minted from the underlying (guards against an unfavorable ST share price)
            require(seniorSharesMinted >= _minStSharesMinted, INSUFFICIENT_OUTPUT_AMOUNT());

            // Credit the ST underlying (already transferred to the kernel by the LT tranche).
            // We do not enforce coverage yet
            _stDepositAssets(_stAssets);
            state = _postOpSyncTrancheAccounting(Operation.ST_DEPOSIT, ZERO_NAV_UNITS);

            // Mint the senior shares to the kernel then add them with the quote leg
            IRoycoVaultTranche(SENIOR_TRANCHE).mint(address(this), seniorSharesMinted);
        }

        // If the quote amount is deposited, add it to the liquidity venue
        trancheAssetsOut = _addLiquidityUnbalanced(seniorSharesMinted, _quoteAssets);

        // Deposit the freshly minted LT tranche assets (LP token) into the liquidity tranche
        navToMintSharesAt = state.ltRawNAV;
        valueAllocated = ltConvertTrancheUnitsToNAVUnits(toTrancheUnits(trancheAssetsOut));
        _ltDepositAssets(toTrancheUnits(trancheAssetsOut));

        // Execute a post-deposit sync on accounting and enforce the market's coverage requirement
        _postOpSyncTrancheAccountingAndEnforceCoverage(Operation.LT_DEPOSIT);
    }

    /// @inheritdoc IRoycoDayKernel
    function ltRedeemMultiAsset(
        uint256 _ltShares,
        uint256 _minQuoteOut,
        address _receiver
    )
        external
        virtual
        override(IRoycoDayKernel)
        whenNotPaused
        onlyLiquidityTranche
        nonReentrant
        withQuoterCache
        returns (AssetClaims memory stClaims, uint256 quoteOut)
    {
        // Size the proportional LP-token slice and debit it
        (SyncedAccountingState memory state, AssetClaims memory ltClaims, uint256 totalLtShares) = _preOpSyncTrancheAccounting(TrancheType.LIQUIDITY);
        // Multi-asset redemptions are disabled during a fixed-term market state
        require(state.marketState == MarketState.PERPETUAL, DISABLED_IN_FIXED_TERM_STATE());

        TRANCHE_UNIT trancheAssetsToRemove = UtilsLib.scaleAssetClaims(ltClaims, _ltShares, totalLtShares).ltAssets;
        require(trancheAssetsToRemove != ZERO_TRANCHE_UNITS, INSUFFICIENT_OUTPUT_AMOUNT());

        // Debit the LP-token slice from the LT's owned assets and book the LT redemption
        RoycoDayKernelState storage $ = _getRoycoDayKernelStorage();
        $.ltOwnedYieldBearingAssets = $.ltOwnedYieldBearingAssets - trancheAssetsToRemove;
        _postOpSyncTrancheAccounting(Operation.LT_REDEEM, ZERO_NAV_UNITS);

        // Remove the LP-token slice for its (senior shares + quote) constituents
        uint256 seniorSharesOut;
        (seniorSharesOut, quoteOut) = _removeLiquidityProportional(toUint256(trancheAssetsToRemove), 0, _minQuoteOut);

        // Redeem the pooled senior shares back to ST underlying for the receiver (no self-liquidation bonus: this is an internal unwind)
        (, AssetClaims memory cumulativeStClaims, uint256 totalStShares) = _preOpSyncTrancheAccounting(TrancheType.SENIOR);
        stClaims = UtilsLib.scaleAssetClaims(cumulativeStClaims, seniorSharesOut, totalStShares);

        // Burn the pooled senior shares held by the kernel, then withdraw the corresponding ST underlying to the receiver
        IRoycoVaultTranche(SENIOR_TRANCHE).burn(seniorSharesOut);
        _withdrawAssets(stClaims, _receiver);
        _postOpSyncTrancheAccountingAndEnforceCoverage(Operation.ST_REDEEM);

        require(quoteOut >= _minQuoteOut, INSUFFICIENT_OUTPUT_AMOUNT());

        // Return the quote leg to the receiver and enforce the caller's slippage bounds
        if (quoteOut != 0) IERC20(QUOTE_ASSET).safeTransfer(_receiver, quoteOut);
    }

    /// @inheritdoc IRoycoDayKernel
    function previewLtDepositMultiAsset(
        uint256 _stUnderlying,
        uint256 _quoteAmount
    )
        external
        virtual
        override(IRoycoDayKernel)
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt, uint256 trancheAssetsOut)
    {
        // Preview the ST leg: value the underlying and compute the senior share count against the post-fee senior supply
        (SyncedAccountingState memory state,, uint256 totalStShares) = previewSyncTrancheAccounting(TrancheType.SENIOR);
        NAV_UNIT stValueAllocated = stConvertTrancheUnitsToNAVUnits(toTrancheUnits(_stUnderlying));
        uint256 seniorShares = _navToShares(stValueAllocated, state.stEffectiveNAV, totalStShares);

        // Query the liquidity venue add for the LT tranche assets (LP token) out (non-view query)
        trancheAssetsOut = _queryAddLiquidityUnbalanced(seniorShares, _quoteAmount);

        // Preview the LT leg: the LT shares are minted by the tranche from these outputs at the pre-deposit LT raw NAV
        navToMintSharesAt = state.ltRawNAV;
        valueAllocated = ltConvertTrancheUnitsToNAVUnits(toTrancheUnits(trancheAssetsOut));
    }

    /// @inheritdoc IRoycoDayKernel
    function previewLtRedeemMultiAsset(uint256 _ltShares) external virtual override(IRoycoDayKernel) returns (AssetClaims memory stClaims, uint256 quoteOut) {
        // Preview the LT leg: size the proportional LP-token slice
        (, AssetClaims memory ltClaims, uint256 totalLtShares) = previewSyncTrancheAccounting(TrancheType.LIQUIDITY);
        uint256 trancheAssetsToRemove = toUint256(UtilsLib.scaleAssetClaims(ltClaims, _ltShares, totalLtShares).ltAssets);

        // Query the liquidity venue remove for the (senior shares + quote) constituents (non-view query)
        uint256 seniorSharesOut;
        (seniorSharesOut, quoteOut) = _queryRemoveLiquidityProportional(trancheAssetsToRemove);

        // Preview the ST redeem of the pooled senior shares
        (, AssetClaims memory cumulativeStClaims, uint256 totalStShares) = previewSyncTrancheAccounting(TrancheType.SENIOR);
        stClaims = UtilsLib.scaleAssetClaims(cumulativeStClaims, seniorSharesOut, totalStShares);
    }

    // =============================
    // Liquidity Tranche Liquidity-Venue Hooks (overridden by the concrete venue kernel)
    // =============================

    /// @notice Single-sided/unbalanced add of (senior shares + quote) into the liquidity venue; returns the LT tranche assets (LP token) minted. Overridden by the concrete venue kernel
    function _addLiquidityUnbalanced(uint256, uint256) internal virtual returns (uint256) {
        // TODO: Implemented by the concrete venue kernel
        revert("not implemented");
    }

    /// @notice Proportional removal of the LP token into its (senior shares + quote) constituents. Overridden by the concrete venue kernel
    function _removeLiquidityProportional(uint256, uint256, uint256) internal virtual returns (uint256, uint256) {
        // TODO: Implemented by the concrete venue kernel
        revert("not implemented");
    }

    /// @notice Off-chain query for the single-sided add (non-view, like an AMM router's query functions). Overridden by the concrete venue kernel
    function _queryAddLiquidityUnbalanced(uint256, uint256) internal virtual returns (uint256) {
        // TODO: Implemented by the concrete venue kernel
        revert("not implemented");
    }

    /// @notice Off-chain query for the proportional removal (non-view, like an AMM router's query functions). Overridden by the concrete venue kernel
    function _queryRemoveLiquidityProportional(uint256) internal virtual returns (uint256, uint256) {
        // TODO: Implemented by the concrete venue kernel
        revert("not implemented");
    }

    /**
     * @notice Converts a NAV value to a tranche share count, mirroring `RoycoVaultTranche._convertToShares`
     * @dev Used to compute the fair senior share count to mint when seeding the pool so it matches a tranche-side mint
     * @param _value The NAV value being converted to shares
     * @param _navTotal The tranche's total controlled NAV (the per-share denominator)
     * @param _totalSupply The tranche's total share supply (including any minted protocol fee shares)
     * @return shares The share count for the specified NAV value, rounded down
     */
    function _navToShares(NAV_UNIT _value, NAV_UNIT _navTotal, uint256 _totalSupply) internal pure returns (uint256 shares) {
        if (_totalSupply == 0) return toUint256(_value);
        // When total NAV is zero, mirror the tranche's boundary: treat existing supply as backed by a single NAV unit
        uint256 denom = _navTotal == ZERO_NAV_UNITS ? uint256(1) : toUint256(_navTotal);
        shares = Math.mulDiv(_totalSupply, toUint256(_value), denom, Math.Rounding.Floor);
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
        _getRoycoDayKernelStorage().stSelfLiquidationBonusWAD = _stSelfLiquidationBonusWAD;
        emit SeniorTrancheSelfLiquidationBonusUpdated(_stSelfLiquidationBonusWAD);
    }

    /// @inheritdoc IRoycoDayKernel
    function setRoycoBlacklist(address _roycoBlacklist) external override(IRoycoDayKernel) restricted {
        _getRoycoDayKernelStorage().roycoBlacklist = _roycoBlacklist;
        emit RoycoBlacklistUpdated(_roycoBlacklist);
    }

    // =============================
    // Tranche Compliance Methods
    // =============================

    /**
     * @notice Returns whether the specified account is screened out by the market's blacklist
     * @dev Returns false when no blacklist is configured (the null address disables screening)
     * @param _account The address of the account to check
     * @return Whether the account is blacklisted by the market's configured blacklist
     */
    function _isBlacklisted(address _account) internal view returns (bool) {
        address roycoBlacklist = _getRoycoDayKernelStorage().roycoBlacklist;
        return (roycoBlacklist != address(0) && IRoycoBlacklist(roycoBlacklist).isBlacklisted(_account));
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
        // Batch screen the involved accounts against the market's blacklist if one is configured (the null address disables screening)
        address roycoBlacklist = _getRoycoDayKernelStorage().roycoBlacklist;
        if (roycoBlacklist != address(0)) {
            address[] memory accountsToScreen = new address[](3);
            accountsToScreen[0] = _caller;
            accountsToScreen[1] = _from;
            accountsToScreen[2] = _to;
            IRoycoBlacklist(roycoBlacklist).enforceNotBlacklisted(accountsToScreen);
        }
        // If transferring shares, ensure that the recipient is a whitelisted LP for the tranche
        if (_to != address(0) && ENFORCE_TRANCHE_SHARES_TRANSFER_WHITELIST) {
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

    /**
     * @notice Pre-balance update hook for the kernel
     * @dev Should be overridden by concrete kernel implementations to perform any additional checks or actions
     * @dev The caller is the address that initiated the balance update
     * @param _caller The address that initiated the balance update
     * @param _from The address from which the balance is being updated
     * @param _to The address to which the balance is being updated
     * @param _value The amount of the balance being updated
     */
    function _preTrancheBalanceUpdate(address _caller, address _from, address _to, uint256 _value) internal virtual { }

    // =============================
    // Internal Tranche Accounting Synchronization Functions
    // =============================

    /**
     * @notice Previews an accounting sync via the accountant
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function _previewSyncTrancheAccounting() internal view virtual whenNotPaused returns (SyncedAccountingState memory state) {
        // Preview an accounting sync via the accountant
        state = IRoycoDayAccountant(ACCOUNTANT).previewSyncTrancheAccounting(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV(), _getLiquidityTrancheRawNAV());
    }

    /**
     * @notice Invokes the accountant to do a pre-operation (deposit and withdrawal) NAV sync and mints any protocol fee shares accrued
     * @dev A sync must be executed before every NAV mutating operation (deposit and withdrawal)
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function _preOpSyncTrancheAccounting() internal virtual returns (SyncedAccountingState memory state) {
        // Execute the pre-op sync via the accountant
        state = IRoycoDayAccountant(ACCOUNTANT).preOpSyncTrancheAccounting(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV(), _getLiquidityTrancheRawNAV());

        // Collect any protocol fees accrued
        _collectProtocolFees(state.stProtocolFee, state.jtProtocolFee, state.ltProtocolFee, state.stEffectiveNAV, state.jtEffectiveNAV, state.ltRawNAV);
    }

    /**
     * @notice Invokes the accountant to do a NAV sync and mints any protocol fee shares accrued
     * @dev A sync must be executed before every NAV mutating operation (deposit and withdrawal)
     * @notice Returns the asset claims and total tranche shares after minting any fees for the specified tranche
     * @param _trancheType An enumerator indicating which tranche to return claims and total tranche shares for
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     * @return claims The cumulative asset claims that the specified tranche is entitled to
     * @return totalTrancheShares The total shares outstanding in the specified tranche after minting any protocol fee shares
     */
    function _preOpSyncTrancheAccounting(TrancheType _trancheType)
        internal
        virtual
        returns (SyncedAccountingState memory state, AssetClaims memory claims, uint256 totalTrancheShares)
    {
        // Execute the pre-op sync via the accountant
        state = IRoycoDayAccountant(ACCOUNTANT).preOpSyncTrancheAccounting(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV(), _getLiquidityTrancheRawNAV());

        // Collect any protocol fees accrued from the sync to the fee recipient
        RoycoDayKernelState storage $ = _getRoycoDayKernelStorage();
        address protocolFeeRecipient = $.protocolFeeRecipient;
        uint256 stTotalTrancheSharesAfterMintingFees;
        uint256 jtTotalTrancheSharesAfterMintingFees;
        uint256 ltTotalTrancheSharesAfterMintingFees;
        // If the call needs to get total supply or mint shares for fees accrued for the senior tranche
        if (_trancheType == TrancheType.SENIOR || state.stProtocolFee != ZERO_NAV_UNITS) {
            (, stTotalTrancheSharesAfterMintingFees) =
                IRoycoVaultTranche(SENIOR_TRANCHE).mintProtocolFeeShares(state.stProtocolFee, state.stEffectiveNAV, protocolFeeRecipient);
        }
        // If the call needs to get total supply or mint shares for fees accrued for the junior tranche
        if (_trancheType == TrancheType.JUNIOR || state.jtProtocolFee != ZERO_NAV_UNITS) {
            (, jtTotalTrancheSharesAfterMintingFees) =
                IRoycoVaultTranche(JUNIOR_TRANCHE).mintProtocolFeeShares(state.jtProtocolFee, state.jtEffectiveNAV, protocolFeeRecipient);
        }
        // If the call needs to get total supply or mint shares for fees accrued for the liquidity tranche
        if (_trancheType == TrancheType.LIQUIDITY || state.ltProtocolFee != ZERO_NAV_UNITS) {
            (, ltTotalTrancheSharesAfterMintingFees) =
                IRoycoVaultTranche(LIQUIDITY_TRANCHE).mintProtocolFeeShares(state.ltProtocolFee, state.ltRawNAV, protocolFeeRecipient);
        }

        // Assign the total supply of tranche shares for the specified tranche
        totalTrancheShares =
        (_trancheType == TrancheType.SENIOR
                ? stTotalTrancheSharesAfterMintingFees
                : _trancheType == TrancheType.JUNIOR ? jtTotalTrancheSharesAfterMintingFees : ltTotalTrancheSharesAfterMintingFees);

        // Derive the asset claims for the specified tranche
        claims = _deriveTrancheAssetClaims(_trancheType, state);
    }

    /**
     * @notice Invokes the accountant to do a post-operation (deposit or withdrawal) NAV sync
     * @dev Must be executed after every NAV mutating operation that doesn't require a coverage check (ST redemption and JT deposit)
     * @param _op The operation being executed in between the pre and post synchronizations
     * @param _stSelfLiquidationBonusNAV The NAV of assets from JT effective NAV used as a bonus for ST redemptions (only applicable if _op == ST_REDEEM)
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function _postOpSyncTrancheAccounting(Operation _op, NAV_UNIT _stSelfLiquidationBonusNAV) internal virtual returns (SyncedAccountingState memory state) {
        // Execute the post-op sync on the accountant
        state = IRoycoDayAccountant(ACCOUNTANT)
            .postOpSyncTrancheAccounting(_op, _getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV(), _getLiquidityTrancheRawNAV(), _stSelfLiquidationBonusNAV);
    }

    /**
     * @notice Invokes the accountant to do a post-operation (deposit or withdrawal) NAV sync and enforce that the market's coverage requirement is satisfied after reconciliation
     * @dev Must be executed after every NAV mutating operation that requires a coverage check (ST deposit and JT redemption)
     * @param _op The operation being executed in between the pre and post synchronizations
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function _postOpSyncTrancheAccountingAndEnforceCoverage(Operation _op) internal virtual returns (SyncedAccountingState memory state) {
        // TODO: verify that this also enforces liq util check
        // Execute the post-op sync on the accountant
        state = IRoycoDayAccountant(ACCOUNTANT)
            .postOpSyncTrancheAccountingAndEnforceCoverage(_op, _getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV(), _getLiquidityTrancheRawNAV());
    }

    /**
     * @notice Mints protocol fee shares to the fee recipient based on fees accrued on an accounting sync
     * @dev Shares are minted at the current effective NAV per share ratio, diluting existing holders proportionally
     * @dev Only mints if non-zero fees were accrued
     * @param _stProtocolFee The NAV amount of protocol fees accrued from senior tranche yield
     * @param _jtProtocolFee The NAV amount of protocol fees accrued from junior tranche yield
     * @param _ltProtocolFee The NAV amount of protocol fees accrued from liquidity tranche yield
     * @param _stEffectiveNAV The senior tranche's effective NAV used to calculate shares to mint
     * @param _jtEffectiveNAV The junior tranche's effective NAV used to calculate shares to mint
     * @param _ltEffectiveNAV The liquidity tranche's effective NAV used to calculate shares to mint
     */
    function _collectProtocolFees(
        NAV_UNIT _stProtocolFee,
        NAV_UNIT _jtProtocolFee,
        NAV_UNIT _ltProtocolFee,
        NAV_UNIT _stEffectiveNAV,
        NAV_UNIT _jtEffectiveNAV,
        NAV_UNIT _ltEffectiveNAV
    )
        internal
    {
        if (_stProtocolFee != ZERO_NAV_UNITS || _jtProtocolFee != ZERO_NAV_UNITS || _ltProtocolFee != ZERO_NAV_UNITS) {
            RoycoDayKernelState storage $ = _getRoycoDayKernelStorage();
            address protocolFeeRecipient = $.protocolFeeRecipient;
            // If ST fees were accrued, mint ST protocol fee shares to the protocol fee recipient
            if (_stProtocolFee != ZERO_NAV_UNITS) {
                IRoycoVaultTranche(SENIOR_TRANCHE).mintProtocolFeeShares(_stProtocolFee, _stEffectiveNAV, protocolFeeRecipient);
            }
            // If JT fees were accrued, mint JT protocol fee shares to the protocol fee recipient
            if (_jtProtocolFee != ZERO_NAV_UNITS) {
                IRoycoVaultTranche(JUNIOR_TRANCHE).mintProtocolFeeShares(_jtProtocolFee, _jtEffectiveNAV, protocolFeeRecipient);
            }
            // If LT fees were accrued, mint LT protocol fee shares to the protocol fee recipient
            if (_ltProtocolFee != ZERO_NAV_UNITS) {
                IRoycoVaultTranche(LIQUIDITY_TRANCHE).mintProtocolFeeShares(_ltProtocolFee, _ltEffectiveNAV, protocolFeeRecipient);
            }
        }
    }

    /**
     * @notice Derives the cumulative asset claims that the specified tranche is entitled to
     * @param _trancheType An enumerator indicating which tranche to return cumulative claims for
     * @param _state The synced NAV, impermanent loss, and fee accounting containing all mark to market accounting data
     * @return claims The cumulative asset claims that the specified tranche is entitled to
     */
    function _deriveTrancheAssetClaims(TrancheType _trancheType, SyncedAccountingState memory _state)
        internal
        view
        virtual
        returns (AssetClaims memory claims)
    {
        // Decompose the NAV claims for the tranches based on the synced accounting state
        (NAV_UNIT stClaimOnSTRawNAV, NAV_UNIT stClaimOnJTRawNAV, NAV_UNIT jtClaimOnSTRawNAV, NAV_UNIT jtClaimOnJTRawNAV) =
            UtilsLib.computeTrancheClaimsOnNAVs(_state);

        // Compute the cumulative asset claims for the specified tranche based on the NAV decomposition
        if (_trancheType == TrancheType.SENIOR) {
            if (stClaimOnSTRawNAV != ZERO_NAV_UNITS) claims.stAssets = stConvertNAVUnitsToTrancheUnits(stClaimOnSTRawNAV);
            if (stClaimOnJTRawNAV != ZERO_NAV_UNITS) claims.jtAssets = jtConvertNAVUnitsToTrancheUnits(stClaimOnJTRawNAV);
            // ST's Claim on LT NAV is always zero
            claims.ltAssets = ZERO_TRANCHE_UNITS;
            claims.nav = _state.stEffectiveNAV;
        } else if (_trancheType == TrancheType.JUNIOR) {
            if (jtClaimOnSTRawNAV != ZERO_NAV_UNITS) {
                claims.stAssets = stConvertNAVUnitsToTrancheUnits(jtClaimOnSTRawNAV);
            }
            if (jtClaimOnJTRawNAV != ZERO_NAV_UNITS) claims.jtAssets = jtConvertNAVUnitsToTrancheUnits(jtClaimOnJTRawNAV);
            // JT's Claim on LT NAV is always zero
            claims.ltAssets = ZERO_TRANCHE_UNITS;
            claims.nav = _state.jtEffectiveNAV;
        } else {
            // LT's claim on its own raw NAV is simply the full LT raw NAV
            if (_state.ltRawNAV != ZERO_NAV_UNITS) claims.ltAssets = ltConvertNAVUnitsToTrancheUnits(_state.ltRawNAV);
            // LT's Claim on ST and JT NAV is always zero
            claims.stAssets = ZERO_TRANCHE_UNITS;
            claims.jtAssets = ZERO_TRANCHE_UNITS;
            claims.nav = _state.ltRawNAV;
        }
    }

    // =============================
    // Internal Utility Functions
    // =============================

    /**
     * @notice Returns the raw net asset value of the senior tranche denominated in the NAV units (USD, BTC, etc.) for this kernel
     * @return stRawNAV The pure net asset value of the senior tranche invested assets
     */
    function _getSeniorTrancheRawNAV() internal view virtual returns (NAV_UNIT stRawNAV) {
        // Get the yield bearing assets owned by ST and convert them to NAV units via the configured quoter
        return stConvertTrancheUnitsToNAVUnits(_getRoycoDayKernelStorage().stOwnedYieldBearingAssets);
    }

    /**
     * @notice Returns the raw net asset value of the junior tranche denominated in the NAV units (USD, BTC, etc.) for this kernel
     * @return jtRawNAV The pure net asset value of the junior tranche invested assets
     */
    function _getJuniorTrancheRawNAV() internal view virtual returns (NAV_UNIT jtRawNAV) {
        // Get the yield bearing assets owned by JT and convert them to NAV units via the configured quoter
        return jtConvertTrancheUnitsToNAVUnits(_getRoycoDayKernelStorage().jtOwnedYieldBearingAssets);
    }

    /**
     * @notice Returns the raw net asset value of the liquidity tranche denominated in the NAV units (USD, BTC, etc.) for this kernel
     * @return ltRawNAV The pure net asset value of the liquidity tranche invested assets
     */
    function _getLiquidityTrancheRawNAV() internal view virtual returns (NAV_UNIT ltRawNAV) {
        // Get the yield bearing assets owned by LT and convert them to NAV units via the configured quoter
        return ltConvertTrancheUnitsToNAVUnits(_getRoycoDayKernelStorage().ltOwnedYieldBearingAssets);
    }

    /**
     * @notice Process a deposit of senior tranche assets
     * @dev The ST vault has already transferred the assets to the kernel
     * @param _stAssets The senior tranche assets deposited by the ST LP
     */
    function _stDepositAssets(TRANCHE_UNIT _stAssets) internal virtual {
        // Credit the deposited assets to the senior tranche
        RoycoDayKernelState storage $ = _getRoycoDayKernelStorage();
        $.stOwnedYieldBearingAssets = $.stOwnedYieldBearingAssets + _stAssets;
    }

    /**
     * @notice Process a deposit of junior tranche assets
     * @dev The JT vault has already transferred the assets to the kernel
     * @param _jtAssets The junior tranche assets deposited by the JT LP
     */
    function _jtDepositAssets(TRANCHE_UNIT _jtAssets) internal virtual {
        // Credit the deposited assets to the junior tranche
        RoycoDayKernelState storage $ = _getRoycoDayKernelStorage();
        $.jtOwnedYieldBearingAssets = $.jtOwnedYieldBearingAssets + _jtAssets;
    }

    /**
     * @notice Process a deposit of liquidity tranche assets
     * @dev The LT vault has already transferred the assets to the kernel
     * @param _ltAssets The liquidity tranche assets deposited by the LT LP
     */
    function _ltDepositAssets(TRANCHE_UNIT _ltAssets) internal virtual {
        // Credit the deposited assets to the liquidity tranche
        RoycoDayKernelState storage $ = _getRoycoDayKernelStorage();
        $.ltOwnedYieldBearingAssets = $.ltOwnedYieldBearingAssets + _ltAssets;
    }

    /**
     * @notice Withdraws any specified assets from each tranche and transfer them to the receiver
     * @param _claims The ST and JT assets to withdraw and transfer to the specified receiver
     * @param _receiver The receiver of the tranche asset claims
     */
    function _withdrawAssets(AssetClaims memory _claims, address _receiver) internal virtual {
        // Cache the individual claims
        TRANCHE_UNIT stAssetsToClaim = _claims.stAssets;
        TRANCHE_UNIT jtAssetsToClaim = _claims.jtAssets;
        TRANCHE_UNIT ltAssetsToClaim = _claims.ltAssets;

        // Debit the ST, JT, and LT assets being withdrawn from each tranche if non-zero
        RoycoDayKernelState storage $ = _getRoycoDayKernelStorage();
        if (stAssetsToClaim != ZERO_TRANCHE_UNITS) $.stOwnedYieldBearingAssets = $.stOwnedYieldBearingAssets - stAssetsToClaim;
        if (jtAssetsToClaim != ZERO_TRANCHE_UNITS) $.jtOwnedYieldBearingAssets = $.jtOwnedYieldBearingAssets - jtAssetsToClaim;
        if (ltAssetsToClaim != ZERO_TRANCHE_UNITS) $.ltOwnedYieldBearingAssets = $.ltOwnedYieldBearingAssets - ltAssetsToClaim;

        // Credit the yield bearing assets being withdrawn to the receiver
        if (stAssetsToClaim + jtAssetsToClaim != ZERO_TRANCHE_UNITS) {
            // Do one batch transfer if they are the same asset, else do two separate transfers
            if (ST_ASSET == JT_ASSET) {
                IERC20(ST_ASSET).safeTransfer(_receiver, toUint256(stAssetsToClaim + jtAssetsToClaim));
            } else {
                if (stAssetsToClaim != ZERO_TRANCHE_UNITS) IERC20(ST_ASSET).safeTransfer(_receiver, toUint256(stAssetsToClaim));
                if (jtAssetsToClaim != ZERO_TRANCHE_UNITS) IERC20(JT_ASSET).safeTransfer(_receiver, toUint256(jtAssetsToClaim));
            }
        }

        // Credit the liquidity assets being withdrawn to the receiver
        if (ltAssetsToClaim != ZERO_TRANCHE_UNITS) IERC20(LT_ASSET).safeTransfer(_receiver, toUint256(ltAssetsToClaim));
    }

    /**
     * @notice Computes and applies the self-liquidation bonus for ST redemptions when the liquidation coverageUtilization threshold is breached, sourced from JT asset claims
     * @dev The bonus incentivizes ST to self-liquidate by redeeming to delever the market
     * @dev After exiting the market, the bonus affords ST LPs the ability to:
     *      1. Absorb discounts/losses on secondary markets when liquidating the withdrawn exposure
     *      2. Absorb any duration risk associated with liquidating the withdrawn exposure
     * @dev The bonus is computed on the NAV being redeemed by the senior tranche
     * @dev The bonus is capped to ensure coverageUtilization does not increase, preventing bank run dynamics where one LP's bonus eats into coverage for remaining LPs
     * @param _state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     * @param _stUserClaims The claims of the redeeming ST user
     * @return stUserClaimsWithBonus The claims of the redeeming ST user after applying the self-liquidation bonus
     * @return stSelfLiquidationBonusNAV Bonus sourced from JT's claims on ST and JT assets
     */
    function _applySeniorTrancheSelfLiquidationBonus(
        SyncedAccountingState memory _state,
        AssetClaims memory _stUserClaims
    )
        internal
        view
        virtual
        returns (AssetClaims memory stUserClaimsWithBonus, NAV_UNIT stSelfLiquidationBonusNAV)
    {
        // If the liquidation coverageUtilization threshold has not been breached, there is no ST self-liquidation bonus remitted
        if (_state.coverageUtilizationWAD < _state.liquidationCoverageUtilizationWAD) return (_stUserClaims, ZERO_NAV_UNITS);

        // Compute the desired ST bonus based on the configured ST self-liquidation bonus rate
        NAV_UNIT desiredBonusNAV = _stUserClaims.nav.mulDiv(_getRoycoDayKernelStorage().stSelfLiquidationBonusWAD, WAD, Math.Rounding.Floor);

        // Decompose the NAV claims for the Junior Tranche to get the NAV claims for sourcing the bonus
        (,, NAV_UNIT jtClaimOnSTRawNAV,) = UtilsLib.computeTrancheClaimsOnNAVs(_state);

        // Compute the maximum bonus that doesn't increase coverageUtilization, preventing bank run dynamics
        NAV_UNIT maxCoverageUtilizationNeutralBonusNAV = _computeMaxCoverageUtilizationNeutralBonus(_state, _stUserClaims, jtClaimOnSTRawNAV);

        // Clamp the actual bonus by the remaining JT controlled NAV and the maximum coverageUtilization-neutral (leverage retaining or delevering) NAV
        stSelfLiquidationBonusNAV = UnitsMathLib.min(UnitsMathLib.min(desiredBonusNAV, _state.jtEffectiveNAV), maxCoverageUtilizationNeutralBonusNAV);

        // Preemptively return if there is no remaining bonus capital to remit
        if (stSelfLiquidationBonusNAV == ZERO_NAV_UNITS) return (_stUserClaims, ZERO_NAV_UNITS);

        // Compute the bonus NAV sourced from JT's claims on each tranche's NAV: prioritize ST assets over JT assets for sourcing
        // stSelfLiquidationBonusNAV <= (jtClaimOnSTRawNAV + jtClaimOnSelfRawNAV) since it was bounded by JT effective NAV already
        NAV_UNIT bonusFromJTClaimOnSTRawNAV = UnitsMathLib.min(stSelfLiquidationBonusNAV, jtClaimOnSTRawNAV);
        NAV_UNIT bonusFromJTClaimOnSelfRawNAV = (stSelfLiquidationBonusNAV - bonusFromJTClaimOnSTRawNAV);

        // Apply the derived bonus to the user's asset claims
        stUserClaimsWithBonus.stAssets = _stUserClaims.stAssets + stConvertNAVUnitsToTrancheUnits(bonusFromJTClaimOnSTRawNAV);
        stUserClaimsWithBonus.jtAssets = _stUserClaims.jtAssets + jtConvertNAVUnitsToTrancheUnits(bonusFromJTClaimOnSelfRawNAV);
        stUserClaimsWithBonus.nav = _stUserClaims.nav + stSelfLiquidationBonusNAV;
    }

    /**
     * @notice Computes the maximum self-liquidation bonus that doesn't increase coverageUtilization (market's leverage)
     * @dev Prevents bank run dynamics by ensuring one LP's bonus doesn't reduce coverage for remaining LPs
     * @dev Derivation:
     *      Post-redemption coverageUtilization must not exceed original coverageUtilization:
     *      U = Current coverageUtilization = ((ST_RAW_NAV + (JT_RAW_NAV * β)) * MIN_COVERAGE) / JT_EFFECTIVE_NAV
     *      U' = Post-redemption coverageUtilization (including bonus)
     *      Post-redemption coverageUtilization:
     *      U' = (((ST_RAW_NAV - ST_REDEMPTION_ST_RAW_NAV - BONUS_ST_RAW_NAV) + ((JT_RAW_NAV - ST_REDEMPTION_JT_RAW_NAV - BONUS_JT_RAW_NAV) * β)) * MIN_COVERAGE) / (JT_EFFECTIVE_NAV - BONUS_ST_RAW_NAV - BONUS_JT_RAW_NAV)
     *
     *      NOTE: INVARIANT: U' <= U
     *      Resulting invariant after simplification:
     *      COVERED_EXPOSURE = ST_RAW_NAV + JT_RAW_NAV * β
     *      BONUS_ST_RAW_NAV * (COVERED_EXPOSURE - JT_EFFECTIVE_NAV) + BONUS_JT_RAW_NAV * (COVERED_EXPOSURE - β * JT_EFFECTIVE_NAV) <= JT_EFFECTIVE_NAV * (ST_REDEMPTION_ST_RAW_NAV + ST_REDEMPTION_JT_RAW_NAV * β)
     *
     *      Since with β < 1 BONUS_ST_RAW_NAV is cheaper per unit, use the ST_RAW_NAV to source the bonus first:
     *      First Priority (BONUS_JT_RAW_NAV = 0):
     *          BONUS_MAX = (ST_REDEMPTION_ST_RAW_NAV + ST_REDEMPTION_JT_RAW_NAV * β) * JT_EFFECTIVE_NAV / (COVERED_EXPOSURE - JT_EFFECTIVE_NAV)
     *
     *      Second Priority (BONUS_ST_RAW_NAV = JT_CLAIM_ON_ST_RAW_NAV, maxed out):
     *          BONUS_MAX = (ST_REDEMPTION_ST_RAW_NAV + ST_REDEMPTION_JT_RAW_NAV * β + JT_CLAIM_ON_ST_RAW_NAV * (1 - β)) * JT_EFFECTIVE_NAV / (COVERED_EXPOSURE - β * JT_EFFECTIVE_NAV)
     *
     * @param _state The synced accounting state
     * @param _stUserClaims The ST user's base claims before bonus
     * @param _jtClaimOnSTRawNAV JT's cross-tranche claim on ST assets
     * @return maxCoverageUtilizationNeutralBonusNAV The maximum bonus NAV that maintains coverageUtilization neutrality
     */
    function _computeMaxCoverageUtilizationNeutralBonus(
        SyncedAccountingState memory _state,
        AssetClaims memory _stUserClaims,
        NAV_UNIT _jtClaimOnSTRawNAV
    )
        internal
        view
        returns (NAV_UNIT maxCoverageUtilizationNeutralBonusNAV)
    {
        // Preemptively return if there is no remaining capital to source a bonus from
        NAV_UNIT jtEffectiveNAV = _state.jtEffectiveNAV;
        if (jtEffectiveNAV == ZERO_NAV_UNITS) return ZERO_NAV_UNITS;

        // Compute the total covered exposure of the market, rounding up to be conservative
        NAV_UNIT totalCoveredExposure = _state.stRawNAV + _state.jtRawNAV.mulDiv(_state.betaWAD, WAD, Math.Rounding.Ceil);

        // Compute the ST LP's NAV claim on real exposure (with beta factored in)
        NAV_UNIT stUserWeightedClaimNAV = stConvertTrancheUnitsToNAVUnits(_stUserClaims.stAssets)
            + jtConvertTrancheUnitsToNAVUnits(_stUserClaims.jtAssets).mulDiv(_state.betaWAD, WAD, Math.Rounding.Floor);
        // If the weighted claim is zero, there is no bonus to apply
        if (stUserWeightedClaimNAV == ZERO_NAV_UNITS) return ZERO_NAV_UNITS;

        // Case 1: Bonus sourced entirely from JT's claim on ST assets
        // maxBonus = stUserWeightedClaimNAV * jtEffectiveNAV / (totalCoveredExposure - jtEffectiveNAV)
        NAV_UNIT stAssetSourcedMaxBonusNAV = stUserWeightedClaimNAV.mulDiv(jtEffectiveNAV, (totalCoveredExposure - jtEffectiveNAV), Math.Rounding.Floor);
        if (stAssetSourcedMaxBonusNAV <= _jtClaimOnSTRawNAV) return stAssetSourcedMaxBonusNAV;

        // Case 2: Bonus sourced from both JT's claim on ST assets and JT's claim on JT assets
        // maxBonus = (stUserWeightedClaimNAV + jtClaimOnSTRawNAV * (1 - β)) * jtEffectiveNAV / (totalCoveredExposure - β * jtEffectiveNAV)
        NAV_UNIT weightedClaimWithSTSourceAdjustmentNAV = stUserWeightedClaimNAV + _jtClaimOnSTRawNAV.mulDiv((WAD - _state.betaWAD), WAD, Math.Rounding.Floor);
        return weightedClaimWithSTSourceAdjustmentNAV.mulDiv(
            jtEffectiveNAV, (totalCoveredExposure - jtEffectiveNAV.mulDiv(_state.betaWAD, WAD, Math.Rounding.Floor)), Math.Rounding.Floor
        );
    }

    // =============================
    // Internal Quoter Cache Functions
    // =============================

    /**
     * @notice Initializes the quoter
     * @dev Should be called at the start of a call
     * @dev Typically used to initialize the cached tranche unit to NAV unit conversion rate
     */
    function _initializeQuoterCache() internal virtual;

    /**
     * @notice Clears the quoter cache
     * @dev Should be called at the end of a call
     * @dev Typically used to clear the cached tranche unit to NAV unit conversion rate
     */
    function _clearQuoterCache() internal virtual;

    // =============================
    // Kernel State Accessor Functions
    // =============================

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
