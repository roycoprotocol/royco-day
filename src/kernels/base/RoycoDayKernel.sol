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
import { IRoycoSeniorTranche } from "../../interfaces/IRoycoSeniorTranche.sol";
import { IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { MAX_NAV_UNITS, MAX_TRANCHE_UNITS, WAD, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../../libraries/Constants.sol";
import { AssetClaims, MarketState, Operation, SyncedAccountingState, TrancheType } from "../../libraries/Types.sol";
import { Math, NAV_UNIT, TRANCHE_UNIT, UnitsMathLib, toNAVUnits, toTrancheUnits, toUint256 } from "../../libraries/Units.sol";
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
    using UnitsMathLib for uint256;
    using Math for uint256;

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

    /// @notice Whether to enforce the tranche whitelist on share transfers
    bool public immutable ENFORCE_TRANCHE_WHITELIST_ON_TRANSFER;

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
        ENFORCE_TRANCHE_WHITELIST_ON_TRANSFER = _params.enforceVaultSharesTransferWhitelist;
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
        returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated, uint256 totalTrancheSharesAfterSync)
    {
        // Preview the senior tranche state and its post-sync supply (after the premium and protocol fee shares) before the deposit
        (stateBeforeDeposit,, totalTrancheSharesAfterSync) = previewSyncTrancheAccounting(TrancheType.SENIOR);
        // Convert the assets to NAV units
        valueAllocated = stConvertTrancheUnitsToNAVUnits(_assets);
    }

    /// @inheritdoc IRoycoDayKernel
    function jtPreviewDeposit(TRANCHE_UNIT _assets)
        public
        view
        override(IRoycoDayKernel)
        returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated, uint256 totalTrancheSharesAfterSync)
    {
        // Preview the junior tranche state and its post-sync supply (after the protocol fee shares) before the deposit
        (stateBeforeDeposit,, totalTrancheSharesAfterSync) = previewSyncTrancheAccounting(TrancheType.JUNIOR);
        // Convert the assets to NAV units
        valueAllocated = jtConvertTrancheUnitsToNAVUnits(_assets);
    }

    /// @inheritdoc IRoycoDayKernel
    function ltPreviewDeposit(TRANCHE_UNIT _assets)
        public
        view
        override(IRoycoDayKernel)
        returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated, uint256 totalTrancheSharesAfterSync, NAV_UNIT navToMintSharesAt)
    {
        // Preview the liquidity tranche state and its post-sync supply (after the protocol fee shares) before the deposit
        (stateBeforeDeposit,, totalTrancheSharesAfterSync) = previewSyncTrancheAccounting(TrancheType.LIQUIDITY);
        // Convert the assets to NAV units
        valueAllocated = ltConvertTrancheUnitsToNAVUnits(_assets);
        // Surface the pre-deposit LT EFFECTIVE NAV (the value deployed into the AMM or another market-making venue plus the idle liquidity-premium senior shares) as the NAV to mint
        // LT shares at: it is not carried in SyncedAccountingState, so the tranche cannot derive it locally. Inject this period's post-mint
        // held count (the preview does not commit the premium mint), valued at the post-mint senior supply, mirroring execution
        (uint256 liquidityPremiumShares,, uint256 stTotalSupplyAfterMints) =
            _computeSTFeeAndLiquidityPremiumSharesToMint(stateBeforeDeposit, IERC20(SENIOR_TRANCHE).totalSupply());
        navToMintSharesAt = _getLiquidityTrancheEffectiveNAV(
            stateBeforeDeposit.stEffectiveNAV, stTotalSupplyAfterMints, _getRoycoDayKernelStorage().ltOwnedSeniorTrancheShares + liquidityPremiumShares
        );
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
        (stMaxWithdrawableNAV, jtMaxWithdrawableNAV) = IRoycoDayAccountant(ACCOUNTANT).maxJTWithdrawal(state);
    }

    /// @inheritdoc IRoycoDayKernel
    function ltMaxDeposit(address _receiver) public view virtual override(IRoycoDayKernel) returns (TRANCHE_UNIT) {
        // If the receiver is blacklisted or the kernel is currently paused, return zero tranche units
        if (_isBlacklisted(_receiver) || paused()) return ZERO_TRANCHE_UNITS;
        // LT deposits remain enabled during a fixed-term market state: the in-kind deposit only adds market-making depth, and the multi-asset
        // deposit's senior exposure is gated by the coverage requirement enforced on the post-op sync, so no separate fixed-term block is needed
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

        // Return the requested tranche claims and total shares after the sync mints its premium and protocol fee shares
        if (_trancheType == TrancheType.SENIOR) {
            // The senior supply after both senior-share carve-outs: the liquidity premium and the ST protocol fee
            (,, totalTrancheShares) = _computeSTFeeAndLiquidityPremiumSharesToMint(state, IERC20(SENIOR_TRANCHE).totalSupply());
        } else if (_trancheType == TrancheType.JUNIOR) {
            // The junior supply after the JT protocol fee shares, priced against the post-fee junior NAV (mirrors execution)
            uint256 jtTotalSupply = IERC20(JUNIOR_TRANCHE).totalSupply();
            totalTrancheShares = jtTotalSupply + _navToShares(state.jtProtocolFee, state.jtEffectiveNAV - state.jtProtocolFee, jtTotalSupply);
        } else {
            // Value the LT protocol fee against the liquidity tranche's effective NAV at the post-carve-out senior supply and
            // owned shares, mirroring execution so the previewed supply matches the supply that execution mints
            (uint256 liquidityPremiumShares,, uint256 stTotalSupplyAfterMints) =
                _computeSTFeeAndLiquidityPremiumSharesToMint(state, IERC20(SENIOR_TRANCHE).totalSupply());
            uint256 ltOwnedSeniorTrancheSharesAfter = _getRoycoDayKernelStorage().ltOwnedSeniorTrancheShares + liquidityPremiumShares;
            // The preview does not commit the premium mint, so _deriveTrancheAssetClaims above read the pre-mint held count from storage;
            // overwrite the idle-premium leg with the post-mint count so the previewed claims match what execution derives post-mint
            claims.stShares = ltOwnedSeniorTrancheSharesAfter;
            NAV_UNIT ltEffectiveNAV = _getLiquidityTrancheEffectiveNAV(state.stEffectiveNAV, stTotalSupplyAfterMints, ltOwnedSeniorTrancheSharesAfter);
            uint256 ltTotalSupply = IERC20(LIQUIDITY_TRANCHE).totalSupply();
            totalTrancheShares = ltTotalSupply + _navToShares(state.ltProtocolFee, ltEffectiveNAV - state.ltProtocolFee, ltTotalSupply);
        }
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
        // Execute an accounting sync to reconcile underlying PNL
        SyncedAccountingState memory state = _preOpSyncTrancheAccounting();
        // ST deposits are disabled during a fixed-term market state
        require(state.marketState == MarketState.PERPETUAL, DISABLED_IN_FIXED_TERM_STATE());
        // The NAV to mint tranche shares at is the pre-deposit senior tranche controlled NAV
        navToMintSharesAt = state.stEffectiveNAV;
        // The precise value allocated is the value of the deposited assets
        valueAllocated = stConvertTrancheUnitsToNAVUnits(_assets);

        // Credit the deposited assets to the senior tranche
        RoycoDayKernelState storage $ = _getRoycoDayKernelStorage();
        $.stOwnedYieldBearingAssets = $.stOwnedYieldBearingAssets + _assets;

        // Execute a post-deposit sync on accounting and enforce the market's coverage and liquidity requirements against the new senior exposure
        _postOpSyncTrancheAccounting(Operation.ST_DEPOSIT, ZERO_NAV_UNITS, true);
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

        // Execute a post-redeem sync on accounting, specifying whether or not to bypass the markets' requirements
        _postOpSyncTrancheAccounting(Operation.ST_REDEEM, stSelfLiquidationBonusNAV, false);
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

        // Credit the deposited assets to the junior tranche
        RoycoDayKernelState storage $ = _getRoycoDayKernelStorage();
        $.jtOwnedYieldBearingAssets = $.jtOwnedYieldBearingAssets + _assets;

        // Execute a post-deposit sync on accounting; a JT deposit grows the loss-absorption buffer and only improves coverage, so no requirements are enforced
        _postOpSyncTrancheAccounting(Operation.JT_DEPOSIT, ZERO_NAV_UNITS, false);
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

        // Execute a post-redeem sync on accounting, specifying whether or not to bypass the markets' requirements
        _postOpSyncTrancheAccounting(Operation.JT_REDEEM, ZERO_NAV_UNITS, !_bypassRedemptionRestrictions);
    }

    // =============================
    // Liquidity Tranche Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoDayKernel
    /// @dev LT deposits are enabled in all market states
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
        // The NAV to mint tranche shares at is the pre-deposit liquidity tranche effective NAV (its MM depth in addition to its idle liquidity-premium senior shares the kernel holds)
        navToMintSharesAt = _getLiquidityTrancheEffectiveNAV(state.stEffectiveNAV, IERC20(SENIOR_TRANCHE).totalSupply());
        // The precise value allocated is the value of the deposited assets
        valueAllocated = ltConvertTrancheUnitsToNAVUnits(_assets);

        // Credit the deposited assets to the liquidity tranche
        RoycoDayKernelState storage $ = _getRoycoDayKernelStorage();
        $.ltOwnedYieldBearingAssets = $.ltOwnedYieldBearingAssets + _assets;

        // Execute a post-deposit sync on accounting. An in-kind LT deposit only adds pooled depth and improves liquidity, so no requirements are enforced
        _postOpSyncTrancheAccounting(Operation.LT_DEPOSIT, ZERO_NAV_UNITS, false);
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev LT redemptions are enabled only in a PERPETUAL market state (unless restrictions are bypassed for a seizure), granted that the market's liquidity requirement is satisfied post-redemption
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

        // Execute a post-redeem sync on accounting, specifying whether or not to bypass the markets' requirements
        _postOpSyncTrancheAccounting(Operation.LT_REDEEM, ZERO_NAV_UNITS, !_bypassRedemptionRestrictions);
    }

    // =============================
    // Liquidity Tranche Multi-Asset Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoDayKernel
    /// @dev LT multi-asset deposits are enabled in all market states, granted that the market's coverage and liquidity requirements are satisfied against the new senior exposure
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
        // At least one constituent leg (ST underlying or quote) must be supplied
        require(_stAssets != ZERO_TRANCHE_UNITS || _quoteAssets != 0, MUST_DEPOSIT_NON_ZERO_ASSETS());

        // Execute an accounting sync to reconcile underlying PNL
        (SyncedAccountingState memory state,, uint256 totalSTShares) = _preOpSyncTrancheAccounting(TrancheType.SENIOR);
        // The NAV to mint tranche shares at is the pre-deposit liquidity tranche effective NAV (its MM depth plus the idle liquidity-premium senior shares the kernel holds), read before the add moves the pool mark
        navToMintSharesAt = _getLiquidityTrancheEffectiveNAV(state.stEffectiveNAV, totalSTShares);

        // If the ST asset leg is supplied, mint the corresponding non-diluting senior shares (priced at the pre-deposit senior effective NAV and pre-mint supply) to seed the add's senior leg
        RoycoDayKernelState storage $ = _getRoycoDayKernelStorage();
        uint256 stSharesMinted;
        if (_stAssets != ZERO_TRANCHE_UNITS) {
            // Compute the number of senior tranche shares to mint for this ST asset deposit
            stSharesMinted = _navToShares(stConvertTrancheUnitsToNAVUnits(_stAssets), state.stEffectiveNAV, totalSTShares);
            // Commit the ST underlying as an intermediate ST_DEPOSIT before the mint so the rate provider stays non-diluted when the add values the pool. Enforcement is deferred to the final sync
            $.stOwnedYieldBearingAssets = $.stOwnedYieldBearingAssets + _stAssets;
            // Mint the senior shares to the kernel (raises supply only, leaving the senior raw NAV unchanged)
            IRoycoVaultTranche(SENIOR_TRANCHE).mint(address(this), stSharesMinted);
        }

        // Add the minted ST shares and supplied quote assets into the liquidity venue with the specified slippage check
        ltAssetsOut = _addLiquidity(stSharesMinted, _quoteAssets, _minLTAssetsOut);
        // The precise value allocated is the value of the LT assets rendered by adding liquidity
        valueAllocated = ltConvertTrancheUnitsToNAVUnits(ltAssetsOut);

        // Credit the minted LT tranche assets (LP token) to the liquidity tranche
        $.ltOwnedYieldBearingAssets = $.ltOwnedYieldBearingAssets + ltAssetsOut;

        // Execute a post-deposit sync on accounting and enforce the market's coverage and liquidity requirements against the new ST and LT exposure
        _postOpSyncTrancheAccounting(Operation.LT_DEPOSIT, ZERO_NAV_UNITS, true);
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev LT multi-asset redemptions are enabled only in a PERPETUAL market state, granted the market's liquidity requirement is satisfied post-redemption unless the liquidation coverage utilization threshold is breached
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
        // Execute a pre-op sync, minting this period's liquidity premium into the kernel's held senior shares so the held pile and the LT supply are consistent for sizing the redeemer's slice
        (SyncedAccountingState memory state, AssetClaims memory ltClaims, uint256 totalLTShares) = _preOpSyncTrancheAccounting(TrancheType.LIQUIDITY);
        // Multi-asset redemptions are disabled during a fixed-term market state
        require(state.marketState == MarketState.PERPETUAL, DISABLED_IN_FIXED_TERM_STATE());

        // An LT share claims both LT effective-NAV legs: the deployed LP token and the idle liquidity-premium senior shares.
        RoycoDayKernelState storage $ = _getRoycoDayKernelStorage();
        // Compute the LT assets
        AssetClaims memory userAssetClaims = UtilsLib.scaleAssetClaims(ltClaims, _ltShares, totalLTShares);
        require(userAssetClaims.ltAssets != ZERO_TRANCHE_UNITS || userAssetClaims.stShares != 0, INSUFFICIENT_OUTPUT_AMOUNT());

        // Derive the ST total claims and supply from the synced state
        stClaims = _deriveTrancheAssetClaims(TrancheType.SENIOR, state);
        uint256 totalSTShares = IERC20(SENIOR_TRANCHE).totalSupply();

        // Debit both LT legs from the kernel's holdings: the LP-token slice and the idle premium senior shares
        // Remove the liquidity equivalent to the LT assets the user has a claim on
        uint256 stSharesWithdrawn;
        if (userAssetClaims.stShares != 0) $.ltOwnedSeniorTrancheShares -= userAssetClaims.stShares;
        if (userAssetClaims.ltAssets != ZERO_TRANCHE_UNITS) {
            $.ltOwnedYieldBearingAssets = $.ltOwnedYieldBearingAssets - userAssetClaims.ltAssets;
            (stSharesWithdrawn, quoteAssets) = _removeLiquidity(userAssetClaims.ltAssets, _minSTSharesOut, _minQuoteAssetsOut, _receiver);
        }

        // Redeem all of the redeemer's senior shares from the venue and from the premium
        uint256 stSharesToRedeem = stSharesWithdrawn + userAssetClaims.stShares;
        stClaims = UtilsLib.scaleAssetClaims(stClaims, stSharesToRedeem, totalSTShares);

        // Apply any ST self-liquidation bonus to the redeeming user's ST shares claims and retrieve the bonus NAV applied
        NAV_UNIT stSelfLiquidationBonusNAV;
        (stClaims, stSelfLiquidationBonusNAV) = _applySeniorTrancheSelfLiquidationBonus(state, stClaims);

        // Burn the redeemed senior shares and withdraw the bonus-adjusted ST claims to the receiver
        // The quote assets were remitted in the venue removal above
        IRoycoVaultTranche(SENIOR_TRANCHE).burn(stSharesToRedeem);
        _withdrawAssets(stClaims, _receiver);

        // Execute a post-redeem sync on accounting with the applied ST liquidation bonus
        _postOpSyncTrancheAccounting(Operation.LT_REDEEM, stSelfLiquidationBonusNAV, true);
    }

    // =============================
    // Liquidity Tranche Venue Hooks
    // =============================

    /**
     * @notice Single-sided/unbalanced add of (senior shares + quote) into the liquidity venue; returns the LT tranche assets (LP token) minted
     * @dev Overridden by the concrete venue kernel
     * @param _stShares The exact amount of senior tranche shares to add into the liquidity venue
     * @param _quoteAssets The exact amount of quote assets to add into the liquidity venue
     * @param _minLTAssetsOut The minimum LT tranche assets (LP token) that must be minted, bounding the add's slippage
     * @return ltAssets The LT tranche assets (LP token) minted by the add
     */
    function _addLiquidity(uint256 _stShares, uint256 _quoteAssets, TRANCHE_UNIT _minLTAssetsOut) internal virtual returns (TRANCHE_UNIT ltAssets);

    /**
     * @notice Proportional removal of the LP token into its (senior shares + quote) constituents; returns the constituents withdrawn
     * @dev Overridden by the concrete venue kernel
     * @param _ltAssets The exact LT tranche assets (LP token) to burn
     * @param _minSTSharesOut The minimum senior tranche shares that must be withdrawn, bounding the removal's slippage
     * @param _minQuoteAssetsOut The minimum quote assets that must be withdrawn, bounding the removal's slippage
     * @param _quoteAssetsReceiver The recipient of the withdrawn quote assets; the withdrawn senior shares always return to the kernel for the combined ST unwind
     * @return stShares The senior tranche shares withdrawn by the removal
     * @return quoteAssets The quote assets withdrawn by the removal
     */
    function _removeLiquidity(
        TRANCHE_UNIT _ltAssets,
        uint256 _minSTSharesOut,
        uint256 _minQuoteAssetsOut,
        address _quoteAssetsReceiver
    )
        internal
        virtual
        returns (uint256 stShares, uint256 quoteAssets);

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
        if (_to != address(0) && ENFORCE_TRANCHE_WHITELIST_ON_TRANSFER) {
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
        // Preview a senior/junior accounting sync via the accountant
        state = IRoycoDayAccountant(ACCOUNTANT).previewSyncTrancheAccounting(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV());
        // Refresh the liquidity tranche raw NAV and utilization in memory so the preview mirrors execution
        state.ltRawNAV = _getLiquidityTrancheRawNAV();
        state.liquidityUtilizationWAD = UtilsLib.computeLiquidityUtilization(state.stEffectiveNAV, state.minLiquidityWAD, state.ltRawNAV);
    }

    /**
     * @notice Invokes the accountant to do a pre-operation (deposit and withdrawal) NAV sync and mints any protocol fee shares accrued
     * @dev A sync must be executed before every NAV mutating operation (deposit and withdrawal)
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function _preOpSyncTrancheAccounting() internal virtual returns (SyncedAccountingState memory state) {
        // Execute the pre-op PnL synchronization via the accountant
        state = IRoycoDayAccountant(ACCOUNTANT).preOpSyncTrancheAccounting(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV());

        // Mint the protocol fee shares and the liquidity premium shares accrued by this sync
        _processFeesAndLiquidityPremium(state);

        // Commit the liquidity tranche's fresh raw NAV against the post-sync market state
        _commitPostSyncLiquidityTrancheRawNAV(state);
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
        // Execute the pre-op PnL synchronization via the accountant
        state = IRoycoDayAccountant(ACCOUNTANT).preOpSyncTrancheAccounting(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV());

        // Mint the protocol fee shares and the liquidity premium shares accrued by this sync
        _processFeesAndLiquidityPremium(state);

        // Commit the liquidity tranche's fresh raw NAV against the post-sync market state
        _commitPostSyncLiquidityTrancheRawNAV(state);

        // Read the requested tranche's total supply after all shares (fees and premium) have been minted
        if (_trancheType == TrancheType.SENIOR) {
            totalTrancheShares = IERC20(SENIOR_TRANCHE).totalSupply();
        } else if (_trancheType == TrancheType.JUNIOR) {
            totalTrancheShares = IERC20(JUNIOR_TRANCHE).totalSupply();
        } else {
            totalTrancheShares = IERC20(LIQUIDITY_TRANCHE).totalSupply();
        }

        // Derive the asset claims for the specified tranche
        claims = _deriveTrancheAssetClaims(_trancheType, state);
    }

    /**
     * @notice The single post-operation accounting entrypoint for every deposit and redeem path
     * @notice Commits the final state of the accounting after the operation has executed and checks the market's coverage and liquidity requirements
     * @param _op The operation being executed in between the pre and post synchronizations
     * @param _stSelfLiquidationBonusNAV The NAV of assets from JT effective NAV used as a bonus for ST redemptions (only nonzero if _op == ST_REDEEM || LT_REDEEM)
     * @param _enforceCoverageAndLiquidityRequirements Whether to enforce the market's coverage and liquidity requirements applicable to the operation
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function _postOpSyncTrancheAccounting(
        Operation _op,
        NAV_UNIT _stSelfLiquidationBonusNAV,
        bool _enforceCoverageAndLiquidityRequirements
    )
        internal
        virtual
        returns (SyncedAccountingState memory state)
    {
        // Execute the post-op sync on the accountant, committing the final state of the accounting and enforcing the market's requirements if specified
        state = IRoycoDayAccountant(ACCOUNTANT)
            .postOpSyncTrancheAccounting(
                _op,
                _getSeniorTrancheRawNAV(),
                _getJuniorTrancheRawNAV(),
                _getLiquidityTrancheRawNAV(),
                _stSelfLiquidationBonusNAV,
                _enforceCoverageAndLiquidityRequirements
            );
    }

    /**
     * @notice Mints the protocol fee shares and the liquidity premium shares accrued by a pre-op sync
     * @dev The liquidity premium is senior yield routed to the LT: it is minted as senior tranche shares the kernel holds for the
     *      liquidity tranche, leaving the senior raw NAV (and thus coverage) unchanged, so the mint is coverage-neutral
     * @dev The premium and ST protocol fee are priced jointly against the pre-sync senior supply, so neither dilutes the other. The
     *      LT protocol fee is minted last and so values against the post-carve-out senior supply and owned shares
     * @param _state The synced accounting state whose accrued liquidity premium and protocol fees are minted
     */
    function _processFeesAndLiquidityPremium(SyncedAccountingState memory _state) internal virtual {
        RoycoDayKernelState storage $ = _getRoycoDayKernelStorage();
        address protocolFeeRecipient = $.protocolFeeRecipient;

        // Split the senior effective NAV into its two senior-share carve-outs (the liquidity premium and the ST protocol fee)
        // at one joint price against the pre-sync senior supply, so neither carve-out dilutes the other
        (uint256 liquidityPremiumShares, uint256 stProtocolFeeShares, uint256 stTotalSupplyAfterMints) =
            _computeSTFeeAndLiquidityPremiumSharesToMint(_state, IERC20(SENIOR_TRANCHE).totalSupply());

        // Mint the liquidity premium as senior tranche shares held by the kernel on behalf of the liquidity tranche
        // The premium is already booked into the senior effective NAV, so minting these shares only reassigns senior appreciation to the LT
        if (liquidityPremiumShares != 0) {
            IRoycoSeniorTranche(SENIOR_TRANCHE).mintLiquidityPremiumShares(address(this), liquidityPremiumShares);
            $.ltOwnedSeniorTrancheShares += liquidityPremiumShares;
        }
        // Mint the ST protocol fee shares to the protocol fee recipient and LT liquidity premium fee shares to the kernel at an identical price
        if (stProtocolFeeShares != 0) {
            IRoycoVaultTranche(SENIOR_TRANCHE).mintProtocolFeeShares(protocolFeeRecipient, stProtocolFeeShares);
        }
        // If JT fees were accrued, price them against the post-fee junior NAV (the fee dilutes existing holders) and mint to the recipient
        if (_state.jtProtocolFee != ZERO_NAV_UNITS) {
            uint256 jtProtocolFeeShares = _navToShares(_state.jtProtocolFee, _state.jtEffectiveNAV - _state.jtProtocolFee, IERC20(JUNIOR_TRANCHE).totalSupply());
            IRoycoVaultTranche(JUNIOR_TRANCHE).mintProtocolFeeShares(protocolFeeRecipient, jtProtocolFeeShares);
        }
        // If LT fees were accrued, price them against the post-fee LT effective NAV (its pooled depth plus the idle premium) and mint to the recipient
        if (_state.ltProtocolFee != ZERO_NAV_UNITS) {
            NAV_UNIT ltEffectiveNAV = _getLiquidityTrancheEffectiveNAV(_state.stEffectiveNAV, stTotalSupplyAfterMints);
            uint256 ltProtocolFeeShares = _navToShares(_state.ltProtocolFee, ltEffectiveNAV - _state.ltProtocolFee, IERC20(LIQUIDITY_TRANCHE).totalSupply());
            IRoycoVaultTranche(LIQUIDITY_TRANCHE).mintProtocolFeeShares(protocolFeeRecipient, ltProtocolFeeShares);
        }
    }

    /**
     * @notice Marks and commits the liquidity tranche's fresh raw NAV and refreshes the in-memory state packet
     * @dev Called after a sync has committed the senior/junior NAVs and this kernel has minted any fee shares (and after any liquidity
     *      tranche venue mutation has settled), so the freshly marked liquidity tranche raw NAV reflects the final post-mint depth and
     *      senior share rate. The committed liquidity tranche raw NAV stays out of the P&L waterfall and the senior share rate provider's dependency loop
     * @dev Refreshes the state packet in place so every downstream consumer reads the most up-to-date values
     * @param _state The synced accounting state to refresh in place
     */
    function _commitPostSyncLiquidityTrancheRawNAV(SyncedAccountingState memory _state) internal virtual {
        // Get the post-sync LT raw NAV
        NAV_UNIT ltRawNAV = _getLiquidityTrancheRawNAV();
        // Commit the fresh LT raw NAV in the accountant and the derived liquidity utilization in the state packet
        IRoycoDayAccountant(ACCOUNTANT).commitLiquidityTrancheRawNAV(ltRawNAV);
        _state.ltRawNAV = ltRawNAV;
        _state.liquidityUtilizationWAD = UtilsLib.computeLiquidityUtilization(_state.stEffectiveNAV, _state.minLiquidityWAD, ltRawNAV);
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
        if (_trancheType == TrancheType.SENIOR || _trancheType == TrancheType.JUNIOR) {
            // Decompose the NAV claims for the senior and junior tranches based on the synced accounting state
            (NAV_UNIT stClaimOnSTRawNAV, NAV_UNIT stClaimOnJTRawNAV, NAV_UNIT jtClaimOnSTRawNAV, NAV_UNIT jtClaimOnJTRawNAV) =
                UtilsLib.computeTrancheClaimsOnNAVs(_state);

            // Compute the cumulative asset claims for the specified tranche based on the NAV decomposition
            if (_trancheType == TrancheType.SENIOR) {
                if (stClaimOnSTRawNAV != ZERO_NAV_UNITS) claims.stAssets = stConvertNAVUnitsToTrancheUnits(stClaimOnSTRawNAV);
                if (stClaimOnJTRawNAV != ZERO_NAV_UNITS) claims.jtAssets = jtConvertNAVUnitsToTrancheUnits(stClaimOnJTRawNAV);
                claims.nav = _state.stEffectiveNAV;
            } else {
                if (jtClaimOnSTRawNAV != ZERO_NAV_UNITS) claims.stAssets = stConvertNAVUnitsToTrancheUnits(jtClaimOnSTRawNAV);
                if (jtClaimOnJTRawNAV != ZERO_NAV_UNITS) claims.jtAssets = jtConvertNAVUnitsToTrancheUnits(jtClaimOnJTRawNAV);
                claims.nav = _state.jtEffectiveNAV;
            }
        } else {
            if (_state.ltRawNAV != ZERO_NAV_UNITS) claims.ltAssets = ltConvertNAVUnitsToTrancheUnits(_state.ltRawNAV);
            claims.stShares = _getRoycoDayKernelStorage().ltOwnedSeniorTrancheShares;
            claims.nav = _getLiquidityTrancheEffectiveNAV(_state.stEffectiveNAV, IRoycoVaultTranche(SENIOR_TRANCHE).totalSupply(), claims.stShares);
        }
    }

    /**
     * @notice Computes the senior tranche shares minted for this sync's senior yield split: the LT liquidity premium and the ST protocol fee
     * @dev Both the premium and the fee are reallocations of value already booked into the senior effective NAV (no assets enter or
     *      leave), so minting them is NAV-neutral and coverage-neutral: the premium reassigns senior appreciation to the LT and the fee to the protocol
     * @dev Both are priced over the same pre-sync supply against one shared denominator, the NAV the pre-existing shares retain net of the
     *      premium and fee (stEffectiveNAV - premium - fee), so neither dilutes the other. Both round down, so floor dust accrues to the pre-existing shares
     * @param _state The synced accounting state carrying the senior effective NAV, the liquidity premium, and the ST protocol fee
     * @param _seniorTrancheTotalSupply The total senior tranche share supply before this sync mints the premium and fee shares
     * @return liquidityPremiumShares The senior shares to mint as the LT liquidity premium, rounded down
     * @return stProtocolFeeShares The senior shares to mint as the ST protocol fee, rounded down
     * @return stTotalSupplyAfterMints The total senior tranche supply after minting the premium and fee shares
     */
    function _computeSTFeeAndLiquidityPremiumSharesToMint(
        SyncedAccountingState memory _state,
        uint256 _seniorTrancheTotalSupply
    )
        internal
        pure
        returns (uint256 liquidityPremiumShares, uint256 stProtocolFeeShares, uint256 stTotalSupplyAfterMints)
    {
        // The pre-existing senior shares retain the senior effective NAV net of the premium and fee
        // NOTE: The waterfall enforces that (premium + fee) <= senior effective NAV, so the subtraction never underflows
        NAV_UNIT retainedSeniorNAV = (_state.stEffectiveNAV - _state.ltLiquidityPremium - _state.stProtocolFee);

        // Convert each carve-out into senior shares against the retained NAV over the pre-sync supply (the zero-NAV boundary is handled in _navToShares)
        liquidityPremiumShares = _navToShares(_state.ltLiquidityPremium, retainedSeniorNAV, _seniorTrancheTotalSupply);
        stProtocolFeeShares = _navToShares(_state.stProtocolFee, retainedSeniorNAV, _seniorTrancheTotalSupply);
        stTotalSupplyAfterMints = _seniorTrancheTotalSupply + liquidityPremiumShares + stProtocolFeeShares;
    }

    /**
     * @notice Converts a NAV value to a tranche share count, mirroring `RoycoVaultTranche._convertToShares`
     * @dev Used to compute the fair senior share count to mint when seeding the pool so it matches a tranche-side mint
     * @param _nav The NAV value being converted to shares
     * @param _totalTrancheNAV The tranche's total controlled NAV (the per-share denominator)
     * @param _totalSupply The tranche's total share supply (including any minted protocol fee shares)
     * @return shares The share count for the specified NAV value, rounded down
     */
    function _navToShares(NAV_UNIT _nav, NAV_UNIT _totalTrancheNAV, uint256 _totalSupply) internal pure returns (uint256 shares) {
        // With no shares outstanding the conversion is 1:1 with the NAV value, mirroring the tranche's first mint
        if (_totalSupply == 0) return toUint256(_nav);
        // When the total tranche NAV is zero, assume the existing supply is backed by a single NAV unit, mirroring the tranche's boundary
        shares = _totalSupply.mulDiv(_nav, (_totalTrancheNAV == ZERO_NAV_UNITS ? toNAVUnits(uint256(1)) : _totalTrancheNAV), Math.Rounding.Floor);
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
     * @notice Returns the effective net asset value (NAV) of the liquidity tranche denominated in the NAV units (USD, BTC, etc.) for this kernel
     * @dev The effective NAV is the liquidity tranche's deployed market-making inventory (its raw NAV) plus the value of the
     *      senior tranche shares it holds from accumulated, not yet reinvested, liquidity premium payments
     * @dev Reads the held senior-share count from storage, the value execution sees after the premium mint; the preview path uses
     *      the overload below to inject the post-mint count that storage does not yet reflect
     * @dev The senior NAV and share supply must be mutually consistent: the post-sync effective NAV against the
     *      post-carve-out-mint total supply, so the held senior shares are valued at the correct NAV per share
     * @param _stEffectiveNAV The senior tranche's post-sync effective NAV: the total NAV backing all senior shares after reconciling unrealized PnL
     * @param _totalSeniorTrancheShares The total senior tranche shares outstanding after minting the premium and protocol fee shares
     * @return ltEffectiveNAV The effective net asset value of the liquidity tranche
     */
    function _getLiquidityTrancheEffectiveNAV(
        NAV_UNIT _stEffectiveNAV,
        uint256 _totalSeniorTrancheShares
    )
        internal
        view
        virtual
        returns (NAV_UNIT ltEffectiveNAV)
    {
        // Value the held senior shares using the count committed to storage (the value execution sees after the premium mint)
        return _getLiquidityTrancheEffectiveNAV(_stEffectiveNAV, _totalSeniorTrancheShares, _getRoycoDayKernelStorage().ltOwnedSeniorTrancheShares);
    }

    /**
     * @notice Returns the effective net asset value of the liquidity tranche for an explicitly supplied held senior-share count
     * @dev The preview path supplies the post-mint held-share count (current storage plus this sync's premium shares) before the
     *      premium mint commits it to storage, so the previewed LT effective NAV matches the value execution computes from storage
     * @param _stEffectiveNAV The senior tranche's post-sync effective NAV: the total NAV backing all senior shares after reconciling unrealized PnL
     * @param _totalSeniorTrancheShares The total senior tranche shares outstanding after minting the premium and protocol fee shares
     * @param _ltOwnedSeniorTrancheShares The senior tranche shares held by the liquidity tranche from accumulated liquidity premium payments
     * @return ltEffectiveNAV The effective net asset value of the liquidity tranche
     */
    function _getLiquidityTrancheEffectiveNAV(
        NAV_UNIT _stEffectiveNAV,
        uint256 _totalSeniorTrancheShares,
        uint256 _ltOwnedSeniorTrancheShares
    )
        internal
        view
        virtual
        returns (NAV_UNIT ltEffectiveNAV)
    {
        // Get the value of LT's market-making inventory
        NAV_UNIT ltRawNAV = _getLiquidityTrancheRawNAV();

        // If there are no held senior shares or no senior shares outstanding, the effective NAV is just the raw NAV
        if (_ltOwnedSeniorTrancheShares == 0 || _totalSeniorTrancheShares == 0) return ltRawNAV;

        // The LT effective NAV is the sum of the NAVs of its market-making inventory and ST shares
        return (ltRawNAV + _stEffectiveNAV.mulDiv(_ltOwnedSeniorTrancheShares, _totalSeniorTrancheShares, Math.Rounding.Floor));
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
        uint256 stSharesToClaim = _claims.stShares;

        // Debit the ST assets, JT assets, LT assets, and/or ST shares being withdrawn from each tranche if non-zero
        RoycoDayKernelState storage $ = _getRoycoDayKernelStorage();
        if (stAssetsToClaim != ZERO_TRANCHE_UNITS) $.stOwnedYieldBearingAssets = $.stOwnedYieldBearingAssets - stAssetsToClaim;
        if (jtAssetsToClaim != ZERO_TRANCHE_UNITS) $.jtOwnedYieldBearingAssets = $.jtOwnedYieldBearingAssets - jtAssetsToClaim;
        if (ltAssetsToClaim != ZERO_TRANCHE_UNITS) $.ltOwnedYieldBearingAssets = $.ltOwnedYieldBearingAssets - ltAssetsToClaim;
        if (stSharesToClaim != 0) $.ltOwnedSeniorTrancheShares -= stSharesToClaim;

        // Credit the ST and JT assets being withdrawn to the receiver
        if (stAssetsToClaim + jtAssetsToClaim != ZERO_TRANCHE_UNITS) {
            // Do one batch transfer if they are the same asset, else do two separate transfers
            if (ST_ASSET == JT_ASSET) {
                IERC20(ST_ASSET).safeTransfer(_receiver, toUint256(stAssetsToClaim + jtAssetsToClaim));
            } else {
                if (stAssetsToClaim != ZERO_TRANCHE_UNITS) IERC20(ST_ASSET).safeTransfer(_receiver, toUint256(stAssetsToClaim));
                if (jtAssetsToClaim != ZERO_TRANCHE_UNITS) IERC20(JT_ASSET).safeTransfer(_receiver, toUint256(jtAssetsToClaim));
            }
        }
        // Credit the LT assets being withdrawn to the receiver
        if (ltAssetsToClaim != ZERO_TRANCHE_UNITS) IERC20(LT_ASSET).safeTransfer(_receiver, toUint256(ltAssetsToClaim));
        // Credit the senior tranche shares being withdrawn to the receiver
        if (stSharesToClaim != 0) IERC20(SENIOR_TRANCHE).safeTransfer(_receiver, stSharesToClaim);
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
        if (_state.coverageUtilizationWAD < _state.coverageLiquidationUtilizationWAD) return (_stUserClaims, ZERO_NAV_UNITS);

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
