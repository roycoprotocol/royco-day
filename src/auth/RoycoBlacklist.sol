// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { Ownable } from "../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import { Ownable2Step } from "../../lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import { IRoycoBlacklist } from "../interfaces/IRoycoBlacklist.sol";
import { ISanctionsList } from "../interfaces/external/chainalysis/ISanctionsList.sol";

/**
 * @title RoycoBlacklist
 * @author Shivaansh Kapoor, Ankur Dubey, Tomer Ganor
 * @notice Manages account blacklisting and Chainalysis sanctions screening for a Royco market
 * @notice Queried by the market's kernel for any operations involving preview or state-mutating asset transfers between accounts
 */
contract RoycoBlacklist is Ownable2Step, IRoycoBlacklist {
    /// @notice The Chainalysis maintained sanctions list used to screen accounts (the null address if unused)
    address private _chainalysisSanctionsList;

    /// @notice Accounts locally blacklisted from holding or transferring this market's tranche shares
    mapping(address account => bool isBlacklisted) private _accountToIsBlacklisted;

    /**
     * @notice Deploys the market's blacklist under the given owner
     * @param _owner The account granted ownership of the blacklist's mutation surface (blacklist/unblacklist/sanctions)
     * @param _chainalysisSanctionsListAddress The Chainalysis maintained sanctions list for addresses (the null address if unused)
     * @param _accounts The initial accounts to blacklist
     */
    constructor(address _owner, address _chainalysisSanctionsListAddress, address[] memory _accounts) Ownable(_owner) {
        _setSanctionsList(_chainalysisSanctionsListAddress);
        _blacklistAccounts(_accounts);
    }

    // =============================
    // Blacklist Mutation Functions
    // =============================

    /// @inheritdoc IRoycoBlacklist
    function blacklistAccounts(address[] calldata _accounts) public override(IRoycoBlacklist) onlyOwner {
        _blacklistAccounts(_accounts);
    }

    /// @inheritdoc IRoycoBlacklist
    function unblacklistAccounts(address[] calldata _accounts) external override(IRoycoBlacklist) onlyOwner {
        for (uint256 i = 0; i < _accounts.length; ++i) {
            address account = _accounts[i];
            require(account != address(0), NULL_ADDRESS());
            _accountToIsBlacklisted[account] = false;
            emit AccountUnblacklisted(account);
        }
    }

    // =============================
    // Blacklist Query Functions
    // =============================

    /// @inheritdoc IRoycoBlacklist
    function isBlacklisted(address _account) public view override(IRoycoBlacklist) returns (bool) {
        // An account is blacklisted if it is locally blacklisted, screened by the configured Chainalysis sanctions list, or flagged by the exogenous blacklist check
        if (_account == address(0)) return false;
        return (_accountToIsBlacklisted[_account] || _isSanctioned(_account) || _isExogenouslyBlacklisted(_account));
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
    function setSanctionsList(address _chainalysisSanctionsListAddress) external override(IRoycoBlacklist) onlyOwner {
        _setSanctionsList(_chainalysisSanctionsListAddress);
    }

    /// @inheritdoc IRoycoBlacklist
    function getSanctionsList() external view override(IRoycoBlacklist) returns (address chainalysisSanctionsList) {
        return _chainalysisSanctionsList;
    }

    // =============================
    // Internal Utility Functions
    // =============================

    /**
     * @notice Blacklists the specified addresses from holding or transferring Royco tranche shares
     * @dev Idempotent: blacklisting an already-blacklisted account is a no-op (still emits AccountBlacklisted)
     * @param _accounts The addresses of the accounts to blacklist
     */
    function _blacklistAccounts(address[] memory _accounts) internal {
        for (uint256 i = 0; i < _accounts.length; ++i) {
            address account = _accounts[i];
            require(account != address(0), NULL_ADDRESS());
            _accountToIsBlacklisted[account] = true;
            emit AccountBlacklisted(account);
        }
    }

    /// @notice Sets the Chainalysis sanctions list used to screen accounts
    /// @param _chainalysisSanctionsListAddress The Chainalysis maintained sanctions list address (set to the null address to disable sanctions screening)
    function _setSanctionsList(address _chainalysisSanctionsListAddress) internal {
        _chainalysisSanctionsList = _chainalysisSanctionsListAddress;
        emit SanctionsListUpdated(_chainalysisSanctionsListAddress);
    }

    /**
     * @notice Checks if the specified account is screened by the configured Chainalysis sanctions list
     * @dev Returns false when no sanctions list is configured (the null address)
     * @param _account The address of the account to screen
     * @return sanctioned Whether the account is included in the configured Chainalysis sanctions designation
     */
    function _isSanctioned(address _account) internal view returns (bool sanctioned) {
        address sanctionsList = _chainalysisSanctionsList;
        return (sanctionsList != address(0) && ISanctionsList(sanctionsList).isSanctioned(_account));
    }

    /**
     * @notice Checks if the specified account is blacklisted by an exogenous blacklist
     * @dev Enables bespoke blacklist checks for external issuers and integrators
     * @dev Intentionally implemented with an empty body since this function is optional and only adds to the basic blacklist's checks
     * @param _account The address of the account to check
     * @return blacklisted Whether the account is blacklisted by the exogenous blacklist
     */
    function _isExogenouslyBlacklisted(address _account) internal view virtual returns (bool blacklisted) { }
}
