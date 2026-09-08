// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { IIdleCDO } from "../interfaces/external/idle-finance/IIdleCDO.sol";
import { WAD_DECIMALS } from "../libraries/Constants.sol";
import { DiscretePriceOracleBase } from "./base/DiscretePriceOracleBase.sol";

/**
 * @title DiscreteIdleCDOTranchePriceOracle
 * @author Shivaansh Kapoor, Ankur Dubey, Tomer Ganor
 * @notice Oracle to price Idle CDO tranche tokens (AA or BB) in NAV units by converting the tranche to the CDO's underlying token at the owner-checkpointed virtual price and pricing the underlying token using a Chainlink (compatible) oracle
 * @dev Use case: price AA_FalconXUSDC (collateral asset) in USDC (reference asset) using the Pareto CDO's virtualPrice checkpointed at each epoch settlement and price USDC in USD (NAV unit) using its Chainlink (compatible) fundamental price feed
 * @dev The virtual price steps down between epoch settlements as management fees accrue on every queue interaction, so the owner checkpoints it at each settlement (and after any post-default markdown) and the fee drift in between never reaches the market
 */
contract DiscreteIdleCDOTranchePriceOracle is DiscretePriceOracleBase {
    /// @notice The Idle CDO whose tranche token is the collateral asset
    address public immutable IDLE_CDO;

    /// @dev The multiplier that scales the CDO's virtual price from the underlying token's decimals to WAD precision
    uint256 internal immutable _CDO_VIRTUAL_PRICE_MULTIPLIER_FOR_WAD_PRECISION;

    /// @notice Thrown when the collateral asset is not one of the CDO's two tranche tokens
    error COLLATERAL_ASSET_MUST_BE_CDO_TRANCHE();

    /**
     * @notice Constructs the Idle CDO tranche checkpointed virtual price to Chainlink (compatible) oracle composed collateral oracle
     * @param _owner The owner trusted to checkpoint the virtual price at each epoch settlement
     * @param _idleCDO The Idle CDO whose tranche token is the collateral asset
     * @param _tranche The CDO tranche token (AA or BB) this oracle prices into NAV units
     * @param _underlyingTokenToNavAssetOracle The Chainlink (compatible) oracle pricing the CDO's underlying token in NAV units
     * @param _chainlinkOracleStalenessThresholdSeconds The maximum age of the Chainlink (compatible) oracle's report before pricing fails shut, sized to its heartbeat
     * @param _cdoPriceStalenessThresholdSeconds The maximum age of the virtual-price checkpoint before pricing fails shut, sized to the CDO's epoch cadence plus slack
     */
    constructor(
        address _owner,
        address _idleCDO,
        address _tranche,
        address _underlyingTokenToNavAssetOracle,
        uint32 _chainlinkOracleStalenessThresholdSeconds,
        uint32 _cdoPriceStalenessThresholdSeconds
    )
        DiscretePriceOracleBase(
            _owner, _tranche, _underlyingTokenToNavAssetOracle, _chainlinkOracleStalenessThresholdSeconds, _cdoPriceStalenessThresholdSeconds
        )
    {
        require(_idleCDO != address(0), NULL_ADDRESS());
        // virtualPrice treats any unknown address as the BB tranche, so the tranche must be validated here
        require(_tranche == IIdleCDO(_idleCDO).AATranche() || _tranche == IIdleCDO(_idleCDO).BBTranche(), COLLATERAL_ASSET_MUST_BE_CDO_TRANCHE());

        IDLE_CDO = _idleCDO;

        // virtualPrice returns the value of one whole tranche token scaled to the CDO underlying token's decimals
        // OUTPUT_DECIMALS = UNDERLYING_DECIMALS + MULTIPLIER_EXPONENT
        // For OUTPUT_DECIMALS to have WAD_DECIMALS of precision:
        // MULTIPLIER_EXPONENT = WAD_DECIMALS - UNDERLYING_DECIMALS
        // The checked subtraction reverts at construction for underlying decimals above WAD_DECIMALS, the edge of the supported precision
        _CDO_VIRTUAL_PRICE_MULTIPLIER_FOR_WAD_PRECISION = 10 ** (WAD_DECIMALS - IERC20Metadata(IIdleCDO(_idleCDO).token()).decimals());

        // Trial read: a source no checkpoint could ever latch (a reverting or zero virtualPrice) fails the deployment loudly instead of wiring a dead oracle
        require(_getSourcePrice() > 0, INVALID_SOURCE_PRICE());
    }

    /// @inheritdoc DiscretePriceOracleBase
    function _getSourcePrice() internal view override(DiscretePriceOracleBase) returns (uint256 price) {
        // The virtual price is returned in the CDO underlying token's decimals, the multiplier lifts it to WAD precision exactly
        return IIdleCDO(IDLE_CDO).virtualPrice(COLLATERAL_ASSET) * _CDO_VIRTUAL_PRICE_MULTIPLIER_FOR_WAD_PRECISION;
    }
}
