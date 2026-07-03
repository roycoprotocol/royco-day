// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { ERC4626 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import { SafeERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

contract ERC4626Mock is ERC4626 {
    using SafeERC20 for IERC20;

    error FailedToSetSharePrice(uint256 expectedSharePrice, uint256 actualSharePrice);

    address internal immutable RESERVE_ADDRESS;

    constructor(address _underlying, address _reserveAddress) ERC4626(IERC20(_underlying)) ERC20("ERC4626Mock", "E4626M") {
        RESERVE_ADDRESS = _reserveAddress;
    }

    function setSharePrice(uint256 _sharePrice) external {
        uint256 requiredTotalAssets = _sharePrice * (totalSupply() + 10 ** _decimalsOffset()) - 1;
        uint256 currentTotalAssets = totalAssets();
        if (currentTotalAssets < requiredTotalAssets) {
            uint256 requiredAssets = requiredTotalAssets - currentTotalAssets;
            IERC20(asset()).safeTransferFrom(RESERVE_ADDRESS, address(this), requiredAssets);
        } else if (currentTotalAssets > requiredTotalAssets) {
            uint256 requiredAssets = currentTotalAssets - requiredTotalAssets;
            IERC20(asset()).safeTransfer(RESERVE_ADDRESS, requiredAssets);
        }

        require(_convertToAssets(1, Math.Rounding.Floor) == _sharePrice, FailedToSetSharePrice(_sharePrice, _convertToAssets(1, Math.Rounding.Floor)));
    }
}
