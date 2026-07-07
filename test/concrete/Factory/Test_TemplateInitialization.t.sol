// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Initializable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import { AccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { SSTORE2 } from "../../../lib/solady/src/utils/SSTORE2.sol";
import { ADMIN_FACTORY_ROLE, ADMIN_ROLE, DEPLOYER_ROLE } from "../../../src/factory/RolesConfiguration.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";
import { COMPONENT_ID_SENIOR_TRANCHE_IMPL, COMPONENT_ID_YDM_ADAPTIVE_CURVE_V2 } from "../../../src/factory/templates/base/Components.sol";
import { IBaseTemplate } from "../../../src/interfaces/factory/IBaseTemplate.sol";
import { IRoycoFactory } from "../../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { AdaptiveCurveYDM_V2 } from "../../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { MockDeploymentTemplate } from "../../mocks/MockDeploymentTemplate.sol";
import { UninitializedERC1967Proxy } from "../../mocks/UninitializedERC1967Proxy.sol";

/**
 * @title Test_TemplateInitialization
 * @notice Exercises `BaseDeploymentTemplate.initialize` (the SSTORE2 component bytecode load) and the `_deployYDM`
 *         salt-reuse path, driven through a real `RoycoFactory` behind an ERC1967 proxy with a concrete mock template
 * @dev The template's bytecode registry is what every market deployment executes, so who may load it, what counts
 *      as "loaded", and which guard arms reject a malformed load are all pinned here, along with the one component
 *      (the YDM) whose deployment deliberately tolerates an already-occupied CREATE3 address
 */
contract Test_TemplateInitialization is Test {
    AccessManager internal am;
    RoycoFactory internal factory;
    MockDeploymentTemplate internal template;

    address internal STRANGER = makeAddr("STRANGER");

    function setUp() public {
        // This test contract is the AccessManager admin (ADMIN_ROLE holder zero).
        am = new AccessManager(address(this));

        // `RoycoFactory.initialize` requires the factory to already hold ADMIN_ROLE on the AM, so deploy the proxy
        // uninitialized, grant the real proxy address ADMIN_ROLE, then initialize as a separate call.
        RoycoFactory impl = new RoycoFactory();
        factory = RoycoFactory(address(new UninitializedERC1967Proxy(address(impl))));
        am.grantRole(ADMIN_ROLE, address(factory), 0);
        factory.initialize(address(am));

        // This test acts as both the factory admin (registerTemplate) and the deployer (executeMarketDeployment).
        am.grantRole(ADMIN_FACTORY_ROLE, address(this), 0);
        am.grantRole(DEPLOYER_ROLE, address(this), 0);

        // A concrete template bound to this factory, with an initially empty bytecode registry.
        template = new MockDeploymentTemplate(IRoycoFactory(address(factory)));
    }

    /// @dev Wraps one (componentId, creationCode) pair into the index-aligned arrays `initialize` takes
    function _singleComponent(bytes32 _id, bytes memory _code) internal pure returns (bytes32[] memory ids, bytes[] memory codes) {
        ids = new bytes32[](1);
        codes = new bytes[](1);
        ids[0] = _id;
        codes[0] = _code;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // initialize — who may load the bytecode registry
    // ═══════════════════════════════════════════════════════════════════════════

    /// A mempool front-runner can seed the template's bytecode registry before the deployer, and the poisoned
    /// template still registers cleanly because registration checks only the initialized flag, never the content
    function test_DIVERGENCE_20_TemplateInitialize_StrangerFrontRunsDeployerAndRegisterStillSucceeds() external {
        // CURRENT behavior: `BaseDeploymentTemplate.initialize` carries only OZ's `initializer` modifier — no caller
        // gate — so it is permissionless-first-caller. EXPECTED behavior: initialize restricted to the deployer or
        // the factory, or the loaded bytecode content verified at registration, so the code a registered template
        // deploys is provably the code the deployer intended to load.
        bytes memory attackerCode = hex"deadbeefcafe";

        // The stranger front-runs the deployer's initialize with attacker-chosen creation code.
        (bytes32[] memory ids, bytes[] memory codes) = _singleComponent(COMPONENT_ID_SENIOR_TRANCHE_IMPL, attackerCode);
        vm.prank(STRANGER);
        template.initialize(ids, codes);
        assertTrue(template.isInitialized(), "stranger's call flipped the initialized flag");

        // The deployer's own (legitimate) initialize is now permanently locked out: OZ `initializer` is single-use,
        // so the diligent deployer's only signal of the front-run is this revert.
        (bytes32[] memory legitIds, bytes[] memory legitCodes) = _singleComponent(COMPONENT_ID_SENIOR_TRANCHE_IMPL, type(AdaptiveCurveYDM_V2).creationCode);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        template.initialize(legitIds, legitCodes);

        // The registry now permanently holds the attacker's bytes: the SSTORE2 pointer resolves to exactly the
        // 6 bytes the stranger supplied, and nothing can ever overwrite them.
        address pointer = template.bytecodePointer(COMPONENT_ID_SENIOR_TRANCHE_IMPL);
        assertTrue(pointer != address(0), "attacker component pointer persisted");
        assertEq(SSTORE2.read(pointer), attackerCode, "registry holds the attacker's creation code");

        // registerTemplate checks isInitialized() only — the poisoned template enables without any content check.
        factory.registerTemplate(address(template));
        assertTrue(factory.isTemplateEnabled(address(template)), "poisoned template registered and enabled");
    }

    /// initialize with two empty arrays counts as fully initialized, so a template with zero components registers
    /// cleanly and the emptiness only surfaces at deploy time as CREATION_CODE_NOT_SET
    function test_DIVERGENCE_20_TemplateInitialize_EmptyArraysCountAsInitialized_DeployLaterRevertsCreationCodeNotSet() external {
        // CURRENT behavior: the loop body never runs for empty arrays, yet the `initializer` modifier still flips
        // the version to 1, so `isInitialized()` is true with an empty bytecode registry. EXPECTED behavior: an
        // empty component load rejected at initialize (or at registration), not discovered on the first deployment.
        template.initialize(new bytes32[](0), new bytes[](0));
        assertTrue(template.isInitialized(), "zero-component initialize counts as initialized");

        // Registration checks only the flag, so the empty template enables.
        factory.registerTemplate(address(template));
        assertTrue(factory.isTemplateEnabled(address(template)), "empty template registered and enabled");

        // First real use: nonempty params make the mock drive _deployYDM, whose creation-code read finds a zero
        // SSTORE2 pointer for the YDM component and reverts — the emptiness is caught only at deploy time.
        vm.expectRevert(abi.encodeWithSelector(IBaseTemplate.CREATION_CODE_NOT_SET.selector, COMPONENT_ID_YDM_ADAPTIVE_CURVE_V2));
        factory.executeMarketDeployment(address(template), abi.encode(keccak256("EMPTY_TEMPLATE_YDM_SALT"), uint256(0.5e18)));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // initialize — malformed-load guard arms
    // ═══════════════════════════════════════════════════════════════════════════

    /// Each malformed component load is rejected by its own guard: mismatched array lengths, the same component id
    /// twice in one call, and empty creation code
    function test_RevertIf_TemplateInitializeLengthMismatch_DuplicateComponentId_OrEmptyCreationCode() external {
        // All three arms revert, so the `initializer` modifier's state also unwinds each time and the same fresh
        // template instance can probe every guard.

        // Arm 1 — index-aligned arrays of different lengths (2 ids vs 1 code) fail the length equality check before
        // any pointer is written.
        bytes32[] memory twoIds = new bytes32[](2);
        twoIds[0] = COMPONENT_ID_SENIOR_TRANCHE_IMPL;
        twoIds[1] = COMPONENT_ID_YDM_ADAPTIVE_CURVE_V2;
        bytes[] memory oneCode = new bytes[](1);
        oneCode[0] = hex"01";
        vm.expectRevert(IBaseTemplate.LENGTH_MISMATCH.selector);
        template.initialize(twoIds, oneCode);

        // Arm 2 — the same id twice within ONE call: iteration 0 writes the pointer, iteration 1 finds it nonzero
        // and rejects, so a single load can never silently overwrite one of its own components.
        bytes32[] memory dupIds = new bytes32[](2);
        dupIds[0] = COMPONENT_ID_SENIOR_TRANCHE_IMPL;
        dupIds[1] = COMPONENT_ID_SENIOR_TRANCHE_IMPL;
        bytes[] memory twoCodes = new bytes[](2);
        twoCodes[0] = hex"01";
        twoCodes[1] = hex"02";
        vm.expectRevert(abi.encodeWithSelector(IBaseTemplate.CREATION_CODE_ALREADY_SET.selector, COMPONENT_ID_SENIOR_TRANCHE_IMPL));
        template.initialize(dupIds, twoCodes);

        // Arm 3 — empty creation code is rejected: an empty SSTORE2 blob would otherwise pass the not-set check
        // forever while deploying nothing.
        (bytes32[] memory ids, bytes[] memory codes) = _singleComponent(COMPONENT_ID_SENIOR_TRANCHE_IMPL, "");
        vm.expectRevert(abi.encodeWithSelector(IBaseTemplate.CREATION_CODE_CANNOT_BE_EMPTY.selector, COMPONENT_ID_SENIOR_TRANCHE_IMPL));
        template.initialize(ids, codes);

        // All three loads unwound completely: the registry is still empty and the template still uninitialized.
        assertEq(template.bytecodePointer(COMPONENT_ID_SENIOR_TRANCHE_IMPL), address(0), "no pointer survived a reverted load");
        assertFalse(template.isInitialized(), "reverted loads left the template uninitialized");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // _deployYDM — the documented salt-reuse exception
    // ═══════════════════════════════════════════════════════════════════════════

    /// _deployYDM is the one component deploy that tolerates an occupied CREATE3 address: a second deployment at the
    /// same salt returns the existing instance, and the second call's requested target utilization is silently ignored
    function test_DeployYDM_ReusesExistingInstanceAtSalt_RequestedTargetUtilizationSilentlyIgnored() external {
        // Register the template with the REAL AdaptiveCurveYDM_V2 creation code so _deployYDM appends the target
        // utilization as a genuine constructor arg and deploys a live model instance.
        (bytes32[] memory ids, bytes[] memory codes) = _singleComponent(COMPONENT_ID_YDM_ADAPTIVE_CURVE_V2, type(AdaptiveCurveYDM_V2).creationCode);
        template.initialize(ids, codes);
        factory.registerTemplate(address(template));

        // The factory requires a non-zero kernel in the deployment result; this test only exercises the YDM path,
        // so hand back a minimal result carrying a kernel (tranches may be zero — those registry writes are skipped).
        template.setDeploymentResult(
            IRoycoProtocolTemplate.DeploymentResult({
                seniorTranche: address(0),
                juniorTranche: address(0),
                liquidityTranche: address(0),
                kernel: makeAddr("YDM_TEST_KERNEL"),
                accountant: address(0),
                ydm: address(0),
                ltYdm: address(0),
                extras: ""
            })
        );

        // First deployment at the salt: fresh instance, so alreadyDeployed is false and the immutable kink is
        // exactly the 0.5e18 passed as the constructor arg (the appended abi.encode(0.5e18) word).
        bytes32 salt = keccak256("SHARED_YDM_SALT");
        factory.executeMarketDeployment(address(template), abi.encode(salt, uint256(0.5e18)));
        address firstYdm = template.lastDeployedYDM();
        assertTrue(firstYdm != address(0), "first deployment produced a live YDM");
        assertFalse(template.lastYDMAlreadyDeployed(), "first deployment was fresh");
        assertEq(AdaptiveCurveYDM_V2(firstYdm).TARGET_UTILIZATION_WAD(), 0.5e18, "kink pinned to the first call's constructor arg");

        // Second deployment at the SAME salt requesting a DIFFERENT kink (0.9e18). The CREATE3 address depends only
        // on (factory, salt) — never on the creation code — so the occupied-address check short-circuits before the
        // 0.9e18 constructor arg is ever executed. This reuse is the intended cross-market YDM sharing, and this is
        // its exact hazard: the requested 0.9e18 is silently discarded, with no revert and no event, leaving the
        // caller wired to a model whose kink it did not ask for.
        factory.executeMarketDeployment(address(template), abi.encode(salt, uint256(0.9e18)));
        assertEq(template.lastDeployedYDM(), firstYdm, "same salt resolves to the same instance");
        assertTrue(template.lastYDMAlreadyDeployed(), "second deployment reused the existing instance");
        assertEq(AdaptiveCurveYDM_V2(firstYdm).TARGET_UTILIZATION_WAD(), 0.5e18, "kink still the FIRST call's 0.5e18, the requested 0.9e18 vanished");
    }
}
