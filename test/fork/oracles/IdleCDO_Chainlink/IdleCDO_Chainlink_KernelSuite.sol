// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AggregatorV3Interface } from "../../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";
import { IIdleCDO } from "../../../../src/interfaces/external/idle-finance/IIdleCDO.sol";
import { IdleCDOTranchePriceOracle } from "../../../../src/oracle/IdleCDOTranchePriceOracle.sol";
import { ChainlinkPriceOracleBase } from "../../../../src/oracle/base/ChainlinkPriceOracleBase.sol";
import { Test_BalancerExogenousInteractionsBase } from "../../venues/balancer-v3/Test_BalancerExogenousInteractionsBase.t.sol";

/**
 * @title IdleCDO_Chainlink_KernelSuite
 * @notice The ORACLE layer of the fork chain: layers an oracle + asset shape ON the Balancer venue module,
 *         so one concrete asset leaf carries the full kernel suite plus the deep venue suites. The shape:
 *         collateral is a REAL Idle CDO AA tranche priced by an `IdleCDOTranchePriceOracle` (tranche->underlying
 *         via the CDO's virtualPrice and underlying->NAV via a Chainlink-compatible feed, timestamped by the
 *         older of the deviation clock and the feed), with the LPT holding the venue's Gyro E-CLP BPT of
 *         `{collateral_share, quote}`.
 * @dev Implements the `IKernelTestHooks` deal + simulate seams once for this oracle and asset shape, so a
 *      concrete asset leaf supplies only `getTestConfig`, `_deployKernelAndMarket`, the CDO/tranche/feed
 *      addresses, and the rounding tolerances. Kernel behavior is asserted only in `Test_KernelSuiteBase` and
 *      venue behavior only in the venue suites below: this layer overrides oracles and assets, never expectations.
 * @dev PnL moves through the CDO's virtualPrice (the axis the tranche accrues on in production) by mocking the
 *      REAL CDO's `virtualPrice(tranche)`, so a move shifts the composed price by exactly the stated fraction
 *      and, with the market deployed at a zero deviation threshold, reads as a clock deviation in the same breath.
 */
abstract contract IdleCDO_Chainlink_KernelSuite is Test_BalancerExogenousInteractionsBase {
    /// @dev Cached mocked virtual price in the CDO underlying token's decimals, seeded from the REAL CDO on first use.
    uint256 internal _mockedVirtualPrice;
    bool internal _virtualPriceMocked;

    /// @dev Cached underlying->NAV feed answer, seeded from the real feed on first use; re-stamped fresh after warps.
    int256 internal _mockedFeedAnswer;
    bool internal _feedMocked;

    /// @dev The REAL Idle CDO whose AA tranche is the market's collateral asset.
    function _idleCDO() internal view virtual returns (address);

    /// @dev The CDO tranche token the market holds as collateral (ST and JT share it).
    function _cdoTrancheToken() internal view virtual returns (address);

    /// @dev The underlying(token)->NAV Chainlink-compatible feed backing the composed oracle (e.g. USDC/USD).
    function _underlyingToNavFeed() internal view virtual returns (address);

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
    // SIMULATE HOOKS — move the tranche->underlying leg by mocking the CDO's virtualPrice
    // ═══════════════════════════════════════════════════════════════════════════
    // NOTE: ST and JT share the same tranche token + the same virtual price, so a move affects BOTH legs by the same
    //      fraction. Isolating a single tranche's NAV is not possible via this axis. The composed price is linear in
    //      the virtual price, so a p% move shifts the collateral price by exactly p% (floored at the virtual price's
    //      own decimals, the same granularity production accrual carries).

    function simulateSTYield(uint256 _percentageWAD) public virtual override {
        _moveVirtualPrice(int256(1), _percentageWAD);
    }

    function simulateJTYield(uint256 _percentageWAD) public virtual override {
        _moveVirtualPrice(int256(1), _percentageWAD);
    }

    function simulateSTLoss(uint256 _percentageWAD) public virtual override {
        _moveVirtualPrice(int256(-1), _percentageWAD);
    }

    function simulateJTLoss(uint256 _percentageWAD) public virtual override {
        _moveVirtualPrice(int256(-1), _percentageWAD);
    }

    /// @dev Yield realization is immediate here (a virtual price move re-marks instantly), so no time warp is required.
    function _requiresTimeWarpForYield() internal virtual override returns (bool) {
        return false;
    }

    /// @dev The staleness selector the collateral oracle fails shut with, enabling the abstract suite's staleness
    ///      brick test. The brick warp exceeds BOTH hop thresholds and the base checks the feed hop first, so the
    ///      composed oracle surfaces the feed's error rather than STALE_VIRTUAL_PRICE.
    function _oracleStalenessSelector() internal pure virtual override returns (bytes4) {
        return ChainlinkPriceOracleBase.STALE_FEED_PRICE.selector;
    }

    /**
     * @dev Keep BOTH of the composed report's hops fresh at the current (post-warp) time, since the report's
     *      timestamp is the OLDER of the two: the feed mock is re-stamped at now (self-seeding from the real feed's
     *      live answer on first use), and the deviation clock is re-checkpointed at now through a price-neutral
     *      double poke (bump the virtual price one underlying-decimal wei, poke, restore it, poke), which the
     *      market's zero deviation threshold counts as two observed updates while leaving the price bit-identical.
     */
    function _refreshOraclesAfterWarp() internal virtual override {
        // Re-stamp the feed leg fresh
        if (!_feedMocked) _seedFeedMock();
        _applyFeedMock();

        // Re-checkpoint the clock leg fresh without moving the price
        if (!_virtualPriceMocked) _seedVirtualPriceMock();
        uint256 restore = _mockedVirtualPrice;
        _applyVirtualPriceMock(restore + 1);
        _pokeCollateralOracle();
        _applyVirtualPriceMock(restore);
        _pokeCollateralOracle();
    }

    /// @dev Commits a clock checkpoint on the kernel's collateral oracle at the current virtual price reading.
    function _pokeCollateralOracle() internal {
        IdleCDOTranchePriceOracle(KERNEL.getCollateralAssetOracle()).poke();
    }

    function _moveVirtualPrice(int256 _sign, uint256 _percentageWAD) internal {
        if (!_virtualPriceMocked) _seedVirtualPriceMock();
        uint256 delta = (_mockedVirtualPrice * _percentageWAD) / 1e18;
        _mockedVirtualPrice = (_sign > 0) ? _mockedVirtualPrice + delta : _mockedVirtualPrice - delta;
        // The composed price must never collapse to zero: the smallest representable virtual price stands in
        if (_mockedVirtualPrice == 0) _mockedVirtualPrice = 1;
        _applyVirtualPriceMock(_mockedVirtualPrice);
    }

    /// @dev Seeds the virtual price mock from the REAL CDO's live reading (a 0% move).
    function _seedVirtualPriceMock() internal {
        _mockedVirtualPrice = IIdleCDO(_idleCDO()).virtualPrice(_cdoTrancheToken());
        _virtualPriceMocked = true;
    }

    function _applyVirtualPriceMock(uint256 _virtualPrice) internal {
        vm.mockCall(_idleCDO(), abi.encodeWithSelector(IIdleCDO.virtualPrice.selector, _cdoTrancheToken()), abi.encode(_virtualPrice));
    }

    /// @dev Seeds the feed mock from the real feed's live answer (a 0% move) while it is still fresh, so a later
    ///      warp can re-stamp it without re-reading a by-then-stale real feed.
    function _seedFeedMock() internal {
        (, int256 answer,,,) = AggregatorV3Interface(_underlyingToNavFeed()).latestRoundData();
        _mockedFeedAnswer = answer;
        _feedMocked = true;
    }

    function _applyFeedMock() internal {
        vm.mockCall(
            _underlyingToNavFeed(),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), _mockedFeedAnswer, block.timestamp, block.timestamp, uint80(1))
        );
    }
}
