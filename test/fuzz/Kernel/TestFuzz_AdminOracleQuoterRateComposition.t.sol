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
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel as ERC4626ToAdminKernel
} from "../../../src/kernels/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel.sol";
import {
    IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter
} from "../../../src/kernels/base/quoter/identical-st-jt/IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter.sol";
import {
    IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter
} from "../../../src/kernels/base/quoter/identical-st-jt/IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter.sol";
import { IdenticalAssets_ST_JT_AdminOracle_Quoter } from "../../../src/kernels/base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_AdminOracle_Quoter.sol";
import {
    IdenticalAssets_ST_JT_ChainlinkOracle_Quoter
} from "../../../src/kernels/base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.sol";
import { BalancerV3_LT_BPTOracle_Quoter } from "../../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_BPTOracle_Quoter.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoJuniorTranche } from "../../../src/tranches/RoycoJuniorTranche.sol";
import { RoycoLiquidityTranche } from "../../../src/tranches/RoycoLiquidityTranche.sol";
import { RoycoSeniorTranche } from "../../../src/tranches/RoycoSeniorTranche.sol";
import {
    Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3_BPTOracle_LT_Kernel as ChainlinkToAdminKernel
} from "../../../src/kernels/Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3_BPTOracle_LT_Kernel.sol";
import { MockAggregatorV3 } from "../../mocks/MockAggregatorV3.sol";
import { MockBPT } from "../../mocks/MockBPT.sol";
import { MockBPTOracle } from "../../mocks/MockBPTOracle.sol";
import { MockBalancerVault } from "../../mocks/MockBalancerVault.sol";
import { MockERC20C } from "../../mocks/MockERC20C.sol";
import { MockERC4626C } from "../../mocks/MockERC4626C.sol";

/**
 * @title TestFuzz_AdminOracleQuoterRateComposition_Kernel
 * @notice Fuzzes the two admin-second-hop ST/JT quoter compositions, the Chainlink-to-admin quoter (a Chainlink feed
 *         prices the tranche asset into a reference asset, an admin rate prices the reference asset into NAV units)
 *         and the ERC4626-share-price-to-Chainlink quoter deployed admin-primary (the vault's live share price is the
 *         first hop, and the stored admin rate, standing in for a null Chainlink oracle, is the second)
 * @dev The composed rate is the market's sole pricing seam: every deposit, redemption, coverage check, and sync marks
 *      tranche value through it, so a one-wei composition error silently misprices every tranche. The forward
 *      conversion is pinned against a plain checked-integer composition derived by hand from the raw fuzz inputs,
 *      never against the production math, and every zero admin-rate draw pins the setter's rejection of the zero
 *      sentinel, since in these compositions there is no oracle to resume and a stored zero would brick all pricing
 */
contract TestFuzz_AdminOracleQuoterRateComposition_Kernel is Test {
    /// @dev The staleness threshold given to the Chainlink hop, generous so the constructor-stamped round stays fresh for the whole run
    uint48 internal constant STALENESS_THRESHOLD_SECONDS = 1 days;

    /**
     * @dev The minimal market plumbing one kernel deployment needs, bundled so both kernel deploy helpers share it
     * @custom:field balancerVault - The mock Balancer vault the liquidity venue is ledgered on
     * @custom:field bpt - The BPT the liquidity tranche holds
     * @custom:field bptOracle - The oracle attesting to the BPT, demanded by the LT quoter's initializer
     * @custom:field seniorTranche - The senior tranche bound to the predicted kernel address
     * @custom:field juniorTranche - The junior tranche bound to the predicted kernel address
     * @custom:field liquidityTranche - The liquidity tranche bound to the predicted kernel address
     * @custom:field accountant - The accountant bound to the predicted kernel address
     * @custom:field kernelProxyDeployer - The dedicated deployer whose next create lands at the predicted address
     * @custom:field predictedKernel - The kernel proxy address baked into every component's immutables
     */
    struct MarketPlumbing {
        MockBalancerVault balancerVault;
        MockBPT bpt;
        MockBPTOracle bptOracle;
        address seniorTranche;
        address juniorTranche;
        address liquidityTranche;
        address accountant;
        address kernelProxyDeployer;
        address predictedKernel;
    }

    /// @notice The authority every fuzz-deployed kernel is initialized with
    AccessManager internal accessManager;

    /// @dev The zero-draw arm drives the restricted setter directly, so the kernels' authority must genuinely
    ///      authorize this test contract: a fresh manager admin'd by the test leaves every target function on the default admin role, which the test holds
    function setUp() public {
        accessManager = new AccessManager(address(this));
    }

    /**
     * Scenario: both admin-second-hop kernels are deployed over one set of fuzzed inputs, a Chainlink feed with
     * fuzzed decimals and price for the first, an ERC4626 vault with a fuzzed share rate for the second, both
     * sharing one fuzzed admin rate, then one fuzzed amount is pushed through each kernel's senior tranche -> NAV
     * conversion.
     *
     * Each forward conversion is pinned to a plain checked-integer composition written out from the raw fuzz inputs.
     * The domains are sized so every intermediate product fits comfortably in 256 bits, so the derivation needs no
     * 512-bit multiplication and therefore cannot be a mirror of the production full-width mulDiv chain: agreement
     * means the production chain introduces no extra rounding or scaling step anywhere in either two-hop path.
     *
     * A zero admin-rate draw exercises the other half of the contract: zero is the resume-the-oracle sentinel in the
     * stored-rate-overrides-oracle quoter family, but neither deployment has a second-hop oracle to resume (the
     * Chainlink-to-admin quoter's oracle-query helper is a hard revert, and the admin-primary kernel's second-hop
     * oracle is the null address), so a stored zero would brick every conversion and the setter must reject it
     * loudly on both kernels.
     */
    function testFuzz_TwoHopConversion_MatchesIndependentComposition(
        uint256 _feedDecimalsSeed,
        uint256 _feedPriceSeed,
        uint256 _vaultRateSeed,
        uint256 _adminRateSeed,
        uint256 _amountSeed
    )
        public
    {
        // Feed decimals span the common Chainlink envelope (USD feeds at 8, ETH-quoted feeds at 18, and low-precision
        // feeds down at 6), so the 10^decimals normalization is exercised across the whole realistic range
        uint8 feedDecimals = uint8(bound(_feedDecimalsSeed, 6, 18));
        // Feed price spans one raw feed unit (10^-decimals, the smallest nonzero price a feed can report) up to a
        // trillion whole reference assets per tranche asset
        uint256 feedPrice = bound(_feedPriceSeed, 1, 1e12 * (10 ** uint256(feedDecimals)));
        // The vault's assets-per-share rate is the WAD analog of the feed domain: 1 wei of WAD up to a trillion
        // whole underlying per whole share
        uint256 vaultRateWAD = bound(_vaultRateSeed, 1, 1e30);
        // The admin rate domain deliberately includes zero so the fuzzer itself walks into the setter's rejection arm
        uint256 adminRateWAD = bound(_adminRateSeed, 0, 1e24);
        // Amounts up to 1e30 wei cover a trillion whole 18-decimal units, and bound's edge bias hits 0 and the max
        uint256 amount = bound(_amountSeed, 0, 1e30);

        if (adminRateWAD == 0) {
            // A zero admin rate can never be stored: it is the query-the-oracle sentinel, and neither deployment has
            // a second-hop oracle to fall back on (the Chainlink-to-admin quoter's oracle-query helper is an
            // unconditional revert, the admin-primary kernel's second-hop oracle is the null address), so a stored
            // zero would turn every conversion (and with it every sync, deposit, and redemption) into a revert. Both
            // kernels are deployed with a valid placeholder rate and the setter must refuse to overwrite it with the
            // sentinel, the admin-only quoter through its unconditional zero gate and the admin-primary kernel
            // through the Chainlink base's no-oracle-to-resume gate
            ChainlinkToAdminKernel chainlinkKernel = _deployChainlinkToAdminKernel(feedDecimals, feedPrice, 1e18);
            vm.expectRevert(IdenticalAssets_ST_JT_AdminOracle_Quoter.INVALID_CONVERSION_RATE.selector);
            chainlinkKernel.setConversionRate(0, false);

            ERC4626ToAdminKernel erc4626Kernel = _deployERC4626ToAdminKernel(vaultRateWAD, 1e18);
            vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.SENTINEL_RATE_WITHOUT_ORACLE.selector);
            erc4626Kernel.setConversionRate(0, false);
            return;
        }

        // ============================================================
        // Composition 1: Chainlink feed price x admin rate
        // ============================================================
        {
            ChainlinkToAdminKernel chainlinkKernel = _deployChainlinkToAdminKernel(feedDecimals, feedPrice, adminRateWAD);

            // Independent composition in plain checked arithmetic. The feed answer is a fixed-point number with
            // feedDecimals fractional digits, so normalizing the product of the two hops back to WAD divides by
            // 10^feedDecimals once:
            //   composedRateWAD = floor(feedPrice x adminRateWAD / 10^feedDecimals)
            // Headroom: feedPrice <= 1e12 x 10^dec and adminRateWAD <= 1e24, so the raw product is at most 1e54 and
            // the quotient at most 1e36, far below 2^256 (~1.16e77), so checked 256-bit math suffices
            uint256 expectedRateWAD = (feedPrice * adminRateWAD) / (10 ** uint256(feedDecimals));
            // Forward conversion over an 18-decimal tranche asset divides by its unit scale once more:
            //   expectedNAV = floor(amount x composedRateWAD / 1e18), at most 1e30 x 1e36 = 1e66 before the division
            uint256 expectedNAV = (amount * expectedRateWAD) / 1e18;

            assertEq(
                chainlinkKernel.getTrancheUnitToNAVUnitConversionRateWAD(),
                expectedRateWAD,
                "the Chainlink-to-admin composed rate must be floor(feedPrice x adminRate / 10^feedDecimals)"
            );
            assertEq(
                toUint256(chainlinkKernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(amount))),
                expectedNAV,
                "senior tranche -> NAV through the Chainlink-to-admin quoter must equal the hand-composed two-hop floor derivation"
            );
        }

        // ============================================================
        // Composition 2: ERC4626 vault share price x admin rate
        // ============================================================
        {
            ERC4626ToAdminKernel erc4626Kernel = _deployERC4626ToAdminKernel(vaultRateWAD, adminRateWAD);

            // Hop 1 is exact by algebra: the quoter probes convertToAssets with 10^(18 + shareDecimals -
            // underlyingDecimals) shares, and the mock vault floors (shares x rateWAD / 10^(18 + 18 - 6)) over that
            // very same scalar, so the scale factors cancel and one WAD-scaled share is worth EXACTLY rateWAD
            // underlying with no flooring loss. Hop 2 then re-normalizes the doubled WAD:
            //   composedRateWAD = floor(vaultRateWAD x adminRateWAD / 1e18), at most 1e30 x 1e24 = 1e54 raw
            uint256 expectedRateWAD = (vaultRateWAD * adminRateWAD) / 1e18;
            // Forward conversion over the 18-decimal vault share: floor(amount x composedRateWAD / 1e18), the raw
            // product at most 1e30 x 1e36 = 1e66, still comfortably inside checked 256-bit math
            uint256 expectedNAV = (amount * expectedRateWAD) / 1e18;

            assertEq(
                erc4626Kernel.getTrancheUnitToNAVUnitConversionRateWAD(),
                expectedRateWAD,
                "the share-price-to-admin composed rate must be floor(vaultRate x adminRate / 1e18)"
            );
            assertEq(
                toUint256(erc4626Kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(amount))),
                expectedNAV,
                "senior tranche -> NAV through the share-price-to-admin quoter must equal the hand-composed two-hop floor derivation"
            );
        }
    }

    // =============================
    // Deployment helpers (minimal wiring the quoters' constructors and initializers accept)
    // =============================

    /**
     * @notice Deploys a Chainlink-to-admin kernel over a fresh 18-decimal tranche asset and a feed with the fuzzed
     *         decimals and price
     * @dev The tranche and accountant implementations are consumed uninitialized: the kernel's constructor and
     *      initializer read only their immutables, and the test exercises only the kernel's view conversion surface
     *      plus the setter's pre-sync zero gate (which rejects before any accounting sync runs), so no market state
     *      is ever needed
     * @param _feedDecimals The Chainlink feed's decimals
     * @param _feedPrice The feed's answer, scaled to the feed decimals (the tranche-asset-to-reference-asset price)
     * @param _adminRateWAD The admin oracle's reference-asset-to-NAV rate, WAD-scaled
     * @return kernel The initialized kernel proxy exposing the quoter's conversion surface
     */
    function _deployChainlinkToAdminKernel(uint8 _feedDecimals, uint256 _feedPrice, uint256 _adminRateWAD) internal returns (ChainlinkToAdminKernel kernel) {
        // One shared plain ERC20 doubles as BOTH tranche assets (the quoter family mandates identical ST/JT assets)
        MockERC20C trancheAsset = new MockERC20C("ST/JT Asset", "STJT", 18);
        // The constructor stamps the round at the current timestamp, so the answer stays fresh for the whole run
        MockAggregatorV3 feed = new MockAggregatorV3(_feedDecimals, int256(_feedPrice));
        MarketPlumbing memory plumbing = _deployPlumbing(address(trancheAsset), "CHAINLINK_KERNEL_DEPLOYER");

        ChainlinkToAdminKernel impl = new ChainlinkToAdminKernel(_constructionParams(plumbing, address(trancheAsset)));
        bytes memory initData = abi.encodeCall(
            impl.initialize,
            (
                _standardInitParams(),
                ChainlinkToAdminKernel.KernelSpecificInitParams({
                    stAndJTQuoterParams: IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter.ST_JT_QuoterSpecificParams({
                        initialConversionRateWAD: _adminRateWAD,
                        trancheAssetToReferenceAssetOracle: address(feed),
                        gracePeriodSeconds: 0,
                        sequencerUptimeFeed: address(0),
                        stalenessThresholdSeconds: STALENESS_THRESHOLD_SECONDS
                    }),
                    ltQuoterParams: BalancerV3_LT_BPTOracle_Quoter.LT_QuoterSpecificParams({
                        bptOracle: address(plumbing.bptOracle), maxReinvestmentSlippageWAD: 0
                    })
                })
            )
        );
        vm.prank(plumbing.kernelProxyDeployer);
        kernel = ChainlinkToAdminKernel(address(new ERC1967Proxy(address(impl), initData)));
        require(address(kernel) == plumbing.predictedKernel, "chainlink kernel proxy address prediction failed");
    }

    /**
     * @notice Deploys the shipped share-price-to-Chainlink kernel in admin-primary mode (a null second-hop oracle
     *         priced entirely through a nonzero stored rate) over a fresh 18-decimal vault share (6-decimal
     *         underlying) whose assets-per-share rate is pinned to the fuzzed value
     * @dev The 18/6 decimal split makes the quoter's convertToAssets probe amount (1e30 shares) differ from WAD, so
     *      the scale-factor cancellation on the first hop is genuinely exercised rather than trivially 1e18/1e18.
     *      The initializer stores the rate before wiring the oracle, so the nonzero rate is exactly what lets the
     *      null oracle through the Chainlink base's NULL_ORACLE_WITHOUT_STORED_RATE gate
     * @param _vaultRateWAD The vault's assets-per-share rate, WAD-normalized (the tranche-share-to-base-asset price)
     * @param _adminRateWAD The admin oracle's base-asset-to-NAV rate, WAD-scaled (nonzero, admin-primary mandates a stored rate)
     * @return kernel The initialized kernel proxy exposing the quoter's conversion surface
     */
    function _deployERC4626ToAdminKernel(uint256 _vaultRateWAD, uint256 _adminRateWAD) internal returns (ERC4626ToAdminKernel kernel) {
        MockERC20C underlying = new MockERC20C("Vault Underlying", "UNDR", 6);
        // The shared vault share doubles as BOTH tranche assets (the quoter family mandates identical ST/JT assets)
        MockERC4626C vaultShare = new MockERC4626C(address(underlying), "ST/JT Vault Share", "vSHARE", 18);
        vaultShare.setRate(_vaultRateWAD);
        MarketPlumbing memory plumbing = _deployPlumbing(address(vaultShare), "ERC4626_KERNEL_DEPLOYER");

        ERC4626ToAdminKernel impl = new ERC4626ToAdminKernel(_constructionParams(plumbing, address(vaultShare)));
        bytes memory initData = abi.encodeCall(
            impl.initialize,
            (
                _standardInitParams(),
                ERC4626ToAdminKernel.KernelSpecificInitParams({
                    stAndJTQuoterParams: IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter.ST_JT_QuoterSpecificParams({
                        initialConversionRateWAD: _adminRateWAD,
                        baseAssetToNavAssetOracle: address(0),
                        stalenessThresholdSeconds: 0,
                        sequencerUptimeFeed: address(0),
                        gracePeriodSeconds: 0
                    }),
                    ltQuoterParams: BalancerV3_LT_BPTOracle_Quoter.LT_QuoterSpecificParams({
                        bptOracle: address(plumbing.bptOracle), maxReinvestmentSlippageWAD: 0
                    })
                })
            )
        );
        vm.prank(plumbing.kernelProxyDeployer);
        kernel = ERC4626ToAdminKernel(address(new ERC1967Proxy(address(impl), initData)));
        require(address(kernel) == plumbing.predictedKernel, "erc4626 kernel proxy address prediction failed");
    }

    /**
     * @notice Deploys the venue, tranche, and accountant plumbing one kernel needs, bound to a predicted kernel address
     * @dev The pool must be registered before the kernel implementation is constructed (the LT quoter's constructor
     *      validates the registration), and each kernel gets its own dedicated proxy deployer so the address
     *      prediction is independent of how many kernels a single fuzz run deploys
     * @param _stJtAsset The shared senior/junior tranche asset
     * @param _deployerLabel A per-kernel label for the dedicated proxy deployer
     * @return plumbing The deployed components and the predicted kernel address
     */
    function _deployPlumbing(address _stJtAsset, string memory _deployerLabel) internal returns (MarketPlumbing memory plumbing) {
        // Liquidity venue wiring: the LT quoter's constructor demands a registered two-token pool pairing the
        // senior tranche, and its initializer demands an oracle attesting to that exact pool
        plumbing.balancerVault = new MockBalancerVault();
        plumbing.bpt = new MockBPT(IVault(address(plumbing.balancerVault)), "Royco BPT", "rBPT");
        plumbing.bptOracle = new MockBPTOracle(plumbing.balancerVault, address(plumbing.bpt));
        MockERC20C quoteToken = new MockERC20C("Quote Stable", "QUOTE", 6);

        // Predict the kernel proxy address so the tranche implementations can bake it into their immutables
        plumbing.kernelProxyDeployer = makeAddr(_deployerLabel);
        plumbing.predictedKernel = vm.computeCreateAddress(plumbing.kernelProxyDeployer, vm.getNonce(plumbing.kernelProxyDeployer));

        plumbing.seniorTranche = address(new RoycoSeniorTranche(_stJtAsset, plumbing.predictedKernel));
        plumbing.juniorTranche = address(new RoycoJuniorTranche(_stJtAsset, plumbing.predictedKernel));
        plumbing.liquidityTranche = address(new RoycoLiquidityTranche(address(plumbing.bpt), plumbing.predictedKernel));
        // Identical ST/JT assets force the co-invested junior configuration at kernel construction
        plumbing.accountant = address(new RoycoDayAccountant(plumbing.predictedKernel, true));

        plumbing.balancerVault.registerPool(address(plumbing.bpt), [IERC20(plumbing.seniorTranche), IERC20(address(quoteToken))]);
    }

    /// @notice Builds the kernel construction params over the deployed plumbing and the shared ST/JT asset
    /// @param _plumbing The deployed market plumbing
    /// @param _stJtAsset The shared senior/junior tranche asset
    function _constructionParams(
        MarketPlumbing memory _plumbing,
        address _stJtAsset
    )
        internal
        pure
        returns (IRoycoDayKernel.RoycoDayKernelConstructionParams memory)
    {
        return IRoycoDayKernel.RoycoDayKernelConstructionParams({
            seniorTranche: _plumbing.seniorTranche,
            stAsset: _stJtAsset,
            juniorTranche: _plumbing.juniorTranche,
            jtAsset: _stJtAsset,
            accountant: _plumbing.accountant,
            liquidityTranche: _plumbing.liquidityTranche,
            ltAsset: address(_plumbing.bpt),
            enforceVaultSharesTransferWhitelist: false
        });
    }

    /// @notice Builds the standard kernel init params against the test-admin'd access manager
    function _standardInitParams() internal returns (IRoycoDayKernel.RoycoDayKernelInitParams memory) {
        return IRoycoDayKernel.RoycoDayKernelInitParams({
            initialAuthority: address(accessManager),
            protocolFeeRecipient: makeAddr("PROTOCOL_FEE_RECIPIENT"),
            stSelfLiquidationBonusWAD: 0,
            roycoBlacklist: address(0)
        });
    }
}
