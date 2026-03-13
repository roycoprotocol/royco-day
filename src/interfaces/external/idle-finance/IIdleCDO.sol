// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/// @title Idle CDO interface
/// @author Idle Labs Inc.
/// @notice External interface for Idle CDO (Collateralized Debt Obligation) tranche operations
interface IIdleCDO {
    /// @notice Address of the AA (senior) tranche token contract
    /// @return Address of the AA tranche token
    function AATranche() external view returns (address);

    /// @notice Address of the BB (junior) tranche token contract
    /// @return Address of the BB tranche token
    function BBTranche() external view returns (address);

    /// @notice Underlying token (e.g. DAI)
    /// @return Underlying token address
    function token() external view returns (address);

    /// @notice Tranche price including interest/loss not yet split (since last deposit/withdraw/harvest)
    /// @param _tranche Tranche address
    /// @return Virtual price in underlying units per tranche token (18 decimals)
    function virtualPrice(address _tranche) external view returns (uint256);
}
