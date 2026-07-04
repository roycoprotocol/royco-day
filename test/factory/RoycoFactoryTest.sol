// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { GyroECLPPoolFactory } from "../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { Test } from "../../lib/forge-std/src/Test.sol";
import { Initializable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { AccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { ERC1967Proxy } from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { DeployScript } from "../../script/Deploy.s.sol";
import { ADMIN_ENTRY_POINT_ROLE, ADMIN_FACTORY_ROLE, ADMIN_ROLE, ADMIN_UPGRADER_ROLE, DEPLOYER_ROLE } from "../../src/factory/RolesConfiguration.sol";
import { RoycoFactory } from "../../src/factory/RoycoFactory.sol";
import { DayIdenticalERC4626ChainlinkDeploymentTemplate } from "../../src/factory/templates/DayIdenticalERC4626ChainlinkDeploymentTemplate.sol";
import { COMPONENT_ID_SENIOR_TRANCHE_IMPL } from "../../src/factory/templates/base/Components.sol";
import { IRoycoFactory } from "../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../src/interfaces/factory/IRoycoProtocolTemplate.sol";

/// @title RoycoFactoryTest
/// @notice Fork tests for `RoycoFactory` driven by the REAL Day market template
///         (`DayIdenticalERC4626ChainlinkDeploymentTemplate`) — no mock. Covers: initialization + role wiring,
///         template registration/disabling, the deployment entrypoint standing up a real snUSD market (tranche
///         mappings + events + live contracts), auth/pause gating, the active-template-gated primitives rejecting
///         outside a deployment window, getters, and the UUPS upgrade gate.
/// @dev Requires a mainnet fork (real Balancer V3 + Gyro E-CLP + snUSD vault). Skips when `MAINNET_RPC_URL` is unset.
contract RoycoFactoryTest is Test {
    uint256 internal constant FORK_BLOCK = 25_400_000;
    address internal constant GYRO_ECLP_POOL_FACTORY = 0x04d584195a96DFfc7F8B695aA3C9D3c1606b69d1;

    AccessManager internal am;
    RoycoFactory internal factory;
    DeployScript internal deployScript;
    DayIdenticalERC4626ChainlinkDeploymentTemplate internal template;

    address internal FACTORY_ADMIN = makeAddr("FACTORY_ADMIN");
    address internal DEPLOYER = makeAddr("DEPLOYER");
    address internal UPGRADER = makeAddr("UPGRADER");
    address internal STRANGER = makeAddr("STRANGER");
    address internal PROTOCOL_FEE_RECIPIENT = makeAddr("PROTOCOL_FEE_RECIPIENT");

    // Mirrors of the factory's events, for `vm.expectEmit`.
    event TemplateRegistered(address indexed template);
    event TemplateDisabled(address indexed template);
    event MarketDeploymentStarted(address indexed template, address indexed deployer);
    event MarketDeploymentCompleted(address indexed template, IRoycoProtocolTemplate.DeploymentResult result);

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            // The real template's constructor + deployMarket need real Balancer V3 + Gyro + snUSD code.
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);

        // This test contract is the AccessManager admin (ADMIN_ROLE).
        am = new AccessManager(address(this));

        // OZ mandates init data in the ERC1967Proxy constructor, and `initialize` requires the factory to already hold
        // ADMIN_ROLE on the AM. So predict the proxy's CREATE address, grant it ADMIN_ROLE, then construct the proxy with
        // real init data (mirrors DeployScript's predicted-factory grant).
        RoycoFactory impl = new RoycoFactory();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        am.grantRole(ADMIN_ROLE, predicted, 0);
        factory = RoycoFactory(address(new ERC1967Proxy(address(impl), abi.encodeCall(RoycoFactory.initialize, (address(am))))));
        require(address(factory) == predicted, "proxy address prediction failed");

        // Grant the factory-facing roles the initialize() call bound to selectors.
        am.grantRole(ADMIN_FACTORY_ROLE, FACTORY_ADMIN, 0);
        am.grantRole(DEPLOYER_ROLE, DEPLOYER, 0);
        am.grantRole(ADMIN_UPGRADER_ROLE, UPGRADER, 0);

        // The real Day template, bound to this factory. `deployScript` is used only for its pure/view build helpers
        // (`dayTemplateComponents`, `buildDayParams`, `getMarketConfig`) — the factory + template above are the units under test.
        deployScript = new DeployScript();
        template = new DayIdenticalERC4626ChainlinkDeploymentTemplate(IRoycoFactory(address(factory)), GyroECLPPoolFactory(GYRO_ECLP_POOL_FACTORY));
    }

    // ─── helpers ───

    function _register() internal {
        (bytes32[] memory ids, bytes[] memory codes) = deployScript.dayTemplateComponents();
        vm.prank(FACTORY_ADMIN);
        factory.registerTemplate(address(template), ids, codes);
    }

    function _encodedParams(bytes32 _marketId) internal view returns (bytes memory) {
        return abi.encode(deployScript.buildDayParams(deployScript.getMarketConfig("snUSD"), _marketId, PROTOCOL_FEE_RECIPIENT, address(0)));
    }

    function _deploy(bytes32 _marketId) internal returns (IRoycoProtocolTemplate.DeploymentResult memory) {
        // Precompute the params first: `_encodedParams` makes external calls to `deployScript`, which would otherwise
        // consume the `vm.prank(DEPLOYER)` intended for `executeMarketDeployment`.
        bytes memory p = _encodedParams(_marketId);
        vm.prank(DEPLOYER);
        return factory.executeMarketDeployment(address(template), p);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    function test_initialize_wiresAuthorityAndRoles() external view {
        assertEq(factory.authority(), address(am), "authority");
        assertEq(factory.ROYCO_AUTHORITY(), address(am), "ROYCO_AUTHORITY");

        (bool hasEntryPoint,) = am.hasRole(ADMIN_ENTRY_POINT_ROLE, address(factory));
        assertTrue(hasEntryPoint, "factory should hold ADMIN_ENTRY_POINT_ROLE");

        assertEq(am.getTargetFunctionRole(address(factory), IRoycoFactory.executeMarketDeployment.selector), DEPLOYER_ROLE, "deploy role");
        assertEq(am.getTargetFunctionRole(address(factory), IRoycoFactory.registerTemplate.selector), ADMIN_FACTORY_ROLE, "register role");
        assertEq(am.getTargetFunctionRole(address(factory), IRoycoFactory.disableTemplate.selector), ADMIN_FACTORY_ROLE, "disable role");
        assertEq(am.getTargetFunctionRole(address(factory), UUPSUpgradeable.upgradeToAndCall.selector), ADMIN_UPGRADER_ROLE, "upgrade role");
    }

    function test_initialize_revertsOnZeroAccessManager() external {
        RoycoFactory freshImpl = new RoycoFactory();
        vm.expectRevert(IRoycoFactory.ACCESS_MANAGER_CANNOT_BE_ZERO_ADDRESS.selector);
        new ERC1967Proxy(address(freshImpl), abi.encodeCall(RoycoFactory.initialize, (address(0))));
    }

    function test_initialize_revertsWhenAccessManagerHasNoCode() external {
        address eoa = makeAddr("EOA_NO_CODE");
        RoycoFactory freshImpl = new RoycoFactory();
        vm.expectRevert(IRoycoFactory.ACCESS_MANAGER_HAS_NO_CODE.selector);
        new ERC1967Proxy(address(freshImpl), abi.encodeCall(RoycoFactory.initialize, (eoa)));
    }

    function test_initialize_revertsWhenFactoryNotAdminOnAM() external {
        RoycoFactory freshImpl = new RoycoFactory();
        vm.expectRevert(IRoycoFactory.FACTORY_NOT_ADMIN_ON_ACCESS_MANAGER.selector);
        new ERC1967Proxy(address(freshImpl), abi.encodeCall(RoycoFactory.initialize, (address(am))));
    }

    function test_initialize_revertsOnSecondCall() external {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        factory.initialize(address(am));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // registerTemplate
    // ═══════════════════════════════════════════════════════════════════════════

    function test_registerTemplate_succeeds() external {
        assertFalse(factory.isTemplateEnabled(address(template)), "not enabled pre");

        vm.expectEmit(true, false, false, false, address(factory));
        emit TemplateRegistered(address(template));

        _register();

        assertTrue(factory.isTemplateEnabled(address(template)), "enabled post");
        // Registration ran the template's `initialize`, which SSTORE2-persisted each component's creation code.
        assertTrue(template.bytecodePointer(COMPONENT_ID_SENIOR_TRANCHE_IMPL) != address(0), "component bytecode persisted");
    }

    function test_registerTemplate_revertsForNonAdmin() external {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, STRANGER));
        factory.registerTemplate(address(template), new bytes32[](0), new bytes[](0));
    }

    function test_registerTemplate_revertsOnZeroAddress() external {
        vm.prank(FACTORY_ADMIN);
        vm.expectRevert(IRoycoFactory.TEMPLATE_CANNOT_BE_ZERO_ADDRESS.selector);
        factory.registerTemplate(address(0), new bytes32[](0), new bytes[](0));
    }

    function test_registerTemplate_revertsOnDoubleRegister() external {
        _register();
        vm.prank(FACTORY_ADMIN);
        vm.expectRevert(IRoycoFactory.TEMPLATE_ALREADY_REGISTERED.selector);
        factory.registerTemplate(address(template), new bytes32[](0), new bytes[](0));
    }

    function test_registerTemplate_revertsForForeignFactory() external {
        // A real template bound to a different factory address must be rejected.
        DayIdenticalERC4626ChainlinkDeploymentTemplate foreign =
            new DayIdenticalERC4626ChainlinkDeploymentTemplate(IRoycoFactory(makeAddr("OTHER_FACTORY")), GyroECLPPoolFactory(GYRO_ECLP_POOL_FACTORY));
        vm.prank(FACTORY_ADMIN);
        vm.expectRevert(IRoycoFactory.TEMPLATE_BOUND_TO_DIFFERENT_FACTORY.selector);
        factory.registerTemplate(address(foreign), new bytes32[](0), new bytes[](0));
    }

    function test_registerTemplate_revertsWhenPaused() external {
        factory.pause(); // this == AM admin
        vm.prank(FACTORY_ADMIN);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        factory.registerTemplate(address(template), new bytes32[](0), new bytes[](0));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // disableTemplate
    // ═══════════════════════════════════════════════════════════════════════════

    function test_disableTemplate_succeeds() external {
        _register();

        vm.expectEmit(true, false, false, false, address(factory));
        emit TemplateDisabled(address(template));

        vm.prank(FACTORY_ADMIN);
        factory.disableTemplate(address(template));

        assertFalse(factory.isTemplateEnabled(address(template)), "disabled");
    }

    function test_disableTemplate_revertsForNonAdmin() external {
        _register();
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, STRANGER));
        factory.disableTemplate(address(template));
    }

    function test_disableTemplate_thenDeployReverts() external {
        _register();
        vm.prank(FACTORY_ADMIN);
        factory.disableTemplate(address(template));

        bytes memory p = _encodedParams(keccak256("disabled"));
        vm.prank(DEPLOYER);
        vm.expectRevert(IRoycoFactory.TEMPLATE_NOT_ENABLED.selector);
        factory.executeMarketDeployment(address(template), p);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // executeMarketDeployment — against the real template
    // ═══════════════════════════════════════════════════════════════════════════

    function test_execute_deploysRealMarketAndStoresMappings() external {
        _register();
        bytes memory p = _encodedParams(keccak256("snUSD-market-A"));

        vm.expectEmit(true, true, false, false, address(factory));
        emit MarketDeploymentStarted(address(template), DEPLOYER);
        vm.expectEmit(true, false, false, false, address(factory));
        emit MarketDeploymentCompleted(address(template), _emptyResult());

        vm.prank(DEPLOYER);
        IRoycoProtocolTemplate.DeploymentResult memory r = factory.executeMarketDeployment(address(template), p);

        // The real template produced live contracts.
        assertGt(r.seniorTranche.code.length, 0, "senior live");
        assertGt(r.juniorTranche.code.length, 0, "junior live");
        assertGt(r.liquidityTranche.code.length, 0, "liquidity live");
        assertGt(r.kernel.code.length, 0, "kernel live");
        assertGt(r.accountant.code.length, 0, "accountant live");
        assertTrue(r.ydm != address(0) && r.ltYdm != address(0) && r.ydm != r.ltYdm, "distinct YDM + LDM");

        // The factory recorded the senior<->junior tranche pairing.
        assertEq(factory.seniorTrancheToJuniorTranche(r.seniorTranche), r.juniorTranche, "s->j mapping");
        assertEq(factory.juniorTrancheToSeniorTranche(r.juniorTranche), r.seniorTranche, "j->s mapping");
    }

    function test_execute_clearsActiveTemplate_allowsSequentialDeploys() external {
        _register();

        IRoycoProtocolTemplate.DeploymentResult memory a = _deploy(keccak256("seq-A"));
        // A second deployment succeeding proves the transient active-template binding was cleared.
        IRoycoProtocolTemplate.DeploymentResult memory b = _deploy(keccak256("seq-B"));

        assertTrue(a.kernel != b.kernel, "distinct markets");
        assertEq(factory.seniorTrancheToJuniorTranche(b.seniorTranche), b.juniorTranche, "second mapping");
    }

    function test_execute_revertsForNonDeployer() external {
        _register();
        bytes memory p = _encodedParams(keccak256("nd"));
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, STRANGER));
        factory.executeMarketDeployment(address(template), p);
    }

    function test_execute_revertsWhenTemplateNotEnabled() external {
        // Never registered.
        bytes memory p = _encodedParams(keccak256("ne"));
        vm.prank(DEPLOYER);
        vm.expectRevert(IRoycoFactory.TEMPLATE_NOT_ENABLED.selector);
        factory.executeMarketDeployment(address(template), p);
    }

    function test_execute_revertsWhenPaused() external {
        _register();
        bytes memory p = _encodedParams(keccak256("pz"));
        factory.pause();
        vm.prank(DEPLOYER);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        factory.executeMarketDeployment(address(template), p);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEMPLATE-CALLABLE PRIMITIVES — rejected outside an active deployment window
    // ═══════════════════════════════════════════════════════════════════════════

    function test_primitives_revertWithoutActiveTemplate() external {
        // Called directly (no deployment in progress): `_activeTemplate == 0`, so every primitive rejects.
        vm.startPrank(STRANGER);

        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.deployDeterministicContract(hex"00", keccak256("x"));

        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.deployDeterministicProxy(address(this), "", keccak256("y"));

        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.setMarketTargetFunctionRole(address(this), bytes4(0), 0);

        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.grantMarketRole(0, address(this), 0);

        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.executeAsFactory(address(this), "");

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GETTERS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_getters_zeroForUnknownTranche() external {
        assertEq(factory.seniorTrancheToJuniorTranche(makeAddr("UNKNOWN_S")), address(0), "unknown s->j");
        assertEq(factory.juniorTrancheToSeniorTranche(makeAddr("UNKNOWN_J")), address(0), "unknown j->s");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // UPGRADE GATE
    // ═══════════════════════════════════════════════════════════════════════════

    function test_upgrade_revertsForNonUpgrader() external {
        address newImpl = address(new RoycoFactory());
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, STRANGER));
        factory.upgradeToAndCall(newImpl, "");
    }

    function test_upgrade_succeedsForUpgrader() external {
        address newImpl = address(new RoycoFactory());
        vm.prank(UPGRADER);
        factory.upgradeToAndCall(newImpl, "");
        assertEq(factory.authority(), address(am), "authority preserved");
    }

    // ─── internal ───

    function _emptyResult() internal pure returns (IRoycoProtocolTemplate.DeploymentResult memory r) {
        r; // zero-initialized; only used for event topic matching (data not checked)
    }
}
