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
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel as ShippedKernel
} from "../../../src/kernels/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel.sol";
import {
    Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel as MakinaChainlinkKernel
} from "../../../src/kernels/Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel.sol";
import {
    IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_Quoter
} from "../../../src/kernels/base/quoter/identical-st-jt/IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_Quoter.sol";
import {
    IdenticalAssets_ST_JT_ChainlinkOracle_Quoter
} from "../../../src/kernels/base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.sol";
import { IdenticalAssets_ST_JT_Oracle_Quoter } from "../../../src/kernels/base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_Oracle_Quoter.sol";
import { BalancerV3_LT_BPTOracle_Quoter } from "../../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_BPTOracle_Quoter.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoJuniorTranche } from "../../../src/tranches/RoycoJuniorTranche.sol";
import { RoycoLiquidityTranche } from "../../../src/tranches/RoycoLiquidityTranche.sol";
import { RoycoSeniorTranche } from "../../../src/tranches/RoycoSeniorTranche.sol";
import { MockAggregatorV3 } from "../../mocks/MockAggregatorV3.sol";
import { MockBPT } from "../../mocks/MockBPT.sol";
import { MockBPTOracle } from "../../mocks/MockBPTOracle.sol";
import { MockBalancerVault } from "../../mocks/MockBalancerVault.sol";
import { MockERC20C } from "../../mocks/MockERC20C.sol";
import { MockMakinaMachine } from "../../mocks/MockMakinaMachine.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { FixtureCell, MarketParamsConfig } from "../../utils/FixtureTypes.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { _plainToken } from "../../utils/TokenConfigs.sol";

/**
 * @title MakinaChainlinkMarketTestBase
 * @notice Deploys a full Day market around the Makina machine-share-price-to-Chainlink-oracle kernel composition: the
 *         tranche unit is a Makina machine share whose accounting-asset value comes from the machine's
 *         convertToAssets (a live hop) and whose accounting-asset-to-NAV-unit rate comes from a Chainlink feed with
 *         a stored admin rate as an OVERRIDE (a nonzero stored rate wins, zero restores the feed path)
 * @dev Mirrors MakinaMarketTestBase step for step and swaps only the second hop: a MockAggregatorV3
 *      accounting-asset-to-NAV price feed is wired into the kernel init through the 5-field Chainlink quoter params.
 *      The tests drive the shipped concrete Makina Chainlink kernel from src/kernels end to end. The market stays
 *      unseeded in every test, conversion rates are independent of tranche NAVs and the setters' internal accounting
 *      syncs pass trivially at zero NAVs
 */
abstract contract MakinaChainlinkMarketTestBase is DayMarketTestBase {
    /// @notice The deployed market's kernel proxy, typed to the Makina Chainlink composition under test
    MakinaChainlinkKernel internal makinaKernel;

    /// @notice The kernel implementation, kept so tests can attempt fresh proxy initializations against it
    MakinaChainlinkKernel internal makinaKernelImpl;

    /// @notice The plain ERC20 machine share serving as the coinvested collateral asset (the kernel prices it as COLLATERAL_ASSET)
    MockERC20C internal machineShare;

    /// @notice The machine's accounting token, the intermediate asset of the two-hop NAV conversion
    MockERC20C internal accountingToken;

    /// @notice The Makina machine whose settable share price is the live first hop of the composed rate
    MockMakinaMachine internal machine;

    /// @notice The accounting-asset-to-NAV Chainlink-shaped feed, the oracle half of the second hop
    MockAggregatorV3 internal accountingFeed;

    /// @notice The sequencer uptime feed wired at kernel init, the null address when the deploy disabled the check
    address internal initSequencerUptimeFeed;

    /// @notice Deploys the full Day market with no sequencer uptime feed configured
    function _deployMakinaChainlinkMarket(
        uint8 _trancheDecimals,
        uint8 _accountingDecimals,
        uint256 _initialSharePriceWAD,
        uint8 _feedDecimals,
        int256 _feedAnswer,
        MarketParamsConfig memory _params,
        uint256 _initialConversionRateWAD
    )
        internal
    {
        _deployMakinaChainlinkMarket(
            _trancheDecimals, _accountingDecimals, _initialSharePriceWAD, _feedDecimals, _feedAnswer, _params, _initialConversionRateWAD, address(0)
        );
    }

    /**
     * @notice Deploys the full Day market with the Makina Chainlink kernel composition
     * @param _trancheDecimals The machine share (tranche asset) decimals
     * @param _accountingDecimals The machine accounting token decimals
     * @param _initialSharePriceWAD The machine's initial share price (whole accounting tokens per whole share), WAD scaled
     * @param _feedDecimals The accounting-asset-to-NAV feed's oracle decimals
     * @param _feedAnswer The feed's initial answer, scaled to the feed decimals
     * @param _params The market parameterization to deploy
     * @param _initialConversionRateWAD The stored accounting-asset-to-NAV rate the kernel is initialized with (0 runs Chainlink-primary)
     * @param _sequencerUptimeFeed The L2 sequencer uptime feed wired at init (the null address disables the check)
     */
    function _deployMakinaChainlinkMarket(
        uint8 _trancheDecimals,
        uint8 _accountingDecimals,
        uint256 _initialSharePriceWAD,
        uint8 _feedDecimals,
        int256 _feedAnswer,
        MarketParamsConfig memory _params,
        uint256 _initialConversionRateWAD,
        address _sequencerUptimeFeed
    )
        internal
    {
        // The base fixture's ERC4626 shape validation does not apply here: the tranche asset is a PLAIN ERC20
        // machine share, only the quote-asset decimals are consumed by the base's pool-genesis helper
        cell = FixtureCell({ name: "MakinaChainlink", collateralAsset: _plainToken(_trancheDecimals), quoteAsset: _plainToken(6) });
        params = _params;
        initSequencerUptimeFeed = _sequencerUptimeFeed;

        // Access manager, admin'd by this fixture so role wiring needs no schedule/execute dance
        accessManager = new AccessManager(address(this));

        // Tokens: quote stable + ONE machine share for both ST and JT, plus the machine's accounting token, the
        // machine itself, and the accounting-asset-to-NAV Chainlink-shaped feed. No ERC4626 vault exists anywhere
        quoteToken = _deployERC20("Quote Stable", "QUOTE", cell.quoteAsset);
        machineShare = new MockERC20C("Machine Share", "mSHARE", _trancheDecimals);
        accountingToken = new MockERC20C("Accounting Token", "ACCT", _accountingDecimals);
        machine = new MockMakinaMachine(address(machineShare), address(accountingToken), _initialSharePriceWAD);
        accountingFeed = new MockAggregatorV3(_feedDecimals, _feedAnswer);
        vm.label(address(machineShare), "MachineShare");
        vm.label(address(accountingToken), "AccountingToken");
        vm.label(address(machine), "MockMakinaMachine");
        vm.label(address(accountingFeed), "MockAccountingFeed");

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
        RoycoDayAccountant accImpl = new RoycoDayAccountant(predictedKernel);

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
        makinaKernelImpl = new MakinaChainlinkKernel(_makinaConstructionParams(), address(machine));

        PROTOCOL_FEE_RECIPIENT = makeAddr("PROTOCOL_FEE_RECIPIENT");

        // Kernel proxy from the dedicated deployer so it lands at the predicted address
        vm.prank(kernelProxyDeployer);
        address kernelProxy = address(new ERC1967Proxy(address(makinaKernelImpl), _kernelInitData(_initialConversionRateWAD, _sequencerUptimeFeed)));
        require(kernelProxy == predictedKernel, "MakinaChainlinkMarketTestBase: kernel proxy address prediction failed");
        makinaKernel = MakinaChainlinkKernel(kernelProxy);
        vm.label(kernelProxy, "MakinaChainlinkKernel");

        // The base's kernel handle is used only for ADDRESS-based role wiring, and every selector the bindings
        // target (setConversionRate, setChainlinkOracle, setSequencerUptimeFeed, sync, pause, ...) exists on this
        // composition and resolves identically
        kernel = ShippedKernel(kernelProxy);

        // The kernel is the senior leg's live rate provider in BOTH venue price stores, as in production
        balancerVault.setTokenRateProvider(address(seniorTranche), kernelProxy);
        bptOracle.setTokenRateProvider(address(seniorTranche), kernelProxy);

        _wireTargetFunctionRoles();
        _wireRoleGrants();
    }

    /// @notice Builds the standard kernel construction params over the currently deployed market Constants
    /// @dev Reused by construction-boundary tests that construct throwaway kernel impls against the live wiring
    function _makinaConstructionParams() internal view returns (IRoycoDayKernel.RoycoDayKernelConstructionParams memory) {
        return IRoycoDayKernel.RoycoDayKernelConstructionParams({
            seniorTranche: address(seniorTranche),
            juniorTranche: address(juniorTranche),
            collateralAsset: address(machineShare),
            accountant: address(accountant),
            liquidityTranche: address(liquidityTranche),
            ltAsset: address(bpt),
            enforceVaultSharesTransferWhitelist: params.enforceWhitelistOnTransfer
        });
    }

    /// @notice Builds the kernel proxy initialization calldata for the specified initial stored rate and sequencer feed, wiring the fixture's accounting feed
    /// @param _initialConversionRateWAD The stored accounting-asset-to-NAV rate to initialize the ST/JT quoter with (0 runs Chainlink-primary)
    /// @param _sequencerUptimeFeed The L2 sequencer uptime feed (the null address disables the check)
    function _kernelInitData(uint256 _initialConversionRateWAD, address _sequencerUptimeFeed) internal view returns (bytes memory) {
        return _kernelInitDataWithOracle(_initialConversionRateWAD, address(accountingFeed), _sequencerUptimeFeed);
    }

    /// @notice Builds the kernel proxy initialization calldata with an explicit accounting-asset-to-NAV oracle, so init-gate tests can pass the null address
    /// @param _initialConversionRateWAD The stored accounting-asset-to-NAV rate to initialize the ST/JT quoter with (0 runs Chainlink-primary)
    /// @param _oracle The accounting-asset-to-NAV oracle to wire (the null address runs admin-primary and requires a nonzero stored rate)
    /// @param _sequencerUptimeFeed The L2 sequencer uptime feed (the null address disables the check)
    function _kernelInitDataWithOracle(uint256 _initialConversionRateWAD, address _oracle, address _sequencerUptimeFeed) internal view returns (bytes memory) {
        return abi.encodeCall(
            makinaKernelImpl.initialize,
            (
                IRoycoDayKernel.RoycoDayKernelInitParams({
                    initialAuthority: address(accessManager),
                    protocolFeeRecipient: PROTOCOL_FEE_RECIPIENT,
                    stSelfLiquidationBonusWAD: params.stSelfLiquidationBonusWAD,
                    roycoBlacklist: address(0)
                }),
                MakinaChainlinkKernel.KernelSpecificInitParams({
                    stAndJTQuoterParams: IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_Quoter.ST_JT_QuoterSpecificParams({
                        initialConversionRateWAD: _initialConversionRateWAD,
                        accountingAssetToNavAssetOracle: _oracle,
                        stalenessThresholdSeconds: ORACLE_STALENESS_THRESHOLD_SECONDS,
                        sequencerUptimeFeed: _sequencerUptimeFeed,
                        gracePeriodSeconds: ORACLE_GRACE_PERIOD_SECONDS
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
 * @title Test_MachineSharePriceTimesChainlinkRate_MakinaChainlinkOracleQuoter
 * @notice The Makina machine-share-price-to-Chainlink-oracle composition's full construction, pricing, override, and
 *         admin surface: the constructor sanity checks, both initial rate configurations (the VALID zero rate this
 *         family supports and its admin sibling forbids, and the nonzero genesis override), the composed two-hop
 *         rate across decimal shapes and feed decimal configurations on both sides of WAD, the stored-rate override
 *         precedence over the feed, and every inherited Chainlink gate through the composed path
 * @dev UNLIKE the Makina admin sibling, the second hop here has an oracle: zero is the query-the-feed sentinel, not
 *      a bricked configuration, so setConversionRate resolves to the PERMISSIVE root setter (a nonzero value stores
 *      an override that short-circuits the feed entirely, zero restores the feed path and its gates)
 */
contract Test_MachineSharePriceTimesChainlinkRate_MakinaChainlinkOracleQuoter is MakinaChainlinkMarketTestBase {
    /// @dev Baseline shape: 18-decimal shares over an 18-decimal accounting token, share price 1.0, an 8-decimal feed at 1.0, stored rate 0 (Chainlink-primary)
    function setUp() public {
        _deployMakinaChainlinkMarket(18, 18, 1e18, 8, 1e8, defaultParams(), 0);
    }

    // =============================
    // Construction sanity checks
    // =============================

    /**
     * @notice Constructing the kernel with a null Makina machine is rejected outright
     * @dev The machine's convertToAssets IS the live half of the two-hop rate: a Chainlink quoter without a machine
     *      could never price the share hop, so accepting the null address would ship a kernel whose every quote
     *      calls into empty code. The constructor must fail loud before any market can be wired around it
     */
    function test_RevertIf_MakinaChainlinkQuoterConstructedWithNullMachine() public {
        // A throwaway kernel impl against the live market wiring, only the machine argument is poisoned
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        new MakinaChainlinkKernel(_makinaConstructionParams(), address(0));
    }

    /**
     * @notice Constructing the kernel with a machine whose share token is not the collateral asset is rejected
     * @dev The quoter prices the TRANCHE asset through the machine's share price, so the tranche asset must BE the
     *      machine's share token: pricing token X off machine Y's share price would mark every senior and junior
     *      NAV against an unrelated instrument. One equality check against COLLATERAL_ASSET suffices because both
     *      tranches deposit the one collateral asset
     */
    function test_RevertIf_TrancheAssetIsNotMakinaChainlinkMachineShareToken() public {
        // A machine over a foreign share token, everything else identical to the live wiring
        MockERC20C foreignShare = new MockERC20C("Foreign Share", "FRGN", 18);
        MockMakinaMachine foreignMachine = new MockMakinaMachine(address(foreignShare), address(accountingToken), 1e18);

        vm.expectRevert(IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_Quoter.TRANCHE_ASSET_MUST_BE_MACHINE_SHARE.selector);
        new MakinaChainlinkKernel(_makinaConstructionParams(), address(foreignMachine));
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
    function test_RevertIf_MakinaChainlinkAccountingDecimalsExceedWADPlusTrancheDecimals() public {
        // Redeploy the market with 6-decimal machine shares so the tranche side of the exponent is 6
        _deployMakinaChainlinkMarket(6, 18, 1e18, 8, 1e8, defaultParams(), 0);

        // A machine over the SAME share token (so the share-token equality check passes) but a 25-decimal
        // accounting token, pushing the scale exponent to 18 + 6 - 25 = -1
        MockERC20C accounting25 = new MockERC20C("Accounting 25", "ACC25", 25);
        MockMakinaMachine outOfEnvelopeMachine = new MockMakinaMachine(address(machineShare), address(accounting25), 1e18);

        vm.expectRevert(stdError.arithmeticError);
        new MakinaChainlinkKernel(_makinaConstructionParams(), address(outOfEnvelopeMachine));
    }

    // =============================
    // The initial rate configurations (zero runs Chainlink-primary, nonzero installs a genesis override)
    // =============================

    /**
     * @notice Initializing the kernel with a zero conversion rate is VALID and the composed rate prices through the feed
     * @dev The Makina admin sibling rejects a zero initial rate with INVALID_CONVERSION_RATE because its stored rate
     *      is the ONLY second-hop price source. Here zero is the query-the-feed sentinel: the init skips the store,
     *      the quoter runs Chainlink-primary, and the composed rate is machine share price x the feed price scaled
     *      to WAD. A regression that routed this family's init through the zero-rejecting admin guard would make
     *      the shipped Chainlink-primary configuration undeployable
     */
    function test_ZeroInitialConversionRate_IsValidAndPricesThroughTheFeed() public {
        // The setUp market was initialized with rate 0 and deployed successfully, the sentinel is in storage
        assertEq(makinaKernel.getStoredConversionRateWAD(), 0, "a zero initial rate must land as the query-the-feed sentinel");

        // Composed: machine 1.0 x feed floor(1e8 x 1e18 / 1e8) = 1e18, so floor(1e18 x 1e18 / 1e18) = 1e18
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 1e18, "the composed rate must price through the feed with no stored rate");
        // One whole 18-decimal share is 1e18 tranche-wei: 1e18 x 1e18 / 1e18 = 1e18 NAV through the one collateral converter both tranches share
        assertEq(toUint256(makinaKernel.convertCollateralAssetsToValue(toTrancheUnits(1e18))), 1e18, "one whole share must quote 1.0 NAV through the feed");
        // The inverse divides by the same composed rate: 1e18 NAV x 1e18 / 1e18 = 1e18 share-wei
        assertEq(toUint256(makinaKernel.convertValueToCollateralAssets(toNAVUnits(uint256(1e18)))), 1e18, "NAV -> share must invert the feed-composed rate");

        // A FRESH proxy over the live impl also initializes cleanly at rate 0, the exact call shape the admin
        // sibling pins as an INVALID_CONVERSION_RATE revert
        MakinaChainlinkKernel fresh = MakinaChainlinkKernel(address(new ERC1967Proxy(address(makinaKernelImpl), _kernelInitData(0, address(0)))));
        assertEq(fresh.getTrancheUnitToNAVUnitConversionRateWAD(), 1e18, "a fresh zero-rate proxy must price through the feed immediately");
    }

    /**
     * @notice Initializing the kernel with a NONZERO conversion rate installs a genesis override: the composed rate
     *         runs off the stored rate from the very first quote, a fully dead feed cannot block pricing, and
     *         setConversionRate(0) hands the second hop back to the feed
     * @dev The initializer writes the nonzero rate into the same storage slot the admin setter uses, so the override
     *      precedence must hold with NO setter call ever made. This is the day-one rescue shape: a market can launch
     *      against an accounting asset whose feed is not yet live (or not yet trusted) and run entirely on the
     *      governed rate until governance clears it. A regression that dropped the init-time store would silently
     *      launch such a market Chainlink-primary and brick it on the first dead-feed quote
     */
    function test_NonzeroInitialConversionRate_InstallsAGenesisOverrideThatShortCircuitsTheFeed() public {
        // Redeploy with machine share price 1.5, the 8-decimal feed at 1.0, and initial stored rate 2.0. The share
        // price off 1.0 makes the composition unambiguous: the composed rate below matches NEITHER hop alone
        _deployMakinaChainlinkMarket(18, 18, 1.5e18, 8, 1e8, defaultParams(), 2e18);

        // The init must have landed the rate in quoter storage, exactly as the admin setter would
        assertEq(makinaKernel.getStoredConversionRateWAD(), 2e18, "a nonzero initial rate must land in quoter storage");

        // Composed: machine 1.5 x stored 2.0 = floor(1.5e18 x 2e18 / 1e18) = 3e18. The feed path would compose to
        // machine 1.5 x feed 1.0 = 1.5e18 and the stored rate alone is 2e18, so 3e18 proves the genesis override is
        // the second hop of a genuine two-hop composition, not a passthrough of either value
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 3e18, "the composed rate must be machine 1.5 x stored 2.0, not the feed path");
        // One whole share: 1e18 x 3e18 / 1e18 = 3e18 NAV through the one collateral converter both tranches share
        assertEq(toUint256(makinaKernel.convertCollateralAssetsToValue(toTrancheUnits(1e18))), 3e18, "one whole share must quote through the genesis override");
        // The inverse: 3e18 NAV x 1e18 / 3e18 = 1e18 share-wei, an exact round-trip
        assertEq(toUint256(makinaKernel.convertValueToCollateralAssets(toNAVUnits(uint256(3e18)))), 1e18, "NAV -> share must invert the override-composed rate");

        // Poison the feed BOTH ways (stale by warp AND armed to revert outright): if the init-stored rate did not
        // short-circuit _queryChainlinkOracle these quotes would revert, so surviving them proves the genesis
        // override never consults the feed even though no setter call ever ran
        vm.warp(block.timestamp + ORACLE_STALENESS_THRESHOLD_SECONDS + 1);
        accountingFeed.setRevertMode(true);
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 3e18, "a dead feed must not block a genesis-overridden rate");
        assertEq(toUint256(makinaKernel.convertCollateralAssetsToValue(toTrancheUnits(1e18))), 3e18, "forward quotes must run off the genesis override");
        assertEq(toUint256(makinaKernel.convertValueToCollateralAssets(toNAVUnits(uint256(3e18)))), 1e18, "inverse quotes must run off the genesis override");

        // Clearing to the sentinel hands the second hop back to the feed. The feed must be healthy again first,
        // since the setter's post-set re-cache prices through the now-feed-driven rate
        accountingFeed.setRevertMode(false);
        accountingFeed.setUpdatedAt(block.timestamp);
        vm.prank(ORACLE_QUOTER_ADMIN);
        makinaKernel.setConversionRate(0, false);
        assertEq(makinaKernel.getStoredConversionRateWAD(), 0, "clearing the genesis override must restore the sentinel");
        // The feed path resumes: machine 1.5 x feed 1.0 = floor(1.5e18 x 1e18 / 1e18) = 1.5e18
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 1.5e18, "the cleared quoter must price through the feed at 1.5 x 1.0");
    }

    // =============================
    // The oracle-presence invariant (no configuration may strand both price sources)
    // =============================

    /**
     * @notice Initializing the kernel with a zero rate AND a null oracle is rejected outright
     * @dev Zero is the query-the-feed sentinel and the null oracle means there is no feed to query, so this
     *      configuration has no price source at all: before the invariant it deployed successfully and bricked on
     *      the first quote with an untyped revert into empty code. The config gate must catch it at initialize with
     *      a typed error instead of letting a priceless market ship
     */
    function test_RevertIf_InitializedWithNullOracleAndZeroRate() public {
        // A fresh proxy over the live impl with BOTH second-hop price sources absent
        bytes memory initData = _kernelInitDataWithOracle(0, address(0), address(0));
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.NULL_ORACLE_WITHOUT_STORED_RATE.selector);
        new ERC1967Proxy(address(makinaKernelImpl), initData);
    }

    /**
     * @notice Initializing with a nonzero rate and a null oracle is a valid admin-primary configuration
     * @dev This is the shape that emulates the admin sibling on the Chainlink composition: the stored rate is the
     *      whole second hop and no feed exists to consult. The invariant must permit it (the stored rate prices the
     *      market) while the paired init gate above rejects the priceless variant, so admin-primary deployments are
     *      a first-class configuration rather than an accident of the null-oracle allowance
     */
    function test_NullOracleWithNonzeroInitialRate_RunsAdminPrimary() public {
        // A fresh proxy over the live impl: stored rate 2.0 as the entire second hop, no oracle wired
        MakinaChainlinkKernel fresh =
            MakinaChainlinkKernel(address(new ERC1967Proxy(address(makinaKernelImpl), _kernelInitDataWithOracle(2e18, address(0), address(0)))));

        // The rate landed and the oracle slot is genuinely null
        assertEq(fresh.getStoredConversionRateWAD(), 2e18, "the admin-primary rate must land in quoter storage");
        assertEq(fresh.getChainlinkOracleConfiguration().oracle, address(0), "the oracle slot must be null in the admin-primary configuration");

        // Composed: machine 1.0 x stored 2.0 = 2e18, priced with no feed in existence, forward and inverse
        assertEq(fresh.getTrancheUnitToNAVUnitConversionRateWAD(), 2e18, "the composed rate must run off the stored rate with no oracle wired");
        assertEq(toUint256(fresh.convertCollateralAssetsToValue(toTrancheUnits(1e18))), 2e18, "one whole share must quote through the admin-primary rate");
        assertEq(toUint256(fresh.convertValueToCollateralAssets(toNAVUnits(uint256(2e18)))), 1e18, "NAV -> share must invert the admin-primary rate");
    }

    /**
     * @notice The two setters gate each other so no admin operation sequence can strand both price sources: the
     *         oracle cannot be detached while the sentinel is stored, and the sentinel cannot be stored while the
     *         oracle is null, while the full migration to admin-primary and back remains reachable in order
     * @dev Each setter checks the OTHER price source before removing its own: setChainlinkOracle(0) requires a
     *      stored rate and setConversionRate(0) requires a wired oracle. Before the invariant both landed (or died
     *      in the post-set sync with an untyped revert into empty code), so a two-step admin mistake could strand a
     *      live market with no price source. The lifecycle below walks the whole state machine through the public
     *      surface: feed-primary -> override -> detached admin-primary -> blocked sentinel -> re-attached -> feed-primary
     */
    function test_OraclePresenceInvariant_DetachAndSentinelGateEachOther() public {
        // Feed-primary (the setUp baseline): detaching the only price source is rejected with a typed error
        vm.prank(ORACLE_QUOTER_ADMIN);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.NULL_ORACLE_WITHOUT_STORED_RATE.selector);
        makinaKernel.setChainlinkOracle(address(0), 0, false);
        assertEq(makinaKernel.getChainlinkOracleConfiguration().oracle, address(accountingFeed), "the rejected detach must leave the feed wired");

        // Install an override, then the detach is legal: the stored rate carries the second hop alone
        vm.prank(ORACLE_QUOTER_ADMIN);
        makinaKernel.setConversionRate(2e18, false);
        vm.prank(ORACLE_QUOTER_ADMIN);
        makinaKernel.setChainlinkOracle(address(0), 0, false);
        assertEq(makinaKernel.getChainlinkOracleConfiguration().oracle, address(0), "the overridden market must permit detaching the feed");
        // Admin-primary pricing: machine 1.0 x stored 2.0 = 2e18
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 2e18, "the detached market must price through the stored rate");

        // With no oracle wired, storing the sentinel is rejected with a typed error instead of the untyped
        // empty-code revert this exact sequence produced before the invariant
        vm.prank(ORACLE_QUOTER_ADMIN);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.SENTINEL_RATE_WITHOUT_ORACLE.selector);
        makinaKernel.setConversionRate(0, false);
        assertEq(makinaKernel.getStoredConversionRateWAD(), 2e18, "the rejected sentinel must leave the stored rate untouched");

        // Re-attach the feed, then the sentinel is legal again and the feed path resumes: machine 1.0 x feed 1.0 = 1e18
        vm.prank(ORACLE_QUOTER_ADMIN);
        makinaKernel.setChainlinkOracle(address(accountingFeed), ORACLE_STALENESS_THRESHOLD_SECONDS, false);
        vm.prank(ORACLE_QUOTER_ADMIN);
        makinaKernel.setConversionRate(0, false);
        assertEq(makinaKernel.getStoredConversionRateWAD(), 0, "clearing against a re-attached feed must restore the sentinel");
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 1e18, "the re-attached feed must price the second hop again");
    }

    // =============================
    // The composed two-hop rate (machine share price x Chainlink feed price)
    // =============================

    /**
     * @notice The composed rate is floor(machine share price x feed price scaled to WAD / 1e18) across three decimal
     *         shapes and two feed decimal configurations, both tranches price through it, the inverse round-trips,
     *         and each hop reprices with NO admin action
     * @dev The quoter feeds convertToAssets exactly 10^(18 + trancheDecimals - accountingDecimals) share-wei so the
     *      machine's answer is the WAD-scaled share price regardless of either token's decimals, then multiplies by
     *      the feed price scaled to WAD via floor(answer x 1e18 / 10^feedDecimals). BOTH hops are live reads: machine
     *      yield and feed repricing each move the composed rate with no setter call, the stored rate stays at the
     *      sentinel throughout. Every expected value below is composed by hand from the two hops
     */
    function test_MakinaTwoHopRate_ComposesMachineSharePriceWithChainlinkRate() public {
        // ---- Shape 1: 18-decimal shares over a 6-decimal accounting token, 8-decimal feed (share price 1.5, feed 0.8) ----
        // convertToAssets input is 10^(18+18-6) = 1e30 share-wei, the answer is the WAD share price 1.5e18.
        // Feed hop: floor(0.8e8 x 1e18 / 1e8) = 0.8e18. Composed: floor(1.5e18 x 0.8e18 / 1e18) = 1.2e18 NAV per whole share
        _deployMakinaChainlinkMarket(18, 6, 1.5e18, 8, 0.8e8, defaultParams(), 0);
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 1.2e18, "shape 1: the composed rate must be 1.5 x 0.8 = 1.2");
        // One whole 18-decimal share is 1e18 tranche-wei: 1e18 x 1.2e18 / 1e18 = 1.2e18 NAV through the one collateral converter both tranches share
        assertEq(toUint256(makinaKernel.convertCollateralAssetsToValue(toTrancheUnits(1e18))), 1.2e18, "shape 1: one whole share must quote 1.2 NAV");
        // 1 share-wei: floor(1 x 1.2e18 / 1e18) = 1 NAV-wei, the fractional 0.2 floors away
        assertEq(toUint256(makinaKernel.convertCollateralAssetsToValue(toTrancheUnits(1))), 1, "shape 1: a 1-wei quote must floor 1.2 down to 1 NAV-wei");
        // The inverse divides by the same composed rate: 1.2e18 NAV x 1e18 / 1.2e18 = 1e18 share-wei, an exact round-trip
        assertEq(
            toUint256(makinaKernel.convertValueToCollateralAssets(toNAVUnits(uint256(1.2e18)))), 1e18, "shape 1: NAV -> share must invert the composed rate"
        );

        // Machine yield reprices with NO admin action, the live first hop: share price 1.5 -> 2.0 moves the composed
        // rate to floor(2e18 x 0.8e18 / 1e18) = 1.6e18, while the stored rate stays at the sentinel
        machine.setSharePriceWAD(2e18);
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 1.6e18, "shape 1: machine yield must reprice the composed rate to 2.0 x 0.8 = 1.6");
        assertEq(toUint256(makinaKernel.convertCollateralAssetsToValue(toTrancheUnits(1e18))), 1.6e18, "shape 1: quotes must track the live machine hop");
        assertEq(makinaKernel.getStoredConversionRateWAD(), 0, "shape 1: the stored rate must remain the sentinel through machine yield");

        // The FEED reprices with NO admin action either, the live second hop (setAnswer never touches freshness):
        // answer 0.8e8 -> 1.5e8 composes to floor(2e18 x 1.5e18 / 1e18) = 3e18
        accountingFeed.setAnswer(1.5e8);
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 3e18, "shape 1: a feed move must reprice the composed rate to 2.0 x 1.5 = 3.0");
        assertEq(toUint256(makinaKernel.convertCollateralAssetsToValue(toTrancheUnits(1e18))), 3e18, "shape 1: quotes must track the live feed hop");
        assertEq(makinaKernel.getStoredConversionRateWAD(), 0, "shape 1: the stored rate must remain the sentinel through feed moves");

        // ---- Shape 2: 18-decimal shares over an 18-decimal accounting token, 18-decimal feed (share price 1e18 + 1, feed 0.5) ----
        // convertToAssets input is 10^(18+18-18) = 1e18 share-wei (one whole share), the answer is 1e18 + 1.
        // Feed hop: floor(0.5e18 x 1e18 / 1e18) = 0.5e18, an 18-decimal feed passes through the WAD scaling exactly.
        // Composed: floor((1e18 + 1) x 5e17 / 1e18) = floor(5e17 + 0.5) = 5e17, the half-wei contribution of the
        // machine's 1-wei-above-peg share price floors away
        _deployMakinaChainlinkMarket(18, 18, 1e18 + 1, 18, 0.5e18, defaultParams(), 0);
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 5e17, "shape 2: the 1-wei share-price excess must floor out of the composed rate");
        // One whole share: 1e18 x 5e17 / 1e18 = 5e17 NAV
        assertEq(toUint256(makinaKernel.convertCollateralAssetsToValue(toTrancheUnits(1e18))), 5e17, "shape 2: one whole share must quote 0.5 NAV");
        // The inverse: 5e17 NAV x 1e18 / 5e17 = 1e18 share-wei, an exact round-trip
        assertEq(toUint256(makinaKernel.convertValueToCollateralAssets(toNAVUnits(uint256(5e17)))), 1e18, "shape 2: NAV -> share must invert the composed rate");

        // Feed hop reprice on the 18-decimal feed: answer -> 2e18 composes to floor((1e18 + 1) x 2e18 / 1e18) =
        // 2e18 + 2, the machine's 1-wei excess now survives the floor because 2.0 doubles it into whole wei
        accountingFeed.setAnswer(2e18);
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 2e18 + 2, "shape 2: the feed move must reprice the composed rate to (1e18 + 1) x 2.0");
        assertEq(toUint256(makinaKernel.convertCollateralAssetsToValue(toTrancheUnits(1e18))), 2e18 + 2, "shape 2: quotes must carry the doubled 1-wei excess");

        // ---- Shape 3: 6-decimal shares over an 18-decimal accounting token, 8-decimal feed (share price 2.5, feed 2.0) ----
        // convertToAssets input is 10^(18+6-18) = 1e6 share-wei (one whole share), the answer is the WAD share
        // price 2.5e18. Feed hop: floor(2e8 x 1e18 / 1e8) = 2e18. Composed: floor(2.5e18 x 2e18 / 1e18) = 5e18
        _deployMakinaChainlinkMarket(6, 18, 2.5e18, 8, 2e8, defaultParams(), 0);
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 5e18, "shape 3: the composed rate must be 2.5 x 2.0 = 5.0");
        // One whole 6-decimal share is 1e6 tranche-wei: 1e6 x 5e18 / 1e6 = 5e18 NAV
        assertEq(toUint256(makinaKernel.convertCollateralAssetsToValue(toTrancheUnits(1e6))), 5e18, "shape 3: one whole 6-dec share must quote 5.0 NAV");
        // 1 share-wei is a millionth of a whole share: 1 x 5e18 / 1e6 = 5e12 NAV-wei exactly (no flooring loss)
        assertEq(
            toUint256(makinaKernel.convertCollateralAssetsToValue(toTrancheUnits(1))),
            5e12,
            "shape 3: a 1-wei quote must scale by the 6-dec tranche unit exactly"
        );
        // The inverse: 5e18 NAV x 1e6 / 5e18 = 1e6 share-wei, an exact round-trip
        assertEq(toUint256(makinaKernel.convertValueToCollateralAssets(toNAVUnits(uint256(5e18)))), 1e6, "shape 3: NAV -> share must invert the composed rate");

        // Machine yield reprice: share price -> 3.0 composes to floor(3e18 x 2e18 / 1e18) = 6e18, no admin action
        machine.setSharePriceWAD(3e18);
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 6e18, "shape 3: machine yield must reprice the composed rate to 3.0 x 2.0 = 6.0");
    }

    /**
     * @notice A feed ABOVE 18 decimals whose answer does not divide evenly has the WAD-normalization remainder
     *         floored away, so the composed rate rounds down and never overstates a mark
     * @dev Every feed the other tests wire sits at or below 18 decimals, where 10^feedDecimals divides 1e18 exactly
     *      and the normalization floor(answer x 1e18 / 10^feedDecimals) is lossless in either rounding direction.
     *      Only a feed above WAD precision makes the divisor exceed 1e18 and the floor genuinely truncate, so only
     *      this shape pins the rounding DIRECTION of the normalization. The quoter must round its own pricing seam
     *      down because a ceil here would overstate the tranche mark by a wei on every quote, the compounding
     *      direction that favors redeemers against the market
     */
    function test_FeedAbove18Decimals_FloorsTheNormalizationRemainderOutOfTheComposedRate() public {
        // A 21-decimal feed at 2.5 plus one raw feed-wei, machine share price 1.0. The +1 is worth 1e-21 of the
        // asset, far below WAD resolution, so a correct floor must erase it entirely
        _deployMakinaChainlinkMarket(18, 18, 1e18, 21, 2.5e21 + 1, defaultParams(), 0);

        // Feed hop: floor((2.5e21 + 1) x 1e18 / 1e21) = floor(2.5e18 + 0.001) = 2.5e18 exactly, a ceil would
        // produce 2.5e18 + 1. Composed: floor(1e18 x 2.5e18 / 1e18) = 2.5e18
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 2.5e18, "the sub-WAD feed remainder must floor out of the composed rate");
        // One whole share: 1e18 x 2.5e18 / 1e18 = 2.5e18 NAV
        assertEq(toUint256(makinaKernel.convertCollateralAssetsToValue(toTrancheUnits(1e18))), 2.5e18, "one whole share must quote off the floored rate");
        // The inverse: 2.5e18 NAV x 1e18 / 2.5e18 = 1e18 share-wei, an exact round-trip off the floored rate
        assertEq(
            toUint256(makinaKernel.convertValueToCollateralAssets(toNAVUnits(uint256(2.5e18)))), 1e18, "NAV -> share must invert the floored composed rate"
        );
    }

    // =============================
    // Override precedence (a stored nonzero rate wins over the feed, zero restores the feed path)
    // =============================

    /**
     * @notice A stored nonzero rate overrides the feed: feed moves stop repricing, a stale or zeroed or reverting
     *         feed cannot block pricing, and setConversionRate(0) restores the feed path and its gates
     * @dev The override short-circuits _queryChainlinkOracle entirely, which is exactly its economic purpose: if the
     *      accounting-asset feed dies, the admin pins the second hop so deposits, redemptions, and syncs keep
     *      running off a governed rate instead of the whole market bricking on STALE_PRICE. The gates MUST resume
     *      biting after the override clears, otherwise a forgotten cleanup would leave the market silently trusting
     *      a dead feed
     */
    function test_StoredOverride_WinsOverFeedAndSurvivesFeedFailureUntilCleared() public {
        // Baseline is Chainlink-primary: machine 1.0 x feed 1.0 = 1e18
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 1e18, "the baseline must price through the feed");

        // Store the override: composed becomes machine 1.0 x stored 2.0 = 2e18, and the setter emits
        vm.expectEmit(address(makinaKernel));
        emit IdenticalAssets_ST_JT_Oracle_Quoter.ConversionRateUpdated(2e18);
        vm.prank(ORACLE_QUOTER_ADMIN);
        makinaKernel.setConversionRate(2e18, false);
        assertEq(makinaKernel.getStoredConversionRateWAD(), 2e18, "the override must land in quoter storage");
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 2e18, "the composed rate must be machine 1.0 x stored 2.0");

        // A feed answer move must NOT reprice while overridden: with the feed at 5.0 the composed rate stays 2e18
        accountingFeed.setAnswer(5e8);
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 2e18, "a feed move must not reprice through a stored override");

        // A STALE feed must not block pricing while overridden (the override never calls _queryChainlinkOracle)
        vm.warp(block.timestamp + ORACLE_STALENESS_THRESHOLD_SECONDS + 1);
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 2e18, "a stale feed must not block an overridden rate");
        assertEq(
            toUint256(makinaKernel.convertCollateralAssetsToValue(toTrancheUnits(1e18))), 2e18, "forward quotes must run off the override through a stale feed"
        );
        assertEq(
            toUint256(makinaKernel.convertValueToCollateralAssets(toNAVUnits(uint256(2e18)))),
            1e18,
            "inverse quotes must run off the override through a stale feed"
        );

        // A ZEROED feed answer must not block pricing while overridden
        accountingFeed.setAnswer(0);
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 2e18, "a zeroed feed must not block an overridden rate");

        // A REVERTING feed must not block pricing while overridden
        accountingFeed.setRevertMode(true);
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 2e18, "a reverting feed must not block an overridden rate");
        assertEq(
            toUint256(makinaKernel.convertCollateralAssetsToValue(toTrancheUnits(1e18))),
            2e18,
            "forward quotes must run off the override through a reverting feed"
        );

        // Restore the feed to healthy at 5.0, then clear the override: the feed path resumes at machine 1.0 x 5.0
        accountingFeed.setRevertMode(false);
        accountingFeed.setAnswer(5e8);
        accountingFeed.setUpdatedAt(block.timestamp);
        vm.prank(ORACLE_QUOTER_ADMIN);
        makinaKernel.setConversionRate(0, false);
        assertEq(makinaKernel.getStoredConversionRateWAD(), 0, "clearing the override must restore the sentinel");
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 5e18, "the cleared quoter must price through the feed at 1.0 x 5.0");

        // The gates resume with the override cleared: a stale feed bites again
        vm.warp(block.timestamp + ORACLE_STALENESS_THRESHOLD_SECONDS + 1);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.STALE_PRICE.selector);
        makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD();
    }

    /**
     * @notice The setter's own internal accounting sync goes through the composed rate: storing an override through
     *         a dead feed requires syncBeforeUpdate=false, and CLEARING the override through a dead feed reverts
     * @dev setConversionRate always re-caches the composed rate after the store. With a nonzero value just stored
     *      the re-cache short-circuits the feed, so the override can be installed while the feed is already dead
     *      (its rescue purpose) as long as the PRE-set sync is skipped. Clearing back to the sentinel makes the
     *      re-cache query the dead feed and revert, which is the safe failure mode: the admin cannot hand pricing
     *      back to a feed that cannot price, so a market can never be left quoting off a dead oracle
     */
    function test_OverrideLifecycleThroughADeadFeed_InstallsWithoutPreSyncAndRefusesToClear() public {
        // Kill the feed by staleness with the quoter still Chainlink-primary
        vm.warp(block.timestamp + ORACLE_STALENESS_THRESHOLD_SECONDS + 1);

        // Installing the override WITH a pre-set sync reverts: the pre-sync caches through the still-sentinel rate
        vm.prank(ORACLE_QUOTER_ADMIN);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.STALE_PRICE.selector);
        makinaKernel.setConversionRate(2e18, true);
        assertEq(makinaKernel.getStoredConversionRateWAD(), 0, "the reverted install must leave the sentinel in place");

        // Installing WITHOUT the pre-set sync succeeds: the post-set re-cache reads the just-stored override
        vm.prank(ORACLE_QUOTER_ADMIN);
        makinaKernel.setConversionRate(2e18, false);
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 2e18, "the rescue override must price through the dead feed");

        // Clearing while the feed is still dead reverts in the post-set re-cache, storage rolls back to the override
        vm.prank(ORACLE_QUOTER_ADMIN);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.STALE_PRICE.selector);
        makinaKernel.setConversionRate(0, false);
        assertEq(makinaKernel.getStoredConversionRateWAD(), 2e18, "the reverted clear must leave the override in place");

        // Once the feed is healthy again the clear lands and the feed path resumes at machine 1.0 x feed 1.0
        accountingFeed.setUpdatedAt(block.timestamp);
        vm.prank(ORACLE_QUOTER_ADMIN);
        makinaKernel.setConversionRate(0, false);
        assertEq(makinaKernel.getStoredConversionRateWAD(), 0, "the clear must land once the feed is healthy");
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 1e18, "the restored feed path must price at 1.0 x 1.0");
    }

    // =============================
    // Chainlink gates through the composed path (no override stored)
    // =============================

    /**
     * @notice With no override stored, the staleness, validity, and completeness gates all bite through the composed
     *         rate and both conversion directions
     * @dev The feed is the second hop of every quote, so a gate that stopped biting would let a dead or broken feed
     *      silently mark every senior and junior NAV. Each gate is driven independently through the mock's knobs
     *      (setAnswer never refreshes updatedAt, so price and freshness are separate levers) and the quoter must
     *      surface the typed error on the rate read, the forward quote, and the inverse quote alike
     */
    function test_ChainlinkGates_StaleInvalidAndIncompleteBiteThroughTheComposedPath() public {
        // At exactly the staleness threshold the answer still prices: machine 1.0 x feed 1.0 = 1e18
        vm.warp(block.timestamp + ORACLE_STALENESS_THRESHOLD_SECONDS);
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 1e18, "an answer aged exactly the threshold must still price");

        // One second past the threshold STALE_PRICE bites on the rate read and both conversion directions
        vm.warp(block.timestamp + 1);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.STALE_PRICE.selector);
        makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD();
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.STALE_PRICE.selector);
        makinaKernel.convertCollateralAssetsToValue(toTrancheUnits(1e18));
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.STALE_PRICE.selector);
        makinaKernel.convertValueToCollateralAssets(toNAVUnits(uint256(1e18)));

        // A fresh but ZERO answer is a broken feed, not a price of zero: INVALID_PRICE on the rate read, the
        // depositor-facing forward quote, and the redeemer-facing inverse quote alike
        accountingFeed.setUpdatedAt(block.timestamp);
        accountingFeed.setAnswer(0);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.INVALID_PRICE.selector);
        makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD();
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.INVALID_PRICE.selector);
        makinaKernel.convertCollateralAssetsToValue(toTrancheUnits(1e18));
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.INVALID_PRICE.selector);
        makinaKernel.convertValueToCollateralAssets(toNAVUnits(uint256(1e18)));

        // A NEGATIVE answer is equally broken: INVALID_PRICE on both conversion directions
        accountingFeed.setAnswer(-1);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.INVALID_PRICE.selector);
        makinaKernel.convertCollateralAssetsToValue(toTrancheUnits(1e18));
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.INVALID_PRICE.selector);
        makinaKernel.convertValueToCollateralAssets(toNAVUnits(uint256(1e18)));

        // A healthy answer computed in an OLDER round than the latest (answeredInRound < roundId): INCOMPLETE_PRICE
        // on the rate read and on both depositor-facing and redeemer-facing quotes
        accountingFeed.setAnswer(1e8);
        accountingFeed.setAnsweredInRound(0);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.INCOMPLETE_PRICE.selector);
        makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD();
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.INCOMPLETE_PRICE.selector);
        makinaKernel.convertCollateralAssetsToValue(toTrancheUnits(1e18));
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.INCOMPLETE_PRICE.selector);
        makinaKernel.convertValueToCollateralAssets(toNAVUnits(uint256(1e18)));

        // Restoring round completeness restores pricing at machine 1.0 x feed 1.0
        accountingFeed.setAnsweredInRound(1);
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 1e18, "a fully restored feed must price again");
    }

    /**
     * @notice With a sequencer uptime feed configured at init, the sequencer gates bite through the composed path:
     *         SEQUENCER_DOWN while down, GRACE_PERIOD_NOT_OVER when freshly restored and when startedAt reads the
     *         uninitialized 0, then a passing query strictly after the grace period elapses
     * @dev On an L2 a down sequencer means the feed's answer can be arbitrarily old the moment the sequencer
     *      returns, so quotes must stay blocked until a full grace period passes. The startedAt == 0 case pins the
     *      uninitialized-feed guard: a feed that has never posted a round must be treated as not-yet-trustworthy,
     *      not as up-since-genesis. The gate is strict (elapsed must EXCEED the grace period), pinned at the boundary
     */
    function test_SequencerGates_DownGracePeriodAndUninitializedBiteThenPassAfterGrace() public {
        // Redeploy the market with a sequencer uptime feed wired at kernel init: answer 0 (up), restored at deploy time
        MockAggregatorV3 seqFeed = new MockAggregatorV3(0, 0);
        _deployMakinaChainlinkMarket(18, 18, 1e18, 8, 1e8, defaultParams(), 0, address(seqFeed));

        // Freshly restored (startedAt == now, elapsed 0 is not > grace): GRACE_PERIOD_NOT_OVER blocks the composed
        // path on the rate read and on both the depositor-facing and redeemer-facing quote surfaces
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.GRACE_PERIOD_NOT_OVER.selector);
        makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD();
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.GRACE_PERIOD_NOT_OVER.selector);
        makinaKernel.convertCollateralAssetsToValue(toTrancheUnits(1e18));
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.GRACE_PERIOD_NOT_OVER.selector);
        makinaKernel.convertValueToCollateralAssets(toNAVUnits(uint256(1e18)));

        // The sequencer reporting DOWN (answer 1) bites before any grace-period reasoning, again on the rate read
        // and on both conversion directions
        seqFeed.setAnswer(1);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.SEQUENCER_DOWN.selector);
        makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD();
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.SEQUENCER_DOWN.selector);
        makinaKernel.convertCollateralAssetsToValue(toTrancheUnits(1e18));
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.SEQUENCER_DOWN.selector);
        makinaKernel.convertValueToCollateralAssets(toNAVUnits(uint256(1e18)));

        // An UNINITIALIZED uptime feed (startedAt == 0) must read as not-yet-trustworthy, never as up-since-genesis
        seqFeed.setAnswer(0);
        seqFeed.setStartedAt(0);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.GRACE_PERIOD_NOT_OVER.selector);
        makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD();

        // Restored at t, at EXACTLY t + grace the gate still bites (elapsed must strictly exceed the grace period)
        seqFeed.setStartedAt(block.timestamp);
        vm.warp(block.timestamp + ORACLE_GRACE_PERIOD_SECONDS);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.GRACE_PERIOD_NOT_OVER.selector);
        makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD();

        // One second later the grace period has fully elapsed and the composed rate prices: machine 1.0 x feed 1.0.
        // The 1 hour + 1 second of warping stays far inside the 1 day staleness threshold, so only the sequencer
        // gate was ever in play
        vm.warp(block.timestamp + 1);
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 1e18, "the composed rate must price once the grace period fully elapses");
        assertEq(toUint256(makinaKernel.convertCollateralAssetsToValue(toTrancheUnits(1e18))), 1e18, "quotes must price through the passed gate");
    }

    // =============================
    // The Chainlink admin surface
    // =============================

    /**
     * @notice setChainlinkOracle swaps the feed and reprices the composed rate, the configuration getter reflects
     *         every field, and an unprivileged caller is rejected before any state moves
     * @dev The feed is the second hop of every senior and junior mark, so swapping it is a full market repricing
     *      lever and must sit behind the oracle-quoter admin role. The swap must also fully detach the old feed:
     *      a poisoned old feed moving quotes after a swap would mean the quoter cached the wrong oracle handle
     */
    function test_SetChainlinkOracle_SwapsFeedAndRepricesAndGatesTheCaller() public {
        // The init-time configuration is fully reflected by the getter
        IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.IdenticalAssets_ST_JT_ChainlinkOracle_QuoterState memory cfg =
            makinaKernel.getChainlinkOracleConfiguration();
        assertEq(cfg.oracle, address(accountingFeed), "the init-time oracle must be in the configuration");
        assertEq(cfg.stalenessThresholdSeconds, ORACLE_STALENESS_THRESHOLD_SECONDS, "the init-time staleness threshold must be in the configuration");
        assertEq(cfg.sequencerUptimeFeed, address(0), "the sequencer check must be disabled at this deploy");
        assertEq(cfg.gracePeriodSeconds, ORACLE_GRACE_PERIOD_SECONDS, "the init-time grace period must be in the configuration");

        // An unprivileged caller cannot swap the feed, and the configuration is untouched by the attempt
        MockAggregatorV3 newFeed = new MockAggregatorV3(18, 3e18);
        address attacker = makeAddr("ATTACKER");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, attacker));
        makinaKernel.setChainlinkOracle(address(newFeed), 2 days, false);
        assertEq(makinaKernel.getChainlinkOracleConfiguration().oracle, address(accountingFeed), "the failed swap must leave the oracle unchanged");

        // The admin swaps to an 18-decimal feed at 3.0 with a 2 day threshold and the setter emits
        vm.expectEmit(address(makinaKernel));
        emit IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.ChainlinkOracleUpdated(address(newFeed), 2 days);
        vm.prank(ORACLE_QUOTER_ADMIN);
        makinaKernel.setChainlinkOracle(address(newFeed), 2 days, false);
        cfg = makinaKernel.getChainlinkOracleConfiguration();
        assertEq(cfg.oracle, address(newFeed), "the swapped oracle must be in the configuration");
        assertEq(cfg.stalenessThresholdSeconds, 2 days, "the swapped staleness threshold must be in the configuration");

        // The composed rate reprices through the new feed with NO other action: machine 1.0 x floor(3e18 x 1e18 / 1e18) = 3e18
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 3e18, "the swap must reprice the composed rate through the new feed");
        assertEq(toUint256(makinaKernel.convertCollateralAssetsToValue(toTrancheUnits(1e18))), 3e18, "quotes must track the new feed");

        // The old feed is fully detached: poisoning it must not move the composed rate
        accountingFeed.setAnswer(0);
        accountingFeed.setRevertMode(true);
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 3e18, "the old feed must have no residual influence after the swap");
    }

    /**
     * @notice setChainlinkOracle can rescue a market off a DEAD feed, but only with the pre-set sync skipped: the
     *         opted-in pre-sync prices through the dying feed and reverts, the skip lands the swap and the composed
     *         rate immediately prices through the new feed
     * @dev The syncBeforeUpdate flag is the escape hatch that makes the feed swap a genuine rescue lever: the
     *      pre-set sync caches the composed rate through the STILL-WIRED old oracle, so against a dead feed the
     *      opted-in shape can never land. Without the skip an admin whose feed died could only restore pricing by
     *      first storing a rate override, leaving the market quoting off a governed number while the healthy
     *      replacement feed sat unwired. The post-set sync then re-caches through the NEW feed, so the swap itself
     *      proves the replacement is alive before it takes over pricing
     */
    function test_SetChainlinkOracle_RescuesADeadFeedOnlyWhenThePreSyncIsSkipped() public {
        // Kill the wired feed by staleness and prove the market is genuinely bricked on it
        vm.warp(block.timestamp + ORACLE_STALENESS_THRESHOLD_SECONDS + 1);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.STALE_PRICE.selector);
        makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD();

        // The replacement feed is healthy: its constructor stamps the round at the post-warp timestamp
        MockAggregatorV3 newFeed = new MockAggregatorV3(8, 3e8);

        // Swapping WITH the pre-set sync reverts: the pre-sync still prices through the dead old feed
        vm.prank(ORACLE_QUOTER_ADMIN);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.STALE_PRICE.selector);
        makinaKernel.setChainlinkOracle(address(newFeed), ORACLE_STALENESS_THRESHOLD_SECONDS, true);
        assertEq(makinaKernel.getChainlinkOracleConfiguration().oracle, address(accountingFeed), "the reverted swap must leave the dead oracle wired");

        // Swapping WITHOUT the pre-set sync lands: only the post-set sync runs and it prices through the new feed
        vm.prank(ORACLE_QUOTER_ADMIN);
        makinaKernel.setChainlinkOracle(address(newFeed), ORACLE_STALENESS_THRESHOLD_SECONDS, false);
        assertEq(makinaKernel.getChainlinkOracleConfiguration().oracle, address(newFeed), "the rescue swap must wire the new oracle");

        // The composed rate immediately prices through the replacement: machine 1.0 x floor(3e8 x 1e18 / 1e8) = 3e18
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 3e18, "the rescued market must price through the new feed immediately");
        assertEq(toUint256(makinaKernel.convertCollateralAssetsToValue(toTrancheUnits(1e18))), 3e18, "quotes must run off the new feed after the rescue");
    }

    /**
     * @notice Setting a live oracle with a zero staleness threshold is rejected
     * @dev A zero threshold would make every answer stale the second after it lands (updatedAt + 0 >= now fails one
     *      second later), bricking the feed path in a way that looks like an oracle outage rather than a config
     *      error. The base setter only tolerates zero staleness alongside a NULL oracle (the admin-primary shape
     *      other compositions use), so a live oracle with zero staleness must fail loud at configuration
     */
    function test_RevertIf_SetChainlinkOracleWithZeroStalenessOnLiveOracle() public {
        vm.prank(ORACLE_QUOTER_ADMIN);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.INVALID_STALENESS_THRESHOLD_SECONDS.selector);
        makinaKernel.setChainlinkOracle(address(accountingFeed), 0, false);

        // The rejected set must not have clobbered the live configuration
        assertEq(
            makinaKernel.getChainlinkOracleConfiguration().stalenessThresholdSeconds,
            ORACLE_STALENESS_THRESHOLD_SECONDS,
            "the rejected zero threshold must leave the configuration unchanged"
        );
    }

    /**
     * @notice setSequencerUptimeFeed validates the grace period, reflects updates in the configuration, arms the
     *         sequencer gate on a live market, and disarms it when reset to null
     * @dev A live uptime feed with a zero grace period would trust the price the very second the sequencer returns,
     *      exactly the window where the answer is most likely to be a pre-outage relic, so the pairing is rejected.
     *      The null feed disables the check entirely (an L1 deployment), and flipping between the two through the
     *      setter must arm and disarm the gate on the very next quote
     */
    function test_SetSequencerUptimeFeed_ValidatesGracePeriodAndArmsAndDisarmsTheGate() public {
        // A live feed with a zero grace period is rejected outright
        MockAggregatorV3 seqFeed = new MockAggregatorV3(0, 0);
        vm.prank(ORACLE_QUOTER_ADMIN);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.INVALID_GRACE_PERIOD_SECONDS.selector);
        makinaKernel.setSequencerUptimeFeed(address(seqFeed), 0);

        // An unprivileged caller cannot touch the sequencer configuration at all
        address attacker = makeAddr("ATTACKER");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, attacker));
        makinaKernel.setSequencerUptimeFeed(address(seqFeed), 30 minutes);

        // The admin arms the gate: the feed was restored at deploy time (startedAt == now), so with a 30 minute
        // grace period the very next composed quote is blocked by GRACE_PERIOD_NOT_OVER
        vm.expectEmit(address(makinaKernel));
        emit IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.SequencerUptimeFeedUpdated(address(seqFeed), 30 minutes);
        vm.prank(ORACLE_QUOTER_ADMIN);
        makinaKernel.setSequencerUptimeFeed(address(seqFeed), 30 minutes);
        IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.IdenticalAssets_ST_JT_ChainlinkOracle_QuoterState memory cfg =
            makinaKernel.getChainlinkOracleConfiguration();
        assertEq(cfg.sequencerUptimeFeed, address(seqFeed), "the armed sequencer feed must be in the configuration");
        assertEq(cfg.gracePeriodSeconds, 30 minutes, "the armed grace period must be in the configuration");
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.GRACE_PERIOD_NOT_OVER.selector);
        makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD();

        // Resetting to the null feed disarms the check and the composed rate prices again: machine 1.0 x feed 1.0
        vm.prank(ORACLE_QUOTER_ADMIN);
        makinaKernel.setSequencerUptimeFeed(address(0), 0);
        assertEq(makinaKernel.getChainlinkOracleConfiguration().sequencerUptimeFeed, address(0), "the disarmed configuration must hold the null feed");
        assertEq(makinaKernel.getTrancheUnitToNAVUnitConversionRateWAD(), 1e18, "disarming the sequencer check must restore pricing");
    }

    // =============================
    // Access gates (unprivileged callers rejected before any state moves)
    // =============================

    /**
     * @notice An unprivileged caller can move NEITHER the conversion rate NOR the Chainlink oracle, and both failed
     *         attempts leave pricing untouched
     * @dev Each setter is a full market repricing lever: a hostile stored rate would remark every senior and junior
     *      NAV at the very next sync, and a hostile feed swap would do the same through an attacker-controlled
     *      oracle. Both must revert AccessManagedUnauthorized at the access manager, before any quoter logic runs
     */
    function test_RevertIf_UnprivilegedCallersTouchTheQuoterAdminSurface() public {
        address attacker = makeAddr("ATTACKER");

        // setConversionRate is rejected at the access manager and the sentinel survives
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, attacker));
        makinaKernel.setConversionRate(20e18, false);
        assertEq(makinaKernel.getStoredConversionRateWAD(), 0, "the stored rate must be untouched by the failed attempt");

        // setChainlinkOracle is rejected at the access manager and the wired feed survives
        MockAggregatorV3 hostileFeed = new MockAggregatorV3(8, 100e8);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, attacker));
        makinaKernel.setChainlinkOracle(address(hostileFeed), 1 days, false);
        assertEq(makinaKernel.getChainlinkOracleConfiguration().oracle, address(accountingFeed), "the wired oracle must be untouched by the failed attempt");

        // Pricing still runs off the legitimate feed path: machine 1.0 x feed 1.0 = 1e18 per whole share
        assertEq(toUint256(makinaKernel.convertCollateralAssetsToValue(toTrancheUnits(1e18))), 1e18, "pricing must still run off the legitimate configuration");
    }
}
