// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";

/**
 * @title Test_FixedTermRedemptionGates_Kernel
 * @notice Non-fork, exact-selector revert pins for the redemption operations that FIXED_TERM blocks. The only
 *         prior guards for these newly-blocked rules lived in the mainnet-fork abstract kernel suite, so a CI run
 *         without an RPC left JT redemption and both LT redemption flows in FIXED_TERM entirely unverified. These
 *         bind them on the mock market
 * @dev Every tranche redemption pre-op syncs and then requires MarketState.PERPETUAL (RedemptionLogic), so each
 *      flow reverts DISABLED_IN_FIXED_TERM_STATE once a covered drawdown has put the market in FIXED_TERM
 */
contract Test_FixedTermRedemptionGates_Kernel is DayMarketTestBase {
    /// @dev Whole ST/JT vault shares seeded. Coverage after seed: (100 + 30) x 0.2 / 30 = 0.8667 <= 1, gate clears
    uint256 internal constant ST_SEED_WHOLE = 100;
    uint256 internal constant JT_SEED_WHOLE = 30;

    uint256 internal stUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.stAsset.decimals);
        _seedMarket(ST_SEED_WHOLE * stUnit, JT_SEED_WHOLE * stUnit);
        _enterFixedTerm();
    }

    /// @dev A covered -20% senior drawdown: coverageUtilization = ceil(104e18 x 0.2 / 4e18) = 5.2e18, above WAD and below the
    ///      6.4667e18 liquidation threshold, so the market enters FIXED_TERM with every redemption locked
    function _enterFixedTerm() internal {
        applySTPnL(-2000);
        SyncedAccountingState memory s = _sync();
        assertEq(uint8(s.marketState), uint8(MarketState.FIXED_TERM), "the covered drawdown must enter FIXED_TERM");
    }

    /// @notice A senior redemption in FIXED_TERM reverts on the PERPETUAL-only gate
    function test_RevertIf_STRedeemInFixedTerm() public {
        uint256 shares = seniorTranche.balanceOf(ST_PROVIDER) / 10;
        vm.prank(ST_PROVIDER);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        seniorTranche.redeem(shares, ST_PROVIDER, ST_PROVIDER);
    }

    /// @notice A junior redemption in FIXED_TERM reverts on the PERPETUAL-only gate (newly-blocked op)
    function test_RevertIf_JTRedeemInFixedTerm() public {
        uint256 shares = juniorTranche.balanceOf(JT_PROVIDER) / 10;
        vm.prank(JT_PROVIDER);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        juniorTranche.redeem(shares, JT_PROVIDER, JT_PROVIDER);
    }

    /// @notice An in-kind liquidity redemption in FIXED_TERM reverts on the PERPETUAL-only gate (newly-blocked op)
    function test_RevertIf_LTRedeemInKindInFixedTerm() public {
        uint256 shares = liquidityTranche.balanceOf(LT_PROVIDER) / 2;
        vm.prank(LT_PROVIDER);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        liquidityTranche.redeem(shares, LT_PROVIDER, LT_PROVIDER);
    }

    /// @notice A multi-asset liquidity redemption in FIXED_TERM reverts on the PERPETUAL-only gate (newly-blocked op)
    function test_RevertIf_LTRedeemMultiAssetInFixedTerm() public {
        uint256 shares = liquidityTranche.balanceOf(LT_PROVIDER) / 2;
        vm.prank(LT_PROVIDER);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        liquidityTranche.redeemMultiAsset(shares, 0, 0, LT_PROVIDER, LT_PROVIDER);
    }

    /// @notice The senior redeem preview reverts on the PERPETUAL-only gate in FIXED_TERM, matching the reverting redeem and the zero maxRedeem
    /// @dev previewRedeem now simulates the real kernel redemption, so the FIXED_TERM gate bubbles from the preview exactly as from exec
    function test_RevertIf_STPreviewRedeemInFixedTerm() public {
        uint256 shares = seniorTranche.balanceOf(ST_PROVIDER) / 10;
        assertEq(seniorTranche.maxRedeem(ST_PROVIDER), 0, "senior maxRedeem must already zero in FIXED_TERM, so the preview must agree");
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        seniorTranche.previewRedeem(shares);
    }

    /// @notice The junior redeem preview reverts on the PERPETUAL-only gate in FIXED_TERM, matching the reverting redeem and the zero maxRedeem
    function test_RevertIf_JTPreviewRedeemInFixedTerm() public {
        uint256 shares = juniorTranche.balanceOf(JT_PROVIDER) / 10;
        assertEq(juniorTranche.maxRedeem(JT_PROVIDER), 0, "junior maxRedeem must already zero in FIXED_TERM, so the preview must agree");
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        juniorTranche.previewRedeem(shares);
    }
}
