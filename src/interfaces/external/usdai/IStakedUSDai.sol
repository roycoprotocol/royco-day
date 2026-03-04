// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title Staked USDai Interface
 * @author MetaStreet Foundation
 */
interface IStakedUSDai {
    /**
     * @notice Get redemption share price
     * @return Redemption share price
     */
    function redemptionSharePrice() external view returns (uint256);

    /// @dev ERC4626 asset function which returns the address of USDai
    function asset() external view returns (address);
}
