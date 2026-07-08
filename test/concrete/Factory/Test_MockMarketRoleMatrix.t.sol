// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ERC20BurnableUpgradeable } from
    "../../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {
    ADMIN_ROLE, PUBLIC_ROLE, ST_LP_ROLE, JT_LP_ROLE, LT_LP_ROLE, SYNC_ROLE, BURNER_ROLE
} from "../../../src/factory/RolesConfiguration.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoLiquidityTranche } from "../../../src/interfaces/IRoycoLiquidityTranche.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";

/**
 * @title Test_MockMarketRoleMatrix
 * @notice Always-running regression pin on the deployed-market access-control matrix. The production
 *         BalancerV3DeploymentTemplate's role wiring is only asserted in the RPC-gated fork factory suite, so a
 *         standard CI run leaves it unverified; DayMarketTestBase hand-mirrors that wiring
 *         (`_wireTargetFunctionRoles`/`_wireRoleGrants`), and this pins the mirror against drift — including the
 *         grant set that lets a whitelist-enforcing market mint fee and premium shares.
 * @dev Asserts selector->role bindings, the two contract grants, that the kernel and fee recipient DO hold the
 *      tranche LP roles (so their fee/premium mints pass the tranche whitelist screen), and that `mint` is
 *      deliberately unbound (defaults to AccessManager ADMIN_ROLE, the kernel gating it via an immutable
 *      `onlyKernel` check instead).
 */
contract Test_MockMarketRoleMatrix is DayMarketTestBase {
    function setUp() public {
        _deployMarket(cellA(), defaultParams());
    }

    function _role(address _target, bytes4 _selector) internal view returns (uint64) {
        return accessManager.getTargetFunctionRole(_target, _selector);
    }

    function _holds(uint64 _roleId, address _account) internal view returns (bool m) {
        (m,) = accessManager.hasRole(_roleId, _account);
    }

    // ---------------------------------------------------------------------
    // Selector -> role bindings
    // ---------------------------------------------------------------------

    function test_TrancheDepositRedeem_boundToLPRoles() public view {
        assertEq(_role(address(seniorTranche), IRoycoVaultTranche.deposit.selector), ST_LP_ROLE, "ST deposit -> ST_LP_ROLE");
        assertEq(_role(address(seniorTranche), IRoycoVaultTranche.redeem.selector), ST_LP_ROLE, "ST redeem -> ST_LP_ROLE");
        assertEq(_role(address(juniorTranche), IRoycoVaultTranche.deposit.selector), JT_LP_ROLE, "JT deposit -> JT_LP_ROLE");
        assertEq(_role(address(juniorTranche), IRoycoVaultTranche.redeem.selector), JT_LP_ROLE, "JT redeem -> JT_LP_ROLE");
    }

    function test_LTDeposit_isPublic_LTRedeem_isLPGated() public view {
        assertEq(_role(address(liquidityTranche), IRoycoVaultTranche.deposit.selector), PUBLIC_ROLE, "LT deposit -> PUBLIC_ROLE");
        assertEq(_role(address(liquidityTranche), IRoycoLiquidityTranche.depositMultiAsset.selector), PUBLIC_ROLE, "LT depositMultiAsset -> PUBLIC_ROLE");
        assertEq(_role(address(liquidityTranche), IRoycoVaultTranche.redeem.selector), LT_LP_ROLE, "LT redeem -> LT_LP_ROLE");
        assertEq(_role(address(liquidityTranche), IRoycoLiquidityTranche.redeemMultiAsset.selector), LT_LP_ROLE, "LT redeemMultiAsset -> LT_LP_ROLE");
    }

    function test_KernelSync_boundToSyncRole_and_TrancheBurn_boundToBurnerRole() public view {
        assertEq(_role(address(kernel), IRoycoDayKernel.syncTrancheAccounting.selector), SYNC_ROLE, "kernel sync -> SYNC_ROLE");
        assertEq(_role(address(seniorTranche), ERC20BurnableUpgradeable.burn.selector), BURNER_ROLE, "ST burn -> BURNER_ROLE");
        assertEq(_role(address(juniorTranche), ERC20BurnableUpgradeable.burnFrom.selector), BURNER_ROLE, "JT burnFrom -> BURNER_ROLE");
    }

    // ---------------------------------------------------------------------
    // Contract grants (postInitGrants mirror, minus the mock-absent Balancer hook)
    // ---------------------------------------------------------------------

    function test_PostInitGrants_syncToAccountant_burnerToKernel() public view {
        assertTrue(_holds(SYNC_ROLE, address(accountant)), "accountant must hold SYNC_ROLE");
        assertTrue(_holds(BURNER_ROLE, address(kernel)), "kernel must hold BURNER_ROLE");
    }

    // ---------------------------------------------------------------------
    // Kernel and fee recipient DO hold the tranche LP roles, so a whitelist-enforcing market's fee/premium mints
    // pass the tranche `_update` whitelist screen.
    // ---------------------------------------------------------------------

    function test_KernelAndFeeRecipient_HoldTrancheLPRoles() public view {
        assertTrue(_holds(ST_LP_ROLE, address(kernel)), "kernel must hold ST_LP_ROLE");
        assertTrue(_holds(JT_LP_ROLE, address(kernel)), "kernel must hold JT_LP_ROLE");
        assertTrue(_holds(LT_LP_ROLE, address(kernel)), "kernel must hold LT_LP_ROLE");
        assertTrue(_holds(ST_LP_ROLE, PROTOCOL_FEE_RECIPIENT), "fee recipient must hold ST_LP_ROLE");
        assertTrue(_holds(JT_LP_ROLE, PROTOCOL_FEE_RECIPIENT), "fee recipient must hold JT_LP_ROLE");
        assertTrue(_holds(LT_LP_ROLE, PROTOCOL_FEE_RECIPIENT), "fee recipient must hold LT_LP_ROLE");
    }

    // ---------------------------------------------------------------------
    // mint is deliberately unbound -> defaults to AccessManager ADMIN_ROLE (0)
    // ---------------------------------------------------------------------

    function test_MintSelector_isUnbound_defaultsToAdminRole() public view {
        assertEq(_role(address(seniorTranche), IRoycoVaultTranche.mint.selector), ADMIN_ROLE, "ST mint must be unbound (kernel gates it via onlyKernel)");
        assertEq(_role(address(juniorTranche), IRoycoVaultTranche.mint.selector), ADMIN_ROLE, "JT mint must be unbound");
    }
}
