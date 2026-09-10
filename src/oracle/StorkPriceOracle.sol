// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { Strings } from "../../lib/openzeppelin-contracts/contracts/utils/Strings.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoPriceOracle } from "../interfaces/IRoycoPriceOracle.sol";
import { IStork, StorkStructs } from "../interfaces/external/stork/IStork.sol";
import { WAD, WAD_DECIMALS } from "../libraries/Constants.sol";
import { NAV_UNIT, toNAVUnits } from "../libraries/Units.sol";

/**
 * @title StorkPriceOracle
 * @author Shivaansh Kapoor, Ankur Dubey, Tomer Ganor
 * @notice Oracle to price a collateral asset in NAV units by composing up to two Stork-published values read directly
 *         from the Stork core contract: the collateral asset in its reference asset, times the reference asset in NAV units
 */
contract StorkPriceOracle is IRoycoPriceOracle {
    using Math for uint256;

    /// @inheritdoc IRoycoPriceOracle
    address public immutable COLLATERAL_ASSET;

    /// @notice The Stork core contract both legs are read from
    IStork public immutable STORK;

    /// @notice The Stork asset id pricing the collateral asset in its reference asset
    bytes32 public immutable COLLATERAL_TO_REFERENCE_ID;

    /// @notice The Stork asset id pricing the reference asset in NAV units, or zero when the reference asset IS the NAV unit (identity leg)
    bytes32 public immutable REFERENCE_TO_NAV_ID;

    /// @notice The maximum age of the collateral leg's value before pricing fails shut
    uint32 public immutable COLLATERAL_LEG_STALENESS_THRESHOLD_SECONDS;

    /// @notice The maximum age of the reference leg's value before pricing fails shut (unused on an identity leg)
    uint32 public immutable REFERENCE_LEG_STALENESS_THRESHOLD_SECONDS;

    /// @dev Stork quantizes every value to 18 decimals
    uint256 private constant _STORK_VALUE_PRECISION = 1e18;

    /// @dev Stork publisher timestamps are in nanoseconds
    uint256 private constant _NANOSECONDS_PER_SECOND = 1e9;

    /// @notice Thrown when the collateral asset or the Stork contract is constructed as the null address
    error NULL_ADDRESS();

    /// @notice Thrown when the collateral leg's asset id is constructed as zero
    error INVALID_PRICE_ID();

    /// @notice Thrown when a leg reports a non-positive value
    error INVALID_PRICE();

    /// @notice Thrown when a leg's value is older than its staleness threshold
    /// @param id The asset id of the stale leg
    error STALE_STORK_PRICE(bytes32 id);

    /// @notice Thrown when a staleness threshold is constructed as zero, which would fail every price read
    error INVALID_STALENESS_THRESHOLD_SECONDS();

    /// @notice Thrown when a leg's publisher timestamp is in the future
    error UPDATED_AT_CANNOT_BE_FUTURE();

    /**
     * @notice Constructs the Stork composed price oracle
     * @param _collateralAsset The collateral asset this oracle prices in NAV units
     * @param _stork The Stork core contract
     * @param _collateralToReferenceId The Stork asset id pricing the collateral asset in its reference asset
     * @param _referenceToNavId The Stork asset id pricing the reference asset in NAV units, or zero when the reference asset is the NAV unit
     * @param _collateralLegStalenessThresholdSeconds The maximum age of the collateral leg's value before pricing fails shut, sized to its publishing cadence
     * @param _referenceLegStalenessThresholdSeconds The maximum age of the reference leg's value before pricing fails shut, sized to its publishing cadence
     */
    constructor(
        address _collateralAsset,
        address _stork,
        bytes32 _collateralToReferenceId,
        bytes32 _referenceToNavId,
        uint32 _collateralLegStalenessThresholdSeconds,
        uint32 _referenceLegStalenessThresholdSeconds
    ) {
        // Sanity checks on the wiring
        require(_collateralAsset != address(0) && _stork != address(0), NULL_ADDRESS());
        require(_collateralToReferenceId != bytes32(0), INVALID_PRICE_ID());
        require(_collateralLegStalenessThresholdSeconds > 0 && _referenceLegStalenessThresholdSeconds > 0, INVALID_STALENESS_THRESHOLD_SECONDS());

        COLLATERAL_ASSET = _collateralAsset;
        STORK = IStork(_stork);
        COLLATERAL_TO_REFERENCE_ID = _collateralToReferenceId;
        REFERENCE_TO_NAV_ID = _referenceToNavId;
        COLLATERAL_LEG_STALENESS_THRESHOLD_SECONDS = _collateralLegStalenessThresholdSeconds;
        REFERENCE_LEG_STALENESS_THRESHOLD_SECONDS = _referenceLegStalenessThresholdSeconds;

        // Prove every configured id exists on the core contract (NotFound bubbles); freshness is judged per read, not here
        IStork(_stork).getTemporalNumericValueUnsafeV1(_collateralToReferenceId);
        if (_referenceToNavId != bytes32(0)) IStork(_stork).getTemporalNumericValueUnsafeV1(_referenceToNavId);
    }

    /**
     * @inheritdoc IRoycoPriceOracle
     * @notice The price returned is the value of 1 whole collateral asset in NAV units
     * @dev The two legs are composed in a single floored mulDiv, so the hops carry no intermediate rounding
     * @dev updatedAt is the older leg's publisher timestamp in seconds; an identity reference leg reads as current
     */
    function getPrice() public view override(IRoycoPriceOracle) returns (NAV_UNIT price, uint256 updatedAt) {
        (uint256 collateralInReference, uint256 collateralLegUpdatedAt) = _readLeg(COLLATERAL_TO_REFERENCE_ID, COLLATERAL_LEG_STALENESS_THRESHOLD_SECONDS);

        uint256 referenceInNav = WAD;
        uint256 referenceLegUpdatedAt = block.timestamp;
        if (REFERENCE_TO_NAV_ID != bytes32(0)) {
            (referenceInNav, referenceLegUpdatedAt) = _readLeg(REFERENCE_TO_NAV_ID, REFERENCE_LEG_STALENESS_THRESHOLD_SECONDS);
        }

        price = toNAVUnits(collateralInReference.mulDiv(referenceInNav, _STORK_VALUE_PRECISION, Math.Rounding.Floor));
        updatedAt = Math.min(collateralLegUpdatedAt, referenceLegUpdatedAt);
    }

    /// @inheritdoc IRoycoPriceOracle
    /// @dev Stork publishers stamp their own updates, so the report's oldest leg IS the clock: nothing to commit
    function poke() external view override(IRoycoPriceOracle) returns (uint256 updatedAt) {
        (, updatedAt) = getPrice();
    }

    /// @inheritdoc IRoycoPriceOracle
    function previewPoke() external view override(IRoycoPriceOracle) returns (uint256 updatedAt) {
        (, updatedAt) = getPrice();
    }

    /// @inheritdoc IRoycoPriceOracle
    function decimals() external pure override(IRoycoPriceOracle) returns (uint8) {
        return uint8(WAD_DECIMALS);
    }

    /// @inheritdoc IRoycoPriceOracle
    /// @dev Stork identifies assets by opaque ids, so the description names the composed ids rather than a pair string
    function description() external view override(IRoycoPriceOracle) returns (string memory) {
        string memory collateralLeg = string.concat("Stork ", Strings.toHexString(uint256(COLLATERAL_TO_REFERENCE_ID), 32));
        if (REFERENCE_TO_NAV_ID == bytes32(0)) return collateralLeg;
        return string.concat(collateralLeg, " x ", Strings.toHexString(uint256(REFERENCE_TO_NAV_ID), 32));
    }

    /// @inheritdoc IRoycoPriceOracle
    function version() external pure override(IRoycoPriceOracle) returns (uint256) {
        return 1;
    }

    /**
     * @notice Reads one leg from the Stork core, normalizing its timestamp to seconds and gating it on the leg's threshold
     * @param _id The Stork asset id of the leg
     * @param _stalenessThresholdSeconds The maximum age of the leg's value before pricing fails shut
     * @return value The leg's value, scaled to 18 decimals
     * @return updatedAt The leg's publisher timestamp in seconds, never later than the current block
     */
    function _readLeg(bytes32 _id, uint32 _stalenessThresholdSeconds) internal view returns (uint256 value, uint256 updatedAt) {
        // An unknown id reverts NotFound inside the core, failing shut
        StorkStructs.TemporalNumericValue memory report = STORK.getTemporalNumericValueUnsafeV1(_id);
        require(report.quantizedValue > 0, INVALID_PRICE());

        // Floor the nanosecond stamp to seconds: the reported update time is never later than the real one
        updatedAt = uint256(report.timestampNs) / _NANOSECONDS_PER_SECOND;
        require(updatedAt <= block.timestamp, UPDATED_AT_CANNOT_BE_FUTURE());
        require((updatedAt + _stalenessThresholdSeconds) >= block.timestamp, STALE_STORK_PRICE(_id));

        value = uint256(int256(report.quantizedValue));
    }
}
