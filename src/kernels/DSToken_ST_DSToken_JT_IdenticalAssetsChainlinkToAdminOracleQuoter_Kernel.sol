// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoKernel } from "../interfaces/IRoycoKernel.sol";
import { IComplianceServiceWhitelisted } from "../interfaces/external/ds-token/IComplianceServiceWhitelisted.sol";
import { IDSToken } from "../interfaces/external/ds-token/IDSToken.sol";
import { RoycoKernel } from "./base/RoycoKernel.sol";
import { IdenticalAssetsChainlinkToAdminOracleQuoter } from "./base/quoter/IdenticalAssetsChainlinkToAdminOracleQuoter.sol";

/**
 * @title DSToken_ST_DSToken_JT_IdenticalAssetsChainlinkToAdminOracleQuoter_Kernel
 * @author Waymont
 * @notice The senior and junior tranches transfer in the same DSToken
 * @notice The tranche transfers are restricted to whitelisted addresses on the underlying DS-Token compliance service
 * @notice The kernel uses a Chainlink oracle to convert tranche token units to NAV units, allowing NAVs to sync based on underlying PNL
 */
contract DSToken_ST_DSToken_JT_IdenticalAssetsChainlinkToAdminOracleQuoter_Kernel is RoycoKernel, IdenticalAssetsChainlinkToAdminOracleQuoter {
    /// @notice Thrown when the compliance service is invalid
    error INVALID_COMPLIANCE_SERVICE();

    /// @notice Thrown when the from address is not whitelisted by the compliance service
    error FROM_ADDRESS_NOT_WHITELISTED_ON_DSTOKEN_COMPLIANCE_SERVICE(address from);

    /// @notice Thrown when the to address is not whitelisted by the compliance service
    error TO_ADDRESS_NOT_WHITELISTED_ON_DSTOKEN_COMPLIANCE_SERVICE(address to);

    /// @notice The address of the compliance service
    address public immutable COMPLIANCE_SERVICE;

    /// @notice Constructs the kernel state
    /// @param _params The standard construction parameters for the Royco kernel
    constructor(RoycoKernelConstructionParams memory _params) RoycoKernel(_params) {
        // The tranche asset is the DSToken. Query the compliance service from the DSToken.
        COMPLIANCE_SERVICE = IDSToken(ST_ASSET).getDSService(IDSToken(ST_ASSET).COMPLIANCE_SERVICE());
        require(COMPLIANCE_SERVICE != address(0), INVALID_COMPLIANCE_SERVICE());
    }

    /**
     * @notice Initializes the Royco Kernel
     * @param _params The standard initialization parameters for the Royco Kernel
     * @param _trancheAssetToReferenceAssetOracle The tranche asset to reference asset oracle
     * @param _stalenessThresholdSeconds The staleness threshold seconds
     * @param _initialConversionRateWAD The initial reference asset to NAV unit conversion rate, scaled to WAD precision
     */
    function initialize(
        IRoycoKernel.RoycoKernelInitParams calldata _params,
        address _trancheAssetToReferenceAssetOracle,
        uint48 _stalenessThresholdSeconds,
        uint256 _initialConversionRateWAD
    )
        external
        initializer
    {
        // Initialize the base kernel state
        __RoycoKernel_init(_params);
        // Initialize the identical assets chainlink to admin oracle quoter
        __IdenticalAssetsChainlinkToAdminOracleQuoter_init(_initialConversionRateWAD, _trancheAssetToReferenceAssetOracle, _stalenessThresholdSeconds);
    }

    /// @inheritdoc RoycoKernel
    function _preTrancheBalanceUpdate(address _from, address _to, uint256, address) internal view override {
        // Check if the from address is whitelisted by the compliance service
        require(
            _from == address(0) || IComplianceServiceWhitelisted(COMPLIANCE_SERVICE).checkWhitelisted(_from),
            FROM_ADDRESS_NOT_WHITELISTED_ON_DSTOKEN_COMPLIANCE_SERVICE(_from)
        );
        // Check if the to address is whitelisted by the compliance service
        require(
            _to == address(0) || IComplianceServiceWhitelisted(COMPLIANCE_SERVICE).checkWhitelisted(_to),
            TO_ADDRESS_NOT_WHITELISTED_ON_DSTOKEN_COMPLIANCE_SERVICE(_to)
        );
    }
}
