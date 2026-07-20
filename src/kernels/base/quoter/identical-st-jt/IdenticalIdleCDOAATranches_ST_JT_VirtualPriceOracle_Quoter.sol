// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { IIdleCDO } from "../../../../interfaces/external/idle-finance/IIdleCDO.sol";
import { WAD_DECIMALS } from "../../../../libraries/Constants.sol";
import { IdenticalAssets_ST_JT_Oracle_Quoter } from "./base/IdenticalAssets_ST_JT_Oracle_Quoter.sol";

/**
 * @title IdenticalIdleCDOAATranches_ST_JT_VirtualPriceOracle_Quoter
 * @notice Quoter to convert tranche units (Idle CDO AA tranche tokens) to/from NAV units using the CDO's virtual price scaled to WAD precision or an admin set rate
 * @dev The CDO's virtualPrice is the full tranche unit to NAV unit oracle in a single hop, so this quoter inherits the root oracle quoter directly with no Chainlink layer
 * @dev A nonzero admin set rate overrides the live virtual price entirely and the zero sentinel resumes it (the CDO is a constructor immutable so the live path can never be absent)
 * @dev The senior and junior tranches must have the same AA tranche token as their tranche unit
 * @dev Use case: Convert AA_FalconXUSDC (Tranche unit) to USD (NAV unit) using the Pareto CDO's virtualPrice or an admin set rate
 */
abstract contract IdenticalIdleCDOAATranches_ST_JT_VirtualPriceOracle_Quoter is IdenticalAssets_ST_JT_Oracle_Quoter {
    /// @dev The address of the Idle CDO whose AA tranche token is the ST and JT asset
    address public immutable IDLE_CDO;

    /// @dev The multiplier that scales the CDO's virtual price from the underlying token's decimals to WAD precision
    uint256 internal immutable CDO_VIRTUAL_PRICE_MULTIPLIER_FOR_WAD_PRECISION;

    /// @dev Thrown when the tranche asset is not the CDO's AA tranche token
    error TRANCHE_ASSET_MUST_BE_CDO_AA_TRANCHE();

    /**
     * @notice The quoter-specific initialization parameters
     * @custom:field initialConversionRateWAD - The initial conversion rate as defined by the oracle, scaled to WAD precision (0 to query the CDO's virtual price live)
     */
    struct ST_JT_QuoterSpecificParams {
        uint256 initialConversionRateWAD;
    }

    /// @notice Constructs the Idle CDO AA tranche virtual price oracle quoter
    /// @param _idleCDO The Idle CDO for the Royco market's tranche asset
    constructor(address _idleCDO) {
        // Sanity checks on the Idle CDO and Royco market configuration
        require(_idleCDO != address(0), NULL_ADDRESS());
        // We only need to check equality against one tranche asset since the parent contract asserts equality of the tranche assets
        require(IIdleCDO(_idleCDO).AATranche() == ST_ASSET, TRANCHE_ASSET_MUST_BE_CDO_AA_TRANCHE());
        IDLE_CDO = _idleCDO;

        // NOTE: Both tranche assets are identical Idle CDO AA tranche assets
        // virtualPrice returns the value of one whole AA tranche token scaled to the CDO underlying token's decimals
        // OUTPUT_DECIMALS = UNDERLYING_DECIMALS + MULTIPLIER_EXPONENT
        // For OUTPUT_DECIMALS to have WAD_DECIMALS of precision:
        // MULTIPLIER_EXPONENT = WAD_DECIMALS - UNDERLYING_DECIMALS
        // The checked subtraction reverts at construction for underlying decimals above WAD_DECIMALS, the edge of the supported precision
        CDO_VIRTUAL_PRICE_MULTIPLIER_FOR_WAD_PRECISION = 10 ** (WAD_DECIMALS - IERC20Metadata(IIdleCDO(_idleCDO).token()).decimals());
    }

    /// @notice Initializes the identical Idle CDO AA tranche virtual price oracle quoter and its inherited contracts
    /// @param _params The quoter-specific initialization parameters
    function __IdenticalIdleCDOAATranches_ST_JT_VirtualPriceOracle_Quoter_init(ST_JT_QuoterSpecificParams calldata _params) internal onlyInitializing {
        __IdenticalAssets_ST_JT_Oracle_Quoter_init_unchained(_params.initialConversionRateWAD);
    }

    /// @notice Returns the conversion rate from tranche units to NAV units read live from the CDO, scaled to WAD precision
    /// @return trancheToNAVUnitConversionRateWAD The value of one whole AA tranche token in NAV units, scaled to WAD precision
    function _getConversionRateFromOracleWAD() internal view override(IdenticalAssets_ST_JT_Oracle_Quoter) returns (uint256 trancheToNAVUnitConversionRateWAD) {
        // The virtual price is returned in the CDO underlying token's decimals, the multiplier lifts it to WAD precision exactly
        return IIdleCDO(IDLE_CDO).virtualPrice(ST_ASSET) * CDO_VIRTUAL_PRICE_MULTIPLIER_FOR_WAD_PRECISION;
    }
}
