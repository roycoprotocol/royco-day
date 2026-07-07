// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { IMachine } from "../../src/interfaces/external/makina/IMachine.sol";

/**
 * @title MockMakinaMachine
 * @notice Minimal Makina machine mock: a share token, an accounting token, and a convertToAssets driven by a
 *         settable share price so tests move the machine's yield without a real strategy
 * @dev The share price is the value of one whole share in whole accounting tokens, scaled to WAD precision.
 *      Decimals come from the constructor-provided tokens, so any tranche/accounting decimal pair is expressible
 */
contract MockMakinaMachine is IMachine {
    /// @dev The machine's share token, the Royco market's tranche asset
    address private immutable SHARE_TOKEN;

    /// @dev The machine's accounting token, the intermediate asset of the two-hop NAV conversion
    address private immutable ACCOUNTING_TOKEN;

    /// @dev Scale factor of the share token: 10^(share token decimals)
    uint256 private immutable SHARE_SCALE;

    /// @dev Scale factor of the accounting token: 10^(accounting token decimals)
    uint256 private immutable ACCOUNTING_SCALE;

    /// @notice The value of one whole share in whole accounting tokens, scaled to WAD precision
    uint256 public sharePriceWAD;

    /**
     * @notice Deploys the mock machine over the two provided tokens
     * @param _shareToken The machine's share token
     * @param _accountingToken The machine's accounting token
     * @param _initialSharePriceWAD The initial share price, scaled to WAD precision
     */
    constructor(address _shareToken, address _accountingToken, uint256 _initialSharePriceWAD) {
        SHARE_TOKEN = _shareToken;
        ACCOUNTING_TOKEN = _accountingToken;
        SHARE_SCALE = 10 ** IERC20Metadata(_shareToken).decimals();
        ACCOUNTING_SCALE = 10 ** IERC20Metadata(_accountingToken).decimals();
        sharePriceWAD = _initialSharePriceWAD;
    }

    /// @notice Sets the share price, the mock's stand-in for machine yield or loss
    /// @param _sharePriceWAD The new share price, scaled to WAD precision
    function setSharePriceWAD(uint256 _sharePriceWAD) external {
        sharePriceWAD = _sharePriceWAD;
    }

    /// @inheritdoc IMachine
    function shareToken() external view override(IMachine) returns (address) {
        return SHARE_TOKEN;
    }

    /// @inheritdoc IMachine
    function accountingToken() external view override(IMachine) returns (address) {
        return ACCOUNTING_TOKEN;
    }

    /// @inheritdoc IMachine
    /// @dev assets = shares x sharePriceWAD, rescaled from share decimals to accounting decimals, floored
    function convertToAssets(uint256 shares) external view override(IMachine) returns (uint256 assets) {
        return (shares * sharePriceWAD * ACCOUNTING_SCALE) / (SHARE_SCALE * 1e18);
    }
}
