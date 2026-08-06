// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IProtocolFeeController } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IProtocolFeeController.sol";
import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { IVaultAdmin } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultAdmin.sol";
import { TokenInfo, TokenType } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { GyroECLPPoolFactory } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Initializable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { RoycoMarketSyncer } from "../../../lib/royco-periphery/src/syncer/RoycoMarketSyncer.sol";
import { AdaptiveCurveYDM_V1_Params, DeploymentResult, ERC4626SharePriceOracleParams, FixedYDMParams, ImplementationSet, YDMType } from "../../../script/config/DeploymentTypes.sol";
import { RoycoDayEntryPoint } from "../../../src/entrypoint/RoycoDayEntryPoint.sol";
import {
    ADMIN_BALANCER_POOL_MANAGER_ROLE,
    ADMIN_ENTRY_POINT_ROLE,
    ADMIN_FACTORY_ROLE,
    ADMIN_PAUSER_ROLE,
    ADMIN_PROTOCOL_FEE_SETTER_ROLE,
    ADMIN_ROLE,
    ADMIN_UNPAUSER_ROLE,
    ADMIN_UPGRADER_ROLE,
    PUBLIC_ROLE,
    SYNC_ROLE
} from "../../../src/factory/Roles.sol";
import { RoycoAccessManager } from "../../../src/factory/RoycoAccessManager.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";
import { RoycoFactoryGatekeeper } from "../../../src/factory/RoycoFactoryGatekeeper.sol";
import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { BaseDeploymentTemplate } from "../../../src/factory/templates/base/BaseDeploymentTemplate.sol";
import { TAG_ST_PROXY } from "../../../src/factory/templates/base/Constants.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { IBaseTemplate } from "../../../src/interfaces/factory/IBaseTemplate.sol";
import { IRoycoAccessManager } from "../../../src/interfaces/factory/IRoycoAccessManager.sol";
import { IRoycoFactory } from "../../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { MarketDeploymentValidationLogic } from "../../../src/libraries/logic/factory/MarketDeploymentValidationLogic.sol";
import { TrancheType } from "../../../src/libraries/Types.sol";
import { ERC4626SharePriceOracle } from "../../../src/oracle/ERC4626SharePriceOracle.sol";
import { AdaptiveCurveYDM_V1 } from "../../../src/ydm/AdaptiveCurveYDM_V1.sol";
import { AdaptiveCurveYDM_V2 } from "../../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { FixedYDM } from "../../../src/ydm/FixedYDM.sol";
import { StaticCurveYDM } from "../../../src/ydm/StaticCurveYDM.sol";
import { DayMarketRegistry } from "../../../script/deploy/templates/royco-day-balancer-v3/DayMarketRegistry.sol";
import { DayMarketConfig } from "../../../script/deploy/templates/royco-day-balancer-v3/DayMarketTypes.sol";
import { DeployMarketComponent } from "../../../script/deploy/templates/royco-day-balancer-v3/DeployMarket.s.sol";
import { FactoryScaffold } from "../../utils/FactoryScaffold.sol";
import { TemplateScaffold } from "../../utils/TemplateScaffold.sol";

/// @title Test_RoycoFactory
/// @notice Fork tests for `RoycoFactory` driven by the REAL Day market template
///         (`RoycoDayBalancerV3MarketDeploymentTemplate`) — no mock. Covers: initialization + role wiring,
///         template registration/disabling, the deployment entrypoint standing up a real snUSD market (tranche
///         mappings + events + live contracts), auth/pause gating, the active-template-gated primitives rejecting
///         outside a deployment window, getters, and the UUPS upgrade gate.
/// @dev Requires a mainnet fork (real Balancer V3 + Gyro E-CLP + snUSD vault). FAILS (env not found) when
///      `MAINNET_RPC_URL` is unset, instead of silently passing.
contract Test_RoycoFactory is Test {
    /// @dev The address that supplies each market's genesis pool liquidity in this suite
    uint256 internal constant FORK_BLOCK = 25_400_000;
    address internal constant GYRO_ECLP_POOL_FACTORY = 0x04d584195a96DFfc7F8B695aA3C9D3c1606b69d1;

    RoycoAccessManager internal am;
    RoycoFactoryGatekeeper internal gatekeeper;
    RoycoFactory internal factory;
    DayMarketRegistry internal registry;
    DeployMarketComponent internal marketBuilder;
    ImplementationSet internal implementationSet;
    RoycoDayBalancerV3MarketDeploymentTemplate internal template;
    IRoycoDayEntryPoint internal entryPoint;
    RoycoMarketSyncer internal syncer;

    /// @dev The chain's blacklist singleton, pinned into the template at construction
    address internal roycoBlacklist;

    address internal FACTORY_ADMIN = makeAddr("FACTORY_ADMIN");
    address internal DEPLOYER = makeAddr("DEPLOYER");
    address internal UPGRADER = makeAddr("UPGRADER");
    address internal STRANGER = makeAddr("STRANGER");
    address internal PROTOCOL_FEE_RECIPIENT = makeAddr("PROTOCOL_FEE_RECIPIENT");

    /// @dev Mirrors YDMLib.YDM_TARGET_UTILIZATION_WAD: the chain-wide kink every model instance is deployed with
    uint256 internal constant YDM_TARGET_UTILIZATION_WAD = 0.9e18;

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
        am = new RoycoAccessManager(address(this));

        // The factory proxy takes a CREATE3 address, a function of its salt alone, which is what lets the gatekeeper
        // and the factory each hold the other as a constructor immutable. The scaffold stands both up and binds the
        // factory's own selectors and roles, exactly as the deployment script does.
        (factory, gatekeeper, entryPoint, syncer) = FactoryScaffold.deployFactory(am, keccak256("FACTORY_PROXY"));

        // Every market the template deploys screens against this one blacklist, and the template rejects a null one
        roycoBlacklist = FactoryScaffold.deployBlacklist(am);

        // Grant the factory-facing roles the scaffold bound to the factory's selectors.
        am.grantRole(ADMIN_FACTORY_ROLE, FACTORY_ADMIN, 0);
        am.grantRole(ADMIN_UPGRADER_ROLE, UPGRADER, 0);
        // The scaffold binds the factory's pause/unpause to the pauser/unpauser roles, so this test contract (the AM
        // admin) needs them to pause/unpause the factory directly.
        am.grantRole(ADMIN_PAUSER_ROLE, address(this), 0);
        am.grantRole(ADMIN_UNPAUSER_ROLE, address(this), 0);

        // The scaffold deployed the REAL periphery singletons alongside the gatekeeper that pins them

        // Bind the config selectors the factory drives during deployments (the factory self-granted
        // ADMIN_ENTRY_POINT_ROLE + SYNC_ROLE in its initialize).
        bytes4[] memory entryPointSelectors = new bytes4[](1);
        entryPointSelectors[0] = IRoycoDayEntryPoint.modifyTrancheConfigs.selector;
        am.setTargetFunctionRole(address(entryPoint), entryPointSelectors, ADMIN_ENTRY_POINT_ROLE);
        bytes4[] memory syncerSelectors = new bytes4[](1);
        syncerSelectors[0] = RoycoMarketSyncer.addMarketKernels.selector;
        am.setTargetFunctionRole(address(syncer), syncerSelectors, SYNC_ROLE);

        // The real Day template, bound to this factory, stood up through the real per-component deploy scripts.
        // The template deploys every market contract itself, so the script only builds the params (`buildMarketParams`).
        TemplateScaffold.Result memory scaffold = TemplateScaffold.standUp(am, factory, roycoBlacklist);
        registry = scaffold.registry;
        marketBuilder = scaffold.market;
        implementationSet = scaffold.impls;
        template = scaffold.template;

        // The template's configuration surface, bound exactly as the scaffolding phase does: the pool
        // policy and the recipient answer to ADMIN_FACTORY_ROLE, the fee set to the same role as each market's own
        // protocol fee setters
        bytes4[] memory configSelectors = new bytes4[](2);
        configSelectors[0] = BaseDeploymentTemplate.setProtocolFeeRecipient.selector;
        configSelectors[1] = RoycoDayBalancerV3MarketDeploymentTemplate.setBalancerPoolConfig.selector;
        am.setTargetFunctionRole(address(template), configSelectors, ADMIN_FACTORY_ROLE);

        bytes4[] memory feeSelectors = new bytes4[](1);
        feeSelectors[0] = BaseDeploymentTemplate.setProtocolFeeConfig.selector;
        am.setTargetFunctionRole(address(template), feeSelectors, ADMIN_PROTOCOL_FEE_SETTER_ROLE);
        am.grantRole(ADMIN_PROTOCOL_FEE_SETTER_ROLE, FACTORY_ADMIN, 0);
    }

    // ─── helpers ───

    function _register() internal {
        vm.prank(FACTORY_ADMIN);
        factory.registerTemplate(address(template));
    }

    /// @dev Every market is deployed with genesis pool liquidity, so the configured funder must hold each seed leg and
    ///      have approved the template before `executeMarketDeployment`. The deployment caller (DEPLOYER) funds the seed.
    ///      The collateral leg is optional, so it is funded only when the config asks for it
    /// @dev Funds and approves an explicit deployer, which the template pulls the genesis seed from
    function _fundPoolSeedFor(DayMarketConfig memory _cfg, address _deployer) internal {
        deal(_cfg.pool.quoteAsset, _deployer, _cfg.poolInitialization.quoteAmount);
        vm.prank(_deployer);
        IERC20(_cfg.pool.quoteAsset).approve(address(template), _cfg.poolInitialization.quoteAmount);
    }

    function _fundPoolSeed(DayMarketConfig memory _cfg) internal {
        _fundSeedLeg(_cfg.pool.quoteAsset, _cfg.poolInitialization.quoteAmount);
        if (_cfg.poolInitialization.collateralAmount != 0) _fundSeedLeg(_cfg.collateralAsset, _cfg.poolInitialization.collateralAmount);
    }

    /// @dev Deals one seed leg to the deployment caller (DEPLOYER) and approves the template to pull it
    function _fundSeedLeg(address _asset, uint256 _amount) internal {
        deal(_asset, DEPLOYER, _amount);
        vm.prank(DEPLOYER);
        IERC20(_asset).approve(address(template), _amount);
    }

    /// @dev Resolves the snUSD config's oracle and YDM instances, funds the seed, and builds the encoded template
    ///      params from the SAME config. `_marketId` must place the senior tranche as pool token0 for this suite's
    ///      `factory` (see MARKET_ID_A/B).
    function _encodedParams(bytes32 _marketId) internal returns (bytes memory) {
        DayMarketConfig memory cfg = registry.getDayMarketConfig("snUSD");
        _resolveCollateralOracle(cfg);
        _resolveYdms(cfg);
        _fundPoolSeed(cfg);
        return abi.encode(marketBuilder.buildMarketParams(cfg, _marketId, address(factory), DEPLOYER));
    }

    /// @dev The `deploy()` flow resolves an unset config oracle itself; the direct-template path must supply it, so
    ///      deploy the config's ERC4626 share-price adapter over the market's collateral vault + base->NAV feed.
    function _resolveCollateralOracle(DayMarketConfig memory _cfg) internal {
        if (_cfg.oracle.deployed != address(0)) return;
        _cfg.oracle.deployed = address(
            _newErc4626Oracle(_cfg.collateralAsset, _cfg.oracle.specificParams)
        );
    }

    /// @dev Resolves (or deploys) the market's yield distribution model instances, mirroring the pipeline
    function _resolveYdms(DayMarketConfig memory _cfg) internal {
        if (_cfg.accountant.jtYdm.deployed == address(0)) _cfg.accountant.jtYdm.deployed = marketBuilder.deployYDM("JT model  ", _cfg.accountant.jtYdm);
        if (_cfg.accountant.lptYdm.deployed == address(0)) _cfg.accountant.lptYdm.deployed = marketBuilder.deployYDM("LPT model ", _cfg.accountant.lptYdm);
    }

    function _deploy(bytes32 _marketId) internal returns (IRoycoProtocolTemplate.DeploymentResult memory) {
        // Precompute the params first: `_encodedParams` builds the template params outside the deployment call,
        // which would otherwise consume the `vm.prank(DEPLOYER)` intended for `executeMarketDeployment`.
        bytes memory p = _encodedParams(_marketId);
        vm.prank(DEPLOYER);
        return factory.executeMarketDeployment(address(template), p);
    }

    /// The genesis seed's collateral leg is optional. When the config asks for one, the multi-asset deposit mints it
    /// into senior shares, so the pool opens with depth on BOTH legs rather than quote alone.
    /// @dev The market must set `minCoverageWAD` to zero for this to be reachable: the seed is the market's FIRST
    ///      deposit, so the junior tranche is still empty and any senior mint under a nonzero coverage floor takes
    ///      coverage utilization above WAD and reverts `COVERAGE_REQUIREMENT_VIOLATED` inside the deployment
    function test_ExecuteMarketDeployment_SeedsBothPoolLegsWhenCollateralIsConfigured() external {
        _register();

        DayMarketConfig memory cfg = registry.getDayMarketConfig("snUSD");
        _resolveCollateralOracle(cfg);
        _resolveYdms(cfg);
        cfg.accountant.minCoverageWAD = 0;
        cfg.poolInitialization.collateralAmount = 10_000e18;
        _fundPoolSeed(cfg);
        bytes memory p = abi.encode(marketBuilder.buildMarketParams(cfg, MARKET_ID_A, address(factory), DEPLOYER));

        vm.prank(DEPLOYER);
        IRoycoProtocolTemplate.DeploymentResult memory r = factory.executeMarketDeployment(address(template), p);

        IVault vault = IVault(address(GyroECLPPoolFactory(GYRO_ECLP_POOL_FACTORY).getVault()));
        (,, uint256[] memory balances,) = vault.getPoolTokenInfo(IRoycoDayKernel(r.kernel).lptAsset());
        assertGt(balances[0], 0, "senior leg opened with no genesis depth");
        assertGt(balances[1], 0, "quote leg opened with no genesis depth");
        // The collateral leg is the only source of senior shares here, and the funder receives the genesis LP shares
        assertGt(IERC20(r.seniorTranche).totalSupply(), 0, "collateral leg minted no senior shares");
        assertGt(IERC20(r.liquidityProviderTranche).balanceOf(DEPLOYER), 0, "funder holds no genesis liquidity shares");
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

        // The periphery roles sit on the gatekeeper, which drives the entry point and the syncer itself
        (bool factoryHasEntryPoint,) = am.hasRole(ADMIN_ENTRY_POINT_ROLE, address(factory));
        assertFalse(factoryHasEntryPoint, "the factory must NOT hold ADMIN_ENTRY_POINT_ROLE");
        (bool gatekeeperHasEntryPoint,) = am.hasRole(ADMIN_ENTRY_POINT_ROLE, address(gatekeeper));
        assertTrue(gatekeeperHasEntryPoint, "the gatekeeper must hold ADMIN_ENTRY_POINT_ROLE");

        // Market deployment is permissionless: any funded caller may deploy, so the entrypoint is PUBLIC_ROLE
        assertEq(am.getTargetFunctionRole(address(factory), IRoycoFactory.executeMarketDeployment.selector), PUBLIC_ROLE, "deploy role");
        assertEq(am.getTargetFunctionRole(address(factory), IRoycoFactory.registerTemplate.selector), ADMIN_FACTORY_ROLE, "register role");
        assertEq(am.getTargetFunctionRole(address(factory), IRoycoFactory.disableTemplate.selector), ADMIN_FACTORY_ROLE, "disable role");
        assertEq(am.getTargetFunctionRole(address(factory), UUPSUpgradeable.upgradeToAndCall.selector), ADMIN_UPGRADER_ROLE, "upgrade role");
    }

    /// A zero AccessManager address is rejected at initialization
    function test_RevertIf_InitializedWithZeroAccessManager() external {
        RoycoFactory freshImpl = new RoycoFactory(address(gatekeeper));
        vm.expectRevert(IRoycoFactory.ACCESS_MANAGER_CANNOT_BE_ZERO_ADDRESS.selector);
        new ERC1967Proxy(address(freshImpl), abi.encodeCall(RoycoFactory.initialize, (address(0))));
    }

    /// An AccessManager with no code is rejected: the factory refuses a dead authority
    function test_RevertIf_InitializedWithCodelessAccessManager() external {
        address eoa = makeAddr("EOA_NO_CODE");
        RoycoFactory freshImpl = new RoycoFactory(address(gatekeeper));
        vm.expectRevert(IRoycoFactory.ACCESS_MANAGER_HAS_NO_CODE.selector);
        new ERC1967Proxy(address(freshImpl), abi.encodeCall(RoycoFactory.initialize, (eoa)));
    }

    /// The factory's gatekeeper must hold authority over the access manager it is initialized against: a factory whose
    /// gatekeeper governs some OTHER manager would have no way to configure anything
    function test_RevertIf_InitializedAgainstAnAccessManagerItsGatekeeperDoesNotGovern() external {
        RoycoAccessManager otherAM = new RoycoAccessManager(address(this));
        RoycoFactory freshImpl = new RoycoFactory(address(new RoycoFactoryGatekeeper(address(otherAM), address(factory), address(entryPoint), address(syncer))));
        vm.expectRevert(IRoycoFactory.FACTORY_GATEKEEPER_MISMATCH.selector);
        new ERC1967Proxy(address(freshImpl), abi.encodeCall(RoycoFactory.initialize, (address(am))));
    }

    /// A factory can never be constructed without a gatekeeper to route its configuration through
    function test_RevertIf_ConstructedWithoutAGatekeeper() external {
        vm.expectRevert(IRoycoFactory.FACTORY_GATEKEEPER_CANNOT_BE_ZERO_ADDRESS.selector);
        new RoycoFactory(address(0));
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
        // A real template bound to a different factory address must be rejected. The foreign factory has to be a real
        // one: the template reads `ROYCO_AUTHORITY()` off it at construction to set its own access manager. Its entry
        // point must be bound to that same foreign factory, which the template also validates at construction.
        (RoycoFactory otherFactory,,,) = FactoryScaffold.deployFactory(am, keccak256("FOREIGN_FACTORY_PROXY"));
        new RoycoDayEntryPoint(address(otherFactory));
        RoycoDayBalancerV3MarketDeploymentTemplate foreign =
            RoycoDayBalancerV3MarketDeploymentTemplate(TemplateScaffold.deployTemplateFor(am, otherFactory, roycoBlacklist, implementationSet));
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
        // Both slots select the same V2 shape, which resolves to the one chain-wide instance
        assertTrue(r.ydm != address(0) && r.ydm == r.lptYdm, "both slots must share the chain-wide V2 instance");

        // The registry resolves the WHOLE market from ANY of the three tranches.
        _assertGetMarketResolves(r, r.seniorTranche, "via senior");
        _assertGetMarketResolves(r, r.juniorTranche, "via junior");
        _assertGetMarketResolves(r, r.liquidityProviderTranche, "via liquidity");
        assertEq(factory.trancheToKernel(r.seniorTranche), r.kernel, "st->kernel");
        assertEq(factory.trancheToKernel(r.juniorTranche), r.kernel, "jt->kernel");
        assertEq(factory.trancheToKernel(r.liquidityProviderTranche), r.kernel, "lt->kernel");

        // The template configured the entry point for all three tranches through the factory (post-registration hook).
        DayMarketConfig memory cfg = registry.getDayMarketConfig("snUSD");
        _assertEntryPointConfigured(r.seniorTranche, r.kernel, cfg.stEntryPointConfig, "st entry point config");
        _assertEntryPointConfigured(r.juniorTranche, r.kernel, cfg.jtEntryPointConfig, "jt entry point config");
        _assertEntryPointConfigured(r.liquidityProviderTranche, r.kernel, cfg.lptEntryPointConfig, "lpt entry point config");

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
     * @notice A second market deploys against an access manager where the chain-global Balancer governance targets are
     *         already configured, and declines to re-assert them
     * @dev This is the interaction between the gatekeeper's fresh-target rule and the shared, non-market-owned targets
     *      in the template's binding set. The Balancer vault and its protocol fee controller belong to the chain, not to
     *      a market, so whichever deployment reaches them first configures them and every later one must skip: without
     *      the skip the gatekeeper would reject market B outright and no second market could ever be deployed
     */
    function test_ExecuteMarketDeployment_SecondMarketSkipsAlreadyConfiguredBalancerTargets() external {
        _register();

        address vault = address(template.BALANCER_V3_VAULT());
        address feeController = address(template.BALANCER_V3_VAULT().getProtocolFeeController());
        IRoycoAccessManager accessManager = IRoycoAccessManager(address(am));

        assertFalse(accessManager.wasEverConfigured(vault), "the Balancer vault must start unconfigured");
        assertFalse(accessManager.wasEverConfigured(feeController), "the fee controller must start unconfigured");

        _deploy(MARKET_ID_A);

        // Market A configured them, and the bindings it installed are live
        assertTrue(accessManager.wasEverConfigured(vault), "market A must configure the Balancer vault");
        assertTrue(accessManager.wasEverConfigured(feeController), "market A must configure the fee controller");
        assertEq(am.getTargetFunctionRole(vault, IVaultAdmin.pausePool.selector), ADMIN_PAUSER_ROLE, "vault pausePool binding from market A");
        assertEq(
            am.getTargetFunctionRole(feeController, IProtocolFeeController.setPoolCreatorSwapFeePercentage.selector),
            ADMIN_BALANCER_POOL_MANAGER_ROLE,
            "fee controller binding from market A"
        );

        // Market B deploys without re-asserting them, and market A's bindings survive untouched
        _deploy(MARKET_ID_B);
        assertEq(am.getTargetFunctionRole(vault, IVaultAdmin.pausePool.selector), ADMIN_PAUSER_ROLE, "vault binding must survive the second deployment");
        assertEq(
            am.getTargetFunctionRole(feeController, IProtocolFeeController.setPoolCreatorSwapFeePercentage.selector),
            ADMIN_BALANCER_POOL_MANAGER_ROLE,
            "fee controller binding must survive the second deployment"
        );
    }

    /**
     * @notice The YDM salt is chain-wide per shape: two markets selecting the same model shape share ONE instance,
     *         and within a market the JT and LPT slots share it too, since each accountant's curves are keyed per
     *         accountant AND per tranche type on the instance. A market configured with a DIFFERENT model resolves
     *         to a different instance (the shape is part of the salt), so sharing never crosses model boundaries
     */
    function test_ExecuteMarketDeployment_SharesYdmInstancesAcrossMarkets() external {
        _register();

        IRoycoProtocolTemplate.DeploymentResult memory a = _deploy(MARKET_ID_A);
        IRoycoProtocolTemplate.DeploymentResult memory b = _deploy(MARKET_ID_B);
        assertTrue(a.kernel != b.kernel, "distinct markets");

        // Both markets and both tranche slots share the one chain-wide V2 instance (shape-keyed salts)
        assertEq(a.ydm, b.ydm, "the JT YDM instance must be shared across markets");
        assertEq(a.lptYdm, b.lptYdm, "the LPT LDM instance must be shared across markets");
        assertEq(a.ydm, a.lptYdm, "one shape must resolve to one shared instance for both tranche slots");

        // Each market's accountant initialized its OWN curves on the shared instance (state keyed per accountant and
        // tranche type): the snUSD config's V2 curve (0.11e18 at zero, 0.11e18 at target, 0.31e18 at full) decomposes
        // to yieldShareAtTarget = 0.11e18, discount-at-zero = 0, premium-at-full = 0.2e18 for both accountants
        assertTrue(a.accountant != b.accountant, "distinct accountants");
        _assertV2CurveInitialized(a.ydm, a.accountant, TrancheType.JUNIOR, "market A JT curve on the shared instance");
        _assertV2CurveInitialized(a.ydm, a.accountant, TrancheType.LIQUIDITY_PROVIDER, "market A LPT curve on the shared instance");
        _assertV2CurveInitialized(a.ydm, b.accountant, TrancheType.JUNIOR, "market B JT curve on the shared instance");

        // A different-model market resolves to a different instance: the YDM shape is part of the deployed contract type
        DayMarketConfig memory staticCfg = registry.getDayMarketConfig("snUSD");
        _resolveCollateralOracle(staticCfg);
        _fundPoolSeed(staticCfg);
        staticCfg.accountant.jtYdm.ydmType = YDMType.StaticCurve;
        staticCfg.accountant.lptYdm.ydmType = YDMType.StaticCurve;
        _resolveYdms(staticCfg);
        bytes32 staticId = MARKET_ID_C;
        bytes memory p = abi.encode(marketBuilder.buildMarketParams(staticCfg, staticId, address(factory), DEPLOYER));
        vm.prank(DEPLOYER);
        IRoycoProtocolTemplate.DeploymentResult memory s = factory.executeMarketDeployment(address(template), p);
        assertTrue(s.ydm != a.ydm, "a different YDM model must not share the adaptive markets' JT YDM instance");
        assertTrue(s.lptYdm != a.lptYdm, "a different YDM model must not share the adaptive markets' LPT LDM instance");
    }

    /// @dev Asserts the shared V2 YDM instance holds the snUSD config's initialized curve for the given accountant and tranche type
    function _assertV2CurveInitialized(address _ydm, address _accountant, TrancheType _trancheType, string memory _ctx) internal view {
        (uint64 yieldShareAtTargetWAD, uint32 lastAdaptationTimestamp, uint64 discountToTargetAtZeroUtilWAD, uint64 premiumToTargetAtFullUtilWAD) =
            AdaptiveCurveYDM_V2(_ydm).accountantToCurve(_accountant, _trancheType);
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
        address quoteAsset = registry.getDayMarketConfig("snUSD").pool.quoteAsset;
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
        address pool = IRoycoDayKernel(_r.kernel).lptAsset();
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
        (address st, address jt, address lt, address kernel, address accountant) = factory.getMarket(_key);
        assertEq(st, _r.seniorTranche, string.concat(_ctx, ": senior"));
        assertEq(jt, _r.juniorTranche, string.concat(_ctx, ": junior"));
        assertEq(lt, _r.liquidityProviderTranche, string.concat(_ctx, ": liquidity"));
        assertEq(kernel, _r.kernel, string.concat(_ctx, ": kernel"));
        assertEq(accountant, _r.accountant, string.concat(_ctx, ": accountant"));
    }

    /// @notice Market deployment is PERMISSIONLESS: any caller who funds the genesis seed can stand up a market.
    ///         Protocol policy lives on the template and every component lands in a salt namespaced by the caller,
    ///         so an open entrypoint cannot misprice or grief another deployer's markets
    function test_ExecuteMarketDeployment_IsPermissionlessForAnyFundedCaller() external {
        _register();

        DayMarketConfig memory cfg = registry.getDayMarketConfig("snUSD");
        _resolveCollateralOracle(cfg);
        _fundPoolSeedFor(cfg, STRANGER);
        bytes memory p = abi.encode(marketBuilder.buildMarketParams(cfg, MARKET_ID_A, address(factory), STRANGER));

        vm.prank(STRANGER);
        IRoycoProtocolTemplate.DeploymentResult memory r = factory.executeMarketDeployment(address(template), p);
        assertGt(r.kernel.code.length, 0, "a stranger's funded deployment must produce a live market");
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

        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.setMarketTargetFunctionRole(address(this), selectors, roleIds);

        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.configureMarketPeriphery(addrs, new IRoycoDayEntryPoint.TrancheConfig[](1), address(this));

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
        (address st, address jt, address lt, address kernel, address accountant) = factory.getMarket(makeAddr("UNKNOWN"));
        assertEq(st, address(0), "unknown senior");
        assertEq(jt, address(0), "unknown junior");
        assertEq(lt, address(0), "unknown liquidity");
        assertEq(kernel, address(0), "unknown kernel");
        assertEq(accountant, address(0), "unknown accountant");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ROLE-ESCALATION ATTEMPTS (adversarial)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice A deployer key cannot reach the factory-admin surface: market deployment is PUBLIC and grants no
    ///         standing, so a compromised deployer key cannot register or disable templates to redirect future markets
    function test_RevertIf_DeployerCallsFactoryAdminSurface() external {
        _register();
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, DEPLOYER));
        factory.registerTemplate(address(template));
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, DEPLOYER));
        factory.disableTemplate(address(template));
    }


    /**
     * @notice Even legitimate role holders cannot use the template-callable role primitives outside a deployment
     *         window: a deployer trying to grant itself a market role, or bind a selector to a role it controls,
     *         is rejected because no template is active
     * @dev This is the factory's outer privilege-escalation chokepoint: the role primitives reach the AccessManager
     *      (via the gatekeeper, which holds ADMIN_ROLE), so they must be callable only from inside
     *      executeMarketDeployment's transient template binding. The gatekeeper's fresh-target rule and the factory's
     *      grant allowlist are the inner gates, covered separately
     */
    function test_RevertIf_RoleHolderCallsTemplatePrimitivesOutsideDeploymentWindow() external {
        _register();

        // A market deployer attempting to grant itself ADMIN_ROLE / bind the factory's own registerTemplate selector
        address[] memory accounts = new address[](1);
        accounts[0] = DEPLOYER;

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IRoycoFactory.registerTemplate.selector;
        uint64[] memory bindRoleIds = new uint64[](1);
        bindRoleIds[0] = ADMIN_FACTORY_ROLE;

        vm.startPrank(DEPLOYER);
        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.configureMarketPeriphery(accounts, new IRoycoDayEntryPoint.TrancheConfig[](1), DEPLOYER);
        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.setMarketTargetFunctionRole(address(factory), selectors, bindRoleIds);
        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.executeAsFactory(address(am), abi.encodeCall(IAccessManager.grantRole, (ADMIN_ROLE, DEPLOYER, 0)));
        // The gatekeeper is denied as an arbitrary-call target alongside the access manager itself: it holds
        // ADMIN_ROLE, so from a blast-radius standpoint it IS the access manager
        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.executeAsFactory(address(gatekeeper), "");
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // UPGRADE GATE
    // ═══════════════════════════════════════════════════════════════════════════

    /// Only ADMIN_UPGRADER_ROLE may upgrade the factory proxy
    function test_RevertIf_NonUpgraderUpgradesFactory() external {
        address newImpl = address(new RoycoFactory(address(gatekeeper)));
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, STRANGER));
        factory.upgradeToAndCall(newImpl, "");
    }

    /// The upgrader role can upgrade and the authority survives the implementation swap
    function test_UpgradeToAndCall_SucceedsForUpgrader() external {
        address newImpl = address(new RoycoFactory(address(gatekeeper)));
        vm.prank(UPGRADER);
        factory.upgradeToAndCall(newImpl, "");
        assertEq(factory.authority(), address(am), "authority preserved");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET-ID COLLISION + YDM-TYPE WIRING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The deployer is mixed into the base salt, so two deployers submitting IDENTICAL params land on
    ///         disjoint markets instead of colliding on each other's CREATE3 salts
    function test_ExecuteMarketDeployment_SameParamsFromADifferentDeployerYieldADistinctMarket() external {
        _register();

        address otherDeployer = makeAddr("OTHER_DEPLOYER");

        DayMarketConfig memory cfg = registry.getDayMarketConfig("snUSD");
        _resolveCollateralOracle(cfg);

        // The same seed and the same config, mined for each deployer in turn
        _fundPoolSeedFor(cfg, DEPLOYER);
        bytes memory pA = abi.encode(marketBuilder.buildMarketParams(cfg, MARKET_ID_A, address(factory), DEPLOYER));
        _fundPoolSeedFor(cfg, otherDeployer);
        bytes memory pB = abi.encode(marketBuilder.buildMarketParams(cfg, MARKET_ID_A, address(factory), otherDeployer));

        vm.prank(DEPLOYER);
        IRoycoProtocolTemplate.DeploymentResult memory first = factory.executeMarketDeployment(address(template), pA);
        vm.prank(otherDeployer);
        IRoycoProtocolTemplate.DeploymentResult memory second = factory.executeMarketDeployment(address(template), pB);

        assertTrue(first.kernel != second.kernel, "a different deployer must produce a different kernel");
        assertTrue(first.seniorTranche != second.seniorTranche, "a different deployer must produce a different senior tranche");
    }

    /// @notice Re-running a deployment with params that already produced a market reverts on the first colliding
    ///         CREATE3 salt (the senior tranche proxy) and unwinds the whole transaction atomically, so a repeat can
    ///         never half-build a second market or leave a live market wired to a YDM reused earlier in the same
    ///         transaction. Blast radius is a clean revert, never aliasing
    /// @dev Every component salt hashes the WHOLE params struct, so a collision needs the exact same params, not
    ///      merely the same market id: the encoded blob is built once here and submitted twice
    function test_RevertIf_MarketRedeployedWithSameMarketId() external {
        _register();
        bytes memory p = _encodedParams(MARKET_ID_A);

        vm.prank(DEPLOYER);
        IRoycoProtocolTemplate.DeploymentResult memory first = factory.executeMarketDeployment(address(template), p);
        assertGt(first.kernel.code.length, 0, "first market is live");

        // The second deployment collides on the very first proxy the template deploys: the senior tranche already
        // exists at its CREATE3 address. Match on the selector only: the (address, salt) payload is an internal detail
        vm.prank(DEPLOYER);
        vm.expectPartialRevert(BaseDeploymentTemplate.MARKET_COMPONENT_ALREADY_DEPLOYED.selector);
        factory.executeMarketDeployment(address(template), p);

        // Atomicity: the failed redeploy left the first market's registry entry exactly as it was.
        _assertGetMarketResolves(first, first.seniorTranche, "first market intact after failed redeploy");
    }

    /// @notice A StaticCurve YDM config resolves an actual StaticCurveYDM instance for both the JT YDM and the LPT LDM
    /// @dev The pipeline deploys (or reuses) the selected shape's chain-wide instance and passes it by address, so the
    ///      deployed contract matches the config even though StaticCurveYDM.initializeYDMForMarket shares its 4-byte
    ///      selector with the V2 initializer. The reused snUSD params (0.11e18, 0.11e18, 0.31e18) are ABI-identical to
    ///      StaticCurveYDMParams, so the static init calldata decodes and binds on the StaticCurve model
    function test_StaticCurveYdmConfig_DeploysStaticCurveModel() external {
        _register();

        DayMarketConfig memory cfg = registry.getDayMarketConfig("snUSD");
        _resolveCollateralOracle(cfg);
        _fundPoolSeed(cfg);
        cfg.accountant.jtYdm.ydmType = YDMType.StaticCurve;
        cfg.accountant.lptYdm.ydmType = YDMType.StaticCurve;
        cfg.accountant.jtYdm.deployed = address(0);
        cfg.accountant.lptYdm.deployed = address(0);
        _resolveYdms(cfg);
        bytes32 marketId = MARKET_ID_A;
        bytes memory p = abi.encode(marketBuilder.buildMarketParams(cfg, marketId, address(factory), DEPLOYER));

        vm.prank(DEPLOYER);
        IRoycoProtocolTemplate.DeploymentResult memory r = factory.executeMarketDeployment(address(template), p);

        // The resolved model is the configured StaticCurveYDM. The YDMs embed their target utilization as an
        // immutable, so runtime code is target-dependent. Compare against a reference instance built with the SAME
        // target the config carries, which isolates the model type as the only difference that matters.
        StaticCurveYDM refStatic = new StaticCurveYDM(YDM_TARGET_UTILIZATION_WAD);
        AdaptiveCurveYDM_V2 refV2 = new AdaptiveCurveYDM_V2(YDM_TARGET_UTILIZATION_WAD, 0.0001e18, 1e18, (100e18 / uint256(365 days)));
        assertEq(r.ydm.codehash, address(refStatic).codehash, "configured StaticCurve, ydm must be StaticCurveYDM");
        assertEq(r.lptYdm.codehash, address(refStatic).codehash, "configured StaticCurve, lptYdm must be StaticCurveYDM");
        // One shape resolves to one chain-wide instance, shared by both tranche slots
        assertEq(r.ydm, r.lptYdm, "both slots must share the chain-wide StaticCurve instance");
        // And it is NOT the adaptive model that used to stand in for it under a static config.
        assertTrue(r.ydm.codehash != address(refV2).codehash, "ydm must not be the adaptive V2 code");
    }

    /// @notice An AdaptiveCurve_V1 YDM config resolves an actual AdaptiveCurveYDM_V1 instance for both the JT YDM and the LPT LDM
    /// @dev With the shape instance resolved from the config selection, a V1 config resolves the V1 contract and its
    ///      TrancheType + two-share initializeYDMForMarket binds on it, so the deployment succeeds rather than
    ///      reverting against a stand-in V2 instance whose selector the V1 calldata could not match
    function test_AdaptiveV1YdmConfig_DeploysAdaptiveV1Model() external {
        _register();

        DayMarketConfig memory cfg = registry.getDayMarketConfig("snUSD");
        _resolveCollateralOracle(cfg);
        _fundPoolSeed(cfg);
        cfg.accountant.jtYdm.ydmType = YDMType.AdaptiveCurve_V1;
        cfg.accountant.lptYdm.ydmType = YDMType.AdaptiveCurve_V1;
        cfg.accountant.jtYdm.deployed = address(0);
        cfg.accountant.lptYdm.deployed = address(0);
        _resolveYdms(cfg);
        // V1 takes only (target, full), so re-encode both curves as V1 params, a two-word init blob that binds on the V1 model
        bytes memory v1Params = abi.encode(AdaptiveCurveYDM_V1_Params({ yieldShareAtTargetUtilWAD: 0.11e18, yieldShareAtFullUtilWAD: 0.31e18 }));
        cfg.accountant.jtYdm.curveParams = v1Params;
        cfg.accountant.lptYdm.curveParams = v1Params;
        bytes32 marketId = MARKET_ID_A;
        bytes memory p = abi.encode(marketBuilder.buildMarketParams(cfg, marketId, address(factory), DEPLOYER));

        vm.prank(DEPLOYER);
        IRoycoProtocolTemplate.DeploymentResult memory r = factory.executeMarketDeployment(address(template), p);

        // The resolved model is the configured AdaptiveCurveYDM_V1, compared against a reference built with the same target
        AdaptiveCurveYDM_V1 refV1 = new AdaptiveCurveYDM_V1(YDM_TARGET_UTILIZATION_WAD, 0.0001e18, 1e18, (50e18 / uint256(365 days)));
        assertEq(r.ydm.codehash, address(refV1).codehash, "configured AdaptiveCurve_V1, ydm must be AdaptiveCurveYDM_V1");
        assertEq(r.lptYdm.codehash, address(refV1).codehash, "configured AdaptiveCurve_V1, lptYdm must be AdaptiveCurveYDM_V1");
        // One shape resolves to one chain-wide instance, shared by both tranche slots
        assertEq(r.ydm, r.lptYdm, "both slots must share the chain-wide V1 instance");
    }

    /// @notice A Fixed ydmType config deploys the FixedYDM model for both tranche slots and the accountant's init
    ///         call binds the configured fixed share, including through the real template deployment path
    /// @dev The fixed model takes no constructor args, so one reference codehash covers both slots, and the two
    ///      deployed instances must still be distinct addresses because the accountant rejects identical YDMs
    function test_FixedYdmConfig_DeploysFixedModel() external {
        _register();

        DayMarketConfig memory cfg = registry.getDayMarketConfig("snUSD");
        _resolveCollateralOracle(cfg);
        _fundPoolSeed(cfg);
        cfg.accountant.jtYdm.ydmType = YDMType.Fixed;
        cfg.accountant.lptYdm.ydmType = YDMType.Fixed;
        // The fixed model takes only the constant share, so re-encode both curves as Fixed params — a one-word init blob that binds on the fixed model
        cfg.accountant.jtYdm.curveParams = abi.encode(FixedYDMParams({ fixedYieldShareWAD: 0.11e18 }));
        cfg.accountant.lptYdm.curveParams = abi.encode(FixedYDMParams({ fixedYieldShareWAD: 0 }));
        bytes32 marketId = MARKET_ID_A;
        bytes memory p = abi.encode(marketBuilder.buildMarketParams(cfg, marketId, address(factory), DEPLOYER));

        vm.prank(DEPLOYER);
        IRoycoProtocolTemplate.DeploymentResult memory r = factory.executeMarketDeployment(address(template), p);

        // The deployed model is the configured FixedYDM on both slots, at distinct instance addresses
        FixedYDM refFixed = new FixedYDM();
        assertEq(r.ydm.codehash, address(refFixed).codehash, "configured Fixed, ydm must be FixedYDM");
        assertEq(r.lptYdm.codehash, address(refFixed).codehash, "configured Fixed, lptYdm must be FixedYDM");
        assertTrue(r.ydm != r.lptYdm, "the two tranche slots must hold distinct instances");

        // The accountant's init bound the configured shares, zero included: the flag marks both initialized
        (bool jtInitialized, uint64 jtShareWAD) = FixedYDM(r.ydm).accountantToFixedYieldShare(r.accountant);
        (bool lptInitialized, uint64 lptShareWAD) = FixedYDM(r.lptYdm).accountantToFixedYieldShare(r.accountant);
        assertTrue(jtInitialized && lptInitialized, "both slots must be initialized for the market's accountant");
        assertEq(jtShareWAD, 0.11e18, "the JT slot holds the configured fixed share");
        assertEq(lptShareWAD, 0, "the LPT slot holds the configured zero share");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET PARAM VALIDATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev A funded, oracle-resolved param set for MARKET_ID_A, ready for a test to corrupt one field of
    function _validParams() internal returns (RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory) {
        DayMarketConfig memory cfg = registry.getDayMarketConfig("snUSD");
        _resolveCollateralOracle(cfg);
        _fundPoolSeed(cfg);
        return marketBuilder.buildMarketParams(cfg, MARKET_ID_A, address(factory), DEPLOYER);
    }

    /// @dev Runs a deployment expected to revert with `_err` from the params validation
    /// @dev Partial matching: several of these errors carry the offending address or role id, and the point of each
    ///      test is which check fired, not the argument it echoed back
    function _expectParamsRevert(RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory _params, bytes4 _err) internal {
        _register();
        vm.prank(DEPLOYER);
        vm.expectPartialRevert(_err);
        factory.executeMarketDeployment(address(template), abi.encode(_params));
    }

    /// The market's two assets must both be live contracts and must be distinct, else the pool is not a two-token pool
    function test_RevertIf_CollateralAssetIsNull() external {
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory p = _validParams();
        p.collateralAsset = address(0);
        _expectParamsRevert(p, MarketDeploymentValidationLogic.NULL_MARKET_PARAMETER.selector);
    }

    function test_RevertIf_QuoteAssetHasNoCode() external {
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory p = _validParams();
        p.quoteAsset = makeAddr("NOT_A_TOKEN");
        _expectParamsRevert(p, MarketDeploymentValidationLogic.MARKET_PARAMETER_HAS_NO_CODE.selector);
    }

    function test_RevertIf_CollateralAndQuoteAssetAreIdentical() external {
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory p = _validParams();
        p.quoteAsset = p.collateralAsset;
        _expectParamsRevert(p, MarketDeploymentValidationLogic.COLLATERAL_AND_QUOTE_ASSET_IDENTICAL.selector);
    }

    function test_RevertIf_CollateralAssetOracleHasNoCode() external {
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory p = _validParams();
        p.collateralAssetOracle = makeAddr("NOT_AN_ORACLE");
        _expectParamsRevert(p, MarketDeploymentValidationLogic.MARKET_PARAMETER_HAS_NO_CODE.selector);
    }

    /// A null sequencer feed is the documented "not an L2" case, but a non-null one must be a live contract
    function test_RevertIf_SequencerUptimeFeedHasNoCode() external {
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory p = _validParams();
        p.sequencerUptimeFeed = makeAddr("NOT_A_FEED");
        p.gracePeriodSeconds = 1 hours;
        _expectParamsRevert(p, MarketDeploymentValidationLogic.MARKET_PARAMETER_HAS_NO_CODE.selector);
    }

    /// Same rule for the quote leg's rate provider, which becomes a live `IRateProvider` on the pool
    function test_RevertIf_QuoteAssetRateProviderHasNoCode() external {
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory p = _validParams();
        p.poolCreationParams.quoteAssetRateProvider = makeAddr("NOT_A_RATE_PROVIDER");
        _expectParamsRevert(p, MarketDeploymentValidationLogic.MARKET_PARAMETER_HAS_NO_CODE.selector);
    }


    function test_RevertIf_TrancheNameIsEmpty() external {
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory p = _validParams();
        p.jtParams.name = "";
        _expectParamsRevert(p, MarketDeploymentValidationLogic.EMPTY_TRANCHE_NAME_OR_SYMBOL.selector);
    }

    /// The genesis seed's quote leg is mandatory, and is now rejected up front rather than after the market is built
    function test_RevertIf_PoolSeedQuoteAmountIsZero() external {
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory p = _validParams();
        p.poolInitializationParams.quoteAmount = 0;
        _expectParamsRevert(p, MarketDeploymentValidationLogic.POOL_SEED_REQUIRED.selector);
    }

    /// Each tranche selects its model shape by name, and the empty name is never a registered shape
    function test_RevertIf_YdmTypeIsEmpty() external {
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory p = _validParams();
        p.lptYdmType = "";
        _expectParamsRevert(p, MarketDeploymentValidationLogic.EMPTY_YDM_TYPE.selector);
    }

    /// Each model instance decodes its own initialization blob, so an empty one can never initialize it
    function test_RevertIf_YdmInitializationDataIsEmpty() external {
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory p = _validParams();
        p.accountantParams.jtYDMInitializationData = "";
        _expectParamsRevert(p, MarketDeploymentValidationLogic.EMPTY_YDM_INITIALIZATION_DATA.selector);
    }

    /// The pool token is a live ERC20 in its own right
    function test_RevertIf_PoolSymbolIsEmpty() external {
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory p = _validParams();
        p.poolCreationParams.symbol = "";
        _expectParamsRevert(p, MarketDeploymentValidationLogic.EMPTY_POOL_NAME_OR_SYMBOL.selector);
    }


    /// An inverted E-CLP price range is not an interval, and would produce a nonsensical curve
    function test_RevertIf_EclpPriceRangeIsInverted() external {
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory p = _validParams();
        (p.poolCreationParams.eclpParams.alpha, p.poolCreationParams.eclpParams.beta) =
        (p.poolCreationParams.eclpParams.beta, p.poolCreationParams.eclpParams.alpha);
        _expectParamsRevert(p, MarketDeploymentValidationLogic.INVALID_ECLP_PRICE_RANGE.selector);
    }


    /// Coverage must demand less than the whole senior exposure
    function test_RevertIf_MinCoverageIsNotBelowWad() external {
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory p = _validParams();
        p.accountantParams.minCoverageWAD = uint64(1e18);
        _expectParamsRevert(p, MarketDeploymentValidationLogic.INVALID_ACCOUNTANT_CONFIG.selector);
    }

    /// Both premiums are carved out of senior appreciation, so together they cannot exceed it
    function test_RevertIf_MaxYieldSharesSumAboveWad() external {
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory p = _validParams();
        p.accountantParams.maxJTYieldShareWAD = uint64(1e18);
        p.accountantParams.maxLPTYieldShareWAD = 1;
        _expectParamsRevert(p, MarketDeploymentValidationLogic.INVALID_ACCOUNTANT_CONFIG.selector);
    }

    /**
     * @notice The seed is the market's first deposit, so its junior tranche is empty. A collateral leg mints senior
     *         shares against that empty junior, which breaches any nonzero coverage floor deep inside the accounting
     *         sync — this rejects it up front with a message that says what is actually wrong
     */
    function test_RevertIf_CollateralSeedOnAMarketWithACoverageFloor() external {
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory p = _validParams();
        p.poolInitializationParams.collateralAmount = 1e18;
        p.accountantParams.minCoverageWAD = 0.1e18;
        _expectParamsRevert(p, MarketDeploymentValidationLogic.COLLATERAL_SEED_REQUIRES_ZERO_MIN_COVERAGE.selector);
    }

    /// The whole point of validating up front: a rejected deployment must leave no component behind, and must not
    /// consume any AccessManager target's one-time `wasEverConfigured` freshness
    function test_ParamsValidation_RunsBeforeAnyComponentIsDeployed() external {
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory p = _validParams();
        p.collateralAsset = address(0);

        address predictedST = factory.predictDeterministicAddress(keccak256(abi.encodePacked("ROYCO_MARKET_", MARKET_ID_A, TAG_ST_PROXY)));
        _expectParamsRevert(p, MarketDeploymentValidationLogic.NULL_MARKET_PARAMETER.selector);
        assertEq(predictedST.code.length, 0, "a rejected deployment must not have deployed the senior tranche");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEMPLATE CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev A fee set with one field raised, for the bound tests
    function _feeConfig(uint64 _st) internal pure returns (BaseDeploymentTemplate.ProtocolFeeConfig memory) {
        return BaseDeploymentTemplate.ProtocolFeeConfig({
            stProtocolFeeWAD: _st, jtProtocolFeeWAD: 0, jtYieldShareProtocolFeeWAD: 0, lptYieldShareProtocolFeeWAD: 0
        });
    }

    /// The fees and the recipient are protocol policy, so the deployer cannot express them and the market inherits
    /// exactly what the template holds
    function test_ExecuteMarketDeployment_MarketInheritsTheTemplatesFeePolicy() external {
        _register();
        IRoycoProtocolTemplate.DeploymentResult memory r = _deploy(MARKET_ID_A);

        (uint64 st, uint64 jt, uint64 jtYield, uint64 lptYield) = template.protocolFeeConfig();
        IRoycoDayAccountant.RoycoDayAccountantState memory a = IRoycoDayAccountant(r.accountant).getState();
        assertEq(a.stProtocolFeeWAD, st, "senior fee must come from the template");
        assertEq(a.jtProtocolFeeWAD, jt, "junior fee must come from the template");
        assertEq(a.jtYieldShareProtocolFeeWAD, jtYield, "junior yield-share fee must come from the template");
        assertEq(a.lptYieldShareProtocolFeeWAD, lptYield, "liquidity yield-share fee must come from the template");
        assertEq(
            IRoycoDayKernel(r.kernel).getState().protocolFeeRecipient, template.protocolFeeRecipient(), "recipient must come from the template"
        );
    }

    /**
     * @notice A config change binds FUTURE markets only. A live market holds its own copy, retuned through the
     *         accountant's own setters — this is the property operators are most likely to assume wrongly
     */
    function test_SetProtocolFeeConfig_BindsFutureMarketsOnly() external {
        _register();
        IRoycoProtocolTemplate.DeploymentResult memory first = _deploy(MARKET_ID_A);
        uint64 originalFee = IRoycoDayAccountant(first.accountant).getState().stProtocolFeeWAD;

        vm.prank(FACTORY_ADMIN);
        template.setProtocolFeeConfig(_feeConfig(0.42e18));

        IRoycoProtocolTemplate.DeploymentResult memory second = _deploy(MARKET_ID_B);

        assertEq(IRoycoDayAccountant(first.accountant).getState().stProtocolFeeWAD, originalFee, "the live market must be untouched");
        assertEq(IRoycoDayAccountant(second.accountant).getState().stProtocolFeeWAD, 0.42e18, "the new market must take the new fee");
    }

    /// Each configuration setter is admin-only: a market deployer needs no role at all, never the config surface
    function test_RevertIf_ConfigSettersCalledByNonAdmin() external {
        // Read the pool config BEFORE pranking: a view call would otherwise consume the prank before the setter runs
        RoycoDayBalancerV3MarketDeploymentTemplate.BalancerPoolConfig memory poolConfig = _templateBalancerPoolConfig();

        vm.prank(DEPLOYER);
        vm.expectPartialRevert(IAccessManaged.AccessManagedUnauthorized.selector);
        template.setProtocolFeeConfig(_feeConfig(0));

        vm.prank(DEPLOYER);
        vm.expectPartialRevert(IAccessManaged.AccessManagedUnauthorized.selector);
        template.setProtocolFeeRecipient(makeAddr("HIJACKED"));

        vm.prank(DEPLOYER);
        vm.expectPartialRevert(IAccessManaged.AccessManagedUnauthorized.selector);
        template.setBalancerPoolConfig(poolConfig);
    }

    /// A protocol fee above 100% is refused, matching the bound the accountant itself enforces
    function test_RevertIf_ProtocolFeeConfigExceedsTheMaximum() external {
        vm.expectRevert(BaseDeploymentTemplate.INVALID_PROTOCOL_FEE_CONFIG.selector);
        vm.prank(FACTORY_ADMIN);
        template.setProtocolFeeConfig(_feeConfig(uint64(1e18) + 1));
    }

    /// The recipient can never be nulled: the kernel's own initializer would reject it, and a live market would have
    /// nowhere to send its fee shares
    function test_RevertIf_ProtocolFeeRecipientSetToNull() external {
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        vm.prank(FACTORY_ADMIN);
        template.setProtocolFeeRecipient(address(0));
    }

    /// The swap fee is held to Gyro's own band. Below it, Balancer would reject the pool mid-deployment and every
    /// market this template deploys would fail, so the floor belongs at configuration time
    function test_RevertIf_SwapFeeOutsideGyrosBand() external {
        RoycoDayBalancerV3MarketDeploymentTemplate.BalancerPoolConfig memory tooLow = _templateBalancerPoolConfig();
        tooLow.swapFeePercentage = 1e12 - 1;
        vm.expectPartialRevert(RoycoDayBalancerV3MarketDeploymentTemplate.INVALID_SWAP_FEE.selector);
        vm.prank(FACTORY_ADMIN);
        template.setBalancerPoolConfig(tooLow);

        RoycoDayBalancerV3MarketDeploymentTemplate.BalancerPoolConfig memory tooHigh = _templateBalancerPoolConfig();
        tooHigh.swapFeePercentage = uint64(1e18) + 1;
        vm.expectPartialRevert(RoycoDayBalancerV3MarketDeploymentTemplate.INVALID_SWAP_FEE.selector);
        vm.prank(FACTORY_ADMIN);
        template.setBalancerPoolConfig(tooHigh);
    }

    /// The constructor runs the same validator as the setter, so a template can never be born out of bounds
    function test_RevertIf_TemplateConstructedWithAnInvalidFeeConfig() external {
        RoycoDayBalancerV3MarketDeploymentTemplate.TemplateConstructionParams memory cp = _templateConstructionParams();
        cp.protocolFeeConfig = _feeConfig(uint64(1e18) + 1);
        vm.expectRevert(BaseDeploymentTemplate.INVALID_PROTOCOL_FEE_CONFIG.selector);
        new RoycoDayBalancerV3MarketDeploymentTemplate(cp);
    }

    /// @notice Balancer refuses a leg that pays yield fees with no rate provider to measure them against. The flag is
    ///         template policy and the rate provider is the deployer's, so the clash is caught before anything deploys
    ///         rather than inside pool creation, which runs after the senior tranche proxy already exists
    function test_RevertIf_QuoteYieldFeeChargedWithoutAQuoteRateProvider() external {
        RoycoDayBalancerV3MarketDeploymentTemplate.BalancerPoolConfig memory cfg = _templateBalancerPoolConfig();
        cfg.chargeYieldFeeOnQuoteAsset = true;
        vm.prank(FACTORY_ADMIN);
        template.setBalancerPoolConfig(cfg);

        // The snUSD config leaves the quote leg's rate provider null, so the pool policy and the market disagree
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory p = _validParams();
        assertEq(p.poolCreationParams.quoteAssetRateProvider, address(0), "this market must supply no quote rate provider");
        _expectParamsRevert(p, MarketDeploymentValidationLogic.QUOTE_RATE_PROVIDER_REQUIRED_FOR_YIELD_FEE.selector);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BLACKLIST
    // ═══════════════════════════════════════════════════════════════════════════

    /// The blacklist is the template's, not the market's: every market it deploys reads back exactly the pinned one
    function test_ExecuteMarketDeployment_KernelReadsBackTheTemplatesBlacklist() external {
        _register();
        IRoycoProtocolTemplate.DeploymentResult memory r = _deploy(MARKET_ID_A);
        assertEq(template.ROYCO_BLACKLIST(), roycoBlacklist, "the template must pin the blacklist it was constructed with");
        assertEq(IRoycoDayKernel(r.kernel).getState().roycoBlacklist, roycoBlacklist, "the market's kernel must screen against the template's blacklist");
    }

    /// Screening is mandatory: a template cannot be constructed without a blacklist, so no market can opt out of it
    function test_RevertIf_TemplateConstructedWithNullBlacklist() external {
        RoycoDayBalancerV3MarketDeploymentTemplate.TemplateConstructionParams memory cp = _templateConstructionParams();
        cp.roycoBlacklist = address(0);
        vm.expectRevert(RoycoDayBalancerV3MarketDeploymentTemplate.NULL_CONSTRUCTION_PARAMETER.selector);
        new RoycoDayBalancerV3MarketDeploymentTemplate(cp);
    }

    /// An EOA passes the non-null check but could never screen anything, so it is rejected separately
    function test_RevertIf_TemplateConstructedWithCodelessBlacklist() external {
        RoycoDayBalancerV3MarketDeploymentTemplate.TemplateConstructionParams memory cp = _templateConstructionParams();
        cp.roycoBlacklist = makeAddr("NOT_A_BLACKLIST");
        vm.expectRevert(abi.encodeWithSelector(RoycoDayBalancerV3MarketDeploymentTemplate.CONSTRUCTION_PARAMETER_HAS_NO_CODE.selector, cp.roycoBlacklist));
        new RoycoDayBalancerV3MarketDeploymentTemplate(cp);
    }

    // ─── internal ───

    /// @dev The chain-wide construction params read off the known-good template from `setUp`, for a construction test
    ///      to corrupt one field of
    function _templateConstructionParams() internal view returns (RoycoDayBalancerV3MarketDeploymentTemplate.TemplateConstructionParams memory) {
        return RoycoDayBalancerV3MarketDeploymentTemplate.TemplateConstructionParams({
            factory: IRoycoFactory(address(factory)),
            balancerV3PoolFactory: template.BALANCER_V3_POOL_FACTORY(),
            eclpLPOracleFactory: template.ECLP_LP_ORACLE_FACTORY(),
            bptOracleConstantPriceFeed: template.BPT_ORACLE_CONSTANT_PRICE_FEED(),
            roycoBlacklist: template.ROYCO_BLACKLIST(),
            seniorTrancheBeacon: template.SENIOR_TRANCHE_BEACON(),
            juniorTrancheBeacon: template.JUNIOR_TRANCHE_BEACON(),
            liquidityProviderTrancheBeacon: template.LIQUIDITY_PROVIDER_TRANCHE_BEACON(),
            kernelBeacon: template.KERNEL_BEACON(),
            accountantBeacon: template.ACCOUNTANT_BEACON(),
            protocolFeeConfig: _templateProtocolFeeConfig(),
            protocolFeeRecipient: template.protocolFeeRecipient(),
            balancerPoolConfig: _templateBalancerPoolConfig()
        });
    }

    /// @dev The live template's fee set, read back through its auto-getter
    function _templateProtocolFeeConfig() internal view returns (BaseDeploymentTemplate.ProtocolFeeConfig memory) {
        (uint64 st, uint64 jt, uint64 jtYield, uint64 lptYield) = template.protocolFeeConfig();
        return BaseDeploymentTemplate.ProtocolFeeConfig({
            stProtocolFeeWAD: st, jtProtocolFeeWAD: jt, jtYieldShareProtocolFeeWAD: jtYield, lptYieldShareProtocolFeeWAD: lptYield
        });
    }

    /// @dev The live template's pool policy, read back through its auto-getter
    function _templateBalancerPoolConfig() internal view returns (RoycoDayBalancerV3MarketDeploymentTemplate.BalancerPoolConfig memory) {
        (uint64 swapFee, bool chargeSenior, bool chargeQuote) = template.balancerPoolConfig();
        return RoycoDayBalancerV3MarketDeploymentTemplate.BalancerPoolConfig({
            swapFeePercentage: swapFee, chargeYieldFeeOnSeniorTrancheShares: chargeSenior, chargeYieldFeeOnQuoteAsset: chargeQuote
        });
    }

    function _emptyResult() internal pure returns (IRoycoProtocolTemplate.DeploymentResult memory r) {
        r; // zero-initialized; only used for event topic matching (data not checked)
    }
    /// @dev Deploys the config's ERC4626 share-price adapter with its per-hop staleness immutable, as the script does
    function _newErc4626Oracle(address _collateral, bytes memory _oracleParams) internal returns (ERC4626SharePriceOracle) {
        ERC4626SharePriceOracleParams memory op = abi.decode(_oracleParams, (ERC4626SharePriceOracleParams));
        return new ERC4626SharePriceOracle(
            _collateral,
            op.baseAssetToNavAssetFeed,
            op.minDeviationWAD,
            op.lastUpdate,
            op.chainlinkOracleStalenessThresholdSeconds,
            op.vaultSharePriceStalenessThresholdSeconds
        );
    }

}
