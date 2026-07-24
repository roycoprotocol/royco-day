// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import { IRateProvider } from "../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { IVault } from "../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { LPOracleBase } from "../../../../../lib/balancer-v3-monorepo/pkg/oracles/contracts/LPOracleBase.sol";
import { BalancerPoolToken } from "../../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/BalancerPoolToken.sol";
import { VaultGuard } from "../../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/VaultGuard.sol";
import { IERC20 } from "../../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "../../../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { IRoycoDayAccountant } from "../../../../interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../../../interfaces/IRoycoDayKernel.sol";
import { IRoycoPriceOracle } from "../../../../interfaces/IRoycoPriceOracle.sol";
import { Cache, CacheKey } from "../../../../libraries/Cache.sol";
import { WAD, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../../../../libraries/Constants.sol";
import { Math, NAV_UNIT, RoycoUnitsMath, TRANCHE_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../../../libraries/Units.sol";
import { DispatchLogic } from "../../../../libraries/logic/DispatchLogic.sol";
import { FeeAndLiquidityPremiumLogic } from "../../../../libraries/logic/FeeAndLiquidityPremiumLogic.sol";
import { ValuationLogic } from "../../../../libraries/logic/ValuationLogic.sol";
import { RoycoDayKernel, SyncedAccountingState } from "../../RoycoDayKernel.sol";
import { IBalancerV3VenueCallbacks } from "./interfaces/IBalancerV3VenueCallbacks.sol";
import { BalancerV3VenueLogic } from "./libraries/BalancerV3VenueLogic.sol";

/**
 * @title BalancerV3LiquidityVenue
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice The liquidity venue for liquidity provider tranches using Balancer V3 pools (ST share <> Quote asset) as their secondary liquidity venue
 * @notice The liquidity provider tranche (LPT) asset is a Balancer Pool Token (BPT) between this kernel's senior tranche share and a quote asset
 */
abstract contract BalancerV3LiquidityVenue is RoycoDayKernel, VaultGuard, IRateProvider, IBalancerV3VenueCallbacks {
    using RoycoUnitsMath for NAV_UNIT;
    using RoycoUnitsMath for TRANCHE_UNIT;
    using SafeERC20 for IERC20;
    using DispatchLogic for address;

    /// @dev Storage slot for BalancerV3LiquidityVenueState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.BalancerV3LiquidityVenueState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BALANCER_V3_LIQUIDITY_VENUE_STORAGE_SLOT = 0x6acdb3c7456d7977317bc93eaa2681ec68014f836d3a13d257053a0d594f9a00;

    /// @notice Index of the Senior Tranche share token in the pool's token registration order
    uint256 internal immutable ST_SHARE_POOL_INDEX;

    /// @notice Index of the quote asset in the pool's token registration order
    uint256 internal immutable QUOTE_ASSET_POOL_INDEX;

    /// @inheritdoc RoycoDayKernel
    /// @dev Resolved from this kernel's BPT registration
    address public immutable override(RoycoDayKernel) QUOTE_ASSET;

    /**
     * @notice The namespaced storage for the BalancerV3LiquidityVenue
     * @custom:storage-location erc7201:Royco.storage.BalancerV3LiquidityVenueState
     * @custom:field bptOracle - The manipulation-resistant Balancer V3 pool token (BPT) oracle used to value the liquidity provider tranche assets
     * @custom:field maxReinvestmentSlippageWAD - The maximum slippage tolerated when single-sided reinvesting the liquidity premium ST shares into the BPT, scaled to WAD precision, a reinvestment breaching it is skipped and the premium shares remain idle
     */
    struct BalancerV3LiquidityVenueState {
        address bptOracle;
        uint64 maxReinvestmentSlippageWAD;
    }

    /**
     * @notice The liquidity venue initialization parameters
     * @custom:field bptOracle - The manipulation-resistant Balancer V3 pool token (BPT) oracle used to value the liquidity provider tranche
     * @custom:field maxReinvestmentSlippageWAD - The maximum slippage tolerated when single-sided reinvesting the ST shares minted as a liquidity premium into the Balancer V3 Pool, scaled to WAD precision
     */
    struct LiquidityVenueInitParams {
        address bptOracle;
        uint64 maxReinvestmentSlippageWAD;
    }

    /// @notice Emitted when the BPT oracle used to value the liquidity provider tranche is updated
    event BPTOracleUpdated(address indexed bptOracle);

    /// @notice Emitted when the maximum reinvestment slippage tolerance is updated
    /// @param maxReinvestmentSlippageWAD The new maximum slippage tolerated when single-sided reinvesting the liquidity premium into the BPT, scaled to WAD precision
    event MaxReinvestmentSlippageUpdated(uint64 maxReinvestmentSlippageWAD);

    /// @notice Thrown when the Balancer V3 Vault passed to the constructor is not the one the pool is registered with
    error INVALID_BALANCER_V3_VAULT();

    /// @notice Thrown when the Balancer pool is not registered with the Balancer V3 Vault
    error POOL_NOT_REGISTERED();

    /// @notice Thrown when the Balancer pool is not configured with exactly two tokens (ST share and the kernel's quote asset)
    error POOL_MUST_HAVE_TWO_TOKENS();

    /// @notice Thrown when neither of the pool's two tokens is the senior tranche share
    error INVALID_POOL_TOKEN_CONFIGURATION();

    /// @notice Thrown when the configured maximum reinvestment slippage is not strictly less than WAD (100%)
    error INVALID_MAX_REINVESTMENT_SLIPPAGE();

    /// @notice Thrown when the BPT oracle prices a pool other than this market's registered liquidity provider tranche pool
    error BPT_ORACLE_POOL_MISMATCH();

    /// @notice Thrown when setting a BPT oracle configured to revert while the vault is unlocked, the venue reads it through the unlocked vault (previews and hooks)
    error BPT_ORACLE_CANNOT_REVERT_WHILE_VAULT_UNLOCKED();

    /// @notice Constructs the Balancer V3 liquidity venue
    /// @param _balancerV3Vault The instance of the singleton Balancer V3 Vault
    constructor(IVault _balancerV3Vault) VaultGuard(_balancerV3Vault) {
        // Ensure the passed vault is the one the pool (LPT_ASSET) is registered with (LPT_ASSET reads fine here in the body)
        require(address(BalancerPoolToken(LPT_ASSET).getVault()) == address(_balancerV3Vault), INVALID_BALANCER_V3_VAULT());
        // Ensure that the Balancer V3 Pool is registered with the vault
        require(_vault.isPoolRegistered(LPT_ASSET), POOL_NOT_REGISTERED());

        // Retrieve the constituent tokens of this kernel's Balancer V3 pool and ensure that there are exactly 2
        IERC20[] memory tokens = _vault.getPoolTokens(LPT_ASSET);
        require(tokens.length == 2, POOL_MUST_HAVE_TWO_TOKENS());

        // Resolve and cache the indexes of the ST share and the quote asset
        // Revert if the pool is not configured with the senior tranche share as one of its two constituents
        if (address(tokens[0]) == SENIOR_TRANCHE) QUOTE_ASSET_POOL_INDEX = 1;
        else if (address(tokens[1]) == SENIOR_TRANCHE) ST_SHARE_POOL_INDEX = 1;
        else revert INVALID_POOL_TOKEN_CONFIGURATION();

        // Immutable set the quote asset address from the pool registration
        QUOTE_ASSET = address(tokens[QUOTE_ASSET_POOL_INDEX]);
    }

    /// @notice Initializes the Balancer V3 liquidity venue
    /// @param _params The liquidity venue initialization parameters
    function __BalancerV3LiquidityVenue_init_unchained(LiquidityVenueInitParams calldata _params) internal onlyInitializing {
        _setBPTOracle(_params.bptOracle);
        _setMaxReinvestmentSlippage(_params.maxReinvestmentSlippageWAD);
    }

    // =============================
    // Liquidity Venue Functions
    // =============================

    /**
     * @inheritdoc RoycoDayKernel
     * @dev Values the BPT amount at the liquidity venue's manipulation-resistant NAV per BPT (the oracle's total NAV over the BPT
     *      supply), rounding down so the liquidity provider tranche's NAV is never overstated
     * @dev The oracle is read live on every call rather than through the price cache: the kernel mints, joins, and exits the pool
     *      within a single transaction, so a value cached at the start of the operation would be stale by the time it is consumed
     */
    function convertLPTAssetsToValue(TRANCHE_UNIT _lptAssets) public view virtual override(RoycoDayKernel) returns (NAV_UNIT) {
        TRANCHE_UNIT bptTotalSupply = toTrancheUnits(_vault.totalSupply(LPT_ASSET));
        if (bptTotalSupply == ZERO_TRANCHE_UNITS) return ZERO_NAV_UNITS;
        NAV_UNIT bptTotalNAV = toNAVUnits(LPOracleBase(_getBalancerV3LiquidityVenueStorage().bptOracle).computeTVL());
        return bptTotalNAV.mulDiv(_lptAssets, bptTotalSupply, Math.Rounding.Floor);
    }

    /// @inheritdoc RoycoDayKernel
    /// @dev Converts the NAV amount to a BPT amount at the same live, manipulation-resistant NAV per BPT, rounding down
    function convertValueToLPTAssets(NAV_UNIT _value) public view virtual override(RoycoDayKernel) returns (TRANCHE_UNIT) {
        TRANCHE_UNIT bptTotalSupply = toTrancheUnits(_vault.totalSupply(LPT_ASSET));
        if (bptTotalSupply == ZERO_TRANCHE_UNITS) return ZERO_TRANCHE_UNITS;
        NAV_UNIT bptTotalNAV = toNAVUnits(LPOracleBase(_getBalancerV3LiquidityVenueStorage().bptOracle).computeTVL());
        return bptTotalSupply.mulDiv(_value, bptTotalNAV, Math.Rounding.Floor);
    }

    // =============================
    // Senior Share Rate Provider Function
    // =============================

    /**
     * @inheritdoc IRateProvider
     * @dev Reverts when the kernel is paused to ensure that the pool never executes operations on a faulty kernel state
     * @dev Values one senior tranche share in NAV units, the rate at which the pool prices its senior share leg
     * @dev Within a synchronized operation the returned rate is the one the pre-op sync cached, so an inline senior share mint or burn (a multi-asset deposit or redemption) cannot transiently move the senior-leg mark before the matching effective NAV is committed
     * @dev Before the first sync of a transaction the cache is unset, so a standalone pool interaction or an off-chain read previews the fresh rate the next sync would resolve from committed state
     * @dev The rate is floored to a minimum of 1 wei so the pool never receives a zero rate, which it would reject
     * @dev Before the senior tranche is seeded (zero ST supply) the rate resolves to that 1-wei floor rather than a neutral 1.0, this is inert because with no ST shares in existence the pool's ST leg is empty, so the rate only ever scales a zero balance until the tranche is seeded
     */
    function getRate() external view override(IRateProvider) whenNotPaused returns (uint256 rate) {
        // Query the cache for the ST share price
        bool cacheHit;
        (cacheHit, rate) = Cache._read(CacheKey.ST_SHARE_PRICE);

        // On a cache miss, value the senior share against the post-sync ST effective NAV and total supply
        if (!cacheHit) {
            RoycoDayKernelState storage $ = _getRoycoDayKernelStorage();
            // Simulate the poke first so a circuit-breaking oracle halts pool pricing identically to the kernel's operations
            IRoycoPriceOracle($.collateralAssetOracle).previewPoke();
            // NOTE: The accountant's preview is read directly so pricing the senior leg never recurses back into the liquidity provider tranche mark
            SyncedAccountingState memory state = IRoycoDayAccountant(ACCOUNTANT).previewSyncTrancheAccounting(ValuationLogic._getCollateralNAV($));
            (,, uint256 stTotalSupply) = FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(state, IERC20(SENIOR_TRANCHE).totalSupply());

            // Compute the ST share rate
            rate = toUint256(ValuationLogic._computeTrancheShareRate(stTotalSupply, state.stEffectiveNAV));
        }

        // Floor the ST share rate to 1 wei so the Balancer pool never receives a zero rate, which it would reject
        return (rate == 0 ? 1 : rate);
    }

    // =============================
    // Balancer V3 Liquidity Provider Tranche Venue Hooks
    // =============================

    /**
     * @inheritdoc IRoycoDayKernel
     * @dev Dispatches the add liquidity callback below through the unlocked Vault
     * @dev A preview unwinds every transient balance change via the callback's result-carrying revert
     * @dev Only invoked via a self-call from the kernel's delegatecall logic libraries
     */
    function addLiquidity(
        bool _isPreview,
        uint256 _seniorShares,
        uint256 _quoteAssets,
        TRANCHE_UNIT _minLPTAssetsOut
    )
        external
        override(IRoycoDayKernel)
        onlySelf
        returns (TRANCHE_UNIT lptAssets, NAV_UNIT depositNAV, NAV_UNIT postOpLPTRawNAV)
    {
        // Both transports yield the unlock's ABI encoded bytes return byte for byte
        (lptAssets, depositNAV, postOpLPTRawNAV) = abi.decode(
            abi.decode(
                address(_vault)
                    ._dispatch(
                        _isPreview,
                        abi.encodeCall(
                            _vault.unlock, (abi.encodeCall(this.addBalancerV3Liquidity, (_isPreview, _seniorShares, _quoteAssets, _minLPTAssetsOut)))
                        )
                    ),
                (bytes)
            ),
            (TRANCHE_UNIT, NAV_UNIT, NAV_UNIT)
        );
    }

    /**
     * @inheritdoc IRoycoDayKernel
     * @dev Dispatches the remove liquidity callback below through the unlocked Vault
     * @dev A preview unwinds every transient balance change via the callback's result-carrying revert
     * @dev Only invoked via a self-call from the kernel's delegatecall logic libraries
     */
    function removeLiquidity(
        bool _isPreview,
        TRANCHE_UNIT _lptAssets,
        uint256 _minSTSharesOut,
        uint256 _minQuoteAssetsOut,
        address _quoteAssetsReceiver
    )
        external
        override(IRoycoDayKernel)
        onlySelf
        returns (uint256 stShares, uint256 quoteAssets, NAV_UNIT postOpLPTRawNAV)
    {
        // Both transports yield the unlock's ABI encoded bytes return byte for byte
        (stShares, quoteAssets, postOpLPTRawNAV) = abi.decode(
            abi.decode(
                address(_vault)
                    ._dispatch(
                        _isPreview,
                        abi.encodeCall(
                            _vault.unlock,
                            (abi.encodeCall(
                                    this.removeBalancerV3Liquidity, (_isPreview, _lptAssets, _minSTSharesOut, _minQuoteAssetsOut, _quoteAssetsReceiver)
                                ))
                        )
                    ),
                (bytes)
            ),
            (uint256, uint256, NAV_UNIT)
        );
    }

    /**
     * @inheritdoc IRoycoDayKernel
     * @dev Deploys the idle liquidity-premium senior share balance the kernel holds into the BPT via a gated single-sided add
     * @dev The min-BPT-out floors the add at the manipulation-resistant oracle's fair value (not the pool spot) less the max reinvestment slippage, so a manipulated pool cannot widen the tolerance
     * @dev Tolerates reversions to ensure a tranche operation doesn't revert on a failing reinvestment
     * @dev Only invoked via a self-call from the kernel's delegatecall logic libraries
     */
    function attemptLiquidityPremiumReinvestment(
        uint256 _stSharesToReinvest,
        NAV_UNIT _stEffectiveNAV,
        uint256 _totalSTShares
    )
        external
        override(IRoycoDayKernel)
        onlySelf
    {
        BalancerV3VenueLogic.attemptLiquidityPremiumReinvestment(
            _getRoycoDayKernelStorage(),
            _getBalancerV3VenueImmutableState(),
            _getBalancerV3LiquidityVenueStorage().maxReinvestmentSlippageWAD,
            _stSharesToReinvest,
            _stEffectiveNAV,
            _totalSTShares
        );
    }

    // =============================
    // Balancer V3 Liquidity Position Callback Functions
    // =============================

    /// @inheritdoc IBalancerV3VenueCallbacks
    function addBalancerV3Liquidity(
        bool _isPreview,
        uint256 _seniorShares,
        uint256 _quoteAssets,
        TRANCHE_UNIT _minLPTAssetsOut
    )
        external
        override(IBalancerV3VenueCallbacks)
        onlyVault
        returns (uint256 lptAssets, NAV_UNIT depositNAV, NAV_UNIT postOpLPTRawNAV)
    {
        return BalancerV3VenueLogic.addBalancerV3Liquidity(
            _getBalancerV3VenueImmutableState(), _isPreview, _getRoycoDayKernelStorage().totalLPTAssets, _seniorShares, _quoteAssets, _minLPTAssetsOut
        );
    }

    /// @inheritdoc IBalancerV3VenueCallbacks
    function removeBalancerV3Liquidity(
        bool _isPreview,
        TRANCHE_UNIT _lptAssets,
        uint256 _minSTSharesOut,
        uint256 _minQuoteAssetsOut,
        address _quoteAssetsReceiver
    )
        external
        override(IBalancerV3VenueCallbacks)
        onlyVault
        returns (uint256 stShares, uint256 quoteAssets, NAV_UNIT postOpLPTRawNAV)
    {
        return BalancerV3VenueLogic.removeBalancerV3Liquidity(
            _getBalancerV3VenueImmutableState(),
            _isPreview,
            _getRoycoDayKernelStorage().totalLPTAssets,
            _lptAssets,
            _minSTSharesOut,
            _minQuoteAssetsOut,
            _quoteAssetsReceiver
        );
    }

    // =============================
    // Admin Functions
    // =============================

    /**
     * @notice Sets the BPT oracle used to value the liquidity provider tranche
     * @param _bptOracle The new manipulation-resistant balancer pool token (BPT) oracle
     * @param _syncBeforeUpdate Whether to sync the tranche accounting against the outgoing oracle before updating the BPT oracle
     */
    function setBPTOracle(address _bptOracle, bool _syncBeforeUpdate) external restricted {
        // If specified, sync the tranche accounting against the outgoing oracle before updating it
        if (_syncBeforeUpdate) _preOpSyncTrancheAccountingWithFreshCache();
        // Update the BPT oracle
        _setBPTOracle(_bptOracle);
        // Sync the tranche accounting against the incoming oracle so the committed liquidity provider tranche raw NAV reflects it
        _preOpSyncTrancheAccountingWithFreshCache();
    }

    /// @notice Sets the maximum slippage tolerated when single-sided reinvesting the liquidity premium into the BPT
    /// @param _maxReinvestmentSlippageWAD The new maximum reinvestment slippage tolerance, scaled to WAD precision
    function setMaxReinvestmentSlippage(uint64 _maxReinvestmentSlippageWAD) external restricted {
        _setMaxReinvestmentSlippage(_maxReinvestmentSlippageWAD);
    }

    // =============================
    // Internal Utility Functions
    // =============================

    /// @inheritdoc RoycoDayKernel
    /// @dev The Balancer V3 Vault escrows every pool's constituent assets, making the vault the custodian of the senior tranche shares backing the BPT
    function _isTrancheShareCustodian(address _account) internal view virtual override(RoycoDayKernel) returns (bool) {
        return (_account == address(_vault));
    }

    /// @notice Sets the new BPT oracle
    /// @param _bptOracle The new manipulation-resistant balancer pool token (BPT) oracle
    function _setBPTOracle(address _bptOracle) internal {
        require(address(LPOracleBase(_bptOracle).pool()) == LPT_ASSET, BPT_ORACLE_POOL_MISMATCH());
        // The venue reads the oracle while the vault is unlocked, so it must not revert on an unlocked vault
        require(!LPOracleBase(_bptOracle).getShouldRevertIfVaultUnlocked(), BPT_ORACLE_CANNOT_REVERT_WHILE_VAULT_UNLOCKED());
        _getBalancerV3LiquidityVenueStorage().bptOracle = _bptOracle;
        emit BPTOracleUpdated(_bptOracle);
    }

    /// @notice Sets the new maximum reinvestment slippage tolerance
    /// @param _maxReinvestmentSlippageWAD The new maximum reinvestment slippage tolerance, scaled to WAD precision
    function _setMaxReinvestmentSlippage(uint64 _maxReinvestmentSlippageWAD) internal {
        require(_maxReinvestmentSlippageWAD < WAD, INVALID_MAX_REINVESTMENT_SLIPPAGE());
        _getBalancerV3LiquidityVenueStorage().maxReinvestmentSlippageWAD = _maxReinvestmentSlippageWAD;
        emit MaxReinvestmentSlippageUpdated(_maxReinvestmentSlippageWAD);
    }

    // =============================
    // State Accessor Functions
    // =============================

    /**
     * @notice Builds the immutables carrier threaded into the Balancer V3 venue's delegatecall logic library
     * @dev A delegatecalled library cannot read the venue's immutables directly, so they are passed in via this struct
     * @return immutables The venue's Balancer V3 vault, required asset and tranche addresses, and the corresponding asset indexes in the pool
     */
    function _getBalancerV3VenueImmutableState() internal view returns (IBalancerV3VenueCallbacks.BalancerV3VenueImmutableState memory immutables) {
        return IBalancerV3VenueCallbacks.BalancerV3VenueImmutableState({
            vault: _vault,
            lptAsset: LPT_ASSET,
            seniorTranche: SENIOR_TRANCHE,
            quoteAsset: QUOTE_ASSET,
            stSharePoolIndex: ST_SHARE_POOL_INDEX,
            quoteAssetPoolIndex: QUOTE_ASSET_POOL_INDEX
        });
    }

    /// @notice Returns the Balancer V3 liquidity venue configuration (the BPT oracle and the maximum reinvestment slippage tolerance)
    function getBalancerV3LiquidityVenueState() external view returns (BalancerV3LiquidityVenueState memory) {
        return _getBalancerV3LiquidityVenueStorage();
    }

    /**
     * @notice Returns a storage pointer to the BalancerV3LiquidityVenueState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer to the venue's state
     */
    function _getBalancerV3LiquidityVenueStorage() internal pure returns (BalancerV3LiquidityVenueState storage $) {
        assembly ("memory-safe") {
            $.slot := BALANCER_V3_LIQUIDITY_VENUE_STORAGE_SLOT
        }
    }
}
