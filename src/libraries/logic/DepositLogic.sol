// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { PausableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { IRoycoDayAccountant } from "../../interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { Cache, CacheKey } from "../Cache.sol";
import { MAX_NAV_UNITS, MAX_TRANCHE_UNITS, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../Constants.sol";
import { AssetClaims, DispatchMode, MarketState, SyncedAccountingState, TrancheType, toDepositOperation } from "../Types.sol";
import { Math, NAV_UNIT, TRANCHE_UNIT, toUint256 } from "../Units.sol";
import { AccountingSyncLogic } from "./AccountingSyncLogic.sol";
import { AssetLedgerLogic } from "./AssetLedgerLogic.sol";
import { BlacklistLogic } from "./BlacklistLogic.sol";
import { DispatchLogic } from "./DispatchLogic.sol";
import { ValuationLogic } from "./ValuationLogic.sol";

/**
 * @title DepositLogic
 * @author Waymont
 * @notice The in-kind and multi-asset tranche deposit flows and max-deposit reads for a Royco market
 * @dev Invoked by the kernel via delegatecall
 */
library DepositLogic {
    // =============================
    // Tranche Deposit Functions
    // =============================

    /**
     * @notice Processes the in-kind deposit of a specified amount of the tranche's own assets into the specified tranche
     * @dev Assumes that the funds are transferred to the kernel before the deposit call is made
     * @dev Screens the caller and receiver against the market's blacklist so no blacklisted account can initiate or receive the deposit
     * @dev ST and JT deposits are enabled only in a PERPETUAL market state, the ST deposit granted that the market's coverage and liquidity requirements are satisfied post-deposit
     * @dev An in-kind LPT deposit mints no new senior shares and only deepens liquidity, so it is enabled in every market state (including fixed-term) and enforces no requirements
     * @param $ The storage state of the Royco Kernel that is delegatecalling into this function
     * @param _mode The dispatch mode: SIMULATE computes the operation and unwinds every mutation by reverting with its result, EXECUTE settles it
     * @param _trancheType An enumerator indicating which tranche to deposit into
     * @param _assets The amount of assets to deposit, denominated in the specified tranche's tranche units
     * @param _caller The address that initiated the deposit, the null address for a simulation's synthetic caller (a composite flow forwards its own resolved caller)
     * @param _receiver The address that receives the minted tranche shares
     * @return trancheSharesMinted The number of tranche shares minted to the receiver for the deposit
     */
    function inkindDeposit(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        DispatchMode _mode,
        TrancheType _trancheType,
        TRANCHE_UNIT _assets,
        address _caller,
        address _receiver
    )
        public
        returns (uint256 trancheSharesMinted)
    {
        // Screen the deposit's involved accounts against the market's blacklist so no blacklisted account can initiate or receive the deposit
        BlacklistLogic._enforceNotBlacklisted($, _caller, _receiver);

        // Execute an accounting sync to reconcile underlying PNL and read the deposited tranche's post-mint claims and supply
        // The claim NAV is the tranche's pre-deposit effective NAV and the supply includes the sync's premium and protocol fee mints
        (SyncedAccountingState memory state, AssetClaims memory claims, uint256 totalTrancheShares) =
            AccountingSyncLogic.preOpSyncTrancheAccountingFor($, _trancheType);

        // ST and JT deposits are disabled during a fixed-term market state
        require(_trancheType == TrancheType.LIQUIDITY_PROVIDER || state.marketState == MarketState.PERPETUAL, IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE());

        // The deposit NAV is the value of the deposited assets: the venue's position token for the LPT, the coinvested collateral otherwise
        NAV_UNIT depositNAV = (_trancheType == TrancheType.LIQUIDITY_PROVIDER)
            ? IRoycoDayKernel(address(this)).convertLPTAssetsToValue(_assets)
            : IRoycoDayKernel(address(this)).convertCollateralAssetsToValue(_assets);

        // Credit the deposited assets to the tranche
        AssetLedgerLogic._creditAssets($, _trancheType, _assets);

        // Price the shares at the pre-deposit effective NAV and mint them to the receiver, rejecting a deposit that prices to zero shares
        // NOTE: The effective NAV can be zero initially when the tranche is deployed
        trancheSharesMinted = ValuationLogic._convertToShares(depositNAV, claims.nav, totalTrancheShares, Math.Rounding.Floor);
        require(trancheSharesMinted != 0, IRoycoDayKernel.MUST_MINT_NON_ZERO_SHARES());
        IRoycoVaultTranche(AssetLedgerLogic._getTrancheAddress($, _trancheType)).kernelMint(_receiver, trancheSharesMinted);

        // Execute a post-deposit sync on accounting, enforcing the market's coverage and liquidity requirements against new senior exposure
        // A JT deposit grows the loss-absorption buffer and an in-kind LPT deposit only adds market-making depth, so the post-op enforces nothing for them
        AccountingSyncLogic.postOpSyncTrancheAccounting($, toDepositOperation(_trancheType), ZERO_NAV_UNITS);

        // A preview carries its result out via this revert, unwinding every mutation this flow made
        if (_mode == DispatchMode.SIMULATE) revert DispatchLogic.SIMULATION_RESULT(abi.encode(trancheSharesMinted));
    }

    /**
     * @notice Atomically enters the liquidity provider tranche with the LPT assets' constituent assets: deposits collateral (minting senior
     *         shares), adds (senior shares + quote) into the liquidity venue to mint the LPT tranche assets, then deposits them into the LPT
     * @dev Composed from the shared deposit primitives: an ST deposit seeding the add's senior shares, the venue add, then an LPT deposit of the minted assets
     * @dev Screens the caller and receiver at the flow entry and forwards its caller into the inner legs, mirroring the multi-asset redemption's caller forwarding
     * @dev Assumes the collateral and quote have been transferred to the kernel before this call (by the LPT tranche)
     * @dev Enabled in a PERPETUAL market state, and in a fixed-term market only for a quote-only deposit that mints no senior shares
     * @dev The flow's intermediate legs defer the liquidity requirement to the final leg's settled state, whose unhealed violation the end-of-flow gate reverts on
     * @dev Prices the shares at the pre-deposit LPT effective NAV against the venue's post-add mark and mints them to the receiver
     * @dev A preview never returns: the flow unwinds every mutation by reverting with SIMULATION_RESULT carrying the ABI encoded return values
     * @param $ The storage state of the Royco Kernel that is delegatecalling into this function
     * @param _mode The dispatch mode: SIMULATE computes the operation and unwinds every mutation by reverting with its result, EXECUTE settles it
     * @param _collateralAssets The amount of collateral to deposit for the senior leg, denominated in tranche units
     * @param _quoteAssets The amount of quote asset to add as the second venue leg
     * @param _minLPTAssetsOut The minimum LPT tranche assets the liquidity add must mint (slippage bound against an unfavorable venue state)
     * @param _caller The address that initiated the deposit
     * @param _receiver The address that receives the minted tranche shares
     * @return trancheSharesMinted The number of tranche shares minted to the receiver for the deposit
     * @return lptAssetsOut The amount of LPT tranche assets minted and credited to the liquidity provider tranche
     */
    function lptDepositMultiAsset(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        DispatchMode _mode,
        TRANCHE_UNIT _collateralAssets,
        uint256 _quoteAssets,
        TRANCHE_UNIT _minLPTAssetsOut,
        address _caller,
        address _receiver
    )
        external
        returns (uint256 trancheSharesMinted, TRANCHE_UNIT lptAssetsOut)
    {
        // Screen the deposit's involved accounts against the market's blacklist so no blacklisted account can initiate or receive the deposit
        BlacklistLogic._enforceNotBlacklisted($, _caller, _receiver);

        // Mark the multi-asset flow, whose exit below judges the liquidity requirement at the flow's final settled state
        AccountingSyncLogic._enterMultiAssetFlow();

        // Collateral leg: an ST deposit minting the add's senior shares to the kernel
        // Its post-op waives the liquidity requirement that this operation may satisfy below with the added liquidity
        uint256 stSharesMinted;
        if (_collateralAssets != ZERO_TRANCHE_UNITS) {
            stSharesMinted = inkindDeposit($, DispatchMode.EXECUTE, TrancheType.SENIOR, _collateralAssets, _caller, address(this));
        }

        // Add the minted ST shares and supplied quote assets into the liquidity venue with the specified slippage check
        NAV_UNIT lptAssetPrice;
        (lptAssetsOut, lptAssetPrice) = IRoycoDayKernel(address(this)).addLiquidity(_mode, stSharesMinted, _quoteAssets, _minLPTAssetsOut);

        // Cache the venue's post-add price for a preview, whose unwound add would otherwise price the pre-add pool live
        // Execution caches nothing: the LPT leg prices the settled post-add pool live at the same mark
        if (_mode == DispatchMode.SIMULATE) Cache._write(CacheKey.LPT_ASSET_PRICE, toUint256(lptAssetPrice));

        // LPT leg: an in-kind LPT deposit of the minted assets at the post-add price, priced and minted to the receiver by the shared primitive
        // Its in-flow post-op enforces the liquidity requirement against this flow's settled state
        trancheSharesMinted = inkindDeposit($, DispatchMode.EXECUTE, TrancheType.LIQUIDITY_PROVIDER, lptAssetsOut, _caller, _receiver);

        // Exit the settled multi-asset flow, reverting on a pending liquidity violation its final settled state never healed
        AccountingSyncLogic._exitMultiAssetFlow();

        // A preview carries its result out via this revert, unwinding every mutation this flow made
        if (_mode == DispatchMode.SIMULATE) revert DispatchLogic.SIMULATION_RESULT(abi.encode(trancheSharesMinted, lptAssetsOut));
    }

    // =============================
    // Tranche Max Deposit Functions
    // =============================

    /**
     * @notice Returns the maximum amount of assets that can be deposited in-kind into the specified tranche
     * @dev ST deposits are allowed only in a PERPETUAL market state, granted that the market's coverage and liquidity requirements are satisfied post-deposit
     * @dev JT deposits are allowed only in a PERPETUAL market state and are unbounded
     * @dev An in-kind LPT deposit mints no new senior shares and only deepens liquidity, so it is enabled in every market state and unbounded
     * @param $ The storage state of the Royco Kernel that is delegatecalling into this function
     * @param _trancheType An enumerator indicating which tranche to return the max deposit for
     * @param _receiver The address that will receive the tranche shares equating to the deposited assets
     * @return assets The maximum amount of assets that can be deposited into the specified tranche, denominated in its tranche units
     */
    function inkindMaxDeposit(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        TrancheType _trancheType,
        address _receiver
    )
        external
        view
        returns (TRANCHE_UNIT assets)
    {
        // If the receiver is blacklisted or the kernel is currently paused, return zero tranche units
        if (BlacklistLogic._isBlacklisted($, _receiver) || PausableUpgradeable(address(this)).paused()) return ZERO_TRANCHE_UNITS;
        // In-kind LPT deposits are never gated, so the deposit is unbounded
        if (_trancheType == TrancheType.LIQUIDITY_PROVIDER) return MAX_TRANCHE_UNITS;

        // ST and JT deposits are disabled during a fixed-term market state
        SyncedAccountingState memory state = AccountingSyncLogic.previewPreOpSyncTrancheAccounting($);
        if (state.marketState == MarketState.FIXED_TERM) return ZERO_TRANCHE_UNITS;
        // JT deposits only grow the loss-absorption buffer, so the deposit is unbounded
        if (_trancheType == TrancheType.JUNIOR) return MAX_TRANCHE_UNITS;

        // ST deposits are enabled as long as the market's coverage and liquidity requirements are satisfied
        NAV_UNIT stMaxDepositableNAV = IRoycoDayAccountant($.accountant).maxSTDeposit(state);
        // Preemptively return if there is no capacity for marginal value
        if (stMaxDepositableNAV == ZERO_NAV_UNITS) return ZERO_TRANCHE_UNITS;
        return ((stMaxDepositableNAV == MAX_NAV_UNITS) ? MAX_TRANCHE_UNITS : IRoycoDayKernel(address(this)).convertValueToCollateralAssets(stMaxDepositableNAV));
    }
}
