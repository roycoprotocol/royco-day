// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { LT_LP_ROLE } from "../../../src/factory/Roles.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toTrancheUnits } from "../../../src/libraries/Units.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_FixedTermEntrypointMatrix
 * @notice The DEPOSIT half of the FIXED_TERM per-entrypoint matrix, always-running (mock, no RPC). The redemption
 *         half is pinned by Test_FixedTermRedemptionGates_Kernel; the deposit matrix previously lived only in the
 *         RPC-gated fork kernel suite, so a CI run without an RPC left it unverified.
 * @dev Production implements a coherent middle ground: nothing that mints senior shares is allowed
 *      mid-term, everything that only deepens liquidity is. So stDeposit/jtDeposit and an ST-leg multi-asset LT
 *      deposit revert DISABLED_IN_FIXED_TERM_STATE, while an in-kind BPT LT deposit and a quote-only multi-asset
 *      LT deposit succeed.
 */
contract Test_FixedTermEntrypointMatrix is DayMarketTestBase {
    uint256 internal constant ST_SEED_WHOLE = 100;
    uint256 internal constant JT_SEED_WHOLE = 30;

    uint256 internal collateralUnit;
    uint256 internal quoteUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        collateralUnit = 10 ** uint256(cell.collateralAsset.decimals);
        quoteUnit = 10 ** uint256(cell.quoteAsset.decimals);
        _seedMarket(ST_SEED_WHOLE * collateralUnit, JT_SEED_WHOLE * collateralUnit);
        _enterFixedTerm();
    }

    /// @dev A covered -20% senior drawdown enters FIXED_TERM (coverageUtilization above WAD, below the liquidation threshold).
    function _enterFixedTerm() internal {
        applySTPnL(-2000);
        SyncedAccountingState memory s = _sync();
        assertEq(uint8(s.marketState), uint8(MarketState.FIXED_TERM), "the covered drawdown must enter FIXED_TERM");
    }

    /// @dev Mints BPT to `_to` backed by a quote-only pool leg (NAV-per-BPT stays ~1.0), for the in-kind LT deposit.
    function _mintBptTo(address _to, uint256 _bptAmount, uint256 _quoteLeg) internal {
        quoteToken.mint(address(this), _quoteLeg);
        quoteToken.approve(address(balancerVault), _quoteLeg);
        uint256[2] memory legs;
        legs[1 - stPoolTokenIndex] = _quoteLeg;
        balancerVault.mintPoolTokensTo(address(bpt), _to, _bptAmount, legs);
    }

    // ---------------------------------------------------------------------
    // Blocked in FIXED_TERM: anything that mints senior shares
    // ---------------------------------------------------------------------

    // All tranche deposits are role-gated (restricted); use the seeded role-holders (or grant the LT role to
    // fresh actors) so auth passes and the op reaches the FIXED_TERM gate.
    function test_RevertIf_STDepositInFixedTerm() public {
        stJtVault.mintShares(ST_PROVIDER, collateralUnit);
        vm.startPrank(ST_PROVIDER);
        stJtVault.approve(address(seniorTranche), collateralUnit);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        seniorTranche.deposit(toTrancheUnits(collateralUnit), ST_PROVIDER);
        vm.stopPrank();
    }

    function test_RevertIf_JTDepositInFixedTerm() public {
        stJtVault.mintShares(JT_PROVIDER, collateralUnit);
        vm.startPrank(JT_PROVIDER);
        stJtVault.approve(address(juniorTranche), collateralUnit);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        juniorTranche.deposit(toTrancheUnits(collateralUnit), JT_PROVIDER);
        vm.stopPrank();
    }

    function test_RevertIf_MultiAssetLTDepositWithSTLegInFixedTerm() public {
        address a = makeAddr("FT_LT_STLEG");
        accessManager.grantRole(LT_LP_ROLE, a, 0);
        stJtVault.mintShares(a, collateralUnit);
        quoteToken.mint(a, 10 * quoteUnit);
        vm.startPrank(a);
        stJtVault.approve(address(liquidityTranche), collateralUnit);
        quoteToken.approve(address(liquidityTranche), 10 * quoteUnit);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        liquidityTranche.depositMultiAsset(collateralUnit, 10 * quoteUnit, 0, a);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Allowed in FIXED_TERM: liquidity-only deepening
    // ---------------------------------------------------------------------

    function test_QuoteOnlyMultiAssetLTDeposit_SucceedsInFixedTerm() public {
        address a = makeAddr("FT_LT_QUOTE");
        accessManager.grantRole(LT_LP_ROLE, a, 0);
        quoteToken.mint(a, 10 * quoteUnit);
        vm.startPrank(a);
        quoteToken.approve(address(liquidityTranche), 10 * quoteUnit);
        (uint256 shares,) = liquidityTranche.depositMultiAsset(0, 10 * quoteUnit, 0, a);
        vm.stopPrank();
        assertGt(shares, 0, "quote-only multi-asset LT deposit must mint shares in FIXED_TERM");
    }

    function test_InKindLTDeposit_SucceedsInFixedTerm() public {
        address a = makeAddr("FT_LT_INKIND");
        accessManager.grantRole(LT_LP_ROLE, a, 0);
        uint256 bptAmount = 10e18;
        _mintBptTo(a, bptAmount, 10 * quoteUnit);
        vm.startPrank(a);
        bpt.approve(address(liquidityTranche), bptAmount);
        uint256 shares = liquidityTranche.deposit(toTrancheUnits(bptAmount), a);
        vm.stopPrank();
        assertGt(shares, 0, "in-kind BPT LT deposit must mint shares in FIXED_TERM");
    }
}
