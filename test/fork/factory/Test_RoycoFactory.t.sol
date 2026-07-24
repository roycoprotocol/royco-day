// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

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
import { RoycoMarketSyncer } from "../../../lib/royco-periphery/src/syncer/RoycoMarketSyncer.sol";
import { DeployScript } from "../../../script/Deploy.s.sol";
import {
    AdaptiveCurveYDM_V1_Params,
    DeploymentResult,
    ERC4626SharePriceOracleParams,
    MarketConfig,
    StaticCurveYDMParams,
    YDMType
} from "../../../script/config/DeploymentTypes.sol";
import { RoycoDayEntryPoint } from "../../../src/entrypoint/RoycoDayEntryPoint.sol";
import {
    ADMIN_ENTRY_POINT_ROLE,
    ADMIN_FACTORY_ROLE,
    ADMIN_PAUSER_ROLE,
    ADMIN_ROLE,
    ADMIN_UNPAUSER_ROLE,
    ADMIN_UPGRADER_ROLE,
    DEPLOYER_ROLE,
    SYNC_ROLE
} from "../../../src/factory/Roles.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";
import { TAG_JT_PROXY } from "../../../src/factory/templates/base/Constants.sol";
import {
    RoycoDayBalancerV3MarketDeploymentTemplate
} from "../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { EntryPointConfigurer } from "../../../src/factory/templates/periphery/EntryPointConfigurer.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { IBaseTemplate } from "../../../src/interfaces/factory/IBaseTemplate.sol";
import { IRoycoFactory } from "../../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { ERC4626SharePriceOracle } from "../../../src/oracle/ERC4626SharePriceOracle.sol";
import { AdaptiveCurveYDM_V1 } from "../../../src/ydm/AdaptiveCurveYDM_V1.sol";
import { AdaptiveCurveYDM_V2 } from "../../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { StaticCurveYDM } from "../../../src/ydm/StaticCurveYDM.sol";

/// @title Test_RoycoFactory
/// @notice Fork tests for `RoycoFactory` driven by the REAL Day market template
///         (`RoycoDayBalancerV3MarketDeploymentTemplate`) — no mock. Covers: initialization + role wiring,
///         template registration/disabling, the deployment entrypoint standing up a real snUSD market (tranche
///         mappings + events + live contracts), auth/pause gating, the active-template-gated primitives rejecting
///         outside a deployment window, getters, and the UUPS upgrade gate.
/// @dev Requires a mainnet fork (real Balancer V3 + Gyro E-CLP + snUSD vault). FAILS (env not found) when
///      `MAINNET_RPC_URL` is unset, instead of silently passing.
contract Test_RoycoFactory is Test {
    uint256 internal constant FORK_BLOCK = 25_400_000;
    address internal constant GYRO_ECLP_POOL_FACTORY = 0x04d584195a96DFfc7F8B695aA3C9D3c1606b69d1;

    AccessManager internal am;
    RoycoFactory internal factory;
    DeployScript internal deployScript;
    RoycoDayBalancerV3MarketDeploymentTemplate internal template;
    IRoycoDayEntryPoint internal entryPoint;
    RoycoMarketSyncer internal syncer;

    address internal FACTORY_ADMIN = makeAddr("FACTORY_ADMIN");
    address internal DEPLOYER = makeAddr("DEPLOYER");
    address internal UPGRADER = makeAddr("UPGRADER");
    address internal STRANGER = makeAddr("STRANGER");
    address internal PROTOCOL_FEE_RECIPIENT = makeAddr("PROTOCOL_FEE_RECIPIENT");

    bytes32 internal constant MARKET_ID_A = 0x81c1e5d2e327b2f16a45a4a7b25319edbfa61389ebe2f2d04e269fe48b4ebc7f;
    bytes32 internal constant MARKET_ID_B = 0x6a95a11c1a51be634f7c4739c9b6a47fbf54cbc9d972a7ed0d6926819f8e7a81;
    bytes32 internal constant MARKET_ID_C = 0xf3f7f56087460b0de51563f17f2237a68f7a4526e5719d074824316d23bc2815;

    // Mirrors of the factory's events, for `vm.expectEmit`.
    event TemplateRegistered(address indexed template);
    event TemplateDisabled(address indexed template);
    event MarketDeploymentCompleted(address indexed template, address indexed deployer, IRoycoProtocolTemplate.DeploymentResult result);

    function setUp() public {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(rpc, FORK_BLOCK);

        // This test contract is the AccessManager admin (ADMIN_ROLE).
        am = new AccessManager(address(this));

        // OZ mandates init data in the ERC1967Proxy constructor, and `initialize` requires the factory to already
        // hold ADMIN_ROLE on the AM. So deploy the proxy via CREATE2: predict the salted address, grant it
        // ADMIN_ROLE, then construct the proxy with real init data. A salt-based prediction is nonce-independent (a
        // CREATE-nonce prediction drifts after createSelectFork on current foundry), which keeps `factory` — and the
        // pre-mined MARKET_ID_* below, keyed to it — stable.
        RoycoFactory impl = new RoycoFactory();
        bytes memory factoryInitData = abi.encodeCall(RoycoFactory.initialize, (address(am)));
        bytes32 proxySalt = keccak256("FACTORY_PROXY");
        address predicted = vm.computeCreate2Address(
            proxySalt, keccak256(abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(address(impl), factoryInitData))), address(this)
        );
        am.grantRole(ADMIN_ROLE, predicted, 0);
        factory = RoycoFactory(address(new ERC1967Proxy{ salt: proxySalt }(address(impl), factoryInitData)));
        require(address(factory) == predicted, "proxy address prediction failed");

        // Grant the factory-facing roles the initialize() call bound to selectors.
        am.grantRole(ADMIN_FACTORY_ROLE, FACTORY_ADMIN, 0);
        am.grantRole(DEPLOYER_ROLE, DEPLOYER, 0);
        am.grantRole(ADMIN_UPGRADER_ROLE, UPGRADER, 0);
        // initialize() binds the factory's pause/unpause to the pauser/unpauser roles, so this test contract (the AM
        // admin) needs them to pause/unpause the factory directly.
        am.grantRole(ADMIN_PAUSER_ROLE, address(this), 0);
        am.grantRole(ADMIN_UNPAUSER_ROLE, address(this), 0);

        // The REAL periphery singletons the template configures per market: the entry point (initialized empty,
        // configs flow through the factory) and the market syncer (initialized with no kernels).
        RoycoDayEntryPoint entryPointImpl = new RoycoDayEntryPoint(address(factory));
        entryPoint = IRoycoDayEntryPoint(
            address(
                new ERC1967Proxy(
                    address(entryPointImpl), abi.encodeCall(RoycoDayEntryPoint.initialize, (new address[](0), new IRoycoDayEntryPoint.TrancheConfig[](0)))
                )
            )
        );
        RoycoMarketSyncer syncerImpl = new RoycoMarketSyncer();
        syncer =
            RoycoMarketSyncer(address(new ERC1967Proxy(address(syncerImpl), abi.encodeCall(RoycoMarketSyncer.initialize, (address(am), new address[](0))))));

        // Bind the config selectors the factory drives during deployments (the factory self-granted
        // ADMIN_ENTRY_POINT_ROLE + SYNC_ROLE in its initialize).
        bytes4[] memory entryPointSelectors = new bytes4[](1);
        entryPointSelectors[0] = IRoycoDayEntryPoint.modifyTrancheConfigs.selector;
        am.setTargetFunctionRole(address(entryPoint), entryPointSelectors, ADMIN_ENTRY_POINT_ROLE);
        bytes4[] memory syncerSelectors = new bytes4[](1);
        syncerSelectors[0] = RoycoMarketSyncer.addMarketKernels.selector;
        am.setTargetFunctionRole(address(syncer), syncerSelectors, SYNC_ROLE);

        // The real Day template, bound to this factory. `deployScript` externally deploys each market's impls/YDMs/pool
        // and pre-deploys its ST + hook proxies (`deployMarketContractsForTest`), then builds the template params
        // (`buildMarketParams`) — the factory + template above are the units under test. Its nested `deployDeterministicProxy` calls run
        // with `msg.sender == address(deployScript)`, so the deployScript must hold DEPLOYER_ROLE.
        deployScript = new DeployScript();
        am.grantRole(DEPLOYER_ROLE, address(deployScript), 0);
        template = new RoycoDayBalancerV3MarketDeploymentTemplate(
            IRoycoFactory(address(factory)), GyroECLPPoolFactory(GYRO_ECLP_POOL_FACTORY), address(entryPoint), address(syncer)
        );
    }

    // ─── helpers ───

    function _register() internal {
        vm.prank(FACTORY_ADMIN);
        factory.registerTemplate(address(template));
    }

    /// @dev Externally deploys the snUSD market's impls/YDMs/pool and pre-deploys its ST + hook proxies (as the
    ///      deployScript, which holds DEPLOYER_ROLE), then builds the encoded template params from the SAME config.
    ///      `_marketId` must place the senior tranche as pool token0 for this suite's `factory` (see MARKET_ID_A/B).
    function _encodedParams(bytes32 _marketId) internal returns (bytes memory) {
        MarketConfig memory cfg = deployScript.getMarketConfig("snUSD");
        _resolveCollateralOracle(cfg);
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketContracts memory mc =
            deployScript.deployMarketContractsForTest(cfg, _marketId, factory, address(template), address(am));
        return abi.encode(deployScript.buildMarketParams(cfg, _marketId, PROTOCOL_FEE_RECIPIENT, address(0), mc));
    }

    /// @dev The `deploy()` flow resolves an unset config oracle itself; the direct-template path must supply it, so
    ///      deploy the config's ERC4626 share-price adapter over the market's collateral vault + base->NAV feed.
    function _resolveCollateralOracle(MarketConfig memory _cfg) internal {
        if (_cfg.collateralAssetOracle != address(0)) return;
        _cfg.collateralAssetOracle = address(
            new ERC4626SharePriceOracle(
                _cfg.collateralAsset, abi.decode(_cfg.collateralAssetOracleSpecificParams, (ERC4626SharePriceOracleParams)).baseAssetToNavAssetFeed
            )
        );
    }

    function _deploy(bytes32 _marketId) internal returns (IRoycoProtocolTemplate.DeploymentResult memory) {
        // Precompute the params first: `_encodedParams` externally deploys the market contracts as `deployScript`,
        // which would otherwise consume the `vm.prank(DEPLOYER)` intended for `executeMarketDeployment`.
        bytes memory p = _encodedParams(_marketId);
        vm.prank(DEPLOYER);
        return factory.executeMarketDeployment(address(template), p);
    }

    /// The single wiring transaction must fit under EIP-7825's per-transaction gas cap (the reason the deployment
    /// was split: implementations/pool/YDMs are deployed in separate transactions, leaving only wiring + verification here)
    function test_ExecuteMarketDeployment_WiringTxUnderGasCap() external {
        _register();
        bytes memory p = _encodedParams(MARKET_ID_A);
        vm.prank(DEPLOYER);
        uint256 gasBefore = gasleft();
        factory.executeMarketDeployment(address(template), p);
        uint256 gasUsed = gasBefore - gasleft();
        // EIP-7825 caps every transaction at 2^24 = 16,777,216 gas
        assertLt(gasUsed, 16_777_216, "wiring tx exceeds EIP-7825 per-tx gas cap");
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

    /// Registering a template enables it and emits TemplateRegistered
    function test_RegisterTemplate_EnablesTemplateWithEvent() external {
        assertFalse(factory.isTemplateEnabled(address(template)), "not enabled pre");

        // Registration no longer initializes any component bytecode store — the market's implementations are deployed
        // externally by the deployer — so the factory simply enables the template and emits its event.
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
        // A real template bound to a different factory address must be rejected. The template validates its entry
        // point's factory binding at construction, so the foreign template needs an entry point bound to the foreign
        // factory: a bare (uninitialized) implementation suffices since ROYCO_FACTORY is a constructor immutable.
        address otherFactory = makeAddr("OTHER_FACTORY");
        RoycoDayEntryPoint foreignEntryPoint = new RoycoDayEntryPoint(otherFactory);
        RoycoDayBalancerV3MarketDeploymentTemplate foreign = new RoycoDayBalancerV3MarketDeploymentTemplate(
            IRoycoFactory(otherFactory), GyroECLPPoolFactory(GYRO_ECLP_POOL_FACTORY), address(foreignEntryPoint), address(syncer)
        );
        vm.prank(FACTORY_ADMIN);
        vm.expectRevert(IRoycoFactory.TEMPLATE_BOUND_TO_DIFFERENT_FACTORY.selector);
        factory.registerTemplate(address(foreign));
    }

    /// A template constructed with an entry point bound to a different factory is rejected at construction
    function test_RevertIf_TemplateConstructedWithMisboundEntryPoint() external {
        RoycoDayEntryPoint foreignEntryPoint = new RoycoDayEntryPoint(makeAddr("OTHER_FACTORY"));
        vm.expectRevert(EntryPointConfigurer.ENTRY_POINT_BOUND_TO_DIFFERENT_FACTORY.selector);
        new RoycoDayBalancerV3MarketDeploymentTemplate(
            IRoycoFactory(address(factory)), GyroECLPPoolFactory(GYRO_ECLP_POOL_FACTORY), address(foreignEntryPoint), address(syncer)
        );
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

        bytes memory p = _encodedParams(MARKET_ID_A);
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
        bytes memory p = _encodedParams(MARKET_ID_A);

        // Single completion event: topics carry (template, deployer); the result payload is checked below via the
        // returned struct + the market registry.
        vm.expectEmit(true, true, false, false, address(factory));
        emit MarketDeploymentCompleted(address(template), DEPLOYER, _emptyResult());

        vm.prank(DEPLOYER);
        IRoycoProtocolTemplate.DeploymentResult memory r = factory.executeMarketDeployment(address(template), p);

        // The real template produced live contracts.
        assertGt(r.seniorTranche.code.length, 0, "senior live");
        assertGt(r.juniorTranche.code.length, 0, "junior live");
        assertGt(r.liquidityProviderTranche.code.length, 0, "liquidity live");
        assertGt(r.kernel.code.length, 0, "kernel live");
        assertGt(r.accountant.code.length, 0, "accountant live");
        assertTrue(r.ydm != address(0) && r.lptYdm != address(0) && r.ydm != r.lptYdm, "distinct YDM + LDM");

        // The registry resolves the WHOLE market from ANY of the three tranches.
        _assertGetMarketResolves(r, r.seniorTranche, "via senior");
        _assertGetMarketResolves(r, r.juniorTranche, "via junior");
        _assertGetMarketResolves(r, r.liquidityProviderTranche, "via liquidity");
        assertEq(factory.trancheToKernel(r.seniorTranche), r.kernel, "st->kernel");
        assertEq(factory.trancheToKernel(r.juniorTranche), r.kernel, "jt->kernel");
        assertEq(factory.trancheToKernel(r.liquidityProviderTranche), r.kernel, "lt->kernel");

        // The template configured the entry point for all three tranches through the factory (post-registration hook).
        MarketConfig memory cfg = deployScript.getMarketConfig("snUSD");
        _assertEntryPointConfigured(r.seniorTranche, r.kernel, cfg.stEntryPointConfig, "st entry point config");
        _assertEntryPointConfigured(r.juniorTranche, r.kernel, cfg.jtEntryPointConfig, "jt entry point config");
        _assertEntryPointConfigured(r.liquidityProviderTranche, r.kernel, cfg.lptEntryPointConfig, "lt entry point config");

        // The template registered the market's kernel on the syncer through the factory.
        assertTrue(syncer.isMarketKernelRegistered(r.kernel), "kernel registered on the syncer");
    }

    /// @dev Asserts the entry point stored the expected config for a tranche, enriched with the market's kernel.
    function _assertEntryPointConfigured(
        address _tranche,
        address _kernel,
        IRoycoDayEntryPoint.TrancheConfig memory _expected,
        string memory _ctx
    )
        internal
        view
    {
        IRoycoDayEntryPoint.EnrichedTrancheConfig memory stored = entryPoint.getTrancheConfig(_tranche);
        assertEq(stored.kernel, _kernel, string.concat(_ctx, ": kernel"));
        assertEq(stored.baseConfig.enabled, _expected.enabled, string.concat(_ctx, ": enabled"));
        assertEq(stored.baseConfig.depositDelaySeconds, _expected.depositDelaySeconds, string.concat(_ctx, ": deposit delay"));
        assertEq(stored.baseConfig.redemptionDelaySeconds, _expected.redemptionDelaySeconds, string.concat(_ctx, ": redemption delay"));
        assertEq(stored.baseConfig.gateByOracleUpdate, _expected.gateByOracleUpdate, string.concat(_ctx, ": oracle enabled"));
    }

    /// @notice A revoked SYNC_ROLE makes the syncer registration leg of the periphery hook fail, and the whole
    ///         deployment unwinds atomically: no market contracts, no registry entries, no entry point configs
    function test_RevertIf_FactoryLacksSyncRole_DeploymentUnwindsAtomically() external {
        _register();
        am.revokeRole(SYNC_ROLE, address(factory));

        bytes memory p = _encodedParams(MARKET_ID_A);
        // The senior tranche + hook proxies are pre-deployed outside the wiring transaction, so the atomic-unwind
        // check targets the junior tranche proxy, which the template deploys INSIDE `executeMarketDeployment`.
        address predictedJT = factory.predictDeterministicAddress(keccak256(abi.encodePacked("ROYCO_MARKET_", MARKET_ID_A, TAG_JT_PROXY)));
        vm.prank(DEPLOYER);
        vm.expectPartialRevert(IRoycoFactory.FACTORY_CALL_FAILED.selector);
        factory.executeMarketDeployment(address(template), p);

        // Atomic unwind: the wiring transaction's contracts and registry entries are gone.
        assertEq(predictedJT.code.length, 0, "no junior tranche deployed");
        assertEq(factory.trancheToKernel(predictedJT), address(0), "no registry entry");
    }

    /// @notice Only the factory may drive the periphery configuration hook
    function test_RevertIf_StrangerCallspostMarketRegistration() external {
        _register();
        IRoycoProtocolTemplate.DeploymentResult memory r = _deploy(MARKET_ID_A);

        // The `onlyRoycoFactory` gate reverts before the params blob is even decoded, so empty params suffice (and
        // avoid re-deploying the same-marketId contracts, which would collide on the pre-deployed senior proxy).
        vm.prank(STRANGER);
        vm.expectRevert(IBaseTemplate.ONLY_ROYCO_FACTORY.selector);
        template.postMarketRegistration(r, "");
    }

    /// The transient active-template binding clears after a deployment, so sequential deploys work and registries stay per-market
    function test_ExecuteMarketDeployment_ClearsActiveTemplate_AllowsSequentialDeploys() external {
        _register();

        IRoycoProtocolTemplate.DeploymentResult memory a = _deploy(MARKET_ID_A);
        // A second deployment succeeding proves the transient active-template binding was cleared.
        IRoycoProtocolTemplate.DeploymentResult memory b = _deploy(MARKET_ID_B);

        assertTrue(a.kernel != b.kernel, "distinct markets");
        // Each market's tranches resolve only to their own market — no cross-market bleed in the registry.
        _assertGetMarketResolves(a, a.seniorTranche, "market A via senior");
        _assertGetMarketResolves(b, b.seniorTranche, "market B via senior");
        assertTrue(factory.trancheToKernel(a.seniorTranche) != factory.trancheToKernel(b.seniorTranche), "registries distinct");
    }

    /**
     * @notice The YDM salt is market-agnostic: two markets deployed with the same (role, model) pair share ONE JT
     *         YDM instance and ONE LPT LDM instance, while each market's JT-vs-LPT pair stays distinct (the role tag
     *         is part of the salt), and each market's accountant initializes its own curve on the shared instance.
     *         A market configured with a DIFFERENT model resolves to a different instance (the component id is part
     *         of the salt), so sharing never crosses model boundaries
     */
    function test_ExecuteMarketDeployment_SharesYdmInstancesAcrossMarkets() external {
        _register();

        IRoycoProtocolTemplate.DeploymentResult memory a = _deploy(MARKET_ID_A);
        IRoycoProtocolTemplate.DeploymentResult memory b = _deploy(MARKET_ID_B);
        assertTrue(a.kernel != b.kernel, "distinct markets");

        // Both markets share one JT YDM and one LPT LDM singleton (market-agnostic salts) ...
        assertEq(a.ydm, b.ydm, "the JT YDM instance must be shared across markets");
        assertEq(a.lptYdm, b.lptYdm, "the LPT LDM instance must be shared across markets");
        // ... while each market's JT YDM and LPT LDM remain distinct instances (the role tag stays in the salt)
        assertTrue(a.ydm != a.lptYdm, "the JT YDM and LPT LDM must remain distinct instances within a market");

        // Each market's accountant initialized its OWN curve on the shared instance (state keyed per accountant):
        // the snUSD config's V2 curve (0.11e18 at zero, 0.11e18 at target, 0.31e18 at full) decomposes to
        // yieldShareAtTarget = 0.11e18, discount-at-zero = 0, premium-at-full = 0.2e18 for both accountants
        assertTrue(a.accountant != b.accountant, "distinct accountants");
        _assertV2CurveInitialized(a.ydm, a.accountant, "market A on the shared JT YDM");
        _assertV2CurveInitialized(a.ydm, b.accountant, "market B on the shared JT YDM");

        // A different-model market resolves to different instances: the YDM model is part of the deployed contract type
        MarketConfig memory staticCfg = deployScript.getMarketConfig("snUSD");
        _resolveCollateralOracle(staticCfg);
        staticCfg.ydmType = YDMType.StaticCurve;
        bytes32 staticId = MARKET_ID_C;
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketContracts memory staticMc =
            deployScript.deployMarketContractsForTest(staticCfg, staticId, factory, address(template), address(am));
        bytes memory p = abi.encode(deployScript.buildMarketParams(staticCfg, staticId, PROTOCOL_FEE_RECIPIENT, address(0), staticMc));
        vm.prank(DEPLOYER);
        IRoycoProtocolTemplate.DeploymentResult memory s = factory.executeMarketDeployment(address(template), p);
        assertTrue(s.ydm != a.ydm, "a different YDM model must not share the adaptive markets' JT YDM instance");
        assertTrue(s.lptYdm != a.lptYdm, "a different YDM model must not share the adaptive markets' LPT LDM instance");
    }

    /// @dev Asserts the shared V2 YDM instance holds the snUSD config's initialized curve for the given accountant
    function _assertV2CurveInitialized(address _ydm, address _accountant, string memory _ctx) internal view {
        (uint64 yieldShareAtTargetWAD, uint32 lastAdaptationTimestamp, uint64 discountToTargetAtZeroUtilWAD, uint64 premiumToTargetAtFullUtilWAD) =
            AdaptiveCurveYDM_V2(_ydm).accountantToCurve(_accountant);
        assertEq(yieldShareAtTargetWAD, 0.11e18, string.concat(_ctx, ": yield share at target"));
        assertEq(discountToTargetAtZeroUtilWAD, 0, string.concat(_ctx, ": discount at zero util"));
        assertEq(premiumToTargetAtFullUtilWAD, 0.2e18, string.concat(_ctx, ": premium at full util"));
        assertEq(lastAdaptationTimestamp, 0, string.concat(_ctx, ": no adaptation yet"));
    }

    /// Balancer requires pool tokens registered in ascending address order. The marketId is mined so the CREATE3 ST
    /// proxy address always sorts below the quote asset, pinning the senior tranche as token0 — the deployment path
    /// asserts this rather than sorting. The senior leg (token0) must carry the WITH_RATE + kernel-rate-provider config
    /// and the quote leg (token1) STANDARD/no-provider; a mis-assignment would price the pool off the wrong token.
    function test_ExecuteMarketDeployment_SeniorLegIsToken0WithRate() external {
        _register();
        address quoteAsset = deployScript.getMarketConfig("snUSD").gyroECLPPoolParams.quoteAsset;
        _assertSeniorLegWithRate(_deploy(MARKET_ID_A), quoteAsset, 0, "senior is token0");
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
        address pool = IRoycoDayKernel(_r.kernel).LPT_ASSET();
        IVault vault = IVault(address(GyroECLPPoolFactory(GYRO_ECLP_POOL_FACTORY).getVault()));
        (IERC20[] memory tokens, TokenInfo[] memory info,,) = vault.getPoolTokenInfo(pool);

        assertEq(tokens.length, 2, string.concat(_ctx, ": pool token count"));
        assertEq(address(tokens[_expectedSeniorIndex]), _r.seniorTranche, string.concat(_ctx, ": senior leg position"));
        assertEq(address(tokens[1 - _expectedSeniorIndex]), _quoteAsset, string.concat(_ctx, ": quote leg position"));

        assertTrue(info[_expectedSeniorIndex].tokenType == TokenType.WITH_RATE, string.concat(_ctx, ": senior leg not WITH_RATE"));
        assertEq(address(info[_expectedSeniorIndex].rateProvider), _r.kernel, string.concat(_ctx, ": senior rate provider != kernel"));
        assertTrue(info[1 - _expectedSeniorIndex].tokenType == TokenType.STANDARD, string.concat(_ctx, ": quote leg not STANDARD"));
        assertEq(address(info[1 - _expectedSeniorIndex].rateProvider), address(0), string.concat(_ctx, ": quote leg has a rate provider"));
        assertFalse(info[_expectedSeniorIndex].paysYieldFees, string.concat(_ctx, ": senior leg must not pay Balancer yield fees per the config"));
        assertFalse(info[1 - _expectedSeniorIndex].paysYieldFees, string.concat(_ctx, ": quote leg must not pay Balancer yield fees per the config"));
    }

    /// @dev Asserts `getMarket(key)` returns exactly the deployed market's full component set.
    function _assertGetMarketResolves(IRoycoProtocolTemplate.DeploymentResult memory _r, address _key, string memory _ctx) internal view {
        (address st, address jt, address lt, address kernel) = factory.getMarket(_key);
        assertEq(st, _r.seniorTranche, string.concat(_ctx, ": senior"));
        assertEq(jt, _r.juniorTranche, string.concat(_ctx, ": junior"));
        assertEq(lt, _r.liquidityProviderTranche, string.concat(_ctx, ": liquidity"));
        assertEq(kernel, _r.kernel, string.concat(_ctx, ": kernel"));
    }

    /// Only DEPLOYER_ROLE may execute a market deployment
    function test_RevertIf_NonDeployerExecutesMarketDeployment() external {
        _register();
        bytes memory p = _encodedParams(MARKET_ID_A);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, STRANGER));
        factory.executeMarketDeployment(address(template), p);
    }

    /// A never-registered template cannot deploy markets
    function test_RevertIf_DeployingThroughUnregisteredTemplate() external {
        // Never registered.
        bytes memory p = _encodedParams(MARKET_ID_A);
        vm.prank(DEPLOYER);
        vm.expectRevert(IRoycoFactory.TEMPLATE_NOT_ENABLED.selector);
        factory.executeMarketDeployment(address(template), p);
    }

    /// Deployment is blocked while the factory is paused
    function test_RevertIf_MarketDeploymentExecutedWhilePaused() external {
        _register();
        bytes memory p = _encodedParams(MARKET_ID_A);
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
        // Called directly (no deployment in progress): `_activeTemplate == 0`, so every active-template primitive rejects.
        vm.startPrank(STRANGER);

        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.deployDeterministicProxyFromTemplate(address(this), "", keccak256("y"));

        address[] memory addrs = new address[](1);
        addrs[0] = address(this);
        bytes4[] memory selectors = new bytes4[](1);
        uint64[] memory roleIds = new uint64[](1);
        uint32[] memory delays = new uint32[](1);

        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.setMarketTargetFunctionRole(addrs, selectors, roleIds);

        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.grantMarketRole(roleIds, addrs, delays);

        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.executeAsFactory(address(this), "");

        // `deployDeterministicProxy` is NOT active-template gated: it is a standalone deployer primitive bound to DEPLOYER_ROLE, so a
        // caller without that role is rejected by the AccessManager (never with ONLY_ACTIVE_TEMPLATE). The init data is
        // a harmless view call: the hardened ERC1967Proxy rejects empty init data.
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, STRANGER));
        factory.deployDeterministicProxy(address(template), abi.encodeCall(IBaseTemplate.ROYCO_FACTORY, ()), keccak256("z"));

        vm.stopPrank();

        // A DEPLOYER_ROLE holder CAN call `deployDeterministicProxy` outside a deployment window: it deploys a live ERC1967 proxy
        // at the CREATE3 address derived from the salt (which is itself the proxy's provenance — only the factory can
        // deploy there). (Init data is a non-empty no-op view call — the hardened ERC1967Proxy rejects empty init data.)
        vm.prank(DEPLOYER);
        address proxy = factory.deployDeterministicProxy(address(template), abi.encodeCall(IBaseTemplate.ROYCO_FACTORY, ()), keccak256("standalone-proxy"));
        assertGt(proxy.code.length, 0, "deployDeterministicProxy must produce a live proxy");
        assertEq(
            proxy, factory.predictDeterministicAddress(keccak256("standalone-proxy")), "deployDeterministicProxy must deploy at the salt's CREATE3 address"
        );
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
        bytes memory p = _encodedParams(MARKET_ID_A);
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

        // A DEPLOYER attempting to grant itself ADMIN_FACTORY_ROLE / bind the factory's own registerTemplate selector
        uint64[] memory roleIds = new uint64[](1);
        roleIds[0] = ADMIN_FACTORY_ROLE;
        address[] memory accounts = new address[](1);
        accounts[0] = DEPLOYER;
        uint32[] memory delays = new uint32[](1);

        address[] memory targets = new address[](1);
        targets[0] = address(factory);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IRoycoFactory.registerTemplate.selector;
        uint64[] memory bindRoleIds = new uint64[](1);
        bindRoleIds[0] = DEPLOYER_ROLE;

        vm.startPrank(DEPLOYER);
        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.grantMarketRole(roleIds, accounts, delays);
        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.setMarketTargetFunctionRole(targets, selectors, bindRoleIds);
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
        bytes32 marketId = MARKET_ID_A;
        IRoycoProtocolTemplate.DeploymentResult memory first = _deploy(MARKET_ID_A);
        assertGt(first.kernel.code.length, 0, "first market is live");

        // The deterministic component addresses are a pure function of the marketId, so a second run with the same id
        // cannot even re-deploy the market's contracts: the senior tranche proxy already exists at its CREATE3 address,
        // so the factory's `deployDeterministicProxy` rejects the collision before the wiring transaction is ever reached. Match on
        // the selector only: the exact (address, salt) payload is an internal detail.
        MarketConfig memory cfg = deployScript.getMarketConfig("snUSD");
        vm.expectPartialRevert(IRoycoFactory.PROXY_ALREADY_DEPLOYED.selector);
        deployScript.deployMarketContractsForTest(cfg, marketId, factory, address(template), address(am));

        // Atomicity: the failed redeploy left the first market's registry entry exactly as it was.
        _assertGetMarketResolves(first, first.seniorTranche, "first market intact after failed redeploy");
    }

    /// @notice A StaticCurve YDM config deploys an actual StaticCurveYDM model for both the JT YDM and the LPT LDM
    /// @dev The template registers every YDM model's bytecode and selects the configured type by component id, so the
    ///      deployed contract matches the config even though StaticCurveYDM.initializeYDMForMarket(uint64,uint64,uint64)
    ///      shares its 4-byte selector with the V2 initializer. The reused snUSD params (0.11e18, 0.11e18, 0.31e18) are
    ///      ABI-identical to StaticCurveYDMParams, so the static init calldata decodes and binds on the StaticCurve model
    function test_StaticCurveYdmConfig_DeploysStaticCurveModel() external {
        _register();

        MarketConfig memory cfg = deployScript.getMarketConfig("snUSD");
        _resolveCollateralOracle(cfg);
        cfg.ydmType = YDMType.StaticCurve;
        bytes32 marketId = MARKET_ID_A;
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketContracts memory mc =
            deployScript.deployMarketContractsForTest(cfg, marketId, factory, address(template), address(am));
        bytes memory p = abi.encode(deployScript.buildMarketParams(cfg, marketId, PROTOCOL_FEE_RECIPIENT, address(0), mc));

        vm.prank(DEPLOYER);
        IRoycoProtocolTemplate.DeploymentResult memory r = factory.executeMarketDeployment(address(template), p);

        // The deployed model is the configured StaticCurveYDM. The YDMs embed their target utilization as an immutable,
        // so runtime code is target-dependent — compare against reference instances built with the SAME targets the
        // config carries, which isolates the model type as the only difference that matters.
        StaticCurveYDM refJtStatic = new StaticCurveYDM(cfg.jtYdmTargetUtilizationWAD);
        StaticCurveYDM refLptStatic = new StaticCurveYDM(cfg.lptYdmTargetUtilizationWAD);
        AdaptiveCurveYDM_V2 refV2 = new AdaptiveCurveYDM_V2(cfg.jtYdmTargetUtilizationWAD, 0.0001e18, 1e18, (100e18 / uint256(365 days)));
        assertEq(r.ydm.codehash, address(refJtStatic).codehash, "configured StaticCurve, ydm must be StaticCurveYDM");
        assertEq(r.lptYdm.codehash, address(refLptStatic).codehash, "configured StaticCurve, lptYdm must be StaticCurveYDM");
        // And it is NOT the adaptive model that used to stand in for it under a static config.
        assertTrue(r.ydm.codehash != address(refV2).codehash, "ydm must not be the adaptive V2 code");
    }

    /// @notice An AdaptiveCurve_V1 YDM config deploys an actual AdaptiveCurveYDM_V1 model for both the JT YDM and the LPT LDM
    /// @dev With every YDM model's bytecode registered and selected by component id, a V1 config deploys the V1 contract
    ///      and its two-argument initializeYDMForMarket(uint64,uint64) binds on it, so the deployment succeeds rather than
    ///      reverting against a stand-in V2 instance whose selector the V1 calldata could not match
    function test_AdaptiveV1YdmConfig_DeploysAdaptiveV1Model() external {
        _register();

        MarketConfig memory cfg = deployScript.getMarketConfig("snUSD");
        _resolveCollateralOracle(cfg);
        cfg.ydmType = YDMType.AdaptiveCurve_V1;
        // V1 takes only (target, full), so re-encode both curves as V1 params — a two-word init blob that binds on the V1 model
        bytes memory v1Params = abi.encode(AdaptiveCurveYDM_V1_Params({ yieldShareAtTargetUtilWAD: 0.11e18, yieldShareAtFullUtilWAD: 0.31e18 }));
        cfg.ydmSpecificParams = v1Params;
        cfg.lptYdmSpecificParams = v1Params;
        bytes32 marketId = MARKET_ID_A;
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketContracts memory mc =
            deployScript.deployMarketContractsForTest(cfg, marketId, factory, address(template), address(am));
        bytes memory p = abi.encode(deployScript.buildMarketParams(cfg, marketId, PROTOCOL_FEE_RECIPIENT, address(0), mc));

        vm.prank(DEPLOYER);
        IRoycoProtocolTemplate.DeploymentResult memory r = factory.executeMarketDeployment(address(template), p);

        // The deployed model is the configured AdaptiveCurveYDM_V1, compared against references built with the same targets
        AdaptiveCurveYDM_V1 refJtV1 = new AdaptiveCurveYDM_V1(cfg.jtYdmTargetUtilizationWAD, 0.0001e18, 1e18, (50e18 / uint256(365 days)));
        AdaptiveCurveYDM_V1 refLptV1 = new AdaptiveCurveYDM_V1(cfg.lptYdmTargetUtilizationWAD, 0.0001e18, 1e18, (50e18 / uint256(365 days)));
        assertEq(r.ydm.codehash, address(refJtV1).codehash, "configured AdaptiveCurve_V1, ydm must be AdaptiveCurveYDM_V1");
        assertEq(r.lptYdm.codehash, address(refLptV1).codehash, "configured AdaptiveCurve_V1, lptYdm must be AdaptiveCurveYDM_V1");
    }

    // ─── internal ───

    function _emptyResult() internal pure returns (IRoycoProtocolTemplate.DeploymentResult memory r) {
        r; // zero-initialized; only used for event topic matching (data not checked)
    }
}
