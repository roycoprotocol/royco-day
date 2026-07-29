// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IGyroECLPPool } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/pool-gyro/IGyroECLPPool.sol";
import { IRateProvider } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { IVaultAdmin } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultAdmin.sol";
import { PoolRoleAccounts, TokenConfig } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { AccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { RoycoDayMarketGenesis } from "../../../src/factory/periphery/RoycoDayMarketGenesis.sol";
import { IRoycoFactory } from "../../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { NAV_UNIT, toNAVUnits } from "../../../src/libraries/Units.sol";
import { ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { UtilizationLogic } from "../../../src/libraries/logic/UtilizationLogic.sol";
import { C4BatteryBase } from "./Test_C4FullBattery.t.sol";

/**
 * @title Test_MarketGenesisFlow
 * @notice Working example of the two-transaction market opening that removes the initialization window: deploy the
 *         market with its pool paused, then reopen and seed it when the operator is ready. Exercised against the
 *         real Balancer Vault, a real OpenZeppelin AccessManager standing in for the market authority, and a real
 *         Gyro E-CLP pool, so the pause manager check, the unlock callback, and the pool math are the production
 *         ones rather than mocks.
 *
 *         The factory is a stub that creates the pool and returns it in the deployment result extras, which is the
 *         part of the real template's behavior this flow depends on. Everything else in the path is real.
 *
 *         Regenerate: FOUNDRY_PROFILE=research forge test --match-path test/research/eclp/Test_MarketGenesisFlow.t.sol -vv | grep -E "METRIC|VERDICT"
 */
contract Test_MarketGenesisFlow is C4BatteryBase {
    /// The market's expected first liquidity provider deposit, which the seed has to be able to accept.
    uint256 internal constant FIRST_DEPOSIT_ST = X0_C4B;
    uint256 internal constant FIRST_DEPOSIT_QUOTE = Y0;

    /// The role the market authority binds the Balancer Vault's pause and unpause functions to.
    uint64 internal constant PAUSER_ROLE = 42;

    AccessManager internal authority;
    GenesisFactoryStub internal factoryStub;
    RoycoDayMarketGenesis internal genesis;
    address internal outsider;

    function setUp() public virtual override {
        super.setUp();
        outsider = makeAddr("outsider");

        // The market authority, and the factory the genesis contract deploys through.
        authority = new AccessManager(address(this));
        factoryStub = new GenesisFactoryStub(
            address(authority),
            address(factory),
            IVault(address(vault)),
            _eclpParamsC4(),
            _derivedParamsC4(),
            SWAP_FEE,
            _tokens(),
            address(stRateProvider),
            address(quoteRateProvider)
        );
        genesis = new RoycoDayMarketGenesis(IRoycoFactory(address(factoryStub)), IVault(address(vault)));

        // Bind the Vault's pause functions to a role and grant it to the genesis contract, mirroring the market
        // template's own role bindings for `pausePool` and `unpausePool`.
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = IVaultAdmin.pausePool.selector;
        selectors[1] = IVaultAdmin.unpausePool.selector;
        authority.setTargetFunctionRole(address(vault), selectors, PAUSER_ROLE);
        authority.grantRole(PAUSER_ROLE, address(genesis), 0);

        // The operator funds and approves the genesis contract for the seed.
        st.approve(address(genesis), type(uint256).max);
        quoteToken.approve(address(genesis), type(uint256).max);
    }

    /// The seed this flow uses: one wei of senior shares and 30% of the first deposit's value in quote.
    function _seedAmounts() internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = 1;
        amounts[1] = ((FIRST_DEPOSIT_QUOTE + FIRST_DEPOSIT_ST) * 30) / 100;
    }

    /// The first deposit the seed has to be able to accept.
    function _firstDepositAmounts() internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = FIRST_DEPOSIT_ST;
        amounts[1] = FIRST_DEPOSIT_QUOTE;
    }

    /// The most recently deployed market's pool, read by the accountant stub to record the ordering.
    address internal lastGenesisPool;

    /// Runs step one and returns the market's pool.
    function _deployPaused() internal returns (address pool_) {
        (, pool_) = genesis.deployMarketPaused(address(0xdead), "");
        lastGenesisPool = pool_;
    }

    /// Lets the accountant stub observe whether the pool held inventory when the requirement was applied.
    function lastPoolSupply() external view returns (uint256) {
        return IERC20(lastGenesisPool).totalSupply();
    }

    /// The liquidity requirement argument that leaves the market's setting alone.
    function _noLiquidityRequirement() internal pure returns (RoycoDayMarketGenesis.LiquidityRequirement memory) {
        return RoycoDayMarketGenesis.LiquidityRequirement({ accountant: address(0), minLiquidityWAD: 0 });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP ONE: THE POOL IS NEVER LIVE AND UNINITIALIZED
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Deployment leaves the pool registered, paused, and uninitialized, with no window an outsider can use
     * @dev The pause happens in the same transaction that registers the pool, so there is no block in which an
     *      outside initializer could act
     */
    function test_DeploymentLeavesThePoolClosed() public {
        address p = _deployPaused();

        assertTrue(vault.isPoolRegistered(p), "the pool must be registered");
        assertTrue(vault.isPoolPaused(p), "and paused");
        assertFalse(vault.isPoolInitialized(p), "and still uninitialized");

        // An outsider holding both tokens cannot take the genesis.
        pool = p;
        st.mint(outsider, 1e24);
        quoteToken.mint(outsider, 1e24);
        vm.startPrank(outsider);
        st.approve(address(router), type(uint256).max);
        quoteToken.approve(address(router), type(uint256).max);
        bool grabbed;
        try router.initialize(p, outsider, _tokens(), _two(0, 1e12)) {
            grabbed = true;
        } catch { }
        vm.stopPrank();
        assertFalse(grabbed, "an outsider must not be able to initialize the paused pool");

        _logVerdict(
            "genesis_step_one",
            "NO_WINDOW_BETWEEN_DEPLOYMENT_AND_SEEDING",
            "the pool is registered and paused in one transaction, so it is never both live and uninitialized"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP TWO: REOPEN AND SEED
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Reopening and seeding in one transaction produces a pool that serves the first deposit immediately
     * @dev Uses the seed the analysis arrives at: one wei of senior shares, and 30% of the first deposit's value
     *      in quote
     */
    function test_UnpauseAndInitializeOpensAUsableMarket() public {
        address p = _deployPaused();
        uint256[] memory seed = _seedAmounts();

        uint256 bptOut = genesis.unpauseAndInitialize(p, seed, 0, address(this), _firstDepositAmounts(), _noLiquidityRequirement());
        assertGt(bptOut, 0, "the genesis must mint pool tokens");
        assertTrue(vault.isPoolInitialized(p), "the pool must be initialized");
        assertFalse(vault.isPoolPaused(p), "and unpaused");
        assertEq(IERC20(p).balanceOf(address(this)), bptOut, "the pool tokens must reach the named recipient");

        pool = p;
        (uint256 stRaw, uint256 qRaw) = _rawBalances();
        assertEq(stRaw, seed[0], "the senior balance must be exactly the seeded amount");
        assertEq(qRaw, seed[1], "the quote balance must be exactly the seeded amount");

        // The market's first deposit works on the first call, in either shape.
        IERC20(p).approve(address(router), type(uint256).max);
        (, uint256 firstDepositBpt) = router.addLiquidityUnbalanced(p, address(this), _tokens(), _firstDepositAmounts(), 0);
        assertGt(firstDepositBpt, 0, "the first deposit must succeed immediately");

        _logMetric(
            "GENESIS_FLOW",
            string.concat("seed_st=", _u(seed[0]), "|seed_quote=", _u(seed[1]), "|genesis_bpt=", _u(bptOut), "|first_deposit_bpt=", _u(firstDepositBpt))
        );
        _logVerdict(
            "genesis_step_two",
            "ONE_TRANSACTION_OPENS_A_USABLE_MARKET",
            "unpause and initialize together, then the first deposit succeeds on the next call"
        );
    }

    /// A quote-only genesis is refused, so the arithmetic underflow can never be reached.
    function test_TheGenesisRefusesAZeroLeg() public {
        address p = _deployPaused();
        uint256[] memory seed = _seedAmounts();
        seed[0] = 0;

        vm.expectRevert(RoycoDayMarketGenesis.GENESIS_LEG_IS_ZERO.selector);
        genesis.unpauseAndInitialize(p, seed, 0, address(this), _firstDepositAmounts(), _noLiquidityRequirement());

        assertTrue(vault.isPoolPaused(p), "the pool must stay paused when the genesis is refused");

        _logVerdict("genesis_zero_leg", "REFUSED", "a genesis leaving a token at zero cannot be set through this path");
    }

    /// A seed too small for the declared first deposit is refused before the pool is opened.
    function test_TheGenesisRefusesAnUndersizedSeed() public {
        address p = _deployPaused();
        uint256[] memory seed = _seedAmounts();
        seed[1] = seed[1] / 4;

        vm.expectPartialRevert(RoycoDayMarketGenesis.GENESIS_TOO_SMALL_FOR_FIRST_DEPOSIT.selector);
        genesis.unpauseAndInitialize(p, seed, 0, address(this), _firstDepositAmounts(), _noLiquidityRequirement());

        assertTrue(vault.isPoolPaused(p), "the pool must stay paused when the seed is refused");

        _logVerdict("genesis_undersized_seed", "REFUSED", "a seed that cannot carry the declared first deposit is rejected before the pool opens");
    }

    /**
     * @notice The liquidity requirement is applied after seeding, in the same transaction
     * @dev The ordering is the point. A nonzero requirement against an empty liquidity provider tranche saturates
     *      the market's liquidity utilization, and senior deposits enforce that utilization, so raising it before
     *      the pool holds inventory stops the senior deposits that mint the shares the genesis needs
     */
    function test_TheLiquidityRequirementIsRaisedAfterSeeding() public {
        address p = _deployPaused();
        AccountantStub accountant = new AccountantStub();

        // The authority binds the accountant's setter to the same role the genesis contract holds.
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = AccountantStub.setMinLiquidity.selector;
        authority.setTargetFunctionRole(address(accountant), selectors, PAUSER_ROLE);

        assertEq(accountant.minLiquidityWAD(), 0, "the market must start with no liquidity requirement");

        uint256 bptOut = genesis
            .unpauseAndInitialize(
                p,
                _seedAmounts(),
                0,
                address(this),
                _firstDepositAmounts(),
                RoycoDayMarketGenesis.LiquidityRequirement({ accountant: address(accountant), minLiquidityWAD: 0.05e18 })
            );

        assertGt(bptOut, 0, "the genesis must still mint pool tokens");
        assertEq(accountant.minLiquidityWAD(), 0.05e18, "the liquidity requirement must be applied");
        assertGt(accountant.poolSupplyWhenSet(), 0, "and it must be applied only once the pool holds inventory");

        _logVerdict(
            "genesis_liquidity_requirement",
            "RAISED_ONLY_AFTER_THE_POOL_HOLDS_INVENTORY",
            "the requirement is applied in the same transaction as the seeding, and after it"
        );
    }

    /**
     * @notice The contract's sizing preview agrees with what the Vault actually accepts
     * @dev Sweeps seed sizes, comparing the previewed growth ratio against whether the real deposit succeeds
     */
    function test_TheSizingPreviewMatchesTheVault() public {
        uint256[] memory firstDeposit = _firstDepositAmounts();
        uint256 depositValue = FIRST_DEPOSIT_QUOTE + FIRST_DEPOSIT_ST;
        uint256[5] memory percents = [uint256(10), 20, 26, 30, 50];
        uint256 agreements;

        for (uint256 i = 0; i < percents.length; ++i) {
            address p = _deployPaused();
            uint256[] memory seed = new uint256[](2);
            seed[0] = 1;
            seed[1] = (depositValue * percents[i]) / 100;

            uint256 previewed = genesis.previewFirstDepositInvariantRatio(p, seed, firstDeposit);
            bool previewSaysOk = previewed <= genesis.MAX_INVARIANT_RATIO();

            // Open the pool without the check, then attempt the real deposit.
            genesis.unpauseAndInitialize(p, seed, 0, address(this), new uint256[](0), _noLiquidityRequirement());
            pool = p;
            bool actuallyOk;
            try router.addLiquidityUnbalanced(p, address(this), _tokens(), firstDeposit, 0) returns (uint256[] memory, uint256 bpt) {
                actuallyOk = bpt > 0;
            } catch { }

            assertEq(previewSaysOk, actuallyOk, "the preview must agree with the Vault at every seed size");
            ++agreements;
        }

        assertEq(agreements, percents.length, "every seed size must have been compared");
        _logVerdict(
            "genesis_sizing_preview",
            "THE_PREVIEW_AGREES_WITH_THE_VAULT",
            "the on-chain seed check accepts exactly the seeds the Vault would accept the first deposit against"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // WHY THE ORDERING MATTERS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice The liquidity utilization branch that makes the ordering necessary, measured directly
     * @dev The check is on the liquidity provider tranche holding exactly nothing, not on how large the requirement
     *      is, so a requirement of one wei saturates the utilization exactly as a large one does. Shrinking the
     *      requirement is not a way around the ordering
     * @dev Senior deposits enforce `liquidityUtilizationWAD <= WAD`, so a saturated utilization stops them
     */
    function test_ASmallLiquidityRequirementDoesNotAvoidTheOrdering() public pure {
        NAV_UNIT stNAV = toNAVUnits(uint256(1_000_000e18));

        // No requirement: the utilization is zero however empty the liquidity provider tranche is.
        assertEq(UtilizationLogic._computeLiquidityUtilization(stNAV, 0, ZERO_NAV_UNITS), 0, "a zero requirement leaves the utilization at zero");

        // Any nonzero requirement against an empty tranche saturates, including one wei.
        assertEq(
            UtilizationLogic._computeLiquidityUtilization(stNAV, 1, ZERO_NAV_UNITS),
            type(uint256).max,
            "a one wei requirement against an empty tranche saturates the utilization"
        );
        assertEq(
            UtilizationLogic._computeLiquidityUtilization(stNAV, 0.05e18, ZERO_NAV_UNITS),
            type(uint256).max,
            "and so does an ordinary one"
        );

        // Once the tranche holds inventory the requirement prices normally, and a one wei requirement is negligible.
        uint256 seeded = UtilizationLogic._computeLiquidityUtilization(stNAV, 1, toNAVUnits(uint256(3_000_000e18)));
        assertLe(seeded, 1e18, "with inventory present a one wei requirement is far inside the limit");

        _logVerdict(
            "liquidity_requirement_ordering",
            "THE_BRANCH_IS_ON_EMPTY_NOT_ON_SIZE",
            "any nonzero requirement saturates against an empty tranche, so shrinking it does not replace seeding first"
        );
    }
}

/**
 * @title AccountantStub
 * @notice Records the liquidity requirement the genesis contract applies, and the pool supply at the moment it is
 *         applied, so a test can assert the ordering rather than only the final value
 */
contract AccountantStub {
    uint64 public minLiquidityWAD;
    uint256 public poolSupplyWhenSet;

    address internal immutable POOL_SUPPLY_SOURCE;

    constructor() {
        POOL_SUPPLY_SOURCE = msg.sender;
    }

    function setMinLiquidity(uint64 _minLiquidityWAD) external {
        minLiquidityWAD = _minLiquidityWAD;
        poolSupplyWhenSet = IPoolSupplyProbe(POOL_SUPPLY_SOURCE).lastPoolSupply();
    }
}

interface IPoolSupplyProbe {
    function lastPoolSupply() external view returns (uint256);
}

/**
 * @title GenesisFactoryStub
 * @notice Minimal stand-in for the Royco factory: creates the market's Gyro E-CLP pool the way the real deployment
 *         template does, naming the market authority as the pool's pause manager, and returns it in the deployment
 *         result extras
 * @dev Only the parts of the factory this flow depends on are modeled. The pool creation, its role accounts, and the
 *      result encoding are the real template's
 */
contract GenesisFactoryStub {
    address public immutable AUTHORITY;
    address internal immutable POOL_FACTORY;
    IVault internal immutable VAULT;
    uint256 internal immutable SWAP_FEE_PERCENTAGE;
    address internal immutable ST_RATE_PROVIDER;
    address internal immutable QUOTE_RATE_PROVIDER;

    IGyroECLPPool.EclpParams internal eclpParams;
    IGyroECLPPool.DerivedEclpParams internal derivedParams;
    IERC20[] internal tokens;
    uint256 internal salt;

    constructor(
        address _authority,
        address _poolFactory,
        IVault _vault,
        IGyroECLPPool.EclpParams memory _eclpParams,
        IGyroECLPPool.DerivedEclpParams memory _derivedParams,
        uint256 _swapFeePercentage,
        IERC20[] memory _tokens,
        address _stRateProvider,
        address _quoteRateProvider
    ) {
        AUTHORITY = _authority;
        POOL_FACTORY = _poolFactory;
        VAULT = _vault;
        eclpParams = _eclpParams;
        derivedParams = _derivedParams;
        SWAP_FEE_PERCENTAGE = _swapFeePercentage;
        tokens = _tokens;
        ST_RATE_PROVIDER = _stRateProvider;
        QUOTE_RATE_PROVIDER = _quoteRateProvider;
    }

    function ROYCO_AUTHORITY() external view returns (address) {
        return AUTHORITY;
    }

    /// Creates the market's pool with the authority as its pause manager, as the real template does.
    function executeMarketDeployment(address, bytes calldata) external returns (IRoycoProtocolTemplate.DeploymentResult memory result) {
        IRateProvider[] memory provs = new IRateProvider[](2);
        provs[0] = IRateProvider(ST_RATE_PROVIDER);
        provs[1] = IRateProvider(QUOTE_RATE_PROVIDER);

        TokenConfig[] memory cfg = IVaultLike(address(VAULT)).buildTokenConfig(tokens, provs);
        PoolRoleAccounts memory roleAccounts =
            PoolRoleAccounts({ pauseManager: AUTHORITY, swapFeeManager: AUTHORITY, poolCreator: AUTHORITY });

        address pool = IGyroECLPPoolFactoryLike(POOL_FACTORY)
            .create(
                "Royco Day genesis E-CLP",
                "RD-ECLP-G",
                cfg,
                eclpParams,
                derivedParams,
                roleAccounts,
                SWAP_FEE_PERCENTAGE,
                address(0),
                false,
                false,
                bytes32(uint256(9000 + salt++))
            );

        result.kernel = address(this);
        result.seniorTranche = address(tokens[0]);
        result.extras = abi.encode(pool, address(0), address(0));
    }
}

interface IVaultLike {
    function buildTokenConfig(IERC20[] memory tokens, IRateProvider[] memory rateProviders) external view returns (TokenConfig[] memory);
}

interface IGyroECLPPoolFactoryLike {
    function create(
        string memory name,
        string memory symbol,
        TokenConfig[] memory tokens,
        IGyroECLPPool.EclpParams memory eclpParams,
        IGyroECLPPool.DerivedEclpParams memory derivedEclpParams,
        PoolRoleAccounts memory roleAccounts,
        uint256 swapFeePercentage,
        address poolHooksContract,
        bool enableDonation,
        bool disableUnbalancedLiquidity,
        bytes32 salt
    )
        external
        returns (address pool);
}
