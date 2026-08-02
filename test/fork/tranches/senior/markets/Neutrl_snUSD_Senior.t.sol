// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { DeployScript } from "../../../../../script/Deploy.s.sol";
import { DeploymentResult, MarketConfig } from "../../../../../script/config/DeploymentTypes.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits } from "../../../../../src/libraries/Units.sol";
import { Test_SeniorTrancheDepositWithdrawBase } from "../Test_SeniorTrancheDepositWithdrawBase.t.sol";

/**
 * @title Neutrl_snUSD_Senior
 * @notice Runs the senior-tranche deposit/withdraw suite against the real forked Neutrl snUSD market. The test methods
 *         + senior helpers come from `Test_SeniorTrancheDepositWithdrawBase` (which extends the ERC4626-Chainlink-Balancer
 *         per-kernel base for the sim/deal/oracle hooks); this concrete only supplies the per-market config. `setUp` is
 *         inherited from `Test_KernelSuiteBase`.
 */
contract Neutrl_snUSD_Senior is Test_SeniorTrancheDepositWithdrawBase {
    address internal constant SNUSD_VAULT = 0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313; // ST/JT ERC4626 asset
    address internal constant NUSD_REDSTONE_ORACLE = 0x5e7281f74e74D76347f0b8f4a36Fd3cb29c19d95; // base(nUSD)->NAV feed
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // LPT pool quote asset

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
            hasLiquidityProviderTranche: true,
            initialFunding: 1_000_000e18
        });
    }

    function _deployKernelAndMarket() internal override returns (DeploymentResult memory) {
        // The template pulls the genesis pool seed from the configured funder. Repoint the funder at the broadcasting
        // deployer, which approves the template from inside the script's broadcast, and fund it with the seed legs
        MarketConfig memory cfg = DEPLOY_SCRIPT.getMarketConfig("snUSD");
        deal(cfg.gyroECLPPoolParams.quoteAsset, DEPLOYER.addr, cfg.poolInitialization.quoteAmount);
        if (cfg.poolInitialization.collateralAmount != 0) {
            deal(cfg.collateralAsset, DEPLOYER.addr, cfg.poolInitialization.collateralAmount);
        }
        return DEPLOY_SCRIPT.deploy(
            cfg,
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
