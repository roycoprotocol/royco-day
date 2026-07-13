// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AssetClaims, TrancheType } from "../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../libraries/Units.sol";

/**
 * @title IRoycoDayEntryPoint
 * @notice Interface for the RoycoDayEntryPoint contract enabling asynchronous deposit and redemption flows on Royco Tranches
 */
interface IRoycoDayEntryPoint {
    /**
     * @notice Storage state for the Royco entry point
     * @custom:field lastRequestNonce - The last assigned request nonce
     * @custom:field trancheToConfig - A mapping of tranches to their enriched entry point configurations
     * @custom:field userToNonceToDepositRequest - A mapping tracking each user's deposit requests by nonce
     * @custom:field userToNonceToRedemptionRequest - A mapping tracking each user's redemption requests by nonce
     * @custom:field trancheToProtocolFeeShares - A mapping tracking the protocol fee shares accrued for each tranche
     */
    struct RoycoDayEntryPointState {
        uint256 lastRequestNonce;
        mapping(address tranche => EnrichedTrancheConfig config) trancheToConfig;
        mapping(address user => mapping(uint256 requestNonce => DepositRequest request)) userToNonceToDepositRequest;
        mapping(address user => mapping(uint256 requestNonce => RedemptionRequest request)) userToNonceToRedemptionRequest;
        mapping(address tranche => uint256 protocolFeeShares) trancheToProtocolFeeShares;
    }

    /**
     * @notice Defines the recipient of yield accrued during the deposit or redemption delay period
     * @dev Accrued yield is any positive delta between the execution NAV and the NAV at request time for the assets being deposited or the shares being redeemed
     * @dev The requesting LP is never a valid recipient: a queued request that captures its own yield is a free option on stale-oracle NAV, defeating the delay
     * @custom:type PROTOCOL - Accrued yield is sent to the protocol fee recipient
     * @custom:type REMAINING_LPS - Accrued yield stays in the pool for remaining tranche LPs
     */
    enum AccruedYieldRecipient {
        PROTOCOL,
        REMAINING_LPS
    }

    /**
     * @notice Configuration for a tranche on this entry point
     * @custom:field enabled - Whether the tranche is enabled for deposits and redemptions
     * @custom:field yieldRecipient - The recipient of yield accrued during the deposit or redemption delay period
     * @custom:field depositDelaySeconds - The delay in seconds between deposit request and execution
     * @custom:field redemptionDelaySeconds - The delay in seconds between redemption request and execution
     * @custom:field oracleClock - The oracle clock gating execution on at least one observed oracle update after the request (the null address disables the gate)
     */
    struct TrancheConfig {
        bool enabled;
        AccruedYieldRecipient yieldRecipient;
        uint24 depositDelaySeconds;
        uint24 redemptionDelaySeconds;
        address oracleClock;
    }

    /**
     * @notice Enriched configuration containing the tranche's asset, market kernel, tranche type, and base config
     * @custom:field trancheType - The type of the tranche (senior, junior, or liquidity)
     * @custom:field kernel - The kernel of the market that the tranche belongs to
     * @custom:field asset - The underlying asset of the tranche
     * @custom:field baseConfig - The base configuration for the tranche
     */
    struct EnrichedTrancheConfig {
        TrancheType trancheType;
        address kernel;
        address asset;
        TrancheConfig baseConfig;
    }

    /**
     * @notice A pending deposit request
     * @custom:field assets - The amount of assets requested to be deposited
     * @custom:field baseRequest - The base request data shared across request types
     */
    struct DepositRequest {
        TRANCHE_UNIT assets;
        BaseRequest baseRequest;
    }

    /**
     * @notice A pending redemption request
     * @custom:field shares - The amount of escrowed shares pending redemption
     * @custom:field baseRequest - The base request data shared across request types
     */
    struct RedemptionRequest {
        uint256 shares;
        BaseRequest baseRequest;
    }

    /**
     * @notice Base request data shared across deposit and redemption requests
     * @custom:field tranche - The Royco tranche that this request is for
     * @custom:field oracleClockSnapshot - The oracle clock timestamp observed when the request was placed (zero when the tranche had no oracle clock)
     * @custom:field executableAtTimestamp - The timestamp after which the request can be executed
     * @custom:field executorBonusWAD - The bonus percentage (0-100%) paid to third-party executors, scaled to WAD precision
     *                                  Set to type(uint64).max to restrict execution to the request owner only
     * @custom:field receiver - The address that will receive the output assets or shares
     * @custom:field navAtRequestTime - The total NAV of the escrowed assets or shares at request time, used to calculate yield forfeiture on execution
     */
    struct BaseRequest {
        address tranche;
        uint32 oracleClockSnapshot;
        uint32 executableAtTimestamp;
        uint64 executorBonusWAD;
        address receiver;
        NAV_UNIT navAtRequestTime;
    }

    /**
     * @notice Emitted when a user requests a deposit
     * @param user The user requesting the deposit
     * @param nonce The nonce identifying this request
     * @param tranche The tranche for which the deposit was requested
     * @param assets The amount of assets requested to be deposited into the tranche
     * @param executableAtTimestamp The timestamp at which the request can be executed
     * @param executorBonusWAD The bonus percentage offered to executors (type(uint64).max if opted out), scaled to WAD precision
     */
    event DepositRequested(
        address indexed user, uint256 indexed nonce, address indexed tranche, TRANCHE_UNIT assets, uint32 executableAtTimestamp, uint64 executorBonusWAD
    );

    /**
     * @notice Emitted when a deposit request is executed
     * @param user The user whose deposit request was executed
     * @param nonce The nonce identifying the executed request
     * @param executor The address that executed the request (user or executor)
     * @param assetsDeposited The amount of assets deposited into the tranche (after bonus deduction if applicable)
     * @param sharesMinted The amount of tranche shares minted to the receiver (after yield forfeiture if applicable)
     * @param forfeitedYieldShares The shares forfeited equating to the yield accrued during the request lifecycle (zero if NAV decreased)
     * @param bonusAssets The amount of assets paid to the executor as a bonus (0 if self-executed)
     */
    event DepositExecuted(
        address indexed user,
        uint256 indexed nonce,
        address indexed executor,
        TRANCHE_UNIT assetsDeposited,
        uint256 sharesMinted,
        uint256 forfeitedYieldShares,
        TRANCHE_UNIT bonusAssets
    );

    /**
     * @notice Emitted when a deposit request is cancelled
     * @param user The user whose deposit request was cancelled
     * @param nonce The nonce identifying the cancelled request
     * @param receiver The address that received the returned escrowed assets
     * @param assets The amount of assets returned
     */
    event DepositRequestCancelled(address indexed user, uint256 indexed nonce, address receiver, TRANCHE_UNIT assets);

    /**
     * @notice Emitted when a user requests a redemption
     * @param user The user requesting the redemption
     * @param nonce The nonce identifying this request
     * @param tranche The tranche for which the redemption was requested
     * @param shares The amount of shares requested to be redeemed from the tranche
     * @param executableAtTimestamp The timestamp at which the request can be executed
     * @param executorBonusWAD The bonus percentage offered to executors (type(uint64).max if opted out), scaled to WAD precision
     */
    event RedemptionRequested(
        address indexed user, uint256 indexed nonce, address indexed tranche, uint256 shares, uint32 executableAtTimestamp, uint64 executorBonusWAD
    );

    /**
     * @notice Emitted when a redemption request is executed
     * @param user The user whose redemption request was executed
     * @param nonce The nonce identifying the executed request
     * @param executor The address that executed the request (user or executor)
     * @param sharesRedeemed The shares redeemed for the user which equate to the user claims
     * @param forfeitedYieldShares The shares forfeited equating to the yield accrued during the request lifecycle (zero if NAV decreased)
     * @param userClaims The asset claims withdrawn to the receiver
     * @param bonusClaims The asset claims paid to the executor as a bonus (zero if self-executed)
     */
    event RedemptionExecuted(
        address indexed user,
        uint256 indexed nonce,
        address indexed executor,
        uint256 sharesRedeemed,
        uint256 forfeitedYieldShares,
        AssetClaims userClaims,
        AssetClaims bonusClaims
    );

    /**
     * @notice Emitted when a redemption request is cancelled
     * @param user The user whose redemption request was cancelled
     * @param nonce The nonce identifying the cancelled request
     * @param receiver The address that received the returned escrowed shares
     * @param shares The amount of shares returned
     */
    event RedemptionRequestCancelled(address indexed user, uint256 indexed nonce, address receiver, uint256 shares);

    /**
     * @notice Emitted when a tranche's entry point configuration is updated
     * @param tranche The tranche that the configuration was updated for
     * @param config The new tranche configuration
     */
    event TrancheConfigUpdated(address indexed tranche, TrancheConfig config);

    /**
     * @notice Emitted when protocol fee shares are accrued from a deposit's or redemption's accrued yield
     * @param tranche The tranche for which protocol fee shares were accrued
     * @param shares The amount of shares accrued as protocol fees
     */
    event ProtocolFeeSharesAccrued(address indexed tranche, uint256 shares);

    /**
     * @notice Emitted when protocol fee shares are collected
     * @param tranche The tranche from which protocol fee shares were collected
     * @param receiver The address that received the collected shares
     * @param shares The amount of shares collected
     */
    event ProtocolFeeSharesCollected(address indexed tranche, address indexed receiver, uint256 shares);

    /// @dev Thrown when the specified tranche wasn't deployed by the canonical Royco Factory
    error INVALID_TRANCHE();

    /// @dev Thrown when passing a zero amount as input
    error MUST_EXECUTE_NON_ZERO_AMOUNT();

    /// @dev Thrown when the lengths of provided arrays do not match
    error ARRAY_LENGTH_MISMATCH();

    /// @dev Thrown when attempting to request a deposit or redemption for a tranche that is not enabled
    error TRANCHE_NOT_ENABLED();

    /// @dev Thrown when a request does not exist, was already executed/cancelled, or is not yet executable
    error INVALID_REQUEST(uint256 requestNonce);

    /// @dev Thrown when executing a request before the tranche's oracle clock has observed an oracle update after the request was placed
    error ORACLE_CLOCK_NOT_ADVANCED(uint256 requestNonce);

    /// @dev Thrown when the executor bonus is not strictly less than 100% (WAD) and is not the opt-out sentinel value
    error INVALID_EXECUTOR_BONUS();

    /// @dev Thrown when a non-owner attempts to execute a request that has opted out of executor execution
    error THIRD_PARTY_EXECUTION_DISABLED();

    /**
     * @notice Requests a deposit into the tranche, escrowing assets until the delay period elapses and the request is executed
     * @param _tranche The tranche to deposit into
     * @param _assets The amount of underlying assets to deposit, denominated in tranche asset units
     * @param _receiver The address that will receive the minted tranche shares
     * @param _executorBonusWAD The bonus percentage (0-100%), scaled to WAD precision, to pay executors for executing this request (use type(uint64).max to restrict execution to self only)
     * @return requestNonce The unique nonce identifying this deposit request
     * @return executableAtTimestamp The timestamp at which this request can be executed
     */
    function requestDeposit(
        address _tranche,
        TRANCHE_UNIT _assets,
        address _receiver,
        uint64 _executorBonusWAD
    )
        external
        returns (uint256 requestNonce, uint32 executableAtTimestamp);

    /**
     * @notice Executes multiple pending deposit requests across the specified users
     * @param _users The users whose deposit requests should be executed
     * @param _requestNonces The nonces of the deposit requests to execute
     * @param _assetsToDeposit The amounts of assets to deposit for each request (use MAX_TRANCHE_UNITS to deposit min(requestedAssets, maxDeposit))
     * @return trancheSharesMinted The amounts of tranche shares minted for each executed request
     */
    function executeDeposits(
        address[] calldata _users,
        uint256[] calldata _requestNonces,
        TRANCHE_UNIT[] calldata _assetsToDeposit
    )
        external
        returns (uint256[] memory trancheSharesMinted);

    /**
     * @notice Executes a pending deposit request for the specified user
     * @dev The request must exist and the configured delay period must have elapsed
     *      If executed by a third party, the executor bonus is paid in assets before depositing the remainder
     * @param _user The user whose deposit request should be executed
     * @param _requestNonce The nonce of the deposit request to execute
     * @param _assetsToDeposit The amount of assets to deposit (use MAX_TRANCHE_UNITS to deposit the maximum possible)
     * @return trancheSharesMinted The amount of tranche shares minted to the receiver
     */
    function executeDeposit(address _user, uint256 _requestNonce, TRANCHE_UNIT _assetsToDeposit) external returns (uint256 trancheSharesMinted);

    /**
     * @notice Cancels multiple pending deposit requests for the caller, returning escrowed assets
     * @param _requestNonces The nonces of the deposit requests to cancel
     * @param _receiver The address to receive the returned escrowed assets
     */
    function cancelDepositRequests(uint256[] calldata _requestNonces, address _receiver) external;

    /**
     * @notice Cancels a pending deposit request for the caller, returning escrowed assets
     * @param _requestNonce The nonce of the deposit request to cancel
     * @param _receiver The address to receive the returned escrowed assets
     */
    function cancelDepositRequest(uint256 _requestNonce, address _receiver) external;

    /**
     * @notice Requests a redemption from the tranche, escrowing tranche shares until the delay period elapses and the request is executed
     * @param _tranche The tranche to redeem shares from
     * @param _shares The amount of tranche shares to redeem
     * @param _receiver The address that will receive the assets withdrawn upon redemption
     * @param _executorBonusWAD The bonus percentage, scaled to WAD precision, to pay executors for executing this request (use type(uint64).max to opt out of executor execution entirely)
     * @return requestNonce The unique nonce identifying this redemption request
     * @return executableAtTimestamp The timestamp at which this request can be executed
     */
    function requestRedemption(
        address _tranche,
        uint256 _shares,
        address _receiver,
        uint64 _executorBonusWAD
    )
        external
        returns (uint256 requestNonce, uint32 executableAtTimestamp);

    /**
     * @notice Executes multiple pending redemption requests across the specified users
     * @param _users The users whose redemption requests should be executed
     * @param _requestNonces The nonces of the redemption requests to execute
     * @param _sharesToRedeem The amount of shares to redeem for the redemption requests to execute (use type(uint256).max to redeem the maximum possible)
     * @return userClaims The assets withdrawn to the request-specific receiver upon executing each executed request
     */
    function executeRedemptions(
        address[] calldata _users,
        uint256[] calldata _requestNonces,
        uint256[] calldata _sharesToRedeem
    )
        external
        returns (AssetClaims[] memory userClaims);

    /**
     * @notice Executes a pending redemption request for the specified user
     * @dev The request must exist and the configured delay period must have elapsed
     * @param _user The user whose redemption request should be executed
     * @param _requestNonce The nonce of the redemption request to execute
     * @param _sharesToRedeem The amount of shares to redeem (use type(uint256).max to redeem the maximum possible)
     * @return userClaims The assets withdrawn to the request-specific receiver upon executing this redemption request
     */
    function executeRedemption(address _user, uint256 _requestNonce, uint256 _sharesToRedeem) external returns (AssetClaims memory userClaims);

    /**
     * @notice Cancels multiple pending redemption requests for the caller, returning escrowed shares
     * @param _requestNonces The nonces of the redemption requests to cancel
     * @param _receiver The address to receive the returned escrowed shares
     */
    function cancelRedemptionRequests(uint256[] calldata _requestNonces, address _receiver) external;

    /**
     * @notice Cancels a pending redemption request for the caller, returning escrowed shares
     * @param _requestNonce The nonce of the redemption request to cancel
     * @param _receiver The address to receive the returned escrowed shares
     */
    function cancelRedemptionRequest(uint256 _requestNonce, address _receiver) external;

    /**
     * @notice Modifies the entry point configuration for the specified tranches
     * @param _tranches The tranches to modify configurations for
     * @param _configs The new configurations for each tranche
     */
    function modifyTrancheConfigs(address[] calldata _tranches, TrancheConfig[] calldata _configs) external;

    /**
     * @notice Collects accumulated protocol fee shares from the specified tranches
     * @param _tranches The tranches to collect protocol fees from
     * @param _sharesToClaim The amount of protocol fee shares to claim for each tranche (use type(uint256).max to claim all available)
     * @param _receiver The address to receive the collected protocol fee shares
     */
    function collectProtocolFees(address[] calldata _tranches, uint256[] calldata _sharesToClaim, address _receiver) external;

    /// =============================
    /// State Accessor Functions
    /// =============================

    /// @notice Returns the canonical Royco factory used to validate tranche provenance
    /// @return roycoFactory The address of the canonical Royco factory
    function ROYCO_FACTORY() external view returns (address roycoFactory);

    /**
     * @notice Returns the last assigned request nonce
     * @return nonce The last request nonce that was assigned
     */
    function getLastRequestNonce() external view returns (uint256 nonce);

    /**
     * @notice Returns the configuration for a specific tranche
     * @param _tranche The tranche to get configuration for
     * @return config The enriched configuration for the tranche
     */
    function getTrancheConfig(address _tranche) external view returns (EnrichedTrancheConfig memory config);

    /**
     * @notice Returns a deposit request for a specific user and nonce
     * @param _user The user who owns the deposit request
     * @param _requestNonce The nonce of the deposit request
     * @return request The deposit request data
     */
    function getDepositRequest(address _user, uint256 _requestNonce) external view returns (DepositRequest memory request);

    /**
     * @notice Returns a redemption request for a specific user and nonce
     * @param _user The user who owns the redemption request
     * @param _requestNonce The nonce of the redemption request
     * @return request The redemption request data
     */
    function getRedemptionRequest(address _user, uint256 _requestNonce) external view returns (RedemptionRequest memory request);

    /**
     * @notice Returns the accumulated protocol fee shares for a specific tranche
     * @param _tranche The tranche to get protocol fee shares for
     * @return shares The amount of protocol fee shares accumulated for the tranche
     */
    function getProtocolFeeSharesPendingCollection(address _tranche) external view returns (uint256 shares);
}
