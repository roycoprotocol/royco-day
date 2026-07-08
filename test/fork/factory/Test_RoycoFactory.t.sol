// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ILPOracleFactoryBase } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/oracles/ILPOracleFactoryBase.sol";
import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { TokenInfo, TokenType } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { GyroECLPPoolFactory } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Initializable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { AccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { CREATE3 } from "../../../lib/solady/src/utils/CREATE3.sol";
import { DeployScript } from "../../../script/Deploy.s.sol";
import { MarketDeploymentConfig } from "../../../script/config/MarketDeploymentConfig.sol";
import {
    ADMIN_ENTRY_POINT_ROLE,
    ADMIN_FACTORY_ROLE,
    ADMIN_PAUSER_ROLE,
    ADMIN_ROLE,
    ADMIN_UNPAUSER_ROLE,
    ADMIN_UPGRADER_ROLE,
    DEPLOYER_ROLE
} from "../../../src/factory/RolesConfiguration.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";
import { Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3GyroECLP_LT_DeploymentTemplate } from "../../../src/factory/templates/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3GyroECLP_LT_DeploymentTemplate.sol";
import { BaseDeploymentTemplate } from "../../../src/factory/templates/base/BaseDeploymentTemplate.sol";
import { COMPONENT_ID_SENIOR_TRANCHE_IMPL, TAG_ST_IMPL, TAG_ST_PROXY } from "../../../src/factory/templates/base/Components.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoFactory } from "../../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { AdaptiveCurveYDM_V1 } from "../../../src/ydm/AdaptiveCurveYDM_V1.sol";
import { AdaptiveCurveYDM_V2 } from "../../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { StaticCurveYDM } from "../../../src/ydm/StaticCurveYDM.sol";

/// @title Test_RoycoFactory
/// @notice Fork tests for `RoycoFactory` driven by the REAL Day market template
///         (`Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3GyroECLP_LT_DeploymentTemplate`) — no mock. Covers: initialization + role wiring,
///         template registration/disabling, the deployment entrypoint standing up a real snUSD market (tranche
///         mappings + events + live contracts), auth/pause gating, the active-template-gated primitives rejecting
///         outside a deployment window, getters, and the UUPS upgrade gate.
/// @dev Requires a mainnet fork (real Balancer V3 + Gyro E-CLP + snUSD vault). FAILS (env not found) when
///      `MAINNET_RPC_URL` is unset, instead of silently passing.
contract Test_RoycoFactory is Test {
    uint256 internal constant FORK_BLOCK = 25_400_000;
    address internal constant GYRO_ECLP_POOL_FACTORY = 0x04d584195a96DFfc7F8B695aA3C9D3c1606b69d1;
    address internal constant ECLP_LP_ORACLE_FACTORY = 0x301EDe5Fd4f9d7266B09c3A2E38F97776447154B;

    AccessManager internal am;
    RoycoFactory internal factory;
    DeployScript internal deployScript;
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3GyroECLP_LT_DeploymentTemplate internal template;

    address internal FACTORY_ADMIN = makeAddr("FACTORY_ADMIN");
    address internal DEPLOYER = makeAddr("DEPLOYER");
    address internal UPGRADER = makeAddr("UPGRADER");
    address internal STRANGER = makeAddr("STRANGER");
    address internal PROTOCOL_FEE_RECIPIENT = makeAddr("PROTOCOL_FEE_RECIPIENT");

    // Mirrors of the factory's events, for `vm.expectEmit`.
    event TemplateRegistered(address indexed template);
    event TemplateDisabled(address indexed template);
    event MarketDeploymentCompleted(address indexed template, address indexed deployer, IRoycoProtocolTemplate.DeploymentResult result);

    function setUp() public {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
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
        // initialize() binds the factory's pause/unpause to the pauser/unpauser roles, so this test contract (the AM
        // admin) needs them to pause/unpause the factory directly.
        am.grantRole(ADMIN_PAUSER_ROLE, address(this), 0);
        am.grantRole(ADMIN_UNPAUSER_ROLE, address(this), 0);

        // The real Day template, bound to this factory. `deployScript` is used only for its pure/view build helpers
        // (`dayTemplateComponents`, `buildDayParams`, `getMarketConfig`) — the factory + template above are the units under test.
        deployScript = new DeployScript();
        template = new Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3GyroECLP_LT_DeploymentTemplate(
            IRoycoFactory(address(factory)), GyroECLPPoolFactory(GYRO_ECLP_POOL_FACTORY), ILPOracleFactoryBase(ECLP_LP_ORACLE_FACTORY)
        );
    }

    // ─── helpers ───

    function _register() internal {
        (bytes32[] memory ids, bytes[] memory codes) = deployScript.dayTemplateComponents();
        template.initialize(ids, codes);
        vm.prank(FACTORY_ADMIN);
        factory.registerTemplate(address(template));
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

    /// initialize wires the authority and binds every factory entrypoint to its intended role
    function test_Initialize_WiresAuthorityAndRoles() external view {
        assertEq(factory.authority(), address(am), "authority");
        assertEq(factory.ROYCO_AUTHORITY(), address(am), "ROYCO_AUTHORITY");

        (bool hasEntryPoint,) = am.hasRole(ADMIN_ENTRY_POINT_ROLE, address(factory));
        assertTrue(hasEntryPoint, "factory should hold ADMIN_ENTRY_POINT_ROLE");

        assertEq(am.getTargetFunctionRole(address(factory), IRoycoFactory.executeMarketDeployment.selector), DEPLOYER_ROLE, "deploy role");
        assertEq(am.getTargetFunctionRole(address(factory), IRoycoFactory.registerTemplate.selector), ADMIN_FACTORY_ROLE, "register role");
        assertEq(am.getTargetFunctionRole(address(factory), IRoycoFactory.disableTemplate.selector), ADMIN_FACTORY_ROLE, "disable role");
        assertEq(am.getTargetFunctionRole(address(factory), UUPSUpgradeable.upgradeToAndCall.selector), ADMIN_UPGRADER_ROLE, "upgrade role");
    }

    /// A zero AccessManager address is rejected at initialization
    function test_RevertIf_InitializedWithZeroAccessManager() external {
        RoycoFactory freshImpl = new RoycoFactory();
        vm.expectRevert(IRoycoFactory.ACCESS_MANAGER_CANNOT_BE_ZERO_ADDRESS.selector);
        new ERC1967Proxy(address(freshImpl), abi.encodeCall(RoycoFactory.initialize, (address(0))));
    }

    /// An AccessManager with no code is rejected: the factory refuses a dead authority
    function test_RevertIf_InitializedWithCodelessAccessManager() external {
        address eoa = makeAddr("EOA_NO_CODE");
        RoycoFactory freshImpl = new RoycoFactory();
        vm.expectRevert(IRoycoFactory.ACCESS_MANAGER_HAS_NO_CODE.selector);
        new ERC1967Proxy(address(freshImpl), abi.encodeCall(RoycoFactory.initialize, (eoa)));
    }

    /// The factory must already hold ADMIN_ROLE on the AccessManager when initialize runs
    function test_RevertIf_InitializedWithoutAdminRoleOnAccessManager() external {
        RoycoFactory freshImpl = new RoycoFactory();
        vm.expectRevert(IRoycoFactory.FACTORY_NOT_ADMIN_ON_ACCESS_MANAGER.selector);
        new ERC1967Proxy(address(freshImpl), abi.encodeCall(RoycoFactory.initialize, (address(am))));
    }

    /// The initializer is single-use
    function test_RevertIf_InitializedTwice() external {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        factory.initialize(address(am));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // registerTemplate
    // ═══════════════════════════════════════════════════════════════════════════

    /// Registering a pre-initialized template enables it and emits TemplateRegistered
    function test_RegisterTemplate_EnablesInitializedTemplateWithEvent() external {
        assertFalse(factory.isTemplateEnabled(address(template)), "not enabled pre");

        // The deployer initializes the template directly (SSTORE2-persisting each component's creation code) ...
        (bytes32[] memory ids, bytes[] memory codes) = deployScript.dayTemplateComponents();
        template.initialize(ids, codes);
        assertTrue(template.bytecodePointer(COMPONENT_ID_SENIOR_TRANCHE_IMPL) != address(0), "component bytecode persisted");
        assertTrue(template.isInitialized(), "template initialized");

        // ... then the factory registers the pre-initialized template.
        vm.expectEmit(true, false, false, false, address(factory));
        emit TemplateRegistered(address(template));
        vm.prank(FACTORY_ADMIN);
        factory.registerTemplate(address(template));

        assertTrue(factory.isTemplateEnabled(address(template)), "enabled post");
    }

    /// Only ADMIN_FACTORY_ROLE may register templates
    function test_RevertIf_NonFactoryAdminRegistersTemplate() external {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, STRANGER));
        factory.registerTemplate(address(template));
    }

    /// The zero address is rejected as a template
    function test_RevertIf_ZeroAddressTemplateRegistered() external {
        vm.prank(FACTORY_ADMIN);
        vm.expectRevert(IRoycoFactory.TEMPLATE_CANNOT_BE_ZERO_ADDRESS.selector);
        factory.registerTemplate(address(0));
    }

    /// A template cannot be registered twice
    function test_RevertIf_TemplateRegisteredTwice() external {
        _register();
        vm.prank(FACTORY_ADMIN);
        vm.expectRevert(IRoycoFactory.TEMPLATE_ALREADY_REGISTERED.selector);
        factory.registerTemplate(address(template));
    }

    /// The factory refuses a template whose component bytecode store was never initialized
    function test_RevertIf_UninitializedTemplateRegistered() external {
        // The factory refuses to enable a template whose component bytecode store was never initialized.
        vm.prank(FACTORY_ADMIN);
        vm.expectRevert(IRoycoFactory.TEMPLATE_NOT_INITIALIZED.selector);
        factory.registerTemplate(address(template));
    }

    /// Disabling is reversible: a disabled template can be re-registered
    function test_RegisterTemplate_ReRegisterAfterDisable() external {
        // Registration no longer initializes the template, so disable is reversible: disable -> re-register works.
        _register();
        vm.prank(FACTORY_ADMIN);
        factory.disableTemplate(address(template));
        assertFalse(factory.isTemplateEnabled(address(template)), "disabled");

        vm.prank(FACTORY_ADMIN);
        factory.registerTemplate(address(template));
        assertTrue(factory.isTemplateEnabled(address(template)), "re-enabled");
    }

    /// A template constructed against a different factory address is rejected
    function test_RevertIf_TemplateBoundToDifferentFactoryRegistered() external {
        // A real template bound to a different factory address must be rejected.
        Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3GyroECLP_LT_DeploymentTemplate foreign = new Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3GyroECLP_LT_DeploymentTemplate(
            IRoycoFactory(makeAddr("OTHER_FACTORY")), GyroECLPPoolFactory(GYRO_ECLP_POOL_FACTORY), ILPOracleFactoryBase(ECLP_LP_ORACLE_FACTORY)
        );
        vm.prank(FACTORY_ADMIN);
        vm.expectRevert(IRoycoFactory.TEMPLATE_BOUND_TO_DIFFERENT_FACTORY.selector);
        factory.registerTemplate(address(foreign));
    }

    /// Registration is blocked while the factory is paused
    function test_RevertIf_TemplateRegisteredWhilePaused() external {
        factory.pause(); // this == AM admin
        vm.prank(FACTORY_ADMIN);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        factory.registerTemplate(address(template));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // disableTemplate
    // ═══════════════════════════════════════════════════════════════════════════

    /// Disabling an enabled template emits TemplateDisabled and turns the enable flag off
    function test_DisableTemplate_DisablesWithEvent() external {
        _register();

        vm.expectEmit(true, false, false, false, address(factory));
        emit TemplateDisabled(address(template));

        vm.prank(FACTORY_ADMIN);
        factory.disableTemplate(address(template));

        assertFalse(factory.isTemplateEnabled(address(template)), "disabled");
    }

    /// Only ADMIN_FACTORY_ROLE may disable templates
    function test_RevertIf_NonFactoryAdminDisablesTemplate() external {
        _register();
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, STRANGER));
        factory.disableTemplate(address(template));
    }

    /// A disabled template cannot deploy markets
    function test_RevertIf_DeployingThroughDisabledTemplate() external {
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

    /// A real deployment produces live contracts, emits the completion event, and registers every tranche in the market registry
    function test_ExecuteMarketDeployment_DeploysRealMarketAndStoresMappings() external {
        _register();
        bytes memory p = _encodedParams(keccak256("snUSD-market-A"));

        // Single completion event: topics carry (template, deployer); the result payload is checked below via the
        // returned struct + the market registry.
        vm.expectEmit(true, true, false, false, address(factory));
        emit MarketDeploymentCompleted(address(template), DEPLOYER, _emptyResult());

        vm.prank(DEPLOYER);
        IRoycoProtocolTemplate.DeploymentResult memory r = factory.executeMarketDeployment(address(template), p);

        // The real template produced live contracts.
        assertGt(r.seniorTranche.code.length, 0, "senior live");
        assertGt(r.juniorTranche.code.length, 0, "junior live");
        assertGt(r.liquidityTranche.code.length, 0, "liquidity live");
        assertGt(r.kernel.code.length, 0, "kernel live");
        assertGt(r.accountant.code.length, 0, "accountant live");
        assertTrue(r.ydm != address(0) && r.ltYdm != address(0) && r.ydm != r.ltYdm, "distinct YDM + LDM");

        // The registry resolves the WHOLE market from ANY of the three tranches.
        _assertGetMarketResolves(r, r.seniorTranche, "via senior");
        _assertGetMarketResolves(r, r.juniorTranche, "via junior");
        _assertGetMarketResolves(r, r.liquidityTranche, "via liquidity");
        assertEq(factory.trancheToKernel(r.seniorTranche), r.kernel, "st->kernel");
        assertEq(factory.trancheToKernel(r.juniorTranche), r.kernel, "jt->kernel");
        assertEq(factory.trancheToKernel(r.liquidityTranche), r.kernel, "lt->kernel");
    }

    /// The transient active-template binding clears after a deployment, so sequential deploys work and registries stay per-market
    function test_ExecuteMarketDeployment_ClearsActiveTemplate_AllowsSequentialDeploys() external {
        _register();

        IRoycoProtocolTemplate.DeploymentResult memory a = _deploy(keccak256("seq-A"));
        // A second deployment succeeding proves the transient active-template binding was cleared.
        IRoycoProtocolTemplate.DeploymentResult memory b = _deploy(keccak256("seq-B"));

        assertTrue(a.kernel != b.kernel, "distinct markets");
        // Each market's tranches resolve only to their own market — no cross-market bleed in the registry.
        _assertGetMarketResolves(a, a.seniorTranche, "market A via senior");
        _assertGetMarketResolves(b, b.seniorTranche, "market B via senior");
        assertTrue(factory.trancheToKernel(a.seniorTranche) != factory.trancheToKernel(b.seniorTranche), "registries distinct");
    }

    /// Balancer requires pool tokens registered in ascending address order, so the senior leg's position depends
    /// on how the CREATE3 ST proxy address sorts against the quote asset. Both orderings must land the WITH_RATE +
    /// kernel-rate-provider config on the SENIOR leg (and STANDARD/no-provider on the quote leg) — a sort-dependent
    /// mis-assignment would price the pool off the wrong token. MarketIds are searched by predicting the ST proxy
    /// address (no deployment) until each ordering has a witness, then one market per ordering is actually deployed.
    function test_ExecuteMarketDeployment_PoolTokenSort_BothOrderings_SeniorLegAlwaysWithRate() external {
        _register();
        address quoteAsset =
            deployScript.buildDayParams(deployScript.getMarketConfig("snUSD"), bytes32(0), PROTOCOL_FEE_RECIPIENT, address(0)).gyroECLPPoolParams.quoteAsset;

        // Search deterministic marketIds for one ST-proxy prediction on each side of the quote asset. Each try is a
        // fair ~50/50 coin flip on the hashed address, so 64 tries bounds the miss probability at 2^-63 per side.
        bytes32 seniorFirstId;
        bytes32 seniorSecondId;
        for (uint256 i; seniorFirstId == bytes32(0) || seniorSecondId == bytes32(0); ++i) {
            require(i < 64, "no witness for both token orderings within 64 marketIds");
            bytes32 id = keccak256(abi.encodePacked("POOL_TOKEN_SORT_", i));
            address predictedST = factory.predictDeterministicAddress(keccak256(abi.encodePacked("ROYCO_MARKET_", id, TAG_ST_PROXY)));
            if (uint160(predictedST) < uint160(quoteAsset)) {
                if (seniorFirstId == bytes32(0)) seniorFirstId = id;
            } else if (seniorSecondId == bytes32(0)) {
                seniorSecondId = id;
            }
        }

        _assertSeniorLegWithRate(_deploy(seniorFirstId), quoteAsset, 0, "senior sorts below quote");
        _assertSeniorLegWithRate(_deploy(seniorSecondId), quoteAsset, 1, "senior sorts above quote");
    }

    /// @dev Asserts the deployed market's pool has the senior tranche at `_expectedSeniorIndex` configured WITH_RATE
    ///      and rate-provided by the kernel, and the quote leg STANDARD with no rate provider.
    function _assertSeniorLegWithRate(
        IRoycoProtocolTemplate.DeploymentResult memory _r,
        address _quoteAsset,
        uint256 _expectedSeniorIndex,
        string memory _ctx
    )
        internal
        view
    {
        address pool = IRoycoDayKernel(_r.kernel).LT_ASSET();
        IVault vault = IVault(address(GyroECLPPoolFactory(GYRO_ECLP_POOL_FACTORY).getVault()));
        (IERC20[] memory tokens, TokenInfo[] memory info,,) = vault.getPoolTokenInfo(pool);

        assertEq(tokens.length, 2, string.concat(_ctx, ": pool token count"));
        assertEq(address(tokens[_expectedSeniorIndex]), _r.seniorTranche, string.concat(_ctx, ": senior leg position"));
        assertEq(address(tokens[1 - _expectedSeniorIndex]), _quoteAsset, string.concat(_ctx, ": quote leg position"));

        assertTrue(info[_expectedSeniorIndex].tokenType == TokenType.WITH_RATE, string.concat(_ctx, ": senior leg not WITH_RATE"));
        assertEq(address(info[_expectedSeniorIndex].rateProvider), _r.kernel, string.concat(_ctx, ": senior rate provider != kernel"));
        assertTrue(info[1 - _expectedSeniorIndex].tokenType == TokenType.STANDARD, string.concat(_ctx, ": quote leg not STANDARD"));
        assertEq(address(info[1 - _expectedSeniorIndex].rateProvider), address(0), string.concat(_ctx, ": quote leg has a rate provider"));
    }

    /// @dev Asserts `getMarket(key)` returns exactly the deployed market's full component set.
    function _assertGetMarketResolves(IRoycoProtocolTemplate.DeploymentResult memory _r, address _key, string memory _ctx) internal view {
        (address st, address jt, address lt, address kernel) = factory.getMarket(_key);
        assertEq(st, _r.seniorTranche, string.concat(_ctx, ": senior"));
        assertEq(jt, _r.juniorTranche, string.concat(_ctx, ": junior"));
        assertEq(lt, _r.liquidityTranche, string.concat(_ctx, ": liquidity"));
        assertEq(kernel, _r.kernel, string.concat(_ctx, ": kernel"));
    }

    /// Only DEPLOYER_ROLE may execute a market deployment
    function test_RevertIf_NonDeployerExecutesMarketDeployment() external {
        _register();
        bytes memory p = _encodedParams(keccak256("nd"));
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, STRANGER));
        factory.executeMarketDeployment(address(template), p);
    }

    /// A never-registered template cannot deploy markets
    function test_RevertIf_DeployingThroughUnregisteredTemplate() external {
        // Never registered.
        bytes memory p = _encodedParams(keccak256("ne"));
        vm.prank(DEPLOYER);
        vm.expectRevert(IRoycoFactory.TEMPLATE_NOT_ENABLED.selector);
        factory.executeMarketDeployment(address(template), p);
    }

    /// Deployment is blocked while the factory is paused
    function test_RevertIf_MarketDeploymentExecutedWhilePaused() external {
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

    /// Every template-callable primitive rejects a direct call when no deployment is in progress
    function test_RevertIf_TemplatePrimitivesCalledOutsideDeploymentWindow() external {
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

    /// Unknown tranches resolve to the zero market: the registry never fabricates a mapping
    function test_GetMarket_ZeroForUnknownTranche() external {
        assertEq(factory.trancheToKernel(makeAddr("UNKNOWN")), address(0), "unknown tranche->kernel");
        (address st, address jt, address lt, address kernel) = factory.getMarket(makeAddr("UNKNOWN"));
        assertEq(st, address(0), "unknown senior");
        assertEq(jt, address(0), "unknown junior");
        assertEq(lt, address(0), "unknown liquidity");
        assertEq(kernel, address(0), "unknown kernel");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ROLE-ESCALATION ATTEMPTS (adversarial)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice A deployer key cannot reach the factory-admin surface: holding DEPLOYER_ROLE grants deployment
    ///         only, so a compromised deployer cannot register or disable templates to redirect future markets
    function test_RevertIf_DeployerCallsFactoryAdminSurface() external {
        _register();
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, DEPLOYER));
        factory.registerTemplate(address(template));
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, DEPLOYER));
        factory.disableTemplate(address(template));
    }

    /// @notice The factory admin cannot deploy markets: ADMIN_FACTORY_ROLE curates templates but only
    ///         DEPLOYER_ROLE may execute a deployment, so the two powers stay separated in both directions
    function test_RevertIf_FactoryAdminExecutesMarketDeployment() external {
        _register();
        bytes memory p = _encodedParams(keccak256("admin-deploy"));
        vm.prank(FACTORY_ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, FACTORY_ADMIN));
        factory.executeMarketDeployment(address(template), p);
    }

    /**
     * @notice Even legitimate role holders cannot use the template-callable role primitives outside a deployment
     *         window: a deployer trying to grant itself a market role, or bind a selector to a role it controls,
     *         is rejected because no template is active
     * @dev This is the factory's privilege-escalation chokepoint: grantMarketRole and
     *      setMarketTargetFunctionRole wield the factory's ADMIN_ROLE on the AccessManager, so they must be
     *      callable only from inside executeMarketDeployment's transient template binding
     */
    function test_RevertIf_RoleHolderCallsTemplatePrimitivesOutsideDeploymentWindow() external {
        _register();
        vm.startPrank(DEPLOYER);
        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.grantMarketRole(ADMIN_FACTORY_ROLE, DEPLOYER, 0);
        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.setMarketTargetFunctionRole(address(factory), IRoycoFactory.registerTemplate.selector, DEPLOYER_ROLE);
        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.executeAsFactory(address(am), abi.encodeCall(AccessManager.grantRole, (ADMIN_ROLE, DEPLOYER, 0)));
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // UPGRADE GATE
    // ═══════════════════════════════════════════════════════════════════════════

    /// Only ADMIN_UPGRADER_ROLE may upgrade the factory proxy
    function test_RevertIf_NonUpgraderUpgradesFactory() external {
        address newImpl = address(new RoycoFactory());
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, STRANGER));
        factory.upgradeToAndCall(newImpl, "");
    }

    /// The upgrader role can upgrade and the authority survives the implementation swap
    function test_UpgradeToAndCall_SucceedsForUpgrader() external {
        address newImpl = address(new RoycoFactory());
        vm.prank(UPGRADER);
        factory.upgradeToAndCall(newImpl, "");
        assertEq(factory.authority(), address(am), "authority preserved");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET-ID COLLISION + YDM-TYPE WIRING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Re-running a deployment with a marketId that already produced a market reverts on the first colliding
    ///         CREATE3 salt (the senior tranche implementation) and unwinds the whole transaction atomically, so a
    ///         same-names/same-block marketId collision can never half-build a second market or leave a live market
    ///         wired to a YDM reused earlier in the same transaction. Blast radius is a clean revert, never aliasing
    function test_RevertIf_MarketRedeployedWithSameMarketId() external {
        _register();
        bytes32 marketId = keccak256("dup-id");
        IRoycoProtocolTemplate.DeploymentResult memory first = _deploy(marketId);
        assertGt(first.kernel.code.length, 0, "first market is live");

        // The deterministic component addresses are a pure function of the marketId, so a second run with the same id
        // cannot get past the very first CREATE3 deploy. Match on the selector only: the exact (address, salt) payload
        // is an internal detail, but the specific already-deployed error must be the one that fires.
        bytes memory p = _encodedParams(marketId);
        vm.prank(DEPLOYER);
        vm.expectPartialRevert(BaseDeploymentTemplate.MARKET_COMPONENT_ALREADY_DEPLOYED.selector);
        factory.executeMarketDeployment(address(template), p);

        // Atomicity: the failed redeploy left the first market's registry entry exactly as it was.
        _assertGetMarketResolves(first, first.seniorTranche, "first market intact after failed redeploy");
    }

    /// @notice A StaticCurve YDM config deploys an actual StaticCurveYDM model for both the JT YDM and the LT LDM
    /// @dev The template registers every YDM model's bytecode and selects the configured type by component id, so the
    ///      deployed contract matches the config even though StaticCurveYDM.initializeYDMForMarket(uint64,uint64,uint64)
    ///      shares its 4-byte selector with the V2 initializer. The reused snUSD params (0.11e18, 0.11e18, 0.31e18) are
    ///      ABI-identical to StaticCurveYDMParams, so the static init calldata decodes and binds on the StaticCurve model
    function test_StaticCurveYdmConfig_DeploysStaticCurveModel() external {
        _register();

        MarketDeploymentConfig.MarketConfig memory cfg = deployScript.getMarketConfig("snUSD");
        cfg.ydmType = DeployScript.YDMType.StaticCurve;
        bytes memory p = abi.encode(deployScript.buildDayParams(cfg, keccak256("static-config-deploys-static"), PROTOCOL_FEE_RECIPIENT, address(0)));

        vm.prank(DEPLOYER);
        IRoycoProtocolTemplate.DeploymentResult memory r = factory.executeMarketDeployment(address(template), p);

        // The deployed model is the configured StaticCurveYDM. The YDMs embed their target utilization as an immutable,
        // so runtime code is target-dependent — compare against reference instances built with the SAME targets the
        // config carries, which isolates the model type as the only difference that matters.
        StaticCurveYDM refJtStatic = new StaticCurveYDM(cfg.jtYdmTargetUtilizationWAD);
        StaticCurveYDM refLtStatic = new StaticCurveYDM(cfg.ltYdmTargetUtilizationWAD);
        AdaptiveCurveYDM_V2 refV2 = new AdaptiveCurveYDM_V2(cfg.jtYdmTargetUtilizationWAD);
        assertEq(r.ydm.codehash, address(refJtStatic).codehash, "configured StaticCurve, ydm must be StaticCurveYDM");
        assertEq(r.ltYdm.codehash, address(refLtStatic).codehash, "configured StaticCurve, ltYdm must be StaticCurveYDM");
        // And it is NOT the adaptive model that used to stand in for it under a static config.
        assertTrue(r.ydm.codehash != address(refV2).codehash, "ydm must not be the adaptive V2 code");
    }

    /// @notice An AdaptiveCurve_V1 YDM config deploys an actual AdaptiveCurveYDM_V1 model for both the JT YDM and the LT LDM
    /// @dev With every YDM model's bytecode registered and selected by component id, a V1 config deploys the V1 contract
    ///      and its two-argument initializeYDMForMarket(uint64,uint64) binds on it, so the deployment succeeds rather than
    ///      reverting against a stand-in V2 instance whose selector the V1 calldata could not match
    function test_AdaptiveV1YdmConfig_DeploysAdaptiveV1Model() external {
        _register();

        MarketDeploymentConfig.MarketConfig memory cfg = deployScript.getMarketConfig("snUSD");
        cfg.ydmType = DeployScript.YDMType.AdaptiveCurve_V1;
        // V1 takes only (target, full), so re-encode both curves as V1 params — a two-word init blob that binds on the V1 model
        bytes memory v1Params = abi.encode(DeployScript.AdaptiveCurveYDM_V1_Params({ yieldShareAtTargetUtilWAD: 0.11e18, yieldShareAtFullUtilWAD: 0.31e18 }));
        cfg.ydmSpecificParams = v1Params;
        cfg.ltYdmSpecificParams = v1Params;
        bytes memory p = abi.encode(deployScript.buildDayParams(cfg, keccak256("v1-config-deploys-v1"), PROTOCOL_FEE_RECIPIENT, address(0)));

        vm.prank(DEPLOYER);
        IRoycoProtocolTemplate.DeploymentResult memory r = factory.executeMarketDeployment(address(template), p);

        // The deployed model is the configured AdaptiveCurveYDM_V1, compared against references built with the same targets
        AdaptiveCurveYDM_V1 refJtV1 = new AdaptiveCurveYDM_V1(cfg.jtYdmTargetUtilizationWAD);
        AdaptiveCurveYDM_V1 refLtV1 = new AdaptiveCurveYDM_V1(cfg.ltYdmTargetUtilizationWAD);
        assertEq(r.ydm.codehash, address(refJtV1).codehash, "configured AdaptiveCurve_V1, ydm must be AdaptiveCurveYDM_V1");
        assertEq(r.ltYdm.codehash, address(refLtV1).codehash, "configured AdaptiveCurve_V1, ltYdm must be AdaptiveCurveYDM_V1");
    }

    // ─── internal ───

    function _emptyResult() internal pure returns (IRoycoProtocolTemplate.DeploymentResult memory r) {
        r; // zero-initialized; only used for event topic matching (data not checked)
    }
}
