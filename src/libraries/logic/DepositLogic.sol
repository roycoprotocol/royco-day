// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { PausableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IRoycoDayAccountant } from "../../interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { MAX_NAV_UNITS, MAX_TRANCHE_UNITS, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../Constants.sol";
import { MarketState, Operation, SyncedAccountingState, TrancheType } from "../Types.sol";
import { Math, NAV_UNIT, TRANCHE_UNIT } from "../Units.sol";
import { AccountingSyncLogic } from "./AccountingSyncLogic.sol";
import { BlacklistLogic } from "./BlacklistLogic.sol";
import { FeeAndLiquidityPremiumLogic } from "./FeeAndLiquidityPremiumLogic.sol";
import { ValuationLogic } from "./ValuationLogic.sol";

/**
 * @title DepositLogic
 * @author Waymont
 * @notice The senior, junior, liquidity, and multi-asset deposit flows, their previews, and max-deposit reads for a Royco market
 * @dev Invoked by the kernel via delegatecall
 */
library DepositLogic {
    // =============================
    // Deposit Preview Functions
    // =============================

    /**
     * @notice Previews the deposit of a specified amount of assets into the senior tranche
     * @param _assets The amount of assets to deposit, denominated in the senior tranche's tranche units
     * @return stateBeforeDeposit The state of the senior tranche before the deposit, after applying the pre-op sync
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units
     * @return totalTrancheShares The senior tranche supply after the pre-op sync mints the premium and protocol fee shares
     */
    function stPreviewDeposit(TRANCHE_UNIT _assets)
        external
        view
        returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated, uint256 totalTrancheShares)
    {
        // Preview the senior tranche state and its post-sync supply (after the premium and protocol fee shares) before the deposit
        (stateBeforeDeposit,, totalTrancheShares) = IRoycoDayKernel(address(this)).previewSyncTrancheAccounting(TrancheType.SENIOR);
        // Convert the assets to NAV units
        valueAllocated = IRoycoDayKernel(address(this)).stConvertTrancheUnitsToNAVUnits(_assets);
    }

    /**
     * @notice Previews the deposit of a specified amount of assets into the junior tranche
     * @dev The kernel may decide to simulate the deposit and revert internally with the result
     * @dev Should revert if deposits are asynchronous
     * @param _assets The amount of assets to deposit, denominated in the junior tranche's tranche units
     * @return stateBeforeDeposit The state of the junior tranche before the deposit, after applying the pre-op sync
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units
     * @return totalTrancheShares The junior tranche supply after the pre-op sync mints the protocol fee shares
     */
    function jtPreviewDeposit(TRANCHE_UNIT _assets)
        external
        view
        returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated, uint256 totalTrancheShares)
    {
        // Preview the junior tranche state and its post-sync supply (after the protocol fee shares) before the deposit
        (stateBeforeDeposit,, totalTrancheShares) = IRoycoDayKernel(address(this)).previewSyncTrancheAccounting(TrancheType.JUNIOR);
        // Convert the assets to NAV units
        valueAllocated = IRoycoDayKernel(address(this)).jtConvertTrancheUnitsToNAVUnits(_assets);
    }

    /**
     * @notice Previews the deposit of a specified amount of assets into the liquidity tranche
     * @param _assets The amount of assets to deposit, denominated in the liquidity tranche's tranche units
     * @return stateBeforeDeposit The state of the liquidity tranche before the deposit, after applying the pre-op sync
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units
     * @return totalTrancheShares The liquidity tranche supply after the pre-op sync mints the protocol fee shares
     * @return navToMintSharesAt The pre-deposit LT effective NAV (value deployed into the AMM or another market-making venue plus the idle liquidity-premium senior shares) to mint LT shares at
     */
    function ltPreviewDeposit(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        TRANCHE_UNIT _assets
    )
        external
        view
        returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated, uint256 totalTrancheShares, NAV_UNIT navToMintSharesAt)
    {
        // Preview the liquidity tranche state and its post-sync supply (after the protocol fee shares) before the deposit
        (stateBeforeDeposit,, totalTrancheShares) = IRoycoDayKernel(address(this)).previewSyncTrancheAccounting(TrancheType.LIQUIDITY);
        // Convert the assets to NAV units
        valueAllocated = IRoycoDayKernel(address(this)).ltConvertTrancheUnitsToNAVUnits(_assets);
        // Compute the LT effective NAV prior to the deposit as the NAV to mint shares at
        (uint256 liquidityPremiumShares,, uint256 stTotalSupplyAfterMints) =
            FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(stateBeforeDeposit, IERC20(_immutables.seniorTranche).totalSupply());
        navToMintSharesAt = ValuationLogic._getLiquidityTrancheEffectiveNAV(
            $, stateBeforeDeposit.stEffectiveNAV, stTotalSupplyAfterMints, ($.ltOwnedSeniorTrancheShares + liquidityPremiumShares)
        );
    }

    /**
     * @notice Previews a multi-asset LT deposit of (ST underlying + quote) by simulating the venue add
     * @dev NON-VIEW: routes the venue add through its simulation/query mode, so callers must staticcall it
     * @param _stAssets The ST underlying leg, in the ST asset's native units
     * @param _quoteAssets The quote asset leg
     * @return valueAllocated The NAV value of the LT assets the add would mint
     * @return navToMintSharesAt The pre-deposit LT effective NAV that LT shares would be minted against
     * @return ltAssetsOut The LT tranche assets the add would mint
     * @return ltTotalSupplyAfterMints The LT tranche supply after this sync mints its protocol fee shares, which LT shares must be priced against
     */
    function ltPreviewDepositMultiAsset(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        TRANCHE_UNIT _stAssets,
        uint256 _quoteAssets
    )
        external
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt, TRANCHE_UNIT ltAssetsOut, uint256 ltTotalSupplyAfterMints)
    {
        // Preview the sync and the LT supply after this sync mints the LT protocol fee shares, exactly as depositMultiAsset reads totalSupply() post-sync
        SyncedAccountingState memory state;
        (state,, ltTotalSupplyAfterMints) = IRoycoDayKernel(address(this)).previewSyncTrancheAccounting(TrancheType.LIQUIDITY);
        // During a fixed-term market state only a quote-only deposit is permitted; an ST-leg deposit reverts, so return zero before quoting the venue add to match it
        if (state.marketState == MarketState.FIXED_TERM && _stAssets != ZERO_TRANCHE_UNITS) {
            return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS, ltTotalSupplyAfterMints);
        }
        // The NAV to mint LT shares at is the pre-deposit LT effective NAV (market-making depth plus the idle premium senior shares); the senior supply is taken after its premium and protocol fee mint
        (uint256 liquidityPremiumShares,, uint256 totalSTShares) =
            FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(state, IERC20(_immutables.seniorTranche).totalSupply());
        navToMintSharesAt =
            ValuationLogic._getLiquidityTrancheEffectiveNAV($, state.stEffectiveNAV, totalSTShares, ($.ltOwnedSeniorTrancheShares + liquidityPremiumShares));
        // Size the senior shares the ST leg would mint (zero if no ST underlying is supplied), priced like the execution path
        uint256 stSharesToAdd = (_stAssets == ZERO_TRANCHE_UNITS)
            ? 0
            : ValuationLogic._convertToShares(
                IRoycoDayKernel(address(this)).stConvertTrancheUnitsToNAVUnits(_stAssets), state.stEffectiveNAV, totalSTShares, Math.Rounding.Floor
            );
        // Quote the venue add for the senior shares and quote assets (simulation only: no slippage gate, no settlement)
        ltAssetsOut = IRoycoDayKernel(address(this)).previewAddLiquidity(stSharesToAdd, _quoteAssets);
        // The value allocated is the value of the LT assets the add would mint
        valueAllocated = IRoycoDayKernel(address(this)).ltConvertTrancheUnitsToNAVUnits(ltAssetsOut);
    }

    // =============================
    // Tranche Max Deposit Functions
    // =============================

    /**
     * @notice Returns the maximum amount of assets that can be deposited into the senior tranche
     * @param _receiver The address that will receive the ST shares equating to the deposited assets
     * @return assets The maximum amount of assets that can be deposited into the senior tranche, denominated in the senior tranche's tranche units
     * @dev ST deposits are allowed only in a PERPETUAL market state, granted that the market's coverage requirement is satisfied post-deposit
     */
    function stMaxDeposit(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        address _receiver
    )
        external
        view
        returns (TRANCHE_UNIT assets)
    {
        // If the receiver is blacklisted or the kernel is currently paused, return zero tranche units
        if (BlacklistLogic._isBlacklisted($, _receiver) || PausableUpgradeable(address(this)).paused()) return ZERO_TRANCHE_UNITS;
        SyncedAccountingState memory state = AccountingSyncLogic._previewSyncTrancheAccounting($, _immutables);
        // ST deposits are disabled during a fixed-term market state
        if (state.marketState == MarketState.FIXED_TERM) return ZERO_TRANCHE_UNITS;
        // ST deposits are enabled as long as the market's coverage requirement is satisfied
        NAV_UNIT stMaxDepositableNAV = IRoycoDayAccountant(_immutables.accountant).maxSTDeposit(state);
        return
            ((stMaxDepositableNAV == MAX_NAV_UNITS) ? MAX_TRANCHE_UNITS : IRoycoDayKernel(address(this)).stConvertNAVUnitsToTrancheUnits(stMaxDepositableNAV));
    }

    /**
     * @notice Returns the maximum amount of assets that can be deposited into the junior tranche
     * @param _receiver The address that will receive the JT shares equating to the deposited assets
     * @return assets The maximum amount of assets that can be deposited into the junior tranche, denominated in the junior tranche's tranche units
     * @dev JT deposits are allowed if the market is in a PERPETUAL state
     */
    function jtMaxDeposit(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        address _receiver
    )
        external
        view
        returns (TRANCHE_UNIT assets)
    {
        // If the receiver is blacklisted or the kernel is currently paused, return zero tranche units
        if (BlacklistLogic._isBlacklisted($, _receiver) || PausableUpgradeable(address(this)).paused()) return ZERO_TRANCHE_UNITS;
        // JT deposits are disabled during a fixed-term market state
        if ((AccountingSyncLogic._previewSyncTrancheAccounting($, _immutables)).marketState == MarketState.FIXED_TERM) return ZERO_TRANCHE_UNITS;
        return MAX_TRANCHE_UNITS;
    }

    /**
     * @notice Returns the maximum amount of assets that can be deposited into the liquidity tranche
     * @param _receiver The address that will receive the LT shares equating to the deposited assets
     * @return assets The maximum amount of assets that can be deposited into the liquidity tranche, denominated in the liquidity tranche's tranche units
     * @dev An in-kind LT deposit mints no new senior shares and only deepens liquidity, so it is enabled in every market state and unbounded
     */
    function ltMaxDeposit(IRoycoDayKernel.RoycoDayKernelState storage $, address _receiver) external view returns (TRANCHE_UNIT assets) {
        // If the receiver is blacklisted or the kernel is currently paused, return zero tranche units
        if (BlacklistLogic._isBlacklisted($, _receiver) || PausableUpgradeable(address(this)).paused()) return ZERO_TRANCHE_UNITS;
        // In-kind LT deposits are never gated, so the deposit is unbounded
        return MAX_TRANCHE_UNITS;
    }

    // =============================
    // Senior Tranche Deposit Functions
    // =============================

    /**
     * @notice Processes the deposit of a specified amount of assets into the senior tranche
     * @dev Assumes that the funds are transferred to the kernel before the deposit call is made
     * @param _assets The amount of assets to deposit, denominated in the senior tranche's tranche units
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units
     * @return navToMintSharesAt The NAV at which the shares will be minted, exclusive of valueAllocated
     * @dev ST deposits are enabled only in a PERPETUAL market state, granted that the market's coverage requirement is satisfied post-deposit
     */
    function stDeposit(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        TRANCHE_UNIT _assets
    )
        external
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt)
    {
        // Execute an accounting sync to reconcile underlying PNL
        SyncedAccountingState memory state = AccountingSyncLogic._preOpSyncTrancheAccounting($, _immutables);
        // ST deposits are disabled during a fixed-term market state
        require(state.marketState == MarketState.PERPETUAL, IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE());
        // The NAV to mint tranche shares at is the pre-deposit senior tranche controlled NAV
        navToMintSharesAt = state.stEffectiveNAV;
        // The precise value allocated is the value of the deposited assets
        valueAllocated = IRoycoDayKernel(address(this)).stConvertTrancheUnitsToNAVUnits(_assets);

        // Credit the deposited assets to the senior tranche
        $.stOwnedYieldBearingAssets = $.stOwnedYieldBearingAssets + _assets;

        // Execute a post-deposit sync on accounting and enforce the market's coverage and liquidity requirements against the new senior exposure
        AccountingSyncLogic._postOpSyncTrancheAccounting($, _immutables, Operation.ST_DEPOSIT, ZERO_NAV_UNITS, true);
    }

    // =============================
    // Junior Tranche Deposit Functions
    // =============================

    /**
     * @notice Processes the deposit of a specified amount of assets into the junior tranche
     * @dev Assumes that the funds are transferred to the kernel before the deposit call is made
     * @param _assets The amount of assets to deposit, denominated in the junior tranche's tranche units
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units
     * @return navToMintSharesAt The NAV at which the shares will be minted, exclusive of valueAllocated
     * @dev JT deposits are enabled if the market is in a PERPETUAL state
     */
    function jtDeposit(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        TRANCHE_UNIT _assets
    )
        external
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt)
    {
        // Execute an accounting sync to reconcile underlying PNL
        SyncedAccountingState memory state = AccountingSyncLogic._preOpSyncTrancheAccounting($, _immutables);
        // JT deposits are disabled during a fixed-term market state
        require(state.marketState == MarketState.PERPETUAL, IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE());
        // The NAV to mint tranche shares at is the pre-deposit junior tranche controlled NAV
        navToMintSharesAt = state.jtEffectiveNAV;
        // The precise value allocated is the value of the deposited assets
        valueAllocated = IRoycoDayKernel(address(this)).jtConvertTrancheUnitsToNAVUnits(_assets);

        // Credit the deposited assets to the junior tranche
        $.jtOwnedYieldBearingAssets = $.jtOwnedYieldBearingAssets + _assets;

        // Execute a post-deposit sync on accounting; a JT deposit grows the loss-absorption buffer and only improves coverage, so no requirements are enforced
        AccountingSyncLogic._postOpSyncTrancheAccounting($, _immutables, Operation.JT_DEPOSIT, ZERO_NAV_UNITS, false);
    }

    // =============================
    // Liquidity Tranche Deposit Functions
    // =============================

    /**
     * @notice Processes the deposit of a specified amount of assets into the liquidity tranche.
     * @dev An in-kind LT deposit mints no new senior shares and only deepens liquidity, so it is enabled in every market state (including fixed-term).
     * @param _assets The amount of assets (the liquidity venue's position token) to deposit, denominated in the liquidity tranche's tranche units.
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units.
     * @return navToMintSharesAt The NAV at which the shares will be minted, exclusive of valueAllocated.
     * @dev An in-kind LT deposit mints no new senior shares and only deepens liquidity, so it is enabled in every market state and enforces no requirements
     */
    function ltDeposit(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        TRANCHE_UNIT _assets
    )
        external
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt)
    {
        // Execute an accounting sync to reconcile underlying PNL
        SyncedAccountingState memory state = AccountingSyncLogic._preOpSyncTrancheAccounting($, _immutables);
        // The NAV to mint tranche shares at is the pre-deposit liquidity tranche effective NAV (its MM depth in addition to its idle liquidity-premium senior shares the kernel holds)
        navToMintSharesAt = ValuationLogic._getLiquidityTrancheEffectiveNAV($, state.stEffectiveNAV, IERC20(_immutables.seniorTranche).totalSupply());
        // The precise value allocated is the value of the deposited assets
        valueAllocated = IRoycoDayKernel(address(this)).ltConvertTrancheUnitsToNAVUnits(_assets);

        // Credit the deposited assets to the liquidity tranche
        $.ltOwnedYieldBearingAssets = $.ltOwnedYieldBearingAssets + _assets;

        // Execute a post-deposit sync on accounting. An in-kind LT deposit only adds market-making depth and improves liquidity, so no requirements are enforced
        AccountingSyncLogic._postOpSyncTrancheAccounting($, _immutables, Operation.LT_DEPOSIT, ZERO_NAV_UNITS, false);
    }

    // =============================
    // Liquidity Tranche Multi-Asset Deposit Functions
    // =============================

    /**
     * @notice Atomically enters the liquidity tranche with the LT assets' constituent assets: deposits ST underlying (minting senior
     *         shares), adds (senior shares + quote) into the liquidity venue to mint the LT tranche assets, then deposits them into the LT
     * @dev Assumes the ST underlying and quote have been transferred to the kernel before this call (by the LT tranche)
     * @dev Enabled in a PERPETUAL market state, and in a fixed-term market only for a quote-only deposit (_stAssets == 0) that mints no senior shares. An ST-leg deposit reverts in a fixed-term market
     * @dev The combined new senior exposure is gated by the market's coverage and liquidity requirements. Reverts if either is unsatisfied
     * @param _stAssets The amount of ST underlying (the senior tranche's base asset) to deposit, denominated in ST tranche units
     * @param _quoteAssets The amount of quote asset to add as the second venue leg
     * @param _minLTAssetsOut The minimum LT tranche assets the liquidity add must mint (slippage bound against an unfavorable venue state)
     * @return valueAllocated The value of the minted LT tranche assets, denominated in the kernel's NAV units
     * @return navToMintSharesAt The LT effective NAV at which the LT shares will be minted (pre-deposit)
     * @return ltAssetsOut The amount of LT tranche assets minted and credited to the liquidity tranche
     * @dev LT multi-asset deposits are enabled in a PERPETUAL market state (granted the market's coverage and liquidity requirements are satisfied against the new senior exposure), and in a fixed-term market only for a quote-only deposit that mints no senior shares
     */
    function ltDepositMultiAsset(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        TRANCHE_UNIT _stAssets,
        uint256 _quoteAssets,
        TRANCHE_UNIT _minLTAssetsOut
    )
        external
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt, TRANCHE_UNIT ltAssetsOut)
    {
        // At least one constituent leg (ST underlying or quote) must be supplied
        require(_stAssets != ZERO_TRANCHE_UNITS || _quoteAssets != 0, IRoycoDayKernel.MUST_DEPOSIT_NON_ZERO_ASSETS());

        // Execute an accounting sync to reconcile underlying PNL
        (SyncedAccountingState memory state,, uint256 totalSTShares) = AccountingSyncLogic._preOpSyncTrancheAccounting($, _immutables, TrancheType.SENIOR);
        // ST deposits are disabled during a fixed-term market state, so the market only accepts quote-only LT deposits
        require(state.marketState == MarketState.PERPETUAL || _stAssets == ZERO_TRANCHE_UNITS, IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE());
        // The NAV to mint tranche shares at is the pre-deposit liquidity tranche effective NAV (its MM depth plus the idle liquidity-premium senior shares the kernel holds), read before the add moves the venue mark
        navToMintSharesAt = ValuationLogic._getLiquidityTrancheEffectiveNAV($, state.stEffectiveNAV, totalSTShares);

        // If the ST asset leg is supplied, mint the corresponding non-diluting senior shares (priced at the pre-deposit senior effective NAV and pre-mint supply) to seed the add's senior leg
        uint256 stSharesMinted;
        if (_stAssets != ZERO_TRANCHE_UNITS) {
            // Compute the number of senior tranche shares to mint for this ST asset deposit
            stSharesMinted = ValuationLogic._convertToShares(
                IRoycoDayKernel(address(this)).stConvertTrancheUnitsToNAVUnits(_stAssets), state.stEffectiveNAV, totalSTShares, Math.Rounding.Floor
            );
            // Credit the deposited ST underlying to the senior raw NAV and mint the corresponding senior shares to the kernel (raises supply only)
            // NOTE: The final post-op accounts for this ST deposit in addition to the subsequent LT deposit in one batch call
            $.stOwnedYieldBearingAssets = $.stOwnedYieldBearingAssets + _stAssets;
            IRoycoVaultTranche(_immutables.seniorTranche).mint(address(this), stSharesMinted);
        }

        // Add the minted ST shares and supplied quote assets into the liquidity venue with the specified slippage check
        ltAssetsOut = IRoycoDayKernel(address(this)).addLiquidity(stSharesMinted, _quoteAssets, _minLTAssetsOut);
        // The precise value allocated is the value of the LT assets rendered from adding liquidity
        valueAllocated = IRoycoDayKernel(address(this)).ltConvertTrancheUnitsToNAVUnits(ltAssetsOut);

        // Credit the minted LT tranche assets to the liquidity tranche
        $.ltOwnedYieldBearingAssets = $.ltOwnedYieldBearingAssets + ltAssetsOut;

        // Execute a post-deposit sync on accounting: it commits both the ST-leg deposit (deltaSTRawNAV >= 0) and the new venue depth (deltaLTRawNAV > 0), enforcing the market's coverage and liquidity requirements only when senior exposure was added
        // A quote-only deposit mints no senior shares: it cannot worsen coverage and only deepens liquidity, so it is guaranteed to be at least coverage and liquidity neutral
        AccountingSyncLogic._postOpSyncTrancheAccounting($, _immutables, Operation.LT_DEPOSIT, ZERO_NAV_UNITS, (_stAssets != ZERO_TRANCHE_UNITS));
    }
}
