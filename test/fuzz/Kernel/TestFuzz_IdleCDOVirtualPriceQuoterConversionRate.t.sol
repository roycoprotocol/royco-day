// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { Test } from "../../../lib/forge-std/src/Test.sol";
import { AccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { RoycoDayAccountant } from "../../../src/accountant/RoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import {
    Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_BalancerV3_BPTOracle_LT_Kernel as IdleCDOKernel
} from "../../../src/kernels/Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_BalancerV3_BPTOracle_LT_Kernel.sol";
import {
    IdenticalIdleCDOAATranches_ST_JT_VirtualPriceOracle_Quoter
} from "../../../src/kernels/base/quoter/identical-st-jt/IdenticalIdleCDOAATranches_ST_JT_VirtualPriceOracle_Quoter.sol";
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

/**
 * @title TestFuzz_IdleCDOVirtualPriceQuoterConversionRate_Kernel
 * @notice Fuzzes the Idle CDO AA tranche ST/JT quoter's one-hop rate (AA tranche token -> NAV via the CDO's
 *         virtualPrice lifted to WAD by the 10^(18 - underlyingDecimals) multiplier) across the full supported
 *         tranche and underlying decimal envelope, virtual price, and amount domains, plus the admin override
 *         that supersedes the virtual price entirely
 * @dev The quoter is the market's sole pricing seam: every deposit, redemption, coverage check, and sync marks
 *      tranche value through these conversions, so a rate error silently misprices every tranche. Unlike the
 *      Makina composition there is no second hop and no probe-amount coupling to the tranche decimals: the
 *      multiplier depends only on the underlying decimals and the rate seam is an exact checked multiplication
 *      with no floor. The forward conversion is pinned to an independently derived rate from the raw fuzz
 *      inputs (the senior and junior tranches share the ONE collateral converter, so identical pricing is
 *      structural rather than asserted), the NAV -> collateral -> NAV round trip is bounded by its input, and a
 *      stored nonzero override must be the ENTIRE rate regardless of the virtual price for every fuzzed CDO
 *      configuration
 */
contract TestFuzz_IdleCDOVirtualPriceQuoterConversionRate_Kernel is Test {
    /// @notice The authority every fuzz-deployed kernel is initialized with
    AccessManager internal accessManager;

    /// @dev The override arm drives the restricted setConversionRate directly, so the kernels' authority must genuinely
    ///      authorize this test contract: a fresh manager admin'd by the test leaves every target function on the default admin role, which the test holds
    function setUp() public {
        accessManager = new AccessManager(address(this));
    }

    /**
     * @notice Deploys an Idle-CDO-virtual-price-quoter kernel over freshly parameterized tokens and CDO, the
     *         smallest wiring the quoter's constructors and initializer accept
     * @dev The tranche and accountant implementations are consumed uninitialized: the kernel's constructor and
     *      initializer read only their immutables (asset addresses), the conversion
     *      surface under test is pure-view, and the override setter's internal accounting syncs pass trivially at
     *      zero NAVs, so no market state is ever needed
     * @param _trancheDecimals The AA tranche token's decimals (the ST and JT tranche unit)
     * @param _underlyingDecimals The CDO underlying token's decimals, which denominate the virtual price and set the WAD multiplier
     * @param _virtualPrice The CDO's virtual price, the value of one whole AA tranche token scaled to the underlying token's decimals
     * @param _initialConversionRateWAD The initial stored rate (0 is VALID here and means virtual-price-primary)
     * @return kernel The initialized kernel proxy exposing the quoter's conversion surface
     * @return cdo The deployed mock CDO, returned so tests can move its knobs after initialization
     */
    function _deployIdleCDOVirtualPriceKernel(
        uint8 _trancheDecimals,
        uint8 _underlyingDecimals,
        uint256 _virtualPrice,
        uint256 _initialConversionRateWAD
    )
        internal
        returns (IdleCDOKernel kernel, MockIdleCDO cdo)
    {
        // The AA tranche token is the market's ONE coinvested collateral asset shared by ST and JT
        MockERC20C aaTranche = new MockERC20C("AA Tranche", "AA_TRANCHE", _trancheDecimals);
        MockERC20C underlyingToken = new MockERC20C("CDO Underlying", "UNDER", _underlyingDecimals);
        // The CDO is the one-hop oracle: virtualPrice is the whole tranche-to-NAV rate in underlying decimals
        cdo = new MockIdleCDO(address(aaTranche), address(underlyingToken), _virtualPrice);
        MockERC20C quoteToken = new MockERC20C("Quote Stable", "QUOTE", 6);

        // Liquidity venue wiring: the LT quoter's constructor demands a registered two-token pool pairing the
        // senior tranche, and its initializer demands an oracle attesting to that exact pool
        MockBalancerVault balancerVault = new MockBalancerVault();
        MockBPT bpt = new MockBPT(IVault(address(balancerVault)), "Royco BPT", "rBPT");
        MockBPTOracle bptOracle = new MockBPTOracle(balancerVault, address(bpt));

        // Predict the kernel proxy address so the tranche implementations can bake it into their immutables
        address kernelProxyDeployer = makeAddr("KERNEL_PROXY_DEPLOYER");
        address predictedKernel = vm.computeCreateAddress(kernelProxyDeployer, vm.getNonce(kernelProxyDeployer));

        RoycoSeniorTranche seniorTranche = new RoycoSeniorTranche(address(aaTranche), predictedKernel);
        RoycoJuniorTranche juniorTranche = new RoycoJuniorTranche(address(aaTranche), predictedKernel);
        RoycoLiquidityTranche liquidityTranche = new RoycoLiquidityTranche(address(bpt), predictedKernel);
        RoycoDayAccountant accountant = new RoycoDayAccountant(predictedKernel);

        balancerVault.registerPool(address(bpt), [IERC20(address(seniorTranche)), IERC20(address(quoteToken))]);

        IdleCDOKernel impl = new IdleCDOKernel(
            IRoycoDayKernel.RoycoDayKernelConstructionParams({
                seniorTranche: address(seniorTranche),
                juniorTranche: address(juniorTranche),
                collateralAsset: address(aaTranche),
                accountant: address(accountant),
                liquidityTranche: address(liquidityTranche),
                ltAsset: address(bpt),
                enforceVaultSharesTransferWhitelist: false
            }),
            address(cdo)
        );
        bytes memory initData = abi.encodeCall(
            impl.initialize,
            (
                IRoycoDayKernel.RoycoDayKernelInitParams({
                    initialAuthority: address(accessManager),
                    protocolFeeRecipient: makeAddr("PROTOCOL_FEE_RECIPIENT"),
                    stSelfLiquidationBonusWAD: 0,
                    roycoBlacklist: address(0)
                }),
                IdleCDOKernel.KernelSpecificInitParams({
                    stAndJTQuoterParams: IdenticalIdleCDOAATranches_ST_JT_VirtualPriceOracle_Quoter.ST_JT_QuoterSpecificParams({
                        initialConversionRateWAD: _initialConversionRateWAD
                    }),
                    ltQuoterParams: BalancerV3_LT_BPTOracle_Quoter.LT_QuoterSpecificParams({ bptOracle: address(bptOracle), maxReinvestmentSlippageWAD: 0 })
                })
            )
        );
        vm.prank(kernelProxyDeployer);
        kernel = IdleCDOKernel(address(new ERC1967Proxy(address(impl), initData)));
        require(address(kernel) == predictedKernel, "kernel proxy address prediction failed");
    }

    /**
     * Scenario: an Idle-CDO-virtual-price-quoter kernel is deployed with a fuzzed virtual price and fuzzed
     * tranche/underlying decimals spanning the constructor's whole supported envelope (underlying capped at 18
     * where the 10^(18 - underlyingDecimals) multiplier bottoms out at one), initialized with the zero stored
     * rate so the rate is genuinely virtual-price-primary, then one amount is pushed through the tranche -> NAV
     * conversion and one value through the NAV -> tranche -> NAV round trip.
     *
     * Two properties are pinned, neither by re-running the quoter's own code (the old junior-equals-senior
     * conjunct is now structural: both tranches price through the single collateral converter, so divergent
     * per-tranche marks are unrepresentable):
     * (a) the rate and the forward conversion equal a derivation composed by hand from the raw fuzz inputs, and
     *     the rate itself is pinned EXACTLY because the one-hop seam is a lossless checked multiplication with
     *     no floor, unlike the Makina composition where the two-hop re-normalization floors, and
     * (b) the NAV -> collateral -> NAV round trip never exceeds its input (two floor divisions can only lose value,
     *     and a round trip that came back higher would let a redeem-redeposit loop print NAV out of rounding).
     */
    function testFuzz_IdleCDOVirtualPriceConversionRoundTrip_NeverExceedsInputAndMatchesOneHopDerivation(
        uint256 _trancheDecimalsSeed,
        uint256 _underlyingDecimalsSeed,
        uint256 _virtualPriceSeed,
        uint256 _amountSeed,
        uint256 _navSeed
    )
        public
    {
        // Decimal envelope: the root quoter supports any 10^(trancheDecimals) scale factor, so tranche decimals
        // span the degenerate 0-decimal token up to a 24-decimal token. Unlike Makina there is no probe-amount
        // coupling between the two decimal domains: the multiplier exponent 18 - underlyingDecimals depends only
        // on the underlying, so the underlying spans 0 to 18 independently, including the multiplier-of-one edge
        // at exactly 18 (above 18 the constructor's checked subtraction panics, out of envelope by design)
        uint8 trancheDecimals = uint8(bound(_trancheDecimalsSeed, 0, 24));
        uint8 underlyingDecimals = uint8(bound(_underlyingDecimalsSeed, 0, 18));
        // The virtual price is bounded so its WAD-lifted rate spans roughly 1e9 to 1e27 and is never zero. For
        // underlyingDecimals >= 9 the price 10^(underlyingDecimals - 9) lifts to exactly 1e9 WAD. Below 9 that
        // target sits under one raw underlying unit, so the lower bound clamps at 1 and the lifted floor rises
        // to one raw unit, 10^(18 - underlyingDecimals) WAD, still at least 1e9. Either way the rate is nonzero,
        // so the NAV -> tranche division cannot hit a zero denominator (a zero rate cannot price anything and is
        // not a conversion-math case)
        uint256 minVirtualPrice = underlyingDecimals > 9 ? 10 ** (uint256(underlyingDecimals) - 9) : 1;
        uint256 virtualPrice = bound(_virtualPriceSeed, minVirtualPrice, 10 ** (uint256(underlyingDecimals) + 9));
        // Amounts up to 1e30 wei cover a million whole units even at 24 decimals, and bound's edge bias hits 0 and the max
        uint256 amount = bound(_amountSeed, 0, 1e30);
        uint256 navValue = bound(_navSeed, 0, 1e30);

        // The zero initial rate is a SUPPORTED configuration in this composition: initialize skips the store and
        // the rate resolves through the CDO's virtualPrice on every quote
        (IdleCDOKernel kernel,) = _deployIdleCDOVirtualPriceKernel(trancheDecimals, underlyingDecimals, virtualPrice, 0);

        // Independent one-hop derivation from the raw fuzz inputs, in plain checked arithmetic (every intermediate
        // is bounded well under 2^256, so no 512-bit multiplication is needed and the src multiplication is not reused):
        //
        // The CDO returns the value of one WHOLE AA tranche token in underlying units scaled to the underlying
        // token's decimals, so the tranche decimals never enter the rate. The quoter lifts it to WAD with the
        // constructor-pinned multiplier:
        //   rateWAD = virtualPrice x 10^(18 - underlyingDecimals)
        // This is an EXACT checked multiplication, not a floored mulDiv, so the rate seam loses nothing for any
        // underlying decimals in the envelope. Largest intermediate is 10^(uD + 9) x 10^(18 - uD) = 1e27
        uint256 expectedRateWAD = virtualPrice * (10 ** (18 - uint256(underlyingDecimals)));

        // (a) Forward conversion: NAV = floor(amount x rateWAD / 10^trancheDecimals), the forward path's ONLY
        // floor. Largest intermediate is 1e30 x 1e27 = 1e57, comfortably below 2^256
        uint256 expectedNAV = (amount * expectedRateWAD) / (10 ** uint256(trancheDecimals));
        uint256 forwardNAV = toUint256(kernel.convertCollateralAssetsToValue(toTrancheUnits(amount)));
        assertEq(
            kernel.getTrancheUnitToNAVUnitConversionRateWAD(), expectedRateWAD, "the one-hop rate must be exactly virtualPrice x 10^(18 - underlyingDecimals)"
        );
        assertEq(forwardNAV, expectedNAV, "collateral -> NAV must equal the hand-derived one-hop floor derivation");

        // (b) Round trip: NAV -> collateral floors once, collateral -> NAV floors again, so the value coming back
        // can never exceed what went in. This is the no-closed-form bound: whatever the rate and decimals, a holder
        // converting a NAV claim to collateral units and marking it back must never come out ahead
        uint256 trancheUnitsOut = toUint256(kernel.convertValueToCollateralAssets(toNAVUnits(navValue)));
        uint256 navRoundTrip = toUint256(kernel.convertCollateralAssetsToValue(toTrancheUnits(trancheUnitsOut)));
        assertLe(navRoundTrip, navValue, "NAV -> collateral -> NAV must never exceed the original value");
    }

    /**
     * Scenario: an Idle-CDO-virtual-price-quoter kernel is deployed virtual-price-primary (zero stored rate)
     * over the same fuzzed domains, the authority-held test contract stores a fuzzed nonzero override through
     * the restricted setConversionRate, and then the CDO is zeroed and armed to revert outright.
     *
     * The override property pinned: a stored nonzero rate is the ENTIRE rate, not a hop composed against
     * anything live (contrast the Makina sibling where the override still multiplies against the machine's
     * share price). Before the store the rate must track the virtual price, after the store it must equal the
     * override EXACTLY regardless of the virtual price, and it must keep quoting through a CDO that would
     * revert outright if it were ever consulted, which proves _getConversionRateFromOracleWAD is never called
     * while the override is stored. Storing zero afterwards must RESTORE the virtual price path, since zero is
     * always the resume-the-CDO sentinel in this composition (the CDO immutable guarantees the live path
     * exists, so there is no oracle-presence gate that could reject it).
     */
    function testFuzz_IdleCDOAdminOverride_StoredRateSupersedesVirtualPriceAndZeroRestoresIt(
        uint256 _trancheDecimalsSeed,
        uint256 _underlyingDecimalsSeed,
        uint256 _virtualPriceSeed,
        uint256 _overrideRateSeed,
        uint256 _amountSeed
    )
        public
    {
        // Same decimal envelope and virtual price domain as the round-trip fuzz (see its bound justifications)
        uint8 trancheDecimals = uint8(bound(_trancheDecimalsSeed, 0, 24));
        uint8 underlyingDecimals = uint8(bound(_underlyingDecimalsSeed, 0, 18));
        uint256 minVirtualPrice = underlyingDecimals > 9 ? 10 ** (uint256(underlyingDecimals) - 9) : 1;
        uint256 virtualPrice = bound(_virtualPriceSeed, minVirtualPrice, 10 ** (uint256(underlyingDecimals) + 9));
        // The override spans 1e-9 to 1e9 and is strictly nonzero: zero is not an override in this composition,
        // it is the resume-the-CDO sentinel exercised at the end of this very test
        uint256 overrideRateWAD = bound(_overrideRateSeed, 1e9, 1e27);
        uint256 amount = bound(_amountSeed, 0, 1e30);

        (IdleCDOKernel kernel, MockIdleCDO cdo) = _deployIdleCDOVirtualPriceKernel(trancheDecimals, underlyingDecimals, virtualPrice, 0);

        // Baseline: with the zero stored rate the quote resolves through the CDO, so the rate must track the
        // virtual price (same hand derivation as the round-trip fuzz, an exact multiplication with no floor)
        uint256 virtualPriceRateWAD = virtualPrice * (10 ** (18 - uint256(underlyingDecimals)));
        assertEq(
            kernel.getTrancheUnitToNAVUnitConversionRateWAD(),
            virtualPriceRateWAD,
            "with no override stored the rate must be the live virtual price lifted to WAD"
        );

        // Store the override through the restricted setter: this test contract holds the manager's admin role,
        // so the call is genuinely authorized rather than gate-bypassed. The setter's internal accounting sync
        // runs against the unseeded market and passes trivially at zero NAVs
        kernel.setConversionRate(overrideRateWAD, false);
        assertEq(kernel.getStoredConversionRateWAD(), overrideRateWAD, "the override must land in quoter storage");

        // The override property: the stored rate IS the rate, with nothing live composed against it. In the
        // Makina composition the override only replaces the second hop and still multiplies against the share
        // price, here the equality is exact against the raw override for every fuzzed CDO configuration
        assertEq(kernel.getTrancheUnitToNAVUnitConversionRateWAD(), overrideRateWAD, "a stored override must be the ENTIRE rate, superseding the virtual price");

        // Forward conversion prices through the override: floor(amount x override / 10^trancheDecimals),
        // at most 1e30 x 1e27 = 1e57 before the division
        uint256 expectedNAV = (amount * overrideRateWAD) / (10 ** uint256(trancheDecimals));
        assertEq(toUint256(kernel.convertCollateralAssetsToValue(toTrancheUnits(amount))), expectedNAV, "forward conversion must price through the override");

        // Kill the CDO two ways: a zero virtual price (a zero rate if consulted) and then full revert mode. If
        // the quoter touched _getConversionRateFromOracleWAD with the override stored, these asserts would move
        // or revert, so surviving them proves the CDO is never consulted, a dead CDO must NOT block pricing
        // while an admin override is stored
        cdo.setVirtualPrice(0);
        assertEq(kernel.getTrancheUnitToNAVUnitConversionRateWAD(), overrideRateWAD, "a zeroed virtual price must not affect an override-priced quote");
        cdo.setRevertMode(true);
        assertEq(kernel.getTrancheUnitToNAVUnitConversionRateWAD(), overrideRateWAD, "a reverting CDO must not affect an override-priced quote");
        assertEq(toUint256(kernel.convertCollateralAssetsToValue(toTrancheUnits(amount))), expectedNAV, "conversions must keep pricing through a dead CDO");

        // Zero RESTORES the virtual price path: zero is always the resume-the-CDO sentinel here, there is no
        // oracle-presence invariant because the CDO immutable guarantees the live path exists. The CDO must be
        // healthy again first, since the setter's post-set accounting sync re-caches the now-live rate
        cdo.setRevertMode(false);
        cdo.setVirtualPrice(virtualPrice);
        kernel.setConversionRate(0, false);
        assertEq(kernel.getStoredConversionRateWAD(), 0, "the zero sentinel must land in quoter storage");
        assertEq(kernel.getTrancheUnitToNAVUnitConversionRateWAD(), virtualPriceRateWAD, "storing the zero sentinel must restore the live virtual price");
    }
}
