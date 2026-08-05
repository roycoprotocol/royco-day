// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { IRoycoAuth } from "../interfaces/IRoycoAuth.sol";
import { IIdleCDO } from "../interfaces/external/idle-finance/IIdleCDO.sol";
import { WAD_DECIMALS } from "../libraries/Constants.sol";
import { ChainlinkPriceOracleBase } from "./base/ChainlinkPriceOracleBase.sol";
import { ClockedChainlinkPriceOracleBase } from "./base/ClockedChainlinkPriceOracleBase.sol";
import { OracleClockBase } from "./base/clock/OracleClockBase.sol";

/**
 * @title IdleCDOTranchePriceOracle
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Oracle to price Idle CDO tranche tokens (AA or BB) in NAV units by converting the tranche to the CDO's underlying token at the virtual price and pricing the underlying token using a Chainlink (compatible) oracle
 * @dev Use case: price AA_FalconXUSDC (collateral asset) in USDC (reference asset) using the Pareto CDO's virtualPrice and price USDC in USD (NAV unit) using its Chainlink (compatible) fundamental price feed
 * @dev The CDO reprices through discrete accounting and exposes no update timestamp, so the clocked base checkpoints observed virtual-price deviations and reports the older of that clock and the feed's update timestamp
 */
contract IdleCDOTranchePriceOracle is ClockedChainlinkPriceOracleBase {
    /// @notice The Idle CDO whose tranche token is the collateral asset
    address public immutable IDLE_CDO;

    /// @dev The multiplier that scales the CDO's virtual price from the underlying token's decimals to WAD precision
    uint256 internal immutable _CDO_VIRTUAL_PRICE_MULTIPLIER_FOR_WAD_PRECISION;

    /// @notice Thrown when the collateral asset is not one of the CDO's two tranche tokens
    error COLLATERAL_ASSET_MUST_BE_CDO_TRANCHE();

    /**
     * @notice Constructs the Idle CDO tranche virtual price to Chainlink (compatible) oracle composed collateral oracle
     * @param _idleCDO The Idle CDO whose tranche token is the collateral asset
     * @param _tranche The CDO tranche token (AA or BB) this oracle prices into NAV units
     * @param _underlyingTokenToNavAssetOracle The Chainlink (compatible) oracle pricing the CDO's underlying token in NAV units
     * @param _minDeviationWAD The minimum relative deviation from the checkpointed virtual price that counts as an update, scaled to WAD precision (zero counts any change)
     * @param _lastUpdate The deployer-attested timestamp of the virtual price's last update (zero if unknown, which holds pricing and the execution gate shut until the first observed deviation)
     * @param _chainlinkOracleStalenessThresholdSeconds The maximum age of the Chainlink (compatible) oracle's report before pricing fails shut, sized to its heartbeat
     * @param _cdoPriceStalenessThresholdSeconds The maximum age of the virtual-price clock's checkpoint before pricing fails shut, sized to the CDO's update cadence
     */
    constructor(
        address _idleCDO,
        address _tranche,
        address _underlyingTokenToNavAssetOracle,
        uint256 _minDeviationWAD,
        uint32 _lastUpdate,
        uint32 _chainlinkOracleStalenessThresholdSeconds,
        uint32 _cdoPriceStalenessThresholdSeconds
    )
        ClockedChainlinkPriceOracleBase(
            _tranche,
            _underlyingTokenToNavAssetOracle,
            _minDeviationWAD,
            _lastUpdate,
            _chainlinkOracleStalenessThresholdSeconds,
            _cdoPriceStalenessThresholdSeconds
        )
    {
        require(_idleCDO != address(0), IRoycoAuth.NULL_ADDRESS());
        // virtualPrice treats any unknown address as the BB tranche, so the tranche must be validated here
        require(_tranche == IIdleCDO(_idleCDO).AATranche() || _tranche == IIdleCDO(_idleCDO).BBTranche(), COLLATERAL_ASSET_MUST_BE_CDO_TRANCHE());

        IDLE_CDO = _idleCDO;

        // virtualPrice returns the value of one whole tranche token scaled to the CDO underlying token's decimals
        // OUTPUT_DECIMALS = UNDERLYING_DECIMALS + MULTIPLIER_EXPONENT
        // For OUTPUT_DECIMALS to have WAD_DECIMALS of precision:
        // MULTIPLIER_EXPONENT = WAD_DECIMALS - UNDERLYING_DECIMALS
        // The checked subtraction reverts at construction for underlying decimals above WAD_DECIMALS, the edge of the supported precision
        _CDO_VIRTUAL_PRICE_MULTIPLIER_FOR_WAD_PRECISION = 10 ** (WAD_DECIMALS - IERC20Metadata(IIdleCDO(_idleCDO).token()).decimals());

        // Checkpoint the construction baseline through the same source read every poke uses
        _initializeOracleClock(_getSourcePrice());
    }

    /// @inheritdoc OracleClockBase
    function _getSourcePrice() internal view override(OracleClockBase) returns (uint256 price) {
        // The virtual price is returned in the CDO underlying token's decimals, the multiplier lifts it to WAD precision exactly
        return IIdleCDO(IDLE_CDO).virtualPrice(COLLATERAL_ASSET) * _CDO_VIRTUAL_PRICE_MULTIPLIER_FOR_WAD_PRECISION;
    }
}
