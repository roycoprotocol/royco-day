// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { PausableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IRoycoDayAccountant } from "../../interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { Cache, CacheKey } from "../Cache.sol";
import { MAX_NAV_UNITS, MAX_TRANCHE_UNITS, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../Constants.sol";
import { MarketState, Operation, SyncedAccountingState, TrancheType } from "../Types.sol";
import { Math, NAV_UNIT, TRANCHE_UNIT, toUint256 } from "../Units.sol";
import { AccountingSyncLogic } from "./AccountingSyncLogic.sol";
import { AssetLedgerLogic } from "./AssetLedgerLogic.sol";
import { BlacklistLogic } from "./BlacklistLogic.sol";
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
     * @dev ST deposits are enabled only in a PERPETUAL market state, granted that the market's coverage and liquidity requirements are satisfied post-deposit
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _isPreview Whether this is a preview of the operation which must not mutate state
     * @param _assets The amount of assets to deposit, denominated in the senior tranche's tranche units
     * @param _receiver The address that receives the minted tranche shares
     * @param _enforceLiquidityRequirement Whether the post-op enforces the market's liquidity requirement, waived only by the multi-asset LPT deposit whose venue add deploys the minted senior shares as depth
     * @return trancheSharesMinted The number of tranche shares minted to the receiver for the deposit
     */
    function stDeposit(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        bool _isPreview,
        TRANCHE_UNIT _assets,
        address _receiver,
        bool _enforceLiquidityRequirement
    )
        public
        returns (uint256 trancheSharesMinted)
    {
        // Execute an accounting sync to reconcile underlying PNL
        SyncedAccountingState memory state = AccountingSyncLogic._preOpSyncTrancheAccounting($, _immutables);
        // Read the supply after the sync's premium and protocol fee mints, the supply the shares price against
        uint256 totalTrancheShares = IERC20(_immutables.seniorTranche).totalSupply();
        // ST deposits are disabled during a fixed-term market state
        require(state.marketState == MarketState.PERPETUAL, IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE());
        // The deposit NAV is the value of the deposited assets
        NAV_UNIT depositNAV = IRoycoDayKernel(address(this)).convertCollateralAssetsToValue(_assets);

        // Credit the deposited assets to the senior tranche
        AssetLedgerLogic._creditAssets($, TrancheType.SENIOR, _assets);

        // Price the shares at the pre-deposit senior tranche effective NAV and mint them to the receiver, the tranche rejects a zero share count on return
        // NOTE: The effective NAV can be zero initially when the tranche is deployed
        trancheSharesMinted = ValuationLogic._convertToShares(depositNAV, state.stEffectiveNAV, totalTrancheShares, Math.Rounding.Floor);
        IRoycoVaultTranche(_immutables.seniorTranche).kernelMint(_receiver, trancheSharesMinted);

        // Execute a post-deposit sync on accounting and enforce the market's coverage and liquidity requirements against the new senior exposure
        AccountingSyncLogic._postOpSyncTrancheAccounting($, _immutables, Operation.ST_DEPOSIT, ZERO_NAV_UNITS, _enforceLiquidityRequirement);

        // A preview carries its result out via this revert, unwinding every mutation this flow made
        if (_isPreview) revert DispatchLogic.SIMULATION_RESULT(abi.encode(trancheSharesMinted));
    }

    /**
     * @notice Processes the deposit of a specified amount of assets into the junior tranche
     * @dev Assumes that the funds are transferred to the kernel before the deposit call is made
     * @dev JT deposits are enabled if the market is in a PERPETUAL state
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _isPreview Whether this is a preview of the operation which must not mutate state
     * @param _assets The amount of assets to deposit, denominated in the junior tranche's tranche units
     * @param _receiver The address that receives the minted tranche shares
     * @return trancheSharesMinted The number of tranche shares minted to the receiver for the deposit
     */
    function jtDeposit(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        bool _isPreview,
        TRANCHE_UNIT _assets,
        address _receiver
    )
        external
        returns (uint256 trancheSharesMinted)
    {
        // Execute an accounting sync to reconcile underlying PNL
        SyncedAccountingState memory state = AccountingSyncLogic._preOpSyncTrancheAccounting($, _immutables);
        // Read the supply after the sync's premium and protocol fee mints, the supply the shares price against
        uint256 totalTrancheShares = IERC20(_immutables.juniorTranche).totalSupply();
        // JT deposits are disabled during a fixed-term market state
        require(state.marketState == MarketState.PERPETUAL, IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE());
        // The deposit NAV is the value of the deposited assets
        NAV_UNIT depositNAV = IRoycoDayKernel(address(this)).convertCollateralAssetsToValue(_assets);

        // Credit the deposited assets to the junior tranche
        AssetLedgerLogic._creditAssets($, TrancheType.JUNIOR, _assets);

        // Price the shares at the pre-deposit junior tranche effective NAV and mint them to the receiver, the tranche rejects a zero share count on return
        // NOTE: The effective NAV can be zero initially when the tranche is deployed
        trancheSharesMinted = ValuationLogic._convertToShares(depositNAV, state.jtEffectiveNAV, totalTrancheShares, Math.Rounding.Floor);
        IRoycoVaultTranche(_immutables.juniorTranche).kernelMint(_receiver, trancheSharesMinted);

        // Execute a post-deposit sync on accounting. A JT deposit grows the loss-absorption buffer and only improves coverage, so no requirements are enforced
        AccountingSyncLogic._postOpSyncTrancheAccounting($, _immutables, Operation.JT_DEPOSIT, ZERO_NAV_UNITS, true);

        // A preview carries its result out via this revert, unwinding every mutation this flow made
        if (_isPreview) revert DispatchLogic.SIMULATION_RESULT(abi.encode(trancheSharesMinted));
    }

    /**
     * @notice Processes the deposit of a specified amount of assets into the liquidity provider tranche
     * @dev An in-kind LPT deposit mints no new senior shares and only deepens liquidity, so it is enabled in every market state (including fixed-term) and enforces no requirements
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _isPreview Whether this is a preview of the operation which must not mutate state
     * @param _assets The amount of assets (the liquidity venue's position token) to deposit, denominated in the liquidity provider tranche's tranche units
     * @param _receiver The address that receives the minted tranche shares
     * @return trancheSharesMinted The number of tranche shares minted to the receiver for the deposit
     */
    function lptDeposit(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        bool _isPreview,
        TRANCHE_UNIT _assets,
        address _receiver
    )
        public
        returns (uint256 trancheSharesMinted)
    {
        // Execute an accounting sync to reconcile underlying PNL
        SyncedAccountingState memory state = AccountingSyncLogic._preOpSyncTrancheAccounting($, _immutables);
        // Read the supply after the sync's premium and protocol fee mints, the supply the shares price against
        uint256 totalTrancheShares = IERC20(_immutables.liquidityProviderTranche).totalSupply();
        // The NAV to mint tranche shares at is the pre-deposit liquidity provider tranche effective NAV (its MM depth in addition to its idle liquidity-premium senior shares the kernel holds)
        NAV_UNIT effectiveNAV =
            ValuationLogic._getLiquidityProviderTrancheEffectiveNAV($, state.stEffectiveNAV, IERC20(_immutables.seniorTranche).totalSupply());
        // The deposit NAV is the value of the deposited assets
        NAV_UNIT depositNAV = IRoycoDayKernel(address(this)).convertLPTAssetsToValue(_assets);

        // Credit the deposited assets to the liquidity provider tranche
        AssetLedgerLogic._creditAssets($, TrancheType.LIQUIDITY_PROVIDER, _assets);

        // Price the shares at the pre-deposit effective NAV and mint them to the receiver, the tranche rejects a zero share count on return
        // NOTE: The effective NAV can be zero initially when the tranche is deployed
        trancheSharesMinted = ValuationLogic._convertToShares(depositNAV, effectiveNAV, totalTrancheShares, Math.Rounding.Floor);
        IRoycoVaultTranche(_immutables.liquidityProviderTranche).kernelMint(_receiver, trancheSharesMinted);

        // Execute a post-deposit sync on accounting
        // An in-kind LPT deposit only adds market-making depth and improves liquidity, so no requirements are enforced
        AccountingSyncLogic._postOpSyncTrancheAccounting($, _immutables, Operation.LPT_DEPOSIT, ZERO_NAV_UNITS, true);

        // A preview carries its result out via this revert, unwinding every mutation this flow made
        if (_isPreview) revert DispatchLogic.SIMULATION_RESULT(abi.encode(trancheSharesMinted));
    }

    /**
     * @notice Atomically enters the liquidity provider tranche with the LPT assets' constituent assets: deposits collateral (minting senior
     *         shares), adds (senior shares + quote) into the liquidity venue to mint the LPT tranche assets, then deposits them into the LPT
     * @dev Composed from the shared deposit primitives: an ST deposit seeding the add's senior shares, the venue add, then an LPT deposit of the minted assets
     * @dev Assumes the collateral and quote have been transferred to the kernel before this call (by the LPT tranche)
     * @dev Enabled in a PERPETUAL market state, and in a fixed-term market only for a quote-only deposit that mints no senior shares
     * @dev The senior leg is gated by the market's coverage requirement, its liquidity requirement is satisfied by the add deploying the minted shares as depth
     * @dev Prices the shares at the pre-deposit LPT effective NAV cached at the venue's post-add mark and mints them to the receiver
     * @dev A preview never returns: the flow unwinds every mutation by reverting with SIMULATION_RESULT carrying the ABI encoded return values
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _isPreview Whether this is a preview of the operation which must not mutate state
     * @param _collateralAssets The amount of collateral to deposit for the senior leg, denominated in tranche units
     * @param _quoteAssets The amount of quote asset to add as the second venue leg
     * @param _minLPTAssetsOut The minimum LPT tranche assets the liquidity add must mint (slippage bound against an unfavorable venue state)
     * @param _receiver The address that receives the minted tranche shares
     * @return trancheSharesMinted The number of tranche shares minted to the receiver for the deposit
     * @return lptAssetsOut The amount of LPT tranche assets minted and credited to the liquidity provider tranche
     */
    function lptDepositMultiAsset(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        bool _isPreview,
        TRANCHE_UNIT _collateralAssets,
        uint256 _quoteAssets,
        TRANCHE_UNIT _minLPTAssetsOut,
        address _receiver
    )
        external
        returns (uint256 trancheSharesMinted, TRANCHE_UNIT lptAssetsOut)
    {
        // Collateral leg: an ST deposit minting the add's senior shares to the kernel, waiving only the liquidity requirement the add's deployed depth satisfies below
        // Both legs run settled in preview and execution alike, this flow's own result revert unwinds them in a preview
        uint256 stSharesMinted;
        if (_collateralAssets != ZERO_TRANCHE_UNITS) {
            stSharesMinted = stDeposit($, _immutables, false, _collateralAssets, address(this), false);
            require(stSharesMinted != 0, IRoycoVaultTranche.MUST_MINT_NON_ZERO_SHARES());
        }

        // Add the minted ST shares and supplied quote assets into the liquidity venue with the specified slippage check
        // The venue prices 1 whole LPT asset against the post-add pool state in both modes
        NAV_UNIT lptAssetPrice;
        (lptAssetsOut, lptAssetPrice) = IRoycoDayKernel(address(this)).addLiquidity(_isPreview, stSharesMinted, _quoteAssets, _minLPTAssetsOut);

        // Refresh the cached LPT asset price at the venue's post-add mark, so the LPT leg prices and enforces at the same post-add state in preview and execution alike
        Cache._write(CacheKey.LPT_ASSET_PRICE, toUint256(lptAssetPrice));

        // LPT leg: an in-kind LPT deposit of the minted assets at the cached price, priced and minted to the receiver by the shared primitive
        trancheSharesMinted = lptDeposit($, _immutables, false, lptAssetsOut, _receiver);

        // A preview carries its result out via this revert, unwinding every mutation this flow made
        if (_isPreview) revert DispatchLogic.SIMULATION_RESULT(abi.encode(trancheSharesMinted, lptAssetsOut));
    }

    // =============================
    // Tranche Max Deposit Functions
    // =============================

    /**
     * @notice Returns the maximum amount of assets that can be deposited into the senior tranche
     * @dev ST deposits are allowed only in a PERPETUAL market state, granted that the market's coverage and liquidity requirements are satisfied post-deposit
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _receiver The address that will receive the ST shares equating to the deposited assets
     * @return assets The maximum amount of assets that can be deposited into the senior tranche, denominated in the senior tranche's tranche units
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
        // A zero capacity needs no backward conversion, which would divide by a wiped (zero) collateral rate
        if (stMaxDepositableNAV == ZERO_NAV_UNITS) return ZERO_TRANCHE_UNITS;
        return ((stMaxDepositableNAV == MAX_NAV_UNITS) ? MAX_TRANCHE_UNITS : IRoycoDayKernel(address(this)).convertValueToCollateralAssets(stMaxDepositableNAV));
    }

    /**
     * @notice Returns the maximum amount of assets that can be deposited into the junior tranche
     * @dev JT deposits are allowed if the market is in a PERPETUAL state
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _receiver The address that will receive the JT shares equating to the deposited assets
     * @return assets The maximum amount of assets that can be deposited into the junior tranche, denominated in the junior tranche's tranche units
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
     * @notice Returns the maximum amount of assets that can be deposited into the liquidity provider tranche
     * @dev An in-kind LPT deposit mints no new senior shares and only deepens liquidity, so it is enabled in every market state and unbounded
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _receiver The address that will receive the LPT shares equating to the deposited assets
     * @return assets The maximum amount of assets that can be deposited into the liquidity provider tranche, denominated in the liquidity provider tranche's tranche units
     */
    function lptMaxDeposit(IRoycoDayKernel.RoycoDayKernelState storage $, address _receiver) external view returns (TRANCHE_UNIT assets) {
        // If the receiver is blacklisted or the kernel is currently paused, return zero tranche units
        if (BlacklistLogic._isBlacklisted($, _receiver) || PausableUpgradeable(address(this)).paused()) return ZERO_TRANCHE_UNITS;
        // In-kind LPT deposits are never gated, so the deposit is unbounded
        return MAX_TRANCHE_UNITS;
    }
}
