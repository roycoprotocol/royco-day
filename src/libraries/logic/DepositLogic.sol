// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
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
import { DispatchLogic } from "./DispatchLogic.sol";
import { ValuationLogic } from "./ValuationLogic.sol";

/**
 * @title DepositLogic
 * @author Waymont
 * @notice The senior, junior, liquidity, and multi-asset deposit flows and max-deposit reads for a Royco market
 * @dev Invoked by the kernel via delegatecall
 */
library DepositLogic {
    // =============================
    // Tranche Deposit Functions
    // =============================

    /**
     * @notice Processes the deposit of a specified amount of assets into the senior tranche
     * @dev Assumes that the funds are transferred to the kernel before the deposit call is made
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _isPreview Whether this is a preview of the operation which must not mutate state
     * @param _assets The amount of assets to deposit, denominated in the senior tranche's tranche units
     * @return depositNAV The value of the assets deposited, denominated in the kernel's NAV units
     * @return effectiveNAV The NAV at which the shares will be minted, exclusive of depositNAV
     * @return totalTrancheShares The tranche's total share supply after the sync's premium and protocol fee mints, the supply the shares price against
     * @dev ST deposits are enabled only in a PERPETUAL market state, granted that the market's coverage and liquidity requirements are satisfied post-deposit
     */
    function stDeposit(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        bool _isPreview,
        TRANCHE_UNIT _assets
    )
        external
        returns (NAV_UNIT depositNAV, NAV_UNIT effectiveNAV, uint256 totalTrancheShares)
    {
        // Execute an accounting sync to reconcile underlying PNL
        SyncedAccountingState memory state = AccountingSyncLogic._preOpSyncTrancheAccounting($, _immutables);
        // Read the post-mint supply in this frame, a preview's sync mints unwind with the flow so the caller cannot read it
        totalTrancheShares = IERC20(_immutables.seniorTranche).totalSupply();
        // ST deposits are disabled during a fixed-term market state
        require(state.marketState == MarketState.PERPETUAL, IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE());
        // The NAV to mint tranche shares at is the pre-deposit senior tranche controlled NAV
        effectiveNAV = state.stEffectiveNAV;
        // The deposit NAV is the value of the deposited assets
        depositNAV = IRoycoDayKernel(address(this)).stConvertTrancheUnitsToNAVUnits(_assets);

        // Credit the deposited assets to the senior tranche
        $.stOwnedYieldBearingAssets = $.stOwnedYieldBearingAssets + _assets;

        // Execute a post-deposit sync on accounting and enforce the market's coverage and liquidity requirements against the new senior exposure
        AccountingSyncLogic._postOpSyncTrancheAccounting($, _immutables, Operation.ST_DEPOSIT, ZERO_NAV_UNITS, true);

        // A preview carries its result out via this revert, unwinding every mutation this flow made
        if (_isPreview) revert DispatchLogic.SIMULATION_RESULT(abi.encode(depositNAV, effectiveNAV, totalTrancheShares));
    }

    /**
     * @notice Processes the deposit of a specified amount of assets into the junior tranche
     * @dev Assumes that the funds are transferred to the kernel before the deposit call is made
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _isPreview Whether this is a preview of the operation which must not mutate state
     * @param _assets The amount of assets to deposit, denominated in the junior tranche's tranche units
     * @return depositNAV The value of the assets deposited, denominated in the kernel's NAV units
     * @return effectiveNAV The NAV at which the shares will be minted, exclusive of depositNAV
     * @return totalTrancheShares The tranche's total share supply after the sync's premium and protocol fee mints, the supply the shares price against
     * @dev JT deposits are enabled if the market is in a PERPETUAL state
     */
    function jtDeposit(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        bool _isPreview,
        TRANCHE_UNIT _assets
    )
        external
        returns (NAV_UNIT depositNAV, NAV_UNIT effectiveNAV, uint256 totalTrancheShares)
    {
        // Execute an accounting sync to reconcile underlying PNL
        SyncedAccountingState memory state = AccountingSyncLogic._preOpSyncTrancheAccounting($, _immutables);
        // Read the post-mint supply in this frame, a preview's sync mints unwind with the flow so the caller cannot read it
        totalTrancheShares = IERC20(_immutables.juniorTranche).totalSupply();
        // JT deposits are disabled during a fixed-term market state
        require(state.marketState == MarketState.PERPETUAL, IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE());
        // The NAV to mint tranche shares at is the pre-deposit junior tranche controlled NAV
        effectiveNAV = state.jtEffectiveNAV;
        // The deposit NAV is the value of the deposited assets
        depositNAV = IRoycoDayKernel(address(this)).jtConvertTrancheUnitsToNAVUnits(_assets);

        // Credit the deposited assets to the junior tranche
        $.jtOwnedYieldBearingAssets = $.jtOwnedYieldBearingAssets + _assets;

        // Execute a post-deposit sync on accounting. A JT deposit grows the loss-absorption buffer and only improves coverage, so no requirements are enforced
        AccountingSyncLogic._postOpSyncTrancheAccounting($, _immutables, Operation.JT_DEPOSIT, ZERO_NAV_UNITS, false);

        // A preview carries its result out via this revert, unwinding every mutation this flow made
        if (_isPreview) revert DispatchLogic.SIMULATION_RESULT(abi.encode(depositNAV, effectiveNAV, totalTrancheShares));
    }

    /**
     * @notice Processes the deposit of a specified amount of assets into the liquidity tranche
     * @dev An in-kind LT deposit mints no new senior shares and only deepens liquidity, so it is enabled in every market state (including fixed-term)
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _isPreview Whether this is a preview of the operation which must not mutate state
     * @param _assets The amount of assets (the liquidity venue's position token) to deposit, denominated in the liquidity tranche's tranche units
     * @return depositNAV The value of the assets deposited, denominated in the kernel's NAV units
     * @return effectiveNAV The NAV at which the shares will be minted, exclusive of depositNAV
     * @return totalTrancheShares The tranche's total share supply after the sync's premium and protocol fee mints, the supply the shares price against
     * @dev An in-kind LT deposit mints no new senior shares and only deepens liquidity, so it is enabled in every market state and enforces no requirements
     */
    function ltDeposit(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        bool _isPreview,
        TRANCHE_UNIT _assets
    )
        external
        returns (NAV_UNIT depositNAV, NAV_UNIT effectiveNAV, uint256 totalTrancheShares)
    {
        // Execute an accounting sync to reconcile underlying PNL
        SyncedAccountingState memory state = AccountingSyncLogic._preOpSyncTrancheAccounting($, _immutables);
        // Read the post-mint supply in this frame, a preview's sync mints unwind with the flow so the caller cannot read it
        totalTrancheShares = IERC20(_immutables.liquidityTranche).totalSupply();
        // The NAV to mint tranche shares at is the pre-deposit liquidity tranche effective NAV (its MM depth in addition to its idle liquidity-premium senior shares the kernel holds)
        effectiveNAV = ValuationLogic._getLiquidityTrancheEffectiveNAV($, state.stEffectiveNAV, IERC20(_immutables.seniorTranche).totalSupply());
        // The deposit NAV is the value of the deposited assets
        depositNAV = IRoycoDayKernel(address(this)).ltConvertTrancheUnitsToNAVUnits(_assets);

        // Credit the deposited assets to the liquidity tranche
        $.ltOwnedYieldBearingAssets = $.ltOwnedYieldBearingAssets + _assets;

        // Execute a post-deposit sync on accounting
        // An in-kind LT deposit only adds market-making depth and improves liquidity, so no requirements are enforced
        AccountingSyncLogic._postOpSyncTrancheAccounting($, _immutables, Operation.LT_DEPOSIT, ZERO_NAV_UNITS, false);

        // A preview carries its result out via this revert, unwinding every mutation this flow made
        if (_isPreview) revert DispatchLogic.SIMULATION_RESULT(abi.encode(depositNAV, effectiveNAV, totalTrancheShares));
    }

    /**
     * @notice Atomically enters the liquidity tranche with the LT assets' constituent assets: deposits ST underlying (minting senior
     *         shares), adds (senior shares + quote) into the liquidity venue to mint the LT tranche assets, then deposits them into the LT
     * @dev Assumes the ST underlying and quote have been transferred to the kernel before this call (by the LT tranche)
     * @dev Enabled in a PERPETUAL market state, and in a fixed-term market only for a quote-only deposit that mints no senior shares
     * @dev The combined new senior exposure is gated by the market's coverage and liquidity requirements, reverts if either is unsatisfied
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _isPreview Whether this is a preview of the operation which must not mutate state
     * @param _stAssets The amount of ST underlying (the senior tranche's base asset) to deposit, denominated in ST tranche units
     * @param _quoteAssets The amount of quote asset to add as the second venue leg
     * @param _minLTAssetsOut The minimum LT tranche assets the liquidity add must mint (slippage bound against an unfavorable venue state)
     * @return depositNAV The value of the minted LT tranche assets, denominated in the kernel's NAV units
     * @return effectiveNAV The LT effective NAV at which the LT shares will be minted (pre-deposit)
     * @return ltAssetsOut The amount of LT tranche assets minted and credited to the liquidity tranche
     */
    function ltDepositMultiAsset(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        bool _isPreview,
        TRANCHE_UNIT _stAssets,
        uint256 _quoteAssets,
        TRANCHE_UNIT _minLTAssetsOut
    )
        external
        returns (NAV_UNIT depositNAV, NAV_UNIT effectiveNAV, TRANCHE_UNIT ltAssetsOut)
    {
        // At least one constituent leg (ST underlying or quote) must be supplied
        require(_stAssets != ZERO_TRANCHE_UNITS || _quoteAssets != 0, IRoycoDayKernel.MUST_DEPOSIT_NON_ZERO_ASSETS());

        // Execute an accounting sync to reconcile underlying PNL
        (SyncedAccountingState memory state,, uint256 totalSTShares) = AccountingSyncLogic._preOpSyncTrancheAccounting($, _immutables, TrancheType.SENIOR);
        // ST deposits are disabled during a fixed-term market state, so the market only accepts quote-only LT deposits
        require(state.marketState == MarketState.PERPETUAL || _stAssets == ZERO_TRANCHE_UNITS, IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE());
        // The NAV to mint tranche shares at is the pre-deposit liquidity tranche effective NAV (its MM depth plus the idle liquidity-premium senior shares the kernel holds), read before the add moves the venue mark
        effectiveNAV = ValuationLogic._getLiquidityTrancheEffectiveNAV($, state.stEffectiveNAV, totalSTShares);

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
        // The venue values the minted LT assets and marks the post-op LT raw NAV against the post-add pool state in both modes
        NAV_UNIT postOpLTRawNAV;
        (ltAssetsOut, depositNAV, postOpLTRawNAV) = IRoycoDayKernel(address(this)).addLiquidity(_isPreview, stSharesMinted, _quoteAssets, _minLTAssetsOut);

        // Credit the minted LT tranche assets to the liquidity tranche
        $.ltOwnedYieldBearingAssets = $.ltOwnedYieldBearingAssets + ltAssetsOut;

        // Execute a post-deposit sync on accounting at the venue-marked LT raw NAV: it commits both the ST-leg deposit (deltaSTRawNAV >= 0) and the new venue depth (deltaLTRawNAV > 0), enforcing the market's coverage and liquidity requirements only when senior exposure was added
        // A quote-only deposit mints no senior shares: it cannot worsen coverage and only deepens liquidity, so it is guaranteed to be at least coverage and liquidity neutral
        AccountingSyncLogic._postOpSyncTrancheAccounting($, _immutables, Operation.LT_MULTI_ASSET_DEPOSIT, postOpLTRawNAV, ZERO_NAV_UNITS, (_stAssets != ZERO_TRANCHE_UNITS));

        // A preview carries its result out via this revert, unwinding every mutation this flow made
        if (_isPreview) revert DispatchLogic.SIMULATION_RESULT(abi.encode(depositNAV, effectiveNAV, ltAssetsOut));
    }

    // =============================
    // Tranche Max Deposit Functions
    // =============================

    /**
     * @notice Returns the maximum amount of assets that can be deposited into the senior tranche
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _receiver The address that will receive the ST shares equating to the deposited assets
     * @return assets The maximum amount of assets that can be deposited into the senior tranche, denominated in the senior tranche's tranche units
     * @dev ST deposits are allowed only in a PERPETUAL market state, granted that the market's coverage and liquidity requirements are satisfied post-deposit
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
        // ST deposits are enabled as long as the market's coverage and liquidity requirements are satisfied
        NAV_UNIT stMaxDepositableNAV = IRoycoDayAccountant(_immutables.accountant).maxSTDeposit(state);
        return
            ((stMaxDepositableNAV == MAX_NAV_UNITS) ? MAX_TRANCHE_UNITS : IRoycoDayKernel(address(this)).stConvertNAVUnitsToTrancheUnits(stMaxDepositableNAV));
    }

    /**
     * @notice Returns the maximum amount of assets that can be deposited into the junior tranche
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
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
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
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
}
