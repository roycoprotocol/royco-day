// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IComplianceServiceWhitelisted } from "../../../../src/interfaces/external/ds-token/IComplianceServiceWhitelisted.sol";
import { IDSToken } from "../../../../src/interfaces/external/ds-token/IDSToken.sol";
import {
    DSToken_ST_DSToken_JT_IdenticalAssetsChainlinkToAdminOracleQuoter_Kernel
} from "../../../../src/kernels/DSToken_ST_DSToken_JT_IdenticalAssetsChainlinkToAdminOracleQuoter_Kernel.sol";
import { YieldBearingERC20Chainlink_TestBase } from "../../Identical_ERC20_ST_JT_Chainlink/base/YieldBearingERC20Chainlink_TestBase.t.sol";

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

    // ═══════════════════════════════════════════════════════════════════════════
    // DS-TOKEN COMPLIANCE WHITELISTING TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function _complianceService() private view returns (address) {
        return DSToken_ST_DSToken_JT_IdenticalAssetsChainlinkToAdminOracleQuoter_Kernel(address(KERNEL)).COMPLIANCE_SERVICE();
    }

    function _mockNotWhitelisted(address _who) private {
        vm.mockCall(_complianceService(), abi.encodeWithSelector(IComplianceServiceWhitelisted.checkWhitelisted.selector, _who), abi.encode(false));
    }

    /// @dev Grants both ST and JT LP roles to an address so it passes the AccessManager check
    function _grantLPRoles(address _who) private {
        vm.startPrank(LP_ROLE_ADMIN_ADDRESS);
        FACTORY.grantRole(ST_LP_ROLE, _who, 0);
        FACTORY.grantRole(JT_LP_ROLE, _who, 0);
        vm.stopPrank();
    }

    function test_dsTokenCompliance_ST_transferReverts_whenRecipientNotWhitelisted() external {
        uint256 depositAmount = _minDepositAmount() * 10;
        _depositJT(ALICE_ADDRESS, depositAmount);
        uint256 stShares = _depositST(BOB_ADDRESS, depositAmount / 2);

        address nonWhitelisted = makeAddr("nonWhitelisted");
        _grantLPRoles(nonWhitelisted);
        _mockNotWhitelisted(nonWhitelisted);

        vm.prank(BOB_ADDRESS);
        vm.expectRevert(
            abi.encodeWithSelector(
                DSToken_ST_DSToken_JT_IdenticalAssetsChainlinkToAdminOracleQuoter_Kernel.TO_ADDRESS_NOT_WHITELISTED_ON_DSTOKEN_COMPLIANCE_SERVICE.selector,
                nonWhitelisted
            )
        );
        ST.transfer(nonWhitelisted, stShares);
    }

    function test_dsTokenCompliance_JT_transferReverts_whenRecipientNotWhitelisted() external {
        uint256 depositAmount = _minDepositAmount() * 10;
        uint256 jtShares = _depositJT(ALICE_ADDRESS, depositAmount);

        address nonWhitelisted = makeAddr("nonWhitelisted");
        _grantLPRoles(nonWhitelisted);
        _mockNotWhitelisted(nonWhitelisted);

        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(
            abi.encodeWithSelector(
                DSToken_ST_DSToken_JT_IdenticalAssetsChainlinkToAdminOracleQuoter_Kernel.TO_ADDRESS_NOT_WHITELISTED_ON_DSTOKEN_COMPLIANCE_SERVICE.selector,
                nonWhitelisted
            )
        );
        JT.transfer(nonWhitelisted, jtShares);
    }

    function test_dsTokenCompliance_ST_transferReverts_whenSenderNotWhitelisted() external {
        uint256 depositAmount = _minDepositAmount() * 10;
        _depositJT(ALICE_ADDRESS, depositAmount);
        uint256 stShares = _depositST(BOB_ADDRESS, depositAmount / 2);

        // Grant ALICE the ST LP role so she can receive, then delist BOB from compliance
        _grantLPRoles(ALICE_ADDRESS);
        _mockNotWhitelisted(BOB_ADDRESS);

        vm.prank(BOB_ADDRESS);
        vm.expectRevert(
            abi.encodeWithSelector(
                DSToken_ST_DSToken_JT_IdenticalAssetsChainlinkToAdminOracleQuoter_Kernel.FROM_ADDRESS_NOT_WHITELISTED_ON_DSTOKEN_COMPLIANCE_SERVICE.selector,
                BOB_ADDRESS
            )
        );
        ST.transfer(ALICE_ADDRESS, stShares);
    }

    function test_dsTokenCompliance_JT_transferReverts_whenSenderNotWhitelisted() external {
        uint256 depositAmount = _minDepositAmount() * 10;
        uint256 jtShares = _depositJT(ALICE_ADDRESS, depositAmount);

        // Grant BOB the JT LP role so he can receive, then delist ALICE from compliance
        _grantLPRoles(BOB_ADDRESS);
        _mockNotWhitelisted(ALICE_ADDRESS);

        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(
            abi.encodeWithSelector(
                DSToken_ST_DSToken_JT_IdenticalAssetsChainlinkToAdminOracleQuoter_Kernel.FROM_ADDRESS_NOT_WHITELISTED_ON_DSTOKEN_COMPLIANCE_SERVICE.selector,
                ALICE_ADDRESS
            )
        );
        JT.transfer(BOB_ADDRESS, jtShares);
    }

    function test_dsTokenCompliance_ST_transferSucceeds_whenBothWhitelisted() external {
        uint256 depositAmount = _minDepositAmount() * 10;
        _depositJT(ALICE_ADDRESS, depositAmount);
        uint256 stShares = _depositST(BOB_ADDRESS, depositAmount / 2);

        // Grant ALICE the ST LP role so the AccessManager allows the transfer
        _grantLPRoles(ALICE_ADDRESS);

        // Both addresses are whitelisted via blanket mock — transfer should succeed
        vm.prank(BOB_ADDRESS);
        ST.transfer(ALICE_ADDRESS, stShares);

        assertEq(ST.balanceOf(ALICE_ADDRESS), stShares, "ALICE should have received ST shares");
        assertEq(ST.balanceOf(BOB_ADDRESS), 0, "BOB should have 0 ST shares after transfer");
    }

    function test_dsTokenCompliance_JT_transferSucceeds_whenBothWhitelisted() external {
        uint256 depositAmount = _minDepositAmount() * 10;
        uint256 jtShares = _depositJT(ALICE_ADDRESS, depositAmount);

        // Grant BOB the JT LP role so the AccessManager allows the transfer
        _grantLPRoles(BOB_ADDRESS);

        // Both addresses are whitelisted via blanket mock — transfer should succeed
        vm.prank(ALICE_ADDRESS);
        JT.transfer(BOB_ADDRESS, jtShares);

        assertEq(JT.balanceOf(BOB_ADDRESS), jtShares, "BOB should have received JT shares");
        assertEq(JT.balanceOf(ALICE_ADDRESS), 0, "ALICE should have 0 JT shares after transfer");
    }
}
