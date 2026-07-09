// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title IRoycoBlacklist
/// @notice Interface for the RoycoBlacklist contract that manages account blacklisting and sanctions screening for a Royco market
interface IRoycoBlacklist {
    /**
     * @notice Storage state for the Royco blacklist
     * @custom:storage-location erc7201:Royco.storage.RoycoBlacklistState
     * @custom:field chainalysisSanctionsList - The Chainalysis maintained sanctions list used to screen accounts (the null address if unused)
     * @custom:field accountToIsBlacklisted - A mapping of accounts to a boolean indicating if they are locally blacklisted
     */
    struct RoycoBlacklistState {
        address chainalysisSanctionsList;
        mapping(address account => bool isBlacklisted) accountToIsBlacklisted;
    }

    /// @notice Emitted when an account is blacklisted
    /// @param account The address of the account
    event AccountBlacklisted(address indexed account);

    /// @notice Emitted when an account is unblacklisted
    /// @param account The address of the account
    event AccountUnblacklisted(address indexed account);

    /// @notice Emitted when the Chainalysis sanctions list is updated
    /// @param chainalysisSanctionsList The new Chainalysis sanctions list address (the null address if unused)
    event SanctionsListUpdated(address chainalysisSanctionsList);

    /// @notice Thrown when the specified account is blacklisted
    error ACCOUNT_BLACKLISTED(address account);

    /**
     * @notice Blacklists the specified addresses from holding or transferring Royco tranche shares
     * @dev Idempotent: blacklisting an already-blacklisted account is a no-op (still emits AccountBlacklisted)
     * @param _accounts The addresses of the accounts to blacklist
     */
    function blacklistAccounts(address[] calldata _accounts) external;

    /**
     * @notice Unblacklists the specified addresses from holding or transferring Royco tranche shares
     * @dev Idempotent: unblacklisting a non-blacklisted account is a no-op (still emits AccountUnblacklisted)
     * @param _accounts The addresses of the accounts to unblacklist
     */
    function unblacklistAccounts(address[] calldata _accounts) external;

    /**
     * @notice Checks if the specified account is blacklisted
     * @dev Returns true if the account is locally blacklisted, included in the configured Chainalysis sanctions designation, or flagged by the exogenous blacklist check
     * @param _account The address of the account to check
     * @return blacklisted Whether the account is blacklisted
     */
    function isBlacklisted(address _account) external view returns (bool blacklisted);

    /**
     * @notice Reverts if the specified account is blacklisted
     * @dev Reverts if the account is locally blacklisted, included in the configured Chainalysis sanctions designation, or flagged by the exogenous blacklist check
     * @param _account The address of the account to enforce against the blacklist
     */
    function enforceNotBlacklisted(address _account) external view;

    /**
     * @notice Reverts if any of the specified accounts is blacklisted
     * @dev Reverts if an account is locally blacklisted, included in the configured Chainalysis sanctions designation, or flagged by the exogenous blacklist check
     * @dev The null address is skipped so callers can pass sentinel mint/redeem counterparties without special casing
     * @param _accounts The addresses of the accounts to enforce against the blacklist
     */
    function enforceNotBlacklisted(address[] memory _accounts) external view;

    /// @notice Sets the Chainalysis sanctions list used to screen accounts
    /// @param _chainalysisSanctionsList The Chainalysis maintained sanctions list address (set to the null address to disable sanctions screening)
    function setSanctionsList(address _chainalysisSanctionsList) external;

    /// @notice Returns the Chainalysis sanctions list used to screen accounts
    /// @return chainalysisSanctionsList The configured Chainalysis sanctions list address (the null address if unused)
    function getSanctionsList() external view returns (address chainalysisSanctionsList);
}
