// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { AccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { RoycoDayAccountant } from "../../../src/accountant/RoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import {
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel as ShippedKernel
} from "../../../src/kernels/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel.sol";
import {
    IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter
} from "../../../src/kernels/base/quoter/identical-st-jt/IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter.sol";
import {
    IdenticalAssets_ST_JT_AdminOracle_Quoter
} from "../../../src/kernels/base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_AdminOracle_Quoter.sol";
import {
    IdenticalAssets_ST_JT_ChainlinkOracle_Quoter
} from "../../../src/kernels/base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.sol";
import { IdenticalAssets_ST_JT_Oracle_Quoter } from "../../../src/kernels/base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_Oracle_Quoter.sol";
import { BalancerV3_LT_BPTOracle_Quoter } from "../../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_BPTOracle_Quoter.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoJuniorTranche } from "../../../src/tranches/RoycoJuniorTranche.sol";
import { RoycoLiquidityTranche } from "../../../src/tranches/RoycoLiquidityTranche.sol";
import { RoycoSeniorTranche } from "../../../src/tranches/RoycoSeniorTranche.sol";
import {
    Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3_BPTOracle_LT_Kernel as ChainlinkToAdminKernel
} from "../../mocks/Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3_BPTOracle_LT_Kernel.sol";
import { MockAggregatorV3 } from "../../mocks/MockAggregatorV3.sol";
import { MockBPT } from "../../mocks/MockBPT.sol";
import { MockBPTOracle } from "../../mocks/MockBPTOracle.sol";
import { MockBalancerVault } from "../../mocks/MockBalancerVault.sol";
import { MockERC4626C } from "../../mocks/MockERC4626C.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_AdminOracleQuoter_ChainlinkToAdmin
 * @notice Exercises the Chainlink-to-admin ST/JT quoter composition, where the tranche asset is priced into a
 *         reference asset by a Chainlink feed and the reference asset is priced into NAV units by an admin rate
 * @dev This composition inverts the shipped stored-rate-overrides-oracle family: the stored rate here is a mandatory
 *      second pricing hop rather than an oracle bypass, so zero (the resume-the-oracle sentinel elsewhere) must be
 *      rejected at initialize and by the setter, and every Chainlink sanity gate must keep biting with a rate stored
 * @dev The quoter ships abstract with no concrete kernel wiring it, so the tests drive it through a test-only kernel
 *      that composes it with the Balancer V3 LT quoter, deployed with the same order and role wiring as the shipped
 *      market fixture with only the kernel implementation swapped
 * @dev The market stays unseeded: conversion rates are independent of tranche NAVs, and the setter's internal
 *      accounting syncs pass trivially at zero NAVs, isolating the two-hop pricing math under test
 */
contract Test_AdminOracleQuoter_ChainlinkToAdmin is DayMarketTestBase {
    /// @dev The admin-set reference asset to NAV unit rate the market is initialized with (1.0, so the feed alone decides the initial composed rate)
    uint256 internal constant INITIAL_ADMIN_RATE_WAD = 1e18;

    /// @notice The kernel proxy under its concrete Chainlink-to-admin type (same address as the base's `kernel` handle)
    ChainlinkToAdminKernel internal adminKernel;

    /// @notice The construction params of the deployed kernel, kept so init-revert tests can build fresh impls against the same market plumbing
    IRoycoDayKernel.RoycoDayKernelConstructionParams internal kernelConstructionParams;

    function setUp() public {
        _deployChainlinkToAdminMarket();
    }

    // =============================
    // Initialization gate (the zero rate must fail at config, not at first sync)
    // =============================

    /**
     * @notice Initializing the quoter with a zero conversion rate is rejected outright
     * @dev In this composition the reference-to-NAV hop is admin-rate-only: zero is the query-the-oracle sentinel,
     *      and the oracle-query helper is a hard revert, so a zero initial rate would deploy a market whose every
     *      conversion (and therefore every sync, deposit, and redemption) reverts at first use. The config gate
     *      must catch that at initialize instead of letting a bricked market ship
     */
    function test_RevertIf_InitializedWithZeroConversionRate() public {
        // A fresh implementation against the already-deployed market plumbing (same tranches, accountant, and registered pool)
        ChainlinkToAdminKernel freshImpl = new ChainlinkToAdminKernel(kernelConstructionParams);
        bytes memory initData = abi.encodeCall(freshImpl.initialize, (_standardKernelInitParams(), _kernelSpecificInitParams(0)));
        vm.expectRevert(IdenticalAssets_ST_JT_AdminOracle_Quoter.INVALID_CONVERSION_RATE.selector);
        new ERC1967Proxy(address(freshImpl), initData);
    }

    // =============================
    // The zero-rate setter gate (the sentinel never resumes an oracle path here)
    // =============================

    /**
     * @notice setConversionRate(0) is rejected and the stored rate is untouched
     * @dev Pins that the override chain dispatches to the zero-rejecting admin setter: in the stored-rate-overrides-
     *      oracle family a 0 means resume-the-oracle, but this composition has no reference-to-NAV oracle to resume,
     *      so accepting 0 would leave every subsequent conversion reverting in the unreachable-backstop helper.
     *      A regression that resolves the diamond to the permissive base setter would make 0 land silently
     */
    function test_RevertIf_ConversionRateSetToZero_SentinelNeverRestoresAnOraclePath() public {
        vm.prank(ORACLE_QUOTER_ADMIN);
        vm.expectRevert(IdenticalAssets_ST_JT_AdminOracle_Quoter.INVALID_CONVERSION_RATE.selector);
        adminKernel.setConversionRate(0, false);

        // The failed set must not have touched storage: the rate is still the 1.0 the market was initialized with
        assertEq(adminKernel.getStoredConversionRateWAD(), INITIAL_ADMIN_RATE_WAD, "a rejected zero rate must leave the stored rate unchanged");
    }

    // =============================
    // Two-hop pricing (Chainlink price x admin rate)
    // =============================

    /**
     * @notice One whole tranche unit quotes at the Chainlink price times the admin rate, on both tranches, and the
     *         inverse conversion round-trips back to one whole unit
     * @dev Hand-composed: the 8-decimal feed at 2e8 is a 2.0 tranche-asset-to-reference price, the admin second hop
     *      is 1.5, so 1 tranche unit = 2.0 x 1.5 = 3.0 NAV units, i.e. exactly 3e18 for one 18-decimal unit.
     *      Neither hop alone (2e18 or 1.5e18) is the right answer, so this pins that both hops are actually composed
     */
    function test_TrancheUnitPricing_ChainlinkPriceTimesAdminRate() public {
        // Feed to 2.0 (2e8 at 8 decimals), admin second hop to 1.5 (setAnswer never touches freshness, the feed stays fresh)
        priceFeed.setAnswer(2e8);
        vm.prank(ORACLE_QUOTER_ADMIN);
        adminKernel.setConversionRate(1.5e18, false);

        // Composed rate: 2e8 x 1.5e18 / 1e8 = 3e18, so one whole unit is 1e18 x 3e18 / 1e18 = 3e18 NAV
        assertEq(toUint256(adminKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 3e18, "one whole senior unit must quote 2.0 x 1.5 = 3.0 NAV");
        assertEq(toUint256(adminKernel.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 3e18, "the junior side shares the identical composed rate");

        // The inverse divides by the same composed rate: 3e18 NAV x 1e18 / 3e18 = 1e18 tranche units, an exact round-trip
        assertEq(toUint256(adminKernel.stConvertNAVUnitsToTrancheUnits(toNAVUnits(uint256(3e18)))), 1e18, "3.0 NAV must invert to exactly one whole senior unit");
        assertEq(toUint256(adminKernel.jtConvertNAVUnitsToTrancheUnits(toNAVUnits(uint256(3e18)))), 1e18, "3.0 NAV must invert to exactly one whole junior unit");
    }

    // =============================
    // Chainlink gates with an admin rate stored (the rate is a second hop, never an oracle bypass)
    // =============================

    /**
     * @notice A stored admin rate does not bypass the Chainlink sanity gates: a stale feed answer and a zero feed
     *         answer both still revert
     * @dev This is the exact inversion of the stored-rate-overrides-oracle family, where a nonzero stored rate
     *      short-circuits the feed entirely. Here the stored rate only prices the second hop, so if the gates
     *      stopped biting a dead feed would silently keep pricing the market off its last admin rate
     */
    function test_ChainlinkGatesStillBiteWithAdminRateSet() public {
        // The admin rate is stored and nonzero for the whole test (1.0 from initialization)
        assertEq(adminKernel.getStoredConversionRateWAD(), INITIAL_ADMIN_RATE_WAD, "the initialized admin rate must be in storage");

        // At exactly the staleness threshold the answer still prices: feed 1.0 x admin 1.0 = 1e18 per whole unit
        vm.warp(block.timestamp + ORACLE_STALENESS_THRESHOLD_SECONDS);
        assertEq(toUint256(adminKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 1e18, "an answer aged exactly the threshold must still price");

        // One second past the threshold the staleness gate bites, admin rate or not
        vm.warp(block.timestamp + 1);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.STALE_PRICE.selector);
        adminKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18));

        // A fresh but zero answer is a broken feed, not a price of zero, and must also revert through the stored rate
        priceFeed.setUpdatedAt(block.timestamp);
        priceFeed.setAnswer(0);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.INVALID_PRICE.selector);
        adminKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18));
    }

    // =============================
    // Repricing the second hop
    // =============================

    /**
     * @notice setConversionRate emits, lands in storage, and moves every quote to feedPrice x newRate
     * @dev With the feed still at its initial 1.0 (1e8 at 8 decimals), doubling the second hop to 2.0 must move a
     *      whole-unit quote to exactly 1.0 x 2.0 = 2e18: the feed hop is unchanged, so the delta is purely the admin rate
     */
    function test_SetConversionRate_RepricesSecondHopAndEmits() public {
        vm.expectEmit(address(adminKernel));
        emit IdenticalAssets_ST_JT_Oracle_Quoter.ConversionRateUpdated(2e18);
        vm.prank(ORACLE_QUOTER_ADMIN);
        adminKernel.setConversionRate(2e18, true);

        assertEq(adminKernel.getStoredConversionRateWAD(), 2e18, "the new second-hop rate must land in quoter storage");
        assertEq(toUint256(adminKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 2e18, "one whole unit must quote feed 1.0 x admin 2.0 = 2e18");
    }

    /**
     * @notice An unprivileged caller cannot set the conversion rate, and the failed attempt leaves storage untouched
     * @dev The second hop is a full market repricing lever: a hostile 2x rate would double every senior and junior
     *      mark at the very next sync, so the setter must be gated to the oracle-quoter admin
     */
    function test_RevertIf_SetConversionRateCalledByNonAdmin() public {
        address attacker = makeAddr("ATTACKER");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, attacker));
        adminKernel.setConversionRate(2e18, false);

        assertEq(adminKernel.getStoredConversionRateWAD(), INITIAL_ADMIN_RATE_WAD, "the stored rate must be untouched by the failed attempt");
    }

    // =============================
    // The unreachable oracle-query backstop
    // =============================

    /**
     * @notice The internal oracle-query helper is a hard revert in this composition
     * @dev The composed rate resolution falls back to this helper only when the stored rate reads the zero sentinel,
     *      and the init and setter gates above reject zero, so through the guarded lifecycle the fallback branch is
     *      unreachable. Pinning the helper's revert documents WHY that is safe: if the zero gates ever regressed,
     *      the failure mode is this loud revert on every conversion rather than a silent price of zero
     */
    function test_OracleQueryHelperRevertsAsUnreachableBackstop() public {
        vm.expectRevert(IdenticalAssets_ST_JT_AdminOracle_Quoter.MUST_USE_ADMIN_ORACLE_INPUT.selector);
        adminKernel.exposed_getConversionRateFromOracleWAD();
    }

    // =============================
    // Fixture: the shipped market deployment order with the kernel implementation swapped
    // =============================

    /**
     * @notice Deploys the full Day market exactly like the shipped fixture, swapping in the Chainlink-to-admin kernel
     * @dev Mirrors the base deployment order 1:1 (tokens, oracles, venue, YDMs, predicted kernel address, impls,
     *      tranche and accountant proxies, pool registration, kernel impl, kernel proxy, role wiring) so the quoter
     *      under test runs behind production-shaped proxies and roles. Only the kernel implementation and its
     *      quoter-specific init params differ from the base's _deployMarket
     */
    function _deployChainlinkToAdminMarket() internal {
        cell = cellA();
        params = defaultParams();

        // Access manager, admin'd by the fixture so role wiring needs no schedule/execute dance
        accessManager = new AccessManager(address(this));

        // Tokens: quote stable + one shared vault share for both ST and JT (the quoter family requires identical assets)
        quoteToken = _deployERC20("Quote Stable", "QUOTE", cell.quoteAsset);
        stJtUnderlying = _deployERC20("ST/JT Underlying", "UNDR", _toUnderlyingConfig(cell.stAsset));
        stJtVault = new MockERC4626C(address(stJtUnderlying), "ST/JT Vault Share", "vSHARE", cell.stAsset.decimals);
        stJtVault.setRate(cell.stAsset.initialRateWAD);

        // Oracles: the tranche-asset-to-reference-asset feed at 1.0 (8 decimals), sequencer checks disabled at init
        priceFeed = new MockAggregatorV3(PRICE_FEED_DECIMALS, PRICE_FEED_INITIAL_ANSWER);

        // Venue: mock Balancer vault, the BPT it ledgers, and the BPT oracle
        balancerVault = new MockBalancerVault();
        bpt = new MockBPT(IVault(address(balancerVault)), "Royco BPT", "rBPT");
        bptOracle = new MockBPTOracle(balancerVault, address(bpt));

        // YDMs: always two distinct instances (the accountant rejects identical YDMs)
        bytes memory jtYdmInitData;
        bytes memory ltYdmInitData;
        (jtYdm, jtYdmInitData) = _deployYDM("JT_YDM", params.jtYdmKind, params.jtCurve, params.targetUtilizationWAD);
        (ltYdm, ltYdmInitData) = _deployYDM("LT_YDM", params.ltYdmKind, params.ltCurve, params.targetUtilizationWAD);

        // Predict the kernel proxy address so the tranche and accountant impls can bake it into their immutables
        kernelProxyDeployer = makeAddr("KERNEL_PROXY_DEPLOYER");
        address predictedKernel = vm.computeCreateAddress(kernelProxyDeployer, vm.getNonce(kernelProxyDeployer));

        RoycoSeniorTranche stImpl = new RoycoSeniorTranche(address(stJtVault), predictedKernel);
        RoycoJuniorTranche jtImpl = new RoycoJuniorTranche(address(stJtVault), predictedKernel);
        RoycoLiquidityTranche ltImpl = new RoycoLiquidityTranche(address(bpt), predictedKernel);
        RoycoDayAccountant accImpl = new RoycoDayAccountant(predictedKernel, true);

        // Tranche and accountant proxies must exist before the kernel impl (its constructor reads the accountant)
        seniorTranche = RoycoSeniorTranche(_deployTrancheProxy(address(stImpl), "Royco Senior Tranche", "RST"));
        juniorTranche = RoycoJuniorTranche(_deployTrancheProxy(address(jtImpl), "Royco Junior Tranche", "RJT"));
        liquidityTranche = RoycoLiquidityTranche(_deployTrancheProxy(address(ltImpl), "Royco Liquidity Tranche", "RLT"));
        accountant = RoycoDayAccountant(
            address(
                new ERC1967Proxy(
                    address(accImpl),
                    abi.encodeCall(RoycoDayAccountant.initialize, (_buildAccountantInitParams(params, jtYdmInitData, ltYdmInitData), address(accessManager)))
                )
            )
        );

        // Register the pool before kernel impl construction (the LT quoter constructor validates the registration),
        // sorted ascending by address exactly as the production vault registers pool tokens
        bool stSortsFirst = address(seniorTranche) < address(quoteToken);
        stPoolTokenIndex = stSortsFirst ? 0 : 1;
        IERC20[2] memory poolTokens =
            stSortsFirst ? [IERC20(address(seniorTranche)), IERC20(address(quoteToken))] : [IERC20(address(quoteToken)), IERC20(address(seniorTranche))];
        balancerVault.registerPool(address(bpt), poolTokens);
        _initializePoolMinimumSupply();

        // THE SWAPPED STEP: the Chainlink-to-admin kernel impl instead of the shipped share-price-to-Chainlink kernel
        kernelConstructionParams = IRoycoDayKernel.RoycoDayKernelConstructionParams({
            seniorTranche: address(seniorTranche),
            stAsset: address(stJtVault),
            juniorTranche: address(juniorTranche),
            jtAsset: address(stJtVault),
            accountant: address(accountant),
            liquidityTranche: address(liquidityTranche),
            ltAsset: address(bpt),
            enforceVaultSharesTransferWhitelist: params.enforceWhitelistOnTransfer
        });
        ChainlinkToAdminKernel kernelImpl = new ChainlinkToAdminKernel(kernelConstructionParams);

        PROTOCOL_FEE_RECIPIENT = makeAddr("PROTOCOL_FEE_RECIPIENT");

        // Kernel proxy from the dedicated deployer so it lands at the predicted address
        bytes memory kernelInitData = abi.encodeCall(kernelImpl.initialize, (_standardKernelInitParams(), _kernelSpecificInitParams(INITIAL_ADMIN_RATE_WAD)));
        vm.prank(kernelProxyDeployer);
        address kernelProxy = address(new ERC1967Proxy(address(kernelImpl), kernelInitData));
        require(kernelProxy == predictedKernel, "Test_AdminOracleQuoter_ChainlinkToAdmin: kernel proxy address prediction failed");
        adminKernel = ChainlinkToAdminKernel(kernelProxy);
        // The base's handle points at the same proxy so its role-wiring helpers bind the shared quoter selectors
        kernel = ShippedKernel(kernelProxy);
        vm.label(kernelProxy, "ChainlinkToAdminKernel");

        // Wire the kernel as the senior leg's live rate provider in both price stores, mirroring production
        balancerVault.setTokenRateProvider(address(seniorTranche), kernelProxy);
        bptOracle.setTokenRateProvider(address(seniorTranche), kernelProxy);

        // Role bindings and grants, unchanged from the base (the quoter setter selectors are shared across the family)
        _wireTargetFunctionRoles();
        _wireRoleGrants();
    }

    /// @notice Builds the standard kernel init params against the deployed access manager and fee recipient
    function _standardKernelInitParams() internal view returns (IRoycoDayKernel.RoycoDayKernelInitParams memory) {
        return IRoycoDayKernel.RoycoDayKernelInitParams({
            initialAuthority: address(accessManager),
            protocolFeeRecipient: PROTOCOL_FEE_RECIPIENT,
            stSelfLiquidationBonusWAD: params.stSelfLiquidationBonusWAD,
            roycoBlacklist: address(0)
        });
    }

    /// @notice Builds the kernel-specific init params for a given initial admin conversion rate
    /// @param _initialConversionRateWAD The reference asset to NAV unit rate the ST/JT quoter is initialized with
    function _kernelSpecificInitParams(uint256 _initialConversionRateWAD) internal view returns (ChainlinkToAdminKernel.KernelSpecificInitParams memory) {
        return ChainlinkToAdminKernel.KernelSpecificInitParams({
            stAndJTQuoterParams: IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter.ST_JT_QuoterSpecificParams({
                initialConversionRateWAD: _initialConversionRateWAD,
                trancheAssetToReferenceAssetOracle: address(priceFeed),
                gracePeriodSeconds: ORACLE_GRACE_PERIOD_SECONDS,
                sequencerUptimeFeed: address(0),
                stalenessThresholdSeconds: ORACLE_STALENESS_THRESHOLD_SECONDS
            }),
            ltQuoterParams: BalancerV3_LT_BPTOracle_Quoter.LT_QuoterSpecificParams({
                bptOracle: address(bptOracle), maxReinvestmentSlippageWAD: params.maxReinvestmentSlippageWAD
            })
        });
    }
}
