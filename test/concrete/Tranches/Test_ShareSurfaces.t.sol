// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { PausableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { IERC20Errors } from "../../../lib/openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";
import { LT_LP_ROLE, ST_LP_ROLE } from "../../../src/factory/Roles.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoLiquidityTranche } from "../../../src/interfaces/IRoycoLiquidityTranche.sol";
import { IRoycoSeniorTranche } from "../../../src/interfaces/IRoycoSeniorTranche.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { AssetClaims, Operation } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { MarketParamsConfig } from "../../utils/FixtureTypes.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_ShareSurfaces_Tranches
 * @notice Exercises the tranche share-token surfaces the deposit and redemption flow suites do not reach: the
 *         kernel-only burn and mint gates, the zero-value deposit and redemption guards, delegated
 *         (allowance-path) redemptions on both the plain and multi-asset exits, the junior and liquidity
 *         share-conversion views, and the multi-asset preview quotes
 * @dev Seeded once in setUp so every derivation below is against the same wei-exact state: ST 100e18 and JT 30e18
 *      vault shares (coverage (100 + 30) x 0.2 / 30 = 0.8667 <= 1), plus the market base's auto-seeded quote-only
 *      LT depth of 6 whole quote (required ceil(100e18 x 0.05) = 5e18 plus one whole-token cushion), so the LT
 *      holds 6e18 BPT at a NAV-per-BPT of exactly 1.0
 */
contract Test_ShareSurfaces_Tranches is DayMarketTestBase {
    /// @dev A second senior LP the allowance-path tests delegate to
    address internal ST_DELEGATE;

    /// @dev A second liquidity LP the multi-asset allowance-path test delegates to
    address internal LT_DELEGATE;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        _seedMarket(100e18, 30e18);
        ST_DELEGATE = _generateActor("ST_DELEGATE", ST_LP_ROLE);
        LT_DELEGATE = _generateActor("LT_DELEGATE", LT_LP_ROLE);
    }

    /// @dev A zero AssetClaims literal for event expectations whose data payload is not checked
    function _emptyClaims() internal pure returns (AssetClaims memory claims) {
        claims;
    }

    // =============================
    // Kernel-only burn and mint gates
    // =============================

    /**
     * @notice The kernel can burn a holder's shares through its allowance, the burn path multi-asset exits rely on
     * @dev The kernel holds the burner role and burns pre-approved shares when unwinding a venue position, so the
     *      allowance-consuming burnFrom must reduce the holder's balance and the supply by exactly the burned amount
     */
    function test_BurnFrom_KernelBurnsApprovedSharesExactly() public {
        uint256 supplyBefore = seniorTranche.totalSupply();
        vm.prank(ST_PROVIDER);
        seniorTranche.approve(address(kernel), 10e18);
        vm.prank(address(kernel));
        seniorTranche.burnFrom(ST_PROVIDER, 10e18);
        assertEq(seniorTranche.balanceOf(ST_PROVIDER), 90e18, "the holder's balance must drop by exactly the burned 10e18");
        assertEq(seniorTranche.totalSupply(), supplyBefore - 10e18, "the supply must drop by exactly the burned 10e18");
    }

    /// @notice Only the kernel can mint tranche shares, and a kernel mint rejects the null receiver and the zero amount
    function test_RevertIf_MintGatesViolated() public {
        vm.expectRevert(IRoycoVaultTranche.ONLY_KERNEL.selector);
        seniorTranche.mint(address(this), 1e18);
        vm.startPrank(address(kernel));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        seniorTranche.mint(address(0), 1e18);
        vm.expectRevert(IRoycoVaultTranche.MUST_MINT_NON_ZERO_SHARES.selector);
        seniorTranche.mint(address(this), 0);
        vm.stopPrank();
    }

    /// @notice Only the kernel can mint protocol fee shares, and a zero-share fee mint is a supply-preserving no-op
    function test_MintProtocolFeeShares_KernelOnlyAndZeroIsNoOp() public {
        vm.expectRevert(IRoycoVaultTranche.ONLY_KERNEL.selector);
        seniorTranche.mintProtocolFeeShares(PROTOCOL_FEE_RECIPIENT, 1e18);

        uint256 supplyBefore = seniorTranche.totalSupply();
        vm.prank(address(kernel));
        uint256 reportedSupply = seniorTranche.mintProtocolFeeShares(PROTOCOL_FEE_RECIPIENT, 0);
        assertEq(reportedSupply, supplyBefore, "a zero-share fee mint must report the unchanged supply");
        assertEq(seniorTranche.balanceOf(PROTOCOL_FEE_RECIPIENT), 0, "a zero-share fee mint must mint nothing");
    }

    /**
     * @notice Only the kernel can mint liquidity premium shares, and a zero-share premium mint is a
     *         supply-preserving no-op that still reports and emits the current supply
     * @dev The premium mint reassigns senior appreciation to the liquidity tranche, so an open mint gate would let
     *      anyone dilute every senior holder for free — the kernel-only gate is the entire defense. A sync whose
     *      liquidity premium rounds to zero shares still calls this, so the zero path must change no balance and
     *      no supply, only surface the (unchanged) supply the kernel prices later mints against
     */
    function test_MintLiquidityPremiumShares_KernelOnlyAndZeroIsNoOp() public {
        vm.expectRevert(IRoycoVaultTranche.ONLY_KERNEL.selector);
        seniorTranche.mintLiquidityPremiumShares(address(kernel), 1e18);

        // Expected values are pre-call reads: a no-op must leave every one of them byte-identical
        uint256 supplyBefore = seniorTranche.totalSupply();
        uint256 kernelBalanceBefore = seniorTranche.balanceOf(address(kernel));
        vm.expectEmit(address(seniorTranche));
        emit IRoycoSeniorTranche.LiquidityPremiumSharesMinted(address(kernel), 0, supplyBefore);
        vm.prank(address(kernel));
        uint256 reportedSupply = seniorTranche.mintLiquidityPremiumShares(address(kernel), 0);

        assertEq(reportedSupply, supplyBefore, "a zero-share premium mint must report the unchanged supply");
        assertEq(seniorTranche.totalSupply(), supplyBefore, "a zero-share premium mint must not change the supply");
        assertEq(seniorTranche.balanceOf(address(kernel)), kernelBalanceBefore, "a zero-share premium mint must credit the kernel nothing");
    }

    // =============================
    // Paused-kernel mint surface
    // =============================

    /**
     * @notice A paused kernel admits no supply change: every kernel mint path with non-zero shares reverts
     * @dev The kernel is the market's single pause authority, and a mint is a share movement like any other — if any
     *      mint slipped through, a paused market's share count could still drift and dilute holders mid-incident. The
     *      fee, premium, and plain mints all route their balance update through the kernel's whenNotPaused hook, so a
     *      paused kernel lands all three on the same EnforcedPause
     */
    function test_RevertIf_KernelPausedAndMintsNonZeroShares() public {
        vm.prank(PAUSER);
        kernel.pause();

        vm.startPrank(address(kernel));
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        seniorTranche.mintProtocolFeeShares(PROTOCOL_FEE_RECIPIENT, 1e18);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        seniorTranche.mintLiquidityPremiumShares(address(kernel), 1e18);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        seniorTranche.mint(address(this), 1e18);
        vm.stopPrank();
    }

    /**
     * @notice While the kernel is paused, the ZERO-share fee and premium mints still succeed (returning the
     *         unchanged supply and emitting their mint events), while the plain mint reverts on its zero-shares guard
     * @dev The fee and premium mints only reach the kernel's whenNotPaused hook when they actually move shares, which
     *      a zero-share call never does, so they sail through a paused market. The plain mint reverts before any
     *      balance update, on its own MUST_MINT_NON_ZERO_SHARES guard. Nothing of value escapes: no balance or supply moves
     */
    function test_ZeroShareFeeAndPremiumMintsSucceedWhileKernelPaused_PlainMintReverts() public {
        vm.prank(PAUSER);
        kernel.pause();

        uint256 supplyBefore = seniorTranche.totalSupply();
        uint256 kernelBalanceBefore = seniorTranche.balanceOf(address(kernel));

        vm.startPrank(address(kernel));
        // The zero-share fee mint sails through the pause and still emits its mint event
        vm.expectEmit(address(seniorTranche));
        emit IRoycoVaultTranche.ProtocolFeeSharesMinted(PROTOCOL_FEE_RECIPIENT, 0, supplyBefore);
        uint256 feeReportedSupply = seniorTranche.mintProtocolFeeShares(PROTOCOL_FEE_RECIPIENT, 0);
        // So does the zero-share premium mint
        vm.expectEmit(address(seniorTranche));
        emit IRoycoSeniorTranche.LiquidityPremiumSharesMinted(address(kernel), 0, supplyBefore);
        uint256 premiumReportedSupply = seniorTranche.mintLiquidityPremiumShares(address(kernel), 0);
        // The plain mint refuses the same zero-share call on its own zero-shares guard, before any balance update
        vm.expectRevert(IRoycoVaultTranche.MUST_MINT_NON_ZERO_SHARES.selector);
        seniorTranche.mint(address(this), 0);
        vm.stopPrank();

        assertEq(feeReportedSupply, supplyBefore, "the paused zero-share fee mint must report the unchanged supply");
        assertEq(premiumReportedSupply, supplyBefore, "the paused zero-share premium mint must report the unchanged supply");
        // Only the events escape the pause: no supply or balance may have moved
        assertEq(seniorTranche.totalSupply(), supplyBefore, "no supply change may escape the pause");
        assertEq(seniorTranche.balanceOf(PROTOCOL_FEE_RECIPIENT), 0, "the fee recipient must be credited nothing while paused");
        assertEq(seniorTranche.balanceOf(address(kernel)), kernelBalanceBefore, "the kernel must be credited nothing while paused");
    }

    /**
     * @notice A paused kernel bricks the kernel-only burn and burnFrom, so a paused market can never destroy shares
     * @dev burn and burnFrom carry no pause modifier of their own, only the BURNER_ROLE gate, so their freeze under a
     *      pause rides entirely on the _update -> preTrancheBalanceUpdateHook path, which reverts EnforcedPause. The
     *      hook fires before the balance is touched, so no share moves and the reverted burnFrom consumes no allowance
     */
    function test_RevertIf_KernelPausedAndBurns() public {
        uint256 ownerBalanceBefore = seniorTranche.balanceOf(ST_PROVIDER);

        // burnFrom needs a standing allowance so it reaches the balance update rather than the allowance guard
        vm.prank(ST_PROVIDER);
        seniorTranche.approve(address(kernel), 1e18);

        vm.prank(PAUSER);
        kernel.pause();

        vm.startPrank(address(kernel));
        // A burn of the caller's own shares reverts on the hook before any balance decrement
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        seniorTranche.burn(1e18);
        // burnFrom clears the allowance guard, then reverts on the same hook
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        seniorTranche.burnFrom(ST_PROVIDER, 1e18);
        vm.stopPrank();

        // No share burned and the reverted burnFrom left the allowance intact
        assertEq(seniorTranche.balanceOf(ST_PROVIDER), ownerBalanceBefore, "no share may burn while the kernel is paused");
        assertEq(seniorTranche.allowance(ST_PROVIDER, address(kernel)), 1e18, "the reverted burnFrom must not consume the allowance");
    }

    // =============================
    // Zero-value deposit and redemption guards
    // =============================

    /**
     * @notice A deposit of zero assets is rejected, no free share can ever be minted
     * @dev The kernel's post-operation validation fires first: a zero-asset deposit moves the senior raw NAV by
     *      zero, which fails the deposit's required positive delta before the tranche's own zero-value guard runs
     */
    function test_RevertIf_DepositMovesNoValue() public {
        vm.prank(ST_PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        seniorTranche.deposit(toTrancheUnits(0), ST_PROVIDER);
    }

    /// @notice Deposits and redemptions reject the null receiver, and redemptions reject a zero share count
    function test_RevertIf_NullReceiverOrZeroShares() public {
        vm.startPrank(ST_PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        seniorTranche.deposit(toTrancheUnits(1e18), address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        seniorTranche.redeem(1e18, address(0), ST_PROVIDER);
        vm.expectRevert(IRoycoVaultTranche.MUST_REQUEST_NON_ZERO_SHARES.selector);
        seniorTranche.redeem(0, ST_PROVIDER, ST_PROVIDER);
        vm.stopPrank();
    }

    // =============================
    // Delegated (allowance-path) redemptions
    // =============================

    /**
     * @notice A delegate with an allowance can redeem the owner's senior shares, receiving the assets itself
     * @dev All senior value is backed by senior raw NAV (no losses have occurred), so redeeming 10e18 of the 100e18
     *      senior shares pays out its proportional slice, scaled against the effective supply (100e18 + 1e6) so the
     *      redeemer leaves one virtual-dust sliver behind: floor(100e18 x 10e18 / (100e18 + 1e6)) =
     *      9999999999999900000 vault shares, and the claim values to the same NAV floor((100e18 + 1) x 10e18 / (100e18 + 1e6))
     */
    function test_Redeem_DelegateSpendsAllowanceAndReceivesAssets() public {
        vm.prank(ST_PROVIDER);
        seniorTranche.approve(ST_DELEGATE, 10e18);
        uint256 delegateAssetsBefore = stJtVault.balanceOf(ST_DELEGATE);
        // The redemption emits Redeem with the exact claims: the 10e18-share slice net of the virtual-dust sliver
        vm.expectEmit(address(seniorTranche));
        emit IRoycoVaultTranche.Redeem(
            ST_DELEGATE,
            ST_DELEGATE,
            AssetClaims({
                stAssets: toTrancheUnits(9_999_999_999_999_900_000),
                jtAssets: toTrancheUnits(0),
                ltAssets: toTrancheUnits(0),
                stShares: 0,
                nav: toNAVUnits(uint256(9_999_999_999_999_900_000))
            }),
            10e18
        );
        vm.prank(ST_DELEGATE);
        seniorTranche.redeem(10e18, ST_DELEGATE, ST_PROVIDER);

        assertEq(seniorTranche.balanceOf(ST_PROVIDER), 90e18, "the owner's shares must drop by the delegated 10e18");
        assertEq(seniorTranche.allowance(ST_PROVIDER, ST_DELEGATE), 0, "the delegate's allowance must be fully consumed");
        assertEq(
            stJtVault.balanceOf(ST_DELEGATE) - delegateAssetsBefore,
            9_999_999_999_999_900_000,
            "the delegate receives the 10e18-share slice net of the virtual-dust sliver"
        );
    }

    /**
     * @notice A delegate with an allowance can multi-asset redeem the owner's liquidity shares down to the quote leg
     * @dev The seeded pool is quote-only, so removing 0.5e18 of the 6e18 LT shares returns no senior shares and the
     *      proportional quote leg. The BPT claim scales against the effective supply (S + 1e6), so it lands one
     *      virtual-dust sliver below the naive proportional share: floor(6e18 x 0.5e18 / (6e18 + 1e6)) =
     *      499999999999916666 BPT, which unwinds to floor(6000001 x 499999999999916666 / 6.000001e18) = 499999 quote-wei
     */
    function test_RedeemMultiAsset_DelegateSpendsAllowanceAndReceivesQuote() public {
        vm.prank(LT_PROVIDER);
        liquidityTranche.approve(LT_DELEGATE, 0.5e18);
        // The multi-asset exit emits MultiAssetRedeem naming the delegate as caller and receiver and the owner it redeemed for
        vm.expectEmit(true, true, true, false, address(liquidityTranche));
        emit IRoycoLiquidityTranche.MultiAssetRedeem(LT_DELEGATE, LT_DELEGATE, LT_PROVIDER, 0, _emptyClaims(), 0);
        vm.prank(LT_DELEGATE);
        (AssetClaims memory stClaims, uint256 quoteAssets) = liquidityTranche.redeemMultiAsset(0.5e18, 0, 0, LT_DELEGATE, LT_PROVIDER);

        assertEq(quoteAssets, 499_999, "the quote-only pool slice unwinds to 499999 quote-wei, one dust below the naive half");
        assertEq(toUint256(stClaims.stAssets), 0, "no senior leg exists in the quote-only pool to unwind");
        assertEq(quoteToken.balanceOf(LT_DELEGATE), 499_999, "the delegate must receive the unwound quote");
        assertEq(liquidityTranche.balanceOf(LT_PROVIDER), 5.5e18, "the owner's LT shares must drop by the delegated 0.5e18");
        assertEq(liquidityTranche.allowance(LT_PROVIDER, LT_DELEGATE), 0, "the delegate's allowance must be fully consumed");
    }

    // =============================
    // Junior and liquidity share-conversion views
    // =============================

    /**
     * @notice The junior and liquidity conversion views price one whole asset into ~one share at the seeded 1.0 rates,
     *         biased up by the virtual-shares offset (VIRTUAL_SHARES = 1e6 over VIRTUAL_VALUE = 1)
     * @dev Every conversion prices against the effective supply (S + 1e6) over (effNAV + 1): the fresh 1:1 rate is
     *      perturbed by a floor(1e6 x value / (effNAV + 1)) sliver, negligible at real NAV scale but pinned exactly.
     *      Junior: floor((30e18 + 1e6) x 1e18 / (30e18 + 1)) = 1e18 + floor(1e6 / 30) = 1000000000000033333.
     *      Liquidity: floor((6e18 + 1e6) x 1e18 / (6e18 + 1)) = 1e18 + floor(1e6 / 6) = 1000000000000166666
     */
    function test_ConvertToShares_JuniorAndLiquidityPriceAtSeededRates() public view {
        assertEq(
            juniorTranche.convertToShares(toTrancheUnits(1e18)),
            1_000_000_000_000_033_333,
            "one whole vault share converts to one junior share plus the virtual-offset sliver"
        );
        assertEq(
            liquidityTranche.convertToShares(toTrancheUnits(1e18)),
            1_000_000_000_000_166_666,
            "one whole BPT converts to one liquidity share plus the virtual-offset sliver"
        );
    }

    // =============================
    // Multi-asset preview quotes
    // =============================

    /**
     * @notice A quote-only multi-asset deposit preview quotes shares at the pool's linear fair value
     * @dev 1000 whole quote (1000e6) adds 1000e18 NAV, minting 1000e18 BPT at the mock venue's fair-value pricing,
     *      and LT shares are minted against the effective supply (6e18 + 1e6) over (6e18 + 1):
     *      floor((6e18 + 1e6) x 1000e18 / (6e18 + 1)) = 1000e18 + the virtual-offset sliver = 1000000000000166666499
     */
    function test_PreviewDepositMultiAsset_QuoteOnlyQuotesFairValueShares() public {
        (uint256 shares,) = liquidityTranche.previewDepositMultiAsset(0, 1000e6);
        assertEq(shares, 1_000_000_000_000_166_666_499, "1000 whole quote previews 1000e18 LT shares plus the virtual-offset sliver");
    }

    /**
     * @notice A multi-asset redemption preview quotes the exact proportional quote-leg unwind
     * @dev 1e18 of the 6e18 LT shares claims floor(6e18 x 1e18 / (6e18 + 1e6)) = 999999999999833333 BPT (one
     *      virtual-dust sliver below 1e18), and the quote-only pool holds 6000001 quote-wei over a 6.000001e18 BPT
     *      supply, so the removal quotes floor(6000001 x 999999999999833333 / 6.000001e18) = 999999 quote-wei
     */
    function test_PreviewRedeemMultiAsset_QuotesProportionalQuoteLeg() public {
        (AssetClaims memory stClaims, uint256 quoteAssets) = liquidityTranche.previewRedeemMultiAsset(1e18);
        assertEq(quoteAssets, 999_999, "the preview quotes 999999 quote-wei, one dust below the naive proportional leg");
        assertEq(toUint256(stClaims.stAssets), 0, "the quote-only pool has no senior leg to preview");
    }

    // =============================
    // Allowance and burn-gate abuse (adversarial)
    // =============================

    /**
     * @notice A delegate cannot redeem one wei more than its allowance, and the failed attempt consumes nothing
     * @dev The allowance is the only thing standing between a delegate and the owner's whole position, so the
     *      exact OZ insufficient-allowance revert (spender, allowance 5e18, needed 10e18) is pinned
     */
    function test_RevertIf_DelegateRedeemsBeyondAllowance() public {
        vm.prank(ST_PROVIDER);
        seniorTranche.approve(ST_DELEGATE, 5e18);
        vm.prank(ST_DELEGATE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ST_DELEGATE, 5e18, 10e18));
        seniorTranche.redeem(10e18, ST_DELEGATE, ST_PROVIDER);

        assertEq(seniorTranche.balanceOf(ST_PROVIDER), 100e18, "the owner's shares must be untouched by the failed redemption");
        assertEq(seniorTranche.allowance(ST_PROVIDER, ST_DELEGATE), 5e18, "the failed redemption must not consume allowance");
    }

    /**
     * @notice An allowance alone cannot burn tranche shares: burnFrom is role-gated, so a non-burner holding a
     *         full approval is still rejected before the allowance is even read
     * @dev An attacker who phishes an approval must not be able to destroy the victim's shares (a burn moves the
     *      share price for everyone else), so the access-manager gate is pinned with the exact caller-named error
     */
    function test_RevertIf_NonBurnerCallsBurnFromWithFullAllowance() public {
        address attacker = makeAddr("BURN_ATTACKER");
        uint256 supplyBefore = seniorTranche.totalSupply();
        vm.prank(ST_PROVIDER);
        seniorTranche.approve(attacker, 100e18);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, attacker));
        seniorTranche.burnFrom(ST_PROVIDER, 100e18);

        assertEq(seniorTranche.balanceOf(ST_PROVIDER), 100e18, "no share may be burned without the burner role");
        assertEq(seniorTranche.totalSupply(), supplyBefore, "the supply must be untouched");
    }
}

/**
 * @title Test_IdleLiquidityPremiumRedemption_LiquidityTranche
 * @notice A holder who redeems in kind while idle liquidity premium senior shares are still held by the kernel
 *         (not yet deployed into the pool) receives its pro-rata slice of those idle shares directly, alongside
 *         its BPT slice — the premium is claimable on exit, never stranded with the kernel
 * @dev Runs on zero protocol fees so every fee and liquidity premium share mint literal below stays a two-term
 *      derivation. The venue's slippage mode is armed so the sync's single-sided premium deploy fails and the
 *      whole premium stays idle as ltOwnedSeniorTrancheShares
 */
contract Test_IdleLiquidityPremiumRedemption_LiquidityTranche is DayMarketTestBase {
    /// @dev defaultParams with every protocol fee zeroed, so no fee shares perturb the supplies below
    function _zeroFeeParams() internal pure returns (MarketParamsConfig memory p) {
        p = defaultParams();
        p.stProtocolFeeWAD = 0;
        p.jtProtocolFeeWAD = 0;
        p.jtYieldShareProtocolFeeWAD = 0;
        p.ltYieldShareProtocolFeeWAD = 0;
    }

    function setUp() public {
        _deployMarket(cellA(), _zeroFeeParams());
        // ST 100e18 / JT 30e18 vault shares, coverage (100 + 30) x 0.2 / 30 = 0.8667 <= 1, LT auto-seed 6e18 quote-only depth
        _seedMarket(100e18, 30e18);
        // Arm persistent venue slippage so the premium's single-sided add always fails and the mint stays staged
        setVenueSlippageMode(true);
    }

    /**
     * @notice The staged premium's pro-rata slice is paid out in senior shares on an in-kind redemption
     * @dev Full derivation of every literal (zero fees, pinned LT yield share 0.1, pinned JT yield share 0.2). Every
     *      share conversion prices against the effective supply (S + VIRTUAL_SHARES = S + 1e6) over (effNAV + 1):
     *      +100% shared PnL: stGain 100e18 -> jtRiskPremium 20e18, ltLiquidityPremium 10e18, stEff 180e18.
     *      Premium shares = floor((100e18 + 1e6) x 10e18 / (170e18 + 1)) = 5882352941176529411, staged (deploy fails).
     *      Depth top-up: 12e18 quote-only BPT deposited; the depositor's shares price at the LT effective NAV
     *      6e18 + floor((180e18 + 1) x staged / (100e18 + staged + 1e6)) = 6e18 + 9999999999999999998 = 15999999999999999998,
     *      so it mints floor((6e18 + 1e6) x 12e18 / (15999999999999999998 + 1)) = 4500000000000750000, LT supply 10500000000000750000, depth 18e18.
     *      Redeeming 3e18 of that supply claims floor(18e18 x 3e18 / (supply + 1e6)) = 5142857142856285714 BPT and
     *      floor(staged x 3e18 / (supply + 1e6)) = 1680672268907299719 staged senior shares, leaving
     *      5882352941176529411 - 1680672268907299719 = 4201680672269229692 staged with the kernel
     */
    function test_Redeem_InKind_PaysIdleLiquidityPremiumSliceDirectly() public {
        // Accrue the premium and commit it staged (slippage mode blocks the single-sided deploy)
        applySTPnL(10_000);
        _warpAndRefreshFeed(1 days);
        _sync();
        assertEq(kernel.getState().ltOwnedSeniorTrancheShares, 5_882_352_941_176_529_411, "the whole premium must stay staged behind the slippage gate");

        // Top up quote-only depth so the post-redemption liquidity requirement (9e18 against 180e18 senior) clears
        address depthProvider = makeAddr("DEPTH_PROVIDER");
        accessManager.grantRole(LT_LP_ROLE, depthProvider, 0);
        quoteToken.mint(address(this), 12e6);
        quoteToken.approve(address(balancerVault), 12e6);
        uint256[2] memory quoteOnlyLegs;
        quoteOnlyLegs[1 - stPoolTokenIndex] = 12e6;
        balancerVault.mintPoolTokensTo(address(bpt), depthProvider, 12e18, quoteOnlyLegs);
        vm.startPrank(depthProvider);
        bpt.approve(address(liquidityTranche), 12e18);
        uint256 depthShares = liquidityTranche.deposit(toTrancheUnits(12e18), depthProvider);
        vm.stopPrank();
        assertEq(depthShares, 4_500_000_000_000_750_000, "the top-up mints floor((6e18 + 1e6) x 12e18 / (15999999999999999998 + 1)) LT shares");

        // The provider redeems 3e18 of the 10.5e18 LT shares in kind and must receive BOTH legs of its slice
        uint256 stSharesBefore = seniorTranche.balanceOf(LT_PROVIDER);
        uint256 bptBefore = bpt.balanceOf(LT_PROVIDER);
        vm.prank(LT_PROVIDER);
        AssetClaims memory claims = liquidityTranche.redeem(3e18, LT_PROVIDER, LT_PROVIDER);

        assertEq(toUint256(claims.ltAssets), 5_142_857_142_856_285_714, "the BPT slice must be floor(18e18 x 3e18 / (supply + 1e6))");
        assertEq(claims.stShares, 1_680_672_268_907_299_719, "the staged-premium slice must be floor(staged x 3e18 / (supply + 1e6))");
        assertEq(bpt.balanceOf(LT_PROVIDER) - bptBefore, 5_142_857_142_856_285_714, "the redeemer must receive its BPT slice in kind");
        assertEq(
            seniorTranche.balanceOf(LT_PROVIDER) - stSharesBefore,
            1_680_672_268_907_299_719,
            "the redeemer must receive its staged premium slice as senior shares"
        );
        assertEq(kernel.getState().ltOwnedSeniorTrancheShares, 4_201_680_672_269_229_692, "the kernel's staged pile must drop by exactly the paid slice");
    }
}
