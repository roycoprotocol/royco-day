// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { TrancheClaimsLogic } from "../../../src/libraries/logic/TrancheClaimsLogic.sol";
import { RoycoTestMath } from "../../base/math/RoycoTestMath.sol";

/**
 * @title ClaimsFuzz
 * @notice Phase C fuzz properties for the F13 claim scaling (testing-strategy.md §4.2 row `redeem claims`):
 *         exact five-field equality against the independent RoycoTestMath mirror, the pro-rata ceiling, and the
 *         floor-dust conservation of a full-supply redemption partition
 * @dev Pure-library layer, no market deploy. Production is asserted against RoycoTestMath or a hand-derived
 *      bound, never against a second call of the function under test
 */
contract ClaimsFuzz is Test {
    /// @notice Suite-wide NAV, tranche-unit, and share-supply ceiling (testing-strategy.md §4.2 global bounds)
    uint256 internal constant MAX_NAV = 1e30;

    /// @dev Wraps five raw claim totals into the production AssetClaims struct
    function _claims(uint256 _st, uint256 _jt, uint256 _lt, uint256 _stShares, uint256 _nav) internal pure returns (AssetClaims memory c) {
        c.stAssets = toTrancheUnits(_st);
        c.jtAssets = toTrancheUnits(_jt);
        c.ltAssets = toTrancheUnits(_lt);
        c.stShares = _stShares;
        c.nav = toNAVUnits(_nav);
    }

    /// @dev Asserts all five fields of a production-scaled AssetClaims equal the RoycoTestMath mirror exactly
    function _assertFieldsEq(AssetClaims memory _got, RoycoTestMath.Claims memory _want, string memory _leg) internal pure {
        assertEq(toUint256(_got.stAssets), _want.stAssets, string.concat(_leg, ": stAssets == RoycoTestMath.scaleClaims"));
        assertEq(toUint256(_got.jtAssets), _want.jtAssets, string.concat(_leg, ": jtAssets == RoycoTestMath.scaleClaims"));
        assertEq(toUint256(_got.ltAssets), _want.ltAssets, string.concat(_leg, ": ltAssets == RoycoTestMath.scaleClaims"));
        assertEq(_got.stShares, _want.stShares, string.concat(_leg, ": stShares == RoycoTestMath.scaleClaims"));
        assertEq(toUint256(_got.nav), _want.nav, string.concat(_leg, ": nav == RoycoTestMath.scaleClaims"));
    }

    /**
     * Property (F13, TrancheClaimsLogic:117-131): every one of the five claim fields scales as
     *   scaled == floor(claim * shares / totalShares) == RoycoTestMath.scaleClaims(...)   [exact, all five fields]
     * and the floor direction caps the redeemer at pro-rata: scaled <= total per field whenever
     * shares <= totalShares (the redeemer cannot extract more than its slice)
     */
    function testFuzz_ScaleClaims_matchesMirrorAllFields(
        uint256 _st,
        uint256 _jt,
        uint256 _lt,
        uint256 _stShares,
        uint256 _nav,
        uint256 _shares,
        uint256 _totalShares
    )
        public
        pure
    {
        _st = bound(_st, 0, MAX_NAV); // uniform over the full tranche-unit range incl. the 0 edge
        _jt = bound(_jt, 0, MAX_NAV); // uniform over the full tranche-unit range incl. the 0 edge
        _lt = bound(_lt, 0, MAX_NAV); // uniform over the full tranche-unit range incl. the 0 edge
        _stShares = bound(_stShares, 0, MAX_NAV); // uniform over the full idle-share range incl. the 0 edge
        _nav = bound(_nav, 0, MAX_NAV); // uniform over the full NAV range incl. the 0 edge
        _totalShares = bound(_totalShares, 1, MAX_NAV); // F13 precondition: a redeemer only exists against a live supply
        _shares = bound(_shares, 0, _totalShares); // full redeemer slice range: 0 through the entire supply

        AssetClaims memory total = _claims(_st, _jt, _lt, _stShares, _nav);
        AssetClaims memory scaled = TrancheClaimsLogic._scaleAssetClaims(total, _shares, _totalShares);

        RoycoTestMath.Claims memory want = RoycoTestMath.scaleClaims(
            RoycoTestMath.Claims({ stAssets: _st, jtAssets: _jt, ltAssets: _lt, stShares: _stShares, nav: _nav }), _shares, _totalShares
        );
        _assertFieldsEq(scaled, want, "F13");

        // Floor direction: the scaled slice never exceeds the total on any field (shares <= totalShares)
        assertLe(toUint256(scaled.stAssets), _st, "F13 pro-rata cap: stAssets");
        assertLe(toUint256(scaled.jtAssets), _jt, "F13 pro-rata cap: jtAssets");
        assertLe(toUint256(scaled.ltAssets), _lt, "F13 pro-rata cap: ltAssets");
        assertLe(scaled.stShares, _stShares, "F13 pro-rata cap: stShares");
        assertLe(toUint256(scaled.nav), _nav, "F13 pro-rata cap: nav");
    }

    /**
     * Property (§4.2 full-supply redemption): partition the entire tranche supply into three redemptions
     * s1 + s2 + s3 == totalShares. Per field, the redeemed sum obeys
     *   total - 2 <= Σ scaled <= total
     * Upper side: each slice floors, so the sum of exact pro-rata terms (which telescopes to exactly the total)
     * only shrinks. Lower side (derived floor-dust bound): each of the three floors loses strictly less than
     * one unit, so the integer sum loses at most 3 - 1 = 2 units
     */
    function testFuzz_ScaleClaims_fullSupplyPartitionFloorDust(
        uint256 _st,
        uint256 _jt,
        uint256 _lt,
        uint256 _stShares,
        uint256 _nav,
        uint256 _sharesA,
        uint256 _sharesB,
        uint256 _totalShares
    )
        public
        pure
    {
        _st = bound(_st, 0, MAX_NAV); // uniform over the full tranche-unit range incl. the 0 edge
        _jt = bound(_jt, 0, MAX_NAV); // uniform over the full tranche-unit range incl. the 0 edge
        _lt = bound(_lt, 0, MAX_NAV); // uniform over the full tranche-unit range incl. the 0 edge
        _stShares = bound(_stShares, 0, MAX_NAV); // uniform over the full idle-share range incl. the 0 edge
        _nav = bound(_nav, 0, MAX_NAV); // uniform over the full NAV range incl. the 0 edge
        _totalShares = bound(_totalShares, 1, MAX_NAV); // F13 precondition: a redeemer only exists against a live supply
        _sharesA = bound(_sharesA, 0, _totalShares); // first slice: uniform over the whole supply incl. both edges
        _sharesB = bound(_sharesB, 0, _totalShares - _sharesA); // second slice: uniform over the remainder incl. both edges
        uint256 sharesC = _totalShares - _sharesA - _sharesB; // third slice completes the exact partition

        AssetClaims memory total = _claims(_st, _jt, _lt, _stShares, _nav);
        AssetClaims memory a = TrancheClaimsLogic._scaleAssetClaims(total, _sharesA, _totalShares);
        AssetClaims memory b = TrancheClaimsLogic._scaleAssetClaims(total, _sharesB, _totalShares);
        AssetClaims memory c = TrancheClaimsLogic._scaleAssetClaims(total, sharesC, _totalShares);

        // Derived floor-dust bound for a 3-way partition: 3 floors each lose < 1 unit, integer total loss <= 2
        uint256 partitionFloorDustDerivedBound = 2;

        _assertPartitionField(toUint256(a.stAssets) + toUint256(b.stAssets) + toUint256(c.stAssets), _st, partitionFloorDustDerivedBound, "stAssets");
        _assertPartitionField(toUint256(a.jtAssets) + toUint256(b.jtAssets) + toUint256(c.jtAssets), _jt, partitionFloorDustDerivedBound, "jtAssets");
        _assertPartitionField(toUint256(a.ltAssets) + toUint256(b.ltAssets) + toUint256(c.ltAssets), _lt, partitionFloorDustDerivedBound, "ltAssets");
        _assertPartitionField(a.stShares + b.stShares + c.stShares, _stShares, partitionFloorDustDerivedBound, "stShares");
        _assertPartitionField(toUint256(a.nav) + toUint256(b.nav) + toUint256(c.nav), _nav, partitionFloorDustDerivedBound, "nav");
    }

    /// @dev Asserts one field's partition sum sits in [total - dustBound, total]
    function _assertPartitionField(uint256 _sum, uint256 _total, uint256 _dustBound, string memory _field) internal pure {
        assertLe(_sum, _total, string.concat("partition never over-redeems: ", _field));
        assertGe(_sum + _dustBound, _total, string.concat("partition floor dust bounded: ", _field));
    }
}
