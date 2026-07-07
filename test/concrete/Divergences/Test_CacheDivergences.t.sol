// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Cache, CacheKey } from "../../../src/libraries/Cache.sol";

/**
 * @title Test_CacheDivergences
 * @notice Loud, first-class pin of the transient cache library's lossy top-bit write: values at or above 2^255
 *         collide with the populated marker and silently read back with the top bit stripped
 * @dev The cache stores `value | 2^255` and reads back `stored ^ 2^255`, using the top bit as the populated
 *      marker that distinguishes a cached zero from an unset slot. That encoding is only injective for values
 *      strictly below 2^255. The library documents that precondition but never enforces it, so an oversized
 *      write succeeds and corrupts silently instead of failing loud. If a future src change adds the missing
 *      bound check, the pin below MUST fail — that is the alarm it exists to raise
 * @dev The library is driven through internal calls in this contract's own frame, so every write and its read
 *      share one transient-storage scope — exactly how production consumes the cache, where a quoter writes and
 *      reads within a single transaction
 */
contract Test_CacheDivergences is Test {
    /// @dev 2^255, the populated-marker bit the cache ORs into every stored slot. Hand literal: half of 2^256
    uint256 internal constant TOP_BIT = 57896044618658097711785492504343953926634992332820282019728792003956564819968;

    /**
     * @notice DIVERGENCE 26: writing a value with the top bit set does not revert; the value silently reads back
     *         with the top bit stripped, breaking read-after-write identity
     * @dev The top bit doubles as the populated marker, so a stored slot cannot tell "value 2^255 + x" apart
     *      from "value x". EXPECTED-CORRECT: `_write` reverts on any value >= 2^255 — a cache that silently
     *      returns a different number than was stored is worse than no cache, because every consumer trusts a
     *      hit blindly. ACTUAL: the write succeeds and the corrupted value flows onward as a clean hit
     * @dev Corrupt read-backs hand-derived from the encoding, never from re-running it:
     *      write 2^255:     stored = 2^255 | 2^255 = 2^255 (marker only), read = 2^255 ^ 2^255 = 0
     *      write 2^255 + 7: stored = (2^255 + 7) | 2^255 = 2^255 + 7,     read = (2^255 + 7) ^ 2^255 = 7
     */
    function test_DIVERGENCE_26_writeValueWithTopBitSet_SilentlyReadsBackTopBitStripped() public {
        // Exactly the marker bit: the write is indistinguishable from caching zero. A consumer that stored
        // 2^255 gets back 0 on a "hit" — e.g. a rate cache would price everything at zero without any revert.
        Cache._write(CacheKey.ST_SHARE_RATE, TOP_BIT); // does NOT revert (the divergence)
        (bool hit, uint256 value) = Cache._read(CacheKey.ST_SHARE_RATE);
        assertTrue(hit, "the oversized write must still mark the slot populated (marker bit is the value's own top bit)");
        assertEq(value, 0, "2^255 must silently read back as 0 (top bit stripped by the marker XOR)");

        // Marker bit plus a payload: the payload survives but the top bit vanishes, so the read-back is off by
        // exactly 2^255 — a silent corruption of ~5.8e76, not a truncation a caller could ever detect from a hit.
        Cache._write(CacheKey.ST_SHARE_RATE, TOP_BIT + 7); // overwrite, again without any revert
        (hit, value) = Cache._read(CacheKey.ST_SHARE_RATE);
        assertTrue(hit, "the second oversized write must also read as a populated slot");
        assertEq(value, 7, "2^255 + 7 must silently read back as 7 (only the low 255 bits round-trip)");
    }
}
