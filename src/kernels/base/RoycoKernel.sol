// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from "../../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import { RoycoBase } from "../../base/RoycoBase.sol";
import { IRoycoAccountant } from "../../interfaces/IRoycoAccountant.sol";
import { IRoycoKernel } from "../../interfaces/kernel/IRoycoKernel.sol";
import { IRoycoVaultTranche } from "../../interfaces/tranche/IRoycoVaultTranche.sol";
import { MAX_TRANCHE_UNITS, WAD, WAD_DECIMALS, ZERO_BASE_UNITS, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../../libraries/Constants.sol";
import { AssetClaims, MarketState, Operation, SyncedAccountingState, TrancheType } from "../../libraries/Types.sol";
import { BASE_UNIT, Math, NAV_UNIT, TRANCHE_UNIT, UnitsMathLib, toBaseUnits, toNAVUnits, toUint256 } from "../../libraries/Units.sol";
import { UtilsLib } from "../../libraries/UtilsLib.sol";

/**
 * @title RoycoKernel
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Abstract contract serving as the base for all Royco kernel implementations
 * @dev Provides the foundational logic for kernel contracts including pre and post operation NAV reconciliation, coverage enforcement logic,
 *      and base wiring for tranche synchronization. All concrete kernel implementations should inherit from the Royco Kernel.
 */
abstract contract RoycoKernel is IRoycoKernel, RoycoBase, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using UnitsMathLib for NAV_UNIT;
    using UnitsMathLib for TRANCHE_UNIT;

    /// @dev Storage slot for RoycoKernelState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoKernelState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BASE_KERNEL_STORAGE_SLOT = 0xf8fc0d016168fef0a165a086b5a5dc3ffa533689ceaf1369717758ae5224c600;

    /// @dev The base asset used for liquidation settlements, with 1:1 value parity with NAV units but may differ in precision
    /// @dev Constitutes the BASE_UNIT for this market
    address public immutable BASE_ASSET;
    /// @dev The scale factor used to scale base asset quantities to/from NAV unit precision (WAD decimals)
    uint256 internal immutable BASE_UNIT_SCALE_FACTOR_TO_WAD;

    /// @dev Immutable addresses for the senior tranche, ST asset, junior tranche, and JT asset
    address public immutable SENIOR_TRANCHE;
    address public immutable ST_ASSET;
    address public immutable JUNIOR_TRANCHE;
    address public immutable JT_ASSET;

    /// @dev The accountant responsible for maintaining all accounting state and marking tranche NAVs to market
    IRoycoAccountant public immutable ACCOUNTANT;

    /// @dev Permissions the function to only the market's senior tranche
    /// @dev Should be placed on all ST deposit and redeem functions
    // forge-lint: disable-next-item(unwrapped-modifier-logic)
    modifier onlySeniorTranche() {
        require(msg.sender == SENIOR_TRANCHE, ONLY_SENIOR_TRANCHE());
        _;
    }

    /// @dev Permissions the function to only the market's junior tranche
    /// @dev Should be placed on all JT deposit and redeem functions
    // forge-lint: disable-next-item(unwrapped-modifier-logic)
    modifier onlyJuniorTranche() {
        require(msg.sender == JUNIOR_TRANCHE, ONLY_JUNIOR_TRANCHE());
        _;
    }

    /// @dev Modifier to initialize and clear the quoter cache
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
    constructor(RoycoKernelConstructionParams memory _params) {
        // Ensure that the tranche addresses are not null
        require(
            _params.seniorTranche != address(0) && _params.stAsset != address(0) && _params.juniorTranche != address(0) && _params.jtAsset != address(0)
                && _params.accountant != address(0),
            NULL_ADDRESS()
        );

        // Compute the scaling factor that will scale base asset quantities to and from WAD precision
        // Base asset can be set to the null address if liquidations are not supported for this market
        uint8 baseAssetDecimals = _params.baseAsset != address(0) ? IERC20Metadata(_params.baseAsset).decimals() : 0;
        require(baseAssetDecimals <= WAD_DECIMALS, UNSUPPORTED_DECIMALS());
        BASE_ASSET = _params.baseAsset;
        BASE_UNIT_SCALE_FACTOR_TO_WAD = 10 ** (WAD_DECIMALS - baseAssetDecimals);

        // Set the immutable addresses
        SENIOR_TRANCHE = _params.seniorTranche;
        ST_ASSET = _params.stAsset;
        JUNIOR_TRANCHE = _params.juniorTranche;
        JT_ASSET = _params.jtAsset;
        ACCOUNTANT = IRoycoAccountant(_params.accountant);
    }

    /**
     * @notice Initializes the base Royco kernel state
     * @dev Initializes any parent contracts and the base kernel state
     * @param _params The standard initialization parameters for the Royco kernel
     */
    function __RoycoKernel_init(RoycoKernelInitParams memory _params) internal onlyInitializing {
        // Ensure that the tranches and their corresponding assets in the kernel match
        require(
            IRoycoVaultTranche(SENIOR_TRANCHE).asset() == ST_ASSET && IRoycoVaultTranche(JUNIOR_TRANCHE).asset() == JT_ASSET,
            TRANCHE_AND_KERNEL_ASSETS_MISMATCH()
        );
        // Ensure that the initial authority and protocol fee recipient are not null
        require(_params.initialAuthority != address(0) && _params.protocolFeeRecipient != address(0), NULL_ADDRESS());

        // Initialize the Royco kernel state
        __RoycoBase_init(_params.initialAuthority);
        _getRoycoKernelStorage().protocolFeeRecipient = _params.protocolFeeRecipient;

        emit ProtocolFeeRecipientUpdated(_params.protocolFeeRecipient);
    }

    // =============================
    // State Accessor Function
    // =============================

    /// @inheritdoc IRoycoKernel
    function getState() external view override(IRoycoKernel) returns (RoycoKernelState memory $) {
        return _getRoycoKernelStorage();
    }

    // =============================
    // Base Asset Quoter Functions
    // =============================

    function convertBaseUnitsToNAVUnits(BASE_UNIT _baseAssets) public view virtual override(IRoycoKernel) returns (NAV_UNIT) {
        return toNAVUnits(toUint256(_baseAssets) * BASE_UNIT_SCALE_FACTOR_TO_WAD);
    }

    function convertNAVUnitsToBaseUnits(NAV_UNIT _nav) public view virtual override(IRoycoKernel) returns (BASE_UNIT) {
        return toBaseUnits(toUint256(_nav) / BASE_UNIT_SCALE_FACTOR_TO_WAD);
    }

    // =============================
    // Tranche Asset Quoter Functions
    // =============================

    /// @inheritdoc IRoycoKernel
    function stConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _stAssets) public view virtual override(IRoycoKernel) returns (NAV_UNIT);

    /// @inheritdoc IRoycoKernel
    function jtConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _jtAssets) public view virtual override(IRoycoKernel) returns (NAV_UNIT);

    /// @inheritdoc IRoycoKernel
    function stConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) public view virtual override(IRoycoKernel) returns (TRANCHE_UNIT);

    /// @inheritdoc IRoycoKernel
    function jtConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) public view virtual override(IRoycoKernel) returns (TRANCHE_UNIT);

    // =============================
    // Senior and Junior Tranche Max Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoKernel
    /// @dev ST deposits are allowed if the market is in a PERPETUAL or FIXED_TERM state, granted that the market's coverage requirement is satisfied post-deposit
    function stMaxDeposit(address _receiver) public view virtual override(IRoycoKernel) returns (TRANCHE_UNIT) {
        // If ST IL exists, ST deposits are disabled to preclude existing ST's from getting diluted and realizing losses
        if (_previewSyncTrancheAccounting().stImpermanentLoss != ZERO_NAV_UNITS) return ZERO_TRANCHE_UNITS;
        // ST deposits are enabled as long as ST IL is nonexistant and coverage is satisfied
        // No need to include ST liquidation proceeds in the raw NAV because those assets are not exposed to any volatility
        NAV_UNIT stMaxDepositableNAV = ACCOUNTANT.maxSTDepositGivenCoverage(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV(), _getLiquidationProceedsNAV());
        return stConvertNAVUnitsToTrancheUnits(stMaxDepositableNAV);
    }

    /// @inheritdoc IRoycoKernel
    /// @dev ST redemptions are allowed in PERPETUAL market states
    function stMaxWithdrawable(address _owner)
        public
        view
        virtual
        override(IRoycoKernel)
        returns (
            NAV_UNIT claimOnStNAV,
            NAV_UNIT claimOnJtNAV,
            NAV_UNIT stMaxWithdrawableNAV,
            NAV_UNIT jtMaxWithdrawableNAV,
            uint256 totalTrancheSharesAfterMintingFees
        )
    {
        SyncedAccountingState memory state;
        AssetClaims memory stNotionalClaims;
        (state, stNotionalClaims, totalTrancheSharesAfterMintingFees) = previewSyncTrancheAccounting(TrancheType.SENIOR);

        // If the market is in a state where ST withdrawals are not allowed, return zero claims
        if (state.marketState != MarketState.PERPETUAL) {
            return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);
        }

        // Get the total claims the senior tranche has on each tranche's assets
        claimOnStNAV = stConvertTrancheUnitsToNAVUnits(stNotionalClaims.stAssets);
        claimOnJtNAV = jtConvertTrancheUnitsToNAVUnits(stNotionalClaims.jtAssets);

        // Bound the claims by the max withdrawable assets globally for each tranche and compute the cumulative NAV
        stMaxWithdrawableNAV = _getSeniorTrancheRawNAV();
        jtMaxWithdrawableNAV = _getJuniorTrancheRawNAV();
    }

    /// @inheritdoc IRoycoKernel
    /// @dev JT deposits are allowed if the market is in a PERPETUAL state
    function jtMaxDeposit(address _receiver) public view virtual override(IRoycoKernel) returns (TRANCHE_UNIT) {
        // If the market is in a state where JT deposits are not allowed, return zero tranche units
        if ((_previewSyncTrancheAccounting()).marketState != MarketState.PERPETUAL) return ZERO_TRANCHE_UNITS;
        return MAX_TRANCHE_UNITS;
    }

    /// @inheritdoc IRoycoKernel
    /// @dev JT redemptions are allowed if the market is in a PERPETUAL or FIXED_TERM state, granted that the market's coverage requirement is satisfied post-redemption
    function jtMaxWithdrawable(address _owner)
        public
        view
        virtual
        override(IRoycoKernel)
        returns (
            NAV_UNIT claimOnStNAV,
            NAV_UNIT claimOnJtNAV,
            NAV_UNIT stMaxWithdrawableNAV,
            NAV_UNIT jtMaxWithdrawableNAV,
            uint256 totalTrancheSharesAfterMintingFees
        )
    {
        // Get the total claims the junior tranche has on each tranche's assets
        SyncedAccountingState memory state;
        AssetClaims memory jtNotionalClaims;
        (state, jtNotionalClaims, totalTrancheSharesAfterMintingFees) = previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Get the max withdrawable ST and JT assets in NAV units from the accountant consider coverage requirement
        (, NAV_UNIT stClaimableGivenCoverage, NAV_UNIT jtClaimableGivenCoverage) = ACCOUNTANT.maxJTWithdrawalGivenCoverage(
            state.stRawNAV,
            state.jtRawNAV,
            state.liquidationProceedsNAV,
            stConvertTrancheUnitsToNAVUnits(jtNotionalClaims.stAssets),
            jtConvertTrancheUnitsToNAVUnits(jtNotionalClaims.jtAssets)
        );

        claimOnStNAV = stConvertTrancheUnitsToNAVUnits(jtNotionalClaims.stAssets);
        claimOnJtNAV = jtConvertTrancheUnitsToNAVUnits(jtNotionalClaims.jtAssets);

        // Bound the claims by the max withdrawable assets globally for each tranche and compute the cumulative NAV
        stMaxWithdrawableNAV = stClaimableGivenCoverage;
        jtMaxWithdrawableNAV = jtClaimableGivenCoverage;
    }

    // =============================
    // External Tranche Accounting and Synchronization Functions
    // =============================

    /// @inheritdoc IRoycoKernel
    function syncTrancheAccounting()
        public
        virtual
        override(IRoycoKernel)
        whenNotPaused
        restricted
        nonReentrant
        withQuoterCache
        returns (SyncedAccountingState memory state)
    {
        // Execute a NAV accounting sync via the accountant
        return _syncTrancheAccounting();
    }

    /// @inheritdoc IRoycoKernel
    function previewSyncTrancheAccounting(TrancheType _trancheType)
        public
        view
        virtual
        override(IRoycoKernel)
        returns (SyncedAccountingState memory state, AssetClaims memory claims, uint256 totalTrancheShares)
    {
        // Preview an accounting sync via the accountant
        state = _previewSyncTrancheAccounting();

        // Marshal the asset claims
        (AssetClaims memory stClaims, AssetClaims memory jtClaims) = _marshalTrancheAssetClaims(state);

        // Return the requested tranche claims and total shares
        if (_trancheType == TrancheType.SENIOR) {
            claims = stClaims;
            (, totalTrancheShares) = IRoycoVaultTranche(SENIOR_TRANCHE).previewMintProtocolFeeShares(state.stProtocolFeeAccrued, state.stEffectiveNAV);
        } else {
            claims = jtClaims;
            (, totalTrancheShares) = IRoycoVaultTranche(JUNIOR_TRANCHE).previewMintProtocolFeeShares(state.jtProtocolFeeAccrued, state.jtEffectiveNAV);
        }
    }

    // =============================
    // Senior Tranche Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoKernel
    /// @dev ST deposits are allowed if the market is in a PERPETUAL or FIXED_TERM state, granted that the market's coverage requirement is satisfied post-deposit
    function stDeposit(
        TRANCHE_UNIT _assets,
        address,
        address
    )
        external
        virtual
        override(IRoycoKernel)
        whenNotPaused
        onlySeniorTranche
        nonReentrant
        withQuoterCache
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt)
    {
        // Execute an accounting sync to reconcile underlying PNL
        SyncedAccountingState memory state = _syncTrancheAccounting();
        // If ST IL exists, ST deposits are disabled to preclude existing ST's from getting diluted and realizing losses
        require(state.stImpermanentLoss == ZERO_NAV_UNITS, ST_DEPOSIT_DISABLED_IN_LOSS());

        // The tranche vault has already transfered the assets to the kernel, so simply credit those assets to the senior tranche
        RoycoKernelState storage $ = _getRoycoKernelStorage();
        $.stOwnedYieldBearingAssets = $.stOwnedYieldBearingAssets + _assets;

        // Execute a post-deposit sync on accounting and enforce the market's coverage requirement
        NAV_UNIT stPostDepositNAV = (_postOpSyncTrancheAccountingAndEnforceCoverage(Operation.ST_DEPOSIT, ZERO_NAV_UNITS)).stEffectiveNAV;

        // The NAV to mint tranche shares at is the pre-deposit senior tranche controlled NAV
        navToMintSharesAt = state.stEffectiveNAV;
        // The precise value allocated is the delta between the pre and post deposit NAVs
        valueAllocated = (stPostDepositNAV - navToMintSharesAt);
    }

    /// @inheritdoc IRoycoKernel
    /// @dev ST redemptions are allowed if the market is in a PERPETUAL state
    function stRedeem(
        uint256 _shares,
        address,
        address,
        address _receiver
    )
        external
        virtual
        override(IRoycoKernel)
        whenNotPaused
        onlySeniorTranche
        nonReentrant
        withQuoterCache
        returns (AssetClaims memory userAssetClaims)
    {
        AssetClaims memory trancheAssetClaims;
        uint256 totalTrancheShares;
        {
            // Execute an accounting sync to reconcile underlying PNL
            SyncedAccountingState memory state;
            (state, trancheAssetClaims, totalTrancheShares) = _syncTrancheAccounting(TrancheType.SENIOR);
            // Ensure that the market is in a state where ST redemptions are allowed: PERPETUAL
            require(state.marketState == MarketState.PERPETUAL, ST_REDEEM_DISABLED_IN_FIXED_TERM_STATE());
        }

        // Compute user's claims with FCFS LP prioritization
        userAssetClaims = _previewRedeem(trancheAssetClaims, _shares, totalTrancheShares);

        // Withdraw the asset claims from each tranche and transfer them to the receiver
        _withdrawAssets(userAssetClaims, _receiver);

        // Execute a post-redeem sync on accounting
        // TODO: Add ST redemption bonus if LLTV is breached
        _postOpSyncTrancheAccounting(Operation.ST_REDEEM, ZERO_NAV_UNITS);
    }

    // =============================
    // Junior Tranche Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoKernel
    /// @dev JT deposits are allowed if the market is in a PERPETUAL state
    function jtDeposit(
        TRANCHE_UNIT _assets,
        address,
        address
    )
        external
        virtual
        override(IRoycoKernel)
        whenNotPaused
        onlyJuniorTranche
        nonReentrant
        withQuoterCache
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt)
    {
        // Execute an accounting sync to reconcile underlying PNL
        SyncedAccountingState memory state = _syncTrancheAccounting();
        // Ensure that the market is in a state where JT deposits are allowed: PERPETUAL
        require(state.marketState == MarketState.PERPETUAL, JT_DEPOSIT_DISABLED_IN_FIXED_TERM_STATE());

        // The tranche vault has already transfered the assets to the kernel, so simply credit those assets to the junior tranche
        RoycoKernelState storage $ = _getRoycoKernelStorage();
        $.jtOwnedYieldBearingAssets = $.jtOwnedYieldBearingAssets + _assets;

        // Execute a post-deposit sync on accounting and enforce the market's coverage requirement
        NAV_UNIT jtPostDepositNAV = (_postOpSyncTrancheAccounting(Operation.JT_DEPOSIT, ZERO_NAV_UNITS)).jtEffectiveNAV;

        // The NAV to mint tranche shares at is the pre-deposit junior tranche controlled NAV
        navToMintSharesAt = state.jtEffectiveNAV;
        // The precise value allocated is the delta between the pre and post deposit NAVs
        valueAllocated = (jtPostDepositNAV - navToMintSharesAt);
    }

    /// @inheritdoc IRoycoKernel
    /// @dev JT redemptions are allowed if the market is in a PERPETUAL or FIXED_TERM state, granted that the market's coverage requirement is satisfied post-redemption
    function jtRedeem(
        uint256 _shares,
        address,
        address,
        address _receiver
    )
        external
        virtual
        override(IRoycoKernel)
        whenNotPaused
        onlyJuniorTranche
        nonReentrant
        withQuoterCache
        returns (AssetClaims memory userAssetClaims)
    {
        // Execute a pre-op sync on accounting
        AssetClaims memory trancheAssetClaims;
        uint256 totalTrancheShares;
        (, trancheAssetClaims, totalTrancheShares) = _syncTrancheAccounting(TrancheType.JUNIOR);

        // Compute user's claims with FCFS LP prioritization
        userAssetClaims = _previewRedeem(trancheAssetClaims, _shares, totalTrancheShares);

        // Withdraw the asset claims from each tranche and transfer them to the receiver
        _withdrawAssets(userAssetClaims, _receiver);

        // Execute a post-redeem sync on accounting and enforce the market's coverage requirement
        _postOpSyncTrancheAccountingAndEnforceCoverage(Operation.JT_REDEEM, ZERO_NAV_UNITS);
    }

    // =============================
    // Liquidation Facility Functions
    // =============================

    /**
     * @notice Returns the senior tranche's claims on ST and JT assets available for liquidation
     * @return stAssets The senior tranche's claim on ST assets available for liquidation
     * @return jtAssets The senior tranche's claim on JT assets available for liquidation
     */
    function getLiquidatableAssets() public view virtual returns (TRANCHE_UNIT stAssets, TRANCHE_UNIT jtAssets);

    /**
     * @notice Executes a flash liquidation of the senior tranche's underwater position
     * @param _stAssetsToLiquidate The amount of ST assets the liquidator wants to seize
     * @param _jtAssetsToLiquidate The amount of JT assets the liquidator wants to seize
     * @param _liquidationCallbackData Arbitrary data passed to the liquidator's callback function
     */
    function liquidate(TRANCHE_UNIT _stAssetsToLiquidate, TRANCHE_UNIT _jtAssetsToLiquidate, bytes calldata _liquidationCallbackData) external virtual;

    // =============================
    // Admin Functions
    // =============================

    /// @inheritdoc IRoycoKernel
    function setProtocolFeeRecipient(address _protocolFeeRecipient) external override(IRoycoKernel) restricted {
        require(_protocolFeeRecipient != address(0), NULL_ADDRESS());
        _getRoycoKernelStorage().protocolFeeRecipient = _protocolFeeRecipient;
        emit ProtocolFeeRecipientUpdated(_protocolFeeRecipient);
    }

    // =============================
    // Internal Tranche Accounting Synchronization Functions
    // =============================

    /**
     * @notice Previews an accounting sync via the accountant
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function _previewSyncTrancheAccounting() internal view virtual returns (SyncedAccountingState memory state) {
        // Preview an accounting sync via the accountant
        state = ACCOUNTANT.previewSyncTrancheAccounting(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV(), _getLiquidationProceedsNAV(), ZERO_NAV_UNITS);
    }

    /**
     * @notice Invokes the accountant to do a pre-operation (deposit and withdrawal) NAV sync and mints any protocol fee shares accrued
     * @dev A sync must be executed before every NAV mutating operation (deposit, withdrawal, and liquidation)
     * @dev Should not be called to sync post-liquidation NAVs: use `_postLiquidationSyncTrancheAccounting` instead
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function _syncTrancheAccounting() internal virtual returns (SyncedAccountingState memory state) {
        // Execute the pre-op sync via the accountant
        state = ACCOUNTANT.syncTrancheAccounting(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV(), _getLiquidationProceedsNAV(), ZERO_NAV_UNITS);

        // Collect any protocol fees accrued
        _collectProtocolFees(state.stProtocolFeeAccrued, state.jtProtocolFeeAccrued, state.stEffectiveNAV, state.jtEffectiveNAV);
    }

    /**
     * @notice Invokes the accountant to do a sync and returns asset claims for both tranches
     * @dev A sync must be executed before every NAV mutating operation (deposit, withdrawal, and liquidation)
     * @dev Should not be called to sync post-liquidation NAVs: use `_postLiquidationSyncTrancheAccounting` instead
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     * @return stClaims The claims on ST, JT, and liquidation proceed assets that the senior tranche has, denominated in tranche-native units
     * @return jtClaims The claims on ST, JT, and liquidation proceed assets that the junior tranche has, denominated in tranche-native units
     */
    function _syncTrancheAccountingWithClaims()
        internal
        virtual
        returns (SyncedAccountingState memory state, AssetClaims memory stClaims, AssetClaims memory jtClaims)
    {
        // Execute the NAV sync via the accountant
        state = _syncTrancheAccounting();

        // Marshal the asset claims
        (stClaims, jtClaims) = _marshalTrancheAssetClaims(state);
    }

    /**
     * @notice Invokes the accountant to do a NAV sync and mints any protocol fee shares accrued
     * @dev A sync must be executed before every NAV mutating operation (deposit, withdrawal, and liquidation)
     * @dev Should not be called to sync post-liquidation NAVs: use `_postLiquidationSyncTrancheAccounting` instead
     * @notice Returns the asset claims and total tranche shares after minting any fees for the specified tranche
     * @param _trancheType An enum indicating which tranche to return claims and total tranche shares for
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     * @return claims The claims on ST, JT, and liquidation proceed assets that the specified tranche has denominated in tranche-native units
     * @return totalTrancheShares The total shares outstanding in the specified tranche after minting any protocol fee shares
     */
    function _syncTrancheAccounting(TrancheType _trancheType)
        internal
        virtual
        returns (SyncedAccountingState memory state, AssetClaims memory claims, uint256 totalTrancheShares)
    {
        // Execute the pre-op sync via the accountant
        state = ACCOUNTANT.syncTrancheAccounting(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV(), _getLiquidationProceedsNAV(), ZERO_NAV_UNITS);

        // Collect any protocol fees accrued from the sync to the fee recipient
        RoycoKernelState storage $ = _getRoycoKernelStorage();
        address protocolFeeRecipient = $.protocolFeeRecipient;
        uint256 stTotalTrancheSharesAfterMintingFees;
        uint256 jtTotalTrancheSharesAfterMintingFees;
        // If the call needs to get total supply or mint shares for fees accrued for the senior tranche
        if (_trancheType == TrancheType.SENIOR || state.stProtocolFeeAccrued != ZERO_NAV_UNITS) {
            (, stTotalTrancheSharesAfterMintingFees) =
                IRoycoVaultTranche(SENIOR_TRANCHE).mintProtocolFeeShares(state.stProtocolFeeAccrued, state.stEffectiveNAV, protocolFeeRecipient);
        }
        // If the call needs to get total supply or mint shares for fees accrued for the junior tranche
        if (_trancheType == TrancheType.JUNIOR || state.jtProtocolFeeAccrued != ZERO_NAV_UNITS) {
            (, jtTotalTrancheSharesAfterMintingFees) =
                IRoycoVaultTranche(JUNIOR_TRANCHE).mintProtocolFeeShares(state.jtProtocolFeeAccrued, state.jtEffectiveNAV, protocolFeeRecipient);
        }

        // Marshal the asset claims
        (AssetClaims memory stClaims, AssetClaims memory jtClaims) = _marshalTrancheAssetClaims(state);

        // Return the requested tranche claims and total shares
        if (_trancheType == TrancheType.SENIOR) {
            claims = stClaims;
            totalTrancheShares = stTotalTrancheSharesAfterMintingFees;
        } else {
            claims = jtClaims;
            totalTrancheShares = jtTotalTrancheSharesAfterMintingFees;
        }
    }

    /**
     * @notice Invokes the accountant to do a pre-operation (deposit and withdrawal) NAV sync and mints any protocol fee shares accrued
     * @dev Should be called on every NAV mutating user operation
     * @param _liquidationBonusNAV The liquidation bonus NAV paid to the liquidator (if this sync is meant to reconcile a liquidation event)
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function _postLiquidationSyncTrancheAccounting(NAV_UNIT _liquidationBonusNAV) internal virtual returns (SyncedAccountingState memory state) {
        // Execute the pre-op sync via the accountant
        state = ACCOUNTANT.syncTrancheAccounting(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV(), _getLiquidationProceedsNAV(), _liquidationBonusNAV);

        // Collect any protocol fees accrued
        _collectProtocolFees(state.stProtocolFeeAccrued, state.jtProtocolFeeAccrued, state.stEffectiveNAV, state.jtEffectiveNAV);
    }

    /**
     * @notice Invokes the accountant to do a post-operation (deposit or withdrawal) NAV sync
     * @dev Should be called on every NAV mutating user operation that doesn't require a coverage check
     * @param _op The operation being executed in between the pre and post synchronizations
     * @param _stRedemptionBonusNAV The NAV of assets from JT effective NAV used as a bonus for ST redemptions (only applicable with _op == ST_REDEEM)
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function _postOpSyncTrancheAccounting(Operation _op, NAV_UNIT _stRedemptionBonusNAV) internal virtual returns (SyncedAccountingState memory state) {
        // Execute the post-op sync on the accountant
        state = ACCOUNTANT.postOpSyncTrancheAccounting(
            _op, _getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV(), _getLiquidationProceedsNAV(), _stRedemptionBonusNAV
        );
    }

    /**
     * @notice Invokes the accountant to do a post-operation (deposit or withdrawal) NAV sync and enforce that the market's coverage requirement is satisfied after reconciliation
     * @dev Should be called on every NAV mutating user operation that requires a coverage check: ST deposit and JT withdrawal
     * @param _op The operation being executed in between the pre and post synchronizations
     * @param _stRedemptionBonusNAV The NAV of assets from JT effective NAV used as a bonus for ST redemptions (only applicable with _op == ST_REDEEM)
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function _postOpSyncTrancheAccountingAndEnforceCoverage(
        Operation _op,
        NAV_UNIT _stRedemptionBonusNAV
    )
        internal
        virtual
        returns (SyncedAccountingState memory state)
    {
        // Execute the post-op sync on the accountant
        state = ACCOUNTANT.postOpSyncTrancheAccountingAndEnforceCoverage(
            _op, _getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV(), _getLiquidationProceedsNAV(), _stRedemptionBonusNAV
        );
    }

    /**
     * @notice Mints protocol fee shares to the fee recipient based on yield accrued during a sync
     * @dev Shares are minted at the current effective NAV per share ratio, diluting existing holders proportionally
     * @dev Only mints if fees were actually accrued (non-zero)
     * @param _stProtocolFeeAccrued The NAV amount of protocol fees accrued from senior tranche yield
     * @param _jtProtocolFeeAccrued The NAV amount of protocol fees accrued from junior tranche yield
     * @param _stEffectiveNAV The senior tranche's effective NAV used to calculate shares to mint
     * @param _jtEffectiveNAV The junior tranche's effective NAV used to calculate shares to mint
     */
    function _collectProtocolFees(NAV_UNIT _stProtocolFeeAccrued, NAV_UNIT _jtProtocolFeeAccrued, NAV_UNIT _stEffectiveNAV, NAV_UNIT _jtEffectiveNAV) internal {
        if (_stProtocolFeeAccrued != ZERO_NAV_UNITS || _jtProtocolFeeAccrued != ZERO_NAV_UNITS) {
            RoycoKernelState storage $ = _getRoycoKernelStorage();
            address protocolFeeRecipient = $.protocolFeeRecipient;
            // If ST fees were accrued or we need to get total shares for ST, mint ST protocol fee shares to the protocol fee recipient
            if (_stProtocolFeeAccrued != ZERO_NAV_UNITS) {
                IRoycoVaultTranche(SENIOR_TRANCHE).mintProtocolFeeShares(_stProtocolFeeAccrued, _stEffectiveNAV, protocolFeeRecipient);
            }
            // If JT fees were accrued or we need to get total shares for JT, mint JT protocol fee shares to the protocol fee recipient
            if (_jtProtocolFeeAccrued != ZERO_NAV_UNITS) {
                IRoycoVaultTranche(JUNIOR_TRANCHE).mintProtocolFeeShares(_jtProtocolFeeAccrued, _jtEffectiveNAV, protocolFeeRecipient);
            }
        }
    }

    /**
     * @notice Marshals each tranche's cumulative asset claims given an accounting sync packet
     * @param _state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     * @return stClaims The senior tranche's cumulative asset claims
     * @return jtClaims The junior tranche's cumulative asset claims
     */
    function _marshalTrancheAssetClaims(SyncedAccountingState memory _state)
        internal
        view
        virtual
        returns (AssetClaims memory stClaims, AssetClaims memory jtClaims)
    {
        // Liquidation settlement claims
        // ST has the first claim on liquidation proceeds
        NAV_UNIT stNAVClaimOnLiquidationProceeds = UnitsMathLib.min(_state.stEffectiveNAV, _state.liquidationProceedsNAV);
        // JT has the second claim on liquidation proceeds: the remaining after ST has been made whole
        NAV_UNIT jtNAVClaimOnLiquidationProceeds = UnitsMathLib.saturatingSub(_state.liquidationProceedsNAV, stNAVClaimOnLiquidationProceeds);

        // Cross-tranche claims
        NAV_UNIT stNAVClaimOnJT = UnitsMathLib.saturatingSub((_state.stEffectiveNAV - stNAVClaimOnLiquidationProceeds), _state.stRawNAV);
        NAV_UNIT jtNAVClaimOnST = UnitsMathLib.saturatingSub((_state.jtEffectiveNAV - jtNAVClaimOnLiquidationProceeds), _state.jtRawNAV);

        // Self-backed claims
        NAV_UNIT stNAVClaimOnSelf = UnitsMathLib.saturatingSub(_state.stRawNAV, jtNAVClaimOnST);
        NAV_UNIT jtNAVClaimOnSelf = UnitsMathLib.saturatingSub(_state.jtRawNAV, stNAVClaimOnJT);

        // Marshal senior tranche claims
        if (stNAVClaimOnSelf != ZERO_NAV_UNITS) stClaims.stAssets = stConvertNAVUnitsToTrancheUnits(stNAVClaimOnSelf);
        if (stNAVClaimOnJT != ZERO_NAV_UNITS) stClaims.jtAssets = jtConvertNAVUnitsToTrancheUnits(stNAVClaimOnJT);
        if (stNAVClaimOnLiquidationProceeds != ZERO_NAV_UNITS) stClaims.liquidationProceeds = convertNAVUnitsToBaseUnits(stNAVClaimOnLiquidationProceeds);
        stClaims.nav = (stNAVClaimOnSelf + stNAVClaimOnJT + stNAVClaimOnLiquidationProceeds);

        // Marshal junior tranche claims
        if (jtNAVClaimOnST != ZERO_NAV_UNITS) jtClaims.stAssets = stConvertNAVUnitsToTrancheUnits(jtNAVClaimOnST);
        if (jtNAVClaimOnSelf != ZERO_NAV_UNITS) jtClaims.jtAssets = jtConvertNAVUnitsToTrancheUnits(jtNAVClaimOnSelf);
        if (jtNAVClaimOnLiquidationProceeds != ZERO_NAV_UNITS) jtClaims.liquidationProceeds = convertNAVUnitsToBaseUnits(jtNAVClaimOnLiquidationProceeds);
        jtClaims.nav = (jtNAVClaimOnST + jtNAVClaimOnSelf + jtNAVClaimOnLiquidationProceeds);
    }

    /**
     * @notice Computes a user's asset claims for redemption with first-come-first-serve liquidation proceed prioritization
     * @dev Tranche controlled liquidation proceeds satisfy NAV claims first, and remaining NAV comes from exposure scaled proportionally
     * @param _trancheAssetClaims The tranche's total asset claims
     * @param _shares The number of shares being redeemed
     * @param _totalTrancheShares The total supply of tranche shares
     * @return userClaims The user's asset claims
     */
    function _previewRedeem(
        AssetClaims memory _trancheAssetClaims,
        uint256 _shares,
        uint256 _totalTrancheShares
    )
        internal
        view
        returns (AssetClaims memory userClaims)
    {
        // Scale tranche claims proportionally to get user's baseline entitlement
        AssetClaims memory proportionalClaims = UtilsLib.scaleAssetClaims(_trancheAssetClaims, _shares, _totalTrancheShares);
        NAV_UNIT userNAVClaim = proportionalClaims.nav;

        // First-come-first-served LP: try to cover NAV claim from tranche's LP allocation first
        NAV_UNIT availableLiquidationProceedsNAV = convertBaseUnitsToNAVUnits(_trancheAssetClaims.liquidationProceeds);
        if (availableLiquidationProceedsNAV >= userNAVClaim) {
            // LP covers entire claim - give only LP, no exposure
            userClaims.liquidationProceeds = convertNAVUnitsToBaseUnits(userNAVClaim);
            userClaims.nav = userNAVClaim;
        } else {
            // LP doesn't cover - take all available LP, scale down exposure proportionally
            userClaims.liquidationProceeds = convertNAVUnitsToBaseUnits(availableLiquidationProceedsNAV);

            // Compute the NAV needed from exposure after exhausting the available liquidation proceeds
            NAV_UNIT exposureNAVNeeded = userNAVClaim - availableLiquidationProceedsNAV;
            // Compute the original NAV needed from exposure before applying FCFS for available liquidation proceeds
            NAV_UNIT originalExposureNAV = userNAVClaim - convertBaseUnitsToNAVUnits(proportionalClaims.liquidationProceeds);

            // Scale down the claims to exposure to account for FCFS on the liquidation proceeds
            userClaims.stAssets = proportionalClaims.stAssets.mulDiv(exposureNAVNeeded, originalExposureNAV, Math.Rounding.Floor);
            userClaims.jtAssets = proportionalClaims.jtAssets.mulDiv(exposureNAVNeeded, originalExposureNAV, Math.Rounding.Floor);
            userClaims.nav = userNAVClaim;
        }
    }

    // =============================
    // Internal Utility Functions
    // =============================

    /**
     * @notice Withdraws any specified assets from each tranche and transfer them to the receiver
     * @param _claims The ST and JT assets to withdraw and transfer to the specified receiver
     * @param _receiver The receiver of the tranche asset claims
     */
    function _withdrawAssets(AssetClaims memory _claims, address _receiver) internal virtual {
        // Cache the individual claims
        TRANCHE_UNIT stAssetsToClaim = _claims.stAssets;
        TRANCHE_UNIT jtAssetsToClaim = _claims.jtAssets;
        BASE_UNIT liquidationProceedsToClaim = _claims.liquidationProceeds;

        // Debit the yield bearing assets being withdrawn from the junior tranche
        RoycoKernelState storage $ = _getRoycoKernelStorage();
        // Account for the ST and JT assets being withdrawn from each tranche if non-zero
        if (stAssetsToClaim != ZERO_TRANCHE_UNITS) $.stOwnedYieldBearingAssets = $.stOwnedYieldBearingAssets - stAssetsToClaim;
        if (jtAssetsToClaim != ZERO_TRANCHE_UNITS) $.jtOwnedYieldBearingAssets = $.jtOwnedYieldBearingAssets - jtAssetsToClaim;
        // Transfer any liquidation proceeds to the receiver
        if (liquidationProceedsToClaim != ZERO_BASE_UNITS) {
            $.liquidationProceeds = $.liquidationProceeds - liquidationProceedsToClaim;
            IERC20(BASE_ASSET).safeTransfer(_receiver, toUint256(liquidationProceedsToClaim));
        }

        // Transfer the yield bearing assets being withdrawn to the receiver
        // Do one batch transfer if they are the same asset, else do two separate transfers
        if (ST_ASSET == JT_ASSET) {
            IERC20(ST_ASSET).safeTransfer(_receiver, toUint256(stAssetsToClaim + jtAssetsToClaim));
        } else {
            if (stAssetsToClaim != ZERO_TRANCHE_UNITS) IERC20(ST_ASSET).safeTransfer(_receiver, toUint256(stAssetsToClaim));
            if (jtAssetsToClaim != ZERO_TRANCHE_UNITS) IERC20(JT_ASSET).safeTransfer(_receiver, toUint256(jtAssetsToClaim));
        }
    }

    /**
     * @notice Pulls base assets from a liquidator and increments the liquidation proceeds balance
     * @dev Used during liquidation to collect settlement from the liquidator
     * @param _amount The amount of base assets to pull
     * @param _liquidator The address of the liquidator providing the base assets
     */
    function _pullLiquidationProceeds(BASE_UNIT _amount, address _liquidator) internal {
        IERC20(BASE_ASSET).safeTransferFrom(_liquidator, address(this), toUint256(_amount));
        RoycoKernelState storage $ = _getRoycoKernelStorage();
        $.liquidationProceeds = $.liquidationProceeds + _amount;
    }

    // =============================
    // Internal NAV Retrieval Functions
    // =============================

    /**
     * @notice Returns the raw net asset value of the senior tranche denominated in the NAV units (USD, BTC, etc.) for this kernel
     * @return stRawNAV The pure net asset value of the senior tranche invested assets
     */
    function _getSeniorTrancheRawNAV() internal view virtual returns (NAV_UNIT stRawNAV) {
        // Get the yield bearing assets owned by ST and convert them to NAV units via the configured quoter
        return stConvertTrancheUnitsToNAVUnits(_getRoycoKernelStorage().stOwnedYieldBearingAssets);
    }

    /**
     * @notice Returns the raw net asset value of the junior tranche denominated in the NAV units (USD, BTC, etc.) for this kernel
     * @return jtRawNAV The pure net asset value of the junior tranche invested assets
     */
    function _getJuniorTrancheRawNAV() internal view virtual returns (NAV_UNIT jtRawNAV) {
        // Get the yield bearing assets owned by JT and convert them to NAV units via the configured quoter
        return jtConvertTrancheUnitsToNAVUnits(_getRoycoKernelStorage().jtOwnedYieldBearingAssets);
    }

    /**
     * @notice Returns the raw net asset value of the liquidation proceeds denominated in the NAV units (USD, BTC, etc.) for this kernel
     * @return liquidationProceedsNAV The net asset value of the liquidation proceeds from past liquidation events
     */
    function _getLiquidationProceedsNAV() internal view returns (NAV_UNIT liquidationProceedsNAV) {
        return convertBaseUnitsToNAVUnits(_getRoycoKernelStorage().liquidationProceeds);
    }

    // =============================
    // Internal Quoter Functions
    // =============================

    /**
     * @notice Initializes the quoter for a transaction
     * @dev Should be called at the start of a transaction
     * @dev Typically used to initialize the cached tranche unit to NAV unit conversion rate
     */
    function _initializeQuoterCache() internal virtual;

    /**
     * @notice Clears the quoter cache
     * @dev Should be called at the end of a transaction
     * @dev Typically used to clear the cached tranche unit to NAV unit conversion rate
     */
    function _clearQuoterCache() internal virtual;

    // =============================
    // Kernel Storage Functions
    // =============================

    /**
     * @notice Returns a storage pointer to the RoycoKernelState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer to the kernel's state
     */
    function _getRoycoKernelStorage() internal pure returns (RoycoKernelState storage $) {
        assembly ("memory-safe") {
            $.slot := BASE_KERNEL_STORAGE_SLOT
        }
    }
}
