// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.28;

import { SubscriptionPermission } from "../libraries/SubscriptionLib.sol";

/// @title ISubscriptionRegistry
/// @notice Global index of all subscription permissions across all accounts.
/// @dev Modules and delegates MUST call register() on creation and
///      updateStatus() on every status transition.
interface ISubscriptionRegistry {

    // ─── Events ───────────────────────────────────────────────────────────────

    /// @notice Emitted when a new subscription is registered.
    event SubscriptionRegistered(
        bytes32 indexed subscriptionId,
        address indexed user,
        address indexed merchant
    );

    /// @notice Emitted when a subscription's status is updated.
    event StatusUpdated(bytes32 indexed subscriptionId, uint8 newStatus);

    /// @notice Emitted when a charge is recorded.
    event ChargeRecorded(bytes32 indexed subscriptionId, uint48 chargedAt, uint256 amount);

    /// @notice Emitted when a subscription's permission fields are updated (e.g., after plan upgrade).
    event PermissionUpdated(
        bytes32 indexed subscriptionId,
        bytes32         newPlanId,
        uint256         newMaxAmount,
        uint32          newPeriodSeconds,
        address         newToken
    );

    /// @notice Emitted when a module's registration authorization changes.
    event ModuleAuthorizationUpdated(address indexed module, bool authorized);

    // ─── Write ────────────────────────────────────────────────────────────────

    /// @notice Register a new subscription. Called by the module at subscribe().
    /// @param subscriptionId  Subscription identifier.
    /// @param user            Smart account or EOA address.
    /// @param permission      Full permission struct at creation time.
    function register(
        bytes32                         subscriptionId,
        address                         user,
        SubscriptionPermission calldata permission
    ) external;

    /// @notice Notify the registry of a status change.
    /// @dev Called by the module on cancel/pause/resume/expire transitions.
    /// @param subscriptionId  Target subscription.
    /// @param newStatus       Updated status value.
    function updateStatus(bytes32 subscriptionId, uint8 newStatus) external;

    /// @notice Notify the registry of a successful charge.
    /// @dev Updates lastChargedAt in the registry's cached copy.
    ///      The module is authoritative; the registry mirrors for query efficiency.
    /// @param subscriptionId  Target subscription.
    /// @param chargedAt       Timestamp of successful charge.
    /// @param amount          Token amount charged.
    function recordCharge(
        bytes32 subscriptionId,
        uint48  chargedAt,
        uint256 amount
    ) external;

    /// @notice Update the plan fields in the registry's cached copy after a plan upgrade.
    /// @dev Called by the module after update() to keep the registry in sync.
    /// @param subscriptionId   Target subscription.
    /// @param newPlanId        New plan identifier.
    /// @param newMaxAmount     New charge amount per period.
    /// @param newPeriodSeconds New billing interval.
    /// @param newToken         New billing token.
    function updatePermission(
        bytes32 subscriptionId,
        bytes32 newPlanId,
        uint256 newMaxAmount,
        uint32  newPeriodSeconds,
        address newToken
    ) external;

    // ─── Crank Query Interface ─────────────────────────────────────────────────

    /// @notice Return subscription IDs whose next renewal is due.
    /// @dev A subscription is due when:
    ///      lastChargedAt + periodSeconds <= block.timestamp
    ///      AND status == Active
    ///      AND (expiresAt == 0 OR block.timestamp < expiresAt)
    ///      Implementations SHOULD paginate — large deployments may have millions of
    ///      subscriptions and this function MUST NOT exceed block gas limits.
    /// @param cursor  Pagination offset (0 for first page).
    /// @param limit   Maximum number of results to return.
    /// @return ids         Due subscription IDs.
    /// @return nextCursor  Cursor for the next page (0 if no more results).
    function getDueSubscriptions(uint256 cursor, uint256 limit)
        external
        view
        returns (bytes32[] memory ids, uint256 nextCursor);

    /// @notice Return all subscription IDs for a given user address.
    /// @param user   Smart account or EOA address.
    /// @return ids   All subscription IDs registered for this user.
    function getSubscriptionsByUser(address user)
        external
        view
        returns (bytes32[] memory ids);

    /// @notice Return all subscription IDs for a given merchant.
    /// @param merchant  Merchant receiving address.
    /// @return ids      All subscription IDs registered for this merchant.
    function getSubscriptionsByMerchant(address merchant)
        external
        view
        returns (bytes32[] memory ids);

    /// @notice Return all non-terminal subscriptions for a user address.
    /// @dev Wallets call this to populate the subscription dashboard.
    ///      MUST return Active and Paused subscriptions.
    ///      MUST NOT return Cancelled or Expired subscriptions.
    /// @param wallet  User's smart account or EOA address.
    /// @return ids         Subscription IDs.
    /// @return permissions Full SubscriptionPermission structs.
    function getActiveSubscriptionsForWallet(address wallet)
        external
        view
        returns (
            bytes32[]                memory ids,
            SubscriptionPermission[] memory permissions
        );
}
