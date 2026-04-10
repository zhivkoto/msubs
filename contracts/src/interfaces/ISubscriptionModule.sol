// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.28;

import { SubscriptionPermission } from "../libraries/SubscriptionLib.sol";

/// @title ISubscriptionModule
/// @notice ERC-7579 Validator + Executor module interface for subscription permissions.
/// @dev Implementations MUST comply with ERC-7579 module interfaces (IValidator, IExecutor)
///      in addition to this interface.
interface ISubscriptionModule {

    // ─── Events ───────────────────────────────────────────────────────────────

    /// @notice Emitted when a subscription is successfully created.
    /// @param subscriptionId  Unique subscription identifier.
    /// @param user            Smart account or EOA that holds the permission.
    /// @param merchant        Merchant receiving address.
    /// @param planId          Merchant plan identifier.
    /// @param token           ERC-20 token for billing.
    /// @param amount          Charge amount per period.
    /// @param periodSeconds   Billing interval.
    /// @param startTime       Subscription start timestamp.
    /// @param sessionKey      Session key authorized for renewals.
    event SubscriptionCreated(
        bytes32 indexed subscriptionId,
        address indexed user,
        address indexed merchant,
        bytes32         planId,
        address         token,
        uint256         amount,
        uint32          periodSeconds,
        uint48          startTime,
        address         sessionKey
    );

    /// @notice Emitted on every successful renewal charge.
    /// @param subscriptionId  Subscription that was charged.
    /// @param merchant        Merchant receiving address.
    /// @param amount          Token amount transferred to merchant.
    /// @param fee             Protocol fee amount.
    /// @param timestamp       Block timestamp of the charge.
    /// @param nextChargeAt    Earliest timestamp for the next renewal.
    event SubscriptionCharged(
        bytes32 indexed subscriptionId,
        address indexed merchant,
        uint256         amount,
        uint256         fee,
        uint48          timestamp,
        uint48          nextChargeAt
    );

    /// @notice Emitted when a renewal attempt fails.
    /// @param subscriptionId  Subscription that failed.
    /// @param retryCount      Total failed attempts for the current period (1-indexed).
    /// @param reason          Human-readable failure reason.
    event SubscriptionFailed(
        bytes32 indexed subscriptionId,
        uint8           retryCount,
        string          reason
    );

    /// @notice Emitted when a user cancels a subscription.
    /// @param subscriptionId  Cancelled subscription.
    /// @param canceller       Address that initiated cancellation (account owner).
    /// @param timestamp       Block timestamp of cancellation.
    event SubscriptionCancelled(
        bytes32 indexed subscriptionId,
        address indexed canceller,
        uint48          timestamp
    );

    /// @notice Emitted when a subscription's plan or status is updated.
    /// @param subscriptionId  Updated subscription.
    /// @param oldPlanId       Previous plan (zero bytes32 if status-only change).
    /// @param newPlanId       New plan (zero bytes32 if status-only change).
    /// @param oldStatus       Previous SubscriptionStatus value.
    /// @param newStatus       New SubscriptionStatus value.
    event SubscriptionUpdated(
        bytes32 indexed subscriptionId,
        bytes32         oldPlanId,
        bytes32         newPlanId,
        uint8           oldStatus,
        uint8           newStatus
    );

    /// @notice Emitted when a subscription reaches its hard expiry or exceeds max retries.
    /// @param subscriptionId  Expired subscription.
    /// @param reason          "hard_expiry" | "max_retries_exceeded" | "grace_period_expired".
    event SubscriptionExpired(
        bytes32 indexed subscriptionId,
        string          reason
    );

    /// @notice Emitted when the session key for a subscription is rotated.
    /// @param subscriptionId  Target subscription.
    /// @param oldKey          Previous session key (now invalidated).
    /// @param newKey          New session key.
    /// @param timestamp       Block timestamp of the rotation.
    event SessionKeyRotated(
        bytes32 indexed subscriptionId,
        address indexed oldKey,
        address indexed newKey,
        uint48          timestamp
    );

    // ─── Lifecycle ────────────────────────────────────────────────────────────

    /// @notice Create a new subscription permission.
    /// @dev MUST be called from the account that will hold the permission
    ///      (i.e., msg.sender == the smart account, or via UserOperation).
    ///      Emits SubscriptionCreated.
    ///      Reverts if planId does not exist in the MerchantRegistry, or if
    ///      a permission for (merchant, planId) already exists with Active status.
    /// @param planId     Merchant plan to subscribe to.
    /// @param sessionKey Address whose corresponding private key the platform
    ///                   will use to sign renewal UserOperations.
    /// @param expiresAt  Hard expiry timestamp. Pass 0 for no expiry.
    /// @return subscriptionId keccak256 identifier for this permission.
    function subscribe(
        bytes32 planId,
        address sessionKey,
        uint48  expiresAt
    ) external returns (bytes32 subscriptionId);

    /// @notice Cancel a subscription permanently.
    /// @dev MUST be callable only by the account owner (not the session key).
    ///      Sets status to Cancelled, invalidates session key for this subscription.
    ///      Emits SubscriptionCancelled.
    /// @param subscriptionId Subscription to cancel.
    function cancel(bytes32 subscriptionId) external;

    /// @notice Pause renewal attempts.
    /// @dev MUST be callable only by the account owner.
    ///      Crank MUST NOT attempt renewals on Paused subscriptions.
    ///      Emits SubscriptionUpdated with status change.
    /// @param subscriptionId Subscription to pause.
    function pause(bytes32 subscriptionId) external;

    /// @notice Resume a paused subscription.
    /// @dev MUST be callable only by the account owner.
    ///      Sets status back to Active.
    ///      Emits SubscriptionUpdated with status change.
    /// @param subscriptionId Subscription to resume.
    function resume(bytes32 subscriptionId) external;

    /// @notice Upgrade or downgrade to a different plan.
    /// @dev MUST be callable only by the account owner.
    ///      New plan MUST be registered in MerchantRegistry for the same merchant.
    ///      Updates maxAmount, periodSeconds, and planId.
    ///      MUST NOT reset lastChargedAt (proration logic is application-layer).
    ///      Emits SubscriptionUpdated.
    /// @param subscriptionId   Subscription to update.
    /// @param newPlanId        Replacement plan identifier.
    function update(bytes32 subscriptionId, bytes32 newPlanId) external;

    // ─── Session Key Rotation ─────────────────────────────────────────────────

    /// @notice Replace the session key for a subscription.
    /// @dev MUST be callable only by the account owner.
    ///      Old session key is invalidated immediately upon execution.
    /// @param subscriptionId  Target subscription.
    /// @param newSessionKey   Replacement session key address.
    function rotateSessionKey(bytes32 subscriptionId, address newSessionKey) external;

    // ─── Renewal Execution ────────────────────────────────────────────────────

    /// @notice Execute a renewal charge for a subscription.
    /// @dev MAY be called by the session key (via UserOperation) or the platform crank.
    ///      Enforces all on-chain constraints: period elapsed, amount cap, active status.
    ///      Executes ERC-20 transfer: smart account → merchant (net) + treasury (fee).
    ///      Emits SubscriptionCharged on success.
    /// @param subscriptionId  Subscription to renew.
    function processRenewal(bytes32 subscriptionId) external;

    /// @notice Execute a renewal on behalf of a specific account.
    /// @dev MAY be called by any address (permissionless crank). Same constraints as processRenewal.
    /// @param account         The smart account owning the subscription.
    /// @param subscriptionId  Subscription to renew.
    function processRenewalFor(address account, bytes32 subscriptionId) external;

    // ─── Views ────────────────────────────────────────────────────────────────

    /// @notice Retrieve a subscription permission by ID.
    /// @param subscriptionId  keccak256 subscription identifier.
    /// @return permission     The full SubscriptionPermission struct.
    function getSubscription(bytes32 subscriptionId)
        external
        view
        returns (SubscriptionPermission memory permission);

    /// @notice Enumerate all active subscriptions for this account.
    /// @dev Implementations SHOULD return Paused subscriptions in addition to Active.
    ///      MUST NOT return Cancelled or Expired subscriptions.
    ///      Used by wallets to display the subscription dashboard.
    /// @return subscriptionIds  Array of active/paused subscription IDs.
    /// @return permissions      Corresponding SubscriptionPermission structs.
    function getActiveSubscriptions()
        external
        view
        returns (
            bytes32[]                   memory subscriptionIds,
            SubscriptionPermission[]    memory permissions
        );
}
