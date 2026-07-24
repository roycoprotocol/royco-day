// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { Initializable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { RoycoDayBalancerV3Kernel as DayKernel } from "../../../src/kernels/RoycoDayBalancerV3Kernel.sol";
import { BalancerV3LiquidityVenue } from "../../../src/kernels/base/liquidity-venue/balancer-v3/BalancerV3LiquidityVenue.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoJuniorTranche } from "../../../src/tranches/RoycoJuniorTranche.sol";
import { RoycoSeniorTranche } from "../../../src/tranches/RoycoSeniorTranche.sol";
import { MockBPT } from "../../mocks/MockBPT.sol";
import { MockERC20C } from "../../mocks/MockERC20C.sol";
import { MockERC4626C } from "../../mocks/MockERC4626C.sol";
import { MockPriceOracle } from "../../mocks/MockPriceOracle.sol";
import { MockThreeTokenVaultShim } from "../../mocks/MockThreeTokenVaultShim.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_Construction_Kernel
 * @notice Exercises the kernel family's construction- and initialization-time validation: null wiring, the
 *         coinvested tranche-vs-kernel collateral asset agreement, the liquidity pool's registration
 *         and token-pairing checks, and the genesis collateral oracle pricing path
 * @dev These checks only ever run at market genesis, but each one guards a wiring mistake that would be
 *      unrecoverable behind the proxy once real deposits land, so every rejection path is pinned here
 * @dev NOTE on INVALID_BALANCER_V3_VAULT: unreachable through this kernel family by construction, the concrete
 *      kernel derives the liquidity venue constructor's vault FROM the pool (BalancerPoolToken(lptAsset).getVault()), so
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
            liquidityProviderTranche: address(liquidityProviderTranche),
            lptAsset: address(bpt),
            enforceVaultSharesTransferWhitelist: false
        });
    }

    /// @dev Builds initialization params identical to the deployed market's kernel with a configurable oracle and fee recipient
    function _goodInitParams(
        address _collateralAssetOracle,
        address _protocolFeeRecipient
    )
        internal
        view
        returns (IRoycoDayKernel.RoycoDayKernelInitParams memory standardParams, BalancerV3LiquidityVenue.LiquidityVenueInitParams memory venueParams)
    {
        standardParams = IRoycoDayKernel.RoycoDayKernelInitParams({
            initialAuthority: address(accessManager),
            protocolFeeRecipient: _protocolFeeRecipient,
            stSelfLiquidationBonusWAD: 0.01e18,
            roycoBlacklist: address(0),
            collateralAssetOracle: _collateralAssetOracle,
            stalenessThresholdSeconds: 1 days,
            sequencerUptimeFeed: address(0),
            gracePeriodSeconds: 1 hours
        });
        venueParams = BalancerV3LiquidityVenue.LiquidityVenueInitParams({ bptOracle: address(bptOracle), maxReinvestmentSlippageWAD: 0.001e18 });
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

    /// @notice A liquidity provider tranche asset that is not a registered Balancer pool is rejected at construction
    function test_RevertIf_LPTAssetPoolNotRegisteredWithVault() public {
        MockBPT unregisteredBpt = new MockBPT(IVault(address(balancerVault)), "Unregistered BPT", "uBPT");
        IRoycoDayKernel.RoycoDayKernelConstructionParams memory params = _goodConstructionParams();
        params.lptAsset = address(unregisteredBpt);
        vm.expectRevert(BalancerV3LiquidityVenue.POOL_NOT_REGISTERED.selector);
        new DayKernel(params);
    }

    /// @notice A registered pool that does not pair the senior tranche share is rejected, the LPT must market-make senior exits
    function test_RevertIf_LPTAssetPoolDoesNotPairSeniorTranche() public {
        // A second pool pairing two unrelated tokens, registered with the same mock vault
        MockBPT foreignBpt = new MockBPT(IVault(address(balancerVault)), "Foreign BPT", "fBPT");
        MockERC20C tokenA = new MockERC20C("Token A", "TKA", 18);
        MockERC20C tokenB = new MockERC20C("Token B", "TKB", 6);
        balancerVault.registerPool(address(foreignBpt), [IERC20(address(tokenA)), IERC20(address(tokenB))]);

        IRoycoDayKernel.RoycoDayKernelConstructionParams memory params = _goodConstructionParams();
        params.lptAsset = address(foreignBpt);
        vm.expectRevert(BalancerV3LiquidityVenue.INVALID_POOL_TOKEN_CONFIGURATION.selector);
        new DayKernel(params);
    }

    /// @notice A pool reporting three tokens is rejected at construction, the LPT pool must be exactly the senior share against one quote
    function test_RevertIf_LPTAssetPoolReportsThreeTokens() public {
        IERC20[] memory three = new IERC20[](3);
        three[0] = IERC20(address(seniorTranche));
        three[1] = IERC20(address(quoteToken));
        three[2] = IERC20(makeAddr("THIRD_TOKEN"));
        MockThreeTokenVaultShim shim = new MockThreeTokenVaultShim(three);
        MockBPT shimBpt = new MockBPT(IVault(address(shim)), "Shim BPT", "shBPT");

        IRoycoDayKernel.RoycoDayKernelConstructionParams memory params = _goodConstructionParams();
        params.lptAsset = address(shimBpt);
        vm.expectRevert(BalancerV3LiquidityVenue.POOL_MUST_HAVE_TWO_TOKENS.selector);
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

        (IRoycoDayKernel.RoycoDayKernelInitParams memory standardParams, BalancerV3LiquidityVenue.LiquidityVenueInitParams memory venueParams) =
            _goodInitParams(address(collateralAssetOracle), PROTOCOL_FEE_RECIPIENT);
        bytes memory initData = abi.encodeCall(mismatchedImpl.initialize, (standardParams, venueParams));
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

        (IRoycoDayKernel.RoycoDayKernelInitParams memory standardParams, BalancerV3LiquidityVenue.LiquidityVenueInitParams memory venueParams) =
            _goodInitParams(address(collateralAssetOracle), PROTOCOL_FEE_RECIPIENT);
        bytes memory initData = abi.encodeCall(mismatchedImpl.initialize, (standardParams, venueParams));
        vm.expectRevert(IRoycoDayKernel.TRANCHE_AND_KERNEL_ASSETS_MISMATCH.selector);
        new ERC1967Proxy(address(mismatchedImpl), initData);
    }

    /// @notice A null protocol fee recipient is rejected at initialization, sync-time fee mints need a live destination
    function test_RevertIf_KernelInitializedWithNullFeeRecipient() public {
        DayKernel freshImpl = new DayKernel(_goodConstructionParams());
        (IRoycoDayKernel.RoycoDayKernelInitParams memory standardParams, BalancerV3LiquidityVenue.LiquidityVenueInitParams memory venueParams) =
            _goodInitParams(address(collateralAssetOracle), address(0));
        bytes memory initData = abi.encodeCall(freshImpl.initialize, (standardParams, venueParams));
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        new ERC1967Proxy(address(freshImpl), initData);
    }

    /**
     * @notice An attacker cannot re-initialize the live kernel proxy to seize its authority or rewire its pricing
     * @dev Re-initialization is the classic proxy takeover: a second initialize call with attacker-controlled
     *      params would replace the access authority and the fee recipient in one transaction
     */
    function test_RevertIf_KernelReinitializedAfterGenesis() public {
        (IRoycoDayKernel.RoycoDayKernelInitParams memory standardParams, BalancerV3LiquidityVenue.LiquidityVenueInitParams memory venueParams) =
            _goodInitParams(address(collateralAssetOracle), makeAddr("ATTACKER"));
        standardParams.initialAuthority = makeAddr("ATTACKER_AUTHORITY");
        vm.prank(makeAddr("ATTACKER"));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        kernel.initialize(standardParams, venueParams);
    }

    // =============================
    // Initialization-time oracle validation
    // =============================

    /// @notice A null collateral asset oracle is rejected at initialization, the kernel has no fallback price source
    function test_RevertIf_KernelInitializedWithNullOracle() public {
        DayKernel freshImpl = new DayKernel(_goodConstructionParams());
        (IRoycoDayKernel.RoycoDayKernelInitParams memory standardParams, BalancerV3LiquidityVenue.LiquidityVenueInitParams memory venueParams) =
            _goodInitParams(address(0), PROTOCOL_FEE_RECIPIENT);
        bytes memory initData = abi.encodeCall(freshImpl.initialize, (standardParams, venueParams));
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        new ERC1967Proxy(address(freshImpl), initData);
    }

    /// @notice A zero staleness threshold is rejected at initialization, it would flag every report stale and brick pricing
    function test_RevertIf_KernelInitializedWithZeroStalenessThreshold() public {
        DayKernel freshImpl = new DayKernel(_goodConstructionParams());
        (IRoycoDayKernel.RoycoDayKernelInitParams memory standardParams, BalancerV3LiquidityVenue.LiquidityVenueInitParams memory venueParams) =
            _goodInitParams(address(collateralAssetOracle), PROTOCOL_FEE_RECIPIENT);
        standardParams.stalenessThresholdSeconds = 0;
        bytes memory initData = abi.encodeCall(freshImpl.initialize, (standardParams, venueParams));
        vm.expectRevert(IRoycoDayKernel.INVALID_STALENESS_THRESHOLD_SECONDS.selector);
        new ERC1967Proxy(address(freshImpl), initData);
    }

    /// @notice An oracle pricing a different collateral asset is rejected at initialization, the pairing can never mismatch
    function test_RevertIf_KernelInitializedWithMismatchedOracle() public {
        MockPriceOracle foreignOracle = new MockPriceOracle(makeAddr("FOREIGN_ASSET"), 1e18);
        DayKernel freshImpl = new DayKernel(_goodConstructionParams());
        (IRoycoDayKernel.RoycoDayKernelInitParams memory standardParams, BalancerV3LiquidityVenue.LiquidityVenueInitParams memory venueParams) =
            _goodInitParams(address(foreignOracle), PROTOCOL_FEE_RECIPIENT);
        bytes memory initData = abi.encodeCall(freshImpl.initialize, (standardParams, venueParams));
        vm.expectRevert(IRoycoDayKernel.COLLATERAL_ASSET_ORACLE_MISMATCH.selector);
        new ERC1967Proxy(address(freshImpl), initData);
    }

    /// @notice A sequencer uptime feed with a zero grace period is rejected at initialization, a restore needs a settling window
    function test_RevertIf_KernelInitializedWithSequencerFeedAndZeroGracePeriod() public {
        DayKernel freshImpl = new DayKernel(_goodConstructionParams());
        (IRoycoDayKernel.RoycoDayKernelInitParams memory standardParams, BalancerV3LiquidityVenue.LiquidityVenueInitParams memory venueParams) =
            _goodInitParams(address(collateralAssetOracle), PROTOCOL_FEE_RECIPIENT);
        standardParams.sequencerUptimeFeed = makeAddr("SEQUENCER_UPTIME_FEED");
        standardParams.gracePeriodSeconds = 0;
        bytes memory initData = abi.encodeCall(freshImpl.initialize, (standardParams, venueParams));
        vm.expectRevert(IRoycoDayKernel.INVALID_GRACE_PERIOD_SECONDS.selector);
        new ERC1967Proxy(address(freshImpl), initData);
    }

    // =============================
    // Initialization-time oracle pricing
    // =============================

    /**
     * @notice A kernel initialized against an oracle at a non-unit price prices through that oracle from genesis
     * @dev The deployed fixture kernel wires the shared oracle at 1.0, so this deploys a sibling kernel proxy over
     *      the same market wiring against a fresh oracle at 3.0: one whole share must quote 1e18 x 3e18 / 1e18 = 3e18 NAV
     */
    function test_KernelInitializedWithOracle_PricesThroughItFromGenesis() public {
        MockPriceOracle seededOracle = new MockPriceOracle(address(stJtVault), 3e18);
        DayKernel freshImpl = new DayKernel(_goodConstructionParams());
        (IRoycoDayKernel.RoycoDayKernelInitParams memory standardParams, BalancerV3LiquidityVenue.LiquidityVenueInitParams memory venueParams) =
            _goodInitParams(address(seededOracle), PROTOCOL_FEE_RECIPIENT);
        DayKernel seededKernel = DayKernel(address(new ERC1967Proxy(address(freshImpl), abi.encodeCall(freshImpl.initialize, (standardParams, venueParams)))));

        assertEq(seededKernel.getCollateralAssetOracle(), address(seededOracle), "the initialization oracle must land as the kernel's collateral oracle");
        assertEq(toUint256(seededKernel.convertCollateralAssetsToValue(toTrancheUnits(1e18))), 3e18, "one whole share must quote at the oracle's 3.0 price");
    }
}

/**
 * @title Test_PreGenesisConversions_Kernel
 * @notice The liquidity venue's zero-supply boundary: before the pool's genesis mint the BPT supply is zero, and both
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
    function test_LPTConversions_ZeroBptSupplyResolvesToZero() public view {
        assertEq(toUint256(kernel.convertLPTAssetsToValue(toTrancheUnits(5e18))), 0, "BPT -> NAV on an empty pool must be zero");
        assertEq(toUint256(kernel.convertValueToLPTAssets(toNAVUnits(uint256(5e18)))), 0, "NAV -> BPT on an empty pool must be zero");
    }
}
