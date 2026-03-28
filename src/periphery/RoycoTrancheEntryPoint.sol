// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { RoycoBase } from "../base/RoycoBase.sol";
import { IRoycoFactory } from "../interfaces/IRoycoFactory.sol";
import { IRoycoKernel } from "../interfaces/IRoycoKernel.sol";
import { IRoycoVaultTranche, TrancheType } from "../interfaces/IRoycoVaultTranche.sol";
import { WAD, ZERO_TRANCHE_UNITS } from "../libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toUint256 } from "../libraries/Units.sol";

/**
 * @title RoycoTrancheEntryPoint
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Periphery contract enabling bespoke deposit and redemption flows on Royco Tranches
 */
contract RoycoTrancheEntryPoint is RoycoBase {
    using SafeERC20 for IERC20;

    /// @dev Storage slot for RoycoTrancheEntryPointState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoTrancheEntryPoint")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROYCO_ENTRY_POINT_STORAGE_SLOT = 0x97dbcf4566a2e818822a3079c61056404fedac337d5f1e2910e98e13410bdb00;

    /**
     * @notice Configuration for a tranche on this entry point
     * @custom:field enabled Whether the tranche is enabled for deposits and redemptions
     * @custom:field depositDelaySeconds The delay in seconds between deposit request and execution
     * @custom:field redemptionDelaySeconds The delay in seconds between redemption request and execution
     */
    struct TrancheConfig {
        bool enabled;
        uint24 depositDelaySeconds;
        uint24 redemptionDelaySeconds;
    }

    /**
     * @notice Enriched configuration containing the tranche's asset and base config
     * @custom:field asset The underlying asset of the tranche
     * @custom:field baseConfig The base configuration for the tranche
     */
    struct EnrichedTrancheConfig {
        address asset;
        TrancheConfig baseConfig;
    }

    /**
     * @notice A pending deposit request
     * @custom:field assets The amount of assets to deposit
     * @custom:field baseRequest The base request data shared across request types
     */
    struct DepositRequest {
        TRANCHE_UNIT assets;
        BaseRequest baseRequest;
    }

    /**
     * @notice Base request data shared across deposit and redemption requests
     * @custom:field tranche The tranche the request is for
     * @custom:field receiver The address that will receive the output assets or shares
     * @custom:field executableAtTimestamp The timestamp after which the request can be executed
     * @custom:field executorBonusWAD The bonus percentage paid to executors for executing the request, scaled to WAD precision
     *               Set to type(uint64).max to opt out of executor execution
     */
    struct BaseRequest {
        address tranche;
        address receiver;
        uint32 executableAtTimestamp;
        uint64 executorBonusWAD;
    }

    /**
     * @notice Storage state for the Royco entry point
     * @custom:field lastRequestNonce The last assigned request nonce
     * @custom:field trancheToConfig A mapping of tranches to their enriched entry point configurations
     * @custom:field userToNonceToDepositRequest A mapping tracking each user's deposit requests by nonce
     */
    struct RoycoTrancheEntryPointState {
        uint200 lastRequestNonce;
        mapping(address tranche => EnrichedTrancheConfig config) trancheToConfig;
        mapping(address user => mapping(uint256 requestNonce => DepositRequest depositRequest)) userToNonceToDepositRequest;
    }

    /**
     * @notice Emitted when a user requests a deposit
     * @param user The user requesting the deposit
     * @param nonce The nonce identifying this request
     * @param tranche The tranche for which the deposit was requested
     * @param assets The amount of assets requested to be deposited into the tranche
     * @param executableAtTimestamp The timestamp at which the request can be executed
     */
    event DepositRequested(address indexed user, uint256 indexed nonce, address indexed tranche, TRANCHE_UNIT assets, uint32 executableAtTimestamp);

    /**
     * @notice Emitted when a deposit request is executed
     * @param user The user whose deposit request was executed
     * @param nonce The nonce identifying the executed request
     * @param executor The address that executed the request (user or executor)
     * @param sharesMinted The amount of tranche shares minted to the receiver
     * @param bonusShares The amount of shares paid to the executor as executor bonus (0 if self-executed)
     */
    event DepositExecuted(address indexed user, uint256 indexed nonce, address indexed executor, uint256 sharesMinted, uint256 bonusShares);

    /**
     * @notice Emitted when a deposit request is cancelled
     * @param user The user whose deposit request was cancelled
     * @param nonce The nonce identifying the cancelled request
     * @param receiver The address that received the returned escrowed assets
     * @param assets The amount of assets returned
     */
    event DepositRequestCancelled(address indexed user, uint256 indexed nonce, address receiver, TRANCHE_UNIT assets);

    /**
     * @notice Emitted when a tranche's entry point configuration is updated
     * @param tranche The tranche that the configuration was updated for
     * @param config The new tranche configuration
     */
    event TrancheConfigUpdated(address indexed tranche, TrancheConfig config);

    /// @dev Thrown when the specified tranche wasn't deployed by the canonical Royco Factory
    error INVALID_TRANCHE();

    /// @dev Thrown when requesting to deposit or redeem a zero amount of tranche assets or shares respectively
    error MUST_REQUEST_NON_ZERO_AMOUNT();

    /// @dev Thrown when the number of tranches and configs provided do not match
    error EACH_TRANCHE_MUST_HAVE_A_CONFIG();

    /// @dev Thrown when attempting to request a deposit or redemption for a tranche that is not enabled
    error TRANCHE_NOT_ENABLED();

    /// @dev Thrown when trying to execute a deposit or redemption that does not exist, was already executed, or has been cancelled
    error INVALID_REQUEST(uint256 requestNonce);

    /// @dev Thrown when the executor bonus exceeds 100% (WAD) and is not the opt-out sentinel value
    error INVALID_EXECUTOR_BONUS();

    /// @dev Thrown when a non-owner attempts to execute a request that has opted out of executor execution
    error EXECUTOR_EXECUTION_DISABLED();

    /**
     * @notice Initializes the entry point state
     * @param _roycoFactory The canonical Royco factory responsible for deploying markets and acting as the singleton access manager
     * @param _tranches The tranches to enable for this entry point on initialization
     * @param _configs The configurations for each tranche
     */
    function initialize(address _roycoFactory, address[] calldata _tranches, TrancheConfig[] calldata _configs) external initializer {
        // Initialize the base entry point state
        __RoycoBase_init(_roycoFactory);

        // Initialize the entry point with the initial enabled tranches and their initial configurations
        _modifyTrancheConfigs(_tranches, _configs);
    }

    /// =============================
    /// Entry Point Deposit Functions
    /// =============================

    /**
     * @notice Requests a deposit into the tranche, escrowing assets until the delay period elapses
     * @param _tranche The tranche to deposit into
     * @param _assets The amount of tranche assets to deposit
     * @param _receiver The address that will receive the minted tranche shares
     * @param _executorBonusWAD The bonus percentage (in WAD) to pay executors for executing this request. Use type(uint64).max to disable executor execution entirely
     * @return requestNonce The unique nonce identifying this deposit request
     * @return executableAtTimestamp The timestamp after which this request can be executed
     */
    function requestDeposit(
        address _tranche,
        TRANCHE_UNIT _assets,
        address _receiver,
        uint64 _executorBonusWAD
    )
        external
        whenNotPaused
        restricted
        returns (uint256 requestNonce, uint32 executableAtTimestamp)
    {
        // Validate the deposit request
        require(_assets != ZERO_TRANCHE_UNITS, MUST_REQUEST_NON_ZERO_AMOUNT());
        require(_tranche != address(0) && _receiver != address(0), NULL_ADDRESS());
        require(_executorBonusWAD <= WAD || _executorBonusWAD == type(uint64).max, INVALID_EXECUTOR_BONUS());

        // Ensure that the tranche is enabled on this entry point
        RoycoTrancheEntryPointState storage $ = _getRoycoTrancheEntryPointStorage();
        EnrichedTrancheConfig memory config = $.trancheToConfig[_tranche];
        require(config.baseConfig.enabled, TRANCHE_NOT_ENABLED());

        // Register the user's deposit request with a fresh nonce
        DepositRequest storage userDepositRequest = $.userToNonceToDepositRequest[msg.sender][requestNonce = ++$.lastRequestNonce];
        userDepositRequest.assets = _assets;
        userDepositRequest.baseRequest = BaseRequest({
            tranche: _tranche,
            receiver: _receiver,
            executableAtTimestamp: (executableAtTimestamp = uint32(block.timestamp + config.baseConfig.depositDelaySeconds)),
            executorBonusWAD: _executorBonusWAD
        });

        // Transfer the requested amount of tranche assets into the entrypoint to queue the deposit
        IERC20(config.asset).safeTransferFrom(msg.sender, address(this), toUint256(_assets));

        // Emit the deposit request event
        emit DepositRequested(msg.sender, requestNonce, _tranche, _assets, executableAtTimestamp);
    }

    /**
     * @notice Executes multiple pending deposit requests for the specified user
     * @param _user The user whose deposit requests should be executed
     * @param _requestNonces The nonces of the deposit requests to execute
     * @return trancheSharesMinted The amounts of tranche shares minted for each executed request
     */
    function executeDeposits(address _user, uint256[] calldata _requestNonces) external restricted returns (uint256[] memory trancheSharesMinted) {
        // Execute the user specified deposit requests
        uint256 numRequestsToExecute = _requestNonces.length;
        trancheSharesMinted = new uint256[](numRequestsToExecute);
        for (uint256 i = 0; i < numRequestsToExecute; ++i) {
            trancheSharesMinted[i] = executeDeposit(_user, _requestNonces[i]);
        }
    }

    /**
     * @notice Executes a pending deposit request for the specified user
     * @dev The request must exist and the configured delay period must have elapsed
     * @param _user The user whose deposit request should be executed
     * @param _requestNonce The nonce of the deposit request to execute
     * @return trancheSharesMinted The amount of tranche shares minted to the receiver
     */
    function executeDeposit(address _user, uint256 _requestNonce) public whenNotPaused restricted returns (uint256 trancheSharesMinted) {
        // Retrieve the user's specified deposit request and assert its validity
        RoycoTrancheEntryPointState storage $ = _getRoycoTrancheEntryPointStorage();
        DepositRequest memory userDepositRequest = $.userToNonceToDepositRequest[_user][_requestNonce];
        _validateRequestExecution(_requestNonce, userDepositRequest.baseRequest.executableAtTimestamp);

        // Ensure the tranche is still enabled
        address tranche = userDepositRequest.baseRequest.tranche;
        EnrichedTrancheConfig memory config = $.trancheToConfig[tranche];
        require(config.baseConfig.enabled, TRANCHE_NOT_ENABLED());

        // Mark the request as executed
        delete $.userToNonceToDepositRequest[_user][_requestNonce];

        // Execute the deposit on the underlying tranche
        // Approve the assets to be pulled by the tranche for deposit
        IERC20(config.asset).forceApprove(tranche, toUint256(userDepositRequest.assets));
        uint64 executorBonusWAD = userDepositRequest.baseRequest.executorBonusWAD;
        uint256 bonusShares;

        // If this is a self-deposit or there is no executor bonus configured, mint shares directly to the specified recipient
        if (_user == msg.sender || executorBonusWAD == 0) {
            trancheSharesMinted = IRoycoVaultTranche(tranche).deposit(userDepositRequest.assets, userDepositRequest.baseRequest.receiver);
        }
        // If this is an external execution, compute and remit the executor bonus
        else {
            // Ensure that the user has opted into external execution
            require(executorBonusWAD != type(uint64).max, EXECUTOR_EXECUTION_DISABLED());
            // Mint shares to the entry point
            trancheSharesMinted = IRoycoVaultTranche(tranche).deposit(userDepositRequest.assets, address(this));
            // Compute and transfer executor bonus shares
            bonusShares = Math.mulDiv(trancheSharesMinted, executorBonusWAD, WAD, Math.Rounding.Floor);
            if (bonusShares != 0) IERC20(tranche).safeTransfer(msg.sender, bonusShares);
            // Transfer remainder to receiver
            IERC20(tranche).safeTransfer(userDepositRequest.baseRequest.receiver, (trancheSharesMinted -= bonusShares));
        }

        // Emit the deposit execution event
        emit DepositExecuted(_user, _requestNonce, msg.sender, trancheSharesMinted, bonusShares);
    }

    /**
     * @notice Cancels multiple pending deposit requests for the caller, returning escrowed assets
     * @param _requestNonces The nonces of the deposit requests to cancel
     * @param _receiver The address to receive the returned escrowed assets
     */
    function cancelDepositRequests(uint256[] calldata _requestNonces, address _receiver) external whenNotPaused restricted {
        // Execute the user specified deposit request cancellations
        uint256 numRequestsToCancel = _requestNonces.length;
        for (uint256 i = 0; i < numRequestsToCancel; ++i) {
            cancelDepositRequest(_requestNonces[i], _receiver);
        }
    }

    /**
     * @notice Cancels a pending deposit request for the caller, returning escrowed assets
     * @param _requestNonce The nonce of the deposit request to cancel
     * @param _receiver The address to receive the returned escrowed assets
     */
    function cancelDepositRequest(uint256 _requestNonce, address _receiver) public whenNotPaused restricted {
        // Ensure the receiver isn't null
        require(_receiver != address(0), NULL_ADDRESS());
        // Retrieve the user's specified deposit request and assert that it exists
        RoycoTrancheEntryPointState storage $ = _getRoycoTrancheEntryPointStorage();
        DepositRequest memory userDepositRequest = $.userToNonceToDepositRequest[msg.sender][_requestNonce];
        require(userDepositRequest.assets != ZERO_TRANCHE_UNITS, INVALID_REQUEST(_requestNonce));

        // Mark the request as cancelled
        delete $.userToNonceToDepositRequest[msg.sender][_requestNonce];

        // Return the assets from the cancelled request to the specified receiver
        address asset = $.trancheToConfig[userDepositRequest.baseRequest.tranche].asset;
        IERC20(asset).safeTransfer(_receiver, toUint256(userDepositRequest.assets));

        // Emit the deposit request cancellation event
        emit DepositRequestCancelled(msg.sender, _requestNonce, _receiver, userDepositRequest.assets);
    }

    /// =============================
    /// Entry Point Redemption Functions
    /// =============================

    /// =============================
    /// Admin Functions
    /// =============================

    /**
     * @notice Modifies the entry point configuration for the specified tranches
     * @param _tranches The tranches to modify configurations for
     * @param _configs The new configurations for each tranche
     */
    function modifyTrancheConfigs(address[] calldata _tranches, TrancheConfig[] calldata _configs) public restricted {
        _modifyTrancheConfigs(_tranches, _configs);
    }

    /// =============================
    /// Internal Utility Functions
    /// =============================

    /**
     * @dev Asserts that a request exists and is executable (not executed already or cancelled)
     * @param _requestNonce The nonce of the request being validated
     * @param _executableAtTimestamp The timestamp after which the request can be executed
     */
    function _validateRequestExecution(uint256 _requestNonce, uint256 _executableAtTimestamp) internal view {
        require(_executableAtTimestamp != 0 && _executableAtTimestamp <= block.timestamp, INVALID_REQUEST(_requestNonce));
    }

    /**
     * @dev Modifies the entry point configuration for the specified tranches
     * @param _tranches The tranches to modify configurations for
     * @param _configs The new configurations for each tranche
     */
    function _modifyTrancheConfigs(address[] calldata _tranches, TrancheConfig[] calldata _configs) internal {
        // Ensure that each tranche has a specified config
        uint256 numTranches = _tranches.length;
        require(numTranches == _configs.length, EACH_TRANCHE_MUST_HAVE_A_CONFIG());

        // Ensure that each tranche was deployed by the Royco factory and update their configurations
        RoycoTrancheEntryPointState storage $ = _getRoycoTrancheEntryPointStorage();
        for (uint256 i = 0; i < numTranches; ++i) {
            address tranche = _tranches[i];
            _validateTranche(tranche);
            $.trancheToConfig[tranche] = EnrichedTrancheConfig({ asset: IRoycoVaultTranche(tranche).asset(), baseConfig: _configs[i] });
            emit TrancheConfigUpdated(tranche, _configs[i]);
        }
    }

    /// @dev Validates whether a tranche was deployed by the canonical Royco Factory
    /// @param _ostensibleRoycoTranche The ostensibly valid Royco tranche to validate
    function _validateTranche(address _ostensibleRoycoTranche) internal view {
        require(_ostensibleRoycoTranche != address(0), NULL_ADDRESS());
        // Get the tranche corresponding to the specified tranche and validate that it was deployed by the factory
        address correspondingTranche = IRoycoVaultTranche(_ostensibleRoycoTranche).TRANCHE_TYPE() == TrancheType.SENIOR
            ? IRoycoFactory(authority()).seniorTrancheToJuniorTranche(_ostensibleRoycoTranche)
            : IRoycoFactory(authority()).juniorTrancheToSeniorTranche(_ostensibleRoycoTranche);
        require(correspondingTranche != address(0), INVALID_TRANCHE());
    }

    /**
     * @notice Returns a storage pointer to the RoycoTrancheEntryPointState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer to the kernel's state
     */
    function _getRoycoTrancheEntryPointStorage() internal pure returns (RoycoTrancheEntryPointState storage $) {
        assembly ("memory-safe") {
            $.slot := ROYCO_ENTRY_POINT_STORAGE_SLOT
        }
    }
}
