// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/// @title IIdleCDO
/// @author Idle Labs Inc.
/// @notice Abridged interface for an Idle CDO (Collateralized Debt Obligation) whose AA tranche token is a Royco market's tranche asset
interface IIdleCDO {
    /// @notice Address of the AA (senior) tranche token contract
    function AATranche() external view returns (address);

    /// @notice Underlying token of the CDO (e.g. USDC)
    function token() external view returns (address);

    /**
     * @notice Tranche price including interest and loss not yet split (since the last deposit, withdraw, or harvest)
     * @dev Denominated in the CDO underlying token's decimals, not 18 decimals as the upstream natspec claims
     * @param _tranche Tranche token address
     * @return Value of one whole tranche token in underlying token units, scaled to the underlying token's decimals
     */
    function virtualPrice(address _tranche) external view returns (uint256);
}
