// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { AdaptiveCurveYDM_V2 } from "../../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { ParameterUpdateBase } from "../base/ParameterUpdateBase.sol";

/**
 * @title SetYDM
 * @notice Generates Safe transaction batches for re-initializing the AdaptiveCurve_V2 YDM
 *         across multiple markets and chains
 * @dev Usage:
 *      1. Add/update config entries in `_initializeConfigs()` for target markets
 *      2. Run: forge script script/update/accountant/SetYDM.s.sol
 *      3. Import the generated JSON files from output/update/accountant/ into Safe Transaction Builder
 */
contract SetYDM is ParameterUpdateBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    // ═══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    struct SetYDMConfig {
        uint256 chainId;
        string marketName;
        address ydm;
        uint64 yieldShareAtZeroUtilWAD;
        uint64 yieldShareAtTargetUtilWAD;
        uint64 yieldShareAtFullUtilWAD;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════════

    SetYDMConfig[] internal _configs;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor() {
        _initializeConfigs();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIG
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Configure YDM re-initialization here
     * @dev Values mirror the AdaptiveCurveYDM_V2 params from script/config/MarketDeploymentConfig.sol,
     */
    function _initializeConfigs() internal {
        // Populate with Day markets as they ship. Empty by default.
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ENTRY POINT
    // ═══════════════════════════════════════════════════════════════════════════

    function run() external {
        require(_configs.length > 0, "No configs defined");

        // Collect unique chain IDs
        uint256[] memory chainIds = _getUniqueChainIds();

        // Process each chain
        for (uint256 c = 0; c < chainIds.length; c++) {
            uint256 chainId = chainIds[c];

            // Collect configs for this chain
            uint256 count = 0;
            for (uint256 i = 0; i < _configs.length; i++) {
                if (_configs[i].chainId == chainId) count++;
            }

            // Build UpdateParams for this chain (requires fork to resolve addresses)
            string memory rpcUrl = _getRpcUrl(chainId);
            vm.createSelectFork(rpcUrl);

            UpdateParams[] memory updates = new UpdateParams[](count);
            uint256 idx = 0;
            for (uint256 i = 0; i < _configs.length; i++) {
                if (_configs[i].chainId == chainId) {
                    SetYDMConfig storage cfg = _configs[i];
                    MarketAddresses memory addrs = getMarketAddresses(cfg.marketName);

                    bytes memory ydmInitData = abi.encodeCall(
                        AdaptiveCurveYDM_V2.initializeYDMForMarket, (cfg.yieldShareAtZeroUtilWAD, cfg.yieldShareAtTargetUtilWAD, cfg.yieldShareAtFullUtilWAD)
                    );

                    updates[idx] = UpdateParams({
                        marketName: cfg.marketName,
                        target: addrs.accountant,
                        callData: abi.encodeCall(IRoycoDayAccountant.setJuniorTrancheYDM, (cfg.ydm, ydmInitData)),
                        description: string.concat("Set YDM for ", cfg.marketName)
                    });
                    idx++;
                }
            }

            _processChain(chainId, updates, "accountant", "set_ydm", "Set YDM");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Verifies the accountant points at the expected YDM and the curve was
     *         re-initialized with the expected params on that YDM.
     */
    function _verify(UpdateParams memory _params) internal view override {
        // Decode `setJuniorTrancheYDM(address ydm, bytes initData)` from the outer calldata
        (address expectedYDM, bytes memory initData) = _decodeSetYDMCallData(_params.callData);

        // Decode `initializeYDMForMarket(uint64,uint64,uint64,uint64)` from initData
        (uint64 expectedZeroUtilWAD, uint64 expectedTargetUtilWAD, uint64 expectedFullUtilWAD) = _decodeInitializeYDMForMarketCallData(initData);

        // Accountant must now point at the expected YDM
        IRoycoDayAccountant.RoycoDayAccountantState memory state = IRoycoDayAccountant(_params.target).getState();
        require(state.jtYDM == expectedYDM, VerificationFailed("YDM address mismatch after execution"));

        // The YDM must have stored the new curve params for this accountant.
        // Mirror the derivation from initializeYDMForMarket.
        uint64 expectedDiscount = expectedTargetUtilWAD - expectedZeroUtilWAD;
        uint64 expectedPremium = expectedFullUtilWAD - expectedTargetUtilWAD;

        (uint64 yieldShareAtTargetWAD, uint32 lastAdaptationTimestamp, uint64 discountToTargetAtZeroUtilWAD, uint64 premiumToTargetAtFullUtilWAD) =
            AdaptiveCurveYDM_V2(expectedYDM).accountantToCurve(_params.target);

        require(yieldShareAtTargetWAD == expectedTargetUtilWAD, VerificationFailed("yieldShareAtTargetWAD mismatch"));
        require(discountToTargetAtZeroUtilWAD == expectedDiscount, VerificationFailed("discountToTargetAtZeroUtilWAD mismatch"));
        require(premiumToTargetAtFullUtilWAD == expectedPremium, VerificationFailed("premiumToTargetAtFullUtilWAD mismatch"));
        // initializeYDMForMarket resets the last-adaptation timestamp to zero
        require(lastAdaptationTimestamp == 0, VerificationFailed("lastAdaptationTimestamp not reset"));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Strips the 4-byte selector and abi.decodes the `(address, bytes)` params of `setJuniorTrancheYDM`.
    function _decodeSetYDMCallData(bytes memory _cd) internal pure returns (address ydm, bytes memory initData) {
        bytes memory args = new bytes(_cd.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = _cd[i + 4];
        }
        (ydm, initData) = abi.decode(args, (address, bytes));
    }

    /// @dev Strips the 4-byte selector and abi.decodes the 3 uint64 params of `initializeYDMForMarket`.
    function _decodeInitializeYDMForMarketCallData(bytes memory _cd) internal pure returns (uint64 zeroUtilWAD, uint64 targetUtilWAD, uint64 fullUtilWAD) {
        bytes memory args = new bytes(_cd.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = _cd[i + 4];
        }
        (zeroUtilWAD, targetUtilWAD, fullUtilWAD) = abi.decode(args, (uint64, uint64, uint64));
    }

    function _getUniqueChainIds() internal view returns (uint256[] memory) {
        uint256[] memory temp = new uint256[](_configs.length);
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < _configs.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (temp[j] == _configs[i].chainId) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                temp[uniqueCount] = _configs[i].chainId;
                uniqueCount++;
            }
        }

        uint256[] memory result = new uint256[](uniqueCount);
        for (uint256 i = 0; i < uniqueCount; i++) {
            result[i] = temp[i];
        }
        return result;
    }
}
