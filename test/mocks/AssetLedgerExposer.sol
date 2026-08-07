// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AssetClaims } from "../../src/libraries/Types.sol";
import { AssetLedgerLogic } from "../../src/libraries/logic/AssetLedgerLogic.sol";

/**
 * @title AssetLedgerExposer
 * @notice Thin external exposer over the pure tranche claim math: the proportional scaling of a tranche's
 *         asset claims by a share count
 * @dev External entrypoints let a test observe reverts anywhere in the claim math through try/catch
 */
contract AssetLedgerExposer {
    /// @notice Scales a tranche's asset claims by the redeemed shares over the tranche's total shares
    function scaleAssetClaims(AssetClaims memory _claims, uint256 _shares, uint256 _totalTrancheShares)
        external
        pure
        returns (AssetClaims memory scaledClaims)
    {
        return AssetLedgerLogic._scaleAssetClaims(_claims, _shares, _totalTrancheShares, true);
    }
}
