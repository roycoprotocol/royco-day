// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test, console } from "../../lib/forge-std/src/Test.sol";
import { AccessManagerUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/access/manager/AccessManagerUpgradeable.sol";
import { IRoycoAccountant } from "../../src/interfaces/IRoycoAccountant.sol";
import { AdaptiveCurveYDM_V1 } from "../../src/ydm/AdaptiveCurveYDM_V1.sol";
import { AdaptiveCurveYDM_V2 } from "../../src/ydm/AdaptiveCurveYDM_V2.sol";

/// @title MigrateYDMV1ToV2
/// @notice Utility test to generate and verify calldata for migrating markets from AdaptiveCurveYDM V1 to V2
/// @dev Forks Ethereum mainnet or Avalanche, schedules the operation on the AccessManager, warps past the delay, executes, and verifies
contract MigrateYDMV1ToV2 is Test {
    // ═══════════════════════════════════════════════════════════════════════════
    // SHARED ADDRESSES (same across chains via CREATE2)
    // ═══════════════════════════════════════════════════════════════════════════

    AccessManagerUpgradeable constant FACTORY = AccessManagerUpgradeable(0xD567cCbb336Eb71eC2537057E2bCF6DB840bB71d);
    AdaptiveCurveYDM_V1 constant YDM_V1 = AdaptiveCurveYDM_V1(0x071B0FA065774b403B8dae0aE93A09Df5DE3DFAc);
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
        markets = new MarketConfig[](4);

        // sNUSD — Ethereum
        markets[0] = MarketConfig({
            name: "sNUSD",
            chainId: 1,
            accountant: IRoycoAccountant(0x3371871E8901899fEc4539aE2d1737D84aCB6D89),
            multisig: ROOT_MULTISIG_ETHEREUM,
            jtYieldShareAtZeroUtilWAD: 0.06e18,
            jtYieldShareAtTargetUtilWAD: 0.06e18,
            jtYieldShareAtFullUtilWAD: 0.4e18,
            maxAdaptationSpeedWAD: uint64(50e18 / uint256(365 days))
        });

        // stcUSD — Ethereum
        markets[1] = MarketConfig({
            name: "stcUSD",
            chainId: 1,
            accountant: IRoycoAccountant(0x4D6DC4aE81101BF74498f1013b7Ffd1AEB5088bE),
            multisig: ROOT_MULTISIG_ETHEREUM,
            jtYieldShareAtZeroUtilWAD: 0.05e18,
            jtYieldShareAtTargetUtilWAD: 0.05e18,
            jtYieldShareAtFullUtilWAD: 0.4e18,
            maxAdaptationSpeedWAD: uint64(80e18 / uint256(365 days))
        });

        // autoUSD — Ethereum
        markets[2] = MarketConfig({
            name: "autoUSD",
            chainId: 1,
            accountant: IRoycoAccountant(0xf113B53334d7ccD4EDC8f321E74B7F140f3ebC83),
            multisig: ROOT_MULTISIG_ETHEREUM,
            jtYieldShareAtZeroUtilWAD: 0.05e18,
            jtYieldShareAtTargetUtilWAD: 0.05e18,
            jtYieldShareAtFullUtilWAD: 0.4e18,
            maxAdaptationSpeedWAD: uint64(80e18 / uint256(365 days))
        });

        // savUSD — Avalanche
        markets[3] = MarketConfig({
            name: "savUSD",
            chainId: 43_114,
            accountant: IRoycoAccountant(0x7C6b4184fD7799Eef36E9CBddC8780Ef9c24413a),
            multisig: ROOT_MULTISIG_NON_ETHEREUM,
            jtYieldShareAtZeroUtilWAD: 0.01e18,
            jtYieldShareAtTargetUtilWAD: 0.01e18,
            jtYieldShareAtFullUtilWAD: 0.5e18,
            maxAdaptationSpeedWAD: uint64(50e18 / uint256(365 days))
        });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // AVALANCHE TEST
    // ═══════════════════════════════════════════════════════════════════════════

    function test_migrateYDM_savUSD_avalanche() public {
        vm.skip(true);
        _forkAndMigrate(3, vm.envString("AVALANCHE_RPC_URL"));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ALL ETHEREUM MARKETS IN ONE TEST
    // ═══════════════════════════════════════════════════════════════════════════

    function test_migrateYDM_allEthereumMarkets() public {
        vm.skip(true);
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        MarketConfig[] memory markets = _buildMarkets();
        for (uint256 i = 0; i < 3; i++) {
            _migrateMarket(markets[i]);
        }
    }

    function testBatchEth() external {
        vm.skip(true);

        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        vm.startPrank(0x85De42e5697D16b853eA24259C42290DaCe35190, true);

        (bool success,) = address(0x40A2aCCbd92BCA938b02010E17A5b8929b49130D)
            .delegatecall(
                hex"8d80ff0a000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000005eb00d567ccbb336eb71ec2537057e2bcf6db840bb71d000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001a4f801a6980000000000000000000000003371871e8901899fec4539ae2d1737d84acb6d8900000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010416ffd4a3000000000000000000000000764ccb0c5acd0e3c5e8fd1fdd4d66e5186fc0f7a000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000849bbf63fa00000000000000000000000000000000000000000000000000d529ae9e86000000000000000000000000000000000000000000000000000000d529ae9e860000000000000000000000000000000000000000000000000000058d15e17628000000000000000000000000000000000000000000000000000000000171268b5ad4000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000d567ccbb336eb71ec2537057e2bcf6db840bb71d000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001a4f801a6980000000000000000000000004d6dc4ae81101bf74498f1013b7ffd1aeb5088be00000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010416ffd4a3000000000000000000000000764ccb0c5acd0e3c5e8fd1fdd4d66e5186fc0f7a000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000849bbf63fa00000000000000000000000000000000000000000000000000b1a2bc2ec5000000000000000000000000000000000000000000000000000000b1a2bc2ec50000000000000000000000000000000000000000000000000000058d15e1762800000000000000000000000000000000000000000000000000000000024ea4122aed000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000d567ccbb336eb71ec2537057e2bcf6db840bb71d000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001a4f801a698000000000000000000000000f113b53334d7ccd4edc8f321e74b7f140f3ebc8300000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010416ffd4a3000000000000000000000000764ccb0c5acd0e3c5e8fd1fdd4d66e5186fc0f7a000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000849bbf63fa00000000000000000000000000000000000000000000000000b1a2bc2ec5000000000000000000000000000000000000000000000000000000b1a2bc2ec50000000000000000000000000000000000000000000000000000058d15e1762800000000000000000000000000000000000000000000000000000000024ea4122aed0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
            );
        assertTrue(success, "Schedule Failed");

        vm.warp(block.timestamp + 1 days + 1);

        (success,) = address(0x40A2aCCbd92BCA938b02010E17A5b8929b49130D)
            .delegatecall(
                hex"8d80ff0a0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000058b00d567ccbb336eb71ec2537057e2bcf6db840bb71d000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001841cff79cd0000000000000000000000003371871e8901899fec4539ae2d1737d84acb6d890000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000010416ffd4a3000000000000000000000000764ccb0c5acd0e3c5e8fd1fdd4d66e5186fc0f7a000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000849bbf63fa00000000000000000000000000000000000000000000000000d529ae9e86000000000000000000000000000000000000000000000000000000d529ae9e860000000000000000000000000000000000000000000000000000058d15e17628000000000000000000000000000000000000000000000000000000000171268b5ad4000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000d567ccbb336eb71ec2537057e2bcf6db840bb71d000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001841cff79cd0000000000000000000000004d6dc4ae81101bf74498f1013b7ffd1aeb5088be0000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000010416ffd4a3000000000000000000000000764ccb0c5acd0e3c5e8fd1fdd4d66e5186fc0f7a000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000849bbf63fa00000000000000000000000000000000000000000000000000b1a2bc2ec5000000000000000000000000000000000000000000000000000000b1a2bc2ec50000000000000000000000000000000000000000000000000000058d15e1762800000000000000000000000000000000000000000000000000000000024ea4122aed000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000d567ccbb336eb71ec2537057e2bcf6db840bb71d000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001841cff79cd000000000000000000000000f113b53334d7ccd4edc8f321e74b7f140f3ebc830000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000010416ffd4a3000000000000000000000000764ccb0c5acd0e3c5e8fd1fdd4d66e5186fc0f7a000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000849bbf63fa00000000000000000000000000000000000000000000000000b1a2bc2ec5000000000000000000000000000000000000000000000000000000b1a2bc2ec50000000000000000000000000000000000000000000000000000058d15e1762800000000000000000000000000000000000000000000000000000000024ea4122aed0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
            );
        assertTrue(success, "Execute Failed");

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CORE MIGRATION LOGIC
    // ═══════════════════════════════════════════════════════════════════════════

    function _forkAndMigrate(uint256 _marketIndex, string memory _rpcUrl) internal {
        vm.createSelectFork(_rpcUrl);

        MarketConfig[] memory markets = _buildMarkets();
        MarketConfig memory market = markets[_marketIndex];

        _migrateMarket(market);
    }

    /// @dev Reads the YDM address from a deployed accountant via low-level staticcall
    ///      The deployed contracts may have a different struct layout than the current source,
    ///      so we use a raw staticcall and extract the ydm field at the known word offset
    function _readYDM(address _accountant) internal view returns (address ydm) {
        (bool success, bytes memory data) = _accountant.staticcall(abi.encodeWithSignature("getState()"));
        require(success, "getState() call failed");
        // The ydm field is at word index 9 in the deployed struct ABI encoding (0-indexed)
        // Fields: kernel(0), fixedTermDurationSeconds(1), fixedTermEndTimestamp(2), coverageWAD(3),
        //         betaWAD(4), lltvWAD(5), stProtocolFeeWAD(6), jtProtocolFeeWAD(7),
        //         yieldShareProtocolFeeWAD(8), ydm(9), ...
        require(data.length >= 320, "getState() return data too short");
        assembly {
            ydm := mload(add(data, 320)) // 32 (length prefix) + 9*32 = 320
        }
    }

    function _migrateMarket(MarketConfig memory _market) internal {
        address accountant = address(_market.accountant);

        // ── Pre-migration: read V1 state ──
        (uint64 v1JtYieldShareAtTargetWAD, uint32 v1LastAdaptationTimestamp, uint160 v1SteepnessWAD) = YDM_V1.accountantToCurve(accountant);

        address ydmBefore = _readYDM(accountant);
        assertEq(ydmBefore, address(YDM_V1), string.concat(_market.name, ": YDM should be V1 before migration"));

        console.log("===", _market.name, "===");
        console.log("Accountant:", accountant);
        console.log("V1 jtYieldShareAtTargetWAD:", v1JtYieldShareAtTargetWAD);
        console.log("V1 lastAdaptationTimestamp:", v1LastAdaptationTimestamp);
        console.log("V1 steepnessWAD:", v1SteepnessWAD);

        // ── Build calldata ──
        bytes memory ydmInitData = abi.encodeCall(
            AdaptiveCurveYDM_V2.initializeYDMForMarket,
            (_market.jtYieldShareAtZeroUtilWAD, _market.jtYieldShareAtTargetUtilWAD, _market.jtYieldShareAtFullUtilWAD, _market.maxAdaptationSpeedWAD)
        );

        bytes memory setYDMCalldata = abi.encodeCall(IRoycoAccountant.setYDM, (address(YDM_V2), ydmInitData));

        // Log calldata for multisig submission
        console.log("--- Calldata for multisig ---");
        console.log("Target (Accountant):", accountant);
        console.log("setYDM calldata:");
        console.logBytes(setYDMCalldata);

        // ── Step 1: Schedule the operation on the AccessManager ──
        bytes memory scheduleCalldata = abi.encodeCall(FACTORY.schedule, (accountant, setYDMCalldata, uint48(0)));
        console.log("schedule calldata (call on Factory):");
        console.logBytes(scheduleCalldata);

        vm.prank(_market.multisig);
        FACTORY.schedule(accountant, setYDMCalldata, uint48(0));

        // Verify the operation is scheduled
        bytes32 operationId = FACTORY.hashOperation(_market.multisig, accountant, setYDMCalldata);
        uint48 scheduledTime = FACTORY.getSchedule(operationId);
        assertGt(scheduledTime, 0, string.concat(_market.name, ": Operation should be scheduled"));
        console.log("Scheduled at timestamp:", scheduledTime);

        // ── Step 2: Warp past the 1-day execution delay ──
        vm.warp(block.timestamp + ACCOUNTANT_ADMIN_DELAY + 1);

        // ── Step 3: Execute the operation ──
        bytes memory executeCalldata = abi.encodeCall(FACTORY.execute, (accountant, setYDMCalldata));
        console.log("execute calldata (call on Factory):");
        console.logBytes(executeCalldata);

        vm.prank(_market.multisig);
        FACTORY.execute(accountant, setYDMCalldata);

        // ── Post-migration: verify YDM was updated ──
        address ydmAfter = _readYDM(accountant);
        assertEq(ydmAfter, address(YDM_V2), string.concat(_market.name, ": YDM should be V2 after migration"));

        // Verify V2 curve was initialized for this accountant
        (
            uint64 v2JtYieldShareAtTargetWAD,
            uint32 v2LastAdaptationTimestamp,
            uint64 v2MaxAdaptationSpeedWAD,
            uint64 v2DiscountToTargetAtZeroUtilWAD,
            uint64 v2PremiumToTargetAtFullUtilWAD
        ) = YDM_V2.accountantToCurve(accountant);

        assertEq(v2JtYieldShareAtTargetWAD, _market.jtYieldShareAtTargetUtilWAD, string.concat(_market.name, ": V2 jtYieldShareAtTargetWAD mismatch"));
        assertEq(v2MaxAdaptationSpeedWAD, _market.maxAdaptationSpeedWAD, string.concat(_market.name, ": V2 maxAdaptationSpeedWAD mismatch"));
        assertEq(
            v2DiscountToTargetAtZeroUtilWAD,
            _market.jtYieldShareAtTargetUtilWAD - _market.jtYieldShareAtZeroUtilWAD,
            string.concat(_market.name, ": V2 discountToTargetAtZeroUtilWAD mismatch")
        );
        assertEq(
            v2PremiumToTargetAtFullUtilWAD,
            _market.jtYieldShareAtFullUtilWAD - _market.jtYieldShareAtTargetUtilWAD,
            string.concat(_market.name, ": V2 premiumToTargetAtFullUtilWAD mismatch")
        );
        assertEq(v2LastAdaptationTimestamp, 0, string.concat(_market.name, ": V2 lastAdaptationTimestamp should be reset to 0"));

        console.log("V2 jtYieldShareAtTargetWAD:", v2JtYieldShareAtTargetWAD);
        console.log("V2 maxAdaptationSpeedWAD:", v2MaxAdaptationSpeedWAD);
        console.log("V2 discountToTargetAtZeroUtilWAD:", v2DiscountToTargetAtZeroUtilWAD);
        console.log("V2 premiumToTargetAtFullUtilWAD:", v2PremiumToTargetAtFullUtilWAD);
        console.log("Migration successful!");
        console.log("");
    }
}

interface IMultiSendCallOnly {
    function multiSend(bytes memory transactions) external payable;
}
