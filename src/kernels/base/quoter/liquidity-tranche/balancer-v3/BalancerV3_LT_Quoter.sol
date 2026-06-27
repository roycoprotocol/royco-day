// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRateProvider } from "../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
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

    /**
     * @notice The namespaced storage for the BalancerV3_LT_Quoter
     * @custom:field bptOracle - The manipulation-resistant Balancer pool token (BPT) oracle used to value the liquidity tranche
     */
    struct BalancerV3_LT_QuoterState {
        address bptOracle;
    }

    /// @notice Emitted when the BPT oracle used to value the liquidity tranche is updated
    event BptOracleUpdated(address indexed bptOracle);

    /// @notice Thrown when the Balancer pool is not registered with the Balancer V3 Vault
    error POOL_NOT_REGISTERED();

    /// @notice Thrown when the Balancer pool is not configured with exactly two tokens (ST share and the kernel's quote asset)
    error POOL_MUST_HAVE_TWO_TOKENS();

    /// @notice Thrown when the pool's tokens don't match the kernel's configured ST share and quote asset
    error INVALID_POOL_TOKEN_CONFIGURATION();

    constructor() VaultGuard(BalancerPoolToken(LT_ASSET).getVault()) {
        // Ensure that the Balancer V3 Pool is registered with the vault
        require(_vault.isPoolRegistered(LT_ASSET), POOL_NOT_REGISTERED());

        // Retrieve the constituent tokens of this kernel's Balancer V3 pool and ensure that their are exactly 2
        IERC20[] memory tokens = _vault.getPoolTokens(LT_ASSET);
        require(tokens.length == 2, POOL_MUST_HAVE_TWO_TOKENS());

        // Resolve and cache the indexes of the ST share and the kernel's quote asset in the pool configuration
        // Revert if the pool is not configured with ST share and the kernel's quote asset as its constituents
        if (address(tokens[0]) == SENIOR_TRANCHE && address(tokens[1]) == QUOTE_ASSET) QUOTE_ASSET_POOL_INDEX = 1;
        else if (address(tokens[0]) == QUOTE_ASSET && address(tokens[1]) == SENIOR_TRANCHE) ST_SHARE_POOL_INDEX = 1;
        else revert INVALID_POOL_TOKEN_CONFIGURATION();
    }

    /**
     * @notice Initializes the Balancer V3 liquidity tranche quoter
     * @param _bptOracle The manipulation-resistant balancer pool token (BPT) oracle used to value the liquidity tranche
     */
    function __BalancerV3_LT_Quoter_init_unchained(address _bptOracle) internal onlyInitializing {
        _setBptOracle(_bptOracle);
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
    // BPT Oracle Configuration Functions
    // =============================

    /**
     * @notice Sets the BPT oracle used to value the liquidity tranche
     * @param _bptOracle The new manipulation-resistant balancer pool token (BPT) oracle
     * @param _syncBeforeUpdate Whether to sync the tranche accounting against the outgoing oracle before updating the BPT oracle
     */
    function setBptOracle(address _bptOracle, bool _syncBeforeUpdate) external restricted {
        // If specified, sync the tranche accounting against the outgoing oracle before updating it
        if (_syncBeforeUpdate) _preOpSyncTrancheAccounting();
        // Update the BPT oracle
        _setBptOracle(_bptOracle);
        // Sync the tranche accounting against the incoming oracle so the committed liquidity tranche raw NAV reflects it
        _preOpSyncTrancheAccounting();
    }

    /// @notice Returns the BPT oracle configuration for this quoter
    function getBptOracleConfiguration() external pure returns (BalancerV3_LT_QuoterState memory) {
        return _getBalancerV3_LT_QuoterStorage();
    }

    /// @notice Sets the new BPT oracle
    /// @param _bptOracle The new manipulation-resistant balancer pool token (BPT) oracle
    function _setBptOracle(address _bptOracle) internal {
        require(_bptOracle != address(0), NULL_ADDRESS());
        _getBalancerV3_LT_QuoterStorage().bptOracle = _bptOracle;
        emit BptOracleUpdated(_bptOracle);
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
                kind: AddLiquidityKind.UNBALANCED, // Single-sided/unbalanced add; the Vault charges the pool's swap fee on the imbalanced portion
                userData: "" // UNBALANCED adds skip the pool's compute callback and this kernel's hooks do not consume userData
            })
        );

        // Settle the senior tranche shares and quote assets this kernel owes the Vault for the add by transferring them in and cancelling the debt
        IERC20(SENIOR_TRANCHE).safeTransfer(address(_vault), _seniorShares);
        _vault.settle(IERC20(SENIOR_TRANCHE), _seniorShares);
        IERC20(QUOTE_ASSET).safeTransfer(address(_vault), _quoteAssets);
        _vault.settle(IERC20(QUOTE_ASSET), _quoteAssets);
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
        _vault.sendTo(IERC20(SENIOR_TRANCHE), address(this), (stShares = amountsOut[ST_SHARE_POOL_INDEX]));
        // Credit the quote assets withdrawn to its specified receiver
        _vault.sendTo(IERC20(QUOTE_ASSET), _quoteAssetsReceiver, (quoteAssets = amountsOut[QUOTE_ASSET_POOL_INDEX]));
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
        // Unlock the Balancer vault, execute the callback to mint the liquidity position from the specified senior tranche shares and quote assets, and return the LT assets minted in the process
        bytes memory callbackReturnData = _vault.unlock(abi.encodeCall(this.addBalancerV3Liquidity, (_seniorShares, _quoteAssets, _minLTAssetsOut)));
        assembly ("memory-safe") {
            ltAssets := mload(add(callbackReturnData, 0x20))
        }
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
        // Unlock the Balancer vault, execute the callback to unwrap the specified units of the liquidity position, and return the ST shares withdrawn in the process
        bytes memory callbackReturnData =
            _vault.unlock(abi.encodeCall(this.removeBalancerV3Liquidity, (_ltAssets, _minSTSharesOut, _minQuoteAssetsOut, _quoteAssetsReceiver)));
        assembly ("memory-safe") {
            stShares := mload(add(callbackReturnData, 0x20))
            quoteAssets := mload(add(callbackReturnData, 0x40))
        }
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
