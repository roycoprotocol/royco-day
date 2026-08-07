// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IGyroECLPPool } from "../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/pool-gyro/IGyroECLPPool.sol";
import { Test } from "../../lib/forge-std/src/Test.sol";
import { Vm } from "../../lib/forge-std/src/Vm.sol";
import { AccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { ChainDeployment, DeploymentResult, MarketUpstream, RoleAssignmentAddresses, TemplatePolicy } from "../../script/config/DeploymentTypes.sol";
import { BootstrapChainComponent } from "../../script/deploy/BootstrapChain.s.sol";
import { RenounceDeployerRolesComponent } from "../../script/deploy/core/RenounceDeployerRoles.s.sol";
import { DayMarketRegistry } from "../../script/deploy/templates/royco-day-balancer-v3/DayMarketRegistry.sol";
import { DayMarketConfig } from "../../script/deploy/templates/royco-day-balancer-v3/DayMarketTypes.sol";
import { DeployMarketComponent } from "../../script/deploy/templates/royco-day-balancer-v3/DeployMarket.s.sol";
import { ADMIN_UNPAUSER_ROLE, JT_LP_ROLE, LP_ROLE_ADMIN_ROLE, ST_LP_ROLE } from "../../src/factory/Roles.sol";
import { RoycoFactory } from "../../src/factory/RoycoFactory.sol";
import { IRoycoBlacklist } from "../../src/interfaces/IRoycoBlacklist.sol";
import { IRoycoDayAccountant } from "../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../src/interfaces/IRoycoVaultTranche.sol";
import { IYDM } from "../../src/interfaces/IYDM.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits } from "../../src/libraries/Units.sol";
import { Assertions } from "./Assertions.sol";

abstract contract RoycoDayTestBase is Test, Assertions {
    struct TrancheState {
        NAV_UNIT rawNAV;
        NAV_UNIT effectiveNAV;
        TRANCHE_UNIT stAssetsClaim;
        TRANCHE_UNIT jtAssetsClaim;
        NAV_UNIT protocolFeeValue;
        uint256 totalShares;
    }

    // -----------------------------------------
    // Test Wallets
    // -----------------------------------------
    Vm.Wallet internal OWNER;
    address internal OWNER_ADDRESS;

    // Role-specific wallets
    Vm.Wallet internal PAUSER;
    address internal PAUSER_ADDRESS;

    Vm.Wallet internal UNPAUSER;
    address internal UNPAUSER_ADDRESS;

    Vm.Wallet internal UPGRADER;
    address internal UPGRADER_ADDRESS;

    Vm.Wallet internal SYNC_ROLE_HOLDER;
    address internal SYNC_ROLE_ADDRESS;

    Vm.Wallet internal KERNEL_ADMIN;
    address internal KERNEL_ADMIN_ADDRESS;

    Vm.Wallet internal ACCOUNTANT_ADMIN;
    address internal ACCOUNTANT_ADMIN_ADDRESS;

    Vm.Wallet internal PROTOCOL_FEE_SETTER;
    address internal PROTOCOL_FEE_SETTER_ADDRESS;

    Vm.Wallet internal ORACLE_ADMIN;
    address internal ORACLE_ADMIN_ADDRESS;

    /// @dev The FNDN-style emergency oracle seat: co-holds ADMIN_ORACLE_ROLE at delay 0 beside ORACLE_ADMIN's
    ///      delayed parameter path. A DISTINCT wallet: granting both seats to one account would hit OZ AM's
    ///      delay-decrease timelock and leave the second grant at the first grant's delay
    Vm.Wallet internal ORACLE_EMERGENCY_ADMIN;
    address internal ORACLE_EMERGENCY_ADMIN_ADDRESS;

    Vm.Wallet internal MARKET_REINVEST_LIQUIDITY_PREMIUM_ADMIN;
    address internal MARKET_REINVEST_LIQUIDITY_PREMIUM_ADMIN_ADDRESS;

    Vm.Wallet internal LP_ROLE_ADMIN;
    address internal LP_ROLE_ADMIN_ADDRESS;

    Vm.Wallet internal ROLE_GUARDIAN;
    address internal ROLE_GUARDIAN_ADDRESS;

    Vm.Wallet internal PROTOCOL_FEE_RECIPIENT;
    address internal PROTOCOL_FEE_RECIPIENT_ADDRESS;

    Vm.Wallet internal DEPLOYER;
    address internal DEPLOYER_ADDRESS;

    Vm.Wallet internal DEPLOYER_ADMIN;
    address internal DEPLOYER_ADMIN_ADDRESS;

    // ST-only providers
    Vm.Wallet internal ST_ALICE;
    Vm.Wallet internal ST_BOB;
    Vm.Wallet internal ST_CHARLIE;
    Vm.Wallet internal ST_DAN;
    address internal ST_ALICE_ADDRESS;
    address internal ST_BOB_ADDRESS;
    address internal ST_CHARLIE_ADDRESS;
    address internal ST_DAN_ADDRESS;

    // JT-only providers
    Vm.Wallet internal JT_ALICE;
    Vm.Wallet internal JT_BOB;
    Vm.Wallet internal JT_CHARLIE;
    Vm.Wallet internal JT_DAN;
    address internal JT_ALICE_ADDRESS;
    address internal JT_BOB_ADDRESS;
    address internal JT_CHARLIE_ADDRESS;
    address internal JT_DAN_ADDRESS;

    address[] internal providers;

    // -----------------------------------------
    // Royco Deployments
    // -----------------------------------------

    // Deployment pipeline components (simulation-only instances; each broadcasts as the fixture's DEPLOYER)
    BootstrapChainComponent internal BOOTSTRAP;
    DayMarketRegistry internal MARKET_REGISTRY;
    ChainDeployment internal CHAIN;

    // Deployments
    RoycoFactory internal FACTORY;
    AccessManager internal ACCESS_MANAGER;
    IYDM internal YDM;
    IRoycoVaultTranche internal ST;
    IRoycoVaultTranche internal JT;
    IRoycoDayKernel internal KERNEL;
    IRoycoDayAccountant internal ACCOUNTANT;
    IRoycoBlacklist internal BLACKLIST;

    // -----------------------------------------
    // Royco Deployments Parameters
    // -----------------------------------------

    string internal SENIOR_TRANCHE_NAME = "Royco Senior Tranche";
    string internal SENIOR_TRANCHE_SYMBOL = "RST";
    string internal JUNIOR_TRANCHE_NAME = "Royco Junior Tranche";
    string internal JUNIOR_TRANCHE_SYMBOL = "RJT";
    uint64 internal COVERAGE_WAD = 0.2e18; // 20% coverage
    uint64 internal ST_PROTOCOL_FEE_WAD = 0.1e18; // 10% protocol fee
    uint64 internal JT_PROTOCOL_FEE_WAD = 0.1e18; // 10% protocol fee
    /**
     * @dev Liquidation coverage utilization threshold. Derivation at this fixture's 20% minimum coverage:
     *      coverage utilization is collateralNAV x minCoverage / jtEffectiveNAV. At 6.4667e18
     *      liquidation arms only once the junior buffer covers less than
     *      ~3.09% (0.2e18 / 6.4667e18) of total exposure, a near-total JT wipeout, far above any utilization
     *      a healthy seeded state in this suite reads
     */
    uint256 internal LIQUIDATION_COVERAGE_UTILIZATION_WAD = 6.4667e18;
    uint24 internal FIXED_TERM_DURATION_SECONDS = 2 weeks; // 2 weeks in seconds
    NAV_UNIT internal DUST_TOLERANCE = toNAVUnits(uint256(1));

    modifier prankModifier(address _pranker) {
        vm.startPrank(_pranker);
        _;
        vm.stopPrank();
    }

    function _setUpRoyco() internal virtual {
        _setupFork();
        _setupWallets();

        // Stand up the deployment pipeline components
        BOOTSTRAP = new BootstrapChainComponent(false, address(0));
        MARKET_REGISTRY = new DayMarketRegistry();
        _pinChainPolicyForTests();
    }

    /// @notice Pins the chain-level policy these suites' reference math and actors assume, without touching the
    ///         production config: the canonical fee set may evolve, but every arrange and expectation here is written
    ///         against this one. The recipient is the fixture's prankable wallet, so deployed kernels pay a known
    ///         actor. Also re-points the whole role graph at the fixture's prankable wallets and the ADMIN_ROLE at
    ///         OWNER — what the legacy script took as per-deploy arguments now rides the component overrides
    /// @dev MUST run after `BOOTSTRAP`/`MARKET_REGISTRY` are created and before any market deploys through them. Fork
    ///      bases that stand up their own component instances call this themselves
    function _pinChainPolicyForTests() internal {
        TemplatePolicy memory pinned = BOOTSTRAP.templatePolicy(false);
        pinned.protocolFeeRecipient = PROTOCOL_FEE_RECIPIENT_ADDRESS;
        pinned.stProtocolFeeWAD = 0.1e18;
        pinned.jtProtocolFeeWAD = 0;
        pinned.jtYieldShareProtocolFeeWAD = 0.45e18;
        pinned.lptYieldShareProtocolFeeWAD = 0;
        // The venue suites' leak and slippage formulas are written against a 1 bp pool swap fee
        pinned.poolSwapFeePercentage = 1e14;
        BOOTSTRAP.overrideTemplatePolicyForTest(pinned);

        // The fixtures act through role-specific prankable wallets, with OWNER as the AccessManager admin
        BOOTSTRAP.overrideFactoryAdminForTest(OWNER_ADDRESS);
        BOOTSTRAP.overrideRoleAssignmentAddressesForTest(_fixtureRoleAssignmentAddresses());

        // The venue suites' slippage bounds, reinvestment-gate interactions, and staged-premium arranges are
        // calibrated against the tight snUSD E-CLP curve (lambda 4000); pin it so a curve retune in the canonical
        // config cannot silently invalidate every calibrated expectation
        DayMarketConfig memory snUsd = MARKET_REGISTRY.getDayMarketConfig("snUSD");
        snUsd.pool.eclpParams = IGyroECLPPool.EclpParams({
            alpha: 998_502_246_630_054_917,
            beta: 1_000_200_040_008_001_600,
            c: 707_106_781_186_547_524,
            s: 707_106_781_186_547_524,
            lambda: 4_000_000_000_000_000_000_000
        });
        snUsd.pool.derivedEclpParams = IGyroECLPPool.DerivedEclpParams({
            tauAlpha: IGyroECLPPool.Vector2({ x: -94_861_212_813_096_057_289_512_505_574_275_160_547, y: 31_644_119_574_235_279_926_451_292_677_567_331_630 }),
            tauBeta: IGyroECLPPool.Vector2({ x: 37_142_269_533_113_549_537_591_131_345_643_981_951, y: 92_846_388_265_400_743_995_957_747_409_218_517_601 }),
            u: 66_001_741_173_104_803_338_721_745_994_955_553_010,
            v: 62_245_253_919_818_011_890_633_399_060_291_020_887,
            w: 30_601_134_345_582_732_000_058_913_853_921_008_022,
            z: -28_859_471_639_991_253_843_240_999_485_797_747_790,
            dSq: 99_999_999_999_999_999_886_624_093_342_106_115_200
        });
        MARKET_REGISTRY.overrideDayMarketConfigForTest(snUsd);
    }

    /// @notice Deploys a market through the REAL pipeline, exactly as the runbook composes it: bootstrap the chain
    ///         (idempotent — re-runs reuse everything), drop the deployer's admin roles (legacy `deploy()` parity:
    ///         admin-gated setup ends before any market lands), then deploy the market from its config struct
    function _deployMarketThroughPipeline(DayMarketConfig memory _cfg) internal returns (DeploymentResult memory result) {
        DeployMarketComponent market = _marketComponent();
        result = market.deployMarket(_cfg, MARKET_REGISTRY.getMarketId(_cfg.marketName, CHAIN.factory), DEPLOYER.privateKey);
    }

    /// @notice Bootstraps the chain (idempotent), drops the deployer's admin roles, and returns a market component
    ///         wired to the resulting chain — for tests that need the component itself (e.g. to try/catch a deploy)
    function _marketComponent() internal returns (DeployMarketComponent market) {
        CHAIN = BOOTSTRAP.bootstrap(DEPLOYER.privateKey);

        new RenounceDeployerRolesComponent(CHAIN.accessManager).execute(BOOTSTRAP.factoryAdmin(false), !CHAIN.amExisted, DEPLOYER.privateKey);

        market = new DeployMarketComponent(
            MarketUpstream({
                accessManager: CHAIN.accessManager,
                factory: CHAIN.factory,
                entryPoint: CHAIN.entryPoint,
                marketSyncer: CHAIN.marketSyncer,
                roycoBlacklist: CHAIN.roycoBlacklist,
                template: CHAIN.template
            })
        );
    }

    function _setupFork() internal {
        (uint256 forkBlock, string memory forkRpcUrl) = _forkConfiguration();
        if (bytes(forkRpcUrl).length > 0) {
            require(forkBlock != 0, "Fork block is required");
            vm.createSelectFork(forkRpcUrl, forkBlock);
        }
    }

    function _setupWallets() internal {
        // Admin wallet
        OWNER = _initWallet("OWNER", 1000 ether);
        OWNER_ADDRESS = OWNER.addr;

        // Role-specific wallets
        PAUSER = _initWallet("PAUSER", 1000 ether);
        PAUSER_ADDRESS = PAUSER.addr;

        UNPAUSER = _initWallet("UNPAUSER", 1000 ether);
        UNPAUSER_ADDRESS = UNPAUSER.addr;

        UPGRADER = _initWallet("UPGRADER", 1000 ether);
        UPGRADER_ADDRESS = UPGRADER.addr;

        SYNC_ROLE_HOLDER = _initWallet("SYNC_ROLE_HOLDER", 1000 ether);
        SYNC_ROLE_ADDRESS = SYNC_ROLE_HOLDER.addr;

        KERNEL_ADMIN = _initWallet("KERNEL_ADMIN", 1000 ether);
        KERNEL_ADMIN_ADDRESS = KERNEL_ADMIN.addr;

        ACCOUNTANT_ADMIN = _initWallet("ACCOUNTANT_ADMIN", 1000 ether);
        ACCOUNTANT_ADMIN_ADDRESS = ACCOUNTANT_ADMIN.addr;

        PROTOCOL_FEE_SETTER = _initWallet("PROTOCOL_FEE_SETTER", 1000 ether);
        PROTOCOL_FEE_SETTER_ADDRESS = PROTOCOL_FEE_SETTER.addr;

        ORACLE_ADMIN = _initWallet("ORACLE_ADMIN", 1000 ether);
        ORACLE_ADMIN_ADDRESS = ORACLE_ADMIN.addr;

        ORACLE_EMERGENCY_ADMIN = _initWallet("ORACLE_EMERGENCY_ADMIN", 1000 ether);
        ORACLE_EMERGENCY_ADMIN_ADDRESS = ORACLE_EMERGENCY_ADMIN.addr;

        MARKET_REINVEST_LIQUIDITY_PREMIUM_ADMIN = _initWallet("MARKET_REINVEST_LIQUIDITY_PREMIUM_ADMIN", 1000 ether);
        MARKET_REINVEST_LIQUIDITY_PREMIUM_ADMIN_ADDRESS = MARKET_REINVEST_LIQUIDITY_PREMIUM_ADMIN.addr;

        LP_ROLE_ADMIN = _initWallet("LP_ROLE_ADMIN", 1000 ether);
        LP_ROLE_ADMIN_ADDRESS = LP_ROLE_ADMIN.addr;

        ROLE_GUARDIAN = _initWallet("ROLE_GUARDIAN", 1000 ether);
        ROLE_GUARDIAN_ADDRESS = ROLE_GUARDIAN.addr;

        PROTOCOL_FEE_RECIPIENT = _initWallet("PROTOCOL_FEE_RECIPIENT", 1000 ether);
        PROTOCOL_FEE_RECIPIENT_ADDRESS = PROTOCOL_FEE_RECIPIENT.addr;

        // Deployer wallets (for factory deployment)
        DEPLOYER = _initWallet("DEPLOYER", 1000 ether);
        DEPLOYER_ADDRESS = DEPLOYER.addr;

        DEPLOYER_ADMIN = _initWallet("DEPLOYER_ADMIN", 1000 ether);
        DEPLOYER_ADMIN_ADDRESS = DEPLOYER_ADMIN.addr;
    }

    function _setupProviders() internal {
        // ST-only providers
        ST_ALICE = _generateProvider("ST_ALICE", ST_LP_ROLE);
        ST_BOB = _generateProvider("ST_BOB", ST_LP_ROLE);
        ST_CHARLIE = _generateProvider("ST_CHARLIE", ST_LP_ROLE);
        ST_DAN = _generateProvider("ST_DAN", ST_LP_ROLE);

        ST_ALICE_ADDRESS = ST_ALICE.addr;
        ST_BOB_ADDRESS = ST_BOB.addr;
        ST_CHARLIE_ADDRESS = ST_CHARLIE.addr;
        ST_DAN_ADDRESS = ST_DAN.addr;

        // JT-only providers
        JT_ALICE = _generateProvider("JT_ALICE", JT_LP_ROLE);
        JT_BOB = _generateProvider("JT_BOB", JT_LP_ROLE);
        JT_CHARLIE = _generateProvider("JT_CHARLIE", JT_LP_ROLE);
        JT_DAN = _generateProvider("JT_DAN", JT_LP_ROLE);

        JT_ALICE_ADDRESS = JT_ALICE.addr;
        JT_BOB_ADDRESS = JT_BOB.addr;
        JT_CHARLIE_ADDRESS = JT_CHARLIE.addr;
        JT_DAN_ADDRESS = JT_DAN.addr;

        // All unique provider addresses
        providers.push(ST_ALICE_ADDRESS);
        providers.push(JT_ALICE_ADDRESS);
        providers.push(ST_BOB_ADDRESS);
        providers.push(JT_BOB_ADDRESS);
        providers.push(ST_CHARLIE_ADDRESS);
        providers.push(JT_CHARLIE_ADDRESS);
        providers.push(ST_DAN_ADDRESS);
        providers.push(JT_DAN_ADDRESS);
    }

    function _setDeployedMarket(DeploymentResult memory _deploymentResult) internal {
        YDM = _deploymentResult.ydm;
        vm.label(address(YDM), "YDM");

        ST = _deploymentResult.seniorTranche;
        vm.label(address(ST), "ST");

        JT = _deploymentResult.juniorTranche;
        vm.label(address(JT), "JT");

        ACCOUNTANT = _deploymentResult.accountant;
        vm.label(address(ACCOUNTANT), "Accountant");

        KERNEL = _deploymentResult.kernel;
        vm.label(address(KERNEL), "Kernel");

        BLACKLIST = IRoycoBlacklist(_deploymentResult.roycoBlacklist);
        vm.label(address(BLACKLIST), "Blacklist");

        FACTORY = _deploymentResult.factory;
        vm.label(address(FACTORY), "Factory");

        ACCESS_MANAGER = _deploymentResult.accessManager;
        vm.label(address(ACCESS_MANAGER), "AccessManager");

        _wireExtraRoles();
    }

    /// @dev The AccessManager admin-role holder to prank for setup-time governance: `OWNER_ADDRESS` for a fresh
    ///      in-memory deploy, the production root multisig when the test forks a chain with a live factory
    function _adminRoleHolder() internal view returns (address fndn) {
        (bool ownerIsAdmin,) = ACCESS_MANAGER.hasRole(0, OWNER_ADDRESS);
        return ownerIsAdmin ? OWNER_ADDRESS : 0x7c405bbD131e42af506d14e752f2e59B19D49997;
    }

    /// @dev Wires roles that live in `ExtraRoles` and are intentionally NOT passed through
    ///      `factory.initialize` (canonical `Roles.getRoleConfig` doesn't know
    ///      them, so including them in the init array would revert). Pranks FNDN (the
    ///      admin-role holder): `OWNER_ADDRESS` for a fresh in-memory deploy, the FNDN multisig
    ///      when the test forks a chain where the factory is already on-chain.
    function _wireExtraRoles() internal {
        // Live-chain fallback is the production root multisig, pinned in `_adminRoleHolder`. Hardcoded (rather than
        // imported from script config) because that config is deploy tooling this test base intentionally does not
        // depend on — if the production admin ever rotates, fork tests hitting a live factory fail loudly below
        address fndn = _adminRoleHolder();

        // Standard 24h delay matches the canonical UNPAUSER config (and what `ApplySecurityMigration`
        // applies in production). The `_scheduleAndExecuteUnpause` test helper relies on a non-zero
        // delay — OZ AccessManager.schedule reverts when the caller's `setback == 0`.
        (bool unpauserHasRole,) = ACCESS_MANAGER.hasRole(ADMIN_UNPAUSER_ROLE, UNPAUSER_ADDRESS);
        if (!unpauserHasRole) {
            vm.prank(fndn);
            ACCESS_MANAGER.grantRole(ADMIN_UNPAUSER_ROLE, UNPAUSER_ADDRESS, 1 days);
        }
    }

    function _initWallet(string memory _name, uint256 _amount) internal returns (Vm.Wallet memory) {
        Vm.Wallet memory wallet = vm.createWallet(_name);
        vm.label(wallet.addr, _name);
        vm.deal(wallet.addr, _amount);
        return wallet;
    }

    /// @notice A delay-0 holder of `_role` the fixtures route synchronous admin calls through
    /// @dev The production role graph puts a 72h EXECUTION delay on most admin grants, so pranking the configured
    ///      wallets reverts AccessManagerNotScheduled on any direct restricted call. Fixtures instead act through a
    ///      dedicated per-role wallet the AM admin stands up FRESH with a zero execution delay — a fresh membership
    ///      takes effect immediately, whereas lowering an existing member's delay is itself time-locked by the old
    ///      delay. Scheduled-path behavior stays covered by the helpers that schedule + warp + execute for real
    function _immediateRoleHolder(uint64 _role, string memory _label) internal returns (address holder) {
        holder = makeAddr(string.concat(_label, "_IMMEDIATE"));
        (bool isMember,) = ACCESS_MANAGER.hasRole(_role, holder);
        if (!isMember) {
            vm.prank(_adminRoleHolder());
            ACCESS_MANAGER.grantRole(_role, holder, 0);
        }
    }

    /// @notice The delay-0 LP-role admin the fixtures grant providers through
    function _immediateLpRoleAdmin() internal returns (address lpAdmin) {
        return _immediateRoleHolder(LP_ROLE_ADMIN_ROLE, "LP_ROLE_ADMIN");
    }

    /// @notice Generates a provider address
    /// @param _name The name of the provider
    /// @return provider The provider address
    function _generateProvider(string memory _name, uint64 _role) internal virtual returns (Vm.Wallet memory provider) {
        provider = _initWallet(_name, 10_000_000e6);

        vm.prank(_immediateLpRoleAdmin());
        ACCESS_MANAGER.grantRole(_role, provider.addr, 0);

        return provider;
    }

    /// @notice Generates a provider address with both ST and JT LP roles
    /// @param index The index of the provider
    /// @return provider The provider address
    function _generateProvider(uint256 index) internal virtual returns (Vm.Wallet memory provider) {
        string memory providerName = string(abi.encodePacked("PROVIDER", vm.toString(index)));
        provider = _initWallet(providerName, 10_000_000e6);

        address lpAdmin = _immediateLpRoleAdmin();
        vm.startPrank(lpAdmin);
        ACCESS_MANAGER.grantRole(ST_LP_ROLE, provider.addr, 0);
        ACCESS_MANAGER.grantRole(JT_LP_ROLE, provider.addr, 0);
        vm.stopPrank();

        return provider;
    }

    /// @notice Converts the specified assets denominated in ST's tranche units to the kernel's NAV units
    /// @param _assets The assets denominated in ST's tranche units to convert to the kernel's NAV units
    /// @return value The specified assets denominated in ST's tranche units converted to the kernel's NAV units
    function _toSTValue(TRANCHE_UNIT _assets) internal view returns (NAV_UNIT) {
        return KERNEL.convertCollateralAssetsToValue(_assets);
    }

    /// @notice Returns the fork configuration
    /// @return forkBlock The fork block
    /// @return forkRpcUrl The fork RPC URL
    function _forkConfiguration() internal virtual returns (uint256 forkBlock, string memory forkRpcUrl) {
        return (0, "");
    }

    /// @notice The fixture's role-holder wallets, in the shape the role-graph component assigns from
    function _fixtureRoleAssignmentAddresses() internal view returns (RoleAssignmentAddresses memory) {
        return (RoleAssignmentAddresses({
                pauserAddress: PAUSER_ADDRESS,
                unpauserAddress: UNPAUSER_ADDRESS,
                upgraderAddress: UPGRADER_ADDRESS,
                syncRoleAddress: SYNC_ROLE_ADDRESS,
                adminKernelAddress: KERNEL_ADMIN_ADDRESS,
                adminAccountantAddress: ACCOUNTANT_ADMIN_ADDRESS,
                adminProtocolFeeSetterAddress: PROTOCOL_FEE_SETTER_ADDRESS,
                adminOracleAddress: ORACLE_ADMIN_ADDRESS,
                adminOracleEmergencyAddress: ORACLE_EMERGENCY_ADMIN_ADDRESS,
                lpRoleAdminAddress: LP_ROLE_ADMIN_ADDRESS,
                lpRoleAdminOperatorAddress: LP_ROLE_ADMIN_ADDRESS,
                guardianAddress: ROLE_GUARDIAN_ADDRESS,
                guardianVetoAddress: ROLE_GUARDIAN_ADDRESS,
                lpRoleHolderAddress: PROTOCOL_FEE_RECIPIENT_ADDRESS,
                balancerPoolManagerAddress: KERNEL_ADMIN_ADDRESS,
                marketOpsAddress: KERNEL_ADMIN_ADDRESS,
                marketReinvestLiquidityPremiumAddress: MARKET_REINVEST_LIQUIDITY_PREMIUM_ADMIN_ADDRESS,
                adminEntryPointAddress: KERNEL_ADMIN_ADDRESS,
                entryPointFeeCollectorAddress: PROTOCOL_FEE_RECIPIENT_ADDRESS
            }));
    }

    // -----------------------------------------
    // Role-Specific Helper Functions
    // -----------------------------------------

    /// @notice Calls sync on the kernel with SYNC_ROLE
    function _sync() internal prankModifier(SYNC_ROLE_ADDRESS) {
        KERNEL.syncTrancheAccounting();
    }
}
