// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IRoycoBlacklistHook } from "../../interfaces/IRoycoBlacklistHook.sol";
import { IRoycoDayAccountant } from "../../interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoDayKernelLens } from "../../interfaces/IRoycoDayKernelLens.sol";
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
 * @title RoycoDayKernelLens
 * @notice Read-only companion to `RoycoDayKernel`: it holds the entire preview/max/withdrawable surface so that
 *         bytecode lives off the kernel proxy (which is over the EIP-170 limit). It is a standalone contract that
 *         composes over the kernel's public interface — every value it needs comes from an external call on the
 *         kernel (state, conversions, raw NAVs, the composite claim/effective-NAV/self-liquidation-bonus helpers,
 *         blacklist, pause) plus shared pure math in `RoycoDayKernelMathLib`, so preview always equals execution.
 * @dev Abstract: the venue preview simulation (`_previewAddLiquidity`/`_previewRemoveLiquidity`) is venue-specific
 *      and supplied by a concrete lens (e.g. the Balancer V3 preview quoter).
 */
abstract contract RoycoDayKernelLens is IRoycoDayKernelLens {
    using UnitsMathLib for NAV_UNIT;

    /// @notice The kernel this lens reads from
    IRoycoDayKernel public immutable ROYCO_DAY_KERNEL;

    /// @dev Immutables pulled from the kernel at construction so the lens can reference them cheaply
    address internal immutable ACCOUNTANT;
    address internal immutable SENIOR_TRANCHE;
    address internal immutable JUNIOR_TRANCHE;
    address internal immutable LIQUIDITY_TRANCHE;

    /// @notice Thrown when a preview is requested while the kernel is paused (mirrors the kernel's whenNotPaused preview gate)
    error KERNEL_PAUSED();

    constructor(address _roycoDayKernel) {
        ROYCO_DAY_KERNEL = IRoycoDayKernel(_roycoDayKernel);
        ACCOUNTANT = ROYCO_DAY_KERNEL.ACCOUNTANT();
        SENIOR_TRANCHE = ROYCO_DAY_KERNEL.SENIOR_TRANCHE();
        JUNIOR_TRANCHE = ROYCO_DAY_KERNEL.JUNIOR_TRANCHE();
        LIQUIDITY_TRANCHE = ROYCO_DAY_KERNEL.LIQUIDITY_TRANCHE();
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

    /// @inheritdoc IRoycoDayKernelLens
    function previewSyncTrancheAccounting(TrancheType _trancheType)
        public
        view
        virtual
        override(IRoycoDayKernelLens)
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
        return IRoycoBlacklistHook(IRoycoVaultTranche(SENIOR_TRANCHE).hook()).isBlacklisted(_account);
    }

    // =============================
    // Tranche Preview Functions
    // =============================

    /// @inheritdoc IRoycoDayKernelLens
    function stPreviewDeposit(TRANCHE_UNIT _assets)
        public
        view
        override(IRoycoDayKernelLens)
        returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated, uint256 totalTrancheShares)
    {
        (stateBeforeDeposit,, totalTrancheShares) = previewSyncTrancheAccounting(TrancheType.SENIOR);
        valueAllocated = ROYCO_DAY_KERNEL.stConvertTrancheUnitsToNAVUnits(_assets);
    }

    /// @inheritdoc IRoycoDayKernelLens
    function jtPreviewDeposit(TRANCHE_UNIT _assets)
        public
        view
        override(IRoycoDayKernelLens)
        returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated, uint256 totalTrancheShares)
    {
        (stateBeforeDeposit,, totalTrancheShares) = previewSyncTrancheAccounting(TrancheType.JUNIOR);
        valueAllocated = ROYCO_DAY_KERNEL.jtConvertTrancheUnitsToNAVUnits(_assets);
    }

    /// @inheritdoc IRoycoDayKernelLens
    function ltPreviewDeposit(TRANCHE_UNIT _assets)
        external
        view
        override(IRoycoDayKernelLens)
        returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated, uint256 totalTrancheShares, NAV_UNIT navToMintSharesAt)
    {
        (stateBeforeDeposit,, totalTrancheShares) = previewSyncTrancheAccounting(TrancheType.LIQUIDITY);
        valueAllocated = ROYCO_DAY_KERNEL.ltConvertTrancheUnitsToNAVUnits(_assets);
        // The LT prices its shares at the pre-deposit LT effective NAV (deployed depth plus the idle premium senior shares)
        (uint256 liquidityPremiumShares,, uint256 stTotalSupplyAfterMints) =
            RoycoDayKernelMathLib.computeSTFeeAndLiquidityPremiumSharesToMint(stateBeforeDeposit, IERC20(SENIOR_TRANCHE).totalSupply());
        navToMintSharesAt = ROYCO_DAY_KERNEL.getLiquidityTrancheEffectiveNAV(
            stateBeforeDeposit.stEffectiveNAV, stTotalSupplyAfterMints, (ROYCO_DAY_KERNEL.getState().ltOwnedSeniorTrancheShares + liquidityPremiumShares)
        );
    }

    /// @inheritdoc IRoycoDayKernelLens
    function ltPreviewDepositMultiAsset(
        TRANCHE_UNIT _stAssets,
        uint256 _quoteAssets
    )
        external
        virtual
        override(IRoycoDayKernelLens)
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
            : RoycoDayKernelMathLib.navToShares(ROYCO_DAY_KERNEL.stConvertTrancheUnitsToNAVUnits(_stAssets), state.stEffectiveNAV, totalSTShares);
        // Quote the venue add for the senior shares and quote assets (simulation only: no slippage gate, no settlement)
        ltAssetsOut = _previewAddLiquidity(stSharesToAdd, _quoteAssets);
        // The value allocated is the value of the LT assets the add would mint
        valueAllocated = ROYCO_DAY_KERNEL.ltConvertTrancheUnitsToNAVUnits(ltAssetsOut);
    }

    /// @inheritdoc IRoycoDayKernelLens
    function ltPreviewRedeemMultiAsset(uint256 _ltShares)
        external
        virtual
        override(IRoycoDayKernelLens)
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

    /// @inheritdoc IRoycoDayKernelLens
    function stPreviewRedeem(uint256 _shares) public view override(IRoycoDayKernelLens) returns (AssetClaims memory userClaim) {
        (SyncedAccountingState memory state, AssetClaims memory stClaims, uint256 totalShares) = previewSyncTrancheAccounting(TrancheType.SENIOR);
        userClaim = UtilsLib.scaleAssetClaims(stClaims, _shares, totalShares);
        (userClaim,) = ROYCO_DAY_KERNEL.applySeniorTrancheSelfLiquidationBonus(state, userClaim);
    }

    /// @inheritdoc IRoycoDayKernelLens
    function jtPreviewRedeem(uint256 _shares) public view override(IRoycoDayKernelLens) returns (AssetClaims memory userClaim) {
        (, AssetClaims memory jtClaims, uint256 totalShares) = previewSyncTrancheAccounting(TrancheType.JUNIOR);
        userClaim = UtilsLib.scaleAssetClaims(jtClaims, _shares, totalShares);
    }

    /// @inheritdoc IRoycoDayKernelLens
    function ltPreviewRedeem(uint256 _shares) public view override(IRoycoDayKernelLens) returns (AssetClaims memory userClaim) {
        (SyncedAccountingState memory state, AssetClaims memory ltClaims, uint256 totalShares) = previewSyncTrancheAccounting(TrancheType.LIQUIDITY);
        // LT redemptions are disabled during a fixed-term market state: return an empty claim, matching the reverting redeem path
        if (state.marketState == MarketState.FIXED_TERM) return userClaim;
        userClaim = UtilsLib.scaleAssetClaims(ltClaims, _shares, totalShares);
    }

    // =============================
    // Tranche Max Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoDayKernelLens
    /// @dev ST deposits are allowed only in a PERPETUAL market state, granted that the market's coverage requirement is satisfied post-deposit
    function stMaxDeposit(address _receiver) public view virtual override(IRoycoDayKernelLens) returns (TRANCHE_UNIT) {
        if (_isBlacklisted(_receiver) || IPausable(address(ROYCO_DAY_KERNEL)).paused()) return ZERO_TRANCHE_UNITS;
        SyncedAccountingState memory state = _previewSyncState();
        if (state.marketState == MarketState.FIXED_TERM) return ZERO_TRANCHE_UNITS;
        NAV_UNIT stMaxDepositableNAV = IRoycoDayAccountant(ACCOUNTANT).maxSTDeposit(state);
        return ((stMaxDepositableNAV == MAX_NAV_UNITS) ? MAX_TRANCHE_UNITS : ROYCO_DAY_KERNEL.stConvertNAVUnitsToTrancheUnits(stMaxDepositableNAV));
    }

    /// @inheritdoc IRoycoDayKernelLens
    /// @dev ST redemptions are allowed in PERPETUAL market states
    function stMaxWithdrawable(address _owner)
        public
        view
        virtual
        override(IRoycoDayKernelLens)
        returns (NAV_UNIT claimOnSTNAV, NAV_UNIT claimOnJTNAV, NAV_UNIT stMaxWithdrawableNAV, NAV_UNIT jtMaxWithdrawableNAV, uint256 totalTrancheShares)
    {
        if (_isBlacklisted(_owner) || IPausable(address(ROYCO_DAY_KERNEL)).paused()) {
            return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);
        }

        SyncedAccountingState memory state;
        AssetClaims memory stClaims;
        (state, stClaims, totalTrancheShares) = previewSyncTrancheAccounting(TrancheType.SENIOR);

        if (state.marketState == MarketState.FIXED_TERM) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);

        claimOnSTNAV = ROYCO_DAY_KERNEL.stConvertTrancheUnitsToNAVUnits(stClaims.stAssets);
        claimOnJTNAV = ROYCO_DAY_KERNEL.jtConvertTrancheUnitsToNAVUnits(stClaims.jtAssets);

        (stMaxWithdrawableNAV, jtMaxWithdrawableNAV,) = ROYCO_DAY_KERNEL.getTrancheRawNAVs();
    }

    /// @inheritdoc IRoycoDayKernelLens
    /// @dev JT deposits are allowed if the market is in a PERPETUAL state
    function jtMaxDeposit(address _receiver) public view virtual override(IRoycoDayKernelLens) returns (TRANCHE_UNIT) {
        if (_isBlacklisted(_receiver) || IPausable(address(ROYCO_DAY_KERNEL)).paused()) return ZERO_TRANCHE_UNITS;
        if ((_previewSyncState()).marketState == MarketState.FIXED_TERM) return ZERO_TRANCHE_UNITS;
        return MAX_TRANCHE_UNITS;
    }

    /// @inheritdoc IRoycoDayKernelLens
    /// @dev JT redemptions are allowed only in a PERPETUAL market state, granted that the market's coverage requirement is satisfied post-redemption
    function jtMaxWithdrawable(address _owner)
        public
        view
        virtual
        override(IRoycoDayKernelLens)
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

    /// @inheritdoc IRoycoDayKernelLens
    /// @dev An in-kind LT deposit mints no new senior shares and only deepens liquidity, so it is enabled in every market state and unbounded
    function ltMaxDeposit(address _receiver) public view virtual override(IRoycoDayKernelLens) returns (TRANCHE_UNIT) {
        if (_isBlacklisted(_receiver) || IPausable(address(ROYCO_DAY_KERNEL)).paused()) return ZERO_TRANCHE_UNITS;
        return MAX_TRANCHE_UNITS;
    }

    /// @inheritdoc IRoycoDayKernelLens
    function ltMaxWithdrawable(address _owner)
        public
        view
        virtual
        override(IRoycoDayKernelLens)
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
