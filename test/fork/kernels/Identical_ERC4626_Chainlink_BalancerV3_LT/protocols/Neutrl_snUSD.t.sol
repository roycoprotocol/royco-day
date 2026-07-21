// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { DeployScript } from "../../../../../script/Deploy.s.sol";
import { DeploymentResult } from "../../../../../script/config/DeploymentTypes.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits } from "../../../../../src/libraries/Units.sol";
import { Test_BalancerLPGateReinvestBase } from "../../../balancer/base/Test_BalancerLPGateReinvestBase.t.sol";

/**
 * @title Neutrl_snUSD
 * @notice Concrete Day market fixture for the Neutrl snUSD market (ST/JT are the snUSD ERC4626 vault, priced base(nUSD)->NAV
 *         via the RedStone nUSD feed; the LT holds the `{snUSD_share, USDC}` Gyro E-CLP BPT). The inherited `setUp` forks
 *         mainnet, deploys the market through the real `DeployScript`, and captures every contract into member vars — the
 *         market is ready to test. No `test_*` methods here: extending the deep Balancer-venue fork chain (which itself
 *         extends the abstract kernel suite) makes this one leaf carry the kernel suite plus the venue suites.
 */
contract Neutrl_snUSD is Test_BalancerLPGateReinvestBase {
    address internal constant SNUSD_VAULT = 0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313; // ST/JT ERC4626 asset
    address internal constant NUSD_REDSTONE_ORACLE = 0x5e7281f74e74D76347f0b8f4a36Fd3cb29c19d95; // base(nUSD)->NAV feed
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // LT pool quote asset

    function _baseAssetToNavOracle() internal pure override returns (address) {
        return NUSD_REDSTONE_ORACLE;
    }

    function getTestConfig() public pure override returns (TestConfig memory) {
        return TestConfig({
            forkBlock: 25_400_000,
            forkRpcUrlEnvVar: "MAINNET_RPC_URL",
            stAsset: SNUSD_VAULT,
            jtAsset: SNUSD_VAULT,
            quoteAsset: USDC,
            hasLiquidityTranche: true,
            initialFunding: 1_000_000e18
        });
    }

    function _deployKernelAndMarket() internal override returns (DeploymentResult memory) {
        return DEPLOY_SCRIPT.deploy(
            DEPLOY_SCRIPT.getMarketConfig("snUSD"),
            OWNER_ADDRESS,
            PROTOCOL_FEE_RECIPIENT_ADDRESS,
            DEPLOY_SCRIPT.getChainConfig(block.chainid, false).scheduledOperationsExpirySeconds,
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
