// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.28;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {
    SubscriptionPermission,
    SubscriptionStatus,
    Plan,
    SubscriptionLib
} from "./libraries/SubscriptionLib.sol";
import { ISubscriptionModule } from "./interfaces/ISubscriptionModule.sol";
import { ISubscriptionValidator } from "./interfaces/ISubscriptionValidator.sol";
import { ISubscriptionRegistry } from "./interfaces/ISubscriptionRegistry.sol";
import { SubscriptionRegistry } from "./SubscriptionRegistry.sol";
import { IMerchantRegistry } from "./interfaces/IMerchantRegistry.sol";
import { MerchantRegistry } from "./MerchantRegistry.sol";

// ERC-7579 interfaces
import { IValidator, IExecutor, IModule } from "erc7579/interfaces/IERC7579Module.sol";
import { PackedUserOperation } from "account-abstraction/interfaces/PackedUserOperation.sol";

/// @title SubscriptionModule
/// @notice ERC-7579 Validator + Executor module implementing the MIP Subscription
///         Permissions Standard.
///
/// @dev Architecture notes:
///      - This module is installed per-smart-account.
///      - Each smart account holds its own mapping of subscriptionId → permission.
///      - The module calls into SubscriptionRegistry for global indexing.
///      - processRenewal() is callable by the session key (via UserOp) or by any
///        address — on-chain constraints are the security boundary, not caller restriction.
///      - ERC-7579 module type: both VALIDATOR (1) and EXECUTOR (2).
///
/// Checks-Effects-Interactions pattern is enforced throughout:
///      all state changes occur before external calls.
contract SubscriptionModule is
    ISubscriptionModule,
    ISubscriptionValidator,
    IValidator,
    IExecutor,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;
    using SubscriptionLib for *;

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 internal constant VALIDATION_SUCCESS = 0;
    uint256 internal constant VALIDATION_FAILED  = 1;

    /// @notice Module type IDs per ERC-7579.
    uint256 internal constant MODULE_TYPE_VALIDATOR = 1;
    uint256 internal constant MODULE_TYPE_EXECUTOR  = 2;

    /// @notice Number of consecutive failed renewal attempts before entering GracePeriod.
    uint8 public constant MAX_FAILED_ATTEMPTS = 4;

    /// @notice Duration of the grace period in seconds (7 days).
    uint32 public constant GRACE_PERIOD_SECONDS = 7 days;

    // ─── Immutables ───────────────────────────────────────────────────────────

    /// @notice Global subscription registry (mirrors state for off-chain indexing).
    SubscriptionRegistry public immutable registry;

    /// @notice Merchant registry (source of truth for plan terms).
    MerchantRegistry public immutable merchantRegistry;

    /// @notice Protocol treasury address receiving fee cuts.
    address public immutable treasury;

    // ─── Storage ──────────────────────────────────────────────────────────────

    /// @dev account → subscriptionId → SubscriptionPermission
    mapping(address => mapping(bytes32 => SubscriptionPermission)) private _permissions;

    /// @dev account → array of subscriptionIds (active + paused + grace; not terminal)
    mapping(address => bytes32[]) private _accountSubscriptionIds;

    /// @dev account → subscriptionId index in _accountSubscriptionIds (1-based; 0 = not present)
    mapping(address => mapping(bytes32 => uint256)) private _idIndex;

    /// @dev account → per-plan subscription nonce (prevents collisions on re-subscribe)
    mapping(address => mapping(bytes32 => uint256)) private _subscriptionNonce;

    /// @dev account → planId → active subscriptionId (bytes32(0) if none active/paused)
    mapping(address => mapping(bytes32 => bytes32)) private _activePlanSubscription;

    /// @dev Per-account EIP-712 domain separator (computed at onInstall time).
    mapping(address => bytes32) private _domainSeparators;

    /// @dev account → subscriptionId → consecutive failed renewal attempts
    mapping(address => mapping(bytes32 => uint8)) private _failedAttempts;

    /// @dev account → subscriptionId → grace period end timestamp (0 if not in grace)
    mapping(address => mapping(bytes32 => uint48)) private _graceUntil;

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @param _registry         SubscriptionRegistry address.
    /// @param _merchantRegistry MerchantRegistry address.
    /// @param _treasury         Protocol treasury address.
    constructor(
        address _registry,
        address _merchantRegistry,
        address _treasury
    ) {
        if (_registry == address(0) || _merchantRegistry == address(0) || _treasury == address(0)) {
            revert SubscriptionLib.ZeroAddress();
        }
        registry        = SubscriptionRegistry(_registry);
        merchantRegistry = MerchantRegistry(_merchantRegistry);
        treasury        = _treasury;
    }

    // ─── ERC-7579 Module Lifecycle ────────────────────────────────────────────

    /// @notice Called by the smart account during module installation.
    /// @param data  ABI-encoded (nothing required; pass bytes("")).
    function onInstall(bytes calldata data) external {
        if (_domainSeparators[msg.sender] != bytes32(0)) {
            revert IModule.AlreadyInitialized(msg.sender);
        }
        _domainSeparators[msg.sender] = SubscriptionLib.domainSeparator(address(this));
        data; // suppress unused warning
    }

    /// @notice Called by the smart account during module uninstallation.
    /// @dev Cancels all non-terminal subscriptions before clearing account state.
    ///      This prevents subscriptions from being chargeable after the user
    ///      has uninstalled the module.
    function onUninstall(bytes calldata data) external {
        address account = msg.sender;
        bytes32[] storage ids = _accountSubscriptionIds[account];

        // Cancel all non-terminal subscriptions (Active, Paused, GracePeriod)
        uint256 len = ids.length;
        for (uint256 i = 0; i < len; ) {
            bytes32 sid = ids[i];
            SubscriptionPermission storage perm = _permissions[account][sid];
            if (
                perm.status == SubscriptionStatus.Active   ||
                perm.status == SubscriptionStatus.Paused   ||
                perm.status == SubscriptionStatus.GracePeriod
            ) {
                perm.status = SubscriptionStatus.Cancelled;
                _activePlanSubscription[account][perm.planId] = bytes32(0);
                registry.updateStatus(sid, uint8(SubscriptionStatus.Cancelled));
                emit SubscriptionCancelled(sid, account, uint48(block.timestamp));
            }
            unchecked { ++i; }
        }

        // Clear the subscription list and domain separator
        delete _accountSubscriptionIds[account];
        delete _domainSeparators[account];

        data;
    }

    /// @notice Returns true if this module is of the given ERC-7579 type.
    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == MODULE_TYPE_VALIDATOR || moduleTypeId == MODULE_TYPE_EXECUTOR;
    }

    /// @notice Returns true if this module has been installed for a given account.
    function isInitialized(address smartAccount) external view returns (bool) {
        return _domainSeparators[smartAccount] != bytes32(0);
    }

    // ─── ERC-7579 Validator ───────────────────────────────────────────────────

    /// @notice ERC-7579 / ERC-4337 validateUserOp entry point.
    /// @dev The userOp.signature encodes: abi.encode(subscriptionId, ecdsa_sig)
    ///      The module validates that the UserOp is a valid processRenewal call.
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) external view returns (uint256 validationData) {
        // Decode subscription ID and ECDSA signature from userOp.signature
        (bytes32 subscriptionId, bytes memory sig) = abi.decode(userOp.signature, (bytes32, bytes));

        return _validateRenewalInternal(userOp.sender, subscriptionId, userOpHash, sig);
    }

    /// @notice ERC-1271 isValidSignatureWithSender — not used for renewals, returns 0xffffffff.
    function isValidSignatureWithSender(
        address /*sender*/,
        bytes32 /*hash*/,
        bytes calldata /*data*/
    ) external pure returns (bytes4) {
        return 0xffffffff; // not supported
    }

    // ─── ISubscriptionValidator ───────────────────────────────────────────────

    /// @inheritdoc ISubscriptionValidator
    function validateRenewal(
        bytes32 subscriptionId,
        bytes32 userOpHash,
        bytes calldata signature
    ) external view returns (uint256 validationData) {
        // In the ERC-7579 path, msg.sender is the smart account.
        return _validateRenewalInternal(msg.sender, subscriptionId, userOpHash, signature);
    }

    // ─── ISubscriptionModule Lifecycle ───────────────────────────────────────

    /// @inheritdoc ISubscriptionModule
    function subscribe(
        bytes32 planId,
        address sessionKey,
        uint48  expiresAt
    ) external returns (bytes32 subscriptionId) {
        address account = msg.sender;

        if (sessionKey == address(0)) revert SubscriptionLib.InvalidSessionKeyAddress();
        if (_domainSeparators[account] == bytes32(0)) revert IModule.NotInitialized(account);

        // [M-04] Reject subscriptions with a past expiry timestamp
        if (expiresAt != 0 && expiresAt <= uint48(block.timestamp)) {
            revert SubscriptionLib.SubscriptionExpired(bytes32(0));
        }

        // Validate plan
        Plan memory plan = merchantRegistry.getPlan(planId);
        if (plan.planId == bytes32(0)) revert SubscriptionLib.PlanNotFound(planId);
        if (!plan.active)              revert SubscriptionLib.PlanInactive(planId);

        // Derive subscription ID using per-account nonce for this plan
        uint256 nonce = _subscriptionNonce[account][planId];
        subscriptionId = SubscriptionLib.deriveSubscriptionId(account, plan.merchant, planId, nonce);

        // Check for active duplicate using the plan→subscription mapping
        bytes32 existing = _activePlanSubscription[account][planId];
        if (existing != bytes32(0)) {
            SubscriptionStatus existingStatus = _permissions[account][existing].status;
            if (existingStatus == SubscriptionStatus.Active || existingStatus == SubscriptionStatus.Paused) {
                revert SubscriptionLib.SubscriptionAlreadyActive(existing);
            }
        }

        uint48 startTime = uint48(block.timestamp);

        SubscriptionPermission memory perm = SubscriptionPermission({
            token:         plan.token,
            merchant:      plan.merchant,
            maxAmount:     plan.amount,
            periodSeconds: plan.period,
            startTime:     startTime,
            lastChargedAt: 0,
            expiresAt:     expiresAt,
            status:        SubscriptionStatus.Active,
            planId:        planId,
            sessionKey:    sessionKey
        });

        // Effects
        _permissions[account][subscriptionId] = perm;
        _idIndex[account][subscriptionId] = _accountSubscriptionIds[account].length + 1; // 1-based
        _accountSubscriptionIds[account].push(subscriptionId);
        _subscriptionNonce[account][planId] = nonce + 1;
        _activePlanSubscription[account][planId] = subscriptionId;

        // Interactions (registry is trusted; no CEI risk here)
        registry.register(subscriptionId, account, perm);

        emit SubscriptionCreated(
            subscriptionId,
            account,
            plan.merchant,
            planId,
            plan.token,
            plan.amount,
            plan.period,
            startTime,
            sessionKey
        );
    }

    /// @inheritdoc ISubscriptionModule
    function cancel(bytes32 subscriptionId) external {
        address account = msg.sender;
        SubscriptionPermission storage perm = _getPermission(account, subscriptionId);

        if (perm.status == SubscriptionStatus.Cancelled || perm.status == SubscriptionStatus.Expired) {
            revert SubscriptionLib.SubscriptionTerminal(subscriptionId);
        }

        uint8 oldStatus = uint8(perm.status);

        // Effects
        perm.status = SubscriptionStatus.Cancelled;
        _activePlanSubscription[account][perm.planId] = bytes32(0);
        _removeFromActiveList(account, subscriptionId);

        // Interactions
        registry.updateStatus(subscriptionId, uint8(SubscriptionStatus.Cancelled));

        emit SubscriptionCancelled(subscriptionId, account, uint48(block.timestamp));
        emit SubscriptionUpdated(subscriptionId, bytes32(0), bytes32(0), oldStatus, uint8(SubscriptionStatus.Cancelled));
    }

    /// @inheritdoc ISubscriptionModule
    function pause(bytes32 subscriptionId) external {
        address account = msg.sender;
        SubscriptionPermission storage perm = _getPermission(account, subscriptionId);

        if (perm.status != SubscriptionStatus.Active && perm.status != SubscriptionStatus.GracePeriod) {
            revert SubscriptionLib.SubscriptionNotActive(subscriptionId);
        }

        uint8 oldStatus = uint8(perm.status);

        // Effects
        perm.status = SubscriptionStatus.Paused;

        // Interactions
        registry.updateStatus(subscriptionId, uint8(SubscriptionStatus.Paused));

        emit SubscriptionUpdated(subscriptionId, bytes32(0), bytes32(0), oldStatus, uint8(SubscriptionStatus.Paused));
    }

    /// @inheritdoc ISubscriptionModule
    function resume(bytes32 subscriptionId) external {
        address account = msg.sender;
        SubscriptionPermission storage perm = _getPermission(account, subscriptionId);

        if (perm.status != SubscriptionStatus.Paused) {
            revert SubscriptionLib.SubscriptionNotPaused(subscriptionId);
        }

        // Check hard expiry before resuming
        if (perm.expiresAt != 0 && uint48(block.timestamp) >= perm.expiresAt) {
            revert SubscriptionLib.SubscriptionExpired(subscriptionId);
        }

        // Effects
        perm.status = SubscriptionStatus.Active;

        // Interactions
        registry.updateStatus(subscriptionId, uint8(SubscriptionStatus.Active));

        emit SubscriptionUpdated(subscriptionId, bytes32(0), bytes32(0), uint8(SubscriptionStatus.Paused), uint8(SubscriptionStatus.Active));
    }

    /// @inheritdoc ISubscriptionModule
    function update(bytes32 subscriptionId, bytes32 newPlanId) external {
        address account = msg.sender;
        SubscriptionPermission storage perm = _getPermission(account, subscriptionId);

        if (perm.status == SubscriptionStatus.Cancelled || perm.status == SubscriptionStatus.Expired) {
            revert SubscriptionLib.SubscriptionTerminal(subscriptionId);
        }

        // Validate new plan
        Plan memory newPlan = merchantRegistry.getPlan(newPlanId);
        if (newPlan.planId == bytes32(0)) revert SubscriptionLib.PlanNotFound(newPlanId);
        if (!newPlan.active)              revert SubscriptionLib.PlanInactive(newPlanId);

        // New plan must be for the same merchant
        if (newPlan.merchant != perm.merchant) {
            revert SubscriptionLib.PlanMerchantMismatch(newPlanId, perm.merchant, newPlan.merchant);
        }

        bytes32 oldPlanId = perm.planId;
        uint8 oldStatus   = uint8(perm.status);

        // [H-01] Fix _activePlanSubscription: clear old entry, set new one
        _activePlanSubscription[account][oldPlanId] = bytes32(0);
        _activePlanSubscription[account][newPlanId] = subscriptionId;

        // Effects — update terms, do NOT reset lastChargedAt
        perm.planId        = newPlanId;
        perm.maxAmount     = newPlan.amount;
        perm.periodSeconds = newPlan.period;
        perm.token         = newPlan.token;

        // [M-02] Sync registry with updated plan data
        registry.updatePermission(
            subscriptionId,
            newPlanId,
            newPlan.amount,
            newPlan.period,
            newPlan.token
        );

        emit SubscriptionUpdated(subscriptionId, oldPlanId, newPlanId, oldStatus, oldStatus);
    }

    /// @inheritdoc ISubscriptionModule
    function rotateSessionKey(bytes32 subscriptionId, address newSessionKey) external {
        address account = msg.sender;
        SubscriptionPermission storage perm = _getPermission(account, subscriptionId);

        if (perm.status == SubscriptionStatus.Cancelled || perm.status == SubscriptionStatus.Expired) {
            revert SubscriptionLib.SubscriptionTerminal(subscriptionId);
        }
        if (newSessionKey == address(0)) revert SubscriptionLib.InvalidSessionKeyAddress();

        // [L-03] Emit SessionKeyRotated event
        address oldKey = perm.sessionKey;
        perm.sessionKey = newSessionKey;
        emit SessionKeyRotated(subscriptionId, oldKey, newSessionKey, uint48(block.timestamp));
    }

    // ─── Renewal Execution ────────────────────────────────────────────────────

    /// @inheritdoc ISubscriptionModule
    /// @dev processRenewal is permissionless — on-chain constraints are the security
    ///      boundary. Any caller may submit this; the crank is a liveness mechanism only.
    function processRenewal(bytes32 subscriptionId) external nonReentrant {
        // Get user from registry
        (address account, , ) = registry.getRecord(subscriptionId);

        _executeRenewal(account, subscriptionId);
    }

    /// @notice Execute renewal on behalf of a specific account.
    /// @dev Can be called directly by the smart account or via processRenewal.
    /// @param account        The smart account owning the subscription.
    /// @param subscriptionId Subscription to renew.
    function processRenewalFor(address account, bytes32 subscriptionId) external nonReentrant {
        _executeRenewal(account, subscriptionId);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    /// @inheritdoc ISubscriptionModule
    function getSubscription(bytes32 subscriptionId)
        external
        view
        returns (SubscriptionPermission memory)
    {
        address account = msg.sender;
        return _permissions[account][subscriptionId];
    }

    /// @notice Get subscription for a specific account (callable by anyone).
    /// @param account        Smart account address.
    /// @param subscriptionId Subscription identifier.
    function getSubscriptionFor(address account, bytes32 subscriptionId)
        external
        view
        returns (SubscriptionPermission memory)
    {
        return _permissions[account][subscriptionId];
    }

    /// @inheritdoc ISubscriptionModule
    function getActiveSubscriptions()
        external
        view
        returns (
            bytes32[]                memory subscriptionIds,
            SubscriptionPermission[] memory permissions
        )
    {
        address account = msg.sender;
        return _getActiveSubscriptionsFor(account);
    }

    /// @notice Get active subscriptions for a specific account.
    /// @param account  Smart account address.
    function getActiveSubscriptionsFor(address account)
        external
        view
        returns (
            bytes32[]                memory subscriptionIds,
            SubscriptionPermission[] memory permissions
        )
    {
        return _getActiveSubscriptionsFor(account);
    }

    /// @notice Get the number of consecutive failed renewal attempts for a subscription.
    /// @param account        Smart account address.
    /// @param subscriptionId Subscription identifier.
    /// @return               Failed attempt count.
    function getFailedAttempts(address account, bytes32 subscriptionId)
        external
        view
        returns (uint8)
    {
        return _failedAttempts[account][subscriptionId];
    }

    /// @notice Get the grace period end timestamp for a subscription.
    /// @param account        Smart account address.
    /// @param subscriptionId Subscription identifier.
    /// @return               Grace period end timestamp (0 if not in grace).
    function getGraceUntil(address account, bytes32 subscriptionId)
        external
        view
        returns (uint48)
    {
        return _graceUntil[account][subscriptionId];
    }

    // ─── Internal Helpers ─────────────────────────────────────────────────────

    function _getPermission(
        address account,
        bytes32 subscriptionId
    ) internal view returns (SubscriptionPermission storage perm) {
        perm = _permissions[account][subscriptionId];
        if (perm.sessionKey == address(0)) {
            revert SubscriptionLib.SubscriptionNotFound(subscriptionId);
        }
    }

    function _validateRenewalInternal(
        address account,
        bytes32 subscriptionId,
        bytes32 userOpHash,
        bytes memory signature
    ) internal view returns (uint256) {
        SubscriptionPermission storage perm = _permissions[account][subscriptionId];
        if (perm.sessionKey == address(0)) {
            revert SubscriptionLib.SubscriptionNotFound(subscriptionId);
        }

        // Terminal state — hard revert per ISubscriptionValidator spec
        if (perm.status == SubscriptionStatus.Cancelled || perm.status == SubscriptionStatus.Expired) {
            revert SubscriptionLib.SubscriptionTerminal(subscriptionId);
        }

        // Must be Active (not Paused or GracePeriod)
        if (perm.status != SubscriptionStatus.Active) {
            return VALIDATION_FAILED;
        }

        // Hard expiry
        if (perm.expiresAt != 0 && uint48(block.timestamp) >= perm.expiresAt) {
            revert SubscriptionLib.SubscriptionExpired(subscriptionId);
        }

        // [H-02] Period elapsed check — MUST per ISubscriptionValidator spec
        // First charge: lastChargedAt == 0, use startTime + periodSeconds
        uint48 earliestNextCharge = perm.lastChargedAt == 0
            ? perm.startTime + perm.periodSeconds
            : perm.lastChargedAt + perm.periodSeconds;
        if (uint48(block.timestamp) < earliestNextCharge) {
            return VALIDATION_FAILED;
        }

        // Recover signer from userOpHash + signature
        address recovered = SubscriptionLib.recoverSigner(userOpHash, signature);
        if (recovered != perm.sessionKey) {
            return VALIDATION_FAILED;
        }

        return VALIDATION_SUCCESS;
    }

    function _executeRenewal(address account, bytes32 subscriptionId) internal {
        SubscriptionPermission storage perm = _permissions[account][subscriptionId];
        if (perm.sessionKey == address(0)) {
            revert SubscriptionLib.SubscriptionNotFound(subscriptionId);
        }

        // ── Checks ────────────────────────────────────────────────────────────

        // Allow renewals from Active and GracePeriod states
        if (perm.status != SubscriptionStatus.Active && perm.status != SubscriptionStatus.GracePeriod) {
            revert SubscriptionLib.SubscriptionNotActive(subscriptionId);
        }

        // Hard expiry
        if (perm.expiresAt != 0 && uint48(block.timestamp) >= perm.expiresAt) {
            // Mark expired
            perm.status = SubscriptionStatus.Expired;
            _activePlanSubscription[account][perm.planId] = bytes32(0);
            _removeFromActiveList(account, subscriptionId);
            registry.updateStatus(subscriptionId, uint8(SubscriptionStatus.Expired));
            emit SubscriptionExpired(subscriptionId, "hard_expiry");
            return;
        }

        // [M-03] If in GracePeriod, check whether grace window has expired
        if (perm.status == SubscriptionStatus.GracePeriod) {
            uint48 graceEnd = _graceUntil[account][subscriptionId];
            if (graceEnd != 0 && uint48(block.timestamp) >= graceEnd) {
                // Grace period elapsed without payment → expire
                perm.status = SubscriptionStatus.Expired;
                _activePlanSubscription[account][perm.planId] = bytes32(0);
                _removeFromActiveList(account, subscriptionId);
                registry.updateStatus(subscriptionId, uint8(SubscriptionStatus.Expired));
                emit SubscriptionExpired(subscriptionId, "grace_period_expired");
                return;
            }
        }

        // [M-01] Period elapsed check: first charge requires startTime + periodSeconds
        uint48 validFrom = perm.lastChargedAt == 0
            ? perm.startTime + perm.periodSeconds
            : perm.lastChargedAt + perm.periodSeconds;

        if (uint48(block.timestamp) < validFrom) {
            revert SubscriptionLib.PeriodNotElapsed(subscriptionId, validFrom, uint48(block.timestamp));
        }

        uint256 chargeAmount = perm.maxAmount;

        // ── Pre-compute fee (read-only, before state changes) ─────────────────

        bytes32 merchantId = merchantRegistry.getMerchantIdByReceiver(perm.merchant);
        uint16 feeBps = 0;
        if (merchantId != bytes32(0)) {
            feeBps = merchantRegistry.getMerchant(merchantId).feeTier;
        }
        uint256 feeAmount = (chargeAmount * feeBps) / 10_000;
        uint256 netAmount = chargeAmount - feeAmount;

        // ── Attempt transfer FIRST (before state changes) ─────────────────────
        // [M-03] Non-reverting failure path: if transfer fails, emit SubscriptionFailed
        // and begin the GracePeriod state machine. The crank transaction does not revert,
        // and lastChargedAt is NOT advanced on failure (billing clock preserved).
        // nonReentrant guards the outer function.
        bool transferSuccess = _tryTransfer(perm.token, account, perm.merchant, netAmount);
        if (!transferSuccess) {
            _handleFailedRenewal(account, subscriptionId, perm, "transfer_failed");
            return;
        }

        // ── Effects (only committed on successful transfer) ───────────────────

        uint48 chargedAt = uint48(block.timestamp);
        uint48 newNextChargeAt = chargedAt + perm.periodSeconds;
        perm.lastChargedAt = chargedAt;

        // Reset failure counter and recover from GracePeriod on success
        _failedAttempts[account][subscriptionId] = 0;
        bool wasInGrace = perm.status == SubscriptionStatus.GracePeriod;
        if (wasInGrace) {
            perm.status = SubscriptionStatus.Active;
            _graceUntil[account][subscriptionId] = 0;
        }

        // ── Remaining interactions (after state committed) ────────────────────

        // Transfer fee to treasury (only if non-zero)
        if (feeAmount > 0) {
            IERC20(perm.token).safeTransferFrom(account, treasury, feeAmount);
        }

        // Sync registry: status back to Active if recovered from GracePeriod
        if (wasInGrace) {
            registry.updateStatus(subscriptionId, uint8(SubscriptionStatus.Active));
        }
        registry.recordCharge(subscriptionId, chargedAt, chargeAmount);

        emit SubscriptionCharged(
            subscriptionId,
            perm.merchant,
            netAmount,
            feeAmount,
            chargedAt,
            newNextChargeAt
        );
    }

    /// @dev Attempt an ERC-20 transferFrom without reverting on failure.
    ///      Returns true on success, false on failure.
    function _tryTransfer(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal returns (bool success) {
        try IERC20(token).transferFrom(from, to, amount) returns (bool ok) {
            success = ok;
        } catch {
            success = false;
        }
    }

    /// @dev Handle a failed renewal: update state, emit events, transition to GracePeriod/Expired.
    function _handleFailedRenewal(
        address account,
        bytes32 subscriptionId,
        SubscriptionPermission storage perm,
        string memory reason
    ) internal {
        uint8 attempts = _failedAttempts[account][subscriptionId] + 1;
        _failedAttempts[account][subscriptionId] = attempts;

        emit SubscriptionFailed(subscriptionId, attempts, reason);

        if (attempts >= MAX_FAILED_ATTEMPTS) {
            if (perm.status != SubscriptionStatus.GracePeriod) {
                // Transition to GracePeriod
                uint8 oldStatus = uint8(perm.status);
                perm.status = SubscriptionStatus.GracePeriod;
                uint48 graceEnd = uint48(block.timestamp) + GRACE_PERIOD_SECONDS;
                _graceUntil[account][subscriptionId] = graceEnd;
                registry.updateStatus(subscriptionId, uint8(SubscriptionStatus.GracePeriod));
                emit SubscriptionUpdated(
                    subscriptionId,
                    bytes32(0),
                    bytes32(0),
                    oldStatus,
                    uint8(SubscriptionStatus.GracePeriod)
                );
            }
            // If already in GracePeriod, keep it there (grace expiry is checked in _executeRenewal)
        }
    }

    function _getActiveSubscriptionsFor(address account)
        internal
        view
        returns (
            bytes32[]                memory ids,
            SubscriptionPermission[] memory perms
        )
    {
        bytes32[] storage allIds = _accountSubscriptionIds[account];
        uint256 len = allIds.length;

        // Count active/paused/grace
        uint256 count = 0;
        for (uint256 i = 0; i < len; ) {
            SubscriptionStatus s = _permissions[account][allIds[i]].status;
            if (s == SubscriptionStatus.Active || s == SubscriptionStatus.Paused || s == SubscriptionStatus.GracePeriod) {
                unchecked { ++count; }
            }
            unchecked { ++i; }
        }

        ids   = new bytes32[](count);
        perms = new SubscriptionPermission[](count);
        uint256 idx = 0;

        for (uint256 i = 0; i < len; ) {
            bytes32 sid = allIds[i];
            SubscriptionStatus s = _permissions[account][sid].status;
            if (s == SubscriptionStatus.Active || s == SubscriptionStatus.Paused || s == SubscriptionStatus.GracePeriod) {
                ids[idx]   = sid;
                perms[idx] = _permissions[account][sid];
                unchecked { ++idx; }
            }
            unchecked { ++i; }
        }
    }

    /// @dev Remove a subscription from the active list using swap-and-pop.
    function _removeFromActiveList(address account, bytes32 subscriptionId) internal {
        uint256 idx = _idIndex[account][subscriptionId];
        if (idx == 0) return; // not in list

        bytes32[] storage list = _accountSubscriptionIds[account];
        uint256 lastIdx = list.length - 1;
        uint256 targetIdx = idx - 1; // convert to 0-based

        if (targetIdx != lastIdx) {
            bytes32 lastId = list[lastIdx];
            list[targetIdx] = lastId;
            _idIndex[account][lastId] = idx; // update moved element's 1-based index
        }

        list.pop();
        delete _idIndex[account][subscriptionId];
    }
}
