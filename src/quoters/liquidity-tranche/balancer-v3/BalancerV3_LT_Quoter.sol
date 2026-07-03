// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRateProvider } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { IVault } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import {
    AddLiquidityKind,
    AddLiquidityParams,
    RemoveLiquidityKind,
    RemoveLiquidityParams
} from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { LPOracleBase } from "../../../../lib/balancer-v3-monorepo/pkg/oracles/contracts/LPOracleBase.sol";
import { BalancerPoolToken } from "../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/BalancerPoolToken.sol";
import { VaultGuard } from "../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/VaultGuard.sol";
import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IRoycoDayAccountant } from "../../../interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../../interfaces/IRoycoDayKernel.sol";
import { WAD, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../../../libraries/Constants.sol";
import { RoycoDayKernelMathLib } from "../../../libraries/RoycoDayKernelMathLib.sol";
import { SyncedAccountingState } from "../../../libraries/Types.sol";
import { Math, NAV_UNIT, TRANCHE_UNIT, UnitsMathLib, toNAVUnits, toTrancheUnits, toUint256 } from "../../../libraries/Units.sol";
import { RoycoDayQuoter } from "../../base/RoycoDayQuoter.sol";

/**
 * @title BalancerV3_LT_Quoter
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice A quoter for liquidity tranches using Balancer V3 pools (ST share <> Quote asset) as their secondary liquidity venue
 * @notice The liquidity tranche asset is a Balancer Pool Token (BPT) between this market's senior tranche share and quote asset
 * @dev The view-only half of the Balancer V3 liquidity tranche: it values the BPT, is the pool's senior-share rate provider, and
 *      simulates the venue add/remove for previews. The settling execution callbacks live on the kernel's Balancer V3 venue
 */
abstract contract BalancerV3_LT_Quoter is RoycoDayQuoter, VaultGuard, IRateProvider {
    using UnitsMathLib for NAV_UNIT;
    using UnitsMathLib for TRANCHE_UNIT;

    /// @dev Storage slot for BalancerV3_LT_QuoterState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.BalancerV3_LT_QuoterState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BALANCER_V3_LT_QUOTER_STORAGE_SLOT = 0x8a7de9cdb687047f7d2fa86cad84bde8f19c3d8b5242f498d1bd0c4e66164e00;

    /// @notice Index of the Senior Tranche share token in the pool's token registration order
    uint256 internal immutable ST_SHARE_POOL_INDEX;

    /// @notice Index of the quote asset in the pool's token registration order
    uint256 internal immutable QUOTE_ASSET_POOL_INDEX;

    /// @dev The senior tranche share rate (senior NAV per share, scaled to WAD) frozen by each pre-op sync so an inline senior share mint or burn cannot transiently move the pool's senior-leg mark. It is scoped to the transaction via EIP-1153 rather than cleared per operation: unset until the first sync of a transaction (getRate then previews the rate live), re-frozen by every subsequent sync, and auto-cleared at transaction end. A same-transaction read after an operation returns that operation's rate, which equals a fresh preview since the committed state is unchanged
    uint256 internal transient cachedSTShareRateWAD;

    /**
     * @notice The namespaced storage for the BalancerV3_LT_Quoter
     * @custom:field bptOracle - The manipulation-resistant Balancer V3 pool token (BPT) oracle used to value the liquidity tranche assets
     */
    struct BalancerV3_LT_QuoterState {
        address bptOracle;
    }

    /// @notice Emitted when the BPT oracle used to value the liquidity tranche is updated
    event BPTOracleUpdated(address indexed bptOracle);

    /// @notice Thrown when the Balancer pool is not configured with exactly two tokens (ST share and the kernel's quote asset)
    error POOL_MUST_HAVE_TWO_TOKENS();

    /// @notice Thrown when neither of the pool's two tokens is the senior tranche share
    error INVALID_POOL_TOKEN_CONFIGURATION();

    /// @param _roycoDayKernel The kernel this quoter prices (its Balancer V3 Vault and pool wiring are resolved from the kernel's LT asset)
    constructor(address _roycoDayKernel)
        RoycoDayQuoter(_roycoDayKernel)
        VaultGuard(BalancerPoolToken(IRoycoDayKernel(_roycoDayKernel).LT_ASSET()).getVault())
    {
        // Resolve and cache the pool token indices, mirroring the kernel venue's registration lookup
        IERC20[] memory tokens = _vault.getPoolTokens(LT_ASSET);
        require(tokens.length == 2, POOL_MUST_HAVE_TWO_TOKENS());
        if (address(tokens[0]) == SENIOR_TRANCHE) QUOTE_ASSET_POOL_INDEX = 1;
        else if (address(tokens[1]) == SENIOR_TRANCHE) ST_SHARE_POOL_INDEX = 1;
        else revert INVALID_POOL_TOKEN_CONFIGURATION();
    }

    /**
     * @notice The quoter-specific initialization parameters
     * @custom:field bptOracle - The manipulation-resistant Balancer V3 pool token (BPT) oracle used to value the liquidity tranche
     */
    struct LT_QuoterSpecificParams {
        address bptOracle;
    }

    /// @notice Initializes the Balancer V3 liquidity tranche quoter
    /// @param _params The quoter-specific initialization parameters
    function __BalancerV3_LT_Quoter_init_unchained(LT_QuoterSpecificParams calldata _params) internal onlyInitializing {
        _setBPTOracle(_params.bptOracle);
    }

    // =============================
    // Liquidity Tranche Quoter Functions
    // =============================

    /**
     * @inheritdoc RoycoDayQuoter
     * @dev Values the BPT amount at the liquidity venue's manipulation-resistant NAV per BPT (the oracle's total NAV over the BPT
     *      supply), rounding down so the liquidity tranche's NAV is never overstated
     * @dev The oracle is read live on every call rather than through the quoter cache: the kernel mints, joins, and exits the pool
     *      within a single transaction, so a value cached at the start of the operation would be stale by the time it is consumed
     */
    function ltConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _ltAssets) public view virtual override(RoycoDayQuoter) returns (NAV_UNIT) {
        TRANCHE_UNIT bptTotalSupply = toTrancheUnits(_vault.totalSupply(LT_ASSET));
        if (bptTotalSupply == ZERO_TRANCHE_UNITS) return ZERO_NAV_UNITS;
        NAV_UNIT bptTotalNAV = toNAVUnits(LPOracleBase(_getBalancerV3_LT_QuoterStorage().bptOracle).computeTVL());
        return bptTotalNAV.mulDiv(_ltAssets, bptTotalSupply, Math.Rounding.Floor);
    }

    /// @inheritdoc RoycoDayQuoter
    /// @dev Converts the NAV amount to a BPT amount at the same live, manipulation-resistant NAV per BPT, rounding down
    function ltConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) public view virtual override(RoycoDayQuoter) returns (TRANCHE_UNIT) {
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
     * @dev Values one senior tranche share in NAV units, the rate at which the pool prices its senior share leg
     * @dev Within a synchronized operation the rate is frozen to the value the pre-op sync cached, so an inline senior share mint or burn (a multi-asset deposit or redemption) cannot transiently move the senior-leg mark before the matching effective NAV is committed
     * @dev Before the first sync of a transaction the cache is unset, so a standalone pool interaction or an off-chain read previews the fresh rate the next sync would resolve from committed state
     */
    function getRate() external view virtual override(IRateProvider) returns (uint256 rate) {
        // Within a synchronized operation, return the rate the pre-op sync froze
        (bool cacheHit, uint256 cachedSTShareRate) = _decodeCachedValue(cachedSTShareRateWAD);
        if (cacheHit) return cachedSTShareRate;

        // Outside a synchronized operation preview the sync the accountant would commit and value the senior share against its post-mint supply
        // NOTE: The accountant's preview is read directly (never the kernel's) so pricing the senior leg never recurses back into the liquidity tranche mark
        SyncedAccountingState memory state =
            IRoycoDayAccountant(ACCOUNTANT).previewSyncTrancheAccounting(ROYCO_DAY_KERNEL.getSeniorTrancheRawNAV(), ROYCO_DAY_KERNEL.getJuniorTrancheRawNAV());
        (,, uint256 stTotalSupply) = RoycoDayKernelMathLib.computeSTFeeAndLiquidityPremiumSharesToMint(state, IERC20(SENIOR_TRANCHE).totalSupply());
        return _computeSTShareRate(state.stEffectiveNAV, stTotalSupply);
    }

    /// @inheritdoc RoycoDayQuoter
    /// @dev Freezes the post-mint senior share rate resolved by the pre-op sync: the accountant commits the senior effective NAV before this sync's premium and fee shares are minted, so caching the rate here lets an inline senior share mint or burn move the live supply within the operation without moving the senior-leg mark before the matching effective NAV is committed
    function _cacheSTShareRate(NAV_UNIT _stEffectiveNAV, uint256 _stTotalSupplyAfterMints) internal virtual override(RoycoDayQuoter) {
        cachedSTShareRateWAD = _computeSTShareRate(_stEffectiveNAV, _stTotalSupplyAfterMints) | CACHE_SET_MASK;
    }

    /**
     * @notice Computes the senior tranche share rate (senior NAV per share) from a synced senior effective NAV and its post-mint supply
     * @dev Shared by the pre-op cache and the standalone fallback so both resolve an identical rate
     * @param _stEffectiveNAV The synced senior tranche effective NAV
     * @param _stTotalSupply The senior tranche share supply after this sync's liquidity premium and ST protocol fee shares are minted, the per-share denominator
     * @return rate The senior tranche share rate in NAV units, scaled to WAD precision
     */
    function _computeSTShareRate(NAV_UNIT _stEffectiveNAV, uint256 _stTotalSupply) internal pure returns (uint256 rate) {
        // Before the senior tranche is seeded there are no shares to price: return a neutral 1.0 rate so the pool never divides by zero
        if (_stTotalSupply == 0) return WAD;

        // NOTE: Senior tranche shares always use WAD decimals of precision so WAD == 1 ST share
        rate = toUint256(_stEffectiveNAV.mulDiv(WAD, _stTotalSupply, Math.Rounding.Floor));

        // Floor the computed rate to 1 wei to prevent reversions in the underlying balancer pool
        if (rate == 0) rate = 1;
    }

    // =============================
    // Preview-only Vault callbacks (no settlement) — dispatched by Vault.quote, guarded to the Vault
    // =============================

    /// @notice Simulates the unbalanced BPT mint the kernel's add would perform (query mode: no settlement, reverted by the Vault)
    function previewAddBalancerV3Liquidity(uint256 _seniorShares, uint256 _quoteAssets) external onlyVault returns (uint256 ltAssets) {
        uint256[] memory exactAmountsIn = new uint256[](2);
        exactAmountsIn[ST_SHARE_POOL_INDEX] = _seniorShares;
        exactAmountsIn[QUOTE_ASSET_POOL_INDEX] = _quoteAssets;
        (, ltAssets,) = _vault.addLiquidity(
            AddLiquidityParams({
                pool: LT_ASSET, to: address(this), maxAmountsIn: exactAmountsIn, minBptAmountOut: 0, kind: AddLiquidityKind.UNBALANCED, userData: ""
            })
        );
    }

    /// @notice Simulates the proportional BPT unwrap the kernel's removal would perform (query mode: no settlement, reverted by the Vault)
    function previewRemoveBalancerV3Liquidity(TRANCHE_UNIT _ltAssets) external onlyVault returns (uint256 stShares, uint256 quoteAssets) {
        uint256[] memory minAmountsOut = new uint256[](2);
        (, uint256[] memory amountsOut,) = _vault.removeLiquidity(
            RemoveLiquidityParams({
                pool: LT_ASSET,
                from: address(this),
                maxBptAmountIn: toUint256(_ltAssets),
                minAmountsOut: minAmountsOut,
                kind: RemoveLiquidityKind.PROPORTIONAL,
                userData: ""
            })
        );
        stShares = amountsOut[ST_SHARE_POOL_INDEX];
        quoteAssets = amountsOut[QUOTE_ASSET_POOL_INDEX];
    }

    // =============================
    // Venue preview hooks (RoycoDayQuoter)
    // =============================

    /// @inheritdoc RoycoDayQuoter
    /// @dev Routes the add through the Vault's query mode (`quote`), which re-enters this contract's preview callback
    function _previewAddLiquidity(uint256 _seniorShares, uint256 _quoteAssets) internal override(RoycoDayQuoter) returns (TRANCHE_UNIT ltAssets) {
        bytes memory callbackReturnData = _vault.quote(abi.encodeCall(this.previewAddBalancerV3Liquidity, (_seniorShares, _quoteAssets)));
        assembly ("memory-safe") {
            ltAssets := mload(add(callbackReturnData, 0x20))
        }
    }

    /// @inheritdoc RoycoDayQuoter
    /// @dev Routes the removal through the Vault's query mode (`quote`), which re-enters this contract's preview callback
    function _previewRemoveLiquidity(TRANCHE_UNIT _ltAssets) internal override(RoycoDayQuoter) returns (uint256 stShares, uint256 quoteAssets) {
        bytes memory callbackReturnData = _vault.quote(abi.encodeCall(this.previewRemoveBalancerV3Liquidity, (_ltAssets)));
        assembly ("memory-safe") {
            stShares := mload(add(callbackReturnData, 0x20))
            quoteAssets := mload(add(callbackReturnData, 0x40))
        }
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
        if (_syncBeforeUpdate) ROYCO_DAY_KERNEL.syncTrancheAccounting();
        // Update the BPT oracle
        _setBPTOracle(_bptOracle);
        // Sync the tranche accounting against the incoming oracle so the committed liquidity tranche raw NAV reflects it
        ROYCO_DAY_KERNEL.syncTrancheAccounting();
    }

    /// @notice Returns the Balancer V3 quoter configuration (the BPT oracle)
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
