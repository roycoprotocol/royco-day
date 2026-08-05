// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { DeploymentResult, IdleCDOTranchePriceOracleParams, MarketConfig, OracleType } from "../../../script/config/DeploymentTypes.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits } from "../../../src/libraries/Units.sol";
import { IdleCDO_Chainlink_KernelSuite } from "../oracles/IdleCDO_Chainlink/IdleCDO_Chainlink_KernelSuite.sol";

/**
 * @title Pareto_FalconXUSDC_AA
 * @notice The ASSET layer of the fork chain: the concrete Day market fixture for the Pareto FalconX USDC AA market
 *         (ST/JT are the REAL Pareto Idle CDO's AA tranche token, priced tranche->underlying(USDC) via the CDO's
 *         virtualPrice and underlying->NAV via the Chainlink USDC/USD feed; the LPT holds the `{AA_share, USDC}`
 *         Gyro E-CLP BPT). The inherited `setUp` forks mainnet, deploys the market through the real `DeployScript`,
 *         and captures every contract into member vars — the market is ready to test. No `test_*` methods here:
 *         extending the IdleCDO+Chainlink oracle layer (which sits on the Balancer venue module, which sits on the
 *         abstract kernel suite) makes this one leaf carry the kernel suite plus the venue suites.
 * @dev The market deploys at a zero deviation threshold so every simulated virtual price move reads as a clock
 *      deviation, keeping the composed report's clock leg live for the suite's flows (the threshold semantics
 *      themselves are pinned in the concrete oracle and clock suites)
 */
contract Pareto_FalconXUSDC_AA is IdleCDO_Chainlink_KernelSuite {
    address internal constant PARETO_FALCONX_CDO = 0x433D5B175148dA32Ffe1e1A37a939E1b7e79be4d; // the REAL Idle CDO
    address internal constant AA_TRANCHE_TOKEN = 0xC26A6Fa2C37b38E549a4a1807543801Db684f99C; // ST/JT collateral asset
    address internal constant USDC_USD_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6; // underlying(USDC)->NAV feed
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // LPT pool quote asset

    function _idleCDO() internal pure override returns (address) {
        return PARETO_FALCONX_CDO;
    }

    function _cdoTrancheToken() internal pure override returns (address) {
        return AA_TRANCHE_TOKEN;
    }

    function _underlyingToNavFeed() internal pure override returns (address) {
        return USDC_USD_FEED;
    }

    function getTestConfig() public pure override returns (TestConfig memory) {
        return TestConfig({
            forkBlock: 25_400_000,
            forkRpcUrlEnvVar: "MAINNET_RPC_URL",
            stAsset: AA_TRANCHE_TOKEN,
            jtAsset: AA_TRANCHE_TOKEN,
            quoteAsset: USDC,
            hasLiquidityProviderTranche: true,
            initialFunding: 500_000e18
        });
    }

    function _deployKernelAndMarket() internal override returns (DeploymentResult memory) {
        // Clone the registered snUSD market shape (same 18-decimal collateral over a USDC quote pool) and swap in
        // the CDO AA tranche collateral with its composed virtual-price oracle, deployed by the script itself
        MarketConfig memory cfg = DEPLOY_SCRIPT.getMarketConfig("snUSD");
        cfg.collateralAsset = AA_TRANCHE_TOKEN;
        cfg.collateralAssetOracleType = OracleType.IdleCDOTranchePrice;
        cfg.collateralAssetOracleSpecificParams = abi.encode(
            IdleCDOTranchePriceOracleParams({
                idleCDO: PARETO_FALCONX_CDO,
                underlyingTokenToNavAssetFeed: USDC_USD_FEED,
                // Zero threshold: any observed virtual price change counts as an update (see the contract docstring)
                minDeviationWAD: 0,
                // The deployer attests the virtual price is current at deployment
                lastUpdate: uint32(block.timestamp),
                // Per-hop staleness immutables: the Chainlink leg tight (24h heartbeat doubled), the virtual-price
                // clock wide enough for the CDO's slow cadence
                feedStalenessThresholdSeconds: 48 hours,
                virtualPriceStalenessThresholdSeconds: 8 days
            })
        );

        // The template pulls the genesis pool seed from the configured funder. Repoint the funder at the broadcasting
        // deployer, which approves the template from inside the script's broadcast, and fund it with the seed legs
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
