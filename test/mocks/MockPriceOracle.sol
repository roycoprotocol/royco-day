// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoPriceOracle } from "../../src/interfaces/IRoycoPriceOracle.sol";
import { NAV_UNIT, toNAVUnits } from "../../src/libraries/Units.sol";

/**
 * @title MockPriceOracle
 * @notice Settable IRoycoPriceOracle test double pricing 1 whole collateral asset in NAV units
 * @dev HARD RULE, updatedAt is NEVER auto-refreshed, freshness and price are independent knobs so warping time genuinely crosses the staleness gate
 * @dev The constructor stamps updatedAt once at block.timestamp, after that every field moves only through its setter
 * @dev Revert mode makes every oracle function revert, standing in for a circuit-breaking oracle halting all sync-gated operations
 */
contract MockPriceOracle is IRoycoPriceOracle {
    /// @notice Thrown by every oracle function when revert mode is armed
    error ORACLE_REVERT_MODE();

    /// @inheritdoc IRoycoPriceOracle
    address public immutable COLLATERAL_ASSET;

    /// @dev The price of 1 whole collateral asset in NAV units, WAD scaled
    uint256 private _priceWAD;

    /// @dev The last update timestamp reported by getPrice, poke, and previewPoke, never auto-refreshed
    uint256 private _updatedAt;

    /// @dev Whether every oracle function reverts
    bool private _revertMode;

    /**
     * @notice Deploys the mock oracle with a single fresh report
     * @param _collateralAsset The collateral asset this oracle prices in NAV units
     * @param _initialPriceWAD The initial price of 1 whole collateral asset in NAV units, WAD scaled
     */
    constructor(address _collateralAsset, uint256 _initialPriceWAD) {
        COLLATERAL_ASSET = _collateralAsset;
        _priceWAD = _initialPriceWAD;
        _updatedAt = block.timestamp;
    }

    // =============================
    // IRoycoPriceOracle Surface
    // =============================

    /// @inheritdoc IRoycoPriceOracle
    function getPrice() external view override(IRoycoPriceOracle) returns (NAV_UNIT price, uint256 updatedAt) {
        require(!_revertMode, ORACLE_REVERT_MODE());
        return (toNAVUnits(_priceWAD), _updatedAt);
    }

    /// @inheritdoc IRoycoPriceOracle
    function poke() external view override(IRoycoPriceOracle) returns (uint256 updatedAt) {
        require(!_revertMode, ORACLE_REVERT_MODE());
        return _updatedAt;
    }

    /// @inheritdoc IRoycoPriceOracle
    function previewPoke() external view override(IRoycoPriceOracle) returns (uint256 updatedAt) {
        require(!_revertMode, ORACLE_REVERT_MODE());
        return _updatedAt;
    }

    /// @inheritdoc IRoycoPriceOracle
    function decimals() external view override(IRoycoPriceOracle) returns (uint8) {
        require(!_revertMode, ORACLE_REVERT_MODE());
        return 18;
    }

    /// @inheritdoc IRoycoPriceOracle
    function description() external view override(IRoycoPriceOracle) returns (string memory) {
        require(!_revertMode, ORACLE_REVERT_MODE());
        return "MockPriceOracle";
    }

    /// @inheritdoc IRoycoPriceOracle
    function version() external view override(IRoycoPriceOracle) returns (uint256) {
        require(!_revertMode, ORACLE_REVERT_MODE());
        return 1;
    }

    // =============================
    // Field Knobs (each independent, none touch updatedAt except its own setter)
    // =============================

    /// @notice Sets the price WITHOUT touching updatedAt, so a price move never implicitly refreshes staleness
    function setPrice(uint256 _newPriceWAD) external {
        _priceWAD = _newPriceWAD;
    }

    /// @notice Sets the reported update timestamp, the only way freshness moves
    function setUpdatedAt(uint256 _newUpdatedAt) external {
        _updatedAt = _newUpdatedAt;
    }

    /// @notice Arms or disarms the revert mode on every oracle function
    function setRevertMode(bool _shouldRevert) external {
        _revertMode = _shouldRevert;
    }
}
