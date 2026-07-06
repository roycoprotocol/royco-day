// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { WAD } from "../../src/libraries/Constants.sol";
import { MockBehaviors } from "./MockBehaviors.sol";

/**
 * @title MockERC20C
 * @notice Configurable ERC20 test mock whose non-standard behaviors are toggled through the MockBehaviors bitmap
 * @dev Balances are stored as internal shares scaled by a settable rebase factor, so BEHAVIOR_REBASING moves every balance read without a transfer
 * @dev All behavior changes go through setters, never vm.mockCall, so the production code between mock and assertion actually executes
 */
contract MockERC20C {
    /// @notice Emitted on every balance-moving operation, mirroring the ERC20 standard
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Emitted on every approval, mirroring the ERC20 standard
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice Thrown when a transfer is attempted while the token is paused (BEHAVIOR_PAUSABLE)
    error TOKEN_PAUSED();

    /// @notice Thrown on a zero-amount transfer or transferFrom (BEHAVIOR_REVERT_ON_ZERO)
    error ZERO_AMOUNT_TRANSFER();

    /// @notice Thrown when the sender or recipient is on the deny list (BEHAVIOR_BLOCKLIST)
    error ADDRESS_BLOCKED();

    /// @notice Thrown when the sender's balance cannot cover the transfer or burn
    error INSUFFICIENT_BALANCE();

    /// @notice Thrown when the spender's allowance cannot cover the transferFrom
    error INSUFFICIENT_ALLOWANCE();

    /// @notice Thrown when the rebase factor is set to zero
    error INVALID_REBASE_FACTOR();

    /// @notice Thrown when the transfer fee exceeds 100%
    error INVALID_FEE_BPS();

    /// @dev The token name
    string private _name;

    /// @dev The token symbol
    string private _symbol;

    /// @dev The token decimals, fixed at construction
    uint8 private immutable DECIMALS;

    /// @dev Internal share balances, scaled to external amounts by the effective rebase factor on every read
    mapping(address account => uint256 shares) private _shares;

    /// @dev Total internal shares in existence
    uint256 private _totalShares;

    /// @notice The standard ERC20 allowance mapping, denominated in external (rebased) amounts
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    /// @notice The active MockBehaviors bitmap
    uint256 public behaviors;

    /// @notice The transfer fee in basis points, only applied when BEHAVIOR_FEE_ON_TRANSFER is set. The fee is burned
    uint16 public feeBps;

    /// @notice The per-address deny list, only enforced when BEHAVIOR_BLOCKLIST is set
    mapping(address account => bool blocked) public blocked;

    /// @notice The global pause switch, only enforced when BEHAVIOR_PAUSABLE is set
    bool public paused;

    /// @notice The rebase factor scaling every balance read, only applied when BEHAVIOR_REBASING is set
    uint256 public rebaseFactorWAD = WAD;

    /// @notice The hook target called on every transfer when BEHAVIOR_HOOK_ON_TRANSFER is set (reentrancy probe)
    address public transferHook;

    /**
     * @notice Deploys the configurable ERC20 with no non-standard behaviors enabled
     * @param _tokenName The token name
     * @param _tokenSymbol The token symbol
     * @param _decimals The token decimals
     */
    constructor(string memory _tokenName, string memory _tokenSymbol, uint8 _decimals) {
        _name = _tokenName;
        _symbol = _tokenSymbol;
        DECIMALS = _decimals;
    }

    // =============================
    // ERC20 Surface
    // =============================

    /// @notice Returns the token name
    function name() external view returns (string memory) {
        return _name;
    }

    /// @notice Returns the token symbol
    function symbol() external view returns (string memory) {
        return _symbol;
    }

    /// @notice Returns the token decimals
    function decimals() external view returns (uint8) {
        return DECIMALS;
    }

    /// @notice Returns the total supply in external (rebased) amounts
    function totalSupply() external view returns (uint256) {
        return _toAmount(_totalShares);
    }

    /// @notice Returns the account's balance in external (rebased) amounts
    function balanceOf(address _account) external view returns (uint256) {
        return _toAmount(_shares[_account]);
    }

    /// @notice Transfers tokens to the recipient, applying every enabled behavior
    /// @dev With BEHAVIOR_NO_RETURN_VALUE set, returns empty returndata (USDT shape) instead of the declared bool
    function transfer(address _to, uint256 _amount) external returns (bool) {
        _transfer(msg.sender, _to, _amount);
        if (_has(MockBehaviors.BEHAVIOR_NO_RETURN_VALUE)) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }

    /// @notice Transfers tokens from the owner to the recipient using the caller's allowance, applying every enabled behavior
    /// @dev With BEHAVIOR_NO_RETURN_VALUE set, returns empty returndata (USDT shape) instead of the declared bool
    function transferFrom(address _from, address _to, uint256 _amount) external returns (bool) {
        _spendAllowance(_from, msg.sender, _amount);
        _transfer(_from, _to, _amount);
        if (_has(MockBehaviors.BEHAVIOR_NO_RETURN_VALUE)) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }

    /// @notice Approves the spender for the specified external amount
    function approve(address _spender, uint256 _amount) external returns (bool) {
        allowance[msg.sender][_spender] = _amount;
        emit Approval(msg.sender, _spender, _amount);
        return true;
    }

    // =============================
    // Test Helpers
    // =============================

    /// @notice Mints the specified external amount to the account, free for tests
    function mint(address _to, uint256 _amount) external {
        uint256 shares = _toShares(_amount);
        _shares[_to] += shares;
        _totalShares += shares;
        emit Transfer(address(0), _to, _amount);
    }

    /// @notice Burns the specified external amount from the account, free for tests
    function burn(address _from, uint256 _amount) external {
        uint256 shares = _toShares(_amount);
        require(_shares[_from] >= shares, INSUFFICIENT_BALANCE());
        _shares[_from] -= shares;
        _totalShares -= shares;
        emit Transfer(_from, address(0), _amount);
    }

    // =============================
    // Behavior Configuration
    // =============================

    /// @notice Sets the active MockBehaviors bitmap
    function setBehaviors(uint256 _bitmap) external {
        behaviors = _bitmap;
    }

    /// @notice Sets the transfer fee in basis points (BEHAVIOR_FEE_ON_TRANSFER)
    function setFeeBps(uint16 _feeBps) external {
        require(_feeBps <= 10_000, INVALID_FEE_BPS());
        feeBps = _feeBps;
    }

    /// @notice Adds or removes an account from the deny list (BEHAVIOR_BLOCKLIST)
    function setBlocked(address _account, bool _isBlocked) external {
        blocked[_account] = _isBlocked;
    }

    /// @notice Sets the global pause switch (BEHAVIOR_PAUSABLE)
    function setPaused(bool _isPaused) external {
        paused = _isPaused;
    }

    /// @notice Sets the rebase factor scaling every balance and supply read (BEHAVIOR_REBASING)
    function setRebaseFactorWAD(uint256 _rebaseFactorWAD) external {
        require(_rebaseFactorWAD > 0, INVALID_REBASE_FACTOR());
        rebaseFactorWAD = _rebaseFactorWAD;
    }

    /// @notice Sets the hook target called on every transfer (BEHAVIOR_HOOK_ON_TRANSFER)
    function setTransferHook(address _transferHook) external {
        transferHook = _transferHook;
    }

    // =============================
    // Internal Logic
    // =============================

    /**
     * @notice Moves the external amount from the sender to the recipient, applying every enabled behavior
     * @dev The fee (BEHAVIOR_FEE_ON_TRANSFER) is deducted from the amount credited to the recipient and burned
     * @dev The hook (BEHAVIOR_HOOK_ON_TRANSFER) runs after balances settle and bubbles its revert verbatim so a blocked reentry fails the transfer
     */
    function _transfer(address _from, address _to, uint256 _amount) internal {
        require(!_has(MockBehaviors.BEHAVIOR_PAUSABLE) || !paused, TOKEN_PAUSED());
        require(!_has(MockBehaviors.BEHAVIOR_REVERT_ON_ZERO) || _amount > 0, ZERO_AMOUNT_TRANSFER());
        require(!_has(MockBehaviors.BEHAVIOR_BLOCKLIST) || (!blocked[_from] && !blocked[_to]), ADDRESS_BLOCKED());

        // Compute the fee burned on the transfer, zero unless BEHAVIOR_FEE_ON_TRANSFER is set
        uint256 fee = _has(MockBehaviors.BEHAVIOR_FEE_ON_TRANSFER) ? (_amount * feeBps) / 10_000 : 0;

        // Move the internal shares, burning the fee's share equivalent
        uint256 shares = _toShares(_amount);
        uint256 feeShares = _toShares(fee);
        require(_shares[_from] >= shares, INSUFFICIENT_BALANCE());
        _shares[_from] -= shares;
        _shares[_to] += shares - feeShares;
        _totalShares -= feeShares;

        emit Transfer(_from, _to, _amount - fee);

        // Invoke the transfer hook if configured, bubbling any revert verbatim
        if (_has(MockBehaviors.BEHAVIOR_HOOK_ON_TRANSFER) && transferHook != address(0)) {
            (bool success, bytes memory returnData) =
                transferHook.call(abi.encodeWithSignature("onTokenTransfer(address,address,uint256)", _from, _to, _amount));
            if (!success) {
                assembly ("memory-safe") {
                    revert(add(returnData, 0x20), mload(returnData))
                }
            }
        }
    }

    /// @notice Consumes the spender's allowance, skipping the decrement for an infinite approval
    function _spendAllowance(address _owner, address _spender, uint256 _amount) internal {
        uint256 currentAllowance = allowance[_owner][_spender];
        if (currentAllowance == type(uint256).max) return;
        require(currentAllowance >= _amount, INSUFFICIENT_ALLOWANCE());
        allowance[_owner][_spender] = currentAllowance - _amount;
    }

    /// @notice Returns the effective rebase factor, WAD unless BEHAVIOR_REBASING is set
    function _effectiveFactorWAD() internal view returns (uint256) {
        return _has(MockBehaviors.BEHAVIOR_REBASING) ? rebaseFactorWAD : WAD;
    }

    /// @notice Converts internal shares to an external (rebased) amount, rounding down
    function _toAmount(uint256 _sharesAmount) internal view returns (uint256) {
        return (_sharesAmount * _effectiveFactorWAD()) / WAD;
    }

    /// @notice Converts an external (rebased) amount to internal shares, rounding down
    function _toShares(uint256 _amount) internal view returns (uint256) {
        return (_amount * WAD) / _effectiveFactorWAD();
    }

    /// @notice Returns whether the specified behavior flag is enabled
    function _has(uint256 _flag) internal view returns (bool) {
        return behaviors & _flag != 0;
    }
}
