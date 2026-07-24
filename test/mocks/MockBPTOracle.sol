// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRateProvider } from "../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { WAD } from "../../src/libraries/Constants.sol";
import { MockBalancerVault } from "./MockBalancerVault.sol";

/**
 * @title MockBPTOracle
 * @notice BPT oracle test mock satisfying LPOracleBase's computeTVL, the 18-decimal NAV of the whole pool the kernel venue consumes
 * @dev AUTO mode derives the TVL live from the MockBalancerVault's pool balances at per-token WAD prices, so lptRawNAV stays consistent
 *      through adds and removes. MANUAL mode pins the TVL exactly for tests asserting hand-derived literals
 * @dev Fidelity gap vs the real E-CLP oracle: pricing is linear (balance x per-token price), not curve-implied, and the
 *      manipulation-resistance of the production oracle is a wiring property here, not an economic one
 */
contract MockBPTOracle {
    using Math for uint256;

    /// @dev How computeTVL resolves its value
    enum Mode {
        MANUAL,
        AUTO
    }

    /// @notice Thrown by computeTVL when revert mode is armed
    error ORACLE_REVERT_MODE();

    /// @notice Thrown when a bump factor would drive the value to or below zero
    error INVALID_BUMP();

    /// @dev The mock vault whose pool balances back AUTO mode
    MockBalancerVault private immutable VAULT;

    /// @dev The pool this oracle values
    address private immutable POOL;

    /// @notice The active resolution mode, AUTO by default
    Mode public mode = Mode.AUTO;

    /// @notice The pinned TVL returned in MANUAL mode, 18-decimal
    uint256 public manualTVL;

    /// @dev Whether computeTVL reverts
    bool private _revertMode;

    /// @dev Whether the oracle reverts its reads while the vault is unlocked, the LPOracleBase flag the venue rejects at wiring
    bool private _shouldRevertIfVaultUnlocked;

    /// @dev Per-token WAD prices used in AUTO mode, zero reads as the WAD (1.0) default
    mapping(address token => uint256 priceWAD) private _priceWAD;

    /// @dev Per-token live rate providers, when set the token's AUTO-mode price is read from the provider and the static price is ignored
    mapping(address token => address rateProvider) private _rateProvider;

    /// @notice Deploys the oracle against the mock vault and the pool it values
    /// @param _vault The MockBalancerVault whose pool balances back AUTO mode
    /// @param _pool The pool this oracle values
    constructor(MockBalancerVault _vault, address _pool) {
        VAULT = _vault;
        POOL = _pool;
    }

    // =============================
    // LPOracleBase Surface
    // =============================

    /// @notice Returns the pool this oracle values, the LPOracleBase surface the kernel venue validates when the oracle is wired
    function pool() external view returns (address) {
        return POOL;
    }

    /// @notice Returns whether the oracle reverts its reads while the vault is unlocked, the LPOracleBase surface the kernel venue rejects when true
    function getShouldRevertIfVaultUnlocked() external view returns (bool) {
        return _shouldRevertIfVaultUnlocked;
    }

    /**
     * @notice Returns the 18-decimal NAV of the whole pool, the LPOracleBase surface the kernel venue consumes
     * @dev MANUAL returns the pinned value, AUTO sums each pool balance at its effective WAD price read live from the mock vault
     * @return tvl The pool's total value, 18-decimal
     */
    function computeTVL() external view returns (uint256 tvl) {
        require(!_revertMode, ORACLE_REVERT_MODE());
        if (mode == Mode.MANUAL) return manualTVL;

        IERC20[] memory tokens = VAULT.getPoolTokens(POOL);
        uint256[2] memory balances = VAULT.getPoolBalances(POOL);
        for (uint256 i; i < 2; ++i) {
            if (balances[i] == 0) continue;
            tvl += balances[i].mulDiv(getPriceWAD(address(tokens[i])), 10 ** IERC20Metadata(address(tokens[i])).decimals(), Math.Rounding.Floor);
        }
    }

    // =============================
    // Test Knobs
    // =============================

    /// @notice Sets the resolution mode (MANUAL or AUTO)
    function setMode(Mode _mode) external {
        mode = _mode;
    }

    /// @notice Pins the MANUAL-mode TVL exactly, 18-decimal
    function setTVL(uint256 _tvl) external {
        manualTVL = _tvl;
    }

    /// @notice Sets a token's WAD price for AUTO mode, zero resets to the WAD (1.0) default
    /// @dev Shadowed by a live rate provider when one is set for the token
    function setPriceWAD(address _token, uint256 _newPriceWAD) external {
        _priceWAD[_token] = _newPriceWAD;
    }

    /**
     * @notice Wires a live rate provider for a token, address(0) unwires it back to the static price
     * @dev Mirrors production, the E-CLP oracle values a rate-scaled leg through the same IRateProvider.getRate the
     *      pool reads, so this oracle and the vault's fair-value pricing stay coherent by construction for that leg
     */
    function setTokenRateProvider(address _token, address _tokenRateProvider) external {
        _rateProvider[_token] = _tokenRateProvider;
    }

    /// @notice Returns a token's effective WAD price for AUTO mode, the live rate provider when wired, else the static price
    function getPriceWAD(address _token) public view returns (uint256) {
        address rateProvider = _rateProvider[_token];
        if (rateProvider != address(0)) return IRateProvider(rateProvider).getRate();
        uint256 priceWAD = _priceWAD[_token];
        return priceWAD == 0 ? WAD : priceWAD;
    }

    /**
     * @notice Scales the oracle's value by (1e18 + bps * 1e14), the fixture's applyLPTPnL hook
     * @dev In MANUAL mode the pinned TVL scales directly, in AUTO mode the static prices of both pool tokens scale
     * @dev Provider-backed tokens are skipped, their leg is pegged to the live senior mark and cannot drift from
     *      it independently, exactly as the production rate-scaled pool leg cannot
     * @param _bps The signed basis-point move, positive appreciates and negative depreciates
     */
    function bump(int256 _bps) external {
        int256 factorWAD = int256(WAD) + _bps * 1e14;
        require(factorWAD > 0, INVALID_BUMP());

        if (mode == Mode.MANUAL) {
            manualTVL = manualTVL.mulDiv(uint256(factorWAD), WAD, Math.Rounding.Floor);
        } else {
            IERC20[] memory tokens = VAULT.getPoolTokens(POOL);
            for (uint256 i; i < 2; ++i) {
                address token = address(tokens[i]);
                if (_rateProvider[token] != address(0)) continue;
                _priceWAD[token] = getPriceWAD(token).mulDiv(uint256(factorWAD), WAD, Math.Rounding.Floor);
            }
        }
    }

    /// @notice Arms or disarms the unlocked-vault revert flag the venue rejects at wiring
    function setShouldRevertIfVaultUnlocked(bool _shouldRevert) external {
        _shouldRevertIfVaultUnlocked = _shouldRevert;
    }

    /// @notice Arms or disarms the revert mode on computeTVL
    function setRevertMode(bool _shouldRevert) external {
        _revertMode = _shouldRevert;
    }
}
