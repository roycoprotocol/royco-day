// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { AccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { IERC20Errors } from "../../../lib/openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";
import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { UpgradeableBeacon } from "../../../lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuardTransient } from "../../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import { RoycoDayAccountant } from "../../../src/accountant/RoycoDayAccountant.sol";
import { ST_LP_ROLE, SYNC_ROLE } from "../../../src/factory/Roles.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { RoycoDayBalancerV3Kernel } from "../../../src/kernels/RoycoDayBalancerV3Kernel.sol";
import { BalancerV3LiquidityVenue } from "../../../src/kernels/base/liquidity-venue/balancer-v3/BalancerV3LiquidityVenue.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoJuniorTranche } from "../../../src/tranches/RoycoJuniorTranche.sol";
import { RoycoLiquidityProviderTranche } from "../../../src/tranches/RoycoLiquidityProviderTranche.sol";
import { RoycoSeniorTranche } from "../../../src/tranches/RoycoSeniorTranche.sol";
import { MockAggregatorV3 } from "../../mocks/MockAggregatorV3.sol";
import { MockBPT } from "../../mocks/MockBPT.sol";
import { MockBPTOracle } from "../../mocks/MockBPTOracle.sol";
import { MockBalancerVault } from "../../mocks/MockBalancerVault.sol";
import { MockBehaviors } from "../../mocks/MockBehaviors.sol";
import { MockPriceOracle } from "../../mocks/MockPriceOracle.sol";
import { MockReentrancyProbe } from "../../mocks/MockReentrancyProbe.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { zeroLiquidityParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";
import { IBalancerV3LiquidityVenue } from "../../../src/interfaces/liquidity-venue/IBalancerV3LiquidityVenue.sol";

/**
 * @title Test_RedeemReentrancyWindow_Tranches
 * @notice Adversarial probes of the redemption payout window: the tranche burns the owner's shares BEFORE it pays
 *         the receiver (the kernel scales claims against the pre-burn supply, then kernelBurn runs, then the payout
 *         transfer fires), so by the time a malicious receiver runs code mid-transfer the redeemed shares are
 *         already gone. The receiver must be unable to exploit the payout hook: every kernel-mutating entrypoint is
 *         sealed by the kernel's transient reentrancy guard, and the one state change the guard cannot stop (moving
 *         shares with a plain ERC20 transfer) finds the shares already burned, so the reentrant transfer reverts
 *         harmlessly and the outer redemption settles once and correctly
 * @dev The shipped fixture's collateral asset is an ERC4626 share with no transfer callback, so a receiver can
 *      never run code during its payout. To open the window this suite makes the hookable MockERC20C underlying
 *      the collateral asset directly (the kernel prices any ERC20 through its collateral asset oracle). The
 *      deployment mirrors the shipped fixture's order and role wiring with only the tranche asset and its
 *      oracle swapped. The oracle's 1.0 price pins one token = one NAV unit, and the market runs at zero minimum
 *      liquidity with no PnL so every payout below is a wei-exact literal carrying the virtual-shares/value +1 offset
 */
contract Test_RedeemReentrancyWindow_Tranches is DayMarketTestBase {
    /// @dev The collateral oracle price (1.0, one token = one NAV unit)
    uint256 internal constant INITIAL_ORACLE_PRICE_WAD = 1e18;

    /// @notice The malicious payout receiver, wired as the senior asset's transfer hook
    MockReentrancyProbe internal probe;

    function setUp() public {
        _deployPlainAssetMarket();

        // Seed JT first (senior deposits are coverage-gated on junior NAV): JT 30e18, ST 100e18 tokens at the 1.0
        // rate gives coverage utilization (100 + 30) x 0.2 / 30 = 0.8667 <= 1, a healthy PERPETUAL market
        stJtUnderlying.mint(JT_PROVIDER, 30e18);
        vm.startPrank(JT_PROVIDER);
        stJtUnderlying.approve(address(juniorTranche), 30e18);
        juniorTranche.deposit(toTrancheUnits(30e18), JT_PROVIDER);
        vm.stopPrank();
        stJtUnderlying.mint(ST_PROVIDER, 100e18);
        vm.startPrank(ST_PROVIDER);
        stJtUnderlying.approve(address(seniorTranche), 100e18);
        seniorTranche.deposit(toTrancheUnits(100e18), ST_PROVIDER);
        vm.stopPrank();

        // The probe is a fully qualified senior LP and sync operator: every reentrant attempt below must fail on
        // the reentrancy guard alone, never on a missing role, balance, or allowance that would mask a guard hole
        probe = new MockReentrancyProbe();
        vm.label(address(probe), "ReentrancyProbe");
        accessManager.grantRole(ST_LP_ROLE, address(probe), 0);
        accessManager.grantRole(SYNC_ROLE, address(probe), 0);
    }

    /**
     * @notice A receiver reentering the market mid-payout is rejected by the transient reentrancy guard on every
     *         kernel-mutating entrypoint, and the outer redemption settles on the clean redemption path
     * @dev The payout transfer is the last step of a redemption whose kernel guard is still held (the entrypoint
     *      has not returned), so at hook time any reentrant kernel-mutating call lands inside the guarded region: an
     *      unguarded redeem would re-enter the ledger the outer flow is still settling, an unguarded deposit would
     *      mint against that mid-flow state, and an unguarded sync would commit a checkpoint inside the redemption.
     *      All three must revert with the guard's error.
     *      Every literal carries the virtual-shares/value +1 offset at the pinned 1.0 rate with no PnL and no fee
     *      mints (fees accrue only on gains): control redeem 10e18 of 100e18 shares pays
     *      floor(100e18 x 10e18 / (100e18 + 1)) = 9999999999999999999 tokens (the kernel retains one wei of virtual
     *      dust, so the senior effective NAV lands at 90000000000000000001 over a 90e18 supply). The probe's
     *      5e18-token deposit then mints floor((90e18 + 1) x 5e18 / (90000000000000000001 + 1)) =
     *      4999999999999999999 shares. The hooked redeem of 10e18 of the resulting 94999999999999999999 supply
     *      against the 95000000000000000001 senior effective NAV pays
     *      floor(95000000000000000001 x 10e18 / (94999999999999999999 + 1)) = 10000000000000000000 tokens, one wei
     *      above the control payout because the probe's interleaved deposit reshapes the supply and NAV the floor
     *      divides, so the offset rounding lands a wei higher (the old VS=1e6 pins made the two coincide, the +1
     *      offset no longer does)
     */
    function test_RevertIf_RedeemPayoutReentersKernelMutatingFlows() public {
        // Control run, no hook armed: the clean-path payout every hooked delta below must match exactly
        address controlReceiver = makeAddr("CONTROL_RECEIVER");
        vm.prank(ST_PROVIDER);
        AssetClaims memory controlClaims = seniorTranche.redeem(10e18, controlReceiver, ST_PROVIDER);
        assertEq(
            toUint256(controlClaims.collateralAssets),
            9_999_999_999_999_999_999,
            "the control redemption must pay floor(100e18 x 10e18 / (100e18 + 1)) = 9999999999999999999 tokens"
        );
        assertEq(stJtUnderlying.balanceOf(controlReceiver), 9_999_999_999_999_999_999, "the control receiver must hold exactly the 9999999999999999999 payout");

        // Qualify the probe before arming the hook: 6e18 tokens minted, 5e18 deposited (minting the offset-adjusted
        // quote against the post-control 90000000000000100000 claims over 90e18 shares), 1e18 kept to fund the reentrant deposit
        stJtUnderlying.mint(address(probe), 6e18);
        vm.startPrank(address(probe));
        stJtUnderlying.approve(address(seniorTranche), type(uint256).max);
        seniorTranche.deposit(toTrancheUnits(5e18), address(probe));
        vm.stopPrank();
        assertEq(
            seniorTranche.balanceOf(address(probe)),
            4_999_999_999_999_999_999,
            "the probe's qualifying deposit must mint floor((90e18 + 1) x 5e18 / (90000000000000000001 + 1)) = 4999999999999999999 senior shares"
        );

        // Arm one attempt per kernel-mutating flow: redeem the probe's own shares, deposit the probe's kept tokens,
        // and sync the accounting, all fully qualified so only the guard stands between them and execution
        probe.armCall(address(seniorTranche), abi.encodeCall(seniorTranche.redeem, (1e18, address(probe), address(probe))));
        probe.armCall(address(seniorTranche), abi.encodeCall(seniorTranche.deposit, (toTrancheUnits(1e18), address(probe))));
        probe.armCall(address(kernel), abi.encodeCall(kernel.syncTrancheAccounting, ()));
        stJtUnderlying.setTransferHook(address(probe));
        stJtUnderlying.setBehaviors(MockBehaviors.BEHAVIOR_HOOK_ON_TRANSFER);

        // The hooked run: the payout transfer to the probe fires all three armed reentrant calls mid-redemption
        vm.prank(ST_PROVIDER);
        AssetClaims memory hookedClaims = seniorTranche.redeem(10e18, address(probe), ST_PROVIDER);

        // Every reentrant attempt fired and every one was rejected by the transient guard, nothing else
        assertTrue(probe.fired(), "the payout transfer must have fired the probe's armed calls");
        assertEq(probe.outcomeCount(), 3, "all three armed reentrant calls must have been attempted");
        bytes memory guardRevert = abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        for (uint256 i; i < 3; ++i) {
            MockReentrancyProbe.ProbeOutcome memory outcome = probe.outcomeAt(i);
            assertFalse(outcome.succeeded, "a reentrant kernel-mutating call must not execute inside the payout window");
            assertEq(outcome.returnOrRevertData, guardRevert, "the rejection must be the reentrancy guard's error, not an incidental failure");
        }

        // The outer redemption must settle on the clean redemption path unperturbed by the rejected reentries. The
        // probe's interleaved qualifying deposit shifts the supply and NAV the second redeem divides, so its offset
        // floor lands one wei above the control payout (10000000000000000000 vs 9999999999999999999), the +1 offset
        // no longer pins them equal the way VS=1e6 did. Both redemptions still debit the owner 10e18 shares apiece
        assertEq(
            toUint256(hookedClaims.collateralAssets), 10_000_000_000_000_000_000, "the hooked redemption must pay floor(95000000000000000001 x 10e18 / (94999999999999999999 + 1)) = 10000000000000000000"
        );
        assertEq(
            stJtUnderlying.balanceOf(address(probe)),
            11_000_000_000_000_000_000,
            "the probe must hold its kept 1e18 plus exactly the 10000000000000000000 payout"
        );
        assertEq(seniorTranche.balanceOf(ST_PROVIDER), 80e18, "the owner's shares must drop 100e18 -> 90e18 -> 80e18, 10e18 per redemption");
        assertEq(
            seniorTranche.totalSupply(),
            84_999_999_999_999_999_999,
            "supply must be 100e18 - 10e18 + 4999999999999999999 - 10e18 = 84999999999999999999, no phantom mint or burn"
        );
        // The collateral ledger carries the seeded ST 100e18 + JT 30e18, minus the two payouts 9999999999999999999
        // and 10000000000000000000, plus the probe's 5e18 deposit: 135e18 - 19999999999999999999 =
        // 115000000000000000001 (one wei of virtual dust survives overall), untouched by the rejected reentries
        assertEq(
            toUint256(kernel.getState().totalCollateralAssets), 115_000_000_000_000_000_001, "the kernel's collateral ledger must land at 115000000000000000001"
        );
    }

    /**
     * @notice A receiver who tries to move the owner's shares away during the payout finds them already burned: the
     *         redemption burns BEFORE it pays, so when the payout hook fires the shares are gone, the mid-payout
     *         transfer reverts on a zero balance, the probe swallows that revert, and the redemption settles once
     *         and correctly, so no path ends with the redeemer holding both the assets and a live second claim
     * @dev This is the window the pay-before-burn design would have opened and burn-before-pay closes: a plain share
     *      transfer never enters the kernel's guarded surface (the pre-balance-update hook is unguarded by design, it
     *      must run inside guarded kernel flows), so ordering, not the guard, is the defense. RedemptionLogic burns
     *      the owner's shares (kernelBurn, :94) before remitting the claims (_remitClaims, :100), so the probe's
     *      20e18-token deposit mints the offset-adjusted 20000000000000000000 shares, its double-claim attempt
     *      (redeem 20e18 shares, receive the payout, mid-transfer ship the entire balance to an accomplice) hits a
     *      probe balance already zeroed by the burn: the reentrant transfer of 20e18 reverts
     *      ERC20InsufficientBalance(probe, 0, 20e18), the probe records that failure without bubbling it, and the
     *      outer redemption completes. Payout: floor(120e18 claims x 20e18 / (120e18 + 1)) = 19999999999999999999
     */
    function test_BurnBeforePayDefeatsShareExfiltrationDuringRedeemPayout() public {
        // The probe becomes a real senior LP with 20e18 shares (1:1 against the seeded 100e18 claims over 100e18 shares)
        stJtUnderlying.mint(address(probe), 20e18);
        vm.startPrank(address(probe));
        stJtUnderlying.approve(address(seniorTranche), 20e18);
        seniorTranche.deposit(toTrancheUnits(20e18), address(probe));
        vm.stopPrank();
        assertEq(
            seniorTranche.balanceOf(address(probe)),
            20_000_000_000_000_000_000,
            "the probe's deposit must mint floor((100e18 + 1) x 20e18 / (100e18 + 1)) = 20000000000000000000 senior shares"
        );

        // Arm the share exfiltration and wire the hook AFTER the qualifying deposit so setup transfers stay silent.
        // Ship the probe's ENTIRE balance, but the burn runs before the payout hook so this transfer finds zero shares
        address accomplice = makeAddr("ACCOMPLICE");
        probe.armCall(address(seniorTranche), abi.encodeCall(seniorTranche.transfer, (accomplice, 20_000_000_000_000_000_000)));
        stJtUnderlying.setTransferHook(address(probe));
        stJtUnderlying.setBehaviors(MockBehaviors.BEHAVIOR_HOOK_ON_TRANSFER);

        // Pre-attack ledgers: the kernel custodies the seeded 100e18 + 30e18 plus the probe's 20e18, senior supply is
        // the seeded 100e18 plus the probe's shares
        assertEq(stJtUnderlying.balanceOf(address(kernel)), 150e18, "the kernel must custody the seeded 100e18 + 30e18 plus the probe's 20e18");
        assertEq(
            seniorTranche.totalSupply(),
            120_000_000_000_000_000_000,
            "the pre-attack senior supply is the seeded 100e18 plus the probe's offset-adjusted 20000000000000000000 shares"
        );

        // The full-balance redemption settles cleanly: the burn zeroes the probe's shares first, then the payout hook
        // fires and its reentrant share transfer reverts on the emptied balance, harmlessly recorded not bubbled
        vm.prank(address(probe));
        AssetClaims memory claims = seniorTranche.redeem(20e18, address(probe), address(probe));
        assertEq(
            toUint256(claims.collateralAssets), 19_999_999_999_999_999_999, "the redemption must pay floor(120e18 x 20e18 / (120e18 + 1)) = 19999999999999999999"
        );

        // The reentrant exfiltration fired and failed on the already-burned balance, swallowed by the probe
        assertTrue(probe.fired(), "the payout transfer must have fired the probe's armed share transfer");
        assertEq(probe.outcomeCount(), 1, "the single armed share transfer must have been attempted");
        MockReentrancyProbe.ProbeOutcome memory outcome = probe.outcomeAt(0);
        assertFalse(outcome.succeeded, "the mid-payout share transfer must revert on the balance the burn already zeroed");
        assertEq(
            outcome.returnOrRevertData,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(probe), uint256(0), uint256(20e18)),
            "the failure must be ERC20InsufficientBalance(probe, 0, 20e18), the shares were burned before the payout"
        );

        // The redemption settled once: shares burned, nothing reached the accomplice, and the probe holds only the
        // single payout, never a second claim
        assertEq(seniorTranche.balanceOf(address(probe)), 0, "the burn-before-pay ordering left the probe with zero shares");
        assertEq(seniorTranche.balanceOf(accomplice), 0, "the accomplice must be left with nothing, the exfiltration transfer reverted");
        assertEq(stJtUnderlying.balanceOf(address(probe)), 19_999_999_999_999_999_999, "the probe holds exactly the single 19999999999999999999 payout, no double claim");
        // The kernel paid the 19999999999999999999 out of its seeded 150e18 custody, retaining one wei of virtual dust
        assertEq(stJtUnderlying.balanceOf(address(kernel)), 130_000_000_000_000_000_001, "the kernel's asset custody drops by exactly the one settled payout");
        assertEq(toUint256(kernel.getState().totalCollateralAssets), 130_000_000_000_000_000_001, "the kernel's collateral ledger drops by exactly the one settled payout");
        assertEq(seniorTranche.totalSupply(), 100e18, "supply must drop 120e18 -> 100e18, the redeemed 20e18 burned exactly once");
    }

    // =============================
    // Fixture: the shipped market deployment order with the kernel and senior asset swapped
    // =============================

    /**
     * @notice Deploys the full Day market exactly like the shipped fixture, making the hookable MockERC20C
     *         underlying the collateral asset directly with the collateral oracle pricing it
     * @dev Mirrors the base deployment order 1:1 (tokens, oracles, venue, YDMs, predicted kernel address, impls,
     *      tranche and accountant proxies, pool registration, kernel impl, kernel proxy, role wiring) so the payout
     *      window under test runs behind production-shaped proxies and roles. Zero minimum liquidity keeps the
     *      market a plain senior/junior system, no pool depth is needed for the senior flows probed here
     */
    function _deployPlainAssetMarket() internal {
        cell = cellA();
        params = zeroLiquidityParams();

        // Access manager, admin'd by the fixture so role wiring needs no schedule/execute dance
        accessManager = new AccessManager(address(this));

        // Tokens: quote stable + ONE hookable plain ERC20 serving as the coinvested collateral asset (the
        // collateral oracle prices any ERC20 in NAV units)
        quoteToken = _deployERC20("Quote Stable", "QUOTE", cell.quoteAsset);
        stJtUnderlying = _deployERC20("ST/JT Plain Asset", "UNDR", _toUnderlyingConfig(cell.collateralAsset));

        // Oracles: the collateral asset oracle at 1.0 over the plain ERC20 (the kernel's only collateral price
        // source) plus the quote-side feed at 1.0 (8 decimals), sequencer checks disabled at init
        collateralAssetOracle = new MockPriceOracle(address(stJtUnderlying), INITIAL_ORACLE_PRICE_WAD, ORACLE_STALENESS_THRESHOLD_SECONDS);
        collateralPriceWAD = INITIAL_ORACLE_PRICE_WAD;
        priceFeed = new MockAggregatorV3(PRICE_FEED_DECIMALS, PRICE_FEED_INITIAL_ANSWER);

        // Venue: mock Balancer vault, the BPT it ledgers, and the BPT oracle
        balancerVault = new MockBalancerVault();
        bpt = new MockBPT(IVault(address(balancerVault)), "Royco BPT", "rBPT");
        bptOracle = new MockBPTOracle(balancerVault, address(bpt));

        // YDMs: always two distinct instances (the accountant rejects identical YDMs)
        bytes memory jtYdmInitData;
        bytes memory lptYdmInitData;
        (jtYdm, jtYdmInitData) = _deployYDM("JT_YDM", params.jtYdmKind, params.jtCurve, params.targetUtilizationWAD);
        (lptYdm, lptYdmInitData) = _deployYDM("LPT_YDM", params.lptYdmKind, params.lptCurve, params.targetUtilizationWAD);

        // Predict the kernel proxy address so the tranche and accountant impls can bake it into their immutables
        kernelProxyDeployer = makeAddr("KERNEL_PROXY_DEPLOYER");
        address predictedKernel = vm.computeCreateAddress(kernelProxyDeployer, vm.getNonce(kernelProxyDeployer));

        // THE ASSET SWAP: the senior and junior tranches hold the hookable plain ERC20 itself, so a redemption's
        // payout transfer executes receiver code exactly where a callback-bearing production asset would
        UpgradeableBeacon stSwapBeacon = new UpgradeableBeacon(address(new RoycoSeniorTranche()), address(accessManager));
        UpgradeableBeacon jtSwapBeacon = new UpgradeableBeacon(address(new RoycoJuniorTranche()), address(accessManager));
        UpgradeableBeacon lptSwapBeacon = new UpgradeableBeacon(address(new RoycoLiquidityProviderTranche()), address(accessManager));
        RoycoDayAccountant accImpl = new RoycoDayAccountant();

        // Tranche and accountant proxies must exist before the kernel (its initializer reads each tranche's asset)
        seniorTranche =
            RoycoSeniorTranche(_deployTrancheProxy(address(stSwapBeacon), "Royco Senior Tranche", "RST", predictedKernel, address(stJtUnderlying)));
        juniorTranche =
            RoycoJuniorTranche(_deployTrancheProxy(address(jtSwapBeacon), "Royco Junior Tranche", "RJT", predictedKernel, address(stJtUnderlying)));
        liquidityProviderTranche = RoycoLiquidityProviderTranche(
            _deployTrancheProxy(address(lptSwapBeacon), "Royco Liquidity Provider Tranche", "RLT", predictedKernel, address(bpt))
        );
        accountant = RoycoDayAccountant(
            address(
                new ERC1967Proxy(
                    address(accImpl),
                    abi.encodeCall(RoycoDayAccountant.initialize, (_buildAccountantInitParams(params, predictedKernel, jtYdmInitData, lptYdmInitData)))
                )
            )
        );

        // Register the pool before kernel impl construction (the liquidity venue constructor validates the registration),
        // sorted ascending by address exactly as the production vault registers pool tokens
        // The venue requires tokens[0] == seniorTranche and tokens[1] == quoteAsset structurally, the ordering the
        // factory template guarantees in production by mining the market id, so the fixture registers it directly
        stPoolTokenIndex = 0;
        balancerVault.registerPool(address(bpt), [IERC20(address(seniorTranche)), IERC20(address(quoteToken))]);
        _initializePoolMinimumSupply();

        // The shipped kernel impl over the plain asset (the oracle above carries the whole collateral pricing swap)
        RoycoDayBalancerV3Kernel kernelImpl = new RoycoDayBalancerV3Kernel(IVault(address(balancerVault)));

        PROTOCOL_FEE_RECIPIENT = makeAddr("PROTOCOL_FEE_RECIPIENT");

        // Kernel proxy from the dedicated deployer so it lands at the predicted address
        bytes memory kernelInitData = abi.encodeCall(
            kernelImpl.initialize,
            (
                IRoycoDayKernel.RoycoDayKernelInitParams({
                    initialAuthority: address(accessManager),
                    seniorTranche: address(seniorTranche),
                    juniorTranche: address(juniorTranche),
                    liquidityProviderTranche: address(liquidityProviderTranche),
                    collateralAsset: address(stJtUnderlying),
                    lptAsset: address(bpt),
                    quoteAsset: address(quoteToken),
                    accountant: address(accountant),
                    protocolFeeRecipient: PROTOCOL_FEE_RECIPIENT,
                    stSelfLiquidationBonusWAD: params.stSelfLiquidationBonusWAD,
                    roycoBlacklist: address(0),
                    collateralAssetOracle: address(collateralAssetOracle),
                    sequencerUptimeFeed: address(0),
                    gracePeriodSeconds: ORACLE_GRACE_PERIOD_SECONDS
                }),
                IBalancerV3LiquidityVenue.BalancerV3LiquidityVenueInitParams({
                    bptOracle: address(bptOracle), maxReinvestmentSlippageWAD: params.maxReinvestmentSlippageWAD
                })
            )
        );
        vm.prank(kernelProxyDeployer);
        address kernelProxy = address(new ERC1967Proxy(address(kernelImpl), kernelInitData));
        require(kernelProxy == predictedKernel, "Test_RedeemReentrancyWindow_Tranches: kernel proxy address prediction failed");
        kernel = RoycoDayBalancerV3Kernel(kernelProxy);
        vm.label(kernelProxy, "Kernel");

        // Wire the kernel as the senior leg's live rate provider in both price stores, mirroring production
        balancerVault.setTokenRateProvider(address(seniorTranche), kernelProxy);
        bptOracle.setTokenRateProvider(address(seniorTranche), kernelProxy);

        // Role bindings and grants, unchanged from the base (the selector surface is shared across the family)
        _wireTargetFunctionRoles();
        _wireRoleGrants();
    }
}
