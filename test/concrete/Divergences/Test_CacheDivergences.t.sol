// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Cache, CacheKey } from "../../../src/libraries/Cache.sol";

/**
 * @title Test_CacheDivergences
 * @notice The transient cache library rejects an out-of-domain write loudly: a value at or above 2^255 would
 *         collide with the populated marker and read back corrupted, so the write reverts instead
 * @dev The cache stores `value | 2^255` and reads back `stored ^ 2^255`, using the top bit as the populated
 *      marker that distinguishes a cached zero from an unset slot. That encoding is only injective for values
 *      strictly below 2^255, so `_write` requires `_value < 2^255` and reverts CACHE_VALUE_OUT_OF_DOMAIN
 *      otherwise — a cache that silently returned a different number than was stored is worse than no cache,
 *      because every consumer trusts a hit blindly
 * @dev The write is driven through an external wrapper so vm.expectRevert can catch the revert from the internal
 *      library call, while the in-domain round-trip read runs in this contract's own frame — the same
 *      transient-storage scope production consumes the cache in, where a quoter writes and reads within one transaction
 */
contract Test_CacheDivergences is Test {
    /// @dev 2^255, the populated-marker bit the cache ORs into every stored slot. Hand literal: half of 2^256
    uint256 internal constant TOP_BIT = 57896044618658097711785492504343953926634992332820282019728792003956564819968;

    /// @dev External wrapper so vm.expectRevert can catch a revert raised by the internal library write
    function writeExternal(CacheKey _key, uint256 _value) external {
        Cache._write(_key, _value);
    }

    /**
     * @notice A value at or above 2^255 reverts CACHE_VALUE_OUT_OF_DOMAIN instead of reading back corrupted, and
     *         the largest in-domain value round-trips exactly
     * @dev The top bit doubles as the populated marker, so a stored slot cannot tell "value 2^255 + x" apart from
     *      "value x". Writing 2^255 would read back 0 and 2^255 + 7 would read back 7, silent corruptions of ~5.8e76,
     *      so both must revert. 2^255 - 1 is the largest value the encoding round-trips cleanly
     */
    function test_writeValueAtOrAboveDomain_RevertsInsteadOfCorrupting() public {
        // Exactly the marker bit would be indistinguishable from caching zero, so the write reverts
        vm.expectRevert(Cache.CACHE_VALUE_OUT_OF_DOMAIN.selector);
        this.writeExternal(CacheKey.ST_SHARE_RATE, TOP_BIT);

        // Marker bit plus a payload would read back off by exactly 2^255, so the write reverts
        vm.expectRevert(Cache.CACHE_VALUE_OUT_OF_DOMAIN.selector);
        this.writeExternal(CacheKey.ST_SHARE_RATE, TOP_BIT + 7);

        // The largest in-domain value (2^255 - 1) is accepted and round-trips exactly
        Cache._write(CacheKey.ST_SHARE_RATE, TOP_BIT - 1);
        (bool hit, uint256 value) = Cache._read(CacheKey.ST_SHARE_RATE);
        assertTrue(hit, "an in-domain write marks the slot populated");
        assertEq(value, TOP_BIT - 1, "the largest in-domain value round-trips exactly");
    }
}
