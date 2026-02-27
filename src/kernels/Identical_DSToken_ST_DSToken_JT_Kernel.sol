// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoKernel } from "../interfaces/IRoycoKernel.sol";
import { IComplianceServiceWhitelisted } from "../interfaces/external/ds-token/IComplianceServiceWhitelisted.sol";
import { IDSToken } from "../interfaces/external/ds-token/IDSToken.sol";
import { Identical_ERC20_ST_ERC20_JT_Kernel, RoycoKernel } from "./Identical_ERC20_ST_ERC20_JT_Kernel.sol";

/**
 * @title Identical_DSToken_ST_DSToken_JT_Kernel
 * @author Waymont
 * @notice The senior and junior tranches transfer in the same Digital Security (DS) token (ACRED, STAC, etc.)
 * @notice The tranche transfers are restricted to whitelisted addresses on the underlying DS-Token compliance service
 */
contract Identical_DSToken_ST_DSToken_JT_Kernel is Identical_ERC20_ST_ERC20_JT_Kernel {
    /// @notice Thrown when the compliance service is invalid
    error INVALID_COMPLIANCE_SERVICE();

    /// @notice Thrown when an account is not whitelisted by the digital security compliance service
    error ACCOUNT_NOT_WHITELISTED_ON_SECURITY_COMPLIANCE_SERVICE(address account);

    /// @notice The address of the digital security compliance service
    address public immutable COMPLIANCE_SERVICE;

    /// @notice Constructs the kernel state
    /// @param _params The standard construction parameters for the Royco kernel
    constructor(RoycoKernelConstructionParams memory _params) Identical_ERC20_ST_ERC20_JT_Kernel(_params) {
        // The tranche asset is the DSToken. Query the compliance service from the DSToken.
        COMPLIANCE_SERVICE = IDSToken(ST_ASSET).getDSService(IDSToken(ST_ASSET).COMPLIANCE_SERVICE());
        require(COMPLIANCE_SERVICE != address(0), INVALID_COMPLIANCE_SERVICE());
    }

    /// @inheritdoc RoycoKernel
    function _preTrancheBalanceUpdate(address _from, address _to, uint256) internal view override(RoycoKernel) {
        // Only check sender on redeem and recipient on mint
        // Check if the sender is whitelisted by the compliance service
        require(
            _from == address(0) || IComplianceServiceWhitelisted(COMPLIANCE_SERVICE).checkWhitelisted(_from),
            ACCOUNT_NOT_WHITELISTED_ON_SECURITY_COMPLIANCE_SERVICE(_from)
        );
        // Check if the recipient address is whitelisted by the compliance service
        require(
            _to == address(0) || IComplianceServiceWhitelisted(COMPLIANCE_SERVICE).checkWhitelisted(_to),
            ACCOUNT_NOT_WHITELISTED_ON_SECURITY_COMPLIANCE_SERVICE(_to)
        );
    }
}
