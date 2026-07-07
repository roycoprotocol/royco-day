// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { CacheKey } from "../../../src/libraries/Cache.sol";
import { MockCacheUser } from "../../mocks/MockCacheUser.sol";

/**
 * @title Test_Cache
 * @notice The unified keyed transient cache the quoters share: a populated-marker bit (bit 255) distinguishes a
 *         cached zero from an unset slot, each key owns its own transient slot, and every payload below the marker
 *         bit round-trips bit-exact
 * @dev Expected values are derived from the marker-bit design goal (payload occupies bits 0..254, bit 255 marks
 *      the slot populated), never from running the library. The cache is transaction-scoped, and the pinned forge
 *      toolchain clears transient storage after every top-level call a test makes, so each write/read sequence is
 *      driven through ONE external self-call, modeling production where a quoter writes and reads the cache within
 *      a single user transaction
 */
contract Test_Cache is Test {
    /**
     * @dev The largest payload that does not collide with the populated-marker bit: all 255 payload bits set,
     *      2^255 - 1 = 57896044618658097711785492504343953926634992332820282019728792003956564819967
     */
    uint256 internal constant MAX_CACHEABLE_VALUE = (1 << 255) - 1;

    MockCacheUser internal cacheUser;

    function setUp() public {
        cacheUser = new MockCacheUser();
    }

    /// @notice Same-transaction driver: writes `_value` under `_key`, then reads back both `_key` and `_siblingKey`
    /// @dev External so the test can invoke it as one top-level call, keeping all three cache operations inside a single transient-storage lifetime
    function driveWriteThenReadBothKeys(
        CacheKey _key,
        uint256 _value,
        CacheKey _siblingKey
    )
        external
        returns (bool hit, uint256 value, bool siblingHit, uint256 siblingValue)
    {
        cacheUser.write(_key, _value);
        (hit, value) = cacheUser.read(_key);
        (siblingHit, siblingValue) = cacheUser.read(_siblingKey);
    }

    /**
     * @notice A cached ZERO reads back as a hit carrying zero, and a key that was never written stays a miss even
     *         while its sibling's slot is populated in the same transaction
     * @dev Zero is a legitimate cacheable value (a rate can genuinely be zero), so the cache must not confuse
     *      "cached zero" with "never computed": if it did, a zero rate would be recomputed on every read and a
     *      reader could not trust the hit flag. The marker bit makes the stored word 0 | 2^255, which is nonzero,
     *      so the slot is distinguishable from the all-zero unset slot. The untouched sibling key proves writes
     *      are isolated per key: caching the senior share rate must never fabricate a hit for the identical
     *      ST/JT tranche-to-NAV-unit rate, or a quoter would price off a value meant for a different quantity
     */
    function test_WriteZeroThenRead_ReturnsHitWithZero_AndUntouchedKeyReadsMiss() public {
        (bool hit, uint256 value, bool siblingHit, uint256 siblingValue) =
            this.driveWriteThenReadBothKeys(CacheKey.ST_SHARE_RATE, 0, CacheKey.IDENTICAL_ST_JT_TRANCHE_TO_NAV_UNIT_RATE);

        // The written key: a hit whose payload is exactly the zero that was stored
        assertTrue(hit, "a cached zero must read as a hit, the marker bit keeps the slot nonzero");
        assertEq(value, 0, "the payload of a cached zero must be exactly zero");

        // The untouched key: the canonical miss shape (false, 0), its slot was never populated
        assertFalse(siblingHit, "a key that was never written must read as a miss, keys occupy separate slots");
        assertEq(siblingValue, 0, "a miss must carry a zero value");
    }

    /**
     * @notice The largest non-colliding payload, 2^255 - 1, round-trips bit-exact
     * @dev The marker occupies bit 255, leaving bits 0..254 as payload. With every payload bit set the stored
     *      word is all 256 bits on, and unmarking must peel off ONLY bit 255 and return the other 255 bits
     *      untouched. This is the read-after-write identity at its upper edge: a quoter that caches a rate must
     *      get the same rate back, or the cache would silently re-price whatever consumed it downstream
     */
    function test_WriteMaxRepresentableValue_RoundTripsExactly() public {
        (bool hit, uint256 value,,) =
            this.driveWriteThenReadBothKeys(CacheKey.ST_SHARE_RATE, MAX_CACHEABLE_VALUE, CacheKey.IDENTICAL_ST_JT_TRANCHE_TO_NAV_UNIT_RATE);

        assertTrue(hit, "a written slot must read as a hit");
        assertEq(value, MAX_CACHEABLE_VALUE, "the max payload (2^255 - 1) must round-trip bit-exact");
    }
}
