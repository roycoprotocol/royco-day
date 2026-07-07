// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Cache, CacheKey } from "../../src/libraries/Cache.sol";

/**
 * @title MockCacheUser
 * @notice External wrappers around the internal Cache library so tests can drive its transient reads and writes
 *         from a real call frame
 */
contract MockCacheUser {
    /// @notice Writes a value to the unified transient cache under the specified key
    /// @param _key The cache key to write to
    /// @param _value The value to cache
    function write(CacheKey _key, uint256 _value) external {
        Cache._write(_key, _value);
    }

    /// @notice Reads the unified transient cache at the specified key
    /// @param _key The cache key to read from
    /// @return cacheHit Whether the slot holds a populated value
    /// @return value The cached value on a hit, otherwise zero
    function read(CacheKey _key) external view returns (bool cacheHit, uint256 value) {
        return Cache._read(_key);
    }

    /// @notice Writes a value and immediately reads the same key back within one call frame
    /// @return cacheHit Whether the read-back observed a populated slot
    /// @return value The value the read-back observed
    function writeThenRead(CacheKey _key, uint256 _value) external returns (bool cacheHit, uint256 value) {
        Cache._write(_key, _value);
        return Cache._read(_key);
    }

    /**
     * @notice Writes two keyed values in order, then reads both keys back within one call frame
     * @dev With distinct keys this observes key isolation, with an identical key it observes that the
     *      second write overwrites the first
     * @return hitA Whether the first key read back as populated
     * @return valueA The value the first key read back
     * @return hitB Whether the second key read back as populated
     * @return valueB The value the second key read back
     */
    function writePairThenReadBoth(
        CacheKey _keyA,
        uint256 _valueA,
        CacheKey _keyB,
        uint256 _valueB
    )
        external
        returns (bool hitA, uint256 valueA, bool hitB, uint256 valueB)
    {
        Cache._write(_keyA, _valueA);
        Cache._write(_keyB, _valueB);
        (hitA, valueA) = Cache._read(_keyA);
        (hitB, valueB) = Cache._read(_keyB);
    }
}
