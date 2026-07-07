// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { CacheKey } from "../../src/libraries/Cache.sol";
import { MockCacheUser } from "../mocks/MockCacheUser.sol";

/**
 * @title CacheSymbolicSpec
 * @notice Native symbolic specs for the unified keyed transient cache: one transient slot per key, with the
 *         top bit doubling as a populated marker so a cached zero is a hit rather than an unset miss. The
 *         load-bearing properties: an unwritten key reads as a miss with a zero value, a value strictly below
 *         the top bit round-trips exactly as a hit, caching zero is a hit distinguishable from a miss, distinct
 *         keys never alias and the last write to a key wins, and — the divergence candidate — a value with the
 *         top bit already set is silently accepted and read back with that bit stripped, since the marker bit
 *         is the value's own top bit and the encoding is only injective below it
 * @dev Run with `forge test --symbolic --match-path test/symbolic/CacheSymbolic.t.sol`. Functions prefixed
 *      check_ are discovered only under --symbolic. Every write and its read share one call frame (the driver's
 *      writeThenRead / writePairThenReadBoth wrappers), so the transient-storage scope is exactly how
 *      production consumes the cache: a quoter writes and reads within a single transaction. Every expected
 *      value is derived independently from the mask-and-XOR encoding, never by re-running the library
 * @dev Engine prerequisite (transient storage): the checks below rely on the symbolic engine modeling tstore /
 *      tload with EVM semantics — an unwritten transient slot reads as zero, a tstore is observable by a later
 *      tload in the same frame, and distinct slots are independent. This was verified to hold on the first
 *      symbolic run (all checks proved). Were it ever to regress, the identical properties are carried
 *      empirically by test/concrete/Quoters/Test_Cache.t.sol and test/fuzz/Logic/TestFuzz_Cache.t.sol, and the
 *      top-bit divergence by test/concrete/Divergences/Test_CacheDivergences.t.sol
 */
contract CacheSymbolicSpec is Test {
    /// @dev The top bit, 2^255, the library ORs into every stored slot as the populated marker. Derived here
    ///      independently as the single highest bit of a 256-bit word, not read from the library
    uint256 internal constant TOP_BIT = 1 << 255;

    /// @dev The number of keys in the CacheKey enum, so ordinal domains stay in range for the cast
    uint256 internal constant KEY_COUNT = 2;

    MockCacheUser internal cache;

    function setUp() public {
        cache = new MockCacheUser();
    }

    /*//////////////////////////////////////////////////////////////////////
                    A FRESH SLOT READS AS A MISS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Reading any key that has never been written returns a miss with a zero value: an unset transient
     *         slot is zero, its top marker bit is clear, so the read reports not-populated. This is what lets a
     *         consumer branch on the hit flag and recompute on a cold cache instead of trusting a stale or
     *         absent value
     * @dev Exhaustive over both enum ordinals via a bounded symbolic ordinal. Independent derivation: with no
     *      prior tstore the slot is zero, zero AND the marker is zero, so _read short-circuits to its default
     *      (false, 0) return — no arithmetic, purely the unset-slot branch
     */
    function check_unwrittenKeyReadsAsAMissWithZeroValue(uint256 keyOrd) external view {
        vm.assume(keyOrd < KEY_COUNT);

        (bool hit, uint256 value) = cache.read(CacheKey(keyOrd));

        // An untouched slot must never masquerade as a populated hit, and it must carry no value
        assert(!hit);
        assert(value == 0);
    }

    /*//////////////////////////////////////////////////////////////////////
                    WRITE THEN READ ROUND-TRIPS BELOW THE TOP BIT
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Writing any value strictly below the top bit and reading the same key back returns a hit with
     *         exactly that value. This is the cache's whole contract on its documented input domain (both
     *         production writers cache WAD-scale rates far below 2^255): a write followed by a read in the same
     *         transaction observes the written value unchanged
     * @dev Exhaustive over both ordinals. Independent derivation of the encoding: the store is `v | 2^255`, and
     *      for v below 2^255 the top bit is clear in v so the OR just sets the marker without touching any
     *      payload bit. The read sees the marker set (a hit) and returns `stored ^ 2^255`, which clears exactly
     *      the marker the OR set, recovering v. No production call is re-run to form the expectation
     */
    function check_writtenValueBelowTopBitReadsBackExactlyAsAHit(uint256 keyOrd, uint256 v) external {
        vm.assume(keyOrd < KEY_COUNT);
        // The library's documented precondition: the value must leave the marker bit free
        vm.assume(v < TOP_BIT);

        (bool hit, uint256 value) = cache.writeThenRead(CacheKey(keyOrd), v);

        // A populated slot reads back as a hit carrying precisely the written value
        assert(hit);
        assert(value == v);
    }

    /*//////////////////////////////////////////////////////////////////////
                    A CACHED ZERO IS A HIT, NOT A MISS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Writing zero and reading it back returns a hit whose value is zero — the entire reason the marker
     *         bit exists. Without the marker a cached zero would be indistinguishable from an unset slot, so a
     *         consumer that legitimately cached a zero rate would recompute forever. The marker makes "cached
     *         zero" and "never written" two different observable states
     * @dev The direct contrast with the fresh-slot miss above: same zero payload, opposite hit flag. Derivation:
     *      the store is `0 | 2^255 = 2^255`, whose marker bit is set (so a hit), and the read returns
     *      `2^255 ^ 2^255 = 0`. The marker is what carries the populated signal when the value itself is zero
     */
    function check_writingZeroProducesAHitDistinguishableFromAMiss(uint256 keyOrd) external {
        vm.assume(keyOrd < KEY_COUNT);

        (bool hit, uint256 value) = cache.writeThenRead(CacheKey(keyOrd), 0);

        // Zero is a legitimately cached value, so it must report as a populated hit, unlike the unset-slot miss
        assert(hit);
        assert(value == 0);
    }

    /*//////////////////////////////////////////////////////////////////////
                    TOP-BIT WRITE IS SILENTLY CORRUPTED (DIVERGENCE)
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice DIVERGENCE CANDIDATE. Writing a value with the top bit already set does not revert, and the value
     *         reads back as a hit with the top bit stripped — off by exactly 2^255 from what was stored. The
     *         library documents the below-2^255 precondition in prose but never enforces it, so an oversized
     *         write corrupts silently instead of failing loud, and every consumer trusts the hit blindly. This
     *         check pins the ACTUAL lossy behavior; the expected-correct behavior is a revert on any value at
     *         or above 2^255
     * @dev Exhaustive over both ordinals. Independent derivation: for v at or above 2^255 the top bit is
     *      already set, so `v | 2^255 == v` — the OR is a no-op and nothing marks this apart from a value that
     *      merely reached into the marker bit. The read sees the marker set (still a hit) and returns
     *      `v ^ 2^255`, which for v with its top bit set equals `v - 2^255`. So the write-read round trip loses
     *      exactly 2^255, unnoticed. Unreachable via today's WAD-scale writers, but a latent API hazard
     */
    function check_DIVERGENCE_candidate_valueWithTopBitSetIsSilentlyReadBackWithTheBitStripped(
        uint256 keyOrd,
        uint256 v
    )
        external
    {
        vm.assume(keyOrd < KEY_COUNT);
        // The out-of-contract region: the value already occupies the marker bit
        vm.assume(v >= TOP_BIT);

        (bool hit, uint256 value) = cache.writeThenRead(CacheKey(keyOrd), v);

        // Still reported as a populated hit: the corruption is silent, never a revert or a miss
        assert(hit);
        // The read-back is the stored value with the marker bit cleared, i.e. exactly 2^255 short
        assert(value == v - TOP_BIT);
    }

    /*//////////////////////////////////////////////////////////////////////
                    DISTINCT KEYS NEVER ALIAS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Two distinct keys occupy independent slots: writing one and then the other, then reading both,
     *         returns each key's own value as a hit. The keys never collide, so caching one rate can never
     *         silently overwrite another. This is the slot-offset arithmetic — base slot plus the key ordinal —
     *         doing its job of giving every key a private slot within the reserved window
     * @dev Both orderings of the two-key pair are covered by leaving the ordinals symbolic and only requiring
     *      them distinct. Independent derivation: distinct ordinals offset the base slot to distinct transient
     *      slots, so the second write lands elsewhere and cannot disturb the first. Both values are held below
     *      the top bit so each round-trips exactly, isolating the aliasing question from the encoding
     */
    function check_distinctKeysNeverAlias(uint256 keyOrdA, uint256 keyOrdB, uint256 vA, uint256 vB) external {
        vm.assume(keyOrdA < KEY_COUNT && keyOrdB < KEY_COUNT);
        // Two different keys, so the slots they derive must not overlap
        vm.assume(keyOrdA != keyOrdB);
        vm.assume(vA < TOP_BIT && vB < TOP_BIT);

        (bool hitA, uint256 valueA, bool hitB, uint256 valueB) =
            cache.writePairThenReadBoth(CacheKey(keyOrdA), vA, CacheKey(keyOrdB), vB);

        // Each key holds exactly what was written to it: the second write did not bleed into the first slot
        assert(hitA && valueA == vA);
        assert(hitB && valueB == vB);
    }

    /*//////////////////////////////////////////////////////////////////////
                    LAST WRITE WINS ON THE SAME KEY
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Writing the same key twice makes the second write win: both read-backs observe the later value.
     *         The cache is re-callable to overwrite, so a fresh sync can replace a stale cached rate in place
     *         without a clear step, and no reader can ever observe the superseded value afterward
     * @dev Exhaustive over both ordinals. Independent derivation: the two writes tstore to the identical slot,
     *      so the second overwrites the first, and both subsequent reads of that one slot return the second
     *      value. Both values are held below the top bit so the round-trip is exact and only the overwrite
     *      semantics are under test
     */
    function check_lastWriteWinsOnSameKey(uint256 keyOrd, uint256 vA, uint256 vB) external {
        vm.assume(keyOrd < KEY_COUNT);
        vm.assume(vA < TOP_BIT && vB < TOP_BIT);

        // Same key for both writes: the pair collapses onto one slot
        (bool hitA, uint256 valueA, bool hitB, uint256 valueB) =
            cache.writePairThenReadBoth(CacheKey(keyOrd), vA, CacheKey(keyOrd), vB);

        // Both read-backs see the second write; the first value is unobservable after the overwrite
        assert(hitA && valueA == vB);
        assert(hitB && valueB == vB);
    }
}
