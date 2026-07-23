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
    Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel as MakinaChainlinkKernel
} from "../../../src/kernels/Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel.sol";
import {
    IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_Quoter
} from "../../../src/kernels/base/quoter/identical-st-jt/IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_Quoter.sol";
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

/**
 * @title TestFuzz_MakinaChainlinkQuoterConversionRate_Kernel
 * @notice Fuzzes the Makina machine-share ST/JT quoter's two-hop composed rate (machine share -> accounting asset
 *         via convertToAssets, accounting asset -> NAV via a Chainlink feed) across the full supported decimal
 *         envelope, share price, feed decimals, feed answer, and amount domains, plus the admin override that
 *         supersedes the feed entirely
 * @dev The quoter is the market's sole pricing seam: every deposit, redemption, coverage check, and sync marks
 *      tranche value through these conversions, so a composed-rate error silently misprices every tranche. The
 *      forward conversion is pinned to an independently floor-composed derivation (the senior and junior
 *      tranches share the ONE collateral converter, so identical pricing is structural rather than asserted),
 *      the NAV -> collateral -> NAV round trip is bounded by its input, and a stored nonzero override must
 *      price the second hop instead of the feed for every fuzzed feed configuration
 */
contract TestFuzz_MakinaChainlinkQuoterConversionRate_Kernel is Test {
    /// @dev The staleness threshold given to the Chainlink hop, generous so the constructor-stamped round stays fresh for the whole run
    uint48 internal constant STALENESS_THRESHOLD_SECONDS = 1 days;

    /// @notice The authority every fuzz-deployed kernel is initialized with
    AccessManager internal accessManager;

    /// @dev The override arm drives the restricted setConversionRate directly, so the kernels' authority must genuinely
    ///      authorize this test contract: a fresh manager admin'd by the test leaves every target function on the default admin role, which the test holds
    function setUp() public {
        accessManager = new AccessManager(address(this));
    }

    /**
     * @notice Deploys a Makina-Chainlink-quoter kernel over freshly parameterized tokens and feed, the smallest
     *         wiring the quoter's constructors and initializer accept
     * @dev The tranche and accountant implementations are consumed uninitialized: the kernel's constructor and
     *      initializer read only their immutables (asset addresses), the conversion
     *      surface under test is pure-view, and the override setter's internal accounting syncs pass trivially at
     *      zero NAVs, so no market state is ever needed
     * @param _trancheDecimals The machine share token's decimals (the ST and JT tranche unit)
     * @param _accountingDecimals The machine accounting token's decimals (the intermediate hop)
     * @param _sharePriceWAD The machine's share price, whole accounting tokens per whole share, WAD-scaled
     * @param _feedDecimals The Chainlink feed's decimals
     * @param _feedAnswer The feed's answer, the accounting-asset-to-NAV price scaled to the feed decimals
     * @param _initialConversionRateWAD The initial stored rate (0 is VALID here and means Chainlink-primary)
     * @return kernel The initialized kernel proxy exposing the quoter's conversion surface
     * @return feed The deployed feed, returned so tests can move its knobs after initialization
     */
    function _deployMakinaChainlinkKernel(
        uint8 _trancheDecimals,
        uint8 _accountingDecimals,
        uint256 _sharePriceWAD,
        uint8 _feedDecimals,
        int256 _feedAnswer,
        uint256 _initialConversionRateWAD
    )
        internal
        returns (MakinaChainlinkKernel kernel, MockAggregatorV3 feed)
    {
        // The machine share is the market's ONE coinvested collateral asset shared by ST and JT
        MockERC20C shareToken = new MockERC20C("Machine Share", "mSHARE", _trancheDecimals);
        MockERC20C accountingToken = new MockERC20C("Machine Accounting", "mACCT", _accountingDecimals);
        MockMakinaMachine machine = new MockMakinaMachine(address(shareToken), address(accountingToken), _sharePriceWAD);
        // The accounting-asset-to-NAV feed: the constructor stamps the round at the current timestamp, so the
        // answer stays fresh against the staleness threshold for the whole run with no warp needed
        feed = new MockAggregatorV3(_feedDecimals, _feedAnswer);
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
        RoycoDayAccountant accountant = new RoycoDayAccountant(predictedKernel);

        balancerVault.registerPool(address(bpt), [IERC20(address(seniorTranche)), IERC20(address(quoteToken))]);

        MakinaChainlinkKernel impl = new MakinaChainlinkKernel(
            IRoycoDayKernel.RoycoDayKernelConstructionParams({
                seniorTranche: address(seniorTranche),
                juniorTranche: address(juniorTranche),
                collateralAsset: address(shareToken),
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
                    initialAuthority: address(accessManager),
                    protocolFeeRecipient: makeAddr("PROTOCOL_FEE_RECIPIENT"),
                    stSelfLiquidationBonusWAD: 0,
                    roycoBlacklist: address(0)
                }),
                MakinaChainlinkKernel.KernelSpecificInitParams({
                    stAndJTQuoterParams: IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_Quoter.ST_JT_QuoterSpecificParams({
                        initialConversionRateWAD: _initialConversionRateWAD,
                        accountingAssetToNavAssetOracle: address(feed),
                        stalenessThresholdSeconds: STALENESS_THRESHOLD_SECONDS,
                        sequencerUptimeFeed: address(0),
                        gracePeriodSeconds: 0
                    }),
                    ltQuoterParams: BalancerV3_LT_BPTOracle_Quoter.LT_QuoterSpecificParams({ bptOracle: address(bptOracle), maxReinvestmentSlippageWAD: 0 })
                })
            )
        );
        vm.prank(kernelProxyDeployer);
        kernel = MakinaChainlinkKernel(address(new ERC1967Proxy(address(impl), initData)));
        require(address(kernel) == predictedKernel, "kernel proxy address prediction failed");
    }

    /**
     * Scenario: a Makina-Chainlink-quoter kernel is deployed with a fuzzed machine share price, a fuzzed feed
     * (decimals and answer), and fuzzed tranche/accounting decimals spanning the constructor's whole supported
     * envelope, initialized with the zero stored rate so the second hop is genuinely Chainlink-primary, then one
     * amount is pushed through the tranche -> NAV conversion and one value through the NAV -> tranche -> NAV
     * round trip.
     *
     * Two properties are pinned, neither by re-running the quoter's own code (the old junior-equals-senior
     * conjunct is now structural: both tranches price through the single collateral converter, so divergent
     * per-tranche marks are unrepresentable):
     * (a) the forward conversion equals a floor composition derived by hand from the raw fuzz inputs, and
     * (b) the NAV -> collateral -> NAV round trip never exceeds its input (two floor divisions can only lose value,
     *     and a round trip that came back higher would let a redeem-redeposit loop print NAV out of rounding).
     */
    function testFuzz_MakinaChainlinkConversionRoundTrip_NeverExceedsInputAndMatchesTwoHopDerivation(
        uint256 _trancheDecimalsSeed,
        uint256 _accountingDecimalsSeed,
        uint256 _sharePriceSeed,
        uint256 _feedDecimalsSeed,
        uint256 _feedAnswerSeed,
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
        // Share price spans 1e-9 to 1e9 (18 orders of magnitude), nonzero
        uint256 sharePriceWAD = bound(_sharePriceSeed, 1e9, 1e27);
        // Feed decimals span the common Chainlink envelope (USD feeds at 8, ETH-quoted feeds at 18, and low-precision
        // feeds down at 6), so the 10^decimals normalization is exercised across the whole realistic range
        uint8 feedDecimals = uint8(bound(_feedDecimalsSeed, 6, 18));
        // The feed answer is bounded so its WAD-normalized price tops out at 1e9, mirroring the share price ceiling,
        // and bottoms out at 1e-9 only for feedDecimals >= 9 (the answer 10^(feedDecimals - 9) normalizes to exactly
        // 1e9 wei). For feedDecimals < 9 that target answer sits below one raw feed unit, so the lower bound clamps
        // at 1 and the normalized floor rises to one raw feed unit, 10^(18 - feedDecimals) WAD. Either way the WAD
        // feed price is at least 1e9, so the share price and the WAD feed price multiply to at least
        // 1e9 x 1e9 = 1e18, the composed WAD rate floors to at least 1, and the NAV -> tranche division cannot hit
        // a zero denominator (a zero composed rate cannot price anything and is not a conversion-math case)
        uint256 minFeedAnswer = feedDecimals > 9 ? 10 ** (uint256(feedDecimals) - 9) : 1;
        uint256 feedAnswer = bound(_feedAnswerSeed, minFeedAnswer, 10 ** (uint256(feedDecimals) + 9));
        // Amounts up to 1e30 wei cover a million whole units even at 24 decimals, and bound's edge bias hits 0 and the max
        uint256 amount = bound(_amountSeed, 0, 1e30);
        uint256 navValue = bound(_navSeed, 0, 1e30);

        // The zero initial rate is a SUPPORTED configuration in this composition: initialize skips the store and
        // the second hop resolves through the Chainlink feed on every quote
        (MakinaChainlinkKernel kernel,) = _deployMakinaChainlinkKernel(trancheDecimals, accountingDecimals, sharePriceWAD, feedDecimals, int256(feedAnswer), 0);

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
        // Hop 2 (accounting asset -> NAV): the feed answer normalized to WAD,
        //   feedRateWAD = floor(answer x 1e18 / 10^feedDecimals)
        // and since feedDecimals <= 18 the divisor 10^feedDecimals divides 1e18 exactly, so the floor is lossless
        // here (feedRateWAD = answer x 10^(18 - feedDecimals)). Largest intermediate is 1e27 x 1e18 = 1e45
        uint256 feedRateWAD = (feedAnswer * 1e18) / (10 ** uint256(feedDecimals));
        // Composition: re-normalizing the doubled WAD,
        //   composedRate = floor(P x feedRateWAD / 1e18), at most 1e27 x 1e27 = 1e54 before the division, safe in checked math
        uint256 expectedRateWAD = (sharePriceWAD * feedRateWAD) / 1e18;

        // (a) Forward conversion: NAV = floor(amount x composedRate / 10^trancheDecimals), the second and only other
        // floor of the forward path. Largest intermediate is 1e30 x 1e36 = 1e66, still comfortably below 2^256
        uint256 expectedNAV = (amount * expectedRateWAD) / (10 ** uint256(trancheDecimals));
        uint256 forwardNAV = toUint256(kernel.convertCollateralAssetsToValue(toTrancheUnits(amount)));
        assertEq(kernel.getTrancheUnitToNAVUnitConversionRateWAD(), expectedRateWAD, "the composed rate must be floor(sharePrice x feedRateWAD / 1e18)");
        assertEq(forwardNAV, expectedNAV, "collateral -> NAV must equal the hand-composed two-hop floor derivation");

        // (b) Round trip: NAV -> collateral floors once, collateral -> NAV floors again, so the value coming back
        // can never exceed what went in. This is the no-closed-form bound: whatever the rate and decimals, a holder
        // converting a NAV claim to collateral units and marking it back must never come out ahead
        uint256 trancheUnitsOut = toUint256(kernel.convertValueToCollateralAssets(toNAVUnits(navValue)));
        uint256 navRoundTrip = toUint256(kernel.convertCollateralAssetsToValue(toTrancheUnits(trancheUnitsOut)));
        assertLe(navRoundTrip, navValue, "NAV -> collateral -> NAV must never exceed the original value");
    }

    /**
     * Scenario: a Makina-Chainlink-quoter kernel is deployed Chainlink-primary (zero stored rate) over the same
     * fuzzed domains, the authority-held test contract stores a fuzzed nonzero override through the restricted
     * setConversionRate, and then the feed is zeroed and armed to revert outright.
     *
     * The override property pinned: a stored nonzero rate is the ENTIRE second hop. Before the store the composed
     * rate must track the feed, after the store it must equal floor(sharePrice x override / 1e18) regardless of the
     * feed answer, and it must keep quoting through a feed that would revert INVALID_PRICE (or revert outright) if
     * it were ever consulted, which proves _queryChainlinkOracle is never called while the override is stored.
     * Storing zero afterwards must RESTORE the Chainlink path (this quoter resolves setConversionRate to the
     * permissive root setter, unlike the admin sibling where zero is rejected), re-exposing the feed-derived rate.
     */
    function testFuzz_MakinaChainlinkAdminOverride_StoredRateSupersedesFeedAndZeroRestoresIt(
        uint256 _trancheDecimalsSeed,
        uint256 _accountingDecimalsSeed,
        uint256 _sharePriceSeed,
        uint256 _feedDecimalsSeed,
        uint256 _feedAnswerSeed,
        uint256 _overrideRateSeed,
        uint256 _amountSeed
    )
        public
    {
        // Same decimal envelope and share price domain as the round-trip fuzz (see its bound justifications)
        uint8 trancheDecimals = uint8(bound(_trancheDecimalsSeed, 0, 24));
        uint8 accountingDecimals = uint8(bound(_accountingDecimalsSeed, 0, trancheDecimals >= 6 ? 24 : 18 + uint256(trancheDecimals)));
        uint256 sharePriceWAD = bound(_sharePriceSeed, 1e9, 1e27);
        uint8 feedDecimals = uint8(bound(_feedDecimalsSeed, 6, 18));
        // Same feed answer domain as the round-trip fuzz: the WAD-normalized feed price tops out at 1e9, bottoming
        // out at 1e-9 for feedDecimals >= 9 and at one raw feed unit (10^(18 - feedDecimals) WAD) below that
        uint256 minFeedAnswer = feedDecimals > 9 ? 10 ** (uint256(feedDecimals) - 9) : 1;
        uint256 feedAnswer = bound(_feedAnswerSeed, minFeedAnswer, 10 ** (uint256(feedDecimals) + 9));
        // The override spans 1e-9 to 1e9 and is strictly nonzero: zero is not an override in this composition, it
        // is the restore-the-feed sentinel exercised at the end of this very test. The 1e9 floor keeps the
        // override-composed rate at least floor(1e9 x 1e9 / 1e18) = 1, nonzero as every stored second hop should be
        uint256 overrideRateWAD = bound(_overrideRateSeed, 1e9, 1e27);
        uint256 amount = bound(_amountSeed, 0, 1e30);

        (MakinaChainlinkKernel kernel, MockAggregatorV3 feed) =
            _deployMakinaChainlinkKernel(trancheDecimals, accountingDecimals, sharePriceWAD, feedDecimals, int256(feedAnswer), 0);

        // Baseline: with the zero stored rate the second hop is the feed, so the composed rate must track it
        // (same hand derivation as the round-trip fuzz, hop 1 cancels exactly to the WAD share price)
        uint256 feedRateWAD = (feedAnswer * 1e18) / (10 ** uint256(feedDecimals));
        uint256 feedComposedRateWAD = (sharePriceWAD * feedRateWAD) / 1e18;
        assertEq(kernel.getTrancheUnitToNAVUnitConversionRateWAD(), feedComposedRateWAD, "with no override stored the second hop must be the live feed");

        // Store the override through the restricted setter: this test contract holds the manager's admin role, so
        // the call is genuinely authorized rather than gate-bypassed. The setter's internal accounting sync runs
        // against the unseeded market and passes trivially at zero NAVs
        kernel.setConversionRate(overrideRateWAD, false);
        assertEq(kernel.getStoredConversionRateWAD(), overrideRateWAD, "the override must land in quoter storage");

        // The override property: composed = floor(sharePrice x override / 1e18), derived by hand exactly like the
        // feed composition (at most 1e27 x 1e27 = 1e54 before the division, safe in checked math), and the feed
        // answer must no longer matter
        uint256 overrideComposedRateWAD = (sharePriceWAD * overrideRateWAD) / 1e18;
        assertEq(kernel.getTrancheUnitToNAVUnitConversionRateWAD(), overrideComposedRateWAD, "a stored override must replace the feed as the second hop");

        // Forward conversion prices through the override-composed rate: floor(amount x rate / 10^trancheDecimals),
        // at most 1e30 x 1e36 = 1e66 before the division
        uint256 expectedNAV = (amount * overrideComposedRateWAD) / (10 ** uint256(trancheDecimals));
        assertEq(toUint256(kernel.convertCollateralAssetsToValue(toTrancheUnits(amount))), expectedNAV, "forward conversion must price through the override");

        // Kill the feed two ways: a zero answer (INVALID_PRICE if consulted) and then full revert mode. If the
        // quoter touched _queryChainlinkOracle with the override stored, these asserts would revert rather than
        // fail, so surviving them proves the feed is never consulted, a dead feed must NOT block pricing while an
        // admin override is stored
        feed.setAnswer(0);
        assertEq(kernel.getTrancheUnitToNAVUnitConversionRateWAD(), overrideComposedRateWAD, "a zeroed feed must not affect an override-priced quote");
        feed.setRevertMode(true);
        assertEq(kernel.getTrancheUnitToNAVUnitConversionRateWAD(), overrideComposedRateWAD, "a reverting feed must not affect an override-priced quote");
        assertEq(toUint256(kernel.convertCollateralAssetsToValue(toTrancheUnits(amount))), expectedNAV, "conversions must keep pricing through a dead feed");

        // Zero RESTORES the Chainlink path: this quoter dispatches setConversionRate to the permissive root setter
        // (zero is the query-the-feed sentinel, not a rejected value like in the admin sibling). The feed must be
        // healthy again first, since the setter's post-set accounting sync re-caches the now-feed-driven rate
        feed.setRevertMode(false);
        feed.setAnswer(int256(feedAnswer));
        kernel.setConversionRate(0, false);
        assertEq(kernel.getStoredConversionRateWAD(), 0, "the zero sentinel must land in quoter storage");
        assertEq(kernel.getTrancheUnitToNAVUnitConversionRateWAD(), feedComposedRateWAD, "storing the zero sentinel must restore the feed as the second hop");
    }
}
