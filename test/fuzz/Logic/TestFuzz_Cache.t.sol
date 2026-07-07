// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Cache, CacheKey } from "../../../src/libraries/Cache.sol";

/**
 * @title TestFuzz_Cache_Logic
 * @notice Fuzz properties for the unified keyed transient cache: read-after-write identity over the whole
 *         representable value range (everything below the populated-marker top bit), last-write-wins on
 *         overwrite, and key isolation between the two cache keys
 * @dev Pure-library layer, no market deploy. The library is driven internally so every step below executes
 *      in the test function's single call frame: transient storage is transaction-scoped, and one frame is
 *      the one context guaranteed to keep the slots alive across the whole write/read sequence
 */
contract TestFuzz_Cache_Logic is Test {
    /**
     * @dev The largest payload that does not collide with the populated-marker bit: all 255 payload bits set,
     *      2^255 - 1 = 57896044618658097711785492504343953926634992332820282019728792003956564819967
     */
    uint256 internal constant MAX_CACHEABLE_VALUE = (1 << 255) - 1;

    /**
     * The cache exists so a rate resolved once early in a transaction (for example the senior share rate
     * committed by a sync) is reused verbatim by every later consumer instead of being recomputed against
     * possibly moved state, so three properties are load-bearing:
     *   1. read-after-write identity: a hit must return the exact value written, because a corrupted rate
     *      would misprice every downstream tranche conversion in the same transaction,
     *   2. last-write-wins: a later stage refreshing the rate must fully supersede the earlier value,
     *   3. key isolation: the identical ST/JT tranche-to-NAV-unit rate and the senior share rate are
     *      unrelated quantities, so a write under one key must never surface under the other.
     * Expected values are the fuzz inputs themselves: the slot stores value | 2^255 (the top bit marks the
     * slot populated) and the read strips that bit, so any value below 2^255 loses nothing in either hop.
     */
    function testFuzz_WriteThenRead_RoundTripsAndOverwriteWinsBelowMarkerBit(
        uint256 _keySeed,
        uint256 _firstValue,
        uint256 _secondValue,
        uint256 _siblingValue
    )
        public
    {
        // Both CacheKey members are exercised, and values span the full representable range [0, 2^255 - 1],
        // including 0, which must still read as a HIT: a cached zero is distinguishable from a never-written slot
        CacheKey key = CacheKey(bound(_keySeed, 0, 1));
        CacheKey sibling = CacheKey(1 - uint256(key));
        _firstValue = bound(_firstValue, 0, MAX_CACHEABLE_VALUE);
        _secondValue = bound(_secondValue, 0, MAX_CACHEABLE_VALUE);
        _siblingValue = bound(_siblingValue, 0, MAX_CACHEABLE_VALUE);

        // Before anything is written both keys are misses: a miss is (false, 0), never a stale or phantom value
        (bool hit, uint256 value) = Cache._read(key);
        assertFalse(hit, "unwritten key reads as a miss");
        assertEq(value, 0, "a miss carries a zero value");
        (hit, value) = Cache._read(sibling);
        assertFalse(hit, "unwritten sibling key reads as a miss");
        assertEq(value, 0, "a sibling miss carries a zero value");

        // Read-after-write identity: the hit returns exactly the fuzzed input, bit for bit
        Cache._write(key, _firstValue);
        (hit, value) = Cache._read(key);
        assertTrue(hit, "written key reads as a hit");
        assertEq(value, _firstValue, "the hit returns exactly the written value");

        // Key isolation: writing one key must not populate the other -- the sibling stays a miss until written,
        // otherwise one quantity's consumer could silently price off the other's cached rate
        (hit, value) = Cache._read(sibling);
        assertFalse(hit, "sibling stays a miss after the other key is written");
        assertEq(value, 0, "the sibling miss still carries a zero value");

        // Last-write-wins: a second bounded write fully replaces the first with no residue of the old value
        Cache._write(key, _secondValue);
        (hit, value) = Cache._read(key);
        assertTrue(hit, "overwritten key still reads as a hit");
        assertEq(value, _secondValue, "the overwrite wins: the hit returns the second value exactly");

        // Once the sibling IS written it becomes a hit with its own value while the first key is untouched:
        // isolation holds in both directions, so neither rate can bleed into the other's slot
        Cache._write(sibling, _siblingValue);
        (hit, value) = Cache._read(sibling);
        assertTrue(hit, "written sibling reads as a hit");
        assertEq(value, _siblingValue, "the sibling hit returns exactly its own written value");
        (hit, value) = Cache._read(key);
        assertTrue(hit, "the first key is still a hit after the sibling write");
        assertEq(value, _secondValue, "the first key still holds its own last-written value");
    }
}
