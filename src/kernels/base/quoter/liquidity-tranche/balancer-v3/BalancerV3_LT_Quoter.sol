// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRateProvider } from "../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { IVault } from "../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import {
    AddLiquidityKind,
    AddLiquidityParams,
    RemoveLiquidityKind,
    RemoveLiquidityParams
} from "../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { LPOracleBase } from "../../../../../../lib/balancer-v3-monorepo/pkg/oracles/contracts/LPOracleBase.sol";
import { BalancerPoolToken } from "../../../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/BalancerPoolToken.sol";
import { VaultGuard } from "../../../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/VaultGuard.sol";
import { IERC20 } from "../../../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "../../../../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { IRoycoDayAccountant } from "../../../../../interfaces/IRoycoDayAccountant.sol";
import { WAD, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../../../../../libraries/Constants.sol";
import { Math, NAV_UNIT, TRANCHE_UNIT, UnitsMathLib, toNAVUnits, toTrancheUnits, toUint256 } from "../../../../../libraries/Units.sol";
import { RoycoDayKernel } from "../../../RoycoDayKernel.sol";

/**
 * @title BalancerV3_LT_Quoter
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice A quoter for liquidity tranches using Balancer V3 pools (ST share <> Quote asset) as their secondary liquidity venue
 * @notice The liquidity tranche asset is a Balancer Pool Token (BPT) between this kernel's senior tranche share and quote asset
 */
abstract contract BalancerV3_LT_Quoter is RoycoDayKernel, VaultGuard, IRateProvider {
    using UnitsMathLib for NAV_UNIT;
    using UnitsMathLib for TRANCHE_UNIT;
    using SafeERC20 for IERC20;

    /// @dev Storage slot for BalancerV3_LT_QuoterState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.BalancerV3_LT_QuoterState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BALANCER_V3_LT_QUOTER_STORAGE_SLOT = 0x8a7de9cdb687047f7d2fa86cad84bde8f19c3d8b5242f498d1bd0c4e66164e00;

    /// @notice Index of the Senior Tranche share token in the pool's token registration order
    uint256 internal immutable ST_SHARE_POOL_INDEX;

    /// @notice Index of the quote asset in the pool's token registration order
    uint256 internal immutable QUOTE_ASSET_POOL_INDEX;

    /// @inheritdoc RoycoDayKernel
    /// @dev Resolved from this kernel's BPT registration
    address public immutable override(RoycoDayKernel) QUOTE_ASSET;

    /// @notice The namespaced storage for the BalancerV3_LT_Quoter
    /// @custom:field bptOracle - The manipulation-resistant Balancer V3 pool token (BPT) oracle used to value the liquidity tranche assets
    /// @custom:field maxReinvestmentSlippageWAD - The maximum slippage tolerated when single-sided reinvesting the liquidity premium ST shares into the BPT, scaled to WAD precision. Above this threshold the reinvestment defers to the auction fallback
    struct BalancerV3_LT_QuoterState {
        address bptOracle;
        uint64 maxReinvestmentSlippageWAD;
    }

    /// @notice Emitted when the BPT oracle used to value the liquidity tranche is updated
    event BPTOracleUpdated(address indexed bptOracle);

    /// @notice Emitted when the maximum reinvestment slippage tolerance is updated
    /// @param maxReinvestmentSlippageWAD The new maximum slippage tolerated when single-sided reinvesting the liquidity premium into the BPT, scaled to WAD precision
    event MaxReinvestmentSlippageUpdated(uint64 maxReinvestmentSlippageWAD);

    /// @notice Emitted when the kernel's held liquidity-premium senior shares are deployed into the BPT via the gated single-sided add
    /// @param stSharesDeployed The senior tranche shares drained from the kernel's held balance and added into the pool
    /// @param ltAssetsMinted The BPT (LT assets) minted to the liquidity tranche by the add
    event LiquidityPremiumReinvested(uint256 stSharesDeployed, TRANCHE_UNIT ltAssetsMinted);

    /// @notice Thrown when the Balancer pool is not registered with the Balancer V3 Vault
    error POOL_NOT_REGISTERED();

    /// @notice Thrown when the Balancer pool is not configured with exactly two tokens (ST share and the kernel's quote asset)
    error POOL_MUST_HAVE_TWO_TOKENS();

    /// @notice Thrown when neither of the pool's two tokens is the senior tranche share
    error INVALID_POOL_TOKEN_CONFIGURATION();

    /// @notice Thrown when the configured maximum reinvestment slippage is not strictly less than WAD (100%)
    error INVALID_MAX_REINVESTMENT_SLIPPAGE();

    constructor() VaultGuard(BalancerPoolToken(LT_ASSET).getVault()) {
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

    /**
     * @notice Initializes the Balancer V3 liquidity tranche quoter
     * @param _bptOracle The manipulation-resistant Balancer V3 pool token (BPT) oracle used to value the liquidity tranche
     * @param _maxReinvestmentSlippageWAD The maximum slippage tolerated when single-sided reinvesting the ST shares minted as a liquidity premium into the Balancer V3 Pool, scaled to WAD precision
     */
    function __BalancerV3_LT_Quoter_init_unchained(address _bptOracle, uint64 _maxReinvestmentSlippageWAD) internal onlyInitializing {
        _setBPTOracle(_bptOracle);
        _setMaxReinvestmentSlippage(_maxReinvestmentSlippageWAD);
    }

    // =============================
    // Liquidity Tranche Quoter Functions
    // =============================

    /**
     * @inheritdoc RoycoDayKernel
     * @dev Values the BPT amount at the liquidity venue's manipulation-resistant NAV per BPT (the oracle's total NAV over the BPT
     *      supply), rounding down so the liquidity tranche's NAV is never overstated
     * @dev The oracle is read live on every call rather than through the quoter cache: the kernel mints, joins, and exits the pool
     *      within a single transaction, so a value cached at the start of the operation would be stale by the time it is consumed
     */
    function ltConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _ltAssets) public view virtual override(RoycoDayKernel) returns (NAV_UNIT) {
        TRANCHE_UNIT bptTotalSupply = toTrancheUnits(_vault.totalSupply(LT_ASSET));
        if (bptTotalSupply == ZERO_TRANCHE_UNITS) return ZERO_NAV_UNITS;
        NAV_UNIT bptTotalNAV = toNAVUnits(LPOracleBase(_getBalancerV3_LT_QuoterStorage().bptOracle).computeTVL());
        return bptTotalNAV.mulDiv(_ltAssets, bptTotalSupply, Math.Rounding.Floor);
    }

    /// @inheritdoc RoycoDayKernel
    /// @dev Converts the NAV amount to a BPT amount at the same live, manipulation-resistant NAV per BPT, rounding down
    function ltConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) public view virtual override(RoycoDayKernel) returns (TRANCHE_UNIT) {
        TRANCHE_UNIT bptTotalSupply = toTrancheUnits(_vault.totalSupply(LT_ASSET));
        if (bptTotalSupply == ZERO_TRANCHE_UNITS) return ZERO_TRANCHE_UNITS;
        NAV_UNIT bptTotalNAV = toNAVUnits(LPOracleBase(_getBalancerV3_LT_QuoterStorage().bptOracle).computeTVL());
        return bptTotalSupply.mulDiv(_navAssets, bptTotalNAV, Math.Rounding.Floor);
    }

    // =============================
    // Senior Share Rate Provider Function
    // =============================

    /**
     * @inheritdoc IRateProvider
     * @dev Values one senior tranche share in NAV units
     * @dev Reads only committed state (the accountant checkpoint and senior tranche share supply) for safety
     * @dev Any pool liquidity operation will be fulfilled at the fresh rate because the pool executes an accounting synchronization prior
     */
    function getRate() external view virtual override(IRateProvider) returns (uint256 rate) {
        // Before the senior tranche is seeded there are no shares to price: return a neutral 1.0 rate so the pool never divides by zero
        uint256 seniorTrancheTotalSupply = IERC20(SENIOR_TRANCHE).totalSupply();
        if (seniorTrancheTotalSupply == 0) return WAD;

        // Compute the senior tranche share rate in NAV units using the last commited ST effective NAV and total supply
        // NOTE: Senior tranche shares always use WAD decimals of precision so WAD == 1 ST share
        rate = toUint256((IRoycoDayAccountant(ACCOUNTANT).getLastSTEffectiveNAV()).mulDiv(WAD, seniorTrancheTotalSupply, Math.Rounding.Floor));

        // Floor the computed rate to 1 wei to prevent reversions in the underlying balancer pool
        if (rate == 0) rate = 1;
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
    function addBalancerV3Liquidity(uint256 _seniorShares, uint256 _quoteAssets, TRANCHE_UNIT _minLTAssetsOut) external onlyVault returns (uint256 ltAssets) {
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

        // Credit the ST shares withdrawn to the kernel for downstream redemption before remitting assets to the user
        if ((stShares = amountsOut[ST_SHARE_POOL_INDEX]) > 0) _vault.sendTo(IERC20(SENIOR_TRANCHE), address(this), stShares);
        // Credit the quote assets withdrawn to its specified receiver
        if ((quoteAssets = amountsOut[QUOTE_ASSET_POOL_INDEX]) > 0) _vault.sendTo(IERC20(QUOTE_ASSET), _quoteAssetsReceiver, quoteAssets);
        /// @dev All credit and debt created during this callback has been settled
    }

    // =============================
    // Balancer V3 Liquidity Tranche Venue Hooks
    // =============================

    /// @inheritdoc RoycoDayKernel
    /// @dev Unlocks the Balancer V3 Vault and dispatches into the add liquidity callback above
    /// @dev The vault is required to be unlocked with a callback in order to transition into a transient accounting state, expecting the callback to settle all credit and debt before returning
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
     * @notice Query-mode callback that simulates the unbalanced BPT mint inside the Vault's query context
     * @dev Only callable by the Balancer V3 Vault (re-entered via `quote`). Performs no settlement: query mode computes the
     *      result without finalizing balances or moving tokens, so the kernel need not hold the senior shares or quote assets
     * @param _seniorShares The senior tranche shares the add would inject
     * @param _quoteAssets The quote assets the add would inject
     * @return ltAssets The BPT (LT assets) the add would mint
     */
    function quoteAddBalancerV3Liquidity(uint256 _seniorShares, uint256 _quoteAssets) external onlyVault returns (uint256 ltAssets) {
        // The senior tranche share and quote asset amounts to add, ordered by the pool's token registration
        uint256[] memory exactAmountsIn = new uint256[](2);
        exactAmountsIn[ST_SHARE_POOL_INDEX] = _seniorShares;
        exactAmountsIn[QUOTE_ASSET_POOL_INDEX] = _quoteAssets;

        // Compute the BPT the unbalanced add would mint; in query mode no slippage gate and no credit/debt settlement is required
        (, ltAssets,) = _vault.addLiquidity(
            AddLiquidityParams({
                pool: LT_ASSET, to: address(this), maxAmountsIn: exactAmountsIn, minBptAmountOut: 0, kind: AddLiquidityKind.UNBALANCED, userData: ""
            })
        );
    }

    /// @inheritdoc RoycoDayKernel
    /// @dev Routes the add through the Vault's query mode (`quote`) so it simulates the BPT minted without settling balances or moving tokens
    function _quoteAddLiquidity(uint256 _seniorShares, uint256 _quoteAssets) internal override(RoycoDayKernel) returns (TRANCHE_UNIT ltAssets) {
        bytes memory callbackReturnData = _vault.quote(abi.encodeCall(this.quoteAddBalancerV3Liquidity, (_seniorShares, _quoteAssets)));
        ltAssets = toTrancheUnits(abi.decode(callbackReturnData, (uint256)));
    }

    /// @inheritdoc RoycoDayKernel
    /// @dev Unlocks the Balancer V3 Vault and dispatches into the remove liquidity callback above
    /// @dev The vault is required to be unlocked with a callback in order to transition into a transient accounting state, expecting the callback to settle all credit and debt before returning
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
    function _reinvestLiquidityPremium(uint256) internal override(RoycoDayKernel) {
        // Deploy the LT's idle ST shares into its market making inventory
        RoycoDayKernelState storage $ = _getRoycoDayKernelStorage();
        uint256 ltOwnedSeniorTrancheShares = $.ltOwnedSeniorTrancheShares;
        if (ltOwnedSeniorTrancheShares == 0) return;

        // Value the ST shares that need to be reinvested in NAV units
        uint256 seniorTrancheTotalSupply = IERC20(SENIOR_TRANCHE).totalSupply();
        NAV_UNIT ltOwnedSeniorTrancheSharesNAV = seniorTrancheTotalSupply == 0
            ? ZERO_NAV_UNITS
            : IRoycoDayAccountant(ACCOUNTANT).getLastSTEffectiveNAV().mulDiv(ltOwnedSeniorTrancheShares, seniorTrancheTotalSupply, Math.Rounding.Floor);
        // Mark that senior NAV to its fair BPT at the manipulation-resistant oracle, then discount by the max tolerated slippage for the gate floor
        TRANCHE_UNIT fairLTAssets = ltConvertNAVUnitsToTrancheUnits(ltOwnedSeniorTrancheSharesNAV);
        TRANCHE_UNIT minLTAssetsOut = fairLTAssets.mulDiv((WAD - _getBalancerV3_LT_QuoterStorage().maxReinvestmentSlippageWAD), WAD, Math.Rounding.Ceil);

        // Single-sided add the ST shares through a low-level call into the Vault's callback
        // The inner unlock dispatches addBalancerV3Liquidity, which mints the BPT bounded by minLTAssetsOut and settles the shares in
        (bool reinvestmentSucceeded, bytes memory returnData) = address(_vault)
            .call(abi.encodeCall(_vault.unlock, (abi.encodeCall(this.addBalancerV3Liquidity, (ltOwnedSeniorTrancheShares, uint256(0), minLTAssetsOut)))));
        // On a breached gate (or any add revert) the premium shares remain idle: no state mutated here, the inner frame rolled back
        if (!reinvestmentSucceeded) return;

        // Decode the BPT minted from the single-sided provision
        TRANCHE_UNIT ltAssetsMinted;
        assembly ("memory-safe") {
            ltAssetsMinted := mload(add(returnData, 0x60))
        }

        // Debit the reinvested ST shares and credit the BPT minted from/to the LT
        $.ltOwnedSeniorTrancheShares -= ltOwnedSeniorTrancheShares;
        $.ltOwnedYieldBearingAssets = $.ltOwnedYieldBearingAssets + ltAssetsMinted;

        emit LiquidityPremiumReinvested(ltOwnedSeniorTrancheShares, ltAssetsMinted);
    }

    // =============================
    // Admin Functions
    // =============================

    /**
     * @notice Sets the BPT oracle used to value the liquidity tranche
     * @param _bptOracle The new manipulation-resistant balancer pool token (BPT) oracle
     * @param _syncBeforeUpdate Whether to sync the tranche accounting against the outgoing oracle before updating the BPT oracle
     */
    function setBPTOracle(address _bptOracle, bool _syncBeforeUpdate) external restricted {
        // If specified, sync the tranche accounting against the outgoing oracle before updating it
        if (_syncBeforeUpdate) _preOpSyncTrancheAccounting();
        // Update the BPT oracle
        _setBPTOracle(_bptOracle);
        // Sync the tranche accounting against the incoming oracle so the committed liquidity tranche raw NAV reflects it
        _preOpSyncTrancheAccounting();
    }

    /// @notice Sets the maximum slippage tolerated when single-sided reinvesting the liquidity premium into the BPT
    /// @param _maxReinvestmentSlippageWAD The new maximum reinvestment slippage tolerance, scaled to WAD precision
    function setMaxReinvestmentSlippage(uint64 _maxReinvestmentSlippageWAD) external restricted {
        _setMaxReinvestmentSlippage(_maxReinvestmentSlippageWAD);
    }

    /// @notice Returns the Balancer V3 quoter configuration (the BPT oracle and the maximum reinvestment slippage tolerance)
    function getBalancerQuoterConfiguration() external pure returns (BalancerV3_LT_QuoterState memory) {
        return _getBalancerV3_LT_QuoterStorage();
    }

    /// @notice Sets the new BPT oracle
    /// @param _bptOracle The new manipulation-resistant balancer pool token (BPT) oracle
    function _setBPTOracle(address _bptOracle) internal {
        require(_bptOracle != address(0), NULL_ADDRESS());
        _getBalancerV3_LT_QuoterStorage().bptOracle = _bptOracle;
        emit BPTOracleUpdated(_bptOracle);
    }

    /// @notice Sets the new maximum reinvestment slippage tolerance
    /// @param _maxReinvestmentSlippageWAD The new maximum reinvestment slippage tolerance, scaled to WAD precision
    function _setMaxReinvestmentSlippage(uint64 _maxReinvestmentSlippageWAD) internal {
        require(_maxReinvestmentSlippageWAD < WAD, INVALID_MAX_REINVESTMENT_SLIPPAGE());
        _getBalancerV3_LT_QuoterStorage().maxReinvestmentSlippageWAD = _maxReinvestmentSlippageWAD;
        emit MaxReinvestmentSlippageUpdated(_maxReinvestmentSlippageWAD);
    }

    /**
     * @notice Returns a storage pointer to the BalancerV3_LT_QuoterState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer to the quoter's state
     */
    function _getBalancerV3_LT_QuoterStorage() internal pure returns (BalancerV3_LT_QuoterState storage $) {
        assembly ("memory-safe") {
            $.slot := BALANCER_V3_LT_QUOTER_STORAGE_SLOT
        }
    }
}
