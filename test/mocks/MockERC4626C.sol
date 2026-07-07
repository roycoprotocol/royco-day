// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { WAD, WAD_DECIMALS } from "../../src/libraries/Constants.sol";

/**
 * @title MockERC4626C
 * @notice ERC4626-shaped test vault over a MockERC20C underlying, implementing only what the identical-shares quoter family touches
 * @dev The rate (assets per share, WAD-normalized) moves ONLY via setRate and accrue, never on its own, so PnL injection is an explicit test action
 * @dev Satisfies the quoter identity, convertToAssets(10 ** (18 + shareDecimals - underlyingDecimals)) == the intended WAD tranche-unit to base-asset rate
 * @dev Fidelity gaps vs a real ERC4626 vault: no preview/max surface and no Deposit/Withdraw events (the quoters
 *      never call them), the rate is a pinned knob rather than a balance-derived value, and mintShares mints
 *      without pulling underlying so redeeming free-minted shares requires funding the vault separately
 */
contract MockERC4626C {
    using Math for uint256;
    using SafeERC20 for IERC20;

    /// @notice Emitted on every balance-moving operation, mirroring the ERC20 standard
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Emitted on every approval, mirroring the ERC20 standard
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice Thrown when the sender's share balance cannot cover the transfer, redemption, or burn
    error INSUFFICIENT_BALANCE();

    /// @notice Thrown when the spender's allowance cannot cover the transferFrom or redeem
    error INSUFFICIENT_ALLOWANCE();

    /// @notice Thrown when the rate is set to zero or an accrual would drive it to or below zero
    error INVALID_RATE();

    /// @notice Thrown when the decimal configuration breaks the quoter's WAD scaling assumption (18 + shareDecimals >= underlyingDecimals)
    error INVALID_DECIMAL_CONFIGURATION();

    /// @dev The underlying asset the vault shares convert to
    address private immutable ASSET;

    /// @dev The share token decimals, fixed at construction
    uint8 private immutable SHARE_DECIMALS;

    /**
     * @dev The share amount that converts to exactly rateWAD assets, 10 ** (18 + shareDecimals - underlyingDecimals)
     * @dev This is the same scalar the quoter derives, so convertToAssets(RATE_SCALAR) == rateWAD by construction
     */
    uint256 private immutable RATE_SCALAR;

    /// @dev The share token name
    string private _name;

    /// @dev The share token symbol
    string private _symbol;

    /// @dev The share balances
    mapping(address account => uint256 shares) private _balances;

    /// @dev The total share supply
    uint256 private _totalSupply;

    /// @notice The standard ERC20 allowance mapping for the share token
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    /// @notice The assets-per-share rate, WAD-normalized (WAD == 1 whole underlying per whole share). Moves only via setRate and accrue
    uint256 public rateWAD = WAD;

    /**
     * @notice Deploys the mock vault share token over the specified underlying
     * @param _underlying The underlying asset (a MockERC20C in the fixture's token shapes)
     * @param _shareName The share token name
     * @param _shareSymbol The share token symbol
     * @param _shareDecimals The share token decimals
     */
    constructor(address _underlying, string memory _shareName, string memory _shareSymbol, uint8 _shareDecimals) {
        uint8 underlyingDecimals = IERC20Metadata(_underlying).decimals();
        require(WAD_DECIMALS + _shareDecimals >= underlyingDecimals, INVALID_DECIMAL_CONFIGURATION());

        ASSET = _underlying;
        SHARE_DECIMALS = _shareDecimals;
        RATE_SCALAR = 10 ** (WAD_DECIMALS + _shareDecimals - underlyingDecimals);
        _name = _shareName;
        _symbol = _shareSymbol;
    }

    // =============================
    // ERC4626 Surface (the subset the quoter family touches)
    // =============================

    /// @notice Returns the underlying asset the vault shares convert to
    function asset() external view returns (address) {
        return ASSET;
    }

    /// @notice Converts the share amount to underlying assets at the current rate, rounding down
    function convertToAssets(uint256 _shares) public view returns (uint256) {
        return _shares.mulDiv(rateWAD, RATE_SCALAR, Math.Rounding.Floor);
    }

    /// @notice Converts the asset amount to shares at the current rate, rounding down
    function convertToShares(uint256 _assets) public view returns (uint256) {
        return _assets.mulDiv(RATE_SCALAR, rateWAD, Math.Rounding.Floor);
    }

    /// @notice Returns the total underlying assets the share supply converts to at the current rate
    function totalAssets() external view returns (uint256) {
        return convertToAssets(_totalSupply);
    }

    /// @notice Deposits underlying assets and mints the converted share amount, a minimal path for test seeding
    function deposit(uint256 _assets, address _receiver) external returns (uint256 shares) {
        shares = convertToShares(_assets);
        IERC20(ASSET).safeTransferFrom(msg.sender, address(this), _assets);
        _mint(_receiver, shares);
    }

    /// @notice Burns the share amount and pays out the converted underlying assets, a minimal path for test seeding
    function redeem(uint256 _shares, address _receiver, address _owner) external returns (uint256 assets) {
        if (msg.sender != _owner) _spendAllowance(_owner, msg.sender, _shares);
        assets = convertToAssets(_shares);
        _burn(_owner, _shares);
        IERC20(ASSET).safeTransfer(_receiver, assets);
    }

    // =============================
    // Rate Knobs
    // =============================

    /// @notice Pins the assets-per-share rate to the specified WAD-normalized value
    function setRate(uint256 _rateWAD) external {
        require(_rateWAD > 0, INVALID_RATE());
        rateWAD = _rateWAD;
    }

    /// @notice Multiplies the rate by (1e18 + bps * 1e14), so positive bps accrues yield and negative bps injects a loss
    function accrue(int256 _bps) external {
        int256 factorWAD = int256(WAD) + _bps * 1e14;
        require(factorWAD > 0, INVALID_RATE());
        uint256 newRateWAD = rateWAD.mulDiv(uint256(factorWAD), WAD, Math.Rounding.Floor);
        require(newRateWAD > 0, INVALID_RATE());
        rateWAD = newRateWAD;
    }

    // =============================
    // Test Helpers
    // =============================

    /// @notice Mints shares directly without pulling underlying, free for tests
    /// @dev Redeeming free-minted shares requires funding this vault's underlying balance separately
    function mintShares(address _to, uint256 _shares) external {
        _mint(_to, _shares);
    }

    // =============================
    // ERC20 Surface (share token)
    // =============================

    /// @notice Returns the share token name
    function name() external view returns (string memory) {
        return _name;
    }

    /// @notice Returns the share token symbol
    function symbol() external view returns (string memory) {
        return _symbol;
    }

    /// @notice Returns the share token decimals
    function decimals() external view returns (uint8) {
        return SHARE_DECIMALS;
    }

    /// @notice Returns the total share supply
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    /// @notice Returns the account's share balance
    function balanceOf(address _account) external view returns (uint256) {
        return _balances[_account];
    }

    /// @notice Transfers shares to the recipient
    function transfer(address _to, uint256 _amount) external returns (bool) {
        _transfer(msg.sender, _to, _amount);
        return true;
    }

    /// @notice Transfers shares from the owner to the recipient using the caller's allowance
    function transferFrom(address _from, address _to, uint256 _amount) external returns (bool) {
        _spendAllowance(_from, msg.sender, _amount);
        _transfer(_from, _to, _amount);
        return true;
    }

    /// @notice Approves the spender for the specified share amount
    function approve(address _spender, uint256 _amount) external returns (bool) {
        allowance[msg.sender][_spender] = _amount;
        emit Approval(msg.sender, _spender, _amount);
        return true;
    }

    // =============================
    // Internal Logic
    // =============================

    /// @notice Moves shares between accounts
    function _transfer(address _from, address _to, uint256 _amount) internal {
        require(_balances[_from] >= _amount, INSUFFICIENT_BALANCE());
        _balances[_from] -= _amount;
        _balances[_to] += _amount;
        emit Transfer(_from, _to, _amount);
    }

    /// @notice Mints shares to the account
    function _mint(address _to, uint256 _shares) internal {
        _balances[_to] += _shares;
        _totalSupply += _shares;
        emit Transfer(address(0), _to, _shares);
    }

    /// @notice Burns shares from the account
    function _burn(address _from, uint256 _shares) internal {
        require(_balances[_from] >= _shares, INSUFFICIENT_BALANCE());
        _balances[_from] -= _shares;
        _totalSupply -= _shares;
        emit Transfer(_from, address(0), _shares);
    }

    /// @notice Consumes the spender's allowance, skipping the decrement for an infinite approval
    function _spendAllowance(address _owner, address _spender, uint256 _amount) internal {
        uint256 currentAllowance = allowance[_owner][_spender];
        if (currentAllowance == type(uint256).max) return;
        require(currentAllowance >= _amount, INSUFFICIENT_ALLOWANCE());
        allowance[_owner][_spender] = currentAllowance - _amount;
    }
}
