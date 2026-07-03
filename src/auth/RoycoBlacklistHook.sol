// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IAccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { RoycoBase } from "../base/RoycoBase.sol";
import { IRoycoBlacklistHook } from "../interfaces/IRoycoBlacklistHook.sol";
import { IRoycoTrancheHook } from "../interfaces/IRoycoTrancheHook.sol";
import { IRoycoVaultTranche } from "../interfaces/IRoycoVaultTranche.sol";
import { ISanctionsList } from "../interfaces/external/chainalysis/ISanctionsList.sol";

/**
 * @title RoycoBlacklistHook
 * @author Waymont
 * @notice Manages account blacklisting and Chainalysis sanctions screening for Royco markets, and serves as the tranche
 *         balance-update hook: on every tranche transfer/mint/burn it screens the involved accounts against the blacklist
 *         and enforces the tranche's transfer whitelist. Shared per chain and wired to each market's tranches.
 */
contract RoycoBlacklistHook is IRoycoBlacklistHook, RoycoBase {
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
     * @param _accounts The initial accounts to blacklist
     */
    function initialize(address _initialAuthority, address _chainalysisSanctionsList, address[] calldata _accounts) external initializer {
        // Initialize the base state of the blacklist
        __RoycoBase_init(_initialAuthority);

        // Set the initial Chainalysis sanctions list
        _setSanctionsList(_chainalysisSanctionsList);
        // Blacklist the initially specified accounts
        _blacklistAccounts(_accounts);
    }

    // =============================
    // Blacklist Mutation Functions
    // =============================

    /// @inheritdoc IRoycoBlacklistHook
    function blacklistAccounts(address[] calldata _accounts) public override(IRoycoBlacklistHook) restricted {
        _blacklistAccounts(_accounts);
    }

    /// @inheritdoc IRoycoBlacklistHook
    function unblacklistAccounts(address[] calldata _accounts) external override(IRoycoBlacklistHook) restricted {
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

    /// @inheritdoc IRoycoBlacklistHook
    function isBlacklisted(address _account) public view override(IRoycoBlacklistHook) returns (bool) {
        // An account is blacklisted if it is locally blacklisted or screened by the configured Chainalysis sanctions list
        if (_account == address(0)) return false;
        return (_getRoycoBlacklistStorage().accountToIsBlacklisted[_account] || _isSanctioned(_account));
    }

    /// @inheritdoc IRoycoBlacklistHook
    function enforceNotBlacklisted(address _account) public view override(IRoycoBlacklistHook) {
        require(!isBlacklisted(_account), ACCOUNT_BLACKLISTED(_account));
    }

    /// @inheritdoc IRoycoBlacklistHook
    function enforceNotBlacklisted(address[] memory _accounts) external view override(IRoycoBlacklistHook) {
        uint256 numChecks = _accounts.length;
        for (uint256 i = 0; i < numChecks; ++i) {
            enforceNotBlacklisted(_accounts[i]);
        }
    }

    // =============================
    // Tranche Balance-Update Hook
    // =============================

    /// @inheritdoc IRoycoTrancheHook
    function preTrancheBalanceUpdateHook(address _caller, address _from, address _to, bool _enforceWhitelist) external view override(IRoycoTrancheHook) {
        // Screen the involved accounts against the blacklist (the null address is skipped inside isBlacklisted)
        enforceNotBlacklisted(_caller);
        enforceNotBlacklisted(_from);
        enforceNotBlacklisted(_to);

        // If transferring shares and the calling tranche enforces its whitelist, the recipient must be a whitelisted LP for that tranche
        if (_to != address(0) && _enforceWhitelist) {
            // The hook shares the market's AccessManager; msg.sender is the calling tranche
            address am = authority();
            (bool isWhitelistedTrancheLP,) = IAccessManager(am).canCall(_to, msg.sender, IRoycoVaultTranche.deposit.selector);
            require(_to != am && isWhitelistedTrancheLP, ACCOUNT_NOT_WHITELISTED_TRANCHE_LP(_to));
        }
    }

    // =============================
    // Sanctions List Functions
    // =============================

    /// @inheritdoc IRoycoBlacklistHook
    function setSanctionsList(address _chainalysisSanctionsList) external override(IRoycoBlacklistHook) restricted {
        _setSanctionsList(_chainalysisSanctionsList);
    }

    /// @inheritdoc IRoycoBlacklistHook
    function getSanctionsList() external view override(IRoycoBlacklistHook) returns (address chainalysisSanctionsList) {
        return _getRoycoBlacklistStorage().chainalysisSanctionsList;
    }

    // =============================
    // Internal Utility Functions
    // =============================

    /**
     * @notice Blacklists the specified addresses from holding or transferring Royco tranche shares
     * @dev Idempotent: blacklisting an already-blacklisted account is a no-op (still emits AccountBlacklisted)
     * @param _accounts The addresses of the accounts to blacklist
     */
    function _blacklistAccounts(address[] calldata _accounts) internal {
        RoycoBlacklistState storage $ = _getRoycoBlacklistStorage();
        for (uint256 i = 0; i < _accounts.length; ++i) {
            address account = _accounts[i];
            require(account != address(0), NULL_ADDRESS());
            $.accountToIsBlacklisted[account] = true;
            emit AccountBlacklisted(account);
        }
    }

    /// @notice Sets the Chainalysis sanctions list used to screen accounts
    /// @param _chainalysisSanctionsList The Chainalysis maintained sanctions list address (set to the null address to disable sanctions screening)
    function _setSanctionsList(address _chainalysisSanctionsList) internal {
        _getRoycoBlacklistStorage().chainalysisSanctionsList = _chainalysisSanctionsList;
        emit SanctionsListUpdated(_chainalysisSanctionsList);
    }

    /**
     * @notice Checks if the specified account is screened by the configured Chainalysis sanctions list
     * @dev Returns false when no sanctions list is configured (the null address)
     * @param _account The address of the account to screen
     * @return sanctioned Whether the account is included in the configured Chainalysis sanctions designation
     */
    function _isSanctioned(address _account) internal view returns (bool sanctioned) {
        address sanctionsList = _getRoycoBlacklistStorage().chainalysisSanctionsList;
        return (sanctionsList != address(0) && ISanctionsList(sanctionsList).isSanctioned(_account));
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
