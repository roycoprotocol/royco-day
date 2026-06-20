// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoBase } from "../base/RoycoBase.sol";
import { IRoycoBlacklist } from "../interfaces/IRoycoBlacklist.sol";
import { ISanctionsList } from "../interfaces/external/chainalysis/ISanctionsList.sol";

/**
 * @title RoycoBlacklist
 * @author Waymont
 * @notice Manages account blacklisting and Chainalysis sanctions screening for a Royco market
 * @notice Queried by kernels for any operations involving preview or state mutating asset transfers between accounts
 */
contract RoycoBlacklist is IRoycoBlacklist, RoycoBase {
    /// @dev Storage slot for RoycoBlacklistState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoBlacklistState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROYCO_BLACKLIST_STORAGE_SLOT = 0x9cdd7566a2b8c3aa6c16fbea0646d47b549e37af578fc5d5261a1bd123401800;

    // =============================
    // Initialization Functions
    // =============================

    /**
     * @notice Initializes the Royco blacklist state
     * @param _initialAuthority The initial authority for the Royco market's blacklist
     * @param _chainalysisSanctionsList The Chainalysis maintained sanctions list for addresses (set to the null address if unused)
     * @param _blacklistedAccounts The initial accounts to blacklist
     */
    function initialize(address _initialAuthority, address _chainalysisSanctionsList, address[] calldata _blacklistedAccounts) external initializer {
        // Initialize the base state of the blacklist
        __RoycoBase_init(_initialAuthority);

        // Set the initial Chainalysis sanctions list
        RoycoBlacklistState storage $ = _getRoycoBlacklistStorage();
        $.chainalysisSanctionsList = _chainalysisSanctionsList;
        emit SanctionsListUpdated(_chainalysisSanctionsList);

        // Blacklist the initially specified accounts. This writes storage directly rather than calling the
        // `restricted` blacklistAccounts: during initialization the deployer holds no role and the blacklist's
        // function-roles are not yet wired on the authority, so the restricted modifier would revert the deploy.
        for (uint256 i = 0; i < _blacklistedAccounts.length; ++i) {
            address account = _blacklistedAccounts[i];
            require(account != address(0), NULL_ADDRESS());
            $.accountToIsBlacklisted[account] = true;
            emit AccountBlacklisted(account);
        }
    }

    // =============================
    // Blacklist Mutation Functions
    // =============================

    /// @inheritdoc IRoycoBlacklist
    function blacklistAccounts(address[] calldata _accounts) public override(IRoycoBlacklist) restricted {
        RoycoBlacklistState storage $ = _getRoycoBlacklistStorage();
        for (uint256 i = 0; i < _accounts.length; ++i) {
            address account = _accounts[i];
            require(account != address(0), NULL_ADDRESS());
            $.accountToIsBlacklisted[account] = true;
            emit AccountBlacklisted(account);
        }
    }

    /// @inheritdoc IRoycoBlacklist
    function unblacklistAccounts(address[] calldata _accounts) external override(IRoycoBlacklist) restricted {
        RoycoBlacklistState storage $ = _getRoycoBlacklistStorage();
        for (uint256 i = 0; i < _accounts.length; ++i) {
            address account = _accounts[i];
            require(account != address(0), NULL_ADDRESS());
            $.accountToIsBlacklisted[account] = false;
            emit AccountUnblacklisted(account);
        }
    }

    // =============================
    // Blacklist Query Functions
    // =============================

    /// @inheritdoc IRoycoBlacklist
    function isBlacklisted(address _account) public view override(IRoycoBlacklist) returns (bool) {
        // An account is blacklisted if it is locally blacklisted or screened by the configured Chainalysis sanctions list
        if (_account == address(0)) return false;
        return _getRoycoBlacklistStorage().accountToIsBlacklisted[_account] || _isSanctioned(_account);
    }

    /// @inheritdoc IRoycoBlacklist
    function enforceNotBlacklisted(address _account) public view override(IRoycoBlacklist) {
        require(!isBlacklisted(_account), ACCOUNT_BLACKLISTED(_account));
    }

    /// @inheritdoc IRoycoBlacklist
    function enforceNotBlacklisted(address[] memory _accounts) external view override(IRoycoBlacklist) {
        uint256 numChecks = _accounts.length;
        for (uint256 i = 0; i < numChecks; ++i) {
            enforceNotBlacklisted(_accounts[i]);
        }
    }

    // =============================
    // Sanctions List Functions
    // =============================

    /// @inheritdoc IRoycoBlacklist
    function setSanctionsList(address _chainalysisSanctionsList) external override(IRoycoBlacklist) restricted {
        _getRoycoBlacklistStorage().chainalysisSanctionsList = _chainalysisSanctionsList;
        emit SanctionsListUpdated(_chainalysisSanctionsList);
    }

    /// @inheritdoc IRoycoBlacklist
    function getSanctionsList() external view override(IRoycoBlacklist) returns (address chainalysisSanctionsList) {
        return _getRoycoBlacklistStorage().chainalysisSanctionsList;
    }

    /**
     * @notice Checks if the specified account is screened by the configured Chainalysis sanctions list
     * @dev Returns false when no sanctions list is configured (the null address)
     * @param _account The address of the account to screen
     * @return sanctioned Whether the account is included in the configured Chainalysis sanctions designation
     */
    function _isSanctioned(address _account) internal view returns (bool sanctioned) {
        address sanctionsList = _getRoycoBlacklistStorage().chainalysisSanctionsList;
        return sanctionsList != address(0) && ISanctionsList(sanctionsList).isSanctioned(_account);
    }

    // =============================
    // Blacklist State Accessor Functions
    // =============================

    /**
     * @notice Returns a storage pointer to the RoycoBlacklistState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer to the blacklist's state
     */
    function _getRoycoBlacklistStorage() private pure returns (RoycoBlacklistState storage $) {
        assembly ("memory-safe") {
            $.slot := ROYCO_BLACKLIST_STORAGE_SLOT
        }
    }
}
