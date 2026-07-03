// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { DeployScript } from "../../../../script/Deploy.s.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits } from "../../../../src/libraries/Units.sol";
import { Identical_ERC4626_Chainlink_BalancerV3_LT_KernelTest } from "../base/Identical_ERC4626_Chainlink_BalancerV3_LT_KernelTest.sol";

/**
 * @title Neutrl_snUSD
 * @notice Concrete Day market test for the Neutrl snUSD market (ST/JT are the snUSD ERC4626 vault, priced base(nUSD)->NAV
 *         via the RedStone nUSD feed; the LT holds the `{snUSD_share, USDC}` Gyro E-CLP BPT).
 * @dev Deploys the market through the real `DeployScript` using the `"snUSD"` config from the config file. The inherited
 *      `setUp` forks mainnet, deploys, and captures every contract into member vars — the market is ready to test. No
 *      `test_*` methods yet.
 */
contract Neutrl_snUSD is Identical_ERC4626_Chainlink_BalancerV3_LT_KernelTest {
    address internal constant SNUSD_VAULT = 0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313; // ST/JT ERC4626 asset
    address internal constant NUSD_REDSTONE_ORACLE = 0x5e7281f74e74D76347f0b8f4a36Fd3cb29c19d95; // base(nUSD)->NAV feed
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // LT pool quote token

    /// @inheritdoc Identical_ERC4626_Chainlink_BalancerV3_LT_KernelTest
    function _baseAssetToNavOracle() internal pure override returns (address) {
        return NUSD_REDSTONE_ORACLE;
    }

    function getTestConfig() public pure override returns (TestConfig memory) {
        return TestConfig({
            forkBlock: 25_400_000, // Gyro factory, Balancer V3 vault, snUSD vault, USDC, RedStone feed all have code here
            forkRpcUrlEnvVar: "MAINNET_RPC_URL",
            stAsset: SNUSD_VAULT,
            jtAsset: SNUSD_VAULT,
            quoteAsset: USDC,
            hasLiquidityTranche: true,
            initialFunding: 1_000_000e18
        });
    }

    function _deployKernelAndMarket() internal override returns (DeployScript.DeploymentResult memory) {
        return DEPLOY_SCRIPT.deploy(
            DEPLOY_SCRIPT.getMarketConfig("snUSD"),
            OWNER_ADDRESS, // factory admin (holds AccessManager ADMIN_ROLE)
            PROTOCOL_FEE_RECIPIENT_ADDRESS,
            DEPLOY_SCRIPT.getChainConfig(block.chainid).scheduledOperationsExpirySeconds,
            _generateRoleAssignments(),
            DEPLOYER.privateKey
        );
    }

    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e12));
    }

    function maxNAVDelta() public pure override returns (NAV_UNIT) {
        return toNAVUnits(uint256(1e12));
    }
}
