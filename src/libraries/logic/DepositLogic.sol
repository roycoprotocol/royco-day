// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { PausableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { IRoycoDayAccountant } from "../../interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { MAX_NAV_UNITS, MAX_TRANCHE_UNITS, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../Constants.sol";
import { AssetClaims, DispatchMode, MarketState, SyncedAccountingState, TrancheType, toDepositOperation } from "../Types.sol";
import { Math, NAV_UNIT, TRANCHE_UNIT } from "../Units.sol";
import { AccountingSyncLogic } from "./AccountingSyncLogic.sol";
import { AssetLedgerLogic } from "./AssetLedgerLogic.sol";
import { BlacklistLogic } from "./BlacklistLogic.sol";
import { DispatchLogic } from "./DispatchLogic.sol";
import { ValuationLogic } from "./ValuationLogic.sol";

/**
 * @title DepositLogic
 * @author Waymont
 * @notice The in-kind tranche deposit flow and max-deposit reads for a Royco market
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
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _trancheType An enumerator indicating which tranche to deposit into
     * @param _mode The dispatch mode: SIMULATE computes the operation and unwinds every mutation by reverting with its result, EXECUTE settles it
     * @param _assets The amount of assets to deposit, denominated in the specified tranche's tranche units
     * @param _caller The address that initiated the deposit
     * @param _receiver The address that receives the minted tranche shares
     * @return trancheSharesMinted The number of tranche shares minted to the receiver for the deposit
     */
    function inkindDeposit(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        TrancheType _trancheType,
        DispatchMode _mode,
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
        // The claim NAV is the tranche's pre-deposit effective NAV and the supply includes the sync's premium and protocol fee mints, the pair the shares price against
        (SyncedAccountingState memory state, AssetClaims memory claims, uint256 totalTrancheShares) =
            AccountingSyncLogic._preOpSyncTrancheAccounting($, _immutables, _trancheType);

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
        IRoycoVaultTranche(AssetLedgerLogic._getTrancheAddress(_immutables, _trancheType)).kernelMint(_receiver, trancheSharesMinted);

        // Execute a post-deposit sync on accounting, enforcing the market's coverage and liquidity requirements against new senior exposure
        // A JT deposit grows the loss-absorption buffer and an in-kind LPT deposit only adds market-making depth, so the post-op enforces nothing for them
        AccountingSyncLogic._postOpSyncTrancheAccounting($, _immutables, toDepositOperation(_trancheType), ZERO_NAV_UNITS);

        // A preview carries its result out via this revert, unwinding every mutation this flow made
        if (_mode == DispatchMode.SIMULATE) revert DispatchLogic.SIMULATION_RESULT(abi.encode(trancheSharesMinted));
    }

    // =============================
    // Tranche Max Deposit Functions
    // =============================

    /**
     * @notice Returns the maximum amount of assets that can be deposited in-kind into the specified tranche
     * @dev ST deposits are allowed only in a PERPETUAL market state, granted that the market's coverage and liquidity requirements are satisfied post-deposit
     * @dev JT deposits are allowed only in a PERPETUAL market state and are unbounded
     * @dev An in-kind LPT deposit mints no new senior shares and only deepens liquidity, so it is enabled in every market state and unbounded
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _trancheType An enumerator indicating which tranche to return the max deposit for
     * @param _receiver The address that will receive the tranche shares equating to the deposited assets
     * @return assets The maximum amount of assets that can be deposited into the specified tranche, denominated in its tranche units
     */
    function inkindMaxDeposit(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
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
        SyncedAccountingState memory state = AccountingSyncLogic._previewSyncTrancheAccounting($, _immutables);
        if (state.marketState == MarketState.FIXED_TERM) return ZERO_TRANCHE_UNITS;
        // JT deposits only grow the loss-absorption buffer, so the deposit is unbounded
        if (_trancheType == TrancheType.JUNIOR) return MAX_TRANCHE_UNITS;

        // ST deposits are enabled as long as the market's coverage and liquidity requirements are satisfied
        NAV_UNIT stMaxDepositableNAV = IRoycoDayAccountant(_immutables.accountant).maxSTDeposit(state);
        // Preemptively return if there is no capacity for marginal value
        if (stMaxDepositableNAV == ZERO_NAV_UNITS) return ZERO_TRANCHE_UNITS;
        return ((stMaxDepositableNAV == MAX_NAV_UNITS) ? MAX_TRANCHE_UNITS : IRoycoDayKernel(address(this)).convertValueToCollateralAssets(stMaxDepositableNAV));
    }
}
