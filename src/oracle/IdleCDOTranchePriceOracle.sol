// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IIdleCDO } from "../interfaces/external/idle-finance/IIdleCDO.sol";
import { WAD_DECIMALS } from "../libraries/Constants.sol";
import { NAV_UNIT } from "../libraries/Units.sol";
import { ChainlinkPriceOracleBase } from "./base/ChainlinkPriceOracleBase.sol";
import { OracleClockBase } from "./base/clock/OracleClockBase.sol";

/**
 * @title IdleCDOTranchePriceOracle
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Oracle to price Idle CDO tranche tokens (AA or BB) in NAV units by converting the tranche to the CDO's underlying token at the virtual price and pricing the underlying token using a Chainlink (compatible) oracle
 * @dev Use case: price AA_FalconXUSDC (collateral asset) in USDC (reference asset) using the Pareto CDO's virtualPrice and price USDC in USD (NAV unit) using its Chainlink (compatible) fundamental price feed
 */
contract IdleCDOTranchePriceOracle is OracleClockBase, ChainlinkPriceOracleBase {
    /// @notice The Idle CDO whose tranche token is the collateral asset
    address public immutable IDLE_CDO;

    /// @dev The multiplier that scales the CDO's virtual price from the underlying token's decimals to WAD precision
    uint256 internal immutable CDO_VIRTUAL_PRICE_MULTIPLIER_FOR_WAD_PRECISION;

    /// @notice Thrown when the collateral asset is not one of the CDO's two tranche tokens
    error COLLATERAL_ASSET_MUST_BE_CDO_TRANCHE();

    /**
     * @notice Constructs the Idle CDO tranche virtual price to Chainlink (compatible) oracle composed collateral oracle
     * @param _idleCDO The Idle CDO whose tranche token is the collateral asset
     * @param _tranche The CDO tranche token (AA or BB) this oracle prices into NAV units
     * @param _underlyingTokenToNavAssetOracle The Chainlink (compatible) oracle pricing the CDO's underlying token in NAV units
     */
    constructor(
        address _idleCDO,
        address _tranche,
        address _underlyingTokenToNavAssetOracle
    )
        ChainlinkPriceOracleBase(_tranche, _underlyingTokenToNavAssetOracle)
    {
        // Sanity checks on the Idle CDO configuration
        require(_idleCDO != address(0), NULL_ADDRESS());
        // virtualPrice treats any unknown address as the BB tranche, so the tranche must be validated here
        require(_tranche == IIdleCDO(_idleCDO).AATranche() || _tranche == IIdleCDO(_idleCDO).BBTranche(), COLLATERAL_ASSET_MUST_BE_CDO_TRANCHE());
        IDLE_CDO = _idleCDO;

        // virtualPrice returns the value of one whole tranche token scaled to the CDO underlying token's decimals
        // OUTPUT_DECIMALS = UNDERLYING_DECIMALS + MULTIPLIER_EXPONENT
        // For OUTPUT_DECIMALS to have WAD_DECIMALS of precision:
        // MULTIPLIER_EXPONENT = WAD_DECIMALS - UNDERLYING_DECIMALS
        // The checked subtraction reverts at construction for underlying decimals above WAD_DECIMALS, the edge of the supported precision
        CDO_VIRTUAL_PRICE_MULTIPLIER_FOR_WAD_PRECISION = 10 ** (WAD_DECIMALS - IERC20Metadata(IIdleCDO(_idleCDO).token()).decimals());
    }

    /**
     * @notice Initializes the Idle CDO tranche virtual price to Chainlink (compatible) oracle composed collateral oracle
     * @param _initialAuthority The initial authority for the oracle
     * @param _minDeviationWAD The minimum relative deviation from the checkpointed virtual price that counts as an update, scaled to WAD precision (zero counts any change)
     * @param _lastUpdate The admin-attested timestamp of the virtual price's last update (zero if unknown, which holds pricing and the execution gate shut until the first observed deviation)
     */
    function initialize(address _initialAuthority, uint256 _minDeviationWAD, uint32 _lastUpdate) external initializer {
        __RoycoBase_init(_initialAuthority);
        __OracleClockBase_init_unchained(_lastUpdate, _minDeviationWAD);
    }

    /**
     * @inheritdoc ChainlinkPriceOracleBase
     * @notice The price returned is the composed tranche price and updatedAt is the oldest hop's last update
     * @dev Reports the older of the checkpointed tranche price clock and the Chainlink leg's update timestamp, so a stale feed gates pricing even while the virtual price keeps deviating
     */
    function getPrice() public view override(ChainlinkPriceOracleBase) returns (NAV_UNIT price, uint256 updatedAt) {
        (price, updatedAt) = ChainlinkPriceOracleBase.getPrice();
        uint256 tranchePriceUpdatedAt = previewPoke();
        updatedAt = Math.min(updatedAt, tranchePriceUpdatedAt);
    }

    /// @inheritdoc ChainlinkPriceOracleBase
    /// @dev The clock keys on the tranche price, so a feed update alone never opens the entry point's execution gate
    function poke() public override(OracleClockBase, ChainlinkPriceOracleBase) returns (uint256 updatedAt) {
        return OracleClockBase.poke();
    }

    /// @inheritdoc ChainlinkPriceOracleBase
    function previewPoke() public view override(OracleClockBase, ChainlinkPriceOracleBase) returns (uint256 updatedAt) {
        return OracleClockBase.previewPoke();
    }

    /// @inheritdoc ChainlinkPriceOracleBase
    function _getCollateralToReferenceAssetConversionRateWAD()
        internal
        view
        override(ChainlinkPriceOracleBase)
        returns (uint256 collateralToReferenceAssetConversionRateWAD)
    {
        // The conversion hop and the clock source are the same reading: the tranche's live virtual price in WAD
        return _getSourcePrice();
    }

    /// @inheritdoc OracleClockBase
    function _getSourcePrice() internal view override(OracleClockBase) returns (uint256 value) {
        // The virtual price is returned in the CDO underlying token's decimals, the multiplier lifts it to WAD precision exactly
        return IIdleCDO(IDLE_CDO).virtualPrice(COLLATERAL_ASSET) * CDO_VIRTUAL_PRICE_MULTIPLIER_FOR_WAD_PRECISION;
    }
}
