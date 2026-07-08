// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { MarketParamsConfig } from "../../utils/FixtureTypes.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";

/**
 * @title Test_TrancheTransferWhitelist_Kernel
 * @notice Exercises the kernel's tranche-transfer whitelist on a market deployed with the whitelist enforced:
 *         every share mint and transfer routes through the kernel's pre-balance-update hook, which requires the
 *         receiver to be a whitelisted depositor for the tranche AND to not be the market's authority itself
 * @dev The authority carve-out is load-bearing on its own: the access manager answers its own canCall query with
 *      true whenever it is mid-execute on the exact target and selector being screened, so the role half of the
 *      check cannot screen the authority — only the explicit `_to != authority` conjunct keeps tranche shares from
 *      being parked on the access manager, where anyone able to route a call through execute could control them
 * @dev Burns are the mirror image: a burn's receiver is address(0), which holds no role, so the hook must (and
 *      does) skip the whitelist for burns or every redemption on an enforcing market would revert
 */
contract Test_TrancheTransferWhitelist_Kernel is DayMarketTestBase {
    function setUp() public {
        // Every test in this suite runs on a market that enforces the tranche-transfer whitelist. All seeding is
        // done at flat PnL: a senior gain would make the next sync mint the liquidity premium as senior shares to
        // the kernel, which this same whitelist hook rejects (pinned by test_DIVERGENCE_11 in
        // Test_PremiumMintDivergences), and that unrelated brick would mask what these tests isolate
        MarketParamsConfig memory p = defaultParams();
        p.enforceWhitelistOnTransfer = true;
        _deployMarket(cellA(), p);
    }

    /**
     * @notice On a whitelist-enforcing market, a liquidity tranche share transfer to a fresh address succeeds
     *         (LT deposits are public, so every ordinary address is a whitelisted LT depositor), while the SAME
     *         amount from the SAME sender to the access manager reverts ACCOUNT_NOT_WHITELISTED_TRANCHE_LP
     * @dev Since the public deposit role whitelists every ordinary receiver, the pair isolates receiver identity
     *      as the only discriminant: the authority is the one address the hook must reject no matter what, because
     *      shares held by the access manager would be controlled by whoever can route calls through its execute
     */
    function test_TransferToAuthority_RevertsAsNotWhitelistedTrancheLP_OnWhitelistEnforcingMarket() public {
        // Seed LT_PROVIDER with LT shares through the production deposit path: a 5e6 quote-wei leg (5.0 units of
        // the 6-decimal quote at its 1.0 price) is worth 5e18 in 18-decimal NAV, backing 5e18 BPT at the pool's
        // genesis NAV-per-BPT of exactly 1.0, and the first LT deposit mints 1 share-wei per NAV-wei, so
        // LT_PROVIDER holds exactly 5e18 LT shares
        _seedLT(5e18, 0, 5e6);
        assertEq(liquidityTranche.balanceOf(LT_PROVIDER), 5e18, "the quote-only seed must mint exactly 5e18 LT shares to LT_PROVIDER");

        // Leg 1: transfer 2e18 shares to a fresh, role-less address. LT deposits are public, so the hook's
        // receiver check passes for any ordinary address and the transfer moves exactly the requested amount
        address recipient = makeAddr("FRESH_LT_RECIPIENT");
        vm.prank(LT_PROVIDER);
        liquidityTranche.transfer(recipient, 2e18);
        assertEq(liquidityTranche.balanceOf(recipient), 2e18, "the fresh receiver must gain exactly the transferred shares");
        assertEq(liquidityTranche.balanceOf(LT_PROVIDER), 3e18, "the sender must lose exactly the transferred shares (5e18 - 2e18)");

        // Leg 2: the identical transfer to the access manager. Everything else about the call is unchanged, so
        // the revert can only come from the receiver's identity: the hook rejects the market's own authority
        vm.prank(LT_PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayKernel.ACCOUNT_NOT_WHITELISTED_TRANCHE_LP.selector, address(accessManager)));
        liquidityTranche.transfer(address(accessManager), 2e18);

        // The failed transfer must leave every balance untouched
        assertEq(liquidityTranche.balanceOf(LT_PROVIDER), 3e18, "the rejected transfer must not move the sender's shares");
        assertEq(liquidityTranche.balanceOf(address(accessManager)), 0, "the authority must never end up holding tranche shares");
    }

    /**
     * @notice The access manager cannot deposit into the liquidity tranche WITH ITSELF as the share receiver, even
     *         through its own execute path where its canCall answer is true: the deposit reverts
     *         ACCOUNT_NOT_WHITELISTED_TRANCHE_LP(accessManager) and no shares are minted to it
     * @dev This pins the `_to != authority` conjunct of the hook as load-bearing. Mid-execute, the access manager
     *      resolves canCall(accessManager, liquidityTranche, deposit) to true from its is-executing marker (and LT
     *      deposits are public besides), so the role half of the whitelist check PASSES for the authority — if the
     *      explicit authority carve-out were dropped, this exact call would park tranche shares on the access
     *      manager, where anyone able to route the matching call through execute could move or redeem them
     */
    function test_AccessManagerExecuteDepositToItself_RevertsDespiteExecutionContextCanCall() public {
        // Fund the access manager with 5e18 BPT backed by a real 5e6 quote-wei pool leg (worth 5e18 NAV at the
        // quote's 1.0 price), so the deposit attempt is fully collateralized and would mint nonzero shares
        quoteToken.mint(address(this), 5e6);
        quoteToken.approve(address(balancerVault), 5e6);
        uint256[2] memory legs;
        legs[1 - stPoolTokenIndex] = 5e6;
        balancerVault.mintPoolTokensTo(address(bpt), address(accessManager), 5e18, legs);

        // The tranche pulls the deposit assets from its caller, so the access manager must approve it first
        vm.prank(address(accessManager));
        bpt.approve(address(liquidityTranche), 5e18);

        // Route the deposit through the access manager's own execute: LT deposit is public so execute admits the
        // call, and mid-execute the manager's canCall answers true for itself on this exact target and selector.
        // The deposit runs all the way to the share mint, whose balance-update hook screens the receiver — and the
        // ONLY conjunct left standing against the authority is `_to != authority`
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayKernel.ACCOUNT_NOT_WHITELISTED_TRANCHE_LP.selector, address(accessManager)));
        accessManager.execute(address(liquidityTranche), abi.encodeCall(IRoycoVaultTranche.deposit, (toTrancheUnits(5e18), address(accessManager))));

        // The revert must unwind the whole deposit: no shares minted, and the BPT never left the access manager
        assertEq(liquidityTranche.balanceOf(address(accessManager)), 0, "the blocked deposit must mint no shares to the authority");
        assertEq(bpt.balanceOf(address(accessManager)), 5e18, "the reverted deposit must return the full BPT collateral to the authority");
    }

    /**
     * @notice A senior tranche redemption succeeds on a whitelist-enforcing market: the share burn's receiver is
     *         address(0), which holds no role, so the hook must skip the receiver whitelist for burns — if it were
     *         consulted, every redemption on an enforcing market would revert and holders could never exit
     * @dev The market is seeded at flat PnL so the redemption's pre-op sync books no senior gain: a gain would
     *      mint the liquidity premium as senior shares to the kernel, and that mint's own whitelist rejection
     *      (a separate, known behavior pinned in Test_PremiumMintDivergences) would mask this burn-path result
     */
    function test_Redeem_SucceedsOnWhitelistEnforcingMarket_BurnSkipsReceiverWhitelist() public {
        // Seed 100e18 ST / 30e18 JT vault shares at the flat 1.0 rate and 1.0 feed, so 1 vault share == 1 NAV
        // unit and the genesis deposits mint 1 share-wei per NAV-wei: ST_PROVIDER holds exactly 100e18 ST shares.
        // Coverage after seeding: (100 + 30) x 0.2 / 30 = 0.8667 <= 1, so both deposits clear their gates
        _seedMarket(100e18, 30e18);
        assertEq(seniorTranche.balanceOf(ST_PROVIDER), 100e18, "the flat genesis seed must mint exactly 100e18 senior shares");
        uint256 vaultSharesBefore = stJtVault.balanceOf(ST_PROVIDER);

        // Partial redemption of 40e18 of the 100e18 senior shares. Everything is still flat, so the pro-rata
        // slice is 40e18 / 100e18 of the 100e18 vault shares the senior tranche owns = exactly 40e18 vault
        // shares, with no premium, fee, or self-liquidation-bonus leg to distort it
        vm.prank(ST_PROVIDER);
        AssetClaims memory claims = seniorTranche.redeem(40e18, ST_PROVIDER, ST_PROVIDER);

        // The burn (receiver address(0)) sailed past the whitelist, and the exit paid exactly the pro-rata slice
        assertEq(toUint256(claims.stAssets), 40e18, "the redemption must claim exactly the pro-rata 40e18 vault shares");
        assertEq(seniorTranche.balanceOf(ST_PROVIDER), 60e18, "the share balance must drop by exactly the redeemed shares (100e18 - 40e18)");
        assertEq(stJtVault.balanceOf(ST_PROVIDER) - vaultSharesBefore, 40e18, "the redeemer's asset balance must grow by exactly the returned vault shares");
    }
}
