// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoAuth } from "../../interfaces/IRoycoAuth.sol";
import { IRoycoPriceOracle } from "../../interfaces/IRoycoPriceOracle.sol";
import { AggregatorV3Interface } from "../../interfaces/external/chainlink/AggregatorV3Interface.sol";
import { WAD_DECIMALS } from "../../libraries/Constants.sol";
import { NAV_UNIT, toNAVUnits } from "../../libraries/Units.sol";

/**
 * @title ChainlinkPriceOracleBase
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Abstract oracle to price a collateral asset in NAV units by converting it to its reference asset at a live rate and pricing the reference asset using a Chainlink (compatible) oracle
 * @dev The conversion rate is read live from its source, so the report is exactly as fresh as the Chainlink (compatible) oracle and its update timestamp passes through unchanged
 * @dev The oracle network timestamps its own updates, so poke passes the feed's latest update timestamp
 */
abstract contract ChainlinkPriceOracleBase is IRoycoPriceOracle {
    using Math for uint256;

    /// @inheritdoc IRoycoPriceOracle
    address public immutable COLLATERAL_ASSET;

    /// @notice The Chainlink (compatible) oracle pricing the reference asset in NAV units
    AggregatorV3Interface public immutable ORACLE;

    /// @dev Value representing the scale factor of the oracle's price precision: 10^(ORACLE.decimals())
    // The oracle is a construction immutable, so its price precision is locked at construction
    uint256 internal immutable ORACLE_PRICE_PRECISION;

    /// @notice Thrown when the Chainlink (compatible) oracle reports a non-positive price
    error INVALID_PRICE();

    /// @notice Thrown when the Chainlink (compatible) oracle's price is incomplete
    error INCOMPLETE_PRICE();

    /**
     * @notice Constructs the Chainlink (compatible) oracle composed price oracle
     * @param _collateralAsset The collateral asset this oracle prices in NAV units
     * @param _oracle The Chainlink (compatible) oracle pricing the reference asset in NAV units
     */
    constructor(address _collateralAsset, address _oracle) {
        // Sanity checks on the collateral asset and oracle configuration
        require(_collateralAsset != address(0) && _oracle != address(0), IRoycoAuth.NULL_ADDRESS());
        COLLATERAL_ASSET = _collateralAsset;
        ORACLE = AggregatorV3Interface(_oracle);
        ORACLE_PRICE_PRECISION = 10 ** AggregatorV3Interface(_oracle).decimals();
    }

    /**
     * @inheritdoc IRoycoPriceOracle
     * @notice The price returned is the value of 1 whole collateral asset in NAV units
     * @dev The price is calculated as the collateral to reference asset conversion rate * the reference asset price in a single floored mulDiv, so the two hops carry no intermediate rounding
     * @dev The conversion rate is always current, so the feed's update timestamp passes through unchanged
     */
    function getPrice() public view virtual override(IRoycoPriceOracle) returns (NAV_UNIT price, uint256 updatedAt) {
        // Fetch the reference asset price in NAV units
        (uint80 roundId, int256 answer,, uint256 feedUpdatedAt, uint80 answeredInRound) = ORACLE.latestRoundData();

        // Conduct sanity checks
        require(answer > 0, INVALID_PRICE());
        require(answeredInRound >= roundId, INCOMPLETE_PRICE());

        // Compose the two hops: collateral value in reference assets (WAD) times reference asset price in NAV units, floored once
        price = toNAVUnits(_getCollateralToReferenceAssetConversionRateWAD().mulDiv(uint256(answer), ORACLE_PRICE_PRECISION, Math.Rounding.Floor));
        updatedAt = feedUpdatedAt;
    }

    /// @inheritdoc IRoycoPriceOracle
    /// @dev Virtual and nonpayable so a composed oracle can re-source the clock
    function poke() public virtual override(IRoycoPriceOracle) returns (uint256 updatedAt) {
        (, updatedAt) = getPrice();
    }

    /// @inheritdoc IRoycoPriceOracle
    function previewPoke() public view virtual override(IRoycoPriceOracle) returns (uint256 updatedAt) {
        (, updatedAt) = getPrice();
    }

    /// @inheritdoc IRoycoPriceOracle
    function decimals() external pure override(IRoycoPriceOracle) returns (uint8) {
        return uint8(WAD_DECIMALS);
    }

    /// @inheritdoc IRoycoPriceOracle
    /// @notice Reads as the pair chain in the Chainlink cross-feed convention, eg. "sNUSD / NUSD / USD"
    function description() external view virtual override(IRoycoPriceOracle) returns (string memory) {
        return string(abi.encodePacked(IERC20Metadata(COLLATERAL_ASSET).symbol(), " / ", ORACLE.description()));
    }

    /// @inheritdoc IRoycoPriceOracle
    function version() external pure override(IRoycoPriceOracle) returns (uint256) {
        return 1;
    }

    /// @notice Returns the value of 1 whole collateral asset in the reference asset the Chainlink (compatible) oracle prices, scaled to WAD precision
    /// @return collateralToReferenceAssetConversionRateWAD The live collateral to reference asset conversion rate, scaled to WAD precision
    function _getCollateralToReferenceAssetConversionRateWAD() internal view virtual returns (uint256 collateralToReferenceAssetConversionRateWAD);
}
