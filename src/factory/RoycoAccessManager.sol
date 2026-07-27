// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { AccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { IRoycoAccessManager } from "../interfaces/factory/IRoycoAccessManager.sol";

/**
 * @title RoycoAccessManager
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice The protocol's access manager: an OpenZeppelin AccessManager that additionally records, permanently, every
 *         target it has ever configured
 */
contract RoycoAccessManager is AccessManager, IRoycoAccessManager {
    /// @inheritdoc IRoycoAccessManager
    mapping(address target => bool configured) public override(IRoycoAccessManager) wasEverConfigured;

    constructor(address _initialAdmin) AccessManager(_initialAdmin) { }

    // ═══════════════════════════════════════════════════════════════════════════
    // TARGET-SCOPED WRITE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    function _setTargetFunctionRole(address _target, bytes4 _selector, uint64 _roleId) internal virtual override(AccessManager) {
        // Record the target as configured
        _markConfigured(_target);
        super._setTargetFunctionRole(_target, _selector, _roleId);
    }

    function _setTargetAdminDelay(address _target, uint32 _newDelay) internal virtual override(AccessManager) {
        // Record the target as configured
        _markConfigured(_target);
        super._setTargetAdminDelay(_target, _newDelay);
    }

    function _setTargetClosed(address _target, bool _closed) internal virtual override(AccessManager) {
        // Record the target as configured
        _markConfigured(_target);
        super._setTargetClosed(_target, _closed);
    }

    /// @dev Records a target as configured, emitting only on the transition so the event marks the first touch
    /// @param _target The target to record as configured
    function _markConfigured(address _target) private {
        if (!wasEverConfigured[_target]) {
            wasEverConfigured[_target] = true;
            emit TargetConfiguredAtGenesis(_target);
        }
    }
}
