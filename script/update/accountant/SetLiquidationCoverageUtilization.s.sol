// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDawnAccountant } from "../../../src/interfaces/IRoycoDawnAccountant.sol";
import { ParameterUpdateBase } from "../base/ParameterUpdateBase.sol";

/**
 * @title SetLiquidationCoverageUtilization
 * @notice Generates Safe transaction batches for updating `liquidationCoverageUtilizationWAD` on each
 *         market's accountant across multiple markets and chains.
 *
 * @dev `setLiquidationCoverageUtilization` is `restricted` to `ADMIN_ACCOUNTANT_ROLE` (timelocked). The
 *      harness emits one batched Safe JSON per chain per phase (schedule, execute, cancel).
 *
 *      Usage:
 *      1. Add/update config entries in `_initializeConfigs()` for target markets
 *      2. Run: forge script script/update/accountant/SetLiquidationCoverageUtilization.s.sol
 *      3. Import the generated JSON files from output/update/accountant/ into Safe Transaction Builder
 *
 *      Values are WAD precision: 1e18 = 100% coverageUtilization. The setter accepts values strictly above
 *      WAD (i.e. above 100% coverageUtilization) per the accountant's coverage-config validation.
 */
contract SetLiquidationCoverageUtilization is ParameterUpdateBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    struct SetLiquidationCoverageUtilizationConfig {
        uint256 chainId;
        string marketName;
        uint256 newLiquidationCoverageUtilizationWAD;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════════

    SetLiquidationCoverageUtilizationConfig[] internal _configs;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor() {
        _initializeConfigs();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIG
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Configure liquidation-coverageUtilization updates here.
    /// @dev Values are WAD-scaled fractional percentages (1e18 = 100%).
    function _initializeConfigs() internal {
        // ── Mainnet ──────────────────────────────────────────────────────────
        // sNUSD                : 100.14306%
        _configs.push(SetLiquidationCoverageUtilizationConfig({ chainId: MAINNET, marketName: SNUSD, newLiquidationCoverageUtilizationWAD: 1.0014306e18 }));
        // autoUSD              : 125.00000%
        _configs.push(SetLiquidationCoverageUtilizationConfig({ chainId: MAINNET, marketName: AUTOUSD, newLiquidationCoverageUtilizationWAD: 1.25e18 }));
        // syrupUSDC            : 133.33333%
        _configs.push(SetLiquidationCoverageUtilizationConfig({ chainId: MAINNET, marketName: SYRUP_USDC, newLiquidationCoverageUtilizationWAD: 1.3333333e18 }));
        // stcUSD               : 100.33445%
        _configs.push(SetLiquidationCoverageUtilizationConfig({ chainId: MAINNET, marketName: STCUSD, newLiquidationCoverageUtilizationWAD: 1.0033445e18 }));
        // ParetoFalconX        : 300.00000%
        _configs.push(SetLiquidationCoverageUtilizationConfig({ chainId: MAINNET, marketName: PARETO_FALCONX, newLiquidationCoverageUtilizationWAD: 3.0e18 }));
        // apyUSD               : 200.00000%
        _configs.push(SetLiquidationCoverageUtilizationConfig({ chainId: MAINNET, marketName: APYUSD, newLiquidationCoverageUtilizationWAD: 2.0e18 }));
        // eEARN                : 101.01010%
        _configs.push(SetLiquidationCoverageUtilizationConfig({ chainId: MAINNET, marketName: eEARN, newLiquidationCoverageUtilizationWAD: 1.010101e18 }));

        // ── Avalanche ────────────────────────────────────────────────────────
        // savUSD               : 100.05003%
        // _configs.push(SetLiquidationCoverageUtilizationConfig({ chainId: AVALANCHE, marketName: SAVUSD, newLiquidationCoverageUtilizationWAD: 1.0005003e18 }));

        // ── Arbitrum ─────────────────────────────────────────────────────────
        // sUSDai               : 116.66667%
        _configs.push(SetLiquidationCoverageUtilizationConfig({ chainId: ARBITRUM, marketName: SUSDAI, newLiquidationCoverageUtilizationWAD: 1.1666667e18 }));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ENTRY POINT
    // ═══════════════════════════════════════════════════════════════════════════

    function run() external {
        require(_configs.length > 0, "No configs defined");

        uint256[] memory chainIds = _getUniqueChainIds();

        for (uint256 c = 0; c < chainIds.length; c++) {
            uint256 chainId = chainIds[c];

            uint256 count = 0;
            for (uint256 i = 0; i < _configs.length; i++) {
                if (_configs[i].chainId == chainId) count++;
            }

            string memory rpcUrl = _getRpcUrl(chainId);
            vm.createSelectFork(rpcUrl);

            UpdateParams[] memory updates = new UpdateParams[](count);
            uint256 idx = 0;
            for (uint256 i = 0; i < _configs.length; i++) {
                if (_configs[i].chainId != chainId) continue;
                SetLiquidationCoverageUtilizationConfig storage cfg = _configs[i];
                MarketAddresses memory addrs = getMarketAddresses(cfg.marketName);
                updates[idx] = UpdateParams({
                    marketName: cfg.marketName,
                    target: addrs.accountant,
                    callData: abi.encodeCall(IRoycoDawnAccountant.setLiquidationCoverageUtilization, (cfg.newLiquidationCoverageUtilizationWAD)),
                    description: string.concat(
                        "Set liquidationCoverageUtilizationWAD for ", cfg.marketName, " to ", vm.toString(cfg.newLiquidationCoverageUtilizationWAD)
                    )
                });
                idx++;
            }

            _processChain(chainId, updates, "accountant", "set_liquidation_coverageUtilization", "Set liquidation coverageUtilization");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════════

    function _verify(UpdateParams memory _params) internal pure override {
        IRoycoDawnAccountant.RoycoDawnAccountantState memory state = IRoycoDawnAccountant(_params.target).getState();

        // Extract expected value from the calldata (skip 4-byte selector; uint256 is at offset 4)
        uint256 expected;
        bytes memory cd = _params.callData;
        assembly {
            expected := mload(add(cd, 36))
        }

        require(state.liquidationCoverageUtilizationWAD == expected, VerificationFailed("liquidationCoverageUtilizationWAD mismatch after execution"));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

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
