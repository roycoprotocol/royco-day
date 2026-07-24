// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { SafeCast } from "../../lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import { RoycoBase } from "../base/RoycoBase.sol";
import { IRoycoDayEntryPoint } from "../interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoDayKernel } from "../interfaces/IRoycoDayKernel.sol";
import { IRoycoLiquidityProviderTranche } from "../interfaces/IRoycoLiquidityProviderTranche.sol";
import { IRoycoPriceOracle } from "../interfaces/IRoycoPriceOracle.sol";
import { IRoycoVaultTranche } from "../interfaces/IRoycoVaultTranche.sol";
import { IRoycoFactory } from "../interfaces/factory/IRoycoFactory.sol";
import { MAX_TRANCHE_UNITS, WAD, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../libraries/Constants.sol";
import { AssetClaims, SyncedAccountingState, TrancheType } from "../libraries/Types.sol";
import { NAV_UNIT, RoycoUnitsMath, TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../libraries/Units.sol";
import { TrancheClaimsLogic } from "../libraries/logic/TrancheClaimsLogic.sol";
import { ValuationLogic } from "../libraries/logic/ValuationLogic.sol";

/**
 * @title RoycoDayEntryPoint
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Periphery contract enabling asynchronous deposit and redemption flows on Royco Tranches
 * @dev Enforces configurable delays between request and execution to prevent oracle front-running attacks
 * @dev Tranches configured with an oracle clock additionally gate execution on at least one observed oracle update after the request, so any information known at request time is priced into the mark before execution
 * @dev A queued request can never capture favorable price movement during its delay:
 *          1. A deposit is pinned to the tranche shares it would have minted at request time: any shares minted in excess at execution are forfeited on a share basis
 *          2. A redemption is pinned to the value its shares were worth at request time: any value accrued in excess is forfeited on a value basis
 * @dev Each tranche also carries an expiry window for it requests: once it elapses the request is terminal and may only be cancelled
 * @dev Supports third-party executors (keepers) with configurable bonus incentives for executing the request
 * @dev Partial execution is supported, allowing requests to be fulfilled incrementally as tranche capacity is freed up
 * @dev Screens interacting accounts against the market's blacklist, covering the request operators and every value flow that settles outside the kernel's own screened paths
 */
contract RoycoDayEntryPoint is RoycoBase, IRoycoDayEntryPoint {
    using SafeCast for uint256;
    using SafeERC20 for IERC20;
    using RoycoUnitsMath for NAV_UNIT;
    using RoycoUnitsMath for TRANCHE_UNIT;
    using RoycoUnitsMath for uint256;

    /// @dev Storage slot for RoycoDayEntryPointState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoDayEntryPoint")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROYCO_DAY_ENTRY_POINT_STORAGE_SLOT = 0x03bd8d6176ab6e234086d98500389a8f80bf2cd4515f169be97ae2e0d147ef00;

    /// @inheritdoc IRoycoDayEntryPoint
    address public immutable override(IRoycoDayEntryPoint) ROYCO_FACTORY;

    /// @notice Constructs the Royco entry point
    /// @param _roycoFactory The canonical Royco factory responsible for deploying markets, used to validate tranche provenance
    constructor(address _roycoFactory) {
        // Ensure the factory isn't null
        require(_roycoFactory != address(0), NULL_ADDRESS());
        // Set the immutable state
        ROYCO_FACTORY = _roycoFactory;
    }

    /**
     * @notice Initializes the entry point state
     * @param _tranches The tranches to enable for this entry point on initialization
     * @param _configs The configurations for each tranche
     */
    function initialize(address[] calldata _tranches, TrancheConfig[] calldata _configs) external initializer {
        // Initialize the base entry point state with the canonical Royco authority governing the factory's markets
        __RoycoBase_init(IRoycoFactory(ROYCO_FACTORY).ROYCO_AUTHORITY());
        // Initialize the entry point with the initial enabled tranches and their initial configurations
        _modifyTrancheConfigs(_tranches, _configs);
    }

    /**
     * =============================
     * Entry Point Deposit Functions
     * =============================
     */

    /// @inheritdoc IRoycoDayEntryPoint
    function requestDeposit(
        address _tranche,
        TRANCHE_UNIT _assets,
        address _receiver,
        uint64 _executorBonusWAD
    )
        external
        override(IRoycoDayEntryPoint)
        whenNotPaused
        restricted
        returns (uint256 requestNonce, uint32 executableAtTimestamp, uint32 expiresAtTimestamp)
    {
        // Validate the deposit request
        require(_assets != ZERO_TRANCHE_UNITS, MUST_EXECUTE_NON_ZERO_AMOUNT());
        require(_tranche != address(0) && _receiver != address(0), NULL_ADDRESS());
        require(_executorBonusWAD < WAD || _executorBonusWAD == type(uint64).max, INVALID_EXECUTOR_BONUS());

        // Ensure that the tranche is enabled on this entry point and the caller and receiver are not blacklisted
        RoycoDayEntryPointState storage $ = _getRoycoDayEntryPointStorage();
        EnrichedTrancheConfig storage config = $.trancheToConfig[_tranche];
        require(config.baseConfig.enabled, TRANCHE_NOT_ENABLED());
        _enforceNotBlacklisted(config.kernel, msg.sender, _receiver);

        // Poke the market's collateral asset oracle to refresh it
        _pokeOracle(_tranche, config);

        // Resolve the request's executable and expiry timestamps: the expiry is a saturating add, so a maximal window
        // pins it at type(uint32).max and the request effectively never expires
        executableAtTimestamp = uint32(block.timestamp + config.baseConfig.depositDelaySeconds);
        expiresAtTimestamp = uint32(Math.min(uint256(executableAtTimestamp) + config.baseConfig.depositExpirySeconds, type(uint32).max));

        // Register the user's deposit request with a fresh nonce
        DepositRequest storage request = $.userToNonceToDepositRequest[msg.sender][(requestNonce = ++$.lastRequestNonce)];
        request.assets = _assets;
        // Snapshot the shares this deposit would mint at request-time pricing
        request.equivalentSharesAtRequestTime = _depositSharesReference(config.kernel, config.trancheType, _tranche, _assets);
        request.baseRequest = BaseRequest({
            tranche: _tranche,
            queuedAtTimestamp: uint32(block.timestamp),
            receiver: _receiver,
            executableAtTimestamp: executableAtTimestamp,
            expiresAtTimestamp: expiresAtTimestamp,
            executorBonusWAD: _executorBonusWAD
        });

        // Transfer the requested amount of tranche assets into the entry point to queue the deposit
        IERC20(config.asset).safeTransferFrom(msg.sender, address(this), toUint256(_assets));

        emit DepositRequested(msg.sender, requestNonce, _tranche, _assets, executableAtTimestamp, expiresAtTimestamp, _executorBonusWAD);
    }

    /// @inheritdoc IRoycoDayEntryPoint
    function executeDeposits(
        address[] calldata _users,
        uint256[] calldata _requestNonces,
        TRANCHE_UNIT[] calldata _assetsToDeposit
    )
        external
        override(IRoycoDayEntryPoint)
        whenNotPaused
        restricted
        returns (uint256[] memory trancheSharesMinted)
    {
        // Execute the user specified deposit requests
        uint256 numRequestsToExecute = _requestNonces.length;
        require(numRequestsToExecute == _users.length && numRequestsToExecute == _assetsToDeposit.length, ARRAY_LENGTH_MISMATCH());
        trancheSharesMinted = new uint256[](numRequestsToExecute);
        for (uint256 i = 0; i < numRequestsToExecute; ++i) {
            trancheSharesMinted[i] = _executeDeposit(_users[i], _requestNonces[i], _assetsToDeposit[i]);
        }
    }

    /// @inheritdoc IRoycoDayEntryPoint
    function executeDeposit(
        address _user,
        uint256 _requestNonce,
        TRANCHE_UNIT _assetsToDeposit
    )
        external
        override(IRoycoDayEntryPoint)
        whenNotPaused
        restricted
        returns (uint256 trancheSharesMinted)
    {
        return _executeDeposit(_user, _requestNonce, _assetsToDeposit);
    }

    /// @inheritdoc IRoycoDayEntryPoint
    function cancelDepositRequests(uint256[] calldata _requestNonces, address _receiver) external override(IRoycoDayEntryPoint) whenNotPaused restricted {
        // Execute the user specified deposit request cancellations
        uint256 numRequestsToCancel = _requestNonces.length;
        for (uint256 i = 0; i < numRequestsToCancel; ++i) {
            _cancelDepositRequest(_requestNonces[i], _receiver);
        }
    }

    /// @inheritdoc IRoycoDayEntryPoint
    function cancelDepositRequest(uint256 _requestNonce, address _receiver) external override(IRoycoDayEntryPoint) whenNotPaused restricted {
        _cancelDepositRequest(_requestNonce, _receiver);
    }

    /**
     * =============================
     * Entry Point Redemption Functions
     * =============================
     */

    /// @inheritdoc IRoycoDayEntryPoint
    function requestRedemption(
        address _tranche,
        uint256 _shares,
        address _receiver,
        uint64 _executorBonusWAD,
        RedemptionMode _mode
    )
        external
        override(IRoycoDayEntryPoint)
        whenNotPaused
        restricted
        returns (uint256 requestNonce, uint32 executableAtTimestamp, uint32 expiresAtTimestamp)
    {
        // Validate the redemption request
        require(_shares != 0, MUST_EXECUTE_NON_ZERO_AMOUNT());
        require(_tranche != address(0) && _receiver != address(0), NULL_ADDRESS());
        require(_executorBonusWAD < WAD || _executorBonusWAD == type(uint64).max, INVALID_EXECUTOR_BONUS());

        // Ensure that the tranche is enabled on this entry point (the share escrow transfer below screens the caller,
        // and both execution paths screen the receiver where its value settles)
        RoycoDayEntryPointState storage $ = _getRoycoDayEntryPointStorage();
        EnrichedTrancheConfig storage config = $.trancheToConfig[_tranche];

        // Ensure that the tranche is enabled
        require(config.baseConfig.enabled, TRANCHE_NOT_ENABLED());
        // Only the liquidity provider tranche can exit multi-asset. The senior and junior tranches must redeem in-kind
        require(config.trancheType == TrancheType.LIQUIDITY_PROVIDER || _mode == RedemptionMode.INKIND, UNSUPPORTED_REDEMPTION_MODE());

        // Poke the market's collateral asset oracle to refresh it
        _pokeOracle(_tranche, config);

        // Resolve the request's executable and expiry timestamps: the expiry is a saturating add, so a maximal window
        // pins it at type(uint32).max and the request effectively never expires
        executableAtTimestamp = uint32(block.timestamp + config.baseConfig.redemptionDelaySeconds);
        expiresAtTimestamp = uint32(Math.min(uint256(executableAtTimestamp) + config.baseConfig.redemptionExpirySeconds, type(uint32).max));

        // Register the user's redemption request with a fresh nonce
        RedemptionRequest storage request = $.userToNonceToRedemptionRequest[msg.sender][(requestNonce = ++$.lastRequestNonce)];
        request.shares = _shares;
        request.mode = _mode;
        // Snapshot the value of the escrowed shares
        request.valueAtRequestTime = _redemptionValueReference(config.kernel, config.trancheType, _shares);
        request.baseRequest = BaseRequest({
            tranche: _tranche,
            queuedAtTimestamp: uint32(block.timestamp),
            receiver: _receiver,
            executableAtTimestamp: executableAtTimestamp,
            expiresAtTimestamp: expiresAtTimestamp,
            executorBonusWAD: _executorBonusWAD
        });

        // Transfer the requested amount of tranche shares into the entry point to queue the redemption
        IERC20(_tranche).safeTransferFrom(msg.sender, address(this), _shares);

        emit RedemptionRequested(msg.sender, requestNonce, _tranche, _shares, _mode, executableAtTimestamp, expiresAtTimestamp, _executorBonusWAD);
    }

    /// @inheritdoc IRoycoDayEntryPoint
    function executeRedemptions(
        address[] calldata _users,
        uint256[] calldata _requestNonces,
        uint256[] calldata _sharesToRedeem
    )
        external
        override(IRoycoDayEntryPoint)
        whenNotPaused
        restricted
        returns (AssetClaims[] memory userClaims, uint256[] memory quoteAssets)
    {
        // Execute the user specified redemption requests
        uint256 numRequestsToExecute = _requestNonces.length;
        require(numRequestsToExecute == _users.length && numRequestsToExecute == _sharesToRedeem.length, ARRAY_LENGTH_MISMATCH());
        userClaims = new AssetClaims[](numRequestsToExecute);
        quoteAssets = new uint256[](numRequestsToExecute);
        for (uint256 i = 0; i < numRequestsToExecute; ++i) {
            (userClaims[i], quoteAssets[i]) = _executeRedemption(_users[i], _requestNonces[i], _sharesToRedeem[i]);
        }
    }

    /// @inheritdoc IRoycoDayEntryPoint
    function executeRedemption(
        address _user,
        uint256 _requestNonce,
        uint256 _sharesToRedeem
    )
        external
        override(IRoycoDayEntryPoint)
        whenNotPaused
        restricted
        returns (AssetClaims memory userClaims, uint256 quoteAssets)
    {
        return _executeRedemption(_user, _requestNonce, _sharesToRedeem);
    }

    /// @inheritdoc IRoycoDayEntryPoint
    function cancelRedemptionRequests(uint256[] calldata _requestNonces, address _receiver) external override(IRoycoDayEntryPoint) whenNotPaused restricted {
        // Execute the user specified redemption request cancellations
        uint256 numRequestsToCancel = _requestNonces.length;
        for (uint256 i = 0; i < numRequestsToCancel; ++i) {
            _cancelRedemptionRequest(_requestNonces[i], _receiver);
        }
    }

    /// @inheritdoc IRoycoDayEntryPoint
    function cancelRedemptionRequest(uint256 _requestNonce, address _receiver) external override(IRoycoDayEntryPoint) whenNotPaused restricted {
        _cancelRedemptionRequest(_requestNonce, _receiver);
    }

    /// @inheritdoc IRoycoDayEntryPoint
    function pokeCollateralAssetOracle(address _tranche) external override(IRoycoDayEntryPoint) whenNotPaused returns (uint32 lastUpdatedAtTimestamp) {
        return _pokeOracle(_tranche, _getRoycoDayEntryPointStorage().trancheToConfig[_tranche]);
    }

    /**
     * =============================
     * Admin Functions
     * =============================
     */

    /// @inheritdoc IRoycoDayEntryPoint
    function modifyTrancheConfigs(address[] calldata _tranches, TrancheConfig[] calldata _configs) external override(IRoycoDayEntryPoint) restricted {
        _modifyTrancheConfigs(_tranches, _configs);
    }

    /// @inheritdoc IRoycoDayEntryPoint
    function collectProtocolFees(
        address[] calldata _tranches,
        uint256[] calldata _sharesToClaim,
        address _receiver
    )
        external
        override(IRoycoDayEntryPoint)
        restricted
    {
        require(_receiver != address(0), NULL_ADDRESS());
        // Ensure that each tranche has a specified amount of protocol fee shares to claim
        uint256 numTranches = _tranches.length;
        require(numTranches == _sharesToClaim.length, ARRAY_LENGTH_MISMATCH());

        // Claim the specified protocol fee shares for each specified tranche
        RoycoDayEntryPointState storage $ = _getRoycoDayEntryPointStorage();
        for (uint256 i = 0; i < numTranches; ++i) {
            address tranche = _tranches[i];
            uint256 sharesToClaim = ((_sharesToClaim[i] == type(uint256).max) ? $.trancheToProtocolFeeShares[tranche] : _sharesToClaim[i]);
            if (sharesToClaim == 0) continue;
            $.trancheToProtocolFeeShares[tranche] -= sharesToClaim;
            IERC20(tranche).safeTransfer(_receiver, sharesToClaim);
            emit ProtocolFeeSharesCollected(tranche, _receiver, sharesToClaim);
        }
    }

    /**
     * =============================
     * State Accessor Functions
     * =============================
     */

    /// @inheritdoc IRoycoDayEntryPoint
    function getLastRequestNonce() external view override(IRoycoDayEntryPoint) returns (uint256 nonce) {
        return _getRoycoDayEntryPointStorage().lastRequestNonce;
    }

    /// @inheritdoc IRoycoDayEntryPoint
    function getTrancheConfig(address _tranche) external view override(IRoycoDayEntryPoint) returns (EnrichedTrancheConfig memory config) {
        return _getRoycoDayEntryPointStorage().trancheToConfig[_tranche];
    }

    /// @inheritdoc IRoycoDayEntryPoint
    function getDepositRequest(address _user, uint256 _requestNonce) external view override(IRoycoDayEntryPoint) returns (DepositRequest memory request) {
        return _getRoycoDayEntryPointStorage().userToNonceToDepositRequest[_user][_requestNonce];
    }

    /// @inheritdoc IRoycoDayEntryPoint
    function getRedemptionRequest(address _user, uint256 _requestNonce) external view override(IRoycoDayEntryPoint) returns (RedemptionRequest memory request) {
        return _getRoycoDayEntryPointStorage().userToNonceToRedemptionRequest[_user][_requestNonce];
    }

    /// @inheritdoc IRoycoDayEntryPoint
    function getProtocolFeeSharesPendingCollection(address _tranche) external view override(IRoycoDayEntryPoint) returns (uint256 shares) {
        return _getRoycoDayEntryPointStorage().trancheToProtocolFeeShares[_tranche];
    }

    /**
     * =============================
     * Internal Utility Functions
     * =============================
     */

    /**
     * @notice Executes a pending deposit request for the specified user
     * @dev The request must exist and the configured delay period must have elapsed
     *      If executed by a third party, the executor bonus is paid in freshly minted tranche shares: the full asset
     *      amount is deposited and the executor takes a share slice of the user's post-forfeiture mint, mirroring how
     *      redemptions pay their bonus out of the redeemed output
     * @param _user The user whose deposit request should be executed
     * @param _requestNonce The nonce of the deposit request to execute
     * @param _assetsToDeposit The amount of assets to deposit (use MAX_TRANCHE_UNITS to deposit the maximum possible)
     * @return trancheSharesMinted The tranche shares minted for the user (the receiver's and the executor's portions combined)
     */
    function _executeDeposit(address _user, uint256 _requestNonce, TRANCHE_UNIT _assetsToDeposit) internal returns (uint256 trancheSharesMinted) {
        require(_assetsToDeposit != ZERO_TRANCHE_UNITS, MUST_EXECUTE_NON_ZERO_AMOUNT());

        // Retrieve the user's specified deposit request and its tranche's config
        RoycoDayEntryPointState storage $ = _getRoycoDayEntryPointStorage();
        DepositRequest memory request = $.userToNonceToDepositRequest[_user][_requestNonce];
        address tranche = request.baseRequest.tranche;
        EnrichedTrancheConfig memory config = $.trancheToConfig[tranche];

        // Assert the validity of the request
        _validateRequestExecution(_requestNonce, request.baseRequest, config);
        require(config.baseConfig.enabled, TRANCHE_NOT_ENABLED());

        // Screen the executor and request owner against the market's blacklist so a flagged party can never operate the request (the tranche deposit below screens the receiver)
        _enforceNotBlacklisted(config.kernel, msg.sender, _user);

        // Resolve the actual amount of assets to deposit
        _assetsToDeposit = (_assetsToDeposit == MAX_TRANCHE_UNITS)
            ? toTrancheUnits(Math.min(toUint256(IRoycoVaultTranche(tranche).maxDeposit(request.baseRequest.receiver)), toUint256(request.assets)))
            : _assetsToDeposit;
        // Return early without reverting if maxDeposit is 0 due to market conditions
        if (_assetsToDeposit == ZERO_TRANCHE_UNITS) return 0;

        // Ensure the resolved amount is not greater than the request's assets
        require(request.assets >= _assetsToDeposit, INVALID_REQUEST(_requestNonce));
        TRANCHE_UNIT assetsLeftToDeposit = request.assets - _assetsToDeposit;

        // Mark the assets as deposited
        if (assetsLeftToDeposit == ZERO_TRANCHE_UNITS) {
            delete $.userToNonceToDepositRequest[_user][_requestNonce];
        } else {
            $.userToNonceToDepositRequest[_user][_requestNonce].assets = assetsLeftToDeposit;
            // Scale the request-time share reference by the assets left to deposit
            $.userToNonceToDepositRequest[_user][_requestNonce].equivalentSharesAtRequestTime =
                request.equivalentSharesAtRequestTime.mulDiv(assetsLeftToDeposit, request.assets, Math.Rounding.Floor);
            request.equivalentSharesAtRequestTime = request.equivalentSharesAtRequestTime.mulDiv(_assetsToDeposit, request.assets, Math.Rounding.Floor);
        }

        // A third party execution requires the user to have opted in (checked before the deposit mutates anything)
        bool remitExecutorBonus = (_user != msg.sender && request.baseRequest.executorBonusWAD != 0);
        require(!remitExecutorBonus || request.baseRequest.executorBonusWAD != type(uint64).max, THIRD_PARTY_EXECUTION_DISABLED());

        // Deposit the full asset amount, forfeiting the shares minted in excess of the request-time reference as protocol fees
        uint256 protocolFeeShares;
        (trancheSharesMinted, protocolFeeShares) = _depositWithShareForfeiture(tranche, config, _assetsToDeposit, request.equivalentSharesAtRequestTime);

        // Pay the executor bonus in freshly minted tranche shares
        uint256 bonusShares;
        if (remitExecutorBonus) {
            bonusShares = Math.mulDiv(trancheSharesMinted, request.baseRequest.executorBonusWAD, WAD, Math.Rounding.Floor);
            if (bonusShares != 0) IERC20(tranche).safeTransfer(msg.sender, bonusShares);
        }
        // The receiver keeps the remainder of the user's minted shares
        uint256 receiverShares = trancheSharesMinted - bonusShares;
        if (receiverShares != 0) IERC20(tranche).safeTransfer(request.baseRequest.receiver, receiverShares);

        emit DepositExecuted(_user, _requestNonce, msg.sender, _assetsToDeposit, trancheSharesMinted, protocolFeeShares, bonusShares);
    }

    /**
     * @dev Cancels the caller's specified deposit request and returns its assets to the specified receiver
     * @param _requestNonce The nonce of the deposit request to cancel
     * @param _receiver The receiver of the cancelled request's assets
     */
    function _cancelDepositRequest(uint256 _requestNonce, address _receiver) internal {
        // Ensure the receiver isn't null
        require(_receiver != address(0), NULL_ADDRESS());
        // Retrieve the user's specified deposit request and assert that it exists
        RoycoDayEntryPointState storage $ = _getRoycoDayEntryPointStorage();
        DepositRequest memory request = $.userToNonceToDepositRequest[msg.sender][_requestNonce];
        require(request.assets != ZERO_TRANCHE_UNITS, INVALID_REQUEST(_requestNonce));
        // Screen the canceller and receiver against the market's blacklist, the returned escrow settles outside the kernel's screened flows
        _enforceNotBlacklisted($.trancheToConfig[request.baseRequest.tranche].kernel, msg.sender, _receiver);

        // Mark the request as cancelled
        delete $.userToNonceToDepositRequest[msg.sender][_requestNonce];

        // Return the assets from the cancelled request to the specified receiver
        address asset = $.trancheToConfig[request.baseRequest.tranche].asset;
        IERC20(asset).safeTransfer(_receiver, toUint256(request.assets));

        emit DepositRequestCancelled(msg.sender, _requestNonce, _receiver, request.assets);
    }

    /**
     * @notice Executes a pending redemption request for the specified user
     * @dev The request must exist and the configured delay period must have elapsed
     *      A maximal liquidity provider tranche redemption exits in-kind whenever the in-kind bound serves the entire
     *      remaining request, and otherwise fills up to the dominant bound capped at the remaining request,
     *      exiting to the LP token's constituents only when the multi-asset bound is strictly wider (equal bounds
     *      stay in-kind), so a redemption the market can serve is never left behind by the in-kind gate. Explicit
     *      amounts always exit in-kind
     * @param _user The user whose redemption request should be executed
     * @param _requestNonce The nonce of the redemption request to execute
     * @param _sharesToRedeem The amount of shares to redeem (use type(uint256).max to redeem the maximum possible)
     * @return userClaims The assets withdrawn to the request-specific receiver upon executing this redemption request
     * @return quoteAssets The quote withdrawn to the request-specific receiver (zero unless the redemption exits multi-asset)
     */
    function _executeRedemption(
        address _user,
        uint256 _requestNonce,
        uint256 _sharesToRedeem
    )
        internal
        returns (AssetClaims memory userClaims, uint256 quoteAssets)
    {
        require(_sharesToRedeem != 0, MUST_EXECUTE_NON_ZERO_AMOUNT());

        // Retrieve the user's specified redemption request and its tranche's config
        RoycoDayEntryPointState storage $ = _getRoycoDayEntryPointStorage();
        RedemptionRequest memory request = $.userToNonceToRedemptionRequest[_user][_requestNonce];
        address tranche = request.baseRequest.tranche;
        EnrichedTrancheConfig memory config = $.trancheToConfig[tranche];

        // Assert the validity of the request
        _validateRequestExecution(_requestNonce, request.baseRequest, config);
        require(config.baseConfig.enabled, TRANCHE_NOT_ENABLED());

        // Screen the executor and request owner against the market's blacklist so a flagged party can never operate the request
        _enforceNotBlacklisted(config.kernel, msg.sender, _user);

        // Resolve the actual amount of shares to redeem and the exit route from the request's redemption mode
        bool isMultiAssetRedemption;
        if (request.mode == RedemptionMode.OPTIMIZED) {
            (_sharesToRedeem, isMultiAssetRedemption) =
                _resolveOptimizedRedemption(tranche, (_sharesToRedeem == type(uint256).max) ? request.shares : _sharesToRedeem);
        } else {
            isMultiAssetRedemption = (request.mode == RedemptionMode.MULTIASSET);
            if (_sharesToRedeem == type(uint256).max) {
                _sharesToRedeem =
                    Math.min(isMultiAssetRedemption ? _maxRedeemMultiAsset(tranche) : IRoycoVaultTranche(tranche).maxRedeem(address(this)), request.shares);
            }
        }
        // Return early without reverting if the resolved amount is 0 due to market conditions
        if (_sharesToRedeem == 0) return (AssetClaims(ZERO_TRANCHE_UNITS, ZERO_TRANCHE_UNITS, 0, ZERO_NAV_UNITS), 0);

        // Ensure the resolved amount is not greater than the request's shares
        require(request.shares >= _sharesToRedeem, INVALID_REQUEST(_requestNonce));
        uint256 sharesLeftToRedeem = request.shares - _sharesToRedeem;

        // Mark the shares as redeemed
        if (sharesLeftToRedeem == 0) {
            delete $.userToNonceToRedemptionRequest[_user][_requestNonce];
        } else {
            $.userToNonceToRedemptionRequest[_user][_requestNonce].shares = sharesLeftToRedeem;
            // Scale the request-time value reference by the shares left to redeem
            $.userToNonceToRedemptionRequest[_user][_requestNonce].valueAtRequestTime =
                request.valueAtRequestTime.mulDiv(sharesLeftToRedeem, request.shares, Math.Rounding.Floor);
            request.valueAtRequestTime = request.valueAtRequestTime.mulDiv(_sharesToRedeem, request.shares, Math.Rounding.Floor);
        }

        // If this is a self-redemption or there is no executor bonus configured, withdraw assets directly to the specified recipient
        uint256 userSharesRedeemed;
        uint256 protocolFeeShares;
        AssetClaims memory bonusClaims;
        uint256 bonusQuoteAssets;
        if (_user == msg.sender || request.baseRequest.executorBonusWAD == 0) {
            // Redeem shares directly to the receiver, forfeiting the value accrued during the queue as protocol fees
            (userSharesRedeemed, protocolFeeShares, userClaims, quoteAssets) =
                _redeemWithValueForfeiture(tranche, _sharesToRedeem, request.valueAtRequestTime, request.baseRequest.receiver, isMultiAssetRedemption);
        }
        // Else, if this is a third party execution, withdraw the assets, forfeit the value accrued during the queue as protocol fees, and remit the executor bonus
        else {
            // Ensure that the user has opted into third party execution
            require(request.baseRequest.executorBonusWAD != type(uint64).max, THIRD_PARTY_EXECUTION_DISABLED());
            // Screen the receiver against the market's blacklist, the asset and quote remittance legs below settle outside the kernel's screened flows (the self path's redemption screens the receiver)
            IRoycoDayKernel(config.kernel).enforceNotBlacklisted(request.baseRequest.receiver);

            // Redeem shares to this contract for bonus calculation, forfeiting the value accrued during the queue as protocol fees
            (userSharesRedeemed, protocolFeeShares, userClaims, quoteAssets) =
                _redeemWithValueForfeiture(tranche, _sharesToRedeem, request.valueAtRequestTime, address(this), isMultiAssetRedemption);

            // Split the redeemed claims and quote into the executor's bonus and the receiver's portion, then remit both
            (bonusClaims, bonusQuoteAssets) =
                _remitRedemptionAndBonusClaims(config.kernel, userClaims, quoteAssets, request.baseRequest.executorBonusWAD, request.baseRequest.receiver);
            quoteAssets -= bonusQuoteAssets;
        }

        emit RedemptionExecuted(_user, _requestNonce, msg.sender, userSharesRedeemed, protocolFeeShares, userClaims, quoteAssets, bonusClaims, bonusQuoteAssets);
    }

    /**
     * @dev Cancels the caller's specified redemption request and returns its shares to the specified receiver
     * @param _requestNonce The nonce of the redemption request to cancel
     * @param _receiver The receiver of the cancelled request's shares
     */
    function _cancelRedemptionRequest(uint256 _requestNonce, address _receiver) internal {
        // Ensure the receiver isn't null
        require(_receiver != address(0), NULL_ADDRESS());
        // Retrieve the user's specified redemption request and assert that it exists
        RoycoDayEntryPointState storage $ = _getRoycoDayEntryPointStorage();
        RedemptionRequest memory request = $.userToNonceToRedemptionRequest[msg.sender][_requestNonce];
        require(request.shares != 0, INVALID_REQUEST(_requestNonce));
        // Screen the canceller and receiver against the market's blacklist, the share escrow return below only screens the receiver through the kernel's balance update hook
        _enforceNotBlacklisted($.trancheToConfig[request.baseRequest.tranche].kernel, msg.sender, _receiver);

        // Mark the request as cancelled
        delete $.userToNonceToRedemptionRequest[msg.sender][_requestNonce];

        // Return the shares from the cancelled request to the specified receiver
        IERC20(request.baseRequest.tranche).safeTransfer(_receiver, request.shares);

        emit RedemptionRequestCancelled(msg.sender, _requestNonce, _receiver, request.shares);
    }

    /**
     * @dev Asserts that a request exists and is executable: not executed already or cancelled, past its delay, not yet
     *      expired, and the market's collateral asset oracle has observed at least one update strictly after the request
     *      was queued, so any information known at request time is priced into the mark before execution
     *      An oracle reporting no update yet (a zero timestamp) conservatively holds the gate shut
     * @param _requestNonce The nonce of the request being validated
     * @param _baseRequest The base request data shared across request types
     * @param _config The tranche's enriched configuration
     */
    function _validateRequestExecution(uint256 _requestNonce, BaseRequest memory _baseRequest, EnrichedTrancheConfig memory _config) internal {
        // Ensure the request exists and the configured delay period has elapsed
        require(_baseRequest.executableAtTimestamp != 0 && _baseRequest.executableAtTimestamp <= block.timestamp, INVALID_REQUEST(_requestNonce));
        // Ensure the request's execution window has not elapsed (a saturated type(uint32).max expiry never arrives)
        require(block.timestamp < _baseRequest.expiresAtTimestamp, REQUEST_EXPIRED(_requestNonce));
        // Ensure the market's collateral asset oracle has observed an update strictly after the request was queued
        require(
            !_config.baseConfig.gateByOracleUpdate || (_pokeOracle(_baseRequest.tranche, _config) > _baseRequest.queuedAtTimestamp),
            COLLATERAL_ASSET_ORACLE_NOT_ADVANCED(_requestNonce)
        );
    }

    /**
     * @dev Pokes the collateral asset oracle of the tranche's market
     * @dev The oracle is resolved live from the kernel since an admin can replace it at any time
     * @param _tranche The tranche whose market's collateral asset oracle is being poked
     * @param _config The tranche's enriched configuration
     * @return lastUpdatedAtTimestamp The oracle's last update timestamp after the poke (zero when the gate is disabled or no update has been observed yet)
     */
    function _pokeOracle(address _tranche, EnrichedTrancheConfig memory _config) internal returns (uint32 lastUpdatedAtTimestamp) {
        if (!_config.baseConfig.gateByOracleUpdate) return 0;
        // The oracle must never report a future update timestamp: it would satisfy the execution gate without a genuine update
        require(
            (lastUpdatedAtTimestamp = IRoycoPriceOracle(IRoycoDayKernel(_config.kernel).getCollateralAssetOracle()).poke().toUint32()) <= block.timestamp,
            COLLATERAL_ASSET_ORACLE_IN_THE_FUTURE()
        );
        emit CollateralAssetOraclePoked(_tranche, lastUpdatedAtTimestamp);
    }

    /**
     * @dev Deposits assets, forfeiting the shares minted in excess of the request-time reference to the protocol
     * @dev The user is left with min(shares minted now, shares the deposit would have minted at request time).
     * @param _tranche The tranche to deposit assets into
     * @param _config The enriched tranche configuration
     * @param _assets The amount of assets to deposit into the tranche
     * @param _equivalentSharesAtRequestTime The shares this deposit would have minted at request-time pricing (the forfeiture reference)
     * @return userTrancheShares The shares minted for the user (total minus forfeited), held by the entry point for the caller to distribute
     * @return protocolFeeShares The shares minted in excess of the request-time reference, forfeited to the protocol (zero if the tranche's share price did not fall during the request lifecycle)
     */
    function _depositWithShareForfeiture(
        address _tranche,
        EnrichedTrancheConfig memory _config,
        TRANCHE_UNIT _assets,
        uint256 _equivalentSharesAtRequestTime
    )
        internal
        returns (uint256 userTrancheShares, uint256 protocolFeeShares)
    {
        // Approve the tranche to pull the assets being deposited
        IERC20(_config.asset).forceApprove(_tranche, toUint256(_assets));
        // Deposit to the entry point and take the shares actually minted
        uint256 sharesAtExecutionTime = IRoycoVaultTranche(_tranche).deposit(_assets, address(this));
        // Forfeit the shares minted in excess of the request-time reference (retained as protocol fee shares), so the
        // user keeps the lower of the request-time and execution-time share counts
        if (sharesAtExecutionTime > _equivalentSharesAtRequestTime) {
            protocolFeeShares = sharesAtExecutionTime - _equivalentSharesAtRequestTime;
            _getRoycoDayEntryPointStorage().trancheToProtocolFeeShares[_tranche] += protocolFeeShares;
        }
        userTrancheShares = sharesAtExecutionTime - protocolFeeShares;
    }

    /**
     * @dev Redeems shares on a VALUE basis, forfeiting the value the escrowed shares accrued during the queue to the protocol
     * @dev The escrowed shares are pinned to their request-time value: any value they gained by execution is skimmed as
     *      protocol fee shares before the redemption settles, so the redeemer receives the request-time value, never more
     * @param _tranche The tranche to redeem shares from
     * @param _shares The amount of shares to redeem from the tranche
     * @param _valueAtRequestTime The value of the shares being redeemed at the time the redemption was requested
     * @param _receiver The address to receive the redeemed assets
     * @param _isMultiAssetRedemption Whether to exit a liquidity provider tranche redemption to the LP token's constituents instead of in-kind
     * @return userSharesRedeemed The shares actually redeemed for the user (total minus forfeited)
     * @return protocolFeeShares The shares forfeited to the protocol equating to the value the escrowed shares accrued during the request lifecycle (zero if their value did not increase)
     * @return userClaims The assets withdrawn from the tranche for the user after forfeiting the accrued value
     * @return quoteAssets The quote withdrawn from the tranche for the user (zero unless the redemption exits multi-asset)
     */
    function _redeemWithValueForfeiture(
        address _tranche,
        uint256 _shares,
        NAV_UNIT _valueAtRequestTime,
        address _receiver,
        bool _isMultiAssetRedemption
    )
        internal
        returns (uint256 userSharesRedeemed, uint256 protocolFeeShares, AssetClaims memory userClaims, uint256 quoteAssets)
    {
        // Initialize the user's shares redeemed as the input
        userSharesRedeemed = _shares;
        // Compute the value of the shares at execution, without any self-liquidation bonus applied
        EnrichedTrancheConfig storage config = _getRoycoDayEntryPointStorage().trancheToConfig[_tranche];
        NAV_UNIT valueAtExecutionTime = _redemptionValueReference(config.kernel, config.trancheType, _shares);
        if (valueAtExecutionTime > _valueAtRequestTime) {
            protocolFeeShares = _shares.mulDiv((valueAtExecutionTime - _valueAtRequestTime), valueAtExecutionTime, Math.Rounding.Floor);
        }
        // Redeem the shares the user is entitled to after deducting the protocol fee shares
        // A fully forfeited redemption (a zero-value snapshot) settles without a redeem call, mirroring the deposit path
        if ((userSharesRedeemed -= protocolFeeShares) != 0) {
            if (_isMultiAssetRedemption) {
                // Multi-asset redemptions mandate that liquidity is removed in a way that cannot render less value than promised at present NAV values
                (userClaims, quoteAssets) = IRoycoLiquidityProviderTranche(_tranche).redeemMultiAsset(userSharesRedeemed, 0, 0, _receiver, address(this));
            } else {
                userClaims = IRoycoVaultTranche(_tranche).redeem(userSharesRedeemed, _receiver, address(this));
            }
        }
        // Accrue the forfeited shares as protocol fees
        if (protocolFeeShares != 0) _getRoycoDayEntryPointStorage().trancheToProtocolFeeShares[_tranche] += protocolFeeShares;
    }

    /// @dev Resolves the request-time SHARE reference for a deposit: the shares the deposit would mint at request-time pricing, the basis the execution-time forfeiture is measured against.
    function _depositSharesReference(address _kernel, TrancheType _trancheType, address _tranche, TRANCHE_UNIT _assets) internal view returns (uint256 shares) {
        // Convert the assets to NAV units
        NAV_UNIT depositValue = (_trancheType == TrancheType.LIQUIDITY_PROVIDER)
            ? IRoycoDayKernel(_kernel).convertLPTAssetsToValue(_assets)
            : IRoycoDayKernel(_kernel).convertCollateralAssetsToValue(_assets);
        // Read the post-sync state so the NAV basis and supply come from one accounting state, a pre-sync supply would understate the reference by the sync's fee and premium mints
        (SyncedAccountingState memory state, AssetClaims memory trancheClaims, uint256 totalTrancheShares) =
            IRoycoDayKernel(_kernel).previewSyncTrancheAccounting(_trancheType);
        // Mirror the mint's pricing basis: the LPT mints against its raw NAV, excluding the idle liquidity premium senior shares
        NAV_UNIT navBasis = ((_trancheType == TrancheType.LIQUIDITY_PROVIDER) ? state.lptRawNAV : trancheClaims.nav);
        // Use the clamp-free conversion so the dilution clamp never manufactures forfeiture, the real mint at execution is still clamped
        return ValuationLogic._convertToSharesUnclamped(depositValue, navBasis, totalTrancheShares, Math.Rounding.Floor);
    }

    /// @dev Resolves the redemption value reference: the escrowed shares' pro-rata claim on the tranche's full post-sync claims
    /// @dev The full claims basis mirrors execution, an LPT redemption claims both effective-NAV legs including the idle liquidity premium senior shares
    /// @dev The reference excludes any self-liquidation bonus applied when the redemption executes, so the bonus is never skimmed as queue-time accrual
    function _redemptionValueReference(address _kernel, TrancheType _trancheType, uint256 _shares) internal view returns (NAV_UNIT value) {
        // Read the post-sync state so the claims and supply come from one accounting state, a pre-sync supply would overstate the reference and hide genuine post-request gains
        (, AssetClaims memory trancheClaims, uint256 totalTrancheShares) = IRoycoDayKernel(_kernel).previewSyncTrancheAccounting(_trancheType);
        return TrancheClaimsLogic._scaleAssetClaims(trancheClaims, _shares, totalTrancheShares, true).nav;
    }

    /**
     * @dev Resolves an OPTIMIZED liquidity provider tranche redemption: in-kind when the in-kind bound serves the
     *      whole target, otherwise fills up to whichever of the in-kind or multi-asset bound redeems more shares,
     *      exiting multi-asset only when its bound is strictly wider (equal bounds stay in-kind), so a redemption the
     *      market can serve is never left behind by the in-kind gate
     * @param _tranche The liquidity provider tranche being redeemed from
     * @param _target The share count the execution targets (the whole remaining request under the MAX sentinel)
     * @return sharesToRedeem The resolved share count: the target when in-kind serves it whole, else the dominant bound capped at the target
     * @return isMultiAssetRedemption Whether the redemption exits multi-asset (the multi-asset bound is strictly wider)
     */
    function _resolveOptimizedRedemption(address _tranche, uint256 _target) internal returns (uint256 sharesToRedeem, bool isMultiAssetRedemption) {
        // In-kind whenever it can serve the entire target
        uint256 maxRedeemInKind = IRoycoVaultTranche(_tranche).maxRedeem(address(this));
        if (maxRedeemInKind >= _target) return (_target, false);
        // Otherwise fill up to the dominant bound, exiting multi-asset only when its bound is strictly wider
        uint256 maxRedeemMultiAsset = _maxRedeemMultiAsset(_tranche);
        return (Math.min(Math.max(maxRedeemInKind, maxRedeemMultiAsset), _target), maxRedeemMultiAsset > maxRedeemInKind);
    }

    /**
     * @dev Probes the liquidity provider tranche's multi-asset redeemable bound through a low-level call: the
     *      multi-asset preview can revert on venue constraints, and a reverted probe must not revert the redemption
     *      (the caller falls back to the in-kind bound). A failed probe reports zero
     * @param _tranche The liquidity provider tranche to probe
     * @return maxRedeemMultiAsset The shares redeemable via the multi-asset exit (zero if the probe reverted)
     */
    function _maxRedeemMultiAsset(address _tranche) internal returns (uint256 maxRedeemMultiAsset) {
        (bool probeSucceeded, bytes memory probeReturnData) = _tranche.call(abi.encodeCall(IRoycoLiquidityProviderTranche.maxRedeemMultiAsset, (address(this))));
        assembly ("memory-safe") {
            if probeSucceeded { maxRedeemMultiAsset := mload(add(probeReturnData, 0x20)) }
        }
    }

    /**
     * @dev Batch-screens two accounts against the market's blacklist through the tranche's kernel
     * @param _kernel The kernel of the market that the tranche belongs to, consulted for the market's configured blacklist
     * @param _account0 The address of the first account to screen
     * @param _account1 The address of the second account to screen
     */
    function _enforceNotBlacklisted(address _kernel, address _account0, address _account1) internal view {
        address[] memory accountsToScreen = new address[](2);
        accountsToScreen[0] = _account0;
        accountsToScreen[1] = _account1;
        IRoycoDayKernel(_kernel).enforceNotBlacklisted(accountsToScreen);
    }

    /**
     * @dev Splits a redemption's claims into the executor's bonus and the receiver's portion, then remits both
     *      Transfers are gated on the receiver's post-bonus legs alone: the bonus floors every leg and the bonus
     *      percentage is strictly under WAD, so a nonzero bonus leg implies a nonzero receiver leg, and a zero
     *      receiver leg proves the whole leg is empty, so no bonus can be stranded behind the gate
     * @param _kernel The kernel of the market that the redeemed tranche belongs to, used to resolve the claim assets
     * @param _userClaims The redemption's total asset claims, reduced in place to the receiver's post-bonus portion
     * @param _quoteAssets The redemption's total quote leg (zero unless a liquidity provider tranche redemption exits multi-asset)
     * @param _executorBonusWAD The bonus percentage (0-100%) paid to the executor (the caller), scaled to WAD precision
     * @param _receiver The address to receive the user's claims
     * @return bonusClaims The asset claims remitted to the executor (the caller)
     * @return bonusQuoteAssets The quote remitted to the executor (the caller)
     */
    function _remitRedemptionAndBonusClaims(
        address _kernel,
        AssetClaims memory _userClaims,
        uint256 _quoteAssets,
        uint64 _executorBonusWAD,
        address _receiver
    )
        internal
        returns (AssetClaims memory bonusClaims, uint256 bonusQuoteAssets)
    {
        // Scale the asset claims to compute the executor bonus and the receiver's portion
        bonusClaims = TrancheClaimsLogic._scaleAssetClaims(_userClaims, _executorBonusWAD, WAD, false);
        // Deduct the NAV of the bonus claims from the user's claims
        _userClaims.collateralAssets = _userClaims.collateralAssets - bonusClaims.collateralAssets;
        _userClaims.lptAssets = _userClaims.lptAssets - bonusClaims.lptAssets;
        _userClaims.stShares = _userClaims.stShares - bonusClaims.stShares;
        _userClaims.nav = _userClaims.nav - bonusClaims.nav;

        // Transfer the collateral asset claims to the executor and receiver respectively
        if (_userClaims.collateralAssets != ZERO_TRANCHE_UNITS) {
            address collateralAsset = IRoycoDayKernel(_kernel).COLLATERAL_ASSET();
            IERC20(collateralAsset).safeTransfer(_receiver, toUint256(_userClaims.collateralAssets));
            if (bonusClaims.collateralAssets != ZERO_TRANCHE_UNITS) IERC20(collateralAsset).safeTransfer(msg.sender, toUint256(bonusClaims.collateralAssets));
        }
        // Transfer the LPT asset claims to the executor and receiver respectively
        if (_userClaims.lptAssets != ZERO_TRANCHE_UNITS) {
            address lptAsset = IRoycoDayKernel(_kernel).LPT_ASSET();
            IERC20(lptAsset).safeTransfer(_receiver, toUint256(_userClaims.lptAssets));
            if (bonusClaims.lptAssets != ZERO_TRANCHE_UNITS) IERC20(lptAsset).safeTransfer(msg.sender, toUint256(bonusClaims.lptAssets));
        }
        // Transfer the senior tranche share claims to the executor and receiver respectively
        if (_userClaims.stShares != 0) {
            address seniorTranche = IRoycoDayKernel(_kernel).SENIOR_TRANCHE();
            IERC20(seniorTranche).safeTransfer(_receiver, _userClaims.stShares);
            if (bonusClaims.stShares != 0) IERC20(seniorTranche).safeTransfer(msg.sender, bonusClaims.stShares);
        }
        // Transfer the quote leg to the executor and receiver respectively
        if (_quoteAssets != 0) {
            bonusQuoteAssets = Math.mulDiv(_quoteAssets, _executorBonusWAD, WAD, Math.Rounding.Floor);
            address quoteAsset = IRoycoDayKernel(_kernel).QUOTE_ASSET();
            IERC20(quoteAsset).safeTransfer(_receiver, (_quoteAssets - bonusQuoteAssets));
            if (bonusQuoteAssets != 0) IERC20(quoteAsset).safeTransfer(msg.sender, bonusQuoteAssets);
        }
    }

    /**
     * @dev Modifies the entry point configuration for the specified tranches
     * @param _tranches The tranches to modify configurations for
     * @param _configs The new configurations for each tranche
     */
    function _modifyTrancheConfigs(address[] calldata _tranches, TrancheConfig[] calldata _configs) internal {
        // Ensure that each tranche has a specified config
        uint256 numTranches = _tranches.length;
        require(numTranches == _configs.length, ARRAY_LENGTH_MISMATCH());

        // Ensure that each tranche was deployed by the Royco factory and update their configurations
        RoycoDayEntryPointState storage $ = _getRoycoDayEntryPointStorage();
        for (uint256 i = 0; i < numTranches; ++i) {
            // Cache and validate the tranche
            address tranche = _tranches[i];
            require(tranche != address(0), NULL_ADDRESS());

            // Get the tranche's kernel from the factory: also serves as validation that the tranche was deployed by the canonical factory
            address kernel = IRoycoFactory(ROYCO_FACTORY).trancheToKernel(tranche);
            require(kernel != address(0), INVALID_TRANCHE());

            // Set the tranche configuration
            EnrichedTrancheConfig memory enrichedConfig = EnrichedTrancheConfig({
                asset: IRoycoVaultTranche(tranche).asset(), kernel: kernel, trancheType: IRoycoVaultTranche(tranche).TRANCHE_TYPE(), baseConfig: _configs[i]
            });
            $.trancheToConfig[tranche] = enrichedConfig;

            // Poke the market's collateral asset oracle to validate it
            _pokeOracle(tranche, enrichedConfig);

            emit TrancheConfigUpdated(tranche, _configs[i]);
        }
    }

    /**
     * @notice Returns a storage pointer to the RoycoDayEntryPointState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer to the entry point's state
     */
    function _getRoycoDayEntryPointStorage() internal pure returns (RoycoDayEntryPointState storage $) {
        assembly ("memory-safe") {
            $.slot := ROYCO_DAY_ENTRY_POINT_STORAGE_SLOT
        }
    }
}
