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
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel as ChainlinkKernel
} from "../../../src/kernels/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel.sol";
import {
    IdenticalERC4626Shares_ST_JT_SharePriceToAdminOracle_Quoter
} from "../../../src/kernels/base/quoter/identical-st-jt/IdenticalERC4626Shares_ST_JT_SharePriceToAdminOracle_Quoter.sol";
import {
    IdenticalAssets_ST_JT_AdminOracle_Quoter
} from "../../../src/kernels/base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_AdminOracle_Quoter.sol";
import { IdenticalAssets_ST_JT_Oracle_Quoter } from "../../../src/kernels/base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_Oracle_Quoter.sol";
import { BalancerV3_LT_BPTOracle_Quoter } from "../../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_BPTOracle_Quoter.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoJuniorTranche } from "../../../src/tranches/RoycoJuniorTranche.sol";
import { RoycoLiquidityTranche } from "../../../src/tranches/RoycoLiquidityTranche.sol";
import { RoycoSeniorTranche } from "../../../src/tranches/RoycoSeniorTranche.sol";
import {
    Identical_ERC4626_ST_JT_SharePriceToAdminOracle_BalancerV3_BPTOracle_LT_Kernel as AdminRateKernel
} from "../../mocks/Identical_ERC4626_ST_JT_SharePriceToAdminOracle_BalancerV3_BPTOracle_LT_Kernel.sol";
import { MockBPT } from "../../mocks/MockBPT.sol";
import { MockBPTOracle } from "../../mocks/MockBPTOracle.sol";
import { MockBalancerVault } from "../../mocks/MockBalancerVault.sol";
import { MockERC4626C } from "../../mocks/MockERC4626C.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { FixtureCell, MarketParamsConfig, TokenConfig } from "../../utils/FixtureTypes.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { _plainToken, _vaultToken, cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title AdminRateMarketTestBase
 * @notice Deploys a full Day market around the ERC4626-share-price-to-admin-oracle kernel composition: the tranche
 *         unit is an ERC4626 vault share whose base-asset value comes from convertToAssets (a live hop) and whose
 *         base-asset-to-NAV-unit rate is a stored admin value (a static hop, no external feed at all)
 * @dev Mirrors DayMarketTestBase._deployMarket step for step, reusing every base helper, and swaps only the kernel:
 *      the composition ships abstract in src with no concrete kernel wiring it, so the test-only concrete kernel in
 *      test/mocks exercises it end to end. The market stays unseeded in every test, conversion rates are independent
 *      of tranche NAVs and the setter's internal accounting syncs pass trivially at zero NAVs
 */
abstract contract AdminRateMarketTestBase is DayMarketTestBase {
    /// @notice The deployed market's kernel proxy, typed to the admin-rate composition under test
    AdminRateKernel internal adminKernel;

    /// @notice The kernel implementation, kept so tests can attempt fresh proxy initializations against it
    AdminRateKernel internal adminKernelImpl;

    /**
     * @notice Deploys the full Day market with the admin-rate kernel composition
     * @param _shape The token shape to deploy
     * @param _params The market parameterization to deploy
     * @param _initialConversionRateWAD The base-asset-to-NAV-unit rate the kernel is initialized with
     */
    function _deployAdminRateMarket(FixtureCell memory _shape, MarketParamsConfig memory _params, uint256 _initialConversionRateWAD) internal {
        require(_params.jtCoinvested, "AdminRateMarketTestBase: kernel family forces jtCoinvested=true");
        _validateFixtureCell(_shape);
        cell = _shape;
        params = _params;

        // Access manager, admin'd by this fixture so role wiring needs no schedule/execute dance
        accessManager = new AccessManager(address(this));

        // Tokens: quote stable + ONE ERC4626 vault share over a mock underlying for both ST and JT (the quoter
        // family requires ST_ASSET == JT_ASSET). No Chainlink feed exists anywhere in this composition
        quoteToken = _deployERC20("Quote Stable", "QUOTE", _shape.quoteAsset);
        stJtUnderlying = _deployERC20("ST/JT Underlying", "UNDR", _toUnderlyingConfig(_shape.stAsset));
        stJtVault = new MockERC4626C(address(stJtUnderlying), "ST/JT Vault Share", "vSHARE", _shape.stAsset.decimals);
        stJtVault.setRate(_shape.stAsset.initialRateWAD);
        vm.label(address(stJtVault), "MockERC4626C_STJT");

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

        RoycoSeniorTranche stImpl = new RoycoSeniorTranche(address(stJtVault), predictedKernel);
        RoycoJuniorTranche jtImpl = new RoycoJuniorTranche(address(stJtVault), predictedKernel);
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
        adminKernelImpl = new AdminRateKernel(
            IRoycoDayKernel.RoycoDayKernelConstructionParams({
                seniorTranche: address(seniorTranche),
                stAsset: address(stJtVault),
                juniorTranche: address(juniorTranche),
                jtAsset: address(stJtVault),
                accountant: address(accountant),
                liquidityTranche: address(liquidityTranche),
                ltAsset: address(bpt),
                enforceVaultSharesTransferWhitelist: _params.enforceWhitelistOnTransfer
            })
        );

        PROTOCOL_FEE_RECIPIENT = makeAddr("PROTOCOL_FEE_RECIPIENT");

        // Kernel proxy from the dedicated deployer so it lands at the predicted address
        vm.prank(kernelProxyDeployer);
        address kernelProxy = address(new ERC1967Proxy(address(adminKernelImpl), _kernelInitData(_initialConversionRateWAD)));
        require(kernelProxy == predictedKernel, "AdminRateMarketTestBase: kernel proxy address prediction failed");
        adminKernel = AdminRateKernel(kernelProxy);
        vm.label(kernelProxy, "AdminRateKernel");

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

    /// @notice Builds the kernel proxy initialization calldata for the specified initial admin conversion rate
    /// @param _initialConversionRateWAD The base-asset-to-NAV-unit rate to initialize the ST/JT quoter with
    function _kernelInitData(uint256 _initialConversionRateWAD) internal view returns (bytes memory) {
        return abi.encodeCall(
            adminKernelImpl.initialize,
            (
                IRoycoDayKernel.RoycoDayKernelInitParams({
                    initialAuthority: address(accessManager),
                    protocolFeeRecipient: PROTOCOL_FEE_RECIPIENT,
                    stSelfLiquidationBonusWAD: params.stSelfLiquidationBonusWAD,
                    roycoBlacklist: address(0)
                }),
                AdminRateKernel.KernelSpecificInitParams({
                    stAndJTQuoterParams: IdenticalERC4626Shares_ST_JT_SharePriceToAdminOracle_Quoter.ST_JT_QuoterSpecificParams({
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
 * @title Test_SharePriceTimesAdminRate_ERC4626ToAdminOracleQuoter
 * @notice The ERC4626-share-price-to-admin-oracle composition's full pricing and admin surface on the baseline
 *         18-decimal-share shape: the composed two-hop rate (convertToAssets x stored admin rate), the live-vs-static
 *         hop split, the zero-rate guards at initialization and at the setter, and the setter's access control
 * @dev The composition has NO oracle fallback: the stored admin rate is the only base-asset price source, and the
 *      sentinel value (0) would route pricing into a hard revert, so both zero-rate guards are fail-loud-at-config
 */
contract Test_SharePriceTimesAdminRate_ERC4626ToAdminOracleQuoter is AdminRateMarketTestBase {
    /// @dev 18-decimal shares over an 18-decimal underlying at a 1.0 vault rate, admin rate initialized to 2.0
    function setUp() public {
        _deployAdminRateMarket(cellA(), defaultParams(), 2e18);
    }

    // =============================
    // Zero-rate guards (fail loud at configuration, never at pricing time)
    // =============================

    /**
     * @notice Initializing the kernel with a zero conversion rate is rejected outright
     * @dev In this composition the stored admin rate is the ONLY base-asset-to-NAV price source: the sentinel (0)
     *      means "query the oracle", and the admin quoter's oracle hook is a hard revert (MUST_USE_ADMIN_ORACLE_INPUT).
     *      Accepting 0 at initialization would deploy a market whose every quote reverts, so the config must fail loud
     */
    function test_RevertIf_InitializedWithZeroConversionRate() public {
        // A fresh proxy over the already-constructed impl re-runs initialize with rate 0 against the same market wiring
        bytes memory initData = _kernelInitData(0);
        vm.expectRevert(IdenticalAssets_ST_JT_AdminOracle_Quoter.INVALID_CONVERSION_RATE.selector);
        new ERC1967Proxy(address(adminKernelImpl), initData);
    }

    /**
     * @notice The admin setter rejects the zero rate and leaves the stored rate untouched, while a nonzero rate lands
     * @dev The concrete kernel's setConversionRate override chain must terminate in the ADMIN quoter's guarded setter:
     *      had it delegated to the base oracle quoter instead, 0 would be silently stored as the sentinel and every
     *      subsequent quote would revert at pricing time (fail-at-use) instead of at configuration (fail-loud)
     */
    function test_RevertIf_ConversionRateSetToZero() public {
        vm.prank(ORACLE_QUOTER_ADMIN);
        vm.expectRevert(IdenticalAssets_ST_JT_AdminOracle_Quoter.INVALID_CONVERSION_RATE.selector);
        adminKernel.setConversionRate(0, false);

        // The rejected zero must not have clobbered the initialization-time 2.0 rate
        assertEq(adminKernel.getStoredConversionRateWAD(), 2e18, "the stored rate must be untouched by the rejected zero");
        // Pricing still works off the surviving rate: 1e18 units x (vault 1.0 x admin 2.0) = 2e18 NAV
        assertEq(toUint256(adminKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 2e18, "pricing must still run off the surviving stored rate");

        // Contrast: the same setter accepts any NONZERO rate, pinning that the guard rejects the value, not the caller
        vm.expectEmit(address(adminKernel));
        emit IdenticalAssets_ST_JT_Oracle_Quoter.ConversionRateUpdated(3e18);
        vm.prank(ORACLE_QUOTER_ADMIN);
        adminKernel.setConversionRate(3e18, false);
        assertEq(adminKernel.getStoredConversionRateWAD(), 3e18, "a nonzero rate must land in quoter storage");
    }

    // =============================
    // The composed two-hop rate
    // =============================

    /**
     * @notice One whole share quotes at exactly (vault rate x admin rate) on both tranches, and the inverse round-trips
     * @dev Hop 1 (live): convertToAssets(1e18 share-wei) at a 1.2 vault rate = 1.2e18 base-asset value in WAD.
     *      Hop 2 (static): x stored admin rate 2e18 / 1e18 = 2.4e18 NAV per whole share.
     *      One whole 18-decimal share is 1e18 tranche-unit wei: 1e18 x 2.4e18 / 1e18 = 2.4e18 NAV
     */
    function test_TrancheUnitPricing_SharePriceTimesAdminRate() public {
        stJtVault.setRate(1.2e18);

        assertEq(toUint256(adminKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 2.4e18, "one whole share must quote vault 1.2 x admin 2.0 = 2.4 NAV");
        assertEq(toUint256(adminKernel.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 2.4e18, "the junior side prices through the identical composed rate");

        // 1 share-wei floors: 1 x 2.4e18 / 1e18 = 2.4, floored to 2 NAV-wei
        assertEq(toUint256(adminKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1))), 2, "a 1-wei quote must floor 2.4 down to 2 NAV-wei");

        // The inverse divides by the same composed rate: 2.4e18 NAV x 1e18 / 2.4e18 = 1e18 share-wei, an exact round-trip
        assertEq(toUint256(adminKernel.stConvertNAVUnitsToTrancheUnits(toNAVUnits(uint256(2.4e18)))), 1e18, "NAV -> share must invert the composed rate exactly");
        assertEq(toUint256(adminKernel.jtConvertNAVUnitsToTrancheUnits(toNAVUnits(uint256(2.4e18)))), 1e18, "the junior inverse shares the identical composed rate");
    }

    /**
     * @notice Vault appreciation reprices every quote with NO admin action, the reason this composition exists
     * @dev The share-price hop is read live from convertToAssets on every quote while the admin hop is a static
     *      stored value, so yield accrual flows into NAV marks without any setter call: at admin rate 2.0, moving
     *      the vault rate 1.0 -> 1.1 must move a whole-share quote from 1e18 x 2.0 = 2e18 to 1.1e18 x 2.0 = 2.2e18
     */
    function test_VaultAppreciationRepricesWithoutAdminAction() public {
        // Deployment state: vault rate 1.0, admin rate 2.0 -> 1e18 x 2e18 / 1e18 = 2e18 NAV per whole share
        assertEq(toUint256(adminKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 2e18, "the pre-accrual quote must be vault 1.0 x admin 2.0");

        // The vault appreciates 10%: ONLY the ERC4626 rate moves, no kernel setter is touched
        stJtVault.setRate(1.1e18);

        assertEq(toUint256(adminKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 2.2e18, "the quote must track the live vault rate with no setter call");
        assertEq(toUint256(adminKernel.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 2.2e18, "the junior side must reprice identically");
        // The static hop really is static: the stored admin rate did not move
        assertEq(adminKernel.getStoredConversionRateWAD(), 2e18, "the stored admin rate must be untouched by vault accrual");
    }

    // =============================
    // Setter access control
    // =============================

    /**
     * @notice An unprivileged attacker cannot move the stored conversion rate, and the failed attempt leaves it untouched
     * @dev The stored rate is this composition's entire base-asset price source: an attacker-set 10x rate would
     *      remark every senior and junior NAV tenfold in the very next sync
     */
    function test_RevertIf_SetConversionRateCalledByNonAdmin() public {
        address attacker = makeAddr("ATTACKER");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, attacker));
        adminKernel.setConversionRate(20e18, false);

        assertEq(adminKernel.getStoredConversionRateWAD(), 2e18, "the stored rate must be untouched by the failed attempt");
        // And quotes still price off the initialization-time rate: 1e18 x (vault 1.0 x admin 2.0) = 2e18
        assertEq(toUint256(adminKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 2e18, "pricing must still run off the original rate");
    }
}

/**
 * @title Test_SharePriceTimesAdminRate_LowDecimalShares_ERC4626ToAdminOracleQuoter
 * @notice The same composed two-hop pricing on a decimal-skewed shape (6-decimal shares over an 18-decimal
 *         underlying), pinning that the quoter's convertToAssets input scale factor lands the composed rate in WAD
 * @dev The quoter feeds convertToAssets exactly 10^(18 + shareDecimals - baseAssetDecimals) share-wei so the result
 *      is WAD-scaled regardless of either token's decimals. Here that is 10^(18 + 6 - 18) = 1e6 share-wei (one whole
 *      share), whose base-asset value at an 18-decimal underlying is already WAD, any other input scale would skew
 *      the composed rate by powers of ten
 */
contract Test_SharePriceTimesAdminRate_LowDecimalShares_ERC4626ToAdminOracleQuoter is AdminRateMarketTestBase {
    /// @dev 6-decimal shares over an 18-decimal underlying at a 1.0 vault rate against a 6-decimal quote stable, admin rate initialized to 0.8
    function setUp() public {
        TokenConfig memory vaultShare = _vaultToken(6, 18);
        _deployAdminRateMarket(
            FixtureCell({ name: "AdminRateLowDecimalShares", stAsset: vaultShare, jtAsset: vaultShare, quoteAsset: _plainToken(6) }), defaultParams(), 0.8e18
        );
    }

    /**
     * @notice One whole 6-decimal share quotes at exactly (vault rate x admin rate) in WAD NAV, and the inverse round-trips
     * @dev Hop 1 (live): convertToAssets(10^(18+6-18) = 1e6 share-wei) at a 1.5 vault rate returns 1.5e18 underlying-wei,
     *      which at an 18-decimal underlying IS the WAD-scaled rate, the scale factor did the decimal reconciliation.
     *      Hop 2 (static): x admin 0.8e18 / 1e18 = 1.2e18 NAV per whole share.
     *      One whole 6-decimal share is 1e6 tranche-unit wei: 1e6 x 1.2e18 / 1e6 = 1.2e18 NAV
     */
    function test_TrancheUnitPricing_ScaleFactorLandsComposedRateInWAD() public {
        stJtVault.setRate(1.5e18);

        assertEq(
            toUint256(adminKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e6))), 1.2e18, "one whole 6-dec share must quote vault 1.5 x admin 0.8 = 1.2 NAV"
        );
        assertEq(toUint256(adminKernel.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e6))), 1.2e18, "the junior side prices through the identical composed rate");

        // 1 share-wei is a millionth of a whole share: 1 x 1.2e18 / 1e6 = 1.2e12 NAV-wei exactly (no flooring loss)
        assertEq(toUint256(adminKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1))), 1.2e12, "a 1-wei quote must scale by the 6-dec tranche unit exactly");

        // The inverse divides by the same composed rate: 1.2e18 NAV x 1e6 / 1.2e18 = 1e6 share-wei, an exact round-trip
        assertEq(toUint256(adminKernel.stConvertNAVUnitsToTrancheUnits(toNAVUnits(uint256(1.2e18)))), 1e6, "NAV -> share must invert the composed rate exactly");
    }
}
