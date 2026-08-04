// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import { IBaseTemplate } from "../../../interfaces/factory/IBaseTemplate.sol";
import { IRoycoFactory } from "../../../interfaces/factory/IRoycoFactory.sol";

/**
 * @notice Resolves the market authority a template is governed by, rejecting a null factory first
 * @param _factory The Royco factory the template is bound to
 * @return authority The market authority governing every template and market the factory deploys
 */
function _resolveMarketAuthority(IRoycoFactory _factory) view returns (address authority) {
    require(address(_factory) != address(0), IBaseTemplate.ROYCO_FACTORY_CANNOT_BE_ZERO_ADDRESS());
    return _factory.ROYCO_AUTHORITY();
}
