// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { AccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { IERC20Errors } from "../../../lib/openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";
import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuardTransient } from "../../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import { RoycoDayAccountant } from "../../../src/accountant/RoycoDayAccountant.sol";
import { ST_LP_ROLE, SYNC_ROLE } from "../../../src/factory/RolesConfiguration.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import {
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel as ShippedKernel
} from "../../../src/kernels/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel.sol";
import {
    IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter
} from "../../../src/kernels/base/quoter/identical-st-jt/IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter.sol";
import { BalancerV3_LT_BPTOracle_Quoter } from "../../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_BPTOracle_Quoter.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoJuniorTranche } from "../../../src/tranches/RoycoJuniorTranche.sol";
import { RoycoLiquidityTranche } from "../../../src/tranches/RoycoLiquidityTranche.sol";
import { RoycoSeniorTranche } from "../../../src/tranches/RoycoSeniorTranche.sol";
import {
    Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3_BPTOracle_LT_Kernel as PlainAssetKernel
} from "../../mocks/Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3_BPTOracle_LT_Kernel.sol";
import { MockAggregatorV3 } from "../../mocks/MockAggregatorV3.sol";
import { MockBPT } from "../../mocks/MockBPT.sol";
import { MockBPTOracle } from "../../mocks/MockBPTOracle.sol";
import { MockBalancerVault } from "../../mocks/MockBalancerVault.sol";
import { MockBehaviors } from "../../mocks/MockBehaviors.sol";
import { MockReentrancyProbe } from "../../mocks/MockReentrancyProbe.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { zeroLiquidityParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_RedeemReentrancyWindow_Tranches
 * @notice Adversarial probes of the redemption payout window: the tranche pays the receiver BEFORE burning the
 *         owner's shares (the kernel scales claims against the pre-burn supply), so between the asset transfer
 *         and the burn the redeemed shares still exist and the payout is already out the door. A malicious
 *         receiver executing code mid-transfer must be unable to exploit that window: every kernel-mutating
 *         entrypoint is sealed by the kernel's transient reentrancy guard, and the one state change the guard
 *         cannot stop (moving the not-yet-burned shares with a plain ERC20 transfer) makes the outer redemption
 *         itself revert at the burn, unwinding the payout with it
 * @dev The shipped fixture's senior asset is an ERC4626 share with no transfer callback, so a receiver can never
 *      run code during its payout. To open the window this suite deploys the identical-plain-assets kernel
 *      composition (the Chainlink-to-admin quoter, which prices the tranche asset off a feed and an admin rate
 *      and works over any ERC20) with the senior/junior asset being the hookable MockERC20C underlying directly.
 *      The deployment mirrors the shipped fixture's order and role wiring with only the kernel implementation
 *      and the tranche asset swapped. Feed 1.0 x admin rate 1.0 pins one token = one NAV unit, and the market
 *      runs at zero minimum liquidity with no PnL so every payout below is a wei-exact 1:1 literal
 */
contract Test_RedeemReentrancyWindow_Tranches is DayMarketTestBase {
    /// @dev The admin-set reference-asset-to-NAV-unit second pricing hop (1.0, so the 1.0 feed alone prices the asset)
    uint256 internal constant INITIAL_ADMIN_RATE_WAD = 1e18;

    /// @notice The kernel proxy under its concrete plain-asset type (same address as the base's `kernel` handle)
    PlainAssetKernel internal plainAssetKernel;

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
     *         kernel-mutating entrypoint, and the outer redemption settles exactly like a hook-free control run
     * @dev The window is real: at hook time the receiver holds the payout while the owner's shares are unburned,
     *      so an unguarded redeem would double-count those shares against a kernel ledger already debited by the
     *      in-flight payout, an unguarded deposit would mint against mid-operation state, and an unguarded sync
     *      would commit a checkpoint halfway through a redemption. All three must revert with the guard's error.
     *      Every literal is 1:1 at the pinned 1.0 rate with no PnL and no fee mints (fees accrue only on gains):
     *      control redeem 10e18 of 100e18 shares pays floor(100e18 x 10e18 / 100e18) = 10e18 tokens, the probe's
     *      5e18-token deposit mints floor(5e18 x 90e18 / 90e18) = 5e18 shares, and the hooked redeem of 10e18 of
     *      the 95e18 supply pays floor(95e18 x 10e18 / 95e18) = 10e18 tokens, identical to the control payout
     */
    function test_RevertIf_RedeemPayoutReentersKernelMutatingFlows() public {
        // Control run, no hook armed: the clean-path payout every hooked delta below must match exactly
        address controlReceiver = makeAddr("CONTROL_RECEIVER");
        vm.prank(ST_PROVIDER);
        AssetClaims memory controlClaims = seniorTranche.redeem(10e18, controlReceiver, ST_PROVIDER);
        assertEq(toUint256(controlClaims.stAssets), 10e18, "the control redemption must pay floor(100e18 x 10e18 / 100e18) = 10e18 tokens");
        assertEq(stJtUnderlying.balanceOf(controlReceiver), 10e18, "the control receiver must hold exactly the 10e18 payout");

        // Qualify the probe before arming the hook: 6e18 tokens minted, 5e18 deposited (minting 5e18 shares at the
        // 1:1 rate against the post-control 90e18 claims over 90e18 shares), 1e18 kept to fund the reentrant deposit
        stJtUnderlying.mint(address(probe), 6e18);
        vm.startPrank(address(probe));
        stJtUnderlying.approve(address(seniorTranche), type(uint256).max);
        seniorTranche.deposit(toTrancheUnits(5e18), address(probe));
        vm.stopPrank();
        assertEq(seniorTranche.balanceOf(address(probe)), 5e18, "the probe's qualifying deposit must mint exactly 5e18 senior shares");

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

        // The outer redemption must settle byte-identically to the control run: same claims, same payout, and the
        // same one-for-one deltas on shares and the kernel's senior asset ledger (-10e18 each, like the control)
        assertEq(toUint256(hookedClaims.stAssets), toUint256(controlClaims.stAssets), "the hooked redemption's claims must equal the control run's");
        assertEq(stJtUnderlying.balanceOf(address(probe)), 11e18, "the probe must hold its kept 1e18 plus exactly the control-equal 10e18 payout");
        assertEq(seniorTranche.balanceOf(ST_PROVIDER), 80e18, "the owner's shares must drop 100e18 -> 90e18 -> 80e18, 10e18 per redemption");
        assertEq(seniorTranche.totalSupply(), 85e18, "supply must be 100e18 - 10e18 + 5e18 - 10e18 = 85e18, no phantom mint or burn");
        assertEq(
            toUint256(kernel.getState().stOwnedYieldBearingAssets),
            85e18,
            "the kernel's senior asset ledger must mirror the supply at the 1:1 rate, untouched by the rejected reentries"
        );
    }

    /**
     * @notice A receiver who moves the owner's not-yet-burned shares away during the payout makes the redemption
     *         revert at the post-payout burn, unwinding the payout with it, so no path ends with the redeemer
     *         holding both the assets and the shares
     * @dev This is the one window action the reentrancy guard cannot stop: a plain share transfer never enters the
     *      kernel's guarded surface (the pre-balance-update hook is unguarded by design, it must run inside guarded
     *      kernel flows). The double-claim attempt is: redeem all 20e18 shares, receive the 20e18-token payout, and
     *      mid-transfer ship the still-unburned 20e18 shares to an accomplice for a second redemption. The defense
     *      is ordering, not the guard: the tranche burns AFTER the kernel pays, so the burn finds a zero balance and
     *      reverts ERC20InsufficientBalance(probe, 0, 20e18), atomically unwinding the payout, the share transfer,
     *      and the kernel's ledger debit. Payout literal: floor(120e18 claims x 20e18 / 120e18 supply) = 20e18
     */
    function test_RevertIf_OwnerSharesMovedAwayDuringRedeemPayout() public {
        // The probe becomes a real senior LP with 20e18 shares (1:1 against the seeded 100e18 claims over 100e18 shares)
        stJtUnderlying.mint(address(probe), 20e18);
        vm.startPrank(address(probe));
        stJtUnderlying.approve(address(seniorTranche), 20e18);
        seniorTranche.deposit(toTrancheUnits(20e18), address(probe));
        vm.stopPrank();
        assertEq(seniorTranche.balanceOf(address(probe)), 20e18, "the probe's deposit must mint exactly 20e18 senior shares");

        // Arm the share exfiltration and wire the hook AFTER the qualifying deposit so setup transfers stay silent
        address accomplice = makeAddr("ACCOMPLICE");
        probe.armCall(address(seniorTranche), abi.encodeCall(seniorTranche.transfer, (accomplice, 20e18)));
        stJtUnderlying.setTransferHook(address(probe));
        stJtUnderlying.setBehaviors(MockBehaviors.BEHAVIOR_HOOK_ON_TRANSFER);

        // Pre-attack ledgers: the burn must find the shares gone (balance 0 against the 20e18 burn), so the whole
        // transaction must roll every one of these back to exactly these values
        assertEq(stJtUnderlying.balanceOf(address(kernel)), 150e18, "the kernel must custody the seeded 100e18 + 30e18 plus the probe's 20e18");
        assertEq(seniorTranche.totalSupply(), 120e18, "the pre-attack senior supply is the seeded 100e18 plus the probe's 20e18");

        // The full-balance redemption: the kernel debits its ledger and pays 20e18 tokens, the hook ships the
        // unburned shares to the accomplice, and the tranche's burn then reverts on the emptied balance
        vm.prank(address(probe));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(probe), uint256(0), uint256(20e18)));
        seniorTranche.redeem(20e18, address(probe), address(probe));

        // The revert unwound everything, including the probe's own recorded outcomes (proof the hook's writes rolled
        // back too): shares back with the probe, nothing with the accomplice, payout back in the kernel
        assertFalse(probe.fired(), "the probe's fired latch must have been rolled back with the reverted transaction");
        assertEq(probe.outcomeCount(), 0, "the probe's recorded outcomes must have been rolled back with the reverted transaction");
        assertEq(seniorTranche.balanceOf(address(probe)), 20e18, "the owner's shares must be fully restored by the unwind");
        assertEq(seniorTranche.balanceOf(accomplice), 0, "the accomplice must be left with nothing");
        assertEq(stJtUnderlying.balanceOf(address(probe)), 0, "the payout must be unwound, the redeemer cannot keep assets AND shares");
        assertEq(stJtUnderlying.balanceOf(address(kernel)), 150e18, "the kernel's asset custody must be byte-identical to the pre-attack value");
        assertEq(toUint256(kernel.getState().stOwnedYieldBearingAssets), 120e18, "the kernel's senior asset ledger debit must be unwound");
        assertEq(toUint256(kernel.getState().jtOwnedYieldBearingAssets), 30e18, "the kernel's junior asset ledger must be untouched");
        assertEq(seniorTranche.totalSupply(), 120e18, "no share may be burned by a redemption that failed to settle");
    }

    // =============================
    // Fixture: the shipped market deployment order with the kernel and senior asset swapped
    // =============================

    /**
     * @notice Deploys the full Day market exactly like the shipped fixture, swapping in the plain-asset kernel and
     *         making the hookable MockERC20C underlying the senior/junior tranche asset directly
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

        // Tokens: quote stable + ONE hookable plain ERC20 serving as BOTH the ST and JT asset (the quoter family
        // requires identical assets, and this composition prices any ERC20 off the feed and the admin rate)
        quoteToken = _deployERC20("Quote Stable", "QUOTE", cell.quoteAsset);
        stJtUnderlying = _deployERC20("ST/JT Plain Asset", "UNDR", _toUnderlyingConfig(cell.stAsset));

        // Oracles: the tranche-asset-to-reference-asset feed at 1.0 (8 decimals), sequencer checks disabled at init
        priceFeed = new MockAggregatorV3(PRICE_FEED_DECIMALS, PRICE_FEED_INITIAL_ANSWER);

        // Venue: mock Balancer vault, the BPT it ledgers, and the BPT oracle
        balancerVault = new MockBalancerVault();
        bpt = new MockBPT(IVault(address(balancerVault)), "Royco BPT", "rBPT");
        bptOracle = new MockBPTOracle(balancerVault, address(bpt));

        // YDMs: always two distinct instances (the accountant rejects identical YDMs)
        bytes memory jtYdmInitData;
        bytes memory ltYdmInitData;
        (jtYdm, jtYdmInitData) = _deployYDM("JT_YDM", params.jtYdmKind, params.jtCurve, params.targetUtilizationWAD);
        (ltYdm, ltYdmInitData) = _deployYDM("LT_YDM", params.ltYdmKind, params.ltCurve, params.targetUtilizationWAD);

        // Predict the kernel proxy address so the tranche and accountant impls can bake it into their immutables
        kernelProxyDeployer = makeAddr("KERNEL_PROXY_DEPLOYER");
        address predictedKernel = vm.computeCreateAddress(kernelProxyDeployer, vm.getNonce(kernelProxyDeployer));

        // THE ASSET SWAP: the senior and junior tranches hold the hookable plain ERC20 itself, so a redemption's
        // payout transfer executes receiver code exactly where a callback-bearing production asset would
        RoycoSeniorTranche stImpl = new RoycoSeniorTranche(address(stJtUnderlying), predictedKernel);
        RoycoJuniorTranche jtImpl = new RoycoJuniorTranche(address(stJtUnderlying), predictedKernel);
        RoycoLiquidityTranche ltImpl = new RoycoLiquidityTranche(address(bpt), predictedKernel);
        RoycoDayAccountant accImpl = new RoycoDayAccountant(predictedKernel, true);

        // Tranche and accountant proxies must exist before the kernel impl (its constructor reads the accountant)
        seniorTranche = RoycoSeniorTranche(_deployTrancheProxy(address(stImpl), "Royco Senior Tranche", "RST"));
        juniorTranche = RoycoJuniorTranche(_deployTrancheProxy(address(jtImpl), "Royco Junior Tranche", "RJT"));
        liquidityTranche = RoycoLiquidityTranche(_deployTrancheProxy(address(ltImpl), "Royco Liquidity Tranche", "RLT"));
        accountant = RoycoDayAccountant(
            address(
                new ERC1967Proxy(
                    address(accImpl),
                    abi.encodeCall(RoycoDayAccountant.initialize, (_buildAccountantInitParams(params, jtYdmInitData, ltYdmInitData), address(accessManager)))
                )
            )
        );

        // Register the pool before kernel impl construction (the LT quoter constructor validates the registration),
        // sorted ascending by address exactly as the production vault registers pool tokens
        bool stSortsFirst = address(seniorTranche) < address(quoteToken);
        stPoolTokenIndex = stSortsFirst ? 0 : 1;
        IERC20[2] memory poolTokens =
            stSortsFirst ? [IERC20(address(seniorTranche)), IERC20(address(quoteToken))] : [IERC20(address(quoteToken)), IERC20(address(seniorTranche))];
        balancerVault.registerPool(address(bpt), poolTokens);
        _initializePoolMinimumSupply();

        // THE KERNEL SWAP: the plain-asset Chainlink-to-admin kernel impl instead of the shipped ERC4626 kernel
        PlainAssetKernel kernelImpl = new PlainAssetKernel(
            IRoycoDayKernel.RoycoDayKernelConstructionParams({
                seniorTranche: address(seniorTranche),
                stAsset: address(stJtUnderlying),
                juniorTranche: address(juniorTranche),
                jtAsset: address(stJtUnderlying),
                accountant: address(accountant),
                liquidityTranche: address(liquidityTranche),
                ltAsset: address(bpt),
                enforceVaultSharesTransferWhitelist: params.enforceWhitelistOnTransfer
            })
        );

        PROTOCOL_FEE_RECIPIENT = makeAddr("PROTOCOL_FEE_RECIPIENT");

        // Kernel proxy from the dedicated deployer so it lands at the predicted address
        bytes memory kernelInitData = abi.encodeCall(
            kernelImpl.initialize,
            (
                IRoycoDayKernel.RoycoDayKernelInitParams({
                    initialAuthority: address(accessManager),
                    protocolFeeRecipient: PROTOCOL_FEE_RECIPIENT,
                    stSelfLiquidationBonusWAD: params.stSelfLiquidationBonusWAD,
                    roycoBlacklist: address(0)
                }),
                PlainAssetKernel.KernelSpecificInitParams({
                    stAndJTQuoterParams: IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter.ST_JT_QuoterSpecificParams({
                        initialConversionRateWAD: INITIAL_ADMIN_RATE_WAD,
                        trancheAssetToReferenceAssetOracle: address(priceFeed),
                        gracePeriodSeconds: ORACLE_GRACE_PERIOD_SECONDS,
                        sequencerUptimeFeed: address(0),
                        stalenessThresholdSeconds: ORACLE_STALENESS_THRESHOLD_SECONDS
                    }),
                    ltQuoterParams: BalancerV3_LT_BPTOracle_Quoter.LT_QuoterSpecificParams({
                        bptOracle: address(bptOracle), maxReinvestmentSlippageWAD: params.maxReinvestmentSlippageWAD
                    })
                })
            )
        );
        vm.prank(kernelProxyDeployer);
        address kernelProxy = address(new ERC1967Proxy(address(kernelImpl), kernelInitData));
        require(kernelProxy == predictedKernel, "Test_RedeemReentrancyWindow_Tranches: kernel proxy address prediction failed");
        plainAssetKernel = PlainAssetKernel(kernelProxy);
        // The base's handle points at the same proxy so its role-wiring helpers bind the shared selectors
        kernel = ShippedKernel(kernelProxy);
        vm.label(kernelProxy, "PlainAssetKernel");

        // Wire the kernel as the senior leg's live rate provider in both price stores, mirroring production
        balancerVault.setTokenRateProvider(address(seniorTranche), kernelProxy);
        bptOracle.setTokenRateProvider(address(seniorTranche), kernelProxy);

        // Role bindings and grants, unchanged from the base (the selector surface is shared across the family)
        _wireTargetFunctionRoles();
        _wireRoleGrants();
    }
}
