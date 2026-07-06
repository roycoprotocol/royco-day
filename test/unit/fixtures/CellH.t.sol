// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { toUint256 } from "../../../src/libraries/Units.sol";
import { FixtureCell } from "../../base/fixtures/FixtureTypes.sol";
import { cellH } from "../../base/fixtures/TokenConfigs.sol";
import { TrancheFixtureSmoke } from "./TrancheFixtureSmoke.sol";

/**
 * @title CellHSmokeNightlyCells
 * @notice Smoke battery on cell H: a rebasing ST/JT vault underlying (balance reads scale by a settable index),
 *         over the baseline 4626(18,18) shares and 6-decimal quote
 * @dev The inherited battery's exact constants hold unchanged: the rebase index starts at 1.0 and no smoke flow
 *      moves it, and even a moved index cannot reach a tranche mark because the market custodies the 4626 SHARE,
 *      whose assets-per-share rate moves only via the explicit PnL feed. Rebase-driven yield therefore models as
 *      a rate move (applySTPnL), never as a silent balance drift
 * @dev Nightly-only concrete, matched by the shared NightlyCells contract-name suffix
 *      (forge test --match-contract NightlyCells)
 */
contract CellHSmokeNightlyCells is TrancheFixtureSmoke {
    function _smokeCell() internal pure override returns (FixtureCell memory) {
        return cellH();
    }

    /**
     * @dev Hand derivation for cell H: one whole ST asset = 1e18 share-wei, at initialRateWAD 1.0 that converts to
     *      1e18 underlying-wei = 1.0 whole 18-decimal underlying, and the 1.0 oracle price maps one whole
     *      underlying to exactly 1e18 NAV wei. The rebase index sits at 1.0 and scales nothing here
     */
    function _expectedSTUnitNAV() internal pure override returns (uint256) {
        return 1e18;
    }

    /**
     * @notice A live underlying rebase scales wallet balances but cannot move any tranche mark
     * @dev Seeds the canonical market, snapshots every mark, then rebases the underlying +10% and proves the
     *      index really fired at the wallet layer while every market mark stayed byte-identical. Why it matters:
     *      the kernel custodies 4626 shares priced by an explicit rate, so an underlying index move that the
     *      vault has not folded into its rate is invisible to NAV — rebase yield must be driven through the rate
     *      feed (applySTPnL), and a green battery on this cell proves the armed flag cannot leak in sideways
     */
    function test_RebasingUnderlying_scalesWalletBalancesButNeverAnyTrancheMark() public {
        _seedDefault();
        uint256 stNavBefore = toUint256(seniorTranche.totalAssets().nav);
        uint256 jtNavBefore = toUint256(juniorTranche.totalAssets().nav);
        uint256 ltNavBefore = toUint256(liquidityTranche.getRawNAV());

        // The rebase flag is live: 100 whole underlying minted at index 1.0 (100e18 internal shares) must read
        // 100e18 x 1.1e18 / 1e18 = 110e18 after a +10% index move
        address holder = makeAddr("REBASE_PROBE");
        stJtUnderlying.mint(holder, 100e18);
        stJtUnderlying.setRebaseFactorWAD(1.1e18);
        assertEq(stJtUnderlying.balanceOf(holder), 110e18, "the armed rebase index must scale wallet balance reads");

        // No tranche mark may move: the kernel holds vault SHARES and the share rate is still exactly 1.0
        assertEq(toUint256(seniorTranche.totalAssets().nav), stNavBefore, "an underlying rebase must not move the senior mark");
        assertEq(toUint256(juniorTranche.totalAssets().nav), jtNavBefore, "an underlying rebase must not move the junior mark");
        assertEq(toUint256(liquidityTranche.getRawNAV()), ltNavBefore, "an underlying rebase must not move the LT depth mark");
    }
}
