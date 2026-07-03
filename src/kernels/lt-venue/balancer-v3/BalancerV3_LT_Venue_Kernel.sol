// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import {
    AddLiquidityKind,
    AddLiquidityParams,
    RemoveLiquidityKind,
    RemoveLiquidityParams
} from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { BalancerPoolToken } from "../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/BalancerPoolToken.sol";
import { VaultGuard } from "../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/VaultGuard.sol";
import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { IRoycoDayQuoter } from "../../../interfaces/IRoycoDayQuoter.sol";
import { WAD, ZERO_NAV_UNITS } from "../../../libraries/Constants.sol";
import { Math, NAV_UNIT, TRANCHE_UNIT, UnitsMathLib, toUint256 } from "../../../libraries/Units.sol";
import { RoycoDayKernel } from "../../base/RoycoDayKernel.sol";

/**
 * @title BalancerV3_LT_Venue_Kernel
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice The Balancer V3 execution venue for a Royco Day liquidity tranche: the settling add/remove callbacks the kernel
 *         performs against the Balancer V3 Vault, and the gated single-sided reinvestment of the idle liquidity premium
 * @dev The BPT valuation, senior-share rate provider, and preview simulation live on the market's read-only quoter
 */
abstract contract BalancerV3_LT_Venue_Kernel is RoycoDayKernel, VaultGuard {
    using UnitsMathLib for NAV_UNIT;
    using UnitsMathLib for TRANCHE_UNIT;
    using SafeERC20 for IERC20;

    /// @dev Storage slot for BalancerV3_LT_Venue_KernelState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.BalancerV3_LT_Venue_KernelState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BALANCER_V3_LT_VENUE_KERNEL_STORAGE_SLOT = 0xe06a3482a996d3cc05047ecca6be092fdfd1e414680dfac86e78469d253a0b00;

    /// @notice Index of the Senior Tranche share token in the pool's token registration order
    uint256 internal immutable ST_SHARE_POOL_INDEX;

    /// @notice Index of the quote asset in the pool's token registration order
    uint256 internal immutable QUOTE_ASSET_POOL_INDEX;

    /// @inheritdoc RoycoDayKernel
    /// @dev Resolved from this kernel's BPT registration
    address public immutable override(RoycoDayKernel) QUOTE_ASSET;

    /**
     * @notice The namespaced storage for the BalancerV3_LT_Venue_Kernel
     * @custom:storage-location erc7201:Royco.storage.BalancerV3_LT_Venue_KernelState
     * @custom:field maxReinvestmentSlippageWAD - The maximum slippage tolerated when single-sided reinvesting the liquidity premium ST shares into the BPT, scaled to WAD precision. Above this threshold the reinvestment defers to the auction fallback
     */
    struct BalancerV3_LT_Venue_KernelState {
        uint64 maxReinvestmentSlippageWAD;
    }

    /// @notice Emitted when the maximum reinvestment slippage tolerance is updated
    /// @param maxReinvestmentSlippageWAD The new maximum slippage tolerated when single-sided reinvesting the liquidity premium into the BPT, scaled to WAD precision
    event MaxReinvestmentSlippageUpdated(uint64 maxReinvestmentSlippageWAD);

    /// @notice Thrown when the Balancer V3 Vault passed to the constructor is not the one the pool (`LT_ASSET`) is registered with
    error INVALID_BALANCER_V3_VAULT();

    /// @notice Thrown when the Balancer pool is not registered with the Balancer V3 Vault
    error POOL_NOT_REGISTERED();

    /// @notice Thrown when the Balancer pool is not configured with exactly two tokens (ST share and the kernel's quote asset)
    error POOL_MUST_HAVE_TWO_TOKENS();

    /// @notice Thrown when neither of the pool's two tokens is the senior tranche share
    error INVALID_POOL_TOKEN_CONFIGURATION();

    /// @notice Thrown when the configured maximum reinvestment slippage is not strictly less than WAD (100%)
    error INVALID_MAX_REINVESTMENT_SLIPPAGE();

    constructor(IVault _balancerV3Vault) VaultGuard(_balancerV3Vault) {
        // Ensure that the Balancer V3 Vault is the same as the one used to register the pool
        require(BalancerPoolToken(LT_ASSET).getVault() == _balancerV3Vault, INVALID_BALANCER_V3_VAULT());

        // Ensure that the Balancer V3 Pool is registered with the vault
        require(_vault.isPoolRegistered(LT_ASSET), POOL_NOT_REGISTERED());

        // Retrieve the constituent tokens of this kernel's Balancer V3 pool and ensure that their are exactly 2
        IERC20[] memory tokens = _vault.getPoolTokens(LT_ASSET);
        require(tokens.length == 2, POOL_MUST_HAVE_TWO_TOKENS());

        // Resolve and cache the indexes of the ST share and the quote asset
        // Revert if the pool is not configured with the senior tranche share as one of its two constituents
        if (address(tokens[0]) == SENIOR_TRANCHE) QUOTE_ASSET_POOL_INDEX = 1;
        else if (address(tokens[1]) == SENIOR_TRANCHE) ST_SHARE_POOL_INDEX = 1;
        else revert INVALID_POOL_TOKEN_CONFIGURATION();

        // Immutable set the quote asset address from the pool registration
        QUOTE_ASSET = address(tokens[QUOTE_ASSET_POOL_INDEX]);
    }

    /// @notice Initializes the Balancer V3 liquidity tranche kernel venue
    /// @param _maxReinvestmentSlippageWAD The maximum slippage tolerated when single-sided reinvesting the ST shares minted as a liquidity premium into the Balancer V3 Pool, scaled to WAD precision
    function __BalancerV3_LT_Venue_Kernel_init_unchained(uint64 _maxReinvestmentSlippageWAD) internal onlyInitializing {
        _setMaxReinvestmentSlippage(_maxReinvestmentSlippageWAD);
    }

    // =============================
    // Balancer V3 Liquidity Position Callback Functions
    // =============================

    /**
     * @notice Callback that performs the unbalanced BPT mint inside the unlocked Balancer V3 Vault's context
     * @dev Only callable by the Balancer V3 Vault
     * @dev This callback must settle all credit and debt created in the vault's accounting by the end of its execution
     * @dev The kernel supplies the senior tranche shares and quote assets it already holds and receives the minted BPT for the liquidity tranche
     * @param _seniorShares The exact amount of senior tranche shares to add into the pool from this kernel's balance
     * @param _quoteAssets The exact amount of quote assets to add into the pool from this kernel's balance
     * @param _minLTAssetsOut The minimum BPT (LT assets) that must be minted, bounding the add's slippage at the Vault
     * @return ltAssets The BPT (LT assets) minted to this kernel by the add
     */
    function addBalancerV3Liquidity(
        uint256 _seniorShares,
        uint256 _quoteAssets,
        TRANCHE_UNIT _minLTAssetsOut
    )
        external
        onlyVault
        returns (uint256 ltAssets)
    {
        // The exact senior tranche share and quote asset amounts to add, ordered by the pool's token registration
        uint256[] memory exactAmountsIn = new uint256[](2);
        exactAmountsIn[ST_SHARE_POOL_INDEX] = _seniorShares;
        exactAmountsIn[QUOTE_ASSET_POOL_INDEX] = _quoteAssets;

        // Credit this kernel with the BPT minted by the unbalanced add of the specified senior tranche shares and quote assets
        (, ltAssets,) = _vault.addLiquidity(
            AddLiquidityParams({
                pool: LT_ASSET, // The Balancer pool to add liquidity to is the liquidity tranche's asset (BPT)
                to: address(this), // The kernel custodies the BPT balance of the entire liquidity tranche, so the minted BPT is credited to it
                maxAmountsIn: exactAmountsIn, // For UNBALANCED adds the Vault treats these as the exact amounts in (not upper bounds)
                minBptAmountOut: toUint256(_minLTAssetsOut), // The Vault reverts the add if it would mint fewer BPT than this, bounding the add's slippage
                kind: AddLiquidityKind.UNBALANCED, // Unbalanced add: the Vault charges the pool's swap fee on the imbalanced portion
                userData: "" // UNBALANCED adds skip the pool's compute callback and this kernel's hooks do not consume userData
            })
        );

        // Settle the senior tranche shares and quote assets this kernel owes the Vault for the add by transferring them in and cancelling the debt
        if (_seniorShares > 0) {
            IERC20(SENIOR_TRANCHE).safeTransfer(address(_vault), _seniorShares);
            _vault.settle(IERC20(SENIOR_TRANCHE), _seniorShares);
        }
        if (_quoteAssets > 0) {
            IERC20(QUOTE_ASSET).safeTransfer(address(_vault), _quoteAssets);
            _vault.settle(IERC20(QUOTE_ASSET), _quoteAssets);
        }
        /// @dev All credit and debt created during this callback has been settled
    }

    /**
     * @notice Callback that performs the proportional BPT unwrap inside the unlocked Balancer V3 Vault's context
     * @dev Only callable by the Balancer V3 Vault
     * @dev This callback must settle all credit and debt created in the vault's accounting by the end of its execution
     * @dev The kernel receives any ST shares withdrawn and is responsible for converting them to the base assets before remitting them to the user
     * @param _ltAssets The exact BPT amount (LT assets) to burn from this kernel's balance
     * @param _minSTSharesOut The minimum senior tranche shares that must be withdrawn, bounding the removal's slippage at the Vault
     * @param _minQuoteAssetsOut The minimum quote assets that must be withdrawn, bounding the removal's slippage at the Vault
     * @param _quoteAssetsReceiver The recipient of the quote assets withdrawn
     * @return stShares The senior tranche shares withdrawn back to this kernel by the unwrap
     * @return quoteAssets The quote assets withdrawn directly to the specified receiver
     */
    function removeBalancerV3Liquidity(
        TRANCHE_UNIT _ltAssets,
        uint256 _minSTSharesOut,
        uint256 _minQuoteAssetsOut,
        address _quoteAssetsReceiver
    )
        external
        onlyVault
        returns (uint256 stShares, uint256 quoteAssets)
    {
        // The minimum senior tranche share and quote asset amounts out, ordered by the pool's token registration
        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[ST_SHARE_POOL_INDEX] = _minSTSharesOut;
        minAmountsOut[QUOTE_ASSET_POOL_INDEX] = _minQuoteAssetsOut;

        // Debit this kernel with the proportional constituent claims tied to the specified amount of LT assets
        (, uint256[] memory amountsOut,) = _vault.removeLiquidity(
            RemoveLiquidityParams({
                pool: LT_ASSET, // The Balancer pool to remove liquidity from is the liquidity tranche's asset (BPT)
                from: address(this), // The kernel custodies the BPT balance of the entire liquidity tranche, so the BPT constituents are debited from its claims
                maxBptAmountIn: toUint256(_ltAssets), // For PROPORTIONAL removals the Vault treats this as the exact BPT amount to burn (not an upper bound)
                minAmountsOut: minAmountsOut, // The Vault reverts the removal if any constituent comes out below these floors, bounding the removal's slippage
                kind: RemoveLiquidityKind.PROPORTIONAL, // Proportional removals preserve the pool's composition, so the unwrap requires no pricing
                userData: "" // PROPORTIONAL removals skip the pool's compute callback and this kernel's hooks do not consume userData
            })
        );

        // Set the amounts out to be returned to the caller
        stShares = amountsOut[ST_SHARE_POOL_INDEX];
        quoteAssets = amountsOut[QUOTE_ASSET_POOL_INDEX];

        // Credit the ST shares withdrawn to the kernel for downstream redemption before remitting assets to the user
        if (stShares > 0) _vault.sendTo(IERC20(SENIOR_TRANCHE), address(this), stShares);
        // Credit the quote assets withdrawn to its specified receiver
        if (quoteAssets > 0) _vault.sendTo(IERC20(QUOTE_ASSET), _quoteAssetsReceiver, quoteAssets);
        /// @dev All credit and debt created during this callback has been settled
    }

    // =============================
    // Balancer V3 Liquidity Tranche Venue Hooks
    // =============================

    /**
     * @inheritdoc RoycoDayKernel
     * @dev Unlocks the Balancer V3 Vault and dispatches into the add liquidity callback above
     * @dev The vault is required to be unlocked with a callback in order to transition into a transient accounting state, expecting the callback to settle all credit and debt before returning
     * @dev The preview counterpart (`_previewAddLiquidity`) lives on the kernel quoter, which re-enters its own `previewAddBalancerV3Liquidity` callback via `Vault.quote`
     */
    function _addLiquidity(
        uint256 _seniorShares,
        uint256 _quoteAssets,
        TRANCHE_UNIT _minLTAssetsOut
    )
        internal
        override(RoycoDayKernel)
        returns (TRANCHE_UNIT ltAssets)
    {
        // Unlock the Balancer vault, execute the callback to mint the liquidity position from the specified senior tranche shares and quote assets
        bytes memory callbackReturnData = _vault.unlock(abi.encodeCall(this.addBalancerV3Liquidity, (_seniorShares, _quoteAssets, _minLTAssetsOut)));
        assembly ("memory-safe") {
            ltAssets := mload(add(callbackReturnData, 0x20))
        }
    }

    /**
     * @inheritdoc RoycoDayKernel
     * @dev Unlocks the Balancer V3 Vault and dispatches into the remove liquidity callback above
     * @dev The vault is required to be unlocked with a callback in order to transition into a transient accounting state, expecting the callback to settle all credit and debt before returning
     * @dev The preview counterpart (`_previewRemoveLiquidity`) lives on the kernel quoter, which re-enters its own `previewRemoveBalancerV3Liquidity` callback via `Vault.quote`
     */
    function _removeLiquidity(
        TRANCHE_UNIT _ltAssets,
        uint256 _minSTSharesOut,
        uint256 _minQuoteAssetsOut,
        address _quoteAssetsReceiver
    )
        internal
        override(RoycoDayKernel)
        returns (uint256 stShares, uint256 quoteAssets)
    {
        // Unlock the Balancer vault, execute the callback to unwrap the specified units of the liquidity position
        bytes memory callbackReturnData =
            _vault.unlock(abi.encodeCall(this.removeBalancerV3Liquidity, (_ltAssets, _minSTSharesOut, _minQuoteAssetsOut, _quoteAssetsReceiver)));
        assembly ("memory-safe") {
            stShares := mload(add(callbackReturnData, 0x20))
            quoteAssets := mload(add(callbackReturnData, 0x40))
        }
    }

    /**
     * @inheritdoc RoycoDayKernel
     * @dev Deploys the idle liquidity-premium senior share balance the kernel holds into the BPT via a gated single-sided add
     * @dev The min-BPT-out floors the add at the manipulation-resistant oracle's fair value (not the pool spot) less the max reinvestment slippage, so a manipulated pool cannot widen the tolerance
     * @dev Tolerates reversions to ensure a tranche operation doesn't revert on a failing reinvestment
     */
    function _attemptLiquidityPremiumReinvestment(
        uint256 _stSharesToReinvest,
        NAV_UNIT _stEffectiveNAV,
        uint256 _totalSTShares
    )
        internal
        override(RoycoDayKernel)
    {
        // Deploy the LT's idle ST shares into its market making inventory
        RoycoDayKernelState storage $ = _getRoycoDayKernelStorage();
        uint256 ltOwnedSeniorTrancheShares = $.ltOwnedSeniorTrancheShares;
        // Reinvest the entire idle balance on the sentinel, else the requested amount capped at what the LT actually holds idle
        uint256 stSharesToReinvest = Math.min(_stSharesToReinvest, ltOwnedSeniorTrancheShares);
        if (stSharesToReinvest == 0) return;

        // Value the ST shares that need to be reinvested in NAV units at the synced senior share rate (effective NAV over the post-mint supply)
        NAV_UNIT stSharesToReinvestNAV = _totalSTShares == 0 ? ZERO_NAV_UNITS : _stEffectiveNAV.mulDiv(stSharesToReinvest, _totalSTShares, Math.Rounding.Floor);
        // Mark that senior NAV to its fair BPT at the manipulation-resistant oracle, discounted by the max tolerated slippage
        TRANCHE_UNIT minLTAssetsOut = IRoycoDayQuoter(QUOTER).ltConvertNAVUnitsToTrancheUnits(stSharesToReinvestNAV)
            .mulDiv((WAD - _getBalancerV3_LT_Venue_KernelStorage().maxReinvestmentSlippageWAD), WAD, Math.Rounding.Ceil);

        // Single-sided add the ST shares through a low-level call into the Vault's callback
        // The inner unlock dispatches addBalancerV3Liquidity, which mints the BPT bounded by minLTAssetsOut and settles the shares in
        (bool reinvestmentSucceeded, bytes memory callbackReturnData) = address(_vault)
            .call(abi.encodeCall(_vault.unlock, (abi.encodeCall(this.addBalancerV3Liquidity, (stSharesToReinvest, uint256(0), minLTAssetsOut)))));
        // On a breached gate (or any add revert) the premium shares remain idle: no state mutated here, the inner frame rolled back
        if (!reinvestmentSucceeded) return;

        // Decode the BPT minted from the single-sided provision
        TRANCHE_UNIT ltAssetsMinted;
        assembly ("memory-safe") {
            ltAssetsMinted := mload(add(callbackReturnData, 0x60))
        }

        // Debit the reinvested ST shares and credit the BPT minted from/to the LT
        $.ltOwnedSeniorTrancheShares = ltOwnedSeniorTrancheShares - stSharesToReinvest;
        $.ltOwnedYieldBearingAssets = $.ltOwnedYieldBearingAssets + ltAssetsMinted;

        emit LiquidityPremiumReinvested(stSharesToReinvest, ltAssetsMinted);
    }

    // =============================
    // Admin Functions
    // =============================

    /// @notice Sets the maximum slippage tolerated when single-sided reinvesting the liquidity premium into the BPT
    /// @param _maxReinvestmentSlippageWAD The new maximum reinvestment slippage tolerance, scaled to WAD precision
    function setMaxReinvestmentSlippage(uint64 _maxReinvestmentSlippageWAD) external restricted {
        _setMaxReinvestmentSlippage(_maxReinvestmentSlippageWAD);
    }

    /// @notice Returns the maximum slippage tolerated when single-sided reinvesting the liquidity premium into the BPT, scaled to WAD precision
    function getMaxReinvestmentSlippage() external view returns (uint64 maxReinvestmentSlippageWAD) {
        return _getBalancerV3_LT_Venue_KernelStorage().maxReinvestmentSlippageWAD;
    }

    /// @notice Sets the new maximum reinvestment slippage tolerance
    /// @param _maxReinvestmentSlippageWAD The new maximum reinvestment slippage tolerance, scaled to WAD precision
    function _setMaxReinvestmentSlippage(uint64 _maxReinvestmentSlippageWAD) internal {
        require(_maxReinvestmentSlippageWAD < WAD, INVALID_MAX_REINVESTMENT_SLIPPAGE());
        _getBalancerV3_LT_Venue_KernelStorage().maxReinvestmentSlippageWAD = _maxReinvestmentSlippageWAD;
        emit MaxReinvestmentSlippageUpdated(_maxReinvestmentSlippageWAD);
    }

    /**
     * @notice Returns a storage pointer to the BalancerV3_LT_Venue_KernelState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer to the venue's state
     */
    function _getBalancerV3_LT_Venue_KernelStorage() internal pure returns (BalancerV3_LT_Venue_KernelState storage $) {
        assembly ("memory-safe") {
            $.slot := BALANCER_V3_LT_VENUE_KERNEL_STORAGE_SLOT
        }
    }
}
