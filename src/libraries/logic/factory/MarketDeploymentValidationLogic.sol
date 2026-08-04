// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import { IVault } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { HooksConfig as BalancerV3HooksConfig } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { IAccessManaged } from "../../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { ADMIN_ROLE, PUBLIC_ROLE } from "../../../factory/Roles.sol";
import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../../../factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { IRoycoDayAccountant } from "../../../interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayEntryPoint } from "../../../interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoDayKernel } from "../../../interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../../interfaces/IRoycoVaultTranche.sol";
import { IBaseTemplate } from "../../../interfaces/factory/IBaseTemplate.sol";
import { IRoycoProtocolTemplate } from "../../../interfaces/factory/IRoycoProtocolTemplate.sol";
import { MAX_PROTOCOL_FEE_WAD, WAD } from "../../Constants.sol";
import { TrancheType } from "../../Types.sol";
import { BalancerV3PoolCreationParams } from "../liquidity-venue/BalancerV3VenueCreationLogic.sol";

/**
 * @title MarketDeploymentValidationLogic
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Validation of a Royco Day market deployment
 */
library MarketDeploymentValidationLogic {
    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Thrown when the market ID is zero
    error MARKET_ID_REQUIRED();

    /// @notice Thrown when a market parameter that must name a live contract is the null address
    error NULL_MARKET_PARAMETER();

    /// @notice Thrown when a market parameter names an address that holds no code
    error MARKET_PARAMETER_HAS_NO_CODE(address subject);

    /// @notice Thrown when the collateral and quote assets are the same token, which cannot form a two-token pool
    error COLLATERAL_AND_QUOTE_ASSET_IDENTICAL(address asset);

    /// @notice Thrown when a tranche is deployed without a share token name or symbol
    error EMPTY_TRANCHE_NAME_OR_SYMBOL();

    /// @notice Thrown when a market is deployed without genesis pool liquidity
    error POOL_SEED_REQUIRED();

    /// @notice Thrown when a tranche selects its yield distribution model shape under an empty name
    error EMPTY_YDM_TYPE();

    /// @notice Thrown when a yield distribution model is handed an empty initialization blob
    error EMPTY_YDM_INITIALIZATION_DATA();

    /// @notice Thrown when the pool is created without a pool token name or symbol
    error EMPTY_POOL_NAME_OR_SYMBOL();

    /// @notice Thrown when the E-CLP's price range is not a real interval
    error INVALID_ECLP_PRICE_RANGE();

    /// @notice Thrown when a genesis seed carries a collateral leg on a market that requires junior coverage
    error COLLATERAL_SEED_REQUIRES_ZERO_MIN_COVERAGE();

    /// @notice Thrown when the accountant's economic configuration is out of bounds
    error INVALID_ACCOUNTANT_CONFIG();

    /// @notice Thrown when the template charges a yield fee on the quote leg but the market supplies no rate provider for it
    error QUOTE_RATE_PROVIDER_REQUIRED_FOR_YIELD_FEE();

    /// @notice Thrown when the created Balancer pool is not a fresh, unseeded, hookless `{ST_share, quote}` pool
    error INVALID_POOL_CONFIGURATION(address pool);

    /// @notice Thrown when a deployed market contract's on-chain wiring does not match the expected configuration
    error MARKET_WIRING_VERIFICATION_FAILED(address subject);

    // ═══════════════════════════════════════════════════════════════════════════
    // PARAM VALIDATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Validates the deployer-supplied params before any of the market's contracts exist
    /// @param _rawParams The ABI-encoded `MarketParams` the deployer passed to `deployMarket`
    /// @param _chargeYieldFeeOnQuoteAsset The template's pool policy for the quote leg, passed in rather than read
    ///        from storage so this library holds no assumption about the template's layout
    /// @return params The validated market params
    function validateMarketParams(
        bytes calldata _rawParams,
        bool _chargeYieldFeeOnQuoteAsset
    )
        external
        view
        returns (RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory params)
    {
        params = abi.decode(_rawParams, (RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams));

        // The market ID must be non-zero
        require(params.marketId != 0, MARKET_ID_REQUIRED());

        // Every tranche is a live ERC20, so it must carry a name and a symbol
        _requireNamed(params.stParams);
        _requireNamed(params.jtParams);
        _requireNamed(params.lptParams);

        // The market's two assets must both be live tokens, and a pool needs two distinct ones
        _requireContract(params.collateralAsset);
        _requireContract(params.quoteAsset);
        require(params.collateralAsset != params.quoteAsset, COLLATERAL_AND_QUOTE_ASSET_IDENTICAL(params.collateralAsset));

        // Validate the accountant's configuration
        _validateAccountantParams(params.accountantParams);

        // Validate the pool's creation parameters
        _validatePoolCreationParams(params.poolCreationParams);

        // Validate the pool's initialization parameters
        _validatePoolInitializationParams(params.poolInitializationParams, params.accountantParams);

        // Each tranche selects its model by shape name out of the template's registry, and the empty name is never registered
        require(bytes(params.jtYdmType).length != 0 && bytes(params.lptYdmType).length != 0, EMPTY_YDM_TYPE());

        // The senior tranche self-liquidation bonus must be less than WAD
        require(params.stSelfLiquidationBonusWAD < WAD, INVALID_ACCOUNTANT_CONFIG());

        // The collateral asset oracle is mandatory; the kernel separately pins that it prices THIS collateral asset
        _requireContract(params.collateralAssetOracle);

        // Balancer rejects a leg that pays yield fees without a rate provider to measure them against.
        require(!_chargeYieldFeeOnQuoteAsset || params.poolCreationParams.quoteAssetRateProvider != address(0), QUOTE_RATE_PROVIDER_REQUIRED_FOR_YIELD_FEE());

        // Optional feeds: null is the documented "not applicable" case, but a non-null one must be live
        if (params.sequencerUptimeFeed != address(0)) _requireCode(params.sequencerUptimeFeed);
        if (params.poolCreationParams.quoteAssetRateProvider != address(0)) _requireCode(params.poolCreationParams.quoteAssetRateProvider);
    }

    /**
     * @notice Validates the Gyro E-CLP pool's creation params
     * @dev The pool factory and the Vault apply their own tighter bounds at creation; these are the checks that are
     *      cheaper to fail here than after the senior tranche has already been deployed
     * @param _params The pool creation params
     */
    function _validatePoolCreationParams(BalancerV3PoolCreationParams memory _params) private pure {
        // The pool token is a live ERC20 in its own right
        require(bytes(_params.name).length != 0 && bytes(_params.symbol).length != 0, EMPTY_POOL_NAME_OR_SYMBOL());

        // The E-CLP's price range must be a real interval. Gyro validates the full curve at pool construction, but an
        // inverted range is the one mistake worth catching before a pool is created against it
        require(_params.eclpParams.alpha < _params.eclpParams.beta, INVALID_ECLP_PRICE_RANGE());
    }

    /**
     * @notice Validates the genesis seed against the market it is seeding
     * @dev The seed is the market's FIRST deposit, so the junior tranche is still empty. A collateral leg mints senior
     *      shares against that empty junior, which takes coverage utilization above WAD and reverts inside the deposit.
     *      Only a market with no coverage floor can be seeded with collateral, and failing here says so plainly rather
     *      than surfacing as a `COVERAGE_REQUIREMENT_VIOLATED` from deep inside the accounting sync
     * @param _params The genesis seed's params
     * @param _accountantParams The accountant's params, read for the market's coverage floor
     */
    function _validatePoolInitializationParams(
        RoycoDayBalancerV3MarketDeploymentTemplate.PoolInitializationParams memory _params,
        IBaseTemplate.AccountantDeploymentParams memory _accountantParams
    )
        private
        pure
    {
        // The quote leg is mandatory, checked here rather than at the end of the deployment
        require(_params.quoteAmount != 0, POOL_SEED_REQUIRED());

        // The collateral leg is optional, and only reachable on a market that requires no junior coverage
        if (_params.collateralAmount != 0) require(_accountantParams.minCoverageWAD == 0, COLLATERAL_SEED_REQUIRES_ZERO_MIN_COVERAGE());
    }

    /**
     * @notice Validates the accountant's economic configuration
     * @dev Mirrors the bounds `RoycoDayAccountant.initialize` enforces, applied before the market's first proxy exists
     * @param _params The accountant's deployer-supplied params
     */
    function _validateAccountantParams(IBaseTemplate.AccountantDeploymentParams memory _params) private pure {
        // Coverage must demand less than the whole senior exposure, and the liquidation threshold can only be breached after losses
        require(_params.minCoverageWAD < WAD && _params.coverageLiquidationUtilizationWAD > WAD, INVALID_ACCOUNTANT_CONFIG());

        // The liquidity requirement must demand less market-making depth than the entire senior claim
        require(_params.minLiquidityWAD < WAD, INVALID_ACCOUNTANT_CONFIG());

        // The two premiums are both carved out of senior appreciation, so together they cannot exceed it
        require(uint256(_params.maxJTYieldShareWAD) + uint256(_params.maxLPTYieldShareWAD) <= WAD, INVALID_ACCOUNTANT_CONFIG());

        // Each model's initialization blob is decoded by the instance the template resolves, so an empty one is never valid
        require(_params.jtYDMInitializationData.length != 0 && _params.lptYDMInitializationData.length != 0, EMPTY_YDM_INITIALIZATION_DATA());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Verifies the whole market's on-chain wiring after the proxies are deployed and initialized
     * @dev Cross-checks every deployed contract's state against the params and against each other, so a script-side
     *      deployment mistake (wrong impl, mis-encoded init data, swapped address) fails loud here rather than
     *      producing a subtly mis-wired live market. Modeled on royco-dawn's `RoycoFactory._validateDeployment`
     * @dev Takes the market's two loose params rather than the whole `MarketParams` so the calling template carries no
     *      encoder for it; the kernel family's own `_validateKernelSpecifics` hook stays on the template
     * @param _result The market's deployment result
     * @param _vault The Balancer V3 vault the market's pool is registered with
     * @param _pool The market's Gyro E-CLP pool, which is also the liquidity provider tranche's asset
     * @param _collateralAsset The collateral asset both the senior and junior tranches are denominated in
     * @param _roycoBlacklist The blacklist the template pins every market it deploys to
     * @param _authority The market authority every component must be governed by
     */
    function validateDeployment(
        IRoycoProtocolTemplate.DeploymentResult memory _result,
        IVault _vault,
        address _pool,
        address _collateralAsset,
        address _roycoBlacklist,
        address _authority
    )
        external
        view
    {
        // Shared market authority governs every component (tranches, kernel, and accountant)
        require(IAccessManaged(_result.seniorTranche).authority() == _authority, MARKET_WIRING_VERIFICATION_FAILED(_result.seniorTranche));
        require(IAccessManaged(_result.juniorTranche).authority() == _authority, MARKET_WIRING_VERIFICATION_FAILED(_result.juniorTranche));
        require(IAccessManaged(_result.liquidityProviderTranche).authority() == _authority, MARKET_WIRING_VERIFICATION_FAILED(_result.liquidityProviderTranche));
        require(IAccessManaged(_result.kernel).authority() == _authority, MARKET_WIRING_VERIFICATION_FAILED(_result.kernel));
        require(IAccessManaged(_result.accountant).authority() == _authority, MARKET_WIRING_VERIFICATION_FAILED(_result.accountant));

        // Senior tranche: type, kernel binding, asset, and unseeded
        require(IRoycoVaultTranche(_result.seniorTranche).TRANCHE_TYPE() == TrancheType.SENIOR, MARKET_WIRING_VERIFICATION_FAILED(_result.seniorTranche));
        require(IRoycoVaultTranche(_result.seniorTranche).kernel() == _result.kernel, MARKET_WIRING_VERIFICATION_FAILED(_result.seniorTranche));
        require(IRoycoVaultTranche(_result.seniorTranche).asset() == _collateralAsset, MARKET_WIRING_VERIFICATION_FAILED(_result.seniorTranche));
        require(IERC20(_result.seniorTranche).totalSupply() == 0, MARKET_WIRING_VERIFICATION_FAILED(_result.seniorTranche));

        // Junior tranche: type, kernel binding, asset
        require(IRoycoVaultTranche(_result.juniorTranche).TRANCHE_TYPE() == TrancheType.JUNIOR, MARKET_WIRING_VERIFICATION_FAILED(_result.juniorTranche));
        require(IRoycoVaultTranche(_result.juniorTranche).kernel() == _result.kernel, MARKET_WIRING_VERIFICATION_FAILED(_result.juniorTranche));
        require(IRoycoVaultTranche(_result.juniorTranche).asset() == _collateralAsset, MARKET_WIRING_VERIFICATION_FAILED(_result.juniorTranche));

        // Liquidity provider tranche: type, kernel binding, asset is the pool BPT
        require(
            IRoycoVaultTranche(_result.liquidityProviderTranche).TRANCHE_TYPE() == TrancheType.LIQUIDITY_PROVIDER,
            MARKET_WIRING_VERIFICATION_FAILED(_result.liquidityProviderTranche)
        );
        require(
            IRoycoVaultTranche(_result.liquidityProviderTranche).kernel() == _result.kernel, MARKET_WIRING_VERIFICATION_FAILED(_result.liquidityProviderTranche)
        );
        require(IRoycoVaultTranche(_result.liquidityProviderTranche).asset() == _pool, MARKET_WIRING_VERIFICATION_FAILED(_result.liquidityProviderTranche));

        // Kernel: full tranche set, assets, accountant, and the template's pinned blacklist
        IRoycoDayKernel kernel = IRoycoDayKernel(_result.kernel);
        require(kernel.seniorTranche() == _result.seniorTranche, MARKET_WIRING_VERIFICATION_FAILED(_result.kernel));
        require(kernel.juniorTranche() == _result.juniorTranche, MARKET_WIRING_VERIFICATION_FAILED(_result.kernel));
        require(kernel.liquidityProviderTranche() == _result.liquidityProviderTranche, MARKET_WIRING_VERIFICATION_FAILED(_result.kernel));
        require(kernel.accountant() == _result.accountant, MARKET_WIRING_VERIFICATION_FAILED(_result.kernel));
        require(kernel.collateralAsset() == _collateralAsset, MARKET_WIRING_VERIFICATION_FAILED(_result.kernel));
        require(kernel.lptAsset() == _pool, MARKET_WIRING_VERIFICATION_FAILED(_result.kernel));
        require(kernel.getState().roycoBlacklist == _roycoBlacklist, MARKET_WIRING_VERIFICATION_FAILED(_result.kernel));

        // Pool: The market id should guarantee that the deployed ST share is "less" than the quote token
        IERC20[] memory tokens = _vault.getPoolTokens(_pool);
        require(address(tokens[0]) == _result.seniorTranche, MARKET_WIRING_VERIFICATION_FAILED(_pool));
        require(address(tokens[1]) == kernel.quoteAsset(), MARKET_WIRING_VERIFICATION_FAILED(_pool));

        // Pool: Unseeded: no BPT has been minted
        require(IERC20(_pool).totalSupply() == 0, INVALID_POOL_CONFIGURATION(_pool));

        // Pool: remains hookless, the kernel serves as its senior-leg rate provider
        require(_vault.getHooksConfig(_pool).hooksContract == address(0), MARKET_WIRING_VERIFICATION_FAILED(_pool));

        // Accountant: kernel binding and the injected JT YDM / LPT LDM instances
        IRoycoDayAccountant.RoycoDayAccountantState memory accountantState = IRoycoDayAccountant(_result.accountant).getState();
        require(accountantState.kernel == _result.kernel, MARKET_WIRING_VERIFICATION_FAILED(_result.accountant));
        require(accountantState.jtYDM == _result.ydm && accountantState.lptYDM == _result.lptYdm, MARKET_WIRING_VERIFICATION_FAILED(_result.accountant));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Requires an address to name a live contract, rejecting the null address and an EOA separately
    function _requireContract(address _subject) private view {
        require(_subject != address(0), NULL_MARKET_PARAMETER());
        _requireCode(_subject);
    }

    /// @dev Requires an already non-null address to hold code
    function _requireCode(address _subject) private view {
        require(_subject.code.length > 0, MARKET_PARAMETER_HAS_NO_CODE(_subject));
    }

    /// @dev Requires a tranche to carry both a share token name and a symbol
    function _requireNamed(IBaseTemplate.TrancheDeploymentParams memory _params) private pure {
        require(bytes(_params.name).length != 0 && bytes(_params.symbol).length != 0, EMPTY_TRANCHE_NAME_OR_SYMBOL());
    }
}
