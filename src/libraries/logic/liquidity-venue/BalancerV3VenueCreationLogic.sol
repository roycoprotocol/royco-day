// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { ILPOracleFactoryBase } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/oracles/ILPOracleFactoryBase.sol";
import { IGyroECLPPool } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/pool-gyro/IGyroECLPPool.sol";
import { IRateProvider } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { IBasePool } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IBasePool.sol";
import {
    PoolRoleAccounts as BalancerV3PoolRoleAccounts,
    TokenConfig as BalancerV3TokenConfig,
    TokenType as BalancerV3TokenType
} from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { GyroECLPPoolFactory } from "../../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import {
    AggregatorV3Interface as BalancerAggregatorV3Interface
} from "../../../../lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @notice The Gyro E-CLP pool creation inputs a market supplies, carried in the template's market params
 * @custom:field name - The pool token's name
 * @custom:field symbol - The pool token's symbol
 * @custom:field eclpParams - The E-CLP curve parameters
 * @custom:field derivedEclpParams - The high-precision derived E-CLP parameters computed off-chain from `eclpParams`
 * @custom:field swapFeePercentage - The pool's swap fee, scaled to WAD (1e18 = 100%)
 * @custom:field quoteAssetRateProvider - The rate provider supplying the quote leg's rate (the null address makes the leg STANDARD)
 * @custom:field chargeYieldFeeOnSeniorTrancheShares - Whether Balancer charges yield fees on the senior leg's rate growth
 * @custom:field chargeYieldFeeOnQuoteAsset - Whether Balancer charges yield fees on the quote leg's rate growth
 */
struct BalancerV3PoolCreationParams {
    string name;
    string symbol;
    IGyroECLPPool.EclpParams eclpParams;
    IGyroECLPPool.DerivedEclpParams derivedEclpParams;
    uint256 swapFeePercentage;
    address quoteAssetRateProvider;
    bool chargeYieldFeeOnSeniorTrancheShares;
    bool chargeYieldFeeOnQuoteAsset;
}

/**
 * @title BalancerV3VenueCreationLogic
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Creation of a Royco Day market's Balancer V3 liquidity venue: the Gyro E-CLP `{ST share, quote}` pool and
 *         its manipulation-resistant BPT TVL oracle
 */
library BalancerV3VenueCreationLogic {
    /// @notice Thrown when the senior tranche share does not sort below the quote asset, so it would not be pool token0
    error SENIOR_TRANCHE_NOT_FIRST_POOL_TOKEN(address seniorTranche, address quoteAsset);

    /// @notice Thrown when a pool leg is configured to pay yield fees without a rate provider to measure them against
    error RATE_PROVIDER_REQUIRED_WHEN_PAYING_YIELD_FEES(address token);

    /**
     * @notice Creates the market's Gyro E-CLP pool and the BPT oracle that prices it
     * @param _poolFactory The Balancer V3 Gyro E-CLP pool factory
     * @param _lpOracleFactory The Balancer E-CLP LP oracle factory
     * @param _constantPriceFeed The shared stateless constant-1.0 price feed used for both pool legs
     * @param _p The market's pool creation parameters
     * @param _seniorTranche The senior tranche share, which must sort below the quote asset so it is pool token0
     * @param _quoteAsset The quote asset paired against the senior share
     * @param _seniorRateProvider The senior leg's rate provider (the market's kernel)
     * @param _authority The market's access manager, set as the pool's pause, swap-fee, and creator role account
     * @param _salt The pool's deterministic creation salt
     * @return pool The created Gyro E-CLP pool (the liquidity provider tranche's asset)
     * @return bptOracle The created BPT TVL oracle
     */
    function createPoolAndBPTOracle(
        GyroECLPPoolFactory _poolFactory,
        ILPOracleFactoryBase _lpOracleFactory,
        address _constantPriceFeed,
        BalancerV3PoolCreationParams memory _p,
        address _seniorTranche,
        address _quoteAsset,
        address _seniorRateProvider,
        address _authority,
        bytes32 _salt
    )
        external
        returns (address pool, address bptOracle)
    {
        // Balancer registers a pool's tokens in ascending address order, and the market's whole design assumes the
        // senior share is token0, so reject any market id that did not mine to that ordering
        require(uint160(_seniorTranche) < uint160(_quoteAsset), SENIOR_TRANCHE_NOT_FIRST_POOL_TOKEN(_seniorTranche, _quoteAsset));

        BalancerV3TokenConfig[] memory tokens = new BalancerV3TokenConfig[](2);
        tokens[0] = _buildTokenConfig(_seniorTranche, _seniorRateProvider, _p.chargeYieldFeeOnSeniorTrancheShares);
        tokens[1] = _buildTokenConfig(_quoteAsset, _p.quoteAssetRateProvider, _p.chargeYieldFeeOnQuoteAsset);

        pool = _poolFactory.create({
            name: _p.name,
            symbol: _p.symbol,
            tokens: tokens,
            eclpParams: _p.eclpParams,
            derivedEclpParams: _p.derivedEclpParams,
            roleAccounts: BalancerV3PoolRoleAccounts({ pauseManager: _authority, swapFeeManager: _authority, poolCreator: _authority }),
            swapFeePercentage: _p.swapFeePercentage,
            poolHooksContract: address(0),
            enableDonation: false,
            disableUnbalancedLiquidity: false,
            salt: _salt
        });

        // Both legs are rate-provided, so both price at a constant 1.0 against their own rate
        BalancerAggregatorV3Interface[] memory feeds = new BalancerAggregatorV3Interface[](2);
        feeds[0] = BalancerAggregatorV3Interface(_constantPriceFeed);
        feeds[1] = BalancerAggregatorV3Interface(_constantPriceFeed);

        bptOracle = address(
            _lpOracleFactory.create({ pool: IBasePool(pool), shouldUseBlockTimeForOldestFeedUpdate: false, shouldRevertIfVaultUnlocked: false, feeds: feeds })
        );
    }

    /// @notice Builds the Balancer token config for one pool leg
    /// @dev A leg is WITH_RATE exactly when it has a rate provider, and can only pay yield fees when it has one
    function _buildTokenConfig(address _token, address _rateProvider, bool _paysYieldFees) private pure returns (BalancerV3TokenConfig memory) {
        require(!_paysYieldFees || _rateProvider != address(0), RATE_PROVIDER_REQUIRED_WHEN_PAYING_YIELD_FEES(_token));
        return BalancerV3TokenConfig({
            token: IERC20(_token),
            tokenType: _rateProvider == address(0) ? BalancerV3TokenType.STANDARD : BalancerV3TokenType.WITH_RATE,
            rateProvider: IRateProvider(_rateProvider),
            paysYieldFees: _paysYieldFees
        });
    }
}
