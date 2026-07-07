// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { Test } from "../../../lib/forge-std/src/Test.sol";
import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { RoycoDayAccountant } from "../../../src/accountant/RoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import {
    IdenticalMakinaShares_ST_JT_SharePriceToAdminOracle_Quoter
} from "../../../src/kernels/base/quoter/identical-st-jt/IdenticalMakinaShares_ST_JT_SharePriceToAdminOracle_Quoter.sol";
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

/**
 * @title TestFuzz_MakinaQuoterConversionRate_Kernel
 * @notice Fuzzes the Makina machine-share ST/JT quoter's two-hop composed rate (machine share -> accounting asset
 *         via convertToAssets, accounting asset -> NAV via the admin rate) across the full supported decimal
 *         envelope, share price, admin rate, and amount domains
 * @dev The quoter is the market's sole pricing seam: every deposit, redemption, coverage check, and sync marks
 *      tranche value through these conversions, so a composed-rate error silently misprices every tranche. The
 *      forward conversion is pinned to an independently floor-composed derivation, the junior side is pinned to
 *      the senior side (one shared machine share, one shared rate), and the NAV -> tranche -> NAV round trip is
 *      bounded by its input, the floor-monotonicity property that needs no closed form
 */
contract TestFuzz_MakinaQuoterConversionRate_Kernel is Test {
    /**
     * @notice Deploys a Makina-quoter kernel over freshly parameterized tokens, the smallest wiring the quoter's
     *         constructors and initializer accept
     * @dev The tranche and accountant implementations are consumed uninitialized: the kernel's constructor and
     *      initializer read only their immutables (asset addresses and the co-investment flag), and the test
     *      exercises only the kernel's pure-view conversion surface, so no market state is ever needed
     * @param _trancheDecimals The machine share token's decimals (the ST and JT tranche unit)
     * @param _accountingDecimals The machine accounting token's decimals (the intermediate hop)
     * @param _sharePriceWAD The machine's share price, whole accounting tokens per whole share, WAD-scaled
     * @param _adminRateWAD The admin oracle's accounting-asset-to-NAV rate, WAD-scaled
     * @return kernel The initialized kernel proxy exposing the quoter's conversion surface
     */
    function _deployMakinaKernel(
        uint8 _trancheDecimals,
        uint8 _accountingDecimals,
        uint256 _sharePriceWAD,
        uint256 _adminRateWAD
    )
        internal
        returns (MakinaKernel kernel)
    {
        // The machine share doubles as BOTH tranche assets (the quoter family mandates identical ST/JT assets)
        MockERC20C shareToken = new MockERC20C("Machine Share", "mSHARE", _trancheDecimals);
        MockERC20C accountingToken = new MockERC20C("Machine Accounting", "mACCT", _accountingDecimals);
        MockMakinaMachine machine = new MockMakinaMachine(address(shareToken), address(accountingToken), _sharePriceWAD);
        MockERC20C quoteToken = new MockERC20C("Quote Stable", "QUOTE", 6);

        // Liquidity venue wiring: the LT quoter's constructor demands a registered two-token pool pairing the
        // senior tranche, and its initializer demands an oracle attesting to that exact pool
        MockBalancerVault balancerVault = new MockBalancerVault();
        MockBPT bpt = new MockBPT(IVault(address(balancerVault)), "Royco BPT", "rBPT");
        MockBPTOracle bptOracle = new MockBPTOracle(balancerVault, address(bpt));

        // Predict the kernel proxy address so the tranche implementations can bake it into their immutables
        address kernelProxyDeployer = makeAddr("KERNEL_PROXY_DEPLOYER");
        address predictedKernel = vm.computeCreateAddress(kernelProxyDeployer, vm.getNonce(kernelProxyDeployer));

        RoycoSeniorTranche seniorTranche = new RoycoSeniorTranche(address(shareToken), predictedKernel);
        RoycoJuniorTranche juniorTranche = new RoycoJuniorTranche(address(shareToken), predictedKernel);
        RoycoLiquidityTranche liquidityTranche = new RoycoLiquidityTranche(address(bpt), predictedKernel);
        // Identical ST/JT assets force the co-invested junior configuration at kernel construction
        RoycoDayAccountant accountant = new RoycoDayAccountant(predictedKernel, true);

        balancerVault.registerPool(address(bpt), [IERC20(address(seniorTranche)), IERC20(address(quoteToken))]);

        MakinaKernel impl = new MakinaKernel(
            IRoycoDayKernel.RoycoDayKernelConstructionParams({
                seniorTranche: address(seniorTranche),
                stAsset: address(shareToken),
                juniorTranche: address(juniorTranche),
                jtAsset: address(shareToken),
                accountant: address(accountant),
                liquidityTranche: address(liquidityTranche),
                ltAsset: address(bpt),
                enforceVaultSharesTransferWhitelist: false
            }),
            address(machine)
        );
        bytes memory initData = abi.encodeCall(
            impl.initialize,
            (
                IRoycoDayKernel.RoycoDayKernelInitParams({
                    initialAuthority: makeAddr("AUTHORITY"),
                    protocolFeeRecipient: makeAddr("PROTOCOL_FEE_RECIPIENT"),
                    stSelfLiquidationBonusWAD: 0,
                    roycoBlacklist: address(0)
                }),
                MakinaKernel.KernelSpecificInitParams({
                    stAndJTQuoterParams: IdenticalMakinaShares_ST_JT_SharePriceToAdminOracle_Quoter.ST_JT_QuoterSpecificParams({
                        initialConversionRateWAD: _adminRateWAD
                    }),
                    ltQuoterParams: BalancerV3_LT_BPTOracle_Quoter.LT_QuoterSpecificParams({ bptOracle: address(bptOracle), maxReinvestmentSlippageWAD: 0 })
                })
            )
        );
        vm.prank(kernelProxyDeployer);
        kernel = MakinaKernel(address(new ERC1967Proxy(address(impl), initData)));
        require(address(kernel) == predictedKernel, "kernel proxy address prediction failed");
    }

    /**
     * Scenario: a Makina-quoter kernel is deployed with a fuzzed machine share price, a fuzzed admin rate, and
     * fuzzed tranche/accounting decimals spanning the constructor's whole supported envelope, then one amount is
     * pushed through the tranche -> NAV conversion and one value through the NAV -> tranche -> NAV round trip.
     *
     * Three properties are pinned, none of them by re-running the quoter's own code:
     * (a) the forward conversion equals a floor composition derived by hand from the raw fuzz inputs,
     * (b) the junior conversions equal the senior conversions on identical inputs (one shared machine share,
     *     one shared admin rate, so any divergence would let the two tranches mark the same asset differently), and
     * (c) the NAV -> tranche -> NAV round trip never exceeds its input (two floor divisions can only lose value,
     *     and a round trip that came back higher would let a redeem-redeposit loop print NAV out of rounding).
     */
    function testFuzz_MakinaConversionRoundTrip_NeverExceedsInputAndMatchesTwoHopDerivation(
        uint256 _trancheDecimalsSeed,
        uint256 _accountingDecimalsSeed,
        uint256 _sharePriceSeed,
        uint256 _adminRateSeed,
        uint256 _amountSeed,
        uint256 _navSeed
    )
        public
    {
        // Decimal envelope: the quoter constructor probes the machine with 10^(18 + trancheDecimals - accountingDecimals)
        // shares, so accountingDecimals <= 18 + trancheDecimals is the whole supported surface. Tranche decimals span
        // the degenerate 0-decimal share up to a 24-decimal share, and accounting decimals span 0 up to that envelope
        // edge (capped at 24), so the boundary accountingDecimals == 18 + trancheDecimals is reachable for small shares
        uint8 trancheDecimals = uint8(bound(_trancheDecimalsSeed, 0, 24));
        uint8 accountingDecimals = uint8(bound(_accountingDecimalsSeed, 0, trancheDecimals >= 6 ? 24 : 18 + uint256(trancheDecimals)));
        // Share price and admin rate each span 1e-9 to 1e9 (18 orders of magnitude), both nonzero. Their product is
        // at least 1e18, so the composed WAD rate floors to at least 1 and the NAV -> tranche division cannot hit a
        // zero denominator (a zero composed rate cannot price anything and is not a conversion-math case)
        uint256 sharePriceWAD = bound(_sharePriceSeed, 1e9, 1e27);
        uint256 adminRateWAD = bound(_adminRateSeed, 1e9, 1e27);
        // Amounts up to 1e30 wei cover a million whole units even at 24 decimals, and bound's edge bias hits 0 and the max
        uint256 amount = bound(_amountSeed, 0, 1e30);
        uint256 navValue = bound(_navSeed, 0, 1e30);

        MakinaKernel kernel = _deployMakinaKernel(trancheDecimals, accountingDecimals, sharePriceWAD, adminRateWAD);

        // Independent two-hop derivation from the raw fuzz inputs, in plain checked arithmetic (every intermediate
        // is bounded well under 2^256, so no 512-bit multiplication is needed and the src mulDiv chain is not reused):
        //
        // Hop 1 (machine share -> accounting asset): the mock machine computes
        //   assets = shares x sharePriceWAD x 10^accountingDecimals / (10^trancheDecimals x 1e18)
        // and the quoter probes it with shares = 10^(18 + trancheDecimals - accountingDecimals), so the scale factors
        // cancel exactly: 10^(18 + tD - aD) x P x 10^aD / (10^tD x 1e18) = P x 10^(18 + tD) / 10^(18 + tD) = P.
        // One WAD-scaled tranche unit is worth EXACTLY the share price in WAD-scaled accounting assets, with no
        // flooring loss on this hop for any decimal pair in the envelope.
        //
        // Hop 2 (accounting asset -> NAV): scaling by the admin rate and re-normalizing the doubled WAD,
        //   composedRate = floor(P x R / 1e18), at most 1e27 x 1e27 = 1e54 before the division, safe in checked math
        uint256 expectedRateWAD = (sharePriceWAD * adminRateWAD) / 1e18;

        // (a) Forward conversion: NAV = floor(amount x composedRate / 10^trancheDecimals), the second and only other
        // floor of the forward path. Largest intermediate is 1e30 x 1e36 = 1e66, still comfortably below 2^256
        uint256 expectedNAV = (amount * expectedRateWAD) / (10 ** uint256(trancheDecimals));
        uint256 stForwardNAV = toUint256(kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(amount)));
        assertEq(kernel.getTrancheUnitToNAVUnitConversionRateWAD(), expectedRateWAD, "the composed rate must be floor(sharePrice x adminRate / 1e18)");
        assertEq(stForwardNAV, expectedNAV, "senior tranche -> NAV must equal the hand-composed two-hop floor derivation");

        // (b) Identical-assets symmetry, forward direction: the junior tranche holds the very same machine share
        // priced through the very same admin rate, so a junior mark differing from the senior mark by even one wei
        // would value one asset two ways inside a single market
        assertEq(toUint256(kernel.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(amount))), stForwardNAV, "junior forward conversion must equal senior");

        // (c) Round trip: NAV -> tranche floors once, tranche -> NAV floors again, so the value coming back can
        // never exceed what went in. This is the no-closed-form bound: whatever the rate and decimals, a holder
        // converting a NAV claim to tranche units and marking it back must never come out ahead
        uint256 trancheUnitsOut = toUint256(kernel.stConvertNAVUnitsToTrancheUnits(toNAVUnits(navValue)));
        uint256 navRoundTrip = toUint256(kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(trancheUnitsOut)));
        assertLe(navRoundTrip, navValue, "NAV -> tranche -> NAV must never exceed the original value");

        // (b) Identical-assets symmetry, inverse direction: the shared rate must also divide identically
        assertEq(toUint256(kernel.jtConvertNAVUnitsToTrancheUnits(toNAVUnits(navValue))), trancheUnitsOut, "junior inverse conversion must equal senior");
    }
}
