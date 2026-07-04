// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AggregatorV3Interface } from "../../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";
import { AbstractKernelTestSuite } from "../../abstract/AbstractKernelTestSuite.sol";

/**
 * @title Identical_ERC4626_Chainlink_BalancerV3_LT_KernelTest
 * @notice Per-kernel-type test base for the `Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel`
 *         family: ST and JT are the same ERC4626 vault share (priced share->base via the vault and base->NAV via a
 *         Chainlink-compatible feed), and the LT holds the Gyro E-CLP BPT of `{ST_share, quote}`.
 * @dev Implements the `IKernelTestHooks` deal + simulate seams once for this kernel family, so concrete protocol tests
 *      supply only `getTestConfig`, `_deployKernelAndMarket` (the market name), the `_baseAssetToNavOracle` address, and
 *      the rounding tolerances. No `test_*` methods yet.
 */
abstract contract Identical_ERC4626_Chainlink_BalancerV3_LT_KernelTest is AbstractKernelTestSuite {
    /// @dev Cached base->NAV feed answer, mocked once then moved by `simulate*`; re-stamped fresh after warps.
    int256 internal _mockedOracleAnswer;
    bool internal _oracleMocked;

    /// @dev The base(asset)->NAV Chainlink-compatible feed backing this market (e.g. the RedStone nUSD feed for snUSD).
    function _baseAssetToNavOracle() internal view virtual returns (address);

    // ═══════════════════════════════════════════════════════════════════════════
    // DEAL HOOKS — real tokens, funded via forge `deal`
    // ═══════════════════════════════════════════════════════════════════════════

    function dealSTAsset(address _to, uint256 _amount) public virtual override {
        deal(testConfig.stAsset, _to, _amount);
    }

    function dealJTAsset(address _to, uint256 _amount) public virtual override {
        deal(testConfig.jtAsset, _to, _amount);
    }

    function dealQuoteAsset(address _to, uint256 _amount) public virtual override {
        if (testConfig.quoteAsset != address(0)) deal(testConfig.quoteAsset, _to, _amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SIMULATE HOOKS — move the base->NAV leg by mocking the Chainlink-compatible feed
    // ═══════════════════════════════════════════════════════════════════════════
    // NOTE (coinvested caveat): ST and JT share the same asset + the same base->NAV feed, so a feed move affects BOTH legs
    //      by the same fraction. Isolating a single tranche's NAV is not possible for a coinvested market via this axis;
    //      a share-price axis (`vm.mockCall` on the vault's `convertToAssets`) can be layered in when yield tests need it.

    function simulateSTYield(uint256 _percentageWAD) public virtual override {
        _moveOracle(int256(1), _percentageWAD);
    }

    function simulateJTYield(uint256 _percentageWAD) public virtual override {
        _moveOracle(int256(1), _percentageWAD);
    }

    function simulateSTLoss(uint256 _percentageWAD) public virtual override {
        _moveOracle(int256(-1), _percentageWAD);
    }

    function simulateJTLoss(uint256 _percentageWAD) public virtual override {
        _moveOracle(int256(-1), _percentageWAD);
    }

    /// @dev Yield realization is immediate here (no rebasing/streaming), so no time warp is required.
    function _requiresTimeWarpForYield() internal virtual override returns (bool) {
        return false;
    }

    /// @dev Keep the mocked feed's `updatedAt` fresh across warps so the kernel's staleness check keeps passing.
    function _refreshOraclesAfterWarp() internal virtual override {
        if (_oracleMocked) _applyOracleMock(_baseAssetToNavOracle());
    }

    function _moveOracle(int256 _sign, uint256 _percentageWAD) internal {
        address oracle = _baseAssetToNavOracle();
        if (!_oracleMocked) {
            (, int256 answer,,,) = AggregatorV3Interface(oracle).latestRoundData();
            _mockedOracleAnswer = answer;
            _oracleMocked = true;
        }
        _mockedOracleAnswer += _sign * ((_mockedOracleAnswer * int256(_percentageWAD)) / int256(1e18));
        _applyOracleMock(oracle);
    }

    function _applyOracleMock(address _oracle) internal {
        vm.mockCall(
            _oracle,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), _mockedOracleAnswer, block.timestamp, block.timestamp, uint80(1))
        );
    }
}
