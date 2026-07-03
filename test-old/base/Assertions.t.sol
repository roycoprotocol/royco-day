// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { NAV_UNIT, TRANCHE_UNIT, toUint256 } from "../../src/libraries/Units.sol";
import { Test } from "forge-std/Test.sol";

contract Assertions is Test {
    function assertEq(TRANCHE_UNIT left, TRANCHE_UNIT right, string memory errorMessage) internal pure {
        assertEq(toUint256(left), toUint256(right), errorMessage);
    }

    function assertNotEq(TRANCHE_UNIT left, TRANCHE_UNIT right, string memory errorMessage) internal pure {
        assertNotEq(toUint256(left), toUint256(right), errorMessage);
    }

    function assertLt(TRANCHE_UNIT left, TRANCHE_UNIT right, string memory errorMessage) internal pure {
        assertLt(toUint256(left), toUint256(right), errorMessage);
    }

    function assertLe(TRANCHE_UNIT left, TRANCHE_UNIT right, string memory errorMessage) internal pure {
        assertLe(toUint256(left), toUint256(right), errorMessage);
    }

    function assertGt(TRANCHE_UNIT left, TRANCHE_UNIT right, string memory errorMessage) internal pure {
        assertGt(toUint256(left), toUint256(right), errorMessage);
    }

    function assertGe(TRANCHE_UNIT left, TRANCHE_UNIT right, string memory errorMessage) internal pure {
        assertGe(toUint256(left), toUint256(right), errorMessage);
    }

    function assertApproxEqAbs(TRANCHE_UNIT left, TRANCHE_UNIT right, uint256 maxAbsDelta, string memory errorMessage) internal pure {
        assertApproxEqAbs(toUint256(left), toUint256(right), maxAbsDelta, errorMessage);
    }

    function assertApproxEqRel(TRANCHE_UNIT left, TRANCHE_UNIT right, uint256 maxRelDelta, string memory errorMessage) internal pure {
        assertApproxEqRel(toUint256(left), toUint256(right), maxRelDelta, errorMessage);
    }

    function assertApproxEqAbs(TRANCHE_UNIT left, TRANCHE_UNIT right, TRANCHE_UNIT maxAbsDelta, string memory errorMessage) internal pure {
        assertApproxEqAbs(toUint256(left), toUint256(right), toUint256(maxAbsDelta), errorMessage);
    }

    function assertEq(NAV_UNIT left, NAV_UNIT right, string memory errorMessage) internal pure {
        assertEq(toUint256(left), toUint256(right), errorMessage);
    }

    function assertNotEq(NAV_UNIT left, NAV_UNIT right, string memory errorMessage) internal pure {
        assertNotEq(toUint256(left), toUint256(right), errorMessage);
    }

    function assertLt(NAV_UNIT left, NAV_UNIT right, string memory errorMessage) internal pure {
        assertLt(toUint256(left), toUint256(right), errorMessage);
    }

    function assertLe(NAV_UNIT left, NAV_UNIT right, string memory errorMessage) internal pure {
        assertLe(toUint256(left), toUint256(right), errorMessage);
    }

    function assertGt(NAV_UNIT left, NAV_UNIT right, string memory errorMessage) internal pure {
        assertGt(toUint256(left), toUint256(right), errorMessage);
    }

    function assertGe(NAV_UNIT left, NAV_UNIT right, string memory errorMessage) internal pure {
        assertGe(toUint256(left), toUint256(right), errorMessage);
    }

    function assertApproxEqAbs(NAV_UNIT left, NAV_UNIT right, uint256 maxAbsDelta, string memory errorMessage) internal pure {
        assertApproxEqAbs(toUint256(left), toUint256(right), maxAbsDelta, errorMessage);
    }

    function assertApproxEqAbs(NAV_UNIT left, NAV_UNIT right, NAV_UNIT maxAbsDelta, string memory errorMessage) internal pure {
        assertApproxEqAbs(toUint256(left), toUint256(right), toUint256(maxAbsDelta), errorMessage);
    }

    function assertApproxEqRel(NAV_UNIT left, NAV_UNIT right, uint256 maxRelDelta, string memory errorMessage) internal pure {
        assertApproxEqRel(toUint256(left), toUint256(right), maxRelDelta, errorMessage);
    }
}
