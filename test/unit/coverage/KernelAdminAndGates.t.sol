// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVaultErrors } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultErrors.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { toTrancheUnits } from "../../../src/libraries/Units.sol";
import { defaultParams } from "../../base/fixtures/MarketParams.sol";
import { cellA } from "../../base/fixtures/TokenConfigs.sol";
import { TrancheFixture } from "../../base/fixtures/TrancheFixture.sol";

/**
 * @title KernelAdminAndGatesTest
 * @notice Exercises the kernel's admin setter surface (protocol fee recipient, senior self-liquidation bonus,
 *         blacklist wiring), its caller gates (the tranche-only balance-update hook and the self-call-only venue
 *         drivers), and the senior share rate provider's cold-cache path
 * @dev These are thin but load-bearing surfaces: a mis-wired setter silently redirects protocol fees, an open
 *      caller gate lets an outsider drive the venue with the kernel's custody, and a wrong cold rate misprices
 *      the pool's senior leg on the first interaction of a transaction
 */
contract KernelAdminAndGatesTest is TrancheFixture {
    function setUp() public {
        _deployMarket(cellA(), defaultParams());
    }

    // =============================
    // Admin setters, happy paths
    // =============================

    /// @notice The kernel admin can redirect protocol fees to a new recipient, and the change lands in storage with its event
    function test_SetProtocolFeeRecipient_updatesStateAndEmits() public {
        address newRecipient = makeAddr("NEW_FEE_RECIPIENT");
        vm.expectEmit(address(kernel));
        emit IRoycoDayKernel.ProtocolFeeRecipientUpdated(newRecipient);
        vm.prank(KERNEL_ADMIN);
        kernel.setProtocolFeeRecipient(newRecipient);
        assertEq(kernel.getState().protocolFeeRecipient, newRecipient, "the fee recipient must be replaced in kernel storage");
    }

    /// @notice Redirecting protocol fees to the null address is rejected, fees must always have a live destination
    function test_RevertIf_ProtocolFeeRecipientSetToNullAddress() public {
        vm.prank(KERNEL_ADMIN);
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        kernel.setProtocolFeeRecipient(address(0));
    }

    /// @notice The kernel admin can retune the senior self-liquidation bonus, and the change lands in storage with its event
    function test_SetSeniorTrancheSelfLiquidationBonus_updatesStateAndEmits() public {
        // The deployed market ships 0.01e18 (defaultParams), the admin moves it to 0.025e18 (2.5%)
        uint64 newBonusWAD = 0.025e18;
        vm.expectEmit(address(kernel));
        emit IRoycoDayKernel.SeniorTrancheSelfLiquidationBonusUpdated(newBonusWAD);
        vm.prank(KERNEL_ADMIN);
        kernel.setSeniorTrancheSelfLiquidationBonus(newBonusWAD);
        assertEq(kernel.getState().stSelfLiquidationBonusWAD, newBonusWAD, "the self-liquidation bonus must be replaced in kernel storage");
    }

    /// @notice The market ops admin can wire and unwire the blacklist contract, and each change lands with its event
    function test_SetRoycoBlacklist_wiresAndUnwiresScreening() public {
        address blacklist = makeAddr("BLACKLIST_STAND_IN");
        vm.expectEmit(address(kernel));
        emit IRoycoDayKernel.RoycoBlacklistUpdated(blacklist);
        vm.prank(MARKET_OPS_ADMIN);
        kernel.setRoycoBlacklist(blacklist);
        assertEq(kernel.getState().roycoBlacklist, blacklist, "the blacklist must be wired in kernel storage");

        // The null address disables screening entirely, so unwiring must also land
        vm.prank(MARKET_OPS_ADMIN);
        kernel.setRoycoBlacklist(address(0));
        assertEq(kernel.getState().roycoBlacklist, address(0), "the null address must unwire the blacklist");
    }

    // =============================
    // Caller gates
    // =============================

    /// @notice The balance-update hook only accepts the three tranches as callers, any outsider is rejected
    function test_RevertIf_BalanceUpdateHookCalledByNonTranche() public {
        vm.expectRevert(IRoycoDayKernel.ONLY_TRANCHE.selector);
        kernel.preTrancheBalanceUpdateHook(address(this), address(this), makeAddr("RECIPIENT"), 1);
    }

    /// @notice Every venue driver is a kernel self-call seam, an external caller is rejected on each of the five entrypoints
    function test_RevertIf_VenueDriversCalledExternally() public {
        vm.expectRevert(IRoycoDayKernel.ONLY_SELF.selector);
        kernel.addLiquidity(1e18, 1e6, toTrancheUnits(0));
        vm.expectRevert(IRoycoDayKernel.ONLY_SELF.selector);
        kernel.removeLiquidity(toTrancheUnits(1e18), 0, 0, address(this));
        vm.expectRevert(IRoycoDayKernel.ONLY_SELF.selector);
        kernel.previewAddLiquidity(1e18, 1e6);
        vm.expectRevert(IRoycoDayKernel.ONLY_SELF.selector);
        kernel.previewRemoveLiquidity(toTrancheUnits(1e18));
        vm.expectRevert(IRoycoDayKernel.ONLY_SELF.selector);
        kernel.attemptLiquidityPremiumReinvestment(type(uint256).max, ZERO_NAV_UNITS, 0);
    }

    /// @notice The Balancer callbacks only accept the vault as caller, so no one can forge a settlement frame around the kernel's custody
    function test_RevertIf_BalancerCallbacksCalledByNonVault() public {
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        kernel.addBalancerV3Liquidity(false, 1e18, 1e6, toTrancheUnits(0));
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        kernel.removeBalancerV3Liquidity(false, toTrancheUnits(1e18), 0, 0, address(this));
    }

    // =============================
    // Senior share rate provider, cold-cache paths
    // =============================

    /**
     * @notice Before any senior shares exist the cold-cache rate resolves to the 1-wei floor
     * @dev With zero supply the effective NAV per share is 0, and the pool would reject a zero rate, so the provider
     *      floors it at 1 wei. This is inert: an unseeded market has an empty senior pool leg for the rate to scale
     */
    function test_GetRate_unseededMarketFloorsAtOneWei() public view {
        // No kernel operation has run in this transaction, so the transient rate cache is cold and the provider
        // derives the rate live: _convertToValue(1e18 shares, supply 0, stEff 0) = 0, floored to 1 wei
        assertEq(kernel.getRate(), 1, "the cold-cache rate on an unseeded market must be the 1-wei floor");
    }
}

/**
 * @title KernelColdRateSeededTest
 * @notice The rate provider's cold-cache derivation on a seeded market, isolated in its own contract so the
 *         seeding runs in setUp (a separate transaction) and the test body's first kernel touch is truly cache-cold
 */
contract KernelColdRateSeededTest is TrancheFixture {
    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        // JT 30 shares first (coverage), then ST 100 shares: coverage after seed = (100 + 30) x 0.2 / 30 = 0.8667 <= 1
        _seedMarket(100e18, 30e18);
    }

    /**
     * @notice On a freshly seeded market the cold-cache rate is exactly 1.0, the first mint's NAV per share
     * @dev The transient cache written by setUp's deposits cleared when that transaction ended, so this read takes
     *      the live-derivation path: stEffectiveNAV 100e18 over 100e18 shares = 1e18 per whole share
     */
    function test_GetRate_seededMarketDerivesCommittedNavPerShare() public view {
        assertEq(kernel.getRate(), 1e18, "the cold-cache rate must be stEffectiveNAV / supply = 100e18 / 100e18 = 1.0");
    }

    /// @notice The quote asset getter resolves the pool's non-senior token, the stable the LT market-makes against
    function test_QuoteAsset_resolvesPoolQuoteToken() public view {
        assertEq(kernel.QUOTE_ASSET(), address(quoteToken), "QUOTE_ASSET must be the pool token that is not the senior tranche share");
    }
}
