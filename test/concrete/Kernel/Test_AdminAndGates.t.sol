// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVaultErrors } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultErrors.sol";
import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { toTrancheUnits } from "../../../src/libraries/Units.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";

/**
 * @title Test_AdminAndGates_Kernel
 * @notice Exercises the kernel's admin setter surface (protocol fee recipient, senior tranche self-liquidation
 *         bonus, blacklist wiring), its caller gates (the tranche-only balance-update hook and the self-call-only
 *         venue drivers), and the attacker-side probes of every one of those gates
 * @dev These are thin but load-bearing surfaces: a mis-wired setter silently redirects protocol fees, an open
 *      caller gate lets an outsider drive the venue with the kernel's custody, and a role gate that admits the
 *      wrong admin collapses the deployment's privilege separation
 */
contract Test_AdminAndGates_Kernel is DayMarketTestBase {
    /// @dev An unprivileged address probing every gated entrypoint
    address internal ATTACKER;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        ATTACKER = makeAddr("ATTACKER");
    }

    // =============================
    // Admin setters, happy paths
    // =============================

    /// @notice The kernel admin can redirect protocol fees to a new recipient, and the change lands in storage with its event
    function test_SetProtocolFeeRecipient_UpdatesStateAndEmits() public {
        address newRecipient = makeAddr("NEW_FEE_RECIPIENT");
        vm.expectEmit(address(kernel));
        emit IRoycoDayKernel.ProtocolFeeRecipientUpdated(newRecipient);
        vm.prank(KERNEL_ADMIN);
        kernel.setProtocolFeeRecipient(newRecipient);
        assertEq(kernel.getState().protocolFeeRecipient, newRecipient, "the fee recipient must be replaced in kernel storage");
    }

    /// @notice Redirecting protocol fees to the null address is rejected, fees must always have a live destination
    function test_RevertIf_ProtocolFeeRecipientSetToNullAddress() public {
        vm.prank(KERNEL_ADMIN);
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        kernel.setProtocolFeeRecipient(address(0));
    }

    /// @notice The kernel admin can retune the senior tranche self-liquidation bonus, and the change lands in storage with its event
    function test_SetSeniorTrancheSelfLiquidationBonus_UpdatesStateAndEmits() public {
        // The deployed market ships 0.01e18 (defaultParams), the admin moves it to 0.025e18 (2.5%)
        uint64 newBonusWAD = 0.025e18;
        vm.expectEmit(address(kernel));
        emit IRoycoDayKernel.SeniorTrancheSelfLiquidationBonusUpdated(newBonusWAD);
        vm.prank(KERNEL_ADMIN);
        kernel.setSeniorTrancheSelfLiquidationBonus(newBonusWAD);
        assertEq(kernel.getState().stSelfLiquidationBonusWAD, newBonusWAD, "the senior tranche self-liquidation bonus must be replaced in kernel storage");
    }

    /// @notice The market ops admin can wire and unwire the blacklist contract, and each change lands with its event
    function test_SetRoycoBlacklist_WiresAndUnwiresScreening() public {
        address blacklist = makeAddr("BLACKLIST_STAND_IN");
        vm.expectEmit(address(kernel));
        emit IRoycoDayKernel.RoycoBlacklistUpdated(blacklist);
        vm.prank(MARKET_OPS_ADMIN);
        kernel.setRoycoBlacklist(blacklist);
        assertEq(kernel.getState().roycoBlacklist, blacklist, "the blacklist must be wired in kernel storage");

        // The null address disables screening entirely, so unwiring must also land
        vm.prank(MARKET_OPS_ADMIN);
        kernel.setRoycoBlacklist(address(0));
        assertEq(kernel.getState().roycoBlacklist, address(0), "the null address must unwire the blacklist");
    }

    // =============================
    // Admin setters, attacker side
    // =============================

    /**
     * @notice An unprivileged attacker cannot redirect protocol fees, retune the senior tranche self-liquidation
     *         bonus, or rewire the blacklist, and every failed attempt leaves the kernel state byte-untouched
     * @dev The fee redirect is the direct-theft vector: a single successful call would route every future sync's
     *      protocol fee mint to the attacker
     */
    function test_RevertIf_KernelAdminSettersCalledByNonAdmin() public {
        IRoycoDayKernel.RoycoDayKernelState memory before = kernel.getState();

        vm.startPrank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ATTACKER));
        kernel.setProtocolFeeRecipient(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ATTACKER));
        kernel.setSeniorTrancheSelfLiquidationBonus(0.5e18);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ATTACKER));
        kernel.setRoycoBlacklist(ATTACKER);
        vm.stopPrank();

        IRoycoDayKernel.RoycoDayKernelState memory afterState = kernel.getState();
        assertEq(afterState.protocolFeeRecipient, before.protocolFeeRecipient, "the fee recipient must be untouched by the failed attempts");
        assertEq(afterState.stSelfLiquidationBonusWAD, before.stSelfLiquidationBonusWAD, "the self-liquidation bonus must be untouched by the failed attempts");
        assertEq(afterState.roycoBlacklist, before.roycoBlacklist, "the blacklist wiring must be untouched by the failed attempts");
    }

    /**
     * @notice Privilege separation between the two kernel admin roles holds in both directions: the market ops
     *         admin cannot touch the kernel-admin setters and the kernel admin cannot touch the market-ops setters
     * @dev A deployment where one compromised operational key could also redirect fees (or vice versa rewire the
     *      blacklist) would collapse the two-role design into a single point of failure
     */
    function test_RevertIf_KernelAdminSettersCalledByWrongAdminRole() public {
        // The market ops admin holds ADMIN_MARKET_OPS_ROLE, not ADMIN_KERNEL_ROLE
        vm.prank(MARKET_OPS_ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, MARKET_OPS_ADMIN));
        kernel.setProtocolFeeRecipient(MARKET_OPS_ADMIN);

        // The kernel admin holds ADMIN_KERNEL_ROLE, not ADMIN_MARKET_OPS_ROLE
        vm.prank(KERNEL_ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, KERNEL_ADMIN));
        kernel.setRoycoBlacklist(KERNEL_ADMIN);
    }

    /**
     * @notice An attacker cannot force-deploy the idle liquidity premium senior shares into the pool at a moment
     *         of their choosing, reinvestLiquidityPremium is market-ops gated
     * @dev A permissionless reinvest would let an attacker time the deploy against a manipulated pool composition
     *      and capture the add's slippage themselves
     */
    function test_RevertIf_ReinvestLiquidityPremiumCalledByNonMarketOps() public {
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ATTACKER));
        kernel.reinvestLiquidityPremium(type(uint256).max);
    }

    /**
     * @notice An attacker cannot drive a tranche accounting sync directly, the entrypoint is SYNC_ROLE gated
     * @dev Direct sync access is the setup step of a sync-then-swap sandwich, so the gate forces every sync
     *      through an authorized operator or the pool hook
     */
    function test_RevertIf_SyncTrancheAccountingCalledByNonSyncRole() public {
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ATTACKER));
        kernel.syncTrancheAccounting();
    }

    // =============================
    // Caller gates
    // =============================

    /// @notice The balance-update hook only accepts the three tranches as callers, any outsider is rejected
    function test_RevertIf_BalanceUpdateHookCalledByNonTranche() public {
        vm.expectRevert(IRoycoDayKernel.ONLY_TRANCHE.selector);
        kernel.preTrancheBalanceUpdateHook(address(this), address(this), makeAddr("RECIPIENT"), 1);
    }

    /// @notice Every venue driver is a kernel self-call seam, an external caller is rejected on each of the five entrypoints
    function test_RevertIf_VenueDriversCalledExternally() public {
        vm.expectRevert(IRoycoDayKernel.ONLY_SELF.selector);
        kernel.addLiquidity(1e18, 1e6, toTrancheUnits(0));
        vm.expectRevert(IRoycoDayKernel.ONLY_SELF.selector);
        kernel.removeLiquidity(toTrancheUnits(1e18), 0, 0, address(this));
        vm.expectRevert(IRoycoDayKernel.ONLY_SELF.selector);
        kernel.previewAddLiquidity(1e18, 1e6);
        vm.expectRevert(IRoycoDayKernel.ONLY_SELF.selector);
        kernel.previewRemoveLiquidity(toTrancheUnits(1e18));
        vm.expectRevert(IRoycoDayKernel.ONLY_SELF.selector);
        kernel.attemptLiquidityPremiumReinvestment(type(uint256).max, ZERO_NAV_UNITS, 0);
    }

    /// @notice The Balancer callbacks only accept the vault as caller, so no one can forge a settlement frame around the kernel's custody
    function test_RevertIf_BalancerCallbacksCalledByNonVault() public {
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        kernel.addBalancerV3Liquidity(false, 1e18, 1e6, toTrancheUnits(0));
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        kernel.removeBalancerV3Liquidity(false, toTrancheUnits(1e18), 0, 0, address(this));
    }
}

/**
 * @title Test_ColdCacheRateProvider_Kernel
 * @notice The senior share rate provider's cold-cache derivation on a seeded market, isolated in its own contract
 *         so the seeding runs in setUp (a separate transaction) and the test body's first kernel touch is truly
 *         cache-cold, mirroring production where every user interaction is its own transaction
 */
contract Test_ColdCacheRateProvider_Kernel is DayMarketTestBase {
    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        // JT 30 shares first (coverage), then ST 100 shares: coverage after seed = (100 + 30) x 0.2 / 30 = 0.8667 <= 1
        _seedMarket(100e18, 30e18);
    }

    /**
     * @notice On a freshly seeded market the cold-cache rate is exactly 1.0, the first mint's NAV per share
     * @dev The transient cache written by setUp's deposits cleared when that transaction ended, so this read takes
     *      the live-derivation path: stEffectiveNAV 100e18 over 100e18 shares = 1e18 per whole share
     */
    function test_GetRate_SeededMarketDerivesCommittedNavPerShare() public view {
        assertEq(kernel.getRate(), 1e18, "the cold-cache rate must be stEffectiveNAV / supply = 100e18 / 100e18 = 1.0");
    }
}
