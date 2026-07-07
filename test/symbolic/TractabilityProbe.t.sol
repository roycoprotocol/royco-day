// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// TEMPORARY probe (not part of the suite, deleted before merge): measures which property shapes
// the native symbolic engine can actually verify, to calibrate the property catalog.
import { Test } from "../../lib/forge-std/src/Test.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

contract TractabilityProbe is Test {
    uint256 internal constant WAD = 1e18;

    // Shape A: OZ mulDiv ceil vs add-before-divide closed form, tiny domain (products fit far below 2^128)
    function check_probeA_ceilClosedForm_tinyDomain(uint256 n, uint256 d) external pure {
        vm.assume(n <= 1e12);
        vm.assume(1 <= d && d <= 1e12);
        uint256 u = Math.mulDiv(n, WAD, d, Math.Rounding.Ceil);
        assert(u == (n * WAD + d - 1) / d);
    }

    // Shape B: same property, production domain (products fit 2^256 but exceed 2^128)
    function check_probeB_ceilClosedForm_prodDomain(uint256 n, uint256 d) external pure {
        vm.assume(n <= 1e30);
        vm.assume(1 <= d && d <= 1e30);
        uint256 u = Math.mulDiv(n, WAD, d, Math.Rounding.Ceil);
        assert(u == (n * WAD + d - 1) / d);
    }

    // Shape C: product-form spec (no division on the spec side), production domain
    function check_probeC_ceilProductForm_prodDomain(uint256 n, uint256 d) external pure {
        vm.assume(n <= 1e30);
        vm.assume(1 <= d && d <= 1e30);
        uint256 u = Math.mulDiv(n, WAD, d, Math.Rounding.Ceil);
        // u = ceil(n*WAD/d)  <=>  u*d >= n*WAD  and  (u == 0 or (u-1)*d < n*WAD)
        assert(u * d >= n * WAD);
        assert(u == 0 || (u - 1) * d < n * WAD);
    }

    // Shape D: native / and % only, no OZ mulDiv at all, production domain
    function check_probeD_nativeDivCeil_prodDomain(uint256 n, uint256 d) external pure {
        vm.assume(n <= 1e30);
        vm.assume(1 <= d && d <= 1e30);
        uint256 q = (n * WAD) / d;
        uint256 u = q + (mulmod(n, WAD, d) == 0 ? 0 : 1);
        assert(u == (n * WAD + d - 1) / d);
    }

    // Shape E: bound (inequality) instead of equivalence, through OZ mulDiv, production domain
    function check_probeE_floorLeqCeil_prodDomain(uint256 n, uint256 d) external pure {
        vm.assume(n <= 1e30);
        vm.assume(1 <= d && d <= 1e30);
        uint256 f = Math.mulDiv(n, WAD, d);
        uint256 c = Math.mulDiv(n, WAD, d, Math.Rounding.Ceil);
        assert(f <= c && c - f <= 1);
    }

    // Shape F: >4 symbolic vars forces the real SMT solver (bypasses the hard-arith heuristic,
    // whose fallback covers at most 4 vars), tight 2^32 domain so bit-blasting stays feasible
    function check_probeF_ceilClosedForm_forcedSolver_tightDomain(uint256 n, uint256 d, uint256 p1, uint256 p2, uint256 p3) external pure {
        vm.assume(n <= type(uint32).max);
        vm.assume(1 <= d && d <= type(uint32).max);
        vm.assume(p1 <= 3 && p2 <= 3 && p3 <= 3); // padding vars only exist to exceed the heuristic's var cap
        uint256 u = Math.mulDiv(n, WAD, d, Math.Rounding.Ceil) + p1 + p2 + p3 - p1 - p2 - p3;
        assert(u == (n * WAD + d - 1) / d);
    }

    // Shape G: forced solver at production domain widths — measures whether bit-blasting scales
    function check_probeG_ceilClosedForm_forcedSolver_prodDomain(uint256 n, uint256 d, uint256 p1, uint256 p2, uint256 p3) external pure {
        vm.assume(n <= 1e30);
        vm.assume(1 <= d && d <= 1e30);
        vm.assume(p1 <= 3 && p2 <= 3 && p3 <= 3);
        uint256 u = Math.mulDiv(n, WAD, d, Math.Rounding.Ceil) + p1 + p2 + p3 - p1 - p2 - p3;
        assert(u == (n * WAD + d - 1) / d);
    }

    // Shape H: mul-by-constant then div-by-constant via native ops (the concrete-fraction premium
    // split shape: floor(gain * frac / WAD) with frac concrete) — bound property
    function check_probeH_constFractionBound(uint256 gain) external pure {
        vm.assume(gain <= 1e30);
        uint256 share = (gain * 3e17) / WAD;
        assert(share <= gain);
    }

    // Shape H2: same shape, exactness against an independently stated bracket via constants only
    function check_probeH2_constFractionResidual(uint256 gain) external pure {
        vm.assume(gain <= 1e30);
        uint256 share = (gain * 3e17) / WAD;
        uint256 residual = gain - share;
        // The floored 30% slice plus its residual reassembles the whole gain
        assert(share + residual == gain);
        // The slice loses less than one whole WAD quantum against the true product
        assert(gain * 3e17 - share * WAD < WAD);
    }

    // Shape I: OZ mulDiv with constant fraction == native constant expression
    function check_probeI_constFractionOZParity(uint256 gain) external pure {
        vm.assume(gain <= 1e30);
        assert(Math.mulDiv(gain, 3e17, WAD) == (gain * 3e17) / WAD);
    }

    // Shape J: constant-fraction bound with forced solver (>4 vars bypasses the deferral)
    function check_probeJ_constFractionBound_forcedSolver(uint256 gain, uint256 p1, uint256 p2, uint256 p3, uint256 p4) external pure {
        vm.assume(gain <= 1e30);
        vm.assume(p1 <= 3 && p2 <= 3 && p3 <= 3 && p4 <= 3);
        uint256 share = (gain * 3e17) / WAD + p1 + p2 + p3 + p4 - p1 - p2 - p3 - p4;
        assert(share <= gain);
    }

    // Shape K: constant-fraction exact bracket with forced solver
    function check_probeK_constFractionBracket_forcedSolver(uint256 gain, uint256 p1, uint256 p2, uint256 p3, uint256 p4) external pure {
        vm.assume(gain <= 1e30);
        vm.assume(p1 <= 3 && p2 <= 3 && p3 <= 3 && p4 <= 3);
        uint256 share = (gain * 3e17) / WAD + p1 + p2 + p3 + p4 - p1 - p2 - p3 - p4;
        // Defining bracket of the floored 30% slice, stated purely with constant multiplies
        assert(share * WAD <= gain * 3e17);
        assert(gain * 3e17 - share * WAD < WAD);
    }
}
