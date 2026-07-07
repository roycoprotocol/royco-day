// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayKernel } from "../../src/interfaces/IRoycoDayKernel.sol";
import { SyncedAccountingState } from "../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../src/libraries/Units.sol";
import { FeeAndLiquidityPremiumLogic } from "../../src/libraries/logic/FeeAndLiquidityPremiumLogic.sol";
import { ValuationLogic } from "../../src/libraries/logic/ValuationLogic.sol";
import { MockTrancheShareLedger } from "./MockTrancheShareLedger.sol";

/**
 * @title FeeAndLiquidityPremiumHarness
 * @notice Thin external-call wrapper around the kernel-side FeeAndLiquidityPremiumLogic and ValuationLogic so unit
 *         tests can drive _processFeesAndLiquidityPremium and _getLiquidityTrancheEffectiveNAV against a real
 *         RoycoDayKernelState storage struct without a full kernel deployment
 * @dev The library calls IRoycoDayKernel(address(this)) back for the reinvestment attempt and the LT raw NAV read,
 *      so this wrapper implements those two entrypoints itself: identity tranche-unit conversion (1 tranche unit
 *      equals 1 NAV unit) and a stub reinvestment that drains a configurable share count from the idle liquidity
 *      premium senior shares (ltOwnedSeniorTrancheShares)
 */
contract FeeAndLiquidityPremiumHarness {
    IRoycoDayKernel.RoycoDayKernelState internal kernelState;

    MockTrancheShareLedger public immutable ST_LEDGER;
    MockTrancheShareLedger public immutable JT_LEDGER;
    MockTrancheShareLedger public immutable LT_LEDGER;

    /// @notice The protocol fee recipient wired into the kernel state at construction
    address public constant PROTOCOL_FEE_RECIPIENT = address(0xFEE);

    /// @notice Shares the stub reinvestment drains from ltOwnedSeniorTrancheShares per call (0 models a slippage-deferred deploy)
    uint256 public reinvestSharesToDrain;

    uint256 public reinvestCallCount;
    uint256 public lastReinvestSharesArg;
    NAV_UNIT public lastReinvestSTEffectiveNAVArg;
    uint256 public lastReinvestTotalSTSharesArg;

    constructor() {
        ST_LEDGER = new MockTrancheShareLedger();
        JT_LEDGER = new MockTrancheShareLedger();
        LT_LEDGER = new MockTrancheShareLedger();
        kernelState.protocolFeeRecipient = PROTOCOL_FEE_RECIPIENT;
    }

    /*//////////////////////////////////////////////////////////////////////
                            STATE SETTERS AND VIEWS
    //////////////////////////////////////////////////////////////////////*/

    function setLTOwnedSeniorTrancheShares(uint256 _shares) external {
        kernelState.ltOwnedSeniorTrancheShares = _shares;
    }

    /// @dev The LT raw NAV read routes through the identity conversion, so this sets ltRawNAV directly in NAV units
    function setLTOwnedYieldBearingAssets(uint256 _assets) external {
        kernelState.ltOwnedYieldBearingAssets = toTrancheUnits(_assets);
    }

    function setSTOwnedYieldBearingAssets(uint256 _assets) external {
        kernelState.stOwnedYieldBearingAssets = toTrancheUnits(_assets);
    }

    function setReinvestSharesToDrain(uint256 _shares) external {
        reinvestSharesToDrain = _shares;
    }

    function ltOwnedSeniorTrancheShares() external view returns (uint256) {
        return kernelState.ltOwnedSeniorTrancheShares;
    }

    function stOwnedYieldBearingAssets() external view returns (uint256) {
        return toUint256(kernelState.stOwnedYieldBearingAssets);
    }

    /*//////////////////////////////////////////////////////////////////////
                            LIBRARY ENTRYPOINTS
    //////////////////////////////////////////////////////////////////////*/

    /// @notice Drives the full post-sync fee and liquidity premium mint orchestration against the harness state
    function processFeesAndLiquidityPremium(SyncedAccountingState memory _state) external {
        FeeAndLiquidityPremiumLogic._processFeesAndLiquidityPremium(kernelState, _immutables(), _state);
    }

    /// @notice The LT effective NAV view: LT raw NAV plus the idle liquidity premium senior shares valued at the senior share price
    function ltEffectiveNAV(NAV_UNIT _stEffectiveNAV, uint256 _totalSeniorTrancheShares) external view returns (NAV_UNIT) {
        return ValuationLogic._getLiquidityTrancheEffectiveNAV(kernelState, _stEffectiveNAV, _totalSeniorTrancheShares);
    }

    /*//////////////////////////////////////////////////////////////////////
                    SELF-CALL SURFACE CONSUMED BY THE LIBRARIES
    //////////////////////////////////////////////////////////////////////*/

    /// @dev Mirror of IRoycoDayKernel.attemptLiquidityPremiumReinvestment: records the call and drains the configured share count
    function attemptLiquidityPremiumReinvestment(uint256 _stSharesToReinvest, NAV_UNIT _stEffectiveNAV, uint256 _totalSTShares) external {
        reinvestCallCount++;
        lastReinvestSharesArg = _stSharesToReinvest;
        lastReinvestSTEffectiveNAVArg = _stEffectiveNAV;
        lastReinvestTotalSTSharesArg = _totalSTShares;
        uint256 idleShares = kernelState.ltOwnedSeniorTrancheShares;
        uint256 drained = reinvestSharesToDrain > idleShares ? idleShares : reinvestSharesToDrain;
        kernelState.ltOwnedSeniorTrancheShares = idleShares - drained;
    }

    /// @dev Identity conversion so the harness LT raw NAV equals ltOwnedYieldBearingAssets in NAV units
    function ltConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _ltAssets) external pure returns (NAV_UNIT nav) {
        return toNAVUnits(toUint256(_ltAssets));
    }

    /*//////////////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////////////*/

    /// @dev The immutables carrier wired to the three mock ledgers (asset and accountant slots are unused by these libraries)
    function _immutables() internal view returns (IRoycoDayKernel.RoycoDayKernelImmutableState memory immutables) {
        immutables.seniorTranche = address(ST_LEDGER);
        immutables.juniorTranche = address(JT_LEDGER);
        immutables.liquidityTranche = address(LT_LEDGER);
    }
}
