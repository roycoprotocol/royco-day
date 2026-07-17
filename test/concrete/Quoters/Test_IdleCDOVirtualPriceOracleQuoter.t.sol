// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { stdError } from "../../../lib/forge-std/src/StdError.sol";
import { AccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { RoycoDayAccountant } from "../../../src/accountant/RoycoDayAccountant.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import {
    Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_BalancerV3_BPTOracle_LT_Kernel as IdleCDOKernel
} from "../../../src/kernels/Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_BalancerV3_BPTOracle_LT_Kernel.sol";
import {
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel as ShippedKernel
} from "../../../src/kernels/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel.sol";
import {
    IdenticalIdleCDOAATranches_ST_JT_VirtualPriceOracle_Quoter
} from "../../../src/kernels/base/quoter/identical-st-jt/IdenticalIdleCDOAATranches_ST_JT_VirtualPriceOracle_Quoter.sol";
import { IdenticalAssets_ST_JT_Oracle_Quoter } from "../../../src/kernels/base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_Oracle_Quoter.sol";
import { BalancerV3_LT_BPTOracle_Quoter } from "../../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_BPTOracle_Quoter.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoJuniorTranche } from "../../../src/tranches/RoycoJuniorTranche.sol";
import { RoycoLiquidityTranche } from "../../../src/tranches/RoycoLiquidityTranche.sol";
import { RoycoSeniorTranche } from "../../../src/tranches/RoycoSeniorTranche.sol";
import { MockBPT } from "../../mocks/MockBPT.sol";
import { MockBPTOracle } from "../../mocks/MockBPTOracle.sol";
import { MockBalancerVault } from "../../mocks/MockBalancerVault.sol";
import { MockERC20C } from "../../mocks/MockERC20C.sol";
import { MockIdleCDO } from "../../mocks/MockIdleCDO.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { FixtureCell, MarketParamsConfig } from "../../utils/FixtureTypes.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { _plainToken } from "../../utils/TokenConfigs.sol";

/**
 * @title IdleCDOVirtualPriceMarketTestBase
 * @notice Deploys a full Day market around the Idle CDO AA tranche virtual price kernel composition: the tranche
 *         unit is a CDO AA tranche token whose ENTIRE tranche-to-NAV rate comes from the CDO's virtualPrice lifted
 *         to WAD precision in a single hop, with a stored admin rate as an OVERRIDE (a nonzero stored rate wins,
 *         zero restores the live virtual price)
 * @dev Mirrors MakinaChainlinkMarketTestBase step for step and swaps the ST/JT quoter: there is NO Chainlink layer
 *      anywhere in this composition, the CDO immutable is the only live price source and it can never be absent.
 *      The tests drive the shipped concrete Idle CDO kernel from src/kernels end to end. The market stays unseeded
 *      in every test, conversion rates are independent of tranche NAVs and the setter's internal accounting syncs
 *      pass trivially at zero NAVs
 */
abstract contract IdleCDOVirtualPriceMarketTestBase is DayMarketTestBase {
    /// @notice The deployed market's kernel proxy, typed to the Idle CDO virtual price composition under test
    IdleCDOKernel internal cdoKernel;

    /// @notice The kernel implementation, kept so tests can attempt fresh proxy initializations against it
    IdleCDOKernel internal cdoKernelImpl;

    /// @notice The plain ERC20 AA tranche token serving as BOTH the ST and JT asset (the quoter family requires ST_ASSET == JT_ASSET)
    MockERC20C internal aaTranche;

    /// @notice The CDO's underlying token, whose decimals denominate the raw virtual price
    MockERC20C internal underlyingToken;

    /// @notice The Idle CDO whose settable virtual price is the whole one-hop rate
    MockIdleCDO internal cdo;

    /**
     * @notice Deploys the full Day market with the Idle CDO virtual price kernel composition
     * @param _trancheDecimals The AA tranche token (tranche asset) decimals
     * @param _underlyingDecimals The CDO underlying token decimals
     * @param _initialVirtualPrice The CDO's initial virtual price (one whole AA tranche token in underlying units), scaled to the UNDERLYING decimals
     * @param _params The market parameterization to deploy
     * @param _initialConversionRateWAD The stored tranche-to-NAV rate the kernel is initialized with (0 runs virtual-price-primary)
     */
    function _deployIdleCDOVirtualPriceMarket(
        uint8 _trancheDecimals,
        uint8 _underlyingDecimals,
        uint256 _initialVirtualPrice,
        MarketParamsConfig memory _params,
        uint256 _initialConversionRateWAD
    )
        internal
    {
        require(_params.jtCoinvested, "IdleCDOVirtualPriceMarketTestBase: kernel family forces jtCoinvested=true");
        // The base fixture's ERC4626 shape validation does not apply here: the tranche asset is a PLAIN ERC20
        // AA tranche token, only the quote-asset decimals are consumed by the base's pool-genesis helper
        cell = FixtureCell({
            name: "IdleCDOVirtualPrice", stAsset: _plainToken(_trancheDecimals), jtAsset: _plainToken(_trancheDecimals), quoteAsset: _plainToken(6)
        });
        params = _params;

        // Access manager, admin'd by this fixture so role wiring needs no schedule/execute dance
        accessManager = new AccessManager(address(this));

        // Tokens: quote stable + ONE AA tranche token for both ST and JT, plus the CDO's underlying token and the
        // CDO itself. No ERC4626 vault and no price feed exist anywhere
        quoteToken = _deployERC20("Quote Stable", "QUOTE", cell.quoteAsset);
        aaTranche = new MockERC20C("AA Tranche", "AA_TRN", _trancheDecimals);
        underlyingToken = new MockERC20C("CDO Underlying", "UNDR", _underlyingDecimals);
        cdo = new MockIdleCDO(address(aaTranche), address(underlyingToken), _initialVirtualPrice);
        vm.label(address(aaTranche), "AATranche");
        vm.label(address(underlyingToken), "CDOUnderlying");
        vm.label(address(cdo), "MockIdleCDO");

        // Venue: mock Balancer vault, the BPT it ledgers, and the BPT oracle (the LT quoter is unchanged here)
        balancerVault = new MockBalancerVault();
        bpt = new MockBPT(IVault(address(balancerVault)), "Royco BPT", "rBPT");
        bptOracle = new MockBPTOracle(balancerVault, address(bpt));

        // YDMs: always two distinct instances (the accountant reverts YDMS_CANNOT_BE_IDENTICAL)
        bytes memory jtYdmInitData;
        bytes memory ltYdmInitData;
        (jtYdm, jtYdmInitData) = _deployYDM("JT_YDM", _params.jtYdmKind, _params.jtCurve, _params.targetUtilizationWAD);
        (ltYdm, ltYdmInitData) = _deployYDM("LT_YDM", _params.ltYdmKind, _params.ltCurve, _params.targetUtilizationWAD);

        // Predict the kernel proxy address so the tranche and accountant impls can bake it into their immutables
        kernelProxyDeployer = makeAddr("KERNEL_PROXY_DEPLOYER");
        address predictedKernel = vm.computeCreateAddress(kernelProxyDeployer, vm.getNonce(kernelProxyDeployer));

        RoycoSeniorTranche stImpl = new RoycoSeniorTranche(address(aaTranche), predictedKernel);
        RoycoJuniorTranche jtImpl = new RoycoJuniorTranche(address(aaTranche), predictedKernel);
        RoycoLiquidityTranche ltImpl = new RoycoLiquidityTranche(address(bpt), predictedKernel);
        RoycoDayAccountant accImpl = new RoycoDayAccountant(predictedKernel, true);

        // Tranche and accountant proxies MUST exist before the kernel impl (its constructor reads the accountant)
        seniorTranche = RoycoSeniorTranche(_deployTrancheProxy(address(stImpl), "Royco Senior Tranche", "RST"));
        juniorTranche = RoycoJuniorTranche(_deployTrancheProxy(address(jtImpl), "Royco Junior Tranche", "RJT"));
        liquidityTranche = RoycoLiquidityTranche(_deployTrancheProxy(address(ltImpl), "Royco Liquidity Tranche", "RLT"));
        accountant = RoycoDayAccountant(
            address(
                new ERC1967Proxy(
                    address(accImpl),
                    abi.encodeCall(RoycoDayAccountant.initialize, (_buildAccountantInitParams(_params, jtYdmInitData, ltYdmInitData), address(accessManager)))
                )
            )
        );

        // Register the pool BEFORE kernel impl construction (the LT quoter constructor validates the registration),
        // mirroring production Balancer's ascending-address token sort
        bool stSortsFirst = address(seniorTranche) < address(quoteToken);
        stPoolTokenIndex = stSortsFirst ? 0 : 1;
        IERC20[2] memory poolTokens =
            stSortsFirst ? [IERC20(address(seniorTranche)), IERC20(address(quoteToken))] : [IERC20(address(quoteToken)), IERC20(address(seniorTranche))];
        balancerVault.registerPool(address(bpt), poolTokens);
        _initializePoolMinimumSupply();

        // Kernel impl of the composition under test (constructor resolves the vault via BalancerPoolToken.getVault)
        cdoKernelImpl = new IdleCDOKernel(_cdoConstructionParams(), address(cdo));

        PROTOCOL_FEE_RECIPIENT = makeAddr("PROTOCOL_FEE_RECIPIENT");

        // Kernel proxy from the dedicated deployer so it lands at the predicted address
        vm.prank(kernelProxyDeployer);
        address kernelProxy = address(new ERC1967Proxy(address(cdoKernelImpl), _kernelInitData(_initialConversionRateWAD)));
        require(kernelProxy == predictedKernel, "IdleCDOVirtualPriceMarketTestBase: kernel proxy address prediction failed");
        cdoKernel = IdleCDOKernel(kernelProxy);
        vm.label(kernelProxy, "IdleCDOKernel");

        // The base's kernel handle is used only for ADDRESS-based role wiring, and every selector the bindings
        // target (setConversionRate, sync, pause, ...) that exists on this composition resolves identically, while
        // the Chainlink-only selectors bind to a target that never dispatches them
        kernel = ShippedKernel(kernelProxy);

        // The kernel is the senior leg's live rate provider in BOTH venue price stores, as in production
        balancerVault.setTokenRateProvider(address(seniorTranche), kernelProxy);
        bptOracle.setTokenRateProvider(address(seniorTranche), kernelProxy);

        _wireTargetFunctionRoles();
        _wireRoleGrants();
    }

    /// @notice Builds the standard kernel construction params over the currently deployed market components
    /// @dev Reused by construction-boundary tests that construct throwaway kernel impls against the live wiring
    function _cdoConstructionParams() internal view returns (IRoycoDayKernel.RoycoDayKernelConstructionParams memory) {
        return IRoycoDayKernel.RoycoDayKernelConstructionParams({
            seniorTranche: address(seniorTranche),
            stAsset: address(aaTranche),
            juniorTranche: address(juniorTranche),
            jtAsset: address(aaTranche),
            accountant: address(accountant),
            liquidityTranche: address(liquidityTranche),
            ltAsset: address(bpt),
            enforceVaultSharesTransferWhitelist: params.enforceWhitelistOnTransfer
        });
    }

    /// @notice Builds the kernel proxy initialization calldata for the specified initial stored rate
    /// @param _initialConversionRateWAD The stored tranche-to-NAV rate to initialize the ST/JT quoter with (0 runs virtual-price-primary)
    function _kernelInitData(uint256 _initialConversionRateWAD) internal view returns (bytes memory) {
        return abi.encodeCall(
            cdoKernelImpl.initialize,
            (
                IRoycoDayKernel.RoycoDayKernelInitParams({
                    initialAuthority: address(accessManager),
                    protocolFeeRecipient: PROTOCOL_FEE_RECIPIENT,
                    stSelfLiquidationBonusWAD: params.stSelfLiquidationBonusWAD,
                    roycoBlacklist: address(0)
                }),
                IdleCDOKernel.KernelSpecificInitParams({
                    stAndJTQuoterParams: IdenticalIdleCDOAATranches_ST_JT_VirtualPriceOracle_Quoter.ST_JT_QuoterSpecificParams({
                        initialConversionRateWAD: _initialConversionRateWAD
                    }),
                    ltQuoterParams: BalancerV3_LT_BPTOracle_Quoter.LT_QuoterSpecificParams({
                        bptOracle: address(bptOracle), maxReinvestmentSlippageWAD: params.maxReinvestmentSlippageWAD
                    })
                })
            )
        );
    }
}

/**
 * @title Test_VirtualPriceOneHopRate_IdleCDOVirtualPriceOracleQuoter
 * @notice The Idle CDO AA tranche virtual price composition's full construction, pricing, override, and admin
 *         surface: the constructor sanity checks, both initial rate configurations (the VALID zero sentinel and the
 *         nonzero genesis override), the one-hop rate across decimal shapes on both sides of the underlying's WAD
 *         boundary, the stored-rate override precedence over the live virtual price, and the access gate
 * @dev UNLIKE the Chainlink siblings, the live price source here is a constructor IMMUTABLE: the CDO can never be
 *      absent, so zero is always a legal stored rate, no oracle-presence invariant exists anywhere in this
 *      composition, and the rate seam is an EXACT multiplication (virtualPrice x a power of ten) with no floor
 */
contract Test_VirtualPriceOneHopRate_IdleCDOVirtualPriceOracleQuoter is IdleCDOVirtualPriceMarketTestBase {
    /// @dev Baseline shape: the Pareto FalconX shape, an 18-decimal AA tranche over a 6-decimal underlying (USDC), virtual price 1.0, stored rate 0 (virtual-price-primary)
    function setUp() public {
        _deployIdleCDOVirtualPriceMarket(18, 6, 1e6, defaultParams(), 0);
    }

    // =============================
    // Construction sanity checks
    // =============================

    /**
     * @notice Constructing the kernel with a null Idle CDO is rejected outright
     * @dev The CDO's virtualPrice IS the entire live rate: a quoter without a CDO could never price anything, so
     *      accepting the null address would ship a kernel whose every quote calls into empty code. The constructor
     *      must fail loud before any market can be wired around it
     */
    function test_RevertIf_IdleCDOQuoterConstructedWithNullCDO() public {
        // A throwaway kernel impl against the live market wiring, only the CDO argument is poisoned
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        new IdleCDOKernel(_cdoConstructionParams(), address(0));
    }

    /**
     * @notice Constructing the kernel with a CDO whose AA tranche token is not the ST/JT asset is rejected
     * @dev The quoter prices the TRANCHE asset through the CDO's virtual price, so the tranche asset must BE the
     *      CDO's AA tranche token: pricing token X off CDO Y's virtual price would mark every senior and junior
     *      NAV against an unrelated instrument. One equality check against ST_ASSET suffices because the parent
     *      quoter already forces ST_ASSET == JT_ASSET
     */
    function test_RevertIf_TrancheAssetIsNotTheCDOAATrancheToken() public {
        // A CDO over a foreign AA tranche token, everything else identical to the live wiring
        MockERC20C foreignTranche = new MockERC20C("Foreign AA Tranche", "FRGN", 18);
        MockIdleCDO foreignCDO = new MockIdleCDO(address(foreignTranche), address(underlyingToken), 1e6);

        vm.expectRevert(IdenticalIdleCDOAATranches_ST_JT_VirtualPriceOracle_Quoter.TRANCHE_ASSET_MUST_BE_CDO_AA_TRANCHE.selector);
        new IdleCDOKernel(_cdoConstructionParams(), address(foreignCDO));
    }

    /**
     * @notice Underlying-token decimals above 18 fall outside the supported envelope and revert at construction
     * @dev The quoter derives the WAD-lifting multiplier as 10^(18 - underlyingDecimals) because virtualPrice is
     *      denominated in the UNDERLYING token's decimals. With a 19-decimal underlying the exponent is 18 - 19 = -1
     *      and the checked subtraction underflows (arithmetic panic 0x11). Tranche decimals do NOT widen the
     *      envelope (unlike the Makina composition's 18 + trancheDecimals - accountingDecimals exponent) because
     *      virtualPrice is quoted per WHOLE tranche token and the root handles tranche scaling separately. The
     *      revert is loud and at construction, so an out-of-envelope CDO can never reach a live market, but it
     *      surfaces as a raw panic rather than a typed error, this test documents the envelope boundary
     */
    function test_RevertIf_UnderlyingDecimalsExceedWAD() public {
        // A CDO over the SAME AA tranche token (so the tranche equality check passes) but a 19-decimal underlying,
        // pushing the multiplier exponent to 18 - 19 = -1
        MockERC20C underlying19 = new MockERC20C("Underlying 19", "UND19", 19);
        MockIdleCDO outOfEnvelopeCDO = new MockIdleCDO(address(aaTranche), address(underlying19), 1e19);

        vm.expectRevert(stdError.arithmeticError);
        new IdleCDOKernel(_cdoConstructionParams(), address(outOfEnvelopeCDO));
    }

    // =============================
    // The initial rate configurations (zero runs virtual-price-primary, nonzero installs a genesis override)
    // =============================

    /**
     * @notice Initializing the kernel with a zero conversion rate is VALID and the rate prices through the CDO's
     *         live virtual price
     * @dev Zero is the query-the-CDO sentinel: the init skips the store, the quoter runs virtual-price-primary, and
     *      the rate is virtualPrice x 10^(18 - underlyingDecimals). The CDO is a constructor immutable, so unlike
     *      the Chainlink siblings there is no configuration in which the sentinel strands the market priceless. A
     *      regression that rejected the zero init would make the shipped virtual-price-primary configuration
     *      undeployable
     */
    function test_ZeroInitialConversionRate_IsValidAndPricesThroughTheVirtualPrice() public {
        // Getter pin: the deployed kernel's immutable price source is the fixture's mock CDO
        assertEq(cdoKernel.IDLE_CDO(), address(cdo), "the kernel must expose the fixture's CDO as its immutable price source");

        // The setUp market was initialized with rate 0 and deployed successfully, the sentinel is in storage
        assertEq(cdoKernel.getStoredConversionRateWAD(), 0, "a zero initial rate must land as the query-the-CDO sentinel");

        // One hop: virtualPrice 1e6 x multiplier 1e12 = 1e18, an exact multiplication with no floor
        assertEq(cdoKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 1e18, "the rate must price through the virtual price with no stored rate");
        // One whole 18-decimal AA tranche token is 1e18 tranche-wei: 1e18 x 1e18 / 1e18 = 1e18 NAV, identically on both tranches
        assertEq(toUint256(cdoKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 1e18, "one whole tranche token must quote 1.0 NAV through the CDO");
        assertEq(toUint256(cdoKernel.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 1e18, "the junior side prices through the identical CDO rate");
        // The inverse divides by the same rate: 1e18 NAV x 1e18 / 1e18 = 1e18 tranche-wei
        assertEq(toUint256(cdoKernel.stConvertNAVUnitsToTrancheUnits(toNAVUnits(uint256(1e18)))), 1e18, "NAV -> tranche must invert the virtual price rate");

        // A FRESH proxy over the live impl also initializes cleanly at rate 0, pinning the sentinel as a
        // first-class deploy configuration rather than an accident of the setUp market
        IdleCDOKernel fresh = IdleCDOKernel(address(new ERC1967Proxy(address(cdoKernelImpl), _kernelInitData(0))));
        assertEq(fresh.getTrancheUnitToNAVUnitConversionRateWAD(), 1e18, "a fresh zero-rate proxy must price through the virtual price immediately");
    }

    /**
     * @notice Initializing the kernel with a NONZERO conversion rate installs a genesis override: the rate IS the
     *         stored value from the very first quote, a dead CDO cannot block pricing, and setConversionRate(0)
     *         hands pricing back to the live virtual price
     * @dev The initializer writes the nonzero rate into the same storage slot the admin setter uses, so the override
     *      precedence must hold with NO setter call ever made. Unlike the Makina composition there is no live first
     *      hop to compose with: the stored rate is the ENTIRE tranche-to-NAV rate, so the quoted rate equals the
     *      stored value exactly. This is the day-one rescue shape: a market can launch against a CDO whose pricing
     *      is paused or distrusted and run entirely on the governed rate until governance clears it
     */
    function test_NonzeroInitialConversionRate_InstallsAGenesisOverride() public {
        // Redeploy with virtual price 1.5 (in 6-decimal underlying units) and initial stored rate 2.0. The virtual
        // price off the stored value makes the precedence unambiguous: 2e18 can only come from the override
        _deployIdleCDOVirtualPriceMarket(18, 6, 1.5e6, defaultParams(), 2e18);

        // The init must have landed the rate in quoter storage, exactly as the admin setter would
        assertEq(cdoKernel.getStoredConversionRateWAD(), 2e18, "a nonzero initial rate must land in quoter storage");

        // The override IS the whole rate: exactly 2e18, not the CDO's 1.5e18 and not any composition of the two
        assertEq(cdoKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 2e18, "the rate must be the stored 2.0 exactly, not the virtual price path");
        // One whole tranche token: 1e18 x 2e18 / 1e18 = 2e18 NAV, identically on both tranches
        assertEq(
            toUint256(cdoKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 2e18, "one whole tranche token must quote through the genesis override"
        );
        assertEq(toUint256(cdoKernel.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 2e18, "the junior side prices through the identical override");
        // The inverse: 2e18 NAV x 1e18 / 2e18 = 1e18 tranche-wei, an exact round-trip
        assertEq(toUint256(cdoKernel.stConvertNAVUnitsToTrancheUnits(toNAVUnits(uint256(2e18)))), 1e18, "NAV -> tranche must invert the override rate");

        // Arm the CDO to revert outright: if the init-stored rate did not short-circuit the live query these quotes
        // would revert, so surviving them proves the genesis override never consults the CDO even though no setter
        // call ever ran
        cdo.setRevertMode(true);
        assertEq(cdoKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 2e18, "a dead CDO must not block a genesis-overridden rate");
        assertEq(toUint256(cdoKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 2e18, "forward quotes must run off the genesis override");
        assertEq(toUint256(cdoKernel.stConvertNAVUnitsToTrancheUnits(toNAVUnits(uint256(2e18)))), 1e18, "inverse quotes must run off the genesis override");

        // Clearing to the sentinel hands pricing back to the CDO. The CDO must be healthy again first, since the
        // setter's post-set re-cache prices through the now-live rate
        cdo.setRevertMode(false);
        vm.prank(ORACLE_QUOTER_ADMIN);
        cdoKernel.setConversionRate(0, false);
        assertEq(cdoKernel.getStoredConversionRateWAD(), 0, "clearing the genesis override must restore the sentinel");
        // The live path resumes: virtualPrice 1.5e6 x multiplier 1e12 = 1.5e18
        assertEq(cdoKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 1.5e18, "the cleared quoter must price through the virtual price at 1.5");
    }

    // =============================
    // The one-hop rate (virtualPrice lifted to WAD by a power of ten)
    // =============================

    /**
     * @notice The one-hop rate is virtualPrice x 10^(18 - underlyingDecimals) EXACTLY across three decimal shapes,
     *         both tranches price through it, the inverse round-trips, 1-wei quotes floor only at the root's
     *         division, and the CDO reprices with NO admin action
     * @dev The multiplier is a power of ten fixed at construction, so the rate seam is an exact checked
     *      multiplication with NO floor, a genuine difference from the Makina composition where a sub-WAD wei can
     *      floor out of the composed rate. The only flooring anywhere in this composition is the root quoter's
     *      division by the tranche unit scale on the quote itself. Every expected value below is hand-derived from
     *      the raw virtual price and the two scale factors
     */
    function test_VirtualPriceOneHopRate_AcrossDecimalShapes() public {
        // ---- Shape 1: 18-decimal AA tranche over a 6-decimal underlying (the Pareto shape), virtual price 1.05 ----
        // Multiplier is 10^(18-6) = 1e12. Rate: 1.05e6 x 1e12 = 1.05e18 exactly
        _deployIdleCDOVirtualPriceMarket(18, 6, 1.05e6, defaultParams(), 0);
        assertEq(cdoKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 1.05e18, "shape 1: the rate must be the virtual price lifted by 1e12 exactly");
        // One whole 18-decimal tranche token is 1e18 tranche-wei: 1e18 x 1.05e18 / 1e18 = 1.05e18 NAV, on both tranches
        assertEq(toUint256(cdoKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 1.05e18, "shape 1: one whole tranche token must quote 1.05 NAV");
        assertEq(
            toUint256(cdoKernel.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 1.05e18, "shape 1: the junior side prices through the identical rate"
        );
        // 1 tranche-wei: floor(1 x 1.05e18 / 1e18) = 1 NAV-wei, the fractional 0.05 floors away at the root's division
        assertEq(toUint256(cdoKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1))), 1, "shape 1: a 1-wei quote must floor 1.05 down to 1 NAV-wei");
        // The inverse divides by the same rate: 1.05e18 NAV x 1e18 / 1.05e18 = 1e18 tranche-wei, an exact round-trip
        assertEq(toUint256(cdoKernel.stConvertNAVUnitsToTrancheUnits(toNAVUnits(uint256(1.05e18)))), 1e18, "shape 1: NAV -> tranche must invert the rate");
        assertEq(
            toUint256(cdoKernel.jtConvertNAVUnitsToTrancheUnits(toNAVUnits(uint256(1.05e18)))), 1e18, "shape 1: the junior inverse shares the identical rate"
        );

        // CDO yield reprices with NO admin action, the live path: virtual price 1.05 -> 2.0 moves the rate to
        // 2e6 x 1e12 = 2e18, while the stored rate stays at the sentinel
        cdo.setVirtualPrice(2e6);
        assertEq(cdoKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 2e18, "shape 1: CDO yield must reprice the rate to 2.0 with no admin action");
        assertEq(toUint256(cdoKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 2e18, "shape 1: quotes must track the live virtual price");
        assertEq(cdoKernel.getStoredConversionRateWAD(), 0, "shape 1: the stored rate must remain the sentinel through CDO yield");

        // ---- Shape 2: 18-decimal AA tranche over an 18-decimal underlying, virtual price 1e18 + 1 ----
        // Multiplier is 10^(18-18) = 1, the envelope's multiplier-of-one edge. Rate: (1e18 + 1) x 1 = 1e18 + 1
        // EXACTLY. This pins that the rate seam is a lossless multiplication with NO floor: in the Makina
        // composition a 1-wei-above-peg first hop can floor out of the composed rate, here it survives verbatim
        _deployIdleCDOVirtualPriceMarket(18, 18, 1e18 + 1, defaultParams(), 0);
        assertEq(
            cdoKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 1e18 + 1, "shape 2: the 1-wei-above-peg virtual price must survive the rate seam exactly"
        );
        // One whole tranche token: floor(1e18 x (1e18 + 1) / 1e18) = 1e18 + 1 NAV-wei, the excess wei is whole at this size
        assertEq(
            toUint256(cdoKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 1e18 + 1, "shape 2: one whole tranche token must carry the 1-wei excess"
        );
        assertEq(
            toUint256(cdoKernel.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 1e18 + 1, "shape 2: the junior side prices through the identical rate"
        );
        // The inverse floors at the root's division: floor((1e18 + 1) x 1e18 / (1e18 + 1)) = 1e18 tranche-wei
        assertEq(toUint256(cdoKernel.stConvertNAVUnitsToTrancheUnits(toNAVUnits(uint256(1e18 + 1)))), 1e18, "shape 2: NAV -> tranche must invert the rate");

        // ---- Shape 3: 6-decimal AA tranche over an 18-decimal underlying, virtual price 2.5 ----
        // Multiplier is again 1 (the underlying pins the multiplier, tranche decimals never enter the exponent).
        // Rate: 2.5e18 x 1 = 2.5e18, and the root scales quotes by the 6-decimal tranche unit
        _deployIdleCDOVirtualPriceMarket(6, 18, 2.5e18, defaultParams(), 0);
        assertEq(cdoKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 2.5e18, "shape 3: the rate must be the 18-decimal virtual price verbatim");
        // One whole 6-decimal tranche token is 1e6 tranche-wei: 1e6 x 2.5e18 / 1e6 = 2.5e18 NAV
        assertEq(toUint256(cdoKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e6))), 2.5e18, "shape 3: one whole 6-dec tranche token must quote 2.5 NAV");
        assertEq(
            toUint256(cdoKernel.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e6))), 2.5e18, "shape 3: the junior side prices through the identical rate"
        );
        // 1 tranche-wei is a millionth of a whole token: 1 x 2.5e18 / 1e6 = 2.5e12 NAV-wei exactly (no flooring loss)
        assertEq(
            toUint256(cdoKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1))),
            2.5e12,
            "shape 3: a 1-wei quote must scale by the 6-dec tranche unit exactly"
        );
        // The inverse: 2.5e18 NAV x 1e6 / 2.5e18 = 1e6 tranche-wei, an exact round-trip
        assertEq(toUint256(cdoKernel.stConvertNAVUnitsToTrancheUnits(toNAVUnits(uint256(2.5e18)))), 1e6, "shape 3: NAV -> tranche must invert the rate");
    }

    /**
     * @notice A ZERO virtual price on the live path zeroes the rate and every forward mark with NO revert, and only
     *         the inverse conversion fails, with a raw division-by-zero panic
     * @dev The one-hop composition has no INVALID_PRICE analog: the Chainlink family gates exactly this input class
     *      (a zero or negative answer) with INVALID_PRICE before it can enter the rate, but here virtualPrice feeds
     *      the rate seam unchecked, so a zero-pricing CDO silently zeroes every senior and junior mark until an
     *      admin override rescues it. This test documents that surface
     */
    function test_ZeroVirtualPrice_SilentlyZeroesTheLiveRateUntilOverridden() public {
        // The setUp stored rate is the sentinel, so the CDO's zero flows straight through the rate seam
        cdo.setVirtualPrice(0);
        assertEq(cdoKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 0, "a zero virtual price must zero the whole one-hop rate");

        // One whole tranche token marks to ZERO NAV with no revert, the silent-zeroing surface itself
        assertEq(toUint256(cdoKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 0, "one whole tranche token must mark to zero NAV with no revert");

        // The inverse divides by the zero rate and panics, the only loud failure anywhere on this path
        vm.expectRevert(stdError.divisionError);
        cdoKernel.stConvertNAVUnitsToTrancheUnits(toNAVUnits(uint256(1e18)));
    }

    // =============================
    // Override precedence (a stored nonzero rate wins over the virtual price, zero restores the live path)
    // =============================

    /**
     * @notice A stored nonzero rate overrides the virtual price: CDO moves stop repricing, a reverting CDO cannot
     *         block pricing, and setConversionRate(0) restores the live virtual price path
     * @dev The override short-circuits the CDO query entirely, which is exactly its economic purpose: if the CDO
     *      pauses or its pricing is distrusted, the admin pins the rate so deposits, redemptions, and syncs keep
     *      running off a governed number instead of the whole market bricking on the CDO's revert. The live path
     *      MUST resume after the override clears, otherwise a forgotten cleanup would leave the market silently
     *      quoting a stale governed rate while the CDO accrues yield
     */
    function test_StoredOverride_WinsOverVirtualPriceAndSurvivesCDOFailureUntilCleared() public {
        // Baseline is virtual-price-primary: 1e6 x 1e12 = 1e18
        assertEq(cdoKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 1e18, "the baseline must price through the virtual price");

        // Store the override: the rate becomes the stored 2e18 exactly, and the setter emits
        vm.expectEmit(address(cdoKernel));
        emit IdenticalAssets_ST_JT_Oracle_Quoter.ConversionRateUpdated(2e18);
        vm.prank(ORACLE_QUOTER_ADMIN);
        cdoKernel.setConversionRate(2e18, false);
        assertEq(cdoKernel.getStoredConversionRateWAD(), 2e18, "the override must land in quoter storage");
        assertEq(cdoKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 2e18, "the rate must be the stored 2.0 exactly");

        // A virtual price move must NOT reprice while overridden: with the CDO at 5.0 the rate stays 2e18
        cdo.setVirtualPrice(5e6);
        assertEq(cdoKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 2e18, "a virtual price move must not reprice through a stored override");

        // A REVERTING CDO must not block pricing while overridden (the override never queries the CDO)
        cdo.setRevertMode(true);
        assertEq(cdoKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 2e18, "a reverting CDO must not block an overridden rate");
        assertEq(
            toUint256(cdoKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 2e18, "forward quotes must run off the override through a dead CDO"
        );
        assertEq(
            toUint256(cdoKernel.stConvertNAVUnitsToTrancheUnits(toNAVUnits(uint256(2e18)))), 1e18, "inverse quotes must run off the override through a dead CDO"
        );
        assertEq(toUint256(cdoKernel.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 2e18, "the junior side must also price off the override");

        // Heal the CDO at 5.0, then clear the override: the live path resumes at 5e6 x 1e12 = 5e18
        cdo.setRevertMode(false);
        vm.prank(ORACLE_QUOTER_ADMIN);
        cdoKernel.setConversionRate(0, false);
        assertEq(cdoKernel.getStoredConversionRateWAD(), 0, "clearing the override must restore the sentinel");
        assertEq(cdoKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 5e18, "the cleared quoter must price through the virtual price at 5.0");
    }

    /**
     * @notice The setter's own internal accounting sync goes through the quoted rate: installing an override through
     *         a dead CDO requires syncBeforeUpdate=false, and CLEARING the override through a dead CDO reverts
     * @dev setConversionRate always re-caches the rate after the store. With a nonzero value just stored the
     *      re-cache short-circuits the CDO, so the override can be installed while the CDO is already dead (its
     *      rescue purpose) as long as the PRE-set sync is skipped. Clearing back to the sentinel makes the re-cache
     *      query the dead CDO and revert, which is the safe failure mode: the admin cannot hand pricing back to a
     *      CDO that cannot price, so a market can never be left quoting off a dead source. Both expectations pin the
     *      mock's typed CDO_REVERT_MODE error bubbling up through the quoter unwrapped
     */
    function test_OverrideLifecycleThroughADeadCDO_InstallsWithoutPreSyncAndRefusesToClear() public {
        // Kill the CDO with the quoter still virtual-price-primary
        cdo.setRevertMode(true);

        // Installing the override WITH a pre-set sync reverts: the pre-sync caches through the still-sentinel rate
        vm.prank(ORACLE_QUOTER_ADMIN);
        vm.expectRevert(MockIdleCDO.CDO_REVERT_MODE.selector);
        cdoKernel.setConversionRate(2e18, true);
        assertEq(cdoKernel.getStoredConversionRateWAD(), 0, "the reverted install must leave the sentinel in place");

        // Installing WITHOUT the pre-set sync succeeds: the post-set re-cache reads the just-stored override
        vm.prank(ORACLE_QUOTER_ADMIN);
        cdoKernel.setConversionRate(2e18, false);
        assertEq(cdoKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 2e18, "the rescue override must price through the dead CDO");

        // Clearing while the CDO is still dead reverts in the post-set re-cache, storage rolls back to the override
        vm.prank(ORACLE_QUOTER_ADMIN);
        vm.expectRevert(MockIdleCDO.CDO_REVERT_MODE.selector);
        cdoKernel.setConversionRate(0, false);
        assertEq(cdoKernel.getStoredConversionRateWAD(), 2e18, "the reverted clear must leave the override in place");

        // Once the CDO is healthy again the clear lands and the live path resumes at 1e6 x 1e12 = 1e18
        cdo.setRevertMode(false);
        vm.prank(ORACLE_QUOTER_ADMIN);
        cdoKernel.setConversionRate(0, false);
        assertEq(cdoKernel.getStoredConversionRateWAD(), 0, "the clear must land once the CDO is healthy");
        assertEq(cdoKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 1e18, "the restored live path must price at 1.0");
    }

    /**
     * @notice The sentinel is ALWAYS legal: an override installs and clears on a healthy CDO with no presence gate
     *         anywhere in the composition
     * @dev The family-difference pin: the Chainlink siblings guard the sentinel with NULL_ORACLE_WITHOUT_STORED_RATE
     *      and SENTINEL_RATE_WITHOUT_ORACLE because their oracle slot is mutable and nullable, so an admin sequence
     *      could strand both price sources. Here the CDO is a constructor immutable, the live path structurally
     *      cannot be absent, and no such invariant exists to trip: storing and clearing are gated only by the
     *      health of the source the post-set re-cache prices through
     */
    function test_SentinelIsAlwaysLegal_NoOraclePresenceInvariant() public {
        // Install an override on the healthy CDO, no gate consulted
        vm.prank(ORACLE_QUOTER_ADMIN);
        cdoKernel.setConversionRate(3e18, false);
        assertEq(cdoKernel.getStoredConversionRateWAD(), 3e18, "the override must land with no presence gate in the way");
        assertEq(cdoKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 3e18, "the rate must be the stored 3.0 exactly");

        // Clear straight back to the sentinel, the exact operation the Chainlink siblings gate on oracle presence
        vm.prank(ORACLE_QUOTER_ADMIN);
        cdoKernel.setConversionRate(0, false);
        assertEq(cdoKernel.getStoredConversionRateWAD(), 0, "the sentinel must always be storable against the immutable CDO");
        assertEq(cdoKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 1e18, "the live virtual price path must resume immediately");
    }

    // =============================
    // Access gates (unprivileged callers rejected before any state moves)
    // =============================

    /**
     * @notice An unprivileged caller cannot move the conversion rate, and the failed attempt leaves pricing untouched
     * @dev setConversionRate is this composition's ONLY quoter admin lever (no oracle setter and no sequencer
     *      surface exist here) and it is a full market repricing lever: a hostile stored rate would remark every
     *      senior and junior NAV at the very next sync. It must revert AccessManagedUnauthorized at the access
     *      manager, before any quoter logic runs
     */
    function test_RevertIf_UnprivilegedCallerTouchesSetConversionRate() public {
        address attacker = makeAddr("ATTACKER");

        // setConversionRate is rejected at the access manager and the sentinel survives
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, attacker));
        cdoKernel.setConversionRate(20e18, false);
        assertEq(cdoKernel.getStoredConversionRateWAD(), 0, "the stored rate must be untouched by the failed attempt");

        // Pricing still runs off the legitimate virtual price path: 1e6 x 1e12 = 1e18 per whole tranche token
        assertEq(toUint256(cdoKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 1e18, "pricing must still run off the legitimate configuration");
    }
}
