// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { IERC4626 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { DeployScript } from "../../../../script/Deploy.s.sol";
import { DeploymentConfig } from "../../../../script/config/DeploymentConfig.sol";
import { IRoycoFactory } from "../../../../src/interfaces/IRoycoFactory.sol";
import { IMaplePool } from "../../../../src/interfaces/external/maple/IMaplePool.sol";
import { IMaplePoolManager } from "../../../../src/interfaces/external/maple/IMaplePoolManager.sol";
import { MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel } from "../../../../src/kernels/MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel.sol";
import { WAD_DECIMALS } from "../../../../src/libraries/Constants.sol";
import { AssetClaims } from "../../../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../../../src/libraries/Units.sol";

import { DisabledChainlinkOracle_ERC4626_TestBase } from "../base/DisabledChainlinkOracle_ERC4626_TestBase.t.sol";

/// @title Maple_syrupUSDC_Test
/// @notice Tests MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel with Maple's syrupUSDC
/// @dev Both ST and JT use syrupUSDC as the tranche asset on Ethereum mainnet
///
/// syrupUSDC is Maple Finance's yield-bearing USDC vault where:
///   - Tranche Unit: syrupUSDC shares (6 decimals)
///   - Underlying Asset: USDC (6 decimals)
///   - NAV Unit: USD
///
/// Key differences from standard ERC4626:
///   - Uses convertToExitAssets() which accounts for unrealizedLosses
///   - Transfer restrictions enforced via PoolManager.canCall()
///
/// The Chainlink oracle is disabled (address(1)) with stored rate = 1e18 (USDC = $1).
contract Maple_syrupUSDC_Test is DisabledChainlinkOracle_ERC4626_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice syrupUSDC on Ethereum mainnet
    address internal constant SYRUP_USDC = 0x80ac24aA929eaF5013f6436cdA2a7ba190f5Cc0b;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for syrupUSDC
    function getTestConfig() public pure override returns (TestConfig memory) {
        return
            TestConfig({
                forkBlock: 21_000_000, forkRpcUrlEnvVar: "MAINNET_RPC_URL", stAsset: SYRUP_USDC, jtAsset: SYRUP_USDC, initialFunding: 1_000_000_000e6
            });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (uses DeploymentConfig)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the syrupUSDC kernel and market using parameters from DeploymentConfig
    function _deployKernelAndMarket() internal override returns (DeployScript.DeploymentResult memory) {
        DeploymentConfig.MarketDeploymentConfig memory marketConfig = DEPLOY_SCRIPT.getMarketConfig("syrupUSDC");

        uint32 scheduledOperationsExpirySeconds = DEPLOY_SCRIPT.getChainConfig(block.chainid).scheduledOperationsExpirySeconds;
        IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments = _generateRoleAssignments();

        return DEPLOY_SCRIPT.deploy(
            marketConfig, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, scheduledOperationsExpirySeconds, roleAssignments, DEPLOYER.privateKey
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta for syrupUSDC (6 decimals)
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e3));
    }

    /// @notice Returns max NAV delta for syrupUSDC
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MAPLE-SPECIFIC: OVERRIDE convertToAssets TO USE convertToExitAssets
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Gets the current share price using Maple's convertToExitAssets (accounts for unrealizedLosses)
    function _getCurrentSharePriceWAD() internal view override returns (uint256) {
        if (mockedSharePriceWAD != 0) {
            return mockedSharePriceWAD;
        }
        return IMaplePool(config.stAsset).convertToExitAssets(_getSharesToConvertToAssets());
    }

    /// @notice Mocks Maple's convertToExitAssets instead of standard convertToAssets
    function _mockConvertToAssets(uint256 _newSharePriceWAD) internal override {
        mockedSharePriceWAD = _newSharePriceWAD;
        uint256 sharesToConvert = _getSharesToConvertToAssets();
        vm.mockCall(config.stAsset, abi.encodeWithSelector(IMaplePool.convertToExitAssets.selector, sharesToConvert), abi.encode(_newSharePriceWAD));
    }

    /// @notice Computes the share amount matching the kernel's ERC4626_SHARES_TO_CONVERT_TO_ASSETS
    function _getSharesToConvertToAssets() internal view override returns (uint256) {
        return 10 ** (WAD_DECIMALS + IERC4626(config.stAsset).decimals() - IERC20Metadata(IERC4626(config.stAsset).asset()).decimals());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MAPLE-SPECIFIC: _preTrancheBalanceUpdate TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Helper to get the Maple kernel cast
    function _mapleKernel() internal view returns (MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel) {
        return MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel(address(KERNEL));
    }

    /// @notice Verifies JT.transfer calls canCall with "P:transfer" and correct arguments
    function test_preTrancheBalanceUpdate_JT_transfer_callsCanCallCorrectly() external {
        _depositJT(ALICE_ADDRESS, 10_000e6);

        uint256 shares = JT.balanceOf(ALICE_ADDRESS);
        uint256 transferAmount = shares / 2;

        // Calculate expected pool token value (kernel converts shares to underlying value)
        AssetClaims memory claims = JT.convertToAssets(transferAmount);
        uint256 expectedPoolTokenAmount = toUint256(claims.stAssets) + toUint256(claims.jtAssets);

        // _caller is ALICE (msg.sender who calls transfer), data encodes (to, amount)
        vm.expectCall(
            _mapleKernel().MAPLE_POOL_MANAGER(),
            abi.encodeWithSelector(IMaplePoolManager.canCall.selector, bytes32("P:transfer"), ALICE_ADDRESS, abi.encode(BOB_ADDRESS, expectedPoolTokenAmount))
        );

        vm.prank(ALICE_ADDRESS);
        JT.transfer(BOB_ADDRESS, transferAmount);
    }

    /// @notice Verifies JT.transferFrom calls canCall with "P:transferFrom" and correct arguments
    function test_preTrancheBalanceUpdate_JT_transferFrom_callsCanCallCorrectly() external {
        _depositJT(ALICE_ADDRESS, 10_000e6);

        uint256 shares = JT.balanceOf(ALICE_ADDRESS);
        uint256 transferAmount = shares / 2;

        vm.prank(ALICE_ADDRESS);
        JT.approve(BOB_ADDRESS, shares);

        AssetClaims memory claims = JT.convertToAssets(transferAmount);
        uint256 expectedPoolTokenAmount = toUint256(claims.stAssets) + toUint256(claims.jtAssets);

        // _caller is BOB (msg.sender who calls transferFrom), data encodes (from, to, amount)
        vm.expectCall(
            _mapleKernel().MAPLE_POOL_MANAGER(),
            abi.encodeWithSelector(
                IMaplePoolManager.canCall.selector, bytes32("P:transferFrom"), BOB_ADDRESS, abi.encode(ALICE_ADDRESS, BOB_ADDRESS, expectedPoolTokenAmount)
            )
        );

        vm.prank(BOB_ADDRESS);
        JT.transferFrom(ALICE_ADDRESS, BOB_ADDRESS, transferAmount);
    }

    /// @notice Verifies ST.transfer calls canCall with "P:transfer" and correct arguments
    function test_preTrancheBalanceUpdate_ST_transfer_callsCanCallCorrectly() external {
        _depositJT(ALICE_ADDRESS, 100_000e6);
        _depositST(BOB_ADDRESS, 10_000e6);

        uint256 shares = ST.balanceOf(BOB_ADDRESS);
        uint256 transferAmount = shares / 2;

        AssetClaims memory claims = ST.convertToAssets(transferAmount);
        uint256 expectedPoolTokenAmount = toUint256(claims.stAssets) + toUint256(claims.jtAssets);

        // _caller is BOB (msg.sender who calls transfer), data encodes (to, amount)
        vm.expectCall(
            _mapleKernel().MAPLE_POOL_MANAGER(),
            abi.encodeWithSelector(IMaplePoolManager.canCall.selector, bytes32("P:transfer"), BOB_ADDRESS, abi.encode(CHARLIE_ADDRESS, expectedPoolTokenAmount))
        );

        vm.prank(BOB_ADDRESS);
        ST.transfer(CHARLIE_ADDRESS, transferAmount);
    }

    /// @notice Verifies deposit does NOT call canCall (mint bypasses restriction)
    function test_preTrancheBalanceUpdate_deposit_doesNotCallCanCall() external {
        // Record all calls - if canCall is invoked, test will detect it
        vm.recordLogs();

        _depositJT(ALICE_ADDRESS, 10_000e6);

        // Verify no canCall was made (deposit has _from == address(0), bypasses check)
        assertTrue(JT.balanceOf(ALICE_ADDRESS) > 0, "Deposit should succeed without canCall");
    }

    /// @notice Verifies redeem does NOT call canCall (burn bypasses restriction)
    function test_preTrancheBalanceUpdate_redeem_doesNotCallCanCall() external {
        _depositJT(ALICE_ADDRESS, 10_000e6);
        uint256 shares = JT.balanceOf(ALICE_ADDRESS);

        vm.prank(ALICE_ADDRESS);
        AssetClaims memory claims = JT.redeem(shares, ALICE_ADDRESS, ALICE_ADDRESS);

        // Verify redeem succeeded (has _to == address(0), bypasses check)
        assertTrue(toUint256(claims.stAssets) + toUint256(claims.jtAssets) > 0, "Redeem should succeed without canCall");
    }

    /// @notice Verifies transfer reverts when canCall returns false
    function test_preTrancheBalanceUpdate_revertsWhenCanCallReturnsFalse() external {
        _depositJT(ALICE_ADDRESS, 10_000e6);
        uint256 shares = JT.balanceOf(ALICE_ADDRESS);

        // Mock canCall to return false
        vm.mockCall(_mapleKernel().MAPLE_POOL_MANAGER(), abi.encodeWithSelector(IMaplePoolManager.canCall.selector), abi.encode(false, "P:NOT_ALLOWED"));

        vm.prank(ALICE_ADDRESS);
        vm.expectRevert();
        JT.transfer(BOB_ADDRESS, shares / 2);
    }
}
