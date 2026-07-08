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
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel as ChainlinkKernel
} from "../../../src/kernels/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel.sol";
import {
    IdenticalMakinaShares_ST_JT_SharePriceToAdminOracle_Quoter
} from "../../../src/kernels/base/quoter/identical-st-jt/IdenticalMakinaShares_ST_JT_SharePriceToAdminOracle_Quoter.sol";
import {
    IdenticalAssets_ST_JT_AdminOracle_Quoter
} from "../../../src/kernels/base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_AdminOracle_Quoter.sol";
import { BalancerV3_LT_BPTOracle_Quoter } from "../../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_BPTOracle_Quoter.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoJuniorTranche } from "../../../src/tranches/RoycoJuniorTranche.sol";
import { RoycoLiquidityTranche } from "../../../src/tranches/RoycoLiquidityTranche.sol";
import { RoycoSeniorTranche } from "../../../src/tranches/RoycoSeniorTranche.sol";
import {
    Identical_Makina_ST_JT_SharePriceToAdminOracle_BalancerV3_BPTOracle_LT_Kernel as MakinaKernel
} from "../../mocks/Identical_Makina_ST_JT_SharePriceToAdminOracle_BalancerV3_BPTOracle_LT_Kernel.sol";
import { MockBPT } from "../../mocks/MockBPT.sol";
import { MockBPTOracle } from "../../mocks/MockBPTOracle.sol";
import { MockBalancerVault } from "../../mocks/MockBalancerVault.sol";
import { MockERC20C } from "../../mocks/MockERC20C.sol";
import { MockMakinaMachine } from "../../mocks/MockMakinaMachine.sol";
import { UninitializedERC1967Proxy } from "../../mocks/UninitializedERC1967Proxy.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { FixtureCell, MarketParamsConfig } from "../../utils/FixtureTypes.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { _plainToken } from "../../utils/TokenConfigs.sol";

/**
 * @title MakinaMarketTestBase
 * @notice Deploys a full Day market around the Makina machine-share-price-to-admin-oracle kernel composition: the
 *         tranche unit is a Makina machine share whose accounting-asset value comes from the machine's
 *         convertToAssets (a live hop) and whose accounting-asset-to-NAV-unit rate is a stored admin value
 *         (a static hop, no external feed anywhere in the composition)
 * @dev Mirrors DayMarketTestBase._deployMarket step for step, reusing every base helper, and swaps only the ST/JT
 *      asset (a plain ERC20 machine share instead of an ERC4626 vault share) and the kernel: the Makina quoter ships
 *      abstract in src with no concrete kernel wiring it, so the test-only concrete kernel in test/mocks exercises it
 *      end to end. The market stays unseeded in every test, conversion rates are independent of tranche NAVs and the
 *      setter's internal accounting syncs pass trivially at zero NAVs
 */
abstract contract MakinaMarketTestBase is DayMarketTestBase {
    /// @notice The deployed market's kernel proxy, typed to the Makina composition under test
    MakinaKernel internal makinaKernel;

    /// @notice The kernel implementation, kept so tests can attempt fresh proxy initializations against it
    MakinaKernel internal makinaKernelImpl;

    /// @notice The plain ERC20 machine share serving as BOTH the ST and JT asset (the quoter family requires ST_ASSET == JT_ASSET)
    MockERC20C internal machineShare;

    /// @notice The machine's accounting token, the intermediate asset of the two-hop NAV conversion
    MockERC20C internal accountingToken;

    /// @notice The Makina machine whose settable share price is the live first hop of the composed rate
    MockMakinaMachine internal machine;

    /**
     * @notice Deploys the full Day market with the Makina kernel composition
     * @param _trancheDecimals The machine share (tranche asset) decimals
     * @param _accountingDecimals The machine accounting token decimals
     * @param _initialSharePriceWAD The machine's initial share price (whole accounting tokens per whole share), WAD scaled
     * @param _params The market parameterization to deploy
     * @param _initialConversionRateWAD The accounting-asset-to-NAV-unit rate the kernel is initialized with
     */
    function _deployMakinaMarket(
        uint8 _trancheDecimals,
        uint8 _accountingDecimals,
        uint256 _initialSharePriceWAD,
        MarketParamsConfig memory _params,
        uint256 _initialConversionRateWAD
    )
        internal
    {
        require(_params.jtCoinvested, "MakinaMarketTestBase: kernel family forces jtCoinvested=true");
        // The base fixture's ERC4626 shape validation does not apply here: the tranche asset is a PLAIN ERC20
        // machine share, only the quote-asset decimals are consumed by the base's pool-genesis helper
        cell = FixtureCell({
            name: "Makina", stAsset: _plainToken(_trancheDecimals), jtAsset: _plainToken(_trancheDecimals), quoteAsset: _plainToken(6)
        });
        params = _params;

        // Access manager, admin'd by this fixture so role wiring needs no schedule/execute dance
        accessManager = new AccessManager(address(this));

        // Tokens: quote stable + ONE machine share for both ST and JT, plus the machine's accounting token and the
        // machine itself. No Chainlink feed and no ERC4626 vault exists anywhere in this composition
        quoteToken = _deployERC20("Quote Stable", "QUOTE", cell.quoteAsset);
        machineShare = new MockERC20C("Machine Share", "mSHARE", _trancheDecimals);
        accountingToken = new MockERC20C("Accounting Token", "ACCT", _accountingDecimals);
        machine = new MockMakinaMachine(address(machineShare), address(accountingToken), _initialSharePriceWAD);
        vm.label(address(machineShare), "MachineShare");
        vm.label(address(accountingToken), "AccountingToken");
        vm.label(address(machine), "MockMakinaMachine");

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

        RoycoSeniorTranche stImpl = new RoycoSeniorTranche(address(machineShare), predictedKernel);
        RoycoJuniorTranche jtImpl = new RoycoJuniorTranche(address(machineShare), predictedKernel);
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
        makinaKernelImpl = new MakinaKernel(_makinaConstructionParams(), address(machine));

        PROTOCOL_FEE_RECIPIENT = makeAddr("PROTOCOL_FEE_RECIPIENT");

        // Kernel proxy from the dedicated deployer so it lands at the predicted address
        vm.prank(kernelProxyDeployer);
        address kernelProxy = address(new ERC1967Proxy(address(makinaKernelImpl), _kernelInitData(_initialConversionRateWAD)));
        require(kernelProxy == predictedKernel, "MakinaMarketTestBase: kernel proxy address prediction failed");
        makinaKernel = MakinaKernel(kernelProxy);
        vm.label(kernelProxy, "MakinaKernel");

        // The base's kernel handle is used only for ADDRESS-based role wiring, every selector the bindings target
        // that this composition implements (setConversionRate, sync, pause, ...) resolves identically, and binding
        // the Chainlink-only selectors this kernel lacks is an inert role-map entry
        kernel = ChainlinkKernel(kernelProxy);

        // The kernel is the senior leg's live rate provider in BOTH venue price stores, as in production
        balancerVault.setTokenRateProvider(address(seniorTranche), kernelProxy);
        bptOracle.setTokenRateProvider(address(seniorTranche), kernelProxy);

        _wireTargetFunctionRoles();
        _wireRoleGrants();
    }

    /// @notice Builds the standard kernel construction params over the currently deployed market components
    /// @dev Reused by construction-boundary tests that construct throwaway kernel impls against the live wiring
    function _makinaConstructionParams() internal view returns (IRoycoDayKernel.RoycoDayKernelConstructionParams memory) {
        return IRoycoDayKernel.RoycoDayKernelConstructionParams({
            seniorTranche: address(seniorTranche),
            stAsset: address(machineShare),
            juniorTranche: address(juniorTranche),
            jtAsset: address(machineShare),
            accountant: address(accountant),
            liquidityTranche: address(liquidityTranche),
            ltAsset: address(bpt),
            enforceVaultSharesTransferWhitelist: params.enforceWhitelistOnTransfer
        });
    }

    /// @notice Builds the kernel proxy initialization calldata for the specified initial admin conversion rate
    /// @param _initialConversionRateWAD The accounting-asset-to-NAV-unit rate to initialize the ST/JT quoter with
    function _kernelInitData(uint256 _initialConversionRateWAD) internal view returns (bytes memory) {
        return abi.encodeCall(
            makinaKernelImpl.initialize,
            (
                IRoycoDayKernel.RoycoDayKernelInitParams({
                    initialAuthority: address(accessManager),
                    protocolFeeRecipient: PROTOCOL_FEE_RECIPIENT,
                    stSelfLiquidationBonusWAD: params.stSelfLiquidationBonusWAD,
                    roycoBlacklist: address(0)
                }),
                MakinaKernel.KernelSpecificInitParams({
                    stAndJTQuoterParams: IdenticalMakinaShares_ST_JT_SharePriceToAdminOracle_Quoter.ST_JT_QuoterSpecificParams({
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
 * @title Test_MachineSharePriceTimesAdminRate_MakinaAdminOracleQuoter
 * @notice The Makina machine-share-price-to-admin-oracle composition's full construction, pricing, and admin surface:
 *         the constructor sanity checks (null machine, foreign share token, the supported decimal envelope), the
 *         zero-rate guards at initialization and at the setter, the composed two-hop rate across three decimal
 *         shapes, and the missing zero-rate sentinel branch pinned as a divergence
 * @dev The composition has NO oracle fallback: the stored admin rate is the only accounting-asset price source, and
 *      because the quoter reads it with no sentinel check, a zero stored rate silently prices everything at zero
 *      instead of failing loud (see the DIVERGENCE test at the bottom)
 */
contract Test_MachineSharePriceTimesAdminRate_MakinaAdminOracleQuoter is MakinaMarketTestBase {
    /// @dev Baseline shape: 18-decimal machine shares over an 18-decimal accounting token, machine share price 1.0, admin rate initialized to 2.0
    function setUp() public {
        _deployMakinaMarket(18, 18, 1e18, defaultParams(), 2e18);
    }

    // =============================
    // Construction sanity checks
    // =============================

    /**
     * @notice Constructing the kernel with a null Makina machine is rejected outright
     * @dev The machine's convertToAssets IS the live half of the two-hop rate: an admin quoter without a machine
     *      could never price the share hop, so accepting the null address would ship a kernel whose every quote
     *      calls into empty code. The constructor must fail loud before any market can be wired around it
     */
    function test_RevertIf_MakinaQuoterConstructedWithNullMachine() public {
        // A throwaway kernel impl against the live market wiring, only the machine argument is poisoned
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        new MakinaKernel(_makinaConstructionParams(), address(0));
    }

    /**
     * @notice Constructing the kernel with a machine whose share token is not the ST/JT asset is rejected
     * @dev The quoter prices the TRANCHE asset through the machine's share price, so the tranche asset must BE the
     *      machine's share token: pricing token X off machine Y's share price would mark every senior and junior
     *      NAV against an unrelated instrument. One equality check against ST_ASSET suffices because the parent
     *      quoter already forces ST_ASSET == JT_ASSET
     */
    function test_RevertIf_TrancheAssetIsNotMachineShareToken() public {
        // A machine over a foreign share token, everything else identical to the live wiring
        MockERC20C foreignShare = new MockERC20C("Foreign Share", "FRGN", 18);
        MockMakinaMachine foreignMachine = new MockMakinaMachine(address(foreignShare), address(accountingToken), 1e18);

        vm.expectRevert(IdenticalMakinaShares_ST_JT_SharePriceToAdminOracle_Quoter.TRANCHE_ASSET_MUST_BE_MACHINE_SHARE.selector);
        new MakinaKernel(_makinaConstructionParams(), address(foreignMachine));
    }

    /**
     * @notice Accounting-token decimals above 18 + tranche decimals fall outside the supported envelope and revert at construction
     * @dev The quoter derives the convertToAssets input as 10^(18 + trancheDecimals - accountingDecimals) so the
     *      machine's answer lands WAD-scaled. With 6-decimal shares and a 25-decimal accounting token the exponent
     *      is 18 + 6 - 25 = -1: no power-of-ten share amount can produce a WAD-scaled result, and the checked
     *      subtraction underflows (arithmetic panic 0x11). The revert is loud and at construction, so an
     *      out-of-envelope pairing can never reach a live market, but it surfaces as a raw panic rather than a
     *      typed error, this test documents the envelope boundary
     */
    function test_RevertIf_MachineAccountingDecimalsExceedWADPlusTrancheDecimals() public {
        // Redeploy the market with 6-decimal machine shares so the tranche side of the exponent is 6
        _deployMakinaMarket(6, 18, 1e18, defaultParams(), 1e18);

        // A machine over the SAME share token (so the share-token equality check passes) but a 25-decimal
        // accounting token, pushing the scale exponent to 18 + 6 - 25 = -1
        MockERC20C accounting25 = new MockERC20C("Accounting 25", "ACC25", 25);
        MockMakinaMachine outOfEnvelopeMachine = new MockMakinaMachine(address(machineShare), address(accounting25), 1e18);

        vm.expectRevert(stdError.arithmeticError);
        new MakinaKernel(_makinaConstructionParams(), address(outOfEnvelopeMachine));
    }

    // =============================
    // Zero-rate guards (fail loud at configuration)
    // =============================

    /**
     * @notice Initializing the kernel with a zero conversion rate is rejected outright
     * @dev In this composition the stored admin rate is the ONLY accounting-asset-to-NAV price source and 0 is the
     *      storage sentinel: a market initialized at 0 would silently price every tranche unit at zero NAV (this
     *      quoter never falls back to an oracle), so the configuration must fail loud instead
     */
    function test_RevertIf_MakinaQuoterInitializedWithZeroConversionRate() public {
        // A fresh proxy over the already-constructed impl re-runs initialize with rate 0 against the same market wiring
        bytes memory initData = _kernelInitData(0);
        vm.expectRevert(IdenticalAssets_ST_JT_AdminOracle_Quoter.INVALID_CONVERSION_RATE.selector);
        new ERC1967Proxy(address(makinaKernelImpl), initData);
    }

    /**
     * @notice The admin setter rejects the zero rate, and an unprivileged caller cannot move the rate at all
     * @dev The setter must dispatch through the zero-rejecting admin guard: storing 0 would not restore any oracle
     *      path (there is none in this composition), it would silently zero every forward quote and brick every
     *      inverse quote. And the stored rate is the entire accounting-asset price source, so an attacker-set rate
     *      would remark every senior and junior NAV in the very next sync, hence the access gate
     */
    function test_RevertIf_MakinaConversionRateSetToZeroOrByNonAdmin() public {
        // Even the legitimate admin cannot store the sentinel 0
        vm.prank(ORACLE_QUOTER_ADMIN);
        vm.expectRevert(IdenticalAssets_ST_JT_AdminOracle_Quoter.INVALID_CONVERSION_RATE.selector);
        makinaKernel.setConversionRate(0, false);

        // The rejected zero must not have clobbered the initialization-time 2.0 rate
        assertEq(makinaKernel.getStoredConversionRateWAD(), 2e18, "the stored rate must be untouched by the rejected zero");

        // An unprivileged caller is rejected by the access manager before any rate logic runs
        address attacker = makeAddr("ATTACKER");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, attacker));
        makinaKernel.setConversionRate(20e18, false);

        assertEq(makinaKernel.getStoredConversionRateWAD(), 2e18, "the stored rate must be untouched by the failed attempt");
        // Pricing still runs off the surviving rate: 1e18 share-wei x (machine 1.0 x admin 2.0) = 2e18 NAV
        assertEq(toUint256(makinaKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 2e18, "pricing must still run off the surviving stored rate");
    }

    // =============================
    // The composed two-hop rate
    // =============================

    /**
     * @notice The composed rate is floor(machine share price x admin rate / 1e18) across three decimal shapes, both
     *         tranches price through it, the inverse round-trips, and each hop reprices independently
     * @dev The quoter feeds convertToAssets exactly 10^(18 + trancheDecimals - accountingDecimals) share-wei so the
     *      machine's answer is the WAD-scaled share price regardless of either token's decimals, then multiplies by
     *      the stored admin rate. Every expected value below is composed by hand from the two hops
     */
    function test_MakinaTwoHopRate_ComposesMachineSharePriceWithAdminRate() public {
        // ---- Shape 1: 18-decimal shares over a 6-decimal accounting token (share price 1.5, admin rate 0.8) ----
        // convertToAssets input is 10^(18+18-6) = 1e30 share-wei, the answer is the WAD share price 1.5e18.
        // Composed: floor(1.5e18 x 0.8e18 / 1e18) = 1.2e18 NAV per whole share
        _deployMakinaMarket(18, 6, 1.5e18, defaultParams(), 0.8e18);
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 1.2e18, "shape 1: the composed rate must be 1.5 x 0.8 = 1.2");
        // One whole 18-decimal share is 1e18 tranche-wei: 1e18 x 1.2e18 / 1e18 = 1.2e18 NAV, identically on both tranches
        assertEq(toUint256(makinaKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 1.2e18, "shape 1: one whole share must quote 1.2 NAV");
        assertEq(toUint256(makinaKernel.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 1.2e18, "shape 1: the junior side prices through the identical rate");
        // 1 share-wei: floor(1 x 1.2e18 / 1e18) = 1 NAV-wei
        assertEq(toUint256(makinaKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1))), 1, "shape 1: a 1-wei quote must floor 1.2 down to 1 NAV-wei");
        // The inverse divides by the same composed rate: 1.2e18 NAV x 1e18 / 1.2e18 = 1e18 share-wei, an exact round-trip
        assertEq(toUint256(makinaKernel.stConvertNAVUnitsToTrancheUnits(toNAVUnits(uint256(1.2e18)))), 1e18, "shape 1: NAV -> share must invert the composed rate");
        assertEq(toUint256(makinaKernel.jtConvertNAVUnitsToTrancheUnits(toNAVUnits(uint256(1.2e18)))), 1e18, "shape 1: the junior inverse shares the identical rate");

        // Machine yield reprices with NO admin action, the live hop: share price 1.5 -> 2.0 moves the composed
        // rate to floor(2e18 x 0.8e18 / 1e18) = 1.6e18, while the stored admin rate stays put
        machine.setSharePriceWAD(2e18);
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 1.6e18, "shape 1: machine yield must reprice the composed rate to 2.0 x 0.8 = 1.6");
        assertEq(toUint256(makinaKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 1.6e18, "shape 1: quotes must track the live machine hop");
        assertEq(makinaKernel.getStoredConversionRateWAD(), 0.8e18, "shape 1: the static admin hop must be untouched by machine yield");

        // The admin hop reprices independently through the setter: rate 0.8 -> 1.5 at share price 2.0 composes to
        // floor(2e18 x 1.5e18 / 1e18) = 3e18
        vm.prank(ORACLE_QUOTER_ADMIN);
        makinaKernel.setConversionRate(1.5e18, false);
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 3e18, "shape 1: the admin hop must reprice the composed rate to 2.0 x 1.5 = 3.0");
        assertEq(toUint256(makinaKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 3e18, "shape 1: quotes must track the updated admin hop");

        // ---- Shape 2: 18-decimal shares over an 18-decimal accounting token (share price 1e18 + 1, admin rate 0.5) ----
        // convertToAssets input is 10^(18+18-18) = 1e18 share-wei (one whole share), the answer is 1e18 + 1.
        // Composed: floor((1e18 + 1) x 5e17 / 1e18) = floor(5e17 + 0.5) = 5e17, the half-wei contribution of the
        // machine's 1-wei-above-peg share price floors away
        _deployMakinaMarket(18, 18, 1e18 + 1, defaultParams(), 0.5e18);
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 5e17, "shape 2: the 1-wei share-price excess must floor out of the composed rate");
        // One whole share: 1e18 x 5e17 / 1e18 = 5e17 NAV
        assertEq(toUint256(makinaKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 5e17, "shape 2: one whole share must quote 0.5 NAV");
        assertEq(toUint256(makinaKernel.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 5e17, "shape 2: the junior side prices through the identical rate");
        // The inverse: 5e17 NAV x 1e18 / 5e17 = 1e18 share-wei, an exact round-trip
        assertEq(toUint256(makinaKernel.stConvertNAVUnitsToTrancheUnits(toNAVUnits(uint256(5e17)))), 1e18, "shape 2: NAV -> share must invert the composed rate");

        // Machine hop reprice: share price -> 3.0 composes to floor(3e18 x 5e17 / 1e18) = 1.5e18
        machine.setSharePriceWAD(3e18);
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 1.5e18, "shape 2: machine yield must reprice the composed rate to 3.0 x 0.5 = 1.5");
        // Admin hop reprice: rate -> 2.0 composes to floor(3e18 x 2e18 / 1e18) = 6e18
        vm.prank(ORACLE_QUOTER_ADMIN);
        makinaKernel.setConversionRate(2e18, false);
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 6e18, "shape 2: the admin hop must reprice the composed rate to 3.0 x 2.0 = 6.0");

        // ---- Shape 3: 6-decimal shares over an 18-decimal accounting token (share price 2.5, admin rate 2.0) ----
        // convertToAssets input is 10^(18+6-18) = 1e6 share-wei (one whole share), the answer is the WAD share
        // price 2.5e18. Composed: floor(2.5e18 x 2e18 / 1e18) = 5e18 NAV per whole share
        _deployMakinaMarket(6, 18, 2.5e18, defaultParams(), 2e18);
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 5e18, "shape 3: the composed rate must be 2.5 x 2.0 = 5.0");
        // One whole 6-decimal share is 1e6 tranche-wei: 1e6 x 5e18 / 1e6 = 5e18 NAV
        assertEq(toUint256(makinaKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e6))), 5e18, "shape 3: one whole 6-dec share must quote 5.0 NAV");
        assertEq(toUint256(makinaKernel.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e6))), 5e18, "shape 3: the junior side prices through the identical rate");
        // 1 share-wei is a millionth of a whole share: 1 x 5e18 / 1e6 = 5e12 NAV-wei exactly (no flooring loss)
        assertEq(toUint256(makinaKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1))), 5e12, "shape 3: a 1-wei quote must scale by the 6-dec tranche unit exactly");
        // The inverse: 5e18 NAV x 1e6 / 5e18 = 1e6 share-wei, an exact round-trip
        assertEq(toUint256(makinaKernel.stConvertNAVUnitsToTrancheUnits(toNAVUnits(uint256(5e18)))), 1e6, "shape 3: NAV -> share must invert the composed rate");
    }

    // =============================
    // Pinned divergence: no zero-rate sentinel branch
    // =============================

    /**
     * @notice A zero stored rate silently prices every tranche unit at zero NAV instead of reverting loud
     * @dev The ERC4626 sibling quoter treats a zero stored rate as the sentinel and routes it to the admin oracle
     *      hook, which reverts loud (MUST_USE_ADMIN_ORACLE_INPUT). The Makina quoter reads the stored rate with NO
     *      sentinel check, so on a proxy whose initializer never ran (rate storage still 0, a state the initializer
     *      and setter both reject but a bare or hijacked proxy exposes) the composed rate is machine hop x 0 = 0:
     *      a sync would read total senior wipeout off a pricing artifact rather than failing, and the inverse
     *      direction divides by the zero rate and panics. This test pins the CURRENT silent-zero behavior, the
     *      expected behavior is a loud typed revert exactly like the sibling's
     */
    function test_DIVERGENCE_18_MakinaQuoterZeroStoredRateSilentlyZeroesTrancheNAVInsteadOfReverting() public {
        // An uninitialized proxy over the live impl: all immutables (machine, tranche assets) resolve, but the
        // stored conversion rate slot was never written and holds the sentinel 0
        MakinaKernel bare = MakinaKernel(address(new UninitializedERC1967Proxy(address(makinaKernelImpl))));

        // The composed rate silently reads 0: machine hop 1e18 x stored 0 / 1e18 = 0, no revert anywhere
        assertEq(bare.getTrancheUnitToNAVUnitConversionRateWAD(), 0, "the composed rate must silently read zero on the sentinel stored rate");

        // Forward conversion silently zeroes: 1e18 share-wei x 0 / 1e18 = 0 NAV, a full senior mark-to-zero
        assertEq(toUint256(bare.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 0, "a whole-share quote must silently collapse to zero NAV");
        assertEq(toUint256(bare.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 0, "the junior side silently collapses identically");

        // The inverse direction divides by the zero composed rate: 1e18 NAV x 1e18 / 0 panics (0x12) instead of
        // reverting with a typed error, so the two directions fail asymmetrically off the same broken state
        vm.expectRevert(stdError.divisionError);
        bare.stConvertNAVUnitsToTrancheUnits(toNAVUnits(uint256(1e18)));
    }
}
