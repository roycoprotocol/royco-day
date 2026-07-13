// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ERC20BurnableUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import { IERC20, SafeERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { RoycoBase } from "../base/RoycoBase.sol";
import { IRoycoDayEntryPoint } from "../interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoDayKernel } from "../interfaces/IRoycoDayKernel.sol";
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
 *      Requests are yield-neutral: any yield accrued on escrowed assets or shares during the delay period is
 *      forfeited to the configured recipient, so a queued request can never gain value over its request-time NAV
 *      Supports third-party executors (keepers) with configurable bonus incentives
 *      Partial execution is supported, allowing requests to be fulfilled incrementally
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

    /// =============================
    /// Entry Point Deposit Functions
    /// =============================

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
        require(_assets != ZERO_TRANCHE_UNITS, ZERO_AMOUNT());
        require(_tranche != address(0) && _receiver != address(0), NULL_ADDRESS());
        require(_executorBonusWAD < WAD || _executorBonusWAD == type(uint64).max, INVALID_EXECUTOR_BONUS());

        // Ensure that the tranche is enabled on this entry point
        RoycoDayEntryPointState storage $ = _getRoycoDayEntryPointStorage();
        EnrichedTrancheConfig memory config = $.trancheToConfig[_tranche];
        require(config.baseConfig.enabled, TRANCHE_NOT_ENABLED());

        // Register the user's deposit request with a fresh nonce
        DepositRequest storage request = $.userToNonceToDepositRequest[msg.sender][(requestNonce = ++$.lastRequestNonce)];
        request.assets = _assets;
        // Snapshot the NAV of the escrowed assets, used to forfeit any yield they accrue during the request lifecycle
        request.navAtRequestTime = _convertAssetsToNAV(config.kernel, config.trancheType, _assets);
        request.baseRequest = BaseRequest({
            tranche: _tranche,
            receiver: _receiver,
            executableAtTimestamp: (executableAtTimestamp = uint32(block.timestamp + config.baseConfig.depositDelaySeconds)),
            executorBonusWAD: _executorBonusWAD
        });

        // Transfer the requested amount of tranche assets into the entry point to queue the deposit
        IERC20(config.asset).safeTransferFrom(msg.sender, address(this), toUint256(_assets));

        // Emit the deposit request event
        emit DepositRequested(msg.sender, requestNonce, _tranche, _assets, executableAtTimestamp, _executorBonusWAD);
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
    function cancelDepositRequests(uint256[] calldata _requestNonces, address _receiver) external override(IRoycoDayEntryPoint) {
        // Execute the user specified deposit request cancellations
        uint256 numRequestsToCancel = _requestNonces.length;
        for (uint256 i = 0; i < numRequestsToCancel; ++i) {
            cancelDepositRequest(_requestNonces[i], _receiver);
        }
    }

    /// @inheritdoc IRoycoDayEntryPoint
    function cancelDepositRequest(uint256 _requestNonce, address _receiver) public override(IRoycoDayEntryPoint) whenNotPaused restricted {
        // Ensure the receiver isn't null
        require(_receiver != address(0), NULL_ADDRESS());
        // Retrieve the user's specified deposit request and assert that it exists
        RoycoDayEntryPointState storage $ = _getRoycoDayEntryPointStorage();
        DepositRequest memory request = $.userToNonceToDepositRequest[msg.sender][_requestNonce];
        require(request.assets != ZERO_TRANCHE_UNITS, INVALID_REQUEST(_requestNonce));

        // Mark the request as cancelled
        delete $.userToNonceToDepositRequest[msg.sender][_requestNonce];

        // Return the assets from the cancelled request to the specified receiver
        address asset = $.trancheToConfig[request.baseRequest.tranche].asset;
        IERC20(asset).safeTransfer(_receiver, toUint256(request.assets));

        // Emit the deposit request cancellation event
        emit DepositRequestCancelled(msg.sender, _requestNonce, _receiver, request.assets);
    }

    /// =============================
    /// Entry Point Redemption Functions
    /// =============================

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
        require(_shares != 0, ZERO_AMOUNT());
        require(_tranche != address(0) && _receiver != address(0), NULL_ADDRESS());
        require(_executorBonusWAD < WAD || _executorBonusWAD == type(uint64).max, INVALID_EXECUTOR_BONUS());

        // Ensure that the tranche is enabled on this entry point
        RoycoDayEntryPointState storage $ = _getRoycoDayEntryPointStorage();
        EnrichedTrancheConfig memory config = $.trancheToConfig[_tranche];
        require(config.baseConfig.enabled, TRANCHE_NOT_ENABLED());

        // Register the user's redemption request with a fresh nonce
        RedemptionRequest storage request = $.userToNonceToRedemptionRequest[msg.sender][(requestNonce = ++$.lastRequestNonce)];
        request.shares = _shares;
        // Snapshot the NAV of the escrowed shares, used to forfeit any yield they accrue during the request lifecycle
        request.navAtRequestTime = IRoycoVaultTranche(_tranche).convertToAssets(_shares).nav;
        request.baseRequest = BaseRequest({
            tranche: _tranche,
            receiver: _receiver,
            executableAtTimestamp: (executableAtTimestamp = uint32(block.timestamp + config.baseConfig.redemptionDelaySeconds)),
            executorBonusWAD: _executorBonusWAD
        });

        // Transfer the requested amount of tranche shares into the entry point to queue the redemption
        IERC20(_tranche).safeTransferFrom(msg.sender, address(this), _shares);

        // Emit the redemption request event
        emit RedemptionRequested(msg.sender, requestNonce, _tranche, _shares, executableAtTimestamp, _executorBonusWAD);
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
        returns (AssetClaims[] memory userClaims)
    {
        // Execute the user specified redemption requests
        uint256 numRequestsToExecute = _requestNonces.length;
        require(numRequestsToExecute == _users.length && numRequestsToExecute == _sharesToRedeem.length, ARRAY_LENGTH_MISMATCH());
        userClaims = new AssetClaims[](numRequestsToExecute);
        for (uint256 i = 0; i < numRequestsToExecute; ++i) {
            userClaims[i] = _executeRedemption(_users[i], _requestNonces[i], _sharesToRedeem[i]);
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
        returns (AssetClaims memory userClaims)
    {
        return _executeRedemption(_user, _requestNonce, _sharesToRedeem);
    }

    /// @inheritdoc IRoycoDayEntryPoint
    function cancelRedemptionRequests(uint256[] calldata _requestNonces, address _receiver) external override(IRoycoDayEntryPoint) {
        // Execute the user specified redemption request cancellations
        uint256 numRequestsToCancel = _requestNonces.length;
        for (uint256 i = 0; i < numRequestsToCancel; ++i) {
            cancelRedemptionRequest(_requestNonces[i], _receiver);
        }
    }

    /// @inheritdoc IRoycoDayEntryPoint
    function cancelRedemptionRequest(uint256 _requestNonce, address _receiver) public override(IRoycoDayEntryPoint) whenNotPaused restricted {
        // Ensure the receiver isn't null
        require(_receiver != address(0), NULL_ADDRESS());
        // Retrieve the user's specified redemption request and assert that it exists
        RoycoDayEntryPointState storage $ = _getRoycoDayEntryPointStorage();
        RedemptionRequest memory request = $.userToNonceToRedemptionRequest[msg.sender][_requestNonce];
        require(request.shares != 0, INVALID_REQUEST(_requestNonce));

        // Mark the request as cancelled
        delete $.userToNonceToRedemptionRequest[msg.sender][_requestNonce];

        // Return the shares from the cancelled request to the specified receiver
        IERC20(request.baseRequest.tranche).safeTransfer(_receiver, request.shares);

        // Emit the redemption request cancellation event
        emit RedemptionRequestCancelled(msg.sender, _requestNonce, _receiver, request.shares);
    }

    /// =============================
    /// Admin Functions
    /// =============================

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

    /// =============================
    /// State Accessor Functions
    /// =============================

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

    /// =============================
    /// Internal Utility Functions
    /// =============================

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
        require(_assetsToDeposit != ZERO_TRANCHE_UNITS, ZERO_AMOUNT());
        // Retrieve the user's specified deposit request and assert its validity
        RoycoDayEntryPointState storage $ = _getRoycoDayEntryPointStorage();
        DepositRequest memory request = $.userToNonceToDepositRequest[_user][_requestNonce];
        _validateRequestExecution(_requestNonce, request.baseRequest.executableAtTimestamp);

        // Ensure the tranche is still enabled
        address tranche = request.baseRequest.tranche;
        EnrichedTrancheConfig memory config = $.trancheToConfig[tranche];
        require(config.baseConfig.enabled, TRANCHE_NOT_ENABLED());

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
            NAV_UNIT navOfAssetsLeftToDeposit = request.navAtRequestTime.mulDiv(assetsLeftToDeposit, request.assets, Math.Rounding.Floor);
            $.userToNonceToDepositRequest[_user][_requestNonce].navAtRequestTime = navOfAssetsLeftToDeposit;
            request.navAtRequestTime = request.navAtRequestTime - navOfAssetsLeftToDeposit;
        }

        // Execute the deposit on the underlying tranche
        TRANCHE_UNIT bonusAssets;
        uint256 forfeitedYieldShares;
        // If this is a self-deposit or there is no executor bonus configured, deposit the assets and route yield as configured
        if (_user == msg.sender || request.baseRequest.executorBonusWAD == 0) {
            (trancheSharesMinted, forfeitedYieldShares) =
                _depositWithYieldRouting(tranche, config, _assetsToDeposit, request.navAtRequestTime, request.baseRequest.receiver);
        }
        // If this is an third party execution, remit the executor bonus and deposit the remaining assets
        else {
            // Ensure that the user has opted into third party execution
            require(request.baseRequest.executorBonusWAD != type(uint64).max, THIRD_PARTY_EXECUTION_DISABLED());
            // Compute and transfer bonus assets to the executor
            bonusAssets = _assetsToDeposit.mulDiv(request.baseRequest.executorBonusWAD, WAD, Math.Rounding.Floor);
            if (bonusAssets != ZERO_TRANCHE_UNITS) IERC20(config.asset).safeTransfer(msg.sender, toUint256(bonusAssets));
            // Scale the NAV at request time to the assets being deposited after remitting the bonus
            request.navAtRequestTime = request.navAtRequestTime.mulDiv(_assetsToDeposit - bonusAssets, _assetsToDeposit, Math.Rounding.Floor);
            // Deposit the remaining assets and route yield as configured
            _assetsToDeposit = _assetsToDeposit - bonusAssets;
            (trancheSharesMinted, forfeitedYieldShares) =
                _depositWithYieldRouting(tranche, config, _assetsToDeposit, request.navAtRequestTime, request.baseRequest.receiver);
        }

        // Emit the deposit execution event
        emit DepositExecuted(_user, _requestNonce, msg.sender, _assetsToDeposit, trancheSharesMinted, forfeitedYieldShares, bonusAssets);
    }

    /**
     * @notice Executes a pending redemption request for the specified user
     * @dev The request must exist and the configured delay period must have elapsed
     * @param _user The user whose redemption request should be executed
     * @param _requestNonce The nonce of the redemption request to execute
     * @param _sharesToRedeem The amount of shares to redeem (use type(uint256).max to redeem the maximum possible)
     * @return userClaims The assets withdrawn to the request-specific receiver upon executing this redemption request
     */
    function _executeRedemption(address _user, uint256 _requestNonce, uint256 _sharesToRedeem) internal returns (AssetClaims memory userClaims) {
        require(_sharesToRedeem != 0, ZERO_AMOUNT());
        // Retrieve the user's specified redemption request and assert its validity
        RoycoDayEntryPointState storage $ = _getRoycoDayEntryPointStorage();
        RedemptionRequest memory request = $.userToNonceToRedemptionRequest[_user][_requestNonce];
        _validateRequestExecution(_requestNonce, request.baseRequest.executableAtTimestamp);

        // Ensure the tranche is still enabled
        address tranche = request.baseRequest.tranche;
        EnrichedTrancheConfig memory config = $.trancheToConfig[tranche];
        require(config.baseConfig.enabled, TRANCHE_NOT_ENABLED());

        // Resolve the actual amount of shares to redeem
        _sharesToRedeem =
            (_sharesToRedeem == type(uint256).max) ? Math.min(IRoycoVaultTranche(tranche).maxRedeem(address(this)), request.shares) : _sharesToRedeem;
        // Return early without reverting if maxRedeem is 0 due to market conditions
        if (_sharesToRedeem == 0) return AssetClaims(ZERO_TRANCHE_UNITS, ZERO_TRANCHE_UNITS, ZERO_TRANCHE_UNITS, 0, ZERO_NAV_UNITS);

        // Mark the shares as redeemed
        uint256 sharesLeftToRedeem = request.shares - _sharesToRedeem;
        if (sharesLeftToRedeem == 0) {
            delete $.userToNonceToRedemptionRequest[_user][_requestNonce];
        } else {
            $.userToNonceToRedemptionRequest[_user][_requestNonce].shares = sharesLeftToRedeem;
            // Scale the NAV of the remaining shares in the request by the shares left to redeem
            NAV_UNIT navOfSharesLeftToRedeem = request.navAtRequestTime.mulDiv(sharesLeftToRedeem, request.shares, Math.Rounding.Floor);
            $.userToNonceToRedemptionRequest[_user][_requestNonce].navAtRequestTime = navOfSharesLeftToRedeem;
            request.navAtRequestTime = request.navAtRequestTime - navOfSharesLeftToRedeem;
        }

        // If this is a self-redemption or there is no executor bonus configured, withdraw assets directly to the specified recipient
        uint256 userSharesRedeemed;
        uint256 forfeitedYieldShares;
        AssetClaims memory bonusClaims;
        if (_user == msg.sender || request.baseRequest.executorBonusWAD == 0) {
            // Redeem shares and route yield directly to the receiver
            (userSharesRedeemed, forfeitedYieldShares, userClaims) =
                _redeemWithYieldRouting(tranche, config.baseConfig.yieldRecipient, _sharesToRedeem, request.navAtRequestTime, request.baseRequest.receiver);
        }
        // If this is a third party execution, withdraw the assets, handle any yield as configured, and remit the executor bonus
        else {
            // Ensure that the user has opted into third party execution
            require(request.baseRequest.executorBonusWAD != type(uint64).max, THIRD_PARTY_EXECUTION_DISABLED());

            // Redeem shares and route yield to this contract for bonus calculation
            (userSharesRedeemed, forfeitedYieldShares, userClaims) =
                _redeemWithYieldRouting(tranche, config.baseConfig.yieldRecipient, _sharesToRedeem, request.navAtRequestTime, address(this));

            // Scale the asset claims to compute the executor bonus and the receiver's portion
            bonusClaims = TrancheClaimsLogic._scaleAssetClaims(userClaims, request.baseRequest.executorBonusWAD, WAD);
            userClaims.stAssets = userClaims.stAssets - bonusClaims.stAssets;
            userClaims.jtAssets = userClaims.jtAssets - bonusClaims.jtAssets;
            userClaims.ltAssets = userClaims.ltAssets - bonusClaims.ltAssets;
            userClaims.stShares = userClaims.stShares - bonusClaims.stShares;
            userClaims.nav = userClaims.nav - bonusClaims.nav;

            // Transfer bonus and remaining assets to executor and receiver respectively
            _remitClaims(config.kernel, userClaims, bonusClaims, request.baseRequest.receiver);
        }

        // Emit the redemption execution event
        emit RedemptionExecuted(_user, _requestNonce, msg.sender, userSharesRedeemed, forfeitedYieldShares, userClaims, bonusClaims);
    }

    /**
     * @dev Asserts that a request exists and is executable (not executed already or cancelled)
     * @param _requestNonce The nonce of the request being validated
     * @param _executableAtTimestamp The timestamp after which the request can be executed
     */
    function _validateRequestExecution(uint256 _requestNonce, uint256 _executableAtTimestamp) internal view {
        require(_executableAtTimestamp != 0 && _executableAtTimestamp <= block.timestamp, INVALID_REQUEST(_requestNonce));
    }

    /**
     * @dev Deposits assets and routes accrued yield based on the tranche's configuration
     * @param _tranche The tranche to deposit assets into
     * @param _config The enriched tranche configuration
     * @param _assets The amount of assets to deposit into the tranche
     * @param _navAtRequestTime The NAV of the assets being deposited at the time the deposit was requested
     * @param _receiver The address to receive the minted tranche shares
     * @return userTrancheShares The shares actually minted for the user (total minus forfeited)
     * @return forfeitedYieldShares The shares forfeited equating to the yield accrued during the request lifecycle (zero if NAV decreased)
     */
    function _depositWithYieldRouting(
        address _tranche,
        EnrichedTrancheConfig memory _config,
        TRANCHE_UNIT _assets,
        NAV_UNIT _navAtRequestTime,
        address _receiver
    )
        internal
        returns (uint256 userTrancheShares, uint256 forfeitedYieldShares)
    {
        // Approve the tranche to pull the assets being deposited
        IERC20(_config.asset).forceApprove(_tranche, toUint256(_assets));
        // Compute the NAV of the assets being deposited at execution time
        NAV_UNIT navAtExecutionTime = _convertAssetsToNAV(_config.kernel, _config.trancheType, _assets);
        // If no yield accrued on the escrowed assets since placing the request, mint shares directly to the specified receiver
        if (navAtExecutionTime <= _navAtRequestTime) {
            userTrancheShares = IRoycoVaultTranche(_tranche).deposit(_assets, _receiver);
        } else {
            // Mint the shares to the entry point and compute the tranche shares to forfeit for the yield accrued since placing the request
            userTrancheShares = IRoycoVaultTranche(_tranche).deposit(_assets, address(this));
            forfeitedYieldShares =
                _computeDepositForfeiture(_tranche, _config.baseConfig.yieldRecipient, userTrancheShares, _navAtRequestTime, navAtExecutionTime);
            // Transfer the shares the user is entitled to after deducting the forfeited yield shares
            if ((userTrancheShares -= forfeitedYieldShares) != 0) IERC20(_tranche).safeTransfer(_receiver, userTrancheShares);
            // If yield was accrued, handle it using the configured method
            _routeForfeitedYieldShares(_tranche, _config.baseConfig.yieldRecipient, forfeitedYieldShares);
        }
    }

    /**
     * @dev Computes the tranche shares to forfeit from a deposit's mint, equating to the value of the yield accrued since placing the request
     *      Shares forfeited to the protocol are retained, leaving the total supply unchanged, so a proportional split leaves the receiver
     *      with shares worth exactly the NAV at request time
     *      Shares forfeited to the remaining LPs are burned, appreciating the receiver's own shares, so the receiver's share count is
     *      instead solved against the post-burn share price, leaving them shares worth exactly the NAV at request time with no claim on the burn
     * @param _tranche The tranche that the deposit was executed on
     * @param _yieldRecipient The configured recipient of yield accrued during the request lifecycle
     * @param _mintedTrancheShares The tranche shares minted to the entry point upon executing the deposit
     * @param _navAtRequestTime The NAV of the assets being deposited at the time the deposit was requested
     * @param _navAtExecutionTime The NAV of the assets being deposited at execution time (strictly greater than the NAV at request time)
     * @return forfeitedYieldShares The tranche shares to forfeit from the minted shares
     */
    function _computeDepositForfeiture(
        address _tranche,
        AccruedYieldRecipient _yieldRecipient,
        uint256 _mintedTrancheShares,
        NAV_UNIT _navAtRequestTime,
        NAV_UNIT _navAtExecutionTime
    )
        internal
        view
        returns (uint256 forfeitedYieldShares)
    {
        // Pre-existing holders exclude this deposit's mint
        // with none there is no pool to donate a burn to, so the
        // proportional split applies there as well as under PROTOCOL
        uint256 totalTrancheShares = IRoycoVaultTranche(_tranche).totalSupply();
        uint256 preexistingShares = totalTrancheShares - _mintedTrancheShares;
        if (_yieldRecipient == AccruedYieldRecipient.PROTOCOL || preexistingShares == 0) {
            return _mintedTrancheShares.mulDiv((_navAtExecutionTime - _navAtRequestTime), _navAtExecutionTime, Math.Rounding.Floor);
        } else {
            // The pre-existing holders settle at exactly (totalNAV - navAtRequestTime) across their unchanged share count post-burn
            NAV_UNIT totalNAV = IRoycoVaultTranche(_tranche).totalAssets().nav;
            uint256 userTrancheShares = _navAtRequestTime.mulDiv(preexistingShares, (totalNAV - _navAtRequestTime), Math.Rounding.Floor);
            // Clamp so the forfeiture never underflows
            return (userTrancheShares >= _mintedTrancheShares) ? 0 : (_mintedTrancheShares - userTrancheShares);
        }
    }

    /**
     * @dev Redeems shares and routes accrued yield based on the tranche's configuration
     * @param _tranche The tranche to redeem shares from
     * @param _yieldRecipient The configured recipient of yield accrued during the request lifecycle
     * @param _shares The amount of shares to redeem from the tranche
     * @param _navAtRequestTime The NAV of the shares being redeemed at the time the redemption was requested
     * @param _receiver The address to receive the redeemed assets
     * @return userSharesRedeemed The shares actually redeemed for the user (total minus forfeited)
     * @return forfeitedYieldShares The shares forfeited equating to the yield accrued during the request lifecycle (zero if NAV decreased)
     * @return userClaims The assets withdrawn from the tranche for the user after routing yield as configured
     */
    function _redeemWithYieldRouting(
        address _tranche,
        AccruedYieldRecipient _yieldRecipient,
        uint256 _shares,
        NAV_UNIT _navAtRequestTime,
        address _receiver
    )
        internal
        returns (uint256 userSharesRedeemed, uint256 forfeitedYieldShares, AssetClaims memory userClaims)
    {
        // Initialize the user's shares redeemed as the input
        userSharesRedeemed = _shares;
        // Compute the tranche shares equivalent to the value of the yield accrued since placing the request
        NAV_UNIT navAtExecutionTime = IRoycoVaultTranche(_tranche).convertToAssets(_shares).nav;
        if (navAtExecutionTime > _navAtRequestTime) {
            forfeitedYieldShares = _shares.mulDiv((navAtExecutionTime - _navAtRequestTime), navAtExecutionTime, Math.Rounding.Floor);
        }
        // Redeem the shares the user is entitled to after deducting the forfeited yield shares
        userClaims = IRoycoVaultTranche(_tranche).redeem((userSharesRedeemed -= forfeitedYieldShares), _receiver, address(this));
        // If yield was accrued, handle it using the configured method
        _routeForfeitedYieldShares(_tranche, _yieldRecipient, forfeitedYieldShares);
    }

    /**
     * @dev Routes forfeited yield shares to the configured accrued yield recipient (no-op if no yield was accrued)
     * @param _tranche The tranche whose shares were forfeited
     * @param _yieldRecipient The configured recipient of yield accrued during the request lifecycle
     * @param _forfeitedYieldShares The shares forfeited equating to the yield accrued during the request lifecycle
     */
    function _routeForfeitedYieldShares(address _tranche, AccruedYieldRecipient _yieldRecipient, uint256 _forfeitedYieldShares) internal {
        if (_forfeitedYieldShares == 0) return;
        // If accrued yield is sent to the protocol, add them to the protocol accounting
        if (_yieldRecipient == AccruedYieldRecipient.PROTOCOL) {
            _getRoycoDayEntryPointStorage().trancheToProtocolFeeShares[_tranche] += _forfeitedYieldShares;
            emit ProtocolFeeSharesAccrued(_tranche, _forfeitedYieldShares);
        }
        // If accrued yield should be distributed to the remaining LPs, burn the shares, effectively donating the yield to the pool
        else {
            ERC20BurnableUpgradeable(_tranche).burn(_forfeitedYieldShares);
        }
    }

    /**
     * @dev Remits the user's claims and the executor's bonus claims to the receiver and executor respectively
     * @param _kernel The kernel of the market that the redeemed tranche belongs to, used to resolve the claim assets
     * @param _userClaims The asset claims to remit to the receiver
     * @param _bonusClaims The asset claims to remit to the executor (the caller)
     * @param _receiver The address to receive the user's claims
     */
    function _remitClaims(address _kernel, AssetClaims memory _userClaims, AssetClaims memory _bonusClaims, address _receiver) internal {
        // Transfer the ST and JT asset claims to the executor and receiver respectively
        address stAsset = IRoycoDayKernel(_kernel).ST_ASSET();
        address jtAsset = IRoycoDayKernel(_kernel).JT_ASSET();
        if (stAsset == jtAsset) {
            // Batch transfer if same asset
            TRANCHE_UNIT totalBonus = _bonusClaims.stAssets + _bonusClaims.jtAssets;
            TRANCHE_UNIT totalUserAssets = _userClaims.stAssets + _userClaims.jtAssets;
            if (totalBonus != ZERO_TRANCHE_UNITS) IERC20(stAsset).safeTransfer(msg.sender, toUint256(totalBonus));
            if (totalUserAssets != ZERO_TRANCHE_UNITS) IERC20(stAsset).safeTransfer(_receiver, toUint256(totalUserAssets));
        } else {
            // Transfer each asset separately
            if (_bonusClaims.stAssets != ZERO_TRANCHE_UNITS) IERC20(stAsset).safeTransfer(msg.sender, toUint256(_bonusClaims.stAssets));
            if (_bonusClaims.jtAssets != ZERO_TRANCHE_UNITS) IERC20(jtAsset).safeTransfer(msg.sender, toUint256(_bonusClaims.jtAssets));
            if (_userClaims.stAssets != ZERO_TRANCHE_UNITS) IERC20(stAsset).safeTransfer(_receiver, toUint256(_userClaims.stAssets));
            if (_userClaims.jtAssets != ZERO_TRANCHE_UNITS) IERC20(jtAsset).safeTransfer(_receiver, toUint256(_userClaims.jtAssets));
        }
        // Transfer the LT asset claims to the executor and receiver respectively
        if (_bonusClaims.ltAssets != ZERO_TRANCHE_UNITS || _userClaims.ltAssets != ZERO_TRANCHE_UNITS) {
            address ltAsset = IRoycoDayKernel(_kernel).LT_ASSET();
            if (_bonusClaims.ltAssets != ZERO_TRANCHE_UNITS) IERC20(ltAsset).safeTransfer(msg.sender, toUint256(_bonusClaims.ltAssets));
            if (_userClaims.ltAssets != ZERO_TRANCHE_UNITS) IERC20(ltAsset).safeTransfer(_receiver, toUint256(_userClaims.ltAssets));
        }
        // Transfer the senior tranche share claims to the executor and receiver respectively
        if (_bonusClaims.stShares != 0 || _userClaims.stShares != 0) {
            address seniorTranche = IRoycoDayKernel(_kernel).SENIOR_TRANCHE();
            if (_bonusClaims.stShares != 0) IERC20(seniorTranche).safeTransfer(msg.sender, _bonusClaims.stShares);
            if (_userClaims.stShares != 0) IERC20(seniorTranche).safeTransfer(_receiver, _userClaims.stShares);
        }
    }

    /**
     * @dev Converts an amount of a tranche's assets to NAV units using the market kernel's asset quoter for that tranche
     * @param _kernel The kernel of the market that the tranche belongs to
     * @param _trancheType The type of the tranche (senior, junior, or liquidity)
     * @param _assets The amount of assets to convert, denominated in the tranche's base asset units
     * @return nav The NAV of the specified assets, denominated in the kernel's NAV units
     */
    function _convertAssetsToNAV(address _kernel, TrancheType _trancheType, TRANCHE_UNIT _assets) internal view returns (NAV_UNIT nav) {
        if (_trancheType == TrancheType.SENIOR) return IRoycoDayKernel(_kernel).stConvertTrancheUnitsToNAVUnits(_assets);
        else if (_trancheType == TrancheType.JUNIOR) return IRoycoDayKernel(_kernel).jtConvertTrancheUnitsToNAVUnits(_assets);
        else return IRoycoDayKernel(_kernel).ltConvertTrancheUnitsToNAVUnits(_assets);
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
            address tranche = _tranches[i];
            address kernel = _validateTranche(tranche);
            $.trancheToConfig[tranche] = EnrichedTrancheConfig({
                asset: IRoycoVaultTranche(tranche).asset(), kernel: kernel, trancheType: IRoycoVaultTranche(tranche).TRANCHE_TYPE(), baseConfig: _configs[i]
            });
            emit TrancheConfigUpdated(tranche, _configs[i]);
        }
    }

    /// @dev Validates whether a tranche was deployed by the canonical Royco Factory
    /// @param _ostensibleRoycoTranche The ostensibly valid Royco tranche to validate
    /// @return kernel The kernel of the market that the validated tranche belongs to
    function _validateTranche(address _ostensibleRoycoTranche) internal view returns (address kernel) {
        require(_ostensibleRoycoTranche != address(0), NULL_ADDRESS());
        // Get the tranche's kernel from the factory to validate the input tranche was factory-deployed
        kernel = IRoycoFactory(ROYCO_FACTORY).trancheToKernel(_ostensibleRoycoTranche);
        require(kernel != address(0), INVALID_TRANCHE());
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
