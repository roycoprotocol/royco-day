// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IGyroECLPPool } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/pool-gyro/IGyroECLPPool.sol";
import { IRateProvider } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { IProtocolFeeController } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IProtocolFeeController.sol";
import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { IVaultAdmin } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultAdmin.sol";
import {
    PoolRoleAccounts as BalancerV3PoolRoleAccounts,
    TokenConfig as BalancerV3TokenConfig,
    TokenType as BalancerV3TokenType
} from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { GyroECLPPoolFactory } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { BalancerPoolToken } from "../../../lib/balancer-v3-monorepo/pkg/vault/contracts/BalancerPoolToken.sol";
import { AccessManagedUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";
import { UUPSUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IRoycoAuth } from "../../interfaces/IRoycoAuth.sol";
import { IRoycoDayAccountant } from "../../interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { IRoycoFactory } from "../../interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../interfaces/factory/IRoycoProtocolTemplate.sol";
import { TrancheType } from "../../libraries/Types.sol";
import {
    ADMIN_ACCOUNTANT_ROLE,
    ADMIN_BALANCER_POOL_MANAGER_ROLE,
    ADMIN_KERNEL_ROLE,
    ADMIN_PAUSER_ROLE,
    ADMIN_PROTOCOL_FEE_SETTER_ROLE,
    ADMIN_UNPAUSER_ROLE,
    ADMIN_UPGRADER_ROLE,
    BURNER_ROLE,
    JT_LP_ROLE,
    LT_LP_ROLE,
    ST_LP_ROLE,
    SYNC_ROLE,
    TRANSFER_AGENT_ROLE
} from "../RolesConfiguration.sol";
import { BaseDeploymentTemplate } from "./base/BaseDeploymentTemplate.sol";

/**
 * @title BalancerV3DeploymentTemplate
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Abstract base for every Royco Day market deployment template (ST + JT + LT).
 *
 * @dev Derived structurally from the Dusk-Balancer template, but Day-shaped: the junior tranche is a plain
 *      first-loss tranche, and a third Liquidity Tranche (LT) holds the Balancer BPT `{ST_share, quote}`.
 *      Dusk peripherals (rate providers + custom hooks) are intentionally omitted for now — pool tokens are
 *      registered `STANDARD` (no rate provider) and the pool runs without hooks. These are wired in later.
 *
 *      Concrete subclasses plug in their kernel by overriding `_kernelComponentId()` and `_kernelInitData(...)`.
 */
abstract contract BalancerV3DeploymentTemplate is BaseDeploymentTemplate {
    // ═══════════════════════════════════════════════════════════════════════════
    // PARAM STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Gyro E-CLP pool params for the LT's `{ST_share, quote}` pool.
    struct GyroECLPPoolParams {
        string name;
        string symbol;
        IGyroECLPPool.EclpParams eclpParams;
        IGyroECLPPool.DerivedEclpParams derivedEclpParams;
        uint256 swapFeePercentage;
        bool enableDonation;
        bool disableUnbalancedLiquidity;
        address quoteToken;
    }

    /// @notice LT params. The asset is the Balancer BPT, filled in by the template after the pool is created.
    struct LiquidityTrancheParams {
        string name;
        string symbol;
    }

    /// @notice Top-level params struct passed to `deployMarket(bytes)`.
    struct DayParams {
        bytes32 marketId;
        SeniorTrancheParams st;
        JuniorTrancheParams jt;
        LiquidityTrancheParams lt;
        AccountantParams accountant;
        GyroECLPPoolParams gyroECLPPoolParams;
        YDMParams ydm;
        address protocolFeeRecipient;
        uint64 stSelfLiquidationBonusWAD;
        address roycoBlacklist;
        bytes kernelSpecificParams;
        bool enforceVaultSharesTransferWhitelist;
    }

    /// @notice Dusk/Day-specific addresses recorded for verification.
    struct ExtraContractsDeployedResult {
        address balancerPool;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error INVALID_ACCESS_MANAGER();
    error INVALID_TRANCHE_TYPE_ON_SENIOR_TRANCHE();
    error INVALID_TRANCHE_TYPE_ON_JUNIOR_TRANCHE();
    error INVALID_TRANCHE_TYPE_ON_LIQUIDITY_TRANCHE();
    error INVALID_KERNEL_ON_SENIOR_TRANCHE();
    error INVALID_KERNEL_ON_JUNIOR_TRANCHE();
    error INVALID_KERNEL_ON_LIQUIDITY_TRANCHE();
    error INVALID_SENIOR_TRANCHE_ON_KERNEL();
    error INVALID_JUNIOR_TRANCHE_ON_KERNEL();
    error INVALID_LIQUIDITY_TRANCHE_ON_KERNEL();
    error INVALID_ST_ASSET_ON_KERNEL();
    error INVALID_JT_ASSET_ON_KERNEL();
    error INVALID_LT_ASSET_ON_KERNEL();
    error INVALID_QUOTE_ASSET_ON_KERNEL();
    error INVALID_ACCOUNTANT_ON_KERNEL();
    error INVALID_KERNEL_ON_ACCOUNTANT();
    error POOL_NOT_REGISTERED_WITH_VAULT();
    error POOL_TOKEN_CONFIGURATION_MISMATCH();

    // ═══════════════════════════════════════════════════════════════════════════
    // IMMUTABLES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The Balancer V3 Gyro E-CLP pool factory.
    GyroECLPPoolFactory public immutable BALANCER_V3_POOL_FACTORY;

    /// @notice The Balancer V3 vault.
    IVault public immutable BALANCER_V3_VAULT;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTION
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(IRoycoFactory _factory, GyroECLPPoolFactory _balancerV3PoolFactory) BaseDeploymentTemplate(_factory) {
        BALANCER_V3_POOL_FACTORY = _balancerV3PoolFactory;
        BALANCER_V3_VAULT = IVault(address(_balancerV3PoolFactory.getVault()));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PER-KERNEL HOOKS (subclasses override)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Returns the SSTORE2 component ID that holds the Day kernel's creation code.
    function _kernelComponentId() internal pure virtual returns (bytes32);

    /// @dev Returns the ABI-encoded kernel `initialize(...)` calldata for the concrete Day kernel.
    function _kernelInitData(
        IRoycoDayKernel.RoycoDayKernelInitParams memory _kip,
        bytes memory _kernelSpecificParams
    )
        internal
        pure
        virtual
        returns (bytes memory);

    // ═══════════════════════════════════════════════════════════════════════════
    // VALIDATE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IRoycoProtocolTemplate
    function validateParams(bytes calldata _params) external pure override(IRoycoProtocolTemplate) {
        DayParams memory p = abi.decode(_params, (DayParams));
        require(p.marketId != bytes32(0), INVALID_PARAMS());
        require(bytes(p.st.name).length > 0 && bytes(p.st.symbol).length > 0 && p.st.asset != address(0), INVALID_PARAMS());
        require(bytes(p.jt.name).length > 0 && bytes(p.jt.symbol).length > 0 && p.jt.asset != address(0), INVALID_PARAMS());
        require(bytes(p.lt.name).length > 0 && bytes(p.lt.symbol).length > 0, INVALID_PARAMS());
        require(p.gyroECLPPoolParams.quoteToken != address(0), INVALID_PARAMS());
        require(p.protocolFeeRecipient != address(0), INVALID_PARAMS());
        require(p.ydm.componentTag != bytes32(0) && p.ydm.version != bytes32(0), INVALID_PARAMS());
        require(p.accountant.ydmInitializationData.length > 0, INVALID_PARAMS());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IRoycoProtocolTemplate
    function deployMarket(bytes calldata _params) external override(IRoycoProtocolTemplate) onlyRoycoFactory returns (DeploymentResult memory result) {
        DayParams memory p = abi.decode(_params, (DayParams));

        // 1. Predict the 5 market proxy addresses.
        bytes32 stProxySalt = _marketComponentSalt(p.marketId, "ST");
        bytes32 jtProxySalt = _marketComponentSalt(p.marketId, "JT");
        bytes32 ltProxySalt = _marketComponentSalt(p.marketId, "LT");
        bytes32 kernelProxySalt = _marketComponentSalt(p.marketId, "KERNEL");
        bytes32 accountantProxySalt = _marketComponentSalt(p.marketId, "ACCOUNTANT");

        result.seniorTranche = ROYCO_FACTORY.predictDeterministicAddress(stProxySalt);
        result.juniorTranche = ROYCO_FACTORY.predictDeterministicAddress(jtProxySalt);
        result.liquidityTranche = ROYCO_FACTORY.predictDeterministicAddress(ltProxySalt);
        result.kernel = ROYCO_FACTORY.predictDeterministicAddress(kernelProxySalt);
        result.accountant = ROYCO_FACTORY.predictDeterministicAddress(accountantProxySalt);

        // 2. Deploy YDM (idempotent across templates).
        (result.ydm,) = _deployYDM(p.ydm);

        // 3. Deploy ST impl + proxy first — the pool needs ST_PROXY as one of its tokens.
        address stImpl = _deploySeniorTrancheImpl(p.st.asset, result.kernel, _marketComponentSalt(p.marketId, "ST_IMPL"));
        _deployProxy(stImpl, _encodeTrancheInitData(p.st.name, p.st.symbol), stProxySalt);

        // 4. Create the Gyro E-CLP pool `{ST_share, quote}` (no rate providers, no hooks). LT asset = pool.
        address balancerPool = _createBalancerV3Pool(p.gyroECLPPoolParams, result.seniorTranche, _marketComponentSalt(p.marketId, "BALANCER_V3_POOL"));

        // 5. Deploy JT impl + proxy (plain first-loss asset).
        address jtImpl = _deployJuniorTrancheImpl(p.jt.asset, result.kernel, _marketComponentSalt(p.marketId, "JT_IMPL"));
        _deployProxy(jtImpl, _encodeTrancheInitData(p.jt.name, p.jt.symbol), jtProxySalt);

        // 6. Deploy LT impl + proxy (asset = the pool BPT).
        address ltImpl = _deployLiquidityTrancheImpl(balancerPool, result.kernel, _marketComponentSalt(p.marketId, "LT_IMPL"));
        _deployProxy(ltImpl, _encodeTrancheInitData(p.lt.name, p.lt.symbol), ltProxySalt);

        // 7. Deploy accountant impl + proxy (Day accountant bytecode registered under the accountant component ID).
        address accountantImpl = _deployAccountantImpl(result.kernel, _marketComponentSalt(p.marketId, "ACCOUNTANT_IMPL"));
        _deployProxy(accountantImpl, _encodeAccountantInitData(p.accountant, result.ydm), accountantProxySalt);

        // 8. Deploy kernel impl + proxy.
        _deployKernelImplAndProxy(p, result, balancerPool, kernelProxySalt);

        // 9. Apply selector->role bindings + post-init grants.
        _applyRoleBindings(_buildRoleBindings(result));

        // 10. Record + verify-friendly extras.
        result.extras = abi.encode(ExtraContractsDeployedResult({ balancerPool: balancerPool }));

        // 11. Sanity-check the pool wiring lines up with what we built.
        _assertPoolWiredCorrectly(balancerPool, result.seniorTranche, p.gyroECLPPoolParams.quoteToken);
    }

    /// @notice Deploys the Day kernel impl + proxy.
    function _deployKernelImplAndProxy(DayParams memory _p, DeploymentResult memory _result, address _balancerPool, bytes32 _kernelProxySalt) internal {
        IRoycoDayKernel.RoycoDayKernelConstructionParams memory cp = IRoycoDayKernel.RoycoDayKernelConstructionParams({
            seniorTranche: _result.seniorTranche,
            stAsset: _p.st.asset,
            juniorTranche: _result.juniorTranche,
            jtAsset: _p.jt.asset,
            accountant: _result.accountant,
            enforceVaultSharesTransferWhitelist: _p.enforceVaultSharesTransferWhitelist,
            liquidityTranche: _result.liquidityTranche,
            ltAsset: _balancerPool,
            quoteAsset: _p.gyroECLPPoolParams.quoteToken
        });
        address kernelImpl = _deployImpl(_kernelComponentId(), abi.encode(cp), _marketComponentSalt(_p.marketId, "KERNEL_IMPL"));

        IRoycoDayKernel.RoycoDayKernelInitParams memory kip = IRoycoDayKernel.RoycoDayKernelInitParams({
            initialAuthority: ROYCO_FACTORY.ROYCO_AUTHORITY(),
            protocolFeeRecipient: _p.protocolFeeRecipient,
            stSelfLiquidationBonusWAD: _p.stSelfLiquidationBonusWAD,
            roycoBlacklist: _p.roycoBlacklist
        });
        _deployProxy(kernelImpl, _kernelInitData(kip, _p.kernelSpecificParams), _kernelProxySalt);
    }

    /// @notice Creates the Gyro E-CLP pool with tokens `{ST_share, quote}` registered `STANDARD` (no rate providers, no hooks).
    function _createBalancerV3Pool(GyroECLPPoolParams memory _p, address _seniorTranche, bytes32 _salt) internal returns (address balancerV3Pool) {
        BalancerV3TokenConfig[] memory tokens = new BalancerV3TokenConfig[](2);
        tokens[0] = BalancerV3TokenConfig({
            token: IERC20(_seniorTranche), tokenType: BalancerV3TokenType.STANDARD, rateProvider: IRateProvider(address(0)), paysYieldFees: false
        });
        tokens[1] = BalancerV3TokenConfig({
            token: IERC20(_p.quoteToken), tokenType: BalancerV3TokenType.STANDARD, rateProvider: IRateProvider(address(0)), paysYieldFees: false
        });

        address authority = ROYCO_FACTORY.ROYCO_AUTHORITY();
        BalancerV3PoolRoleAccounts memory roleAccounts =
            BalancerV3PoolRoleAccounts({ pauseManager: authority, swapFeeManager: authority, poolCreator: authority });

        balancerV3Pool = BALANCER_V3_POOL_FACTORY.create(
            _p.name,
            _p.symbol,
            tokens,
            _p.eclpParams,
            _p.derivedEclpParams,
            roleAccounts,
            _p.swapFeePercentage,
            address(0), // no hooks
            _p.enableDonation,
            _p.disableUnbalancedLiquidity,
            _salt
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VERIFY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IRoycoProtocolTemplate
    function verify(DeploymentResult calldata _d) external view override(IRoycoProtocolTemplate) {
        address expectedAuthority = ROYCO_FACTORY.ROYCO_AUTHORITY();
        require(AccessManagedUpgradeable(_d.accountant).authority() == expectedAuthority, INVALID_ACCESS_MANAGER());
        require(AccessManagedUpgradeable(_d.kernel).authority() == expectedAuthority, INVALID_ACCESS_MANAGER());
        require(AccessManagedUpgradeable(_d.seniorTranche).authority() == expectedAuthority, INVALID_ACCESS_MANAGER());
        require(AccessManagedUpgradeable(_d.juniorTranche).authority() == expectedAuthority, INVALID_ACCESS_MANAGER());
        require(AccessManagedUpgradeable(_d.liquidityTranche).authority() == expectedAuthority, INVALID_ACCESS_MANAGER());

        require(IRoycoVaultTranche(_d.seniorTranche).TRANCHE_TYPE() == TrancheType.SENIOR, INVALID_TRANCHE_TYPE_ON_SENIOR_TRANCHE());
        require(IRoycoVaultTranche(_d.juniorTranche).TRANCHE_TYPE() == TrancheType.JUNIOR, INVALID_TRANCHE_TYPE_ON_JUNIOR_TRANCHE());
        require(IRoycoVaultTranche(_d.liquidityTranche).TRANCHE_TYPE() == TrancheType.LIQUIDITY, INVALID_TRANCHE_TYPE_ON_LIQUIDITY_TRANCHE());
        require(address(IRoycoVaultTranche(_d.seniorTranche).KERNEL()) == _d.kernel, INVALID_KERNEL_ON_SENIOR_TRANCHE());
        require(address(IRoycoVaultTranche(_d.juniorTranche).KERNEL()) == _d.kernel, INVALID_KERNEL_ON_JUNIOR_TRANCHE());
        require(address(IRoycoVaultTranche(_d.liquidityTranche).KERNEL()) == _d.kernel, INVALID_KERNEL_ON_LIQUIDITY_TRANCHE());

        IRoycoDayKernel kernel = IRoycoDayKernel(_d.kernel);
        require(kernel.SENIOR_TRANCHE() == _d.seniorTranche, INVALID_SENIOR_TRANCHE_ON_KERNEL());
        require(kernel.JUNIOR_TRANCHE() == _d.juniorTranche, INVALID_JUNIOR_TRANCHE_ON_KERNEL());
        require(kernel.LIQUIDITY_TRANCHE() == _d.liquidityTranche, INVALID_LIQUIDITY_TRANCHE_ON_KERNEL());
        require(kernel.ST_ASSET() == IRoycoVaultTranche(_d.seniorTranche).asset(), INVALID_ST_ASSET_ON_KERNEL());
        require(kernel.JT_ASSET() == IRoycoVaultTranche(_d.juniorTranche).asset(), INVALID_JT_ASSET_ON_KERNEL());
        require(kernel.LT_ASSET() == IRoycoVaultTranche(_d.liquidityTranche).asset(), INVALID_LT_ASSET_ON_KERNEL());
        require(kernel.ACCOUNTANT() == _d.accountant, INVALID_ACCOUNTANT_ON_KERNEL());

        require(address(IRoycoDayAccountant(_d.accountant).KERNEL()) == _d.kernel, INVALID_KERNEL_ON_ACCOUNTANT());

        // The LT asset is the pool; the pool is wired with `{ST_share, quote}`.
        ExtraContractsDeployedResult memory extras = abi.decode(_d.extras, (ExtraContractsDeployedResult));
        require(kernel.LT_ASSET() == extras.balancerPool, INVALID_LT_ASSET_ON_KERNEL());
        _assertPoolWiredCorrectly(extras.balancerPool, _d.seniorTranche, kernel.QUOTE_ASSET());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ROLE BINDINGS
    // ═══════════════════════════════════════════════════════════════════════════

    function _buildRoleBindings(DeploymentResult memory _r) internal view virtual returns (RoleBindings memory) {
        TargetBinding[] memory targets = new TargetBinding[](7);
        targets[0] = _trancheBinding(_r.seniorTranche, ST_LP_ROLE);
        targets[1] = _trancheBinding(_r.juniorTranche, JT_LP_ROLE);
        targets[2] = _trancheBinding(_r.liquidityTranche, LT_LP_ROLE);
        targets[3] = _kernelBinding(_r.kernel);
        targets[4] = _accountantBinding(_r.accountant);
        targets[5] = _balancerVaultBinding(address(BALANCER_V3_VAULT));
        targets[6] = _balancerProtocolFeeControllerBinding(address(BALANCER_V3_VAULT.getProtocolFeeController()));

        RoleGrant[] memory grants = new RoleGrant[](1);
        grants[0] = RoleGrant({ roleId: SYNC_ROLE, account: _r.accountant, executionDelay: 0 });

        return RoleBindings({ targetBindings: targets, postInitGrants: grants });
    }

    function _trancheBinding(address _tranche, uint64 _lpRole) private pure returns (TargetBinding memory) {
        bytes4[] memory s = new bytes4[](9);
        uint64[] memory r = new uint64[](9);
        s[0] = IRoycoVaultTranche.deposit.selector;
        r[0] = _lpRole;
        s[1] = IRoycoVaultTranche.redeem.selector;
        r[1] = _lpRole;
        s[2] = IRoycoAuth.pause.selector;
        r[2] = ADMIN_PAUSER_ROLE;
        s[3] = IRoycoAuth.unpause.selector;
        r[3] = ADMIN_UNPAUSER_ROLE;
        s[4] = UUPSUpgradeable.upgradeToAndCall.selector;
        r[4] = ADMIN_UPGRADER_ROLE;
        s[5] = IRoycoVaultTranche.seizeShares.selector;
        r[5] = TRANSFER_AGENT_ROLE;
        s[6] = IRoycoVaultTranche.seizeAndRedeemShares.selector;
        r[6] = TRANSFER_AGENT_ROLE;
        s[7] = IRoycoVaultTranche.burn.selector;
        r[7] = BURNER_ROLE;
        s[8] = IRoycoVaultTranche.burnFrom.selector;
        r[8] = BURNER_ROLE;
        return TargetBinding({ target: _tranche, selectors: s, roleIds: r });
    }

    function _kernelBinding(address _kernel) private pure returns (TargetBinding memory) {
        bytes4[] memory s = new bytes4[](7);
        uint64[] memory r = new uint64[](7);
        s[0] = IRoycoDayKernel.setProtocolFeeRecipient.selector;
        r[0] = ADMIN_KERNEL_ROLE;
        s[1] = IRoycoAuth.pause.selector;
        r[1] = ADMIN_PAUSER_ROLE;
        s[2] = IRoycoAuth.unpause.selector;
        r[2] = ADMIN_UNPAUSER_ROLE;
        s[3] = UUPSUpgradeable.upgradeToAndCall.selector;
        r[3] = ADMIN_UPGRADER_ROLE;
        s[4] = IRoycoDayKernel.syncTrancheAccounting.selector;
        r[4] = SYNC_ROLE;
        s[5] = IRoycoDayKernel.setRoycoBlacklist.selector;
        r[5] = ADMIN_KERNEL_ROLE;
        s[6] = IRoycoDayKernel.setSeniorTrancheSelfLiquidationBonus.selector;
        r[6] = ADMIN_KERNEL_ROLE;
        return TargetBinding({ target: _kernel, selectors: s, roleIds: r });
    }

    function _accountantBinding(address _accountant) private pure returns (TargetBinding memory) {
        bytes4[] memory s = new bytes4[](14);
        uint64[] memory r = new uint64[](14);
        s[0] = IRoycoDayAccountant.setJuniorTrancheYDM.selector;
        r[0] = ADMIN_ACCOUNTANT_ROLE;
        s[1] = IRoycoDayAccountant.setLiquidityTrancheYDM.selector;
        r[1] = ADMIN_ACCOUNTANT_ROLE;
        s[2] = IRoycoDayAccountant.setSeniorTrancheProtocolFee.selector;
        r[2] = ADMIN_PROTOCOL_FEE_SETTER_ROLE;
        s[3] = IRoycoDayAccountant.setJuniorTrancheProtocolFee.selector;
        r[3] = ADMIN_PROTOCOL_FEE_SETTER_ROLE;
        s[4] = IRoycoDayAccountant.setLiquidityTrancheProtocolFee.selector;
        r[4] = ADMIN_PROTOCOL_FEE_SETTER_ROLE;
        s[5] = IRoycoDayAccountant.setJTYieldShareProtocolFee.selector;
        r[5] = ADMIN_PROTOCOL_FEE_SETTER_ROLE;
        s[6] = IRoycoDayAccountant.setLTYieldShareProtocolFee.selector;
        r[6] = ADMIN_PROTOCOL_FEE_SETTER_ROLE;
        s[7] = IRoycoDayAccountant.setCoverageConfiguration.selector;
        r[7] = ADMIN_ACCOUNTANT_ROLE;
        s[8] = IRoycoDayAccountant.setLiquidityConfiguration.selector;
        r[8] = ADMIN_ACCOUNTANT_ROLE;
        s[9] = IRoycoDayAccountant.setMaxYieldShares.selector;
        r[9] = ADMIN_ACCOUNTANT_ROLE;
        s[10] = IRoycoDayAccountant.setFixedTermDuration.selector;
        r[10] = ADMIN_ACCOUNTANT_ROLE;
        s[11] = IRoycoAuth.pause.selector;
        r[11] = ADMIN_PAUSER_ROLE;
        s[12] = IRoycoAuth.unpause.selector;
        r[12] = ADMIN_UNPAUSER_ROLE;
        s[13] = UUPSUpgradeable.upgradeToAndCall.selector;
        r[13] = ADMIN_UPGRADER_ROLE;
        return TargetBinding({ target: _accountant, selectors: s, roleIds: r });
    }

    function _balancerVaultBinding(address _vault) private pure returns (TargetBinding memory) {
        bytes4[] memory s = new bytes4[](3);
        uint64[] memory r = new uint64[](3);
        s[0] = IVaultAdmin.pausePool.selector;
        r[0] = ADMIN_PAUSER_ROLE;
        s[1] = IVaultAdmin.unpausePool.selector;
        r[1] = ADMIN_UNPAUSER_ROLE;
        s[2] = IVaultAdmin.setStaticSwapFeePercentage.selector;
        r[2] = ADMIN_BALANCER_POOL_MANAGER_ROLE;
        return TargetBinding({ target: _vault, selectors: s, roleIds: r });
    }

    function _balancerProtocolFeeControllerBinding(address _feeController) private pure returns (TargetBinding memory) {
        bytes4[] memory s = new bytes4[](3);
        uint64[] memory r = new uint64[](3);
        s[0] = IProtocolFeeController.setPoolCreatorSwapFeePercentage.selector;
        r[0] = ADMIN_BALANCER_POOL_MANAGER_ROLE;
        s[1] = IProtocolFeeController.setPoolCreatorYieldFeePercentage.selector;
        r[1] = ADMIN_BALANCER_POOL_MANAGER_ROLE;
        s[2] = bytes4(keccak256("withdrawPoolCreatorFees(address,address)"));
        r[2] = ADMIN_BALANCER_POOL_MANAGER_ROLE;
        return TargetBinding({ target: _feeController, selectors: s, roleIds: r });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Asserts the pool is registered with the Vault and has tokens `{ST_PROXY, quoteAsset}` (any order).
    function _assertPoolWiredCorrectly(address _pool, address _stProxy, address _quoteAsset) internal view {
        IVault vault = BalancerPoolToken(_pool).getVault();
        require(vault.isPoolRegistered(_pool), POOL_NOT_REGISTERED_WITH_VAULT());

        IERC20[] memory ierc20Tokens = vault.getPoolTokens(_pool);
        require(ierc20Tokens.length == 2, POOL_TOKEN_CONFIGURATION_MISMATCH());
        address t0 = address(ierc20Tokens[0]);
        address t1 = address(ierc20Tokens[1]);
        bool match0 = t0 == _stProxy && t1 == _quoteAsset;
        bool match1 = t0 == _quoteAsset && t1 == _stProxy;
        require(match0 || match1, POOL_TOKEN_CONFIGURATION_MISMATCH());
    }
}
