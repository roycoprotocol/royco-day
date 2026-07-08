// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { SlotDerivation } from "../../lib/openzeppelin-contracts/contracts/utils/SlotDerivation.sol";
import { TransientSlot } from "../../lib/openzeppelin-contracts/contracts/utils/TransientSlot.sol";

/**
 * @notice Indexes a slot in the unified transient cache: each key occupies the transient slot at the cache base slot offset by the key's ordinal
 * @custom:type IDENTICAL_ST_JT_TRANCHE_TO_NAV_UNIT_RATE - The identical senior and junior tranche unit to NAV unit conversion rate (only used if ST and JT are invested in the same asset)
 * @custom:type ST_SHARE_RATE - The senior tranche share rate (senior NAV per share)
 * @dev The ordinal is the key's transient slot offset from the cache base slot, so the enum is bounded to 256 members by the reserved ERC-7201 slot window
 * @dev Ordering is unconstrained: the cache is transient and auto-clears every transaction, so no persistent layout depends on the ordinals
 */
enum CacheKey {
    IDENTICAL_ST_JT_TRANCHE_TO_NAV_UNIT_RATE,
    ST_SHARE_RATE
}

/**
 * @title Cache
 * @author Waymont
 * @notice A unified keyed transient cache usable by any contract: one transient slot per CacheKey derived from a single ERC-7201 base slot, with a top-bit populated marker so a cached zero is distinguishable from an unset slot
 */
library Cache {
    using SlotDerivation for bytes32;
    using TransientSlot for bytes32;
    using TransientSlot for TransientSlot.Uint256Slot;

    /**
     * @dev The base transient slot for the unified cache using the ERC-7201 pattern
     * @dev Each cache key occupies its ordinal slot at this base offset
     * @dev keccak256(abi.encode(uint256(keccak256("Royco.transient.Cache")) - 1)) & ~bytes32(uint256(0xff))
     */
    bytes32 private constant TRANSIENT_CACHE_BASE_STORAGE_SLOT = 0x70d6b292032d8753f59a7cdffcb7469958b18c62ee56cf41848217b8027ee200;

    /// @dev The top bit set on a transient cache slot to mark it populated, so a set slot is distinguishable from an unset one
    uint256 private constant CACHE_SET_MASK = (1 << 255);

    /// @notice Thrown when a value to cache is not strictly less than 2^255, which would collide with the populated marker and read back corrupted
    error CACHE_VALUE_OUT_OF_DOMAIN();

    /**
     * @notice Reads a value from the unified transient cache
     * @dev The top bit (CACHE_SET_MASK) marks a populated slot, so an unset (zero) slot reads as a miss
     * @dev View-safe: it never writes, so it is callable on the static read path
     * @param _key The key in this cache to read from
     * @return cacheHit Whether the slot holds a populated value
     * @return value The cached value if this was a cache hit, otherwise zero
     */
    function _read(CacheKey _key) internal view returns (bool cacheHit, uint256 value) {
        uint256 slotValue = _getTransientStorageSlot(_key).asUint256().tload();
        if ((slotValue & CACHE_SET_MASK) != 0) return (true, (slotValue ^ CACHE_SET_MASK));
    }

    /**
     * @notice Writes a value to the unified transient cache for the remainder of the transaction
     * @dev The value is stored as `_value | CACHE_SET_MASK` — re-callable to overwrite
     * @dev The value must be strictly less than 2^255 so the populated marker is unambiguous
     * @param _key The key in this cache to write to
     * @param _value The value to cache
     */
    function _write(CacheKey _key, uint256 _value) internal {
        // The value must be strictly less than 2^255 so it cannot collide with the populated marker, reject an out-of-domain value loudly rather than reading it back corrupted
        require(_value < CACHE_SET_MASK, CACHE_VALUE_OUT_OF_DOMAIN());
        _getTransientStorageSlot(_key).asUint256().tstore((_value | CACHE_SET_MASK));
    }

    /**
     * @notice Returns the transient slot holding the cached value for the specified cache key
     * @dev Offsets the cache base slot by the key's ordinal — the reserved 256-slot ERC-7201 window guarantees keys never collide
     * @param _key The key in this cache to derive the transient storage slot for
     * @return The transient slot for the specified cache key
     */
    function _getTransientStorageSlot(CacheKey _key) private pure returns (bytes32) {
        return TRANSIENT_CACHE_BASE_STORAGE_SLOT.offset(uint256(_key));
    }
}
