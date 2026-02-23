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
import { RoycoKernelInitParams, RoycoKernelState, RoycoKernelStorageLib } from "../../libraries/RoycoKernelStorageLib.sol";
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

    /// @dev The base asset used for liquidation settlements, with 1:1 value parity with NAV units but may differ in precision
    /// @dev Constitutes the BASE_UNIT for this market
    address internal immutable BASE_ASSET;

    /// @dev The scale factor used to scale base asset quantities to/from NAV unit precision (WAD decimals)
    uint256 internal immutable BASE_UNIT_SCALE_FACTOR_TO_WAD;

    /// @dev Immutable addresses for the senior tranche, ST asset, junior tranche, and JT asset
    address internal immutable SENIOR_TRANCHE;
    address internal immutable ST_ASSET;
    address internal immutable JUNIOR_TRANCHE;
    address internal immutable JT_ASSET;

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
    // Initializer and State Accessor Functions
    // =============================

    /// @notice Constructs the base Royco kernel state
    /// @param _params The standard construction parameters for the Royco kernel
    constructor(RoycoKernelConstructionParams memory _params) {
        // Ensure that the tranche addresses are not null
        require(
            _params.seniorTranche != address(0) && _params.stAsset != address(0) && _params.juniorTranche != address(0) && _params.jtAsset != address(0),
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
    }

    /**
     * @notice Initializes the base Royco kernel state
     * @dev Initializes any parent contracts and the base kernel state
     * @param _params The standard initialization parameters for the Royco kernel
     */
    function __RoycoKernel_init(RoycoKernelInitParams memory _params) internal onlyInitializing {
        // Initialize the Royco base state
        __RoycoBase_init(_params.initialAuthority);

        // Initialize the Royco kernel state
        // Ensure that the tranches and their corresponding assets in the kernel match
        require(
            IRoycoVaultTranche(SENIOR_TRANCHE).asset() == ST_ASSET && IRoycoVaultTranche(JUNIOR_TRANCHE).asset() == JT_ASSET,
            TRANCHE_AND_KERNEL_ASSETS_MISMATCH()
        );
        // Ensure that the tranche addresses, accountant, and protocol fee recipient are not null
        require(_params.accountant != address(0) && _params.protocolFeeRecipient != address(0), NULL_ADDRESS());
        // Initialize the base kernel state
        RoycoKernelStorageLib.__RoycoKernel_init(_params);

        emit ProtocolFeeRecipientUpdated(_params.protocolFeeRecipient);
    }

    /// @inheritdoc IRoycoKernel
    function getState()
        external
        view
        override(IRoycoKernel)
        returns (address seniorTranche, address stAsset, address juniorTranche, address jtAsset, address protocolFeeRecipient, address accountant)
    {
        RoycoKernelState storage $ = RoycoKernelStorageLib._getRoycoKernelStorage();
        return (SENIOR_TRANCHE, ST_ASSET, JUNIOR_TRANCHE, JT_ASSET, $.protocolFeeRecipient, $.accountant);
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
    // Tranche Quoter Functions
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
        NAV_UNIT stMaxDepositableNAV = _accountant().maxSTDepositGivenCoverage(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV());
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
        (, NAV_UNIT stClaimableGivenCoverage, NAV_UNIT jtClaimableGivenCoverage) = _accountant()
            .maxJTWithdrawalGivenCoverage(
                state.stRawNAV,
                state.jtRawNAV,
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
        // Execute a pre-op accounting sync via the accountant
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

        // Decompose effective NAVs into self-backed NAV claims and cross-tranche NAV claims
        (NAV_UNIT stNAVClaimOnSelf, NAV_UNIT stNAVClaimOnJT, NAV_UNIT stNAVClaimOnLiquidationProceeds, NAV_UNIT jtNAVClaimOnSelf, NAV_UNIT jtNAVClaimOnST) =
            _decomposeNAVClaims(state);

        // Marshal the tranche claims for this tranche given the decomposed claims
        claims = _marshalAssetClaims(_trancheType, stNAVClaimOnSelf, stNAVClaimOnJT, stNAVClaimOnLiquidationProceeds, jtNAVClaimOnSelf, jtNAVClaimOnST);

        // Preview the total tranche shares after minting any protocol fee shares post-sync
        if (_trancheType == TrancheType.SENIOR) {
            (, totalTrancheShares) = IRoycoVaultTranche(SENIOR_TRANCHE).previewMintProtocolFeeShares(state.stProtocolFeeAccrued, state.stEffectiveNAV);
        } else {
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
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintAt)
    {
        SyncedAccountingState memory state = _syncTrancheAccounting();
        // If ST IL exists, ST deposits are disabled to preclude existing ST's from getting diluted and realizing losses
        require(state.stImpermanentLoss == ZERO_NAV_UNITS, ST_DEPOSIT_DISABLED_IN_LOSS());
        // Execute a pre-op sync on accounting
        navToMintAt = state.stEffectiveNAV;

        // The tranche vault has already transfered the assets to the kernel, so simply credit those assets to the senior tranche
        RoycoKernelState storage $ = RoycoKernelStorageLib._getRoycoKernelStorage();
        $.stOwnedYieldBearingAssets = $.stOwnedYieldBearingAssets + _assets;

        // Execute a post-op sync on accounting and enforce the market's coverage requirement
        NAV_UNIT stPostDepositNAV =
        (_postOpSyncTrancheAccountingAndEnforceCoverage(Operation.ST_DEPOSIT, stDepositNAV, ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS))
        .stEffectiveNAV;
        // The precise value allocated is the delta between the pre and post deposit NAVs
        valueAllocated = stPostDepositNAV - navToMintAt;
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
        // Execute a pre-op sync on accounting
        uint256 totalTrancheShares;
        {
            SyncedAccountingState memory state;
            (state, userAssetClaims, totalTrancheShares) = _syncTrancheAccounting(TrancheType.SENIOR);
            MarketState marketState = state.marketState;

            // Ensure that the market is in a state where ST redemptions are allowed: PERPETUAL
            require(marketState == MarketState.PERPETUAL, ST_REDEEM_DISABLED_IN_FIXED_TERM_STATE());
        }

        // Scale total tranche asset claims by the ratio of shares this user owns of the tranche vault
        // Protocol fee shares were minted in the pre-op sync, so the total tranche shares are up to date
        userAssetClaims = UtilsLib.scaleAssetClaims(userAssetClaims, _shares, totalTrancheShares);

        // Withdraw the asset claims from each tranche and transfer them to the receiver
        _withdrawAssets(userAssetClaims, _receiver);

        // Execute a post-op sync on accounting
        _postOpSyncTrancheAccounting(Operation.ST_REDEEM, ZERO_NAV_UNITS, ZERO_NAV_UNITS, stRedeemNAV, jtRedeemNAV, stLiquidationProceedsRedeemNAV);
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
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintAt)
    {
        // Execute a pre-op sync on accounting
        SyncedAccountingState memory state = _syncTrancheAccounting();
        navToMintAt = state.jtEffectiveNAV;

        // Ensure that the market is in a state where JT deposits are allowed: PERPETUAL
        require(state.marketState == MarketState.PERPETUAL, JT_DEPOSIT_DISABLED_IN_FIXED_TERM_STATE());

        // The tranche vault has already transfered the assets to the kernel, so simply credit those assets to the junior tranche
        RoycoKernelState storage $ = RoycoKernelStorageLib._getRoycoKernelStorage();
        $.jtOwnedYieldBearingAssets = $.jtOwnedYieldBearingAssets + _assets;

        // Execute a post-op sync on accounting and enforce the market's coverage requirement
        NAV_UNIT jtPostDepositNAV =
        (_postOpSyncTrancheAccounting(Operation.JT_DEPOSIT, ZERO_NAV_UNITS, jtDepositNAV, ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS)).jtEffectiveNAV;
        // The precise value allocated is the delta between the pre and post deposit NAVs
        valueAllocated = jtPostDepositNAV - navToMintAt;
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
        uint256 totalTrancheShares;
        SyncedAccountingState memory state;
        (state, userAssetClaims, totalTrancheShares) = _syncTrancheAccounting(TrancheType.JUNIOR);

        // Scale total tranche asset claims by the ratio of shares this user owns of the tranche vault
        // Protocol fee shares were minted in the pre-op sync, so the total tranche shares are up to date
        userAssetClaims = UtilsLib.scaleAssetClaims(userAssetClaims, _shares, totalTrancheShares);

        // Withdraw the asset claims from each tranche and transfer them to the receiver
        _withdrawAssets(userAssetClaims, _receiver);

        // Execute a post-op sync on accounting and enforce the market's coverage requirement
        _postOpSyncTrancheAccountingAndEnforceCoverage(Operation.JT_REDEEM, ZERO_NAV_UNITS, ZERO_NAV_UNITS, stRedeemNAV, jtRedeemNAV, ZERO_NAV_UNITS);
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
        RoycoKernelStorageLib._getRoycoKernelStorage().protocolFeeRecipient = _protocolFeeRecipient;
        emit ProtocolFeeRecipientUpdated(_protocolFeeRecipient);
    }

    // =============================
    // Internal Tranche Accounting Synchronization Functions
    // =============================

    /**
     * @notice Previews an accounting sync via the accountant
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark to market accounting data
     */
    function _previewSyncTrancheAccounting() internal view virtual returns (SyncedAccountingState memory state) {
        // Preview an accounting sync via the accountant
        state = _accountant().previewSyncTrancheAccounting(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV());
    }

    /**
     * @notice Invokes the accountant to do a pre-operation (deposit and withdrawal) NAV sync and mints any protocol fee shares accrued
     * @notice Also returns the asset claims and total tranche shares after minting any fees
     * @dev Should be called on every NAV mutating user operation
     * @param _trancheType An enum indicating which tranche to return claims and total tranche shares for
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark to market accounting data
     * @return claims The claims on ST and JT assets that the specified tranche has denominated in tranche-native units
     * @return totalTrancheShares The total shares outstanding in the specified tranche after minting any protocol fee shares
     */
    function _syncTrancheAccounting(TrancheType _trancheType)
        internal
        virtual
        returns (SyncedAccountingState memory state, AssetClaims memory claims, uint256 totalTrancheShares)
    {
        // Execute the pre-op sync via the accountant
        state = _accountant().syncTrancheAccounting(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV(), _getLiquidationProceedsNAV());

        // Collect any protocol fees accrued from the sync to the fee recipient
        RoycoKernelState storage $ = RoycoKernelStorageLib._getRoycoKernelStorage();
        address protocolFeeRecipient = $.protocolFeeRecipient;
        uint256 stTotalTrancheSharesAfterMintingFees;
        uint256 jtTotalTrancheSharesAfterMintingFees;
        // If the call needs to get total supply or fees accrued for the senior tranche
        if (_trancheType == TrancheType.SENIOR || state.stProtocolFeeAccrued != ZERO_NAV_UNITS) {
            (, stTotalTrancheSharesAfterMintingFees) =
                IRoycoVaultTranche(SENIOR_TRANCHE).mintProtocolFeeShares(state.stProtocolFeeAccrued, state.stEffectiveNAV, protocolFeeRecipient);
        }
        // If the call needs to get total supply or fees accrued for the junior tranche
        if (_trancheType == TrancheType.JUNIOR || state.jtProtocolFeeAccrued != ZERO_NAV_UNITS) {
            (, jtTotalTrancheSharesAfterMintingFees) =
                IRoycoVaultTranche(JUNIOR_TRANCHE).mintProtocolFeeShares(state.jtProtocolFeeAccrued, state.jtEffectiveNAV, protocolFeeRecipient);
        }

        // Set the total tranche shares to the specified tranche's shares after minting fees
        totalTrancheShares = (_trancheType == TrancheType.SENIOR) ? stTotalTrancheSharesAfterMintingFees : jtTotalTrancheSharesAfterMintingFees;

        // Decompose effective NAVs into self-backed NAV claims and cross-tranche NAV claims
        (NAV_UNIT stNAVClaimOnSelf, NAV_UNIT stNAVClaimOnJT, NAV_UNIT stNAVClaimOnLiquidationProceeds, NAV_UNIT jtNAVClaimOnSelf, NAV_UNIT jtNAVClaimOnST) =
            _decomposeNAVClaims(state);

        // Marshal the tranche claims for this tranche given the decomposed claims
        claims = _marshalAssetClaims(_trancheType, stNAVClaimOnSelf, stNAVClaimOnJT, stNAVClaimOnLiquidationProceeds, jtNAVClaimOnSelf, jtNAVClaimOnST);
    }

    /**
     * @notice Invokes the accountant to do a pre-operation (deposit and withdrawal) NAV sync and mints any protocol fee shares accrued
     * @dev Should be called on every NAV mutating user operation
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark to market accounting data
     */
    function _syncTrancheAccounting() internal virtual returns (SyncedAccountingState memory state) {
        // Execute the pre-op sync via the accountant
        state = _accountant().syncTrancheAccounting(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV());

        // Collect any protocol fees accrued
        _collectProtocolFees(state.stProtocolFeeAccrued, state.jtProtocolFeeAccrued, state.stEffectiveNAV, state.jtEffectiveNAV);
    }

    /**
     * @notice Invokes the accountant to do a post-operation (deposit and withdrawal) NAV sync
     * @dev Should be called on every NAV mutating user operation that doesn't require a coverage check
     * @param _op The operation being executed in between the pre and post synchronizations
     * @param _stDepositNAV The pre-op NAV deposited into the senior tranche (0 if not a ST deposit)
     * @param _jtDepositNAV The pre-op NAV deposited into the junior tranche (0 if not a JT deposit)
     * @param _stRedemptionNAV The pre-op NAV withdrawn from the senior tranche's raw NAV
     * @param _jtRedemptionNAV The pre-op NAV withdrawn from the junior tranche's raw NAV
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark to market accounting data
     */
    function _postOpSyncTrancheAccounting(
        Operation _op,
        NAV_UNIT _stDepositNAV,
        NAV_UNIT _jtDepositNAV,
        NAV_UNIT _stRedemptionNAV,
        NAV_UNIT _jtRedemptionNAV,
        NAV_UNIT _stLiquidationProceedsRedemptionNAV
    )
        internal
        virtual
        returns (SyncedAccountingState memory state)
    {
        // Execute the post-op sync on the accountant
        state = _accountant()
            .postOpSyncTrancheAccounting(
                _op,
                _getSeniorTrancheRawNAV(),
                _getJuniorTrancheRawNAV(),
                _getLiquidationProceedsNAV(),
                _stDepositNAV,
                _jtDepositNAV,
                _stRedemptionNAV,
                _jtRedemptionNAV,
                _stLiquidationProceedsRedemptionNAV
            );

        // Collect any protocol fees accrued
        _collectProtocolFees(state.stProtocolFeeAccrued, state.jtProtocolFeeAccrued, state.stEffectiveNAV, state.jtEffectiveNAV);
    }

    /**
     * @notice Invokes the accountant to do a post-operation (deposit and withdrawal) NAV sync and checks the market's coverage requirement is satisfied
     * @dev Should be called on every NAV mutating user operation that requires a coverage check: ST deposit and JT withdrawal
     * @param _op The operation being executed in between the pre and post synchronizations
     * @param _stDepositNAV The pre-op NAV deposited into the senior tranche (0 if not a ST deposit)
     * @param _jtDepositNAV The pre-op NAV deposited into the junior tranche (0 if not a JT deposit)
     * @param _stRedemptionNAV The pre-op NAV withdrawn from the senior tranche's raw NAV
     * @param _jtRedemptionNAV The pre-op NAV withdrawn from the junior tranche's raw NAV
     * @param _stLiquidationProceedsRedemptionNAV The NAV withdrawn from the senior tranche's liquidation proceeds
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark to market accounting data
     */
    function _postOpSyncTrancheAccountingAndEnforceCoverage(
        Operation _op,
        NAV_UNIT _stDepositNAV,
        NAV_UNIT _jtDepositNAV,
        NAV_UNIT _stRedemptionNAV,
        NAV_UNIT _jtRedemptionNAV,
        NAV_UNIT _stLiquidationProceedsRedemptionNAV
    )
        internal
        virtual
        returns (SyncedAccountingState memory state)
    {
        // Execute the post-op sync on the accountant
        state = _accountant()
            .postOpSyncTrancheAccountingAndEnforceCoverage(
                _op,
                _getSeniorTrancheRawNAV(),
                _getJuniorTrancheRawNAV(),
                _stDepositNAV,
                _jtDepositNAV,
                _stRedemptionNAV,
                _jtRedemptionNAV,
                _stLiquidationProceedsRedemptionNAV
            );

        // Collect any protocol fees accrued
        _collectProtocolFees(state.stProtocolFeeAccrued, state.jtProtocolFeeAccrued, state.stEffectiveNAV, state.jtEffectiveNAV);
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
            RoycoKernelState storage $ = RoycoKernelStorageLib._getRoycoKernelStorage();
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
     * @notice Decomposes effective NAVs into self-backed NAV claims and cross-tranche NAV claims
     * @param _state The synced NAV, impermanent loss, and fee accounting containing all mark to market accounting data
     * @return stNAVClaimOnSelf The portion of ST's effective NAV that must be funded by ST’s raw NAV
     * @return stNAVClaimOnJT The portion of ST's effective NAV that must be funded by JT’s raw NAV
     * @return stNAVClaimOnLiquidationProceeds The portion of ST's effective NAV funded by liquidation proceeds
     * @return jtNAVClaimOnSelf The portion of JT's effective NAV that must be funded by JT’s raw NAV
     * @return jtNAVClaimOnST The portion of JT's effective NAV that must be funded by ST’s raw NAV
     */
    function _decomposeNAVClaims(SyncedAccountingState memory _state)
        internal
        view
        virtual
        returns (
            NAV_UNIT stNAVClaimOnSelf,
            NAV_UNIT stNAVClaimOnJT,
            NAV_UNIT stNAVClaimOnLiquidationProceeds,
            NAV_UNIT jtNAVClaimOnSelf,
            NAV_UNIT jtNAVClaimOnST
        )
    {
        // Senior tranche liquidation proceeds from past liquidation events
        stNAVClaimOnLiquidationProceeds = _getLiquidationProceedsNAV();

        // Cross-tranche claims (only one direction should be non-zero under conservation)
        stNAVClaimOnJT = UnitsMathLib.saturatingSub(UnitsMathLib.saturatingSub(_state.stEffectiveNAV, _state.stRawNAV), stNAVClaimOnLiquidationProceeds);
        jtNAVClaimOnST = UnitsMathLib.saturatingSub(_state.jtEffectiveNAV, _state.jtRawNAV);

        // Self-backed portions (the remainder of each tranche’s effective NAV)
        stNAVClaimOnSelf = UnitsMathLib.saturatingSub(_state.stRawNAV, jtNAVClaimOnST);
        jtNAVClaimOnSelf = UnitsMathLib.saturatingSub(_state.jtRawNAV, stNAVClaimOnJT);
    }

    /**
     * @notice Converts NAV denominated claim components into concrete claimable tranche units
     * @param _trancheType An enum indicating which tranche to construct the claim for
     * @param _stNAVClaimOnSelf The portion of ST's effective NAV that must be funded by ST's raw NAV
     * @param _stNAVClaimOnJT The portion of ST's effective NAV that must be funded by JT's raw NAV
     * @param _stNAVClaimOnLiquidationProceeds The portion of ST's effective NAV funded by liquidation proceeds
     * @param _jtNAVClaimOnSelf The portion of JT's effective NAV that must be funded by JT's raw NAV
     * @param _jtNAVClaimOnST The portion of JT's effective NAV that must be funded by ST's raw NAV
     * @return claims The claims on ST and JT assets that the specified tranche has denominated in tranche-native units
     */
    function _marshalAssetClaims(
        TrancheType _trancheType,
        NAV_UNIT _stNAVClaimOnSelf,
        NAV_UNIT _stNAVClaimOnJT,
        NAV_UNIT _stNAVClaimOnLiquidationProceeds,
        NAV_UNIT _jtNAVClaimOnSelf,
        NAV_UNIT _jtNAVClaimOnST
    )
        internal
        view
        virtual
        returns (AssetClaims memory claims)
    {
        if (_trancheType == TrancheType.SENIOR) {
            if (_stNAVClaimOnSelf != ZERO_NAV_UNITS) claims.stAssets = stConvertNAVUnitsToTrancheUnits(_stNAVClaimOnSelf);
            if (_stNAVClaimOnJT != ZERO_NAV_UNITS) claims.jtAssets = jtConvertNAVUnitsToTrancheUnits(_stNAVClaimOnJT);
            if (_stNAVClaimOnLiquidationProceeds != ZERO_NAV_UNITS) claims.liquidationProceeds = convertNAVUnitsToBaseUnits(_stNAVClaimOnLiquidationProceeds);
            claims.nav = (_stNAVClaimOnSelf + _stNAVClaimOnJT + _stNAVClaimOnLiquidationProceeds);
        } else {
            if (_jtNAVClaimOnST != ZERO_NAV_UNITS) claims.stAssets = stConvertNAVUnitsToTrancheUnits(_jtNAVClaimOnST);
            if (_jtNAVClaimOnSelf != ZERO_NAV_UNITS) claims.jtAssets = jtConvertNAVUnitsToTrancheUnits(_jtNAVClaimOnSelf);
            claims.nav = (_jtNAVClaimOnST + _jtNAVClaimOnSelf);
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
        RoycoKernelState storage $ = RoycoKernelStorageLib._getRoycoKernelStorage();
        // Account for the ST and JT assets being withdrawn from each tranche if non-zero
        if (stAssetsToClaim != ZERO_TRANCHE_UNITS) $.stOwnedYieldBearingAssets = $.stOwnedYieldBearingAssets - stAssetsToClaim;
        if (jtAssetsToClaim != ZERO_TRANCHE_UNITS) $.jtOwnedYieldBearingAssets = $.jtOwnedYieldBearingAssets - jtAssetsToClaim;
        // Transfer any liquidation proceeds to the receiver
        if (liquidationProceedsToClaim != ZERO_BASE_UNITS) {
            $.stLiquidationProceeds = $.stLiquidationProceeds - liquidationProceedsToClaim;
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
     * @notice Previews the amount of ST and JT assets that would be redeemed for a given number of shares
     * @param _shares The number of shares to redeem
     * @param _trancheType The type of tranche to preview the redemption for
     * @return userClaim The amount of ST and JT assets that would be redeemed for the given number of shares
     */
    function _previewRedeem(uint256 _shares, TrancheType _trancheType) internal view virtual returns (AssetClaims memory userClaim) {
        // Get the total claim of ST on the ST and JT assets, and scale it to the number of shares being redeemed
        (, AssetClaims memory totalClaims, uint256 totalTrancheShares) = previewSyncTrancheAccounting(_trancheType);
        userClaim = UtilsLib.scaleAssetClaims(totalClaims, _shares, totalTrancheShares);
    }

    /**
     * @notice Returns this kernel's accountant casted to the IRoycoAccountant interface
     * @return accountant The Royco Accountant for this kernel
     */
    function _accountant() internal view returns (IRoycoAccountant accountant) {
        return IRoycoAccountant(RoycoKernelStorageLib._getRoycoKernelStorage().accountant);
    }

    /**
     * @notice Pulls base assets from a liquidator and increments the liquidation proceeds balance
     * @dev Used during liquidation to collect settlement from the liquidator
     * @param _amount The amount of base assets to pull
     * @param _liquidator The address of the liquidator providing the base assets
     */
    function _pullLiquidationProceeds(BASE_UNIT _amount, address _liquidator) internal {
        IERC20(BASE_ASSET).safeTransferFrom(_liquidator, address(this), toUint256(_amount));
        RoycoKernelState storage $ = RoycoKernelStorageLib._getRoycoKernelStorage();
        $.stLiquidationProceeds = $.stLiquidationProceeds + _amount;
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
        return stConvertTrancheUnitsToNAVUnits(RoycoKernelStorageLib._getRoycoKernelStorage().stOwnedYieldBearingAssets);
    }

    /**
     * @notice Returns the raw net asset value of the junior tranche denominated in the NAV units (USD, BTC, etc.) for this kernel
     * @return jtRawNAV The pure net asset value of the junior tranche invested assets
     */
    function _getJuniorTrancheRawNAV() internal view virtual returns (NAV_UNIT jtRawNAV) {
        // Get the yield bearing assets owned by JT and convert them to NAV units via the configured quoter
        return jtConvertTrancheUnitsToNAVUnits(RoycoKernelStorageLib._getRoycoKernelStorage().jtOwnedYieldBearingAssets);
    }

    /**
     * @notice Returns the raw net asset value of the senior tranche's liquidation proceeds denominated in the NAV units (USD, BTC, etc.) for this kernel
     * @return liquidationProceedsNAV The net asset value of the liquidation proceeds that the senior tranche is entitled to
     */
    function _getLiquidationProceedsNAV() internal view returns (NAV_UNIT liquidationProceedsNAV) {
        return convertBaseUnitsToNAVUnits(RoycoKernelStorageLib._getRoycoKernelStorage().stLiquidationProceeds);
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
}
