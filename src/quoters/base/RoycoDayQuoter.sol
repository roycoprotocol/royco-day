// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { RoycoBase } from "../../base/RoycoBase.sol";
import { IRoycoBlacklistHook } from "../../interfaces/IRoycoBlacklistHook.sol";
import { IRoycoDayAccountant } from "../../interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoDayQuoter } from "../../interfaces/IRoycoDayQuoter.sol";
import { IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { MAX_NAV_UNITS, MAX_TRANCHE_UNITS, WAD, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../../libraries/Constants.sol";
import { RoycoDayKernelMathLib } from "../../libraries/RoycoDayKernelMathLib.sol";
import { AssetClaims, MarketState, SyncedAccountingState, TrancheType } from "../../libraries/Types.sol";
import { Math, NAV_UNIT, TRANCHE_UNIT, UnitsMathLib } from "../../libraries/Units.sol";
import { UtilsLib } from "../../libraries/UtilsLib.sol";

/// @dev Minimal view of the kernel's OZ Pausable surface, kept local so the lens can read the kernel's pause state
///      without widening `IRoycoDayKernel` (which would force a diamond override on the kernel).
interface IPausable {
    function paused() external view returns (bool);
}

/**
 * @title RoycoDayQuoter
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Abstract base for all Royco Day quoters: the view-only companion that prices a market's tranche assets and
 *         holds its entire preview/max/withdrawable surface, so that bytecode lives off the kernel proxy (which is over
 *         the EIP-170 limit). It owns the tranche-unit to NAV-unit conversions and the per-operation rate caches (driven
 *         by the kernel), and reads the kernel's committed state (state, raw NAVs, the composite claim/effective-NAV/
 *         self-liquidation-bonus helpers, blacklist, pause) plus shared pure math in `RoycoDayKernelMathLib`, so preview
 *         always equals execution.
 * @dev Abstract: the tranche-asset conversions are supplied by a concrete ST/JT and liquidity-tranche quoter, and the
 *      venue preview simulation (`_previewAddLiquidity`/`_previewRemoveLiquidity`) is venue-specific.
 */
abstract contract RoycoDayQuoter is RoycoBase, IRoycoDayQuoter {
    using UnitsMathLib for NAV_UNIT;

    /// @dev The top bit set on a transient cache slot to mark it populated, shared by every quoter's transient rate cache so a set slot is distinguishable from an unset one
    uint256 internal constant CACHE_SET_MASK = 1 << 255;

    /// @dev The kernel this quoter prices and reads its committed state from
    IRoycoDayKernel internal immutable ROYCO_DAY_KERNEL;

    /// @dev Immutables pulled from the kernel at construction so the quoter can reference them cheaply
    address internal immutable ACCOUNTANT;
    address internal immutable SENIOR_TRANCHE;
    address internal immutable JUNIOR_TRANCHE;
    address internal immutable LIQUIDITY_TRANCHE;
    address internal immutable ST_ASSET;
    address internal immutable JT_ASSET;
    address internal immutable LT_ASSET;

    /// @notice Thrown when a preview is requested while the kernel is paused (mirrors the kernel's whenNotPaused preview gate)
    error KERNEL_PAUSED();

    /// @notice Thrown when the caller of a kernel-only function isn't the kernel paired with this quoter
    error ONLY_KERNEL();

    /// @dev Permissions the function to only be callable by the kernel paired with this quoter
    modifier onlyKernel() {
        require(msg.sender == address(ROYCO_DAY_KERNEL), ONLY_KERNEL());
        _;
    }

    constructor(address _roycoDayKernel) {
        ROYCO_DAY_KERNEL = IRoycoDayKernel(_roycoDayKernel);
        ACCOUNTANT = ROYCO_DAY_KERNEL.ACCOUNTANT();
        SENIOR_TRANCHE = ROYCO_DAY_KERNEL.SENIOR_TRANCHE();
        JUNIOR_TRANCHE = ROYCO_DAY_KERNEL.JUNIOR_TRANCHE();
        LIQUIDITY_TRANCHE = ROYCO_DAY_KERNEL.LIQUIDITY_TRANCHE();
        ST_ASSET = ROYCO_DAY_KERNEL.ST_ASSET();
        JT_ASSET = ROYCO_DAY_KERNEL.JT_ASSET();
        LT_ASSET = ROYCO_DAY_KERNEL.LT_ASSET();
    }

    /// @inheritdoc IRoycoDayQuoter
    function KERNEL() external view override(IRoycoDayQuoter) returns (address kernel) {
        return address(ROYCO_DAY_KERNEL);
    }

    // =============================
    // Tranche Asset Quoter Functions (implemented by the concrete ST/JT and liquidity-tranche quoters)
    // =============================

    /// @inheritdoc IRoycoDayQuoter
    function stConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _stAssets) public view virtual override(IRoycoDayQuoter) returns (NAV_UNIT);

    /// @inheritdoc IRoycoDayQuoter
    function jtConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _jtAssets) public view virtual override(IRoycoDayQuoter) returns (NAV_UNIT);

    /// @inheritdoc IRoycoDayQuoter
    function ltConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _ltAssets) public view virtual override(IRoycoDayQuoter) returns (NAV_UNIT);

    /// @inheritdoc IRoycoDayQuoter
    function stConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) public view virtual override(IRoycoDayQuoter) returns (TRANCHE_UNIT);

    /// @inheritdoc IRoycoDayQuoter
    function jtConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) public view virtual override(IRoycoDayQuoter) returns (TRANCHE_UNIT);

    /// @inheritdoc IRoycoDayQuoter
    function ltConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) public view virtual override(IRoycoDayQuoter) returns (TRANCHE_UNIT);

    // =============================
    // Quoter Cache Functions (kernel-driven; overridden by a caching quoter)
    // =============================

    /// @inheritdoc IRoycoDayQuoter
    function initializeQuoterCache() external override(IRoycoDayQuoter) onlyKernel {
        _initializeQuoterCache();
    }

    /// @inheritdoc IRoycoDayQuoter
    function clearQuoterCache() external override(IRoycoDayQuoter) onlyKernel {
        _clearQuoterCache();
    }

    /// @inheritdoc IRoycoDayQuoter
    function cacheSTShareRate(NAV_UNIT _stEffectiveNAV, uint256 _stTotalSupplyAfterMints) external override(IRoycoDayQuoter) onlyKernel {
        _cacheSTShareRate(_stEffectiveNAV, _stTotalSupplyAfterMints);
    }

    /// @notice Initializes the quoter's per-operation cache
    /// @dev Intentionally implemented with an empty body since inheriting contracts are not required to override this function: the cache is a pure optimization and quoters that do not cache read live
    function _initializeQuoterCache() internal virtual { }

    /// @notice Clears the quoter's per-operation cache
    /// @dev Intentionally implemented with an empty body since inheriting contracts are not required to override this function: the cache is a pure optimization and quoters that do not cache read live
    function _clearQuoterCache() internal virtual { }

    /// @notice Caches the senior tranche share rate resolved by a pre-op synchronization for the duration of the operation
    /// @dev Intentionally implemented with an empty body since inheriting contracts are not required to override this function: only a quoter whose liquidity venue prices the senior share through a rate provider needs to freeze it
    function _cacheSTShareRate(NAV_UNIT _stEffectiveNAV, uint256 _stTotalSupplyAfterMints) internal virtual { }

    /**
     * @notice Decodes a transient cache slot into its populated flag and stored value
     * @dev The single primitive shared by every quoter's transient rate cache: the top bit (CACHE_SET_MASK) marks a populated slot and the remaining bits hold the value, so an unset slot (zero) reads as a miss and a value is encoded for storage as `value | CACHE_SET_MASK`
     * @param _cacheSlot The raw value read from a transient cache slot
     * @return cacheHit Whether the slot holds a populated value
     * @return value The cached value when cacheHit is true, otherwise zero
     */
    function _decodeCachedValue(uint256 _cacheSlot) internal pure returns (bool cacheHit, uint256 value) {
        if (_cacheSlot & CACHE_SET_MASK != 0) return (true, _cacheSlot ^ CACHE_SET_MASK);
    }

    // =============================
    // Venue preview hooks (implemented by the concrete, venue-specific lens)
    // =============================

    /// @notice Preview counterpart of the kernel's `_addLiquidity`: simulates the venue add and returns the LT assets it would mint
    function _previewAddLiquidity(uint256 _seniorShares, uint256 _quoteAssets) internal virtual returns (TRANCHE_UNIT ltAssets);

    /// @notice Preview counterpart of the kernel's `_removeLiquidity`: simulates the proportional removal and returns the constituents it would withdraw
    function _previewRemoveLiquidity(TRANCHE_UNIT _ltAssets) internal virtual returns (uint256 stShares, uint256 quoteAssets);

    // =============================
    // Preview Sync
    // =============================

    /// @inheritdoc IRoycoDayQuoter
    function previewSyncTrancheAccounting(TrancheType _trancheType)
        public
        view
        virtual
        override(IRoycoDayQuoter)
        returns (SyncedAccountingState memory state, AssetClaims memory claims, uint256 totalTrancheShares)
    {
        // Preview an accounting sync (senior/junior via the accountant, then refresh the LT raw NAV + liquidity utilization in memory)
        state = _previewSyncState();

        // Derive the asset claims for this tranche via the shared library (conversions injected as external kernel calls)
        claims = ROYCO_DAY_KERNEL.deriveTrancheAssetClaims(_trancheType, state);

        // Return the requested tranche's total shares after this sync mints its premium and protocol fee shares
        if (_trancheType == TrancheType.SENIOR) {
            // Compute ST share supply after the liquidity premium and the ST protocol fee shares are minted
            (,, totalTrancheShares) = RoycoDayKernelMathLib.computeSTFeeAndLiquidityPremiumSharesToMint(state, IERC20(SENIOR_TRANCHE).totalSupply());
        } else if (_trancheType == TrancheType.JUNIOR) {
            // Compute JT share supply after the JT protocol fee shares are minted
            uint256 jtTotalSupply = IERC20(JUNIOR_TRANCHE).totalSupply();
            totalTrancheShares =
                jtTotalSupply + RoycoDayKernelMathLib.navToShares(state.jtProtocolFee, (state.jtEffectiveNAV - state.jtProtocolFee), jtTotalSupply);
        } else {
            // Compute LT share supply after the LT protocol fee shares are minted, valuing the LT against its post-mint held senior shares
            (uint256 liquidityPremiumShares,, uint256 stTotalSupplyAfterMints) =
                RoycoDayKernelMathLib.computeSTFeeAndLiquidityPremiumSharesToMint(state, IERC20(SENIOR_TRANCHE).totalSupply());
            // Update the simulated post-mint ST shares owned by LT (storage count plus this sync's premium shares)
            uint256 ltOwnedSeniorTrancheShares = ROYCO_DAY_KERNEL.getState().ltOwnedSeniorTrancheShares + liquidityPremiumShares;
            claims.stShares = ltOwnedSeniorTrancheShares;
            NAV_UNIT ltEffectiveNAV =
                ROYCO_DAY_KERNEL.getLiquidityTrancheEffectiveNAV(state.stEffectiveNAV, stTotalSupplyAfterMints, ltOwnedSeniorTrancheShares);
            uint256 ltTotalSupply = IERC20(LIQUIDITY_TRANCHE).totalSupply();
            totalTrancheShares = ltTotalSupply + RoycoDayKernelMathLib.navToShares(state.ltProtocolFee, (ltEffectiveNAV - state.ltProtocolFee), ltTotalSupply);
        }
    }

    /// @dev Previews the senior/junior accounting sync via the accountant, then refreshes the LT raw NAV and liquidity
    ///      utilization in memory so the preview mirrors execution. Reverts while the kernel is paused (its preview gate).
    function _previewSyncState() internal view returns (SyncedAccountingState memory state) {
        if (IPausable(address(ROYCO_DAY_KERNEL)).paused()) revert KERNEL_PAUSED();
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, NAV_UNIT ltRawNAV) = ROYCO_DAY_KERNEL.getTrancheRawNAVs();
        state = IRoycoDayAccountant(ACCOUNTANT).previewSyncTrancheAccounting(stRawNAV, jtRawNAV);
        state.ltRawNAV = ltRawNAV;
        state.liquidityUtilizationWAD = UtilsLib.computeLiquidityUtilization(state.stEffectiveNAV, state.minLiquidityWAD, state.ltRawNAV);
    }

    /// @dev Whether an account is blacklisted, read from the market's tranche balance-update hook (all tranches share it, so read the senior tranche's)
    function _isBlacklisted(address _account) internal view returns (bool) {
        return IRoycoBlacklistHook(IRoycoVaultTranche(SENIOR_TRANCHE).HOOK()).isBlacklisted(_account);
    }

    // =============================
    // Tranche Preview Functions
    // =============================

    /// @inheritdoc IRoycoDayQuoter
    function stPreviewDeposit(TRANCHE_UNIT _assets)
        public
        view
        override(IRoycoDayQuoter)
        returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated, uint256 totalTrancheShares)
    {
        (stateBeforeDeposit,, totalTrancheShares) = previewSyncTrancheAccounting(TrancheType.SENIOR);
        valueAllocated = stConvertTrancheUnitsToNAVUnits(_assets);
    }

    /// @inheritdoc IRoycoDayQuoter
    function jtPreviewDeposit(TRANCHE_UNIT _assets)
        public
        view
        override(IRoycoDayQuoter)
        returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated, uint256 totalTrancheShares)
    {
        (stateBeforeDeposit,, totalTrancheShares) = previewSyncTrancheAccounting(TrancheType.JUNIOR);
        valueAllocated = jtConvertTrancheUnitsToNAVUnits(_assets);
    }

    /// @inheritdoc IRoycoDayQuoter
    function ltPreviewDeposit(TRANCHE_UNIT _assets)
        external
        view
        override(IRoycoDayQuoter)
        returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated, uint256 totalTrancheShares, NAV_UNIT navToMintSharesAt)
    {
        (stateBeforeDeposit,, totalTrancheShares) = previewSyncTrancheAccounting(TrancheType.LIQUIDITY);
        valueAllocated = ltConvertTrancheUnitsToNAVUnits(_assets);
        // The LT prices its shares at the pre-deposit LT effective NAV (deployed depth plus the idle premium senior shares)
        (uint256 liquidityPremiumShares,, uint256 stTotalSupplyAfterMints) =
            RoycoDayKernelMathLib.computeSTFeeAndLiquidityPremiumSharesToMint(stateBeforeDeposit, IERC20(SENIOR_TRANCHE).totalSupply());
        navToMintSharesAt = ROYCO_DAY_KERNEL.getLiquidityTrancheEffectiveNAV(
            stateBeforeDeposit.stEffectiveNAV, stTotalSupplyAfterMints, (ROYCO_DAY_KERNEL.getState().ltOwnedSeniorTrancheShares + liquidityPremiumShares)
        );
    }

    /// @inheritdoc IRoycoDayQuoter
    function ltPreviewDepositMultiAsset(
        TRANCHE_UNIT _stAssets,
        uint256 _quoteAssets
    )
        external
        virtual
        override(IRoycoDayQuoter)
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt, TRANCHE_UNIT ltAssetsOut)
    {
        // Preview the senior sync and its post-mint supply (after the liquidity premium and protocol fee shares), exactly as ltDepositMultiAsset reads them
        (SyncedAccountingState memory state,, uint256 totalSTShares) = previewSyncTrancheAccounting(TrancheType.SENIOR);
        // During a fixed-term market state only a quote-only deposit is permitted; an ST-leg deposit reverts, so return zero before quoting the venue add to match it
        if (state.marketState == MarketState.FIXED_TERM && _stAssets != ZERO_TRANCHE_UNITS) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS);
        // The NAV to mint LT shares at is the pre-deposit LT effective NAV (market-making depth plus the idle premium senior shares)
        (uint256 liquidityPremiumShares,,) = RoycoDayKernelMathLib.computeSTFeeAndLiquidityPremiumSharesToMint(state, IERC20(SENIOR_TRANCHE).totalSupply());
        navToMintSharesAt = ROYCO_DAY_KERNEL.getLiquidityTrancheEffectiveNAV(
            state.stEffectiveNAV, totalSTShares, (ROYCO_DAY_KERNEL.getState().ltOwnedSeniorTrancheShares + liquidityPremiumShares)
        );
        // Size the senior shares the ST leg would mint (zero if no ST underlying is supplied), priced like the execution path
        uint256 stSharesToAdd = _stAssets == ZERO_TRANCHE_UNITS
            ? 0
            : RoycoDayKernelMathLib.navToShares(stConvertTrancheUnitsToNAVUnits(_stAssets), state.stEffectiveNAV, totalSTShares);
        // Quote the venue add for the senior shares and quote assets (simulation only: no slippage gate, no settlement)
        ltAssetsOut = _previewAddLiquidity(stSharesToAdd, _quoteAssets);
        // The value allocated is the value of the LT assets the add would mint
        valueAllocated = ltConvertTrancheUnitsToNAVUnits(ltAssetsOut);
    }

    /// @inheritdoc IRoycoDayQuoter
    function ltPreviewRedeemMultiAsset(uint256 _ltShares)
        external
        virtual
        override(IRoycoDayQuoter)
        returns (AssetClaims memory stClaims, uint256 quoteAssets)
    {
        // Preview the liquidity tranche sync
        (SyncedAccountingState memory state, AssetClaims memory ltClaims, uint256 totalLTShares) = previewSyncTrancheAccounting(TrancheType.LIQUIDITY);
        // Multi-asset redemptions are disabled during a fixed-term market state: return empty claims, matching the reverting redeem path
        if (state.marketState == MarketState.FIXED_TERM) return (stClaims, 0);

        // An LT share claims both LT effective-NAV legs: the deployed LT assets and the idle liquidity-premium senior shares
        AssetClaims memory userAssetClaims = UtilsLib.scaleAssetClaims(ltClaims, _ltShares, totalLTShares);

        // Derive the ST total claims from the synced state, and the senior supply AFTER this sync mints the premium and ST protocol fee shares.
        // The execution path reads totalSupply() after the pre-op sync has minted those shares, so the preview must use the same post-mint supply
        stClaims = ROYCO_DAY_KERNEL.deriveTrancheAssetClaims(TrancheType.SENIOR, state);
        (,, uint256 totalSTShares) = RoycoDayKernelMathLib.computeSTFeeAndLiquidityPremiumSharesToMint(state, IERC20(SENIOR_TRANCHE).totalSupply());

        // Quote the proportional venue removal for the LT-asset slice (simulation only: no slippage gate, no settlement)
        uint256 stSharesWithdrawn;
        if (userAssetClaims.ltAssets != ZERO_TRANCHE_UNITS) (stSharesWithdrawn, quoteAssets) = _previewRemoveLiquidity(userAssetClaims.ltAssets);

        // The redeemer's senior shares come from both the venue removal and the idle premium pile
        uint256 stSharesToRedeem = stSharesWithdrawn + userAssetClaims.stShares;
        stClaims = UtilsLib.scaleAssetClaims(stClaims, stSharesToRedeem, totalSTShares);

        // Apply any ST self-liquidation bonus to the redeeming user's ST shares claims, mirroring the execution path
        (stClaims,) = ROYCO_DAY_KERNEL.applySeniorTrancheSelfLiquidationBonus(state, stClaims);
    }

    /// @inheritdoc IRoycoDayQuoter
    function stPreviewRedeem(uint256 _shares) public view override(IRoycoDayQuoter) returns (AssetClaims memory userClaim) {
        (SyncedAccountingState memory state, AssetClaims memory stClaims, uint256 totalShares) = previewSyncTrancheAccounting(TrancheType.SENIOR);
        userClaim = UtilsLib.scaleAssetClaims(stClaims, _shares, totalShares);
        (userClaim,) = ROYCO_DAY_KERNEL.applySeniorTrancheSelfLiquidationBonus(state, userClaim);
    }

    /// @inheritdoc IRoycoDayQuoter
    function jtPreviewRedeem(uint256 _shares) public view override(IRoycoDayQuoter) returns (AssetClaims memory userClaim) {
        (, AssetClaims memory jtClaims, uint256 totalShares) = previewSyncTrancheAccounting(TrancheType.JUNIOR);
        userClaim = UtilsLib.scaleAssetClaims(jtClaims, _shares, totalShares);
    }

    /// @inheritdoc IRoycoDayQuoter
    function ltPreviewRedeem(uint256 _shares) public view override(IRoycoDayQuoter) returns (AssetClaims memory userClaim) {
        (SyncedAccountingState memory state, AssetClaims memory ltClaims, uint256 totalShares) = previewSyncTrancheAccounting(TrancheType.LIQUIDITY);
        // LT redemptions are disabled during a fixed-term market state: return an empty claim, matching the reverting redeem path
        if (state.marketState == MarketState.FIXED_TERM) return userClaim;
        userClaim = UtilsLib.scaleAssetClaims(ltClaims, _shares, totalShares);
    }

    // =============================
    // Tranche Max Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoDayQuoter
    /// @dev ST deposits are allowed only in a PERPETUAL market state, granted that the market's coverage requirement is satisfied post-deposit
    function stMaxDeposit(address _receiver) public view virtual override(IRoycoDayQuoter) returns (TRANCHE_UNIT) {
        if (_isBlacklisted(_receiver) || IPausable(address(ROYCO_DAY_KERNEL)).paused()) return ZERO_TRANCHE_UNITS;
        SyncedAccountingState memory state = _previewSyncState();
        if (state.marketState == MarketState.FIXED_TERM) return ZERO_TRANCHE_UNITS;
        NAV_UNIT stMaxDepositableNAV = IRoycoDayAccountant(ACCOUNTANT).maxSTDeposit(state);
        return ((stMaxDepositableNAV == MAX_NAV_UNITS) ? MAX_TRANCHE_UNITS : stConvertNAVUnitsToTrancheUnits(stMaxDepositableNAV));
    }

    /// @inheritdoc IRoycoDayQuoter
    /// @dev ST redemptions are allowed in PERPETUAL market states
    function stMaxWithdrawable(address _owner)
        public
        view
        virtual
        override(IRoycoDayQuoter)
        returns (NAV_UNIT claimOnSTNAV, NAV_UNIT claimOnJTNAV, NAV_UNIT stMaxWithdrawableNAV, NAV_UNIT jtMaxWithdrawableNAV, uint256 totalTrancheShares)
    {
        if (_isBlacklisted(_owner) || IPausable(address(ROYCO_DAY_KERNEL)).paused()) {
            return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);
        }

        SyncedAccountingState memory state;
        AssetClaims memory stClaims;
        (state, stClaims, totalTrancheShares) = previewSyncTrancheAccounting(TrancheType.SENIOR);

        if (state.marketState == MarketState.FIXED_TERM) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);

        claimOnSTNAV = stConvertTrancheUnitsToNAVUnits(stClaims.stAssets);
        claimOnJTNAV = jtConvertTrancheUnitsToNAVUnits(stClaims.jtAssets);

        (stMaxWithdrawableNAV, jtMaxWithdrawableNAV,) = ROYCO_DAY_KERNEL.getTrancheRawNAVs();
    }

    /// @inheritdoc IRoycoDayQuoter
    /// @dev JT deposits are allowed if the market is in a PERPETUAL state
    function jtMaxDeposit(address _receiver) public view virtual override(IRoycoDayQuoter) returns (TRANCHE_UNIT) {
        if (_isBlacklisted(_receiver) || IPausable(address(ROYCO_DAY_KERNEL)).paused()) return ZERO_TRANCHE_UNITS;
        if ((_previewSyncState()).marketState == MarketState.FIXED_TERM) return ZERO_TRANCHE_UNITS;
        return MAX_TRANCHE_UNITS;
    }

    /// @inheritdoc IRoycoDayQuoter
    /// @dev JT redemptions are allowed only in a PERPETUAL market state, granted that the market's coverage requirement is satisfied post-redemption
    function jtMaxWithdrawable(address _owner)
        public
        view
        virtual
        override(IRoycoDayQuoter)
        returns (NAV_UNIT claimOnSTNAV, NAV_UNIT claimOnJTNAV, NAV_UNIT stMaxWithdrawableNAV, NAV_UNIT jtMaxWithdrawableNAV, uint256 totalTrancheShares)
    {
        if (_isBlacklisted(_owner) || IPausable(address(ROYCO_DAY_KERNEL)).paused()) {
            return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);
        }

        SyncedAccountingState memory state;
        (state,, totalTrancheShares) = previewSyncTrancheAccounting(TrancheType.JUNIOR);

        if (state.marketState == MarketState.FIXED_TERM) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);

        // Use the precise NAV claims directly from the decomposition instead of round-tripping them through tranche units
        (,, claimOnSTNAV, claimOnJTNAV) = UtilsLib.computeSTandJTClaimsOnNAV(state);

        // Get the max withdrawable ST and JT assets in NAV units from the accountant considering the coverage requirement
        (stMaxWithdrawableNAV, jtMaxWithdrawableNAV) = IRoycoDayAccountant(ACCOUNTANT).maxJTWithdrawal(state);
    }

    /// @inheritdoc IRoycoDayQuoter
    /// @dev An in-kind LT deposit mints no new senior shares and only deepens liquidity, so it is enabled in every market state and unbounded
    function ltMaxDeposit(address _receiver) public view virtual override(IRoycoDayQuoter) returns (TRANCHE_UNIT) {
        if (_isBlacklisted(_receiver) || IPausable(address(ROYCO_DAY_KERNEL)).paused()) return ZERO_TRANCHE_UNITS;
        return MAX_TRANCHE_UNITS;
    }

    /// @inheritdoc IRoycoDayQuoter
    function ltMaxWithdrawable(address _owner)
        public
        view
        virtual
        override(IRoycoDayQuoter)
        returns (NAV_UNIT claimOnLTNAV, NAV_UNIT ltMaxWithdrawableNAV, uint256 totalTrancheShares)
    {
        if (_isBlacklisted(_owner) || IPausable(address(ROYCO_DAY_KERNEL)).paused()) {
            return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);
        }

        SyncedAccountingState memory state;
        (state,, totalTrancheShares) = previewSyncTrancheAccounting(TrancheType.LIQUIDITY);

        if (state.marketState == MarketState.FIXED_TERM) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);

        // An in-kind redemption pulls a proportional slice of both LT legs, bounded by the market's liquidity requirement
        claimOnLTNAV = state.ltRawNAV;
        ltMaxWithdrawableNAV = IRoycoDayAccountant(ACCOUNTANT).maxLTWithdrawal(state);
    }
}
