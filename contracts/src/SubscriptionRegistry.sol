// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.28;

import {
    SubscriptionPermission,
    SubscriptionStatus,
    SubscriptionLib
} from "./libraries/SubscriptionLib.sol";
import { ISubscriptionRegistry } from "./interfaces/ISubscriptionRegistry.sol";

/// @title SubscriptionRegistry
/// @notice Global singleton registry indexing all subscription permissions.
/// @dev This contract holds NO user funds and has NO transfer authority.
///      It is a pure index/mirror — the SubscriptionModule is the authoritative
///      source for permission state. The registry mirrors status and lastChargedAt
///      for efficient off-chain crank queries and wallet visibility.
///
///      Write access model:
///      - `register()` is restricted to authorized modules (whitelisted by the module admin).
///      - `updateStatus()` and `recordCharge()` are restricted to the module
///        that originally registered a given subscription.
///
///      Pagination:
///      - `getDueSubscriptions` returns `nextCursor = type(uint256).max` when there
///        are no more pages. A cursor of 0 is a valid start position.
contract SubscriptionRegistry is ISubscriptionRegistry {

    // ─── Storage ──────────────────────────────────────────────────────────────

    /// @dev Internal record combining permission snapshot with metadata.
    struct Record {
        SubscriptionPermission permission;
        address                user;
        address                module;      // authoritative module for write-back
        bool                   exists;
    }

    /// @notice subscriptionId → Record.
    mapping(bytes32 => Record) private _records;

    /// @notice user → list of subscription IDs (all-time).
    mapping(address => bytes32[]) private _userSubscriptions;

    /// @notice merchant (receiver) → list of subscription IDs (all-time).
    mapping(address => bytes32[]) private _merchantSubscriptions;

    /// @notice Flat ordered list of all subscription IDs (for paginated crank queries).
    bytes32[] private _allIds;

    /// @notice Addresses authorized to call `register()`.
    mapping(address => bool) public authorizedModules;

    /// @notice Address authorized to manage module authorization.
    address public immutable moduleAdmin;

    // ─── Errors ───────────────────────────────────────────────────────────────

    error SubscriptionAlreadyRegistered(bytes32 subscriptionId);
    error SubscriptionNotRegistered(bytes32 subscriptionId);
    error UnauthorizedModule(bytes32 subscriptionId, address caller, address expected);
    error UnauthorizedRegistrar(address caller);
    error NotModuleAdmin();

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @param _moduleAdmin  Address authorized to grant/revoke module registration rights.
    constructor(address _moduleAdmin) {
        moduleAdmin = _moduleAdmin;
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    /// @notice Grant or revoke module registration authorization.
    /// @param module      Module address.
    /// @param authorized  True to authorize, false to revoke.
    function setAuthorizedModule(address module, bool authorized) external {
        if (msg.sender != moduleAdmin) revert NotModuleAdmin();
        authorizedModules[module] = authorized;
        emit ModuleAuthorizationUpdated(module, authorized);
    }

    // ─── Write Interface ──────────────────────────────────────────────────────

    /// @inheritdoc ISubscriptionRegistry
    function register(
        bytes32                         subscriptionId,
        address                         user,
        SubscriptionPermission calldata permission
    ) external {
        if (!authorizedModules[msg.sender]) revert UnauthorizedRegistrar(msg.sender);
        if (_records[subscriptionId].exists) {
            revert SubscriptionAlreadyRegistered(subscriptionId);
        }
        if (user == address(0)) revert SubscriptionLib.ZeroAddress();

        _records[subscriptionId] = Record({
            permission: permission,
            user:       user,
            module:     msg.sender,
            exists:     true
        });

        _userSubscriptions[user].push(subscriptionId);
        _merchantSubscriptions[permission.merchant].push(subscriptionId);
        _allIds.push(subscriptionId);

        emit SubscriptionRegistered(subscriptionId, user, permission.merchant);
    }

    /// @inheritdoc ISubscriptionRegistry
    function updateStatus(bytes32 subscriptionId, uint8 newStatus) external {
        Record storage rec = _records[subscriptionId];
        if (!rec.exists) revert SubscriptionNotRegistered(subscriptionId);
        if (rec.module != msg.sender) {
            revert UnauthorizedModule(subscriptionId, msg.sender, rec.module);
        }

        rec.permission.status = SubscriptionStatus(newStatus);
        emit StatusUpdated(subscriptionId, newStatus);
    }

    /// @inheritdoc ISubscriptionRegistry
    function recordCharge(
        bytes32 subscriptionId,
        uint48  chargedAt,
        uint256 amount
    ) external {
        Record storage rec = _records[subscriptionId];
        if (!rec.exists) revert SubscriptionNotRegistered(subscriptionId);
        if (rec.module != msg.sender) {
            revert UnauthorizedModule(subscriptionId, msg.sender, rec.module);
        }

        rec.permission.lastChargedAt = chargedAt;
        emit ChargeRecorded(subscriptionId, chargedAt, amount);
    }

    /// @inheritdoc ISubscriptionRegistry
    function updatePermission(
        bytes32 subscriptionId,
        bytes32 newPlanId,
        uint256 newMaxAmount,
        uint32  newPeriodSeconds,
        address newToken
    ) external {
        Record storage rec = _records[subscriptionId];
        if (!rec.exists) revert SubscriptionNotRegistered(subscriptionId);
        if (rec.module != msg.sender) {
            revert UnauthorizedModule(subscriptionId, msg.sender, rec.module);
        }

        rec.permission.planId        = newPlanId;
        rec.permission.maxAmount     = newMaxAmount;
        rec.permission.periodSeconds = newPeriodSeconds;
        rec.permission.token         = newToken;

        emit PermissionUpdated(subscriptionId, newPlanId, newMaxAmount, newPeriodSeconds, newToken);
    }

    // ─── Crank Query Interface ─────────────────────────────────────────────────

    /// @inheritdoc ISubscriptionRegistry
    /// @dev Returns nextCursor = type(uint256).max when pagination is exhausted
    ///      (a cursor of 0 is the valid start, so 0 cannot be used as a sentinel).
    function getDueSubscriptions(uint256 cursor, uint256 limit)
        external
        view
        returns (bytes32[] memory ids, uint256 nextCursor)
    {
        uint256 total = _allIds.length;
        if (cursor >= total || limit == 0) {
            return (new bytes32[](0), type(uint256).max);
        }

        // Allocate max possible output
        bytes32[] memory buffer = new bytes32[](limit);
        uint256 found = 0;
        uint256 i = cursor;

        while (i < total && found < limit) {
            bytes32 sid = _allIds[i];
            Record storage rec = _records[sid];
            SubscriptionPermission storage p = rec.permission;

            if (p.status == SubscriptionStatus.Active || p.status == SubscriptionStatus.GracePeriod) {
                // Fix M-01: use startTime + periodSeconds for the first charge
                uint48 validFrom = p.lastChargedAt == 0
                    ? p.startTime + p.periodSeconds
                    : p.lastChargedAt + p.periodSeconds;
                bool periodElapsed = (uint48(block.timestamp) >= validFrom);
                bool notExpired    = (p.expiresAt == 0 || uint48(block.timestamp) < p.expiresAt);
                if (periodElapsed && notExpired) {
                    buffer[found] = sid;
                    unchecked { ++found; }
                }
            }
            unchecked { ++i; }
        }

        // Trim to actual found count
        ids = new bytes32[](found);
        for (uint256 j = 0; j < found; ) {
            ids[j] = buffer[j];
            unchecked { ++j; }
        }

        nextCursor = (i < total) ? i : type(uint256).max;
    }

    // ─── User / Merchant Queries ──────────────────────────────────────────────

    /// @inheritdoc ISubscriptionRegistry
    function getSubscriptionsByUser(address user)
        external
        view
        returns (bytes32[] memory ids)
    {
        return _userSubscriptions[user];
    }

    /// @inheritdoc ISubscriptionRegistry
    function getSubscriptionsByMerchant(address merchant)
        external
        view
        returns (bytes32[] memory ids)
    {
        return _merchantSubscriptions[merchant];
    }

    /// @inheritdoc ISubscriptionRegistry
    function getActiveSubscriptionsForWallet(address wallet)
        external
        view
        returns (
            bytes32[]                memory ids,
            SubscriptionPermission[] memory permissions
        )
    {
        bytes32[] storage allUser = _userSubscriptions[wallet];
        uint256 len = allUser.length;

        // First pass: count active/paused
        uint256 count = 0;
        for (uint256 i = 0; i < len; ) {
            SubscriptionStatus s = _records[allUser[i]].permission.status;
            if (s == SubscriptionStatus.Active || s == SubscriptionStatus.Paused || s == SubscriptionStatus.GracePeriod) {
                unchecked { ++count; }
            }
            unchecked { ++i; }
        }

        ids         = new bytes32[](count);
        permissions = new SubscriptionPermission[](count);

        uint256 idx = 0;
        for (uint256 i = 0; i < len; ) {
            bytes32 sid = allUser[i];
            SubscriptionPermission storage p = _records[sid].permission;
            if (p.status == SubscriptionStatus.Active || p.status == SubscriptionStatus.Paused || p.status == SubscriptionStatus.GracePeriod) {
                ids[idx]         = sid;
                permissions[idx] = p;
                unchecked { ++idx; }
            }
            unchecked { ++i; }
        }
    }

    // ─── Admin Views ──────────────────────────────────────────────────────────

    /// @notice Look up a full record by subscription ID.
    /// @param subscriptionId  Target subscription.
    /// @return user        Owning user address.
    /// @return module      Authoritative module address.
    /// @return permission  Mirrored permission struct.
    function getRecord(bytes32 subscriptionId)
        external
        view
        returns (
            address                user,
            address                module,
            SubscriptionPermission memory permission
        )
    {
        Record storage rec = _records[subscriptionId];
        if (!rec.exists) revert SubscriptionNotRegistered(subscriptionId);
        return (rec.user, rec.module, rec.permission);
    }

    /// @notice Total number of registered subscriptions (all-time, all statuses).
    function totalSubscriptions() external view returns (uint256) {
        return _allIds.length;
    }
}
