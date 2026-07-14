// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import {
    AddLiquidityKind,
    AddLiquidityParams,
    RemoveLiquidityKind,
    RemoveLiquidityParams
} from "../../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { IERC20 } from "../../../../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "../../../../../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { IRoycoDayKernel } from "../../../../../../interfaces/IRoycoDayKernel.sol";
import { WAD, ZERO_TRANCHE_UNITS } from "../../../../../../libraries/Constants.sol";
import { Math, NAV_UNIT, RoycoUnitsMath, TRANCHE_UNIT, toUint256 } from "../../../../../../libraries/Units.sol";
import { ValuationLogic } from "../../../../../../libraries/logic/ValuationLogic.sol";
import { IBalancerV3VenueCallbacks } from "../interfaces/IBalancerV3VenueCallbacks.sol";

/**
 * @notice The immutable liquidity venue configuration a delegatecalled venue logic function needs, carried in from the kernel mixin
 * @custom:field vault - The Balancer V3 Vault the kernel's pool is registered with
 * @custom:field ltAsset - The liquidity tranche asset (the Balancer Pool Token) the kernel custodies
 * @custom:field seniorTranche - The senior tranche share token, one of the pool's two constituents
 * @custom:field quoteAsset - The quote asset, the pool's other constituent
 * @custom:field stSharePoolIndex - The senior tranche share token's index in the pool's token registration order
 * @custom:field quoteAssetPoolIndex - The quote asset's index in the pool's token registration order
 */
struct BalancerV3VenueImmutableState {
    IVault vault;
    address ltAsset;
    address seniorTranche;
    address quoteAsset;
    uint256 stSharePoolIndex;
    uint256 quoteAssetPoolIndex;
}

/**
 * @title BalancerV3VenueLogic
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Externalized Balancer V3 liquidity tranche venue logic delegatecalled by the kernel's BalancerV3_LT_BPTOracle_Quoter mixin
 */
library BalancerV3VenueLogic {
    using RoycoUnitsMath for NAV_UNIT;
    using RoycoUnitsMath for TRANCHE_UNIT;
    using SafeERC20 for IERC20;

    /// @notice Carries a previewed add's minted BPT out of the vault callback, unwinding the preview's transient accounting
    error PREVIEW_ADD_LIQUIDITY_RESULT(uint256 ltAssets);

    /// @notice Carries a previewed removal's withdrawn constituents out of the vault callback, unwinding the preview's transient accounting
    error PREVIEW_REMOVE_LIQUIDITY_RESULT(uint256 stShares, uint256 quoteAssets);

    /**
     * @notice Callback that performs the unbalanced BPT mint inside the unlocked Balancer V3 Vault's context
     * @dev Only callable by the Balancer V3 Vault
     * @dev This callback must settle all credit and debt created in the vault's accounting by the end of its execution
     * @dev The kernel supplies the senior tranche shares and quote assets it already holds and receives the minted BPT for the liquidity tranche
     * @param _isPreview Whether this is a preview, which computes the amounts under the Vault's real semantics and unwinds by reverting with the result instead of settling
     * @param _seniorShares The exact amount of senior tranche shares to add into the pool from this kernel's balance
     * @param _quoteAssets The exact amount of quote assets to add into the pool from this kernel's balance
     * @param _minLTAssetsOut The minimum BPT (LT assets) that must be minted, bounding the add's slippage at the Vault
     * @return ltAssets The BPT (LT assets) minted to this kernel by the add
     */
    function addBalancerV3Liquidity(
        BalancerV3VenueImmutableState memory _venue,
        bool _isPreview,
        uint256 _seniorShares,
        uint256 _quoteAssets,
        TRANCHE_UNIT _minLTAssetsOut
    )
        external
        returns (uint256 ltAssets)
    {
        // The exact senior tranche share and quote asset amounts to add, ordered by the pool's token registration
        uint256[] memory exactAmountsIn = new uint256[](2);
        exactAmountsIn[_venue.stSharePoolIndex] = _seniorShares;
        exactAmountsIn[_venue.quoteAssetPoolIndex] = _quoteAssets;

        // Credit this kernel with the BPT minted by the unbalanced add of the specified senior tranche shares and quote assets
        (, ltAssets,) = _venue.vault
            .addLiquidity(
                AddLiquidityParams({
                    pool: _venue.ltAsset, // The Balancer pool to add liquidity to is the liquidity tranche's asset (BPT)
                    to: address(this), // The kernel custodies the BPT balance of the entire liquidity tranche, so the minted BPT is credited to it
                    maxAmountsIn: exactAmountsIn, // For UNBALANCED adds the Vault treats these as the exact amounts in (not upper bounds)
                    minBptAmountOut: toUint256(_minLTAssetsOut), // The Vault reverts the add if it would mint fewer BPT than this, bounding the add's slippage
                    kind: AddLiquidityKind.UNBALANCED, // Unbalanced add: the Vault charges the pool's swap fee on the imbalanced portion
                    userData: "" // UNBALANCED adds skip the pool's compute callback and this kernel's hooks do not consume userData
                })
            );

        // A preview carries its result out via this revert, unwinding every transient balance change before settlement is due
        if (_isPreview) revert PREVIEW_ADD_LIQUIDITY_RESULT(ltAssets);

        // Settle the senior tranche shares and quote assets this kernel owes the Vault for the add by transferring them in and cancelling the debt
        if (_seniorShares > 0) {
            IERC20(_venue.seniorTranche).safeTransfer(address(_venue.vault), _seniorShares);
            _venue.vault.settle(IERC20(_venue.seniorTranche), _seniorShares);
        }
        if (_quoteAssets > 0) {
            IERC20(_venue.quoteAsset).safeTransfer(address(_venue.vault), _quoteAssets);
            _venue.vault.settle(IERC20(_venue.quoteAsset), _quoteAssets);
        }
        /// @dev All credit and debt created during this callback has been settled
    }

    /**
     * @notice Callback that performs the proportional BPT unwrap inside the unlocked Balancer V3 Vault's context
     * @dev Only callable by the Balancer V3 Vault
     * @dev This callback must settle all credit and debt created in the vault's accounting by the end of its execution
     * @dev The kernel receives any ST shares withdrawn and is responsible for converting them to the base assets before remitting them to the user
     * @param _isPreview Whether this is a preview, which computes the amounts under the Vault's real semantics and unwinds by reverting with the result instead of settling
     * @param _ltAssets The exact BPT amount (LT assets) to burn from this kernel's balance
     * @param _minSTSharesOut The minimum senior tranche shares that must be withdrawn, bounding the removal's slippage at the Vault
     * @param _minQuoteAssetsOut The minimum quote assets that must be withdrawn, bounding the removal's slippage at the Vault
     * @param _quoteAssetsReceiver The recipient of the quote assets withdrawn
     * @return stShares The senior tranche shares withdrawn back to this kernel by the unwrap
     * @return quoteAssets The quote assets withdrawn directly to the specified receiver
     */
    function removeBalancerV3Liquidity(
        BalancerV3VenueImmutableState memory _venue,
        bool _isPreview,
        TRANCHE_UNIT _ltAssets,
        uint256 _minSTSharesOut,
        uint256 _minQuoteAssetsOut,
        address _quoteAssetsReceiver
    )
        external
        returns (uint256 stShares, uint256 quoteAssets)
    {
        // The minimum senior tranche share and quote asset amounts out, ordered by the pool's token registration
        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[_venue.stSharePoolIndex] = _minSTSharesOut;
        minAmountsOut[_venue.quoteAssetPoolIndex] = _minQuoteAssetsOut;

        // Debit this kernel with the proportional constituent claims tied to the specified amount of LT assets
        (, uint256[] memory amountsOut,) = _venue.vault
            .removeLiquidity(
                RemoveLiquidityParams({
                    pool: _venue.ltAsset, // The Balancer pool to remove liquidity from is the liquidity tranche's asset (BPT)
                    from: address(this), // The kernel custodies the BPT balance of the entire liquidity tranche, so the BPT constituents are debited from its claims
                    maxBptAmountIn: toUint256(_ltAssets), // For PROPORTIONAL removals the Vault treats this as the exact BPT amount to burn (not an upper bound)
                    minAmountsOut: minAmountsOut, // The Vault reverts the removal if any constituent comes out below these floors, bounding the removal's slippage
                    kind: RemoveLiquidityKind.PROPORTIONAL, // Proportional removals preserve the pool's composition, so the unwrap requires no pricing
                    userData: "" // PROPORTIONAL removals skip the pool's compute callback and this kernel's hooks do not consume userData
                })
            );

        // Set the amounts out to be returned to the caller
        stShares = amountsOut[_venue.stSharePoolIndex];
        quoteAssets = amountsOut[_venue.quoteAssetPoolIndex];

        // A preview carries its result out via this revert, unwinding every transient balance change before settlement is due
        if (_isPreview) revert PREVIEW_REMOVE_LIQUIDITY_RESULT(stShares, quoteAssets);

        // Credit the ST shares withdrawn to the kernel for downstream redemption before remitting assets to the user
        if (stShares > 0) _venue.vault.sendTo(IERC20(_venue.seniorTranche), address(this), stShares);
        // Credit the quote assets withdrawn to its specified receiver
        if (quoteAssets > 0) _venue.vault.sendTo(IERC20(_venue.quoteAsset), _quoteAssetsReceiver, quoteAssets);
        /// @dev All credit and debt created during this callback has been settled
    }

    /**
     * @notice Attempts to reinvest the liquidity tranche's idle liquidity-premium senior shares into its market-making inventory
     * @dev Tolerates reversions gracefully so it is non-blocking for the tranche operation that invokes it
     * @param _stSharesToReinvest The amount of idle liquidity-premium senior shares to reinvest, or type(uint256).max to reinvest the entire idle balance
     * @param _stEffectiveNAV The synced senior tranche effective NAV used to value the liquidity tranche's idle premium senior shares
     * @param _totalSTShares The senior tranche share supply after the liquidity premium and senior tranche protocol fee shares are minted, the denominator of the senior share rate
     */
    function attemptLiquidityPremiumReinvestment(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        BalancerV3VenueImmutableState memory _venue,
        uint64 _maxReinvestmentSlippageWAD,
        uint256 _stSharesToReinvest,
        NAV_UNIT _stEffectiveNAV,
        uint256 _totalSTShares
    )
        external
    {
        // Deploy the LT's idle ST shares into its market making inventory
        uint256 ltOwnedSeniorTrancheShares = $.ltOwnedSeniorTrancheShares;
        // Reinvest the entire idle balance on the sentinel, else the requested amount capped at what the LT actually holds idle
        uint256 stSharesToReinvest = Math.min(_stSharesToReinvest, ltOwnedSeniorTrancheShares);
        if (stSharesToReinvest == 0) return;

        // Value the ST shares that need to be reinvested in NAV units at the synced senior share rate (effective NAV over the post-mint supply)
        NAV_UNIT stSharesToReinvestNAV = ValuationLogic._convertToValue(stSharesToReinvest, _totalSTShares, _stEffectiveNAV, Math.Rounding.Floor);
        // Mark that senior NAV to its fair BPT at the manipulation-resistant oracle, discounted by the max tolerated slippage
        TRANCHE_UNIT minLTAssetsOut = IRoycoDayKernel(address(this)).ltConvertNAVUnitsToTrancheUnits(stSharesToReinvestNAV)
            .mulDiv((WAD - _maxReinvestmentSlippageWAD), WAD, Math.Rounding.Ceil);
        // Preemptively return if their exists no floor on the reinvested value
        if (minLTAssetsOut == ZERO_TRANCHE_UNITS) return;

        // Single-sided add the ST shares through a low-level call into the Vault's callback
        // The inner unlock dispatches addBalancerV3Liquidity, which mints the BPT bounded by minLTAssetsOut and settles the shares in
        (bool reinvestmentSucceeded, bytes memory callbackReturnData) = address(_venue.vault)
            .call(
                abi.encodeCall(
                    _venue.vault.unlock,
                    (abi.encodeCall(IBalancerV3VenueCallbacks.addBalancerV3Liquidity, (false, stSharesToReinvest, uint256(0), minLTAssetsOut)))
                )
            );
        // On a breached gate, the premium shares remain idle: no state mutated here, the inner frame rolled back
        if (!reinvestmentSucceeded) {
            emit IRoycoDayKernel.LiquidityPremiumReinvestmentFailed(stSharesToReinvest, minLTAssetsOut, callbackReturnData);
            return;
        }

        // Decode the BPT minted from the single-sided provision
        TRANCHE_UNIT ltAssetsMinted;
        assembly ("memory-safe") {
            ltAssetsMinted := mload(add(callbackReturnData, 0x60))
        }

        // Debit the reinvested ST shares and credit the BPT minted from/to the LT
        $.ltOwnedSeniorTrancheShares = ltOwnedSeniorTrancheShares - stSharesToReinvest;
        $.ltOwnedYieldBearingAssets = $.ltOwnedYieldBearingAssets + ltAssetsMinted;

        emit IRoycoDayKernel.LiquidityPremiumReinvested(stSharesToReinvest, ltAssetsMinted);
    }
}
