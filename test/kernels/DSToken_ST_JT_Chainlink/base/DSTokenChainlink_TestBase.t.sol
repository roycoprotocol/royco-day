// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IComplianceServiceWhitelisted } from "../../../../src/interfaces/external/ds-token/IComplianceServiceWhitelisted.sol";
import { IDSToken } from "../../../../src/interfaces/external/ds-token/IDSToken.sol";
import { YieldBearingERC20Chainlink_TestBase } from "../../YieldBearingERC20_ST_JT_Chainlink/base/YieldBearingERC20Chainlink_TestBase.t.sol";

/// @title DSTokenChainlink_TestBase
/// @notice Base test contract for DSToken_ST_DSToken_JT_IdenticalAssetsChainlinkToAdminOracleQuoter_Kernel
/// @dev Extends the Chainlink ERC20 test base to add DS-Token compliance service whitelisting.
///
/// The DSToken kernel adds an additional compliance layer on top of the standard Chainlink kernel:
///   - The kernel resolves the compliance service address from the DSToken at construction time
///   - Every tranche share balance update (mint/burn/transfer) checks that both _from and _to
///     are whitelisted on the DS-Token compliance service
///
/// This base class provides helpers to mock the compliance service's `checkWhitelisted` to return `true`
/// for all addresses, allowing the standard test suite to run without needing real Securitize KYC.
/// It also mocks `validateTransfer` to bypass the DS-Token's own transfer restrictions.
///
/// NOTE: No additional state variables are added to avoid stack-too-deep errors in the deep
/// inheritance chain (AbstractKernelTestSuite already uses many state variables in its test functions).
abstract contract DSTokenChainlink_TestBase is YieldBearingERC20Chainlink_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // COMPLIANCE SERVICE MOCKING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Mocks the DS-Token compliance services to allow all transfers
    /// @dev Resolves compliance services directly from the DSToken (not the kernel),
    ///      so it can be called before deployment. Mocks both the whitelisting check
    ///      (used by the kernel) and the validateTransfer check (used by the DSToken itself).
    /// @param _dsToken The DS-Token address to resolve compliance services from
    function _mockDSTokenCompliance(address _dsToken) internal {
        address svc = IDSToken(_dsToken).getDSService(IDSToken(_dsToken).COMPLIANCE_SERVICE());
        require(svc != address(0), "Compliance service not resolved");

        // Mock checkWhitelisted (used by kernel's _preTrancheBalanceUpdate)
        vm.mockCall(svc, abi.encodeWithSelector(IComplianceServiceWhitelisted.checkWhitelisted.selector), abi.encode(true));

        // Mock validateTransfer (used by DSToken's transfer/transferFrom)
        vm.mockCall(svc, abi.encodeWithSelector(bytes4(keccak256("validateTransfer(address,address,uint256,bool,uint256)"))), bytes(""));
    }
}
