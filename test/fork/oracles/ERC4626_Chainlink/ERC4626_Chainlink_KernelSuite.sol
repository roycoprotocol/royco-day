// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayKernel } from "../../../../src/interfaces/IRoycoDayKernel.sol";
import { AggregatorV3Interface } from "../../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";
import { Test_BalancerExogenousInteractionsBase } from "../../venues/balancer-v3/Test_BalancerExogenousInteractionsBase.t.sol";

/**
 * @title ERC4626_Chainlink_KernelSuite
 * @notice The ORACLE layer of the fork chain: layers an oracle + asset shape ON the Balancer venue module,
 *         so one concrete asset leaf carries the full kernel suite plus the deep venue suites. The shape:
 *         collateral is an ERC4626 vault share priced by an `ERC4626SharePriceOracle` (share->base via the
 *         vault and base->NAV via a Chainlink-compatible feed), with the LPT holding the venue's Gyro E-CLP
 *         BPT of `{collateral_share, quote}`.
 * @dev Implements the `IKernelTestHooks` deal + simulate seams once for this oracle and asset shape, so a
 *      concrete asset leaf supplies only `getTestConfig`, `_deployKernelAndMarket` (the market name), the
 *      `_baseAssetToNavOracle` address, and the rounding tolerances. Kernel behavior is asserted only in
 *      `Test_KernelSuiteBase` and venue behavior only in the venue suites below: this layer overrides
 *      oracles and assets, never expectations.
 */
abstract contract ERC4626_Chainlink_KernelSuite is Test_BalancerExogenousInteractionsBase {
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
    // NOTE: ST and JT share the same asset + the same base->NAV feed, so a feed move affects BOTH legs by the same
    //      fraction. Isolating a single tranche's NAV is not possible via this axis. A share-price axis (`vm.mockCall`
    //      on the vault's `convertToAssets`) can be layered in when yield tests need it.

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

    /// @dev The kernel's collateral oracle staleness selector, enabling the abstract suite's staleness brick test.
    function _oracleStalenessSelector() internal pure virtual override returns (bytes4) {
        return IRoycoDayKernel.STALE_PRICE.selector;
    }

    /**
     * @dev Keep the mocked feed's `updatedAt` fresh at the current (post-warp) time so the kernel's staleness check keeps
     *      passing. Self-seeding: when no simulate has run yet, the mock is seeded from the real feed's live answer (a 0%
     *      move) and stamped fresh, so admin-op warps never leave the market quoting a stale feed.
     */
    function _refreshOraclesAfterWarp() internal virtual override {
        if (!_oracleMocked) _pinOracleFresh();
        else _applyOracleMock(_baseAssetToNavOracle());
    }

    /// @dev Freeze the base->NAV feed's live value into the mock (a 0% move) while it is still fresh, so a later warp can
    ///      re-stamp it via `_refreshOraclesAfterWarp` without re-reading a by-then-stale real feed.
    function _pinOracleFresh() internal {
        _moveOracle(int256(1), 0);
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
