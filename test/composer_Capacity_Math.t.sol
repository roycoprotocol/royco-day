// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { AccessManager } from "../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { BeaconProxy } from "../lib/openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "../lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { IERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Math } from "../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { RoycoDayAccountant } from "../src/accountant/RoycoDayAccountant.sol";
import { RoycoAccessManager } from "../src/factory/RoycoAccessManager.sol";
import { IRoycoDayAccountant } from "../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../src/interfaces/IRoycoDayKernel.sol";
import { IBalancerV3LiquidityVenue } from "../src/interfaces/liquidity-venue/IBalancerV3LiquidityVenue.sol";
import { RoycoDayBalancerV3Kernel } from "../src/kernels/RoycoDayBalancerV3Kernel.sol";
import { MAX_NAV_UNITS, WAD, ZERO_NAV_UNITS } from "../src/libraries/Constants.sol";
import { AssetClaims, MarketState, Operation, SyncedAccountingState } from "../src/libraries/Types.sol";
import { NAV_UNIT, toNAVUnits, toUint256 } from "../src/libraries/Units.sol";
import { RoycoJuniorTranche } from "../src/tranches/RoycoJuniorTranche.sol";
import { RoycoLiquidityProviderTranche } from "../src/tranches/RoycoLiquidityProviderTranche.sol";
import { RoycoSeniorTranche } from "../src/tranches/RoycoSeniorTranche.sol";
import { MockAccountantKernel } from "./mocks/MockAccountantKernel.sol";
import { MockAggregatorV3 } from "./mocks/MockAggregatorV3.sol";
import { MockBPT } from "./mocks/MockBPT.sol";
import { MockBPTOracle } from "./mocks/MockBPTOracle.sol";
import { MockBalancerRouter } from "./mocks/MockBalancerRouter.sol";
import { MockBalancerVault } from "./mocks/MockBalancerVault.sol";
import { MockERC4626C } from "./mocks/MockERC4626C.sol";
import { MockPriceOracle } from "./mocks/MockPriceOracle.sol";
import { MockRecordingYDM } from "./mocks/MockRecordingYDM.sol";
import { UninitializedERC1967Proxy } from "./mocks/UninitializedERC1967Proxy.sol";
import { FixtureCell, MarketParamsConfig } from "./utils/FixtureTypes.sol";
import { MarketFuzzTestBase } from "./utils/MarketFuzzTestBase.sol";
import { defaultParams } from "./utils/MarketParams.sol";
import { RoycoTestMath } from "./utils/RoycoTestMath.sol";
import { cellA, cellD } from "./utils/TokenConfigs.sol";

/*//////////////////////////////////////////////////////////////////////////////
    Test-local, behaviour-identical subclasses of the production contracts

    This harness environment refuses a `new` of any contract declared under `src/` (the runner rewrites
    those construction sites through `vm.deployCode`, which is disabled because it touches the filesystem).
    Deploying a trivial subclass declared in `test/` deploys the SAME logic through a plain CREATE, so every
    contract under test below is the production implementation, byte for byte, reached through a
    construction site the runner does not intercept
//////////////////////////////////////////////////////////////////////////////*/

contract LocalAccessManager is RoycoAccessManager {
    constructor(address _initialAdmin) RoycoAccessManager(_initialAdmin) { }
}

contract LocalAccountant is RoycoDayAccountant { }

contract LocalSeniorTranche is RoycoSeniorTranche { }

contract LocalJuniorTranche is RoycoJuniorTranche { }

contract LocalLiquidityProviderTranche is RoycoLiquidityProviderTranche { }

contract LocalKernel is RoycoDayBalancerV3Kernel {
    constructor(IVault _balancerV3Vault) RoycoDayBalancerV3Kernel(_balancerV3Vault) { }
}

/**
 * @title Test_RoycoDayAccountantCapacityMath
 * @notice Property suite for the RoycoDayAccountant "Capacity Math" component: maxSTDeposit, maxJTWithdrawal
 *         and maxLPTWithdrawal, the advisory view-only quotes the kernel converts into inkindMaxDeposit /
 *         inkindMaxRedeemable / lptMaxRedeemableMultiAsset
 *
 * @dev Two rigs live in one contract:
 *      1. A standalone accountant (`acct`) behind an ERC1967 proxy with a MockAccountantKernel, used for the
 *         closed-form capacity properties. Only `dustTolerance` is storage-resident (mutated per fuzz run
 *         through the real `setDustTolerance` setter); every other capacity input rides in the caller-supplied
 *         `SyncedAccountingState` memory struct, so a single deployment covers the whole configuration domain
 *      2. The full production market fixture (MarketFuzzTestBase, `setUp` deliberately overridden to NOT deploy
 *         it) which the end-to-end properties spin up on demand, so a max-sized operation is actually executed
 *         against the kernel's authoritative post-op gate
 *
 * @dev KNOWN-VULNERABILITY / KNOWN-DEVIATION tests. Seven tests in this file are RED against the current
 *      implementation and are registered as expected failures with the runner. Each asserts the property /
 *      "the attack cannot occur" exactly as stated in the batch, so its FAILURE is the demonstration that the
 *      stated property does not hold. Each contains EXACTLY ONE assertion -- the property itself, placed last.
 *      The concrete magnitudes the current implementation produces are recorded NON-FATALLY with
 *      `emit log_named_uint`, so the test's redness is attributable to the property and to nothing else: when a
 *      fix lands and the magnitudes move, the single assertion is the only statement that decides the outcome,
 *      the test turns green, and the expected-failure registration must be removed. They are:
 *        - test_unbounded_dust_tolerance_capacity_dos                        (P11, overflow leg)
 *        - test_unbounded_dust_tolerance_freezes_capacity                    (P11, freeze leg)
 *        - test_caller_supplied_state_struct_is_trusted                      (P12, overstatement leg)
 *        - test_caller_supplied_state_struct_underflow_reverts_jt_view       (P12, revert leg)
 *        - test_dust_padding_not_worth_full_dust_in_jt_redemption_units      (P15 leg b)
 *        - test_dust_padding_not_worth_full_dust_in_lpt_withdrawal_units     (P15 leg c)
 *        - test_capacity_quote_tightness_jt_leg_counterexample               (P17 leg b)
 *
 * @dev Notation used throughout: C = collateralNAV, S = stEffectiveNAV, J = jtEffectiveNAV, P = lptRawNAV,
 *      c = minCoverageWAD, l = minLiquidityWAD, D = dustTolerance, W = WAD
 */
contract Test_RoycoDayAccountantCapacityMath is MarketFuzzTestBase {
    /// @dev Realistic NAV magnitude ceiling for the fuzz domain (1e12 whole NAV units at 18 decimals)
    uint256 internal constant MAX_NAV = 1e30;
    /// @dev Dust tolerance ceiling for the fuzz domain (still economically absurd, but overflow-free)
    uint256 internal constant MAX_DUST = 1e24;

    /// @dev The standalone accountant under test and its mock kernel / authority
    RoycoDayAccountant internal acct;
    MockAccountantKernel internal mkKernel;
    AccessManager internal acctAuthority;

    /// @dev Sink so the try/catch liveness probes cannot be optimized away
    uint256 internal sink;

    /*//////////////////////////////////////////////////////////////////////
                                    RIG
    //////////////////////////////////////////////////////////////////////*/

    /// @dev Deliberately does NOT deploy the market fixture: the end-to-end tests deploy it themselves
    function setUp() public override {
        _deployStandaloneAccountant();
    }

    /// @dev Deploys an initialized accountant proxy wired to a mock kernel, with this contract as the AccessManager admin
    function _deployStandaloneAccountant() internal {
        mkKernel = new MockAccountantKernel();
        acctAuthority = new AccessManager(address(this));
        LocalAccountant impl = new LocalAccountant();
        acct = RoycoDayAccountant(address(new UninitializedERC1967Proxy(address(impl))));
        mkKernel.setAccountant(address(acct));

        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p;
        p.kernel = address(mkKernel);
        p.initialAuthority = address(acctAuthority);
        p.minCoverageWAD = uint64(0.1e18);
        p.coverageLiquidationUtilizationWAD = 1.1e18;
        p.minLiquidityWAD = uint64(0.05e18);
        p.jtYDM = address(new MockRecordingYDM());
        p.lptYDM = address(new MockRecordingYDM());
        p.maxJTYieldShareWAD = uint64(0.2e18);
        p.maxLPTYieldShareWAD = uint64(0.1e18);
        p.fixedTermDurationSeconds = uint24(604_800);
        p.dustTolerance = ZERO_NAV_UNITS;
        acct.initialize(p);
    }

    /**
     * @dev Verbatim copy of DayMarketTestBase._deployMarket with the six `new <src contract>` sites redirected
     *      at the behaviour-identical test-local subclasses declared above (see the note at the top of this
     *      file). Everything else — ordering, mocks, pool registration, kernel address prediction and the whole
     *      production-shaped role wiring — is the fixture's own code, reached through the base's internal helpers
     */
    function _deployMarket(FixtureCell memory _cell, MarketParamsConfig memory _params) internal override {
        _validateFixtureCell(_cell);

        cell = _cell;
        params = _params;

        // 1. Access manager, admin'd by the fixture so role wiring needs no schedule/execute dance
        accessManager = new LocalAccessManager(address(this));
        vm.label(address(accessManager), "RoycoAccessManager");

        // 2. Tokens: quote stable + ONE ERC4626 vault share over a mock underlying for both ST and JT
        quoteToken = _deployERC20("Quote Stable", "QUOTE", _cell.quoteAsset);
        stJtUnderlying = _deployERC20("ST/JT Underlying", "UNDR", _toUnderlyingConfig(_cell.collateralAsset));
        stJtVault = new MockERC4626C(address(stJtUnderlying), "ST/JT Vault Share", "vSHARE", _cell.collateralAsset.decimals);
        stJtVault.setRate(_cell.collateralAsset.initialRateWAD);
        vm.label(address(stJtVault), "MockERC4626C_STJT");

        // 3. Oracles
        collateralAssetOracle = new MockPriceOracle(address(stJtVault), _cell.collateralAsset.initialRateWAD, ORACLE_STALENESS_THRESHOLD_SECONDS);
        collateralPriceWAD = _cell.collateralAsset.initialRateWAD;
        priceFeed = new MockAggregatorV3(PRICE_FEED_DECIMALS, PRICE_FEED_INITIAL_ANSWER);
        sequencerFeed = new MockAggregatorV3(0, 0);
        vm.label(address(collateralAssetOracle), "MockCollateralAssetOracle");
        vm.label(address(priceFeed), "MockPriceFeed");
        vm.label(address(sequencerFeed), "MockSequencerFeed");

        // 4. Venue
        balancerVault = new MockBalancerVault();
        balancerRouter = new MockBalancerRouter(balancerVault);
        bpt = new MockBPT(IVault(address(balancerVault)), "Royco BPT", "rBPT");
        bptOracle = new MockBPTOracle(balancerVault, address(bpt));
        vm.label(address(balancerVault), "MockBalancerVault");
        vm.label(address(balancerRouter), "MockBalancerRouter");
        vm.label(address(bpt), "MockBPT");
        vm.label(address(bptOracle), "MockBPTOracle");

        // 5. YDMs
        bytes memory jtYdmInitData;
        bytes memory lptYdmInitData;
        (jtYdm, jtYdmInitData) = _deployYDM("JT_YDM", _params.jtYdmKind, _params.jtCurve, _params.targetUtilizationWAD);
        (lptYdm, lptYdmInitData) = _deployYDM("LPT_YDM", _params.lptYdmKind, _params.lptCurve, _params.targetUtilizationWAD);

        // 6. Predict the kernel proxy address
        kernelProxyDeployer = makeAddr("KERNEL_PROXY_DEPLOYER");
        address predictedKernel = vm.computeCreateAddress(kernelProxyDeployer, vm.getNonce(kernelProxyDeployer));

        // 7. Market-independent impls behind per-component beacons
        stBeacon = new UpgradeableBeacon(address(new LocalSeniorTranche()), address(accessManager));
        jtBeacon = new UpgradeableBeacon(address(new LocalJuniorTranche()), address(accessManager));
        lptBeacon = new UpgradeableBeacon(address(new LocalLiquidityProviderTranche()), address(accessManager));
        accountantBeacon = new UpgradeableBeacon(address(new LocalAccountant()), address(accessManager));

        // 8. Tranche and accountant proxies MUST exist before the kernel
        seniorTranche =
            RoycoSeniorTranche(_deployTrancheProxy(address(stBeacon), "Royco Senior Tranche", "RST", predictedKernel, address(stJtVault)));
        juniorTranche =
            RoycoJuniorTranche(_deployTrancheProxy(address(jtBeacon), "Royco Junior Tranche", "RJT", predictedKernel, address(stJtVault)));
        liquidityProviderTranche = RoycoLiquidityProviderTranche(
            _deployTrancheProxy(address(lptBeacon), "Royco Liquidity Provider Tranche", "RLT", predictedKernel, address(bpt))
        );
        vm.label(address(seniorTranche), "ST");
        vm.label(address(juniorTranche), "JT");
        vm.label(address(liquidityProviderTranche), "LPT");

        accountant = RoycoDayAccountant(
            address(
                new BeaconProxy(
                    address(accountantBeacon),
                    abi.encodeCall(RoycoDayAccountant.initialize, (_buildAccountantInitParams(_params, predictedKernel, jtYdmInitData, lptYdmInitData)))
                )
            )
        );
        vm.label(address(accountant), "Accountant");

        // 9. Register the pool BEFORE kernel impl construction
        stPoolTokenIndex = 0;
        balancerVault.registerPool(address(bpt), [IERC20(address(seniorTranche)), IERC20(address(quoteToken))]);
        require(
            address(balancerVault.getPoolTokens(address(bpt))[stPoolTokenIndex]) == address(seniorTranche),
            "DayMarketTestBase: recorded senior pool index does not match the registered token order"
        );
        _initializePoolMinimumSupply();

        // 10. Kernel impl behind its beacon
        kernelBeacon = new UpgradeableBeacon(address(new LocalKernel(IVault(address(balancerVault)))), address(accessManager));

        // 11. Protocol fee recipient wallet must exist before kernel init consumes it
        PROTOCOL_FEE_RECIPIENT = makeAddr("PROTOCOL_FEE_RECIPIENT");

        // 12. Kernel proxy from the dedicated deployer so it lands at the predicted address
        bytes memory kernelInitData = abi.encodeCall(
            RoycoDayBalancerV3Kernel.initialize,
            (
                IRoycoDayKernel.RoycoDayKernelInitParams({
                    initialAuthority: address(accessManager),
                    seniorTranche: address(seniorTranche),
                    juniorTranche: address(juniorTranche),
                    liquidityProviderTranche: address(liquidityProviderTranche),
                    collateralAsset: address(stJtVault),
                    lptAsset: address(bpt),
                    quoteAsset: address(quoteToken),
                    accountant: address(accountant),
                    protocolFeeRecipient: PROTOCOL_FEE_RECIPIENT,
                    stSelfLiquidationBonusWAD: _params.stSelfLiquidationBonusWAD,
                    roycoBlacklist: address(0),
                    collateralAssetOracle: address(collateralAssetOracle),
                    sequencerUptimeFeed: address(0),
                    gracePeriodSeconds: ORACLE_GRACE_PERIOD_SECONDS
                }),
                IBalancerV3LiquidityVenue.BalancerV3LiquidityVenueInitParams({
                    bptOracle: address(bptOracle), maxReinvestmentSlippageWAD: _params.maxReinvestmentSlippageWAD
                })
            )
        );
        vm.prank(kernelProxyDeployer);
        address kernelProxy = address(new BeaconProxy(address(kernelBeacon), kernelInitData));
        require(kernelProxy == predictedKernel, "DayMarketTestBase: kernel proxy address prediction failed");
        kernel = RoycoDayBalancerV3Kernel(kernelProxy);
        vm.label(kernelProxy, "Kernel");

        // 13. Wire the kernel as the senior leg's live rate provider in BOTH price stores
        balancerVault.setTokenRateProvider(address(seniorTranche), kernelProxy);
        bptOracle.setTokenRateProvider(address(seniorTranche), kernelProxy);

        // 14. Role bindings and grants, mirroring the production template
        _wireTargetFunctionRoles();
        _wireBeaconUpgradeRoles();
        _wireRoleGrants();
    }

    /// @dev Writes the storage-resident dust tolerance through the real (restricted, sync-guarded) setter
    function _setDust(uint256 _dust) internal {
        acct.setDustTolerance(toNAVUnits(_dust));
    }

    /// @dev A synced-accounting state with every capacity-relevant field set explicitly (collateral NAV free of conservation)
    function _raw(
        uint256 _collateralNAV,
        uint256 _stEff,
        uint256 _jtEff,
        uint256 _lptRaw,
        uint256 _c,
        uint256 _l
    )
        internal
        pure
        returns (SyncedAccountingState memory s)
    {
        s.marketState = MarketState.PERPETUAL;
        s.collateralNAV = toNAVUnits(_collateralNAV);
        s.stEffectiveNAV = toNAVUnits(_stEff);
        s.jtEffectiveNAV = toNAVUnits(_jtEff);
        s.lptRawNAV = toNAVUnits(_lptRaw);
        s.minCoverageWAD = _c;
        s.minLiquidityWAD = _l;
        s.coverageLiquidationUtilizationWAD = type(uint256).max;
        s.coverageUtilizationWAD = RoycoTestMath.computeCoverageUtilization(_collateralNAV, _c, _jtEff);
        s.liquidityUtilizationWAD = RoycoTestMath.computeLiquidityUtilization(_stEff, _l, _lptRaw);
    }

    /// @dev A conservation-consistent synced-accounting state (collateralNAV == stEffectiveNAV + jtEffectiveNAV)
    function _state(uint256 _stEff, uint256 _jtEff, uint256 _lptRaw, uint256 _c, uint256 _l) internal pure returns (SyncedAccountingState memory) {
        return _raw(_stEff + _jtEff, _stEff, _jtEff, _lptRaw, _c, _l);
    }

    /// @dev Bounds the NAV/dust fuzz domain and commits the fuzzed dust tolerance to storage
    function _domain(uint256 _st, uint256 _jt, uint256 _p, uint256 _d) internal returns (uint256 st, uint256 jt, uint256 p, uint256 d) {
        st = bound(_st, 0, MAX_NAV);
        jt = bound(_jt, 0, MAX_NAV);
        p = bound(_p, 0, MAX_NAV);
        d = bound(_d, 0, MAX_DUST);
        _setDust(d);
    }

    /// @dev Marshals the accountant's committed checkpoint into the state struct the kernel would pass to the capacity views
    function _committedState() internal view returns (SyncedAccountingState memory) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = acct.getState();
        return _raw(
            toUint256(a.lastCollateralNAV),
            toUint256(a.lastSTEffectiveNAV),
            toUint256(a.lastJTEffectiveNAV),
            toUint256(a.lastLPTRawNAV),
            a.minCoverageWAD,
            a.minLiquidityWAD
        );
    }

    /// @dev Live coverage utilization of the deployed market fixture, from the accountant's committed checkpoint
    function _liveCoverageUtilization() internal view returns (uint256) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = accountant.getState();
        return RoycoTestMath.computeCoverageUtilization(toUint256(a.lastCollateralNAV), a.minCoverageWAD, toUint256(a.lastJTEffectiveNAV));
    }

    /// @dev Live liquidity utilization of the deployed market fixture, from the accountant's committed checkpoint
    function _liveLiquidityUtilization() internal view returns (uint256) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = accountant.getState();
        return RoycoTestMath.computeLiquidityUtilization(toUint256(a.lastSTEffectiveNAV), a.minLiquidityWAD, toUint256(a.lastLPTRawNAV));
    }

    /*//////////////////////////////////////////////////////////////////////
        P1 st_deposit_capacity_preserves_coverage
    //////////////////////////////////////////////////////////////////////*/

    /**
     * Property `st_deposit_capacity_preserves_coverage`: on a synced, conservation-consistent state with an active
     * coverage requirement, depositing exactly the reported senior capacity (plus the whole dust pad) keeps
     * (C + m + D) * c <= J * W, i.e. the kernel's ceil-rounded post-op coverage utilization stays at or below 100%
     */
    function testFuzz_st_deposit_capacity_preserves_coverage(uint256 _st, uint256 _jt, uint256 _p, uint256 _c, uint256 _l, uint256 _d) public {
        (uint256 st, uint256 jt, uint256 p, uint256 d) = _domain(_st, _jt, _p, _d);
        uint256 c = bound(_c, 1, WAD - 1);
        uint256 l = bound(_l, 0, WAD - 1);
        uint256 collateral = st + jt;

        uint256 m = toUint256(acct.maxSTDeposit(_state(st, jt, p, c, l)));
        if (m == 0 || m == toUint256(MAX_NAV_UNITS)) return;

        assertLe((collateral + m + d) * c, jt * WAD, "depositing the reported capacity must not breach the coverage requirement");
        assertLe(
            RoycoTestMath.computeCoverageUtilization(collateral + m + d, c, jt),
            WAD,
            "post-deposit coverage utilization (kernel gate math) must stay at or below 100%"
        );
    }

    /*//////////////////////////////////////////////////////////////////////
        P2 st_deposit_capacity_preserves_liquidity
    //////////////////////////////////////////////////////////////////////*/

    /**
     * Property `st_deposit_capacity_preserves_liquidity`: with both legs active, the SAME reported m satisfies the
     * liquidity bound (S + m + D) * l <= P * W and the coverage bound, so the quote is genuinely the minimum of the
     * two active legs and never satisfies one requirement at the expense of the other
     */
    function testFuzz_st_deposit_capacity_preserves_liquidity(uint256 _st, uint256 _jt, uint256 _p, uint256 _c, uint256 _l, uint256 _d) public {
        (uint256 st, uint256 jt, uint256 p, uint256 d) = _domain(_st, _jt, _p, _d);
        uint256 c = bound(_c, 1, WAD - 1);
        uint256 l = bound(_l, 1, WAD - 1);
        uint256 collateral = st + jt;

        uint256 m = toUint256(acct.maxSTDeposit(_state(st, jt, p, c, l)));
        if (m == 0 || m == toUint256(MAX_NAV_UNITS)) return;

        assertLe((st + m + d) * l, p * WAD, "depositing the reported capacity must not breach the liquidity requirement");
        assertLe((collateral + m + d) * c, jt * WAD, "the same reported capacity must simultaneously respect the coverage leg");
        assertLe(
            RoycoTestMath.computeLiquidityUtilization(st + m + d, l, p), WAD, "post-deposit liquidity utilization (kernel gate math) must stay at or below 100%"
        );
    }

    /*//////////////////////////////////////////////////////////////////////
        P3 jt_withdrawal_capacity_preserves_coverage
    //////////////////////////////////////////////////////////////////////*/

    /**
     * Property `jt_withdrawal_capacity_preserves_coverage`: the junior quote never exceeds the junior claim or the
     * collateral backing it, and redeeming exactly it leaves (J - y) * W >= (C - y + D) * c, so the post-op coverage
     * utilization of the symmetric junior redemption stays at or below 100%
     */
    function testFuzz_jt_withdrawal_capacity_preserves_coverage(uint256 _st, uint256 _jt, uint256 _p, uint256 _c, uint256 _d) public {
        (uint256 st, uint256 jt, uint256 p, uint256 d) = _domain(_st, _jt, _p, _d);
        uint256 c = bound(_c, 0, WAD - 1);
        uint256 collateral = st + jt;

        uint256 y = toUint256(acct.maxJTWithdrawal(_state(st, jt, p, c, 0)));
        if (y == 0) return;

        assertLe(y, jt, "the junior quote must never exceed the junior claim");
        assertLe(y, collateral, "the junior quote must never exceed the collateral backing it");
        assertGe((jt - y) * WAD, (collateral - y + d) * c, "redeeming the reported junior capacity must leave the coverage requirement satisfied");
        assertLe(
            RoycoTestMath.computeCoverageUtilization(collateral - y, c, jt - y),
            WAD,
            "post-redemption coverage utilization (kernel gate math) must stay at or below 100%"
        );
    }

    /*//////////////////////////////////////////////////////////////////////
        P4 lpt_withdrawal_capacity_preserves_liquidity
    //////////////////////////////////////////////////////////////////////*/

    /**
     * Property `lpt_withdrawal_capacity_preserves_liquidity`: z <= P always, z == P exactly when no liquidity floor
     * is configured, and otherwise withdrawing z leaves (P - z) * W >= (S + D) * l
     */
    function testFuzz_lpt_withdrawal_capacity_preserves_liquidity(uint256 _st, uint256 _jt, uint256 _p, uint256 _l, uint256 _d, bool _liqActive) public {
        (uint256 st, uint256 jt, uint256 p, uint256 d) = _domain(_st, _jt, _p, _d);
        uint256 l = _liqActive ? bound(_l, 1, WAD - 1) : 0;

        uint256 z = toUint256(acct.maxLPTWithdrawal(_state(st, jt, p, 0, l)));

        assertLe(z, p, "the LPT quote must never exceed the market-making inventory");
        if (l == 0) {
            assertEq(z, p, "with no liquidity floor the whole market-making inventory is withdrawable");
        } else if (z != 0) {
            assertGe((p - z) * WAD, (st + d) * l, "withdrawing the reported depth must not drain the venue below the senior liquidity floor");
            assertLe(
                RoycoTestMath.computeLiquidityUtilization(st, l, p - z),
                WAD,
                "post-withdrawal liquidity utilization (kernel gate math) must stay at or below 100%"
            );
        }
    }

    /*//////////////////////////////////////////////////////////////////////
        P5 zero_capacity_when_requirement_already_breached
    //////////////////////////////////////////////////////////////////////*/

    /**
     * Property `zero_capacity_when_requirement_already_breached`: capacity math saturates to zero rather than
     * advertising headroom in an already-violating state. Both breach regimes are constructed directly (a coverage
     * requirement raised past what the junior buffer can cover, and a market-making inventory below the senior
     * liquidity floor) so the fuzzer spends every run inside the regime under test
     */
    function testFuzz_zero_capacity_when_requirement_already_breached(
        uint256 _st,
        uint256 _jt,
        uint256 _p,
        uint256 _c,
        uint256 _l,
        uint256 _d
    )
        public
    {
        uint256 d = bound(_d, 0, MAX_DUST);
        _setDust(d);

        // --- coverage-breached regime: pick c strictly above the ratio the junior buffer can still cover ---
        {
            // st >= 1e13 keeps cMin = floor(J * W / C) + 1 inside [1, WAD - 1] for every J in the domain
            uint256 st = bound(_st, 1e13, MAX_NAV);
            uint256 jt = bound(_jt, 0, MAX_NAV);
            uint256 p = bound(_p, 0, MAX_NAV);
            uint256 collateral = st + jt;
            uint256 c = bound(_c, Math.mulDiv(jt, WAD, collateral) + 1, WAD - 1);
            SyncedAccountingState memory s = _state(st, jt, p, c, 0);

            assertGt(
                RoycoTestMath.computeCoverageUtilization(collateral, c, jt), WAD, "regime check: the constructed state must have coverage utilization above 100%"
            );
            assertEq(toUint256(acct.maxSTDeposit(s)), 0, "no senior deposit capacity may be advertised while coverage is breached");
            assertEq(toUint256(acct.maxJTWithdrawal(s)), 0, "no junior withdrawal capacity may be advertised while coverage is breached");
        }

        // --- liquidity-breached regime: pick P strictly below the required market-making depth ---
        {
            uint256 st = bound(_st, 1e18, MAX_NAV);
            uint256 jt = bound(_jt, 0, MAX_NAV);
            uint256 l = bound(_l, 1, WAD - 1);
            // S * l >= WAD by the bounds above, so the required depth is at least one NAV wei and this never underflows
            uint256 p = bound(_p, 0, Math.mulDiv(st, l, WAD) - 1);
            SyncedAccountingState memory s = _state(st, jt, p, 0, l);

            assertGt(
                RoycoTestMath.computeLiquidityUtilization(st, l, p), WAD, "regime check: the constructed state must have liquidity utilization above 100%"
            );
            assertEq(toUint256(acct.maxSTDeposit(s)), 0, "no senior deposit capacity may be advertised while liquidity is breached");
            assertEq(toUint256(acct.maxLPTWithdrawal(s)), 0, "no LPT withdrawal capacity may be advertised while liquidity is breached");
        }
    }

    /*//////////////////////////////////////////////////////////////////////
        P6 unlimited_sentinel_only_when_unconstrained
    //////////////////////////////////////////////////////////////////////*/

    /**
     * Property `unlimited_sentinel_only_when_unconstrained`: maxSTDeposit returns the MAX_NAV_UNITS sentinel if and
     * only if BOTH requirements are inactive; whenever either floor is armed the quote is finite and
     * requirement-derived (so the kernel's sentinel special-case can never mis-convert it to MAX_TRANCHE_UNITS)
     */
    function testFuzz_unlimited_sentinel_only_when_unconstrained(
        uint256 _st,
        uint256 _jt,
        uint256 _p,
        uint256 _c,
        uint256 _l,
        uint256 _d,
        bool _covActive,
        bool _liqActive
    )
        public
    {
        (uint256 st, uint256 jt, uint256 p, uint256 d) = _domain(_st, _jt, _p, _d);
        d; // the dust tolerance is committed to storage by _domain
        uint256 c = _covActive ? bound(_c, 1, WAD - 1) : 0;
        uint256 l = _liqActive ? bound(_l, 1, WAD - 1) : 0;

        uint256 m = toUint256(acct.maxSTDeposit(_state(st, jt, p, c, l)));

        assertEq(m == toUint256(MAX_NAV_UNITS), (!_covActive && !_liqActive), "the unlimited sentinel is returned exactly when both requirements are inactive");
        if (_covActive) assertLe(m, Math.mulDiv(jt, WAD, c), "an active coverage floor must yield a finite, requirement-derived quote");
        if (_liqActive) assertLe(m, Math.mulDiv(p, WAD, l), "an active liquidity floor must yield a finite, requirement-derived quote");
    }

    /*//////////////////////////////////////////////////////////////////////
        P7 capacity_monotonicity_in_state_and_dust
    //////////////////////////////////////////////////////////////////////*/

    /**
     * Property `capacity_monotonicity_in_state_and_dust`: every capacity figure moves in the economically correct
     * direction under a marginal change to each input
     *
     * @dev The senior-deposit and LPT-withdrawal legs are unconditional (each is a monotone composition of a floor
     *      or ceil division). The junior-withdrawal leg is unconditional in J, C and D; its monotonicity in
     *      minCoverageWAD additionally needs the state to be conservation-consistent (J <= C) with a senior claim of
     *      at least 2 * WAD: the requirement ceil costs at most one NAV wei, which the 1/(W - c) amplification can
     *      inflate past the marginal tightening when the entire market is worth less than a couple of NAV units
     *      (the sufficient condition S + D >= 2 * WAD is derivable from the closed form). The bound below
     *      (S >= 10 * WAD) sits an order of magnitude inside that condition
     */
    function testFuzz_capacity_monotonicity_in_state_and_dust(
        uint256 _st,
        uint256 _jt,
        uint256 _p,
        uint256 _c,
        uint256 _l,
        uint256 _d,
        uint256 _bump
    )
        public
    {
        uint256 st = bound(_st, 1e19, MAX_NAV);
        uint256 jt = bound(_jt, 0, MAX_NAV);
        uint256 p = bound(_p, 0, MAX_NAV);
        uint256 d = bound(_d, 0, MAX_DUST);
        uint256 c = bound(_c, 1, WAD - 2);
        uint256 l = bound(_l, 1, WAD - 2);
        uint256 bump = bound(_bump, 1, 1e18);
        uint256 collateral = st + jt;
        _setDust(d);

        SyncedAccountingState memory base = _state(st, jt, p, c, l);
        uint256 mBase = toUint256(acct.maxSTDeposit(base));
        uint256 yBase = toUint256(acct.maxJTWithdrawal(base));
        uint256 zBase = toUint256(acct.maxLPTWithdrawal(base));

        uint256 cUp = Math.min(c + bump, WAD - 1);
        uint256 lUp = Math.min(l + bump, WAD - 1);

        // maxSTDeposit: nondecreasing in jtEffectiveNAV and lptRawNAV
        assertGe(toUint256(acct.maxSTDeposit(_raw(collateral, st, jt + bump, p, c, l))), mBase, "maxSTDeposit must be nondecreasing in jtEffectiveNAV");
        assertGe(toUint256(acct.maxSTDeposit(_raw(collateral, st, jt, p + bump, c, l))), mBase, "maxSTDeposit must be nondecreasing in lptRawNAV");
        // maxSTDeposit: nonincreasing in collateralNAV, stEffectiveNAV, minCoverageWAD and minLiquidityWAD
        assertLe(toUint256(acct.maxSTDeposit(_raw(collateral + bump, st, jt, p, c, l))), mBase, "maxSTDeposit must be nonincreasing in collateralNAV");
        assertLe(toUint256(acct.maxSTDeposit(_raw(collateral, st + bump, jt, p, c, l))), mBase, "maxSTDeposit must be nonincreasing in stEffectiveNAV");
        assertLe(toUint256(acct.maxSTDeposit(_raw(collateral, st, jt, p, cUp, l))), mBase, "maxSTDeposit must be nonincreasing in minCoverageWAD");
        assertLe(toUint256(acct.maxSTDeposit(_raw(collateral, st, jt, p, c, lUp))), mBase, "maxSTDeposit must be nonincreasing in minLiquidityWAD");

        // maxJTWithdrawal: nondecreasing in jtEffectiveNAV, nonincreasing in collateralNAV and minCoverageWAD
        assertGe(toUint256(acct.maxJTWithdrawal(_raw(collateral, st, jt + bump, p, c, l))), yBase, "maxJTWithdrawal must be nondecreasing in jtEffectiveNAV");
        assertLe(toUint256(acct.maxJTWithdrawal(_raw(collateral + bump, st, jt, p, c, l))), yBase, "maxJTWithdrawal must be nonincreasing in collateralNAV");
        assertLe(toUint256(acct.maxJTWithdrawal(_raw(collateral, st, jt, p, cUp, l))), yBase, "maxJTWithdrawal must be nonincreasing in minCoverageWAD");

        // maxLPTWithdrawal: nondecreasing in lptRawNAV, nonincreasing in stEffectiveNAV and minLiquidityWAD
        assertGe(toUint256(acct.maxLPTWithdrawal(_raw(collateral, st, jt, p + bump, c, l))), zBase, "maxLPTWithdrawal must be nondecreasing in lptRawNAV");
        assertLe(toUint256(acct.maxLPTWithdrawal(_raw(collateral, st + bump, jt, p, c, l))), zBase, "maxLPTWithdrawal must be nonincreasing in stEffectiveNAV");
        assertLe(toUint256(acct.maxLPTWithdrawal(_raw(collateral, st, jt, p, c, lUp))), zBase, "maxLPTWithdrawal must be nonincreasing in minLiquidityWAD");

        // Every capacity figure is nonincreasing in the dust tolerance
        _setDust(d + bump);
        assertLe(toUint256(acct.maxSTDeposit(base)), mBase, "maxSTDeposit must be nonincreasing in the dust tolerance");
        assertLe(toUint256(acct.maxJTWithdrawal(base)), yBase, "maxJTWithdrawal must be nonincreasing in the dust tolerance");
        assertLe(toUint256(acct.maxLPTWithdrawal(base)), zBase, "maxLPTWithdrawal must be nonincreasing in the dust tolerance");
    }

    /*//////////////////////////////////////////////////////////////////////
        P8 liquidation_state_does_not_widen_capacity
    //////////////////////////////////////////////////////////////////////*/

    /**
     * Property `liquidation_state_does_not_widen_capacity`: the quotes are a function only of
     * (C, S, J, P, c, l, D). Two states that agree on those and disagree on the liquidation threshold (Theta), the
     * market state, the fixed-term end, the carried impermanent loss and the cached utilization/fee fields must
     * quote identically, so a market at or beyond the self-liquidation regime is never quoted MORE capacity
     */
    function testFuzz_liquidation_state_does_not_widen_capacity(
        uint256 _st,
        uint256 _jt,
        uint256 _p,
        uint256 _c,
        uint256 _l,
        uint256 _d,
        uint256 _theta,
        uint32 _end
    )
        public
    {
        (uint256 st, uint256 jt, uint256 p, uint256 d) = _domain(_st, _jt, _p, _d);
        d; // the dust tolerance is committed to storage by _domain
        uint256 c = bound(_c, 1, WAD - 1);
        uint256 l = bound(_l, 1, WAD - 1);

        SyncedAccountingState memory healthy = _state(st, jt, p, c, l);

        // The same NAVs and configuration, but a market sitting at or beyond its liquidation coverage utilization
        SyncedAccountingState memory liquidating = _state(st, jt, p, c, l);
        liquidating.coverageLiquidationUtilizationWAD = bound(_theta, 1, healthy.coverageUtilizationWAD == 0 ? 1 : healthy.coverageUtilizationWAD);
        liquidating.marketState = MarketState.FIXED_TERM;
        liquidating.fixedTermEndTimestamp = _end;
        liquidating.jtImpermanentLoss = toNAVUnits(jt);
        // Deliberately corrupt the cached (non-authoritative) fields too: the quotes must not read them
        liquidating.coverageUtilizationWAD = type(uint256).max;
        liquidating.liquidityUtilizationWAD = type(uint256).max;
        liquidating.lptLiquidityPremium = toNAVUnits(p);
        liquidating.stProtocolFee = toNAVUnits(st);

        assertEq(
            toUint256(acct.maxSTDeposit(liquidating)), toUint256(acct.maxSTDeposit(healthy)), "senior deposit capacity must not depend on the liquidation regime"
        );
        assertEq(
            toUint256(acct.maxJTWithdrawal(liquidating)),
            toUint256(acct.maxJTWithdrawal(healthy)),
            "junior withdrawal capacity must not depend on the liquidation regime"
        );
        assertEq(
            toUint256(acct.maxLPTWithdrawal(liquidating)),
            toUint256(acct.maxLPTWithdrawal(healthy)),
            "LPT withdrawal capacity must not depend on the liquidation regime"
        );
    }

    /*//////////////////////////////////////////////////////////////////////
        P9 capacity_views_never_revert
    //////////////////////////////////////////////////////////////////////*/

    /**
     * Property `capacity_views_never_revert`: for any state satisfying the accountant's own configuration
     * invariants (c < WAD, l < WAD) and any NAV / dust magnitudes inside the realistic domain, all three views
     * return instead of reverting -- these are read through the tranches' maxDeposit / maxRedeem surfaces, so a
     * revert would turn the quoting path into a denial of service
     */
    function testFuzz_capacity_views_never_revert(uint256 _st, uint256 _jt, uint256 _p, uint256 _c, uint256 _l, uint256 _d) public {
        (uint256 st, uint256 jt, uint256 p, uint256 d) = _domain(_st, _jt, _p, _d);
        d; // the dust tolerance is committed to storage by _domain
        uint256 c = bound(_c, 0, WAD - 1);
        uint256 l = bound(_l, 0, WAD - 1);
        SyncedAccountingState memory s = _state(st, jt, p, c, l);

        assertEq(_countRevertingCapacityViews(s), 0, "no capacity view may revert on a state satisfying the accountant's configuration invariants");
    }

    /// @dev Probes all three capacity views and returns how many of them reverted (so no probe is ever skipped)
    function _countRevertingCapacityViews(SyncedAccountingState memory _s) internal returns (uint256 reverting) {
        try acct.maxSTDeposit(_s) returns (NAV_UNIT v) {
            sink = toUint256(v);
        } catch {
            reverting++;
        }
        try acct.maxJTWithdrawal(_s) returns (NAV_UNIT v) {
            sink = toUint256(v);
        } catch {
            reverting++;
        }
        try acct.maxLPTWithdrawal(_s) returns (NAV_UNIT v) {
            sink = toUint256(v);
        } catch {
            reverting++;
        }
    }

    /*//////////////////////////////////////////////////////////////////////
        P10 advisory_capacity_vs_authoritative_gate_off_by_one
    //////////////////////////////////////////////////////////////////////*/

    /**
     * Attack `advisory_capacity_vs_authoritative_gate_off_by_one` (deposit side): an operation sized at exactly the
     * ERC4626-style maxDeposit must neither revert on the kernel's independently recomputed, ceil-rounded post-op
     * gate (a cheap griefing/DoS of maximal deposits and of entry-point fills) nor settle above 100% utilization.
     * Driven end-to-end through tranche -> real kernel -> accountant so the authoritative gate is the one under test
     *
     * @dev At defaultParams (c = 20%, l = 5%, D = 1) and this seed the COVERAGE leg binds and the post-deposit
     *      coverage utilization lands at exactly WAD, so a one-wei rounding disagreement reverts the deposit
     */
    function test_advisory_capacity_vs_authoritative_gate_off_by_one_Deposit() public {
        _deployMarket(cellA(), defaultParams());
        _seedFlatMarket(1000e18, 400e18, 2e8);

        uint256 maxDep = toUint256(seniorTranche.maxDeposit(ST_PROVIDER));
        assertGt(maxDep, 0, "a healthy market must advertise senior deposit capacity");

        // Reverts here iff the advisory quote disagrees with the authoritative gate by even one wei
        uint256 minted = _depositSenior(maxDep);
        assertGt(minted, 0, "the max-sized deposit must be executable");

        assertLe(_liveCoverageUtilization(), WAD, "post-op coverage utilization must settle at or below 100%");
        assertLe(_liveLiquidityUtilization(), WAD, "post-op liquidity utilization must settle at or below 100%");
    }

    /**
     * Attack `advisory_capacity_vs_authoritative_gate_off_by_one` (redemption side): junior and LPT redemptions
     * sized at exactly maxRedeem must clear the authoritative post-op gate and leave both requirements satisfied
     */
    function test_advisory_capacity_vs_authoritative_gate_off_by_one_Redemptions() public {
        _deployMarket(cellA(), defaultParams());
        _seedFlatMarket(1000e18, 400e18, 1e8);

        uint256 jtMax = juniorTranche.maxRedeem(JT_PROVIDER);
        assertGt(jtMax, 0, "a healthy market must advertise junior redemption capacity");
        vm.prank(JT_PROVIDER);
        juniorTranche.redeem(jtMax, JT_PROVIDER, JT_PROVIDER);
        assertLe(_liveCoverageUtilization(), WAD, "post-op coverage utilization must settle at or below 100% after the max junior redemption");

        uint256 lptMax = liquidityProviderTranche.maxRedeem(LPT_PROVIDER);
        assertGt(lptMax, 0, "a healthy market must advertise LPT redemption capacity");
        vm.prank(LPT_PROVIDER);
        liquidityProviderTranche.redeem(lptMax, LPT_PROVIDER, LPT_PROVIDER);
        assertLe(_liveLiquidityUtilization(), WAD, "post-op liquidity utilization must settle at or below 100% after the max LPT redemption");
    }

    /*//////////////////////////////////////////////////////////////////////
        P11 unbounded_dust_tolerance_capacity_dos  (TWO KNOWN-VULNERABILITY TESTS, BOTH EXPECTED TO FAIL)
    //////////////////////////////////////////////////////////////////////*/

    /**
     * Attack `unbounded_dust_tolerance_capacity_dos`, overflow leg -- KNOWN VULNERABILITY, EXPECTED FAILURE
     *
     * dustTolerance is a NAV_UNIT with NO upper bound, settable at any time by the non-delayed
     * ADMIN_MARKET_OPS_ROLE, and it enters every capacity formula additively through a CHECKED add
     * (Units.sol binds NAV_UNIT `+` to a checked addition). This test asserts the attack CANNOT occur, i.e. that
     * no capacity view reverts after a single admissible `setDustTolerance(type(uint256).max)` call.
     *
     * CURRENT BEHAVIOUR (the deviation this test records): all THREE views revert -- `collateralNAV + dust`
     * inside maxSTDeposit and maxJTWithdrawal, and `stEffectiveNAV + dust` inside maxSTDeposit and
     * maxLPTWithdrawal -- so the assertion below fails with a reverting-view count of 3, taking the tranches'
     * maxDeposit / maxRedeem surfaces and every entry-point sizing path down with them
     */
    function test_unbounded_dust_tolerance_capacity_dos() public {
        SyncedAccountingState memory s = _state(1000e18, 200e18, 100e18, 0.1e18, 0.05e18);

        // A single, immediate, non-delayed setter call with no upper-bound validation
        _setDust(type(uint256).max);

        assertEq(
            _countRevertingCapacityViews(s), 0, "an unbounded, non-delayed dust tolerance must not be able to revert the permissionless capacity views"
        );
    }

    /**
     * Attack `unbounded_dust_tolerance_capacity_dos`, freeze leg -- KNOWN VULNERABILITY, EXPECTED FAILURE
     *
     * A merely large (non-overflowing) dust tolerance drives every capacity figure to zero, freezing senior
     * deposits and junior/LPT redemption sizing at the tranche max* surfaces without touching the delay-gated
     * coverage/liquidity parameters. This test asserts the attack CANNOT occur.
     *
     * CURRENT BEHAVIOUR (the deviation this test records): at D = 1e40 against a 1200e18 / 100e18 market ALL
     * THREE quotes saturate to exactly zero, so the assertion below fails with a frozen-view count of 3
     */
    function test_unbounded_dust_tolerance_freezes_capacity() public {
        SyncedAccountingState memory s = _state(1000e18, 200e18, 100e18, 0.1e18, 0.05e18);
        _setDust(1e40);

        uint256 m = toUint256(acct.maxSTDeposit(s));
        uint256 y = toUint256(acct.maxJTWithdrawal(s));
        uint256 z = toUint256(acct.maxLPTWithdrawal(s));
        uint256 frozen = (m == 0 ? 1 : 0) + (y == 0 ? 1 : 0) + (z == 0 ? 1 : 0);

        // Non-fatal magnitude record: only the assertion below may decide this test's outcome
        emit log_named_uint("maxSTDeposit at D = 1e40", m);
        emit log_named_uint("maxJTWithdrawal at D = 1e40", y);
        emit log_named_uint("maxLPTWithdrawal at D = 1e40", z);

        assertEq(frozen, 0, "a large admin-settable dust tolerance must not be able to freeze the senior-deposit and junior/LPT redemption quotes");
    }

    /*//////////////////////////////////////////////////////////////////////
        P12 caller_supplied_state_struct_is_trusted  (TWO KNOWN-VULNERABILITY TESTS, BOTH EXPECTED TO FAIL)
    //////////////////////////////////////////////////////////////////////*/

    /**
     * Attack `caller_supplied_state_struct_is_trusted`, overstatement leg -- KNOWN VULNERABILITY, EXPECTED FAILURE
     *
     * Every NAV and configuration input is taken from the caller-supplied memory struct on a permissionless
     * external view; nothing checks the config fields against the accountant's own storage. This test asserts the
     * attack CANNOT occur, i.e. that a struct understating minCoverageWAD cannot be quoted MORE senior-deposit
     * capacity than the accountant's own configured requirement admits.
     *
     * CURRENT BEHAVIOUR (recorded non-fatally below): at S = 1000e18, J = 200e18, P = 100e18, D = 0 the truthful
     * quote (c = the stored 10%) is 800e18 -- the coverage leg binds -- while the crafted quote (c = 1%) is
     * 1000e18 -- the liquidity leg binds -- a 25% overstatement, so the single assertion below fails
     */
    function test_caller_supplied_state_struct_is_trusted() public {
        uint256 st = 1000e18;
        uint256 jt = 200e18;
        uint256 p = 100e18;
        // The accountant's own, delay-gated requirements
        uint256 storedCoverage = acct.getState().minCoverageWAD;
        uint256 storedLiquidity = acct.getState().minLiquidityWAD;

        uint256 truthful = toUint256(acct.maxSTDeposit(_state(st, jt, p, storedCoverage, storedLiquidity)));
        uint256 crafted = toUint256(acct.maxSTDeposit(_state(st, jt, p, storedCoverage / 10, storedLiquidity)));

        // Non-fatal magnitude record: only the assertion below may decide this test's outcome
        emit log_named_uint("stored minCoverageWAD", storedCoverage);
        emit log_named_uint("quote at the accountant's OWN stored coverage requirement", truthful);
        emit log_named_uint("quote at a crafted, tenfold-understated coverage requirement", crafted);

        assertLe(crafted, truthful, "a crafted (understated) minCoverageWAD must not be able to overstate the advertised capacity");
    }

    /**
     * Attack `caller_supplied_state_struct_is_trusted`, revert leg -- KNOWN VULNERABILITY, EXPECTED FAILURE
     *
     * Nothing validates that the caller-supplied minCoverageWAD respects the accountant's own configuration
     * invariant (c < WAD). This test asserts the attack CANNOT occur, i.e. that the permissionless junior
     * capacity view still returns for a struct carrying c == WAD.
     *
     * CURRENT BEHAVIOUR: maxJTWithdrawal unconditionally evaluates `surplus.mulDiv(WAD, WAD - c)`, so c == WAD
     * makes the denominator zero and the view reverts (and c > WAD underflows it), so the assertion below fails
     */
    function test_caller_supplied_state_struct_underflow_reverts_jt_view() public {
        SyncedAccountingState memory crafted = _state(1000e18, 200e18, 100e18, WAD, acct.getState().minLiquidityWAD);

        bool ok = true;
        try acct.maxJTWithdrawal(crafted) returns (NAV_UNIT v) {
            sink = toUint256(v);
        } catch {
            ok = false;
        }

        assertTrue(ok, "a crafted minCoverageWAD >= WAD must not be able to revert the permissionless junior capacity view");
    }

    /*//////////////////////////////////////////////////////////////////////
        P13 jt_capacity_amplification_assumes_symmetric_nav_delta
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @dev Shared end-to-end probe for `jt_capacity_amplification_assumes_symmetric_nav_delta`: seeds a live
     *      market, reads the junior tranche's ERC4626 maxRedeem (which the kernel derives from the accountant's
     *      amplified maxJTWithdrawal quote), executes the redemption at exactly that size through the production
     *      path, and measures the ACTUAL NAV deltas the kernel booked. The amplification's derivation is only
     *      sound if the executed redemption moves jtEffectiveNAV and collateralNAV by the same amount and leaves
     *      stEffectiveNAV untouched, so this measures exactly that on the real collateral-unit rounding path
     */
    function _probeJTMaxRedeemNAVSymmetry() internal {
        IRoycoDayAccountant.RoycoDayAccountantState memory pre = accountant.getState();

        uint256 jtMax = juniorTranche.maxRedeem(JT_PROVIDER);
        assertGt(jtMax, 0, "a healthy market must advertise junior redemption capacity");

        vm.prank(JT_PROVIDER);
        AssetClaims memory claims = juniorTranche.redeem(jtMax, JT_PROVIDER, JT_PROVIDER);
        assertGt(toUint256(claims.collateralAssets), 0, "the max-sized junior redemption must actually move collateral");

        IRoycoDayAccountant.RoycoDayAccountantState memory post = accountant.getState();
        uint256 deltaCollateral = toUint256(pre.lastCollateralNAV) - toUint256(post.lastCollateralNAV);
        uint256 deltaJunior = toUint256(pre.lastJTEffectiveNAV) - toUint256(post.lastJTEffectiveNAV);

        assertEq(deltaJunior, deltaCollateral, "the executed junior redemption must debit jtEffectiveNAV and collateralNAV by exactly the same NAV");
        assertEq(
            toUint256(post.lastSTEffectiveNAV), toUint256(pre.lastSTEffectiveNAV), "the executed junior redemption must leave the senior claim untouched"
        );
        assertLe(_liveCoverageUtilization(), WAD, "post-op coverage utilization must settle at or below 100% after the max-sized junior redemption");
    }

    /// Attack `jt_capacity_amplification_assumes_symmetric_nav_delta`, baseline 18/18 collateral shape at a unit price
    function test_jt_capacity_amplification_symmetric_nav_delta_cellA() public {
        _deployMarket(cellA(), defaultParams());
        _seedMarket(1000e18, 400e18);
        _probeJTMaxRedeemNAVSymmetry();
    }

    /**
     * Attack `jt_capacity_amplification_assumes_symmetric_nav_delta`, LOSSY NAV <-> tranche-unit round trip: the
     * collateral oracle price is moved off 1.0 to a non-round 1.0377e18 before the probe, so BOTH floor
     * conversions the kernel performs on the redemption path (`convertValueToCollateralAssets` when it turns the
     * NAV-denominated quote into collateral tranche units, and `convertCollateralAssetsToValue` when it marks the
     * units actually moved back to NAV) truncate. This is the collateral-unit rounding asymmetry the attack names:
     * if the executed redemption could debit collateralNAV by even one wei more than jtEffectiveNAV, the
     * amplified quote would leave post-op coverage utilization above 100%
     */
    function test_jt_capacity_amplification_symmetric_nav_delta_LossyPriceRoundTrip() public {
        _deployMarket(cellA(), defaultParams());
        _seedMarket(1000e18, 400e18);
        applySTPnL(377); // collateral oracle price 1.0 -> 1.0377e18, a non-round WAD factor
        _sync(); // commit the revaluation so the probe measures the redemption delta alone
        _probeJTMaxRedeemNAVSymmetry();
    }

    /// Attack `jt_capacity_amplification_assumes_symmetric_nav_delta`, low-decimal (8-dec) collateral shape (cell D):
    /// one collateral tranche unit is worth 1e10 NAV wei here, so the collateral-unit truncation the attack names is coarse
    function test_jt_capacity_amplification_symmetric_nav_delta_cellD_LowDecimalCollateral() public {
        _deployMarket(cellD(), defaultParams());
        _seedMarket(1000e8, 400e8);
        _probeJTMaxRedeemNAVSymmetry();
    }

    /**
     * Attack `jt_capacity_amplification_assumes_symmetric_nav_delta`, unit leg: the accountant's own post-op branch
     * derives the junior debit from the single observed collateral delta and re-checks byte-exact NAV
     * conservation, so no executed junior redemption of any size up to the quote can produce an asymmetric split
     */
    function testFuzz_jt_capacity_amplification_postop_conservation(uint256 _st, uint256 _jt, uint256 _exec, uint256 _d) public {
        uint256 st = bound(_st, 1e18, 1e27);
        uint256 jt = bound(_jt, st / 4, st);
        _setDust(bound(_d, 0, 1e12));

        // Seed a committed checkpoint through legal kernel calls only
        mkKernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(st), ZERO_NAV_UNITS, ZERO_NAV_UNITS);
        mkKernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(st + jt), ZERO_NAV_UNITS, ZERO_NAV_UNITS);

        uint256 y = toUint256(acct.maxJTWithdrawal(_committedState()));
        if (y == 0) return;
        uint256 exec = bound(_exec, 1, y);

        SyncedAccountingState memory post = mkKernel.doPostOp(Operation.JT_REDEMPTION, toNAVUnits(st + jt - exec), ZERO_NAV_UNITS, ZERO_NAV_UNITS);

        assertEq(toUint256(post.jtEffectiveNAV), jt - exec, "the junior claim is debited exactly the executed collateral debit");
        assertEq(toUint256(post.stEffectiveNAV), st, "the senior claim is untouched by a junior redemption");
        assertEq(toUint256(post.collateralNAV), st + jt - exec, "NAV conservation is re-checked byte-exact at post-op");
        assertLe(post.coverageUtilizationWAD, WAD, "post-op coverage utilization must stay at or below 100% for any executed size up to the quote");
    }

    /*//////////////////////////////////////////////////////////////////////
        P14 multi_asset_relief_amplifies_dust_padded_capacity
    //////////////////////////////////////////////////////////////////////*/

    /**
     * Attack `multi_asset_relief_amplifies_dust_padded_capacity`: lptMaxRedeemableMultiAsset scales the accountant's
     * dust-padded maxLPTWithdrawal by lptRawNAV / (lptRawNAV - liquidityRequirementReduction), where the reduction
     * estimates the senior liquidity requirement relieved by redeeming the senior shares recovered in-flow. The
     * amplification only exists when the venue actually holds a SENIOR leg, so this fixture seeds the pool with
     * 100e18 senior tranche shares alongside its quote leg and pins that the quote is STRICTLY widened. A
     * multi-asset redemption sized at exactly the amplified figure must then still settle without reverting at flow
     * exit and must leave the senior liquidity requirement satisfied
     */
    function test_multi_asset_relief_amplifies_dust_padded_capacity() public {
        _deployMarket(cellA(), defaultParams());
        _seedMarket(1000e18, 1000e18);
        // A pool leg with a real SENIOR side: 100e18 ST shares (1 NAV each at the seeded rate) + 100e6 quote wei
        // (1e12 NAV each), minted 1:1 with the 200e18 NAV it adds so NAV-per-BPT stays exactly 1.0
        _seedLPT(200e18, 100e18, 100e6);

        uint256 inkindMax = liquidityProviderTranche.maxRedeem(LPT_PROVIDER);
        uint256 multiMax = liquidityProviderTranche.maxRedeemMultiAsset(LPT_PROVIDER);
        assertGt(inkindMax, 0, "a healthy market must advertise in-kind LPT redemption capacity");
        assertGt(multiMax, inkindMax, "the in-flow senior-share relief must STRICTLY widen the multi-asset quote over the in-kind bound");

        // Reverts here iff the amplification pushed the quote past what the settled flow can actually support
        vm.prank(LPT_PROVIDER);
        liquidityProviderTranche.redeemMultiAsset(multiMax, 0, 0, LPT_PROVIDER, LPT_PROVIDER);

        assertLe(_liveLiquidityUtilization(), WAD, "the max-sized multi-asset redemption must leave the senior liquidity requirement satisfied");
    }

    /*//////////////////////////////////////////////////////////////////////
        P15 dust_padding_worth_full_dust_tolerance_in_operation_units
    //////////////////////////////////////////////////////////////////////*/

    /**
     * Property `dust_padding_worth_full_dust_tolerance_in_operation_units`, leg (a) (the senior deposit leg):
     * an operation sized at the reported capacity PLUS the whole configured dust tolerance still satisfies both
     * requirements, i.e. on the deposit side the padding really is worth a full D measured in deposit units
     */
    function testFuzz_dust_padding_worth_full_dust_tolerance_in_deposit_units(
        uint256 _st,
        uint256 _jt,
        uint256 _p,
        uint256 _c,
        uint256 _l,
        uint256 _d
    )
        public
    {
        (uint256 st, uint256 jt, uint256 p, uint256 d) = _domain(_st, _jt, _p, _d);
        uint256 c = bound(_c, 1, WAD - 1);
        uint256 l = bound(_l, 1, WAD - 1);
        uint256 collateral = st + jt;

        uint256 m = toUint256(acct.maxSTDeposit(_state(st, jt, p, c, l)));
        if (m == 0 || m == toUint256(MAX_NAV_UNITS)) return;

        assertLe((collateral + m + d) * c, jt * WAD, "(a) the senior padding must be worth a full dust tolerance against the coverage requirement");
        assertLe((st + m + d) * l, p * WAD, "(a) the senior padding must be worth a full dust tolerance against the liquidity requirement");
    }

    /**
     * Property `dust_padding_worth_full_dust_tolerance_in_operation_units`, leg (b) -- KNOWN DEVIATION, EXPECTED FAILURE
     *
     * The pad is added INSIDE the coverage inequality (`requiredJTValue = ceil((C + D) * c / W)`), not in the units
     * of the junior redemption being sized, so it is worth only about D * c / (W - c) extra NAV of junior exit
     * rather than a full D. This test asserts leg (b) as stated: (J - y - D) * W >= (C - y - D) * c.
     *
     * CURRENT BEHAVIOUR (recorded non-fatally below): at C = 1200e18, S = 1000e18, J = 200e18, c = 10%, D = 10 the
     * reported junior capacity is y = 88888888888888888887. Coverage holds at exactly y, but at y + D the left
     * side falls 7.3e18 short of the right, so the single assertion below fails: the padding is worth ~1.11 NAV wei
     * of extra junior redemption, not the 10 the property asks for
     */
    function test_dust_padding_not_worth_full_dust_in_jt_redemption_units() public {
        uint256 st = 1000e18;
        uint256 jt = 200e18;
        uint256 d = 10;
        uint256 c = 0.1e18;
        uint256 collateral = st + jt;
        _setDust(d);

        uint256 y = toUint256(acct.maxJTWithdrawal(_state(st, jt, 100e18, c, 0.05e18)));

        // Non-fatal magnitude record: only the assertion below may decide this test's outcome
        emit log_named_uint("reported junior capacity y (C = 1200e18, c = 10%, D = 10)", y);
        emit log_named_uint("coverage LHS at exactly y: (J - y) * W", (jt - y) * WAD);
        emit log_named_uint("coverage RHS at exactly y: (C - y) * c", (collateral - y) * c);
        emit log_named_uint("coverage LHS at y + D: (J - y - D) * W", (jt - y - d) * WAD);
        emit log_named_uint("coverage RHS at y + D: (C - y - D) * c", (collateral - y - d) * c);

        assertGe((jt - y - d) * WAD, (collateral - y - d) * c, "(b) the junior padding must be worth a full dust tolerance in redemption units");
    }

    /**
     * Property `dust_padding_worth_full_dust_tolerance_in_operation_units`, leg (c) -- KNOWN DEVIATION, EXPECTED FAILURE
     *
     * The pad is added INSIDE the liquidity inequality (`requiredLPTValue = ceil((S + D) * l / W)`), so it is worth
     * only about D * l / W extra NAV of LPT withdrawal -- zero at any realistic scale. This test asserts leg (c) as
     * stated: (P - z - D) * W >= S * l.
     *
     * CURRENT BEHAVIOUR (recorded non-fatally below): at S = 1000e18, P = 100e18, l = 5%, D = 10 the reported LPT
     * capacity is z = 49999999999999999999. The floor holds at exactly z, but at z + D the left side falls 9e18
     * short of the right, so the single assertion below fails: the padding buys 0 NAV wei of extra withdrawal here
     */
    function test_dust_padding_not_worth_full_dust_in_lpt_withdrawal_units() public {
        uint256 st = 1000e18;
        uint256 p = 100e18;
        uint256 d = 10;
        uint256 l = 0.05e18;
        _setDust(d);

        uint256 z = toUint256(acct.maxLPTWithdrawal(_state(st, 200e18, p, 0.1e18, l)));

        // Non-fatal magnitude record: only the assertion below may decide this test's outcome
        emit log_named_uint("reported LPT capacity z (S = 1000e18, P = 100e18, l = 5%, D = 10)", z);
        emit log_named_uint("liquidity LHS at exactly z: (P - z) * W", (p - z) * WAD);
        emit log_named_uint("liquidity LHS at z + D: (P - z - D) * W", (p - z - d) * WAD);
        emit log_named_uint("liquidity RHS: S * l", st * l);

        assertGe((p - z - d) * WAD, st * l, "(c) the LPT padding must be worth a full dust tolerance in withdrawal units");
    }

    /*//////////////////////////////////////////////////////////////////////
        P16 no_spurious_zero_capacity_in_healthy_market
    //////////////////////////////////////////////////////////////////////*/

    /**
     * Property `no_spurious_zero_capacity_in_healthy_market`: a market that satisfies both requirements with
     * strictly positive dust-padded slack is quoted strictly positive capacity (a spurious zero silently no-ops
     * entry-point deposit executions and stalls queued redemption fills until expiry)
     *
     * @dev The states are DERIVED rather than assumed so every run lands inside the healthy regime, and the slack
     *      is derived at one full operation-unit rather than one indivisible NAV wei: the quotes are integer
     *      floors, so a slack below the granularity of a single unit of the operation being sized (c NAV wei of
     *      coverage slack per deposit wei, W NAV wei of coverage slack per junior-redemption wei, W NAV wei of
     *      liquidity slack per LPT-withdrawal wei) is by construction unreportable
     */
    function testFuzz_no_spurious_zero_capacity_in_healthy_market(uint256 _st, uint256 _jt, uint256 _c, uint256 _l, uint256 _d, uint256 _extra) public {
        uint256 st = bound(_st, 1e18, 1e27);
        uint256 jt = bound(_jt, 1e18, 1e27);
        uint256 d = bound(_d, 0, 1e18);
        uint256 l = bound(_l, 1, WAD - 1);
        uint256 collateral = st + jt;
        _setDust(d);

        // One full operation-unit of coverage slack: c * (C + D + 1) <= (J - 1) * W
        uint256 c = bound(_c, 1, Math.min(Math.mulDiv(jt - 1, WAD, collateral + d + 1), WAD - 1));
        // One full operation-unit of liquidity slack: P >= ceil((S + D) * l / W) + 1
        uint256 p = Math.mulDiv(st + d, l, WAD, Math.Rounding.Ceil) + 1 + bound(_extra, 0, 1e27);

        SyncedAccountingState memory s = _state(st, jt, p, c, l);

        assertGt(jt * WAD, (collateral + d) * c, "regime check: the coverage requirement must be strictly slack");
        assertGt(p * WAD, (st + d) * l, "regime check: the liquidity requirement must be strictly slack");

        assertGt(toUint256(acct.maxSTDeposit(s)), 0, "a healthy market must quote strictly positive senior deposit capacity");
        assertGt(toUint256(acct.maxJTWithdrawal(s)), 0, "a healthy market must quote strictly positive junior withdrawal capacity");
        assertGt(toUint256(acct.maxLPTWithdrawal(s)), 0, "a healthy market must quote strictly positive LPT withdrawal capacity");
    }

    /*//////////////////////////////////////////////////////////////////////
        P17 capacity_quotes_are_tight_to_within_dust_padding
    //////////////////////////////////////////////////////////////////////*/

    /**
     * Property `capacity_quotes_are_tight_to_within_dust_padding`, legs (a) and (c) plus the two zero-requirement
     * identities: the senior-deposit quote under-reports the exact boundary min(x*, x'*) by at most D + 1, the LPT
     * quote under-reports z* by at most D * l / W + 1, and with a disabled requirement the quote is the exact claim
     */
    function testFuzz_capacity_quotes_are_tight_to_within_dust_padding(
        uint256 _st,
        uint256 _jt,
        uint256 _p,
        uint256 _c,
        uint256 _l,
        uint256 _d,
        bool _covActive,
        bool _liqActive
    )
        public
    {
        (uint256 st, uint256 jt, uint256 p, uint256 d) = _domain(_st, _jt, _p, _d);
        uint256 c = _covActive ? bound(_c, 1, WAD - 1) : 0;
        uint256 l = _liqActive ? bound(_l, 1, WAD - 1) : 0;
        uint256 collateral = st + jt;
        SyncedAccountingState memory s = _state(st, jt, p, c, l);

        // (a) x* = largest x with (C + x) * c <= J * W ; x'* = largest x with (S + x) * l <= P * W
        uint256 xStar = (c == 0) ? type(uint256).max : Math.saturatingSub(Math.mulDiv(jt, WAD, c), collateral);
        uint256 xpStar = (l == 0) ? type(uint256).max : Math.saturatingSub(Math.mulDiv(p, WAD, l), st);
        assertGe(
            toUint256(acct.maxSTDeposit(s)),
            Math.saturatingSub(Math.min(xStar, xpStar), d + 1),
            "the senior deposit quote must be tight to the exact boundary within the dust padding"
        );

        // (c) z* = largest z with (P - z) * W >= S * l
        uint256 zStar = (l == 0) ? p : Math.saturatingSub(p, Math.mulDiv(st, l, WAD, Math.Rounding.Ceil));
        assertGe(
            toUint256(acct.maxLPTWithdrawal(s)),
            Math.saturatingSub(zStar, Math.mulDiv(d, l, WAD) + 1),
            "the LPT withdrawal quote must be tight to the exact boundary within the dust padding"
        );

        // Zero-requirement identities
        if (c == 0) assertEq(toUint256(acct.maxJTWithdrawal(s)), jt, "with no coverage floor the entire junior claim must be withdrawable");
        if (l == 0) assertEq(toUint256(acct.maxLPTWithdrawal(s)), p, "with no liquidity floor the entire inventory must be withdrawable");
    }

    /**
     * Property `capacity_quotes_are_tight_to_within_dust_padding`, leg (b) -- KNOWN DEVIATION, EXPECTED FAILURE
     *
     * The junior quote first CEILs the dust-padded requirement and only then amplifies the surplus by W / (W - c),
     * so a sub-wei ceiling artifact is magnified by up to W / (W - c). The property allows an under-report of at
     * most D * W / (W - c) + 1, which at D == 0 is 1.
     *
     * CURRENT BEHAVIOUR (recorded non-fatally below): at J = 1090e18, C = 1200e18 + 5 (so S = 110e18 + 5 > 0),
     * c = 90%, D = 0 the exact boundary is y* = 100e18 - 45 while the reported quote is y = 100e18 - 50, an
     * under-report of 5 NAV wei where the property allows 1, so the single assertion below fails. The true bound
     * is (D * c + W) / (W - c) + 1
     */
    function test_capacity_quote_tightness_jt_leg_counterexample() public {
        uint256 jt = 1090e18;
        uint256 collateral = 1200e18 + 5;
        uint256 st = collateral - jt;
        uint256 c = 0.9e18;
        _setDust(0);

        uint256 y = toUint256(acct.maxJTWithdrawal(_state(st, jt, 0, c, 0)));
        uint256 yStar = (jt * WAD - collateral * c) / (WAD - c);

        // Non-fatal magnitude record: only the assertion below may decide this test's outcome
        emit log_named_uint("reported junior capacity y", y);
        emit log_named_uint("exact coverage boundary y*", yStar);

        // Property (b) with D == 0: y >= y* - 1
        assertGe(y + 1, yStar, "the junior quote must under-report the exact coverage boundary by at most the dust allowance");
    }

    /*//////////////////////////////////////////////////////////////////////
        P18 dust_capacity_quote_unexecutable_zero_share_mint
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @dev Shared deposit-side probe for `dust_capacity_quote_unexecutable_zero_share_mint`: consumes all but one
     *      collateral tranche unit of the advertised headroom, then re-reads maxDeposit and requires the residual
     *      quote (the smallest figure the surface can advertise) to be executable -- i.e. to convert to a non-zero
     *      collateral amount AND price to a non-zero senior share mint (MUST_MINT_NON_ZERO_SHARES)
     */
    function _probeAdvertisedDepositIsExecutable() internal {
        uint256 maxDep = toUint256(seniorTranche.maxDeposit(ST_PROVIDER));
        assertGt(maxDep, 1, "a healthy market must advertise senior deposit capacity");

        assertGt(_depositSenior(maxDep - 1), 0, "a near-max advertised deposit must mint a non-zero senior share amount");

        uint256 residual = toUint256(seniorTranche.maxDeposit(ST_PROVIDER));
        // Correct behaviour is EITHER a zero quote (nothing advertised below the executable granularity) OR an
        // executable one; a strictly positive quote that mints zero shares would revert here
        if (residual != 0) {
            assertGt(_depositSenior(residual), 0, "the smallest advertised deposit must mint a non-zero senior share amount");
        }
    }

    /// Attack `dust_capacity_quote_unexecutable_zero_share_mint`, deposit side, baseline 18/18 collateral shape
    function test_dust_capacity_quote_unexecutable_zero_share_mint_Deposit_cellA() public {
        _deployMarket(cellA(), defaultParams());
        _seedMarket(1000e18, 400e18);
        _probeAdvertisedDepositIsExecutable();
    }

    /**
     * Attack `dust_capacity_quote_unexecutable_zero_share_mint`, deposit side, LOW-DECIMAL collateral (cell D):
     * the collateral share carries 8 decimals, so one collateral tranche unit is worth 1e10 NAV wei and the
     * kernel's floor conversion of the NAV-denominated advisory quote into tranche units is a real, coarse
     * truncation -- exactly the granularity gap the attack targets
     */
    function test_dust_capacity_quote_unexecutable_zero_share_mint_Deposit_cellD_LowDecimalCollateral() public {
        _deployMarket(cellD(), defaultParams());
        _seedMarket(1000e8, 400e8);
        _probeAdvertisedDepositIsExecutable();
    }

    /**
     * Attack `dust_capacity_quote_unexecutable_zero_share_mint`, redemption side, on the low-decimal (cell D)
     * shape: a maxRedeem-sized redemption must not burn shares whose floor-scaled asset claims are zero
     */
    function test_dust_capacity_quote_unexecutable_zero_share_mint_Redemptions_cellD() public {
        _deployMarket(cellD(), defaultParams());
        _seedMarket(1000e8, 400e8);

        uint256 jtMax = juniorTranche.maxRedeem(JT_PROVIDER);
        assertGt(jtMax, 0, "a healthy market must advertise junior redemption capacity");
        vm.prank(JT_PROVIDER);
        AssetClaims memory jtClaims = juniorTranche.redeem(jtMax, JT_PROVIDER, JT_PROVIDER);
        assertGt(toUint256(jtClaims.collateralAssets), 0, "the max-sized junior redemption must remit a non-zero collateral amount");

        uint256 lptMax = liquidityProviderTranche.maxRedeem(LPT_PROVIDER);
        assertGt(lptMax, 0, "a healthy market must advertise LPT redemption capacity");
        vm.prank(LPT_PROVIDER);
        AssetClaims memory lptClaims = liquidityProviderTranche.redeem(lptMax, LPT_PROVIDER, LPT_PROVIDER);
        assertGt(toUint256(lptClaims.lptAssets), 0, "the max-sized LPT redemption must remit a non-zero venue asset amount");
    }
}
