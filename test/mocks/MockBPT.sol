// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { IVaultErrors } from "../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultErrors.sol";

/**
 * @title MockBPT
 * @notice Thin ERC20 test mock for a Balancer Pool Token, delegating every balance read and move to the vault's ledger
 * @dev Mirrors BalancerPoolToken exactly for the surface the kernel touches, the kernel constructor calls BalancerPoolToken(ltAsset).getVault()
 * @dev All accounting lives in MockBalancerVault, this contract only forwards and emits the ERC20 events on the vault's instruction
 */
contract MockBPT {
    /// @notice Emitted on every balance-moving operation, mirroring the ERC20 standard
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Emitted on every approval, mirroring the ERC20 standard
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @dev The vault whose ledger backs this pool token
    IVault private immutable _vault;

    /// @dev The pool token name
    string private _bptName;

    /// @dev The pool token symbol
    string private _bptSymbol;

    /// @dev Restricts a function to the backing vault, mirroring VaultGuard's onlyVault with the same error shape
    modifier onlyVault() {
        if (msg.sender != address(_vault)) revert IVaultErrors.SenderIsNotVault(msg.sender);
        _;
    }

    /**
     * @notice Deploys the mock pool token against its backing vault
     * @param vault_ The MockBalancerVault whose ledger backs this pool token
     * @param bptName The pool token name
     * @param bptSymbol The pool token symbol
     */
    constructor(IVault vault_, string memory bptName, string memory bptSymbol) {
        _vault = vault_;
        _bptName = bptName;
        _bptSymbol = bptSymbol;
    }

    /// @notice Returns the pool token name
    function name() external view returns (string memory) {
        return _bptName;
    }

    /// @notice Returns the pool token symbol
    function symbol() external view returns (string memory) {
        return _bptSymbol;
    }

    /// @notice Returns the pool token decimals, always 18 for a BPT
    function decimals() external pure returns (uint8) {
        return 18;
    }

    /// @notice Returns the address of the backing vault, the kernel constructor resolves its vault immutable through this
    function getVault() public view returns (IVault) {
        return _vault;
    }

    /// @notice Returns the total supply from the vault's ledger
    function totalSupply() external view returns (uint256) {
        return _vault.totalSupply(address(this));
    }

    /// @notice Returns the account's balance from the vault's ledger
    function balanceOf(address _account) external view returns (uint256) {
        return _vault.balanceOf(address(this), _account);
    }

    /// @notice Transfers pool tokens through the vault's ledger, the vault calls emitTransfer back to emit the event here
    function transfer(address _to, uint256 _amount) external returns (bool) {
        _vault.transfer(msg.sender, _to, _amount);
        return true;
    }

    /// @notice Returns the allowance from the vault's ledger
    function allowance(address _owner, address _spender) external view returns (uint256) {
        return _vault.allowance(address(this), _owner, _spender);
    }

    /// @notice Approves the spender through the vault's ledger, the vault calls emitApproval back to emit the event here
    function approve(address _spender, uint256 _amount) external returns (bool) {
        _vault.approve(msg.sender, _spender, _amount);
        return true;
    }

    /// @notice Transfers pool tokens from the owner through the vault's ledger using the caller's allowance
    function transferFrom(address _from, address _to, uint256 _amount) external returns (bool) {
        _vault.transferFrom(msg.sender, _from, _to, _amount);
        return true;
    }

    /// @notice Emits the Transfer event on the vault's instruction, mirroring the MultiToken pattern
    function emitTransfer(address _from, address _to, uint256 _amount) external onlyVault {
        emit Transfer(_from, _to, _amount);
    }

    /// @notice Emits the Approval event on the vault's instruction, mirroring the MultiToken pattern
    function emitApproval(address _owner, address _spender, uint256 _amount) external onlyVault {
        emit Approval(_owner, _spender, _amount);
    }
}
