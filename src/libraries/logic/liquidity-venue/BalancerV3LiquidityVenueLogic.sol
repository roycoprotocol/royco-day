// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import { IVault } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import {
    AddLiquidityKind,
    AddLiquidityParams,
    RemoveLiquidityKind,
    RemoveLiquidityParams
} from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { IRoycoDayKernel } from "../../../interfaces/IRoycoDayKernel.sol";
import { IBalancerV3LiquidityVenue } from "../../../interfaces/liquidity-venue/IBalancerV3LiquidityVenue.sol";
import { WAD, ZERO_TRANCHE_UNITS } from "../../Constants.sol";
import { DispatchMode } from "../../Types.sol";
import { Math, NAV_UNIT, RoycoUnitsMath, TRANCHE_UNIT, toUint256 } from "../../Units.sol";
import { DispatchLogic } from "../DispatchLogic.sol";

/**
 * @title BalancerV3LiquidityVenueLogic
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Externalized Balancer V3 liquidity provider tranche venue logic delegatecalled by the kernel's BalancerV3LiquidityVenue mixin
 */
library BalancerV3LiquidityVenueLogic {
    using RoycoUnitsMath for NAV_UNIT;
    using RoycoUnitsMath for TRANCHE_UNIT;
    using SafeERC20 for IERC20;
    using DispatchLogic for address;

    /// @dev The pool token indexes are a venue-initialization invariant
    uint256 private constant _ST_SHARE_POOL_INDEX = 0;
    uint256 private constant _QUOTE_ASSET_POOL_INDEX = 1;

    /**
     * @notice Callback that performs the unbalanced BPT mint inside the unlocked Balancer V3 Vault's context
     * @dev Only callable by the Balancer V3 Vault
     * @dev This callback must settle all credit and debt created in the vault's accounting by the end of its execution
     * @dev The kernel supplies the senior tranche shares and quote assets it already holds and receives the minted BPT for the liquidity provider tranche
     * @param $_kernel The storage state of the Royco Kernel that is delegatecalling into this function
     * @param _vault The Balancer V3 Vault, a kernel implementation immutable a delegatecalled library cannot read, so it crosses the boundary as a parameter
     * @param _mode The dispatch mode: SIMULATE computes the amounts under the Vault's real semantics and unwinds by reverting with the result instead of settling, EXECUTE settles
     * @param _seniorShares The exact amount of senior tranche shares to add into the pool from this kernel's balance
     * @param _quoteAssets The exact amount of quote assets to add into the pool from this kernel's balance
     * @param _minLPTAssetsOut The minimum BPT (LPT assets) that must be minted, bounding the add's slippage at the Vault
     * @return lptAssets The BPT (LPT assets) minted to this kernel by the add
     * @return lptAssetPrice The value of 1 whole BPT against the post-add pool state, produced only for a preview to cache for the operation (zero when settling)
     */
    function addBalancerV3Liquidity(
        IRoycoDayKernel.RoycoDayKernelState storage $_kernel,
        IVault _vault,
        DispatchMode _mode,
        uint256 _seniorShares,
        uint256 _quoteAssets,
        TRANCHE_UNIT _minLPTAssetsOut
    )
        external
        returns (uint256 lptAssets, NAV_UNIT lptAssetPrice)
    {
        // Cache the BPT address
        address lptAsset = $_kernel.lptAsset;

        // The exact senior tranche share and quote asset amounts to add, ordered by the pool's token registration
        uint256[] memory exactAmountsIn = new uint256[](2);
        exactAmountsIn[_ST_SHARE_POOL_INDEX] = _seniorShares;
        exactAmountsIn[_QUOTE_ASSET_POOL_INDEX] = _quoteAssets;

        // If the pool is initialized, add liquidity directly, else, the pool must be initialized (seeded)
        if (_vault.isPoolInitialized(lptAsset)) {
            // Credit this kernel with the BPT minted by the unbalanced add of the specified senior tranche shares and quote assets
            (, lptAssets,) = _vault.addLiquidity(
                AddLiquidityParams({
                    pool: lptAsset, // The Balancer pool to add liquidity to is the liquidity provider tranche's asset (BPT)
                    to: address(this), // The kernel custodies the BPT balance of the entire liquidity provider tranche, so the minted BPT is credited to it
                    maxAmountsIn: exactAmountsIn, // For UNBALANCED adds the Vault treats these as the exact amounts in (not upper bounds)
                    minBptAmountOut: toUint256(_minLPTAssetsOut), // The Vault reverts the add if it would mint fewer BPT than this, bounding the add's slippage
                    kind: AddLiquidityKind.UNBALANCED, // Unbalanced add: the Vault charges the pool's swap fee on the imbalanced portion
                    userData: "" // UNBALANCED adds skip the pool's compute callback and this kernel's hooks do not consume userData
                })
            );
        } else {
            // The pool's registered tokens, ordered by the pool's token registration
            IERC20[] memory tokens = new IERC20[](2);
            tokens[_ST_SHARE_POOL_INDEX] = IERC20($_kernel.seniorTranche);
            tokens[_QUOTE_ASSET_POOL_INDEX] = IERC20($_kernel.quoteAsset);

            // Credit this kernel with the BPT minted by seeding the pool's initial balances
            // NOTE: The Vault permanently burns a minimum BPT supply to the null address on initialization, so lptAssets is net of that burn
            lptAssets = _vault.initialize(
                lptAsset, // The Balancer pool to initialize is the liquidity provider tranche's asset (BPT)
                address(this), // The kernel custodies the BPT balance of the entire liquidity provider tranche, so the minted BPT is credited to it
                tokens, // The pool's registered tokens in registration order
                exactAmountsIn, // The exact amounts seeding the pool's initial balances
                toUint256(_minLPTAssetsOut), // The Vault reverts the initialization if it would mint fewer BPT than this, bounding the seed's slippage
                "" // Initialization hooks are disabled for this market's pools and this kernel's hooks do not consume userData
            );
        }

        // A preview carries its result out via this revert, unwinding every transient balance change before settlement
        // The post-add price is produced only here: the preview's unwind discards the post-add pool state, so this frame is the only place to capture its mark
        if (_mode == DispatchMode.SIMULATE) {
            revert DispatchLogic.SIMULATION_RESULT(abi.encode(lptAssets, IRoycoDayKernel(address(this)).queryLPTAssetOracle()));
        }

        // Settle the senior tranche shares and quote assets this kernel owes the Vault for the add by transferring them in and cancelling the debt
        if (_seniorShares > 0) {
            IERC20 seniorTranche = IERC20($_kernel.seniorTranche);
            seniorTranche.safeTransfer(address(_vault), _seniorShares);
            _vault.settle(seniorTranche, _seniorShares);
        }
        if (_quoteAssets > 0) {
            IERC20 quoteAsset = IERC20($_kernel.quoteAsset);
            quoteAsset.safeTransfer(address(_vault), _quoteAssets);
            _vault.settle(quoteAsset, _quoteAssets);
        }
        /// @dev All credit and debt created during this callback has been settled
    }

    /**
     * @notice Callback that performs the proportional BPT unwrap inside the unlocked Balancer V3 Vault's context
     * @dev Only callable by the Balancer V3 Vault
     * @dev This callback must settle all credit and debt created in the vault's accounting by the end of its execution
     * @dev The kernel receives any ST shares withdrawn and is responsible for converting them to the base assets before remitting them to the user
     * @param $_kernel The storage state of the Royco Kernel that is delegatecalling into this function
     * @param _vault The Balancer V3 Vault, a kernel implementation immutable a delegatecalled library cannot read, so it crosses the boundary as a parameter
     * @param _mode The dispatch mode: SIMULATE computes the amounts under the Vault's real semantics and unwinds by reverting with the result instead of settling, EXECUTE settles
     * @param _lptAssets The exact BPT amount (LPT assets) to burn from this kernel's balance
     * @param _minSTSharesOut The minimum senior tranche shares that must be withdrawn, bounding the removal's slippage at the Vault
     * @param _minQuoteAssetsOut The minimum quote assets that must be withdrawn, bounding the removal's slippage at the Vault
     * @param _quoteAssetsReceiver The recipient of the quote assets withdrawn
     * @return stShares The senior tranche shares withdrawn back to this kernel by the unwrap
     * @return quoteAssets The quote assets withdrawn directly to the specified receiver
     * @return lptAssetPrice The value of 1 whole BPT against the post-remove pool state, produced only for a preview to cache for the operation (zero when settling)
     */
    function removeBalancerV3Liquidity(
        IRoycoDayKernel.RoycoDayKernelState storage $_kernel,
        IVault _vault,
        DispatchMode _mode,
        TRANCHE_UNIT _lptAssets,
        uint256 _minSTSharesOut,
        uint256 _minQuoteAssetsOut,
        address _quoteAssetsReceiver
    )
        external
        returns (uint256 stShares, uint256 quoteAssets, NAV_UNIT lptAssetPrice)
    {
        // The minimum senior tranche share and quote asset amounts out, ordered by the pool's token registration
        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[_ST_SHARE_POOL_INDEX] = _minSTSharesOut;
        minAmountsOut[_QUOTE_ASSET_POOL_INDEX] = _minQuoteAssetsOut;

        // Debit this kernel with the proportional constituent claims tied to the specified amount of LPT assets
        (, uint256[] memory amountsOut,) = _vault.removeLiquidity(
            RemoveLiquidityParams({
                pool: $_kernel.lptAsset, // The Balancer pool to remove liquidity from is the liquidity provider tranche's asset (BPT)
                from: address(this), // The kernel custodies the BPT balance of the entire liquidity provider tranche, so the BPT constituents are debited from its claims
                maxBptAmountIn: toUint256(_lptAssets), // For PROPORTIONAL removals the Vault treats this as the exact BPT amount to burn (not an upper bound)
                minAmountsOut: minAmountsOut, // The Vault reverts the removal if any constituent comes out below these floors, bounding the removal's slippage
                kind: RemoveLiquidityKind.PROPORTIONAL, // Proportional removals preserve the pool's composition, so the unwrap requires no pricing
                userData: "" // PROPORTIONAL removals skip the pool's compute callback and this kernel's hooks do not consume userData
            })
        );

        // Set the amounts out to be returned to the caller
        stShares = amountsOut[_ST_SHARE_POOL_INDEX];
        quoteAssets = amountsOut[_QUOTE_ASSET_POOL_INDEX];

        // A preview carries its result out via this revert, unwinding every transient balance change before settlement
        // The post-remove price is produced only here: the preview's unwind discards the post-remove pool state, so this frame is the only place to capture its mark
        if (_mode == DispatchMode.SIMULATE) {
            revert DispatchLogic.SIMULATION_RESULT(abi.encode(stShares, quoteAssets, IRoycoDayKernel(address(this)).queryLPTAssetOracle()));
        }

        // Credit the ST shares withdrawn to the kernel for downstream redemption before remitting assets to the user
        if (stShares > 0) _vault.sendTo(IERC20($_kernel.seniorTranche), address(this), stShares);
        // Credit the quote assets withdrawn to its specified receiver
        if (quoteAssets > 0) _vault.sendTo(IERC20($_kernel.quoteAsset), _quoteAssetsReceiver, quoteAssets);
        /// @dev All credit and debt created during this callback has been settled
    }

    /**
     * @notice Attempts to reinvest the liquidity provider tranche's idle liquidity-premium senior shares into its market-making inventory
     * @dev Tolerates reversions gracefully so it is non-blocking for the tranche operation that invokes it
     * @param $_kernel The storage state of the Royco Kernel that is delegatecalling into this function
     * @param _vault The Balancer V3 Vault, a kernel implementation immutable a delegatecalled library cannot read, so it crosses the boundary as a parameter
     * @param _maxReinvestmentSlippageWAD The maximum slippage tolerated on the single-sided reinvestment, scaled to WAD precision
     * @param _stSharesToReinvest The amount of idle liquidity-premium senior shares to reinvest, or type(uint256).max to reinvest the entire idle balance
     * @param _stShareRate The senior share rate the pile is valued at, the NAV backing one whole (WAD) senior share at the operation's settled state
     */
    function attemptLiquidityPremiumReinvestment(
        IRoycoDayKernel.RoycoDayKernelState storage $_kernel,
        IVault _vault,
        uint64 _maxReinvestmentSlippageWAD,
        uint256 _stSharesToReinvest,
        NAV_UNIT _stShareRate
    )
        external
    {
        // Deploy the LPT's idle ST shares into its market making inventory
        uint256 lptOwnedSeniorTrancheShares = $_kernel.lptOwnedSeniorTrancheShares;
        // Reinvest the entire idle balance on the sentinel, else the requested amount capped at what the LPT actually holds idle
        uint256 stSharesToReinvest = Math.min(_stSharesToReinvest, lptOwnedSeniorTrancheShares);
        if (stSharesToReinvest == 0) return;

        // Value the ST shares that need to be reinvested in NAV units at the senior share rate, rounding up so the slippage floor stays protective
        NAV_UNIT stSharesToReinvestNAV = _stShareRate.mulDiv(stSharesToReinvest, WAD, Math.Rounding.Ceil);
        // Mark that senior NAV to its fair BPT at the manipulation-resistant oracle, discounted by the max tolerated slippage
        (bool priceExists, bytes memory returnData) = address(this)._tryExecute(abi.encodeCall(IRoycoDayKernel.convertValueToLPTAssets, stSharesToReinvestNAV));
        if (!priceExists) return;
        TRANCHE_UNIT equivalentLPTAssetsForValue = abi.decode(returnData, (TRANCHE_UNIT));
        TRANCHE_UNIT minLPTAssetsOut = equivalentLPTAssetsForValue.mulDiv((WAD - _maxReinvestmentSlippageWAD), WAD, Math.Rounding.Ceil);
        // Preemptively return if there exists no floor on the reinvested value
        if (minLPTAssetsOut == ZERO_TRANCHE_UNITS) return;

        // Single-sided add the ST shares through a low-level call into the Vault's callback
        // The inner unlock dispatches addBalancerV3Liquidity, which mints the BPT bounded by minLPTAssetsOut and settles the shares in
        (bool reinvestmentSucceeded, bytes memory callbackReturnData) = DispatchLogic._tryExecute(
            address(_vault),
            abi.encodeCall(
                _vault.unlock,
                (abi.encodeCall(IBalancerV3LiquidityVenue.addBalancerV3Liquidity, (DispatchMode.EXECUTE, stSharesToReinvest, uint256(0), minLPTAssetsOut)))
            )
        );
        // On a breached gate, the premium shares remain idle: no state mutated here, the inner frame rolled back
        if (!reinvestmentSucceeded) {
            emit IRoycoDayKernel.LiquidityPremiumReinvestmentFailed(stSharesToReinvest, minLPTAssetsOut, callbackReturnData);
            return;
        }

        // Decode the BPT minted from the single-sided provision
        TRANCHE_UNIT lptAssetsOut;
        assembly ("memory-safe") { lptAssetsOut := mload(add(callbackReturnData, 0x60)) }

        // Debit the reinvested ST shares and credit the BPT minted from/to the LPT
        $_kernel.lptOwnedSeniorTrancheShares = lptOwnedSeniorTrancheShares - stSharesToReinvest;
        $_kernel.totalLPTAssets = $_kernel.totalLPTAssets + lptAssetsOut;

        emit IRoycoDayKernel.LiquidityPremiumReinvested(stSharesToReinvest, lptAssetsOut);
    }
}
