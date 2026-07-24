// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { TrancheClaimsLogic } from "../../../src/libraries/logic/TrancheClaimsLogic.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";

/**
 * @title TestFuzz_TrancheClaims_Logic
 * @notice Fuzz properties for the pro-rata claim scaling a redemption applies to all four claim legs
 *         (collateral assets, LPT assets, idle liquidity premium senior shares, NAV): exact four-field
 *         equality against the independent RoycoTestMath mirror, the pro-rata ceiling, and floor-dust
 *         conservation when the whole supply redeems in parts
 * @dev Pure-library layer, no market deploy. Production is asserted against RoycoTestMath or a hand-derived
 *      bound, never against a second call of the function under test
 */
contract TestFuzz_TrancheClaims_Logic is Test {
    /// @notice Suite-wide NAV, tranche-unit, and share-supply ceiling
    uint256 internal constant MAX_NAV = 1e30;

    /// @notice The virtual-shares offset every claim slice is priced against (mirrors src Constants.VIRTUAL_SHARES)
    uint256 internal constant VIRTUAL_SHARES = 1e6;

    /// @dev Wraps four raw claim totals into the production AssetClaims struct
    function _claims(uint256 _collateral, uint256 _lt, uint256 _stShares, uint256 _nav) internal pure returns (AssetClaims memory c) {
        c.collateralAssets = toTrancheUnits(_collateral);
        c.lptAssets = toTrancheUnits(_lt);
        c.stShares = _stShares;
        c.nav = toNAVUnits(_nav);
    }

    /// @dev Asserts all four fields of a production-scaled AssetClaims equal the RoycoTestMath mirror exactly
    function _assertFieldsEq(AssetClaims memory _got, RoycoTestMath.Claims memory _want, string memory _leg) internal pure {
        assertEq(toUint256(_got.collateralAssets), _want.collateralAssets, string.concat(_leg, ": collateralAssets == RoycoTestMath.scaleClaims"));
        assertEq(toUint256(_got.lptAssets), _want.lptAssets, string.concat(_leg, ": lptAssets == RoycoTestMath.scaleClaims"));
        assertEq(_got.stShares, _want.stShares, string.concat(_leg, ": stShares == RoycoTestMath.scaleClaims"));
        assertEq(toUint256(_got.nav), _want.nav, string.concat(_leg, ": nav == RoycoTestMath.scaleClaims"));
    }

    /**
     * A redeemer burning `shares` of a `totalShares` supply is owed the same fraction of every claim leg,
     * floored - including the idle liquidity premium senior shares an LPT redeemer receives directly - so no leg can
     * be scaled by a different rule and quietly favor one side. Property:
     *   scaled == floor(claim * shares / (totalShares + VIRTUAL_SHARES)) == RoycoTestMath.scaleClaims(...)  [exact, all four]
     * and the floor direction caps the redeemer at pro-rata: scaled <= total per field whenever
     * shares <= totalShares (the virtual-shares offset only lowers the slice, so the cap holds a fortiori)
     */
    function testFuzz_ScaleClaims_MatchesMirrorAllFields(
        uint256 _collateral,
        uint256 _lt,
        uint256 _stShares,
        uint256 _nav,
        uint256 _shares,
        uint256 _totalShares
    )
        public
        pure
    {
        _collateral = bound(_collateral, 0, MAX_NAV); // uniform over the full tranche-unit range incl. the 0 edge
        _lt = bound(_lt, 0, MAX_NAV); // uniform over the full tranche-unit range incl. the 0 edge
        _stShares = bound(_stShares, 0, MAX_NAV); // uniform over the full idle-share range incl. the 0 edge
        _nav = bound(_nav, 0, MAX_NAV); // uniform over the full NAV range incl. the 0 edge
        _totalShares = bound(_totalShares, 1, MAX_NAV); // a redeemer only exists against a live supply
        _shares = bound(_shares, 0, _totalShares); // full redeemer slice range: 0 through the entire supply

        AssetClaims memory total = _claims(_collateral, _lt, _stShares, _nav);
        AssetClaims memory scaled = TrancheClaimsLogic._scaleAssetClaims(total, _shares, _totalShares);

        RoycoTestMath.Claims memory want = RoycoTestMath.scaleClaims(
            RoycoTestMath.Claims({ collateralAssets: _collateral, lptAssets: _lt, stShares: _stShares, nav: _nav }), _shares, _totalShares
        );
        _assertFieldsEq(scaled, want, "scaled slice");

        // Floor direction: the scaled slice never exceeds the total on any field (shares <= totalShares)
        assertLe(toUint256(scaled.collateralAssets), _collateral, "pro-rata cap: collateralAssets");
        assertLe(toUint256(scaled.lptAssets), _lt, "pro-rata cap: lptAssets");
        assertLe(scaled.stShares, _stShares, "pro-rata cap: stShares");
        assertLe(toUint256(scaled.nav), _nav, "pro-rata cap: nav");
    }

    /**
     * Three redeemers together burning the entire supply (s1 + s2 + s3 == totalShares) collectively receive the
     * whole pot minus (a) the virtual-share sliver the offset permanently withholds and (b) at most floor dust -
     * over-payment would drain the tranche. Each slice is floor(claim * s_i / (totalShares + VIRTUAL_SHARES)), so the
     * exact pro-rata terms sum to claim * totalShares / (totalShares + VIRTUAL_SHARES), short of the total by the
     * virtual-share portion V = claim * VIRTUAL_SHARES / (totalShares + VIRTUAL_SHARES). Per field the redeemed sum obeys
     *   total - ceil(V) - 2 <= sum of the three slices <= total
     * Upper side: each slice floors sub-total terms, so the sum never exceeds the total. Lower side (derived):
     * sum = total - V - Σfrac with Σfrac in [0, 3), and ceil(V) + 2 bounds V + Σfrac from above for the integer sum.
     * The withheld virtual-share sliver stays permanently behind - the donation/premium extraction guard.
     */
    function testFuzz_ScaleClaims_FullSupplyPartitionFloorDust(
        uint256 _collateral,
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
        _collateral = bound(_collateral, 0, MAX_NAV); // uniform over the full tranche-unit range incl. the 0 edge
        _lt = bound(_lt, 0, MAX_NAV); // uniform over the full tranche-unit range incl. the 0 edge
        _stShares = bound(_stShares, 0, MAX_NAV); // uniform over the full idle-share range incl. the 0 edge
        _nav = bound(_nav, 0, MAX_NAV); // uniform over the full NAV range incl. the 0 edge
        _totalShares = bound(_totalShares, 1, MAX_NAV); // a redeemer only exists against a live supply
        _sharesA = bound(_sharesA, 0, _totalShares); // first slice: uniform over the whole supply incl. both edges
        _sharesB = bound(_sharesB, 0, _totalShares - _sharesA); // second slice: uniform over the remainder incl. both edges
        uint256 sharesC = _totalShares - _sharesA - _sharesB; // third slice completes the exact partition

        AssetClaims memory total = _claims(_collateral, _lt, _stShares, _nav);
        AssetClaims memory a = TrancheClaimsLogic._scaleAssetClaims(total, _sharesA, _totalShares);
        AssetClaims memory b = TrancheClaimsLogic._scaleAssetClaims(total, _sharesB, _totalShares);
        AssetClaims memory c = TrancheClaimsLogic._scaleAssetClaims(total, sharesC, _totalShares);

        // Per-field bound: the withheld virtual-share sliver ceil(field*VIRTUAL_SHARES/(totalShares+VIRTUAL_SHARES))
        // plus < 3 floor dust from the three slices (integer bound + 2).
        _assertPartitionField(
            toUint256(a.collateralAssets) + toUint256(b.collateralAssets) + toUint256(c.collateralAssets),
            _collateral,
            _partitionDustBound(_collateral, _totalShares),
            "collateralAssets"
        );
        _assertPartitionField(toUint256(a.lptAssets) + toUint256(b.lptAssets) + toUint256(c.lptAssets), _lt, _partitionDustBound(_lt, _totalShares), "lptAssets");
        _assertPartitionField(a.stShares + b.stShares + c.stShares, _stShares, _partitionDustBound(_stShares, _totalShares), "stShares");
        _assertPartitionField(toUint256(a.nav) + toUint256(b.nav) + toUint256(c.nav), _nav, _partitionDustBound(_nav, _totalShares), "nav");
    }

    /// @dev The maximum a full-supply 3-way partition may leave behind for one field: the virtual-share sliver
    ///      ceil(field * VIRTUAL_SHARES / (totalShares + VIRTUAL_SHARES)) plus 2 (the < 3 floor-dust units, integer-bounded)
    function _partitionDustBound(uint256 _field, uint256 _totalShares) internal pure returns (uint256) {
        uint256 denom = _totalShares + VIRTUAL_SHARES;
        return (_field * VIRTUAL_SHARES + denom - 1) / denom + 2; // ceil(field*VIRTUAL_SHARES/denom) + 2
    }

    /// @dev Asserts one field's partition sum sits in [total - dustBound, total]
    function _assertPartitionField(uint256 _sum, uint256 _total, uint256 _dustBound, string memory _field) internal pure {
        assertLe(_sum, _total, string.concat("partition never over-redeems: ", _field));
        assertGe(_sum + _dustBound, _total, string.concat("partition floor dust bounded: ", _field));
    }
}
