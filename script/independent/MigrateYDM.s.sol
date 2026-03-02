// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AccessManagerUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/access/manager/AccessManagerUpgradeable.sol";
import { IRoycoAccountant } from "../../src/interfaces/IRoycoAccountant.sol";
import { AdaptiveCurveYDM_V2 } from "../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { Script, console2 } from "lib/forge-std/src/Script.sol";

/// @title MigrateYDMScript
/// @notice Simulation script for updating AdaptiveCurveYDM V2 parameters on deployed markets.
/// @dev Forks the target chain, simulates the full AccessManager schedule → delay → execute flow,
///      and verifies post-migration state. Outputs calldata for multisig submission.
///
///      Usage:
///        forge script script/independent/MigrateYDM.s.sol --fork-url $MAINNET_RPC_URL
///        forge script script/independent/MigrateYDM.s.sol --fork-url $AVALANCHE_RPC_URL
contract MigrateYDMScript is Script {
    // ═══════════════════════════════════════════════════════════════════════════
    // SHARED ADDRESSES (same across chains via CREATE2)
    // ═══════════════════════════════════════════════════════════════════════════

    AccessManagerUpgradeable constant FACTORY = AccessManagerUpgradeable(0xD567cCbb336Eb71eC2537057E2bCF6DB840bB71d);
    AdaptiveCurveYDM_V2 constant YDM_V2 = AdaptiveCurveYDM_V2(0x764Ccb0c5aCD0e3c5E8Fd1Fdd4d66E5186fc0F7a);

    // ═══════════════════════════════════════════════════════════════════════════
    // MULTISIG ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    address constant ROOT_MULTISIG_ETHEREUM = 0x85De42e5697D16b853eA24259C42290DaCe35190;
    address constant ROOT_MULTISIG_NON_ETHEREUM = 0xBEe38793Eed92e6Cf9fcB56538CD981A87a8c315;

    uint32 constant ACCOUNTANT_ADMIN_DELAY = 1 days;

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET DEFINITIONS
    // ═══════════════════════════════════════════════════════════════════════════

    struct MarketConfig {
        string name;
        uint256 chainId;
        IRoycoAccountant accountant;
        address multisig;
        uint64 jtYieldShareAtZeroUtilWAD;
        uint64 jtYieldShareAtTargetUtilWAD;
        uint64 jtYieldShareAtFullUtilWAD;
        uint64 maxAdaptationSpeedWAD;
    }

    function _buildMarkets() internal pure returns (MarketConfig[] memory markets) {
        markets = new MarketConfig[](1);

        // savUSD — Avalanche
        markets[0] = MarketConfig({
            name: "savUSD",
            chainId: 43_114,
            accountant: IRoycoAccountant(0x7C6b4184fD7799Eef36E9CBddC8780Ef9c24413a),
            multisig: ROOT_MULTISIG_NON_ETHEREUM,
            jtYieldShareAtZeroUtilWAD: 0.1e18,
            jtYieldShareAtTargetUtilWAD: 0.1e18,
            jtYieldShareAtFullUtilWAD: 0.5e18,
            maxAdaptationSpeedWAD: uint64(50e18 / uint256(365 days))
        });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SCRIPT ENTRY POINT
    // ═══════════════════════════════════════════════════════════════════════════

    function run() external {
        MarketConfig[] memory markets = _buildMarkets();
        uint256 currentChainId = block.chainid;

        for (uint256 i = 0; i < markets.length; i++) {
            if (markets[i].chainId == currentChainId) {
                _simulateMigration(markets[i]);
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CORE MIGRATION + SIMULATION
    // ═══════════════════════════════════════════════════════════════════════════

    function _simulateMigration(MarketConfig memory _market) internal {
        address accountant = address(_market.accountant);

        console2.log("=== %s ===", _market.name);
        console2.log("  Accountant:                      ", accountant);

        // ── Build calldata ──
        bytes memory setYDMCalldata = _buildSetYDMCalldata(_market);

        // ── Log calldata for multisig submission ──
        _logMultisigCalldata(accountant, setYDMCalldata);

        // ── Simulate: schedule → warp → execute ──
        _simulateAccessManagerFlow(_market, accountant, setYDMCalldata);

        // ── Post-migration: verify new V2 curve parameters ──
        _verifyPostMigration(_market, accountant);

        console2.log("  Migration simulation PASSED");
        console2.log("");
    }

    function _buildSetYDMCalldata(MarketConfig memory _market) internal pure returns (bytes memory) {
        bytes memory ydmInitData = abi.encodeCall(
            AdaptiveCurveYDM_V2.initializeYDMForMarket,
            (_market.jtYieldShareAtZeroUtilWAD, _market.jtYieldShareAtTargetUtilWAD, _market.jtYieldShareAtFullUtilWAD, _market.maxAdaptationSpeedWAD)
        );
        return abi.encodeCall(IRoycoAccountant.setYDM, (address(YDM_V2), ydmInitData));
    }

    function _logMultisigCalldata(address _accountant, bytes memory _setYDMCalldata) internal view {
        console2.log("  --- Multisig calldata ---");
        console2.log("  Target (Factory):                ", address(FACTORY));

        bytes memory scheduleCalldata = abi.encodeCall(FACTORY.schedule, (_accountant, _setYDMCalldata, uint48(0)));
        console2.log("  schedule calldata:");
        console2.logBytes(scheduleCalldata);

        bytes memory executeCalldata = abi.encodeCall(FACTORY.execute, (_accountant, _setYDMCalldata));
        console2.log("  execute calldata:");
        console2.logBytes(executeCalldata);
    }

    function _simulateAccessManagerFlow(MarketConfig memory _market, address _accountant, bytes memory _setYDMCalldata) internal {
        vm.prank(_market.multisig);
        FACTORY.schedule(_accountant, _setYDMCalldata, uint48(0));

        bytes32 operationId = FACTORY.hashOperation(_market.multisig, _accountant, _setYDMCalldata);
        uint48 scheduledTime = FACTORY.getSchedule(operationId);
        require(scheduledTime > 0, string.concat(_market.name, ": Operation should be scheduled"));
        console2.log("  Scheduled at timestamp:          ", scheduledTime);

        vm.warp(block.timestamp + ACCOUNTANT_ADMIN_DELAY + 1);

        vm.prank(_market.multisig);
        FACTORY.execute(_accountant, _setYDMCalldata);
    }

    function _verifyPostMigration(MarketConfig memory _market, address _accountant) internal view {
        (
            uint64 newJtYieldShareAtTargetWAD,
            uint32 newLastAdaptationTimestamp,
            uint64 newMaxAdaptationSpeedWAD,
            uint64 newDiscountToTargetAtZeroUtilWAD,
            uint64 newPremiumToTargetAtFullUtilWAD
        ) = YDM_V2.accountantToCurve(_accountant);

        require(newJtYieldShareAtTargetWAD == _market.jtYieldShareAtTargetUtilWAD, string.concat(_market.name, ": jtYieldShareAtTargetWAD mismatch"));
        require(newMaxAdaptationSpeedWAD == _market.maxAdaptationSpeedWAD, string.concat(_market.name, ": maxAdaptationSpeedWAD mismatch"));
        require(
            newDiscountToTargetAtZeroUtilWAD == _market.jtYieldShareAtTargetUtilWAD - _market.jtYieldShareAtZeroUtilWAD,
            string.concat(_market.name, ": discountToTargetAtZeroUtilWAD mismatch")
        );
        require(
            newPremiumToTargetAtFullUtilWAD == _market.jtYieldShareAtFullUtilWAD - _market.jtYieldShareAtTargetUtilWAD,
            string.concat(_market.name, ": premiumToTargetAtFullUtilWAD mismatch")
        );
        require(newLastAdaptationTimestamp == 0, string.concat(_market.name, ": lastAdaptationTimestamp should be reset to 0"));

        console2.log("  New jtYieldShareAtTargetWAD:     ", newJtYieldShareAtTargetWAD);
        console2.log("  New maxAdaptationSpeedWAD:       ", newMaxAdaptationSpeedWAD);
        console2.log("  New discountAtZeroUtil:          ", newDiscountToTargetAtZeroUtilWAD);
        console2.log("  New premiumAtFullUtil:           ", newPremiumToTargetAtFullUtilWAD);
    }
}
