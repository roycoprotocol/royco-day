// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { UtilizationLogic } from "../../src/libraries/logic/UtilizationLogic.sol";
import { toNAVUnits } from "../../src/libraries/Units.sol";

/**
 * @title UtilizationSymbolic
 * @notice Halmos symbolic specs for the coverage and liquidity utilization math. Each metric is pinned to a
 *         complete functional characterization: the zero edges resolve before any division, every other input
 *         resolves to the exact rounded-up ratio, and the function is total (never reverts) on the suite-wide
 *         bounded domain (NAVs up to 1e30 NAV wei, fractions up to WAD)
 * @dev Run with `halmos --contract UtilizationSymbolicSpec`. Functions prefixed check_ are halmos properties and
 *      are not discovered by forge test. The expected ceiling is derived independently as (n + d - 1) / d, the
 *      add-before-divide form, rather than through the OZ mulDiv path production uses
 */
contract UtilizationSymbolicSpec is Test {
    /// @dev Suite-wide NAV domain bound: 1e30 NAV wei (one trillion tokens at WAD precision)
    uint256 internal constant MAX_NAV = 1e30;

    /// @dev WAD fixed-point unit, 1e18 == 100%
    uint256 internal constant WAD = 1e18;

    /*//////////////////////////////////////////////////////////////////////
                            EXTERNAL WRAPPERS
    //////////////////////////////////////////////////////////////////////*/

    /// @dev External wrapper so the totality checks can observe a revert through try/catch
    function coverageUtilizationWrapped(
        uint256 _stRaw,
        uint256 _jtRaw,
        bool _jtCoinvested,
        uint256 _minCoverageWAD,
        uint256 _jtEff
    )
        external
        pure
        returns (uint256)
    {
        return UtilizationLogic._computeCoverageUtilization(toNAVUnits(_stRaw), toNAVUnits(_jtRaw), _jtCoinvested, _minCoverageWAD, toNAVUnits(_jtEff));
    }

    /// @dev External wrapper so the totality checks can observe a revert through try/catch
    function liquidityUtilizationWrapped(uint256 _stEff, uint256 _minLiquidityWAD, uint256 _ltRaw) external pure returns (uint256) {
        return UtilizationLogic._computeLiquidityUtilization(toNAVUnits(_stEff), _minLiquidityWAD, toNAVUnits(_ltRaw));
    }

    /*//////////////////////////////////////////////////////////////////////
                            COVERAGE UTILIZATION
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Coverage utilization equals its full closed form on every bounded input: 0 when there is no
     *         requirement or no covered exposure (even against an empty junior buffer), the uint256 maximum when
     *         a positive requirement meets an empty junior buffer, and otherwise the exact rounded-up ratio
     *         ceil(exposure * minCoverage / jtEff) so the gate can only read pessimistically high, never low
     */
    function check_coverageUtilizationMatchesItsRoundedUpClosedForm(
        uint256 stRaw,
        uint256 jtRaw,
        bool jtCoinvested,
        uint256 minCoverageWAD,
        uint256 jtEff
    )
        external
        pure
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && jtEff <= MAX_NAV && minCoverageWAD <= WAD);

        uint256 utilization =
            UtilizationLogic._computeCoverageUtilization(toNAVUnits(stRaw), toNAVUnits(jtRaw), jtCoinvested, minCoverageWAD, toNAVUnits(jtEff));

        // Exposure is senior raw NAV, plus junior raw NAV only when the junior shares senior's downside
        uint256 exposure = jtCoinvested ? stRaw + jtRaw : stRaw;
        if (minCoverageWAD == 0 || exposure == 0) {
            // Nothing to cover means zero utilization, and this edge must win even when jtEff is also zero
            assert(utilization == 0);
        } else if (jtEff == 0) {
            // A positive requirement against an exhausted junior buffer reads as infinite utilization
            assert(utilization == type(uint256).max);
        } else {
            // Independent ceiling derivation: add denominator-minus-one before the floor division
            assert(utilization == (exposure * minCoverageWAD + (jtEff - 1)) / jtEff);
        }
    }

    /**
     * @notice Coverage utilization never reverts anywhere on the bounded domain, so no market state can brick a
     *         sync or a deposit gate by making the utilization read itself blow up
     */
    function check_coverageUtilizationNeverRevertsOnBoundedInputs(
        uint256 stRaw,
        uint256 jtRaw,
        bool jtCoinvested,
        uint256 minCoverageWAD,
        uint256 jtEff
    )
        external
        view
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && jtEff <= MAX_NAV && minCoverageWAD <= WAD);

        try this.coverageUtilizationWrapped(stRaw, jtRaw, jtCoinvested, minCoverageWAD, jtEff) returns (uint256) { }
        catch {
            assert(false);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                            LIQUIDITY UTILIZATION
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Liquidity utilization equals its full closed form on every bounded input: 0 when there is no senior
     *         value or no requirement (even against an empty pool), the uint256 maximum when a positive requirement
     *         meets an empty pool, and otherwise the exact rounded-up ratio ceil(stEff * minLiquidity / ltRaw) so
     *         the redemption gate can only read pessimistically high, never low
     */
    function check_liquidityUtilizationMatchesItsRoundedUpClosedForm(uint256 stEff, uint256 minLiquidityWAD, uint256 ltRaw) external pure {
        vm.assume(stEff <= MAX_NAV && ltRaw <= MAX_NAV && minLiquidityWAD <= WAD);

        uint256 utilization = UtilizationLogic._computeLiquidityUtilization(toNAVUnits(stEff), minLiquidityWAD, toNAVUnits(ltRaw));

        if (stEff == 0 || minLiquidityWAD == 0) {
            // No senior value to serve or no requirement means zero utilization, even when ltRaw is also zero
            assert(utilization == 0);
        } else if (ltRaw == 0) {
            // A positive required inventory against an empty pool reads as infinite utilization
            assert(utilization == type(uint256).max);
        } else {
            // Independent ceiling derivation: add denominator-minus-one before the floor division
            assert(utilization == (stEff * minLiquidityWAD + (ltRaw - 1)) / ltRaw);
        }
    }

    /**
     * @notice Liquidity utilization never reverts anywhere on the bounded domain, so no pool state can brick the
     *         LT redemption gate by making the utilization read itself blow up
     */
    function check_liquidityUtilizationNeverRevertsOnBoundedInputs(uint256 stEff, uint256 minLiquidityWAD, uint256 ltRaw) external view {
        vm.assume(stEff <= MAX_NAV && ltRaw <= MAX_NAV && minLiquidityWAD <= WAD);

        try this.liquidityUtilizationWrapped(stEff, minLiquidityWAD, ltRaw) returns (uint256) { }
        catch {
            assert(false);
        }
    }
}
