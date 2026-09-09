// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { IIdleCDO } from "../interfaces/external/idle-finance/IIdleCDO.sol";
import { IIdleCreditVault } from "../interfaces/external/idle-finance/IIdleCreditVault.sol";
import { WAD_DECIMALS } from "../libraries/Constants.sol";
import { DiscretePriceOracleBase } from "./base/DiscretePriceOracleBase.sol";

/**
 * @title DiscreteIdleCDOTranchePriceOracle
 * @author Shivaansh Kapoor, Ankur Dubey, Tomer Ganor
 * @notice Oracle to price Idle CDO tranche tokens (AA or BB) in NAV units by converting the tranche to the CDO's underlying token at the checkpointed virtual price and pricing the underlying token using a Chainlink (compatible) oracle
 * @dev Use case: price AA_FalconXUSDC (collateral asset) in USDC (reference asset) using the Pareto CDO's virtualPrice checkpointed at each epoch settlement and price USDC in USD (NAV unit) using its Chainlink (compatible) fundamental price feed
 * @dev The strategy's epochNumber is the checkpoint ID: it increments exactly once per successful settlement and never on a borrower default, so every settlement checkpoints even at an unchanged virtual price while mid-epoch fee drift never reaches the market
 * @dev The CDO's permanent defaulted flag is the force-checkpoint signal: it freezes the ID while losses are marked down without a settlement, so every post-default virtual price move (markdowns and recoveries alike) checkpoints at the first poke that observes it
 * @dev A default marks no losses by itself, so the checkpoint serves the pre-default value until the first markdown lands or pricing fails shut
 * @dev NOTE: an owner-emergency strategy token recall can move the virtual price mid-epoch with no settlement and no default, which stays unpriced until the next settlement or until pricing fails shut
 */
contract DiscreteIdleCDOTranchePriceOracle is DiscretePriceOracleBase {
    /// @notice The Idle CDO whose tranche token is the collateral asset
    address public immutable IDLE_CDO;

    /**
     * @notice The CDO's credit vault strategy whose epochNumber is the checkpoint ID
     * @dev The CDO assigns its strategy only at initialization and exposes no setter, so the pointer is cached as a construction immutable
     * @dev NOTE: an upstream strategy repoint would decouple this counter from the CDO, re-stamping a frozen price instead of aging into the staleness gate, so a repoint requires an oracle redeploy
     */
    address public immutable CREDIT_VAULT_STRATEGY;

    /// @dev The multiplier that scales the CDO's virtual price from the underlying token's decimals to WAD precision
    uint256 internal immutable _CDO_VIRTUAL_PRICE_MULTIPLIER_FOR_WAD_PRECISION;

    /// @notice Thrown when the collateral asset is not one of the CDO's two tranche tokens
    error COLLATERAL_ASSET_MUST_BE_CDO_TRANCHE();

    /**
     * @notice Constructs the Idle CDO tranche checkpointed virtual price to Chainlink (compatible) oracle composed collateral oracle
     * @param _idleCDO The Idle CDO whose tranche token is the collateral asset
     * @param _tranche The CDO tranche token (AA or BB) this oracle prices into NAV units
     * @param _underlyingTokenToNavAssetOracle The Chainlink (compatible) oracle pricing the CDO's underlying token in NAV units
     * @param _chainlinkOracleStalenessThresholdSeconds The maximum age of the Chainlink (compatible) oracle's report before pricing fails shut, sized to its heartbeat
     * @param _cdoPriceStalenessThresholdSeconds The maximum age of the virtual-price checkpoint before pricing fails shut, sized to the CDO's epoch cadence plus slack
     */
    constructor(
        address _idleCDO,
        address _tranche,
        address _underlyingTokenToNavAssetOracle,
        uint32 _chainlinkOracleStalenessThresholdSeconds,
        uint32 _cdoPriceStalenessThresholdSeconds
    )
        DiscretePriceOracleBase(_tranche, _underlyingTokenToNavAssetOracle, _chainlinkOracleStalenessThresholdSeconds, _cdoPriceStalenessThresholdSeconds)
    {
        require(_idleCDO != address(0), NULL_ADDRESS());
        // virtualPrice treats any unknown address as the BB tranche, so the tranche must be validated here
        require(_tranche == IIdleCDO(_idleCDO).AATranche() || _tranche == IIdleCDO(_idleCDO).BBTranche(), COLLATERAL_ASSET_MUST_BE_CDO_TRANCHE());

        IDLE_CDO = _idleCDO;
        CREDIT_VAULT_STRATEGY = IIdleCDO(_idleCDO).strategy();

        // virtualPrice returns the value of one whole tranche token scaled to the CDO underlying token's decimals
        // OUTPUT_DECIMALS = UNDERLYING_DECIMALS + MULTIPLIER_EXPONENT
        // For OUTPUT_DECIMALS to have WAD_DECIMALS of precision:
        // MULTIPLIER_EXPONENT = WAD_DECIMALS - UNDERLYING_DECIMALS
        // The checked subtraction reverts at construction for underlying decimals above WAD_DECIMALS, the edge of the supported precision
        _CDO_VIRTUAL_PRICE_MULTIPLIER_FOR_WAD_PRECISION = 10 ** (WAD_DECIMALS - IERC20Metadata(IIdleCDO(_idleCDO).token()).decimals());

        // Seed the baseline through the same reads and commit every poke uses, so the oracle prices from deployment
        _checkpointSourcePrice();
    }

    /// @inheritdoc DiscretePriceOracleBase
    function _getSourcePrice() internal view override(DiscretePriceOracleBase) returns (uint256 price) {
        // The virtual price is returned in the CDO underlying token's decimals, the multiplier lifts it to WAD precision exactly
        return IIdleCDO(IDLE_CDO).virtualPrice(COLLATERAL_ASSET) * _CDO_VIRTUAL_PRICE_MULTIPLIER_FOR_WAD_PRECISION;
    }

    /// @inheritdoc DiscretePriceOracleBase
    /// @dev The strategy's epochNumber increments exactly once per successful settlement and never on a default, so it is the settlement counter the checkpoint ID needs
    function _getCheckpointId() internal view override(DiscretePriceOracleBase) returns (uint256 id) {
        return IIdleCreditVault(CREDIT_VAULT_STRATEGY).epochNumber();
    }

    /// @inheritdoc DiscretePriceOracleBase
    /// @dev The defaulted flag is permanent and freezes the ID while losses are marked down without a settlement, so under it every virtual price move is information
    function _shouldForceCheckpoint() internal view override(DiscretePriceOracleBase) returns (bool forceCheckpoint) {
        return IIdleCDO(IDLE_CDO).defaulted();
    }
}
