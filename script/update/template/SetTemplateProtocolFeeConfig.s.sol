// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { BaseDeploymentTemplate } from "../../../src/factory/templates/base/BaseDeploymentTemplate.sol";
import { ParameterUpdateBase } from "../base/ParameterUpdateBase.sol";

/**
 * @title SetTemplateProtocolFeeConfig
 * @notice Sets BOTH yield-share protocol fees on the Day template — junior (`jtYieldShareProtocolFeeWAD`) and LP
 *         (`lptYieldShareProtocolFeeWAD`) — to 5%, preserving the two flat protocol fees, on Ethereum, Arbitrum, and
 *         Base.
 *      Usage (needs MAINNET_RPC_URL, ARBITRUM_RPC_URL, BASE_RPC_URL):
 *        forge script script/update/template/SetTemplateProtocolFeeConfig.s.sol
 */
contract SetTemplateProtocolFeeConfig is ParameterUpdateBase {
    /// @dev 5% in WAD (1e18 = 100%)
    uint64 internal constant FIVE_PERCENT_WAD = 0.05e18;

    string internal constant OUTPUT_SUBDIR = "template";
    string internal constant OUTPUT_PREFIX = "set_template_fee_config";
    string internal constant BATCH_DESCRIPTION = "Set Day template junior + LP yield-share protocol fees to 5%";

    /// @dev The registered Day template per chain (_PROD_V1.0.2 — per-chain addresses, see `UpdateConfig.dayTemplate`)
    function _template(uint256 _chainId) internal pure returns (address) {
        return dayTemplate(_chainId);
    }

    function run() external {
        uint256[] memory chainIds = new uint256[](3);
        chainIds[0] = MAINNET;
        chainIds[1] = ARBITRUM;
        chainIds[2] = BASE;

        for (uint256 i = 0; i < chainIds.length; ++i) {
            // Fork so the flat fees are read from this chain's live template. `_processChain` re-forks the same chain.
            vm.createSelectFork(_getRpcUrl(chainIds[i]));
            address template = _template(chainIds[i]);

            UpdateParams[] memory updates = new UpdateParams[](1);
            updates[0] = UpdateParams({
                marketName: "",
                target: template,
                callData: _feeConfigCall(template),
                description: "Set junior + LP yield-share protocol fees to 5% (preserving the flat fees)"
            });

            _processChain(chainIds[i], updates, OUTPUT_SUBDIR, OUTPUT_PREFIX, BATCH_DESCRIPTION);
        }
    }

    /// @dev Builds the `setProtocolFeeConfig` call: preserve the two flat fees, set both yield-share fees to 5%
    function _feeConfigCall(address _templateAddr) internal view returns (bytes memory) {
        (uint64 stFee, uint64 jtFee,,) = BaseDeploymentTemplate(_templateAddr).protocolFeeConfig();
        BaseDeploymentTemplate.ProtocolFeeConfig memory newConfig = BaseDeploymentTemplate.ProtocolFeeConfig({
            stProtocolFeeWAD: stFee, jtProtocolFeeWAD: jtFee, jtYieldShareProtocolFeeWAD: FIVE_PERCENT_WAD, lptYieldShareProtocolFeeWAD: FIVE_PERCENT_WAD
        });
        return abi.encodeCall(BaseDeploymentTemplate.setProtocolFeeConfig, (newConfig));
    }

    /// @inheritdoc ParameterUpdateBase
    function _verify(UpdateParams memory _params) internal view override {
        (,, uint64 jtYieldShare, uint64 lptYieldShare) = BaseDeploymentTemplate(_params.target).protocolFeeConfig();
        require(jtYieldShare == FIVE_PERCENT_WAD, VerificationFailed("junior yield-share fee not set to 5%"));
        require(lptYieldShare == FIVE_PERCENT_WAD, VerificationFailed("LP yield-share fee not set to 5%"));
    }
}
