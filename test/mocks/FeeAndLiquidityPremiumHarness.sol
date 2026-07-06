// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayKernel } from "../../src/interfaces/IRoycoDayKernel.sol";
import { SyncedAccountingState } from "../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../src/libraries/Units.sol";
import { FeeAndLiquidityPremiumLogic } from "../../src/libraries/logic/FeeAndLiquidityPremiumLogic.sol";
import { ValuationLogic } from "../../src/libraries/logic/ValuationLogic.sol";

/**
 * @title MockTrancheShareLedger
 * @notice Minimal tranche share ledger for the FeeAndLiquidityPremiumLogic harness: a settable total supply plus
 *         recording mint entrypoints matching the IRoycoSeniorTranche / IRoycoVaultTranche mint surface
 */
contract MockTrancheShareLedger {
    uint256 public totalSupply;

    uint256 public premiumMintCallCount;
    address public lastPremiumMintTo;
    uint256 public lastPremiumSharesMinted;

    uint256 public feeMintCallCount;
    address public lastFeeMintTo;
    uint256 public lastFeeSharesMinted;

    function setTotalSupply(uint256 _totalSupply) external {
        totalSupply = _totalSupply;
    }

    /// @dev Mirror of IRoycoSeniorTranche.mintLiquidityPremiumShares, recording the call and growing the supply
    function mintLiquidityPremiumShares(address _to, uint256 _liquidityPremiumShares) external returns (uint256 totalTrancheShares) {
        premiumMintCallCount++;
        lastPremiumMintTo = _to;
        lastPremiumSharesMinted = _liquidityPremiumShares;
        totalSupply += _liquidityPremiumShares;
        return totalSupply;
    }

    /// @dev Mirror of IRoycoVaultTranche.mintProtocolFeeShares, recording the call and growing the supply
    function mintProtocolFeeShares(address _protocolFeeRecipient, uint256 _protocolFeeShares) external returns (uint256 totalTrancheShares) {
        feeMintCallCount++;
        lastFeeMintTo = _protocolFeeRecipient;
        lastFeeSharesMinted = _protocolFeeShares;
        totalSupply += _protocolFeeShares;
        return totalSupply;
    }
}

/**
 * @title FeeAndLiquidityPremiumHarness
 * @notice Thin external-call wrapper around the kernel-side FeeAndLiquidityPremiumLogic and ValuationLogic so unit
 *         tests can drive _processFeesAndLiquidityPremium and _getLiquidityTrancheEffectiveNAV against a real
 *         RoycoDayKernelState storage struct without a full kernel deployment
 * @dev The library calls IRoycoDayKernel(address(this)) back for the reinvestment attempt and the LT raw NAV read,
 *      so this harness implements those two entrypoints itself: identity tranche-unit conversion (1 tranche unit
 *      equals 1 NAV unit) and a stub reinvestment that drains a configurable share count from the staged pile
 */
contract FeeAndLiquidityPremiumHarness {
    IRoycoDayKernel.RoycoDayKernelState internal kernelState;

    MockTrancheShareLedger public immutable ST_LEDGER;
    MockTrancheShareLedger public immutable JT_LEDGER;
    MockTrancheShareLedger public immutable LT_LEDGER;

    /// @notice The protocol fee recipient wired into the kernel state at construction
    address public constant PROTOCOL_FEE_RECIPIENT = address(0xFEE);

    /// @notice Shares the stub reinvestment drains from the staged premium pile per call (0 models a slippage-deferred deploy)
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

    /// @notice The LT effective NAV view: LT raw NAV plus the staged premium shares valued at the senior share price
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
        uint256 staged = kernelState.ltOwnedSeniorTrancheShares;
        uint256 drained = reinvestSharesToDrain > staged ? staged : reinvestSharesToDrain;
        kernelState.ltOwnedSeniorTrancheShares = staged - drained;
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
