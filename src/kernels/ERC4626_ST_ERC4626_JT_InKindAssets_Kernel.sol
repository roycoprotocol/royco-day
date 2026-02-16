// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoKernelInitParams } from "../libraries/RoycoKernelStorageLib.sol";
import { NAV_UNIT } from "../libraries/Units.sol";
import { RoycoKernel } from "./base/RoycoKernel.sol";
import { InKindAssetsQuoter } from "./base/quoter/InKindAssetsQuoter.sol";
import { AtomicLiquidationFacility } from "./base/liquidation-facility/AtomicLiquidationFacility.sol";
import { ERC4626_ST_ERC4626_JT_Kernel } from "./base/recipe/ERC4626_ST_ERC4626_JT_Kernel.sol";

/**
 * @title ERC4626_ST_ERC4626_JT_InKindAssets_Kernel
 * @author Waymont
 * @notice The senior and junior tranches are deployed into a ERC4626 compliant vault
 * @notice The two tranches can be deployed into the same ERC4626 compliant vault
 * @notice The tranche assets are identical in value and can have differing precisions (eg. USDC and USDS, USDT and USDe, etc.)
 * @notice NAV units are always expressed in tranche units scaled to WAD (18 decimals) precision
 */
contract ERC4626_ST_ERC4626_JT_InKindAssets_Kernel is ERC4626_ST_ERC4626_JT_Kernel, InKindAssetsQuoter, AtomicLiquidationFacility {
    /**
     * @notice Constructs the Royco kernel
     * @param _params The standard construction parameters for the Royco kernel
     * @param _stVault The address of the ERC4626 compliant vault that the senior tranche will deploy into
     * @param _jtVault The address of the ERC4626 compliant vault that the junior tranche will deploy into
     */
    constructor(RoycoKernelConstructionParams memory _params, address _stVault, address _jtVault) ERC4626_ST_ERC4626_JT_Kernel(_params, _stVault, _jtVault) { }

    /**
     * @notice Initializes the Royco Kernel
     * @param _params The standard initialization parameters for the Royco Kernel
     */
    function initialize(RoycoKernelInitParams calldata _params) external initializer {
        // Initialize the base kernel state
        __ERC4626_ST_ERC4626_JT_Kernel_init(_params);
    }

    /// @inheritdoc ERC4626_ST_ERC4626_JT_Kernel
    function stMaxWithdrawable(address _owner)
        public
        view
        virtual
        override(RoycoKernel, ERC4626_ST_ERC4626_JT_Kernel)
        returns (
            NAV_UNIT claimOnStNAV,
            NAV_UNIT claimOnJtNAV,
            NAV_UNIT stMaxWithdrawableNAV,
            NAV_UNIT jtMaxWithdrawableNAV,
            uint256 totalTrancheSharesAfterMintingFees
        )
    {
        return ERC4626_ST_ERC4626_JT_Kernel.stMaxWithdrawable(_owner);
    }

    /// @inheritdoc ERC4626_ST_ERC4626_JT_Kernel
    function jtMaxWithdrawable(address _owner)
        public
        view
        virtual
        override(RoycoKernel, ERC4626_ST_ERC4626_JT_Kernel)
        returns (
            NAV_UNIT claimOnStNAV,
            NAV_UNIT claimOnJtNAV,
            NAV_UNIT stMaxWithdrawableNAV,
            NAV_UNIT jtMaxWithdrawableNAV,
            uint256 totalTrancheSharesAfterMintingFees
        )
    {
        return ERC4626_ST_ERC4626_JT_Kernel.jtMaxWithdrawable(_owner);
    }
}
