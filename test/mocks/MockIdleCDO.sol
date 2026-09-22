// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IIdleCDO } from "../../src/interfaces/external/idle-finance/IIdleCDO.sol";

/**
 * @title MockIdleCDO
 * @notice Minimal Idle CDO mock: an AA tranche token, an underlying token, and a settable virtual price so tests
 *         move the CDO's yield without a real strategy
 * @dev The virtual price is the value of one whole AA tranche token in underlying token units, scaled to the
 *      underlying token's decimals exactly as the real CDO returns it. A revert mode lets override tests prove
 *      the venue never consults the CDO while an admin rate is stored
 */
contract MockIdleCDO is IIdleCDO {
    /// @notice Thrown by virtualPrice when revert mode is armed
    error CDO_REVERT_MODE();

    /// @notice Thrown by virtualPrice when queried for any token other than the AA tranche
    error UNKNOWN_TRANCHE();

    /// @dev The CDO's AA tranche token, the Royco market's tranche asset
    address private immutable AA_TRANCHE;

    /// @dev The CDO's underlying token, whose decimals denominate the virtual price
    address private immutable UNDERLYING_TOKEN;

    /// @notice The value of one whole AA tranche token in underlying token units, scaled to the underlying token's decimals
    uint256 public storedVirtualPrice;

    /// @notice When armed, every virtualPrice query reverts, standing in for a paused or broken CDO
    bool public revertMode;

    /// @notice The BB (junior) tranche token, settable so AA-only fixtures stay untouched
    address public storedBBTranche;

    /// @notice The number of successfully settled epochs, the settlement counter the discrete oracle's ID tracks
    uint256 public epochNumber;

    /// @notice Whether the borrower has defaulted, the discrete oracle's force-checkpoint signal
    bool public defaulted;

    /**
     * @notice Deploys the mock CDO over the two provided tokens
     * @param _aaTranche The CDO's AA tranche token
     * @param _underlyingToken The CDO's underlying token
     * @param _initialVirtualPrice The initial virtual price, scaled to the underlying token's decimals
     */
    constructor(address _aaTranche, address _underlyingToken, uint256 _initialVirtualPrice) {
        AA_TRANCHE = _aaTranche;
        UNDERLYING_TOKEN = _underlyingToken;
        storedVirtualPrice = _initialVirtualPrice;
    }

    /// @notice Sets the BB (junior) tranche token, unset by default so AA-only fixtures stay untouched
    /// @param _bbTranche The BB tranche token
    function setBBTranche(address _bbTranche) external {
        storedBBTranche = _bbTranche;
    }

    /// @notice Sets the virtual price, the mock's stand-in for CDO yield or loss
    /// @param _virtualPrice The new virtual price, scaled to the underlying token's decimals
    function setVirtualPrice(uint256 _virtualPrice) external {
        storedVirtualPrice = _virtualPrice;
    }

    /// @notice Sets the settlement counter, the mock's stand-in for stopEpoch settlements (a frozen counter models a default)
    /// @param _epochNumber The number of successfully settled epochs
    function setEpochNumber(uint256 _epochNumber) external {
        epochNumber = _epochNumber;
    }

    /// @notice Sets the defaulted flag, the mock's stand-in for a permanent borrower default
    /// @param _defaulted Whether the borrower has defaulted
    function setDefaulted(bool _defaulted) external {
        defaulted = _defaulted;
    }

    /// @notice The credit vault strategy pointer, collapsed onto the mock itself so one fixture serves both abridged interfaces
    function strategy() external view returns (address) {
        return address(this);
    }

    /// @notice Arms or disarms the revert mode
    function setRevertMode(bool _revertMode) external {
        revertMode = _revertMode;
    }

    /// @inheritdoc IIdleCDO
    function AATranche() external view override(IIdleCDO) returns (address) {
        return AA_TRANCHE;
    }

    /// @inheritdoc IIdleCDO
    function BBTranche() external view override(IIdleCDO) returns (address) {
        return storedBBTranche;
    }

    /// @inheritdoc IIdleCDO
    function token() external view override(IIdleCDO) returns (address) {
        return UNDERLYING_TOKEN;
    }

    /**
     * @inheritdoc IIdleCDO
     * @dev Requires a known tranche argument so a consumer regression that queried the wrong token fails loud
     * @dev The real CDO silently computes the BB price for any unknown address, so this guard is stricter than
     *      production by design: it catches miswired queries in tests instead of mispricing them
     */
    function virtualPrice(address _tranche) external view override(IIdleCDO) returns (uint256) {
        require(!revertMode, CDO_REVERT_MODE());
        require(_tranche == AA_TRANCHE || (_tranche == storedBBTranche && _tranche != address(0)), UNKNOWN_TRANCHE());
        return storedVirtualPrice;
    }
}
