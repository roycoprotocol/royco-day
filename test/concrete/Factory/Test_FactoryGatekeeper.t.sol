// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { RoycoAccessManager } from "../../../src/factory/RoycoAccessManager.sol";
import { RoycoFactoryGatekeeper } from "../../../src/factory/RoycoFactoryGatekeeper.sol";
import { ADMIN_ROLE, BURNER_ROLE, PUBLIC_ROLE, ST_LP_ROLE, SYNC_ROLE } from "../../../src/factory/Roles.sol";
import { IRoycoFactoryGatekeeper } from "../../../src/interfaces/factory/IRoycoFactoryGatekeeper.sol";

/**
 * @title Test_FactoryGatekeeper
 * @notice The gatekeeper is the containment boundary that replaces the factory's `ADMIN_ROLE`: a market deployment may
 *         configure a contract exactly once, and may never configure a contract that already exists
 * @dev The fixture stands in for the factory with a plain EOA so the rules are exercised in isolation, without a
 *      deployment window or a template in the way. Both sides of the pairing are constructor immutables, which the
 *      production deployment achieves by giving the factory proxy a CREATE3 address (see RoycoCreate3Deployer)
 */
contract Test_FactoryGatekeeper is Test {
    RoycoAccessManager internal am;
    RoycoFactoryGatekeeper internal gatekeeper;

    address internal FACTORY = makeAddr("FACTORY");
    address internal STRANGER = makeAddr("STRANGER");
    address internal FRESH_TARGET = makeAddr("FRESH_TARGET");

    bytes4 internal constant SELECTOR_A = 0xaaaaaaaa;
    bytes4 internal constant SELECTOR_B = 0xbbbbbbbb;

    function setUp() public {
        am = new RoycoAccessManager(address(this));
        gatekeeper = new RoycoFactoryGatekeeper(address(am), FACTORY);
        am.grantRole(ADMIN_ROLE, address(gatekeeper), 0);
    }

    function _bind(address _target, bytes4[] memory _selectors, uint64[] memory _roleIds) internal {
        vm.prank(FACTORY);
        gatekeeper.configureFreshTarget(_target, _selectors, _roleIds);
    }

    /// @dev Neither role may be ADMIN_ROLE or PUBLIC_ROLE: `configureFreshTarget` rejects both outright
    function _two() internal pure returns (bytes4[] memory selectors, uint64[] memory roleIds) {
        selectors = new bytes4[](2);
        roleIds = new uint64[](2);
        (selectors[0], roleIds[0]) = (SELECTOR_A, SYNC_ROLE);
        (selectors[1], roleIds[1]) = (SELECTOR_B, ST_LP_ROLE);
    }

    /// @dev One selector bound to an arbitrary role, for the role-value rejection tests
    function _one(uint64 _roleId) internal pure returns (bytes4[] memory selectors, uint64[] memory roleIds) {
        selectors = new bytes4[](1);
        roleIds = new uint64[](1);
        (selectors[0], roleIds[0]) = (SELECTOR_A, _roleId);
    }

    // ---------------------------------------------------------------------
    // The happy path, and the reason a whole target is configured in ONE call
    // ---------------------------------------------------------------------

    /// @notice A fresh target's whole selector set binds in one call, and the access manager records it as configured
    function test_configureFreshTarget_bindsEverySelectorAndMarksTheTargetConfigured() public {
        assertFalse(am.wasEverConfigured(FRESH_TARGET), "a target nobody has touched must read as never configured");

        (bytes4[] memory selectors, uint64[] memory roleIds) = _two();
        _bind(FRESH_TARGET, selectors, roleIds);

        assertEq(am.getTargetFunctionRole(FRESH_TARGET, SELECTOR_A), SYNC_ROLE, "the first selector must be bound");
        assertEq(am.getTargetFunctionRole(FRESH_TARGET, SELECTOR_B), ST_LP_ROLE, "the second selector must be bound");
        assertTrue(am.wasEverConfigured(FRESH_TARGET), "configuring a target must record it");
    }

    /**
     * @notice A target may be configured exactly once. This is the whole point: a later deployment cannot re-point an
     *         existing market's kernel, a periphery singleton, or anything else already in the system
     */
    function test_RevertIf_targetWasAlreadyConfigured() public {
        (bytes4[] memory selectors, uint64[] memory roleIds) = _two();
        _bind(FRESH_TARGET, selectors, roleIds);

        vm.expectRevert(abi.encodeWithSelector(IRoycoFactoryGatekeeper.TARGET_ALREADY_CONFIGURED.selector, FRESH_TARGET));
        _bind(FRESH_TARGET, selectors, roleIds);
    }

    /**
     * @notice A target configured by ANY other path is equally off limits, which is why the record lives in the access
     *         manager rather than in the factory: governance and the deploy script write directly, never via the factory
     */
    function test_RevertIf_targetWasConfiguredDirectlyByGovernance() public {
        bytes4[] memory governanceSelectors = new bytes4[](1);
        governanceSelectors[0] = SELECTOR_A;
        am.setTargetFunctionRole(FRESH_TARGET, governanceSelectors, SYNC_ROLE);

        (bytes4[] memory selectors, uint64[] memory roleIds) = _two();
        vm.expectRevert(abi.encodeWithSelector(IRoycoFactoryGatekeeper.TARGET_ALREADY_CONFIGURED.selector, FRESH_TARGET));
        _bind(FRESH_TARGET, selectors, roleIds);
    }

    // ---------------------------------------------------------------------
    // The protocol's own contracts
    // ---------------------------------------------------------------------

    /**
     * @notice The access manager is refused explicitly, NOT by the freshness rule. It holds no target-function config
     *         for itself (its admin surface resolves internally), so it reads as fresh and the freshness check alone
     *         would let a deployment re-bind the access manager's own selectors: the sharpest escalation available
     */
    function test_RevertIf_targetIsTheAccessManager() public {
        assertFalse(am.wasEverConfigured(address(am)), "the access manager holds no self configuration, so it reads as fresh");

        (bytes4[] memory selectors, uint64[] memory roleIds) = _two();
        vm.expectRevert(abi.encodeWithSelector(IRoycoFactoryGatekeeper.TARGET_FORBIDDEN.selector, address(am)));
        _bind(address(am), selectors, roleIds);
    }

    /// @notice The factory can never re-bind its own selectors, which would let it re-gate its own upgrade path
    function test_RevertIf_targetIsTheFactory() public {
        (bytes4[] memory selectors, uint64[] memory roleIds) = _two();
        vm.expectRevert(abi.encodeWithSelector(IRoycoFactoryGatekeeper.TARGET_FORBIDDEN.selector, FACTORY));
        _bind(FACTORY, selectors, roleIds);
    }

    /// @notice Nor the gatekeeper itself, which holds the `ADMIN_ROLE` this whole design is protecting
    function test_RevertIf_targetIsTheGatekeeper() public {
        (bytes4[] memory selectors, uint64[] memory roleIds) = _two();
        vm.expectRevert(abi.encodeWithSelector(IRoycoFactoryGatekeeper.TARGET_FORBIDDEN.selector, address(gatekeeper)));
        _bind(address(gatekeeper), selectors, roleIds);
    }

    // ---------------------------------------------------------------------
    // Caller and argument gating
    // ---------------------------------------------------------------------

    /// @notice Only the one factory the gatekeeper was constructed for may call it
    function test_RevertIf_callerIsNotTheFactory() public {
        (bytes4[] memory selectors, uint64[] memory roleIds) = _two();
        vm.prank(STRANGER);
        vm.expectRevert(IRoycoFactoryGatekeeper.ONLY_FACTORY.selector);
        gatekeeper.configureFreshTarget(FRESH_TARGET, selectors, roleIds);
    }

    /// @notice Mismatched selector/role arrays are rejected before anything is written
    function test_RevertIf_selectorAndRoleArraysDiffer() public {
        bytes4[] memory selectors = new bytes4[](2);
        uint64[] memory roleIds = new uint64[](1);
        vm.expectRevert(IRoycoFactoryGatekeeper.LENGTH_MISMATCH.selector);
        _bind(FRESH_TARGET, selectors, roleIds);
        assertFalse(am.wasEverConfigured(FRESH_TARGET), "a rejected call must not have marked the target");
    }

    /// @notice A gatekeeper can never be deployed serving nobody, in either direction
    function test_RevertIf_constructedWithZeroAddress() public {
        vm.expectRevert(IRoycoFactoryGatekeeper.NULL_ADDRESS.selector);
        new RoycoFactoryGatekeeper(address(0), FACTORY);
        vm.expectRevert(IRoycoFactoryGatekeeper.NULL_ADDRESS.selector);
        new RoycoFactoryGatekeeper(address(am), address(0));
    }


    // ---------------------------------------------------------------------
    // grantMarketRoles: the constant two-role whitelist and its freshness rule
    // ---------------------------------------------------------------------

    /// @dev Builds the three index-aligned grant arrays for a single grant
    function _grantArrays(uint64 _roleId, address _account) internal pure returns (uint64[] memory roleIds, address[] memory accounts, uint32[] memory delays) {
        roleIds = new uint64[](1);
        accounts = new address[](1);
        delays = new uint32[](1);
        (roleIds[0], accounts[0]) = (_roleId, _account);
    }

    /// @notice SYNC_ROLE and BURNER_ROLE, the only two roles a market deployment legitimately mints, both land in one
    ///         batched call and the gatekeeper announces the batch size
    function test_grantMarketRoles_grantsTheTwoWhitelistedRolesInOneBatch() public {
        address syncHolder = makeAddr("SYNC_HOLDER");
        address burnerHolder = makeAddr("BURNER_HOLDER");
        uint64[] memory roleIds = new uint64[](2);
        address[] memory accounts = new address[](2);
        uint32[] memory delays = new uint32[](2);
        (roleIds[0], accounts[0]) = (SYNC_ROLE, syncHolder);
        (roleIds[1], accounts[1]) = (BURNER_ROLE, burnerHolder);

        vm.expectEmit(false, false, false, true, address(gatekeeper));
        emit IRoycoFactoryGatekeeper.MarketRolesGranted(2);
        vm.prank(FACTORY);
        gatekeeper.grantMarketRoles(roleIds, accounts, delays);

        (bool syncGranted,) = am.hasRole(SYNC_ROLE, syncHolder);
        (bool burnerGranted,) = am.hasRole(BURNER_ROLE, burnerHolder);
        assertTrue(syncGranted, "SYNC_ROLE must be grantable by a deployment");
        assertTrue(burnerGranted, "BURNER_ROLE must be grantable by a deployment");
    }

    /// @notice Only the one factory may mint market roles
    function test_RevertIf_grantMarketRolesCalledByNonFactory() public {
        (uint64[] memory roleIds, address[] memory accounts, uint32[] memory delays) = _grantArrays(SYNC_ROLE, makeAddr("HOLDER"));
        vm.prank(STRANGER);
        vm.expectRevert(IRoycoFactoryGatekeeper.ONLY_FACTORY.selector);
        gatekeeper.grantMarketRoles(roleIds, accounts, delays);
    }

    /// @notice All three grant arrays must be index-aligned, in either direction of mismatch
    function test_RevertIf_grantMarketRolesArraysDiffer() public {
        vm.startPrank(FACTORY);
        vm.expectRevert(IRoycoFactoryGatekeeper.LENGTH_MISMATCH.selector);
        gatekeeper.grantMarketRoles(new uint64[](2), new address[](1), new uint32[](2));
        vm.expectRevert(IRoycoFactoryGatekeeper.LENGTH_MISMATCH.selector);
        gatekeeper.grantMarketRoles(new uint64[](2), new address[](2), new uint32[](1));
        vm.stopPrank();
    }

    /// @notice Every role outside the two-entry whitelist is refused with the offending id, including the sharpest
    ///         escalation (ADMIN_ROLE) and an ordinary LP role a deployment has no business minting
    function test_RevertIf_grantMarketRolesGrantsANonWhitelistedRole() public {
        (uint64[] memory adminRoleIds, address[] memory adminAccounts, uint32[] memory adminDelays) = _grantArrays(ADMIN_ROLE, makeAddr("HOLDER"));
        vm.prank(FACTORY);
        vm.expectRevert(abi.encodeWithSelector(IRoycoFactoryGatekeeper.ROLE_FORBIDDEN.selector, ADMIN_ROLE));
        gatekeeper.grantMarketRoles(adminRoleIds, adminAccounts, adminDelays);

        (uint64[] memory lpRoleIds, address[] memory lpAccounts, uint32[] memory lpDelays) = _grantArrays(ST_LP_ROLE, makeAddr("HOLDER"));
        vm.prank(FACTORY);
        vm.expectRevert(abi.encodeWithSelector(IRoycoFactoryGatekeeper.ROLE_FORBIDDEN.selector, ST_LP_ROLE));
        gatekeeper.grantMarketRoles(lpRoleIds, lpAccounts, lpDelays);
    }

    /// @notice The protocol's own contracts can never receive a market role, the factory above all: a factory holding
    ///         SYNC or BURNER would let any active template drive those surfaces via executeAsFactory
    function test_RevertIf_grantMarketRolesTargetsAProtocolContract() public {
        address[3] memory forbidden = [FACTORY, address(gatekeeper), address(am)];
        for (uint256 i = 0; i < forbidden.length; ++i) {
            (uint64[] memory roleIds, address[] memory accounts, uint32[] memory delays) = _grantArrays(SYNC_ROLE, forbidden[i]);
            vm.prank(FACTORY);
            vm.expectRevert(abi.encodeWithSelector(IRoycoFactoryGatekeeper.TARGET_FORBIDDEN.selector, forbidden[i]));
            gatekeeper.grantMarketRoles(roleIds, accounts, delays);
        }
    }

    /// @notice An account that was ever configured as a target is refused a market role: it existed before this
    ///         deployment, so the deployment has no claim on it
    function test_RevertIf_grantMarketRolesAccountWasEverConfigured() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = SELECTOR_A;
        am.setTargetFunctionRole(FRESH_TARGET, selectors, SYNC_ROLE);

        (uint64[] memory roleIds, address[] memory accounts, uint32[] memory delays) = _grantArrays(SYNC_ROLE, FRESH_TARGET);
        vm.prank(FACTORY);
        vm.expectRevert(abi.encodeWithSelector(IRoycoFactoryGatekeeper.TARGET_ALREADY_CONFIGURED.selector, FRESH_TARGET));
        gatekeeper.grantMarketRoles(roleIds, accounts, delays);
    }

    /// @notice A batch is atomic: one forbidden entry unwinds every grant that preceded it
    function test_grantMarketRoles_batchIsAtomic() public {
        address legitimateHolder = makeAddr("LEGITIMATE_HOLDER");
        uint64[] memory roleIds = new uint64[](2);
        address[] memory accounts = new address[](2);
        uint32[] memory delays = new uint32[](2);
        (roleIds[0], accounts[0]) = (SYNC_ROLE, legitimateHolder);
        (roleIds[1], accounts[1]) = (ADMIN_ROLE, makeAddr("ESCALATION_TARGET"));

        vm.prank(FACTORY);
        vm.expectRevert(abi.encodeWithSelector(IRoycoFactoryGatekeeper.ROLE_FORBIDDEN.selector, ADMIN_ROLE));
        gatekeeper.grantMarketRoles(roleIds, accounts, delays);

        (bool granted,) = am.hasRole(SYNC_ROLE, legitimateHolder);
        assertFalse(granted, "a rejected batch must unwind its earlier grants");
    }

    /// @notice A role grant does not mark the account as configured: grants are membership, not target config, so a
    ///         deployment can still bind the granted contract's selectors afterwards
    function test_grantMarketRoles_doesNotMarkTheAccountConfigured() public {
        address marketKernel = makeAddr("MARKET_KERNEL");
        (uint64[] memory roleIds, address[] memory accounts, uint32[] memory delays) = _grantArrays(BURNER_ROLE, marketKernel);
        vm.prank(FACTORY);
        gatekeeper.grantMarketRoles(roleIds, accounts, delays);

        assertFalse(am.wasEverConfigured(marketKernel), "a grant must not record the account as a configured target");

        // The same deployment can still configure the granted contract as a fresh target
        bytes4[] memory selectors = new bytes4[](1);
        uint64[] memory bindRoleIds = new uint64[](1);
        (selectors[0], bindRoleIds[0]) = (SELECTOR_A, SYNC_ROLE);
        _bind(marketKernel, selectors, bindRoleIds);
        assertTrue(am.wasEverConfigured(marketKernel), "the follow-up binding must record it");
    }

    // ---------------------------------------------------------------------
    // Governance is deliberately unaffected
    // ---------------------------------------------------------------------

    /**
     * @notice The fresh-target rule binds the FACTORY path only. Governance holds `ADMIN_ROLE` and writes to the access
     *         manager directly, so it can still reconfigure a contract that has already been configured
     */
    function test_governanceCanStillReconfigureAnAlreadyConfiguredTarget() public {
        (bytes4[] memory selectors, uint64[] memory roleIds) = _two();
        _bind(FRESH_TARGET, selectors, roleIds);

        bytes4[] memory rebind = new bytes4[](1);
        rebind[0] = SELECTOR_A;
        am.setTargetFunctionRole(FRESH_TARGET, rebind, ADMIN_ROLE);
        assertEq(am.getTargetFunctionRole(FRESH_TARGET, SELECTOR_A), ADMIN_ROLE, "governance must retain a direct reconfiguration path");
    }

    // ---------------------------------------------------------------------
    // Role-value gating
    // ---------------------------------------------------------------------

    /**
     * @notice A market's bindings gate admin surfaces, so PUBLIC_ROLE is never legitimate: it would leave the selector
     *         callable by anyone. Enforced here rather than only in a template, so no template can bind around it
     */
    function test_RevertIf_configureFreshTargetBindsPublicRole() public {
        (bytes4[] memory selectors, uint64[] memory roleIds) = _one(PUBLIC_ROLE);
        vm.expectRevert(abi.encodeWithSelector(IRoycoFactoryGatekeeper.ROLE_FORBIDDEN.selector, PUBLIC_ROLE));
        _bind(FRESH_TARGET, selectors, roleIds);
    }

    /// @notice ADMIN_ROLE is the access manager's super-admin, equally never a gate a market deployment should install
    function test_RevertIf_configureFreshTargetBindsAdminRole() public {
        (bytes4[] memory selectors, uint64[] memory roleIds) = _one(ADMIN_ROLE);
        vm.expectRevert(abi.encodeWithSelector(IRoycoFactoryGatekeeper.ROLE_FORBIDDEN.selector, ADMIN_ROLE));
        _bind(FRESH_TARGET, selectors, roleIds);
    }

    /// @notice A forbidden role anywhere in the set rejects the whole call, leaving the target unconfigured and still fresh
    function test_RevertIf_configureFreshTargetBindsAForbiddenRoleAfterAValidOne() public {
        bytes4[] memory selectors = new bytes4[](2);
        uint64[] memory roleIds = new uint64[](2);
        (selectors[0], roleIds[0]) = (SELECTOR_A, SYNC_ROLE);
        (selectors[1], roleIds[1]) = (SELECTOR_B, PUBLIC_ROLE);

        vm.expectRevert(abi.encodeWithSelector(IRoycoFactoryGatekeeper.ROLE_FORBIDDEN.selector, PUBLIC_ROLE));
        _bind(FRESH_TARGET, selectors, roleIds);

        assertFalse(am.wasEverConfigured(FRESH_TARGET), "a rejected binding must not consume the target's one-time freshness");
    }
}
