# MIP: Subscription Permissions Standard

| Field | Value |
|---|---|
| MIP | TBD |
| Title | Subscription Permissions Standard |
| Author | Zhivko Todorov (@zhivkoto) |
| Status | Draft |
| Type | Standards Track |
| Category | ERC / Application |
| Created | 2026-04-10 |
| Requires | ERC-4337, ERC-7579, EIP-7702 |

---

## 1. Executive Summary

This proposal defines a standard interface for subscription-based payment permissions on Monad, covering the `SubscriptionPermission` data structure, module interface, event schema, EIP-712 typed signature format, URI deep-link scheme, and wallet visibility interface. The standard is implemented as an ERC-7579 module (`ISubscriptionModule`) composable with any compliant smart account and as a delegation target (`SubscriptionDelegate`) for EIP-7702 EOA users — both of which are live deployment targets on Monad today via Biconomy Nexus and Pimlico. Without a common interface, each smart account vendor encodes subscription permissions incompatibly, wallets cannot surface active subscriptions, merchants must integrate per-vendor, and the broader ecosystem cannot build shared tooling. This MIP provides the ERC-20-equivalent standard for recurring payments: a minimal, opinionated interface that any wallet, smart account implementation, or merchant SDK can adopt, enabling interoperability without prescribing execution internals.

---

## 2. Problem Statement

Recurring payments are the dominant monetization primitive of the internet, yet no standard for expressing subscription permissions exists across Monad's account abstraction stack. The status quo produces the following failures:

**Fragmented encoding.** Biconomy Nexus session keys, ZeroDev session keys, and Safe plugins each encode "recurring payment authorization" in incompatible ways. A wallet cannot enumerate a user's active subscriptions across smart account implementations. A merchant's backend cannot verify authorization state without vendor-specific SDK calls.

**No wallet-layer visibility.** Because there is no standard struct or interface, wallets cannot display "Active Subscriptions" alongside token balances and NFTs. Users have no in-wallet mechanism to audit, pause, or cancel subscriptions. This is a security gap: a user with multiple subscriptions has no consolidated view of ongoing authorization grants.

**Per-vendor merchant integration.** Merchants wanting to accept recurring crypto payments must integrate separately with Biconomy, ZeroDev, Safe, and any future smart account implementation that gains adoption. This friction prevents merchant adoption and fragments the ecosystem.

**No interoperable URI format.** There is no standard deep-link format for initiating a subscription (analogous to `ethereum:` for transfers or WalletConnect URIs for sessions). Mobile wallets, QR codes, and in-app redirects each use ad-hoc formats.

**EOA exclusion.** Without a standard delegation interface for EIP-7702, EOA users cannot participate in subscription protocols without migrating to a smart contract wallet — a barrier that excludes the majority of active Monad wallets today.

This MIP addresses all five gaps by specifying the minimal interface surface required for interoperability, without constraining implementation internals.

---

## 3. Proposed Solution Overview

The standard defines five interoperable components that compose over Monad's existing AA infrastructure:

```
┌───────────────────────────────────────────────────────────────────────┐
│                   SUBSCRIPTION PERMISSIONS STANDARD                    │
│                                                                        │
│  ┌─────────────────┐  ┌─────────────────┐  ┌────────────────────────┐ │
│  │  Merchant        │  │  Subscription   │  │  Subscription          │ │
│  │  Registry        │  │  Registry       │  │  Paymaster             │ │
│  │  (IMerchantReg.) │  │  (ISubRegistry) │  │  (ISubPaymaster)       │ │
│  │                  │  │                 │  │                        │ │
│  │ Plans & merchant │  │ Global index of │  │ Sponsors gas for       │ │
│  │ configuration    │  │ subscriptions   │  │ renewal UserOps        │ │
│  └────────┬─────────┘  └────────┬────────┘  └──────────┬─────────────┘ │
│           │                     │                       │               │
│  ┌────────┴─────────────────────┴───────────────────────┴─────────────┐ │
│  │                    SubscriptionExecutor (off-standard)              │ │
│  │   processRenewal(subscriptionId) — calls into module/delegate      │ │
│  └─────────────────────────────────┬───────────────────────────────── ┘ │
│                                    │                                    │
│         ┌──────────────────────────┴────────────────────────┐          │
│         ▼                                                    ▼          │
│  ┌────────────────────────┐                ┌──────────────────────────┐ │
│  │  Smart Account         │                │  EOA (EIP-7702 path)     │ │
│  │  (ERC-4337 / ERC-7579) │                │                          │ │
│  │                        │                │  Delegates code to       │ │
│  │  ISubscriptionModule   │                │  SubscriptionDelegate    │ │
│  │  (ERC-7579 Validator   │                │  (same permission model) │ │
│  │   + Executor module)   │                │                          │ │
│  └────────────────────────┘                └──────────────────────────┘ │
└───────────────────────────────────────────────────────────────────────┘
```

**Authorization model.** The user signs exactly once at subscription setup. For smart account users, this is a UserOperation that installs the `SubscriptionModule` and stores the `SubscriptionPermission`. For EOA users, this is an EIP-7702 delegation transaction that binds the EOA to a `SubscriptionDelegate` contract for the duration of the subscription. In both cases, a scoped session key is registered — the platform backend holds the corresponding private key and uses it to construct renewal transactions. The session key has no capabilities beyond executing transfers that match the stored permission.

**Renewal model.** An off-chain crank (platform-operated) periodically queries `ISubscriptionRegistry.getDueSubscriptions()` and submits UserOperations signed with the session key. The bundler routes through the `SubscriptionPaymaster`, which sponsors gas. On-chain validation enforces period elapsed, amount ceiling, and active status — the crank is a liveness mechanism, not a trust assumption. A malicious or compromised crank can only charge `maxAmount` to the pre-specified `merchant` address at the minimum interval `periodSeconds`.

**Security model.** Permissions are scoped to a single `(token, merchant, maxAmount, periodSeconds)` tuple. Compromise of the session key is bounded: the attacker can charge at most `maxAmount` per `periodSeconds` to the pre-approved `merchant` address. The user retains an unscoped key and can cancel at any time. There is no upgrade path from the session key to broader wallet access.

---

## 4. Specification

### 4.1 Core Data Structures

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// @notice Status of a subscription permission.
enum SubscriptionStatus {
    Active,       // 0 — Charging on schedule
    Paused,       // 1 — User-initiated pause; no charge attempts
    Cancelled,    // 2 — Permanently cancelled; session key invalidated
    Expired,      // 3 — Hard expiry reached or max retries exceeded
    GracePeriod   // 4 — Charge failed; within merchant-configured grace window
}

/// @notice Core authorization record. One instance per (user, merchant, plan) tuple.
/// @dev Stored within the SubscriptionModule or SubscriptionDelegate.
struct SubscriptionPermission {
    /// @dev ERC-20 token address (e.g., USDC at 6 decimals).
    address token;

    /// @dev Merchant's receiving address. Immutable after creation.
    address merchant;

    /// @dev Maximum token amount chargeable per period (in token base units).
    ///      A renewal attempting to charge more than this MUST revert.
    uint256 maxAmount;

    /// @dev Minimum seconds between successive charges. Enforced on-chain.
    ///      Renewal before (lastChargedAt + periodSeconds) MUST revert.
    uint32 periodSeconds;

    /// @dev Timestamp when the subscription became active.
    uint48 startTime;

    /// @dev Timestamp of the last successful charge. 0 if never charged.
    uint48 lastChargedAt;

    /// @dev Hard expiration timestamp. After this point, all renewal attempts
    ///      MUST revert regardless of status. 0 = no hard expiry.
    uint48 expiresAt;

    /// @dev Current lifecycle status.
    SubscriptionStatus status;

    /// @dev Merchant-defined plan identifier. Stored for off-chain indexing
    ///      and upgrade/downgrade flows; not validated on-chain.
    bytes32 planId;

    /// @dev Address corresponding to the session key authorized to trigger
    ///      renewals. The module validates that renewal UserOps are signed
    ///      by the private key corresponding to this address.
    address sessionKey;
}

/// @notice A merchant-defined billing plan. Registered in MerchantRegistry.
struct Plan {
    /// @dev Unique plan identifier (keccak256 of merchant address + plan name).
    bytes32 planId;

    /// @dev Merchant address owning this plan.
    address merchant;

    /// @dev ERC-20 token for billing.
    address token;

    /// @dev Exact charge amount per period (in token base units).
    uint256 amount;

    /// @dev Billing interval in seconds (e.g., 2592000 = 30 days).
    uint32 period;

    /// @dev Human-readable plan name for wallet display (max 64 bytes).
    string name;

    /// @dev Whether this plan is accepting new subscribers.
    bool active;
}

/// @notice Merchant configuration. Registered in MerchantRegistry.
struct Merchant {
    /// @dev Unique merchant identifier (keccak256 of receiver address).
    bytes32 merchantId;

    /// @dev Address that receives net subscription payments (after protocol fee).
    address receiver;

    /// @dev Protocol fee in basis points charged on each renewal (e.g., 150 = 1.5%).
    uint16 feeTier;

    /// @dev Off-chain webhook URL for payment event delivery.
    ///      Stored on-chain for transparency; never validated.
    string webhookUrl;

    /// @dev Whether this merchant account is active. Inactive merchants cannot
    ///      receive new subscriptions; existing ones are not affected.
    bool active;
}
```

---

### 4.2 Interfaces

#### ISubscriptionModule

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import { SubscriptionPermission, SubscriptionStatus } from "./SubscriptionTypes.sol";

/// @title ISubscriptionModule
/// @notice ERC-7579 Validator + Executor module interface for subscription permissions.
/// @dev Implementations MUST comply with ERC-7579 module interfaces
///      (IValidator, IExecutor) in addition to this interface.
interface ISubscriptionModule {

    // ─── Lifecycle ────────────────────────────────────────────────────────────

    /// @notice Create a new subscription permission.
    /// @dev MUST be called from the account that will hold the permission
    ///      (i.e., msg.sender == the smart account, or via UserOperation).
    ///      Emits SubscriptionCreated.
    ///      Reverts if planId does not exist in the MerchantRegistry, or if
    ///      a permission for (merchant, planId) already exists with Active status.
    /// @param planId   Merchant plan to subscribe to.
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
```

#### ISubscriptionValidator

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// @title ISubscriptionValidator
/// @notice Validation hook for renewal UserOperations.
/// @dev This interface is called by the smart account's validateUserOp path.
///      Implementations MUST enforce all of the following before returning success:
///      1. The UserOp is signed by the session key registered for subscriptionId.
///      2. block.timestamp >= permission.lastChargedAt + permission.periodSeconds.
///      3. permission.status == SubscriptionStatus.Active.
///      4. The charge amount equals the plan amount (not merely <= maxAmount).
///      5. If permission.expiresAt != 0: block.timestamp < permission.expiresAt.
interface ISubscriptionValidator {

    /// @notice Validate a renewal UserOperation.
    /// @dev Returns SIG_VALIDATION_SUCCESS (0) or SIG_VALIDATION_FAILED (1)
    ///      following ERC-4337 convention.
    ///      MUST revert with a descriptive error rather than returning failed
    ///      when the subscription is in a terminal state (Cancelled, Expired).
    /// @param subscriptionId  Subscription being renewed.
    /// @param userOpHash      ERC-4337 UserOperation hash.
    /// @param signature       Signature bytes from the UserOperation.
    /// @return validationData Packed ERC-4337 validation result.
    function validateRenewal(
        bytes32 subscriptionId,
        bytes32 userOpHash,
        bytes   calldata signature
    ) external returns (uint256 validationData);
}
```

#### ISubscriptionRegistry

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import { SubscriptionPermission } from "./SubscriptionTypes.sol";

/// @title ISubscriptionRegistry
/// @notice Global index of all subscription permissions across all accounts.
/// @dev Modules and delegates MUST call register() on creation and
///      updateStatus() on every status transition.
interface ISubscriptionRegistry {

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
    /// @param newStatus       Updated status.
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
}
```

#### IMerchantRegistry

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import { Merchant, Plan } from "./SubscriptionTypes.sol";

/// @title IMerchantRegistry
/// @notice Merchant onboarding and plan management.
/// @dev Plans registered here are the on-chain source of truth for subscription
///      terms. Wallets and modules MUST validate that the planId presented at
///      subscribe() time exists and is active in this registry.
interface IMerchantRegistry {

    /// @notice Register a new merchant.
    /// @dev Caller becomes the merchant authority (can register/deprecate plans).
    ///      Emits MerchantRegistered.
    /// @param receiver    Address to receive net subscription payments.
    /// @param webhookUrl  Off-chain webhook endpoint (stored for transparency).
    /// @return merchantId keccak256(receiver).
    function registerMerchant(
        address receiver,
        string calldata webhookUrl
    ) external returns (bytes32 merchantId);

    /// @notice Register a billing plan under the calling merchant.
    /// @dev Emits PlanRegistered.
    ///      Plan amount and period are immutable after registration.
    ///      To change pricing, register a new plan and deprecate the old one.
    /// @param token    ERC-20 token for billing.
    /// @param amount   Charge amount per period (in token base units).
    /// @param period   Billing interval in seconds.
    /// @param name     Human-readable plan name (max 64 bytes).
    /// @return planId  keccak256(merchantAddress, name).
    function registerPlan(
        address token,
        uint256 amount,
        uint32  period,
        string  calldata name
    ) external returns (bytes32 planId);

    /// @notice Deprecate a plan. Existing subscribers are not affected.
    /// @dev Emits PlanDeprecated. New subscriptions to this planId MUST revert.
    /// @param planId  Plan to deprecate.
    function deprecatePlan(bytes32 planId) external;

    /// @notice Fetch merchant configuration.
    function getMerchant(bytes32 merchantId)
        external
        view
        returns (Merchant memory);

    /// @notice Fetch plan configuration.
    function getPlan(bytes32 planId)
        external
        view
        returns (Plan memory);
}
```

#### ISubscriptionPaymaster

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// @title ISubscriptionPaymaster
/// @notice ERC-4337 Verifying Paymaster for subscription-related UserOperations.
/// @dev Extends the standard ERC-4337 paymaster interface. Implementations MUST
///      restrict sponsorship to UserOperations whose callData targets one of:
///      subscribe(), cancel(), pause(), resume(), update(), or processRenewal().
///      Any UserOperation targeting other calldata MUST be rejected.
interface ISubscriptionPaymaster {

    /// @notice Validate and approve gas sponsorship for a subscription UserOp.
    /// @dev Implements ERC-4337 IPaymaster.validatePaymasterUserOp.
    ///      MUST verify that:
    ///      1. The UserOp callData selector is an allowlisted subscription function.
    ///      2. The per-user gas budget has not been exceeded (rate limiting).
    ///      3. The paymaster has sufficient ETH balance.
    ///      Returns paymasterAndData context for postOp accounting.
    /// @param userOp       Packed UserOperation.
    /// @param userOpHash   Hash of the UserOperation.
    /// @param maxCost      Maximum gas cost the paymaster may be charged.
    /// @return context     Opaque bytes passed to postOp.
    /// @return validationData  Packed ERC-4337 validation result.
    function validatePaymasterUserOp(
        bytes calldata userOp,
        bytes32        userOpHash,
        uint256        maxCost
    ) external returns (bytes memory context, uint256 validationData);

    /// @notice Post-execution accounting hook.
    /// @dev Implements ERC-4337 IPaymaster.postOp.
    ///      Records actual gas consumed for rate-limit tracking.
    /// @param mode     PostOpMode (opSucceeded, opReverted, postOpReverted).
    /// @param context  Context from validatePaymasterUserOp.
    /// @param actualGasCost  Actual gas consumed (in wei).
    /// @param actualUserOpFeePerGas  Effective gas price.
    function postOp(
        uint8   mode,
        bytes   calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external;

    /// @notice Deposit ETH to fund gas sponsorship.
    function deposit() external payable;

    /// @notice Check remaining gas sponsorship balance.
    function balance() external view returns (uint256);
}
```

---

### 4.3 Events

All events in this section are part of the standard. Implementations MUST emit them exactly as specified. Off-chain indexers, wallets, and merchant webhooks rely on this schema for reliable event correlation.

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

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
/// @param reason          Human-readable failure reason (e.g., "insufficient balance").
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
/// @param reason          "hard_expiry" | "max_retries_exceeded".
event SubscriptionExpired(
    bytes32 indexed subscriptionId,
    string          reason
);
```

---

### 4.4 EIP-712 Typed Data Schema

Wallets MUST display subscription authorization requests using the following EIP-712 typed data structure. The human-readable summary shown to the user before signing MUST include: merchant name (resolved from `MerchantRegistry`), charge amount in human-readable token units, token symbol, and billing period in days or months.

**Domain separator:**

```solidity
bytes32 constant DOMAIN_TYPE_HASH = keccak256(
    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
);

// Domain values at deployment:
// name    = "SubscriptionPermissions"
// version = "1"
// chainId = <Monad mainnet chainId>
// verifyingContract = <SubscriptionModule or SubscriptionDelegate address>
```

**Type hash:**

```solidity
bytes32 constant SUBSCRIPTION_PERMISSION_TYPE_HASH = keccak256(
    "SubscriptionPermission("
        "address token,"
        "address merchant,"
        "uint256 maxAmount,"
        "uint32 periodSeconds,"
        "uint48 startTime,"
        "uint48 expiresAt,"
        "bytes32 planId,"
        "address sessionKey,"
        "uint256 nonce"
    ")"
);
```

**Encoding:**

```solidity
function hashPermission(
    SubscriptionPermission memory p,
    uint256 nonce
) internal pure returns (bytes32) {
    return keccak256(abi.encode(
        SUBSCRIPTION_PERMISSION_TYPE_HASH,
        p.token,
        p.merchant,
        p.maxAmount,
        p.periodSeconds,
        p.startTime,
        p.expiresAt,
        p.planId,
        p.sessionKey,
        nonce
    ));
}
```

**Wallet display requirement.** When signing a `SubscriptionPermission`, wallets MUST render:

```
Allow [merchant display name] to charge [amount] [token symbol]
every [N days / N months], starting [date].

Session key: [sessionKey address] (limited to this subscription only)
Expires: [expiresAt date, or "No hard expiry"]

You can cancel at any time from your wallet.
```

---

### 4.5 Subscription URI Format

The following URI scheme enables deep-linking to subscription checkout flows from QR codes, NFC tags, mobile apps, and web pages.

**Syntax:**

```
monad:subscribe?<params>
```

**Required parameters:**

| Parameter | Type | Description |
|---|---|---|
| `merchant` | `address` | Merchant receiving address (checksummed). |
| `plan` | `bytes32` | Plan identifier (0x-prefixed hex). |

**Optional parameters:**

| Parameter | Type | Description |
|---|---|---|
| `amount` | `uint256` | Charge amount override in token base units. If absent, use plan default. |
| `token` | `string` | Token symbol (e.g., `USDC`). MUST match plan token if provided. |
| `period` | `uint32` | Period override in seconds. If absent, use plan default. |
| `expires` | `uint48` | Hard expiry Unix timestamp. If absent, no expiry. |
| `redirect` | `string` | URL-encoded redirect after successful subscription (percent-encoded). |
| `chainId` | `uint256` | Chain ID. Defaults to Monad mainnet. |

**Example:**

```
monad:subscribe?merchant=0xAb5801a7D398351b8bE11C439e05C5B3259aeC9B&plan=0x4d6f6e61644d6f6e74686c79&token=USDC&period=2592000&redirect=https%3A%2F%2Fapp.example.com%2Fsuccess
```

Wallets that implement this standard MUST handle `monad:subscribe` URIs and route the user to a subscription approval flow that displays the EIP-712 data defined in §4.4 before requesting a signature.

---

### 4.6 Wallet Visibility Interface

Wallets enumerate active subscriptions by calling `ISubscriptionModule.getActiveSubscriptions()` on each installed module and, for EIP-7702-delegated EOAs, by calling the equivalent view on the `SubscriptionDelegate`.

For cross-account aggregation (e.g., a wallet managing multiple smart accounts), the registry provides a user-centric view:

```solidity
interface ISubscriptionRegistry {
    // (defined in §4.2 — restated here for wallet integration clarity)

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
```

Wallets SHOULD display the following fields for each active subscription:

- Merchant name (resolved off-chain from `merchantId` → display name mapping, or shown as address)
- Token amount and symbol
- Billing period in human-readable format
- Last charged date and next expected charge date (`lastChargedAt + periodSeconds`)
- Current status (Active, Paused, GracePeriod)
- Cancel and Pause buttons that construct the corresponding transactions

---

### 4.7 EIP-7702 Delegation Flow

For EOA users on Monad, the `SubscriptionDelegate` contract provides an EIP-7702-compatible delegation target that exposes identical subscription semantics to the ERC-7579 module.

**Subscription setup (EOA path):**

```
1. Merchant SDK resolves plan details from MerchantRegistry.

2. SDK constructs an EIP-7702 authorization:
   {
     chainId:  <Monad mainnet>,
     address:  <SubscriptionDelegate contract address>,
     nonce:    <EOA's current nonce>,
   }
   The EOA signs this authorization, granting the SubscriptionDelegate
   code access to its storage for the duration of the delegation.

3. SDK constructs a transaction that:
   a. Includes the signed EIP-7702 authorization (sets EOA code = delegate).
   b. Calls SubscriptionDelegate.subscribe(planId, sessionKey, expiresAt)
      which writes the SubscriptionPermission into the EOA's storage.
   c. Sets the platform as the fee payer (EOA need not hold MON for gas).

4. EOA signs the transaction. One signature, no further interaction required.

5. From this point, the platform backend uses the session key to trigger
   renewals. The SubscriptionDelegate's validateRenewal() enforces all
   permission constraints identically to the ERC-7579 module.
```

**Delegation revocation (cancellation):**

```
1. EOA calls SubscriptionDelegate.cancel(subscriptionId) with its own key.
2. Permission status is set to Cancelled.
3. EOA may then send a new transaction with EIP-7702 authorization pointing
   to address(0) to clear the code delegation entirely, if no other
   subscriptions remain active.
```

**Important constraints:**
- An EOA MUST NOT have conflicting EIP-7702 delegations. If the EOA is already delegated to another contract (e.g., a Safe or Biconomy Nexus), the platform MUST use the smart account's ERC-7579 module path instead.
- If the EOA's EIP-7702 delegation is revoked or overwritten while a subscription is active, subsequent renewal attempts will revert. The subscription will enter the retry/grace-period flow until the grace period expires.

---

## 5. Reference Implementation Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│  CONTRACTS                                                               │
│                                                                          │
│  SubscriptionModule.sol      — ISubscriptionModule + ISubscriptionValidator │
│  SubscriptionDelegate.sol    — EIP-7702 delegation target (same interface) │
│  SubscriptionRegistry.sol    — ISubscriptionRegistry global state index  │
│  MerchantRegistry.sol        — IMerchantRegistry plan & merchant config  │
│  SubscriptionPaymaster.sol   — ISubscriptionPaymaster ERC-4337 paymaster │
│  SubscriptionExecutor.sol    — Crank entry point: processRenewal()       │
│                                                                          │
│  OFF-CHAIN                                                               │
│                                                                          │
│  Renewal Crank               — Polls getDueSubscriptions(), submits UOps │
│  Retry Manager               — Tracks failure state, schedules retries   │
│  Webhook Relay               — Delivers events to merchant endpoints     │
└─────────────────────────────────────────────────────────────────────────┘
```

**SubscriptionModule.sol** implements `ISubscriptionModule` and `ISubscriptionValidator` as an ERC-7579 Validator + Executor module. It stores `SubscriptionPermission` entries in the smart account's own storage, keyed by `subscriptionId`. On validation, it verifies session key signatures and enforces timing/amount constraints. On execution, it calls `token.transfer()` from the smart account to the merchant, splits the protocol fee, and updates `lastChargedAt`. It calls `SubscriptionRegistry.recordCharge()` and `SubscriptionRegistry.updateStatus()` to keep the global index in sync.

**SubscriptionDelegate.sol** is functionally equivalent to `SubscriptionModule.sol` but is deployed as a standalone contract suitable for EIP-7702 delegation. It reads and writes `SubscriptionPermission` state from the EOA's storage slots (not the delegate's own storage) following EIP-7702 semantics. It implements the same `ISubscriptionValidator` interface so the `SubscriptionExecutor` can call into either path uniformly.

**SubscriptionRegistry.sol** is a global singleton that indexes all subscriptions by user address and merchant address, maintains a time-ordered heap of due renewals for efficient crank queries, and mirrors status/lastChargedAt from authoritative modules for read-only access. It is the source of truth for off-chain tooling, wallets, and merchant dashboards. It does NOT hold any user funds and has no transfer authority.

**MerchantRegistry.sol** stores `Merchant` and `Plan` structs. Merchant registration is permissionless. Plan registration requires the caller to be the registered merchant authority. Plans are immutable after registration; merchants create new plans to change pricing and deprecate old ones. The registry is queried by `SubscriptionModule` at `subscribe()` time to validate planId and copy amount/period into the `SubscriptionPermission`.

**SubscriptionPaymaster.sol** implements ERC-4337 `IPaymaster`. It maintains a whitelist of allowlisted calldata selectors and rejects any UserOperation not matching this allowlist. It enforces per-user gas budgets (daily spend limit) to prevent paymaster drain attacks. It is funded by the protocol treasury, which is replenished from the `feeTier` percentage taken from each renewal.

**SubscriptionExecutor.sol** is the crank-facing entry point. Its sole external function is `processRenewal(bytes32 subscriptionId)`. It resolves the user account and module from the registry, calls `ISubscriptionValidator.validateRenewal()`, executes the transfer, and emits the standard events. The crank constructs UserOperations targeting this contract.

---

## 6. Use Cases

**6.1 SaaS Subscriptions**
A B2B tool (project management, analytics, API access) charges $49/month in USDC. The merchant registers a plan (`plan_pro_monthly`, 49 USDC, 30 days). Users subscribe once via wallet. Renewals execute invisibly on the 1st of each billing period with no user interaction. The merchant receives 98.5% of each charge; 1.5% funds gas sponsorship. Full Stripe parity.

**6.2 Content Paywalls (Substack-equivalent)**
A newsletter platform registers per-creator plans on behalf of creators. Each creator has a unique `merchantId` and `receiver` address. Subscribers sign once; monthly charges are automatic. Creators see real-time subscriber counts and charge events via webhooks. Cancellations reflect immediately in wallet-layer subscription state.

**6.3 AI Agent Usage-Based Billing**
An AI agent runtime (inference, memory, tool access) registers metered plans. Usage-based billing is implemented as: fixed base subscription (access token) + separate per-call charges via the x402 protocol. The subscription layer handles the base access grant; x402 handles per-request metering. The `SubscriptionPermission` gates x402 payment authorization — agents cannot charge unless the user holds an active subscription.

**6.4 DePIN Service Subscriptions**
A decentralized storage or compute network bills per epoch. Providers register epoch-length plans (e.g., 86400 seconds = 1 day). Subscribers authorize epoch-by-epoch billing. The crank submits renewals at epoch boundaries. `SubscriptionFailed` events trigger automatic service suspension; `SubscriptionCharged` events restore access. No custodied funds required.

**6.5 DAO Contributor Stipends**
A DAO treasury creates subscriptions as "reverse" plans: the DAO is the subscriber, contributors are the merchants. Monthly stipends execute via the standard renewal flow, visible in the contributor's wallet. The DAO governance module can call `cancel()` to terminate a stipend via on-chain vote. All stipend state is queryable from the registry.

**6.6 Loan Repayment Schedules**
An on-chain lending protocol (Kamino, Morpho fork) requires borrowers to authorize a repayment schedule at origination using `subscribe()`. The protocol is the merchant. Missed payments surface as `SubscriptionFailed` events that trigger collateral liquidation logic via a Chainlink-Automation or crank callback. The `GracePeriod` status maps cleanly to a delinquency window before liquidation.

**6.7 Insurance Premium Payments**
An on-chain insurance protocol collects monthly premiums. Premium non-payment results in `SubscriptionExpired`, which the protocol reads to automatically invalidate coverage. Policy validity is verifiable on-chain by querying `ISubscriptionRegistry` — no oracle required.

**6.8 Cross-Protocol Scheduled Operations**
Composable DeFi: a yield vault registers as a merchant and issues subscriptions representing recurring rebalance authorizations. On each subscription cycle, the renewal executor triggers not just a token transfer but a CPI call into the vault's `rebalance()` function (via an executor extension). This enables scheduled, user-authorized cross-protocol operations using the same permission framework.

---

## 7. Security Considerations

**Session key compromise.** The session key private material is held by the platform backend. A compromise of the backend grants the attacker the ability to charge `maxAmount` to the pre-specified `merchant` address at the minimum interval of `periodSeconds` — nothing more. The attacker cannot redirect funds to an arbitrary address, cannot charge more than `maxAmount`, cannot charge more frequently than `periodSeconds`, and cannot interact with any other contract. The blast radius is bounded by the permission scope. Users should set `maxAmount` to the exact plan amount, not an inflated ceiling.

**Paymaster abuse.** The `SubscriptionPaymaster` enforces per-user daily gas budgets. A compromised session key cannot use the paymaster to submit arbitrary UserOperations — the calldata selector allowlist ensures only subscription functions are sponsored. Implementations SHOULD set a daily gas cap of ~10× the cost of a single renewal per user.

**Replay protection.** `lastChargedAt` is updated atomically on each successful charge. Any renewal attempt within `periodSeconds` of `lastChargedAt` reverts in the validator. Because renewals are UserOperations submitted to EntryPoint, standard ERC-4337 UserOperation replay protection (`nonce`) also applies.

**Front-running.** Subscription renewals have no economic incentive for front-running: the charge amount is fixed, the recipient is fixed, and there is no slippage or arbitrage. MEV bots gain nothing by reordering or sandwiching a renewal transaction.

**Merchant compromise.** If a merchant's `receiver` address is compromised, the attacker can only receive funds they were already owed (future renewals). They cannot alter plan terms (plans are immutable), cannot access subscriber smart accounts, and cannot prevent cancellations. Users can cancel at any time regardless of merchant state.

**EIP-7702 delegation revocation.** If an EOA's delegation is overwritten by a new EIP-7702 transaction (e.g., user installs a different smart account), the `SubscriptionDelegate` code is no longer active and renewal attempts will revert. The subscription will enter the grace-period flow. Wallets implementing EIP-7702 SHOULD warn users before overwriting an existing delegation if active subscriptions are detected in the EOA's storage.

**Smart account module removal.** If a user uninstalls the `SubscriptionModule` without first calling `cancel()`, the registry may show stale Active subscriptions. The crank will submit renewals that fail validation; the retry/expiry flow will naturally terminate the subscription. Implementations SHOULD emit a `SubscriptionExpired` event from the crank after repeated validation failures to clean up registry state.

---

## 8. Corner Cases & Edge Conditions

**Insufficient balance on renewal.** The renewal UserOperation reverts at the transfer step. `SubscriptionFailed` is emitted with `retryCount`. The crank schedules retries with exponential backoff: +1 day, +2 days, +4 days, +7 days. After 4 failures, status transitions to `GracePeriod` (default 7 days, merchant-configurable). If unresolved by grace expiry, status transitions to `Expired` and no further charge attempts are made. Users must re-subscribe. The paymaster does not charge gas for UserOperations that revert before state changes.

**Merchant address changes.** Merchant `receiver` addresses are immutable in `MerchantRegistry`. A merchant wishing to change their payment address must register a new `Merchant` entry and deprecate their old plans. Existing subscribers are not affected — they continue charging the old receiver. Merchants SHOULD manage fund forwarding off-chain from old to new address, or wait for existing subscriptions to lapse before retiring the old address.

**Plan price changes.** Plans are immutable. Merchants register a new plan and deprecate the old one. Existing subscribers on the old plan continue at the old price indefinitely until they `update()` to the new plan or cancel. Merchants communicate pricing changes off-chain (email/webhook); the protocol does not force-migrate subscribers.

**Subscription upgrades/downgrades (proration).** `ISubscriptionModule.update()` does not reset `lastChargedAt`. Proration logic (credit for unused current period applied to first charge on new plan) is application-layer: the merchant SDK computes proration and applies it as an off-chain billing adjustment. On-chain, the new plan's `amount` and `periodSeconds` take effect from the next renewal.

**Multiple concurrent subscriptions to the same merchant.** The `subscriptionId` is derived from `(user, merchant, planId, startTime)`, not just `(user, merchant)`. A user may hold multiple concurrent subscriptions to the same merchant (e.g., personal and business plans). The module stores each independently, with separate session keys and charge tracking.

**Token migration (USDC → bridged USDC scenarios).** If a token migrates contract address (e.g., Ethereum USDC to native USDC on Monad), existing subscriptions reference the old token address and will continue to charge against it until cancelled. Merchants and platforms must notify subscribers and coordinate re-subscription on the new token. This is an application-layer concern; the protocol enforces whatever token address is in the stored permission.

**EIP-7702 delegation expiry during active subscription.** EIP-7702 delegations do not expire on their own; they persist until overwritten. However, if a user's EIP-7702 delegation is cleared (e.g., via an EOA transaction setting code to `address(0)`), the subscription enters the retry/grace-period flow. Wallet implementations SHOULD detect active subscriptions before allowing delegation removal and warn the user.

**Session key rotation.** `ISubscriptionModule.rotateSessionKey()` atomically replaces the authorized session key. The old key is invalidated immediately — any in-flight UserOperation signed by the old key will fail validation. The platform MUST coordinate key rotation with the crank to avoid a brief window of failed renewals. Recommended: rotate key, wait one block for finality, then update crank configuration.

---

## 9. Dependencies

| Dependency | Version | Role |
|---|---|---|
| **ERC-4337** | EntryPoint v0.7+ | UserOperation infrastructure, bundler network, paymaster pattern |
| **ERC-7579** | Current | Modular smart account interface; `IValidator`, `IExecutor` base interfaces |
| **EIP-7702** | Monad-native | EOA delegation to `SubscriptionDelegate` without smart account migration |
| **ERC-20** | Standard | Token transfer interface used for all subscription charges |
| **EIP-2612 (Permit)** | Optional | Gasless token approval at subscribe time; reduces setup to one UserOperation |
| **OpenZeppelin v5** | ^5.0.0 | `SafeERC20`, `ReentrancyGuard`, `Pausable`, `AccessControl` |

**EIP-2612 note.** If the subscription token supports `permit()`, the setup UserOperation can bundle the token approval and the `subscribe()` call, reducing the setup flow to a single UserOperation with no prior on-chain approval transaction. Implementations SHOULD attempt permit-based setup and fall back to standard `approve` if the token does not support it.

---

## 10. Risks & Open Questions

**Keeper/crank centralization.** The renewal crank is platform-operated. This is a liveness dependency but not a safety dependency: on-chain validation prevents the crank from overcharging, early-charging, or redirecting funds. Acceptable tradeoff for v1. Phase 2 mitigation: open the `processRenewal()` function to any caller (it is already permissionless in the spec) and incentivize third-party crank operators with a small per-renewal bounty funded from the protocol fee.

**No native scheduling on Monad.** Monad has no EVM-equivalent of the Solana SIMD native-scheduling proposal. Crank-based renewals are the correct architecture given current runtime capabilities. This is an accepted constraint, not a blocking gap.

**Merchant webhook reliability.** Webhooks are fire-and-forget; this MIP specifies the on-chain event schema but not the delivery guarantees. Webhook delivery is application-layer infrastructure and is explicitly out of scope. Merchants MUST index events independently (via the standard event schema) rather than relying solely on webhook delivery.

**Wallet adoption.** The standard's value is proportional to wallet adoption. Without at least one major Monad wallet implementing the `monad:subscribe` URI handler and subscription dashboard UI, the interoperability benefit is unrealized. Adoption depends on ecosystem buy-in after MIP acceptance. The `ISubscriptionRegistry.getActiveSubscriptionsForWallet()` interface is intentionally simple to minimize wallet integration cost.

**Stablecoin depeg scenarios.** This MIP supports any ERC-20 token. USDC or USDT depegging does not affect the protocol — subscriptions are denominated in fixed token amounts, not USD value. A merchant charging 10 USDC/month continues to receive exactly 10 USDC regardless of USDC market price. Dollar-value preservation is out of scope and is a merchant-layer concern.

**Open question: Subscription NFTs.** Should active subscriptions be represented as ERC-721 tokens? Arguments for: subscriptions become transferable, marketplaces can emerge for subscription resale (e.g., 11 months of Netflix remaining), better composability with DeFi. Arguments against: adds complexity, enables subscription farming/speculation, complicates revocation (new holder must cancel). This MIP does not mandate ERC-721 representation. An opt-in extension where the module mints an ERC-721 on `subscribe()` and burns it on `cancel()` is compatible with this standard and is left for a future extension MIP.

---

## 11. Backwards Compatibility

This MIP is a new addition with no breaking changes to any existing standard.

**ERC-4337 compatibility.** `SubscriptionModule.sol` and `SubscriptionPaymaster.sol` implement the ERC-4337 `IAccount`, `IValidator`, and `IPaymaster` interfaces as specified in EntryPoint v0.7. No modifications to EntryPoint or the bundler protocol are required.

**ERC-7579 compatibility.** `SubscriptionModule.sol` implements the ERC-7579 module interface. Any smart account that supports ERC-7579 module installation (Biconomy Nexus, Kernel, Safe with ERC-7579 adapter) can install this module without modification to the account contract.

**EIP-7702 compatibility.** `SubscriptionDelegate.sol` is designed as a standalone EIP-7702 delegation target. It does not conflict with other EIP-7702 delegation patterns, though only one delegation can be active per EOA at a time.

**Existing approvals.** This MIP does not deprecate or conflict with ERC-20 `approve()` or Permit2 `AllowanceTransfer`. They remain valid for applications that do not need subscription semantics. This standard is additive.

---

## 12. Rationale

**Why ERC-7579 module, not a fully custom contract.** ERC-7579 provides an audited, composable extension mechanism with broad smart account support. A custom contract would require individual integration work with each smart account vendor. ERC-7579 gives cross-vendor interoperability by default, and the module pattern ensures the subscription logic is sandboxed from the account's other functionality.

**Why session keys, not permit-based renewals.** Permit-based renewals require either a new user signature per renewal (defeating "set and forget") or an infinite approval (unacceptable security posture). Session keys provide the correct tradeoff: one setup signature, scoped authority for all subsequent renewals, with no user involvement after setup. The bounded blast radius of a scoped session key is strictly better than an unbounded approve.

**Why scoped permissions, not unlimited approvals.** Unlimited ERC-20 approvals to a subscription contract would expose users to total fund loss if the contract is compromised. Scoped permissions (`maxAmount` per `periodSeconds` to a specific `merchant`) ensure that the worst-case loss from any single compromise is bounded and predictable. This matches the user's mental model of "I authorized $9.99/month" rather than "I authorized unlimited USDC to this contract."

**Why crank-based renewals, not native scheduling.** Monad has no native scheduling primitive equivalent to the proposed Solana SIMD. Crank-based triggering is the correct architecture given this constraint, and it is the standard pattern in EVM account abstraction (Chainlink Automation, Gelato, platform-operated cranks). The protocol's on-chain validation guarantees that no crank — including the platform's own — can violate the stored permission. Decentralized cranking can be added in a future extension without changing this standard.

**Why Monad over Ethereum mainnet.** Three concrete improvements justify Monad as the primary deployment target: (1) EIP-7702 support expands addressable users from smart account holders to all EOA users; (2) gas costs of ~$0.001/renewal make paymaster economics viable for subscriptions as small as $1/month, whereas Ethereum mainnet gas ($0.50–$5.00/renewal) requires subscriptions above $50/month to be economically viable; (3) parallel execution enables batch renewal throughput at scale that is not achievable on sequential EVM chains.

---

## 13. References

**Standards:**
- [ERC-4337](https://eips.ethereum.org/EIPS/eip-4337) — Account Abstraction Using Alt Mempool
- [ERC-7579](https://eips.ethereum.org/EIPS/eip-7579) — Minimal Modular Smart Accounts
- [EIP-7702](https://eips.ethereum.org/EIPS/eip-7702) — Set EOA Account Code
- [ERC-20](https://eips.ethereum.org/EIPS/eip-20) — Token Standard
- [EIP-2612](https://eips.ethereum.org/EIPS/eip-2612) — Permit Extension for ERC-20
- [EIP-712](https://eips.ethereum.org/EIPS/eip-712) — Typed Structured Data Hashing and Signing

**Infrastructure:**
- [Biconomy Nexus](https://docs.biconomy.io) — ERC-7579 smart account deployed on Monad
- [Pimlico](https://docs.pimlico.io) — Bundler and paymaster infrastructure on Monad
- [Monad Documentation](https://docs.monad.xyz) — EIP-7702 support, parallel execution, MonadBFT

**Prior Art:**
- [Superfluid](https://docs.superfluid.finance) — Streaming payment protocol (continuous flows; different primitive)
- [Sablier](https://docs.sablier.com) — Token vesting and lockup streams
- [Cask Protocol](https://docs.cask.fi) — EVM subscription protocol (deprecated)
- [Unlock Protocol](https://docs.unlock-protocol.com) — NFT-based subscription memberships
- [Rhinestone Module Registry](https://docs.rhinestone.wtf) — ERC-7579 module registry and tooling

**Related Proposals:**
- SIMD-XXXX: Native Scheduled Transfer Instruction (Solana) — analogous primitive for Solana runtime; this MIP is the EVM equivalent using application-layer scheduling

---

*Draft prepared April 10, 2026. Monad mainnet launched November 24, 2025. ERC-4337 (Biconomy Nexus + Pimlico) and EIP-7702 confirmed live on Monad mainnet as of this date.*
