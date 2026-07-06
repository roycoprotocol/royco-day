// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { toUint256 } from "../../../src/libraries/Units.sol";
import { FixtureCell } from "../../base/fixtures/FixtureTypes.sol";
import { cellF } from "../../base/fixtures/TokenConfigs.sol";
import { TrancheFixtureSmoke } from "./TrancheFixtureSmoke.sol";

/**
 * @title CellFSmokeNightlyCells
 * @notice Smoke battery on cell F: a USDT-shaped quote stable returning EMPTY returndata on its transfer paths,
 *         over the baseline 4626(18,18) ST/JT shares and 6-decimal quote
 * @dev The inherited battery's exact constants hold unchanged: empty returndata only breaks callers that strictly
 *      decode the declared bool, and every quote pull in the seed and venue flows goes through SafeERC20, which
 *      accepts it. The cell's value is proving the exact numbers survive with the USDT shape ARMED
 * @dev Nightly-only concrete, matched by the shared NightlyCells contract-name suffix
 *      (forge test --match-contract NightlyCells)
 */
contract CellFSmokeNightlyCells is TrancheFixtureSmoke {
    function _smokeCell() internal pure override returns (FixtureCell memory) {
        return cellF();
    }

    /**
     * @dev Hand derivation for cell F: one whole ST asset = 1e18 share-wei, at initialRateWAD 1.0 that converts to
     *      1e18 underlying-wei = 1.0 whole 18-decimal underlying, and the 1.0 oracle price maps one whole
     *      underlying to exactly 1e18 NAV wei. The quote's returndata shape changes no decimals and no rate
     */
    function _expectedSTUnitNAV() internal pure override returns (uint256) {
        return 1e18;
    }

    /**
     * @notice The quote token really returns empty returndata, yet every SafeERC20 seed flow still lands exactly
     * @dev Probes the raw returndata of a successful transfer by hand, then seeds the canonical market. Why it
     *      matters: without the probe, a green battery on this cell could mean the mock silently ignored the
     *      behavior bitmap. Proving the USDT shape fires, then landing the same wei-exact depth every cell seeds,
     *      shows the venue's quote pulls tolerate a non-bool-returning stable end to end
     */
    function test_NoReturnValueQuote_isLiveAndSafeERC20FlowsStillLandExactly() public {
        // A successful transfer must return ZERO bytes of returndata (the USDT shape), which a strict
        // abi.decode(returndata, (bool)) caller would revert on
        quoteToken.mint(address(this), quoteUnit);
        (bool success, bytes memory returnData) = address(quoteToken).call(abi.encodeCall(quoteToken.transfer, (makeAddr("USDT_SHAPE_PROBE"), quoteUnit)));
        assertTrue(success, "the USDT-shaped transfer itself must succeed");
        assertEq(returnData.length, 0, "the armed cell must return empty returndata, not the declared bool");

        // The canonical seed routes every quote movement through SafeERC20 pulls and must land the exact
        // cell-independent depth: 6e18 auto-seed + 20e18 explicit = 26e18
        _seedDefault();
        assertEq(toUint256(liquidityTranche.getRawNAV()), SEEDED_LT_RAW_NAV, "the USDT-shaped quote must not perturb the seeded depth");
    }
}
