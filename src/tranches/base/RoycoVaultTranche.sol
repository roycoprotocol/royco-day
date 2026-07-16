// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ERC20Upgradeable, IERC20, IERC20Metadata } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import { ERC20BurnableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import { ERC20PausableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import { ERC20PermitUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { SafeERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { RoycoBase } from "../../base/RoycoBase.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { WAD_DECIMALS, ZERO_NAV_UNITS } from "../../libraries/Constants.sol";
import { AssetClaims, SyncedAccountingState, TrancheType } from "../../libraries/Types.sol";
import { NAV_UNIT, RoycoUnitsMath, TRANCHE_UNIT, toUint256 } from "../../libraries/Units.sol";
import { TrancheClaimsLogic } from "../../libraries/logic/TrancheClaimsLogic.sol";
import { ValuationLogic } from "../../libraries/logic/ValuationLogic.sol";

/**
 * @title RoycoVaultTranche
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Abstract base contract implementing core vault functionality for Royco tranches (ST, JT, and LT)
 * @dev Tranches interact with the kernel to execute all operations based on the current holistic state of the Royco market
 */
abstract contract RoycoVaultTranche is IRoycoVaultTranche, RoycoBase, ERC20PausableUpgradeable, ERC20BurnableUpgradeable, ERC20PermitUpgradeable {
    using Math for uint256;
    using RoycoUnitsMath for uint256;
    using SafeERC20 for IERC20;

    /// @dev The address of the yield bearing asset of the tranche
    address internal immutable ASSET;

    /// @inheritdoc IRoycoVaultTranche
    address public immutable override(IRoycoVaultTranche) KERNEL;

    /// @dev Permissions the function to only be callable by the kernel, the single source of truth for sync-driven share mints
    modifier onlyKernel() {
        require(msg.sender == KERNEL, ONLY_KERNEL());
        _;
    }

    /**
     * @notice Constructs the Royco vault tranche
     * @param _asset The underlying asset for the tranche
     * @param _kernel The kernel that handles the core market logic and accounting synchronization
     */
    constructor(address _asset, address _kernel) {
        // Ensure that the asset and kernel are not null
        require(_asset != address(0) && _kernel != address(0), NULL_ADDRESS());

        // Set the immutable state
        ASSET = _asset;
        KERNEL = _kernel;
    }

    /**
     * @notice Initializes the Royco tranche
     * @dev This function initializes parent contracts and the tranche-specific state
     * @param _params Deployment parameters including name, symbol, and initial authority
     */
    function __RoycoTranche_init(RoycoTrancheInitParams calldata _params) internal onlyInitializing {
        // Initialize all the parent contracts
        __RoycoBase_init(_params.initialAuthority);
        __ERC20_init_unchained(_params.name, _params.symbol);
        __ERC20Pausable_init();
        __ERC20Burnable_init();
        __ERC20Permit_init(_params.name);
    }

    /**
     * =============================
     * Tranche Deposit and Redeem Functions
     * =============================
     */

    /// @inheritdoc IRoycoVaultTranche
    function deposit(TRANCHE_UNIT _assets, address _receiver) public virtual override(IRoycoVaultTranche) whenNotPaused restricted returns (uint256 shares) {
        require(_receiver != address(0), ERC20InvalidReceiver(address(0)));

        // Transfer the assets to the kernel
        IERC20(ASSET).safeTransferFrom(msg.sender, KERNEL, toUint256(_assets));

        // Deposit the assets into the Royco market and get the fraction of total assets allocated
        NAV_UNIT valueAllocated;
        NAV_UNIT effectiveNAVToMintAt;
        if (TRANCHE_TYPE() == TrancheType.SENIOR) (valueAllocated, effectiveNAVToMintAt) = IRoycoDayKernel(KERNEL).stDeposit(_assets);
        else if (TRANCHE_TYPE() == TrancheType.JUNIOR) (valueAllocated, effectiveNAVToMintAt) = IRoycoDayKernel(KERNEL).jtDeposit(_assets);
        else (valueAllocated, effectiveNAVToMintAt) = IRoycoDayKernel(KERNEL).ltDeposit(_assets);

        // effectiveNAVToMintAt can be zero initially when the tranche is deployed
        require(valueAllocated != ZERO_NAV_UNITS, INVALID_VALUE_ALLOCATED());

        // valueAllocated represents the value of the assets deposited in the asset that the tranche's NAV is denominated in
        // shares are minted to the user at the effective NAV of the tranche
        // effectiveNAVToMintAt is the effective NAV of the tranche before the deposit is made, ie. the NAV at which the shares will be minted
        shares = ValuationLogic._convertToShares(valueAllocated, effectiveNAVToMintAt, totalSupply(), Math.Rounding.Floor);
        require(shares != 0, MUST_MINT_NON_ZERO_SHARES());

        // Mint the shares to the receiver
        _mint(_receiver, shares);

        emit Deposit(msg.sender, _receiver, _assets, shares);
    }

    /// @inheritdoc IRoycoVaultTranche
    function redeem(
        uint256 _shares,
        address _receiver,
        address _owner
    )
        public
        virtual
        override(IRoycoVaultTranche)
        whenNotPaused
        restricted
        returns (AssetClaims memory claims)
    {
        require(_receiver != address(0), ERC20InvalidReceiver(address(0)));
        require(_shares != 0, MUST_REQUEST_NON_ZERO_SHARES());

        // Spend allowance if msg.sender is not the owner
        if (msg.sender != _owner) _spendAllowance(_owner, msg.sender, _shares);

        // Process the withdrawal from the Royco market
        // It is expected that the kernel transfers the assets directly to the receiver
        if (TRANCHE_TYPE() == TrancheType.SENIOR) claims = IRoycoDayKernel(KERNEL).stRedeem(_shares, _receiver);
        else if (TRANCHE_TYPE() == TrancheType.JUNIOR) claims = IRoycoDayKernel(KERNEL).jtRedeem(_shares, _receiver);
        else claims = IRoycoDayKernel(KERNEL).ltRedeem(_shares, _receiver);

        // Burn shares after kernel processes redemption (kernel depends on pre-burn total supply)
        _burn(_owner, _shares);

        emit Redeem(msg.sender, _receiver, claims, _shares);
    }

    /// @inheritdoc IRoycoVaultTranche
    function mintProtocolFeeShares(
        address _protocolFeeRecipient,
        uint256 _protocolFeeShares
    )
        external
        virtual
        override(IRoycoVaultTranche)
        onlyKernel
        returns (uint256 totalTrancheShares)
    {
        // Mint the precomputed protocol fee shares to the recipient (the kernel prices them jointly with the liquidity premium)
        if (_protocolFeeShares != 0) _mint(_protocolFeeRecipient, _protocolFeeShares);

        totalTrancheShares = totalSupply();
        emit ProtocolFeeSharesMinted(_protocolFeeRecipient, _protocolFeeShares, totalTrancheShares);
    }

    /// @inheritdoc IRoycoVaultTranche
    function mint(address _to, uint256 _shares) external virtual override(IRoycoVaultTranche) whenNotPaused onlyKernel {
        require(_to != address(0), ERC20InvalidReceiver(address(0)));
        require(_shares != 0, MUST_MINT_NON_ZERO_SHARES());
        _mint(_to, _shares);
    }

    /// @inheritdoc ERC20BurnableUpgradeable
    function burn(uint256 _shares) public virtual override(ERC20BurnableUpgradeable) whenNotPaused restricted {
        super.burn(_shares);
    }

    /// @inheritdoc ERC20BurnableUpgradeable
    function burnFrom(address _account, uint256 _shares) public virtual override(ERC20BurnableUpgradeable) whenNotPaused restricted {
        super.burnFrom(_account, _shares);
    }

    /**
     * =============================
     * Tranche Preview and Conversion Functions
     * =============================
     */

    /// @inheritdoc IRoycoVaultTranche
    function previewDeposit(TRANCHE_UNIT _assets) external view virtual override(IRoycoVaultTranche) returns (uint256 shares) {
        // Get the value allocated, the NAV to mint shares at (the tranche's pre-deposit effective NAV), and the post-sync supply after the
        // premium and protocol fee shares are minted (the kernel is the single source of truth for the post-sync supply)
        NAV_UNIT valueAllocated;
        NAV_UNIT effectiveNAV;
        uint256 totalTrancheShares;
        if (TRANCHE_TYPE() == TrancheType.SENIOR) {
            SyncedAccountingState memory stateBeforeDeposit;
            (stateBeforeDeposit, valueAllocated, totalTrancheShares) = IRoycoDayKernel(KERNEL).stPreviewDeposit(_assets);
            effectiveNAV = stateBeforeDeposit.stEffectiveNAV;
        } else if (TRANCHE_TYPE() == TrancheType.JUNIOR) {
            SyncedAccountingState memory stateBeforeDeposit;
            (stateBeforeDeposit, valueAllocated, totalTrancheShares) = IRoycoDayKernel(KERNEL).jtPreviewDeposit(_assets);
            effectiveNAV = stateBeforeDeposit.jtEffectiveNAV;
        } else {
            // The LT prices its shares at the effective NAV (value deployed into the AMM or another market-making venue plus the idle liquidity-premium senior shares), which is not
            // carried in SyncedAccountingState, so the kernel surfaces it directly as navToMintSharesAt
            (, valueAllocated, totalTrancheShares, effectiveNAV) = IRoycoDayKernel(KERNEL).ltPreviewDeposit(_assets);
        }

        // Calculate the shares to be minted to the receiver against the post-sync supply, so the preview matches execution
        shares = ValuationLogic._convertToShares(valueAllocated, effectiveNAV, totalTrancheShares, Math.Rounding.Floor);
    }

    /// @inheritdoc IRoycoVaultTranche
    function previewRedeem(uint256 _shares) external view virtual override(IRoycoVaultTranche) returns (AssetClaims memory claims) {
        if (TRANCHE_TYPE() == TrancheType.SENIOR) claims = IRoycoDayKernel(KERNEL).stPreviewRedeem(_shares);
        else if (TRANCHE_TYPE() == TrancheType.JUNIOR) claims = IRoycoDayKernel(KERNEL).jtPreviewRedeem(_shares);
        else claims = IRoycoDayKernel(KERNEL).ltPreviewRedeem(_shares);
    }

    /// @inheritdoc IRoycoVaultTranche
    function convertToAssets(uint256 _shares) public view virtual override(IRoycoVaultTranche) returns (AssetClaims memory claims) {
        // Get the post-sync tranche state: applying NAV reconciliation
        (SyncedAccountingState memory state, AssetClaims memory trancheClaims, uint256 trancheTotalShares) =
            IRoycoDayKernel(KERNEL).previewSyncTrancheAccounting(TRANCHE_TYPE());
        if (TRANCHE_TYPE() == TrancheType.LIQUIDITY) {
            // We exclude any idle (not reinvested) ST shares from the LT claims in order to ensure that its share price does not drop due to slippage incurred on reinvestment
            trancheClaims.stShares = 0;
            trancheClaims.nav = state.ltRawNAV;
        }
        return TrancheClaimsLogic._scaleAssetClaims(trancheClaims, _shares, trancheTotalShares);
    }

    /// @inheritdoc IRoycoVaultTranche
    function convertToShares(TRANCHE_UNIT _assets) public view virtual override(IRoycoVaultTranche) returns (uint256 shares) {
        // Value the assets specified in NAV units
        NAV_UNIT value;
        if (TRANCHE_TYPE() == TrancheType.SENIOR) value = IRoycoDayKernel(KERNEL).stConvertTrancheUnitsToNAVUnits(_assets);
        else if (TRANCHE_TYPE() == TrancheType.JUNIOR) value = IRoycoDayKernel(KERNEL).jtConvertTrancheUnitsToNAVUnits(_assets);
        else value = IRoycoDayKernel(KERNEL).ltConvertTrancheUnitsToNAVUnits(_assets);

        // Get the post-sync tranche state
        (SyncedAccountingState memory state, AssetClaims memory trancheClaims, uint256 trancheTotalShares) =
            IRoycoDayKernel(KERNEL).previewSyncTrancheAccounting(TRANCHE_TYPE());

        // We exclude any idle (not reinvested) ST shares from the LT NAV basis in order to ensure that its NAV per share does not drop due to slippage incurred on reinvestment
        NAV_UNIT navBasis = ((TRANCHE_TYPE() == TrancheType.LIQUIDITY) ? state.ltRawNAV : trancheClaims.nav);
        shares = ValuationLogic._convertToShares(value, navBasis, trancheTotalShares, Math.Rounding.Floor);
    }

    /**
     * =============================
     * Tranche Max Deposit and Redeem Functions
     * =============================
     */

    /// @inheritdoc IRoycoVaultTranche
    function maxDeposit(address _receiver) external view virtual override(IRoycoVaultTranche) returns (TRANCHE_UNIT assets) {
        if (TRANCHE_TYPE() == TrancheType.SENIOR) assets = IRoycoDayKernel(KERNEL).stMaxDeposit(_receiver);
        else if (TRANCHE_TYPE() == TrancheType.JUNIOR) assets = IRoycoDayKernel(KERNEL).jtMaxDeposit(_receiver);
        else assets = IRoycoDayKernel(KERNEL).ltMaxDeposit(_receiver);
    }

    /// @inheritdoc IRoycoVaultTranche
    function maxRedeem(address _owner) public view virtual override(IRoycoVaultTranche) returns (uint256 shares) {
        uint256 sharesOwned = balanceOf(_owner);

        if (TRANCHE_TYPE() == TrancheType.SENIOR || TRANCHE_TYPE() == TrancheType.JUNIOR) {
            //  We query the kernel for (a) N_s and N_j - the notional claim of the tranche on the ST and JT assets respectively in NAV units, and
            //                          (b) L_s and L_j - the amount that can be withdrawn from the senior and junior tranches globally in NAV units, respectively
            //  When shares are redeemed, assets from the senior and junior tranches are withdrawn proportionally to the notional claims of the tranche on the respective assets
            //  But, the global max withdrawable assets for each tranche are also considered, these are inclusive of any coverage requirements, as well as liquidity constraints
            //  If T respresents the total shares in the tranche, s the total shares owned by the owner, then the maximum amount of shares that can be redeemed s' is subject to:
            //      (a) s' * N_s / T  <= min(s * N_s / T, L_s) => s' <= min(s, T * L_s / N_s)
            //      (b) s' * N_j / T  <= min(s * N_j / T, L_j) => s' <= min(s, T * L_j / N_j)
            //  Therefore, the maximum amount of shares that can be redeemed is:
            //      s' = min(s, T * L_s / N_s, T * L_j / N_j)
            // Get the notional claims and the max withdrawable assets for the tranche
            (NAV_UNIT claimOnSTNAV, NAV_UNIT claimOnJTNAV, NAV_UNIT stMaxWithdrawableNAV, NAV_UNIT jtMaxWithdrawableNAV, uint256 totalSharesAfterMintingFees) =
                (TRANCHE_TYPE() == TrancheType.SENIOR ? IRoycoDayKernel(KERNEL).stMaxWithdrawable(_owner) : IRoycoDayKernel(KERNEL).jtMaxWithdrawable(_owner));

            // We do not allow redemptions if the tranche has no claims on the assets
            if (claimOnSTNAV + claimOnJTNAV == ZERO_NAV_UNITS) return 0;

            // Calculate the maximum amount of shares that can be redeemed based on the senior and junior constraints
            // If the notional claim of the tranche on the ST or JT assets is zero, ignore the constraints since the tranche has no claims on the assets
            uint256 sharesWithdrawableBasedOnSeniorConstraints =
                claimOnSTNAV == ZERO_NAV_UNITS ? sharesOwned : totalSharesAfterMintingFees.mulDiv(stMaxWithdrawableNAV, claimOnSTNAV, Math.Rounding.Floor);
            uint256 sharesWithdrawableBasedOnJuniorConstraints =
                claimOnJTNAV == ZERO_NAV_UNITS ? sharesOwned : totalSharesAfterMintingFees.mulDiv(jtMaxWithdrawableNAV, claimOnJTNAV, Math.Rounding.Floor);
            shares = Math.min(sharesOwned, Math.min(sharesWithdrawableBasedOnSeniorConstraints, sharesWithdrawableBasedOnJuniorConstraints));
        } else {
            // The liquidity tranche has claims only on its own RAW NAV
            (NAV_UNIT claimOnLTNAV, NAV_UNIT ltMaxWithdrawableNAV, uint256 totalTrancheSharesAfterMintingFees) =
                IRoycoDayKernel(KERNEL).ltMaxWithdrawable(_owner);

            // We do not allow redemptions if the tranche has no claims on the assets
            if (claimOnLTNAV == ZERO_NAV_UNITS) return 0;

            shares = Math.min(sharesOwned, totalTrancheSharesAfterMintingFees.mulDiv(ltMaxWithdrawableNAV, claimOnLTNAV, Math.Rounding.Floor));
        }
    }

    /**
     * =============================
     * General Tranche View Functions
     * =============================
     */

    /// @inheritdoc IRoycoVaultTranche
    function totalAssets() external view virtual override(IRoycoVaultTranche) returns (AssetClaims memory claims) {
        (, claims,) = IRoycoDayKernel(KERNEL).previewSyncTrancheAccounting(TRANCHE_TYPE());
    }

    /// @inheritdoc IRoycoVaultTranche
    function getRawNAV() external view virtual override(IRoycoVaultTranche) returns (NAV_UNIT nav) {
        (SyncedAccountingState memory state,,) = IRoycoDayKernel(KERNEL).previewSyncTrancheAccounting(TRANCHE_TYPE());
        if (TRANCHE_TYPE() == TrancheType.SENIOR) return state.stRawNAV;
        else if (TRANCHE_TYPE() == TrancheType.JUNIOR) return state.jtRawNAV;
        else return state.ltRawNAV;
    }

    /// @inheritdoc IRoycoVaultTranche
    function asset() external view virtual override(IRoycoVaultTranche) returns (address) {
        return ASSET;
    }

    /**
     * @inheritdoc IERC20Metadata
     * @dev The kernel always uses WAD precision for NAV units
     * @dev Shares are minted using NAV_UNIT values instead of TRANCHE_UNIT values, so they have identical precision to NAV_UNIT values (WAD precision)
     */
    function decimals() public view virtual override(ERC20Upgradeable, IERC20Metadata) returns (uint8) {
        return uint8(WAD_DECIMALS);
    }

    /// @dev Returns the type of the tranche (Senior, Junior, or Liquidity)
    function TRANCHE_TYPE() public pure virtual returns (TrancheType);

    /// @inheritdoc ERC20PausableUpgradeable
    function _update(address _from, address _to, uint256 _value) internal override(ERC20PausableUpgradeable, ERC20Upgradeable) whenNotPaused {
        // Call the kernel's pre-balance update hook to assert that the balance update is valid
        IRoycoDayKernel(KERNEL).preTrancheBalanceUpdateHook(msg.sender, _from, _to, _value);

        // Call the parent contract's update function to update the balance
        ERC20Upgradeable._update(_from, _to, _value);
    }
}
