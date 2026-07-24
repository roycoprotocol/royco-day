// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { toUint256 } from "../../src/libraries/Units.sol";
import { FixtureCell } from "../utils/FixtureTypes.sol";
import { cellE } from "../utils/TokenConfigs.sol";
import { MockERC20C } from "../mocks/MockERC20C.sol";
import { Test_MarketLifecycleBase } from "./Test_MarketLifecycleBase.t.sol";

/**
 * @title Test_MarketLifecycle_RevertOnZeroAndBlocklistTokens_NonStandardTokens
 * @notice Market lifecycle on hostile transfer semantics: a revert-on-zero ST/JT vault underlying and a
 *         blocklist-capable quote stable, over the baseline 4626(18,18) shares and 6-decimal quote
 * @dev The inherited lifecycle's exact constants hold unchanged: the market custodies the 4626 SHARE and the BPT,
 *      so the hostile underlying never moves in any market flow, and a blocklist with an empty deny list is a
 *      standard ERC20. This shape's value is proving the exact numbers survive with the hostile flags ARMED
 * @dev Nightly-only concrete, matched by the shared NonStandardTokens contract-name suffix
 *      (forge test --match-contract NonStandardTokens)
 */
contract Test_MarketLifecycle_RevertOnZeroAndBlocklistTokens_NonStandardTokens is Test_MarketLifecycleBase {
    function _tokenShape() internal pure override returns (FixtureCell memory) {
        return cellE();
    }

    /**
     * @dev Hand derivation for this shape: one whole ST asset = 1e18 share-wei, at initialRateWAD 1.0 that
     *      converts to 1e18 underlying-wei = 1.0 whole 18-decimal underlying, and the 1.0 oracle price maps one
     *      whole underlying to exactly 1e18 NAV wei. Transfer behaviors change no decimals and no rate
     */
    function _expectedSTUnitNAV() internal pure override returns (uint256) {
        return 1e18;
    }

    /**
     * @notice The hostile flags are live on this shape's tokens, yet the seeded market lands the exact baseline depth
     * @dev Builds both hostile triggers by hand, then seeds the canonical market. Why it matters: without the two
     *      trigger probes, a green run on this shape could mean the mock silently ignored the behavior bitmap.
     *      Proving the flags fire, then landing the same wei-exact depth every shape seeds, shows the market
     *      flows genuinely never touch the hostile paths (custody is the 4626 share and the BPT, never the
     *      underlying, and no seeded actor is on the quote deny list)
     */
    function test_HostileTransferBehaviors_areLiveYetMarketFlowsNeverTouchThem() public {
        // Revert-on-zero is armed on the vault underlying: a zero-amount transfer must revert
        vm.expectRevert(MockERC20C.ZERO_AMOUNT_TRANSFER.selector);
        stJtUnderlying.transfer(makeAddr("ZERO_TRANSFER_PROBE"), 0);

        // The quote deny list is armed: once an address is blocked, its transfers must revert
        quoteToken.mint(address(this), quoteUnit);
        quoteToken.setBlocked(address(this), true);
        vm.expectRevert(MockERC20C.ADDRESS_BLOCKED.selector);
        quoteToken.transfer(makeAddr("BLOCKLIST_PROBE"), quoteUnit);
        quoteToken.setBlocked(address(this), false);

        // With the deny list empty again, the full canonical seed lands the exact shape-independent depth:
        // 6e18 auto-seed + 20e18 explicit = 26e18, byte-identical to the baseline shape
        _seedDefault();
        assertEq(_liveLPTRawNAV(), SEEDED_LPT_RAW_NAV, "armed-but-untouched hostile behaviors must not perturb the seeded depth");
    }
}
