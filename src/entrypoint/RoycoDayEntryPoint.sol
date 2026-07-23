// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { RoycoBase } from "../base/RoycoBase.sol";
import { IOracleClock } from "../interfaces/IOracleClock.sol";
import { IRoycoDayEntryPoint } from "../interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoDayKernel } from "../interfaces/IRoycoDayKernel.sol";
import { IRoycoLiquidityTranche } from "../interfaces/IRoycoLiquidityTranche.sol";
import { IRoycoVaultTranche } from "../interfaces/IRoycoVaultTranche.sol";
import { IRoycoFactory } from "../interfaces/factory/IRoycoFactory.sol";
import { MAX_TRANCHE_UNITS, WAD, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../libraries/Constants.sol";
import { AssetClaims, TrancheType } from "../libraries/Types.sol";
import { NAV_UNIT, RoycoUnitsMath, TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../libraries/Units.sol";
import { TrancheClaimsLogic } from "../libraries/logic/TrancheClaimsLogic.sol";

/**
 * @title RoycoDayEntryPoint
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Periphery contract enabling asynchronous deposit and redemption flows on Royco Tranches
 * @dev Enforces configurable delays between request and execution to prevent oracle front-running attacks
 *      Tranches configured with an oracle clock additionally gate execution on at least one observed oracle update
 *      after the request, so any information known at request time is priced into the mark before execution
 *      Requests are yield-neutral: any yield accrued on escrowed assets or shares during the delay period is
 *      forfeited to the protocol as fee shares, so a queued request can never gain value over its request-time NAV
 *      Supports third-party executors (keepers) with configurable bonus incentives
 *      Partial execution is supported, allowing requests to be fulfilled incrementally as tranche capacity is freed up
 *      Screens interacting addresses against the market's blacklist through the tranche's kernel, covering the request
 *      operators and every value flow that settles outside the kernel's own screened paths
 */
contract RoycoDayEntryPoint is RoycoBase, IRoycoDayEntryPoint {
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
        returns (uint256 requestNonce, uint32 executableAtTimestamp)
    {
        // Validate the deposit request
        require(_assets != ZERO_TRANCHE_UNITS, MUST_EXECUTE_NON_ZERO_AMOUNT());
        require(_tranche != address(0) && _receiver != address(0), NULL_ADDRESS());
        require(_executorBonusWAD < WAD || _executorBonusWAD == type(uint64).max, INVALID_EXECUTOR_BONUS());

        // Ensure that the tranche is enabled on this entry point and the caller and receiver are not blacklisted
        RoycoDayEntryPointState storage $ = _getRoycoDayEntryPointStorage();
        EnrichedTrancheConfig memory config = $.trancheToConfig[_tranche];
        require(config.baseConfig.enabled, TRANCHE_NOT_ENABLED());
        _enforceNotBlacklisted(config.kernel, msg.sender, _receiver);

        // Poke the tranche's oracle clock so that a source update that predates this request can never open its execution gate
        _pokeOracleClock(_tranche, config.baseConfig.oracleClock);

        // Register the user's deposit request with a fresh nonce
        DepositRequest storage request = $.userToNonceToDepositRequest[msg.sender][(requestNonce = ++$.lastRequestNonce)];
        request.assets = _assets;
        request.baseRequest = BaseRequest({
            tranche: _tranche,
            queuedAtTimestamp: uint32(block.timestamp),
            // Snapshot the NAV of the escrowed assets, used to forfeit any yield they accrue during the request lifecycle
            navAtRequestTime: _convertAssetsToValue(config.kernel, config.trancheType, _assets),
            receiver: _receiver,
            executableAtTimestamp: (executableAtTimestamp = uint32(block.timestamp + config.baseConfig.depositDelaySeconds)),
            executorBonusWAD: _executorBonusWAD
        });

        // Transfer the requested amount of tranche assets into the entry point to queue the deposit
        IERC20(config.asset).safeTransferFrom(msg.sender, address(this), toUint256(_assets));

        // Emit the deposit request event
        emit DepositRequested(
            msg.sender, requestNonce, _tranche, _assets, _receiver, request.baseRequest.navAtRequestTime, executableAtTimestamp, _executorBonusWAD
        );
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
        uint64 _executorBonusWAD
    )
        external
        override(IRoycoDayEntryPoint)
        whenNotPaused
        restricted
        returns (uint256 requestNonce, uint32 executableAtTimestamp)
    {
        // Validate the redemption request
        require(_shares != 0, MUST_EXECUTE_NON_ZERO_AMOUNT());
        require(_tranche != address(0) && _receiver != address(0), NULL_ADDRESS());
        require(_executorBonusWAD < WAD || _executorBonusWAD == type(uint64).max, INVALID_EXECUTOR_BONUS());

        // Ensure that the tranche is enabled on this entry point and the receiver is not blacklisted (the share escrow transfer below screens the caller)
        RoycoDayEntryPointState storage $ = _getRoycoDayEntryPointStorage();
        EnrichedTrancheConfig memory config = $.trancheToConfig[_tranche];
        require(config.baseConfig.enabled, TRANCHE_NOT_ENABLED());
        _enforceNotBlacklisted(config.kernel, _receiver);

        // Poke the tranche's oracle clock so that a source update that predates this request can never open its execution gate
        _pokeOracleClock(_tranche, config.baseConfig.oracleClock);

        // Register the user's redemption request with a fresh nonce
        RedemptionRequest storage request = $.userToNonceToRedemptionRequest[msg.sender][(requestNonce = ++$.lastRequestNonce)];
        request.shares = _shares;
        request.baseRequest = BaseRequest({
            tranche: _tranche,
            queuedAtTimestamp: uint32(block.timestamp),
            // Snapshot the NAV of the escrowed shares, used to forfeit any yield they accrue during the request lifecycle
            navAtRequestTime: IRoycoVaultTranche(_tranche).convertToAssets(_shares).nav,
            receiver: _receiver,
            executableAtTimestamp: (executableAtTimestamp = uint32(block.timestamp + config.baseConfig.redemptionDelaySeconds)),
            executorBonusWAD: _executorBonusWAD
        });

        // Transfer the requested amount of tranche shares into the entry point to queue the redemption
        IERC20(_tranche).safeTransferFrom(msg.sender, address(this), _shares);

        // Emit the redemption request event
        emit RedemptionRequested(
            msg.sender, requestNonce, _tranche, _shares, _receiver, request.baseRequest.navAtRequestTime, executableAtTimestamp, _executorBonusWAD
        );
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

    /**
     * =============================
     * Admin Functions
     * =============================
     */

    /// @inheritdoc IRoycoDayEntryPoint
    function pokeOracleClock(address _tranche) external override(IRoycoDayEntryPoint) whenNotPaused restricted returns (uint32 lastUpdatedAtTimestamp) {
        return _pokeOracleClock(_tranche, _getRoycoDayEntryPointStorage().trancheToConfig[_tranche].baseConfig.oracleClock);
    }

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
     *      If executed by a third party, the executor bonus is paid in assets before depositing the remainder
     * @param _user The user whose deposit request should be executed
     * @param _requestNonce The nonce of the deposit request to execute
     * @param _assetsToDeposit The amount of assets to deposit (use MAX_TRANCHE_UNITS to deposit the maximum possible)
     * @return trancheSharesMinted The amount of tranche shares minted to the receiver
     */
    function _executeDeposit(address _user, uint256 _requestNonce, TRANCHE_UNIT _assetsToDeposit) internal returns (uint256 trancheSharesMinted) {
        require(_assetsToDeposit != ZERO_TRANCHE_UNITS, MUST_EXECUTE_NON_ZERO_AMOUNT());

        // Retrieve the user's specified deposit request and its tranche's config
        RoycoDayEntryPointState storage $ = _getRoycoDayEntryPointStorage();
        DepositRequest memory request = $.userToNonceToDepositRequest[_user][_requestNonce];
        address tranche = request.baseRequest.tranche;
        EnrichedTrancheConfig memory config = $.trancheToConfig[tranche];

        // Assert the validity of the request
        _validateRequestExecution(_requestNonce, request.baseRequest, config.baseConfig.oracleClock);
        require(config.baseConfig.enabled, TRANCHE_NOT_ENABLED());

        // Screen the executor and request owner against the market's blacklist so a flagged party can never operate the request (the tranche deposit below screens the receiver)
        _enforceNotBlacklisted(config.kernel, msg.sender, _user);

        // Resolve the actual amount of assets to deposit
        _assetsToDeposit = (_assetsToDeposit == MAX_TRANCHE_UNITS)
            ? toTrancheUnits(Math.min(toUint256(IRoycoVaultTranche(tranche).maxDeposit(request.baseRequest.receiver)), toUint256(request.assets)))
            : _assetsToDeposit;
        // Return early without reverting if maxDeposit is 0 due to market conditions
        if (_assetsToDeposit == ZERO_TRANCHE_UNITS) return 0;

        // Mark the assets as deposited
        TRANCHE_UNIT assetsLeftToDeposit = request.assets - _assetsToDeposit;
        if (assetsLeftToDeposit == ZERO_TRANCHE_UNITS) {
            delete $.userToNonceToDepositRequest[_user][_requestNonce];
        } else {
            $.userToNonceToDepositRequest[_user][_requestNonce].assets = assetsLeftToDeposit;
            // Scale the NAV of the remaining assets in the request by the assets left to deposit
            NAV_UNIT navOfAssetsLeftToDeposit = request.baseRequest.navAtRequestTime.mulDiv(assetsLeftToDeposit, request.assets, Math.Rounding.Floor);
            $.userToNonceToDepositRequest[_user][_requestNonce].baseRequest.navAtRequestTime = navOfAssetsLeftToDeposit;
            request.baseRequest.navAtRequestTime = request.baseRequest.navAtRequestTime - navOfAssetsLeftToDeposit;
        }

        // Execute the deposit on the underlying tranche
        TRANCHE_UNIT bonusAssets;
        uint256 protocolFeeShares;
        // If this is a self-deposit or there is no executor bonus configured, deposit the assets, forfeiting accrued yield as protocol fees
        if (_user == msg.sender || request.baseRequest.executorBonusWAD == 0) {
            (trancheSharesMinted, protocolFeeShares) =
                _depositWithYieldForfeiture(tranche, config, _assetsToDeposit, request.baseRequest.navAtRequestTime, request.baseRequest.receiver);
        }
        // If this is a third party execution, remit the executor bonus and deposit the remaining assets
        else {
            // Ensure that the user has opted into third party execution
            require(request.baseRequest.executorBonusWAD != type(uint64).max, THIRD_PARTY_EXECUTION_DISABLED());
            // Compute and transfer bonus assets to the executor
            bonusAssets = _assetsToDeposit.mulDiv(request.baseRequest.executorBonusWAD, WAD, Math.Rounding.Floor);
            if (bonusAssets != ZERO_TRANCHE_UNITS) IERC20(config.asset).safeTransfer(msg.sender, toUint256(bonusAssets));
            // Scale the NAV at request time to the assets being deposited after remitting the bonus
            request.baseRequest.navAtRequestTime =
                request.baseRequest.navAtRequestTime.mulDiv((_assetsToDeposit - bonusAssets), _assetsToDeposit, Math.Rounding.Floor);
            // Deposit the remaining assets, forfeiting accrued yield as protocol fees
            _assetsToDeposit = _assetsToDeposit - bonusAssets;
            (trancheSharesMinted, protocolFeeShares) =
                _depositWithYieldForfeiture(tranche, config, _assetsToDeposit, request.baseRequest.navAtRequestTime, request.baseRequest.receiver);
        }

        // Emit the deposit execution event
        emit DepositExecuted(_user, _requestNonce, msg.sender, _assetsToDeposit, trancheSharesMinted, protocolFeeShares, bonusAssets);
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

        // Emit the deposit request cancellation event
        emit DepositRequestCancelled(msg.sender, _requestNonce, _receiver, request.assets);
    }

    /**
     * @notice Executes a pending redemption request for the specified user
     * @dev The request must exist and the configured delay period must have elapsed
     *      A maximal liquidity tranche redemption exits in-kind whenever the in-kind bound serves the entire
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
        _validateRequestExecution(_requestNonce, request.baseRequest, config.baseConfig.oracleClock);
        require(config.baseConfig.enabled, TRANCHE_NOT_ENABLED());

        // Screen the executor and request owner against the market's blacklist so a flagged party can never operate the request
        _enforceNotBlacklisted(config.kernel, msg.sender, _user);

        // Resolve the actual amount of shares to redeem and the exit route for liquidity tranche redemptions specifically
        bool isMultiAssetRedemption;
        if (_sharesToRedeem == type(uint256).max) {
            // If the tranche being redeemed from is a LT, default to the in-kind mode if it satisfies the redemption, and fallback to the multiasset flow if it provides a higher redeemable amount
            if (config.trancheType == TrancheType.LIQUIDITY) {
                // Use the in-kind flow if it is sufficient for this redemption
                uint256 maxRedeemInKind = IRoycoVaultTranche(tranche).maxRedeem(address(this));
                if (maxRedeemInKind >= request.shares) {
                    _sharesToRedeem = request.shares;
                } else {
                    // Probe the multi-asset bound through a low-level call: the multi-asset preview can revert on venue constraints, but must not revert the redemption from utilizing the in-kind flow
                    (bool multiAssetProbeSucceeded, bytes memory multiAssetProbeReturnData) =
                        tranche.call(abi.encodeCall(IRoycoLiquidityTranche.maxRedeemMultiAsset, (address(this))));
                    // A reverted probe leaves the multi-asset route unavailable, fall back to the in-kind bound so the portion the market can serve is never left behind
                    uint256 maxRedeemMultiAsset;
                    assembly ("memory-safe") { if multiAssetProbeSucceeded { maxRedeemMultiAsset := mload(add(multiAssetProbeReturnData, 0x20)) } }
                    _sharesToRedeem = Math.min(Math.max(maxRedeemInKind, maxRedeemMultiAsset), request.shares);
                    isMultiAssetRedemption = (maxRedeemMultiAsset > maxRedeemInKind);
                }
            }
            // If the tranche being redeemed from is not a LT, redeem the maximum amount that can be redeemed in-kind, up to the requested amount
            else {
                _sharesToRedeem = Math.min(IRoycoVaultTranche(tranche).maxRedeem(address(this)), request.shares);
            }
        }
        // Return early without reverting if the maximum redeemable is 0 due to market conditions
        if (_sharesToRedeem == 0) return (AssetClaims(ZERO_TRANCHE_UNITS, ZERO_TRANCHE_UNITS, 0, ZERO_NAV_UNITS), 0);

        // Mark the shares as redeemed
        uint256 sharesLeftToRedeem = request.shares - _sharesToRedeem;
        if (sharesLeftToRedeem == 0) {
            delete $.userToNonceToRedemptionRequest[_user][_requestNonce];
        } else {
            $.userToNonceToRedemptionRequest[_user][_requestNonce].shares = sharesLeftToRedeem;
            // Scale the NAV of the remaining shares in the request by the shares left to redeem
            NAV_UNIT navOfSharesLeftToRedeem = request.baseRequest.navAtRequestTime.mulDiv(sharesLeftToRedeem, request.shares, Math.Rounding.Floor);
            $.userToNonceToRedemptionRequest[_user][_requestNonce].baseRequest.navAtRequestTime = navOfSharesLeftToRedeem;
            request.baseRequest.navAtRequestTime = request.baseRequest.navAtRequestTime - navOfSharesLeftToRedeem;
        }

        // If this is a self-redemption or there is no executor bonus configured, withdraw assets directly to the specified recipient
        uint256 userSharesRedeemed;
        uint256 protocolFeeShares;
        AssetClaims memory bonusClaims;
        uint256 bonusQuoteAssets;
        if (_user == msg.sender || request.baseRequest.executorBonusWAD == 0) {
            // Redeem shares directly to the receiver, forfeiting accrued yield as protocol fees
            (userSharesRedeemed, protocolFeeShares, userClaims, quoteAssets) = _redeemWithYieldForfeiture(
                tranche, _sharesToRedeem, request.baseRequest.navAtRequestTime, request.baseRequest.receiver, isMultiAssetRedemption
            );
        }
        // Else, if this is a third party execution, withdraw the assets, forfeit any accrued yield as protocol fees, and remit the executor bonus
        else {
            // Ensure that the user has opted into third party execution
            require(request.baseRequest.executorBonusWAD != type(uint64).max, THIRD_PARTY_EXECUTION_DISABLED());
            // Screen the receiver against the market's blacklist, the asset and quote remittance legs below settle outside the kernel's screened flows (the self path's redemption screens the receiver)
            _enforceNotBlacklisted(config.kernel, request.baseRequest.receiver);

            // Redeem shares to this contract for bonus calculation, forfeiting accrued yield as protocol fees
            (userSharesRedeemed, protocolFeeShares, userClaims, quoteAssets) =
                _redeemWithYieldForfeiture(tranche, _sharesToRedeem, request.baseRequest.navAtRequestTime, address(this), isMultiAssetRedemption);

            // Split the redeemed claims and quote into the executor's bonus and the receiver's portion, then remit both
            (bonusClaims, bonusQuoteAssets) =
                _remitRedemptionAndBonusClaims(config.kernel, userClaims, quoteAssets, request.baseRequest.executorBonusWAD, request.baseRequest.receiver);
            quoteAssets -= bonusQuoteAssets;
        }

        // Emit the redemption execution event
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
        // Screen the canceller against the market's blacklist, the share escrow return below screens the receiver through the kernel's balance update hook
        _enforceNotBlacklisted($.trancheToConfig[request.baseRequest.tranche].kernel, msg.sender);

        // Mark the request as cancelled
        delete $.userToNonceToRedemptionRequest[msg.sender][_requestNonce];

        // Return the shares from the cancelled request to the specified receiver
        IERC20(request.baseRequest.tranche).safeTransfer(_receiver, request.shares);

        // Emit the redemption request cancellation event
        emit RedemptionRequestCancelled(msg.sender, _requestNonce, _receiver, request.shares);
    }

    /**
     * @dev Asserts that a request exists and is executable: not executed already or cancelled, past its delay, and
     *      the tranche's oracle clock has observed at least one oracle update strictly after the request was queued,
     *      so any information known at request time is priced into the mark before execution
     *      A clock reporting no update yet (a zero timestamp) conservatively holds the gate shut
     * @param _requestNonce The nonce of the request being validated
     * @param _baseRequest The base request data shared across request types
     * @param _oracleClock The tranche's oracle clock (the null address disables the gate)
     */
    function _validateRequestExecution(uint256 _requestNonce, BaseRequest memory _baseRequest, address _oracleClock) internal {
        // Ensure the request exists and the configured delay period has elapsed
        require(_baseRequest.executableAtTimestamp != 0 && _baseRequest.executableAtTimestamp <= block.timestamp, INVALID_REQUEST(_requestNonce));
        // Ensure the tranche's oracle clock has observed an oracle update strictly after the request was queued
        require(
            _oracleClock == address(0) || (_pokeOracleClock(_baseRequest.tranche, _oracleClock) > _baseRequest.queuedAtTimestamp),
            ORACLE_CLOCK_NOT_ADVANCED(_requestNonce)
        );
    }

    /**
     * @dev Pokes the tranche's oracle clock
     * @param _tranche The tranche whose oracle clock is being poked
     * @param _oracleClock The tranche's oracle clock (the null address disables the gate and makes the poke a no-op)
     * @return lastUpdatedAtTimestamp The clock's last update timestamp after the poke (zero when the tranche has no clock or it has observed no update yet)
     */
    function _pokeOracleClock(address _tranche, address _oracleClock) internal returns (uint32 lastUpdatedAtTimestamp) {
        if (_oracleClock == address(0)) return 0;
        // The clock must never report a future update timestamp: it would satisfy the execution gate without a genuine update
        require((lastUpdatedAtTimestamp = IOracleClock(_oracleClock).poke()) <= block.timestamp, ORACLE_CLOCK_IN_THE_FUTURE());
        emit OracleClockTick(_tranche, lastUpdatedAtTimestamp);
    }

    /**
     * @dev Deposits assets, forfeiting any yield accrued during the request lifecycle as protocol fees
     * @param _tranche The tranche to deposit assets into
     * @param _config The enriched tranche configuration
     * @param _assets The amount of assets to deposit into the tranche
     * @param _navAtRequestTime The NAV of the assets being deposited at the time the deposit was requested
     * @param _receiver The address to receive the minted tranche shares
     * @return userTrancheShares The shares actually minted for the user (total minus forfeited)
     * @return protocolFeeShares The shares forfeited to the protocol equating to the yield accrued during the request lifecycle (zero if NAV decreased)
     */
    function _depositWithYieldForfeiture(
        address _tranche,
        EnrichedTrancheConfig memory _config,
        TRANCHE_UNIT _assets,
        NAV_UNIT _navAtRequestTime,
        address _receiver
    )
        internal
        returns (uint256 userTrancheShares, uint256 protocolFeeShares)
    {
        // Approve the tranche to pull the assets being deposited
        IERC20(_config.asset).forceApprove(_tranche, toUint256(_assets));
        // Compute the NAV of the assets being deposited at execution time
        NAV_UNIT navAtExecutionTime = _convertAssetsToValue(_config.kernel, _config.trancheType, _assets);
        // If no yield accrued on the escrowed assets since placing the request, mint shares directly to the specified receiver
        if (navAtExecutionTime <= _navAtRequestTime) {
            userTrancheShares = IRoycoVaultTranche(_tranche).deposit(_assets, _receiver);
        } else {
            // Mint the shares to the entry point and compute the tranche shares to forfeit for the yield accrued since placing the request
            // The forfeited shares are retained as protocol fee shares, leaving the receiver with shares worth exactly the NAV at request time
            userTrancheShares = IRoycoVaultTranche(_tranche).deposit(_assets, address(this));
            protocolFeeShares = userTrancheShares.mulDiv((navAtExecutionTime - _navAtRequestTime), navAtExecutionTime, Math.Rounding.Floor);
            // Transfer the shares the user is entitled to after deducting the protocol fee shares
            if ((userTrancheShares -= protocolFeeShares) != 0) IERC20(_tranche).safeTransfer(_receiver, userTrancheShares);
            // Accrue the forfeited shares as protocol fees
            if (protocolFeeShares != 0) _getRoycoDayEntryPointStorage().trancheToProtocolFeeShares[_tranche] += protocolFeeShares;
        }
    }

    /**
     * @dev Redeems shares, forfeiting any yield accrued during the request lifecycle as protocol fees
     * @param _tranche The tranche to redeem shares from
     * @param _shares The amount of shares to redeem from the tranche
     * @param _navAtRequestTime The NAV of the shares being redeemed at the time the redemption was requested
     * @param _receiver The address to receive the redeemed assets
     * @param _isMultiAssetRedemption Whether to exit a liquidity tranche redemption to the LP token's constituents instead of in-kind
     * @return userSharesRedeemed The shares actually redeemed for the user (total minus forfeited)
     * @return protocolFeeShares The shares forfeited to the protocol equating to the yield accrued during the request lifecycle (zero if NAV decreased)
     * @return userClaims The assets withdrawn from the tranche for the user after forfeiting accrued yield
     * @return quoteAssets The quote withdrawn from the tranche for the user (zero unless the redemption exits multi-asset)
     */
    function _redeemWithYieldForfeiture(
        address _tranche,
        uint256 _shares,
        NAV_UNIT _navAtRequestTime,
        address _receiver,
        bool _isMultiAssetRedemption
    )
        internal
        returns (uint256 userSharesRedeemed, uint256 protocolFeeShares, AssetClaims memory userClaims, uint256 quoteAssets)
    {
        // Initialize the user's shares redeemed as the input
        userSharesRedeemed = _shares;
        // Compute the tranche shares equivalent to the value of the yield accrued since placing the request
        NAV_UNIT navAtExecutionTime = IRoycoVaultTranche(_tranche).convertToAssets(_shares).nav;
        if (navAtExecutionTime > _navAtRequestTime) {
            protocolFeeShares = _shares.mulDiv((navAtExecutionTime - _navAtRequestTime), navAtExecutionTime, Math.Rounding.Floor);
        }
        // Redeem the shares the user is entitled to after deducting the protocol fee shares
        // A fully forfeited redemption (a zero-NAV snapshot) settles without a redeem call, mirroring the deposit path
        if ((userSharesRedeemed -= protocolFeeShares) != 0) {
            if (_isMultiAssetRedemption) {
                // Multi-asset redemptions mandate that liquidity is removed in a way that cannot render less value than promised at present NAV values
                (userClaims, quoteAssets) = IRoycoLiquidityTranche(_tranche).redeemMultiAsset(userSharesRedeemed, 0, 0, _receiver, address(this));
            } else {
                userClaims = IRoycoVaultTranche(_tranche).redeem(userSharesRedeemed, _receiver, address(this));
            }
        }
        // Accrue the forfeited shares as protocol fees
        if (protocolFeeShares != 0) _getRoycoDayEntryPointStorage().trancheToProtocolFeeShares[_tranche] += protocolFeeShares;
    }

    /**
     * @dev Converts an amount of a tranche's assets to NAV units using the market kernel's quoter for that asset
     * @dev The senior and junior tranches price through the single coinvested collateral quoter
     * @param _kernel The kernel of the market that the tranche belongs to
     * @param _trancheType The type of the tranche (senior, junior, or liquidity)
     * @param _assets The amount of assets to convert, denominated in the tranche's base asset units
     * @return value The value of the specified assets, denominated in the kernel's NAV units
     */
    function _convertAssetsToValue(address _kernel, TrancheType _trancheType, TRANCHE_UNIT _assets) internal view returns (NAV_UNIT value) {
        return (_trancheType == TrancheType.LIQUIDITY)
            ? IRoycoDayKernel(_kernel).convertLTAssetsToValue(_assets)
            : IRoycoDayKernel(_kernel).convertCollateralAssetsToValue(_assets);
    }

    /**
     * @dev Screens an account against the market's blacklist through the tranche's kernel
     *      Covers the addresses the kernel's own screened flows never reach: request operators, asset escrow movements,
     *      executor bonuses, and third party remittances all settle outside the tranche balance update hooks
     * @param _kernel The kernel of the market that the tranche belongs to, consulted for the market's configured blacklist
     * @param _account The address of the account to screen
     */
    function _enforceNotBlacklisted(address _kernel, address _account) internal view {
        address[] memory accountsToScreen = new address[](1);
        accountsToScreen[0] = _account;
        IRoycoDayKernel(_kernel).enforceNotBlacklisted(accountsToScreen);
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
     * @param _quoteAssets The redemption's total quote leg (zero unless a liquidity tranche redemption exits multi-asset)
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
        bonusClaims = TrancheClaimsLogic._scaleAssetClaims(_userClaims, _executorBonusWAD, WAD);
        // Deduct the NAV of the bonus claims from the user's claims
        _userClaims.collateralAssets = _userClaims.collateralAssets - bonusClaims.collateralAssets;
        _userClaims.ltAssets = _userClaims.ltAssets - bonusClaims.ltAssets;
        _userClaims.stShares = _userClaims.stShares - bonusClaims.stShares;
        _userClaims.nav = _userClaims.nav - bonusClaims.nav;

        // Transfer the collateral asset claims to the executor and receiver respectively
        if (_userClaims.collateralAssets != ZERO_TRANCHE_UNITS) {
            address collateralAsset = IRoycoDayKernel(_kernel).COLLATERAL_ASSET();
            IERC20(collateralAsset).safeTransfer(_receiver, toUint256(_userClaims.collateralAssets));
            if (bonusClaims.collateralAssets != ZERO_TRANCHE_UNITS) IERC20(collateralAsset).safeTransfer(msg.sender, toUint256(bonusClaims.collateralAssets));
        }
        // Transfer the LT asset claims to the executor and receiver respectively
        if (_userClaims.ltAssets != ZERO_TRANCHE_UNITS) {
            address ltAsset = IRoycoDayKernel(_kernel).LT_ASSET();
            IERC20(ltAsset).safeTransfer(_receiver, toUint256(_userClaims.ltAssets));
            if (bonusClaims.ltAssets != ZERO_TRANCHE_UNITS) IERC20(ltAsset).safeTransfer(msg.sender, toUint256(bonusClaims.ltAssets));
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

            // A configured oracle clock must never report a future update timestamp
            _pokeOracleClock(tranche, _configs[i].oracleClock);

            // Set the tranche configuration
            $.trancheToConfig[tranche] = EnrichedTrancheConfig({
                asset: IRoycoVaultTranche(tranche).asset(), kernel: kernel, trancheType: IRoycoVaultTranche(tranche).TRANCHE_TYPE(), baseConfig: _configs[i]
            });
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
