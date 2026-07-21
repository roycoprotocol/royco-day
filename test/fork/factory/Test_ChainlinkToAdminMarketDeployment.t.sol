// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ILPOracleBase } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/oracles/ILPOracleBase.sol";
import { ILPOracleFactoryBase } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/oracles/ILPOracleFactoryBase.sol";
import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { TokenInfo, TokenType } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { LPOracleBase } from "../../../lib/balancer-v3-monorepo/pkg/oracles/contracts/LPOracleBase.sol";
import { GyroECLPPoolFactory } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { Test } from "../../../lib/forge-std/src/Test.sol";
import { AccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { RoycoMarketSyncer } from "../../../lib/royco-periphery/src/syncer/RoycoMarketSyncer.sol";
import { DeployScript } from "../../../script/Deploy.s.sol";
import {
    DeploymentResult,
    IdenticalAssets_ST_JT_ChainlinkToAdminOracle_QuoterKernelParams,
    KernelType,
    MarketConfig
} from "../../../script/config/DeploymentTypes.sol";
import { RoycoDayEntryPoint } from "../../../src/entrypoint/RoycoDayEntryPoint.sol";
import { ADMIN_ENTRY_POINT_ROLE, ADMIN_FACTORY_ROLE, ADMIN_ORACLE_QUOTER_ROLE, ADMIN_ROLE, DEPLOYER_ROLE, SYNC_ROLE } from "../../../src/factory/Roles.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";
import {
    Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3GyroECLP_LT_DeploymentTemplate
} from "../../../src/factory/templates/Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3GyroECLP_LT_DeploymentTemplate.sol";
import { BalancerV3_GyroECLP_LT_DeploymentTemplate } from "../../../src/factory/templates/liquidity-tranche/BalancerV3_GyroECLP_LT_DeploymentTemplate.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoFactory } from "../../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import {
    Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3_BPTOracle_LT_Kernel
} from "../../../src/kernels/Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3_BPTOracle_LT_Kernel.sol";
import {
    IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter
} from "../../../src/kernels/base/quoter/identical-st-jt/IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter.sol";
import { BalancerV3_LT_BPTOracle_Quoter } from "../../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_BPTOracle_Quoter.sol";

/// @title Test_ChainlinkToAdminMarketDeployment
/// @notice Fork test for the REAL Chainlink-to-admin Day template
///         (`Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3GyroECLP_LT_DeploymentTemplate`), modeled on
///         Test_RoycoFactory's direct-template pattern. Covers the deltas the golden ERC4626 suite cannot: this
///         kernel family's init params threading (including the mandatory nonzero admin rate), the BPT oracle
///         injection, the ST/JT quoter selector role bindings, and the senior pool leg's kernel rate provider.
/// @dev Reuses the snUSD asset + RedStone feed addresses: the CTA kernel accepts any identical ST/JT ERC20 pair,
///      and the feed is uncalled at deploy. Requires a mainnet fork. FAILS (env not found) when `MAINNET_RPC_URL`
///      is unset, instead of silently passing.
contract Test_ChainlinkToAdminMarketDeployment is Test {
    uint256 internal constant FORK_BLOCK = 25_400_000;
    address internal constant GYRO_ECLP_POOL_FACTORY = 0x04d584195a96DFfc7F8B695aA3C9D3c1606b69d1;
    address internal constant ECLP_LP_ORACLE_FACTORY = 0x301EDe5Fd4f9d7266B09c3A2E38F97776447154B;
    address internal constant NUSD_REDSTONE_ORACLE = 0x5e7281f74e74D76347f0b8f4a36Fd3cb29c19d95; // tranche asset->reference feed (uncalled at deploy)

    /// @dev The nonzero admin rate the CTA family mandates at initialization (0 is the rejected sentinel)
    uint256 internal constant INITIAL_ADMIN_RATE_WAD = 1e18;

    AccessManager internal am;
    RoycoFactory internal factory;
    DeployScript internal deployScript;
    Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3GyroECLP_LT_DeploymentTemplate internal template;
    IRoycoDayEntryPoint internal entryPoint;
    RoycoMarketSyncer internal syncer;

    address internal FACTORY_ADMIN = makeAddr("FACTORY_ADMIN");
    address internal DEPLOYER = makeAddr("DEPLOYER");
    address internal PROTOCOL_FEE_RECIPIENT = makeAddr("PROTOCOL_FEE_RECIPIENT");

    /// @dev Pre-mined marketId whose senior-tranche CREATE3 proxy sorts below the quote asset (ST is pool token0) for
    ///      this suite's deterministic `factory`; the deployment path asserts that ordering. Mined via script/mine-market-id.
    bytes32 internal constant MARKET_ID = 0x7537556461b25c033e9fe151342e829a6439dc9c0f467afe0667ee9235315cae;

    function setUp() public {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(rpc, FORK_BLOCK);

        // This test contract is the AccessManager admin (ADMIN_ROLE).
        am = new AccessManager(address(this));

        // OZ mandates init data in the ERC1967Proxy constructor, and `initialize` requires the factory to already
        // hold ADMIN_ROLE on the AM. So deploy the proxy via CREATE2: predict the salted address, grant it
        // ADMIN_ROLE, then construct the proxy with real init data. (A salt-based prediction is nonce-independent,
        // the golden suite's CREATE-nonce prediction drifts after createSelectFork on current foundry.)
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

        // The real Chainlink-to-admin Day template, bound to this factory. `deployScript` externally deploys each
        // market's impls/YDMs/pool and pre-deploys its ST + hook proxies (`deployMarketContractsForTest`), then builds
        // the template params (`buildDayParams`). Its nested `deployDeterministicProxy` calls run with
        // `msg.sender == address(deployScript)`, so the deployScript must hold DEPLOYER_ROLE.
        deployScript = new DeployScript();
        am.grantRole(DEPLOYER_ROLE, address(deployScript), 0);
        template = new Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3GyroECLP_LT_DeploymentTemplate(
            IRoycoFactory(address(factory)),
            GyroECLPPoolFactory(GYRO_ECLP_POOL_FACTORY),
            address(entryPoint),
            address(syncer)
        );
    }

    // ─── helpers ───

    function _register() internal {
        vm.prank(FACTORY_ADMIN);
        factory.registerTemplate(address(template));
    }

    /// @dev Clones the snUSD market config in memory and swaps in the CTA kernel type + params blob. No config
    ///      file entry exists for this kernel yet, so the test IS the params source (MarketDeploymentConfig untouched).
    function _marketConfig() internal view returns (MarketConfig memory cfg) {
        cfg = deployScript.getMarketConfig("snUSD");
        cfg.kernelType = KernelType.Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3_BPTOracle_LT_Kernel;
        cfg.kernelSpecificParams = abi.encode(
            IdenticalAssets_ST_JT_ChainlinkToAdminOracle_QuoterKernelParams({
                stAndJTQuoterParams: IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter.ST_JT_QuoterSpecificParams({
                    // The CTA family mandates an admin set reference->NAV rate, the zero sentinel is rejected
                    initialConversionRateWAD: INITIAL_ADMIN_RATE_WAD,
                    trancheAssetToReferenceAssetOracle: NUSD_REDSTONE_ORACLE,
                    gracePeriodSeconds: 0,
                    // Ethereum mainnet has no L2 sequencer, so the sequencer-uptime check is disabled
                    sequencerUptimeFeed: address(0),
                    stalenessThresholdSeconds: 48 hours
                }),
                ltQuoterParams: BalancerV3_LT_BPTOracle_Quoter.LT_QuoterSpecificParams({
                    bptOracle: address(0), // deployed by the template after the pool is created, overwritten by it
                    maxReinvestmentSlippageWAD: 0.001e18
                })
            })
        );
    }

    function _deploy(bytes32 _marketId) internal returns (IRoycoProtocolTemplate.DeploymentResult memory) {
        // Precompute the params first: the builders externally deploy the market contracts as `deployScript`, which
        // would otherwise consume the `vm.prank(DEPLOYER)` intended for `executeMarketDeployment`.
        bytes32 marketId = _marketId;
        MarketConfig memory cfg = _marketConfig();
        BalancerV3_GyroECLP_LT_DeploymentTemplate.MarketContracts memory mc =
            deployScript.deployMarketContractsForTest(cfg, marketId, factory, address(template), address(am));
        bytes memory p = abi.encode(deployScript.buildDayParams(cfg, marketId, PROTOCOL_FEE_RECIPIENT, address(0), mc));
        vm.prank(DEPLOYER);
        return factory.executeMarketDeployment(address(template), p);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT WIRING (the CTA-specific deltas)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The template threads this kernel family's init params (pinning the mandatory admin rate), injects
    ///         its template-deployed BPT oracle into the kernel quoter, binds the ST/JT quoter admin selectors to
    ///         ADMIN_ORACLE_QUOTER_ROLE, and prices the senior pool leg via the kernel
    function test_ExecuteMarketDeployment_ChainlinkToAdminKernelWiring() external {
        _register();
        IRoycoProtocolTemplate.DeploymentResult memory r = _deploy(MARKET_ID);

        // The kernel initialized with the configured admin rate (this family's init path, not the golden's).
        assertEq(
            Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3_BPTOracle_LT_Kernel(r.kernel).getStoredConversionRateWAD(),
            INITIAL_ADMIN_RATE_WAD,
            "stored admin rate != configured"
        );

        // The template deployed the BPT oracle through Balancer's E-CLP LP oracle factory and injected it into the
        // kernel quoter, overwriting the null placeholder in the params blob.
        address pool = IRoycoDayKernel(r.kernel).LT_ASSET();
        address bptOracle = BalancerV3_LT_BPTOracle_Quoter(r.kernel).getBalancerV3QuoterState().bptOracle;
        assertTrue(bptOracle != address(0), "bptOracle unset");
        assertGt(bptOracle.code.length, 0, "bptOracle has no code");
        assertTrue(ILPOracleFactoryBase(ECLP_LP_ORACLE_FACTORY).isOracleFromFactory(ILPOracleBase(bptOracle)), "not from oracle factory");
        assertEq(address(LPOracleBase(bptOracle).pool()), pool, "oracle.pool() != market pool");

        // The three ST/JT quoter admin selectors resolve to ADMIN_ORACLE_QUOTER_ROLE on the market AM.
        assertEq(am.getTargetFunctionRole(r.kernel, bytes4(keccak256("setConversionRate(uint256,bool)"))), ADMIN_ORACLE_QUOTER_ROLE, "setConversionRate role");
        assertEq(
            am.getTargetFunctionRole(r.kernel, bytes4(keccak256("setChainlinkOracle(address,uint48,bool)"))),
            ADMIN_ORACLE_QUOTER_ROLE,
            "setChainlinkOracle role"
        );
        assertEq(
            am.getTargetFunctionRole(r.kernel, bytes4(keccak256("setSequencerUptimeFeed(address,uint48)"))),
            ADMIN_ORACLE_QUOTER_ROLE,
            "setSequencerUptimeFeed role"
        );

        // The senior pool leg is WITH_RATE priced by the kernel and the quote leg is STANDARD.
        IVault vault = IVault(address(GyroECLPPoolFactory(GYRO_ECLP_POOL_FACTORY).getVault()));
        (IERC20[] memory tokens, TokenInfo[] memory info,,) = vault.getPoolTokenInfo(pool);
        assertEq(tokens.length, 2, "pool token count");
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (address(tokens[i]) == r.seniorTranche) {
                assertTrue(info[i].tokenType == TokenType.WITH_RATE, "senior leg not WITH_RATE");
                assertEq(address(info[i].rateProvider), r.kernel, "senior rate provider != kernel");
            } else {
                assertTrue(info[i].tokenType == TokenType.STANDARD, "quote leg not STANDARD");
                assertEq(address(info[i].rateProvider), address(0), "quote leg has a rate provider");
            }
        }
    }
}
