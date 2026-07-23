// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { Initializable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import {
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel as DayKernel
} from "../../../src/kernels/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel.sol";
import {
    IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter
} from "../../../src/kernels/base/quoter/identical-st-jt/IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter.sol";
import { BalancerV3_LT_BPTOracle_Quoter } from "../../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_BPTOracle_Quoter.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoJuniorTranche } from "../../../src/tranches/RoycoJuniorTranche.sol";
import { RoycoSeniorTranche } from "../../../src/tranches/RoycoSeniorTranche.sol";
import { MockBPT } from "../../mocks/MockBPT.sol";
import { MockERC20C } from "../../mocks/MockERC20C.sol";
import { MockERC4626C } from "../../mocks/MockERC4626C.sol";
import { MockThreeTokenVaultShim } from "../../mocks/MockThreeTokenVaultShim.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_Construction_Kernel
 * @notice Exercises the kernel family's construction- and initialization-time validation: null wiring, the
 *         coinvested tranche-vs-kernel collateral asset agreement, the liquidity pool's registration
 *         and token-pairing checks, and the optional initial conversion-rate seed
 * @dev These checks only ever run at market genesis, but each one guards a wiring mistake that would be
 *      unrecoverable behind the proxy once real deposits land, so every rejection path is pinned here
 * @dev NOTE on INVALID_BALANCER_V3_VAULT: unreachable through this kernel family by construction, the concrete
 *      kernel derives the LT quoter constructor's vault FROM the pool (BalancerPoolToken(ltAsset).getVault()), so
 *      the equality it guards is tautological here. The guard protects future subclasses passing an explicit vault
 */
contract Test_Construction_Kernel is DayMarketTestBase {
    function setUp() public {
        _deployMarket(cellA(), defaultParams());
    }

    /// @dev Builds construction params identical to the deployed market's kernel, then tests mutate one field at a time
    function _goodConstructionParams() internal view returns (IRoycoDayKernel.RoycoDayKernelConstructionParams memory) {
        return IRoycoDayKernel.RoycoDayKernelConstructionParams({
            seniorTranche: address(seniorTranche),
            juniorTranche: address(juniorTranche),
            collateralAsset: address(stJtVault),
            accountant: address(accountant),
            liquidityTranche: address(liquidityTranche),
            ltAsset: address(bpt),
            enforceVaultSharesTransferWhitelist: false
        });
    }

    /// @dev Builds initialization params identical to the deployed market's kernel with a configurable stored-rate seed and fee recipient
    function _goodInitParams(
        uint256 _initialConversionRateWAD,
        address _protocolFeeRecipient
    )
        internal
        view
        returns (IRoycoDayKernel.RoycoDayKernelInitParams memory standardParams, DayKernel.KernelSpecificInitParams memory specificParams)
    {
        standardParams = IRoycoDayKernel.RoycoDayKernelInitParams({
            initialAuthority: address(accessManager),
            protocolFeeRecipient: _protocolFeeRecipient,
            stSelfLiquidationBonusWAD: 0.01e18,
            roycoBlacklist: address(0)
        });
        specificParams = DayKernel.KernelSpecificInitParams({
            stAndJTQuoterParams: IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter.ST_JT_QuoterSpecificParams({
                initialConversionRateWAD: _initialConversionRateWAD,
                baseAssetToNavAssetOracle: address(priceFeed),
                stalenessThresholdSeconds: 1 days,
                sequencerUptimeFeed: address(0),
                gracePeriodSeconds: 1 hours
            }),
            ltQuoterParams: BalancerV3_LT_BPTOracle_Quoter.LT_QuoterSpecificParams({ bptOracle: address(bptOracle), maxReinvestmentSlippageWAD: 0.001e18 })
        });
    }

    // =============================
    // Construction-time rejections
    // =============================

    /// @notice A null senior tranche in the construction wiring is rejected before anything else can be mis-set
    function test_RevertIf_KernelConstructedWithNullSeniorTranche() public {
        IRoycoDayKernel.RoycoDayKernelConstructionParams memory params = _goodConstructionParams();
        params.seniorTranche = address(0);
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        new DayKernel(params);
    }

    /// @notice A liquidity tranche asset that is not a registered Balancer pool is rejected at construction
    function test_RevertIf_LTAssetPoolNotRegisteredWithVault() public {
        MockBPT unregisteredBpt = new MockBPT(IVault(address(balancerVault)), "Unregistered BPT", "uBPT");
        IRoycoDayKernel.RoycoDayKernelConstructionParams memory params = _goodConstructionParams();
        params.ltAsset = address(unregisteredBpt);
        vm.expectRevert(BalancerV3_LT_BPTOracle_Quoter.POOL_NOT_REGISTERED.selector);
        new DayKernel(params);
    }

    /// @notice A registered pool that does not pair the senior tranche share is rejected, the LT must market-make senior exits
    function test_RevertIf_LTAssetPoolDoesNotPairSeniorTranche() public {
        // A second pool pairing two unrelated tokens, registered with the same mock vault
        MockBPT foreignBpt = new MockBPT(IVault(address(balancerVault)), "Foreign BPT", "fBPT");
        MockERC20C tokenA = new MockERC20C("Token A", "TKA", 18);
        MockERC20C tokenB = new MockERC20C("Token B", "TKB", 6);
        balancerVault.registerPool(address(foreignBpt), [IERC20(address(tokenA)), IERC20(address(tokenB))]);

        IRoycoDayKernel.RoycoDayKernelConstructionParams memory params = _goodConstructionParams();
        params.ltAsset = address(foreignBpt);
        vm.expectRevert(BalancerV3_LT_BPTOracle_Quoter.INVALID_POOL_TOKEN_CONFIGURATION.selector);
        new DayKernel(params);
    }

    /// @notice A pool reporting three tokens is rejected at construction, the LT pool must be exactly the senior share against one quote
    function test_RevertIf_LTAssetPoolReportsThreeTokens() public {
        IERC20[] memory three = new IERC20[](3);
        three[0] = IERC20(address(seniorTranche));
        three[1] = IERC20(address(quoteToken));
        three[2] = IERC20(makeAddr("THIRD_TOKEN"));
        MockThreeTokenVaultShim shim = new MockThreeTokenVaultShim(three);
        MockBPT shimBpt = new MockBPT(IVault(address(shim)), "Shim BPT", "shBPT");

        IRoycoDayKernel.RoycoDayKernelConstructionParams memory params = _goodConstructionParams();
        params.ltAsset = address(shimBpt);
        vm.expectRevert(BalancerV3_LT_BPTOracle_Quoter.POOL_MUST_HAVE_TWO_TOKENS.selector);
        new DayKernel(params);
    }

    /// @notice A tranche wired with a null asset or a null kernel is rejected at construction
    function test_RevertIf_TrancheConstructedWithNullAssetOrKernel() public {
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        new RoycoSeniorTranche(address(0), address(kernel));
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        new RoycoSeniorTranche(address(stJtVault), address(0));
    }

    // =============================
    // Initialization-time rejections
    // =============================

    /**
     * @notice A kernel whose recorded collateral asset disagrees with what the tranches actually custody is rejected at initialization
     * @dev The constructor cannot see the tranche's asset (the tranche may not exist yet), so the agreement check runs at
     *      initialize, where the tranche is live and queryable
     */
    function test_RevertIf_KernelInitializedWithMismatchedTrancheAsset() public {
        // A fresh vault share the tranches do NOT custody, wired as the kernel's collateral asset
        MockERC4626C foreignVault = new MockERC4626C(address(stJtUnderlying), "Foreign Vault Share", "fSHARE", 18);
        foreignVault.setRate(1e18);
        IRoycoDayKernel.RoycoDayKernelConstructionParams memory params = _goodConstructionParams();
        params.collateralAsset = address(foreignVault);
        DayKernel mismatchedImpl = new DayKernel(params);

        (IRoycoDayKernel.RoycoDayKernelInitParams memory standardParams, DayKernel.KernelSpecificInitParams memory specificParams) =
            _goodInitParams(0, PROTOCOL_FEE_RECIPIENT);
        bytes memory initData = abi.encodeCall(mismatchedImpl.initialize, (standardParams, specificParams));
        vm.expectRevert(IRoycoDayKernel.TRANCHE_AND_KERNEL_ASSETS_MISMATCH.selector);
        new ERC1967Proxy(address(mismatchedImpl), initData);
    }

    /**
     * @notice A junior tranche custodying anything other than the kernel's collateral asset is rejected at
     *         initialization, both tranches must deposit the one coinvested collateral asset so the junior
     *         tranche's capital carries the senior tranche's exposure
     * @dev Coinvestment is structural now (the kernel records one COLLATERAL_ASSET), so the old distinct
     *      ST/JT asset rejection became a per-tranche asset agreement check at initialize, where the
     *      tranche is live and queryable
     */
    function test_RevertIf_KernelInitializedWithForeignJuniorTrancheAsset() public {
        // A junior tranche custodying a fresh vault share, wired against a kernel whose collateral is the fixture vault
        MockERC4626C foreignVault = new MockERC4626C(address(stJtUnderlying), "Foreign Vault Share", "fSHARE", 18);
        foreignVault.setRate(1e18);
        RoycoJuniorTranche foreignJT = new RoycoJuniorTranche(address(foreignVault), address(kernel));

        IRoycoDayKernel.RoycoDayKernelConstructionParams memory params = _goodConstructionParams();
        params.juniorTranche = address(foreignJT);
        DayKernel mismatchedImpl = new DayKernel(params);

        (IRoycoDayKernel.RoycoDayKernelInitParams memory standardParams, DayKernel.KernelSpecificInitParams memory specificParams) =
            _goodInitParams(0, PROTOCOL_FEE_RECIPIENT);
        bytes memory initData = abi.encodeCall(mismatchedImpl.initialize, (standardParams, specificParams));
        vm.expectRevert(IRoycoDayKernel.TRANCHE_AND_KERNEL_ASSETS_MISMATCH.selector);
        new ERC1967Proxy(address(mismatchedImpl), initData);
    }

    /// @notice A null protocol fee recipient is rejected at initialization, sync-time fee mints need a live destination
    function test_RevertIf_KernelInitializedWithNullFeeRecipient() public {
        DayKernel freshImpl = new DayKernel(_goodConstructionParams());
        (IRoycoDayKernel.RoycoDayKernelInitParams memory standardParams, DayKernel.KernelSpecificInitParams memory specificParams) =
            _goodInitParams(0, address(0));
        bytes memory initData = abi.encodeCall(freshImpl.initialize, (standardParams, specificParams));
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        new ERC1967Proxy(address(freshImpl), initData);
    }

    /**
     * @notice An attacker cannot re-initialize the live kernel proxy to seize its authority or rewire its quoters
     * @dev Re-initialization is the classic proxy takeover: a second initialize call with attacker-controlled
     *      params would replace the access authority and the fee recipient in one transaction
     */
    function test_RevertIf_KernelReinitializedAfterGenesis() public {
        (IRoycoDayKernel.RoycoDayKernelInitParams memory standardParams, DayKernel.KernelSpecificInitParams memory specificParams) =
            _goodInitParams(0, makeAddr("ATTACKER"));
        standardParams.initialAuthority = makeAddr("ATTACKER_AUTHORITY");
        vm.prank(makeAddr("ATTACKER"));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        kernel.initialize(standardParams, specificParams);
    }

    // =============================
    // Initialization-time stored-rate seed
    // =============================

    /**
     * @notice A kernel initialized with a nonzero conversion rate prices through that stored rate from genesis
     * @dev The deployed fixture kernel seeds the sentinel (0, oracle-driven), so this deploys a sibling kernel proxy
     *      over the same market wiring with a 3.0 seed: one whole share must quote 1e18 x 3e18 / 1e18 = 3e18 NAV
     */
    function test_KernelInitializedWithStoredRate_PricesThroughItFromGenesis() public {
        DayKernel freshImpl = new DayKernel(_goodConstructionParams());
        (IRoycoDayKernel.RoycoDayKernelInitParams memory standardParams, DayKernel.KernelSpecificInitParams memory specificParams) =
            _goodInitParams(3e18, PROTOCOL_FEE_RECIPIENT);
        DayKernel seededKernel =
            DayKernel(address(new ERC1967Proxy(address(freshImpl), abi.encodeCall(freshImpl.initialize, (standardParams, specificParams)))));

        assertEq(seededKernel.getStoredConversionRateWAD(), 3e18, "the initialization seed must land as the stored conversion rate");
        assertEq(toUint256(seededKernel.convertCollateralAssetsToValue(toTrancheUnits(1e18))), 3e18, "one whole share must quote at the seeded 3.0 rate");
    }
}

/**
 * @title Test_PreGenesisConversions_Kernel
 * @notice The LT quoter's zero-supply boundary: before the pool's genesis mint the BPT supply is zero, and both
 *         conversion directions must resolve to zero instead of dividing by the empty supply
 * @dev Overrides the fixture's pool-genesis hook to skip the minimum-supply backing, leaving a validly registered
 *      pool whose BPT supply is exactly zero
 */
contract Test_PreGenesisConversions_Kernel is DayMarketTestBase {
    function setUp() public {
        _deployMarket(cellA(), defaultParams());
    }

    /// @dev Skips the genesis seed so the registered pool's BPT supply stays at exactly zero
    function _initializePoolMinimumSupply() internal override { }

    /// @notice With zero BPT outstanding both conversion directions return zero, there is no pool value to apportion
    function test_LTConversions_ZeroBptSupplyResolvesToZero() public view {
        assertEq(toUint256(kernel.convertLTAssetsToValue(toTrancheUnits(5e18))), 0, "BPT -> NAV on an empty pool must be zero");
        assertEq(toUint256(kernel.convertValueToLTAssets(toNAVUnits(uint256(5e18)))), 0, "NAV -> BPT on an empty pool must be zero");
    }
}
