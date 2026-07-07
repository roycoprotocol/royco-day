// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { WAD } from "../../src/libraries/Constants.sol";
import { toNAVUnits } from "../../src/libraries/Units.sol";
import { UtilizationLogic } from "../../src/libraries/logic/UtilizationLogic.sol";

/// @dev Temporary encoding probe for the utilization suite, deleted before any verification run
contract ZZUtilProbe is Test {
    /// @dev p1: unit divisor and unit multiplier through the production path, assume-bounded symbol
    function check_p1_unitUnitAssume(uint256 x) external pure {
        vm.assume(1 <= x && x <= 2 ** 16);
        uint256 u = UtilizationLogic._computeCoverageUtilization(toNAVUnits(x), toNAVUnits(uint256(0)), false, 1, toNAVUnits(uint256(1)));
        assert(x <= u * 1);
        assert(u * 1 < x + 1);
    }

    /// @dev p2: unit multiplier, prime divisor, assume-bounded symbol
    function check_p2_primeDivAssume(uint256 x) external pure {
        vm.assume(1 <= x && x <= 2 ** 16);
        uint256 u = UtilizationLogic._computeCoverageUtilization(toNAVUnits(x), toNAVUnits(uint256(0)), false, 1, toNAVUnits(uint256(7)));
        assert(x <= u * 7);
        assert(u * 7 < x + 7);
    }

    /// @dev p3: WAD multiplier, prime divisor, assume-bounded symbol
    function check_p3_wadMulPrimeDivAssume(uint256 x) external pure {
        vm.assume(1 <= x && x <= 2 ** 16);
        uint256 u = UtilizationLogic._computeCoverageUtilization(toNAVUnits(x), toNAVUnits(uint256(0)), false, WAD, toNAVUnits(uint256(3)));
        uint256 n = x * WAD;
        assert(n <= u * 3);
        assert(u * 3 < n + 3);
    }

    /// @dev p4: WAD multiplier, prime divisor, mask-bounded symbol (static bit-width bound)
    function check_p4_wadMulPrimeDivMask(uint256 xRaw) external pure {
        uint256 x = xRaw & 0xFFFF;
        vm.assume(1 <= x);
        uint256 u = UtilizationLogic._computeCoverageUtilization(toNAVUnits(x), toNAVUnits(uint256(0)), false, WAD, toNAVUnits(uint256(3)));
        uint256 n = x * WAD;
        assert(n <= u * 3);
        assert(u * 3 < n + 3);
    }

    /// @dev p5: raw OZ mulDiv ceil, WAD multiplier, prime divisor, assume-bounded
    function check_p5_rawMulDivAssume(uint256 x) external pure {
        vm.assume(1 <= x && x <= 2 ** 16);
        uint256 u = Math.mulDiv(x, WAD, 3, Math.Rounding.Ceil);
        uint256 n = x * WAD;
        assert(n <= u * 3);
        assert(u * 3 < n + 3);
    }

    /// @dev p6: plain solidity ceil-div spec twin, no OZ path at all, assume-bounded
    function check_p6_plainCeilAssume(uint256 x) external pure {
        vm.assume(1 <= x && x <= 2 ** 16);
        uint256 n = x * WAD;
        uint256 u = (n + 2) / 3;
        assert(n <= u * 3);
        assert(u * 3 < n + 3);
    }

    /// @dev p7: gate boundary form at WAD multiplier and prime divisor, assume-bounded
    function check_p7_gateAssume(uint256 x) external pure {
        vm.assume(1 <= x && x <= 2 ** 16);
        uint256 u = UtilizationLogic._computeCoverageUtilization(toNAVUnits(x), toNAVUnits(uint256(0)), false, WAD, toNAVUnits(uint256(3)));
        assert((u <= WAD) == (x * WAD <= WAD * 3));
    }

    /// @dev p8: totality of the wrapped call on the full NAV domain with concrete-divisor config
    function check_p8_totalitySmall(uint256 x) external view {
        vm.assume(x <= 1e30);
        try this.covWrapped(x, 0, false, WAD, 3) returns (uint256) { }
        catch {
            assert(false);
        }
    }

    /// @dev External twin for the totality probe
    function covWrapped(uint256 _stRaw, uint256 _jtRaw, bool _co, uint256 _minCov, uint256 _jtEff) external pure returns (uint256) {
        return UtilizationLogic._computeCoverageUtilization(toNAVUnits(_stRaw), toNAVUnits(_jtRaw), _co, _minCov, toNAVUnits(_jtEff));
    }
}
