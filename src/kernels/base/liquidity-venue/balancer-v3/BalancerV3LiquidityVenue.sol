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
import { IBalancerV3LiquidityVenue } from "../../../../interfaces/liquidity-venue/IBalancerV3LiquidityVenue.sol";
import { Cache, CacheKey } from "../../../../libraries/Cache.sol";
import { WAD, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../../../../libraries/Constants.sol";
import { DispatchMode } from "../../../../libraries/Types.sol";
import { Math, NAV_UNIT, RoycoUnitsMath, TRANCHE_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../../../libraries/Units.sol";
import { DispatchLogic } from "../../../../libraries/logic/DispatchLogic.sol";
import { FeeAndLiquidityPremiumLogic } from "../../../../libraries/logic/FeeAndLiquidityPremiumLogic.sol";
import { ValuationLogic } from "../../../../libraries/logic/ValuationLogic.sol";
import { BalancerV3LiquidityVenueLogic } from "../../../../libraries/logic/liquidity-venue/BalancerV3LiquidityVenueLogic.sol";
import { RoycoDayKernel, SyncedAccountingState } from "../../RoycoDayKernel.sol";

/**
 * @title BalancerV3LiquidityVenue
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice The liquidity venue for liquidity provider tranches using Balancer V3 pools (ST share <> Quote asset) as their secondary liquidity venue
 * @notice The liquidity provider tranche (LPT) asset is a Balancer Pool Token (BPT) between this kernel's senior tranche share and a quote asset
 */
abstract contract BalancerV3LiquidityVenue is RoycoDayKernel, VaultGuard, IBalancerV3LiquidityVenue, IRateProvider {
    using RoycoUnitsMath for NAV_UNIT;
    using RoycoUnitsMath for TRANCHE_UNIT;
    using SafeERC20 for IERC20;
    using DispatchLogic for address;

    /// @dev Storage slot for BalancerV3LiquidityVenueState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.BalancerV3LiquidityVenueState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BALANCER_V3_LIQUIDITY_VENUE_STORAGE_SLOT = 0x6acdb3c7456d7977317bc93eaa2681ec68014f836d3a13d257053a0d594f9a00;

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

    /// @notice Thrown when the pool's first registered token is not the senior tranche share (the market requires the ST share as token0)
    error INVALID_POOL_TOKEN_CONFIGURATION();

    /// @notice Thrown when the configured maximum reinvestment slippage is not strictly less than WAD (100%)
    error INVALID_MAX_REINVESTMENT_SLIPPAGE();

    /// @notice Thrown when the BPT oracle prices a pool other than this market's registered liquidity provider tranche pool
    error BPT_ORACLE_POOL_MISMATCH();

    /// @notice Thrown when setting a BPT oracle configured to revert while the vault is unlocked, the venue reads it through the unlocked vault (previews and hooks)
    error BPT_ORACLE_CANNOT_REVERT_WHILE_VAULT_UNLOCKED();

    /// @notice Thrown when a venue liquidity operation is dispatched into a Vault another party already unlocked
    error VAULT_ALREADY_UNLOCKED();

    /// @dev Requires the Vault to be locked so the operation opens the outermost unlock and settles against a session no other party has touched
    /// @dev Should be placed on every venue operation that unlocks the Vault
    modifier whenVaultLocked() {
        require(!_vault.isUnlocked(), VAULT_ALREADY_UNLOCKED());
        _;
    }

    /// @notice Constructs the Balancer V3 liquidity venue
    /// @param _balancerV3Vault The instance of the singleton Balancer V3 Vault
    constructor(IVault _balancerV3Vault) VaultGuard(_balancerV3Vault) { }

    /// @notice Initializes the Balancer V3 liquidity venue
    /// @param _params The liquidity venue initialization parameters
    function __BalancerV3LiquidityVenue_init_unchained(BalancerV3LiquidityVenueInitParams calldata _params) internal onlyInitializing {
        RoycoDayKernelState storage $_kernel = _getRoycoDayKernelStorage();
        address lptAsset = $_kernel.lptAsset;
        address seniorTranche = $_kernel.seniorTranche;

        // Ensure the vault this venue was constructed against is the one the pool (the LPT asset) is registered with
        require(address(BalancerPoolToken(lptAsset).getVault()) == address(_vault), INVALID_BALANCER_V3_VAULT());
        // Ensure that the Balancer V3 Pool is registered with the vault
        require(_vault.isPoolRegistered(lptAsset), POOL_NOT_REGISTERED());

        // Retrieve the constituent tokens of this kernel's Balancer V3 pool and ensure that there are exactly 2
        IERC20[] memory tokens = _vault.getPoolTokens(lptAsset);
        require(tokens.length == 2, POOL_MUST_HAVE_TWO_TOKENS());

        // Enforce the market's structural token ordering
        require(address(tokens[0]) == seniorTranche && address(tokens[1]) == $_kernel.quoteAsset, INVALID_POOL_TOKEN_CONFIGURATION());

        // Set the venue state
        _setBPTOracle(_params.bptOracle);
        _setMaxReinvestmentSlippage(_params.maxReinvestmentSlippageWAD);
    }

    // =============================
    // Senior Share Rate Provider Function
    // =============================

    /**
     * @inheritdoc IRateProvider
     * @dev Reverts when the kernel is paused to ensure that the pool never executes operations on a faulty kernel state
     * @dev Values one senior tranche share in NAV units, the rate at which the pool prices its senior share leg
     * @dev Within a synchronized operation the returned rate is the one the pre-op sync cached, so an inline senior share mint or burn (a multi-asset deposit or redemption) cannot transiently move the senior-leg mark before the matching effective NAV is committed
     * @dev Outside a synchronized operation the cache is unset (each operation's price frame clears it on exit), so a standalone pool interaction or an off-chain read previews the fresh rate the next sync would resolve from committed state, even later in a transaction that already ran an operation
     * @dev The rate is floored to a minimum of 1 WAD so the pool never receives a zero rate, which it would reject
     */
    function getRate() external view override(IRateProvider) whenNotPaused returns (uint256 rate) {
        // Query the cache for the ST share price
        bool cacheHit;
        (cacheHit, rate) = Cache._read(CacheKey.ST_SHARE_PRICE);

        // On a cache miss, value the senior share against the post-sync ST effective NAV and total supply
        if (!cacheHit) {
            RoycoDayKernelState storage $_kernel = _getRoycoDayKernelStorage();
            // Simulate the poke first so a circuit-breaking oracle halts pool pricing identically to the kernel's operations
            IRoycoPriceOracle($_kernel.collateralAssetOracle).previewPoke();
            // NOTE: The accountant's preview is read directly so pricing the senior leg never recurses back into the liquidity provider tranche mark
            SyncedAccountingState memory state =
                IRoycoDayAccountant($_kernel.accountant).previewSyncTrancheAccounting(ValuationLogic._getCollateralNAV($_kernel));
            (,, uint256 stTotalSupply) =
                FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(state, IERC20($_kernel.seniorTranche).totalSupply());

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
     * @dev Requires the Vault to be locked so this operation opens the outermost unlock, never inheriting another party's session
     * @dev A preview unwinds every transient balance change via the callback's result-carrying revert
     * @dev Only invoked via a self-call from the kernel's delegatecall logic libraries
     */
    function addLiquidity(
        DispatchMode _mode,
        uint256 _seniorShares,
        uint256 _quoteAssets,
        TRANCHE_UNIT _minLPTAssetsOut
    )
        external
        override(IRoycoDayKernel)
        onlySelf
        whenVaultLocked
        returns (TRANCHE_UNIT lptAssets, NAV_UNIT lptAssetPrice)
    {
        // Both transports yield the unlock's ABI encoded bytes return byte for byte
        return abi.decode(
            abi.decode(
                address(_vault)
                    ._dispatch(
                        _mode,
                        abi.encodeCall(_vault.unlock, (abi.encodeCall(this.addBalancerV3Liquidity, (_mode, _seniorShares, _quoteAssets, _minLPTAssetsOut))))
                    ),
                (bytes)
            ),
            (TRANCHE_UNIT, NAV_UNIT)
        );
    }

    /**
     * @inheritdoc IRoycoDayKernel
     * @dev Dispatches the remove liquidity callback below through the unlocked Vault
     * @dev Requires the Vault to be locked so this operation opens the outermost unlock, never inheriting another party's session
     * @dev A preview unwinds every transient balance change via the callback's result-carrying revert
     * @dev Only invoked via a self-call from the kernel's delegatecall logic libraries
     */
    function removeLiquidity(
        DispatchMode _mode,
        TRANCHE_UNIT _lptAssets,
        uint256 _minSTSharesOut,
        uint256 _minQuoteAssetsOut,
        address _quoteAssetsReceiver
    )
        external
        override(IRoycoDayKernel)
        onlySelf
        whenVaultLocked
        returns (uint256 stShares, uint256 quoteAssets, NAV_UNIT lptAssetPrice)
    {
        // Both transports yield the unlock's ABI encoded bytes return byte for byte
        (stShares, quoteAssets, lptAssetPrice) = abi.decode(
            abi.decode(
                address(_vault)
                    ._dispatch(
                        _mode,
                        abi.encodeCall(
                            _vault.unlock,
                            (abi.encodeCall(this.removeBalancerV3Liquidity, (_mode, _lptAssets, _minSTSharesOut, _minQuoteAssetsOut, _quoteAssetsReceiver)))
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
     * @dev Requires the Vault to be locked so this deployment opens the outermost unlock, never inheriting another party's session
     * @dev Only invoked via a self-call from the kernel's delegatecall logic libraries
     */
    function attemptLiquidityPremiumReinvestment(
        uint256 _stSharesToReinvest,
        NAV_UNIT _stShareRate
    )
        external
        override(IRoycoDayKernel)
        onlySelf
        whenVaultLocked
    {
        BalancerV3LiquidityVenueLogic.attemptLiquidityPremiumReinvestment(
            _getRoycoDayKernelStorage(), _vault, _getBalancerV3LiquidityVenueStorage().maxReinvestmentSlippageWAD, _stSharesToReinvest, _stShareRate
        );
    }

    // =============================
    // Balancer V3 Vault Callback Functions
    // =============================

    /// @inheritdoc IBalancerV3LiquidityVenue
    function addBalancerV3Liquidity(
        DispatchMode _mode,
        uint256 _seniorShares,
        uint256 _quoteAssets,
        TRANCHE_UNIT _minLPTAssetsOut
    )
        external
        override(IBalancerV3LiquidityVenue)
        onlyVault
        returns (uint256 lptAssets, NAV_UNIT lptAssetPrice)
    {
        return BalancerV3LiquidityVenueLogic.addBalancerV3Liquidity(_getRoycoDayKernelStorage(), _vault, _mode, _seniorShares, _quoteAssets, _minLPTAssetsOut);
    }

    /// @inheritdoc IBalancerV3LiquidityVenue
    function removeBalancerV3Liquidity(
        DispatchMode _mode,
        TRANCHE_UNIT _lptAssets,
        uint256 _minSTSharesOut,
        uint256 _minQuoteAssetsOut,
        address _quoteAssetsReceiver
    )
        external
        override(IBalancerV3LiquidityVenue)
        onlyVault
        returns (uint256 stShares, uint256 quoteAssets, NAV_UNIT lptAssetPrice)
    {
        return BalancerV3LiquidityVenueLogic.removeBalancerV3Liquidity(
            _getRoycoDayKernelStorage(), _vault, _mode, _lptAssets, _minSTSharesOut, _minQuoteAssetsOut, _quoteAssetsReceiver
        );
    }

    // =============================
    // LPT Asset Pricing Oracle Function
    // =============================

    /// @inheritdoc RoycoDayKernel
    /// @dev Prices one whole LPT asset at the venue's manipulation-resistant NAV per BPT (the oracle's total NAV over the BPT supply), rounding down so the liquidity provider tranche's NAV is never overstated
    function queryLPTAssetOracle() public view virtual override(RoycoDayKernel) returns (NAV_UNIT lptAssetPrice) {
        RoycoDayKernelState storage $_kernel = _getRoycoDayKernelStorage();
        // Preemptively return if the pool is uninitialized
        TRANCHE_UNIT bptTotalSupply = toTrancheUnits(_vault.totalSupply($_kernel.lptAsset));
        if (bptTotalSupply == ZERO_TRANCHE_UNITS) return ZERO_NAV_UNITS;
        // Compute the NAV of all the BPT in circulation
        NAV_UNIT bptTotalValue = toNAVUnits(LPOracleBase(_getBalancerV3LiquidityVenueStorage().bptOracle).computeTVL());
        // Derive the price of one whole BPT and assert that it is non-zero
        lptAssetPrice = toTrancheUnits($_kernel.oneWholeLPTAsset).mulDiv(bptTotalValue, bptTotalSupply, Math.Rounding.Floor);
        require(lptAssetPrice != ZERO_NAV_UNITS, INVALID_PRICE());
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
        if (_syncBeforeUpdate) _preOpSyncTrancheAccountingWithPriceCache();
        // Update the BPT oracle
        _setBPTOracle(_bptOracle);
        // Sync the tranche accounting against the incoming oracle so the committed liquidity provider tranche raw NAV reflects it
        _preOpSyncTrancheAccountingWithPriceCache();
    }

    /// @notice Sets the maximum slippage tolerated when single-sided reinvesting the liquidity premium into the BPT
    /// @param _maxReinvestmentSlippageWAD The new maximum reinvestment slippage tolerance, scaled to WAD precision
    function setMaxReinvestmentSlippage(uint64 _maxReinvestmentSlippageWAD) external restricted {
        _setMaxReinvestmentSlippage(_maxReinvestmentSlippageWAD);
    }

    // =============================
    // Internal Utility Functions
    // =============================

    /// @notice Sets the new BPT oracle
    /// @param _bptOracle The new manipulation-resistant balancer pool token (BPT) oracle
    function _setBPTOracle(address _bptOracle) internal {
        require(address(LPOracleBase(_bptOracle).pool()) == _getRoycoDayKernelStorage().lptAsset, BPT_ORACLE_POOL_MISMATCH());
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
