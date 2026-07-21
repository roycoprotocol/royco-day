// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { UUPSUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC20BurnableUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import { AccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { ERC1967Proxy } from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { RoycoDayAccountant } from "../../src/accountant/RoycoDayAccountant.sol";
import {
    ADMIN_ACCOUNTANT_ROLE,
    ADMIN_KERNEL_ROLE,
    ADMIN_MARKET_OPS_ROLE,
    ADMIN_MARKET_REINVEST_LIQUIDITY_PREMIUM_ROLE,
    ADMIN_ORACLE_QUOTER_ROLE,
    ADMIN_PAUSER_ROLE,
    ADMIN_PROTOCOL_FEE_SETTER_ROLE,
    ADMIN_UNPAUSER_ROLE,
    ADMIN_UPGRADER_ROLE,
    BURNER_ROLE,
    JT_LP_ROLE,
    LT_LP_ROLE,
    ST_LP_ROLE,
    SYNC_ROLE
} from "../../src/factory/Roles.sol";
import { IRoycoAuth } from "../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayAccountant } from "../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../src/interfaces/IRoycoVaultTranche.sol";
import { IYDM } from "../../src/interfaces/IYDM.sol";
import {
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel as DayKernel
} from "../../src/kernels/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel.sol";
import {
    IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter
} from "../../src/kernels/base/quoter/identical-st-jt/IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter.sol";
import {
    IdenticalAssets_ST_JT_ChainlinkOracle_Quoter
} from "../../src/kernels/base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.sol";
import { IdenticalAssets_ST_JT_Oracle_Quoter } from "../../src/kernels/base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_Oracle_Quoter.sol";
import { BalancerV3_LT_BPTOracle_Quoter } from "../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_BPTOracle_Quoter.sol";
import { WAD } from "../../src/libraries/Constants.sol";
import { SyncedAccountingState } from "../../src/libraries/Types.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../src/libraries/Units.sol";
import { RoycoJuniorTranche } from "../../src/tranches/RoycoJuniorTranche.sol";
import { RoycoLiquidityTranche } from "../../src/tranches/RoycoLiquidityTranche.sol";
import { RoycoSeniorTranche } from "../../src/tranches/RoycoSeniorTranche.sol";
import { AdaptiveCurveYDM_V2 } from "../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { StaticCurveYDM } from "../../src/ydm/StaticCurveYDM.sol";
import { MockAggregatorV3 } from "../mocks/MockAggregatorV3.sol";
import { MockBPT } from "../mocks/MockBPT.sol";
import { MockBPTOracle } from "../mocks/MockBPTOracle.sol";
import { MockBalancerVault } from "../mocks/MockBalancerVault.sol";
import { MockERC20C } from "../mocks/MockERC20C.sol";
import { MockERC4626C } from "../mocks/MockERC4626C.sol";
import { MockYDM } from "../mocks/MockYDM.sol";
import { Assertions } from "./Assertions.sol";
import { FixtureCell, MarketParamsConfig, TokenConfig } from "./FixtureTypes.sol";

/**
 * @title DayMarketTestBase
 * @notice The single parameterized market fixture every mock-market test layer inherits
 * @dev Deploys a full Day market — tokens per FixtureCell, mocks for every external surface, the five contracts
 *      (ST, JT, LT, kernel, accountant) behind ERC1967 proxies, and production-shaped role bindings mirroring
 *      BalancerV3_GyroECLP_LT_DeploymentTemplate._buildRoleBindings minus the Balancer-governance targets
 * @dev PnL injection mutates mock rates and oracle answers, never `deal`, so PnL flows through the same quoter
 *      paths production uses. applySTPnL and applyJTPnL are documented aliases over the SHARED ERC4626 rate:
 *      this kernel family prices ST and JT off one vault share rate, so single-tranche PnL isolation is
 *      impossible at the kernel layer and independent (stRawNAV, jtRawNAV) tuples are driven at the mock-kernel
 *      accountant layer (AccountantTestBase)
 */
abstract contract DayMarketTestBase is Assertions {
    using Math for uint256;

    // =============================
    // Constants
    // =============================

    /// @dev Chainlink price staleness threshold wired into the kernel's ST/JT quoter at initialization
    uint48 internal constant ORACLE_STALENESS_THRESHOLD_SECONDS = 1 days;

    /// @dev Sequencer grace period wired into the kernel's ST/JT quoter at initialization
    uint48 internal constant ORACLE_GRACE_PERIOD_SECONDS = 1 hours;

    /// @dev The price feed's oracle decimals
    uint8 internal constant PRICE_FEED_DECIMALS = 8;

    /// @dev The price feed's initial answer (1.0 at 8 decimals, base asset pegged to the NAV asset)
    int256 internal constant PRICE_FEED_INITIAL_ANSWER = 1e8;

    /// @dev Oracle failure modes accepted by setOracleMode
    uint8 internal constant ORACLE_MODE_NONE = 0;
    uint8 internal constant ORACLE_MODE_STALE = 1;
    uint8 internal constant ORACLE_MODE_NEGATIVE = 2;
    uint8 internal constant ORACLE_MODE_ZERO = 3;
    uint8 internal constant ORACLE_MODE_REVERT = 4;

    /// @dev The unbalanced-add haircut armed by setVenueSlippageMode(true), 50% so the reinvest gate always fails
    uint16 internal constant VENUE_SLIPPAGE_MODE_FEE_BPS = 5000;

    // =============================
    // Fixture Configuration
    // =============================

    /// @notice The token shape (FixtureCell, built in TokenConfigs.sol) this market was deployed with
    FixtureCell internal cell;

    /// @notice The market parameterization this market was deployed with
    MarketParamsConfig internal params;

    // =============================
    // Token Handles
    // =============================

    /// @notice The quote stable paired against the senior tranche share in the LT pool
    MockERC20C internal quoteToken;

    /// @notice The underlying of the shared ST/JT ERC4626 vault
    MockERC20C internal stJtUnderlying;

    /**
     * @notice The single ERC4626 vault share serving as BOTH the ST and JT asset
     * @dev The shipped quoter family requires ST_ASSET == JT_ASSET (IdenticalAssets_ST_JT_Oracle_Quoter.sol,
     *      TRANCHE_ASSETS_MUST_BE_IDENTICAL), so one instance backs both tranches and its rate is the shared PnL feed
     */
    MockERC4626C internal stJtVault;

    // =============================
    // Oracle and Venue Handles
    // =============================

    /// @notice The base-asset-to-NAV-asset Chainlink-shaped price feed consumed by the ST/JT quoter
    MockAggregatorV3 internal priceFeed;

    /// @notice A spare sequencer-uptime feed handle, NOT wired at init (the quoter skips sequencer checks for address(0))
    /// @dev Wire it later through the kernel's setSequencerUptimeFeed via ORACLE_QUOTER_ADMIN
    MockAggregatorV3 internal sequencerFeed;

    /// @notice The mock Balancer V3 vault backing the LT venue
    MockBalancerVault internal balancerVault;

    /// @notice The mock BPT (the LT asset), its ledger lives in the mock vault
    MockBPT internal bpt;

    /// @notice The BPT oracle satisfying LPOracleBase.computeTVL, AUTO mode by default
    MockBPTOracle internal bptOracle;

    /**
     * @notice The senior tranche share's index in the pool's token registration order (the quote asset is at 1 - this)
     * @dev Production Balancer registers pool tokens sorted ascending by address, so the senior tranche is NOT
     *      guaranteed index 0, this fixture mirrors that sort and records where the senior share landed
     */
    uint256 internal stPoolTokenIndex;

    // =============================
    // YDM Handles
    // =============================

    /// @notice The junior tranche's YDM (cast to MockYDM / StaticCurveYDM / AdaptiveCurveYDM_V2 per params.jtYdmKind)
    IYDM internal jtYdm;

    /// @notice The liquidity tranche's YDM, always a distinct instance from jtYdm
    IYDM internal ltYdm;

    // =============================
    // Market Handles
    // =============================

    /// @notice The market's access manager, admin'd by this fixture contract
    AccessManager internal accessManager;

    /// @notice The senior tranche proxy
    RoycoSeniorTranche internal seniorTranche;

    /// @notice The junior tranche proxy
    RoycoJuniorTranche internal juniorTranche;

    /// @notice The liquidity tranche proxy
    RoycoLiquidityTranche internal liquidityTranche;

    /// @notice The accountant proxy
    RoycoDayAccountant internal accountant;

    /// @notice The kernel proxy
    DayKernel internal kernel;

    /// @notice The EOA that deploys the kernel proxy so its address is CREATE-predictable for the impl constructors
    address internal kernelProxyDeployer;

    // =============================
    // Role Wallets and Actors
    // =============================

    address internal PAUSER;
    address internal UNPAUSER;
    address internal UPGRADER;
    address internal SYNC_OPERATOR;
    address internal KERNEL_ADMIN;
    address internal MARKET_OPS_ADMIN;
    address internal ACCOUNTANT_ADMIN;
    address internal PROTOCOL_FEE_SETTER;
    address internal ORACLE_QUOTER_ADMIN;
    address internal MARKET_REINVEST_LIQUIDITY_PREMIUM_ADMIN;
    address internal PROTOCOL_FEE_RECIPIENT;

    /// @notice Default LP actors, one per tranche
    address internal ST_PROVIDER;
    address internal JT_PROVIDER;
    address internal LT_PROVIDER;

    // =============================
    // Internal Fixture State
    // =============================

    /// @dev The last positive price-feed answer, restored when setOracleMode returns to NONE
    int256 internal lastHealthyOracleAnswer = PRICE_FEED_INITIAL_ANSWER;

    // =============================
    // Deployment
    // =============================

    /**
     * @notice Deploys the full Day market for the specified token shape and parameterization
     * @dev Mirrors BalancerV3_GyroECLP_LT_DeploymentTemplate.deployMarket's order, adapted to mocks: tokens, oracles, venue, YDMs,
     *      predicted kernel address, impls, tranche and accountant proxies, pool registration, kernel impl (its
     *      constructor validates the registered pool), kernel proxy at the
     *      predicted address, then role bindings and grants
     * @param _cell The token shape (FixtureCell) to deploy
     * @param _params The market parameterization to deploy
     */
    function _deployMarket(FixtureCell memory _cell, MarketParamsConfig memory _params) internal virtual {
        // The kernel family requires identical ST/JT assets, which the kernel constructor enforces
        _validateFixtureCell(_cell);

        cell = _cell;
        params = _params;

        // 1. Access manager, admin'd by the fixture so role wiring needs no schedule/execute dance
        accessManager = new AccessManager(address(this));
        vm.label(address(accessManager), "AccessManager");

        // 2. Tokens: quote stable + ONE ERC4626 vault share over a mock underlying for both ST and JT
        quoteToken = _deployERC20("Quote Stable", "QUOTE", _cell.quoteAsset);
        stJtUnderlying = _deployERC20("ST/JT Underlying", "UNDR", _toUnderlyingConfig(_cell.stAsset));
        stJtVault = new MockERC4626C(address(stJtUnderlying), "ST/JT Vault Share", "vSHARE", _cell.stAsset.decimals);
        stJtVault.setRate(_cell.stAsset.initialRateWAD);
        vm.label(address(stJtVault), "MockERC4626C_STJT");

        // 3. Oracles: price feed at 1.0, plus a spare sequencer feed handle (sequencer checks are skipped at init)
        priceFeed = new MockAggregatorV3(PRICE_FEED_DECIMALS, PRICE_FEED_INITIAL_ANSWER);
        sequencerFeed = new MockAggregatorV3(0, 0);
        lastHealthyOracleAnswer = PRICE_FEED_INITIAL_ANSWER;
        vm.label(address(priceFeed), "MockPriceFeed");
        vm.label(address(sequencerFeed), "MockSequencerFeed");

        // 4. Venue: mock Balancer vault, the BPT it ledgers, and the BPT oracle (AUTO mode default)
        balancerVault = new MockBalancerVault();
        bpt = new MockBPT(IVault(address(balancerVault)), "Royco BPT", "rBPT");
        bptOracle = new MockBPTOracle(balancerVault, address(bpt));
        vm.label(address(balancerVault), "MockBalancerVault");
        vm.label(address(bpt), "MockBPT");
        vm.label(address(bptOracle), "MockBPTOracle");

        // 5. YDMs: always two distinct instances (the accountant reverts YDMS_CANNOT_BE_IDENTICAL)
        bytes memory jtYdmInitData;
        bytes memory ltYdmInitData;
        (jtYdm, jtYdmInitData) = _deployYDM("JT_YDM", _params.jtYdmKind, _params.jtCurve, _params.targetUtilizationWAD);
        (ltYdm, ltYdmInitData) = _deployYDM("LT_YDM", _params.ltYdmKind, _params.ltCurve, _params.targetUtilizationWAD);

        // 6. Predict the kernel proxy address so the tranche and accountant impls can bake it into their immutables
        kernelProxyDeployer = makeAddr("KERNEL_PROXY_DEPLOYER");
        address predictedKernel = vm.computeCreateAddress(kernelProxyDeployer, vm.getNonce(kernelProxyDeployer));

        // 7. Impls with the predicted kernel address
        RoycoSeniorTranche stImpl = new RoycoSeniorTranche(address(stJtVault), predictedKernel);
        RoycoJuniorTranche jtImpl = new RoycoJuniorTranche(address(stJtVault), predictedKernel);
        RoycoLiquidityTranche ltImpl = new RoycoLiquidityTranche(address(bpt), predictedKernel);
        RoycoDayAccountant accImpl = new RoycoDayAccountant(predictedKernel);

        // 8. Tranche and accountant proxies MUST exist before the kernel impl (its initialize calls tranche.asset())
        seniorTranche = RoycoSeniorTranche(_deployTrancheProxy(address(stImpl), "Royco Senior Tranche", "RST"));
        juniorTranche = RoycoJuniorTranche(_deployTrancheProxy(address(jtImpl), "Royco Junior Tranche", "RJT"));
        liquidityTranche = RoycoLiquidityTranche(_deployTrancheProxy(address(ltImpl), "Royco Liquidity Tranche", "RLT"));
        vm.label(address(seniorTranche), "ST");
        vm.label(address(juniorTranche), "JT");
        vm.label(address(liquidityTranche), "LT");

        accountant = RoycoDayAccountant(
            address(
                new ERC1967Proxy(
                    address(accImpl),
                    abi.encodeCall(RoycoDayAccountant.initialize, (_buildAccountantInitParams(_params, jtYdmInitData, ltYdmInitData), address(accessManager)))
                )
            )
        );
        vm.label(address(accountant), "Accountant");

        // 9. Register the pool BEFORE kernel impl construction (the LT quoter constructor validates the registration
        //    and that the pool pairs the senior tranche, BalancerV3_LT_BPTOracle_Quoter.sol:89-107).
        //    Production Balancer registers pool tokens sorted ascending by address (InputHelpers.ensureSortedTokens),
        //    so the senior tranche can land at index 1 and the quoter's tokens[1] == SENIOR_TRANCHE branch is real
        bool stSortsFirst = address(seniorTranche) < address(quoteToken);
        stPoolTokenIndex = stSortsFirst ? 0 : 1;
        IERC20[2] memory poolTokens =
            stSortsFirst ? [IERC20(address(seniorTranche)), IERC20(address(quoteToken))] : [IERC20(address(quoteToken)), IERC20(address(seniorTranche))];
        balancerVault.registerPool(address(bpt), poolTokens);
        // Documenting assertion: the recorded index must resolve the senior share in the registered order. Under
        // the deterministic forge test deployer every standard token shape (A-D) sorts the quote token below the
        // tranche proxies, so ST lands at index 1 and the quoter constructor's tokens[1] == SENIOR_TRANCHE branch
        // (BalancerV3_LT_BPTOracle_Quoter.sol:103) is exercised by every market lifecycle suite, not forced artificially
        require(
            address(balancerVault.getPoolTokens(address(bpt))[stPoolTokenIndex]) == address(seniorTranche),
            "DayMarketTestBase: recorded senior pool index does not match the registered token order"
        );
        _initializePoolMinimumSupply();

        // 10. Kernel impl (constructor resolves the vault via BalancerPoolToken(ltAsset).getVault())
        DayKernel kernelImpl = new DayKernel(
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

        // 11. Protocol fee recipient wallet must exist before kernel init consumes it
        PROTOCOL_FEE_RECIPIENT = makeAddr("PROTOCOL_FEE_RECIPIENT");

        // 12. Kernel proxy from the dedicated deployer so it lands at the predicted address
        bytes memory kernelInitData = abi.encodeCall(
            kernelImpl.initialize,
            (
                IRoycoDayKernel.RoycoDayKernelInitParams({
                    initialAuthority: address(accessManager),
                    protocolFeeRecipient: PROTOCOL_FEE_RECIPIENT,
                    stSelfLiquidationBonusWAD: _params.stSelfLiquidationBonusWAD,
                    roycoBlacklist: address(0)
                }),
                DayKernel.KernelSpecificInitParams({
                    stAndJTQuoterParams: IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter.ST_JT_QuoterSpecificParams({
                        initialConversionRateWAD: 0,
                        baseAssetToNavAssetOracle: address(priceFeed),
                        stalenessThresholdSeconds: ORACLE_STALENESS_THRESHOLD_SECONDS,
                        sequencerUptimeFeed: address(0),
                        gracePeriodSeconds: ORACLE_GRACE_PERIOD_SECONDS
                    }),
                    ltQuoterParams: BalancerV3_LT_BPTOracle_Quoter.LT_QuoterSpecificParams({
                        bptOracle: address(bptOracle), maxReinvestmentSlippageWAD: _params.maxReinvestmentSlippageWAD
                    })
                })
            )
        );
        vm.prank(kernelProxyDeployer);
        address kernelProxy = address(new ERC1967Proxy(address(kernelImpl), kernelInitData));
        require(kernelProxy == predictedKernel, "DayMarketTestBase: kernel proxy address prediction failed");
        kernel = DayKernel(kernelProxy);
        vm.label(kernelProxy, "Kernel");

        // 13. Wire the kernel as the senior leg's live rate provider in BOTH price stores, mirroring production:
        //     the E-CLP prices its rate-scaled ST-share leg through IRateProvider.getRate (the kernel) read live on
        //     every pool operation, and the E-CLP oracle values that leg through the same provider, so a
        //     mid-transaction rate refresh (the kernel's post-sync senior share rate) reaches the very next add,
        //     remove, and TVL mark exactly as the real pool would see it
        balancerVault.setTokenRateProvider(address(seniorTranche), kernelProxy);
        bptOracle.setTokenRateProvider(address(seniorTranche), kernelProxy);

        // 14. Role bindings and grants, mirroring the production template
        _wireTargetFunctionRoles();
        _wireRoleGrants();
    }

    // =============================
    // PnL Injection (mock rates and oracles, never deal)
    // =============================

    /**
     * @notice Applies senior PnL by accruing the shared ST/JT vault rate
     * @dev SHARED-FEED ALIAS: raw NAVs in this kernel family are ownedAssets x the shared 4626/Chainlink rate, so
     *      this moves ST and JT raw NAV proportionally. Single-tranche isolation is impossible at the kernel layer,
     *      independent (stRawNAV, jtRawNAV) tuples are driven at the mock-kernel accountant layer (AccountantTestBase)
     * @param _bps The signed basis-point move applied to the vault rate
     */
    function applySTPnL(int256 _bps) internal virtual {
        stJtVault.accrue(_bps);
    }

    /// @notice Applies junior PnL, a documented alias of applySTPnL over the shared vault rate (see applySTPnL)
    function applyJTPnL(int256 _bps) internal virtual {
        stJtVault.accrue(_bps);
    }

    /**
     * @notice Applies liquidity tranche PnL by scaling the BPT oracle's value and the vault's fair-value pricing together
     * @dev The two price stores must stay coherent: the oracle backs the kernel's ltRawNAV mark and min-BPT-out floor
     *      while the vault's fair-value pricing decides the BPT an add actually mints, so bumping only one would
     *      manufacture phantom slippage (or phantom surplus) production cannot exhibit. The oracle is bumped first and
     *      its effective quote price is copied into the vault, one store of truth. The senior leg is untouched by
     *      construction, both stores peg it to the kernel's live rate provider, so LT PnL lands on the quote leg only,
     *      exactly as a production rate-scaled leg cannot drift from its rate. In the oracle's MANUAL mode the bump
     *      scales the pinned TVL only and the vault pricing is deliberately left to the test's own control
     */
    function applyLTPnL(int256 _bps) internal virtual {
        bptOracle.bump(_bps);
        balancerVault.setTokenPriceWAD(address(quoteToken), bptOracle.getPriceWAD(address(quoteToken)));
    }

    /// @notice Applies quote-side PnL by scaling the Chainlink price feed answer WITHOUT refreshing its freshness
    function applyQuotePnL(int256 _bps) internal virtual {
        (, int256 answer,,,) = priceFeed.latestRoundData();
        int256 factorWAD = int256(WAD) + _bps * 1e14;
        require(factorWAD > 0, "DayMarketTestBase: quote PnL factor must stay positive");
        int256 newAnswer = (answer * factorWAD) / int256(WAD);
        priceFeed.setAnswer(newAnswer);
        if (newAnswer > 0) lastHealthyOracleAnswer = newAnswer;
    }

    // =============================
    // Venue and Oracle Control
    // =============================

    /**
     * @notice Aligns the mock venue's fair-value pricing and the BPT oracle with the quote-leg feed answer
     * @dev The senior leg needs NO syncing, by construction: the pool tokens are the ST TRANCHE SHARES (not the ST
     *      asset) and both stores price that leg through the kernel's IRateProvider.getRate wired at deployment,
     *      read live on every operation exactly as the production E-CLP and its oracle do, so the senior mark can
     *      never drift from the committed senior share NAV and can never read the raw ST-asset mark. Only the
     *      quote leg is a static snapshot of the Chainlink-shaped feed, re-call this after moving the feed
     * @dev Both stores move together, split stores would manufacture phantom slippage production cannot exhibit
     */
    function syncVenuePrices() internal virtual {
        // Quote leg, the feed answer scaled from oracle decimals to WAD
        (, int256 answer,,,) = priceFeed.latestRoundData();
        require(answer > 0, "DayMarketTestBase: cannot sync venue prices off a non-positive feed answer");
        uint256 quotePriceWAD = uint256(answer) * 10 ** (18 - PRICE_FEED_DECIMALS);
        balancerVault.setTokenPriceWAD(address(quoteToken), quotePriceWAD);
        bptOracle.setPriceWAD(address(quoteToken), quotePriceWAD);
    }

    /// @notice Arms (true) or disarms (false) persistent venue slippage so the kernel's reinvest gate deterministically fails or passes
    function setVenueSlippageMode(bool _reinvestmentsFail) internal virtual {
        balancerVault.setUnbalancedFeeBps(_reinvestmentsFail ? VENUE_SLIPPAGE_MODE_FEE_BPS : 0);
    }

    /**
     * @notice Drives the price feed into an oracle failure mode
     * @dev Modes: 0 NONE restores a healthy fresh feed, 1 STALE warps past the staleness threshold WITHOUT
     *      refreshing updatedAt, 2 NEGATIVE and 3 ZERO poison the answer, 4 REVERT arms revert mode
     * @param _mode The ORACLE_MODE_* constant to apply
     */
    function setOracleMode(uint8 _mode) internal virtual {
        if (_mode == ORACLE_MODE_NONE) {
            priceFeed.setRevertMode(false);
            (, int256 answer,,,) = priceFeed.latestRoundData();
            if (answer <= 0) priceFeed.setAnswer(lastHealthyOracleAnswer);
            priceFeed.setUpdatedAt(block.timestamp);
        } else if (_mode == ORACLE_MODE_STALE) {
            vm.warp(block.timestamp + ORACLE_STALENESS_THRESHOLD_SECONDS + 1);
        } else if (_mode == ORACLE_MODE_NEGATIVE) {
            priceFeed.setAnswer(-1);
        } else if (_mode == ORACLE_MODE_ZERO) {
            priceFeed.setAnswer(0);
        } else if (_mode == ORACLE_MODE_REVERT) {
            priceFeed.setRevertMode(true);
        } else {
            revert("DayMarketTestBase: unknown oracle mode");
        }
    }

    /// @notice Warps forward and refreshes the price feed's updatedAt so time passes without tripping the staleness gate
    function _warpAndRefreshFeed(uint256 _secs) internal virtual {
        vm.warp(block.timestamp + _secs);
        priceFeed.setUpdatedAt(block.timestamp);
    }

    // =============================
    // Seed Helpers
    // =============================

    /**
     * @notice Seeds the ST and JT tranches through the production deposit paths
     * @dev Deposits JT first: senior deposits are coverage-gated on existing junior NAV, so a JT-less market
     *      rejects ST deposits. Amounts are denominated in shared vault-share tranche units
     * @dev PRODUCTION CONSTRAINT: ST deposits are ALSO liquidity-gated (RoycoDayAccountant.sol:332-334), and a
     *      market with positive minLiquidity and zero LT depth reads liquidityUtilization as type(uint256).max
     *      (UtilizationLogic.sol:72), so no ST deposit can ever land first. When needed, this helper auto-seeds
     *      the minimal quote-only LT depth that satisfies the requirement before the ST deposit. Tests that need
     *      an exact LT composition must call _seedLT explicitly before this
     * @param _stAssets The vault shares ST_PROVIDER deposits into the senior tranche
     * @param _jtAssets The vault shares JT_PROVIDER deposits into the junior tranche
     */
    function _seedMarket(uint256 _stAssets, uint256 _jtAssets) internal virtual {
        if (_jtAssets != 0) {
            stJtVault.mintShares(JT_PROVIDER, _jtAssets);
            vm.startPrank(JT_PROVIDER);
            stJtVault.approve(address(juniorTranche), _jtAssets);
            juniorTranche.deposit(toTrancheUnits(_jtAssets), JT_PROVIDER);
            vm.stopPrank();
        }
        if (_stAssets != 0) {
            _ensureLiquidityCapacityForSTDeposit(_stAssets);
            stJtVault.mintShares(ST_PROVIDER, _stAssets);
            vm.startPrank(ST_PROVIDER);
            stJtVault.approve(address(seniorTranche), _stAssets);
            seniorTranche.deposit(toTrancheUnits(_stAssets), ST_PROVIDER);
            vm.stopPrank();
        }
    }

    /**
     * @notice Auto-seeds the minimal quote-only LT depth an ST deposit needs to clear the liquidity requirement
     * @dev Computes the post-deposit senior effective NAV, derives the required ltRawNAV from minLiquidity, and
     *      seeds the deficit as a quote-only pool leg (no senior leg needed, which also breaks the circularity of
     *      ST deposits needing LT depth while the LT senior leg needs ST shares). One whole quote unit of cushion
     *      absorbs the utilization computation's ceil rounding
     * @param _stAssets The vault shares about to be deposited into the senior tranche
     */
    function _ensureLiquidityCapacityForSTDeposit(uint256 _stAssets) internal virtual {
        uint256 minLiquidityWAD = params.minLiquidityWAD;
        if (minLiquidityWAD == 0) return;

        uint256 stEffAfter = toUint256(seniorTranche.totalAssets().nav) + toUint256(kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(_stAssets)));
        uint256 requiredLtRawNAV = stEffAfter.mulDiv(minLiquidityWAD, WAD, Math.Rounding.Ceil);
        uint256 currentLtRawNAV = toUint256(liquidityTranche.getRawNAV());
        if (currentLtRawNAV >= requiredLtRawNAV) return;

        uint256 quoteUnit = 10 ** uint256(cell.quoteAsset.decimals);
        uint256 deficitNAV = requiredLtRawNAV - currentLtRawNAV;
        uint256 quoteLeg = deficitNAV.mulDiv(quoteUnit, WAD, Math.Rounding.Ceil) + quoteUnit;
        // BPT is minted 1:1 with the 18-decimal NAV added so the pool's NAV-per-BPT stays at 1.0
        _seedLT(quoteLeg.mulDiv(WAD, quoteUnit, Math.Rounding.Floor), 0, quoteLeg);
    }

    /**
     * @notice Backs the pool's dead minimum BPT supply at genesis so NAV-per-BPT starts at exactly 1.0
     * @dev The mock vault's first mint locks POOL_MINIMUM_TOTAL_SUPPLY dead BPT at address(0), mirroring the real
     *      vault's initialization. Production initializers pay for those dead shares out of their own mint, so this
     *      fixture plays the initializer: it seeds the smallest whole-quote-wei value covering the dead shares and
     *      keeps only the surplus BPT, leaving total supply == pool value (NAV-per-BPT exactly 1.0). Later seeds
     *      that mint BPT 1:1 with the NAV they add therefore keep every hand-derived LT mark wei-exact
     */
    function _initializePoolMinimumSupply() internal virtual {
        uint256 quoteUnit = 10 ** uint256(cell.quoteAsset.decimals);
        uint256 minSupply = balancerVault.POOL_MINIMUM_TOTAL_SUPPLY();
        // The smallest quote-wei amount whose WAD value covers the dead shares (>= 1 wei so the seed is nonempty)
        uint256 genesisQuoteWei = Math.max(1, minSupply.mulDiv(quoteUnit, WAD, Math.Rounding.Ceil));
        // Exact because 10^quoteDecimals divides WAD for quoteDecimals <= 18
        uint256 genesisValueWAD = genesisQuoteWei.mulDiv(WAD, quoteUnit, Math.Rounding.Floor);

        quoteToken.mint(address(this), genesisQuoteWei);
        quoteToken.approve(address(balancerVault), genesisQuoteWei);
        uint256[2] memory legs;
        legs[1 - stPoolTokenIndex] = genesisQuoteWei;
        // The vault adds minSupply dead BPT on this first mint, so total supply lands at exactly genesisValueWAD
        balancerVault.mintPoolTokensTo(address(bpt), makeAddr("POOL_GENESIS_LP"), genesisValueWAD - minSupply, legs);
    }

    /**
     * @notice Seeds LT depth: mints BPT against real pool legs and deposits it through the production LT deposit path
     * @dev The senior leg is acquired through the senior tranche's own deposit path (the only mint path for tranche
     *      shares), so the market must already carry JT coverage headroom (_seedMarket first). The fixture funds both
     *      legs, mints the BPT to LT_PROVIDER via the vault's external-LP helper, and LT_PROVIDER deposits it
     * @param _bptAmount The BPT amount minted and deposited into the liquidity tranche
     * @param _stLeg The senior tranche shares placed in the pool
     * @param _quoteLeg The quote assets placed in the pool
     */
    function _seedLT(uint256 _bptAmount, uint256 _stLeg, uint256 _quoteLeg) internal virtual {
        if (_stLeg != 0) {
            _acquireSTShares(_stLeg);
            seniorTranche.approve(address(balancerVault), _stLeg);
        }
        if (_quoteLeg != 0) {
            quoteToken.mint(address(this), _quoteLeg);
            quoteToken.approve(address(balancerVault), _quoteLeg);
        }
        // The pool's token amounts follow the sorted registration order, so map the legs through the recorded index
        uint256[2] memory legs;
        legs[stPoolTokenIndex] = _stLeg;
        legs[1 - stPoolTokenIndex] = _quoteLeg;
        balancerVault.mintPoolTokensTo(address(bpt), LT_PROVIDER, _bptAmount, legs);

        vm.startPrank(LT_PROVIDER);
        bpt.approve(address(liquidityTranche), _bptAmount);
        liquidityTranche.deposit(toTrancheUnits(_bptAmount), LT_PROVIDER);
        vm.stopPrank();
    }

    /**
     * @notice Acquires at least _shares senior tranche shares for the fixture through the production deposit path
     * @dev Sizes the vault-share deposit from the current effective NAV per share with a one-unit cushion for the
     *      quoter's floor rounding, then verifies the mint covered the request
     * @param _shares The senior tranche shares the fixture must end up holding
     */
    function _acquireSTShares(uint256 _shares) internal virtual {
        uint256 supply = seniorTranche.totalSupply();
        // NAV needed so the floor-rounded share mint still covers _shares (initial mint is 1 share-wei per NAV-wei)
        uint256 navNeeded;
        if (supply == 0) navNeeded = _shares;
        else navNeeded = _shares.mulDiv(toUint256(seniorTranche.totalAssets().nav), supply, Math.Rounding.Ceil);

        uint256 vaultShares = toUint256(kernel.stConvertNAVUnitsToTrancheUnits(toNAVUnits(navNeeded))) + 1;
        // This deposit is itself liquidity-gated, top up quote-only depth first (never recurses, the auto-seed leg has no senior side)
        _ensureLiquidityCapacityForSTDeposit(vaultShares);
        uint256 balanceBefore = seniorTranche.balanceOf(address(this));
        stJtVault.mintShares(address(this), vaultShares);
        stJtVault.approve(address(seniorTranche), vaultShares);
        seniorTranche.deposit(toTrancheUnits(vaultShares), address(this));
        require(seniorTranche.balanceOf(address(this)) - balanceBefore >= _shares, "DayMarketTestBase: ST share acquisition undershoot");
    }

    // =============================
    // Actor and Sync Helpers
    // =============================

    /// @notice Creates a labeled, funded actor and grants it the specified role at zero execution delay
    function _generateActor(string memory _name, uint64 _roleId) internal virtual returns (address actor) {
        actor = makeAddr(_name);
        vm.deal(actor, 100 ether);
        accessManager.grantRole(_roleId, actor, 0);
    }

    /// @notice Syncs the market's accounting as the SYNC_OPERATOR
    function _sync() internal virtual returns (SyncedAccountingState memory state) {
        vm.prank(SYNC_OPERATOR);
        state = kernel.syncTrancheAccounting();
    }

    // =============================
    // Internal Deployment Logic
    // =============================

    /// @notice Validates the token shape satisfies the kernel family's structural constraints
    function _validateFixtureCell(FixtureCell memory _cell) internal pure {
        require(_cell.stAsset.erc4626 && _cell.jtAsset.erc4626, "DayMarketTestBase: ST/JT assets must be ERC4626 vault shares for this kernel family");
        require(!_cell.quoteAsset.erc4626, "DayMarketTestBase: the quote asset must be a plain ERC20");
        require(
            _cell.stAsset.decimals == _cell.jtAsset.decimals && _cell.stAsset.underlyingDecimals == _cell.jtAsset.underlyingDecimals
                && _cell.stAsset.initialRateWAD == _cell.jtAsset.initialRateWAD && _cell.stAsset.behaviors == _cell.jtAsset.behaviors
                && _cell.stAsset.feeBps == _cell.jtAsset.feeBps,
            "DayMarketTestBase: ST and JT token configs must be identical (one shared vault instance)"
        );
    }

    /// @notice Deploys a configurable ERC20 and applies the token config's behavior bitmap and fee
    function _deployERC20(string memory _name, string memory _symbol, TokenConfig memory _config) internal returns (MockERC20C token) {
        token = new MockERC20C(_name, _symbol, _config.decimals);
        if (_config.behaviors != 0) token.setBehaviors(_config.behaviors);
        if (_config.feeBps != 0) token.setFeeBps(_config.feeBps);
        vm.label(address(token), string.concat("MockERC20C_", _symbol));
    }

    /// @notice Projects a 4626 token config onto its underlying's plain-ERC20 config (behaviors live on the underlying)
    function _toUnderlyingConfig(TokenConfig memory _vaultConfig) internal pure returns (TokenConfig memory) {
        return TokenConfig({
            decimals: _vaultConfig.underlyingDecimals,
            behaviors: _vaultConfig.behaviors,
            feeBps: _vaultConfig.feeBps,
            erc4626: false,
            underlyingDecimals: 0,
            initialRateWAD: 0
        });
    }

    /**
     * @notice Deploys one YDM instance per the configured kind
     * @dev Kind 0 is a MockYDM initialized with empty data whose global default share is pinned to the curve's
     *      target value, so kinds 0/1/2 agree at target utilization. Kinds 1/2 return the production
     *      initializeYDMForMarket calldata the accountant raw-calls at initialization
     */
    function _deployYDM(
        string memory _label,
        uint8 _kind,
        uint64[3] memory _curve,
        uint64 _targetUtilizationWAD
    )
        internal
        returns (IYDM ydm, bytes memory initData)
    {
        if (_kind == 0) {
            MockYDM mock = new MockYDM();
            mock.setYieldShare(uint256(_curve[1]));
            (ydm, initData) = (IYDM(address(mock)), bytes(""));
        } else if (_kind == 1) {
            ydm = IYDM(address(new StaticCurveYDM(_targetUtilizationWAD)));
            initData = abi.encodeCall(StaticCurveYDM.initializeYDMForMarket, (_curve[0], _curve[1], _curve[2]));
        } else if (_kind == 2) {
            ydm = IYDM(address(new AdaptiveCurveYDM_V2(_targetUtilizationWAD, 0.0001e18, 1e18, (100e18 / uint256(365 days)))));
            initData = abi.encodeCall(AdaptiveCurveYDM_V2.initializeYDMForMarket, (_curve[0], _curve[1], _curve[2]));
        } else {
            revert("DayMarketTestBase: unknown YDM kind");
        }
        vm.label(address(ydm), _label);
    }

    /// @notice Deploys a tranche proxy with its production-shaped init params
    function _deployTrancheProxy(address _impl, string memory _name, string memory _symbol) internal returns (address proxy) {
        bytes memory initData = abi.encodeCall(
            RoycoSeniorTranche.initialize,
            (IRoycoVaultTranche.RoycoTrancheInitParams({ name: _name, symbol: _symbol, initialAuthority: address(accessManager) }))
        );
        proxy = address(new ERC1967Proxy(_impl, initData));
    }

    /// @notice Builds the accountant's init params from the fixture's market parameterization
    function _buildAccountantInitParams(
        MarketParamsConfig memory _params,
        bytes memory _jtYdmInitData,
        bytes memory _ltYdmInitData
    )
        internal
        view
        returns (IRoycoDayAccountant.RoycoDayAccountantInitParams memory)
    {
        return IRoycoDayAccountant.RoycoDayAccountantInitParams({
            minCoverageWAD: _params.minCoverageWAD,
            coverageLiquidationUtilizationWAD: _params.coverageLiquidationUtilizationWAD,
            minLiquidityWAD: _params.minLiquidityWAD,
            jtYDM: address(jtYdm),
            jtYDMInitializationData: _jtYdmInitData,
            ltYDM: address(ltYdm),
            ltYDMInitializationData: _ltYdmInitData,
            maxJTYieldShareWAD: _params.maxJTYieldShareWAD,
            maxLTYieldShareWAD: _params.maxLTYieldShareWAD,
            fixedTermDurationSeconds: _params.fixedTermDurationSeconds,
            stNAVDustTolerance: toNAVUnits(_params.stNAVDustTolerance),
            jtNAVDustTolerance: toNAVUnits(_params.jtNAVDustTolerance),
            stProtocolFeeWAD: _params.stProtocolFeeWAD,
            jtProtocolFeeWAD: _params.jtProtocolFeeWAD,
            jtYieldShareProtocolFeeWAD: _params.jtYieldShareProtocolFeeWAD,
            ltYieldShareProtocolFeeWAD: _params.ltYieldShareProtocolFeeWAD
        });
    }

    // =============================
    // Role Wiring (mirrors BalancerV3_GyroECLP_LT_DeploymentTemplate._buildRoleBindings minus Balancer-governance targets)
    // =============================

    /// @notice Binds every production selector to its production role on the five market contracts
    function _wireTargetFunctionRoles() internal {
        // ST/JT tranches: LP-gated deposit and redeem, admin surface, kernel-only burns via BURNER_ROLE
        _bindTranche(address(seniorTranche), ST_LP_ROLE, ST_LP_ROLE, false);
        _bindTranche(address(juniorTranche), JT_LP_ROLE, JT_LP_ROLE, false);
        // LT: LP-gated deposits and redemptions, mirroring the ST/JT surface
        _bindTranche(address(liquidityTranche), LT_LP_ROLE, LT_LP_ROLE, true);

        // Kernel
        address k = address(kernel);
        accessManager.setTargetFunctionRole(
            k, _sels(IRoycoDayKernel.setProtocolFeeRecipient.selector, IRoycoDayKernel.setSeniorTrancheSelfLiquidationBonus.selector), ADMIN_KERNEL_ROLE
        );
        accessManager.setTargetFunctionRole(k, _sels(IRoycoDayKernel.syncTrancheAccounting.selector), SYNC_ROLE);
        accessManager.setTargetFunctionRole(k, _sels(IRoycoDayKernel.reinvestLiquidityPremium.selector), ADMIN_MARKET_REINVEST_LIQUIDITY_PREMIUM_ROLE);
        accessManager.setTargetFunctionRole(k, _sels(IRoycoDayKernel.setRoycoBlacklist.selector), ADMIN_MARKET_OPS_ROLE);
        accessManager.setTargetFunctionRole(k, _sels(IRoycoAuth.pause.selector), ADMIN_PAUSER_ROLE);
        accessManager.setTargetFunctionRole(k, _sels(IRoycoAuth.unpause.selector), ADMIN_UNPAUSER_ROLE);
        accessManager.setTargetFunctionRole(k, _sels(UUPSUpgradeable.upgradeToAndCall.selector), ADMIN_UPGRADER_ROLE);

        // Kernel quoter admin surface (the LT-quoter setters the template binds plus this family's ST/JT quoter setters)
        accessManager.setTargetFunctionRole(
            k,
            _sels(
                BalancerV3_LT_BPTOracle_Quoter.setBPTOracle.selector,
                BalancerV3_LT_BPTOracle_Quoter.setMaxReinvestmentSlippage.selector,
                IdenticalAssets_ST_JT_Oracle_Quoter.setConversionRate.selector,
                IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.setChainlinkOracle.selector,
                IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.setSequencerUptimeFeed.selector
            ),
            ADMIN_ORACLE_QUOTER_ROLE
        );

        // Accountant (the template's 16-selector list, BalancerV3_GyroECLP_LT_DeploymentTemplate.sol:525-561)
        address a = address(accountant);
        accessManager.setTargetFunctionRole(
            a,
            _sels7(
                IRoycoDayAccountant.setJuniorTrancheYDM.selector,
                IRoycoDayAccountant.setLiquidityTrancheYDM.selector,
                IRoycoDayAccountant.setMinCoverage.selector,
                IRoycoDayAccountant.setLiquidationCoverageUtilization.selector,
                IRoycoDayAccountant.setMinLiquidity.selector,
                IRoycoDayAccountant.setMaxYieldShares.selector,
                IRoycoDayAccountant.setFixedTermDuration.selector
            ),
            ADMIN_ACCOUNTANT_ROLE
        );
        accessManager.setTargetFunctionRole(
            a,
            _sels(
                IRoycoDayAccountant.setSeniorTrancheProtocolFee.selector,
                IRoycoDayAccountant.setJuniorTrancheProtocolFee.selector,
                IRoycoDayAccountant.setJTYieldShareProtocolFee.selector,
                IRoycoDayAccountant.setLTYieldShareProtocolFee.selector
            ),
            ADMIN_PROTOCOL_FEE_SETTER_ROLE
        );
        accessManager.setTargetFunctionRole(
            a,
            _sels(IRoycoDayAccountant.setSeniorTrancheDustTolerance.selector, IRoycoDayAccountant.setJuniorTrancheDustTolerance.selector),
            ADMIN_MARKET_OPS_ROLE
        );
        accessManager.setTargetFunctionRole(a, _sels(IRoycoAuth.pause.selector), ADMIN_PAUSER_ROLE);
        accessManager.setTargetFunctionRole(a, _sels(IRoycoAuth.unpause.selector), ADMIN_UNPAUSER_ROLE);
        accessManager.setTargetFunctionRole(a, _sels(UUPSUpgradeable.upgradeToAndCall.selector), ADMIN_UPGRADER_ROLE);
    }

    /// @notice Binds one tranche's selector surface (deposit/redeem/admin/burn, plus the LT multi-asset pair)
    function _bindTranche(address _tranche, uint64 _depositRole, uint64 _redeemRole, bool _isLiquidity) internal {
        if (_isLiquidity) {
            accessManager.setTargetFunctionRole(
                _tranche, _sels(IRoycoVaultTranche.deposit.selector, RoycoLiquidityTranche.depositMultiAsset.selector), _depositRole
            );
            accessManager.setTargetFunctionRole(
                _tranche, _sels(IRoycoVaultTranche.redeem.selector, RoycoLiquidityTranche.redeemMultiAsset.selector), _redeemRole
            );
        } else {
            accessManager.setTargetFunctionRole(_tranche, _sels(IRoycoVaultTranche.deposit.selector), _depositRole);
            accessManager.setTargetFunctionRole(_tranche, _sels(IRoycoVaultTranche.redeem.selector), _redeemRole);
        }
        // Pause/unpause are bound for parity with the other Constants, but the tranche enforces no pause of its own:
        // the kernel is the market's single pause authority, so a tranche-level pause is inert
        accessManager.setTargetFunctionRole(_tranche, _sels(IRoycoAuth.pause.selector), ADMIN_PAUSER_ROLE);
        accessManager.setTargetFunctionRole(_tranche, _sels(IRoycoAuth.unpause.selector), ADMIN_UNPAUSER_ROLE);
        accessManager.setTargetFunctionRole(_tranche, _sels(UUPSUpgradeable.upgradeToAndCall.selector), ADMIN_UPGRADER_ROLE);
        accessManager.setTargetFunctionRole(_tranche, _sels(ERC20BurnableUpgradeable.burn.selector, ERC20BurnableUpgradeable.burnFrom.selector), BURNER_ROLE);
    }

    /**
     * @notice Grants the post-init contract roles and the per-role admin and LP wallets, all at zero execution delay
     * @dev Contract grants mirror the template's postInitGrants (SYNC_ROLE to the accountant for withSyncedAccounting,
     *      BURNER_ROLE to the kernel) minus the Balancer hook grant, which does not exist in mock-land. The fixture
     *      itself receives ST_LP_ROLE so the LT seed helper can source senior shares through the production path
     */
    function _wireRoleGrants() internal {
        // Post-init contract grants
        accessManager.grantRole(SYNC_ROLE, address(accountant), 0);
        accessManager.grantRole(BURNER_ROLE, address(kernel), 0);

        // The kernel (premium senior-share mint recipient) and the protocol fee recipient (fee-share mint
        // recipient) are intentionally NOT granted the tranche LP roles, mirroring the deployment template which
        // no longer grants them: the kernel whitelist hook exempts both by address (_to == address(this) and
        // _to == protocolFeeRecipient), so a fee/premium mint never bricks a whitelist-enforcing market

        // Dedicated admin wallets
        PAUSER = _generateActor("PAUSER", ADMIN_PAUSER_ROLE);
        UNPAUSER = _generateActor("UNPAUSER", ADMIN_UNPAUSER_ROLE);
        UPGRADER = _generateActor("UPGRADER", ADMIN_UPGRADER_ROLE);
        SYNC_OPERATOR = _generateActor("SYNC_OPERATOR", SYNC_ROLE);
        KERNEL_ADMIN = _generateActor("KERNEL_ADMIN", ADMIN_KERNEL_ROLE);
        MARKET_OPS_ADMIN = _generateActor("MARKET_OPS_ADMIN", ADMIN_MARKET_OPS_ROLE);
        ACCOUNTANT_ADMIN = _generateActor("ACCOUNTANT_ADMIN", ADMIN_ACCOUNTANT_ROLE);
        PROTOCOL_FEE_SETTER = _generateActor("PROTOCOL_FEE_SETTER", ADMIN_PROTOCOL_FEE_SETTER_ROLE);
        ORACLE_QUOTER_ADMIN = _generateActor("ORACLE_QUOTER_ADMIN", ADMIN_ORACLE_QUOTER_ROLE);
        MARKET_REINVEST_LIQUIDITY_PREMIUM_ADMIN = _generateActor("MARKET_REINVEST_LIQUIDITY_PREMIUM_ADMIN", ADMIN_MARKET_REINVEST_LIQUIDITY_PREMIUM_ROLE);

        // LP actors
        ST_PROVIDER = _generateActor("ST_PROVIDER", ST_LP_ROLE);
        JT_PROVIDER = _generateActor("JT_PROVIDER", JT_LP_ROLE);
        LT_PROVIDER = _generateActor("LT_PROVIDER", LT_LP_ROLE);

        // The fixture sources senior shares for LT pool seeding through the production deposit path
        accessManager.grantRole(ST_LP_ROLE, address(this), 0);
    }

    // =============================
    // Selector Array Builders
    // =============================

    function _sels(bytes4 _a) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = _a;
    }

    function _sels(bytes4 _a, bytes4 _b) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        (s[0], s[1]) = (_a, _b);
    }

    function _sels(bytes4 _a, bytes4 _b, bytes4 _c, bytes4 _d) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        (s[0], s[1], s[2], s[3]) = (_a, _b, _c, _d);
    }

    function _sels(bytes4 _a, bytes4 _b, bytes4 _c, bytes4 _d, bytes4 _e) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        (s[0], s[1], s[2], s[3], s[4]) = (_a, _b, _c, _d, _e);
    }

    function _sels7(bytes4 _a, bytes4 _b, bytes4 _c, bytes4 _d, bytes4 _e, bytes4 _f, bytes4 _g) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](7);
        (s[0], s[1], s[2], s[3], s[4], s[5], s[6]) = (_a, _b, _c, _d, _e, _f, _g);
    }
}
