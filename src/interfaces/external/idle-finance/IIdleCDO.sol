// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/**
 * @title IIdleCDO
 * @author Idle Labs Inc.
 * @notice Abridged interface for the epochic Idle CDO variant (a credit vault) whose tranche token (AA or BB) is a Royco market's tranche asset
 */
interface IIdleCDO {
    /// @notice Address of the AA (senior) tranche token contract
    function AATranche() external view returns (address);

    /// @notice Address of the BB (junior) tranche token
    function BBTranche() external view returns (address);

    /// @notice Underlying token of the CDO (eg. USDC)
    function token() external view returns (address);

    /// @notice The credit vault strategy holding the CDO's epoch accounting
    function strategy() external view returns (address);

    /// @notice Whether the borrower has defaulted
    /// @dev Set permanently by the default handler, after which losses can be marked down without an epoch settlement
    function defaulted() external view returns (bool);

    /**
     * @notice Tranche price including interest and loss not yet split (since the last deposit, withdraw request, or accounting update)
     * @dev Denominated in the CDO underlying token's decimals, the upstream natspec is silent on the scale
     * @param _tranche Tranche token address
     * @return Value of one whole tranche token in underlying token units, scaled to the underlying token's decimals
     */
    function virtualPrice(address _tranche) external view returns (uint256);
}
