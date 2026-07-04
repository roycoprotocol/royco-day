// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { Cache, CacheKey } from "../../../../../libraries/Cache.sol";
import { Math, NAV_UNIT, RoycoUnitsMath, TRANCHE_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../../../../libraries/Units.sol";
import { RoycoDayKernel } from "../../../RoycoDayKernel.sol";

/**
 * @title IdenticalAssets_ST_JT_Oracle_Quoter
 * @notice Quoter to convert tranche units to/from NAV units using an oracle for markets where both tranches use the same tranche units
 * @dev NAV units always have WAD precision
 * @dev The quoter reads the conversion rate from the specified oracle in WAD precision.
 *      The kernel admin can optionally override the conversion rate with a fixed value.
 *      Supported use-cases include:
 *      - Identical Yield Bearing ERC20 for ST And JT: Yield Bearing ERC20 and Tranche Unit (FalconXUSDC, reUSD, etc.), NAV Unit (USD)
 */
abstract contract IdenticalAssets_ST_JT_Oracle_Quoter is RoycoDayKernel {
    using RoycoUnitsMath for NAV_UNIT;
    using RoycoUnitsMath for TRANCHE_UNIT;

    /// @dev Storage slot for IdenticalAssets_ST_JT_Oracle_QuoterState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.IdenticalAssets_ST_JT_Oracle_QuoterState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant IDENTICAL_ASSETS_ST_JT_ORACLE_QUOTER_STORAGE_SLOT = 0x54cd05a2c27d5d9c9a9737f8c40012d3aaaf930bf3bd4a6472e48a5cd4447600;

    /// @notice A sentinel value for the conversion rate, indicating that the conversion rate should be queried in real time from the specified oracle
    uint256 internal constant SENTINEL_CONVERSION_RATE = 0;

    /// @dev Value representing the scale factor of the tranche unit: 10^(TRANCHE_UNIT_DECIMALS)
    uint256 internal immutable TRANCHE_UNIT_SCALE_FACTOR;

    /**
     * @dev Storage state for the Royco identical assets overridable oracle quoter
     * @custom:storage-location erc7201:Royco.storage.IdenticalAssets_ST_JT_Oracle_QuoterState
     * @custom:field conversionRateWAD - The tranche unit to NAV unit conversion rate scaled to WAD precision, or SENTINEL_CONVERSION_RATE (0) to query the oracle in real time
     */
    struct IdenticalAssets_ST_JT_Oracle_QuoterState {
        uint256 conversionRateWAD;
    }

    /// @notice Emitted when the tranche unit to NAV unit conversion rate is updated
    /// @param conversionRateWAD The updated conversion rate as defined by the oracle, scaled to WAD precision
    event ConversionRateUpdated(uint256 conversionRateWAD);

    /// @notice Thrown when the senior and junior tranche assets are not identical
    error TRANCHE_ASSETS_MUST_BE_IDENTICAL();

    /// @dev Constructs the identical assets oracle quoter
    constructor() {
        // The tranche assets must be non-null (guaranteed by order of construction: kernel is constructed first)
        // The tranche assets must be identical since there is a single conversion rate used for both tranches
        require(ST_ASSET == JT_ASSET, TRANCHE_ASSETS_MUST_BE_IDENTICAL());
        // Compute and set the tranche unit scale factor
        TRANCHE_UNIT_SCALE_FACTOR = 10 ** IERC20Metadata(ST_ASSET).decimals();
    }

    /// @notice Initializes the identical assets oracle quoter
    /// @param _initialConversionRateWAD The initial conversion rate as defined by the oracle, scaled to WAD precision
    function __IdenticalAssets_ST_JT_Oracle_Quoter_init_unchained(uint256 _initialConversionRateWAD) internal onlyInitializing {
        // Preemptively return if this quoter is reliant on an oracle instead of an admin set conversion rate
        if (_initialConversionRateWAD == SENTINEL_CONVERSION_RATE) return;
        _getIdenticalAssets_ST_JT_Oracle_QuoterStorage().conversionRateWAD = _initialConversionRateWAD;
        emit ConversionRateUpdated(_initialConversionRateWAD);
    }

    /// @inheritdoc RoycoDayKernel
    function stConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _stAssets) public view override(RoycoDayKernel) returns (NAV_UNIT nav) {
        return _convertTrancheUnitsToNAVUnits(_stAssets);
    }

    /// @inheritdoc RoycoDayKernel
    function jtConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _jtAssets) public view override(RoycoDayKernel) returns (NAV_UNIT nav) {
        return _convertTrancheUnitsToNAVUnits(_jtAssets);
    }

    /// @inheritdoc RoycoDayKernel
    function stConvertNAVUnitsToTrancheUnits(NAV_UNIT _value) public view override(RoycoDayKernel) returns (TRANCHE_UNIT stAssets) {
        return _convertNAVUnitsToTrancheUnits(_value);
    }

    /// @inheritdoc RoycoDayKernel
    function jtConvertNAVUnitsToTrancheUnits(NAV_UNIT _value) public view override(RoycoDayKernel) returns (TRANCHE_UNIT jtAssets) {
        return _convertNAVUnitsToTrancheUnits(_value);
    }

    /**
     * @notice Sets the tranche unit to NAV unit conversion rate
     * @dev Once this is set, the quoter will rely solely on this value instead of the overridden oracle query
     * @dev Executes an accounting sync before and after setting the new conversion rate
     * @dev Only callable by a designated admin
     * @param _conversionRateWAD The conversion rate as defined by the oracle, scaled to WAD precision
     * @param _syncBeforeUpdate Whether to sync the tranche accounting before updating the conversion rate
     */
    function setConversionRate(uint256 _conversionRateWAD, bool _syncBeforeUpdate) public virtual restricted {
        // If specified, sync the tranche accounting to reflect the PNL up to this point in time
        if (_syncBeforeUpdate) _preOpSyncTrancheAccounting();
        // Set the new conversion rate
        _getIdenticalAssets_ST_JT_Oracle_QuoterStorage().conversionRateWAD = _conversionRateWAD;
        emit ConversionRateUpdated(_conversionRateWAD);
        // Sync the tranche accounting to reflect the PNL from the updated conversion rate (the sync entrypoint refreshes the quoter cache to this new rate)
        _preOpSyncTrancheAccounting();
    }

    /**
     * @notice Returns the value of 1 Tranche Unit in NAV Units, scaled to WAD precision
     * @dev If the admin oracle is set, it will return the override value, otherwise it will return the value queried from the oracle
     * @return trancheToNAVUnitConversionRateWAD The tranche unit to NAV unit conversion rate
     */
    function getTrancheUnitToNAVUnitConversionRateWAD() public view virtual returns (uint256 trancheToNAVUnitConversionRateWAD) {
        // If there is an admin set conversion rate, use that, else query the oracle for the rate
        trancheToNAVUnitConversionRateWAD = getStoredConversionRateWAD();
        if (trancheToNAVUnitConversionRateWAD != SENTINEL_CONVERSION_RATE) return trancheToNAVUnitConversionRateWAD;
        return _getConversionRateFromOracleWAD();
    }

    /// @notice Returns the stored conversion rate, scaled to WAD precision
    /// @return conversionRateWAD The stored conversion rate, scaled to WAD precision
    function getStoredConversionRateWAD() public view returns (uint256) {
        return _getIdenticalAssets_ST_JT_Oracle_QuoterStorage().conversionRateWAD;
    }

    /// @notice Initializes the quoter cache for the operation
    /// @dev Called at the start of a synchronized operation to cache the tranche unit to NAV unit conversion rate, so every conversion in the operation values against one consistent rate. No teardown is needed: each operation re-caches and the transient cache auto-clears at transaction end
    function _initializeQuoterCache() internal virtual override {
        // Cache the tranche unit to NAV unit conversion rate for the operation
        Cache._write(CacheKey.IDENTICAL_ST_JT_TRANCHE_TO_NAV_UNIT_RATE, getTrancheUnitToNAVUnitConversionRateWAD());
    }

    /**
     * @notice Returns the cached tranche unit to NAV unit conversion rate
     * @dev If the cache slot is populated returns the cached value, otherwise falls back to querying the rate live for view function compatibility
     * @return The tranche unit to NAV unit conversion rate
     */
    function _getCachedTrancheUnitToNAVUnitConversionRateWAD() internal view returns (uint256) {
        // If the cache slot is populated use the cached value
        (bool cacheHit, uint256 conversionRateWAD) = Cache._read(CacheKey.IDENTICAL_ST_JT_TRANCHE_TO_NAV_UNIT_RATE);
        if (cacheHit) return conversionRateWAD;
        // Otherwise fall back to querying the rate directly (for view functions)
        return getTrancheUnitToNAVUnitConversionRateWAD();
    }

    /// @dev Converts tranche units to NAV units for both tranches since they use identical assets, scaled to WAD precision
    function _convertTrancheUnitsToNAVUnits(TRANCHE_UNIT _assets) internal view returns (NAV_UNIT) {
        return toNAVUnits(toUint256(_assets.mulDiv(_getCachedTrancheUnitToNAVUnitConversionRateWAD(), TRANCHE_UNIT_SCALE_FACTOR, Math.Rounding.Floor)));
    }

    /// @dev Converts NAV units to tranche units for both tranches since they use identical assets, scaled to TRANCHE_UNIT precision
    function _convertNAVUnitsToTrancheUnits(NAV_UNIT _nav) internal view returns (TRANCHE_UNIT) {
        return toTrancheUnits(toUint256(_nav.mulDiv(TRANCHE_UNIT_SCALE_FACTOR, _getCachedTrancheUnitToNAVUnitConversionRateWAD(), Math.Rounding.Floor)));
    }

    /**
     * @notice Returns a conversion rate, scaled to WAD precision
     * @dev Depending on the concrete implementation, this may return the value of 1 tranche unit or an intermediate reference asset in NAV Units
     * @dev This function should be overridden if the conversion rate needs to be fetched from an oracle
     * @return conversionRateWAD The conversion rate, scaled to WAD precision
     */
    function _getConversionRateFromOracleWAD() internal view virtual returns (uint256 conversionRateWAD);

    /**
     * @notice Returns a storage pointer to the IdenticalAssets_ST_JT_Oracle_QuoterState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer
     */
    function _getIdenticalAssets_ST_JT_Oracle_QuoterStorage() private pure returns (IdenticalAssets_ST_JT_Oracle_QuoterState storage $) {
        assembly ("memory-safe") {
            $.slot := IDENTICAL_ASSETS_ST_JT_ORACLE_QUOTER_STORAGE_SLOT
        }
    }
}
