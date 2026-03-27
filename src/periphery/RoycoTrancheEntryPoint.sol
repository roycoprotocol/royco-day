// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { RoycoBase } from "../base/RoycoBase.sol";
import { IRoycoFactory } from "../interfaces/IRoycoFactory.sol";
import { IRoycoKernel } from "../interfaces/IRoycoKernel.sol";
import { IRoycoVaultTranche, TrancheType } from "../interfaces/IRoycoVaultTranche.sol";
import { ZERO_TRANCHE_UNITS } from "../libraries/Constants.sol";
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

    /// @notice The Royco tranche that this entry point is configured for
    address public immutable ROYCO_TRANCHE;

    /// @notice The input asset of the Royco tranche that this entry point is configured for
    address private immutable ROYCO_TRANCHE_ASSET;

    struct DepositRequest {
        TRANCHE_UNIT assets;
        uint40 executableAtTimestamp;
    }

    /// @notice Storage state for the Royco entry point
    /// @custom:field userToNonceToExecValidityTimestamp - A mapping tracking the timestamp that each users' requests are executable at
    struct RoycoTrancheEntryPointState {
        uint200 lastRequestNonce;
        uint24 depositDelaySeconds;
        uint24 redemptionDelaySeconds;
        mapping(address user => mapping(uint256 requestNonce => DepositRequest depositRequest)) userToNonceToDepositRequest;
    }

    /**
     * @notice Emitted when a user requests a deposit
     * @param user The user requesting the deposit
     * @param nonce The nonce identifying this request
     * @param assets The amount of assets requested to be deposited
     * @param executableAtTimestamp The timestamp at which the request can be executed
     */
    event DepositRequested(address indexed user, uint256 indexed nonce, TRANCHE_UNIT assets, uint40 executableAtTimestamp);

    /**
     * @notice Emitted when a deposit request is executed
     * @param user The user requesting the deposit
     * @param nonce The nonce identifying the executed request
     * @param sharesMinted The amount of tranche shares minted to the depositor
     */
    event DepositExecuted(address indexed user, uint256 indexed nonce, uint256 sharesMinted);

    /**
     * @notice Emitted when a deposit request is cancelled
     * @param user The user whose deposit request was cancelled
     * @param nonce The nonce identifying the cancelled request
     * @param receiver The address that received the returned escrowed assets
     * @param assets The amount of assets returned
     */
    event DepositRequestCancelled(address indexed user, uint256 indexed nonce, address receiver, TRANCHE_UNIT assets);

    /// @notice Emitted when the deposit delay is updated for a kernel
    /// @param depositDelaySeconds The new deposit delay in seconds
    event DepositDelayUpdated(uint24 depositDelaySeconds);

    /// @notice Emitted when the redemption delay is updated for a kernel
    /// @param redemptionDelaySeconds The new redemption delay in seconds
    event RedemptionDelayUpdated(uint24 redemptionDelaySeconds);

    /// @dev Thrown when the specified tranche wasn't deployed by the canonical Royco Factory
    error INVALID_TRANCHE();

    /// @dev Thrown when requesting to deposit or redeem a zero amount of tranche assets or shares respectively
    error MUST_REQUEST_NON_ZERO_AMOUNT();

    /// @dev Thrown when trying to execute a deposit or redemption that does not exist, was already executed, or has been cancelled
    error INVALID_REQUEST(uint256 requestNonce);

    /**
     * @notice Constructs the entry point state
     * @param _roycoTranche The Royco tranche that this entry point is configured for
     */
    constructor(address _roycoTranche) {
        // Validate and set the immutable state of this entry point
        require(_roycoTranche != address(0), NULL_ADDRESS());
        ROYCO_TRANCHE = _roycoTranche;
        ROYCO_TRANCHE_ASSET = IRoycoVaultTranche(_roycoTranche).asset();
    }

    /**
     * @notice Initializes the entry point state
     * @param _roycoFactory The canonical Royco factory responsible for deploying markets and acting as the singleton access manager
     * @param _depositDelaySeconds The deposit delay between request and execution employed by this entry point in seconds
     * @param _redemptionDelaySeconds The redemption delay between request and execution employed by this entry point in seconds
     */
    function initialize(address _roycoFactory, uint24 _depositDelaySeconds, uint24 _redemptionDelaySeconds) external initializer {
        // Get the tranche corresponding to this entry point's tranche and validate that it was deployed by the factory
        address correspondingTranche = IRoycoVaultTranche(ROYCO_TRANCHE).TRANCHE_TYPE() == TrancheType.SENIOR
            ? IRoycoFactory(_roycoFactory).seniorTrancheToJuniorTranche(ROYCO_TRANCHE)
            : IRoycoFactory(_roycoFactory).juniorTrancheToSeniorTranche(ROYCO_TRANCHE);
        require(correspondingTranche != address(0), INVALID_TRANCHE());

        // Initialize the base entry point state
        __RoycoBase_init(_roycoFactory);

        // Initialize the entry point with the specified initial configuration
        RoycoTrancheEntryPointState storage $ = _getRoycoTrancheEntryPointStorage();
        $.depositDelaySeconds = _depositDelaySeconds;
        emit DepositDelayUpdated(_depositDelaySeconds);
        $.redemptionDelaySeconds = _redemptionDelaySeconds;
        emit RedemptionDelayUpdated(_redemptionDelaySeconds);

        // Extend a one-time maximum approval to the tranche for pulling assets on deposit
        IERC20(ROYCO_TRANCHE_ASSET).forceApprove(ROYCO_TRANCHE, type(uint256).max);
    }

    /// =============================
    /// Entry Point Deposit Functions
    /// =============================

    /**
     * @notice Requests a deposit into the tranche, escrowing assets until the delay period elapses
     * @param _assets The amount of tranche assets to deposit
     * @return requestNonce The unique nonce identifying this deposit request
     * @return executableAtTimestamp The timestamp after which this request can be executed
     */
    function requestDeposit(TRANCHE_UNIT _assets) external restricted returns (uint256 requestNonce, uint40 executableAtTimestamp) {
        // Ensure that the deposit request isn't for zero tranche assets
        require(_assets != ZERO_TRANCHE_UNITS, MUST_REQUEST_NON_ZERO_AMOUNT());

        // Transfer the requested amount of tranche assets into the entrypoint to queue the deposit
        IERC20(ROYCO_TRANCHE_ASSET).safeTransferFrom(msg.sender, address(this), toUint256(_assets));

        // Retrieve this deposit request's nonce by preincrementing the last request nonce
        RoycoTrancheEntryPointState storage $ = _getRoycoTrancheEntryPointStorage();
        requestNonce = ++$.lastRequestNonce;

        // Register the user's deposit request
        DepositRequest storage userDepositRequest = $.userToNonceToDepositRequest[msg.sender][requestNonce];
        userDepositRequest.assets = _assets;
        userDepositRequest.executableAtTimestamp = executableAtTimestamp = uint40(block.timestamp + $.depositDelaySeconds);

        // Emit the deposit request event
        emit DepositRequested(msg.sender, requestNonce, _assets, executableAtTimestamp);
    }

    /**
     * @notice Executes multiple pending deposit requests for the caller
     * @param _requestNonces The nonces of the deposit requests to execute
     * @return trancheSharesMinted The amounts of tranche shares minted for each executed request
     */
    function executeDeposits(uint256[] calldata _requestNonces) external restricted returns (uint256[] memory trancheSharesMinted) {
        // Execute the user specified deposit requests
        uint256 numRequestsToExecute = _requestNonces.length;
        trancheSharesMinted = new uint256[](numRequestsToExecute);
        for (uint256 i = 0; i < numRequestsToExecute; ++i) {
            trancheSharesMinted[i] = executeDeposit(_requestNonces[i]);
        }
    }

    /**
     * @notice Executes a pending deposit request for the caller
     * @dev The request must exist and the configured delay period must have elapsed
     * @param _requestNonce The nonce of the deposit request to execute
     * @return trancheSharesMinted The amount of tranche shares minted to the caller
     */
    function executeDeposit(uint256 _requestNonce) public restricted returns (uint256 trancheSharesMinted) {
        // Retrieve the user's specified deposit request and assert its validity
        RoycoTrancheEntryPointState storage $ = _getRoycoTrancheEntryPointStorage();
        DepositRequest memory userDepositRequest = $.userToNonceToDepositRequest[msg.sender][_requestNonce];
        _assertRequestValidity(_requestNonce, userDepositRequest.executableAtTimestamp);

        // Mark the request as executed
        delete $.userToNonceToDepositRequest[msg.sender][_requestNonce];

        // Execute the deposit on the underlying tranche
        trancheSharesMinted = IRoycoVaultTranche(ROYCO_TRANCHE).deposit(userDepositRequest.assets, msg.sender);

        // Emit the deposit execution event
        emit DepositExecuted(msg.sender, _requestNonce, trancheSharesMinted);
    }

    /**
     * @notice Cancels multiple pending deposit requests for the caller, returning escrowed assets
     * @param _requestNonces The nonces of the deposit requests to cancel
     * @param _receiver The address to receive the returned escrowed assets
     */
    function cancelDepositRequests(uint256[] calldata _requestNonces, address _receiver) external restricted {
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
    function cancelDepositRequest(uint256 _requestNonce, address _receiver) public restricted {
        // Ensure the receiver isn't null
        require(_receiver != address(0), NULL_ADDRESS());
        // Retrieve the user's specified deposit request and assert that it exists
        RoycoTrancheEntryPointState storage $ = _getRoycoTrancheEntryPointStorage();
        DepositRequest memory userDepositRequest = $.userToNonceToDepositRequest[msg.sender][_requestNonce];
        require(userDepositRequest.assets != ZERO_TRANCHE_UNITS, INVALID_REQUEST(_requestNonce));

        // Mark the request as cancelled
        delete $.userToNonceToDepositRequest[msg.sender][_requestNonce];

        // Return the assets from the cancelled request to the specified receiver
        IERC20(ROYCO_TRANCHE_ASSET).safeTransfer(_receiver, toUint256(userDepositRequest.assets));

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
     * @notice Updates the deposit delay for this entry point
     * @param _depositDelaySeconds The new deposit delay between request and execution employed by this entry point in seconds
     */
    function setDepositDelay(uint24 _depositDelaySeconds) external restricted {
        _getRoycoTrancheEntryPointStorage().depositDelaySeconds = _depositDelaySeconds;
        emit DepositDelayUpdated(_depositDelaySeconds);
    }

    /**
     * @notice Updates the redemption delay for this entry point
     * @param _redemptionDelaySeconds The new redemption delay between request and execution employed by this entry point in seconds
     */
    function setRedemptionDelay(uint24 _redemptionDelaySeconds) external restricted {
        _getRoycoTrancheEntryPointStorage().redemptionDelaySeconds = _redemptionDelaySeconds;
        emit RedemptionDelayUpdated(_redemptionDelaySeconds);
    }

    /// =============================
    /// Internal Utility Functions
    /// =============================

    /**
     * @dev Asserts that a request exists and is executable (not executed already or cancelled)
     * @param _requestNonce The nonce of the request being validated
     * @param _executableAtTimestamp The timestamp after which the request can be executed
     */
    function _assertRequestValidity(uint256 _requestNonce, uint256 _executableAtTimestamp) internal view { }

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
